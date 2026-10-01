class_name TrafficView
extends Node3D
## The cars, taxis, minibuses and buses of Traffic (shared/traffic.gd), drawn
## from the same clock every frame. Nothing about them travels over the network.
##
## Cost control, for phones: one MultiMesh per body type (hatchback, sedan, taxi,
## minibus, bus), one for all wheels, one for far-away boxes, and (at night
## only) one for headlight pools on the road and one for light halos. Vehicles
## beyond GraphicsQuality.traffic_lod() are a single tinted box. The render
## range shrinks with the quality level, but the population does not (it is
## the server's), so collisions never depend on what is drawn.
##
## Body parts carry their role in the vertex colour alpha (see SHADER): paint
## (tinted per vehicle through INSTANCE_CUSTOM), glass, tail light, head light,
## plain colour. Tail lights glow at night and flare when the car brakes.

const HATCH := 0
const SEDAN := 1
const TAXI_T := 2
const MINIBUS_T := 3
const BUS_T := 4
const TYPE_COUNT := 5
const WHEEL_R := 0.33
const WHEEL_RADIUS_OF := [0.31, 0.31, 0.31, 0.38, 0.5]  # per type
const HORN_RANGE := 40.0
const AUDIO_RANGE := 55.0

# Vertex colour alpha: 0 paint, .25 glass, .5 tail light, .75 head light, 1 plain.
const A_PAINT := 0.0
const A_GLASS := 0.25
const A_TAIL := 0.5
const A_HEAD := 0.75
const A_PLAIN := 1.0

const SHADER := """
shader_type spatial;
render_mode cull_back;
global uniform float night;
varying vec4 paint;
varying vec4 vcol;
void vertex() {
	paint = INSTANCE_CUSTOM;
	vcol = COLOR;
}
void fragment() {
	int band = int(vcol.a * 4.0 + 0.5);
	vec3 base = vcol.rgb * vcol.rgb;
	float n = smoothstep(0.2, 0.7, night);
	vec3 emit = vec3(0.0);
	ROUGHNESS = 0.55;
	SPECULAR = 0.4;
	if (band == 0) {
		base = paint.rgb * paint.rgb * (0.55 + 0.45 * vcol.r);
		ROUGHNESS = 0.32;
		SPECULAR = 0.55;
	} else if (band == 1) {
		ROUGHNESS = 0.06;
		SPECULAR = 0.9;
		METALLIC = 0.35;
	} else if (band == 2) {
		emit = base * (0.25 + 0.9 * n + paint.a * 2.4);
	} else if (band == 3) {
		emit = base * (0.1 + 2.2 * n);
	}
	ALBEDO = base;
	EMISSION = emit;
}
"""

const POOL_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
global uniform float night;
varying float fade;
void vertex() {
	fade = 1.0 - smoothstep(55.0, 110.0, length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz));
}
void fragment() {
	float u = UV.x * 2.0 - 1.0;
	float v = 1.0 - UV.y;  // 0 at the car, 1 at the far end
	float spread = 0.55 + v * 0.9;
	float a = pow(max(0.0, 1.0 - abs(u) * spread), 1.6) * pow(max(0.0, 1.0 - v), 1.3) * smoothstep(0.0, 0.12, v);
	ALBEDO = vec3(1.0, 0.9, 0.68) * a * 0.42 * smoothstep(0.2, 0.7, night) * fade;
}
"""

const HALO_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_disabled, shadows_disabled, fog_disabled;
global uniform float night;
varying vec4 tint;
varying float fade;
void vertex() {
	tint = INSTANCE_CUSTOM;
	MODELVIEW_MATRIX = VIEW_MATRIX * mat4(INV_VIEW_MATRIX[0], INV_VIEW_MATRIX[1], INV_VIEW_MATRIX[2], MODEL_MATRIX[3]);
	fade = 1.0 - smoothstep(60.0, 110.0, length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz));
}
void fragment() {
	float d = length(UV - 0.5) * 2.0;
	float core = pow(max(0.0, 1.0 - d), 3.0) * 1.2 + pow(max(0.0, 1.0 - d), 8.0) * 1.6;
	ALBEDO = tint.rgb * core * tint.a * smoothstep(0.2, 0.7, night) * fade;
}
"""

var traffic: Traffic
var sounds: CitySounds
var client: GameClient
var terrain: Terrain
var render_range := 170.0
var lod_distance := 90.0
var drawn := 0  # vehicles drawn last frame (for tests and the perf log)
var drawn_boxes := 0

var _body: Array = []  # MultiMeshInstance3D per type
var _wheels: MultiMeshInstance3D
var _boxes: MultiMeshInstance3D
var _pools: MultiMeshInstance3D
var _halos: MultiMeshInstance3D
var _capacity := PackedInt32Array()
var _pitch := {}  # vehicle id -> smoothed body pitch
var _horned := {}  # vehicle id -> last horn slot
var _type_of := PackedByteArray()
var _quality_seen := -1
var _frame := 0


func setup(game: GameClient, model: Traffic) -> void:
	client = game
	traffic = model
	terrain = model.terrain
	var shader := Shader.new()
	shader.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var counts := PackedInt32Array()
	counts.resize(TYPE_COUNT)
	_type_of.resize(model.vehicles.size())
	for v: Traffic.Vehicle in model.vehicles:
		var t := type_of(v)
		_type_of[v.id] = t
		counts[t] += 1
	_capacity = counts
	var span := model.half + 80.0
	var bounds := AABB(Vector3(-span, -40.0, -span), Vector3(span * 2.0, 120.0, span * 2.0))
	for t in TYPE_COUNT:
		_body.append(_make_multi(_body_mesh(t), mat, counts[t], "Body%d" % t, bounds, true))
	_boxes = _make_multi(_box_mesh(), mat, model.vehicles.size(), "Far", bounds, true)
	_wheels = _make_multi(_wheel_mesh(), mat, model.vehicles.size() * 4, "Wheels", bounds, false)
	var pool_mesh := PlaneMesh.new()
	pool_mesh.size = Vector2(5.5, 11.0)
	pool_mesh.center_offset = Vector3(0, 0, -5.5)
	_pools = _make_multi(pool_mesh, _shader_mat(POOL_SHADER), model.vehicles.size(), "Beams", bounds, false)
	var halo_mesh := QuadMesh.new()
	halo_mesh.size = Vector2(1.1, 1.1)
	_halos = _make_multi(halo_mesh, _shader_mat(HALO_SHADER), model.vehicles.size() * 4, "Halos", bounds, false)
	apply_quality()


func _shader_mat(code: String) -> ShaderMaterial:
	var shader := Shader.new()
	shader.code = code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	return mat


func _make_multi(mesh: Mesh, mat: Material, count: int, node_name: String, bounds: AABB, shadows: bool) -> MultiMeshInstance3D:
	mesh.surface_set_material(0, mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = maxi(count, 1)
	mm.visible_instance_count = 0
	mm.custom_aabb = bounds
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if shadows else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


static func type_of(v: Traffic.Vehicle) -> int:
	match v.kind:
		Traffic.TAXI:
			return TAXI_T
		Traffic.MINIBUS:
			return MINIBUS_T
		Traffic.BUS:
			return BUS_T
	return SEDAN if (v.id % 3) == 0 else HATCH


## Shadows and range follow the graphics quality level.
func apply_quality() -> void:
	_quality_seen = GraphicsQuality.level
	render_range = GraphicsQuality.traffic_range()
	lod_distance = GraphicsQuality.traffic_lod()
	for node: MultiMeshInstance3D in _body:
		node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if GraphicsQuality.shadows() else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


# --- frame -------------------------------------------------------------------------

## t: world time (seconds); cam: camera position; me: the local player.
func update(t: float, night: float, cam: Vector3, me: Vector3, delta: float) -> void:
	if GraphicsQuality.level != _quality_seen:
		apply_quality()
	_frame += 1
	var centre := Vector2(cam.x, cam.z)
	var list := traffic.vehicles_near(t, centre, render_range)
	var lit := night > 0.15
	var counts := PackedInt32Array()
	counts.resize(TYPE_COUNT)
	var n_box := 0
	var n_wheel := 0
	var n_pool := 0
	var n_halo := 0
	var wheels_mm := _wheels.multimesh
	var boxes_mm := _boxes.multimesh
	var pools_mm := _pools.multimesh
	var halos_mm := _halos.multimesh
	var voices := []
	var lod2 := lod_distance * lod_distance
	var hour_blend := 1.0 - exp(-10.0 * delta)
	for v: Traffic.Vehicle in list:
		var d2 := v.pos.distance_squared_to(centre)
		var paint := Color(Traffic.PALETTE[v.colour])
		var braking := v.accel < -0.5 or v.speed < 0.2
		var length := v.length
		var ground := terrain.height(v.pos.x, v.pos.y)
		if d2 > lod2:
			var fwd := Vector3(v.dir.x, 0.0, v.dir.y)
			var bx := Basis.looking_at(fwd, Vector3.UP)
			bx = bx.scaled_local(Vector3(v.width, v.height, length))
			boxes_mm.set_instance_transform(n_box, Transform3D(bx, Vector3(v.pos.x, ground, v.pos.y)))
			boxes_mm.set_instance_custom_data(n_box, _box_paint(v, paint))
			n_box += 1
			continue
		var t_idx: int = _type_of[v.id]
		var f2 := Vector3(v.dir.x, 0.0, v.dir.y)
		var hf := terrain.height(v.pos.x + f2.x * length * 0.4, v.pos.y + f2.z * length * 0.4)
		var hr := terrain.height(v.pos.x - f2.x * length * 0.4, v.pos.y - f2.z * length * 0.4)
		var slope := (hf - hr) / (length * 0.8)
		var pitch_target := clampf(v.accel * 0.011, -0.055, 0.03)
		var pitch: float = lerpf(float(_pitch.get(v.id, pitch_target)), pitch_target, hour_blend)
		_pitch[v.id] = pitch
		var basis := Basis.looking_at(Vector3(f2.x, slope, f2.z).normalized(), Vector3.UP)
		basis = basis * Basis(Vector3.RIGHT, pitch)
		var origin := Vector3(v.pos.x, (hf + hr) * 0.5 + 0.03, v.pos.y)
		var xf := Transform3D(basis, origin)
		var mm: MultiMesh = (_body[t_idx] as MultiMeshInstance3D).multimesh
		var slot := counts[t_idx]
		counts[t_idx] += 1
		mm.set_instance_transform(slot, xf)
		mm.set_instance_custom_data(slot, Color(paint.r, paint.g, paint.b, 1.0 if braking else 0.0))
		# Wheels spin with the distance driven.
		var wr: float = WHEEL_RADIUS_OF[t_idx]
		var spin := -v.arc / wr
		var wb := basis * Basis(Vector3.RIGHT, spin)
		wb = wb.scaled_local(Vector3.ONE * (wr / WHEEL_R))
		var half_w := v.width * 0.5 - 0.1
		var z_front := -length * (0.32 if t_idx == BUS_T else 0.31)
		var z_rear := length * (0.26 if t_idx == BUS_T else 0.31)
		for wz in [z_front, z_rear]:
			for wx in [-half_w, half_w]:
				var wp := xf * Vector3(wx, wr, wz)
				wheels_mm.set_instance_transform(n_wheel, Transform3D(wb, wp))
				n_wheel += 1
		if lit and d2 < 10000.0:
			var up := Basis.looking_at(f2, Vector3.UP)
			pools_mm.set_instance_transform(n_pool, Transform3D(up, Vector3(v.pos.x, ground + 0.16, v.pos.y) + f2 * (length * 0.5 - 0.3)))
			n_pool += 1
			var hx := v.width * 0.5 - 0.3
			var hy := 0.62 if t_idx < BUS_T else 0.8
			for side in [-1.0, 1.0]:
				halos_mm.set_instance_transform(n_halo, Transform3D(Basis(), xf * Vector3(side * hx, hy, -length * 0.5 - 0.05)))
				halos_mm.set_instance_custom_data(n_halo, Color(1.0, 0.92, 0.7, 0.9))
				n_halo += 1
				halos_mm.set_instance_transform(n_halo, Transform3D(Basis(), xf * Vector3(side * (hx - 0.05), hy + 0.04, length * 0.5 + 0.05)))
				halos_mm.set_instance_custom_data(n_halo, Color(1.0, 0.1, 0.06, 0.45 + (1.0 if braking else 0.0)))
				n_halo += 1
		if d2 < AUDIO_RANGE * AUDIO_RANGE:
			voices.append([sqrt(d2), Vector3(v.pos.x, ground + 0.8, v.pos.y), v.speed, v.kind, v.id])
			if d2 < HORN_RANGE * HORN_RANGE:
				_maybe_horn(v, t, me, ground)
	for i in TYPE_COUNT:
		(_body[i] as MultiMeshInstance3D).multimesh.visible_instance_count = counts[i]
	wheels_mm.visible_instance_count = n_wheel
	boxes_mm.visible_instance_count = n_box
	pools_mm.visible_instance_count = n_pool
	halos_mm.visible_instance_count = n_halo
	drawn = list.size()
	drawn_boxes = n_box
	if sounds != null:
		sounds.traffic_audio(voices)


func _box_paint(v: Traffic.Vehicle, paint: Color) -> Color:
	match v.kind:
		Traffic.TAXI:
			return Color("f4c20d")
		Traffic.BUS:
			return Color("c4161c")
	return Color(paint.r, paint.g, paint.b, 0.0)


## A driver leans on the horn, now and then, at someone standing in the road
## ahead. Decided from the world clock alone, so every client hears the same
## honks at the same moments, without any message.
func _maybe_horn(v: Traffic.Vehicle, t: float, me: Vector3, ground: float) -> void:
	if sounds == null or v.speed < 1.5 or absf(me.y - ground) > 2.0:
		return
	var rel := Vector2(me.x, me.z) - v.pos
	var ahead := rel.dot(v.dir) - v.length * 0.5
	if ahead < 1.5 or ahead > 24.0:
		return
	var across := absf(rel.dot(Vector2(-v.dir.y, v.dir.x)))
	if across > v.width * 0.5 + 0.9:
		return
	var period := 5.0
	var slot := floori(t / period)
	if int(_horned.get(v.id, -1)) == slot:
		return
	var honk_at := slot * period + Traffic.h01("horn:%d:%d" % [v.id, slot]) * (period - 1.0)
	if Traffic.h01("honk:%d:%d" % [v.id, slot]) < 0.6 and t >= honk_at and t < honk_at + 0.3:
		_horned[v.id] = slot
		sounds.horn(Vector3(v.pos.x, ground + 1.0, v.pos.y), 0.9 + Traffic.h01("pitch:%d" % v.id) * 0.3, v.kind == Traffic.BUS)


# --- models (forward is -Z, origin at the ground below the centre) ------------------------

func _body_mesh(type: int) -> ArrayMesh:
	var m := MeshMerger.new()
	match type:
		HATCH:
			_car_body(m, Traffic.LENGTHS[0], Traffic.WIDTHS[0], false, false)
		SEDAN:
			_car_body(m, Traffic.LENGTHS[0], Traffic.WIDTHS[0], true, false)
		TAXI_T:
			_car_body(m, Traffic.LENGTHS[1], Traffic.WIDTHS[1], true, true)
		MINIBUS_T:
			_minibus_body(m, Traffic.LENGTHS[2], Traffic.WIDTHS[2])
		BUS_T:
			_bus_body(m, Traffic.LENGTHS[3], Traffic.WIDTHS[3])
	return m.commit("body")


static func _c(rgb: String, alpha: float) -> Color:
	var c := Color(rgb)
	return Color(c.r, c.g, c.b, alpha)


static func _paint() -> Color:
	return Color(1.0, 1.0, 1.0, A_PAINT)


func _lights(m: MeshMerger, length: float, width: float, y_head: float, y_tail: float, size: Vector3) -> void:
	for side in [-1.0, 1.0]:
		m.box("body", size, Vector3(side * (width * 0.5 - 0.28 - size.x * 0.5 + 0.17), y_head, -length * 0.5), _c("fff2d0", A_HEAD))
		m.box("body", size * Vector3(1.1, 1.0, 1.0), Vector3(side * (width * 0.5 - 0.25 - size.x * 0.5 + 0.17), y_tail, length * 0.5), _c("c01010", A_TAIL))


func _car_body(m: MeshMerger, length: float, width: float, sedan: bool, taxi: bool) -> void:
	var paint := _c("f4c20d", A_PLAIN) if taxi else _paint()
	var dark := _c("2a2b2e", A_PLAIN)
	m.box("body", Vector3(width, 0.56, length), Vector3(0, 0.48, 0), paint)  # lower body
	var cabin_len := length * (0.4 if sedan else 0.5)
	var cabin_z := length * (0.04 if sedan else 0.1)
	m.box("body", Vector3(width - 0.14, 0.5, cabin_len), Vector3(0, 1.0, cabin_z), _c("1d242c", A_GLASS))
	m.box("body", Vector3(width - 0.22, 0.07, cabin_len - 0.12), Vector3(0, 1.28, cabin_z), paint)  # roof
	# Sloped windscreen: a wedge from the bonnet to the roof, glass on the front.
	m.box("body", Vector3(width - 0.18, 0.06, 0.8), Vector3(0, 0.98, cabin_z - cabin_len * 0.5 - 0.1), _c("1d242c", A_GLASS), Basis(Vector3.RIGHT, -0.7))
	m.box("body", Vector3(width - 0.06, 0.06, length * 0.27), Vector3(0, 0.79, -length * 0.36), paint)  # bonnet
	if sedan:
		m.box("body", Vector3(width - 0.06, 0.07, length * 0.22), Vector3(0, 0.79, length * 0.39), paint)  # boot
	else:
		m.box("body", Vector3(width - 0.12, 0.42, 0.06), Vector3(0, 0.98, cabin_z + cabin_len * 0.5 + 0.02), _c("1d242c", A_GLASS), Basis(Vector3.RIGHT, -0.25))
	m.box("body", Vector3(width + 0.01, 0.2, 0.2), Vector3(0, 0.33, -length * 0.5 + 0.03), dark)  # bumpers
	m.box("body", Vector3(width + 0.01, 0.2, 0.2), Vector3(0, 0.33, length * 0.5 - 0.03), dark)
	m.box("body", Vector3(width + 0.02, 0.14, length * 0.7), Vector3(0, 0.3, 0), dark)  # sills
	_lights(m, length, width, 0.62, 0.64, Vector3(0.4, 0.13, 0.06))
	if taxi:
		m.box("body", Vector3(width + 0.01, 0.05, length * 0.72), Vector3(0, 0.6, 0), dark)  # checker line
		m.box("body", Vector3(0.55, 0.17, 0.24), Vector3(0, 1.4, cabin_z), _c("ffe9a0", A_HEAD))  # roof sign


func _minibus_body(m: MeshMerger, length: float, width: float) -> void:
	var dark := _c("2a2b2e", A_PLAIN)
	m.box("body", Vector3(width, 0.95, length), Vector3(0, 0.7, 0), _paint())
	m.box("body", Vector3(width + 0.01, 0.12, length), Vector3(0, 0.95, 0), _c("2a5aa0", A_PLAIN))  # stripe
	m.box("body", Vector3(width - 0.04, 0.72, length - 0.5), Vector3(0, 1.52, 0.1), _c("1d242c", A_GLASS))
	m.box("body", Vector3(width - 0.2, 0.7, 0.06), Vector3(0, 1.5, -length * 0.5 + 0.1), _c("1d242c", A_GLASS), Basis(Vector3.RIGHT, 0.3))  # windscreen
	m.box("body", Vector3(width - 0.04, 0.46, length - 0.1), Vector3(0, 2.1, 0), _paint())  # roof
	m.box("body", Vector3(width + 0.01, 0.22, 0.22), Vector3(0, 0.4, -length * 0.5 + 0.03), dark)
	m.box("body", Vector3(width + 0.01, 0.22, 0.22), Vector3(0, 0.4, length * 0.5 - 0.03), dark)
	m.box("body", Vector3(0.9, 0.2, 0.05), Vector3(0, 2.0, -length * 0.5 - 0.01), _c("ffb347", A_HEAD))  # destination sign
	_lights(m, length, width, 0.72, 0.78, Vector3(0.4, 0.16, 0.06))


func _bus_body(m: MeshMerger, length: float, width: float) -> void:
	var red := _c("c4161c", A_PLAIN)
	var dark := _c("2a2b2e", A_PLAIN)
	m.box("body", Vector3(width, 0.95, length), Vector3(0, 0.72, 0), red)
	m.box("body", Vector3(width + 0.01, 0.1, length), Vector3(0, 0.98, 0), _c("f2f2f0", A_PLAIN))  # white stripe
	m.box("body", Vector3(width - 0.04, 1.05, length - 0.4), Vector3(0, 1.72, 0.05), _c("1d242c", A_GLASS))
	m.box("body", Vector3(width - 0.1, 1.0, 0.06), Vector3(0, 1.72, -length * 0.5 + 0.02), _c("1d242c", A_GLASS))  # windscreen
	m.box("body", Vector3(width, 0.5, length), Vector3(0, 2.52, 0), red)
	m.box("body", Vector3(width - 0.3, 0.14, length - 0.3), Vector3(0, 2.84, 0), _c("e8e8e4", A_PLAIN))  # roof
	for z in [-length * 0.3, length * 0.04]:
		m.box("body", Vector3(width + 0.02, 1.7, 1.0), Vector3(0, 1.1, z), _c("33393f", A_PLAIN))  # doors
	m.box("body", Vector3(width + 0.01, 0.3, 0.3), Vector3(0, 0.4, -length * 0.5 + 0.05), dark)
	m.box("body", Vector3(width + 0.01, 0.3, 0.3), Vector3(0, 0.4, length * 0.5 - 0.05), dark)
	m.box("body", Vector3(width - 0.7, 0.3, 0.05), Vector3(0, 2.52, -length * 0.5 - 0.01), _c("ffae42", A_HEAD))  # route sign
	_lights(m, length, width, 0.75, 0.82, Vector3(0.5, 0.2, 0.06))


func _wheel_mesh() -> ArrayMesh:
	var m := MeshMerger.new()
	var side := Basis(Vector3.BACK, PI * 0.5)  # cylinder axis along X
	m.cylinder("w", WHEEL_R, WHEEL_R, 0.24, Transform3D(side, Vector3.ZERO), _c("1b1b1d", A_PLAIN))
	m.cylinder("w", WHEEL_R * 0.6, WHEEL_R * 0.6, 0.27, Transform3D(side, Vector3.ZERO), _c("a4a8ad", A_PLAIN))
	m.box("w", Vector3(0.3, 0.06, 0.42), Vector3.ZERO, _c("4a4e53", A_PLAIN))
	m.box("w", Vector3(0.3, 0.42, 0.06), Vector3.ZERO, _c("4a4e53", A_PLAIN))
	return m.commit("w")


func _box_mesh() -> ArrayMesh:
	var m := MeshMerger.new()
	m.box("b", Vector3.ONE, Vector3(0, 0.5, 0), _paint())
	return m.commit("b")
