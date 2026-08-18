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
uniform float detail_range = 1400.0;
uniform bool uv_debug = false;

varying vec3 wpos;
varying vec3 wnorm;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
	wnorm = normalize((MODEL_MATRIX * vec4(NORMAL, 0.0)).xyz);
}

// второй масштаб повёрнут на ~40° — гасит полосы/повтор
const vec2 R1 = vec2(0.766, 0.643);
vec2 rot(vec2 p) { return vec2(p.x * R1.x - p.y * R1.y, p.x * R1.y + p.y * R1.x); }

vec3 t2(sampler2D s, vec2 p) {
	return texture(s, p * 0.16).rgb * 0.62 + texture(s, rot(p) * 0.045).rgb * 0.38;
}
vec3 n2(sampler2D s, vec2 p) {
	vec3 a = texture(s, p * 0.16).xyz * 2.0 - 1.0;
	vec3 b = texture(s, rot(p) * 0.045).xyz * 2.0 - 1.0;
	return normalize(a * 0.62 + b * 0.38);
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
		// веса: трава ↔ грунт по «зелёности» спутника, камень по крутизне склона
		float green = macro.g - 0.5 * (macro.r + macro.b);
		float grassW = smoothstep(-0.03, 0.05, green);
		float slope = 1.0 - clamp(wnorm.y, 0.0, 1.0);
		float rockW = smoothstep(0.32, 0.6, slope);

		vec3 gd = mix(t2(dirt_tex, p), t2(grass_tex, p), grassW);
		vec3 detail = mix(gd, t2(rock_tex, p), rockW);

		vec3 nd = normalize(mix(n2(dirt_tex, p), n2(grass_tex, p), grassW));
		nd = normalize(mix(nd, n2(rock_tex, p), rockW));

		// фото-фактура принимает крупный цвет спутника (реальная раскладка полей/леса)
		vec3 chroma = macro / max(macro_lum, 0.001);
		vec3 ground = detail * mix(vec3(1.0), chroma, 0.3) * 0.82;
		// сбить желтизну травы: чуть в зелень + снять пересыщение
		ground.g += grassW * (1.0 - rockW) * 0.03;
		ground = mix(ground, vec3(dot(ground, vec3(0.33))), 0.12);

		vec3 base = mix(macro, ground, near);

		// нормаль из карты (приближённо: земля ~ горизонтальна, T=+X, B=+Z)
		vec3 wn = normalize(wnorm + (vec3(1,0,0) * nd.x + vec3(0,0,1) * nd.y) * (0.9 * near));
		NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

		ALBEDO = base;
		ROUGHNESS = 0.95;
		SPECULAR = 0.15;
	}
}
