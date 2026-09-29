class_name Coast
extends RefCounted
## A zone's real coastline (zone.json "coast", from world-pipeline/zonegen/coast.py):
## the sea surface height, land polygons, classified shore runs, piers and
## ferry terminals. Coordinates are Godot XZ (x east, z south), converted
## from the pipeline's east/north metres once on load.

var sea_level := -1.6
var shore_height_m := 1.6
var land: Array = []  # Array[PackedVector2Array]
var shore: Array = []  # [{kind: "quay"|"rocks"|"beach", points: PackedVector2Array}, ...]
var piers: Array = []  # [{id, closed, points, width?, name?}, ...]
var ferry_terminals: Array = []  # [{name, pos: Vector2}, ...]

# A rasterised land mask (mirrors world-pipeline/zonegen/coast.py's LandMask):
# is_land() is called once per terrain grid vertex and every frame for wave
# sound, so a per-call point-in-polygon test over every land ring would be
# far too slow on a real, many-kilometre coastline.
const MASK_CELL := 3.0
var _mask_half := 0.0
var _mask_n := 0
var _mask_rows: Array = []  # Array[PackedByteArray]


static func from_zone(data: Variant) -> Coast:
	if typeof(data) != TYPE_DICTIONARY:
		return null
	var c := Coast.new()
	c.sea_level = float(data.get("sea_level", -1.6))
	c.shore_height_m = float(data.get("shore_height_m", 1.6))
	for poly in data.get("land", []):
		c.land.append(_xz(poly))
	for run in data.get("shore", []):
		c.shore.append({"kind": str(run.get("kind", "rocks")), "points": _xz(run.points)})
	for pier in data.get("piers", []):
		var p := {"id": str(pier.get("id", "")), "closed": bool(pier.get("closed", false)), "points": _xz(pier.points)}
		if pier.has("width"):
			p.width = float(pier.width)
		if pier.has("name"):
			p.name = str(pier.name)
		c.piers.append(p)
	for f in data.get("ferry_terminals", []):
		c.ferry_terminals.append({"name": str(f.get("name", "")), "pos": Vector2(float(f.e), -float(f.n))})
	c._build_mask()
	return c


## Zone east/north points -> Godot XZ (x east, z south).
static func _xz(points: Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		out.append(Vector2(float(p[0]), -float(p[1])))
	return out


## Rasterises `land` into a square grid of `MASK_CELL`-metre cells, sized to
## the land polygons' own extent (they are already clipped to the zone
## square by the pipeline, so this matches the zone almost exactly).
func _build_mask() -> void:
	var half := 1.0
	var edges := []  # [[a: Vector2, b: Vector2], ...]
	for poly in land:
		for i in poly.size():
			var a: Vector2 = poly[i]
			var b: Vector2 = poly[(i + 1) % poly.size()]
			half = maxf(half, maxf(absf(a.x), absf(a.y)))
			edges.append([a, b])
	if edges.is_empty():
		return
	_mask_half = half + MASK_CELL
	_mask_n = maxi(1, int(ceil(2.0 * _mask_half / MASK_CELL)))
	_mask_rows.resize(_mask_n)
	for j in _mask_n:
		var y := -_mask_half + (j + 0.5) * MASK_CELL
		var xs := PackedFloat32Array()
		for e in edges:
			var a: Vector2 = e[0]
			var b: Vector2 = e[1]
			if (a.y > y) != (b.y > y):
				xs.append(a.x + (y - a.y) * (b.x - a.x) / (b.y - a.y))
		xs.sort()
		var row := PackedByteArray()
		row.resize(_mask_n)
		var k := 0
		while k + 1 < xs.size():
			var i0 := maxi(0, int(ceil((xs[k] + _mask_half) / MASK_CELL - 0.5)))
			var i1 := mini(_mask_n - 1, int(floor((xs[k + 1] + _mask_half) / MASK_CELL - 0.5)))
			for i in range(i0, i1 + 1):
				row[i] = 1
			k += 2
		_mask_rows[j] = row


## True if `p` (Godot XZ) lies inside any land polygon.
func is_land(p: Vector2) -> bool:
	if _mask_n > 0:
		var i := int((p.x + _mask_half) / MASK_CELL)
		var j := int((p.y + _mask_half) / MASK_CELL)
		if i < 0 or j < 0 or i >= _mask_n or j >= _mask_n:
			return true  # outside the rasterised area: not our sea
		return bool((_mask_rows[j] as PackedByteArray)[i])
	for poly in land:
		if Geometry2D.is_point_in_polygon(p, poly):
			return true
	return false


## Distance from `p` (Godot XZ) to the nearest shore line, for wave sound
## and effect falloff. INF if the zone has no shore runs.
func distance_to_shore(p: Vector2) -> float:
	var best := INF
	for run in shore:
		var pts: PackedVector2Array = run.points
		for i in pts.size() - 1:
			best = minf(best, p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])))
	return best
