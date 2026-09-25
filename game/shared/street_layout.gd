class_name StreetLayout
extends RefCounted
## Where everything on the street stands: lamps, parked cars, benches,
## bollards and tram platforms. Placement is a deterministic function of the
## zone package, so the server's colliders (WorldBuilder) and the client's
## visuals (CityVisuals) always agree. Geometry is in Godot XZ (x east,
## z south); built once per ZoneData and shared.

const CELL := 16.0
const ASPHALT_KINDS := ["primary", "secondary", "tertiary", "unclassified", "residential", "service", "busway"]
const COBBLE_KINDS := ["pedestrian", "living_street"]
const PARKING_KINDS := ["residential", "tertiary", "secondary", "unclassified"]
const PLATFORM_HEIGHT := 0.25
const CAR_SIZE := Vector3(1.78, 1.45, 4.2)
const CAR_COLOURS := ["f2f2f0", "f2f2f0", "d9dcdf", "b8bcc0", "2b2d30", "8e9499", "7a1f1f", "1f3b66", "c4b59a", "3d4a3a"]
const TAXI := "f2c200"
const BENCH_SIZE := Vector3(1.8, 0.45, 0.55)
const BOLLARD_HEIGHT := 0.8

## The zone this layout belongs to. Held weakly: the zone keeps its layout
## in a meta entry, and a strong reference back would never be freed.
var zone: ZoneData:
	get:
		return _zone_ref.get_ref() as ZoneData
var _zone_ref: WeakRef
var half := 256.0
var road_cells := {}  # Vector2i -> Array of [a: Vector2, b: Vector2, width, kind]
var building_cells := {}  # Vector2i -> Array of PackedVector2Array
var junctions := {}  # Vector2i (0.1 m key) -> exclusion radius
var junction_cells := {}  # Vector2i cell -> Array of [point, radius]
var tracks: Array = []  # PackedVector2Array track centre lines (XZ)

## Results, each an Array of Dictionaries.
var lamps: Array = []  # {base: Vector3, head: Vector3, yaw}
var cars: Array = []  # {pos: Vector3, basis: Basis (tilted with the slope), yaw, color: Color, taxi: bool}
var benches: Array = []  # {pos: Vector3, yaw}
var bollards: Array = []  # Vector3
var stops: Array = []  # {xf: Transform3D, name, color, long, room, track_gap, serves, slab: [centre, size] or []}


static func for_zone(z: ZoneData) -> StreetLayout:
	if z.has_meta("street_layout"):
		return z.get_meta("street_layout")
	var layout := StreetLayout.new(z)
	z.set_meta("street_layout", layout)
	return layout


func _init(z: ZoneData) -> void:
	_zone_ref = weakref(z)
	half = z.half_size()
	_index()
	_place_stops()
	_place_lamps()
	_place_cars()
	_place_bollards()
	_place_benches()


# --- lookups ---------------------------------------------------------------------------

func _index() -> void:
	var seen := {}
	for road in zone.roads:
		var pts := WorldBuilder.footprint_xz(road.points)
		var w := float(road.width)
		for i in pts.size() - 1:
			_bucket(road_cells, pts[i], pts[i + 1], [pts[i], pts[i + 1], w, str(road.kind)])
		if not ASPHALT_KINDS.has(road.kind) and not COBBLE_KINDS.has(road.kind):
			continue
		for p in pts:
			var k := Vector2i(roundi(p.x * 10), roundi(p.y * 10))
			if not seen.has(k):
				seen[k] = {}
			seen[k][str(road.id)] = maxf(float(seen[k].get(str(road.id), 0.0)), w)
	for k in seen:
		if seen[k].size() >= 2:
			var widest := 0.0
			for w in seen[k].values():
				widest = maxf(widest, w)
			junctions[k] = widest / 2.0 + 1.5
			var jp := Vector2(k.x / 10.0, k.y / 10.0)
			var jc := Vector2i(floori(jp.x / CELL), floori(jp.y / CELL))
			for dx in range(-1, 2):
				for dy in range(-1, 2):
					var c := jc + Vector2i(dx, dy)
					if not junction_cells.has(c):
						junction_cells[c] = []
					junction_cells[c].append([jp, widest / 2.0 + 1.5])
	for b in zone.buildings:
		if float(b.min_height) > 2.2:
			continue
		var poly := WorldBuilder.footprint_xz(b.footprint)
		var box := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			box = box.expand(p)
		for x in range(floori(box.position.x / CELL), floori(box.end.x / CELL) + 1):
			for y in range(floori(box.position.y / CELL), floori(box.end.y / CELL) + 1):
				var c := Vector2i(x, y)
				if not building_cells.has(c):
					building_cells[c] = []
				building_cells[c].append(poly)
	for line: TransitNetwork.TransitLine in zone.transit.lines:
		var polys: Array = [line.path] if line.loop else [line.right_track, line.left_track]
		for poly in polys:
			tracks.append(WorldBuilder.footprint_xz(Array(poly).map(func(p): return [p.x, p.y])))


func _bucket(cells: Dictionary, a: Vector2, b: Vector2, item: Array) -> void:
	var box := Rect2(a, Vector2.ZERO).expand(b).grow(item[2] / 2.0 + 2.0)
	for x in range(floori(box.position.x / CELL), floori(box.end.x / CELL) + 1):
		for y in range(floori(box.position.y / CELL), floori(box.end.y / CELL) + 1):
			var c := Vector2i(x, y)
			if not cells.has(c):
				cells[c] = []
			cells[c].append(item)


func roads_near(p: Vector2) -> Array:
	return road_cells.get(Vector2i(floori(p.x / CELL), floori(p.y / CELL)), [])


## Distance to the nearest building wall; negative inside a building.
func building_clearance(p: Vector2) -> float:
	var best := INF
	for poly in building_cells.get(Vector2i(floori(p.x / CELL), floori(p.y / CELL)), []):
		var inside := Geometry2D.is_point_in_polygon(p, poly)
		for i in poly.size():
			var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
			var d := p.distance_to(q)
			best = minf(best, -d if inside else d)
	return best


func near_junction(p: Vector2, extra := 0.0) -> bool:
	for j in junction_cells.get(Vector2i(floori(p.x / CELL), floori(p.y / CELL)), []):
		if p.distance_to(j[0]) < float(j[1]) + extra:
			return true
	return false


func near_track(p: Vector2, radius: float) -> bool:
	for poly in tracks:
		for i in poly.size() - 1:
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p, poly[i], poly[i + 1])) < radius:
				return true
	return false


func inside_zone(p: Vector2, margin := 0.0) -> bool:
	return absf(p.x) < half - margin and absf(p.y) < half - margin


func near_crossing(p: Vector2, radius: float) -> bool:
	for c in zone.crossings:
		if p.distance_to(Vector2(float(c[0]), -float(c[1]))) < radius:
			return true
	return false


## True where something solid already stands (so props do not overlap).
func _occupied(p: Vector2, radius: float) -> bool:
	for list in [cars, benches]:
		for item in list:
			var q: Vector3 = item.pos
			if p.distance_to(Vector2(q.x, q.z)) < radius + 1.5:
				return true
	for l in lamps:
		var b: Vector3 = l.base
		if p.distance_to(Vector2(b.x, b.z)) < radius + 0.3:
			return true
	return false


# --- tram stops ---------------------------------------------------------------------

## Platforms and shelters: one per (stop, direction) spot, merged when two
## lines share a kerb. The raised slab runs from just clear of the tram to a
## little behind where people wait.
func _place_stops() -> void:
	var groups := {}
	for line: TransitNetwork.TransitLine in zone.transit.lines:
		for i in line.stops.size():
			if not line.stops[i].in_zone:
				continue
			for dir in ([1] if line.loop else [1, -1]):
				var p := line.platform(i, dir)
				var key := Vector2i(roundi(p.x / 3.0), roundi(p.y / 3.0))
				if not groups.has(key):
					var plat: float = line.stops[i].plat_r if dir > 0 else line.stops[i].plat_l
					groups[key] = {"pos": p, "tangent": line.tangent_at(float(line.stops[i].s)) * dir,
						"name": line.stops[i].name, "room": line.platform_room(i, dir) - plat,
						"track_gap": plat - line.track_offset,
						"long": line.vehicle_type != "nostalgic", "serves": [], "color": line.color}
				groups[key].serves.append([line.index, i, dir])
	var terrain := zone.terrain
	for g in groups.values():
		var en: Vector2 = g.pos
		var t: Vector2 = g.tangent
		var length := 26.0 if g.long else 13.0
		# Local frame: -Z along travel, +X away from the track, pitched with
		# the street so the platform follows the slope like the rails do.
		var rise := terrain.height_en(en + t * length / 2.0) - terrain.height_en(en - t * length / 2.0)
		var xf := Transform3D(Basis.looking_at(Vector3(t.x, rise / length, -t.y), Vector3.UP),
			Vector3(en.x, terrain.height_en(en), -en.y))
		var inner := -(float(g.track_gap) - TransitNetwork.CAR_HALF_WIDTH - 0.1)
		var outer := minf(0.6, float(g.room) - 0.2)
		g.xf = xf
		g.length = length
		g.slab = [Vector3((inner + outer) / 2.0, PLATFORM_HEIGHT / 2.0, 0.0), Vector3(outer - inner, PLATFORM_HEIGHT, length)] \
			if outer - inner >= 0.6 else []
		g.shelter = float(g.room) >= 1.4
		stops.append(g)


# --- lamps -----------------------------------------------------------------------------

## Street lamps along streets, kept off tracks, junctions and walls.
func _place_lamps() -> void:
	for road in zone.roads:
		var kind := str(road.kind)
		var w := float(road.width)
		if not (ASPHALT_KINDS.has(kind) or COBBLE_KINDS.has(kind)) or w < 4.0 or kind == "service":
			continue
		var pts := WorldBuilder.footprint_xz(road.points)
		var along := 12.0
		var walked := 0.0
		var side := 1.0 if WorldBuilder._hash01(str(road.id)) < 0.5 else -1.0
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var seg := a.distance_to(b)
			while along <= walked + seg:
				var c := a.lerp(b, (along - walked) / seg)
				var d := (b - a) / seg
				var n := Vector2(-d.y, d.x) * side
				var p := c + n * (w / 2.0 + 0.6)
				along += 30.0 if ASPHALT_KINDS.has(kind) else 24.0
				side = -side
				if not inside_zone(p, 3.0) or near_junction(c, 3.0) or near_track(p, 3.2) \
						or building_clearance(p) < 0.4:
					continue
				var yaw := atan2(-n.x, -n.y)  # local +Z (the arm) points towards the street centre
				var ground := zone.terrain.height(p.x, p.y)
				lamps.append({"base": Vector3(p.x, ground, p.y), "yaw": yaw,
					"head": Vector3(p.x - n.x * 1.1, ground + 5.75, p.y - n.y * 1.1)})
			walked += seg


# --- parked cars -------------------------------------------------------------------------

## Cars parked along the kerb of ordinary streets, with gaps, never on tram
## streets, at junctions, crossings or stops. Some are yellow taxis.
func _place_cars() -> void:
	for road in zone.roads:
		var kind := str(road.kind)
		var w := float(road.width)
		if not PARKING_KINDS.has(kind) or w < 6.0:
			continue
		var pts := WorldBuilder.footprint_xz(road.points)
		var key := str(road.id)
		for side: float in [-1.0, 1.0]:
			if w < 9.0 and side > 0.0:
				continue  # narrow streets park on one side only
			var walked := 0.0
			var along := 6.0
			var slot := 0
			for i in pts.size() - 1:
				var a := pts[i]
				var b := pts[i + 1]
				var seg := a.distance_to(b)
				if seg < 0.01:
					continue
				var d := (b - a) / seg
				var n := Vector2(-d.y, d.x) * side
				while along <= walked + seg - 2.5:
					var c := a.lerp(b, (along - walked) / seg)
					along += 5.6
					slot += 1
					var h := WorldBuilder._hash01("%s:%d:%d" % [key, int(side), slot])
					if h < 0.35:
						continue  # an empty space
					var p := c + n * (w / 2.0 - 1.15)
					if not inside_zone(p, 6.0) or near_junction(c, 7.0) or near_track(p, 4.0) \
							or near_crossing(p, 6.0) or building_clearance(p) < 1.2 or _near_stop(p, 16.0):
						continue
					var yaw := atan2(-d.x, -d.y) + (PI if h > 0.8 else 0.0)
					var colour := Color(str(CAR_COLOURS[int(WorldBuilder._hash01(key + str(slot) + "c") * CAR_COLOURS.size())]))
					var taxi := WorldBuilder._hash01(key + str(slot) + "t") < 0.12
					var at := zone.terrain.on_ground(p)
					cars.append({"pos": at, "basis": zone.terrain.resting_basis(at, yaw), "yaw": yaw,
						"color": Color(TAXI) if taxi else colour, "taxi": taxi})
				walked += seg


func _near_stop(p: Vector2, radius: float) -> bool:
	for g in stops:
		var o: Vector3 = (g.xf as Transform3D).origin
		if p.distance_to(Vector2(o.x, o.z)) < radius:
			return true
	return false


# --- bollards and benches ---------------------------------------------------------------

## A row of bollards ("baba") where a pedestrian street meets a road, so no
## car drives in; gaps are wide enough to walk through.
func _place_bollards() -> void:
	for road in zone.roads:
		if str(road.kind) != "pedestrian":
			continue
		var pts := WorldBuilder.footprint_xz(road.points)
		var w := float(road.width)
		for end: int in [0, pts.size() - 1]:
			var p: Vector2 = pts[end]
			if not near_junction(p, 0.5) or not inside_zone(p, 4.0):
				continue
			var inward: Vector2 = (pts[1] - pts[0]).normalized() if end == 0 else (pts[end - 1] - pts[end]).normalized()
			var across := Vector2(-inward.y, inward.x)
			var base := p + inward * (w / 2.0 + 2.0)
			var count := maxi(2, int(w / 1.5))
			for k in count:
				var q := base + across * (-w / 2.0 + 0.5 + k * (w - 1.0) / maxf(1.0, count - 1))
				if building_clearance(q) > 0.5 and not near_track(q, 2.0):
					bollards.append(zone.terrain.on_ground(q))


## Benches along park and plaza edges, facing inwards.
func _place_benches() -> void:
	for area in zone.areas:
		if not str(area.kind) in ["park", "plaza", "grass", "playground"]:
			continue
		var poly := WorldBuilder.footprint_xz(area.polygon)
		if poly.size() < 3:
			continue
		var centre := Vector2.ZERO
		for p in poly:
			centre += p
		centre /= poly.size()
		var walked := 0.0
		var next := 8.0
		for i in poly.size():
			var a := poly[i]
			var b := poly[(i + 1) % poly.size()]
			var seg := a.distance_to(b)
			while next <= walked + seg:
				var c := a.lerp(b, (next - walked) / seg)
				next += 22.0
				var inward := (centre - c).normalized()
				var p := c + inward * 1.6
				if not Geometry2D.is_point_in_polygon(p, poly) or building_clearance(p) < 1.0 \
						or not inside_zone(p, 4.0) or _occupied(p, 1.0) or near_track(p, 3.0):
					continue
				benches.append({"pos": zone.terrain.on_ground(p), "yaw": atan2(-inward.x, -inward.y)})
			walked += seg
