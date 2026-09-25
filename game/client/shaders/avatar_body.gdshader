shader_type spatial;
// Dresses and shapes the Universal Base Characters body (CC0).
// CUSTOM0 = the vertex's T-pose position (skeleton space, metres, +Z is the
// front, +X the character's left) and its body region (baked by
// tools/bake_avatar_anims.gd): 0 torso, 1 arm, 2 hand, 3 leg, 4 foot,
// 5 neck, 6 head. Because the rest pose is a T-pose, sleeve length is just
// |x| and a trouser hem is just y.

uniform sampler2D skin_tex : source_color, filter_linear_mipmap, repeat_disable;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap, repeat_disable;
uniform vec3 skin_tint = vec3(1.0);
uniform vec3 top_color : source_color = vec3(0.23, 0.43, 0.65);
uniform vec3 top_color2 : source_color = vec3(0.9);
uniform vec3 bottom_color : source_color = vec3(0.18, 0.23, 0.33);
uniform vec3 shoe_color : source_color = vec3(0.9);
uniform vec3 sole_color : source_color = vec3(0.92);
uniform vec3 face_hair_color : source_color = vec3(0.2, 0.15, 0.1);

// Landmarks (skeleton space).
uniform vec4 lm_y = vec4(1.52, 1.31, 1.07, 0.95);   // neck, chest, waist, pelvis
uniform vec4 lm_x = vec4(0.21, 0.46, 0.71, 0.11);   // shoulder, elbow, wrist, hip x
uniform vec4 lm_y2 = vec4(0.54, 0.09, 1.60, 1.81);  // knee, ankle, head, top

// Clothes (set per style by AvatarView).
uniform float sleeve_x = 0.4;        // sleeves end at |x| (0: none)
uniform float top_hem_y = 0.93;      // lowest point of the top
uniform float neck_front = 0.06;     // neckline depth at the front
uniform float neck_high = 0.0;       // >0: collar up the neck (hoodie, coat)
uniform float open_front = 0.0;      // jacket/coat opening half-width
uniform float bare_shoulders = 0.0;  // tank top straps
uniform float top_thick = 0.006;
uniform float top_drape = 0.8;        // 0 skin-tight .. 1 fills the body's grooves
uniform float bottom_drape = 0.6;
uniform float top_rough = 0.85;
uniform int pattern = 0;             // 0 plain, 1 stripes, 2 two tone, 3 placket (shirt), 4 zip (hoodie)
uniform float bottom_waist_y = 1.0;
uniform float bottom_hem_y = 0.1;
uniform float bottom_thick = 0.005;
uniform float denim = 0.0;
uniform float shoe_top_y = 0.12;
uniform float shoe_thick = 0.012;
uniform float sandal = 0.0;
uniform int face_hair = 0;           // 0 none, 1 stubble, 2 mustache, 3 goatee, 4 short beard

// Body shape, as offsets from the default avatar.
uniform float weight_d = 0.0;
uniform float muscle_d = 0.0;
uniform float chest_d = 0.0;
uniform float hips_d = 0.0;
uniform float shoulders_d = 0.0;
uniform float female = 0.0;

varying vec3 rest;
varying flat int region;

float bump(float v, float c, float w) {
	float d = (v - c) / w;
	return exp(-d * d);
}

// 0 skin, 1 top, 2 bottom, 3 shoe, 4 top colour 2 (inner shirt, placket)
int cloth(vec3 p, int r) {
	float ax = abs(p.x);
	if (r == 4 || (r == 3 && p.y < shoe_top_y)) {
		if (sandal > 0.5) {
			return (p.y < 0.025 || fract(p.z * 22.0) < 0.3) ? 3 : 0;
		}
		return 3;
	}
	if (r == 3) {
		if (p.y >= top_hem_y) return 1;
		return p.y > bottom_hem_y ? 2 : 0;
	}
	if (r == 0) {
		// The neckline dips at the front; away from the neck the top reaches over the shoulders.
		float neckline = lm_y.x - 0.02 - (p.z > 0.0 ? neck_front * (1.0 - smoothstep(0.0, 0.1, ax)) : 0.0)
			+ smoothstep(0.06, 0.11, ax) * 0.3;
		bool in_top = p.y >= top_hem_y && p.y < neckline + neck_high;
		if (in_top && bare_shoulders > 0.5 && p.y > lm_y.y + 0.03) {
			in_top = abs(ax - 0.075) < 0.018;  // only the straps above the chest
		}
		if (in_top) {
			if (open_front > 0.0 && p.z > 0.02 && ax < open_front && p.y > top_hem_y + 0.08) return 4;
			return 1;
		}
		if (p.y < bottom_waist_y) return 2;
		return 0;
	}
	if (r == 1) return ax < sleeve_x ? 1 : 0;
	if (r == 5) return (neck_high > 0.0 && p.y < lm_y.x + neck_high) ? 1 : 0;
	return 0;
}

float shape(vec3 p, int r) {
	float ax = abs(p.x);
	float push = 0.0;
	if (r == 0 || r == 5) {
		float belly = smoothstep(lm_y.w - 0.08, lm_y.z, p.y) * (1.0 - smoothstep(lm_y.y - 0.05, lm_y.y + 0.05, p.y))
			* smoothstep(-0.04, 0.08, p.z);
		push += weight_d * (0.03 + 0.07 * belly);
		// Chest / bust.
		float bust = bump(p.y, lm_y.y - 0.02 - female * 0.03, 0.07) * smoothstep(0.0, 0.08, p.z) * bump(ax, 0.085, 0.06);
		push += (chest_d * (0.05 + female * 0.05) + muscle_d * 0.03) * bust;
		// Shoulders and the trapezius.
		float sh = bump(ax, lm_x.x - 0.02, 0.06) * smoothstep(lm_y.y, lm_y.x, p.y);
		push += (shoulders_d * 0.04 + muscle_d * 0.02) * sh;
	}
	if (r == 0 || r == 3) {
		// Hips and bottom.
		float hip = bump(p.y, lm_y.w - 0.06, 0.1) * (smoothstep(0.04, 0.15, ax) + smoothstep(0.0, -0.1, p.z) * 0.6);
		push += hips_d * 0.06 * hip;
	}
	if (r == 1) {
		push += weight_d * 0.018 + muscle_d * 0.025 * (1.0 - smoothstep(lm_x.y, lm_x.z, ax) * 0.5);
		push += (shoulders_d * 0.03 + muscle_d * 0.02) * bump(ax, lm_x.x + 0.02, 0.05);
	}
	if (r == 3) {
		push += weight_d * 0.022 * smoothstep(lm_y2.y, lm_y2.x + 0.2, p.y) + muscle_d * 0.012;
	}
	if (r == 6 || r == 5) {
		push += weight_d * 0.01 * (1.0 - smoothstep(lm_y2.z, lm_y2.z + 0.08, p.y));
	}
	return push;
}

void vertex() {
	rest = CUSTOM0.xyz;
	region = int(CUSTOM0.w + 0.5);
	int c = cloth(rest, region);
	float thick = c == 1 || c == 4 ? top_thick : (c == 2 ? bottom_thick : (c == 3 ? shoe_thick : 0.0));
	float drape = c == 1 || c == 4 ? top_drape : (c == 2 ? bottom_drape : (c == 3 ? 1.0 : 0.0));
	thick += CUSTOM1.x * drape;
	if (c == 0 && face_hair == 4 && region == 6) thick = 0.002;
	VERTEX += NORMAL * (shape(rest, region) + thick);
}

float hash(vec3 p) {
	return fract(sin(dot(p, vec3(127.1, 311.7, 74.7))) * 43758.5453);
}

float beard_mask(vec3 p) {
	float head = lm_y2.z;
	float h = lm_y2.w - head;
	float mouth = head + h * 0.14;
	float eye = head + h * 0.47;
	float ax = abs(p.x);
	if (p.z < -0.01) return 0.0;
	if (face_hair == 2) {
		return (p.y > mouth + 0.004 && p.y < mouth + 0.02 && ax < 0.028 && p.z > 0.06) ? 1.0 : 0.0;
	}
	if (face_hair == 3) {
		bool must = p.y > mouth + 0.004 && p.y < mouth + 0.02 && ax < 0.026 && p.z > 0.06;
		bool chin = p.y < mouth - 0.004 && ax < 0.024 && p.z > 0.045;
		return (must || chin) ? 1.0 : 0.0;
	}
	// Stubble / short beard: jaw, chin, cheeks below the cheekbones, upper lip.
	bool lip = abs(p.y - mouth) < 0.006 && ax < 0.03 && p.z > 0.065;
	bool jaw = p.y < mouth + 0.02 && p.y > head - 0.04 && (p.z > 0.0 || ax > 0.04);
	bool cheek = p.y < eye - 0.04 && ax > 0.04 && p.z > -0.005;
	float keep_lips = (abs(p.y - mouth) < 0.006 && ax < 0.024 && p.z > 0.07) ? 0.0 : 1.0;
	return (jaw || cheek) && !lip ? keep_lips : 0.0;
}

void fragment() {
	vec3 p = rest;
	int c = cloth(p, region);
	vec3 skin = texture(skin_tex, UV).rgb * skin_tint;
	vec3 col = skin;
	float rough = 0.55;
	float nd = 1.0;
	float grain = hash(floor(p * 900.0));
	if (c == 1) {
		col = top_color;
		if (pattern == 1 && fract(p.y * 12.0) < 0.45) col = top_color2;
		if (pattern == 2 && p.y > lm_y.y - 0.02) col = top_color2;
		if (pattern == 3 && p.z > 0.04 && abs(p.x) < 0.012) {
			col = top_color * 0.85;
			if (fract(p.y * 11.0) < 0.12 && abs(p.x) < 0.005) col = top_color2;
		}
		if (pattern == 4 && p.z > 0.04 && abs(p.x) < 0.004) col = top_color2;
		// Hems: a slightly darker band at the ends of sleeves and the bottom.
		if (abs(abs(p.x) - sleeve_x) < 0.012 && region == 1) col *= 0.82;
		if (p.y - top_hem_y < 0.018 && region != 1) col *= 0.85;
		col *= 0.96 + grain * 0.06;
		rough = top_rough;
		nd = 0.12;
	} else if (c == 4) {
		col = top_color2 * (0.95 + grain * 0.05);
		rough = 0.8;
		nd = 0.1;
	} else if (c == 2) {
		col = bottom_color * (1.0 + denim * (hash(floor(vec3(p.x * 300.0, p.y * 900.0, p.z * 300.0))) - 0.5) * 0.25);
		if (region == 0 && bottom_waist_y - p.y < 0.03) col *= 0.7;  // waistband
		if (region == 3 && p.y - bottom_hem_y < 0.012) col *= 0.85;
		rough = 0.9;
		nd = 0.12;
	} else if (c == 3) {
		col = p.y < 0.022 ? sole_color : shoe_color;
		if (sandal < 0.5 && region == 4 && p.z > 0.1 && p.y > 0.05 && fract(p.z * 60.0) < 0.2 && abs(p.x) > 0.0) col *= 0.75;
		rough = 0.6;
		nd = 0.0;
	} else if (face_hair > 0 && region == 6) {
		float m = beard_mask(p);
		float amount = face_hair == 1 ? 0.45 : (face_hair == 4 ? 0.92 : 0.95);
		float fleck = face_hair == 1 ? step(0.35, grain) : 1.0;
		col = mix(col, face_hair_color, m * amount * fleck);
		rough = mix(rough, 0.9, m);
	}
	ALBEDO = col;
	ROUGHNESS = rough;
	NORMAL_MAP = texture(normal_tex, UV).rgb;
	NORMAL_MAP_DEPTH = nd;
}
