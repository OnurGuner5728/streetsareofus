class_name RoofBuilder
extends RefCounted
## Geometry of pitched roofs, domes, minarets, towers and chimneys, emitted
## into the SurfaceTools CityVisuals merges a whole 128 m chunk into (walls
## for WALLS-shaded surfaces, roofs for ROOF-shaded ones). Pitched roofs are
## laid over the footprint's bounding rectangle (BuildingStyle.obb) in its
## local frame: `u` along the long side, `v` across, heights above the wall
## top. Roof planes are exact over the rectangle; the wall tops follow them
## (wall_top), so gable ends and slightly irregular footprints stay closed.

## Eaves stick out this far at the long sides and hips, gable ends less.
const EAVE := 0.42
const RAKE := 0.22
## Thickness of the roof edge (fascia) and the soffit below the overhang.
const THICKNESS := 0.14
const SOFFIT := "e6dfd2"
const FASCIA := "d9d1c3"


# --- pitched roofs ----------------------------------------------------------

## Height of the roof plane above the wall top at local (u, v); negative
## where the eaves hang past the walls.
static func height_at(shape: String, hl: float, hw: float, rise: float, u: float, v: float) -> float:
	var s := rise / hw
	if shape == BuildingStyle.GABLED:
		return s * (hw - absf(v))
	if shape == BuildingStyle.HIPPED:
		return s * minf(hw - absf(v), hl - absf(u))
	return 0.0


## Convex facets tiling the walls' rectangle grown by `over` (sides) and
## `over_end` (ends), as local-frame polygons. Hipped roofs need
## over_end == over so the hip lines end in the corners.
static func facets(shape: String, hl: float, hw: float, over: float, over_end: float) -> Array:
	var el := hl + over_end
	var ew := hw + over
	var out := []
	if shape == BuildingStyle.GABLED:
		out.append(PackedVector2Array([Vector2(-el, 0), Vector2(el, 0), Vector2(el, ew), Vector2(-el, ew)]))
		out.append(PackedVector2Array([Vector2(-el, -ew), Vector2(el, -ew), Vector2(el, 0), Vector2(-el, 0)]))
		return out
	var d := maxf(hl - hw, 0.0)
	var front := [Vector2(-el, ew), Vector2(el, ew), Vector2(d, 0), Vector2(-d, 0)]
	var back := [Vector2(-el, -ew), Vector2(el, -ew), Vector2(d, 0), Vector2(-d, 0)]
	for ring in [front, back]:
		var poly := PackedVector2Array()
		for q: Vector2 in ring:
			if poly.is_empty() or poly[poly.size() - 1].distance_to(q) > 0.01:
				poly.append(q)
		out.append(poly)
	out.append(PackedVector2Array([Vector2(el, ew), Vector2(el, -ew), Vector2(d, 0)]))
	out.append(PackedVector2Array([Vector2(-el, -ew), Vector2(-el, ew), Vector2(-d, 0)]))
	return out


## [[t, height above the wall top], ...] along the wall edge p0 -> p1 at every
## point where the roof height changes slope, so the wall can reach the roof.
static func wall_top(p0: Vector2, p1: Vector2, box: Dictionary, shape: String, rise: float) -> Array:
	var hl: float = box.hl
	var hw: float = box.hw
	var c: Vector2 = box.c
	var u: Vector2 = box.u
	var v: Vector2 = box.v
	var a := Vector2((p0 - c).dot(u), (p0 - c).dot(v))
	var b := Vector2((p1 - c).dot(u), (p1 - c).dot(v))
	var ts := [0.0, 1.0]
	if absf(b.y - a.y) > 1e-6:
		ts.append(-a.y / (b.y - a.y))
	if shape == BuildingStyle.HIPPED:
		var d := hl - hw
		for su in [-1.0, 1.0]:
			for sv in [-1.0, 1.0]:
				var f0: float = su * a.x - sv * a.y - d
				var f1: float = su * b.x - sv * b.y - d
				if absf(f1 - f0) > 1e-6:
					ts.append(-f0 / (f1 - f0))
	ts = ts.filter(func(t: float) -> bool: return t >= 0.0 and t <= 1.0)
	ts.sort()
	var out := []
	var last := -1.0
	for t: float in ts:
		if t - last < 0.002:
			continue
		last = t
		var q := a.lerp(b, t)
		out.append([t, maxf(height_at(shape, hl, hw, rise, q.x, q.y), 0.0)])
	return out


## The pitched roof with its eaves: top facets (UV = metres along the eave and
## up the slope, so tile rows follow the eave), the soffit below the overhang
## and the fascia board around the edge. `surface` is a BuildingStyle.SURF_*.
static func emit_pitched(st: SurfaceTool, box: Dictionary, shape: String, rise: float, base_y: float,
		colour: Color, surface: int) -> void:
	var hl: float = box.hl
	var hw: float = box.hw
	var over_end := EAVE if shape == BuildingStyle.HIPPED else RAKE
	var el := hl + over_end
	var ew := hw + EAVE
	var top := colour
	top.a = BuildingStyle.roof_alpha(surface)
	var soffit := Color(SOFFIT)
	soffit.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_PLASTER)
	var fascia := Color(FASCIA)
	fascia.a = soffit.a
	for poly: PackedVector2Array in facets(shape, hl, hw, EAVE, over_end):
		var pts := []
		var under := []
		for q in poly:
			var p := _lift(box, q, shape, hl, hw, rise, base_y)
			pts.append(p)
			under.append(p - Vector3(0, THICKNESS, 0))
		var n := _facet_normal(pts)
		add_poly(st, pts, n, top, true)
		add_poly(st, under, -n, soffit, false)
		# Fascia along the edges on the rectangle's outline.
		for i in poly.size():
			var q0 := poly[i]
			var q1 := poly[(i + 1) % poly.size()]
			var out := Vector2.ZERO
			if is_equal_approx(q0.y, ew) and is_equal_approx(q1.y, ew):
				out = Vector2(0, 1)
			elif is_equal_approx(q0.y, -ew) and is_equal_approx(q1.y, -ew):
				out = Vector2(0, -1)
			elif is_equal_approx(q0.x, el) and is_equal_approx(q1.x, el):
				out = Vector2(1, 0)
			elif is_equal_approx(q0.x, -el) and is_equal_approx(q1.x, -el):
				out = Vector2(-1, 0)
			if out == Vector2.ZERO:
				continue
			var a: Vector3 = pts[i]
			var b: Vector3 = pts[(i + 1) % poly.size()]
			var w := (box.u as Vector2) * out.x + (box.v as Vector2) * out.y
			add_poly(st, [a, b, b - Vector3(0, THICKNESS, 0), a - Vector3(0, THICKNESS, 0)], Vector3(w.x, 0, w.y), fascia, false)


## Chimney at local (u, v): a brick stack standing on the roof plane.
static func emit_chimney(st: SurfaceTool, box: Dictionary, shape: String, rise: float, base_y: float,
		at: Vector2, brick: Color) -> void:
	var hl: float = box.hl
	var hw: float = box.hw
	var low := INF
	var high := -INF
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			var h := height_at(shape, hl, hw, rise, at.x + sx * 0.3, at.y + sz * 0.3)
			low = minf(low, h)
			high = maxf(high, h)
	var y0 := base_y + low - 0.25
	var y1 := base_y + high + 0.95
	var col := brick
	col.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_BRICK)
	var cap := Color("8d8b86")
	cap.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_FLAT)
	add_box(st, BuildingStyle.to_world(box, at), box.u, Vector2(0.55, 0.55), y0, y1, col, cap)
	add_box(st, BuildingStyle.to_world(box, at), box.u, Vector2(0.75, 0.75), y1, y1 + 0.1, cap, cap)


static func _lift(box: Dictionary, q: Vector2, shape: String, hl: float, hw: float, rise: float, base_y: float) -> Vector3:
	var w := BuildingStyle.to_world(box, q)
	return Vector3(w.x, base_y + height_at(shape, hl, hw, rise, q.x, q.y), w.y)


static func _facet_normal(pts: Array) -> Vector3:
	var n := ((pts[1] - pts[0]) as Vector3).cross((pts[2] - pts[0]) as Vector3)
	n = n.normalized()
	return n if n.y > 0.0 else -n


# --- generic pieces ---------------------------------------------------------

## A convex polygon in 3D facing `n`. `uv` projects it on the plane it lies in
## (U along the horizontal, V along the steepest line up), starting at 0 at the
## lowest / leftmost point, so a tile or brick texture lines up with the eave.
static func add_poly(st: SurfaceTool, pts: Array, n: Vector3, col: Color, uv: bool) -> void:
	var t := Vector3.UP.cross(n)
	if t.length() < 0.01:
		t = Vector3.RIGHT
	t = t.normalized()
	var b := n.cross(t)
	var lo := Vector2(INF, INF)
	var coords := []
	for p: Vector3 in pts:
		var q := Vector2(p.dot(t), p.dot(b))
		coords.append(q)
		lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
	for k in range(1, pts.size() - 1):
		var uvs := PackedVector2Array()
		if uv:
			uvs = PackedVector2Array([(coords[0] as Vector2) - lo, (coords[k] as Vector2) - lo, (coords[k + 1] as Vector2) - lo])
		WorldBuilder._add_tri(st, pts[0], pts[k], pts[k + 1], n, col, uvs)


## An upright box (yaw given by axis `u`, footprint `size` along u then v) with
## faces in `side` colour and a `top` face, from y0 to y1. No bottom.
static func add_box(st: SurfaceTool, at: Vector2, u: Vector2, size: Vector2, y0: float, y1: float,
		side: Color, top: Color) -> void:
	var v := Vector2(-u.y, u.x)
	var hx := u * (size.x / 2.0)
	var hz := v * (size.y / 2.0)
	var c := [at - hx - hz, at + hx - hz, at + hx + hz, at - hx + hz]
	for i in 4:
		var a: Vector2 = c[i]
		var b: Vector2 = c[(i + 1) % 4]
		var out := (a + b) / 2.0 - at
		var n2 := out.normalized()
		add_poly(st, [Vector3(a.x, y0, a.y), Vector3(b.x, y0, b.y), Vector3(b.x, y1, b.y), Vector3(a.x, y1, a.y)],
			Vector3(n2.x, 0, n2.y), side, true)
	add_poly(st, [Vector3(c[0].x, y1, c[0].y), Vector3(c[1].x, y1, c[1].y), Vector3(c[2].x, y1, c[2].y),
		Vector3(c[3].x, y1, c[3].y)], Vector3.UP, top, false)


## A plastered stair house: walls in the WALLS surface (windowless, see the
## shader's bay test), a flat roof in the ROOF surface.
static func emit_block(walls: SurfaceTool, roofs: SurfaceTool, at: Vector2, u: Vector2, size: Vector2, y0: float,
		y1: float, wall: Color, roof: Color, wall_base: float, info_top: float) -> void:
	var v := Vector2(-u.y, u.x)
	var hx := u * (size.x / 2.0)
	var hz := v * (size.y / 2.0)
	var c := [at - hx - hz, at + hx - hz, at + hx + hz, at - hx + hz]
	for i in 4:
		var a: Vector2 = c[i]
		var b: Vector2 = c[(i + 1) % 4]
		var e := b - a
		var len := e.length()
		var n := Vector3(-e.y, 0.0, e.x).normalized()
		var a0 := Vector3(a.x, y0, a.y)
		var a1 := Vector3(a.x, y1, a.y)
		var b0 := Vector3(b.x, y0, b.y)
		var b1 := Vector3(b.x, y1, b.y)
		var info := Vector2(info_top, len)
		var ry0 := y0 - wall_base
		var ry1 := y1 - wall_base
		WorldBuilder._add_tri(walls, a0, b1, b0, n, wall, PackedVector2Array([Vector2(0, ry0), Vector2(len, ry1), Vector2(len, ry0)]), info)
		WorldBuilder._add_tri(walls, a0, a1, b1, n, wall, PackedVector2Array([Vector2(0, ry0), Vector2(0, ry1), Vector2(len, ry1)]), info)
	var top := roof
	top.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_FLAT)
	add_poly(roofs, [Vector3(c[0].x, y1, c[0].y), Vector3(c[1].x, y1, c[1].y), Vector3(c[2].x, y1, c[2].y),
		Vector3(c[3].x, y1, c[3].y)], Vector3.UP, top, false)


# --- domes, minarets, towers ----------------------------------------------------

## A smooth dome on a short drum: drum and dome in the ROOF surface.
static func emit_dome(st: SurfaceTool, at: Vector2, radius: float, y0: float, drum: Color, dome: Color,
		segments := 16, rings := 5) -> void:
	var drum_h := 0.9 + radius * 0.25
	var dc := drum
	dc.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_PLASTER)
	var mc := dome
	mc.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_METAL)
	var r0 := radius * 0.98
	for i in segments:
		var a0 := TAU * i / segments
		var a1 := TAU * (i + 1) / segments
		var p0 := at + Vector2(cos(a0), sin(a0)) * r0
		var p1 := at + Vector2(cos(a1), sin(a1)) * r0
		var mid := (a0 + a1) / 2.0
		var n := Vector3(cos(mid), 0, sin(mid))
		add_poly(st, [Vector3(p0.x, y0, p0.y), Vector3(p1.x, y0, p1.y), Vector3(p1.x, y0 + drum_h, p1.y),
			Vector3(p0.x, y0 + drum_h, p0.y)], n, dc, true)
	var y_base := y0 + drum_h
	var height := radius * 0.92
	for k in rings:
		var e0 := (PI / 2.0) * k / rings
		var e1 := (PI / 2.0) * (k + 1) / rings
		for i in segments:
			var a0 := TAU * i / segments
			var a1 := TAU * (i + 1) / segments
			var v00 := _dome_point(at, radius, height, y_base, a0, e0)
			var v10 := _dome_point(at, radius, height, y_base, a1, e0)
			var v01 := _dome_point(at, radius, height, y_base, a0, e1)
			var v11 := _dome_point(at, radius, height, y_base, a1, e1)
			var n00 := _dome_normal(radius, height, a0, e0)
			var n10 := _dome_normal(radius, height, a1, e0)
			var n01 := _dome_normal(radius, height, a0, e1)
			var n11 := _dome_normal(radius, height, a1, e1)
			_smooth_tri(st, v00, v11, v10, n00, n11, n10, mc)
			if k < rings - 1:
				_smooth_tri(st, v00, v01, v11, n00, n01, n11, mc)
	# A small gilded finial.
	var gold := Color("c9a94d")
	gold.a = mc.a
	emit_cone(st, at, 0.16, y_base + height - 0.05, 1.5, gold, BuildingStyle.SURF_METAL, 6)


static func _dome_point(at: Vector2, radius: float, height: float, y_base: float, az: float, el: float) -> Vector3:
	return Vector3(at.x + cos(az) * cos(el) * radius, y_base + sin(el) * height, at.y + sin(az) * cos(el) * radius)


static func _dome_normal(radius: float, height: float, az: float, el: float) -> Vector3:
	return Vector3(cos(az) * cos(el) / radius, sin(el) / height, sin(az) * cos(el) / radius).normalized()


static func _smooth_tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, na: Vector3, nb: Vector3, nc: Vector3,
		col: Color) -> void:
	if a.distance_squared_to(b) < 1e-8 or a.distance_squared_to(c) < 1e-8 or b.distance_squared_to(c) < 1e-8:
		return
	var flat := (b - a).cross(c - a)
	var pts := [a, b, c]
	var nrm := [na, nb, nc]
	if flat.dot(na + nb + nc) > 0.0:
		pts = [a, c, b]
		nrm = [na, nc, nb]
	for i in 3:
		st.set_color(col)
		st.set_normal(nrm[i])
		st.set_uv(Vector2.ZERO)
		st.set_uv2(Vector2.ZERO)
		st.add_vertex(pts[i])


## A cone (a spire or a minaret cap), `sides` faces, in the ROOF surface.
static func emit_cone(st: SurfaceTool, at: Vector2, radius: float, y0: float, height: float, colour: Color,
		surface: int, sides := 8) -> void:
	var col := colour
	col.a = BuildingStyle.roof_alpha(surface)
	var tip := Vector3(at.x, y0 + height, at.y)
	var slope := radius / maxf(height, 0.01)
	for i in sides:
		var a0 := TAU * i / sides
		var a1 := TAU * (i + 1) / sides
		var p0 := Vector3(at.x + cos(a0) * radius, y0, at.y + sin(a0) * radius)
		var p1 := Vector3(at.x + cos(a1) * radius, y0, at.y + sin(a1) * radius)
		var mid := (a0 + a1) / 2.0
		var n := Vector3(cos(mid), slope, sin(mid)).normalized()
		add_poly(st, [p0, p1, tip], n, col, true)


## A round or many-sided shaft between two radii in the WALLS surface (no
## windows: `info_top` 0). UV.x is the arc length so the plaster texture runs
## around it.
static func emit_shaft(st: SurfaceTool, at: Vector2, r0: float, r1: float, y0: float, y1: float, sides: int,
		colour: Color, base: float, rotation := 0.0) -> void:
	for i in sides:
		var a0 := TAU * i / sides + rotation
		var a1 := TAU * (i + 1) / sides + rotation
		var p0 := at + Vector2(cos(a0), sin(a0)) * r0
		var p1 := at + Vector2(cos(a1), sin(a1)) * r0
		var q0 := at + Vector2(cos(a0), sin(a0)) * r1
		var q1 := at + Vector2(cos(a1), sin(a1)) * r1
		var mid := (a0 + a1) / 2.0
		var n := Vector3(cos(mid), 0, sin(mid))
		var len := p0.distance_to(p1)
		var u0 := len * i
		var ry0 := y0 - base
		var ry1 := y1 - base
		var info := Vector2(0, len)
		WorldBuilder._add_tri(st, Vector3(p0.x, y0, p0.y), Vector3(q1.x, y1, q1.y), Vector3(p1.x, y0, p1.y), n, colour,
			PackedVector2Array([Vector2(u0, ry0), Vector2(u0 + len, ry1), Vector2(u0 + len, ry0)]), info)
		WorldBuilder._add_tri(st, Vector3(p0.x, y0, p0.y), Vector3(q0.x, y1, q0.y), Vector3(q1.x, y1, q1.y), n, colour,
			PackedVector2Array([Vector2(u0, ry0), Vector2(u0, ry1), Vector2(u0 + len, ry1)]), info)


## A minaret: square foot, round shaft, the serefe balcony, a thinner upper
## shaft and a pointed lead cap. `walls`/`roofs` are the chunk's surfaces.
static func emit_minaret(walls: SurfaceTool, roofs: SurfaceTool, at: Vector2, y0: float, height: float, wall: Color,
		cap: Color, yaw := 0.0) -> void:
	var foot := y0 + height * 0.2
	var balcony := y0 + height * 0.74
	var neck := y0 + height * 0.92
	emit_shaft(walls, at, 1.55, 1.4, y0 - 0.5, foot, 4, wall, y0, PI / 4.0 + yaw)
	emit_shaft(walls, at, 0.85, 0.7, foot, balcony, 12, wall, y0, yaw)
	# Balcony: a wider ring with a shaded underside and a parapet.
	emit_shaft(walls, at, 1.25, 1.25, balcony, balcony + 0.55, 12, wall, y0, yaw)
	var deck := wall
	deck.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_PLASTER)
	var under := deck.darkened(0.15)
	var pts := []
	var pts_top := []
	for i in 12:
		var a := TAU * i / 12 + yaw
		var q := at + Vector2(cos(a), sin(a)) * 1.25
		pts.append(Vector3(q.x, balcony, q.y))
		pts_top.append(Vector3(q.x, balcony + 0.06, q.y))
	add_poly(roofs, pts, Vector3.DOWN, under, false)
	add_poly(roofs, pts_top, Vector3.UP, deck, false)
	emit_shaft(walls, at, 0.66, 0.56, balcony + 0.55, neck, 12, wall, y0, yaw)
	emit_cone(roofs, at, 0.85, neck, height * 0.08 + 0.6, cap, BuildingStyle.SURF_METAL, 12)
	var gold := Color("c9a94d")
	emit_cone(roofs, at, 0.09, y0 + height - 0.9, 1.4, gold, BuildingStyle.SURF_METAL, 6)


## A church bell tower: a windowless square shaft and a slate pyramid spire.
static func emit_tower(walls: SurfaceTool, roofs: SurfaceTool, at: Vector2, u: Vector2, half: float, y0: float,
		height: float, wall: Color, spire: Color) -> void:
	var v := Vector2(-u.y, u.x)
	var top := y0 + height
	var c := [at - u * half - v * half, at + u * half - v * half, at + u * half + v * half, at - u * half + v * half]
	for i in 4:
		var a: Vector2 = c[i]
		var b: Vector2 = c[(i + 1) % 4]
		var e := b - a
		var len := e.length()
		var n := Vector3(-e.y, 0.0, e.x).normalized()
		var info := Vector2(0, len)
		var a0 := Vector3(a.x, y0 - 0.5, a.y)
		var b0 := Vector3(b.x, y0 - 0.5, b.y)
		var a1 := Vector3(a.x, top, a.y)
		var b1 := Vector3(b.x, top, b.y)
		var ry0 := -0.5
		WorldBuilder._add_tri(walls, a0, b1, b0, n, wall, PackedVector2Array([Vector2(0, ry0), Vector2(len, height), Vector2(len, ry0)]), info)
		WorldBuilder._add_tri(walls, a0, a1, b1, n, wall, PackedVector2Array([Vector2(0, ry0), Vector2(0, height), Vector2(len, height)]), info)
	var tip := Vector3(at.x, top + half * 3.2, at.y)
	var col := spire
	col.a = BuildingStyle.roof_alpha(BuildingStyle.SURF_TILES)
	for i in 4:
		var a: Vector2 = c[i]
		var b: Vector2 = c[(i + 1) % 4]
		var pts := [Vector3(a.x, top, a.y), Vector3(b.x, top, b.y), tip]
		var n := ((pts[1] - pts[0]) as Vector3).cross((pts[2] - pts[0]) as Vector3).normalized()
		var mid := Vector3((a.x + b.x) / 2.0 - at.x, 0, (a.y + b.y) / 2.0 - at.y)
		if n.dot(mid) < 0.0:
			n = -n
		add_poly(roofs, pts, n, col, true)
