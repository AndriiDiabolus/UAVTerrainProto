shader_type spatial;

// Процедурный фасад со случайной вариацией по дому (INSTANCE_ID):
//  • окна реальной сеткой, дверь только на переднем длинном фасаде;
//  • у части домов ставни (свой цвет), у части окон горит свет (тёплое EMISSION,
//    доля растёт к ночи через lit_amount); цоколь-фундамент; вариативные двери.
// Габариты дома: INSTANCE_CUSTOM (w,h,d,type). Базовый цвет стены: INSTANCE COLOR.

uniform vec3 win_glass = vec3(0.15, 0.21, 0.29);
uniform vec3 win_frame = vec3(0.92, 0.90, 0.85);
uniform float lit_amount : hint_range(0.0, 1.0) = 0.03;

varying vec3 vcol;
varying vec4 vdim;
varying vec3 lnorm;
varying vec2 vuv;
varying float bseed;
varying vec2 wxz;
varying float vy;
// тепловизор: thermal_params = (режим 0/1, ночь 0/1, остывание 0..1, —). В режиме: ALBEDO=0, EMISSION=температура 0..1
global uniform vec4 thermal_params;

// тени облаков (глобальные uniform'ы)
global uniform sampler2D cloud_shadow_tex;
global uniform vec4 cloud_shadow_params;
float cloud_shadow(vec2 pxz) {
	float n = texture(cloud_shadow_tex, pxz * cloud_shadow_params.w + cloud_shadow_params.xy).r;
	return 1.0 - smoothstep(0.50, 0.72, n) * cloud_shadow_params.z;
}


const float COL_STEP = 3.2;
const float FLOOR_H  = 3.0;
const float WIN_W    = 1.4;
const float WIN_H    = 1.4;
const float SILL     = 1.0;
const float HALF     = 0.7;

float h11(float p) { p = fract(p * 0.1031); p *= p + 33.33; p *= p + p; return fract(p); }
float h21(vec2 p) {
	vec3 p3 = fract(vec3(p.xyx) * 0.1031);
	p3 += dot(p3, p3.yzx + 33.33);
	return fract((p3.x + p3.y) * p3.z);
}

void vertex() {
	vcol = COLOR.rgb;
	vdim = INSTANCE_CUSTOM;
	lnorm = NORMAL;
	vuv = UV;
	bseed = float(INSTANCE_ID);
	wxz = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xz;
	vy = VERTEX.y + 0.5;   // 0 у основания, 1 у карниза (BoxMesh)
}

void fragment() {
	float w = vdim.x, h = vdim.y, d = vdim.z, typ = vdim.w;
	vec3 col = vcol;
	vec3 emit = vec3(0.0);

	bool zface = abs(lnorm.z) > 0.5;
	bool xface = abs(lnorm.x) > 0.5;

	if (zface || xface) {
		// вариации по дому
		bool shutters = (typ < 0.5) && (h11(bseed + 1.0) > 0.4);
		float si = h11(bseed + 5.0);
		vec3 shutC = si < 0.25 ? vec3(0.42,0.28,0.18) : si < 0.5 ? vec3(0.30,0.40,0.34)
			: si < 0.75 ? vec3(0.24,0.32,0.44) : vec3(0.5,0.42,0.22);
		float di = h11(bseed + 9.0);
		vec3 doorC = di < 0.33 ? vec3(0.36,0.22,0.13) : di < 0.66 ? vec3(0.28,0.30,0.36)
			: vec3(0.44,0.36,0.24);

		float fw = zface ? w : d;
		bool longZ = w >= d;
		bool doorFace = (zface && lnorm.z > 0.5 && longZ) || (xface && lnorm.x > 0.5 && !longZ);

		float u = vuv.x * fw;
		float v = (1.0 - vuv.y) * h;

		// цоколь-фундамент
		if (v < 0.5) col = vcol * 0.55;

		int cols = int(max(1.0, floor(fw / COL_STEP + 0.5)));
		float cstep = fw / float(cols);
		float ci = floor(u / cstep);
		float cx = (ci + 0.5) * cstep;
		float dx = abs(u - cx);
		int floors = int(max(1.0, floor(h / FLOOR_H)));
		float fi = floor((v - SILL) / FLOOR_H);
		float fv = mod(v - SILL, FLOOR_H);
		bool inRows = (v > SILL) && (fv < WIN_H) && (v < float(floors) * FLOOR_H);

		float centerX = float(cols) * 0.5 * cstep;
		bool doorCol = abs(u - centerX) < 0.55;
		bool isDoor = doorFace && doorCol && v < 2.1;

		// ставни (снаружи окна)
		if (shutters && inRows && !isDoor && dx > HALF && dx < HALF + 0.34) {
			col = shutC * (0.85 + 0.15 * step(0.5, fract(fv * 3.0)));
		}

		// окно
		if (inRows && dx < HALF && !(doorFace && doorCol && v < SILL + FLOOR_H)) {
			float mx = HALF - dx;
			float mv = min(fv, WIN_H - fv);
			float m = min(mx, mv);
			if (m < 0.12) {
				col = win_frame;
			} else {
				// часть домов «спит» целиком (45 %), в остальных — доля окон по lit_amount
				float house_awake = step(0.45, h21(vec2(bseed * 3.1, 7.7)));
				bool lit = h21(vec2(bseed * 17.0 + ci, fi + 1.0)) < lit_amount * 0.7 * house_awake;
				if (lit) {
					col = vec3(1.0, 0.86, 0.58);
					emit = vec3(1.0, 0.78, 0.42) * 2.2;
				} else {
					col = win_glass;
					if (dx < 0.03 || abs(fv - WIN_H * 0.5) < 0.03) col = win_frame;
					col += vec3(0.05, 0.06, 0.07) * (1.0 - fv / WIN_H);
				}
			}
		}

		// дверь
		if (isDoor) {
			col = doorC;
			if (v > 2.0 || abs(u - centerX) > 0.5) col = win_frame;   // наличник
			else if (abs(u - centerX) < 0.02) col = doorC * 0.55;      // створки
			else if (v > 1.5 && v < 1.85 && dx < 0.3) col = win_glass; // окошко в двери
		}
	}

	// AO и грязевой поясок у основания (0–0.7 м), лёгкое потемнение к низу стены; яркость стен ±8 % по дому
	float hm = vy * h;
	float base_ao = 0.62 + 0.38 * smoothstep(0.0, 0.8, hm);
	col *= base_ao * (0.92 + 0.16 * h11(bseed + 31.0));
	ALBEDO = col * cloud_shadow(wxz);
	EMISSION = emit;
	if (thermal_params.x > 0.5) {
		float hot = step(0.5, length(emit));          // освещённое окно — тёплое
		ALBEDO = vec3(0.0); EMISSION = vec3(mix(mix(0.46, 0.40, thermal_params.y), 0.78, hot));
	}
	ROUGHNESS = (zface || xface) ? 0.85 : 1.0;
}
