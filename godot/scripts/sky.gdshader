shader_type sky;

// Градиент неба + процедурные плывущие облака + диск солнца + звёзды ночью.
// Цвета/покрытие/направление солнца приходят из weather.gd.

uniform vec3 top_color : source_color = vec3(0.22, 0.43, 0.75);
uniform vec3 horizon_color : source_color = vec3(0.72, 0.81, 0.9);
uniform vec3 ground_color : source_color = vec3(0.55, 0.62, 0.7);
uniform vec3 sun_dir = vec3(0.4, 0.5, 0.3);
uniform vec3 sun_color : source_color = vec3(1.0, 0.95, 0.85);
uniform vec3 cloud_color : source_color = vec3(1.0, 1.0, 1.0);
uniform vec3 cloud_dark : source_color = vec3(0.55, 0.58, 0.62);
uniform float coverage : hint_range(0.0, 1.0) = 0.4;
uniform float night : hint_range(0.0, 1.0) = 0.0;
uniform vec2 wind_dir = vec2(1.0, 0.3);
// тепловизор: thermal_params = (режим 0/1, ночь 0/1, остывание 0..1, —). В режиме: ALBEDO=0, EMISSION=температура 0..1
global uniform vec4 thermal_params;


float hash(vec2 p) {
	p = fract(p * vec2(123.34, 345.45));
	p += dot(p, p + 34.345);
	return fract(p.x * p.y);
}

float noise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	float a = hash(i);
	float b = hash(i + vec2(1.0, 0.0));
	float c = hash(i + vec2(0.0, 1.0));
	float d = hash(i + vec2(1.0, 1.0));
	return mix(mix(a, b, f.x), mix(c, d, f.x), f.y);
}

float fbm(vec2 p) {
	float v = 0.0;
	float a = 0.5;
	for (int i = 0; i < 5; i++) {
		v += a * noise(p);
		p *= 2.02;
		a *= 0.5;
	}
	return v;
}

void sky() {
	vec3 dir = EYEDIR;
	float up = dir.y;

	// базовый градиент
	vec3 col = mix(horizon_color, top_color, clamp(pow(max(up, 0.0), 0.6), 0.0, 1.0));
	col = mix(col, ground_color, clamp(-up * 6.0, 0.0, 1.0));

	// дымка у горизонта: небо «молочнеет» к горизонту (рассеяние Ми в толще воздуха)
	float hz = pow(1.0 - clamp(up, 0.0, 1.0), 5.0);
	col = mix(col, horizon_color * 1.04 + vec3(0.03), hz * 0.6 * (1.0 - night * 0.7));

	// солнце: диск + узкий ореол Ми + широкое свечение
	float sd = max(dot(normalize(dir), normalize(sun_dir)), 0.0);
	col += sun_color * pow(sd, 2500.0) * 12.0;                 // диск
	col += sun_color * pow(sd, 160.0) * 0.9 * (1.0 - night);   // ореол Ми (forward scattering)
	col += sun_color * pow(sd, 8.0) * 0.22 * (1.0 - night);    // широкое свечение
	col += sun_color * pow(sd, 2.5) * 0.05 * (1.0 - night) * hz; // подсветка дымки у горизонта со стороны солнца

	// звёзды ночью — маленькие точки, по одной на редкую ячейку
	if (night > 0.3 && up > 0.05) {
		vec2 sp = dir.xz / (up + 0.15) * 9.0;
		vec2 id = floor(sp);
		vec2 gv = fract(sp) - 0.5;
		float h = hash(id);
		if (h > 0.93) {
			vec2 off = (vec2(hash(id + 1.3), hash(id + 2.7)) - 0.5) * 0.6;
			float d = length(gv - off);
			float star = smoothstep(0.05, 0.0, d) * ((h - 0.93) / 0.07);
			col += vec3(0.9, 0.92, 1.0) * star * night * smoothstep(0.05, 0.28, up);
		}
	}

	// облака: проекция на плоскость облаков
	if (up > 0.01) {
		vec2 cuv = dir.xz / (up + 0.12) * 0.6;
		cuv += wind_dir * TIME * 0.006;
		float n = fbm(cuv);
		float edge = 1.0 - coverage;
		float cl = smoothstep(edge, edge + 0.25, n);
		cl *= smoothstep(0.02, 0.22, up);                     // тают у горизонта
		// объём: тёмный низ / светлый верх по второй частоте
		float shade = fbm(cuv * 2.3 + 5.0);
		vec3 ccol = mix(cloud_dark, cloud_color, clamp(shade + 0.3, 0.0, 1.0));
		ccol += sun_color * pow(sd, 6.0) * 0.4 * (1.0 - night); // подсветка солнцем
		col = mix(col, ccol, cl * 0.9);
	}

	if (thermal_params.x > 0.5) {
		// небо холодное; облака чуть теплее; солнце — горячая точка
		float cl2 = 0.0;
		if (up > 0.01) { vec2 cuv2 = dir.xz / (up + 0.12) * 0.6 + wind_dir * TIME * 0.006; cl2 = smoothstep(1.0 - coverage, 1.25 - coverage, fbm(cuv2)) * smoothstep(0.02, 0.22, up); }
		col = vec3(mix(0.02, 0.10, cl2)) + vec3(pow(sd, 2500.0)) * 1.0 + vec3(0.12) * clamp(-up * 6.0, 0.0, 1.0);
	}
	COLOR = col;
}
