class_name Crowd
extends RefCounted
## Ambient pedestrians, always labelled as NPCs (the plan: never pass a
## machine off as a person). Each one walks an out-and-back route along
## the pavements, stopping at a shop window now and then, as a pure function
## of server time, like the trams: every client sees the same people in the
## same places and nothing is sent over the network. They cannot be talked
## to and do not collide with anyone.

const MAX := 90
const WALK_MIN := 1.05
const WALK_MAX := 1.5


class Walker:
	extends RefCounted
	var path := PackedVector2Array()  # EN points, out and back, on the pavement
	var cum := PackedFloat64Array()
	var leg_t := PackedFloat64Array()  # start time of each leg
	var legs: Array = []  # [kind (0 walk, 1 pause), s0, s1]
	var cycle := 1.0
	var phase := 0.0
	var speed := 1.3
	var looks := PackedInt32Array()  # top, bottom, skin, hair
	var size := 1.0

	## [position EN, heading EN (unit), walking?] at server time t.
	func pose(t: float) -> Array:
		var tau := fposmod(t + phase, cycle)
		var li := clampi(leg_t.bsearch(tau, false) - 1, 0, legs.size() - 1)
		var leg: Array = legs[li]
		var s: float = leg[1]
		var walking: bool = leg[0] == 0
		if walking:
			var dur := (float(leg[2]) - float(leg[1])) / speed
			s = lerpf(float(leg[1]), float(leg[2]), clampf((tau - leg_t[li]) / maxf(dur, 0.001), 0.0, 1.0))
		var i := clampi(cum.bsearch(s, true) - 1, 0, path.size() - 2)
		var seg := cum[i + 1] - cum[i]
		var p := path[i].lerp(path[i + 1], (s - cum[i]) / seg if seg > 0.0 else 0.0)
		var h := (path[i + 1] - path[i]).normalized()
		return [p, h if h != Vector2.ZERO else Vector2.UP, walking]


var walkers: Array = []


static func for_zone(z: ZoneData) -> Crowd:
	if z.has_meta("crowd"):
		return z.get_meta("crowd")
	var crowd := Crowd.new(z)
	z.set_meta("crowd", crowd)
	return crowd


## How busy the streets are at a local hour (0-24): Kadıköy is quiet before
## dawn and lively into the night.
static func density(hours: float) -> float:
	var h := fposmod(hours, 24.0)
	if h < 5.5:
		return 0.25
	if h < 8.0:
		return lerpf(0.3, 0.8, (h - 5.5) / 2.5)
	if h < 23.0:
		return 1.0
	return 0.6


func _init(zone: ZoneData) -> void:
	var graph := zone.road_graph()
	if graph.nodes.size() < 2:
		return
	var streets := StreetLayout.for_zone(zone)
	var rng := RandomNumberGenerator.new()
	for i in MAX:
		rng.seed = hash("%s:crowd:%d" % [zone.zone_id, i])
		var w := _walker(graph, streets, rng)
		if w != null:
			walkers.append(w)


func _walker(graph: RoadGraph, streets: StreetLayout, rng: RandomNumberGenerator) -> Walker:
	# A random stroll from a random corner, then back the same way (on the
	# other pavement, since people keep to their right).
	var cur := rng.randi() % graph.nodes.size()
	var prev := -1
	var seq := PackedInt32Array([cur])
	var length := 0.0
	var target := rng.randf_range(140.0, 420.0)
	for step in 60:
		if length >= target:
			break
		var options: Array = graph.adj[cur].filter(func(nb): return int(nb[0]) != prev)
		if options.is_empty():
			break
		var nb: Array = options[rng.randi() % options.size()]
		prev = cur
		cur = int(nb[0])
		seq.append(cur)
		length += float(nb[1])
	if length < 40.0:
		return null
	var out := PackedVector2Array()
	for n in seq:
		out.append(graph.nodes[n])
	out = _densify(out, 5.0)
	var back := out.duplicate()
	back.reverse()
	var w := Walker.new()
	w.path = _pavement(out, streets)
	var home := _pavement(back, streets)
	w.path.append_array(home)
	w.path.append(w.path[0])  # cross back over to where the walk began
	w.cum.append(0.0)
	for k in w.path.size() - 1:
		w.cum.append(w.cum[k] + w.path[k].distance_to(w.path[k + 1]))
	w.speed = rng.randf_range(WALK_MIN, WALK_MAX)
	w.size = rng.randf_range(0.9, 1.08)
	w.looks = PackedInt32Array([rng.randi() % 8, rng.randi() % 6, rng.randi() % 4, rng.randi() % 4])
	# Walk vertex to vertex, sometimes stopping for a few seconds.
	var t := 0.0
	for k in w.path.size() - 1:
		if rng.randf() < 0.035:  # about once every 150 m
			w.leg_t.append(t)
			w.legs.append([1, w.cum[k], w.cum[k]])
			t += rng.randf_range(2.0, 7.0)
		w.leg_t.append(t)
		w.legs.append([0, w.cum[k], w.cum[k + 1]])
		t += (w.cum[k + 1] - w.cum[k]) / w.speed
	w.cycle = maxf(t, 1.0)
	w.phase = rng.randf() * w.cycle
	return w


static func _densify(line: PackedVector2Array, step: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in line.size() - 1:
		var n := maxi(1, ceili(line[i].distance_to(line[i + 1]) / step))
		for k in n:
			out.append(line[i].lerp(line[i + 1], float(k) / n))
	out.append(line[line.size() - 1])
	return out


## A walking line moved off the carriageway onto the pavement on the
## right-hand side (by the kerb on car streets, off-centre on footways),
## pulled in wherever a wall is close.
static func _pavement(line: PackedVector2Array, streets: StreetLayout) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := line.size()
	for i in n:
		var d_in := (line[i] - line[i - 1]).normalized() if i > 0 else Vector2.ZERO
		var d_out := (line[i + 1] - line[i]).normalized() if i < n - 1 else Vector2.ZERO
		var d := (d_in + d_out).normalized() if (d_in + d_out).length() > 0.1 else (d_out if d_out != Vector2.ZERO else d_in)
		var right := Vector2(d.y, -d.x)  # EN: right of travel
		var xz := Vector2(line[i].x, -line[i].y)
		var width := 0.0
		var foot := true
		for seg in streets.roads_near(xz):
			if xz.distance_to(Geometry2D.get_closest_point_to_segment(xz, seg[0], seg[1])) < 1.0:
				width = maxf(width, float(seg[2]))
				foot = foot and str(seg[3]) in ["footway", "steps", "pedestrian", "living_street"]
		var off := minf(width / 2.0 - 0.8, 1.4) if foot else width / 2.0 + 1.3
		off = maxf(off, 0.0)
		var p := line[i] + right * off
		# Keep clear of walls: step back towards the street centre if needed.
		for k in 6:
			if streets.building_clearance(Vector2(p.x, -p.y)) > 0.5 or off <= 0.1:
				break
			off *= 0.6
			p = line[i] + right * off
		out.append(p)
	return out
