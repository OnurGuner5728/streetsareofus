shader_type spatial;
// Eyes: the iris (the dark, saturated part of the texture) takes the
// player's eye colour; the whites and highlights stay.

uniform sampler2D eye_tex : source_color, filter_linear_mipmap;
uniform vec3 iris_color : source_color = vec3(0.35, 0.23, 0.13);

void fragment() {
	vec3 t = texture(eye_tex, UV).rgb;
	float lum = dot(t, vec3(0.3, 0.59, 0.11));
	float iris = 1.0 - smoothstep(0.45, 0.7, lum);
	ALBEDO = mix(t, iris_color * (0.5 + lum * 1.6), iris);
	ROUGHNESS = 0.15;
	SPECULAR = 0.6;
}
