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
const RAIL_GAUGE := 1.435
const FACADES := ["e8dcc4", "d9c7a7", "c9b18f", "e3d5b8", "bfa98a", "d8cfc4", "c7b9a5", "e6c9a8",
	"d4a88c", "b9b2a6", "cdd3d6", "e0d2c0", "c9a58a", "d6d0bd", "e2c7b1", "c4b8a8"]
const FACADES_COMMERCIAL := ["c8ccd0", "b8c0c8", "d8d4cc", "bcc4c4", "d2cbc0"]
const ROOFS := ["6f6a64", "7b746c", "8a8580", "5d5a57", "757069", "a4553b"]
const AWNINGS := ["b03a2e", "2e7d4f", "1f5f99", "c77d20", "6d3b8f", "8a8a8a", "a52a4a"]
## Pure decoration, hidden on GraphicsQuality.LOW.
const DETAIL_PROPS := ["BayWindows", "Awnings", "WaterTanks", "AirConditioners", "CatenaryArms"]


static func build(zone: ZoneData, vis: Node3D) -> Dictionary:
	var ctx := StreetLayout.for_zone(zone)
	_ground(ctx, vis)
	_areas(ctx, vis)
	_roads(ctx, vis)
	_crossings(ctx, vis)
	_tracks(ctx, vis)
	_buildings(ctx, vis)
	_trees(ctx, vis)
	var lamps := _lamps(ctx, vis)
	_cars(ctx, vis)
	_street_furniture(ctx, vis)
	_shop_signs(ctx, vis)
	_street_signs(ctx, vis)
	_catenary(ctx, vis)
	var boards := _stops(ctx, vis)
	return {"lamps": lamps, "boards": boards}


# --- ground, areas, roads ------------------------------------------------------------

static func _ground(ctx: StreetLayout, vis: Node3D) -> void:
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


static func _areas(ctx: StreetLayout, vis: Node3D) -> void:
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


static func _roads(ctx: StreetLayout, vis: Node3D) -> void:
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
static func _curb(ctx: StreetLayout, st: SurfaceTool, pts: PackedVector2Array, off: float) -> void:
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


static func _crossings(ctx: StreetLayout, vis: Node3D) -> void:
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

static func _tracks(ctx: StreetLayout, vis: Node3D) -> void:
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
	for spec in [[bed, CityMaterials.solid(Color("4a4844"), 0.95), "TrackBed"], [rails, CityMaterials.solid(Color("8a8c8e"), 0.45, 0.55), "Rails"]]:
		var mi := MeshInstance3D.new()
		mi.name = spec[2]
		mi.mesh = (spec[0] as SurfaceTool).commit()
		mi.material_override = spec[1]
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		vis.add_child(mi)


## Pieces of a polyline inside the zone (densified so clipping is smooth).
static func _inside_run(ctx: StreetLayout, poly: PackedVector2Array) -> Array:
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


static func _catenary(ctx: StreetLayout, vis: Node3D) -> void:
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


## Shelters, raised platforms, signs and live departure boards (placement
## from StreetLayout, which also gives the server its colliders). Returns
## the boards as [{label: Label3D, serves: [[line, stop, dir], ...]}].
static func _stops(ctx: StreetLayout, vis: Node3D) -> Array:
	var boards := []
	var stone := Color("b7b2a8")
	var frame := Color("2f3438")
	for g in ctx.stops:
		var node := Node3D.new()
		node.name = "Stop_" + str(g.name)
		node.transform = g.xf
		vis.add_child(node)
		# Local frame: -Z along travel, +X away from the track.
		var length: float = g.length
		# One merged mesh per stop (plus its glass): few draw calls per stop.
		var m := MeshMerger.new()
		var slab: Array = g.slab
		if not slab.is_empty():
			var centre: Vector3 = slab[0]
			var size: Vector3 = slab[1]
			var inner := centre.x - size.x / 2.0
			m.box("stop", size, centre, stone)
			# White edge line and a yellow tactile strip along the tram side.
			m.box("stop", Vector3(0.12, 0.01, length), Vector3(inner + 0.06, size.y + 0.005, 0), Color("e8e3d6"))
			m.box("stop", Vector3(0.3, 0.012, length), Vector3(inner + 0.5, size.y + 0.006, 0), Color("d9b43a"))
		if g.shelter:
			m.box("stop", Vector3(1.5, 0.08, 3.6), Vector3(0.45, 2.55, 0), frame)
			m.box("glass", Vector3(0.04, 2.2, 3.4), Vector3(1.1, 1.3, 0), Color.WHITE)
			for z in [-1.7, 1.7]:
				m.box("stop", Vector3(0.08, 2.5, 0.08), Vector3(1.1, 1.27, z), frame)
			m.box("stop", Vector3(0.45, 0.06, 2.4), Vector3(0.8, 0.48, 0), Color("6b4a33"))
			for z in [-1.0, 1.0]:
				m.box("stop", Vector3(0.06, 0.45, 0.06), Vector3(0.8, 0.23, z), frame)
		# Sign pole with the stop name and the line colour disk.
		m.box("stop", Vector3(0.08, 3.0, 0.08), Vector3(0.6, 1.5, -3.5), frame)
		m.cylinder("stop", 0.32, 0.32, 0.04, Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(0.6, 3.1, -3.5)), g.color)
		m.emit("stop", node, MeshMerger.vertex_colour_material(0.8))
		var glass := m.emit("glass", node, CityMaterials.glass())
		if glass:
			glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		var title := Label3D.new()
		title.text = str(g.name)
		title.font_size = 42
		title.pixel_size = 0.006
		title.outline_size = 8
		title.billboard = BaseMaterial3D.BILLBOARD_FIXED_Y
		title.position = Vector3(0.6, 3.55, -3.5)
		set_range(title, 110.0)
		node.add_child(title)
		var board := Label3D.new()
		board.font_size = 30
		board.pixel_size = 0.005
		board.outline_size = 6
		board.modulate = Color("ffcf6b")
		board.position = Vector3(0.4, 2.2 if g.shelter else 2.7, 0.0 if g.shelter else -3.5)
		board.rotation.y = -PI / 2  # face the track
		board.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
		set_range(board, 45.0)
		node.add_child(board)
		boards.append({"label": board, "serves": g.serves})
	return boards


# --- signs ----------------------------------------------------------------------------

const SIGN_SKIP := ["atm", "waste_disposal", "bench", "parking", "bicycle_parking", "vending_machine", "toilets",
	"drinking_water", "post_box", "recycling", "telephone", "fountain", "apartment"]
const SIGN_COLOURS := {
	"pharmacy": Color("ff4d4d"), "chemist": Color("ff4d4d"), "bank": Color("e8f0ff"),
	"cafe": Color("ffd08a"), "restaurant": Color("ffcf6b"), "fast_food": Color("ffb347"), "bar": Color("ff9ecf"),
	"pub": Color("ff9ecf"), "nightclub": Color("d68bff"), "bakery": Color("ffe3a3"), "confectionery": Color("ffc4e1"),
	"theatre": Color("fff2a8"), "cinema": Color("fff2a8"), "books": Color("c9f0c1"),
}
const STREET_WORDS := {"Caddesi": "Cd.", "Sokağı": "Sk.", "Sokak": "Sk.", "Bulvarı": "Bul.", "Meydanı": "Myd.",
	"Çıkmazı": "Çkm.", "Yokuşu": "Yk."}


## The real names of shops, cafés and banks (OSM points of interest) on the
## street-facing wall of the building they are in, above the shop window.
static func _shop_signs(ctx: StreetLayout, vis: Node3D) -> void:
	var placed: Array = []
	var holder := Node3D.new()
	holder.name = "ShopSigns"
	vis.add_child(holder)
	for poi in ctx.zone.pois:
		var label_text := str(poi.get("name", ""))
		var kind := str(poi.get("kind", ""))
		if label_text == "" or kind in SIGN_SKIP:
			continue
		var p := Vector2(float(poi.e), -float(poi.n))
		var best: Array = []
		var best_d := 14.0
		for poly in ctx.building_cells.get(Vector2i(floori(p.x / StreetLayout.CELL), floori(p.y / StreetLayout.CELL)), []):
			for i in poly.size():
				var a: Vector2 = poly[i]
				var b: Vector2 = poly[(i + 1) % poly.size()]
				if a.distance_to(b) < 3.0:
					continue
				var q := Geometry2D.get_closest_point_to_segment(p, a, b)
				var d := p.distance_to(q)
				if d >= best_d:
					continue
				# Outward normal: the side of the edge away from the building.
				var n := Vector2(-(b - a).y, (b - a).x).normalized()
				if Geometry2D.is_point_in_polygon(q + n * 0.3, poly):
					n = -n
				if _faces_street(ctx, a, b, n):
					best_d = d
					best = [q, n]
		if best.is_empty():
			continue
		var at: Vector2 = best[0]
		var out: Vector2 = best[1]
		var crowded := false
		for other: Vector2 in placed:
			if other.distance_to(at) < 3.2:
				crowded = true
				break
		if crowded:
			continue
		placed.append(at)
		var sign := Label3D.new()
		sign.text = ("ECZANE\n" + label_text) if kind == "pharmacy" else label_text
		sign.font_size = 44
		sign.pixel_size = 0.0055
		sign.outline_size = 10
		sign.outline_modulate = Color(0, 0, 0, 0.85)
		sign.modulate = SIGN_COLOURS.get(kind, Color("f4f1ea"))
		sign.width = 520.0
		sign.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		sign.position = Vector3(at.x + out.x * 0.15, 3.3, at.y + out.y * 0.15)  # above the awnings
		sign.rotation.y = atan2(out.x, out.y)  # Label3D reads towards +Z
		set_range(sign, 45.0)
		holder.add_child(sign)


## Blue Istanbul street name plates on a pole at junctions of named streets.
static func _street_signs(ctx: StreetLayout, vis: Node3D) -> void:
	# Which named streets meet at each junction node, and in which direction.
	var meets := {}
	for road in ctx.zone.roads:
		var road_name := str(road.get("name", ""))
		if road_name == "":
			continue
		var pts := WorldBuilder.footprint_xz(road.points)
		for i in pts.size():
			var key := Vector2i(roundi(pts[i].x * 10), roundi(pts[i].y * 10))
			if not ctx.junctions.has(key):
				continue
			var nb := pts[i + 1] if i + 1 < pts.size() else pts[i - 1]
			if not meets.has(key):
				meets[key] = {}
			meets[key][road_name] = (nb - pts[i]).normalized()
	var m := MeshMerger.new()
	var holder := Node3D.new()
	holder.name = "StreetSigns"
	vis.add_child(holder)
	var any := false
	for key in meets:
		var names: Dictionary = meets[key]
		if names.size() < 2:
			continue
		var j := Vector2(key.x / 10.0, key.y / 10.0)
		var reach: float = ctx.junctions[key] + 0.6
		# The corner between the first two streets, if it is clear.
		var dirs: Array = names.values()
		var corner := ((dirs[0] as Vector2) + (dirs[1] as Vector2)).normalized()
		if corner == Vector2.ZERO:
			corner = Vector2(-(dirs[0] as Vector2).y, (dirs[0] as Vector2).x)
		var pole := j + corner * reach * 1.25
		if ctx.building_clearance(pole) < 0.4 or ctx.near_track(pole, 2.5) or not ctx.inside_zone(pole, 3.0):
			pole = j - corner * reach * 1.25
			if ctx.building_clearance(pole) < 0.4 or ctx.near_track(pole, 2.5) or not ctx.inside_zone(pole, 3.0):
				continue
		any = true
		var base := Vector3(pole.x, 0.0, pole.y)
		m.box("s", Vector3(0.06, 2.9, 0.06), base + Vector3(0, 1.45, 0), Color("3b3f44"))
		var level := 0
		for street_name in names:
			if level >= 2:
				break
			var along: Vector2 = names[street_name]
			var yaw := atan2(along.x, along.y) + PI / 2.0  # plate runs along its street
			var basis := Basis(Vector3.UP, yaw)
			var y := 2.7 - level * 0.34
			m.box("s", Vector3(1.15, 0.28, 0.03), base + Vector3(0, y, 0), Color("1f4fa3"), basis)
			m.box("s", Vector3(1.19, 0.32, 0.02), base + Vector3(0, y, 0), Color("f2f2f2"), basis)
			for face: float in [1.0, -1.0]:
				var text := Label3D.new()
				text.text = _short_street(str(street_name))
				text.font_size = 34
				text.pixel_size = 0.0045
				text.outline_size = 0
				text.modulate = Color.WHITE
				text.width = 240.0
				text.autowrap_mode = TextServer.AUTOWRAP_OFF
				text.position = base + Vector3(0, y, 0) + basis * Vector3(0, 0, 0.02 * face)
				text.rotation.y = yaw + (0.0 if face > 0.0 else PI)
				set_range(text, 30.0)
				holder.add_child(text)
			level += 1
	if any:
		m.emit("s", holder, MeshMerger.vertex_colour_material(0.6))


static func _short_street(street_name: String) -> String:
	for word in STREET_WORDS:
		if street_name.ends_with(" " + word):
			return street_name.trim_suffix(word) + STREET_WORDS[word]
	return street_name


# --- buildings -------------------------------------------------------------------------

static func _buildings(ctx: StreetLayout, vis: Node3D) -> void:
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
static func _faces_street(ctx: StreetLayout, p0: Vector2, p1: Vector2, out: Vector2) -> bool:
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

static func _trees(ctx: StreetLayout, vis: Node3D) -> void:
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
		sphere.radial_segments = 8
		sphere.rings = 4
		var arrays := sphere.get_mesh_arrays()
		var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
		var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		for i in idx:
			st.set_color(Color.WHITE)
			st.set_normal(normals[i])
			st.add_vertex(verts[i] + spec[0])
	return st.commit()


## Street lamps (placed by StreetLayout). Returns lamp head positions
## for the night lights near the camera.
static func _lamps(ctx: StreetLayout, vis: Node3D) -> PackedVector3Array:
	var heads := PackedVector3Array()
	var pole_xf := []
	var head_xf := []
	for l in ctx.lamps:
		pole_xf.append(Transform3D(Basis(Vector3.UP, float(l.yaw)), l.base))
		head_xf.append(Transform3D(Basis(Vector3.UP, float(l.yaw)), l.head))
		heads.append(l.head)
	var pole_mesh := _lamp_pole_mesh()
	_multimesh(vis, pole_mesh, CityMaterials.solid(Color("3d4247"), 0.45, 0.6), pole_xf, [], 200.0, "LampPoles")
	var head_mesh := BoxMesh.new()
	head_mesh.size = Vector3(0.28, 0.14, 0.55)
	_multimesh(vis, head_mesh, CityMaterials.get_shader("lamp_head"), head_xf, [], 400.0, "LampHeads")
	return heads


## Parked cars: one shared model, body colour per instance.
static func _cars(ctx: StreetLayout, vis: Node3D) -> void:
	if ctx.cars.is_empty():
		return
	var xfs := []
	var cols := []
	var sign_xfs := []
	for c in ctx.cars:
		var xf := Transform3D(Basis(Vector3.UP, float(c.yaw)), c.pos)
		xfs.append(xf)
		cols.append(c.color)
		if c.taxi:
			sign_xfs.append(xf * Transform3D(Basis(), Vector3(0, 1.55, 0.2)))
	_multimesh(vis, _car_mesh(), CityMaterials.instanced(0.35), xfs, cols, 150.0, "ParkedCars")
	if not sign_xfs.is_empty():
		var sign := BoxMesh.new()
		sign.size = Vector3(0.7, 0.18, 0.25)
		_multimesh(vis, sign, CityMaterials.solid(Color("fff2a8"), 0.5), sign_xfs, [], 90.0, "TaxiSigns")


## A small saloon, length along Z (front at -Z). White parts take the
## instance colour; dark parts stay dark.
static func _car_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var size := StreetLayout.CAR_SIZE
	var tyre := Color(0.05, 0.05, 0.05)
	var glass := Color(0.09, 0.11, 0.13)
	_box_into(st, Vector3(size.x, 0.62, size.z), Vector3(0, 0.55, 0), Color.WHITE)  # lower body
	_box_into(st, Vector3(size.x - 0.12, 0.5, size.z * 0.5), Vector3(0, 1.1, 0.2), Color.WHITE)  # cabin
	_box_into(st, Vector3(size.x - 0.08, 0.4, size.z * 0.46), Vector3(0, 1.1, 0.2), glass)  # windows
	_box_into(st, Vector3(size.x - 0.3, 0.06, size.z * 0.5), Vector3(0, 1.37, 0.2), Color.WHITE)  # roof
	for x in [-1.0, 1.0]:
		for z in [-1.3, 1.35]:
			_box_into(st, Vector3(0.22, 0.6, 0.6), Vector3(x * (size.x / 2.0 - 0.1), 0.3, z), tyre)
	_box_into(st, Vector3(size.x - 0.2, 0.12, 0.05), Vector3(0, 0.6, -size.z / 2.0), Color(0.95, 0.93, 0.8))  # headlights
	_box_into(st, Vector3(size.x - 0.2, 0.12, 0.05), Vector3(0, 0.62, size.z / 2.0), Color(0.55, 0.05, 0.05))  # tail lights
	return st.commit()


## Bollards and benches.
static func _street_furniture(ctx: StreetLayout, vis: Node3D) -> void:
	var bollard_xf := []
	for p: Vector3 in ctx.bollards:
		bollard_xf.append(Transform3D(Basis(), p + Vector3(0, StreetLayout.BOLLARD_HEIGHT / 2.0, 0)))
	var bollard := CylinderMesh.new()
	bollard.top_radius = 0.08
	bollard.bottom_radius = 0.11
	bollard.height = StreetLayout.BOLLARD_HEIGHT
	bollard.radial_segments = 8
	_multimesh(vis, bollard, CityMaterials.solid(Color("26292c"), 0.5, 0.4), bollard_xf, [], 90.0, "Bollards")
	var bench_xf := []
	for bench in ctx.benches:
		bench_xf.append(Transform3D(Basis(Vector3.UP, float(bench.yaw)), bench.pos))
	_multimesh(vis, _bench_mesh(), CityMaterials.instanced(0.8), bench_xf, [], 110.0, "Benches")


## Park bench: wooden slats on cast iron legs; faces -Z.
static func _bench_mesh() -> Mesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var wood := Color("7a5334")
	var iron := Color("2b2d2f")
	var s := StreetLayout.BENCH_SIZE
	for x in [-s.x / 2.0 + 0.15, s.x / 2.0 - 0.15]:
		_box_into(st, Vector3(0.06, s.y, s.z), Vector3(x, s.y / 2.0, 0), iron)
		_box_into(st, Vector3(0.06, 0.5, 0.06), Vector3(x, s.y + 0.25, s.z / 2.0 - 0.05), iron)
	for k in 3:
		_box_into(st, Vector3(s.x, 0.04, 0.14), Vector3(0, s.y, -s.z / 2.0 + 0.1 + k * 0.17), wood)
	for k in 2:
		_box_into(st, Vector3(s.x, 0.12, 0.03), Vector3(0, s.y + 0.2 + k * 0.17, s.z / 2.0 - 0.04), wood)
	return st.commit()


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
		set_range(mmi, range_end)
		if node_name in DETAIL_PROPS:
			mmi.add_to_group("detail")
			mmi.visible = GraphicsQuality.detail_props()
		vis.add_child(mmi)


## Visibility range that follows GraphicsQuality (see GameClient.apply_quality).
static func set_range(gi: GeometryInstance3D, base: float) -> void:
	gi.set_meta("range", base)
	gi.add_to_group("ranged")
	gi.visibility_range_end = base * GraphicsQuality.range_scale()
	gi.visibility_range_end_margin = 10.0


static func _box(parent: Node3D, size: Vector3, pos: Vector3, mat: Material) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = mat
	parent.add_child(mi)
	return mi
