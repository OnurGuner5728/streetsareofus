class_name WorldBuilder
extends RefCounted
## Builds a zone's collision (client and server) from zone data, and hands
## visuals to CityVisuals on clients. Collision is deliberately simpler than
## visuals: each building footprint becomes a few convex prisms.

const BOUNDARY_HEIGHT := 40.0
const TREE_SPACING := 8.0
const TREE_KINDS := ["park", "grass", "playground"]
## Jolt (Godot 4.7's default 3D physics) builds a compound shape as a chain
## of nested sub-shapes, so a single StaticBody3D with many thousands of
## children (a big, real zone easily has more than that in buildings alone)
## fails with "compound hierarchy is too deep". Shapes are spread over
## several bodies instead, well under that limit.
const COLLISION_CHUNK := 128
## Cell size of the grid that keeps trees off roads (see _road_grid).
const ROAD_CELL := 32.0


## A StaticBody3D that rolls over to a fresh one every COLLISION_CHUNK shapes.
class _CollisionSink:
	var _root: Node3D
	var body: StaticBody3D
	var _count := 0

	func _init(root: Node3D) -> void:
		_root = root
		_new_body()

	func _new_body() -> void:
		body = StaticBody3D.new()
		body.name = "Collision"
		body.collision_layer = Protocol.LAYER_WORLD
		body.collision_mask = 0
		_root.add_child(body)
		_count = 0

	## Registers a shape just added as `body`'s child; rolls the body over
	## once it is full.
	func added() -> void:
		_count += 1
		if _count >= COLLISION_CHUNK:
			_new_body()


static func build(zone: ZoneData, parent: Node3D, with_visuals: bool) -> Node3D:
	var root := Node3D.new()
	root.name = "World"
	parent.add_child(root)
	_build_collision(zone, root)
	if with_visuals:
		_build_visuals(zone, root)
	return root


# --- collision ---------------------------------------------------------------

static func _build_collision(zone: ZoneData, root: Node3D) -> void:
	var timings := {}
	root.set_meta("collision_timings", timings)
	var t0 := Time.get_ticks_usec()
	var sink := _CollisionSink.new(root)

	var s := zone.size_m
	var h := zone.half_size()
	var terrain := zone.terrain
	if terrain.flat:
		_add_box(sink, Vector3(0, -0.5, 0), Vector3(s + 200.0, 1.0, s + 200.0))
	else:
		# The real lie of the land: the same triangles Terrain.height() follows.
		var ground := ConcavePolygonShape3D.new()
		ground.set_faces(terrain.triangles_land(zone.coast) if zone.coast != null else terrain.triangles())
		ground.backface_collision = true
		var cs := CollisionShape3D.new()
		cs.name = "Ground"
		cs.shape = ground
		sink.body.add_child(cs)
		sink.added()
	# Zone edges are walls until zone handoff exists.
	var y := terrain.low - 5.0 + (BOUNDARY_HEIGHT + terrain.high - terrain.low) / 2.0
	var wall_h := BOUNDARY_HEIGHT + terrain.high - terrain.low + 5.0
	_add_box(sink, Vector3(h + 0.5, y, 0), Vector3(1.0, wall_h, s + 2.0))
	_add_box(sink, Vector3(-h - 0.5, y, 0), Vector3(1.0, wall_h, s + 2.0))
	_add_box(sink, Vector3(0, y, h + 0.5), Vector3(s + 2.0, wall_h, 1.0))
	_add_box(sink, Vector3(0, y, -h - 0.5), Vector3(s + 2.0, wall_h, 1.0))

	timings.ground = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	if zone.coast != null:
		_build_coast(zone, sink)
	timings.coast = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for b in zone.buildings:
		var poly := footprint_xz(b.footprint)
		# Floors are counted from the lowest ground under the building; on a
		# slope the walls carry on into the hillside below that.
		var ground_ref := terrain.ground_under(poly)
		var bottom := ground_ref + float(b.min_height) if float(b.min_height) > 0.1 else ground_ref - 1.0
		var top := ground_ref + float(b.height)
		var parts: Array = Geometry2D.decompose_polygon_in_convex(poly)
		if parts.is_empty():
			parts = [Geometry2D.convex_hull(poly)]
		for part in parts:
			var pts := PackedVector3Array()
			for p in part:
				pts.append(Vector3(p.x, bottom, p.y))
				pts.append(Vector3(p.x, top, p.y))
			var shape := ConvexPolygonShape3D.new()
			shape.points = pts
			var cs := CollisionShape3D.new()
			cs.shape = shape
			sink.body.add_child(cs)
			sink.added()

	timings.buildings = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for t in tree_points(zone):
		_add_cylinder(sink, t + Vector3(0, 1.5, 0), 0.3, 3.0)
	timings.trees = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()

	# Street furniture, placed identically on server and clients.
	var layout := StreetLayout.for_zone(zone)
	timings.layout = Time.get_ticks_usec() - t0
	t0 = Time.get_ticks_usec()
	for g in layout.stops:
		var xf: Transform3D = g.xf
		if not (g.slab as Array).is_empty():
			_add_box_xf(sink, xf * Transform3D(Basis(), g.slab[0]), g.slab[1])  # raised platform
		if g.shelter:
			_add_box_xf(sink, xf * Transform3D(Basis(), Vector3(1.1, 1.3, 0)), Vector3(0.12, 2.5, 3.5))  # shelter back
	for c in layout.cars:
		var car_basis: Basis = c.basis
		_add_box_xf(sink, Transform3D(car_basis, c.pos + car_basis.y * StreetLayout.CAR_SIZE.y / 2.0), StreetLayout.CAR_SIZE)
	for bench in layout.benches:
		var seat := StreetLayout.BENCH_SIZE
		_add_box_xf(sink, Transform3D(Basis(Vector3.UP, float(bench.yaw)), bench.pos + Vector3(0, seat.y / 2.0, 0)), seat)
	for p: Vector3 in layout.bollards:
		_add_cylinder(sink, p + Vector3(0, StreetLayout.BOLLARD_HEIGHT / 2.0, 0), 0.1, StreetLayout.BOLLARD_HEIGHT)
	for l in layout.lamps:
		_add_cylinder(sink, (l.base as Vector3) + Vector3(0, 3.0, 0), 0.09, 6.0)
	timings.furniture = Time.get_ticks_usec() - t0


## The sea for a zone with a real coastline: invisible walls along every
## shore run (a player cannot walk from land into the sea, whatever the
## ground mesh looks like), a flat sea bed far below so nothing falls
## through, and a walkable deck over every pier.
static func _build_coast(zone: ZoneData, sink: _CollisionSink) -> void:
	var coast := zone.coast
	var wall_bottom := coast.sea_level - 4.0
	var wall_top := coast.sea_level + coast.shore_height_m + BOUNDARY_HEIGHT
	for run in coast.shore:
		var pts: PackedVector2Array = run.points
		for i in pts.size() - 1:
			var a: Vector2 = pts[i]
			var b: Vector2 = pts[i + 1]
			var seg_len := a.distance_to(b)
			if seg_len < 0.05:
				continue
			var mid := (a + b) / 2.0
			var yaw := atan2(b.x - a.x, b.y - a.y)
			var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(mid.x, (wall_bottom + wall_top) / 2.0, mid.y))
			_add_box_xf(sink, xf, Vector3(0.6, wall_top - wall_bottom, seg_len))
	_add_box(sink, Vector3(0, coast.sea_level - 3.0, 0), Vector3(zone.size_m + 200.0, 1.0, zone.size_m + 200.0))
	var deck_y := coast.sea_level + coast.shore_height_m
	for pier in coast.piers:
		var pts: PackedVector2Array = pier.points
		if bool(pier.get("closed", false)):
			var parts: Array = Geometry2D.decompose_polygon_in_convex(pts)
			if parts.is_empty():
				parts = [Geometry2D.convex_hull(pts)]
			for part in parts:
				var poly3 := PackedVector3Array()
				for p in part:
					poly3.append(Vector3(p.x, deck_y - 1.0, p.y))
					poly3.append(Vector3(p.x, deck_y, p.y))
				var shape := ConvexPolygonShape3D.new()
				shape.points = poly3
				var cs := CollisionShape3D.new()
				cs.shape = shape
				sink.body.add_child(cs)
				sink.added()
		else:
			var width: float = float(pier.get("width", 3.0))
			for i in pts.size() - 1:
				var a: Vector2 = pts[i]
				var b: Vector2 = pts[i + 1]
				var seg_len := a.distance_to(b)
				if seg_len < 0.05:
					continue
				var mid := (a + b) / 2.0
				var yaw := atan2(b.x - a.x, b.y - a.y)
				var xf := Transform3D(Basis(Vector3.UP, yaw), Vector3(mid.x, deck_y - 0.5, mid.y))
				_add_box_xf(sink, xf, Vector3(width, 1.0, seg_len))


static func _add_box_xf(sink: _CollisionSink, xf: Transform3D, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = xf
	sink.body.add_child(cs)
	sink.added()


static func _add_cylinder(sink: _CollisionSink, center: Vector3, radius: float, height: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	sink.body.add_child(cs)
	sink.added()


static func _add_box(sink: _CollisionSink, center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	sink.body.add_child(cs)
	sink.added()


## Zone EN polygon -> Godot XZ polygon (Vector2(x, z)).
static func footprint_xz(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(Vector2(float(p[0]), -float(p[1])))
	return out


## Deterministic tree positions, shared so client visuals match server colliders:
## trees mapped in OSM plus planted rows in parks.
static func tree_points(zone: ZoneData) -> Array:
	if zone.has_meta("tree_points"):
		return zone.get_meta("tree_points")
	var out := []
	for t in zone.trees:
		out.append(zone.ground(float(t[0]), float(t[1])))
	for area in zone.areas:
		if not TREE_KINDS.has(area.kind):
			continue
		var poly := footprint_xz(area.polygon)
		var bounds := Rect2(poly[0], Vector2.ZERO)
		for p in poly:
			bounds = bounds.expand(p)
		var x := bounds.position.x + TREE_SPACING / 2.0
		while x < bounds.end.x:
			var z := bounds.position.y + TREE_SPACING / 2.0
			while z < bounds.end.y:
				var key := "%s:%d:%d" % [area.id, int(x), int(z)]
				var p := Vector2(x + (_hash01(key + "x") - 0.5) * 4.0, z + (_hash01(key + "z") - 0.5) * 4.0)
				if _hash01(key) < 0.75 and Geometry2D.is_point_in_polygon(p, poly) \
						and _edge_distance(p, poly) > 1.5 and not _on_road(zone, p):
					out.append(zone.terrain.on_ground(p))
				z += TREE_SPACING
			x += TREE_SPACING
	zone.set_meta("tree_points", out)
	return out


static func _edge_distance(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
		best = minf(best, p.distance_to(q))
	return best


static func _on_road(zone: ZoneData, p: Vector2) -> bool:
	var segments: Array = _road_grid(zone).get(Vector2i(floori(p.x / ROAD_CELL), floori(p.y / ROAD_CELL)), [])
	for s in segments:
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, s[0], s[1])) < float(s[2]):
			return true
	return false


## Road segments (with their tree clearance) bucketed into a coarse grid, so
## a tree candidate only tests the few segments near it instead of every
## road of the zone (which grows with the zone's area and its road count).
static func _road_grid(zone: ZoneData) -> Dictionary:
	if zone.has_meta("road_clearance_grid"):
		return zone.get_meta("road_clearance_grid")
	var grid := {}
	for road in zone.roads:
		var pts := footprint_xz(road.points)
		var clearance := float(road.width) / 2.0 + 1.2
		var reach := Vector2.ONE * (clearance + 0.01)
		for i in pts.size() - 1:
			var a := pts[i]
			var b := pts[i + 1]
			var lo := Vector2(minf(a.x, b.x), minf(a.y, b.y)) - reach
			var hi := Vector2(maxf(a.x, b.x), maxf(a.y, b.y)) + reach
			for cx in range(floori(lo.x / ROAD_CELL), floori(hi.x / ROAD_CELL) + 1):
				for cy in range(floori(lo.y / ROAD_CELL), floori(hi.y / ROAD_CELL) + 1):
					var key := Vector2i(cx, cy)
					if not grid.has(key):
						grid[key] = []
					grid[key].append([a, b, clearance])
	zone.set_meta("road_clearance_grid", grid)
	return grid


static func _hash01(key: String) -> float:
	return float(hash(key) & 0xFFFFFF) / float(0x1000000)


# --- visuals (client only) --------------------------------------------------------

static func _build_visuals(zone: ZoneData, root: Node3D) -> void:
	var vis := Node3D.new()
	vis.name = "Visuals"
	root.add_child(vis)
	root.set_meta("city", CityVisuals.build(zone, vis))


static func _add_flat_polygon(st: SurfaceTool, poly: PackedVector2Array, y: float, color: Color, normal := Vector3.UP) -> bool:
	var idx := Geometry2D.triangulate_polygon(poly)
	if idx.is_empty():
		return false
	for i in range(0, idx.size(), 3):
		var a := Vector3(poly[idx[i]].x, y, poly[idx[i]].y)
		var b := Vector3(poly[idx[i + 1]].x, y, poly[idx[i + 1]].y)
		var c := Vector3(poly[idx[i + 2]].x, y, poly[idx[i + 2]].y)
		_add_tri(st, a, b, c, normal, color)
	return true


## Adds a triangle facing `normal`. Godot's front faces wind clockwise, i.e.
## (b - a) x (c - a) points away from the viewer; swap b and c if needed.
static func _add_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, normal: Vector3, color: Color,
		uvs := PackedVector2Array(), info := Vector2.ZERO) -> void:
	var verts := [a, b, c]
	var tri_uvs := uvs
	if (b - a).cross(c - a).dot(normal) > 0.0:
		verts = [a, c, b]
		if uvs.size() == 3:
			tri_uvs = PackedVector2Array([uvs[0], uvs[2], uvs[1]])
	for i in 3:
		st.set_color(color)
		st.set_normal(normal)
		st.set_uv(tri_uvs[i] if tri_uvs.size() == 3 else Vector2.ZERO)
		st.set_uv2(info)
		st.add_vertex(verts[i])
