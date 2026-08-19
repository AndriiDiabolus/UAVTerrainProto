shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;

// Пучки травы на кросс-картах вокруг камеры: качание верхушек, альфа-вырезка,
// нормаль «вверх» (освещается как земля), прореживание с дистанцией.

uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.3;
uniform vec3 tint : source_color = vec3(0.40, 0.42, 0.16);
uniform float fade_start = 40.0;
uniform float fade_end = 70.0;


// тени облаков (глобальные uniform'ы: текстура шума + (offset.xy, сила, масштаб 1/м))
global uniform sampler2D cloud_shadow_tex;
global uniform vec4 cloud_shadow_params;
float cloud_shadow(vec2 pxz) {
	float n = texture(cloud_shadow_tex, pxz * cloud_shadow_params.w + cloud_shadow_params.xy).r;
	return 1.0 - smoothstep(0.50, 0.72, n) * cloud_shadow_params.z;
}

varying float vdist;
varying vec2 wxz;

void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	float top = 1.0 - UV.y;                       // 1 у верхушки, 0 у корня
	float rnd = fract(sin(o.x * 12.9898 + o.z * 78.233) * 43758.5453) * 6.2831;
	float t = TIME * 2.2 + rnd;
	float sway = (0.5 + 0.5 * sin(t - dot(o.xz, wind_dir) * 0.3)) * wind_strength;
	VERTEX.xz += wind_dir * (0.06 + 0.22 * sway) * top * top;
	VERTEX.x += sin(t * 1.7) * 0.02 * top;
	vdist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
	wxz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
}

void fragment() {
	vec4 c = texture(tex, UV);
	float fade = clamp((vdist - fade_start) / (fade_end - fade_start), 0.0, 1.0);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = 0.45 + fade * 0.6;   // вдали пучки редеют и исчезают
	ALBEDO = c.rgb * tint * COLOR.rgb * cloud_shadow(wxz);
	vec3 up_v = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	NORMAL = up_v;
	ROUGHNESS = 0.95;
	SPECULAR = 0.1;
	BACKLIGHT = vec3(0.35, 0.4, 0.15) * c.rgb;
}
