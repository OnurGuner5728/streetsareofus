class_name CityMaterials
extends RefCounted
## Procedural surface shaders for the city. Ground, roads and vegetation are
## pure maths on world-space coordinates, so nothing stretches and the phone
## download stays small; building walls and roofs also carry a few small CC0
## photo textures (assets/textures, ambientCG, under 200 KB in total) that
## only modulate the palette colours. All shaders work in the Compatibility
## renderer (web, phones).
## `night` is a project-wide shader global driven by SkyController.
## Every shader also compiles a LITE variant (one noise octave, no Voronoi,
## no normal maps) that low-end phones switch to at runtime.

const COMMON := """
global uniform float wetness;
global uniform float snow;
// Rain darkens and polishes a surface; snow settles on it.
void weather(inout vec3 albedo, inout float rough, float soak) {
	albedo *= 1.0 - 0.42 * wetness * soak;
	rough = mix(rough, 0.28, wetness * soak * 0.75);
	albedo = mix(albedo, vec3(0.88, 0.9, 0.93), snow * 0.85);
	rough = mix(rough, 0.8, snow);
}
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
#ifdef LITE
float fbm(vec2 p) { return vnoise(p) * 0.9375; }
#else
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
#endif
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
	vec3 col = mix(base * 0.55, base, body) * (1.0 - stain);
	float rough = 0.92;
	weather(col, rough, 1.0);
	ALBEDO = col;
	ROUGHNESS = rough;
}
"""

const COBBLES := """
shader_type spatial;
varying vec3 wpos;
%s
void vertex() { wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz; }
void fragment() {
#ifdef LITE
	// Staggered rounded setts: same look from walking height, no cell search.
	vec2 q = wpos.xz / vec2(0.19, 0.16);
	q.x += step(1.0, mod(floor(q.y), 2.0)) * 0.5;
	vec2 cell = floor(q);
	vec2 e = abs(fract(q) - 0.5) * 2.0;
	float gap = 1.0 - smoothstep(0.72, 0.95, max(e.x, e.y * 1.1));
	vec3 stone = srgb(mix(vec3(0.44, 0.42, 0.39), vec3(0.63, 0.58, 0.51), hash12(cell)));
	vec3 col = mix(stone * 0.32, stone, gap);
	float rough = mix(1.0, 0.7, gap);
	weather(col, rough, 1.0);
	ALBEDO = col;
	ROUGHNESS = rough;
#else
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
	vec3 col = mix(stone * 0.32, stone, gap);
	float rough = mix(1.0, 0.7, gap);
	weather(col, rough, 1.0);
	ALBEDO = col;
	ROUGHNESS = rough;
#endif
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
	vec3 col = mix(base, srgb(vec3(0.9, 0.9, 0.86)), paint);
	float rough = mix(0.95, 0.55, paint);
	// Puddles gather in the dips once the road is properly wet.
	float puddle = smoothstep(0.54, 0.6, fbm(p * 0.22 + 5.0)) * smoothstep(0.35, 0.9, wetness) * (1.0 - snow);
	weather(col, rough, 1.0);
	col = mix(col, col * 0.4, puddle);
	rough = mix(rough, 0.03, puddle);
	ALBEDO = col;
	ROUGHNESS = rough;
	SPECULAR = mix(0.5, 0.95, puddle);
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
#ifdef LITE
	float n = vnoise(p * 0.9) * 0.6 + 0.2;
#else
	float n = fbm(p * 0.9) * 0.6 + fbm(p * 7.0) * 0.4;
#endif
	vec3 base = srgb(tint);
	vec3 dry = srgb(vec3(0.55, 0.52, 0.32));
	vec3 col = mix(base * (0.7 + 0.45 * n), dry, smoothstep(0.62, 0.8, fbm(p * 0.15)) * 0.45);
	float rough = 1.0;
	weather(col, rough, 0.5);
	ALBEDO = col;
	ROUGHNESS = rough;
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
uniform sampler2D tex_plaster : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D tex_brick : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D tex_stone : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D nrm_plaster : repeat_enable, filter_linear_mipmap;
uniform sampler2D nrm_brick : repeat_enable, filter_linear_mipmap;
varying vec4 v_color;
varying vec2 v_info;
varying vec3 wpos;
%s
// 1 inside (v < 0), 0 outside, with an anti-aliased edge `aa` wide.
float edge_mask(float v, float aa) { return clamp(0.5 - v / aa, 0.0, 1.0); }
void vertex() {
	v_color = COLOR;
	v_info = UV2;
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
#ifndef LITE
	// Tangent frame of the facade normal maps: U runs along the wall, V up
	// it. Derived from the normal so the meshes carry no tangents.
	vec3 t = cross(vec3(0.0, 1.0, 0.0), NORMAL);
	t = length(t) > 0.01 ? normalize(t) : vec3(1.0, 0.0, 0.0);
	TANGENT = t;
	BINORMAL = cross(NORMAL, t);
#endif
}
void fragment() {
	// Vertex alpha: bit 3 = wall faces a street, bit 0 = shopfront, bits 1-2 = material.
	float code = floor(v_color.a * 15.0 + 0.5);
	float street = step(8.0, code);
	code -= street * 8.0;
	float shop_edge = mod(code, 2.0);
	float mtl = floor(code * 0.5);
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
	float in_bays = step(0.0, u) * step(u, bays * bay_width) * step(1.0, bays) * step(up, top - 0.9) * step(0.0, up);
	vec2 cell = vec2(fract(u / bay_width), fract(up / floor_height));
	vec2 cell_id = vec2(floor(u / bay_width), floor(up / floor_height));
	float ground = 1.0 - step(0.5, cell_id.y);
	float shopf = shop_edge * ground;

	// Facade material: the texture only modulates the vertex colour (which
	// is the facade's average colour), so hues stay under the palette's control.
	vec2 tuv = vec2(UV.x, -UV.y);
	vec2 dux = dFdx(tuv);
	vec2 duy = dFdy(tuv);
	vec3 texel = vec3(1.0);
	vec3 avg = vec3(1.0);
	vec3 nm = vec3(0.5, 0.5, 1.0);
	float nstr = 0.0;
	if (mtl > 0.5 && mtl < 1.5) {
		texel = textureGrad(tex_brick, tuv / 2.0, dux / 2.0, duy / 2.0).rgb;
		avg = vec3(0.311, 0.198, 0.143);
#ifndef LITE
		nm = textureGrad(nrm_brick, tuv / 2.0, dux / 2.0, duy / 2.0).rgb;
		nstr = 1.0;
#endif
	} else if (mtl > 1.5 && mtl < 2.5) {
		texel = textureGrad(tex_stone, tuv / 3.0, dux / 3.0, duy / 3.0).rgb;
		avg = vec3(0.700, 0.462, 0.273);
	} else {
		texel = textureGrad(tex_plaster, tuv / 2.5, dux / 2.5, duy / 2.5).rgb;
		avg = vec3(0.696, 0.669, 0.640);
#ifndef LITE
		nm = textureGrad(nrm_plaster, tuv / 2.5, dux / 2.5, duy / 2.5).rgb;
		nstr = 0.8;
#endif
	}
	float lum_t = dot(texel, vec3(0.299, 0.587, 0.114));
	float lum_a = dot(avg, vec3(0.299, 0.587, 0.114));
	vec3 ratio = clamp(mix(vec3(lum_t / lum_a), texel / avg, 0.4), vec3(0.3), vec3(2.0));

	// Openings. Sizes in metres from the floor: window style varies per
	// building (narrow, wide, tall french doors); shopfronts are wide and
	// low; every so often a bay of the ground floor is the entrance door.
	float wide = step(0.5, seed);
	float french = step(0.66, fract(seed * 7.0));
	vec2 wm = vec2((cell.x - 0.5) * bay_width, cell.y * floor_height);
	float sill_y = mix(0.93, 0.15, french);
	float head_y = mix(2.45, 2.7, fract(seed * 3.7));
	vec2 open_c = vec2(0.0, (sill_y + head_y) * 0.5);
	vec2 open_h = vec2(mix(0.55, 0.8, wide), (head_y - sill_y) * 0.5);
	float door_bay = floor(fract(seed * 5.31 + edge_len * 0.173) * bays);
	float is_door = ground * street * (1.0 - shop_edge) * step(2.0, bays) * (1.0 - step(0.5, abs(cell_id.x - door_bay)));
	french *= (1.0 - shopf) * (1.0 - is_door);
	open_c = mix(open_c, vec2(0.0, 1.2), shopf);
	open_h = mix(open_h, vec2(1.3, 0.9), shopf);
	open_c = mix(open_c, vec2(0.0, 1.06), is_door);
	open_h = mix(open_h, vec2(0.55, 1.06), is_door);
	vec2 d = abs(wm - open_c) - open_h;
	float sd = max(d.x, d.y);
	float aa = fwidth(sd) * 1.2 + 0.002;
	float inside = edge_mask(sd, aa) * in_bays;
	float glass_m = edge_mask(sd + 0.07, aa) * in_bays;
	float frame_m = inside - glass_m;
	float ring_m = edge_mask(sd - 0.09, aa) * in_bays - inside;
	// Sash bars: vertical ones split the opening, a transom cuts tall ones.
	float nsash = mix(2.0 + wide, 3.0, shopf);
	float fx = (wm.x - open_c.x + open_h.x) / (2.0 * open_h.x) * nsash;
	float mull = 1.0 - smoothstep(0.0, 0.03 + aa, abs(fx - floor(fx + 0.5)) * (2.0 * open_h.x / nsash));
	float has_transom = step(0.3, fract(seed * 9.1)) * (1.0 - is_door);
	float transom = (1.0 - smoothstep(0.0, 0.025 + aa, abs(wm.y - (open_c.y + open_h.y * 0.45)))) * has_transom;
	float bars = clamp(mull + transom, 0.0, 1.0) * (1.0 - is_door);
	float win = glass_m * (1.0 - bars) * (1.0 - is_door);

	// Sill slab under ordinary windows, a stone surround for the door.
	float sill_m = edge_mask(abs(wm.x - open_c.x) - (open_h.x + 0.1), aa) * step(open_c.y - open_h.y - 0.12, wm.y)
		* step(wm.y, open_c.y - open_h.y) * in_bays * (1.0 - french) * (1.0 - is_door) * (1.0 - shopf);
	float surround = (edge_mask(sd - 0.16, aa) * in_bays - inside) * is_door;

	// The recess: the inner face of the opening shows on the side away from
	// the viewer and under the lintel; no parallax, just shading and a bevel.
	vec3 nw = normalize((INV_VIEW_MATRIX * vec4(NORMAL, 0.0)).xyz);
	vec3 tw = normalize(cross(vec3(0.0, 1.0, 0.0), nw) + vec3(0.00001));
	float side = dot(normalize((INV_VIEW_MATRIX * vec4(VIEW, 0.0)).xyz), tw);
	float rx = wm.x - open_c.x;
	float vis_side = step(0.0, -rx * side);
	float top_side = step(0.0, wm.y - open_c.y);
	float reveal = ring_m * mix(mix(0.12, 0.42, vis_side), 0.5, top_side);

	float band = (1.0 - step(0.035, cell.y)) * step(0.5, cell_id.y) * step(0.5, fract(seed * 13.7));
	float plinth = 1.0 - step(0.55, up);
	float n = fbm(vec2(wpos.x + wpos.z, wpos.y) * 0.9);
#ifdef LITE
	float grime = smoothstep(2.8, 0.0, up) * 0.16;
#else
	float grime = smoothstep(2.8, 0.0, up) * 0.16 + smoothstep(0.55, 0.9, fbm(vec2((wpos.x + wpos.z) * 2.5, wpos.y * 0.25))) * 0.2;
#endif
	// Rain streaks under every sill.
	float streak = in_bays * step(abs(wm.x - open_c.x), open_h.x) * step(wm.y, open_c.y - open_h.y)
		* smoothstep(1.1, 0.0, open_c.y - open_h.y - wm.y) * (1.0 - french) * (1.0 - is_door);
	vec3 wall = base * ratio * (0.9 + 0.16 * n) * (1.0 - grime) * (1.0 - 0.07 * streak);
	wall = mix(wall, wall * 0.8, band);
	wall = mix(wall, srgb(vec3(0.40, 0.38, 0.36)) * (0.8 + 0.3 * n), plinth);
	// Shopfront piers and fascia read darker than the storeys above.
	wall = mix(wall, wall * 0.78, shopf * (1.0 - inside));
	wall *= 1.0 - reveal;

	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 3.0);
	vec3 glass = mix(srgb(vec3(0.10, 0.14, 0.18)), srgb(vec3(0.55, 0.66, 0.78)), 0.2 + fres * 0.6);
	float r = hash12(cell_id + seed * 91.0);
	// Curtains on some windows: a light cloth over the upper part of the glass.
	float curtain = step(0.65, fract(r * 23.0)) * (1.0 - shopf) * smoothstep(open_c.y - open_h.y * 0.3, open_c.y + open_h.y * 0.1, wm.y);
	vec3 cloth = srgb(mix(vec3(0.88, 0.82, 0.70), vec3(0.62, 0.68, 0.78), fract(r * 7.0)));
	glass = mix(glass, cloth * 0.8, curtain * 0.85);
	// Shade under the lintel and at the sides: the glass sits deep in the wall.
	glass *= 1.0 - 0.5 * smoothstep(0.3, 0.0, open_c.y + open_h.y - wm.y) - 0.3 * smoothstep(0.2, 0.0, open_h.x - abs(wm.x - open_c.x));

	float signboard = step(2.26, wm.y) * step(wm.y, 2.88) * step(abs(wm.x), 1.47) * shopf * in_bays;
	float lit = step(0.55, r) * night + shopf * night * 0.8;
	vec3 lamp = srgb(mix(vec3(1.0, 0.76, 0.42), vec3(0.92, 0.9, 0.84), fract(r * 13.0)));
	lamp = mix(lamp, srgb(vec3(1.0, 0.86, 0.6)), curtain);
	vec3 sign_col = srgb(vec3(fract(seed * 3.1), fract(seed * 5.7), fract(seed * 9.3)) * 0.65 + 0.25);
	vec3 frame_col = mix(srgb(vec3(0.92, 0.91, 0.88)), srgb(vec3(0.28, 0.20, 0.14)), step(0.7, fract(seed * 11.3)));
	frame_col = mix(frame_col, srgb(vec3(0.16, 0.16, 0.17)), shopf);
	vec3 door_col = mix(srgb(vec3(0.23, 0.16, 0.11)), srgb(vec3(0.12, 0.2, 0.15)), step(0.5, fract(seed * 17.3)));

	vec3 col = wall;
	col = mix(col, srgb(vec3(0.84, 0.82, 0.78)), max(sill_m, surround));
	col = mix(col, glass, glass_m);
	col = mix(col, frame_col, frame_m);
	col = mix(col, frame_col, glass_m * bars);
	col = mix(col, door_col, glass_m * is_door);
	col = mix(col, sign_col, signboard);
	// Juliet railing over the french doors: top rail and thin bars.
	float bar_x = 1.0 - smoothstep(0.0, 0.02 + aa, abs(fract(wm.x / 0.13 + 0.5) - 0.5) * 0.13);
	float rail_area = step(abs(wm.x - open_c.x), open_h.x + 0.06) * step(0.22, wm.y) * step(wm.y, 1.0) * in_bays * french;
	float rail_m = rail_area * clamp(step(0.94, wm.y) + bar_x * step(wm.y, 0.94), 0.0, 1.0);
	col = mix(col, srgb(vec3(0.13, 0.14, 0.15)), rail_m);
	float glass_face = win * (1.0 - rail_m);

#ifndef LITE
	// Facade relief from the normal map, plus a bevel around each opening
	// and flat glass.
	vec2 nxy = (nm.xy * 2.0 - 1.0) * nstr;
	vec2 bev = d.x > d.y ? vec2(-sign(wm.x - open_c.x), 0.0) : vec2(0.0, -sign(wm.y - open_c.y));
	nxy += bev * ring_m * 0.9;
	nxy *= 1.0 - glass_m;
	vec3 nn = normalize(vec3(nxy, max(nm.z * 2.0 - 1.0, 0.25)));
	NORMAL_MAP = nn * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
#endif
	ALBEDO = col;
	ROUGHNESS = mix(0.9, 0.1, glass_face);
	SPECULAR = mix(0.25, 0.85, glass_face);
	EMISSION = lamp * glass_face * lit * 1.1 + sign_col * signboard * night * 0.9;
}
"""

const ROOF := """
shader_type spatial;
uniform sampler2D tex_tiles : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D tex_flat : source_color, repeat_enable, filter_linear_mipmap;
uniform sampler2D nrm_tiles : repeat_enable, filter_linear_mipmap;
uniform sampler2D nrm_flat : repeat_enable, filter_linear_mipmap;
varying vec3 wpos;
varying vec3 tint;
varying float surf;
%s
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	tint = COLOR.rgb;
	surf = COLOR.a;
#ifndef LITE
	vec3 t = cross(vec3(0.0, 1.0, 0.0), NORMAL);
	t = length(t) > 0.01 ? normalize(t) : vec3(1.0, 0.0, 0.0);
	TANGENT = t;
	BINORMAL = cross(NORMAL, t);
#endif
}
// Vertex alpha picks the surface: 0 flat roof (asphalt, world-space texture),
// 1 clay tiles, 2 metal sheet, 3 plaster, 4 brick (chimneys).
void fragment() {
	float kind = floor(surf * 15.0 + 0.5);
	vec3 base = srgb(tint);
	vec2 p = wpos.xz;
	vec2 tc = kind < 0.5 ? p : vec2(UV.x, -UV.y);
	vec2 dcx = dFdx(tc);
	vec2 dcy = dFdy(tc);
	float stain = smoothstep(0.55, 0.8, fbm(p * 0.2 + 11.0));
	float n = fbm(p * 0.7);
	vec3 col = base;
	vec3 nm = vec3(0.5, 0.5, 1.0);
	float nstr = 0.0;
	float rough = 0.95;
	if (kind < 0.5) {
		vec3 texel = textureGrad(tex_flat, tc / 3.0, dcx / 3.0, dcy / 3.0).rgb;
		float ratio = dot(texel, vec3(0.299, 0.587, 0.114)) / 0.19;
		col = base * clamp(ratio, 0.3, 2.0) * (0.8 + 0.4 * n) * (1.0 - stain * 0.35);
#ifndef LITE
		nm = textureGrad(nrm_flat, tc / 3.0, dcx / 3.0, dcy / 3.0).rgb;
		nstr = 0.6;
#endif
	} else if (kind < 1.5) {
		vec3 texel = textureGrad(tex_tiles, tc / 2.4, dcx / 2.4, dcy / 2.4).rgb;
		vec3 avg = vec3(0.382, 0.118, 0.063);
		float lum_t = dot(texel, vec3(0.299, 0.587, 0.114));
		float lum_a = dot(avg, vec3(0.299, 0.587, 0.114));
		vec3 ratio = clamp(mix(vec3(lum_t / lum_a), texel / avg, 0.35), vec3(0.3), vec3(2.0));
		// Every tile is a little different, and the old ones grow dark patches.
		float per_tile = 0.86 + 0.28 * hash12(floor(tc / 0.2));
		col = base * ratio * per_tile * (0.85 + 0.3 * n) * (1.0 - stain * 0.3);
#ifndef LITE
		nm = textureGrad(nrm_tiles, tc / 2.4, dcx / 2.4, dcy / 2.4).rgb;
		nstr = 1.0;
#endif
	} else if (kind < 2.5) {
		// Standing-seam sheet metal: a seam every 55 cm.
		float seam = 1.0 - smoothstep(0.0, 0.03, abs(fract(UV.x / 0.55) - 0.5) - 0.47);
		col = base * (0.85 + 0.25 * n) * (1.0 - 0.25 * seam) * (1.0 - stain * 0.2);
		rough = 0.5;
	} else if (kind < 3.5) {
		col = base * (0.85 + 0.3 * n);
	} else {
		vec2 bq = vec2(UV.x / 0.24, -UV.y / 0.075);
		bq.x += step(1.0, mod(floor(bq.y), 2.0)) * 0.5;
		vec2 bf = fract(bq);
		float body = step(0.06, bf.x) * step(0.14, bf.y);
		vec3 mortar = srgb(vec3(0.62, 0.6, 0.56));
		col = mix(mortar, base * (0.8 + 0.4 * hash12(floor(bq))), body);
	}
	weather(col, rough, 0.8);
#ifndef LITE
	vec2 nxy = (nm.xy * 2.0 - 1.0) * nstr;
	NORMAL_MAP = normalize(vec3(nxy, max(nm.z * 2.0 - 1.0, 0.25))) * 0.5 + 0.5;
	NORMAL_MAP_DEPTH = 1.0;
#endif
	ALBEDO = col;
	ROUGHNESS = rough;
}
"""

const LEAVES := """
shader_type spatial;
global uniform float wind;
varying vec3 wpos;
%s
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	float gust = 0.4 + wind * 1.8;
	float sway = (sin(TIME * (1.1 + wind) + wpos.x * 0.3 + wpos.z * 0.2) * 0.06 + sin(TIME * 2.3 + wpos.y) * 0.02) * gust;
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

## The sea surface. `amp`/`wave_dir`/`speed`/`wavelength` are driven every
## frame from the zone's real weather (see WeatherView and the Open-Meteo
## Marine fetch in weather_service.gd). The full variant displaces vertices
## with a sum of Gerstner waves; LITE (low-end phones, web) only scrolls a
## cheap normal-mapped ripple in the fragment shader, no vertex cost.
const WATER := """
shader_type spatial;
render_mode blend_mix, cull_disabled, shadows_disabled;
uniform float amp = 0.12;
uniform float wave_dir = 0.0;
uniform float speed = 1.0;
uniform float wavelength = 18.0;
varying vec3 wpos;
%s
#ifdef LITE
void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}
void fragment() {
	vec2 p = wpos.xz * 0.05;
	vec2 flow = vec2(sin(wave_dir), cos(wave_dir)) * TIME * speed * 0.06;
	float n = vnoise(p + flow) * 0.6 + vnoise(p * 2.3 - flow * 1.6) * 0.4;
	vec3 deep = srgb(vec3(0.06, 0.16, 0.24));
	vec3 shallow = srgb(vec3(0.16, 0.34, 0.40));
	vec3 col = mix(deep, shallow, n);
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(col, vec3(1.0), fres * 0.5);
	ROUGHNESS = 0.15;
	SPECULAR = 0.6;
	ALPHA = 0.92;
}
#else
// Three Gerstner waves (long swell to short chop) summed for the vertex
// offset and its analytic normal. See GPU Gems ch. 1 for the derivation.
vec3 gerstner(vec2 p, float t, out vec3 n) {
	float k1 = 6.283185 / max(4.0, wavelength);
	float k2 = 6.283185 / max(4.0, wavelength * 0.5);
	float k3 = 6.283185 / max(4.0, wavelength * 0.27);
	float c1 = sqrt(9.8 / k1);
	float c2 = sqrt(9.8 / k2);
	float c3 = sqrt(9.8 / k3);
	vec2 d1 = vec2(sin(wave_dir), cos(wave_dir));
	vec2 d2 = vec2(sin(wave_dir + 0.9), cos(wave_dir + 0.9));
	vec2 d3 = vec2(sin(wave_dir - 1.3), cos(wave_dir - 1.3));
	float a1 = amp;
	float a2 = amp * 0.45;
	float a3 = amp * 0.22;
	float f1 = k1 * dot(d1, p) - c1 * k1 * t * speed;
	float f2 = k2 * dot(d2, p) - c2 * k2 * t * speed;
	float f3 = k3 * dot(d3, p) - c3 * k3 * t * speed;
	float q1 = min(0.5, 1.0 / (k1 * a1 * 3.0 + 0.001));
	float q2 = min(0.5, 1.0 / (k2 * a2 * 3.0 + 0.001));
	float q3 = min(0.5, 1.0 / (k3 * a3 * 3.0 + 0.001));
	vec3 off = vec3(0.0);
	off.x = q1 * a1 * d1.x * cos(f1) + q2 * a2 * d2.x * cos(f2) + q3 * a3 * d3.x * cos(f3);
	off.z = q1 * a1 * d1.y * cos(f1) + q2 * a2 * d2.y * cos(f2) + q3 * a3 * d3.y * cos(f3);
	off.y = a1 * sin(f1) + a2 * sin(f2) + a3 * sin(f3);
	float nx = d1.x * k1 * a1 * cos(f1) + d2.x * k2 * a2 * cos(f2) + d3.x * k3 * a3 * cos(f3);
	float nz = d1.y * k1 * a1 * cos(f1) + d2.y * k2 * a2 * cos(f2) + d3.y * k3 * a3 * cos(f3);
	n = normalize(vec3(-nx, 1.0, -nz));
	return off;
}
void vertex() {
	vec3 world = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	vec3 n;
	vec3 off = gerstner(world.xz, TIME, n);
	VERTEX += off;
	NORMAL = n;
	wpos = world + off;
}
void fragment() {
	vec3 deep = srgb(vec3(0.05, 0.14, 0.22));
	vec3 shallow = srgb(vec3(0.18, 0.38, 0.42));
	float n = fbm(wpos.xz * 0.08 + TIME * 0.02);
	vec3 col = mix(deep, shallow, clamp(n, 0.0, 1.0));
	float fres = pow(1.0 - clamp(dot(NORMAL, VIEW), 0.0, 1.0), 4.0);
	ALBEDO = mix(col, vec3(1.0), fres * 0.55);
	ROUGHNESS = 0.08;
	SPECULAR = 0.85;
	ALPHA = 0.94;
}
#endif
"""

## Shader key -> {sampler uniform: file under assets/textures}. Albedo maps
## are 256-512 px JPEGs, normals RGB (no RG packing) so ETC2/ASTC/S3TC all read them.
const TEXTURES := {
	"walls": {
		"tex_plaster": "facade_plaster_albedo", "tex_brick": "facade_brick_albedo", "tex_stone": "facade_stone_albedo",
		"nrm_plaster": "facade_plaster_normal", "nrm_brick": "facade_brick_normal",
	},
	"roof": {
		"tex_tiles": "roof_tiles_albedo", "tex_flat": "roof_flat_albedo",
		"nrm_tiles": "roof_tiles_normal", "nrm_flat": "roof_flat_normal",
	},
}

static var _cache := {}
static var _variants := {}  # key -> [full Shader, lite Shader]
static var lite := false


static func get_shader(key: String) -> ShaderMaterial:
	if _cache.has(key):
		return _cache[key]
	var code: String = {
		"pavers": PAVERS, "cobbles": COBBLES, "asphalt": ASPHALT, "grass": GRASS, "zebra": ZEBRA,
		"walls": WALLS, "roof": ROOF, "leaves": LEAVES, "lamp_head": LAMP_HEAD, "water": WATER,
	}[key]
	if code.contains("%s"):
		code = code % COMMON
	var full := Shader.new()
	full.code = code
	var cheap := Shader.new()
	cheap.code = code.replace("shader_type spatial;", "shader_type spatial;
#define LITE")
	_variants[key] = [full, cheap]
	var mat := ShaderMaterial.new()
	mat.shader = cheap if lite else full
	for uniform_name in TEXTURES.get(key, {}):
		mat.set_shader_parameter(uniform_name, load("res://assets/textures/%s.jpg" % TEXTURES[key][uniform_name]))
	_cache[key] = mat
	return mat


## Switches every city surface between the full and the LITE shaders.
static func set_lite(on: bool) -> void:
	lite = on
	for key in _variants:
		(_cache[key] as ShaderMaterial).shader = _variants[key][1 if on else 0]


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
