shader_type canvas_item;
// Тактична топокарта для брифінгу: рельєф з відмивкою, горизонталі й земельний покрив
// рахуються з сирих даних (height.raw у RG8, mask.png), тож карта чітка на будь-якому наближенні.
// Висота — 16 біт little-endian у R (молодший) і G (старший) → білінійна інтерполяція вручну,
// бо апаратний фільтр змішав би байти окремо.

uniform sampler2D height_tex : filter_nearest;
uniform sampler2D mask_tex : filter_nearest;
uniform float px = 4096.0;
uniform float mask_px = 4096.0;
uniform float e_min = 0.0;
uniform float e_max = 1.0;
uniform float size_m = 52000.0;
uniform vec2 view_min = vec2(0.0);      // світові x,z лівого верхнього кута
uniform vec2 view_size = vec2(3000.0);  // метрів по x,z

float hraw(ivec2 i) {
	i = clamp(i, ivec2(0), ivec2(int(px) - 1));
	vec4 t = texelFetch(height_tex, i, 0);
	return e_min + (e_max - e_min) * (t.r * 255.0 + t.g * 255.0 * 256.0) / 65535.0;
}

float h_at(vec2 world) {
	vec2 p = (world / size_m + 0.5) * px - 0.5;
	ivec2 i = ivec2(floor(p));
	vec2 f = fract(p);
	return mix(mix(hraw(i), hraw(i + ivec2(1, 0)), f.x), mix(hraw(i + ivec2(0, 1)), hraw(i + ivec2(1, 1)), f.x), f.y);
}

vec3 class_col(ivec2 i) {
	i = clamp(i, ivec2(0), ivec2(int(mask_px) - 1));
	float c = floor(texelFetch(mask_tex, i, 0).r * 255.0 + 0.5);
	if (c == 1.0) return vec3(0.105, 0.155, 0.115);   // ліс
	if (c == 4.0) return vec3(0.200, 0.205, 0.150);   // рілля
	if (c == 6.0) return vec3(0.150, 0.185, 0.130);   // чагарник
	if (c == 7.0) return vec3(0.100, 0.150, 0.180);   // вода
	if (c == 8.0) return vec3(0.215, 0.205, 0.185);   // голий ґрунт / скеля
	return vec3(0.165, 0.200, 0.145);                 // луки, дороги й забудова (їх малюють вектори)
}

vec3 cover_at(vec2 world) {
	vec2 p = (world / size_m + 0.5) * mask_px - 0.5;
	ivec2 i = ivec2(floor(p));
	vec2 f = fract(p);
	return mix(mix(class_col(i), class_col(i + ivec2(1, 0)), f.x), mix(class_col(i + ivec2(0, 1)), class_col(i + ivec2(1, 1)), f.x), f.y);
}

// покрив розмитий на ~1.5 клітинки маски: межі лісу/лук без «клітинок» 12.7 м
vec3 cover_soft(vec2 world) {
	float c = size_m / mask_px * 0.85;
	return (cover_at(world + vec2(c, c)) + cover_at(world + vec2(-c, c)) + cover_at(world + vec2(c, -c)) + cover_at(world + vec2(-c, -c))) * 0.25;
}

float contour(float h, float step_m, float width_px) {
	float v = h / step_m;
	float d = abs(fract(v - 0.5) - 0.5) / max(fwidth(v), 1e-5);
	return 1.0 - smoothstep(0.0, width_px, d);
}

void fragment() {
	vec2 world = view_min + UV * view_size;
	float cell = size_m / px;
	float h = h_at(world);
	float hx = h_at(world + vec2(cell, 0.0)) - h_at(world - vec2(cell, 0.0));
	float hz = h_at(world + vec2(0.0, cell)) - h_at(world - vec2(0.0, cell));
	vec3 n = normalize(vec3(-hx, 2.0 * cell, -hz));
	// світло з північного заходу, як на класичних топокартах
	vec3 L = normalize(vec3(-0.6, 0.75, -0.6));
	float shade = clamp(dot(n, L), 0.0, 1.0);
	float slope = 1.0 - n.y;

	vec3 col = cover_soft(world);
	float rel = clamp((h - e_min) / max(e_max - e_min, 1.0), 0.0, 1.0);
	col *= 0.5 + 1.1 * shade;
	col = mix(col, col * vec3(1.08, 1.06, 1.0) + 0.03, rel * 0.6);
	col = mix(col, vec3(0.05, 0.06, 0.055), clamp(slope * 1.6, 0.0, 0.35));

	// горизонталі: 20 м тонкі, 100 м — потовщені
	float minor = contour(h, 20.0, 0.9);
	float major = contour(h, 100.0, 1.3);
	col = mix(col, vec3(0.78, 0.74, 0.55), minor * 0.16);
	col = mix(col, vec3(0.85, 0.80, 0.58), major * 0.40);
	COLOR = vec4(col, 1.0);
}
