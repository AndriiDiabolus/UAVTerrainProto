shader_type canvas_item;

// Видеотракт FPV поверх кадра из SubViewport (TEXTURE = картинка камеры с OSD внутри).
// Аналог (link_type 0): эквидистантный рыбий глаз, интерлейс 480 строк, размытая цветность,
// ступенчатая деградация по link_q (конфетти → потеря цвета → срывы строк → срыв синхры → снег),
// jello от вибраций, «характер» камеры (шарпинг, приподнятый чёрный, тёплый баланс), veiling glare от солнца.
// Цифра (link_type 1): чистая картинка, при падении битрейта — макроблоки, при фризе — SIGNAL LOST.

uniform sampler2D video : filter_linear;
uniform sampler2D osd : filter_linear;
uniform int link_type = 0;
uniform vec2 tex_size = vec2(960.0, 720.0);
uniform float fov_render = 150.0;       // горизонтальный FOV камеры в SubViewport (rectilinear)
uniform float fov_target = 150.0;       // целевой FOV эквидистантного объектива
uniform float link_q : hint_range(0.0, 1.0) = 1.0;
uniform float jello_amp = 0.001;
uniform vec2 sun_uv = vec2(-1.0, -1.0);
uniform float sun_vis = 0.0;
uniform float night = 0.0;
uniform float lost = 0.0;
uniform float frame_t = 0.0;
uniform float thermal = 0.0;
uniform float night_cam = 0.0;    // ночная ч/б камера (Night Eagle): усиление, зерно, блюминг фонарей
uniform int thermal_palette = 0;
uniform float vignette : hint_range(0.0, 1.5) = 0.55;
uniform vec3 white_balance : source_color = vec3(1.04, 1.0, 0.94);   // тёплая камера (Caddx-like)

float rnd(vec2 p) { return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453); }
vec3 hsv2rgb(vec3 c) {
	vec3 p = abs(fract(c.xxx + vec3(0.0, 2.0 / 3.0, 1.0 / 3.0)) * 6.0 - 3.0);
	return c.z * mix(vec3(1.0), clamp(p - 1.0, 0.0, 1.0), c.y);
}

vec3 fetch(vec2 uv) { return texture(video, uv).rgb; }
vec3 ironbow(float t) {
	// чёрный → фиолетовый → красный → оранжевый → жёлтый → белый
	vec3 c1 = vec3(0.0, 0.0, 0.0), c2 = vec3(0.25, 0.0, 0.45), c3 = vec3(0.75, 0.05, 0.25), c4 = vec3(0.95, 0.45, 0.05), c5 = vec3(1.0, 0.85, 0.3), c6 = vec3(1.0);
	if (t < 0.2) return mix(c1, c2, t / 0.2);
	if (t < 0.4) return mix(c2, c3, (t - 0.2) / 0.2);
	if (t < 0.6) return mix(c3, c4, (t - 0.4) / 0.2);
	if (t < 0.8) return mix(c4, c5, (t - 0.6) / 0.2);
	return mix(c5, c6, (t - 0.8) / 0.2);
}

void fragment() {
	vec2 uv = UV;
	float t = frame_t;
	float line = floor(uv.y * 480.0);
	// --- эффекты «в сигнале» (до объектива по порядку обработки, но в экранных координатах):
	// jello, срывы строк, срыв синхры — сдвигают и картинку, и OSD
	vec2 suv = uv;
	float ja = jello_amp * (1.0 - thermal);      // LWIR — глобальный затвор, «желе» нет
	suv.x += ja * sin(uv.y * 62.0 + t * 90.0) + ja * 0.6 * sin(uv.y * 170.0 + t * 120.0);
	suv.y += ja * 0.3 * sin(t * 37.0);
	float dq = 1.0 - link_q;
	if (link_type == 0) {
		float tear = step(1.0 - dq * 0.45, rnd(vec2(line, floor(t * 30.0))));
		suv.x += tear * (rnd(vec2(line * 1.7, floor(t * 30.0))) - 0.5) * 0.18 * dq;
		if (link_q < 0.22) {
			suv.y = fract(suv.y + t * 0.7 * (0.22 - link_q) * 6.0);
		}
	}
	float aspect = tex_size.x / tex_size.y;
	// маска круга объектива — по неподвижным UV (линза не дрожит), выборка — по сдвинутым
	vec2 q0 = (UV - 0.5) * vec2(aspect, 1.0);
	float r0 = length(q0) / (aspect * 0.5);
	bool outside0 = r0 * radians(fov_target) * 0.5 >= 1.55;
	uv = suv;
	vec2 q = (uv - 0.5) * vec2(aspect, 1.0);
	float halfw = aspect * 0.5;
	float r = length(q) / halfw;                         // 1 на горизонтальном краю
	float fr = radians(fov_render) * 0.5;
	float ft = radians(fov_target) * 0.5;
	// эквидистантная проекция: угол пропорционален радиусу на сенсоре
	float theta = r * ft;
	float rs = (theta < 1.55) ? tan(theta) / tan(fr) : 10.0;
	vec2 dirn = (r > 1e-5) ? q / length(q) : vec2(0.0);
	vec2 src = dirn * rs * halfw / vec2(aspect, 1.0) + 0.5;
	bool outside = outside0;
	src = clamp(src, vec2(0.001), vec2(0.999));

	vec3 col;
	if (thermal > 0.5) {
		// --- LWIR 256×192: температура в люме кадра (EMISSION наших материалов) ---
		vec2 res = vec2(256.0, 192.0);
		vec2 g = src * res - 0.5;
		vec2 gi = floor(g); vec2 gf = fract(g);
		float px = 1.0 / res.x, py = 1.0 / res.y;
		// температура в 4 соседних «пикселях» матрицы → билинейный апскейл (как у реальных тепловизоров)
		#define TL(o) dot(fetch((gi + 0.5 + o) / res), vec3(0.299, 0.587, 0.114))
		float t00 = TL(vec2(0.0, 0.0)), t10 = TL(vec2(1.0, 0.0)), t01 = TL(vec2(0.0, 1.0)), t11 = TL(vec2(1.0, 1.0));
		float t0 = mix(mix(t00, t10, gf.x), mix(t01, t11, gf.x), gf.y);
		// AGC: окно вокруг средней температуры земли (нижние 2/3 кадра, грубый мип); горячее — клип
		float m = 0.0;
		for (int i = 0; i < 3; i++) for (int j = 0; j < 2; j++) {
			m += dot(textureLod(video, vec2(0.2 + 0.3 * float(i), 0.55 + 0.3 * float(j)), 6.0).rgb, vec3(0.299, 0.587, 0.114));
		}
		m /= 6.0;
		float lo = m - 0.22, hi = m + 0.30;
		float tv = clamp((t0 - lo) / (hi - lo), 0.0, 1.0);
		// ореол (halo) вокруг горячих объектов: размытый избыток
		float hot = 0.0;
		for (int i = -2; i <= 2; i++) for (int j = -2; j <= 2; j++) {
			float tt = dot(fetch(src + vec2(float(i) * px, float(j) * py) * 1.5), vec3(0.299, 0.587, 0.114));
			hot += max(tt - (m + 0.28), 0.0);
		}
		tv += hot / 25.0 * 1.4;
		// «кипение» матрицы (временной шум) + слабый фиксированный паттерн (FPN)
		vec2 tuv = (gi + 0.5) / res;
		tv += (rnd(tuv * res + floor(t * 25.0) * 3.7) - 0.5) * 0.022 + (rnd(tuv * res * 3.1) - 0.5) * 0.008;
		tv = clamp(tv, 0.0, 1.0);
		if (thermal_palette == 0) col = vec3(tv);
		else if (thermal_palette == 1) col = vec3(1.0 - tv);
		else col = ironbow(tv);
	} else if (night_cam > 0.5) {
		// --- ночная ч/б камера: AGC по средней яркости, мягкий клип, блюминг вокруг ярких источников, зерно ∝ усилению ---
		float px = 1.0 / tex_size.x;
		vec3 c0 = fetch(src);
		float l0 = dot(c0, vec3(0.299, 0.587, 0.114));
		float m = dot(textureLod(video, vec2(0.5), 8.0).rgb, vec3(0.299, 0.587, 0.114));
		float gain = clamp(0.35 / max(m, 0.002), 1.0, 40.0);
		float v = l0 * gain;
		// блюминг: яркие источники растекаются
		float bl = 0.0;
		for (int i = -2; i <= 2; i++) for (int j = -2; j <= 2; j++) {
			float tt = dot(fetch(src + vec2(float(i), float(j)) * px * 2.5), vec3(0.299, 0.587, 0.114)) * gain;
			bl += max(tt - 1.0, 0.0);
		}
		v += bl / 25.0 * 0.8;
		v = v / (1.0 + v * 0.6);                                  // мягкое колено
		float gn = (rnd(src * tex_size + floor(t * 30.0) * 1.3) - 0.5) * (0.03 + 0.012 * sqrt(gain));
		v = clamp(v + gn, 0.0, 1.0);
		col = vec3(v) * vec3(0.93, 1.0, 0.96);
		// далее — аналоговый тракт (строчки, деградация) применяется ниже как к обычному аналогу
		float odd = mod(line, 2.0);
		col *= 1.0 - 0.06 * odd;
	} else if (link_type == 0) {
		// --- аналог ---
		// люма полная, цветность размыта по горизонтали (NTSC) + хроматическая аберрация к краю
		float px = 1.0 / tex_size.x;
		vec3 c0 = fetch(src);
		vec3 cb = (fetch(src - vec2(2.0 * px, 0.0)) + fetch(src - vec2(1.0 * px, 0.0)) + c0
				 + fetch(src + vec2(1.0 * px, 0.0)) + fetch(src + vec2(2.0 * px, 0.0))) * 0.2;
		float ca = 0.00028 * (0.2 + r * r);          // умеренная хроматика к краю
		vec3 cc = vec3(fetch(src + dirn * ca).r, cb.g, fetch(src - dirn * ca).b);
		float y0 = dot(c0, vec3(0.299, 0.587, 0.114));
		float yc = dot(cc, vec3(0.299, 0.587, 0.114));
		col = cc - yc + y0;                               // люма от резкого, цвет от размытого
		// интерлейс: нечётные строки чуть сдвинуты/темнее (гребёнка)
		float odd = mod(line, 2.0);
		col *= 1.0 - 0.07 * odd;
		// характер камеры: лёгкий шарпинг, приподнятый чёрный, насыщенность, баланс белого
		vec3 blur = (fetch(src + vec2(px, 0.0)) + fetch(src - vec2(px, 0.0)) + fetch(src + vec2(0.0, px * aspect)) + fetch(src - vec2(0.0, px * aspect))) * 0.25;
		col += (c0 - blur) * 0.5;
		col = pow(clamp((col - 0.02) * 1.12 + 0.035, 0.0, 1.0), vec3(1.0 / 1.08));
		float lum = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(lum), col, 1.08) * white_balance;
		// деградация: потеря цветности (color killer) → ч/б
		float sat = smoothstep(0.30, 0.58, link_q);
		col = mix(vec3(lum), col, sat);
		// цветное конфетти
		float conf = rnd(uv * tex_size * 0.5 + floor(t * 30.0) * 7.3);
		if (conf > 1.0 - dq * 0.22) col = hsv2rgb(vec3(rnd(uv * 91.0 + t), 1.0, 1.0));
		// снег
		float snow = smoothstep(0.28, 0.0, link_q);
		col = mix(col, vec3(rnd(uv * tex_size * 0.7 + t * 53.0)), snow * 0.9);
		// зерно (ночью сильнее, цвет уходит)
		float g = rnd(uv * tex_size * 0.6 + fract(t) * 91.7) - 0.5;
		col += g * (0.035 + night * 0.10 + dq * 0.05);
		col = mix(col, vec3(dot(col, vec3(0.299, 0.587, 0.114))), night * 0.5);
	} else {
		// --- цифра ---
		vec2 bsz = vec2(160.0, 90.0);
		vec2 buv = (floor(src * bsz) + 0.5) / bsz;
		vec3 c0 = fetch(src);
		vec3 cbk = fetch(buv);
		float blocky = smoothstep(0.75, 0.25, link_q);
		// часть блоков — «битые» (разная степень), mosquito по краям
		float bk = rnd(floor(src * bsz) + floor(t * 15.0));
		col = mix(c0, cbk, blocky * step(0.35, bk));
		col = pow(clamp(col, 0.0, 1.0), vec3(1.0 / 1.04)) * vec3(1.0, 1.0, 1.02);
		float g = rnd(uv * tex_size * 0.6 + fract(t) * 91.7) - 0.5;
		col += g * (0.012 + night * 0.06);
	}
	if (outside) col = vec3(0.0);
	// OSD полётника — поверх картинки (после объектива), под помехами
	vec4 o = texture(osd, suv);
	col = mix(col, o.rgb, o.a);
	if (link_type == 0) {
		float snow2 = smoothstep(0.28, 0.0, link_q);
		col = mix(col, vec3(rnd(uv * tex_size * 0.7 + t * 53.0)), snow2 * 0.9);
		float lum2 = dot(col, vec3(0.299, 0.587, 0.114));
		col = mix(vec3(lum2), col, smoothstep(0.30, 0.58, link_q));
	}

	// солнце в объектив: вуаль + 2 «призрака» по оси через центр + хроматика
	if (sun_vis > 0.001 && sun_uv.x > -0.5) {
		float d = length((uv - sun_uv) * vec2(aspect, 1.0));
		float veil = sun_vis * smoothstep(1.1, 0.0, d);
		col = col * (1.0 - 0.30 * veil) + vec3(0.95, 0.93, 0.85) * 0.55 * veil * veil;
		for (int i = 1; i <= 2; i++) {
			float k = 1.0 + float(i) * 0.55;
			vec2 gp = 0.5 + (0.5 - sun_uv) * k;
			float gd = length((uv - gp) * vec2(aspect, 1.0));
			col += vec3(0.6, 0.75, 0.5) * sun_vis * smoothstep(0.06 + 0.03 * float(i), 0.0, gd) * 0.25;
		}
		col += vec3(1.0, 0.97, 0.9) * sun_vis * smoothstep(0.05, 0.0, d) * 1.5;   // сам диск/засветка
	}

	// виньетка объектива и затемнение углов image circle
	col *= 1.0 - vignette * smoothstep(0.55, 1.25, r0);

	// SIGNAL LOST (цифра): серый затемнённый стоп-кадр
	if (lost > 0.5) {
		col = mix(col, vec3(dot(col, vec3(0.33))), 0.8) * 0.55;
	}
	COLOR = vec4(col, 1.0);
}
