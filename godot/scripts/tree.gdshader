shader_type spatial;

// Качание деревьев на ветру: смещение вершин растёт с высотой над землёй
// (ствол стоит, крона гуляет), фаза зависит от мировой позиции инстанса —
// деревья качаются вразнобой, волной по лесу.

uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.3;
uniform float pivot_y = 0.0;      // высота, ниже которой смещения нет (комель)
uniform vec3 base_color : source_color = vec3(0.15, 0.3, 0.12);

void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	float h = max(VERTEX.y - pivot_y, 0.0);
	float hh = h * h;                                  // ствол стоит, крона гуляет
	float t = TIME * 1.2;

	// бегущая по ветру волна порыва (гребень идёт вниз по потоку) + разнобой деревьев
	float travel = dot(o.xz, wind_dir) * 0.045;
	float rnd = fract(sin(o.x * 12.9898 + o.z * 78.233) * 43758.5453) * 6.2831;
	// трепет 0..1 — ВСЕГДА добавляет по ветру, дерево не уходит навстречу
	float q = 0.5 + 0.5 * (sin(t - travel + rnd * 0.5) * 0.62
	                     + sin(t * 1.7 - travel * 1.3 + rnd) * 0.38);

	float lean = hh * 0.010 * wind_strength;           // постоянный наклон по ветру
	float flutter = hh * 0.006 * wind_strength * q;    // порыв гнёт СИЛЬНЕЕ по ветру
	// лёгкое поперечное дрожание листвы (маленькое — общее направление по ветру)
	vec2 perp = vec2(-wind_dir.y, wind_dir.x);
	float cross = hh * 0.0022 * wind_strength * sin(t * 1.9 + rnd);

	VERTEX.xz += wind_dir * (lean + flutter) + perp * cross;
}

void fragment() {
	ALBEDO = base_color * COLOR.rgb;   // цвет части × per-instance вариация
	ROUGHNESS = 1.0;
}
