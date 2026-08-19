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
uniform sampler2D mask_tex : filter_nearest;      // маска биомов (mask.png): 0 прочее 1 лес 2 дорога 3 застройка 4 пашня 5 луг 6 кустарник 7 вода 8 голая 9 болото
uniform float mask_px = 4096.0;
// тепловизор: thermal_params = (режим 0/1, ночь 0/1, остывание 0..1, —). В режиме: ALBEDO=0, EMISSION=температура 0..1
global uniform vec4 thermal_params;

uniform float detail_range = 1400.0;
uniform bool uv_debug = false;
uniform bool mask_debug = false;


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

// случайное значение «парцеллы» (ячейка Вороного ~cell м) — межи полей/лугов
float hash21(vec2 p) { p = fract(p * vec2(123.34, 345.45)); p += dot(p, p + 34.345); return fract(p.x * p.y); }
vec2 parcel(vec2 wxz, float cell) {
	vec2 g = wxz / cell;
	vec2 i = floor(g);
	float best = 9.0; float id = 0.0;
	for (int y = -1; y <= 1; y++) for (int x = -1; x <= 1; x++) {
		vec2 n = i + vec2(float(x), float(y));
		vec2 o = vec2(hash21(n), hash21(n + 7.1));
		float d = length(g - (n + o));
		if (d < best) { best = d; id = hash21(n + 3.3); }
	}
	return vec2(id, best);   // id 0..1, расстояние до центра (для межи)
}
// класс маски в точке (с лёгким дизерингом, чтобы не было пиксельных ступенек 12 м)
float mask_class(vec2 wuv, float jit) {
	vec2 j = (vec2(hash21(wuv * 4096.0 + jit), hash21(wuv * 4096.0 + jit + 9.1)) - 0.5) * (1.6 / mask_px);
	return floor(texture(mask_tex, wuv + j).r * 255.0 + 0.5);
}

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

		// ---- биомы из маски ----
		float cls = mask_class(UV, 0.0);
		float forest = step(0.5, cls) * step(cls, 1.5);
		float crop = step(3.5, cls) * step(cls, 4.5);
		float meadow = step(4.5, cls) * step(cls, 5.5);
		float shrub = step(5.5, cls) * step(cls, 6.5);
		float waterc = step(6.5, cls) * step(cls, 7.5);
		float bare = step(7.5, cls) * step(cls, 8.5);
		float builtc = step(2.5, cls) * step(cls, 3.5);
		vec2 par = parcel(p, 220.0);
		float pv = par.x;
		// лес: подстилка (хвоя/листва, бурая) вблизи; полог (тёмная «шуба» с кронами-шумом) вдали, где деревьев уже нет
		vec3 litter = mix(vec3(0.16, 0.13, 0.08), vec3(0.10, 0.14, 0.06), nB) * (0.8 + 0.4 * nA);
		float crowns = texture(noise_tex, p * 0.045).r;
		// полог относительно спутника: темнее базы, кроны-шум даёт «шубу», лёгкий сдвиг в зелень
		vec3 canopy = macro * (0.55 + 0.7 * crowns) * vec3(0.92, 1.06, 0.88) * (0.85 + 0.3 * nA);
		float treesNear = 1.0 - smoothstep(2200.0, 3200.0, dist);
		vec3 forestCol = mix(canopy, litter, treesNear);
		// пашня: парцеллы — часть полей зелёная (посев), часть стерня/чернозём; борозды как анизотропная фактура
		float stub = step(0.5, pv);
		vec3 cropGreen = ground * vec3(0.92, 1.0, 0.9) * (0.88 + 0.25 * hash21(vec2(pv, 1.0)));
		vec3 cropDirt = t2(dirt_tex, p, k) * mix(vec3(1.0), chroma, 0.3) * (0.55 + 0.45 * hash21(vec2(pv, 2.0)));
		float rows = 0.92 + 0.08 * sin(dot(p, vec2(cos(pv * 6.28), sin(pv * 6.28))) * 1.2);
		vec3 cropCol = mix(cropGreen, cropDirt, stub) * rows;
		// межа между парцеллями — тёмная полоска
		float edgeP = smoothstep(0.46, 0.5, par.y) * 0.25;
		cropCol *= 1.0 - edgeP;
		// луг: лоскутность оттенка ±8 % по парцелле (сенокос/выпас)
		vec3 meadowCol = ground * (0.92 + 0.16 * hash21(vec2(pv, 3.0))) * mix(vec3(1.0), vec3(1.04, 1.0, 0.9), hash21(vec2(pv, 4.0)));
		meadowCol *= 1.0 - edgeP * 0.5;
		vec3 shrubCol = mix(ground, t2(dirt_tex, p, k) * 0.8, 0.35) * vec3(0.9, 0.95, 0.85);
		vec3 bareCol = mix(t2(dirt_tex, p, k), t2(rock_tex, p, k), 0.5) * 0.9;
		vec3 builtCol = mix(ground, t2(dirt_tex, p, k) * 0.9, 0.5);
		vec3 waterCol = vec3(0.12, 0.16, 0.14);
		vec3 biome = ground;
		biome = mix(biome, forestCol, forest);
		biome = mix(biome, cropCol, crop);
		biome = mix(biome, meadowCol, meadow);
		biome = mix(biome, shrubCol, shrub);
		biome = mix(biome, bareCol, bare);
		biome = mix(biome, builtCol, builtc);
		biome = mix(biome, waterCol, waterc);
		// под лесом — затемнение и вдали тоже (маска работает и там, где спутник светлый)
		ground = biome;
		vec3 farCol = mix(macro, canopy, forest * 0.85);                // дальний план: спутник, но лес — тёмный полог
		farCol = mix(farCol, mix(macro, cropCol, 0.35), crop);
		vec3 base = mix(farCol, ground, near);

		// нормаль из карты (приближённо: земля ~ горизонтальна, T=+X, B=+Z)
		vec3 wn = normalize(wnorm + (vec3(1,0,0) * nd.x + vec3(0,0,1) * nd.y) * (0.9 * near));
		NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

		ALBEDO = base * cloud_shadow(wpos.xz);
		if (mask_debug) { ALBEDO = vec3(cls / 10.0, forest, crop + meadow * 0.5); }
		if (thermal_params.x > 0.5) {
			// температура поверхности: вода холодная, лес прохладный, пашня/голая земля тёплые, дорога/застройка горячие;
			// южные склоны теплее, низины холоднее; ночью всё остывает, асфальт и камень держат тепло
			float night = thermal_params.y;
			float tmp = 0.36;
			tmp = mix(tmp, 0.27, forest); tmp = mix(tmp, 0.33, meadow); tmp = mix(tmp, 0.42 + 0.08 * stub, crop);
			tmp = mix(tmp, 0.50, bare); tmp = mix(tmp, 0.40, builtc); tmp = mix(tmp, 0.12, waterc);
			float road = step(1.5, cls) * step(cls, 2.5);
			tmp = mix(tmp, 0.66, road);
			tmp += wnorm.z * 0.05 - (0.5 - nA) * 0.06 + rockW * 0.06;
			tmp = mix(tmp, tmp * 0.72 + road * 0.08 + rockW * 0.06, night);
			ALBEDO = vec3(0.0); EMISSION = vec3(tmp); ROUGHNESS = 1.0; SPECULAR = 0.0;
		}
		ROUGHNESS = 0.88 + 0.12 * nB - grassW * 0.05;
		SPECULAR = 0.12;
	}
}
