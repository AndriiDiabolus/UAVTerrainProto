shader_type canvas_item;

// Пост-эффект аналогового FPV-видео: бочкообразная дисторсия (рыбий глаз),
// виньетка, хроматические аберрации, зерно, строчные помехи и лёгкий роллинг.

uniform sampler2D screen_tex : hint_screen_texture, filter_linear_mipmap;
uniform float distortion : hint_range(0.0, 0.6) = 0.18;
uniform float vignette : hint_range(0.0, 1.5) = 0.75;
uniform float chroma : hint_range(0.0, 0.01) = 0.0022;
uniform float grain : hint_range(0.0, 0.3) = 0.055;
uniform float scanline : hint_range(0.0, 0.3) = 0.05;
uniform float noise_burst : hint_range(0.0, 1.0) = 0.0;  // помехи при слабом сигнале

float rnd(vec2 p) {
	return fract(sin(dot(p, vec2(12.9898, 78.233))) * 43758.5453);
}

void fragment() {
	vec2 uv = SCREEN_UV;
	vec2 c = uv - 0.5;
	float r2 = dot(c, c);

	// бочка (широкоугольный объектив)
	vec2 duv = uv + c * r2 * distortion;

	// хроматические аберрации к краям
	vec2 dir = c * (r2 * 2.0 + 0.35);
	float rr = texture(screen_tex, duv + dir * chroma).r;
	float gg = texture(screen_tex, duv).g;
	float bb = texture(screen_tex, duv - dir * chroma).b;
	vec3 col = vec3(rr, gg, bb);

	// за границей кадра — чёрное поле объектива
	if (duv.x < 0.0 || duv.x > 1.0 || duv.y < 0.0 || duv.y > 1.0) {
		col = vec3(0.0);
	}

	// строчная структура аналогового видео
	col *= 1.0 - scanline * (0.5 + 0.5 * sin(SCREEN_UV.y * 900.0));

	// зерно
	float g = rnd(SCREEN_UV * 700.0 + fract(TIME) * 91.7) - 0.5;
	col += g * grain;

	// помехи/срывы строк при слабом сигнале
	if (noise_burst > 0.001) {
		float band = step(1.0 - noise_burst * 0.25,
			rnd(vec2(floor(SCREEN_UV.y * 120.0), floor(TIME * 12.0))));
		col = mix(col, vec3(rnd(SCREEN_UV * 300.0 + TIME)), band * noise_burst);
	}

	// виньетка
	col *= 1.0 - vignette * smoothstep(0.15, 0.72, r2);

	COLOR = vec4(col, 1.0);
}
