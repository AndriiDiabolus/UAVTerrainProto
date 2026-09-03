shader_type spatial;
render_mode cull_disabled;

// 3D-пучки травы (Meshy GLB, инстансы в MultiMesh): текстура из GLB, качание по высоте
// с фазой от позиции инстанса + лёгкий индивидуальный трепет. Цвет принимает спутник (как grass.gdshader).

uniform sampler2D alb : source_color, filter_linear_mipmap_anisotropic;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.3;
uniform float clump_h = 0.55;        // высота пучка после нормализации, м
uniform sampler2D sat_tex : source_color, filter_linear_mipmap;
uniform float world_size = 52211.0;
global uniform vec4 thermal_params;
global uniform sampler2D cloud_shadow_tex;
global uniform vec4 cloud_shadow_params;

varying vec2 wxz;
varying vec3 sat_tint;

float cloud_shadow(vec2 pxz) {
	float n = texture(cloud_shadow_tex, pxz * cloud_shadow_params.w + cloud_shadow_params.xy).r;
	return 1.0 - smoothstep(0.50, 0.72, n) * cloud_shadow_params.z;
}

void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	float rnd = fract(sin(o.x * 12.9898 + o.z * 78.233) * 43758.5453) * 6.2831;
	float top = clamp(VERTEX.y / clump_h, 0.0, 1.0);
	float t = TIME * 2.0 + rnd;
	float sway = (0.5 + 0.5 * sin(t - dot(o.xz, wind_dir) * 0.3)) * wind_strength;
	VERTEX.xz += wind_dir * (0.05 + 0.20 * sway) * top * top;
	VERTEX.x += sin(t * 1.8 + VERTEX.z * 7.0) * 0.02 * top;   // трепет отдельных стеблей по фазе от их положения
	VERTEX.z += cos(t * 1.5 + VERTEX.x * 6.0) * 0.018 * top;
	wxz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	vec3 sc = textureLod(sat_tex, o.xz / world_size + 0.5, 2.0).rgb;
	float sl = dot(sc, vec3(0.299, 0.587, 0.114));
	sat_tint = mix(vec3(1.0), sc / max(sl, 0.002), 0.35) * clamp(0.75 + sl * 3.5, 0.75, 1.25);
}

void fragment() {
	vec4 c = texture(alb, UV);
	ALBEDO = c.rgb * sat_tint * cloud_shadow(wxz) * 1.08;
	NORMAL = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);   // освещается как земля, без самозатенения граней
	ROUGHNESS = 0.95;
	SPECULAR = 0.1;
	BACKLIGHT = vec3(0.3, 0.35, 0.14) * c.rgb;
	if (thermal_params.x > 0.5) { ALBEDO = vec3(0.0); EMISSION = vec3(mix(0.33, 0.28, thermal_params.y)); BACKLIGHT = vec3(0.0); }
}
