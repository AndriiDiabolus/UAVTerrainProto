shader_type spatial;

// Реальные CC0-фототекстуры (Poly Haven, aerial) как ближний слой:
//   трава — на пологих, камень — на склонах, грунт — на «полевых» (бурых) пятнах.
// Спутник задаёт крупную раскладку и цвет; фото даёт чёткую фактуру и рельеф вблизи.

uniform sampler2D albedo_tex : source_color, filter_linear_mipmap_anisotropic;
uniform sampler2D grass_tex : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D grass_n   : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_tex  : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D dirt_n    : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_tex  : source_color, filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D rock_n    : filter_linear_mipmap_anisotropic, repeat_enable;
uniform sampler2D noise_tex : filter_linear_mipmap, repeat_enable;   // бесшовный шум (main._make_detail_noise)
uniform float detail_range = 1400.0;
uniform bool uv_debug = false;


// тени облаков (глобальные uniform'ы: текстура шума + (offset.xy, сила, масштаб 1/м))
global uniform sampler2D cloud_shadow_tex;
global uniform vec4 cloud_shadow_params;
float cloud_shadow(vec2 pxz) {
	float n = texture(cloud_shadow_tex, pxz * cloud_shadow_params.w + cloud_shadow_params.xy).r;
	return 1.0 - smoothstep(0.50, 0.72, n) * cloud_shadow_params.z;
}

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// второй масштаб повёрнут на ~40° — гасит полосы/повтор
const vec2 R1 = vec2(0.766, 0.643);
vec2 rot(vec2 p) { return vec2(p.x * R1.x - p.y * R1.y, p.x * R1.y + p.y * R1.x); }

// два масштаба + сбивка повтора: смещённый второй набор координат подмешивается по шуму
vec3 t2(sampler2D s, vec2 p, float k) {
	vec3 a = texture(s, p * 0.16).rgb * 0.62 + texture(s, rot(p) * 0.045).rgb * 0.38;
	vec2 q = p + vec2(37.1, 91.7);
	vec3 b = texture(s, q * 0.16).rgb * 0.62 + texture(s, rot(q) * 0.045).rgb * 0.38;
	return mix(a, b, k);
}
vec3 n2(sampler2D s, vec2 p, float k) {
	vec3 a = normalize((texture(s, p * 0.16).xyz * 2.0 - 1.0) * 0.62 + (texture(s, rot(p) * 0.045).xyz * 2.0 - 1.0) * 0.38);
	vec2 q = p + vec2(37.1, 91.7);
	vec3 b = normalize((texture(s, q * 0.16).xyz * 2.0 - 1.0) * 0.62 + (texture(s, rot(q) * 0.045).xyz * 2.0 - 1.0) * 0.38);
	return normalize(mix(a, b, k));
}

void fragment() {
	if (uv_debug) {
		ALBEDO = vec3(UV, 0.0);
	} else {
		vec3 macro = texture(albedo_tex, UV).rgb;
		float macro_lum = dot(macro, vec3(0.299, 0.587, 0.114));

		float dist = length(CAMERA_POSITION_WORLD - wpos);
		float near = clamp(1.0 - dist / detail_range, 0.0, 1.0);

		vec2 p = wpos.xz;
		float nA = texture(noise_tex, p * 0.0009).r;          // ~1 км пятна (влажность/выгорание)
		float nB = texture(noise_tex, p * 0.011).r;           // ~90 м — сбивка повтора, порог камня
		float k = smoothstep(0.38, 0.62, nB);
		// веса: трава ↔ грунт по «зелёности» спутника (+шум), камень по крутизне склона (+шум)
		float green = macro.g - 0.5 * (macro.r + macro.b);
		float grassW = smoothstep(-0.03, 0.05, green + (nA - 0.5) * 0.04);
		float slope = 1.0 - clamp(wnorm.y, 0.0, 1.0);
		float rockW = smoothstep(0.28 + nB * 0.16, 0.62, slope);

		vec3 gd = mix(t2(dirt_tex, p, k), t2(grass_tex, p, k), grassW);
		vec3 detail = mix(gd, t2(rock_tex, p, k), rockW);

		vec3 nd = normalize(mix(n2(dirt_tex, p, k), n2(grass_tex, p, k), grassW));
		nd = normalize(mix(nd, n2(rock_tex, p, k), rockW));

		// фото-фактура принимает крупный цвет спутника (реальная раскладка полей/леса)
		vec3 chroma = macro / max(macro_lum, 0.001);
		vec3 ground = detail * mix(vec3(1.0), chroma, 0.3) * 0.82;
		ground *= 0.90 + 0.22 * nA;                            // макро-вариация яркости — нет «ровного газона»
		// сбить желтизну травы: чуть в зелень + снять пересыщение
		ground.g += grassW * (1.0 - rockW) * 0.03;
		ground = mix(ground, vec3(dot(ground, vec3(0.33))), 0.12);

		vec3 base = mix(macro, ground, near);

		// нормаль из карты (приближённо: земля ~ горизонтальна, T=+X, B=+Z)
		vec3 wn = normalize(wnorm + (vec3(1,0,0) * nd.x + vec3(0,0,1) * nd.y) * (0.9 * near));
		NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

		ALBEDO = base * cloud_shadow(wpos.xz);
		ROUGHNESS = 0.88 + 0.12 * nB - grassW * 0.05;
		SPECULAR = 0.12;
	}
}
