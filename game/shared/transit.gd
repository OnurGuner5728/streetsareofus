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

var lines: Array = []  # of TransitLine


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
	var legs: Array = []  # {t0, dur, kind, s0, s1, dir, stop, next}
	var leg_starts := PackedFloat64Array()
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
			legs.append({"t0": t, "dur": wait, "kind": DWELL, "s0": s0, "s1": s0, "dir": dir, "stop": i, "next": nxt})
			t += wait
			var s1: float = stops[nxt].s
			if loop and s1 <= s0:
				s1 += length
			var d := absf(s1 - s0)
			var dur := travel_time(d)
			legs.append({"t0": t, "dur": dur, "kind": MOVE, "s0": s0, "s1": s1, "dir": dir, "stop": i, "next": nxt})
			t += dur
		cycle = maxf(t, 1.0)
		for leg in legs:
			leg_starts.append(leg.t0)

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
		return clampi(leg_starts.bsearch(tau, false) - 1, 0, legs.size() - 1)

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
		var leg: Dictionary = legs[li]
		var local := tau - float(leg.t0)
		var s: float = leg.s0
		var spd := 0.0
		if leg.kind == MOVE:
			var d := absf(float(leg.s1) - float(leg.s0))
			s = float(leg.s0) + signf(float(leg.s1) - float(leg.s0)) * travel_distance(d, local)
			spd = travel_speed(d, local)
		var dir: int = leg.dir
		var side := 1.0
		if leg.kind == DWELL and is_terminus(int(leg.stop)):
			# Crossing over to the other track during the layover, not jumping.
			side = lerpf(-1.0, 1.0, smoothstep(0.2, 0.8, local / float(leg.dur)))
		return {
			"line": index, "vehicle": vehicle, "s": s, "dir": dir, "speed": spd,
			"dwelling": leg.kind == DWELL, "stop": leg.stop if leg.kind == DWELL else -1,
			"next": leg.next, "leg": li, "leg_left": float(leg.dur) - local,
			"dwell_started": t - local if leg.kind == DWELL else -1.0, "side": side,
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
		for i in legs.size():
			var leg: Dictionary = legs[i]
			if leg.kind == DWELL and leg.stop == stop and leg.dir == dir:
				return i
		return -1

	## Earliest vehicle whose dwell at (stop, dir) has not ended by time t:
	## {vehicle, arrive, depart} in absolute server time, or {} if none.
	func departure_after(stop: int, dir: int, t: float) -> Dictionary:
		var li := _dwell_leg(stop, dir)
		if li < 0:
			return {}
		var leg: Dictionary = legs[li]
		var best := {}
		for v in vehicles:
			var tau := phase(v, t)
			# Time until this vehicle next *departs* from the dwell (end of leg).
			var until_depart := fposmod(float(leg.t0) + float(leg.dur) - tau, cycle)
			var depart := t + until_depart
			if best.is_empty() or depart < float(best.depart):
				best = {"vehicle": v, "arrive": depart - float(leg.dur), "depart": depart}
		return best

	## Seconds from departing `from` to arriving at `to` (both in direction dir).
	func ride_time(from: int, to: int, dir: int) -> float:
		var li := _dwell_leg(from, dir)
		if li < 0:
			return INF
		var total := 0.0
		var i := (li + 1) % legs.size()
		for _n in legs.size():
			var leg: Dictionary = legs[i]
			if leg.kind == DWELL and leg.stop == to:
				return total
			total += float(leg.dur)
			i = (i + 1) % legs.size()
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
	return en_to_godot(p, FLOOR_HEIGHT)


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
