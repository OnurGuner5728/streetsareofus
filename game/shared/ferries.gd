class_name Ferries
extends RefCounted
## Ferries (vapurlar) between the piers of the coast. Like the trams and the
## road traffic they are a pure function of the zone package and the world
## time: every client computes the same hull in the same place and nothing
## travels over the network.
##
## Each line is a shuttle between two berths. A berth is a spot of open water
## beside a ferry terminal; the sea route is found once on a coarse grid of
## the land mask (A*, then string pulling and corner rounding). A line whose
## far end lies outside the zone (the strait crossings to Eminönü and
## Beşiktaş) just sails over the horizon, waits there out of sight and comes
## back, so the timetable stays honest without modelling the far shore.
## A ship accelerates and brakes along a trapezoid speed profile, rests at
## each berth and keeps a little to the right of its track so two ships that
## meet pass each other starboard to starboard.

const SPEED := 6.2  # cruising speed, about 12 knots (m/s)
const ACCEL := 0.2
const DWELL := 60.0  # time at a berth (s)
const AWAY := 150.0  # time spent at the far end beyond the horizon (s)
const CELL := 16.0  # route grid
const HULL_LENGTH := 38.0
const HULL_BEAM := 9.0
const LATERAL := 6.0  # keep right of the track in open water
const LATERAL_FADE := 140.0  # ... but come back to the track this far from a berth
const SMOOTH := 9.0  # half window of the smoothed heading (m)
const BERTH_SHORE := 8.0  # a berth lies this far off the quay
const PIER_CLEAR := 11.0  # route cells within this of a pier are closed
const HORN_ARRIVE := 20.0  # warning blast this long before docking (s)
const HORN_LEAVE := 6.0  # departure blast this long before casting off (s)

## Terminals are matched by position (name spellings in the OSM data vary).
## `a`: Godot XZ near the berth terminal, `b`: Godot XZ of the other terminal
## or of a point over the horizon (`away`), `ships`: how many hulls share the line.
const LINES := [
	{"name": "Kadıköy - Eminönü", "a": Vector2(-165, -840), "b": Vector2(-300, -1500), "away": true, "ships": 2},
	{"name": "Kadıköy - Moda", "a": Vector2(-248, -702), "b": Vector2(58, 729), "away": false, "ships": 2},
	{"name": "Kadıköy - Beşiktaş", "a": Vector2(-341, -655), "b": Vector2(-700, -1500), "away": true, "ships": 1},
]

## One shuttle line. `path` runs from berth A to berth B (B is the horizon
## point of an `away` line).
class Line:
	extends RefCounted
	var index := 0
	var name := ""
	var path := PackedVector2Array()
	var cum := PackedFloat32Array()  # arc length at each path point
	var length := 0.0
	var away_b := false
	var leg_time := 0.0
	var dwell_a := 0.0
	var dwell_b := 0.0
	var period := 0.0
	var berth_a := Vector2.ZERO
	var berth_b := Vector2.ZERO
	var vpeak := SPEED

	func at(s: float) -> Vector2:
		s = clampf(s, 0.0, length)
		var i := _seg(s)
		var u := 0.0
		var span := cum[i + 1] - cum[i]
		if span > 0.0001:
			u = (s - cum[i]) / span
		return path[i].lerp(path[i + 1], u)

	## Heading at arc length `s`: the chord over a short window, so the ship
	## turns smoothly through the polyline's corners instead of snapping.
	func tangent(s: float) -> Vector2:
		s = clampf(s, 0.0, length)
		var d := at(minf(s + SMOOTH, length)) - at(maxf(s - SMOOTH, 0.0))
		if d.length_squared() < 0.0001:
			var i := _seg(s)
			return (path[i + 1] - path[i]).normalized()
		return d.normalized()

	func _seg(s: float) -> int:
		var lo := 0
		var hi := cum.size() - 2
		while lo < hi:
			var mid := (lo + hi + 1) / 2
			if cum[mid] <= s:
				lo = mid
			else:
				hi = mid - 1
		return lo

	## Distance sailed `tau` seconds after casting off one berth (trapezoid profile).
	func sailed(tau: float) -> float:
		tau = clampf(tau, 0.0, leg_time)
		var t_ramp := vpeak / ACCEL
		var d_ramp := 0.5 * ACCEL * t_ramp * t_ramp
		if tau < t_ramp:
			return 0.5 * ACCEL * tau * tau
		if tau > leg_time - t_ramp:
			var rest := leg_time - tau
			return length - 0.5 * ACCEL * rest * rest
		return d_ramp + vpeak * (tau - t_ramp)

	func speed_at(tau: float) -> float:
		tau = clampf(tau, 0.0, leg_time)
		var t_ramp := vpeak / ACCEL
		if tau < t_ramp:
			return ACCEL * tau
		if tau > leg_time - t_ramp:
			return ACCEL * (leg_time - tau)
		return vpeak


## One ship. pos/dir/speed/phase describe it at the time of the last place().
class Ship:
	extends RefCounted
	var id := 0
	var line: Line
	var offset := 0.0
	var pos := Vector2.ZERO  # centre, Godot XZ
	var dir := Vector2.RIGHT  # heading, unit
	var speed := 0.0
	var phase := 0.0
	var arc := 0.0
	var docked := false
	var away := false  # over the horizon, nobody can see it
	var name_tag := ""

var lines: Array = []  # Line
var ships: Array = []  # Ship
var stats := {}
var _coast: Coast
var _half := 900.0
var _n := 0
var _solid := PackedByteArray()  # 1 where the route grid is closed (land, shore margin, piers)


static func for_zone(z: ZoneData) -> Ferries:
	return Ferries.new(z)


func _init(z: ZoneData) -> void:
	_coast = z.coast
	if _coast == null:
		return
	_half = z.half_size()
	_build_grid()
	var ship_id := 0
	for spec: Dictionary in LINES:
		var line := _build_line(spec, lines.size())
		if line == null:
			continue
		lines.append(line)
		var count := int(spec.ships)
		for k in count:
			var s := Ship.new()
			s.id = ship_id
			ship_id += 1
			s.line = line
			s.offset = (float(k) + Traffic.h01("ferry:%s:%d" % [z.zone_id, line.index]) * 0.3) * line.period / float(count)
			ships.append(s)
	stats = {"lines": lines.size(), "ships": ships.size()}


# --- timetable ------------------------------------------------------------------------------

## Fills `s` with the ship's state at world time `t` (seconds).
func place(s: Ship, t: float) -> void:
	var l := s.line
	var ph := fposmod(t + s.offset, l.period)
	s.phase = ph
	var fwd := l.leg_time + l.dwell_a
	if ph < l.dwell_a:
		s.arc = 0.0
		s.docked = true
		s.away = false
		s.speed = 0.0
		s.dir = l.tangent(0.0)
	elif ph < fwd:
		var tau := ph - l.dwell_a
		s.arc = l.sailed(tau)
		s.speed = l.speed_at(tau)
		s.dir = l.tangent(s.arc)
		s.docked = false
		s.away = false
	elif ph < fwd + l.dwell_b:
		s.arc = l.length
		s.docked = true
		s.away = l.away_b
		s.speed = 0.0
		s.dir = l.tangent(l.length)
	else:
		var tau := ph - fwd - l.dwell_b
		s.arc = l.length - l.sailed(tau)
		s.speed = l.speed_at(tau)
		s.dir = -l.tangent(s.arc)
		s.docked = false
		s.away = false
	var lateral := LATERAL * clampf(minf(s.arc, l.length - s.arc) / LATERAL_FADE, 0.0, 1.0)
	s.pos = l.at(s.arc) + Vector2(-s.dir.y, s.dir.x) * lateral


## Phases of a line's cycle at which a ship sounds its horn (docking warning
## and departure), for berths that are in the zone.
func horn_phases(l: Line) -> PackedFloat32Array:
	var out := PackedFloat32Array()
	var fwd := l.dwell_a + l.leg_time
	out.append(l.dwell_a - HORN_LEAVE)
	if not l.away_b:
		out.append(fwd - HORN_ARRIVE)
		out.append(fwd + l.dwell_b - HORN_LEAVE)
	out.append(l.period - HORN_ARRIVE)
	return out


## True if a horn phase lies in the time window (t0, t1] for ship `s`.
func horn_between(s: Ship, t0: float, t1: float) -> bool:
	var l := s.line
	var p0 := t0 + s.offset
	var p1 := t1 + s.offset
	for hp in horn_phases(l):
		var k := ceilf((p0 - hp) / l.period)
		if hp + k * l.period > p0 and hp + k * l.period <= p1:
			return true
	return false


## Ships that are on the water within `radius` of `p` at time `t`.
func ships_near(t: float, p: Vector2, radius: float) -> Array:
	var out := []
	for s: Ship in ships:
		place(s, t)
		if not s.away and s.pos.distance_to(p) <= radius:
			out.append(s)
	return out


# --- route building -------------------------------------------------------------------------

func _cell_pos(i: int, j: int) -> Vector2:
	return Vector2(-_half + (i + 0.5) * CELL, -_half + (j + 0.5) * CELL)


func _cell_of(p: Vector2) -> Vector2i:
	return Vector2i(clampi(int((p.x + _half) / CELL), 0, _n - 1), clampi(int((p.y + _half) / CELL), 0, _n - 1))


func _build_grid() -> void:
	_n = int(ceil(2.0 * _half / CELL))
	var raw := PackedByteArray()
	raw.resize(_n * _n)
	for j in _n:
		for i in _n:
			# Nine samples, so a thin breakwater between two cell centres still closes the cell.
			var c := _cell_pos(i, j)
			var hit := false
			for dj in range(-1, 2):
				for di in range(-1, 2):
					if _coast.is_land(c + Vector2(di, dj) * (CELL * 0.5)):
						hit = true
			if hit:
				raw[j * _n + i] = 1
	_solid.resize(_n * _n)
	for j in _n:
		for i in _n:
			var closed := false
			for dj in range(-1, 2):
				for di in range(-1, 2):
					if di != 0 and dj != 0:
						continue
					var ii := i + di
					var jj := j + dj
					if ii < 0 or jj < 0 or ii >= _n or jj >= _n or raw[jj * _n + ii] == 1:
						closed = true
			_solid[j * _n + i] = 1 if closed else 0
	for pier: Dictionary in _coast.piers:
		var pts: PackedVector2Array = pier.points
		var reach: float = PIER_CLEAR + (float(pier.get("width", 0.0)) * 0.5)
		for k in pts.size():
			var a := pts[k]
			var b := pts[(k + 1) % pts.size()]
			if k == pts.size() - 1 and not bool(pier.closed):
				break
			var c0 := _cell_of(Vector2(minf(a.x, b.x) - reach, minf(a.y, b.y) - reach))
			var c1 := _cell_of(Vector2(maxf(a.x, b.x) + reach, maxf(a.y, b.y) + reach))
			for j in range(c0.y, c1.y + 1):
				for i in range(c0.x, c1.x + 1):
					var cp := _cell_pos(i, j)
					if cp.distance_to(Geometry2D.get_closest_point_to_segment(cp, a, b)) < reach:
						_solid[j * _n + i] = 1


func _free_at(p: Vector2) -> bool:
	if absf(p.x) >= _half or absf(p.y) >= _half:
		return false
	var c := _cell_of(p)
	return _solid[c.y * _n + c.x] == 0


func _los(a: Vector2, b: Vector2) -> bool:
	var d := a.distance_to(b)
	var steps := maxi(1, int(d / 6.0))
	for k in range(1, steps + 1):
		if not _free_at(a.lerp(b, float(k) / steps)):
			return false
	return true


## Nearest open cell to `p` by a ring search, as a cell index.
func _nearest_free(p: Vector2, max_ring := 40, only := PackedByteArray()) -> Vector2i:
	var c := _cell_of(p)
	for r in range(0, max_ring):
		var best := Vector2i(-1, -1)
		var best_d := INF
		for j in range(c.y - r, c.y + r + 1):
			for i in range(c.x - r, c.x + r + 1):
				if maxi(absi(i - c.x), absi(j - c.y)) != r:
					continue
				if i < 0 or j < 0 or i >= _n or j >= _n or _solid[j * _n + i] == 1:
					continue
				if not only.is_empty() and only[j * _n + i] == 0:
					continue
				var d := _cell_pos(i, j).distance_squared_to(p)
				if d < best_d:
					best_d = d
					best = Vector2i(i, j)
		if best.x >= 0:
			return best
	return Vector2i(-1, -1)


## Distance from `p` to the nearest land along 16 rays (capped at `reach`), and
## the direction of the nearest hit.
func _shore_probe(p: Vector2, reach: float) -> Array:
	var best := reach
	var best_dir := Vector2.ZERO
	for k in 16:
		var d := Vector2.from_angle(TAU * k / 16.0)
		var r := 1.5
		while r < best:
			if _coast.is_land(p + d * r):
				best = r
				best_dir = d
				break
			r += 1.5
	return [best, best_dir]


func _near_pier(p: Vector2, margin: float) -> bool:
	for pier: Dictionary in _coast.piers:
		var pts: PackedVector2Array = pier.points
		var reach: float = margin + float(pier.get("width", 0.0)) * 0.5
		if bool(pier.closed) and Geometry2D.is_point_in_polygon(p, pts):
			return true
		for k in pts.size() - 1:
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[k], pts[k + 1])) < reach:
				return true
		if bool(pier.closed) and p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[pts.size() - 1], pts[0])) < reach:
			return true
	return false


## The spot of water nearest to terminal `t` that is just off the shore and
## clear of the piers, with the heading of a hull lying along the quay.
## Returns [berth, heading] or null.
func _find_berth(term: Vector2) -> Variant:
	var best: Variant = null
	var best_d := INF
	var step := 4.0
	var r := 0.0
	while r <= 90.0:
		var ring := maxi(1, int(TAU * r / step))
		for k in ring:
			var p := term + Vector2.from_angle(TAU * k / ring) * r
			if _coast.is_land(p) or _near_pier(p, 6.0):
				continue
			var probe := _shore_probe(p, 40.0)
			var gap: float = probe[0]
			if gap < BERTH_SHORE or gap > BERTH_SHORE + 6.0:
				continue
			var normal: Vector2 = probe[1]
			var along := Vector2(-normal.y, normal.x)
			if not _berth_clear(p, along):
				continue
			var d := p.distance_to(term)
			if d < best_d:
				best_d = d
				best = [p, along]
		if best != null:
			return best
		r += step
	return null


## The hull's footprint (both ends and the middle) must be clear of land and piers.
func _berth_clear(p: Vector2, along: Vector2) -> bool:
	for off in [-HULL_LENGTH * 0.5, -HULL_LENGTH * 0.25, 0.0, HULL_LENGTH * 0.25, HULL_LENGTH * 0.5]:
		var q: Vector2 = p + along * off
		if _coast.is_land(q) or _near_pier(q, 3.0):
			return false
		var side := Vector2(-along.y, along.x)
		if _coast.is_land(q + side * HULL_BEAM * 0.5) or _coast.is_land(q - side * HULL_BEAM * 0.5):
			return false
	return true


## The open-water entry of a berth: a point `lead` metres off along its heading,
## on whichever end is open water and nearer to `toward`.
func _entry(berth: Vector2, along: Vector2, toward: Vector2) -> Vector2:
	var best := berth
	var best_d := INF
	for sgn: float in [-1.0, 1.0]:
		var lead := 70.0
		var q := berth + along * sgn * lead
		while lead > 20.0 and _coast.is_land(q):
			lead -= 10.0
			q = berth + along * sgn * lead
		if _coast.is_land(q):
			continue
		var d := q.distance_to(toward)
		if d < best_d:
			best_d = d
			best = q
	return best


## 1 for every open cell connected to `start`.
func _flood(start: Vector2i) -> PackedByteArray:
	var seen := PackedByteArray()
	seen.resize(_n * _n)
	var stack := [start]
	seen[start.y * _n + start.x] = 1
	while not stack.is_empty():
		var c: Vector2i = stack.pop_back()
		for d in [Vector2i(1, 0), Vector2i(-1, 0), Vector2i(0, 1), Vector2i(0, -1)]:
			var q: Vector2i = c + d
			if q.x < 0 or q.y < 0 or q.x >= _n or q.y >= _n:
				continue
			var k := q.y * _n + q.x
			if seen[k] == 0 and _solid[k] == 0:
				seen[k] = 1
				stack.append(q)
	return seen


func _astar(from_p: Vector2, to_p: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var b := _nearest_free(to_p)
	if b.x < 0:
		return out
	# Only open water that connects to the destination can start the route
	# (a harbour pocket closed in by piers is not a start).
	var a := _nearest_free(from_p, 40, _flood(b))
	if a.x < 0:
		return out
	var grid := AStarGrid2D.new()
	grid.region = Rect2i(0, 0, _n, _n)
	grid.cell_size = Vector2.ONE
	grid.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	grid.default_compute_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.default_estimate_heuristic = AStarGrid2D.HEURISTIC_EUCLIDEAN
	grid.update()
	for j in _n:
		for i in _n:
			if _solid[j * _n + i] == 1:
				grid.set_point_solid(Vector2i(i, j), true)
	for id in grid.get_id_path(a, b):
		out.append(_cell_pos(id.x, id.y))
	return out


## String pulling: keep only the corners the line of sight needs.
func _pull(pts: PackedVector2Array) -> PackedVector2Array:
	if pts.size() < 3:
		return pts
	var out := PackedVector2Array([pts[0]])
	var i := 0
	while i < pts.size() - 1:
		var j := pts.size() - 1
		while j > i + 1 and not _los(pts[i], pts[j]):
			j -= 1
		out.append(pts[j])
		i = j
	return out


## Corner rounding (Chaikin) that keeps the end points; a corner is cut by a
## quarter of its legs, far less than the cell margin.
static func _round(pts: PackedVector2Array, passes: int) -> PackedVector2Array:
	for _p in passes:
		if pts.size() < 3:
			break
		var out := PackedVector2Array([pts[0]])
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			out.append(a.lerp(b, 0.25))
			out.append(a.lerp(b, 0.75))
		out.append(pts[pts.size() - 1])
		pts = out
	return pts


func _build_line(spec: Dictionary, index: int) -> Line:
	var ta: Variant = _terminal_near(spec.a)
	if ta == null:
		return null
	var ba: Variant = _find_berth(ta)
	if ba == null:
		return null
	var away: bool = spec.away
	var berth_a: Vector2 = ba[0]
	var along_a: Vector2 = ba[1]
	var target: Vector2 = spec.b
	var berth_b := target
	var along_b := Vector2.ZERO
	if not away:
		var tb: Variant = _terminal_near(spec.b)
		if tb == null:
			return null
		var bb: Variant = _find_berth(tb)
		if bb == null:
			return null
		berth_b = bb[0]
		along_b = bb[1]
	var entry_a := _entry(berth_a, along_a, target)
	var entry_b := Vector2.ZERO
	if away:
		entry_b = _exit_point(target)
	else:
		entry_b = _entry(berth_b, along_b, berth_a)
	var grid_path := _astar(entry_a, entry_b)
	if grid_path.size() < 2:
		return null
	var pts := PackedVector2Array([berth_a, entry_a])
	pts.append_array(_pull(grid_path))
	pts.append(entry_b)
	if away:
		pts.append(target)
	else:
		pts.append(berth_b)
	pts = _dedupe(pts)
	pts = _round(pts, 2)
	var line := Line.new()
	line.index = index
	line.name = str(spec.name)
	line.path = pts
	line.berth_a = berth_a
	line.berth_b = berth_b
	line.away_b = away
	line.cum.resize(pts.size())
	var acc := 0.0
	for i in pts.size():
		if i > 0:
			acc += pts[i].distance_to(pts[i - 1])
		line.cum[i] = acc
	line.length = acc
	line.vpeak = minf(SPEED, sqrt(ACCEL * line.length))
	var t_ramp := line.vpeak / ACCEL
	var d_ramp := 0.5 * ACCEL * t_ramp * t_ramp
	line.leg_time = 2.0 * t_ramp + maxf(0.0, line.length - 2.0 * d_ramp) / line.vpeak
	line.dwell_a = DWELL
	line.dwell_b = AWAY if away else DWELL
	line.period = 2.0 * line.leg_time + line.dwell_a + line.dwell_b
	return line


## The open-sea cell at the rim of the grid nearest to a far point; the line
## leaves the grid from there.
func _exit_point(far: Vector2) -> Vector2:
	var best := Vector2.ZERO
	var best_d := INF
	for j in _n:
		for i in _n:
			if minf(minf(i, j), minf(_n - 1 - i, _n - 1 - j)) > 3 or _solid[j * _n + i] == 1:
				continue
			var cp := _cell_pos(i, j)
			var d := cp.distance_to(far)
			if d < best_d:
				best_d = d
				best = cp
	return best


func _terminal_near(p: Vector2) -> Variant:
	var best: Variant = null
	var best_d := 120.0
	for f: Dictionary in _coast.ferry_terminals:
		var d := p.distance_to(f.pos)
		if d < best_d:
			best_d = d
			best = f.pos
	return best


static func _dedupe(pts: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in pts:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 1.0:
			out.append(p)
	return out
