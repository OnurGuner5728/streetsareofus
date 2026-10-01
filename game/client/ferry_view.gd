class_name FerryView
extends Node3D
## Draws the ferries of the Ferries timetable: one MultiMesh for the hulls
## (white and red Şehir Hatları style, black hull stripe, red funnel with a
## black top, lit windows at night), one for the foam wakes. The hulls ride
## the same Gerstner swell as the sea shader (see CityMaterials.WATER), so
## they pitch and roll with the real weather. Horn blasts are decided from
## the world clock alone, like the rest of the city life.

const A_GLASS := 0.25
const A_LAMP := 0.75
const A_PLAIN := 1.0
const HEAR := 1500.0

const SHADER := """
shader_type spatial;
render_mode cull_back;
global uniform float night;
varying vec4 vcol;
void vertex() {
	vcol = COLOR;
}
void fragment() {
	int band = int(vcol.a * 4.0 + 0.5);
	vec3 base = vcol.rgb * vcol.rgb;
	float n = smoothstep(0.2, 0.7, night);
	vec3 emit = vec3(0.0);
	ROUGHNESS = 0.6;
	SPECULAR = 0.35;
	if (band == 1) {
		ROUGHNESS = 0.08;
		SPECULAR = 0.9;
		emit = vec3(1.0, 0.78, 0.45) * (0.05 + 1.1 * n);
	} else if (band == 3) {
		emit = base * (0.15 + 2.5 * n);
	}
	ALBEDO = base;
	EMISSION = emit;
}
"""

## Foam trail: two bright arms spreading from the stern and a churned
## centre line, fading with distance. `strength` is the ship's speed share.
const WAKE_SHADER := """
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never, shadows_disabled;
global uniform float night;
varying float strength;
float hash(vec2 p) {
	return fract(sin(dot(p, vec2(127.1, 311.7))) * 43758.5453);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash(i), hash(i + vec2(1, 0)), f.x), mix(hash(i + vec2(0, 1)), hash(i + vec2(1, 1)), f.x), f.y);
}
void vertex() {
	strength = INSTANCE_CUSTOM.x;
}
void fragment() {
	float u = UV.x;
	float v = UV.y;
	float arms = smoothstep(0.35, 0.0, abs(abs(u) - 0.78 + 0.2 * v));
	float core = smoothstep(0.45, 0.0, abs(u)) * 0.7;
	float foam = vnoise(vec2(u * 9.0, v * 26.0 - TIME * 1.4)) * 0.65 + vnoise(vec2(u * 21.0, v * 55.0 + TIME * 0.7)) * 0.35;
	float shape = (arms + core) * smoothstep(1.0, 0.05, v) * smoothstep(0.0, 0.06, v);
	float a = clamp(shape * (foam * 1.5 - 0.25), 0.0, 1.0) * strength * 0.75;
	vec3 col = mix(vec3(0.95, 0.98, 1.0), vec3(0.45, 0.55, 0.62), night * 0.8);
	ALBEDO = col;
	ALPHA = a;
}
"""

var client: GameClient
var ferries: Ferries
var sounds: CitySounds
var sea_level := -1.6
var _hulls: MultiMeshInstance3D
var _wakes: MultiMeshInstance3D
var _prev_t := -1.0
var _quality_seen := -1


func setup(game: GameClient, model: Ferries, sea: float) -> void:
	client = game
	ferries = model
	sea_level = sea
	var span := 1700.0
	var bounds := AABB(Vector3(-span, -10.0, -span), Vector3(span * 2.0, 40.0, span * 2.0))
	var count := maxi(model.ships.size(), 1)
	var shader := Shader.new()
	shader.code = SHADER
	var mat := ShaderMaterial.new()
	mat.shader = shader
	var mesh := hull_mesh()
	mesh.surface_set_material(0, mat)
	_hulls = _multi(mesh, count, "Hulls", bounds, false)
	_hulls.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON
	var wshader := Shader.new()
	wshader.code = WAKE_SHADER
	var wmat := ShaderMaterial.new()
	wmat.shader = wshader
	var wmesh := wake_mesh()
	wmesh.surface_set_material(0, wmat)
	_wakes = _multi(wmesh, count, "Wakes", bounds, true)
	apply_quality()


func _multi(mesh: Mesh, count: int, node_name: String, bounds: AABB, custom: bool) -> MultiMeshInstance3D:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = custom
	mm.mesh = mesh
	mm.instance_count = count
	mm.visible_instance_count = 0
	mm.custom_aabb = bounds
	var node := MultiMeshInstance3D.new()
	node.name = node_name
	node.multimesh = mm
	node.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(node)
	return node


func apply_quality() -> void:
	_quality_seen = GraphicsQuality.level
	_hulls.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if GraphicsQuality.shadows() else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_wakes.visible = GraphicsQuality.ferry_wake()


# --- sea surface ------------------------------------------------------------------------------

## Height of the sea's Gerstner swell at `p` (Godot XZ), the same sum as the
## y offset in the WATER shader. `time` is the shader TIME.
static func swell(p: Vector2, time: float, amp: float, dir: float, speed: float, wavelength: float) -> float:
	var y := 0.0
	var scale := [1.0, 0.45, 0.22]
	var len_scale := [1.0, 0.5, 0.27]
	var dir_off := [0.0, 0.9, -1.3]
	for k in 3:
		var kk := TAU / maxf(4.0, wavelength * float(len_scale[k]))
		var c := sqrt(9.8 / kk)
		var d := Vector2(sin(dir + float(dir_off[k])), cos(dir + float(dir_off[k])))
		y += amp * float(scale[k]) * sin(kk * d.dot(p) - c * kk * time * speed)
	return y


func _swell_at(p: Vector2) -> float:
	if GraphicsQuality.lite_shaders() or client == null or client.weather_view == null:
		return 0.0
	var w := client.weather_view
	var time := fposmod(Time.get_ticks_msec() / 1000.0, 3600.0)
	return swell(p, time, clampf(w.wave_m * 0.5, 0.02, 1.2), deg_to_rad(w.wave_dir), clampf(6.0 / maxf(w.wave_period, 1.5), 0.3, 3.0), clampf(w.wave_period * 4.0, 6.0, 60.0))


# --- frame ------------------------------------------------------------------------------------

## t: world time (seconds); me: the local player (horn range).
func update(t: float, me: Vector3) -> void:
	if GraphicsQuality.level != _quality_seen:
		apply_quality()
	var hulls := _hulls.multimesh
	var wakes := _wakes.multimesh
	var n := 0
	var w := 0
	for s: Ferries.Ship in ferries.ships:
		ferries.place(s, t)
		if _prev_t >= 0.0 and t - _prev_t < 3.0 and t > _prev_t and sounds != null and not s.away:
			if ferries.horn_between(s, _prev_t, t):
				sounds.ferry_horn(Vector3(s.pos.x, sea_level + 9.0, s.pos.y))
		if s.away:
			continue
		var fwd := s.dir
		var right := Vector2(-fwd.y, fwd.x)
		var h_mid := _swell_at(s.pos)
		var h_bow := _swell_at(s.pos + fwd * 11.0)
		var h_stern := _swell_at(s.pos - fwd * 11.0)
		var h_r := _swell_at(s.pos + right * 3.5)
		var h_l := _swell_at(s.pos - right * 3.5)
		var pitch := atan2(h_bow - h_stern, 22.0)
		var roll := atan2(h_r - h_l, 7.0) * 0.7
		var yaw := atan2(-fwd.x, -fwd.y)
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, pitch) * Basis(Vector3.BACK, roll)
		var pos := Vector3(s.pos.x, sea_level + h_mid * 0.9 + 0.1, s.pos.y)
		hulls.set_instance_transform(n, Transform3D(basis, pos))
		n += 1
		if s.speed > 0.4 and GraphicsQuality.ferry_wake():
			# The wake lies flat on the water behind the stern.
			var wb := Basis(Vector3.UP, yaw)
			wakes.set_instance_transform(w, Transform3D(wb, Vector3(s.pos.x, sea_level + h_mid * 0.9 + 0.25, s.pos.y)))
			wakes.set_instance_custom_data(w, Color(clampf(s.speed / Ferries.SPEED, 0.0, 1.0), 0, 0, 0))
			w += 1
	hulls.visible_instance_count = n
	wakes.visible_instance_count = w
	_prev_t = t


# --- models (forward is -Z, origin on the waterline below the centre) ---------------------------

static func _c(rgb: String, alpha: float) -> Color:
	var c := Color(rgb)
	return Color(c.r, c.g, c.b, alpha)


## A flat wake: a long V behind the stern (+Z); UV.x -1..1 across, UV.y 0..1 along.
static func wake_mesh() -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var rows := 12
	var z0 := 14.0
	var z1 := 110.0
	for i in rows:
		var f0 := float(i) / rows
		var f1 := float(i + 1) / rows
		var za := lerpf(z0, z1, f0)
		var zb := lerpf(z0, z1, f1)
		var wa := 3.5 + 20.0 * f0
		var wb := 3.5 + 20.0 * f1
		var quad := [[Vector3(-wa, 0, za), Vector2(-1, f0)], [Vector3(wa, 0, za), Vector2(1, f0)],
			[Vector3(wb, 0, zb), Vector2(1, f1)], [Vector3(-wb, 0, zb), Vector2(-1, f1)]]
		for k in [0, 2, 1, 0, 3, 2]:
			st.set_uv(quad[k][1])
			st.set_normal(Vector3.UP)
			st.add_vertex(quad[k][0])
	return st.commit()


static func hull_mesh() -> ArrayMesh:
	var m := MeshMerger.new()
	var white := "f1f1ee"
	var black := "1b1d21"
	var red := "b3191c"
	var stations := 16
	var half := Ferries.HULL_LENGTH * 0.5
	var ring: Array = []  # per station: Array of Vector3, left deck edge round the keel to the right deck edge
	for i in stations + 1:
		var z := -half + Ferries.HULL_LENGTH * float(i) / stations
		var f := z / half
		var b := 0.35 + (Ferries.HULL_BEAM * 0.5 - 0.35) * pow(maxf(0.0, 1.0 - pow(absf(f), 2.3)), 0.6)
		var yd := 2.3 + 0.9 * f * f
		var yk := -1.6 * (1.0 - 0.85 * pow(absf(f), 3.0))
		var bt := b * 1.05
		ring.append([
			Vector3(-bt, yd, z), Vector3(-bt * 0.995, yd - 0.4, z), Vector3(-b, 0.3, z), Vector3(-b * 0.8, yk * 0.55, z),
			Vector3(-b * 0.3, yk, z), Vector3(b * 0.3, yk, z), Vector3(b * 0.8, yk * 0.55, z), Vector3(b, 0.3, z),
			Vector3(bt * 0.995, yd - 0.4, z), Vector3(bt, yd, z)])
	# Colours of the nine strips between the ten ring points.
	var strip := [white, black, red, red, red, red, red, black, white]
	var deck_col := _c("8a7a63", A_PLAIN)
	for i in stations:
		var a: Array = ring[i]
		var b: Array = ring[i + 1]
		for k in 9:
			var mid: Vector3 = (a[k] + a[k + 1] + b[k] + b[k + 1]) * 0.25
			var out := Vector3(mid.x, 0.1, 0.0)
			if k >= 3 and k <= 5:
				out = Vector3(mid.x, -1.0, 0.0)
			m.quad("ship", a[k], a[k + 1], b[k + 1], b[k], _c(strip[k], A_PLAIN), out)
		m.quad("ship", a[0], a[9], b[9], b[0], deck_col, Vector3.UP)
	# Close the tips with a cap quad so no hole shows from the front.
	for i in [0, stations]:
		var r: Array = ring[i]
		var outward := Vector3(0, 0, -1 if i == 0 else 1)
		m.quad("ship", r[0], r[2], r[7], r[9], _c(black, A_PLAIN), outward)
		m.quad("ship", r[2], r[4], r[5], r[7], _c(red, A_PLAIN), outward)
	# Cabin decks.
	m.box("ship", Vector3(7.6, 2.6, 24.0), Vector3(0, 3.6, 0), _c(white, A_PLAIN))
	m.box("ship", Vector3(6.4, 2.3, 17.0), Vector3(0, 6.05, 0), _c(white, A_PLAIN))
	m.box("ship", Vector3(7.7, 0.95, 22.4), Vector3(0, 3.75, 0), _c("202a38", A_GLASS))
	m.box("ship", Vector3(6.5, 0.9, 15.4), Vector3(0, 6.1, 0), _c("202a38", A_GLASS))
	m.box("ship", Vector3(7.8, 0.18, 24.4), Vector3(0, 4.95, 0), _c("d8d8d4", A_PLAIN))  # roof edge of the lower deck
	m.box("ship", Vector3(6.6, 0.18, 17.4), Vector3(0, 7.25, 0), _c("d8d8d4", A_PLAIN))
	# Bridges at both ends (a double-ended ferry has two) with wings and masts.
	for sgn in [-1.0, 1.0]:
		var z: float = sgn * 7.4
		m.box("ship", Vector3(5.0, 2.0, 4.2), Vector3(0, 8.3, z), _c(white, A_PLAIN))
		m.box("ship", Vector3(5.15, 0.8, 3.6), Vector3(0, 8.45, z + sgn * 0.2), _c("202a38", A_GLASS))
		m.box("ship", Vector3(7.4, 0.2, 1.3), Vector3(0, 7.6, z), _c("8d9096", A_PLAIN))
		m.box("ship", Vector3(5.4, 0.2, 4.6), Vector3(0, 9.4, z), _c("8d9096", A_PLAIN))
		m.cylinder("ship", 0.07, 0.1, 5.0, Transform3D(Basis(), Vector3(0, 12.0, sgn * 7.0)), _c("8d9096", A_PLAIN))
		m.box("ship", Vector3(0.3, 0.3, 0.3), Vector3(0, 14.6, sgn * 7.0), _c("fff6d8", A_LAMP))
		# Navigation lamps on the tips and the bridge wings (green starboard, red port).
		m.box("ship", Vector3(0.4, 0.4, 0.4), Vector3(0, 3.4, sgn * (half - 0.4)), _c("fff6d8", A_LAMP))
	# Funnel: red with a black top, oval.
	var funnel := Basis().scaled(Vector3(1.0, 1.0, 1.7))
	m.cylinder("ship", 1.25, 1.45, 4.4, Transform3D(funnel, Vector3(0, 9.6, 0)), _c(red, A_PLAIN))
	m.cylinder("ship", 1.3, 1.26, 0.9, Transform3D(funnel, Vector3(0, 12.1, 0)), _c(black, A_PLAIN))
	# Lifeboats on the roof of the lower deck.
	for sx in [-1.0, 1.0]:
		for lz in [-4.6, 4.6]:
			m.box("ship", Vector3(1.1, 0.8, 5.0), Vector3(sx * 3.55, 5.5, lz), _c("e8650f", A_PLAIN))
	# Funnel-side life rafts and a flag-less stern post are left out on purpose: tiny
	# details are lost at ferry viewing distances.
	return m.commit("ship")
