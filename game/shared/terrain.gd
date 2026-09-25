class_name Terrain
extends RefCounted
## Ground height over a zone (zone.json "terrain", from a real DEM): a grid of
## samples whose cells are each split into two triangles along the north-west
## to south-east diagonal. height() follows exactly those triangles, so the
## ground collider, the ground mesh and everything placed with height()
## agree to the millimetre. Zones without elevation are flat at 0.
##
## Coordinates are Godot's (x east, z south); grid row 0 is the north edge.

var flat := true
var size := 2
var spacing := 1.0
var half := 256.0
var base_m := 0.0  # metres above sea level of height 0
var heights := PackedFloat32Array()
var low := 0.0
var high := 0.0


static func from_zone(data: Variant, zone_half: float) -> Terrain:
	var t := Terrain.new()
	t.half = zone_half
	if typeof(data) != TYPE_DICTIONARY or str(data.get("type", "")) != "grid":
		return t
	var n := int(data.get("size", 0))
	var hs: Array = data.get("heights_cm", [])
	if n < 2 or hs.size() != n * n:
		push_error("terrain: grid size %d does not match %d samples, using flat ground" % [n, hs.size()])
		return t
	t.size = n
	t.spacing = float(data.get("spacing_m", 8.0))
	t.base_m = float(data.get("base_m", 0.0))
	t.heights.resize(hs.size())
	t.low = INF
	t.high = -INF
	for i in hs.size():
		var h := float(hs[i]) / 100.0
		t.heights[i] = h
		t.low = minf(t.low, h)
		t.high = maxf(t.high, h)
	t.flat = false
	return t


## Ground height at Godot (x, z); edges extend flat beyond the grid.
func height(x: float, z: float) -> float:
	if flat:
		return 0.0
	var fx := clampf((x + half) / spacing, 0.0, size - 1.0001)
	var fz := clampf((z + half) / spacing, 0.0, size - 1.0001)
	var i := int(fx)
	var j := int(fz)
	var u := fx - i
	var v := fz - j
	var k := j * size + i
	var h00 := heights[k]
	var h11 := heights[k + size + 1]
	if u >= v:
		var h10 := heights[k + 1]
		return h00 + (h10 - h00) * u + (h11 - h10) * v
	var h01 := heights[k + size]
	return h00 + (h11 - h01) * u + (h01 - h00) * v


## Height at an east/north point.
func height_en(p: Vector2) -> float:
	return height(p.x, -p.y)


## A point on the ground (Godot space) for an XZ position, lifted by `lift`.
func on_ground(xz: Vector2, lift := 0.0) -> Vector3:
	return Vector3(xz.x, height(xz.x, xz.y) + lift, xz.y)


## Upward surface normal (finite differences over half a metre).
func normal(x: float, z: float) -> Vector3:
	if flat:
		return Vector3.UP
	var dx := height(x + 0.5, z) - height(x - 0.5, z)
	var dz := height(x, z + 0.5) - height(x, z - 0.5)
	return Vector3(-dx, 1.0, -dz).normalized()


## Orientation for something resting on the slope (a parked car), facing
## `yaw` (its -Z) and tilted with the ground under it.
func resting_basis(pos: Vector3, yaw: float) -> Basis:
	var up := normal(pos.x, pos.z)
	var forward := Basis(Vector3.UP, yaw) * Vector3.FORWARD
	forward = (forward - up * forward.dot(up)).normalized()
	return Basis(up.cross(-forward), up, -forward)


## Lowest ground under a footprint (XZ polygon): where a building's floors
## are counted from; its walls continue down into the slope below that.
func ground_under(poly: PackedVector2Array) -> float:
	if flat or poly.is_empty():
		return 0.0
	var best := INF
	var centre := Vector2.ZERO
	for p in poly:
		best = minf(best, height(p.x, p.y))
		centre += p
	return minf(best, height(centre.x / poly.size(), centre.y / poly.size()))


## Ground triangles (Godot space) covering the grid, two per cell, in the
## same split as height(); for colliders and the ground mesh.
func triangles() -> PackedVector3Array:
	var out := PackedVector3Array()
	var n := size if not flat else 2
	var step := spacing if not flat else half * 2.0
	for j in n - 1:
		for i in n - 1:
			var p00 := _vertex(i, j, step)
			var p10 := _vertex(i + 1, j, step)
			var p01 := _vertex(i, j + 1, step)
			var p11 := _vertex(i + 1, j + 1, step)
			out.append_array([p00, p10, p11, p00, p11, p01])
	return out


func _vertex(i: int, j: int, step: float) -> Vector3:
	var h := 0.0 if flat else heights[j * size + i]
	return Vector3(-half + i * step, h, -half + j * step)
