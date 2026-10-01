class_name HopscotchView
extends Node3D
## Chalk seksek grids drawn on the ground: flat strips draped over the terrain
## (decal-like, no collision) plus flat numbers. The grids themselves come from
## Hopscotch.for_zone, the same list the server judges against, so nothing is
## sent over the network.

const CHALK_WIDTH := 0.07
const LIFT := 0.12  # above road/area surfaces (they sit 0.04-0.105 over the terrain)
const PIECE := 0.4  # strips are cut into pieces this long to follow the ground
const VIEW_RANGE := 170.0

var hopscotch: Hopscotch
var _zone: ZoneData


func setup(zone: ZoneData) -> void:
	_zone = zone
	hopscotch = Hopscotch.for_zone(zone)
	for grid: Dictionary in hopscotch.grids:
		_build(grid)


## Every chalk line of one grid as [from, to] pairs in grid-local coordinates.
static func chalk_lines() -> Array:
	var lines := []
	var q := Hopscotch.SQ
	# The start box: a line across the start strip's far side and its two sides.
	lines.append([Vector2(-q, -Hopscotch.START_DEPTH), Vector2(q, -Hopscotch.START_DEPTH)])
	lines.append([Vector2(-q, -Hopscotch.START_DEPTH), Vector2(-q, 0.0)])
	lines.append([Vector2(q, -Hopscotch.START_DEPTH), Vector2(q, 0.0)])
	lines.append([Vector2(-q, 0.0), Vector2(q, 0.0)])
	for r in Hopscotch.ROWS.size():
		var half := q * float(Hopscotch.ROWS[r]) / 2.0
		var v0 := r * q
		var v1 := (r + 1) * q
		lines.append([Vector2(-half, v1), Vector2(half, v1)])
		lines.append([Vector2(-half, v0), Vector2(-half, v1)])
		lines.append([Vector2(half, v0), Vector2(half, v1)])
		if int(Hopscotch.ROWS[r]) == 2:
			lines.append([Vector2(0.0, v0), Vector2(0.0, v1)])
		if r == 0:
			lines.append([Vector2(-half, v0), Vector2(half, v0)])
	return lines


func _build(grid: Dictionary) -> void:
	var verts := PackedVector3Array()
	var normals := PackedVector3Array()
	var indices := PackedInt32Array()
	for line: Array in chalk_lines():
		_strip(grid, line[0], line[1], verts, normals, indices)
	var mesh := ArrayMesh.new()
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = normals
	arrays[Mesh.ARRAY_INDEX] = indices
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = Color(0.96, 0.96, 0.92)
	mat.roughness = 1.0
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var chalk := MeshInstance3D.new()
	chalk.name = "Seksek%d" % int(grid.id)
	chalk.mesh = mesh
	chalk.material_override = mat
	chalk.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	chalk.visibility_range_end = VIEW_RANGE
	add_child(chalk)
	for sq in range(1, Hopscotch.square_count() + 1):
		_number(grid, str(sq), Hopscotch.square_centre(sq), 0.5)
	_number(grid, "BAŞLA", Hopscotch.square_centre(Hopscotch.START), 0.36)


func _strip(grid: Dictionary, a: Vector2, b: Vector2, verts: PackedVector3Array,
		normals: PackedVector3Array, indices: PackedInt32Array) -> void:
	var length := a.distance_to(b)
	var pieces := maxi(1, ceili(length / PIECE))
	var dir := (b - a) / length
	var side := Vector2(-dir.y, dir.x) * CHALK_WIDTH / 2.0
	var base := verts.size()
	for i in pieces + 1:
		var c := a.lerp(b, float(i) / pieces)
		for off in [-side, side]:
			var w := Hopscotch.to_world(grid, c + off)
			verts.append(Vector3(w.x, _zone.terrain.height(w.x, w.y) + LIFT, w.y))
			normals.append(Vector3.UP)
	for i in pieces:
		var k := base + i * 2
		indices.append_array([k, k + 1, k + 2, k + 1, k + 3, k + 2])


## A flat number lying on the ground, readable from the start line.
func _number(grid: Dictionary, text: String, local: Vector2, size_m: float) -> void:
	var w := Hopscotch.to_world(grid, local)
	var label := Label3D.new()
	label.text = text
	label.font_size = 96
	label.pixel_size = size_m / 96.0
	label.outline_size = 0
	label.modulate = Color(0.96, 0.96, 0.92, 0.9)
	label.shaded = false
	label.double_sided = true
	label.no_depth_test = false
	label.visibility_range_end = 60.0
	label.basis = Basis(Vector3.UP, float(grid.yaw)) * Basis(Vector3.RIGHT, -PI / 2.0)
	label.position = Vector3(w.x, _zone.terrain.height(w.x, w.y) + LIFT + 0.01, w.y)
	add_child(label)
