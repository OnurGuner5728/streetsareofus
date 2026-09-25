class_name MeshMerger
extends RefCounted
## Collects many small primitives (boxes, capsules, spheres...) into one mesh
## per group, coloured through vertex colours. A tram, a stop or an avatar
## limb becomes one draw call instead of dozens, which is what phones need.

static var _arrays_cache := {}
static var _materials := {}

var _groups := {}  # group -> SurfaceTool


func add(group: String, mesh: PrimitiveMesh, xf: Transform3D, color: Color) -> void:
	var st: SurfaceTool = _groups.get(group)
	if st == null:
		st = SurfaceTool.new()
		st.begin(Mesh.PRIMITIVE_TRIANGLES)
		_groups[group] = st
	var arrays := _arrays(mesh)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var normals: PackedVector3Array = arrays[Mesh.ARRAY_NORMAL]
	var idx: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
	var nb := xf.basis.inverse().transposed()
	for i in idx:
		st.set_color(color)
		st.set_normal((nb * normals[i]).normalized())
		st.add_vertex(xf * verts[i])


func box(group: String, size: Vector3, pos: Vector3, color: Color, basis := Basis()) -> void:
	var m := BoxMesh.new()
	m.size = size
	add(group, m, Transform3D(basis, pos), color)


func capsule(group: String, radius: float, height: float, pos: Vector3, color: Color, scale := Vector3.ONE, segments := 10) -> void:
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = maxf(height, radius * 2.0)
	m.radial_segments = segments
	m.rings = 3 if segments >= 8 else 1
	add(group, m, Transform3D(Basis().scaled(scale), pos), color)


func sphere(group: String, radius: float, pos: Vector3, color: Color, scale := Vector3.ONE, segments := 12) -> void:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = segments
	m.rings = maxi(3, segments / 2)
	add(group, m, Transform3D(Basis().scaled(scale), pos), color)


func cylinder(group: String, top: float, bottom: float, height: float, xf: Transform3D, color: Color) -> void:
	var m := CylinderMesh.new()
	m.top_radius = top
	m.bottom_radius = bottom
	m.height = height
	m.radial_segments = 10
	add(group, m, xf, color)


func groups() -> Array:
	return _groups.keys()


func has(group: String) -> bool:
	return _groups.has(group)


## Commits one group into a mesh (for MultiMesh and the like).
func commit(group: String) -> ArrayMesh:
	var st: SurfaceTool = _groups.get(group)
	_groups.erase(group)
	return st.commit() if st else ArrayMesh.new()


## Commits one group into a MeshInstance3D under parent (vertex colour
## material unless another is given).
func emit(group: String, parent: Node3D, material: Material = null) -> MeshInstance3D:
	if not _groups.has(group):
		return null
	var mi := MeshInstance3D.new()
	mi.name = group
	mi.mesh = (_groups[group] as SurfaceTool).commit()
	mi.material_override = material if material else vertex_colour_material()
	parent.add_child(mi)
	_groups.erase(group)
	return mi


static func vertex_colour_material(roughness := 0.7, metallic := 0.0) -> StandardMaterial3D:
	var key := "%.2f/%.2f" % [roughness, metallic]
	if not _materials.has(key):
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = roughness
		m.metallic = metallic
		_materials[key] = m
	return _materials[key]


static func _arrays(mesh: PrimitiveMesh) -> Array:
	var key := "%s/%s" % [mesh.get_class(), var_to_str(_shape_key(mesh))]
	if not _arrays_cache.has(key):
		_arrays_cache[key] = mesh.get_mesh_arrays()
	return _arrays_cache[key]


static func _shape_key(mesh: PrimitiveMesh) -> Array:
	if mesh is BoxMesh:
		return [(mesh as BoxMesh).size]
	if mesh is CapsuleMesh:
		var c := mesh as CapsuleMesh
		return [c.radius, c.height, c.radial_segments, c.rings]
	if mesh is SphereMesh:
		var sp := mesh as SphereMesh
		return [sp.radius, sp.height, sp.radial_segments, sp.rings, sp.is_hemisphere]
	if mesh is CylinderMesh:
		var c := mesh as CylinderMesh
		return [c.top_radius, c.bottom_radius, c.height]
	return [mesh.get_instance_id()]
