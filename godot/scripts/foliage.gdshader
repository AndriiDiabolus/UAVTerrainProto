shader_type spatial;
render_mode cull_disabled, depth_prepass_alpha;

// Листва/хвоя на кросс-картах: альфа-вырезка по процедурной текстуре, мягкая «объёмная» нормаль,
// просвет (backlight), качание на ветру как у tree.gdshader (ствол стоит, крона гуляет).

uniform sampler2D tex : source_color, filter_linear_mipmap_anisotropic;
uniform vec2 wind_dir = vec2(1.0, 0.0);
uniform float wind_strength : hint_range(0.0, 3.0) = 0.3;
uniform float pivot_y = 0.0;
uniform vec3 base_color : source_color = vec3(0.15, 0.3, 0.12);
uniform float leaf_flutter = 1.0;   // хвоя дрожит меньше, листва больше

varying float vdist;

void vertex() {
	vec3 o = MODEL_MATRIX[3].xyz;
	float h = max(VERTEX.y - pivot_y, 0.0);
	float hh = h * h;
	float t = TIME * 1.2;
	float travel = dot(o.xz, wind_dir) * 0.045;
	float rnd = fract(sin(o.x * 12.9898 + o.z * 78.233) * 43758.5453) * 6.2831;
	float q = 0.5 + 0.5 * (sin(t - travel + rnd * 0.5) * 0.62 + sin(t * 1.7 - travel * 1.3 + rnd) * 0.38);
	float lean = hh * 0.010 * wind_strength;
	float flutter = hh * 0.006 * wind_strength * q;
	vec2 perp = vec2(-wind_dir.y, wind_dir.x);
	float cross = hh * 0.0022 * wind_strength * sin(t * 1.9 + rnd);
	VERTEX.xz += wind_dir * (lean + flutter) + perp * cross;
	// мелкий трепет листьев (по UV, чтобы края карты «дышали»)
	VERTEX.y += sin(t * 3.1 + rnd + UV.x * 6.0) * 0.03 * wind_strength * leaf_flutter * h;
	vdist = length((MODELVIEW_MATRIX * vec4(VERTEX, 1.0)).xyz);
}

void fragment() {
	vec4 c = texture(tex, UV);
	// вдали порог ниже — иначе мипы «съедают» листву и дерево редеет
	float thr = 0.5 - 0.28 * clamp(vdist / 1200.0, 0.0, 1.0);
	ALPHA = c.a;
	ALPHA_SCISSOR_THRESHOLD = thr;
	ALBEDO = c.rgb * base_color * COLOR.rgb;
	// нормаль: смесь нормали карты и «вверх» — крона освещается как объём, а не как плоскость
	vec3 up_v = normalize((VIEW_MATRIX * vec4(0.0, 1.0, 0.0, 0.0)).xyz);
	vec3 n = normalize(NORMAL);
	if (!FRONT_FACING) { n = -n; }
	NORMAL = normalize(mix(n, up_v, 0.65));
	ROUGHNESS = 0.92;
	SPECULAR = 0.15;
	BACKLIGHT = vec3(0.30, 0.34, 0.16) * c.rgb;   // просвет листвы на солнце
}
