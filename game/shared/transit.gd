class_name TransitNetwork
extends RefCounted
## Deterministic tram timetable shared by server and client. A vehicle's
## position is a pure function of server time, so trams cost no bandwidth,
## every client sees them in the same place, and the server can validate
## boarding against the same numbers.
##
## Lines are "loop" (one-way ring, e.g. the real T3) or "shuttle" (runs to
## the last stop, lays over, runs back). Paths are local EN metres and may
## extend beyond the zone; vehicles are only drawn and boardable inside it.

const DWELL := 0
const MOVE := 1
const PLATFORM_OFFSET := 2.4
const FLOOR_HEIGHT := 0.32
const ZONE_MARGIN := 40.0
# Car bodies: modern trams are three 8 m sections, the nostalgic car one.
const MODERN_OFFSETS := [-8.3, 0.0, 8.3]
const MODERN_SECTION := 8.0
const NOSTALGIC_SECTION := 10.9
const CAR_HALF_WIDTH := 1.2

var lines: Array = []  # of TransitLine
var zone_half := 256.0
var terrain := Terrain.new()  # set by ZoneData; flat until then
var _state_cache := {}  # Vector3i(line, vehicle, tick) -> state
var _coarse_tick := -1000000
var _coarse: Array = []  # [line, vehicle, pos (EN)] at _coarse_tick


class TransitLine:
	extends RefCounted
	var index := 0
	var id := ""
	var name := ""
	var short_name := ""
	var color := Color.WHITE
	var source := "osm"
	var loop := false
	var path := PackedVector2Array()
	var cum := PackedFloat64Array()
	var length := 0.0
	var stops: Array = []  # {id, name, s, pos: Vector2, in_zone}
	var speed := 7.0
	var accel := 1.0
	var dwell := 14.0
	var layover := 25.0
	var vehicles := 2
	var vehicle_type := "modern"
	var vehicle_length := 24.0
	var track_offset := 1.6
	var right_track := PackedVector2Array()  # path offset to its right, mitred
	var left_track := PackedVector2Array()
	# The timetable cycle as legs (dwell or move), in parallel packed arrays:
	# state() runs for every tram every frame, and packed arrays are several
	# times faster to read than dictionaries.
	var leg_starts := PackedFloat64Array()
	var leg_dur := PackedFloat64Array()
	var leg_kind := PackedInt32Array()
	var leg_s0 := PackedFloat64Array()
	var leg_s1 := PackedFloat64Array()
	var leg_dir := PackedInt32Array()
	var leg_stop := PackedInt32Array()
	var leg_next := PackedInt32Array()
	var cycle := 1.0

	func setup(data: Dictionary, zone_half: float) -> void:
		id = str(data.id)
		name = str(data.name)
		short_name = str(data.get("short_name", name))
		color = Color(str(data.color))
		source = str(data.get("source", "osm"))
		loop = str(data.kind) == "loop"
		for p in data.path:
			path.append(Vector2(float(p[0]), float(p[1])))
		cum.append(0.0)
		for i in path.size() - 1:
			cum.append(cum[i] + path[i].distance_to(path[i + 1]))
		length = cum[cum.size() - 1]
		for st in data.stops:
			var pos := Vector2(float(st.e), float(st.n))
			var plat: Dictionary = st.get("platform", {})
			var default_off := float(data.get("track_offset", 0.0)) + PLATFORM_OFFSET
			stops.append({"id": str(st.id), "name": str(st.name), "s": float(st.s), "pos": pos,
				"in_zone": bool(st.in_zone) and absf(pos.x) < zone_half - 5.0 and absf(pos.y) < zone_half - 5.0,
				"plat_r": float(plat.get("r", default_off)), "plat_l": float(plat.get("l", default_off)),
				"room_r": float(plat.get("r_room", 8.0)), "room_l": float(plat.get("l_room", 8.0))})
		speed = float(data.speed)
		accel = float(data.accel)
		dwell = float(data.dwell)
		layover = float(data.get("layover", dwell))
		vehicles = maxi(1, int(data.vehicles))
		vehicle_type = str(data.get("vehicle_type", "modern"))
		vehicle_length = 11.0 if vehicle_type == "nostalgic" else 24.0
		track_offset = float(data.get("track_offset", 0.0 if loop else 1.6))
		right_track = _offset_path(track_offset)
		left_track = _offset_path(-track_offset)
		_build_legs()

	## The path shifted sideways with mitred corners. Vertex i of the result
	## corresponds to vertex i of the path, so arc length maps segment by
	## segment and trams line up with platforms after every bend.
	func _offset_path(offset: float) -> PackedVector2Array:
		var out := PackedVector2Array()
		var n := path.size()
		for i in n:
			var d_in := _dir(path[i - 1], path[i]) if i > 0 else Vector2.ZERO
			var d_out := _dir(path[i], path[i + 1]) if i < n - 1 else Vector2.ZERO
			if loop and (i == 0 or i == n - 1):
				d_in = _dir(path[n - 2], path[n - 1])
				d_out = _dir(path[0], path[1])
			var n_in := Vector2(d_in.y, -d_in.x)
			var n_out := Vector2(d_out.y, -d_out.x)
			var miter := (n_in + n_out).normalized() if (n_in + n_out).length() > 0.01 else (n_out if d_out != Vector2.ZERO else n_in)
			var ref := n_out if d_out != Vector2.ZERO else n_in
			var scale := 1.0 / maxf(0.4, miter.dot(ref))
			out.append(path[i] + miter * offset * minf(scale, 2.5))
		return out

	static func _dir(a: Vector2, b: Vector2) -> Vector2:
		return (b - a).normalized() if a.distance_squared_to(b) > 1e-6 else Vector2.ZERO

	## Stop visits in running order: (stop index, departing direction).
	func _visits() -> Array:
		var n := stops.size()
		var out := []
		if loop:
			for i in n:
				out.append([i, 1])
		else:
			for i in n - 1:
				out.append([i, 1])
			for i in range(n - 1, 0, -1):
				out.append([i, -1])
		return out

	func _build_legs() -> void:
		var visits := _visits()
		var t := 0.0
		for k in visits.size():
			var i: int = visits[k][0]
			var dir: int = visits[k][1]
			var nxt: int = visits[(k + 1) % visits.size()][0]
			var terminus := not loop and (i == 0 or i == stops.size() - 1)
			var wait := layover if terminus else dwell
			var s0: float = stops[i].s
			_add_leg(t, wait, DWELL, s0, s0, dir, i, nxt)
			t += wait
			var s1: float = stops[nxt].s
			if loop and s1 <= s0:
				s1 += length
			var dur := travel_time(absf(s1 - s0))
			_add_leg(t, dur, MOVE, s0, s1, dir, i, nxt)
			t += dur
		cycle = maxf(t, 1.0)

	func _add_leg(t0: float, dur: float, kind: int, s0: float, s1: float, dir: int, stop: int, next: int) -> void:
		leg_starts.append(t0)
		leg_dur.append(dur)
		leg_kind.append(kind)
		leg_s0.append(s0)
		leg_s1.append(s1)
		leg_dir.append(dir)
		leg_stop.append(stop)
		leg_next.append(next)

	func travel_time(d: float) -> float:
		if d <= 0.0:
			return 0.0
		if d >= speed * speed / accel:
			return d / speed + speed / accel
		return 2.0 * sqrt(d / accel)

	## Distance covered tau seconds into a trapezoidal run of length d.
	func travel_distance(d: float, tau: float) -> float:
		var total := travel_time(d)
		tau = clampf(tau, 0.0, total)
		var ta := minf(speed / accel, total / 2.0)
		var peak := accel * ta
		if tau < ta:
			return 0.5 * accel * tau * tau
		if tau < total - ta:
			return 0.5 * accel * ta * ta + peak * (tau - ta)
		var r := total - tau
		return d - 0.5 * accel * r * r

	func travel_speed(d: float, tau: float) -> float:
		var total := travel_time(d)
		var ta := minf(speed / accel, total / 2.0)
		return accel * minf(minf(tau, total - tau), ta)

	func phase(vehicle: int, t: float) -> float:
		return fposmod(t - vehicle * cycle / vehicles, cycle)

	func leg_at(tau: float) -> int:
		return clampi(leg_starts.bsearch(tau, false) - 1, 0, leg_kind.size() - 1)

	## Arc length along the path, wrapped for loops, extended past the ends for shuttles.
	func point_at(s: float) -> Vector2:
		return _on(path, s)

	func _on(poly: PackedVector2Array, s: float) -> Vector2:
		if loop:
			s = fposmod(s, length)
		var n := poly.size()
		if s <= 0.0:
			return poly[0] + _dir(poly[0], poly[1]) * s
		if s >= length:
			return poly[n - 1] + _dir(poly[n - 2], poly[n - 1]) * (s - length)
		var i := clampi(cum.bsearch(s, true) - 1, 0, n - 2)
		var seg := cum[i + 1] - cum[i]
		return poly[i].lerp(poly[i + 1], (s - cum[i]) / seg if seg > 0.0 else 0.0)

	func section_offsets() -> Array:
		return [0.0] if vehicle_type == "nostalgic" else MODERN_OFFSETS

	func section_length() -> float:
		return NOSTALGIC_SECTION if vehicle_type == "nostalgic" else MODERN_SECTION

	func tangent_at(s: float) -> Vector2:
		var a := point_at(s - 1.5)
		var b := point_at(s + 1.5)
		return (b - a).normalized() if a != b else Vector2.UP

	## Track centre for travel direction dir (right-hand running on shuttles).
	## side = 1 is the normal track; -1 the opposite one (used while reversing).
	func track_point(s: float, dir: int, side := 1.0) -> Vector2:
		if track_offset == 0.0:
			return point_at(s)
		# Right of travel is the path's right when running forward.
		var right := _on(right_track, s)
		var left := _on(left_track, s)
		var w := (side * dir + 1.0) / 2.0
		return left.lerp(right, w)

	func is_terminus(stop: int) -> bool:
		return not loop and (stop == 0 or stop == stops.size() - 1)

	## Where riders wait and step off: beside the track on the right of travel,
	## as far out as the buildings allow (measured by the world pipeline).
	func platform(stop: int, dir: int) -> Vector2:
		var s: float = stops[stop].s
		var t := tangent_at(s) * dir
		var off: float = stops[stop].plat_r if dir > 0 else stops[stop].plat_l
		return point_at(s) + Vector2(t.y, -t.x) * off

	## Free space between the track centre line and the nearest wall on that side.
	func platform_room(stop: int, dir: int) -> float:
		return float(stops[stop].room_r if dir > 0 else stops[stop].room_l)

	func state(vehicle: int, t: float) -> Dictionary:
		var tau := phase(vehicle, t)
		var li := leg_at(tau)
		var local := tau - leg_starts[li]
		var s0 := leg_s0[li]
		var s := s0
		var spd := 0.0
		var dwelling := leg_kind[li] == DWELL
		if not dwelling:
			var d := absf(leg_s1[li] - s0)
			s = s0 + signf(leg_s1[li] - s0) * travel_distance(d, local)
			spd = travel_speed(d, local)
		var dir := leg_dir[li]
		var side := 1.0
		if dwelling and is_terminus(leg_stop[li]):
			# Crossing over to the other track during the layover, not jumping.
			side = lerpf(-1.0, 1.0, smoothstep(0.2, 0.8, local / leg_dur[li]))
		return {
			"line": index, "vehicle": vehicle, "s": s, "dir": dir, "speed": spd,
			"dwelling": dwelling, "stop": leg_stop[li] if dwelling else -1,
			"next": leg_next[li], "leg": li, "leg_left": leg_dur[li] - local,
			"dwell_started": t - local if dwelling else -1.0, "side": side,
			"pos": track_point(s, dir, side), "heading": tangent_at(s) * dir,
		}

	## True when a rider may stay on past this stop visit: the next stop is in
	## the zone and the vehicle is not about to reverse at a terminus.
	func continues_in_zone(stop: int, dir: int) -> bool:
		if not loop and ((dir > 0 and stop == stops.size() - 1) or (dir < 0 and stop == 0)):
			return false
		var nxt := (stop + dir + stops.size()) % stops.size() if loop else stop + dir
		return nxt >= 0 and nxt < stops.size() and stops[nxt].in_zone

	## Stops a rider boarding at `stop` in `dir` can reach without leaving the zone.
	func reachable(stop: int, dir: int) -> Array:
		var out := []
		var cur := stop
		while continues_in_zone(cur, dir) and out.size() < stops.size():
			cur = (cur + dir + stops.size()) % stops.size() if loop else cur + dir
			out.append(cur)
		return out

	func _dwell_leg(stop: int, dir: int) -> int:
		for i in leg_kind.size():
			if leg_kind[i] == DWELL and leg_stop[i] == stop and leg_dir[i] == dir:
				return i
		return -1

	## Earliest vehicle whose dwell at (stop, dir) has not ended by time t:
	## {vehicle, arrive, depart} in absolute server time, or {} if none.
	func departure_after(stop: int, dir: int, t: float) -> Dictionary:
		var li := _dwell_leg(stop, dir)
		if li < 0:
			return {}
		var best := {}
		for v in vehicles:
			var tau := phase(v, t)
			# Time until this vehicle next *departs* from the dwell (end of leg).
			var until_depart := fposmod(leg_starts[li] + leg_dur[li] - tau, cycle)
			var depart := t + until_depart
			if best.is_empty() or depart < float(best.depart):
				best = {"vehicle": v, "arrive": depart - leg_dur[li], "depart": depart}
		return best

	## Seconds from departing `from` to arriving at `to` (both in direction dir).
	func ride_time(from: int, to: int, dir: int) -> float:
		var li := _dwell_leg(from, dir)
		if li < 0:
			return INF
		var total := 0.0
		var n := leg_kind.size()
		var i := (li + 1) % n
		for _k in n:
			if leg_kind[i] == DWELL and leg_stop[i] == to:
				return total
			total += leg_dur[i]
			i = (i + 1) % n
		return INF

	## Path points a rider covers from stop `from` to stop `to` in dir.
	func ride_path(from: int, to: int, dir: int, step := 6.0) -> PackedVector2Array:
		var s0: float = stops[from].s
		var s1: float = stops[to].s
		if loop and s1 <= s0:
			s1 += length
		var out := PackedVector2Array()
		var n := maxi(2, ceili(absf(s1 - s0) / step))
		for k in n + 1:
			var s := lerpf(s0, s1, float(k) / n)
			out.append(track_point(s, dir))
		return out

	## Destination shown on the vehicle: the terminus it is heading to.
	func destination(dir: int) -> String:
		if loop:
			return short_name
		return str(stops[stops.size() - 1].name if dir > 0 else stops[0].name)


static func from_zone(transit: Variant, zone_half: float) -> TransitNetwork:
	var net := TransitNetwork.new()
	net.zone_half = zone_half
	if typeof(transit) != TYPE_DICTIONARY:
		return net
	for data in transit.get("lines", []):
		var line := TransitLine.new()
		line.index = net.lines.size()
		line.setup(data, zone_half)
		if line.stops.size() >= 2 and line.path.size() >= 2:
			net.lines.append(line)
	return net


static func en_to_godot(p: Vector2, height := 0.0) -> Vector3:
	return Vector3(p.x, height, -p.y)


func vehicle_count() -> int:
	var n := 0
	for line: TransitLine in lines:
		n += line.vehicles
	return n


## Car-section boxes within `radius` of p (Godot XZ) at a server tick, for
## collisions: [centre XZ, travel direction XZ (unit), half length,
## half width, speed]. Vehicle states are cached per tick, since the server
## and a predicting client ask about the same few ticks many times.
func boxes_near(tick: int, p: Vector2, radius: float) -> Array:
	# Where every tram roughly is, refreshed every half second; a tram cannot
	# have moved further than its top speed allows since then.
	if absi(tick - _coarse_tick) > Protocol.TICK_RATE / 2:
		_coarse_tick = tick
		_coarse.clear()
		for line: TransitLine in lines:
			for v in line.vehicles:
				_coarse.append([line, v, line.state(v, tick * Protocol.DT).pos])
	if _state_cache.size() > 600:
		_state_cache.clear()
	var slack := absf(tick - _coarse_tick) * Protocol.DT * 9.0 + 1.0
	var en := Vector2(p.x, -p.y)
	var out := []
	for entry in _coarse:
		var line: TransitLine = entry[0]
		if (entry[2] as Vector2).distance_to(en) > radius + line.vehicle_length + slack:
			continue
		var key := Vector3i(line.index, int(entry[1]), tick)
		var st: Dictionary = _state_cache.get(key, {})
		if st.is_empty():
			st = line.state(int(entry[1]), tick * Protocol.DT)
			_state_cache[key] = st
		var centre: Vector2 = st.pos
		if absf(centre.x) > zone_half + 30.0 or absf(centre.y) > zone_half + 30.0 				or Vector2(centre.x, -centre.y).distance_to(p) > radius + line.vehicle_length:
			continue
		var dir: int = st.dir
		for off in line.section_offsets():
			var s := float(st.s) + float(off) * dir
			var c := line.track_point(s, dir, float(st.side))
			var h := line.tangent_at(s) * dir
			out.append([Vector2(c.x, -c.y), Vector2(h.x, -h.y), line.section_length() / 2.0 + 0.1, CAR_HALF_WIDTH, float(st.speed),
				terrain.height_en(c)])
	return out


## Rider standing spot: slots spread along the car, alternating sides.
func rider_position(line_index: int, vehicle: int, slot: int, t: float) -> Vector3:
	var line: TransitLine = lines[line_index]
	var st := line.state(vehicle, t)
	var usable := line.vehicle_length - 3.0
	var rows := maxi(1, int(usable / 1.4))
	var along := -usable / 2.0 + 1.4 * (slot / 2 % rows) + 0.7
	var side := 0.45 if slot % 2 == 0 else -0.45
	var s := float(st.s) + along * int(st.dir)
	var heading := line.tangent_at(s) * int(st.dir)
	var p := line.track_point(s, int(st.dir)) + Vector2(heading.y, -heading.x) * side
	return en_to_godot(p, terrain.height_en(p) + FLOOR_HEIGHT)


## A tram section's pose: on the rails at arc length s, pitched with the
## slope between its two ends (length `span`). -Z points along travel.
func section_transform(line: TransitLine, s: float, dir: int, side: float, span: float) -> Transform3D:
	var c := line.track_point(s, dir, side)
	var h := line.tangent_at(s) * dir
	var front := terrain.height_en(line.track_point(s + dir * span / 2.0, dir, side))
	var back := terrain.height_en(line.track_point(s - dir * span / 2.0, dir, side))
	var forward := Vector3(h.x, (front - back) / maxf(span, 0.1), -h.y)
	return Transform3D(Basis.looking_at(forward, Vector3.UP), Vector3(c.x, (front + back) / 2.0, -c.y))


## Vehicle (state dict) dwelling at an in-zone stop within `radius` of p, where
## a rider could stay on to at least one more stop. {} if none.
func boardable_near(p: Vector2, t: float, radius := 8.0) -> Dictionary:
	var best := {}
	var best_d := radius
	for line: TransitLine in lines:
		for v in line.vehicles:
			var st := line.state(v, t)
			if not st.dwelling or not line.stops[st.stop].in_zone or not line.continues_in_zone(st.stop, st.dir):
				continue
			var half_len: float = line.vehicle_length / 2.0
			var a: Vector2 = st.pos - st.heading * half_len
			var b: Vector2 = st.pos + st.heading * half_len
			var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, a, b))
			if d < best_d:
				best_d = d
				best = st
	return best
