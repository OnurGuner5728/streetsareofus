class_name CityMaterials
extends RefCounted
## Procedural surface shaders for the city. No texture files: patterns come
## from world-space coordinates, so nothing stretches and the phone download
## stays small. All shaders work in the Compatibility renderer (web, phones).
## `night` is a project-wide shader global driven by SkyController.

const COMMON := """
vec3 srgb(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
float hash12(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}
float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	vec2 u = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash12(i), hash12(i + vec2(1.0, 0.0)), u.x),
		mix(hash12(i + vec2(0.0, 1.0)), hash12(i + vec2(1.0, 1.0)), u.x), u.y);
}
float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 4; i++) {
		v += a * vnoise(p);
		p *= 2.03;
		a *= 0.5;
	}
	return v;
}
"""

const PAVERS := """
shader_type spatial;
varying vec3 wpos;
%s
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wpos.xz;
	vec2 q = p / vec2(0.40, 0.20);
	q.x += step(1.0, mod(floor(q.y), 2.0)) * 0.5;
	vec2 cell = floor(q);
	vec2 f = fract(q);
	float body = step(0.04, f.x) * step(f.x, 0.96) * step(0.08, f.y) * step(f.y, 0.92);
	float tone = hash12(cell) * 0.14 + fbm(p * 0.35) * 0.2;
	vec3 base = srgb(vec3(0.60, 0.58, 0.55)) * (0.8 + tone);
	float stain = smoothstep(0.55, 0.75, fbm(p * 0.12 + 7.0)) * 0.25;
	ALBEDO = mix(base * 0.55, base, body) * (1.0 - stain);
	ROUGHNESS = 0.92;
}
"""

const COBBLES := """
shader_type spatial;
varying vec3 wpos;
%s
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
	vec2 p = wpos.xz / 0.17;
	vec2 i = floor(p);
	vec2 f = fract(p);
	float d1 = 8.0;
	float d2 = 8.0;
	vec2 id = vec2(0.0);
	for (int y = -1; y <= 1; y++) {
		for (int x = -1; x <= 1; x++) {
			vec2 g = vec2(float(x), float(y));
			vec2 o = vec2(hash12(i + g), hash12(i + g + 17.3)) * 0.8 + 0.1;
			float d = length(g + o - f);
			if (d < d1) { d2 = d1; d1 = d; id = i + g; } else if (d < d2) { d2 = d; }
		}
	}
	float gap = smoothstep(0.0, 0.14, d2 - d1);
	vec3 stone = srgb(mix(vec3(0.44, 0.42, 0.39), vec3(0.63, 0.58, 0.51), hash12(id)));
	stone *= 0.82 + 0.25 * fbm(wpos.xz * 0.45);
	ALBEDO = mix(stone * 0.32, stone, gap);
	ROUGHNESS = mix(1.0, 0.7, gap);
}
"""

const ASPHALT := """
shader_type spatial;
varying vec3 wpos;
varying float marked;
%s
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; marked = COLOR.a; }
void fragment() {
	vec2 p = wpos.xz;
	float n = fbm(p * 1.6) * 0.45 + hash12(floor(p * 20.0)) * 0.12;
	vec3 base = srgb(vec3(0.19, 0.20, 0.21)) * (0.72 + n);
	float repair = smoothstep(0.60, 0.64, fbm(p * 0.07 + 3.1));
	base = mix(base, base * 1.35, repair * 0.6);
	float across = abs(UV.y - 0.5) * 2.0;
	float dash = step(fract(UV.x / 7.0), 0.45);
	float centre = (1.0 - smoothstep(0.025, 0.04, across)) * dash * step(0.5, marked);
	float kerb = smoothstep(0.93, 0.945, across) * (1.0 - smoothstep(0.965, 0.98, across)) * step(0.5, marked);
	float paint = max(centre, kerb) * (0.75 + 0.25 * vnoise(p * 4.0));
	ALBEDO = mix(base, srgb(vec3(0.9, 0.9, 0.86)), paint);
	ROUGHNESS = mix(0.95, 0.55, paint);
}
"""

const GRASS := """
shader_type spatial;
varying vec3 wpos;
varying vec3 tint;
%s
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; tint = COLOR.rgb; }
void fragment() {
	vec2 p = wpos.xz;
	float n = fbm(p * 0.9) * 0.6 + fbm(p * 7.0) * 0.4;
	vec3 base = srgb(tint);
	vec3 dry = srgb(vec3(0.55, 0.52, 0.32));
	ALBEDO = mix(base * (0.7 + 0.45 * n), dry, smoothstep(0.62, 0.8, fbm(p * 0.15)) * 0.45);
	ROUGHNESS = 1.0;
}
"""

const ZEBRA := """
shader_type spatial;
%s
void fragment() {
	float stripe = step(0.5, fract(UV.y * 5.0));
	float worn = vnoise(UV * vec2(12.0, 40.0));
	if (stripe < 0.5 || worn < 0.18) discard;
	ALBEDO = srgb(vec3(0.9, 0.9, 0.87));
	ROUGHNESS = 0.6;
}
"""

const WALLS := """
shader_type spatial;
global uniform float night;
uniform float floor_height = 3.1;
uniform float bay_width = 3.0;
varying vec4 v_color;
varying vec2 v_info;
varying vec3 wpos;
%s
void vertex() {
	v_color = COLOR;
	v_info = UV2;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec3 base = srgb(v_color.rgb);
	// Quantise first: interpolated vertex colours differ by float noise per
	// pixel, and a hash would turn that into speckles.
	vec3 key = floor(v_color.rgb * 255.0 + 0.5);
	float seed = hash12(key.xy + key.z * 0.137);
	float up = UV.y;
	float top = v_info.x;
	float edge_len = v_info.y;
	float bays = floor(edge_len / bay_width);
	float u = UV.x - (edge_len - bays * bay_width) * 0.5;
	float in_bays = step(0.0, u) * step(u, bays * bay_width) * step(1.0, bays) * step(up, top - 0.9);
	vec2 cell = vec2(fract(u / bay_width), fract(up / floor_height));
	vec2 cell_id = vec2(floor(u / bay_width), floor(up / floor_height));
	float shop = step(0.5, v_color.a) * (1.0 - step(0.5, cell_id.y));
	// Window style varies per building: narrow, wide, or tall french doors.
	float half_w = mix(0.19, 0.27, step(0.5, seed));
	float low = mix(0.30, 0.10, step(0.66, fract(seed * 7.0)));
	float high = mix(0.80, 0.86, seed);
	float dx = abs(cell.x - 0.5);
	float win = step(dx, half_w) * step(low, cell.y) * step(cell.y, high);
	float frame = step(dx, half_w + 0.035) * step(low - 0.035, cell.y) * step(cell.y, high + 0.035) - win;
	float sill = step(dx, half_w + 0.06) * step(low - 0.07, cell.y) * step(cell.y, low - 0.035);
	float shop_win = step(dx, 0.45) * step(0.04, cell.y) * step(cell.y, 0.68);
	float signboard = step(0.73, cell.y) * step(cell.y, 0.93) * step(dx, 0.49) * shop * in_bays;
	win = mix(win, shop_win, shop) * in_bays;
	float trim = clamp(frame + sill, 0.0, 1.0) * (1.0 - shop) * in_bays;
	float band = (1.0 - step(0.035, cell.y)) * step(0.5, cell_id.y);
	float plinth = 1.0 - step(0.55, up);
	float n = fbm(vec2(wpos.x + wpos.z, wpos.y) * 0.9);
	float grime = smoothstep(2.8, 0.0, up) * 0.16 + smoothstep(0.55, 0.9, fbm(vec2((wpos.x + wpos.z) * 2.5, wpos.y * 0.25))) * 0.2;
	vec3 wall = base * (0.86 + 0.22 * n) * (1.0 - grime);
	wall = mix(wall, wall * 0.8, band);
	wall = mix(wall, srgb(vec3(0.40, 0.38, 0.36)) * (0.8 + 0.3 * n), plinth);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 glass = mix(srgb(vec3(0.10, 0.14, 0.18)), srgb(vec3(0.55, 0.66, 0.78)), 0.2 + fres * 0.6);
	float r = hash12(cell_id + seed * 91.0);
	float lit = step(0.55, r) * night + shop * night * 0.8;
	vec3 lamp = srgb(mix(vec3(1.0, 0.76, 0.42), vec3(0.92, 0.9, 0.84), fract(r * 13.0)));
	vec3 sign_col = srgb(vec3(fract(seed * 3.1), fract(seed * 5.7), fract(seed * 9.3)) * 0.65 + 0.25);
	vec3 col = mix(wall, srgb(vec3(0.86, 0.86, 0.84)), trim);
	col = mix(col, sign_col, signboard);
	col = mix(col, glass, win);
	ALBEDO = col;
	ROUGHNESS = mix(0.9, 0.1, win);
	SPECULAR = mix(0.25, 0.85, win);
	EMISSION = lamp * win * lit * 1.1 + sign_col * signboard * night * 0.9;
}
"""

const ROOF := """
shader_type spatial;
varying vec3 wpos;
varying vec3 tint;
%s
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; tint = COLOR.rgb; }
void fragment() {
	vec2 p = wpos.xz;
	float n = fbm(p * 0.7) * 0.5 + hash12(floor(p * 12.0)) * 0.12;
	float stain = smoothstep(0.55, 0.8, fbm(p * 0.2 + 11.0));
	ALBEDO = srgb(tint) * (0.75 + n) * (1.0 - stain * 0.35);
	ROUGHNESS = 0.95;
}
"""

const LEAVES := """
shader_type spatial;
varying vec3 wpos;
%s
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float sway = sin(TIME * 1.1 + wpos.x * 0.3 + wpos.z * 0.2) * 0.06 + sin(TIME * 2.3 + wpos.y) * 0.02;
	VERTEX.x += sway * max(VERTEX.y + 1.0, 0.0);
}
void fragment() {
	float n = fbm(wpos.xz * 2.5 + wpos.y * 1.7);
	vec3 base = srgb(COLOR.rgb);
	ALBEDO = base * (0.6 + 0.6 * n) * mix(0.7, 1.0, clamp(NORMAL.y * 0.5 + 0.5, 0.0, 1.0));
	ROUGHNESS = 0.9;
	BACKLIGHT = base * 0.3;
}
"""

const LAMP_HEAD := """
shader_type spatial;
global uniform float night;
void fragment() {
	ALBEDO = vec3(0.9, 0.85, 0.7);
	EMISSION = vec3(1.0, 0.78, 0.45) * (0.05 + 5.0 * night);
}
"""

static var _cache := {}


static func get_shader(key: String) -> ShaderMaterial:
	if _cache.has(key):
		return _cache[key]
	var code: String = {
		"pavers": PAVERS, "cobbles": COBBLES, "asphalt": ASPHALT, "grass": GRASS, "zebra": ZEBRA,
		"walls": WALLS, "roof": ROOF, "leaves": LEAVES, "lamp_head": LAMP_HEAD,
	}[key]
	if code.contains("%s"):
		code = code % COMMON
	var shader := Shader.new()
	shader.code = code
	var mat := ShaderMaterial.new()
	mat.shader = shader
	_cache[key] = mat
	return mat


static func solid(color: Color, roughness := 0.8, metallic := 0.0) -> StandardMaterial3D:
	var key := "s%s%.2f%.2f" % [color.to_html(), roughness, metallic]
	if not _cache.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = roughness
		m.metallic = metallic
		_cache[key] = m
	return _cache[key]


static func instanced(roughness := 0.85) -> StandardMaterial3D:
	var key := "inst%.2f" % roughness
	if not _cache.has(key):
		var m := StandardMaterial3D.new()
		m.vertex_color_use_as_albedo = true
		m.vertex_color_is_srgb = true
		m.roughness = roughness
		_cache[key] = m
	return _cache[key]


static func glass() -> StandardMaterial3D:
	if not _cache.has("glass"):
		var m := StandardMaterial3D.new()
		m.albedo_color = Color(0.75, 0.85, 0.9, 0.16)
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.roughness = 0.1
		m.metallic = 0.0
		_cache["glass"] = m
	return _cache["glass"]
