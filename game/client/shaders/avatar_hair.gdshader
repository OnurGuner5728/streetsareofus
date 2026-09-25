shader_type spatial;
// Hair, brows and beard meshes (Universal Base Characters, CC0), recoloured:
// the texture's light/dark strands are kept, the colour is the player's.

uniform sampler2D hair_tex : source_color, filter_linear_mipmap;
uniform sampler2D normal_tex : hint_normal, filter_linear_mipmap;
uniform vec3 hair_color : source_color = vec3(0.22, 0.15, 0.1);
uniform float has_texture = 1.0;

void fragment() {
	float strand = 1.0;
	if (has_texture > 0.5) {
		vec3 t = texture(hair_tex, UV).rgb;
		strand = clamp(dot(t, vec3(0.3, 0.59, 0.11)) / 0.26, 0.45, 1.6);  // the texture is grey, ~0.26 linear
		NORMAL_MAP = texture(normal_tex, UV).rgb;
		NORMAL_MAP_DEPTH = 0.8;
	}
	ALBEDO = clamp(hair_color * strand, 0.0, 1.0);
	ROUGHNESS = 0.6;
	SPECULAR = 0.35;
}
