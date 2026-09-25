class_name WorldBuilder
extends RefCounted
## Builds a zone's collision (client and server) from zone data, and hands
## visuals to CityVisuals on clients. Collision is deliberately simpler than
## visuals: each building footprint becomes a few convex prisms.

const BOUNDARY_HEIGHT := 40.0
const TREE_SPACING := 8.0
const TREE_KINDS := ["park", "grass", "playground"]


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
	var body := StaticBody3D.new()
	body.name = "Collision"
	body.collision_layer = Protocol.LAYER_WORLD
	body.collision_mask = 0
	root.add_child(body)

	var s := zone.size_m
	var h := zone.half_size()
	_add_box(body, Vector3(0, -0.5, 0), Vector3(s + 200.0, 1.0, s + 200.0))
	# Zone edges are walls until zone handoff exists.
	var y := BOUNDARY_HEIGHT / 2.0
	_add_box(body, Vector3(h + 0.5, y, 0), Vector3(1.0, BOUNDARY_HEIGHT, s + 2.0))
	_add_box(body, Vector3(-h - 0.5, y, 0), Vector3(1.0, BOUNDARY_HEIGHT, s + 2.0))
	_add_box(body, Vector3(0, y, h + 0.5), Vector3(s + 2.0, BOUNDARY_HEIGHT, 1.0))
	_add_box(body, Vector3(0, y, -h - 0.5), Vector3(s + 2.0, BOUNDARY_HEIGHT, 1.0))

	for b in zone.buildings:
		var poly := footprint_xz(b.footprint)
		var bottom := float(b.min_height)
		var top := float(b.height)
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
			body.add_child(cs)

	for t in tree_points(zone):
		_add_cylinder(body, t + Vector3(0, 1.5, 0), 0.3, 3.0)

	# Street furniture, placed identically on server and clients.
	var layout := StreetLayout.for_zone(zone)
	for g in layout.stops:
		var xf: Transform3D = g.xf
		if not (g.slab as Array).is_empty():
			_add_box_xf(body, xf * Transform3D(Basis(), g.slab[0]), g.slab[1])  # raised platform
		if g.shelter:
			_add_box_xf(body, xf * Transform3D(Basis(), Vector3(1.1, 1.3, 0)), Vector3(0.12, 2.5, 3.5))  # shelter back
	for c in layout.cars:
		_add_box_xf(body, Transform3D(Basis(Vector3.UP, float(c.yaw)), c.pos + Vector3(0, StreetLayout.CAR_SIZE.y / 2.0, 0)), StreetLayout.CAR_SIZE)
	for bench in layout.benches:
		var seat := StreetLayout.BENCH_SIZE
		_add_box_xf(body, Transform3D(Basis(Vector3.UP, float(bench.yaw)), bench.pos + Vector3(0, seat.y / 2.0, 0)), seat)
	for p: Vector3 in layout.bollards:
		_add_cylinder(body, p + Vector3(0, StreetLayout.BOLLARD_HEIGHT / 2.0, 0), 0.1, StreetLayout.BOLLARD_HEIGHT)
	for l in layout.lamps:
		_add_cylinder(body, (l.base as Vector3) + Vector3(0, 3.0, 0), 0.09, 6.0)


static func _add_box_xf(body: StaticBody3D, xf: Transform3D, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.transform = xf
	body.add_child(cs)


static func _add_cylinder(body: StaticBody3D, center: Vector3, radius: float, height: float) -> void:
	var shape := CylinderShape3D.new()
	shape.radius = radius
	shape.height = height
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	body.add_child(cs)


static func _add_box(body: StaticBody3D, center: Vector3, size: Vector3) -> void:
	var shape := BoxShape3D.new()
	shape.size = size
	var cs := CollisionShape3D.new()
	cs.shape = shape
	cs.position = center
	body.add_child(cs)


## Zone EN polygon -> Godot XZ polygon (Vector2(x, z)).
static func footprint_xz(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(Vector2(float(p[0]), -float(p[1])))
	return out


## Deterministic tree positions, shared so client visuals match server colliders:
## trees mapped in OSM plus planted rows in parks.
static func tree_points(zone: ZoneData) -> Array:
	var out := []
	for t in zone.trees:
		out.append(Vector3(float(t[0]), 0.0, -float(t[1])))
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
					out.append(Vector3(p.x, 0.0, p.y))
				z += TREE_SPACING
			x += TREE_SPACING
	return out


static func _edge_distance(p: Vector2, poly: PackedVector2Array) -> float:
	var best := INF
	for i in poly.size():
		var q := Geometry2D.get_closest_point_to_segment(p, poly[i], poly[(i + 1) % poly.size()])
		best = minf(best, p.distance_to(q))
	return best


static func _on_road(zone: ZoneData, p: Vector2) -> bool:
	for road in zone.roads:
		var pts := footprint_xz(road.points)
		var clearance := float(road.width) / 2.0 + 1.2
		for i in pts.size() - 1:
			if p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])) < clearance:
				return true
	return false


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
