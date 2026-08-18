shader_type spatial;
render_mode unshaded;

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform bool uv_debug = false;

void fragment() {
	if (uv_debug) {
		ALBEDO = vec3(UV, 0.0);
	} else {
		ALBEDO = texture(albedo_tex, UV).rgb;
	}
}
