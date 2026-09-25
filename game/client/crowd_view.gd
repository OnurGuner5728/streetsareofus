class_name CrowdView
extends Node3D
## Draws the Crowd (ambient NPC pedestrians): one MultiMesh for everyone,
## legs and arms swung by the vertex shader, clothes picked from palettes by
## per-instance data. How many walk depends on the hour and on quality.
## Pedestrians step aside for real people (a visual nudge off their route).

const NEAR := 55.0
const COUNT_BY_QUALITY := [24, 50, 90]
# Body part codes in the mesh's vertex colour (red channel).
const SKIN := 0.1
const TOP := 0.3
const BOTTOM := 0.5
const HAIR := 0.7
const SHOES := 0.9

const SHADER := """
shader_type spatial;
const vec3 TOPS[8] = {vec3(0.62, 0.12, 0.12), vec3(0.12, 0.2, 0.42), vec3(0.85, 0.83, 0.78), vec3(0.15, 0.15, 0.16),
	vec3(0.25, 0.42, 0.3), vec3(0.72, 0.52, 0.2), vec3(0.45, 0.25, 0.5), vec3(0.55, 0.6, 0.65)};
const vec3 BOTTOMS[6] = {vec3(0.13, 0.18, 0.32), vec3(0.1, 0.1, 0.11), vec3(0.38, 0.33, 0.27), vec3(0.2, 0.28, 0.45),
	vec3(0.5, 0.48, 0.44), vec3(0.25, 0.23, 0.2)};
const vec3 SKINS[4] = {vec3(0.94, 0.76, 0.62), vec3(0.8, 0.6, 0.45), vec3(0.6, 0.42, 0.3), vec3(0.4, 0.27, 0.19)};
const vec3 HAIRS[4] = {vec3(0.08, 0.06, 0.05), vec3(0.3, 0.2, 0.12), vec3(0.6, 0.5, 0.35), vec3(0.55, 0.55, 0.55)};
varying vec3 col;
vec3 srgb(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 turn_x(vec3 v, vec3 pivot, float a) {
	vec3 d = v - pivot;
	return pivot + vec3(d.x, d.y * cos(a) - d.z * sin(a), d.y * sin(a) + d.z * cos(a));
}
void vertex() {
	float walking = step(0.01, INSTANCE_CUSTOM.y);
	float phase = INSTANCE_CUSTOM.x + TIME * INSTANCE_CUSTOM.y;
	float swing = sin(phase) * 0.55 * walking;
	float side = COLOR.g * 2.0 - 1.0;
	if (COLOR.b > 0.25 && COLOR.b < 0.75) {
		VERTEX = turn_x(VERTEX, vec3(0.0, 0.86, 0.0), swing * side);
	} else if (COLOR.b >= 0.75) {
		VERTEX = turn_x(VERTEX, vec3(0.0, 1.38, 0.0), -swing * side * 0.8);
	}
	VERTEX.y += abs(sin(phase)) * 0.025 * walking;
	int look = int(INSTANCE_CUSTOM.z + 0.5);
	int body = int(INSTANCE_CUSTOM.w + 0.5);
	float part = COLOR.r;
	vec3 c = SKINS[body % 4];
	if (part > 0.2 && part < 0.4) c = TOPS[look % 8];
	else if (part >= 0.4 && part < 0.6) c = BOTTOMS[(look / 8) % 6];
	else if (part >= 0.6 && part < 0.8) c = HAIRS[(body / 4) % 4];
	else if (part >= 0.8) c = vec3(0.08, 0.07, 0.07);
	col = srgb(c);
}
void fragment() {
	ALBEDO = col;
	ROUGHNESS = 0.85;
}
"""

var client: GameClient
var crowd: Crowd
var _mm: MultiMesh
var _count := 0
var _frame := 0
var _last := []  # last position per walker (Vector3), for the near/far split
var _cadence := PackedFloat32Array()
var _aside := PackedVector2Array()  # current sidestep per walker (XZ)
const GIVE_WAY := 1.1  # metres at which a pedestrian starts stepping aside


func setup(game: GameClient) -> void:
	client = game
	crowd = Crowd.for_zone(game.zone)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _body_mesh()
	_mm.instance_count = crowd.walkers.size()
	_mm.visible_instance_count = 0
	for i in crowd.walkers.size():
		var w: Crowd.Walker = crowd.walkers[i]
		_mm.set_instance_custom_data(i, Color(float(i) * 1.7, 0.0, float(w.looks[0] + w.looks[1] * 8), float(w.looks[2] + w.looks[3] * 4)))
		_last.append(Vector3(0, -100, 0))
		_cadence.append(0.0)
		_aside.append(Vector2.ZERO)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Crowd"
	mmi.multimesh = _mm
	mmi.extra_cull_margin = 16384.0
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	mat.shader = shader
	mmi.material_override = mat
	add_child(mmi)


func update(now_server: float, hours: float) -> void:
	_frame += 1
	var target := mini(crowd.walkers.size(), roundi(COUNT_BY_QUALITY[GraphicsQuality.level] * Crowd.density(hours)))
	if target != _count:
		_count = target
		_mm.visible_instance_count = _count
	var cam := client.camera.global_position if client.camera else Vector3.ZERO
	# Where real people are, to give way to them.
	var people := PackedVector2Array()
	if client.body:
		people.append(Vector2(client.body.global_position.x, client.body.global_position.z))
	for r in client.remotes.values():
		var rp := (r as Node3D).global_position
		if rp.distance_to(cam) < NEAR:
			people.append(Vector2(rp.x, rp.z))
	var dt := minf(get_process_delta_time(), 0.1)
	for i in _count:
		# People near the camera move every frame, the rest a few times a second.
		if (_last[i] as Vector3).distance_to(cam) > NEAR and (i + _frame) % 6 != 0:
			continue
		var w: Crowd.Walker = crowd.walkers[i]
		var pose := w.pose(now_server)
		var p: Vector2 = pose[0]
		var h: Vector2 = pose[1]
		var xz := Vector2(p.x, -p.y)
		var want := Vector2.ZERO
		if (_last[i] as Vector3).distance_to(cam) < NEAR:
			for q in people:
				var away := xz + _aside[i] - q
				var d := away.length()
				if d < GIVE_WAY and d > 0.001:
					# Sideways relative to their walk, towards whichever side they are on.
					var side := Vector2(h.y, h.x)
					want += side * signf(side.dot(away) + 0.001) * (GIVE_WAY - d) * 1.4
		_aside[i] = _aside[i].lerp(want.limit_length(1.2), 1.0 - exp(-4.0 * dt))
		xz += _aside[i]
		var pos := Vector3(xz.x, client.zone.terrain.height(xz.x, xz.y), xz.y)
		_last[i] = pos
		_mm.set_instance_transform(i, Transform3D(Basis(Vector3.UP, atan2(-h.x, h.y)).scaled(Vector3.ONE * w.size), pos))
		var cadence := w.speed * 4.6 if pose[2] else 0.0
		if _cadence[i] != cadence:
			_cadence[i] = cadence
			var custom := _mm.get_instance_custom_data(i)
			custom.g = cadence
			_mm.set_instance_custom_data(i, custom)


## The pedestrian under the crosshair within `reach`, or -1.
func look_target(origin: Vector3, forward: Vector3, reach: float) -> int:
	var best := -1
	var best_along := INF
	for i in _count:
		var p: Vector3 = _last[i]
		if origin.distance_to(p + Vector3(0, 1.0, 0)) > reach + 0.5:
			continue
		var pts := Geometry3D.get_closest_points_between_segments(origin, origin + forward * 6.0, p + Vector3(0, 0.2, 0), p + Vector3(0, 1.7, 0))
		var along := origin.distance_to(pts[0])
		if pts[0].distance_to(pts[1]) < 0.5 and along < best_along:
			best_along = along
			best = i
	return best


## A plain figure, 1.7 m, facing -Z. Vertex colour codes the part for the
## shader: r = part (skin/top/bottom/hair/shoes), g = side, b = limb.
static func _body_mesh() -> Mesh:
	var m := MeshMerger.new()
	for side: float in [-1.0, 1.0]:
		var g := (side + 1.0) / 2.0
		m.capsule("b", 0.075, 0.5, Vector3(side * 0.09, 0.62, 0), Color(BOTTOM, g, 0.5), Vector3.ONE, 6)
		m.capsule("b", 0.065, 0.46, Vector3(side * 0.09, 0.26, 0), Color(BOTTOM, g, 0.5), Vector3.ONE, 6)
		m.box("b", Vector3(0.12, 0.07, 0.26), Vector3(side * 0.09, 0.035, -0.04), Color(SHOES, g, 0.5))
		m.capsule("b", 0.05, 0.36, Vector3(side * 0.22, 1.2, 0), Color(TOP, g, 1.0), Vector3.ONE, 6)
		m.capsule("b", 0.045, 0.34, Vector3(side * 0.22, 0.94, 0), Color(SKIN, g, 1.0), Vector3.ONE, 6)
	m.capsule("b", 0.17, 0.62, Vector3(0, 1.14, 0), Color(TOP, 0.5, 0.0), Vector3(1.0, 1.0, 0.62), 8)
	m.capsule("b", 0.16, 0.2, Vector3(0, 0.88, 0), Color(BOTTOM, 0.5, 0.0), Vector3(1.0, 1.0, 0.62), 8)
	m.capsule("b", 0.045, 0.12, Vector3(0, 1.46, 0), Color(SKIN, 0.5, 0.0), Vector3.ONE, 6)
	m.sphere("b", 0.105, Vector3(0, 1.6, 0), Color(SKIN, 0.5, 0.0), Vector3(0.9, 1.1, 1.0), 8)
	m.sphere("b", 0.11, Vector3(0, 1.64, 0.02), Color(HAIR, 0.5, 0.0), Vector3(0.93, 0.85, 1.0), 8)
	return m.commit("b")
