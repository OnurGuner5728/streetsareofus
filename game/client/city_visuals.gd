class_name CityVisuals
extends RefCounted
## Everything the city looks like (client only; the server only needs
## WorldBuilder's collision). Geometry is in Godot XZ (x east, z south).
## Repeated props use MultiMesh with visibility ranges so a phone can draw
## a whole neighbourhood.

const ASPHALT_KINDS := ["primary", "secondary", "tertiary", "unclassified", "residential", "service", "busway"]
const COBBLE_KINDS := ["pedestrian", "living_street"]
const MARKED_KINDS := ["primary", "secondary", "tertiary"]
const GREEN_AREAS := {"park": Color("5c8a47"), "grass": Color("6a9650"), "playground": Color("8a9a55"), "pitch": Color("4f8a44")}
const CELL := 16.0
const RAIL_GAUGE := 1.435
const FACADES := ["e8dcc4", "d9c7a7", "c9b18f", "e3d5b8", "bfa98a", "d8cfc4", "c7b9a5", "e6c9a8",
	"d4a88c", "b9b2a6", "cdd3d6", "e0d2c0", "c9a58a", "d6d0bd", "e2c7b1", "c4b8a8"]
const FACADES_COMMERCIAL := ["c8ccd0", "b8c0c8", "d8d4cc", "bcc4c4", "d2cbc0"]
const ROOFS := ["6f6a64", "7b746c", "8a8580", "5d5a57", "757069", "a4553b"]
const AWNINGS := ["b03a2e", "2e7d4f", "1f5f99", "c77d20", "6d3b8f", "8a8a8a", "a52a4a"]


static func build(zone: ZoneData, vis: Node3D) -> Dictionary:
	var ctx := _Context.new(zone)
	_ground(ctx, vis)
	_areas(ctx, vis)
	_roads(ctx, vis)
	_crossings(ctx, vis)
	_tracks(ctx, vis)
	_buildings(ctx, vis)
	_trees(ctx, vis)
	var lamps := _lamps(ctx, vis)
	_catenary(ctx, vis)
	var boards := _stops(ctx, vis)
	return {"lamps": lamps, "boards": boards}


## Shared lookups: road segments and building footprints bucketed by cell.
class _Context:
	extends RefCounted
	var zone: ZoneData
	var half := 256.0
	var road_cells := {}  # Vector2i -> Array of [a: Vector2, b: Vector2, width, kind]
	var building_cells := {}  # Vector2i -> Array of PackedVector2Array
	var junctions := {}  # Vector2i (0.1 m key) -> exclusion radius
	var junction_cells := {}  # Vector2i cell -> Array of [point, radius]
	var tracks: Array = []  # PackedVector2Array track centre lines (XZ)

	func _init(z: ZoneData) -> void:
		zone = z
		half = z.half_size()
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


# --- ground, areas, roads ------------------------------------------------------------

static func _ground(ctx: _Context, vis: Node3D) -> void:
	var plane := PlaneMesh.new()
	plane.size = Vector2(ctx.zone.size_m + 800.0, ctx.zone.size_m + 800.0)
	var ground := MeshInstance3D.new()
	ground.name = "Ground"
	ground.mesh = plane
	ground.material_override = CityMaterials.get_shader("pavers")
	vis.add_child(ground)
	var edge := StandardMaterial3D.new()
	edge.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	edge.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	edge.albedo_color = Color(0.45, 0.65, 1.0, 0.12)
	edge.cull_mode = BaseMaterial3D.CULL_DISABLED
	var h := ctx.half
	var s := ctx.zone.size_m
	for spec in [[Vector3(h, 1.5, 0), Vector3(0.05, 3, s)], [Vector3(-h, 1.5, 0), Vector3(0.05, 3, s)],
			[Vector3(0, 1.5, h), Vector3(s, 3, 0.05)], [Vector3(0, 1.5, -h), Vector3(s, 3, 0.05)]]:
		var box := BoxMesh.new()
		box.size = spec[1]
		box.material = edge
		var mi := MeshInstance3D.new()
		mi.mesh = box
		mi.position = spec[0]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vis.add_child(mi)


static func _areas(ctx: _Context, vis: Node3D) -> void:
	var green := SurfaceTool.new()
	green.begin(Mesh.PRIMITIVE_TRIANGLES)
	var stone := SurfaceTool.new()
	stone.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tar := SurfaceTool.new()
	tar.begin(Mesh.PRIMITIVE_TRIANGLES)
	var water := SurfaceTool.new()
	water.begin(Mesh.PRIMITIVE_TRIANGLES)
	var used := {"g": false, "s": false, "t": false, "w": false}
	for area in ctx.zone.areas:
		var poly := WorldBuilder.footprint_xz(area.polygon)
		var kind := str(area.kind)
		if GREEN_AREAS.has(kind):
			used.g = WorldBuilder._add_flat_polygon(green, poly, 0.03, GREEN_AREAS[kind]) or used.g
		elif kind == "plaza":
			used.s = WorldBuilder._add_flat_polygon(stone, poly, 0.035, Color.WHITE) or used.s
		elif kind == "parking":
			used.t = WorldBuilder._add_flat_polygon(tar, poly, 0.03, Color(1, 1, 1, 0)) or used.t
		elif kind == "water":
			used.w = WorldBuilder._add_flat_polygon(water, poly, 0.02, Color("2f5f86")) or used.w
	var specs := [[green, used.g, CityMaterials.get_shader("grass")], [stone, used.s, CityMaterials.get_shader("cobbles")],
		[tar, used.t, CityMaterials.get_shader("asphalt")], [water, used.w, CityMaterials.solid(Color("2f5f86"), 0.1, 0.2)]]
	for spec in specs:
		if spec[1]:
			var mi := MeshInstance3D.new()
			mi.mesh = (spec[0] as SurfaceTool).commit()
			mi.material_override = spec[2]
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			vis.add_child(mi)


static func _roads(ctx: _Context, vis: Node3D) -> void:
	var tools := {}
	for key in ["asphalt", "cobbles", "pavers", "curb"]:
		var st := SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		tools[key] = st
	for road in ctx.zone.roads:
		var kind := str(road.kind)
		var pts := WorldBuilder.footprint_xz(road.points)
		var w := float(road.width)
		if ASPHALT_KINDS.has(kind):
			var marked := MARKED_KINDS.has(kind) and w >= 7.0
			ribbon(tools.asphalt, pts, w, 0.04, Color(1, 1, 1, 1.0 if marked else 0.0))
			if kind != "service" and kind != "busway":
				for side in [-1.0, 1.0]:
					_curb(ctx, tools.curb, pts, side * (w / 2.0 + 0.08))
		elif COBBLE_KINDS.has(kind):
			ribbon(tools.cobbles, pts, w, 0.05, Color.WHITE)
		else:
			ribbon(tools.pavers, pts, w, 0.06, Color.WHITE)
	var mats := {"asphalt": CityMaterials.get_shader("asphalt"), "cobbles": CityMaterials.get_shader("cobbles"),
		"pavers": CityMaterials.get_shader("pavers"), "curb": CityMaterials.solid(Color("a8a39a"), 0.85)}
	for key in tools:
		var mi := MeshInstance3D.new()
		mi.name = "Roads_" + key
		mi.mesh = (tools[key] as SurfaceTool).commit()
		mi.material_override = mats[key]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF if key != "curb" else GeometryInstance3D.SHADOW_CASTING_SETTING_ON
		vis.add_child(mi)


## Flat strip along a polyline. UV.x = metres along, UV.y = 0..1 across.
static func ribbon(st: SurfaceTool, pts: PackedVector2Array, width: float, y: float, color: Color, lateral := 0.0) -> void:
	if pts.size() < 2:
		return
	var left := offset_polyline(pts, lateral + width / 2.0)
	var right := offset_polyline(pts, lateral - width / 2.0)
	var along := 0.0
	for i in pts.size() - 1:
		var seg := pts[i].distance_to(pts[i + 1])
		var a := Vector3(left[i].x, y, left[i].y)
		var b := Vector3(right[i].x, y, right[i].y)
		var c := Vector3(right[i + 1].x, y, right[i + 1].y)
		var d := Vector3(left[i + 1].x, y, left[i + 1].y)
		var uv := PackedVector2Array([Vector2(along, 0), Vector2(along, 1), Vector2(along + seg, 1)])
		WorldBuilder._add_tri(st, a, b, c, Vector3.UP, color, uv)
		WorldBuilder._add_tri(st, a, c, d, Vector3.UP, color,
			PackedVector2Array([Vector2(along, 0), Vector2(along + seg, 1), Vector2(along + seg, 0)]))
		along += seg


## Polyline shifted sideways (positive = left of travel in XZ), mitred.
static func offset_polyline(pts: PackedVector2Array, off: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var d_in := (pts[i] - pts[i - 1]).normalized() if i > 0 else Vector2.ZERO
		var d_out := (pts[i + 1] - pts[i]).normalized() if i < n - 1 else Vector2.ZERO
		var n_in := Vector2(-d_in.y, d_in.x)
		var n_out := Vector2(-d_out.y, d_out.x)
		var ref := n_out if d_out != Vector2.ZERO else n_in
		var miter := (n_in + n_out).normalized() if (n_in + n_out).length() > 0.01 else ref
		out.append(pts[i] + miter * off / maxf(0.4, miter.dot(ref)))
	return out


## Kerb stones along one edge, left out where other streets join.
static func _curb(ctx: _Context, st: SurfaceTool, pts: PackedVector2Array, off: float) -> void:
	var edge := offset_polyline(pts, off)
	var inward := -signf(off)
	var run := PackedVector2Array()
	for i in edge.size() - 1:
		var a := edge[i]
		var b := edge[i + 1]
		var steps := maxi(1, ceili(a.distance_to(b) / 1.0))
		for k in steps + 1:
			var p := a.lerp(b, float(k) / steps)
			var c := pts[i].lerp(pts[i + 1], float(k) / steps)
			if ctx.near_junction(c) or not ctx.inside_zone(p, 1.0):
				_emit_curb(st, run, inward)
				run = PackedVector2Array()
			elif run.is_empty() or run[run.size() - 1].distance_to(p) > 0.05:
				run.append(p)
	_emit_curb(st, run, inward)


static func _emit_curb(st: SurfaceTool, run: PackedVector2Array, inward: float) -> void:
	if run.size() < 2:
		return
	var top := 0.13
	for i in run.size() - 1:
		var a := run[i]
		var b := run[i + 1]
		var d := (b - a).normalized()
		var n := Vector2(-d.y, d.x) * inward  # towards the carriageway
		var a2 := a - n * 0.16
		var b2 := b - n * 0.16
		# Top face.
		WorldBuilder._add_tri(st, Vector3(a.x, top, a.y), Vector3(b.x, top, b.y), Vector3(b2.x, top, b2.y), Vector3.UP, Color.WHITE)
		WorldBuilder._add_tri(st, Vector3(a.x, top, a.y), Vector3(b2.x, top, b2.y), Vector3(a2.x, top, a2.y), Vector3.UP, Color.WHITE)
		# Face towards the road.
		var face := Vector3(n.x, 0, n.y)
		WorldBuilder._add_tri(st, Vector3(a.x, 0.03, a.y), Vector3(b.x, top, b.y), Vector3(b.x, 0.03, b.y), face, Color.WHITE)
		WorldBuilder._add_tri(st, Vector3(a.x, 0.03, a.y), Vector3(a.x, top, a.y), Vector3(b.x, top, b.y), face, Color.WHITE)


static func _crossings(ctx: _Context, vis: Node3D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var any := false
	for c in ctx.zone.crossings:
		var p := Vector2(float(c[0]), -float(c[1]))
		var best: Array = []
		var best_d := 2.5
		for seg in ctx.roads_near(p):
			if not ASPHALT_KINDS.has(seg[3]):
				continue
			var q := Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1])
			if p.distance_to(q) < best_d:
				best_d = p.distance_to(q)
				best = seg
		if best.is_empty():
			continue
		var along: Vector2 = (best[1] - best[0]).normalized()
		var across := Vector2(-along.y, along.x)
		var half_w: float = float(best[2]) / 2.0 - 0.4
		var y := 0.046
		var corners := [p - along * 1.5 - across * half_w, p + along * 1.5 - across * half_w,
			p + along * 1.5 + across * half_w, p - along * 1.5 + across * half_w]
		var uvs := [Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)]
		for tri in [[0, 1, 2], [0, 2, 3]]:
			WorldBuilder._add_tri(st, Vector3(corners[tri[0]].x, y, corners[tri[0]].y), Vector3(corners[tri[1]].x, y, corners[tri[1]].y),
				Vector3(corners[tri[2]].x, y, corners[tri[2]].y), Vector3.UP, Color.WHITE,
				PackedVector2Array([uvs[tri[0]], uvs[tri[1]], uvs[tri[2]]]))
		any = true
	if any:
		var mi := MeshInstance3D.new()
		mi.name = "Crossings"
		mi.mesh = st.commit()
		mi.material_override = CityMaterials.get_shader("zebra")
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vis.add_child(mi)


# --- trams: tracks, wires, stops -------------------------------------------------------

static func _tracks(ctx: _Context, vis: Node3D) -> void:
	var bed := SurfaceTool.new()
	bed.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rails := SurfaceTool.new()
	rails.begin(Mesh.PRIMITIVE_TRIANGLES)
	for poly in ctx.tracks:
		var inside := _inside_run(ctx, poly)
		for piece in inside:
			ribbon(bed, piece, 2.2, 0.058, Color.WHITE)
			for side in [-1.0, 1.0]:
				ribbon(rails, piece, 0.08, 0.078, Color.WHITE, side * RAIL_GAUGE / 2.0)
	for spec in [[bed, CityMaterials.solid(Color("4a4844"), 0.95), "TrackBed"], [rails, CityMaterials.solid(Color("b9bcc0"), 0.25, 0.9), "Rails"]]:
		var mi := MeshInstance3D.new()
		mi.name = spec[2]
		mi.mesh = (spec[0] as SurfaceTool).commit()
		mi.material_override = spec[1]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vis.add_child(mi)


## Pieces of a polyline inside the zone (densified so clipping is smooth).
static func _inside_run(ctx: _Context, poly: PackedVector2Array) -> Array:
	var pieces := []
	var cur := PackedVector2Array()
	for i in poly.size():
		if ctx.inside_zone(poly[i], -2.0):
			cur.append(poly[i])
		else:
			if cur.size() >= 2:
				pieces.append(cur)
			cur = PackedVector2Array()
	if cur.size() >= 2:
		pieces.append(cur)
	return pieces


static func _catenary(ctx: _Context, vis: Node3D) -> void:
	var pole_xf := []
	var arm_xf := []
	var wires := SurfaceTool.new()
	wires.begin(Mesh.PRIMITIVE_LINES)
	var any_wire := false
	for line: TransitNetwork.TransitLine in ctx.zone.transit.lines:
		var polys: Array = [line.path] if line.loop else [line.right_track, line.left_track]
		for poly in polys:
			for piece in _inside_run(ctx, WorldBuilder.footprint_xz(Array(poly).map(func(p): return [p.x, p.y]))):
				for i in piece.size() - 1:
					wires.add_vertex(Vector3(piece[i].x, 5.6, piece[i].y))
					wires.add_vertex(Vector3(piece[i + 1].x, 5.6, piece[i + 1].y))
					any_wire = true
		var s := 10.0
		while s < line.length:
			var c := line.point_at(s)
			var t := line.tangent_at(s)
			var right := Vector2(t.y, -t.x)
			var side_off := 0.0 if not line.loop else 2.5
			var pole_en := c + right * side_off
			var pole := Vector2(pole_en.x, -pole_en.y)
			s += 32.0
			if not ctx.inside_zone(pole, 3.0) or ctx.building_clearance(pole) < 0.5:
				continue
			var across := Vector2(right.x, -right.y)  # EN -> XZ
			var yaw := atan2(-across.y, across.x)  # local X of the arm along `across`
			pole_xf.append(Transform3D(Basis(), Vector3(pole.x, 3.3, pole.y)))
			var span := 3.6 if not line.loop else 2.5
			var mid := pole_en + (right * -side_off * 0.5 if line.loop else Vector2.ZERO)
			arm_xf.append(Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(span, 1, 1)), Vector3(mid.x, 6.0, -mid.y)))
	var pole_mesh := CylinderMesh.new()
	pole_mesh.top_radius = 0.08
	pole_mesh.bottom_radius = 0.11
	pole_mesh.height = 6.6
	pole_mesh.radial_segments = 8
	var arm_mesh := BoxMesh.new()
	arm_mesh.size = Vector3(1.0, 0.08, 0.08)
	var metal := CityMaterials.solid(Color("4d5359"), 0.5, 0.6)
	_multimesh(vis, pole_mesh, metal, pole_xf, [], 180.0, "CatenaryPoles")
	_multimesh(vis, arm_mesh, metal, arm_xf, [], 180.0, "CatenaryArms")
	if any_wire:
		var mi := MeshInstance3D.new()
		mi.name = "Wires"
		mi.mesh = wires.commit()
		mi.material_override = CityMaterials.solid(Color("202326"), 0.6, 0.5)
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vis.add_child(mi)


## Shelters, platforms, signs and live departure boards. Returns the boards
## as [{label: Label3D, serves: [[line, stop, dir], ...]}] for the client to refresh.
static func _stops(ctx: _Context, vis: Node3D) -> Array:
	var groups := {}
	for line: TransitNetwork.TransitLine in ctx.zone.transit.lines:
		for i in line.stops.size():
			if not line.stops[i].in_zone:
				continue
			for dir in ([1] if line.loop else [1, -1]):
				var p := line.platform(i, dir)
				var key := Vector2i(roundi(p.x / 3.0), roundi(p.y / 3.0))
				if not groups.has(key):
					groups[key] = {"pos": p, "tangent": line.tangent_at(float(line.stops[i].s)) * dir,
						"name": line.stops[i].name, "room": line.platform_room(i, dir) - (line.stops[i].plat_r if dir > 0 else line.stops[i].plat_l),
						"track_gap": (line.stops[i].plat_r if dir > 0 else line.stops[i].plat_l) - line.track_offset,
						"long": line.vehicle_type != "nostalgic", "serves": [], "color": line.color}
				groups[key].serves.append([line.index, i, dir])
	var boards := []
	var stone := CityMaterials.solid(Color("b7b2a8"), 0.9)
	var frame := CityMaterials.solid(Color("2f3438"), 0.4, 0.6)
	for g in groups.values():
		var en: Vector2 = g.pos
		var t: Vector2 = g.tangent
		var right := Vector2(t.y, -t.x)  # away from the track, in EN
		var node := Node3D.new()
		node.name = "Stop_" + str(g.name)
		node.position = Vector3(en.x, 0.0, -en.y)
		node.basis = Basis.looking_at(Vector3(t.x, 0, -t.y), Vector3.UP)
		vis.add_child(node)
		# Local frame: -Z along travel, +X away from the track.
		var length := 26.0 if g.long else 13.0
		# The slab runs from just clear of the tram (1.3 m from the track
		# centre) to a little behind where people stand.
		var inner := -(float(g.track_gap) - 1.3)
		var outer := minf(0.6, float(g.room) - 0.2)
		if outer - inner >= 0.6:
			_box(node, Vector3(outer - inner, 0.1, length), Vector3((inner + outer) / 2.0, 0.05, 0), stone)
			_box(node, Vector3(0.12, 0.14, length), Vector3(inner + 0.06, 0.07, 0), CityMaterials.solid(Color("e8e3d6"), 0.8))
		var has_shelter := float(g.room) >= 1.4
		if has_shelter:
			_box(node, Vector3(1.5, 0.08, 3.6), Vector3(0.45, 2.55, 0), frame)
			_box(node, Vector3(0.04, 2.2, 3.4), Vector3(1.1, 1.3, 0), CityMaterials.glass())
			for z in [-1.7, 1.7]:
				_box(node, Vector3(0.08, 2.5, 0.08), Vector3(1.1, 1.27, z), frame)
			_box(node, Vector3(0.45, 0.06, 2.4), Vector3(0.8, 0.48, 0), CityMaterials.solid(Color("6b4a33"), 0.7))
		# Sign pole with the stop name.
		var pole := _box(node, Vector3(0.08, 3.0, 0.08), Vector3(0.6, 1.5, -3.5), frame)
		pole.name = "SignPole"
		var disk := MeshInstance3D.new()
		var cyl := CylinderMesh.new()
		cyl.top_radius = 0.32
		cyl.bottom_radius = 0.32
		cyl.height = 0.04
		disk.mesh = cyl
		disk.material_override = CityMaterials.solid(g.color, 0.5)
		disk.position = Vector3(0.6, 3.1, -3.5)
		disk.rotation.x = PI / 2
		node.add_child(disk)
		var title := Label3D.new()
		title.text = str(g.name)
		title.font_size = 42
		title.pixel_size = 0.006
		title.outline_size = 8
		title.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		title.position = Vector3(0.6, 3.55, -3.5)
		node.add_child(title)
		var board := Label3D.new()
		board.font_size = 30
		board.pixel_size = 0.005
		board.outline_size = 6
		board.modulate = Color("ffcf6b")
		board.position = Vector3(0.4, 2.2 if has_shelter else 2.7, 0.0 if has_shelter else -3.5)
		board.rotation.y = -PI / 2  # face the track
		board.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		node.add_child(board)
		boards.append({"label": board, "serves": g.serves})
	return boards


# --- buildings -------------------------------------------------------------------------

static func _buildings(ctx: _Context, vis: Node3D) -> void:
	var walls := {}
	var roofs := {}
	var balcony_xf := []
	var balcony_col := []
	var bay_xf := []
	var bay_col := []
	var awning_xf := []
	var awning_col := []
	var tank_xf := []
	var ac_xf := []
	for b in ctx.zone.buildings:
		var poly := WorldBuilder.footprint_xz(b.footprint)
		if poly.size() < 3:
			continue
		var area := 0.0
		for i in poly.size():
			area += poly[i].x * poly[(i + 1) % poly.size()].y - poly[(i + 1) % poly.size()].x * poly[i].y
		if area > 0.0:
			poly.reverse()
		var center := Vector2.ZERO
		for p in poly:
			center += p
		center /= poly.size()
		var chunk := Vector2i(floori(center.x / 128.0), floori(center.y / 128.0))
		if not walls.has(chunk):
			walls[chunk] = SurfaceTool.new()
			walls[chunk].begin(Mesh.PRIMITIVE_TRIANGLES)
			roofs[chunk] = SurfaceTool.new()
			roofs[chunk].begin(Mesh.PRIMITIVE_TRIANGLES)
		var key := str(b.id)
		var bottom := float(b.min_height)
		var top := float(b.height)
		var kind := str(b.kind)
		var facade := _facade_color(key, kind)
		var shop: bool = kind in ["commercial", "generic"] and bottom < 0.1 and top > 6.0 and WorldBuilder._hash01(key + "shop") < 0.7
		facade.a = 1.0 if shop else 0.0
		var parapet := 0.9 if bottom < 0.1 and top > 5.0 else 0.0
		var wst: SurfaceTool = walls[chunk]
		var floors := int(top / 3.1)
		var style := WorldBuilder._hash01(key + "style")
		for i in poly.size():
			var p0 := poly[i]
			var p1 := poly[(i + 1) % poly.size()]
			var edge := p1 - p0
			var length := edge.length()
			if length < 0.05:
				continue
			var n := Vector3(-edge.y, 0.0, edge.x).normalized()
			var info := Vector2(top, length)
			_wall_quad(wst, p0, p1, bottom, top + parapet, n, facade, length, info)
			if parapet > 0.0:
				# Inner face of the parapet, 20 cm in.
				var inset := Vector2(n.x, n.z) * -0.2
				_wall_quad(wst, p1 + inset, p0 + inset, top, top + parapet, -n, facade, length, Vector2(0, length))
			if bottom > 0.1 or length < 4.0 or not _faces_street(ctx, p0, p1, Vector2(n.x, n.z)):
				continue
			var dir := edge / length
			var out := Vector2(n.x, n.z)
			var bays := int((length - 1.0) / 3.0)
			var start := (length - bays * 3.0) / 2.0 + 1.5
			var yaw := atan2(-out.x, -out.y)  # -Z of the prop points out of the wall
			for k in bays:
				var along := start + k * 3.0
				var base := p0 + dir * along
				var h := WorldBuilder._hash01("%s:%d:%d" % [key, i, k])
				if shop:
					var col := Color(str(AWNINGS[int(h * AWNINGS.size())]))
					awning_xf.append(Transform3D(Basis(Vector3.UP, yaw), Vector3(base.x + out.x * 0.6, 2.75, base.y + out.y * 0.6)))
					awning_col.append(col)
				for f in range(1, floors):
					var hf := WorldBuilder._hash01("%s:%d:%d:%d" % [key, i, k, f])
					var y := f * 3.1
					if style < 0.45 and hf < 0.55:
						balcony_xf.append(Transform3D(Basis(Vector3.UP, yaw), Vector3(base.x + out.x * 0.55, y, base.y + out.y * 0.55)))
						balcony_col.append(Color(facade.r, facade.g, facade.b).lightened(0.05))
					elif style > 0.8 and f % 2 == 1 and k % 2 == 0 and f < floors - 1:
						bay_xf.append(Transform3D(Basis(Vector3.UP, yaw), Vector3(base.x + out.x * 0.4, y + 0.2, base.y + out.y * 0.4)))
						bay_col.append(facade)
		var roof_color := Color(str(ROOFS[int(WorldBuilder._hash01(key + "roof") * ROOFS.size())]))
		if not WorldBuilder._add_flat_polygon(roofs[chunk], poly, top, roof_color):
			WorldBuilder._add_flat_polygon(roofs[chunk], Geometry2D.convex_hull(poly), top, roof_color)
		if bottom > 0.1:
			WorldBuilder._add_flat_polygon(roofs[chunk], poly, bottom, roof_color.darkened(0.3), Vector3.DOWN)
		# Istanbul roofs: water tanks and air conditioners.
		if parapet > 0.0 and absf(area) > 60.0:
			var r := WorldBuilder._hash01(key + "tank")
			var spot := center + Vector2(cos(r * TAU), sin(r * TAU)) * 1.5
			if Geometry2D.is_point_in_polygon(spot, poly) and r < 0.6:
				tank_xf.append(Transform3D(Basis(), Vector3(spot.x, top + 0.8, spot.y)))
			var spot2 := center - Vector2(cos(r * TAU), sin(r * TAU)) * 2.0
			if Geometry2D.is_point_in_polygon(spot2, poly) and r > 0.3:
				ac_xf.append(Transform3D(Basis(Vector3.UP, r * TAU), Vector3(spot2.x, top + 0.35, spot2.y)))
	var wall_mat := CityMaterials.get_shader("walls")
	var roof_mat := CityMaterials.get_shader("roof")
	for chunk in walls:
		var mi := MeshInstance3D.new()
		mi.name = "Buildings_%d_%d" % [chunk.x, chunk.y]
		var mesh: ArrayMesh = walls[chunk].commit()
		mesh = roofs[chunk].commit(mesh)
		mesh.surface_set_material(0, wall_mat)
		if mesh.get_surface_count() > 1:
			mesh.surface_set_material(1, roof_mat)
		mi.mesh = mesh
		vis.add_child(mi)
	_multimesh(vis, _balcony_mesh(), CityMaterials.instanced(), balcony_xf, balcony_col, 170.0, "Balconies")
	_multimesh(vis, _bay_mesh(), CityMaterials.instanced(), bay_xf, bay_col, 170.0, "BayWindows")
	_multimesh(vis, _awning_mesh(), CityMaterials.instanced(0.9), awning_xf, awning_col, 130.0, "Awnings")
	var tank := CylinderMesh.new()
	tank.top_radius = 0.6
	tank.bottom_radius = 0.6
	tank.height = 1.6
	tank.radial_segments = 12
	_multimesh(vis, tank, CityMaterials.solid(Color("d6d9dc"), 0.5, 0.3), tank_xf, [], 200.0, "WaterTanks")
	var ac := BoxMesh.new()
	ac.size = Vector3(0.9, 0.7, 0.6)
	_multimesh(vis, ac, CityMaterials.solid(Color("c7cacc"), 0.6), ac_xf, [], 140.0, "AirConditioners")


static func _wall_quad(st: SurfaceTool, p0: Vector2, p1: Vector2, y0: float, y1: float, n: Vector3,
		col: Color, length: float, info: Vector2) -> void:
	var a0 := Vector3(p0.x, y0, p0.y)
	var a1 := Vector3(p0.x, y1, p0.y)
	var b0 := Vector3(p1.x, y0, p1.y)
	var b1 := Vector3(p1.x, y1, p1.y)
	WorldBuilder._add_tri(st, a0, b1, b0, n, col,
		PackedVector2Array([Vector2(0, y0), Vector2(length, y1), Vector2(length, y0)]), info)
	WorldBuilder._add_tri(st, a0, a1, b1, n, col,
		PackedVector2Array([Vector2(0, y0), Vector2(0, y1), Vector2(length, y1)]), info)


## A wall faces the street if a road runs just outside it.
static func _faces_street(ctx: _Context, p0: Vector2, p1: Vector2, out: Vector2) -> bool:
	var probe := (p0 + p1) / 2.0 + out * 4.0
	for seg in ctx.roads_near(probe):
		var q := Geometry2D.get_closest_point_to_segment(probe, seg[0], seg[1])
		if probe.distance_to(q) < float(seg[2]) / 2.0 + 3.5:
			return true
	return false


static func _facade_color(key: String, kind: String) -> Color:
	var palette: Array = FACADES
	if kind == "commercial" or kind == "civic":
		palette = FACADES_COMMERCIAL
	elif kind == "religious":
		palette = ["efe8dc"]
	var base := Color(str(palette[int(WorldBuilder._hash01(key) * palette.size())]))
	return base.darkened((WorldBuilder._hash01(key + "dark") - 0.5) * 0.14)


## Balcony slab with a solid parapet in the wall colour (the usual Istanbul
## apartment balcony) and a thin metal handrail; sticks out along -Z.
static func _balcony_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rail := Color(0.3, 0.31, 0.33)
	_box_into(st, Vector3(2.4, 0.15, 1.1), Vector3(0, 0.0, 0), Color(0.92, 0.92, 0.92))
	_box_into(st, Vector3(2.4, 0.8, 0.08), Vector3(0, 0.47, -0.51), Color.WHITE)
	_box_into(st, Vector3(0.08, 0.8, 1.1), Vector3(-1.16, 0.47, 0), Color.WHITE)
	_box_into(st, Vector3(0.08, 0.8, 1.1), Vector3(1.16, 0.47, 0), Color.WHITE)
	_box_into(st, Vector3(2.44, 0.05, 0.06), Vector3(0, 0.98, -0.51), rail)
	return st.commit()


## Cumba: a closed bay window box.
static func _bay_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box_into(st, Vector3(2.6, 2.7, 0.8), Vector3(0, 1.35, 0), Color.WHITE)
	_box_into(st, Vector3(1.8, 1.2, 0.05), Vector3(0, 1.5, -0.41), Color(0.2, 0.26, 0.32))
	return st.commit()


static func _awning_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var tmp := BoxMesh.new()
	tmp.size = Vector3(2.7, 0.06, 1.3)
	var arrays := tmp.get_mesh_arrays()
	var xf := Transform3D(Basis(Vector3.RIGHT, -0.35), Vector3(0, 0, 0))
	for i in arrays[Mesh.ARRAY_VERTEX].size():
		st.set_color(Color.WHITE)
		st.set_normal(xf.basis * arrays[Mesh.ARRAY_NORMAL][i])
		st.add_vertex(xf * arrays[Mesh.ARRAY_VERTEX][i])
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for i in idx:
		st.add_index(i)
	return st.commit()


static func _box_into(st: SurfaceTool, size: Vector3, pos: Vector3, color: Color) -> void:
	var tmp := BoxMesh.new()
	tmp.size = size
	var arrays := tmp.get_mesh_arrays()
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	for i in range(0, idx.size(), 3):
		for k in 3:
			st.set_color(color)
			st.set_normal(normals[idx[i + k]])
			st.add_vertex(verts[idx[i + k]] + pos)


# --- street furniture ----------------------------------------------------------------

static func _trees(ctx: _Context, vis: Node3D) -> void:
	var points := WorldBuilder.tree_points(ctx.zone)
	if points.is_empty():
		return
	var trunk_xf := []
	var crown_xf := []
	var crown_col := []
	for i in points.size():
		var p: Vector3 = points[i]
		var h := WorldBuilder._hash01("tree%d" % i)
		var s := 1.3 + h * 1.2
		trunk_xf.append(Transform3D(Basis().scaled(Vector3(1, 1 + h * 0.4, 1)), p + Vector3(0, 1.5, 0)))
		crown_xf.append(Transform3D(Basis(Vector3.UP, h * TAU).scaled(Vector3(s, s * 0.9, s)), p + Vector3(0, 3.4 + s * 0.9, 0)))
		crown_col.append(Color("3f6b30").lerp(Color("7c9e4a"), WorldBuilder._hash01("leaf%d" % i)))
	var trunk := CylinderMesh.new()
	trunk.top_radius = 0.14
	trunk.bottom_radius = 0.22
	trunk.height = 3.0
	trunk.radial_segments = 7
	_multimesh(vis, trunk, CityMaterials.solid(Color("4f3d2e"), 0.95), trunk_xf, [], 250.0, "TreeTrunks")
	_multimesh(vis, _crown_mesh(), CityMaterials.get_shader("leaves"), crown_xf, crown_col, 300.0, "TreeCrowns")


## Three overlapping blobs read as a leafy crown from any side.
static func _crown_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for spec in [[Vector3(0, 0, 0), 1.0], [Vector3(0.55, -0.25, 0.2), 0.72], [Vector3(-0.45, -0.2, -0.3), 0.75], [Vector3(0.1, 0.45, -0.1), 0.62]]:
		var sphere := SphereMesh.new()
		sphere.radius = spec[1]
		sphere.height = spec[1] * 1.8
		sphere.radial_segments = 10
		sphere.rings = 6
		var arrays := sphere.get_mesh_arrays()
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in idx:
			st.set_color(Color.WHITE)
			st.set_normal(normals[i])
			st.add_vertex(verts[i] + spec[0])
	return st.commit()


## Street lamps along streets, kept off tracks, junctions and walls.
## Returns lamp head positions (for the night lights near the camera).
static func _lamps(ctx: _Context, vis: Node3D) -> PackedVector3Array:
	var heads := PackedVector3Array()
	var pole_xf := []
	var head_xf := []
	for road in ctx.zone.roads:
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
				if not ctx.inside_zone(p, 3.0) or ctx.near_junction(c, 3.0) or ctx.near_track(p, 3.2) \
						or ctx.building_clearance(p) < 0.4:
					continue
				var yaw := atan2(-n.x, -n.y)  # local +Z (the arm) points towards the street centre
				pole_xf.append(Transform3D(Basis(Vector3.UP, yaw), Vector3(p.x, 0, p.y)))
				var head := Vector3(p.x - n.x * 1.1, 5.75, p.y - n.y * 1.1)
				head_xf.append(Transform3D(Basis(Vector3.UP, yaw), head))
				heads.append(head)
			walked += seg
	var pole_mesh := _lamp_pole_mesh()
	_multimesh(vis, pole_mesh, CityMaterials.solid(Color("3d4247"), 0.45, 0.6), pole_xf, [], 200.0, "LampPoles")
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.28, 0.14, 0.55)
	_multimesh(vis, head_mesh, CityMaterials.get_shader("lamp_head"), head_xf, [], 400.0, "LampHeads")
	return heads


static func _lamp_pole_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	_box_into(st, Vector3(0.12, 6.0, 0.12), Vector3(0, 3.0, 0), Color.WHITE)
	_box_into(st, Vector3(0.07, 0.07, 1.25), Vector3(0, 5.85, 0.6), Color.WHITE)
	return st.commit()


## One MultiMeshInstance per 96 m cell: visibility ranges are measured per
## instance node, so a single zone-wide MultiMesh would never be culled.
static func _multimesh(vis: Node3D, mesh: Mesh, mat: Material, xforms: Array, colors: Array, range_end: float, node_name: String) -> void:
	var cells := {}
	for i in xforms.size():
		var o: Vector3 = (xforms[i] as Transform3D).origin
		var c := Vector2i(floori(o.x / 96.0), floori(o.z / 96.0))
		if not cells.has(c):
			cells[c] = []
		cells[c].append(i)
	for c in cells:
		var ids: Array = cells[c]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = not colors.is_empty()
		mm.mesh = mesh
		mm.instance_count = ids.size()
		for k in ids.size():
			mm.set_instance_transform(k, xforms[ids[k]])
			if mm.use_colors:
				mm.set_instance_color(k, colors[ids[k]])
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "%s_%d_%d" % [node_name, c.x, c.y]
		mmi.multimesh = mm
		mmi.material_override = mat
		mmi.visibility_range_end = range_end
		mmi.visibility_range_end_margin = 20.0
		mmi.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF
		vis.add_child(mmi)


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi
