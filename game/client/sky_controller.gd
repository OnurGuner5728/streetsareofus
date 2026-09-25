class_name SkyController
extends Node3D
## Real sky for the zone: the sun sits where it really is over these
## coordinates right now (everyone shares the same real clock, so no
## networking), with golden hours, blue hour and night. At night windows and
## street lamps come on, and the lamps nearest the camera cast real light.
##
## `hours_override` (0-24, local zone time) pins the clock for screenshots.

const UPDATE_EVERY := 2.0
const NIGHT_LIGHTS := 10
const ZONE_UTC_OFFSET := 3.0  # Istanbul

var latitude := 41.0
var longitude := 29.0
var hours_override := -1.0
var lamp_positions := PackedVector3Array()
var night := 0.0
var sun: DirectionalLight3D
var environment: Environment
var _sky: ProceduralSkyMaterial
var _lights: Array = []
var _timer := 0.0
var _light_timer := 0.0
var _compat := false
# Weather, fed by WeatherView: 0..1 each.
var cloud := 0.2
var rain := 0.0
var fog := 0.0
var _base_sun := 1.0
var _base_ambient := 1.0


func setup(zone: ZoneData, lamps: PackedVector3Array, compatibility: bool) -> void:
	latitude = zone.origin_lat
	longitude = zone.origin_lon
	lamp_positions = lamps
	_compat = compatibility
	_sky = ProceduralSkyMaterial.new()
	_sky.sun_angle_max = 20.0
	var sky := Sky.new()
	sky.sky_material = _sky
	environment = Environment.new()
	environment.background_mode = Environment.BG_SKY
	environment.sky = sky
	environment.ambient_light_source = Environment.AMBIENT_SOURCE_SKY
	# Mostly neutral fill: a blue sky alone makes every shadow look underwater.
	environment.ambient_light_sky_contribution = 0.35
	environment.ambient_light_color = Color("cfc8bc")
	environment.tonemap_mode = Environment.TONE_MAPPER_AGX
	environment.tonemap_exposure = 0.9 if compatibility else 1.0
	environment.glow_enabled = true
	environment.glow_intensity = 0.6
	environment.glow_bloom = 0.05
	environment.glow_hdr_threshold = 1.2
	environment.ssao_enabled = not compatibility
	environment.ssao_intensity = 1.6
	environment.fog_enabled = true
	environment.fog_density = 0.0028
	environment.fog_sky_affect = 0.25
	environment.adjustment_enabled = true
	environment.adjustment_contrast = 1.06
	environment.adjustment_saturation = 1.08
	var world_env := WorldEnvironment.new()
	world_env.environment = environment
	add_child(world_env)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS if compatibility else DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS
	sun.directional_shadow_max_distance = 90.0 if compatibility else 150.0
	sun.shadow_blur = 1.5
	add_child(sun)
	apply_quality()
	for i in NIGHT_LIGHTS:
		var l := OmniLight3D.new()
		l.omni_range = 20.0
		l.omni_attenuation = 1.4
		l.light_energy = 0.0
		l.light_color = Color("ffc98a")
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append(l)
	_apply(0.0)


## Shadows, glow, fog and lamp lights for GraphicsQuality.level.
func apply_quality() -> void:
	sun.shadow_enabled = GraphicsQuality.shadows()
	sun.directional_shadow_max_distance = GraphicsQuality.shadow_distance()
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_4_SPLITS 		if GraphicsQuality.level == GraphicsQuality.HIGH and not _compat else DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	environment.glow_enabled = GraphicsQuality.glow()
	environment.ssao_enabled = GraphicsQuality.level == GraphicsQuality.HIGH and not _compat
	environment.fog_density = GraphicsQuality.fog_density()
	_light_timer = 0.0


## Local zone time as hours 0-24.
func local_hours() -> float:
	if hours_override >= 0.0:
		return hours_override
	var unix := Time.get_unix_time_from_system()
	return fposmod(unix / 3600.0 + ZONE_UTC_OFFSET, 24.0)


func _process(delta: float) -> void:
	_timer -= delta
	if _timer <= 0.0:
		_timer = UPDATE_EVERY
		_apply(0.0)


## Lightning: brightens the scene for a moment without touching the sky
## material (changing that re-renders the sky's radiance map).
func flash(amount: float) -> void:
	sun.light_energy = _base_sun + amount * 2.5
	environment.ambient_light_energy = _base_ambient + amount * 1.6


## Place the night lights on the lamps closest to the camera.
func update_lights(camera_pos: Vector3, delta: float) -> void:
	_light_timer -= delta
	if _light_timer > 0.0:
		return
	_light_timer = 0.5
	var on := night > 0.3 and GraphicsQuality.night_lights() > 0
	if not on or lamp_positions.is_empty():
		for l in _lights:
			l.visible = false
		return
	var order := []
	# Lamp lights cost a pass per lit object in the Compatibility renderer.
	for p in lamp_positions:
		var d := camera_pos.distance_squared_to(p)
		if d < 90.0 * 90.0:
			order.append([d, p])
	order.sort_custom(func(a, b): return a[0] < b[0])
	for i in _lights.size():
		var l: OmniLight3D = _lights[i]
		l.visible = i < order.size() and i < GraphicsQuality.night_lights()
		if l.visible:
			l.global_position = order[i][1] - Vector3(0, 0.3, 0)
			l.light_energy = 3.2 * night


func _apply(_unused: float) -> void:
	var sun_dir := sun_direction(local_hours())
	var elevation := asin(clampf(sun_dir.y, -1.0, 1.0))
	var elev_deg := rad_to_deg(elevation)
	# 0 in full day, 1 in full night; civil twilight in between.
	night = clampf(inverse_lerp(4.0, -7.0, elev_deg), 0.0, 1.0)
	var golden := clampf(1.0 - absf(elev_deg - 3.0) / 12.0, 0.0, 1.0)
	RenderingServer.global_shader_parameter_set("night", night)
	var light_dir := sun_dir if elev_deg > -4.0 else _moon_direction(sun_dir)
	if absf(light_dir.y) > 0.999:
		light_dir = Vector3(0.01, light_dir.y, 0.0).normalized()
	sun.basis = Basis.looking_at(-light_dir, Vector3.UP)
	var day_col := Color("fff4e2")
	var warm := Color("ffb46b")
	var moon := Color("9fb4ff")
	sun.light_color = moon.lerp(day_col.lerp(warm, golden), 1.0 - night)
	# Overcast: a dim, diffuse sun, grey sky, more even light, no hard shadows.
	var overcast := clampf((cloud - 0.35) / 0.65, 0.0, 1.0)
	golden *= 1.0 - overcast
	_base_sun = lerpf(1.35, 0.3, night) * (1.0 - 0.35 * golden * (1.0 - night)) * (1.0 - 0.75 * overcast)
	sun.light_energy = _base_sun
	sun.shadow_enabled = GraphicsQuality.shadows() and overcast < 0.8
	var grey_top := Color("8e959d").lerp(Color("5d6369"), rain)
	var grey_horizon := Color("b3b8bc").lerp(Color("80868b"), rain)
	_sky.sky_top_color = Color("0a1222").lerp(Color("3f74b5"), 1.0 - night).lerp(Color("4a5f8f"), golden * 0.4) 		.lerp(grey_top.darkened(night * 0.85), overcast * 0.85)
	_sky.sky_horizon_color = Color("1a2438").lerp(Color("c3d3e2"), 1.0 - night).lerp(Color("f0a86b"), golden * 0.7) 		.lerp(grey_horizon.darkened(night * 0.85), overcast * 0.85)
	_sky.ground_horizon_color = _sky.sky_horizon_color
	_sky.ground_bottom_color = Color("0b0e12").lerp(Color("6b6f73"), 1.0 - night)
	_sky.sun_curve = 0.15
	# Nights in a lit city are not black: a moonlit, bluish fill (sky light
	# alone is nearly black at night) and a little more exposure.
	_base_ambient = lerpf(0.95, 0.55, night) * (1.0 + 0.25 * overcast)
	environment.ambient_light_energy = _base_ambient
	environment.ambient_light_color = Color("cfc8bc").lerp(Color("8d9cbd"), night)
	environment.ambient_light_sky_contribution = lerpf(lerpf(0.35, 0.6, overcast), 0.12, night)
	environment.tonemap_exposure = (0.9 if _compat else 1.0) * lerpf(1.0, 1.3, night)
	environment.fog_light_color = _sky.sky_horizon_color.darkened(0.1)
	environment.fog_density = GraphicsQuality.fog_density() + rain * 0.006 + fog * 0.03


## Unit vector towards the sun in Godot space for the zone's coordinates.
## NOAA-style approximation, well within a degree.
func sun_direction(hours_local: float) -> Vector3:
	var now := Time.get_unix_time_from_system()
	var day_start := floorf((now / 3600.0 + ZONE_UTC_OFFSET) / 24.0) * 24.0 - ZONE_UTC_OFFSET
	var unix := (day_start + hours_local) * 3600.0
	var n := unix / 86400.0 + 2440587.5 - 2451545.0
	var mean_long := deg_to_rad(fposmod(280.460 + 0.9856474 * n, 360.0))
	var anomaly := deg_to_rad(fposmod(357.528 + 0.9856003 * n, 360.0))
	var ecl_long := mean_long + deg_to_rad(1.915) * sin(anomaly) + deg_to_rad(0.020) * sin(2.0 * anomaly)
	var obliquity := deg_to_rad(23.439 - 0.0000004 * n)
	var ra := atan2(cos(obliquity) * sin(ecl_long), cos(ecl_long))
	var dec := asin(sin(obliquity) * sin(ecl_long))
	var gmst := fposmod(18.697374558 + 24.06570982441908 * n, 24.0)
	var hour_angle := deg_to_rad(fposmod(gmst * 15.0 + longitude, 360.0)) - ra
	var lat := deg_to_rad(latitude)
	var elevation := asin(sin(lat) * sin(dec) + cos(lat) * cos(dec) * cos(hour_angle))
	var azimuth := atan2(-sin(hour_angle), tan(dec) * cos(lat) - sin(lat) * cos(hour_angle))
	var horizontal := cos(elevation)
	# Azimuth from north, clockwise; Godot: x east, z south.
	return Vector3(sin(azimuth) * horizontal, sin(elevation), -cos(azimuth) * horizontal)


func _moon_direction(sun_dir: Vector3) -> Vector3:
	var m := -sun_dir
	m.y = maxf(absf(m.y), 0.45)
	return m.normalized()
