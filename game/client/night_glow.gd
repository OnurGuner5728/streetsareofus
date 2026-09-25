class_name NightGlow
extends Node3D
## Cheap night lighting that works on every quality level, phones included:
## a warm pool of light on the ground under every street lamp and a soft
## halo around each lamp head. Two MultiMeshes (two draw calls) with additive
## unshaded shaders driven by the global "night" parameter, so they cost
## nothing by day. Real OmniLights (SkyController) are added on top where
## the quality allows.

const POOL_SIZE := 13.0
const HALO_SIZE := 1.5
const LAMP_HEIGHT := 5.75
const WARM := Color(1.0, 0.72, 0.42)

const POOL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
global uniform float night;
uniform vec3 tint : source_color;
uniform float strength = 0.55;
varying float fade;
void vertex() {
	fade = 1.0 - smoothstep(70.0, 130.0, length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz));
}
void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float a = pow(max(0.0, 1.0 - d), 2.2);
	ALBEDO = tint * a * strength * smoothstep(0.2, 0.7, night) * fade;
}
"""

const HALO_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
global uniform float night;
uniform vec3 tint : source_color;
varying float fade;
void vertex() {
	// Billboard: face the camera, keep the instance's position.
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	fade = 1.0 - smoothstep(90.0, 180.0, length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz));
}
void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float core = pow(max(0.0, 1.0 - d), 3.0);
	ALBEDO = tint * (core * 1.6 + pow(max(0.0, 1.0 - d), 8.0) * 2.0) * smoothstep(0.2, 0.7, night) * fade;
}
"""


func build(zone: ZoneData, heads: PackedVector3Array) -> void:
	for child in get_children():
		child.queue_free()
	if heads.is_empty():
		return
	var pools := PackedVector3Array()
	var normals := PackedVector3Array()
	for h in heads:
		var base := Vector2(h.x, h.z)
		var g := zone.terrain.height(base.x, base.y)
		# Tilt with the slope so the pool lies on the street, a little above it.
		var dx := zone.terrain.height(base.x + 2.0, base.y) - zone.terrain.height(base.x - 2.0, base.y)
		var dz := zone.terrain.height(base.x, base.y + 2.0) - zone.terrain.height(base.x, base.y - 2.0)
		pools.append(Vector3(base.x, g + 0.18, base.y))
		normals.append(Vector3(-dx / 4.0, 1.0, -dz / 4.0).normalized())
	var pool_mesh := PlaneMesh.new()
	pool_mesh.size = Vector2(POOL_SIZE, POOL_SIZE)
	add_child(_multi(pool_mesh, POOL_SHADER, pools, normals, "Pools"))
	var halo_mesh := QuadMesh.new()
	halo_mesh.size = Vector2(HALO_SIZE, HALO_SIZE)
	add_child(_multi(halo_mesh, HALO_SHADER, heads, PackedVector3Array(), "Halos"))


static func _multi(mesh: Mesh, code: String, at: PackedVector3Array, ups: PackedVector3Array, node_name: String) -> MultiMeshInstance3D:
	var shader := Shader.new()
	shader.code = code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("tint", WARM)
	mesh.surface_set_material(0, mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = at.size()
	for i in at.size():
		var basis := Basis()
		if not ups.is_empty():
			var up := ups[i]
			var right := up.cross(Vector3.FORWARD).normalized()
			basis = Basis(right, up, right.cross(up).normalized())
		mm.set_instance_transform(i, Transform3D(basis, at[i]))
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	return node
