class_name Traffic
extends RefCounted
## Road traffic: cars, yellow taxis, minibuses and IETT buses driving the
## main roads of the zone, on the right. Like the trams and the crowd it is
## a pure function of the zone package and the world time, so the server and
## every client see the same vehicles in the same places and nothing about
## traffic travels over the network.
##
## The drivable roads are turned into closed lane loops (TrafficRoute), each
## directed lane belongs to exactly one loop. Every loop carries a few
## platoons, one per signal cycle of its lap; a platoon is a rigid string of
## one to three vehicles. Vehicles slow for bends, stop for pedestrian
## crossings while their light is red (a fixed 40 s cycle per crossing, the
## same rule for everybody, so people can cross safely) and queue behind the
## leader of their platoon. Side streets and tram streets stay empty.

const CAR := 0
const TAXI := 1
const MINIBUS := 2
const BUS := 3
const LENGTHS := [4.2, 4.5, 6.3, 11.8]
const WIDTHS := [1.78, 1.8, 2.0, 2.5]
const HEIGHTS := [1.45, 1.5, 2.4, 3.1]
const PALETTE := ["f2f2f0", "f2f2f0", "d9dcdf", "b8bcc0", "2b2d30", "8e9499", "7a1f1f", "1f3b66", "c4b59a", "3d4a3a"]

const MIN_ROAD_WIDTH := 8.0  # narrower streets are one lane with parked cars
const ROAD_SPEEDS := {"primary": 12.5, "secondary": 10.0, "tertiary": 9.0, "unclassified": 7.0, "residential": 7.0}
const TRAM_CLEARANCE := 5.0
const LANE_CLEARANCE := 1.4  # a lane this close to a wall is not driven (car half width is 0.9 to 1.25)
const BUILDING_CLEARANCE := 2.0  # road centre lines this close to a wall are not driven
const ZONE_UTC_OFFSET := 3.0  # Istanbul
const ZONE_MARGIN := 25.0
const LOOP_CLOSE := 280.0  # a lane trail may end as soon as it is this long and can reach its start
const MIN_ROUTE := 150.0
const GATE_RADIUS := 6.0
const MAX_SPAN := 46.0  # longest platoon (m)
const PLATOON_GAP := 5.5
const CELL := 32.0
const COARSE_TICKS := 15
const COARSE_RADIUS := 30.0
const GRID := 8.0

## One driving vehicle. `pos`, `dir`, `speed` and `accel` describe it at the
## time of the last place() call.
class Vehicle:
	extends RefCounted
	var id := 0
	var route: TrafficRoute
	var slot := 0
	var member := 0
	var kind := 0
	var colour := 0
	var length := 4.2
	var width := 1.78
	var height := 1.45
	var lead := 0.0  # front bumper distance behind the platoon leader's
	var thr := 0.0  # on the road while the density is above this
	var pos := Vector2.ZERO  # centre, Godot XZ
	var dir := Vector2.RIGHT  # forward, unit
	var speed := 0.0
	var accel := 0.0
	var arc := 0.0
	var tick := -1000000

	func half_length() -> float:
		return length * 0.5

var zone_id := ""
var hour0 := 17.5  # local hour of day at world time 0
var routes: Array = []  # TrafficRoute
var vehicles: Array = []  # Vehicle
var gates_total := 0
var stats := {}  # build statistics, for tests and the log
var terrain: Terrain
var half := 256.0
var _cells := {}  # Vector2i (CELL) -> Array of route indices
var _coarse := {}  # Vector3i(cell x, cell z, bucket) -> Array of Vehicle
var _crossings := PackedVector2Array()  # XZ
var _phases := PackedFloat32Array()


static func for_zone(z: ZoneData) -> Traffic:
	if z.has_meta("traffic"):
		return z.get_meta("traffic")
	var traffic := Traffic.new(z)
	z.set_meta("traffic", traffic)
	return traffic


func _init(z: ZoneData) -> void:
	zone_id = z.zone_id
	terrain = z.terrain
	half = z.half_size()
	for i in z.crossings.size():
		_crossings.append(Vector2(float(z.crossings[i][0]), -float(z.crossings[i][1])))
		_phases.append(h01("%s:xing:%d" % [zone_id, i]) * TrafficRoute.CYCLE)
	_build(z)


## How busy the roads are at a local hour (0-24): quiet at night, two rush
## hours, a steady afternoon.
static func density(hours: float) -> float:
	var h := fposmod(hours, 24.0)
	var keys := [[0.0, 0.3], [3.5, 0.15], [6.0, 0.4], [8.0, 0.95], [10.0, 0.7], [13.0, 0.8], [16.0, 0.85],
		[18.0, 1.0], [20.0, 0.8], [22.0, 0.55], [24.0, 0.3]]
	for i in keys.size() - 1:
		if h <= float(keys[i + 1][0]):
			var a: Array = keys[i]
			var b: Array = keys[i + 1]
			return lerpf(float(a[1]), float(b[1]), (h - float(a[0])) / (float(b[0]) - float(a[0])))
	return 0.3


## The hour0 to use so that world time `t` (seconds, the server's clock) falls on
## the real local time in Istanbul; `forced_hour` >= 0 pins that hour instead.
static func clock_hour0(t: float, forced_hour := -1.0) -> float:
	var local := forced_hour
	if local < 0.0:
		local = fposmod(Time.get_unix_time_from_system() / 3600.0 + ZONE_UTC_OFFSET, 24.0)
	return fposmod(local - t / 3600.0, 24.0)


## Local hour of day at world time t (seconds).
func hours_at(t: float) -> float:
	return fposmod(hour0 + t / 3600.0, 24.0)


# --- crossings ---------------------------------------------------------------------

## Deterministic hash in [0, 1). WorldBuilder._hash01 keeps neighbouring keys
## (crossing 12 and 13) close together; the mixing step spreads them out.
static func h01(key: String) -> float:
	var h := hash(key) & 0xFFFFFFFF
	h ^= h >> 16
	h = (h * 0x85EBCA6B) & 0xFFFFFFFF
	h ^= h >> 13
	h = (h * 0xC2B2AE35) & 0xFFFFFFFF
	h ^= h >> 16
	return float(h & 0xFFFFFF) / float(0x1000000)


## True while cars stop for the pedestrian crossing `index` (world time t).
func crossing_red(index: int, t: float) -> bool:
	return fposmod(t - _phases[index], TrafficRoute.CYCLE) < TrafficRoute.RED


func crossing_count() -> int:
	return _crossings.size()


func crossing_position(index: int) -> Vector2:
	return _crossings[index]


# --- building ----------------------------------------------------------------------

static func lane_offset(kind: String, w: float, left: bool) -> float:
	# Lanes sit half way between the centre line and the kerb, but keep clear
	# of the cars that park along the kerb of ordinary streets.
	var off := w * 0.25
	if StreetLayout.PARKING_KINDS.has(kind) and w >= 6.0 and (w >= 9.0 or left):
		off = minf(off, maxf(w * 0.5 - 3.05, 0.7))
	return off


static func _vertex_normals(pts: PackedVector2Array) -> PackedVector2Array:
	# Right-hand normals (Godot XZ) per vertex, scaled so that offsetting by
	# a distance keeps that distance from both neighbouring segments.
	var out := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var n0 := Vector2.ZERO
		var n1 := Vector2.ZERO
		if i > 0:
			var d0 := (pts[i] - pts[i - 1]).normalized()
			n0 = Vector2(-d0.y, d0.x)
		if i < n - 1:
			var d1 := (pts[i + 1] - pts[i]).normalized()
			n1 = Vector2(-d1.y, d1.x)
		if n0 == Vector2.ZERO:
			n0 = n1
		if n1 == Vector2.ZERO:
			n1 = n0
		var m := n0 + n1
		m = m.normalized() if m.length() > 0.01 else n1
		out.append(m / maxf(m.dot(n1), 0.6))
	return out


func _build(z: ZoneData) -> void:
	var layout := StreetLayout.for_zone(z)
	var node_of := {}
	var node_pos := PackedVector2Array()
	var e_from := PackedInt32Array()
	var e_to := PackedInt32Array()
	var e_p0 := PackedVector2Array()
	var e_p1 := PackedVector2Array()
	var e_speed := PackedFloat32Array()
	var e_len := PackedFloat32Array()
	var out_edges: Array = []
	var pair := {}
	for road in z.roads:
		var kind := str(road.kind)
		var w := float(road.width)
		if not ROAD_SPEEDS.has(kind) or w < MIN_ROAD_WIDTH or not bool(road.get("walkable", true)) \
				or bool(road.get("through_building", false)):
			continue
		var oneway := int(road.get("oneway", 0))
		var pts := WorldBuilder.footprint_xz(road.points)
		if pts.size() < 2:
			continue
		var normals := _vertex_normals(pts)
		var off_fwd := lane_offset(kind, w, false)
		var off_back := lane_offset(kind, w, true)
		var speed: float = ROAD_SPEEDS[kind]
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var seg := a.distance_to(b)
			if seg < 0.3:
				continue
			var mid := (a + b) * 0.5
			if absf(a.x) > half - ZONE_MARGIN or absf(a.y) > half - ZONE_MARGIN \
					or absf(b.x) > half - ZONE_MARGIN or absf(b.y) > half - ZONE_MARGIN:
				continue
			if layout.near_track(a, TRAM_CLEARANCE) or layout.near_track(b, TRAM_CLEARANCE) or layout.near_track(mid, TRAM_CLEARANCE):
				continue
			if _in_building(layout, a, b):  # OSM has roads through malls and stadiums
				continue
			var ka := Vector2i(roundi(a.x * 10.0), roundi(a.y * 10.0))
			var kb := Vector2i(roundi(b.x * 10.0), roundi(b.y * 10.0))
			if ka == kb or pair.has(Vector4i(ka.x, ka.y, kb.x, kb.y)) or pair.has(Vector4i(kb.x, kb.y, ka.x, ka.y)):
				continue
			var na := _node(node_of, node_pos, out_edges, ka, a)
			var nb := _node(node_of, node_pos, out_edges, kb, b)
			pair[Vector4i(ka.x, ka.y, kb.x, kb.y)] = true
			var fa := a + normals[i] * off_fwd
			var fb := b + normals[i + 1] * off_fwd
			if oneway >= 0 and not _in_building(layout, fa, fb, LANE_CLEARANCE):
				_edge(out_edges, e_from, e_to, e_p0, e_p1, e_speed, e_len, na, nb, fa, fb, speed, seg)
			var ba := b - normals[i + 1] * off_back
			var bb := a - normals[i] * off_back
			if oneway <= 0 and not _in_building(layout, ba, bb, LANE_CLEARANCE):
				_edge(out_edges, e_from, e_to, e_p0, e_p1, e_speed, e_len, nb, na, ba, bb, speed, seg)
	stats.edges = e_from.size()
	# Closed trails: every directed lane is used by exactly one.
	var used := PackedByteArray()
	used.resize(e_from.size())
	var trails: Array = []
	for e0 in e_from.size():
		if used[e0] != 0:
			continue
		used[e0] = 1
		var trail := [e0]
		var start := e_from[e0]
		var node := e_to[e0]
		var incoming := e0
		var ok := true
		var metres := float(e_len[e0])
		while node != start:
			var pick := _next_edge(node, incoming, used, out_edges, e_from, e_to, node_pos, e0, trail.size(),
				start if metres >= LOOP_CLOSE else -1)
			if pick < 0:
				ok = false
				break
			used[pick] = 1
			trail.append(pick)
			metres += e_len[pick]
			incoming = pick
			node = e_to[pick]
		if ok:
			trails.append(trail)
	stats.trails = trails.size()
	# Lane loops.
	var grid := {}
	for trail in trails:
		var raw := PackedVector2Array()
		var lims := PackedFloat32Array()
		var total := 0.0
		for j in trail.size():
			var e: int = trail[j]
			var nxt: int = trail[(j + 1) % trail.size()]
			total += e_len[e]
			if raw.is_empty() or raw[raw.size() - 1].distance_to(e_p0[e]) > 0.05:
				raw.append(e_p0[e])
				lims.append(e_speed[e])
			raw.append(e_p1[e])
			lims.append(minf(e_speed[e], e_speed[nxt]))
		if raw.size() > 2 and raw[0].distance_to(raw[raw.size() - 1]) < 0.05:
			raw.remove_at(raw.size() - 1)
			lims.remove_at(lims.size() - 1)
		if total < MIN_ROUTE or raw.size() < 3:
			continue
		var route := TrafficRoute.new()
		route.index = routes.size()
		route.setup(raw, lims)
		routes.append(route)
		for k in route.pts.size():
			var c := Vector2i(floori(route.pts[k].x / GRID), floori(route.pts[k].y / GRID))
			if not grid.has(c):
				grid[c] = []
			grid[c].append(route.index * 100000 + k)
	# Pedestrian crossings on the lanes.
	var gate_lists := {}
	for ci in _crossings.size():
		var c := _crossings[ci]
		var per_route := {}
		var cc := Vector2i(floori(c.x / GRID), floori(c.y / GRID))
		for dx in range(-1, 2):
			for dy in range(-1, 2):
				var list: Array = grid.get(cc + Vector2i(dx, dy), [])
				for code: int in list:
					var r: int = code / 100000
					var k: int = code % 100000
					var d := (routes[r] as TrafficRoute).pts[k].distance_to(c)
					if d < GATE_RADIUS:
						if not per_route.has(r):
							per_route[r] = []
						per_route[r].append(Vector2(k, d))
		for r in per_route:
			var hits: Array = per_route[r]
			hits.sort_custom(func(p, q): return p.x < q.x)
			var best := Vector2(-1000, 99)
			var found := []
			for h in hits:
				if h.x - best.x > 25.0:
					if best.x >= 0.0:
						found.append(best)
					best = h
				elif h.y < best.y:
					best = h
			if best.x >= 0.0:
				found.append(best)
			if not gate_lists.has(r):
				gate_lists[r] = []
			for f in found:
				gate_lists[r].append([f.x * (routes[r] as TrafficRoute).step, _phases[ci], ci])
	stats.loops = routes.size()
	# Plan every loop and put platoons on it.
	var plan_t0 := Time.get_ticks_msec()
	var kept: Array = []
	for route: TrafficRoute in routes:
		route.set_gates(gate_lists.get(route.index, []))
		var template := _template(route)
		if route.plan(template.span):
			route.index = kept.size()
			kept.append(route)
			gates_total += route.gates.size()
			_populate(route, template)
	routes = kept
	stats.plan_ms = Time.get_ticks_msec() - plan_t0
	stats.dropped = stats.loops - kept.size()
	for route: TrafficRoute in routes:
		var last := Vector2i(1 << 30, 0)
		for p in route.pts:
			var c := Vector2i(floori(p.x / CELL), floori(p.y / CELL))
			if c == last:
				continue
			last = c
			if not _cells.has(c):
				_cells[c] = []
			if not (_cells[c] as Array).has(route.index):
				_cells[c].append(route.index)


## True if a solid building stands on or right beside the stretch a to b.
func _in_building(layout: StreetLayout, a: Vector2, b: Vector2, clearance := BUILDING_CLEARANCE) -> bool:
	var n := maxi(int(a.distance_to(b) / 3.0), 1)
	for k in n + 1:
		if layout.building_clearance(a.lerp(b, float(k) / n)) < clearance:
			return true
	return false


func _node(node_of: Dictionary, node_pos: PackedVector2Array, out_edges: Array, key: Vector2i, p: Vector2) -> int:
	if node_of.has(key):
		return node_of[key]
	var id := node_pos.size()
	node_of[key] = id
	node_pos.append(p)
	out_edges.append([])
	return id


func _edge(out_edges: Array, e_from: PackedInt32Array, e_to: PackedInt32Array, e_p0: PackedVector2Array,
		e_p1: PackedVector2Array, e_speed: PackedFloat32Array, e_len: PackedFloat32Array,
		from: int, to: int, p0: Vector2, p1: Vector2, speed: float, seg: float) -> void:
	(out_edges[from] as Array).append(e_from.size())
	e_from.append(from)
	e_to.append(to)
	e_p0.append(p0)
	e_p1.append(p1)
	e_speed.append(speed)
	e_len.append(seg)


## The next lane of a trail: mostly straight on, sometimes a turn, never a
## U-turn unless it is the only way out.
func _next_edge(node: int, incoming: int, used: PackedByteArray, out_edges: Array, e_from: PackedInt32Array,
		e_to: PackedInt32Array, node_pos: PackedVector2Array, salt: int, step: int, close_at: int) -> int:
	var options: Array = []
	var turnback := -1
	var here := node_pos[node] - node_pos[e_from[incoming]]
	for e in out_edges[node]:
		if used[e] != 0:
			continue
		if e_to[e] == e_from[incoming]:
			turnback = e
			continue
		options.append(e)
	if options.is_empty():
		return turnback
	if close_at >= 0:
		for e: int in options:
			if e_to[e] == close_at:
				return e
	if options.size() == 1:
		return options[0]
	var roll := h01("%s:turn:%d:%d" % [zone_id, salt, step])
	var best: int = options[0]
	var best_key := -INF
	for e: int in options:
		var there := node_pos[e_to[e]] - node_pos[node]
		var angle := here.angle_to(there)  # positive is a right turn in XZ
		var key := -absf(angle) if roll < 0.55 else (angle if roll < 0.85 else -angle)
		if key > best_key:
			best_key = key
			best = e
	return best


## Platoon composition of a loop: vehicle kinds, their bumper offsets and the
## platoon length.
func _template(route: TrafficRoute) -> Dictionary:
	var major := route.major_share()
	var kinds := []
	var count := 2 + int(h01("%s:n:%d" % [zone_id, route.index]) * (3.0 if major > 0.5 else 2.0))
	for i in count:
		var r := h01("%s:k:%d:%d" % [zone_id, route.index, i])
		var bus_p := 0.14 if major > 0.5 else 0.02
		var mini_p := 0.12 if major > 0.5 else 0.08
		var kind := CAR
		if r < bus_p and i == 0:
			kind = BUS
		elif r < bus_p + mini_p:
			kind = MINIBUS
		elif r < bus_p + mini_p + 0.2:
			kind = TAXI
		kinds.append(kind)
		if kind == BUS and count > 2:
			count = 2
	kinds.resize(mini(kinds.size(), count))
	var leads := []
	var at := 0.0
	for k in kinds:
		if not leads.is_empty() and at + float(LENGTHS[k]) > MAX_SPAN:
			break
		leads.append(at)
		at += float(LENGTHS[k]) + PLATOON_GAP
	kinds.resize(leads.size())
	return {"kinds": kinds, "leads": leads, "span": at - PLATOON_GAP}


func _populate(route: TrafficRoute, template: Dictionary) -> void:
	for slot in route.slots:
		var kinds: Array = template.kinds
		for i in kinds.size():
			var key := "%s:v:%d:%d:%d" % [zone_id, route.index, slot, i]
			var v := Vehicle.new()
			v.id = vehicles.size()
			v.route = route
			v.slot = slot
			v.member = i
			v.kind = kinds[i]
			v.length = LENGTHS[v.kind]
			v.width = WIDTHS[v.kind]
			v.height = HEIGHTS[v.kind]
			v.lead = template.leads[i]
			v.colour = int(h01(key + "c") * PALETTE.size())
			v.thr = h01(key + "d")
			vehicles.append(v)
			route.vehicles.append(v)


# --- queries -----------------------------------------------------------------------

## Puts the vehicle where it is at world time t (seconds).
func place(v: Vehicle, t: float) -> void:
	var r := v.route
	var u := t - v.slot * TrafficRoute.CYCLE
	var s := r.front(u) - v.lead - v.length * 0.5
	v.arc = s
	v.pos = r.point_at(s)
	v.dir = r.dir_at(s)
	var m := r.motion(u)
	v.speed = m.x
	v.accel = m.y
	v.tick = -1000000


## Routes with lane within `radius` of p (Godot XZ).
func routes_near(p: Vector2, radius: float) -> Array:
	var out := []
	var c0 := Vector2i(floori((p.x - radius) / CELL), floori((p.y - radius) / CELL))
	var c1 := Vector2i(floori((p.x + radius) / CELL), floori((p.y + radius) / CELL))
	for x in range(c0.x, c1.x + 1):
		for y in range(c0.y, c1.y + 1):
			for r in _cells.get(Vector2i(x, y), []):
				if not out.has(r):
					out.append(r)
	return out


## The vehicles on the road within `radius` of p at world time t, placed at t.
## The result is only good until the next call that places vehicles.
func vehicles_near(t: float, p: Vector2, radius: float) -> Array:
	var dens := density(hours_at(t))
	var out := []
	var r2 := radius * radius
	for ri in routes_near(p, radius + 12.0):
		var route: TrafficRoute = routes[ri]
		for v: Vehicle in route.vehicles:
			if v.thr >= dens:
				continue
			place(v, t)
			if v.pos.distance_squared_to(p) <= r2:
				out.append(v)
	return out


## True if vehicle v is on the road at world time t.
func is_active(v: Vehicle, t: float) -> bool:
	return v.thr < density(hours_at(t))


func _candidates(p: Vector2, bucket: int) -> Array:
	var cell := Vector2i(floori(p.x / 16.0), floori(p.y / 16.0))
	var key := Vector3i(cell.x, cell.y, bucket)
	if _coarse.has(key):
		return _coarse[key]
	if _coarse.size() > 300:
		for k: Vector3i in _coarse.keys():
			if absi(k.z - bucket) > 1:
				_coarse.erase(k)
		if _coarse.size() > 300:
			_coarse.clear()
	var centre := (Vector2(cell) + Vector2(0.5, 0.5)) * 16.0
	var t := (bucket * COARSE_TICKS + COARSE_TICKS * 0.5) * Protocol.DT
	var dens := density(hours_at(t))
	var list := []
	var r2 := COARSE_RADIUS * COARSE_RADIUS
	for ri in routes_near(centre, COARSE_RADIUS + 8.0):
		var route: TrafficRoute = routes[ri]
		for v: Vehicle in route.vehicles:
			if v.thr >= dens:
				continue
			var s := route.front(t - v.slot * TrafficRoute.CYCLE) - v.lead - v.length * 0.5
			if route.point_at(s).distance_squared_to(centre) <= r2:
				list.append(v)
	_coarse[key] = list
	return list


## Collision boxes of the vehicles within `radius` of p (Godot XZ) at a world
## tick: [centre XZ, travel direction XZ (unit), half length, half width,
## speed, ground height]. Candidates are looked up per half second and area,
## so the server and a predicting client pay for the few cars around a
## player only.
func boxes_near(tick: int, p: Vector2, radius: float) -> Array:
	var out := []
	if routes.is_empty():
		return out
	var t := tick * Protocol.DT
	for v: Vehicle in _candidates(p, floori(float(tick) / COARSE_TICKS)):
		if v.tick != tick:
			place(v, t)
			v.tick = tick
		var reach := radius + v.length * 0.5
		if v.pos.distance_squared_to(p) > reach * reach:
			continue
		out.append([v.pos, v.dir, v.length * 0.5, v.width * 0.5, v.speed, terrain.height(v.pos.x, v.pos.y)])
	return out
