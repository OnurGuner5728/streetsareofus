class_name WeatherView
extends Node3D
## Draws the weather the server reports (WeatherService): rain or snow
## falling around the camera (one draw call, animated on the GPU), a cloud
## layer that thickens with cloud cover, lightning in storms, wind in the
## trees, and streets that get wet in rain and dry slowly afterwards.

const DROPS := 1400
const BOX := 26.0
const HEIGHT := 16.0

const PRECIP_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled, blend_mix;
uniform float fall = 9.0;
uniform float snow = 0.0;
uniform vec2 drift = vec2(0.0);
uniform float box = 26.0;
uniform float height = 16.0;
uniform float alpha = 0.5;
void vertex() {
	vec3 seed = MODEL_MATRIX[3].xyz;  // each drop's fixed slot in the box
	vec3 cam = INV_VIEW_MATRIX[3].xyz;
	float t = TIME * fall;
	vec3 p;
	p.y = cam.y + mod(seed.y - t - cam.y + height * 0.5, height) - height * 0.5;
	vec2 moved = seed.xz + drift * t * 0.12 + snow * vec2(sin(t * 0.7 + seed.y), cos(t * 0.5 + seed.x)) * 0.4;
	p.x = cam.x + mod(moved.x - cam.x + box * 0.5, box) - box * 0.5;
	p.z = cam.z + mod(moved.y - cam.z + box * 0.5, box) - box * 0.5;
	vec3 right = normalize(INV_VIEW_MATRIX[0].xyz);
	vec3 down = normalize(vec3(drift.x * 0.12, -1.0, drift.y * 0.12));
	float len = mix(0.6, 0.09, snow);
	float wide = mix(0.014, 0.09, snow);
	vec3 world = p + right * VERTEX.x * wide - down * VERTEX.y * len;
	POSITION = PROJECTION_MATRIX * VIEW_MATRIX * vec4(world, 1.0);
}
void fragment() {
	ALBEDO = mix(vec3(0.8, 0.85, 0.9), vec3(1.0), snow);
	// Round flakes; rain streaks fade at their ends.
	float edge = snow > 0.5 ? 1.0 - smoothstep(0.3, 0.5, length(UV - 0.5)) : 1.0 - abs(UV.y - 0.5) * 2.0;
	ALPHA = alpha * mix(1.0, 1.8, snow) * edge;
}
"""

const CLOUD_SHADER := """
shader_type spatial;
render_mode unshaded, cull_front, depth_draw_never, shadows_disabled, blend_mix, fog_disabled;
uniform float cover = 0.3;
uniform vec3 tint = vec3(1.0);
uniform vec2 drift = vec2(0.0);
varying vec3 dir;
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x), mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}
void vertex() { dir = VERTEX; }
void fragment() {
	vec3 d = normalize(dir);
	if (d.y < 0.02) discard;
	// Clouds on a plane high above, seen through the dome.
	vec2 uv = d.xz / d.y * 0.9 + drift * TIME * 0.004;
	float n = vnoise(uv) * 0.5 + vnoise(uv * 2.1 + 3.7) * 0.3 + vnoise(uv * 4.3 + 7.1) * 0.2;
	float c = smoothstep(1.0 - cover * 0.95, 1.05 - cover * 0.6, n);
	ALBEDO = tint * mix(1.0, 0.72, c * cover);
	ALPHA = c * smoothstep(0.02, 0.2, d.y) * 0.92;
}
"""

var client: GameClient
var info := {}
var rain := 0.0  # 0..1 now falling
var snow := 0.0
var cloud := 0.2
var fog := 0.0
var wind := 0.2
var wetness := 0.0
var _target := {"rain": 0.0, "snow": 0.0, "cloud": 0.2, "fog": 0.0, "wind": 0.2}
var _precip: MultiMeshInstance3D
var _precip_mat: ShaderMaterial
var _clouds: MeshInstance3D
var _cloud_mat: ShaderMaterial
var _flash := 0.0
var _next_flash := 8.0
var _rng := RandomNumberGenerator.new()


func setup(game: GameClient) -> void:
	client = game
	_rng.randomize()
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	var quad := QuadMesh.new()
	quad.size = Vector2(1, 1)
	mm.mesh = quad
	mm.instance_count = DROPS
	var seeds := RandomNumberGenerator.new()
	seeds.seed = 7
	for i in DROPS:
		mm.set_instance_transform(i, Transform3D(Basis(), Vector3(seeds.randf() * BOX, seeds.randf() * HEIGHT, seeds.randf() * BOX)))
	mm.visible_instance_count = 0
	_precip = MultiMeshInstance3D.new()
	_precip.multimesh = mm
	_precip.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_precip.extra_cull_margin = 16384.0  # the shader moves drops next to the camera
	_precip_mat = ShaderMaterial.new()
	_precip_mat.shader = _shader(PRECIP_SHADER)
	_precip.material_override = _precip_mat
	add_child(_precip)
	var dome := SphereMesh.new()
	# Inside the medium/high camera range, so the far plane never cuts it.
	dome.radius = 600.0
	dome.height = 1200.0
	dome.radial_segments = 24
	dome.rings = 12
	_clouds = MeshInstance3D.new()
	_clouds.mesh = dome
	_clouds.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_clouds.extra_cull_margin = 16384.0
	_cloud_mat = ShaderMaterial.new()
	_cloud_mat.shader = _shader(CLOUD_SHADER)
	_clouds.material_override = _cloud_mat
	add_child(_clouds)


static func _shader(code: String) -> Shader:
	var s := Shader.new()
	s.code = code
	return s


func set_info(w: Dictionary) -> void:
	var first := info.is_empty()
	info = w
	var code := int(w.get("code", 0))
	var mm := float(w.get("rain_mm", 0.0))
	var snowing := code in [71, 73, 75, 77, 85, 86]
	var raining := code >= 51 and not snowing
	var amount := clampf(mm / 4.0, 0.25, 1.0) if (raining or snowing) else 0.0
	_target.rain = amount if raining else 0.0
	_target.snow = amount if snowing else 0.0
	_target.cloud = clampf(float(w.get("cloud", 0.2)), 0.0, 1.0)
	_target.fog = 1.0 if code in [45, 48] else 0.0
	_target.wind = clampf(float(w.get("wind_kmh", 10.0)) / 45.0, 0.05, 1.0)
	if first:
		# Joining during the rain: it did not just start, the streets are wet.
		rain = _target.rain
		snow = _target.snow
		cloud = _target.cloud
		fog = _target.fog
		wind = _target.wind
		wetness = 1.0 if rain > 0.0 else 0.0


func is_storm() -> bool:
	return int(info.get("code", 0)) >= 95


## One line for the HUD, e.g. "14°C · Yağmurlu".
func summary() -> String:
	if info.is_empty():
		return ""
	return "%d°C · %s" % [roundi(float(info.get("temp_c", 0.0))), WeatherService.describe_code(int(info.get("code", 0)))]


func update(delta: float) -> void:
	var k := 1.0 - exp(-delta / 6.0)  # weather changes over some seconds
	rain = lerpf(rain, _target.rain, k)
	snow = lerpf(snow, _target.snow, k)
	cloud = lerpf(cloud, _target.cloud, k)
	fog = lerpf(fog, _target.fog, k)
	wind = lerpf(wind, _target.wind, k)
	# Streets soak in a minute and take a good while to dry.
	if rain > 0.05:
		wetness = minf(1.0, wetness + delta * rain / 60.0)
	else:
		wetness = maxf(0.0, wetness - delta / 600.0)
	RenderingServer.global_shader_parameter_set("wetness", wetness)
	RenderingServer.global_shader_parameter_set("snow", minf(1.0, snow * 1.5))
	RenderingServer.global_shader_parameter_set("wind", wind)
	var falling := maxf(rain, snow)
	var count := int(DROPS * falling * (0.5 if GraphicsQuality.level == GraphicsQuality.LOW else 1.0))
	if _precip.multimesh.visible_instance_count != count:
		_precip.multimesh.visible_instance_count = count
	var dir_rad := deg_to_rad(float(info.get("wind_dir", 0.0)))
	var drift := Vector2(-sin(dir_rad), cos(dir_rad)) * wind * 6.0  # wind blows *from* wind_dir
	_precip_mat.set_shader_parameter("snow", 1.0 if snow > rain else 0.0)
	_precip_mat.set_shader_parameter("fall", 1.2 if snow > rain else 9.0)
	_precip_mat.set_shader_parameter("drift", drift)
	_clouds.visible = GraphicsQuality.level >= GraphicsQuality.MEDIUM and cloud > 0.08
	if _clouds.visible:
		var night := client.night
		_cloud_mat.set_shader_parameter("cover", cloud)
		_cloud_mat.set_shader_parameter("drift", drift)
		_cloud_mat.set_shader_parameter("tint", Vector3(0.95, 0.96, 1.0).lerp(Vector3(0.12, 0.13, 0.17), night) * (1.0 + _flash * 2.0))
		if client.camera:
			_clouds.global_position = client.camera.global_position
	if client.sounds:
		client.sounds.rain = rain
	# Lightning: a flash, then thunder a moment later.
	_flash = maxf(0.0, _flash - delta * 6.0)
	if is_storm():
		_next_flash -= delta
		if _next_flash <= 0.0:
			_next_flash = _rng.randf_range(7.0, 22.0)
			_flash = 1.0
			if client.sounds:
				get_tree().create_timer(_rng.randf_range(0.8, 3.0)).timeout.connect(client.sounds.thunder)
