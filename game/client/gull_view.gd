class_name GullView
extends Node3D
## Draws the gulls of the Gulls timetable as one MultiMesh (wings flap in the
## vertex shader). Calls are decided from the world clock, so everybody hears
## the same gull at the same moment; only the ones close to the camera are
## played.

const CALL_RANGE := 110.0

const SHADER := """
shader_type spatial;
render_mode cull_disabled;
varying vec3 col;
void vertex() {
	// Alpha 0.5: wing vertices. Flap fast when circling a ferry, slow when soaring.
	if (COLOR.a < 0.75 && COLOR.a > 0.25) {
		float t = TIME * INSTANCE_CUSTOM.y + INSTANCE_CUSTOM.x;
		VERTEX.y += abs(VERTEX.x) * sin(t) * 0.55;
	}
	col = COLOR.rgb * COLOR.rgb;
}
void fragment() {
	ALBEDO = col;
	ROUGHNESS = 0.8;
}
"""

var client: GameClient
var gulls: Gulls
var sounds: CitySounds
var sea_level := -1.6
var _multi: MultiMeshInstance3D
var _prev_t := -1.0


func setup(game: GameClient, model: Gulls, sea: float) -> void:
	client = game
	gulls = model
	sea_level = sea
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	var mesh := gull_mesh()
	var shader := Shader.new()
	shader.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mesh.surface_set_material(0, mat)
	mm.mesh = mesh
	mm.instance_count = maxi(model.gulls.size(), 1)
	mm.visible_instance_count = 0
	var span := 1700.0
	mm.custom_aabb = AABB(Vector3(-span, -10.0, -span), Vector3(span * 2.0, 80.0, span * 2.0))
	_multi = MultiMeshInstance3D.new()
	_multi.name = "Gulls"
	_multi.multimesh = mm
	_multi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_multi)
	for g: Gulls.Gull in model.gulls:
		var flap := 7.0 if g.kind == "ferry" else 3.5
		mm.set_instance_custom_data(g.id, Color(g.phase * 3.0, flap + 2.0 * Traffic.h01("gullflap:%d" % g.id), 0, 0))


func update(t: float, me: Vector3) -> void:
	var mm := _multi.multimesh
	var want := mini(GraphicsQuality.gull_count(), gulls.gulls.size())
	var n := 0
	for i in want:
		var g: Gulls.Gull = gulls.gulls[i]
		gulls.place(g, t)
		if not g.visible:
			continue
		var pos := Vector3(g.pos.x, sea_level + g.pos.y, g.pos.z)
		var yaw := atan2(-g.dir.x, -g.dir.y)
		# A herring gull spans about 1.4 m; the model is a little smaller.
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, -g.bank) * Basis.from_scale(Vector3.ONE * 1.35)
		mm.set_instance_transform(n, Transform3D(basis, pos))
		# Keep the per-gull custom data (phase, flap speed) with its slot.
		var flap := 7.0 if g.kind == "ferry" else 3.5
		mm.set_instance_custom_data(n, Color(g.phase * 3.0, flap + 2.0 * Traffic.h01("gullflap:%d" % g.id), 0, 0))
		n += 1
		if sounds != null and _prev_t >= 0.0 and t > _prev_t and t - _prev_t < 3.0 and pos.distance_to(me) < CALL_RANGE:
			if gulls.call_between(g, _prev_t, t):
				sounds.gull_call(pos)
	mm.visible_instance_count = n
	_prev_t = t


## A gull, about 55 cm long with a 1.2 m wingspan, facing -Z. Colour: white
## body, grey wings with black tips (alpha 0.5 marks the flapping parts),
## yellow bill.
static func gull_mesh() -> ArrayMesh:
	var m := MeshMerger.new()
	var white := Color(0.95, 0.95, 0.95, 1.0)
	m.sphere("g", 0.09, Vector3(0, 0, 0.02), white, Vector3(0.8, 0.75, 2.2), 8)
	m.sphere("g", 0.05, Vector3(0, 0.05, -0.2), white, Vector3.ONE, 6)
	m.box("g", Vector3(0.016, 0.016, 0.07), Vector3(0, 0.04, -0.27), Color(0.95, 0.75, 0.15, 1.0))
	m.box("g", Vector3(0.12, 0.01, 0.12), Vector3(0, 0.0, 0.26), white)  # tail
	for side: float in [-1.0, 1.0]:
		m.box("g", Vector3(0.3, 0.012, 0.16), Vector3(side * 0.18, 0.02, 0.0), Color(0.72, 0.75, 0.78, 0.5))
		m.box("g", Vector3(0.28, 0.012, 0.12), Vector3(side * 0.46, 0.02, 0.02), Color(0.2, 0.2, 0.22, 0.5))
	return m.commit("g")
