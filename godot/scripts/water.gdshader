shader_type spatial;
render_mode cull_disabled, depth_draw_always;

// Вода: движущиеся волны (две частоты шума в мировых координатах), френель
// (у берега прозрачнее, вдаль зеркальнее), отражение неба через низкий roughness
// + SSR из Environment. Цвет глубины отдельно от цвета отражения.

uniform sampler2D wave_tex : filter_linear_mipmap, repeat_enable;
uniform vec3 shallow_color : source_color = vec3(0.21, 0.25, 0.20);   // мутная серо-зелёная (горная река после дождей / пруд)
uniform vec3 deep_color : source_color = vec3(0.07, 0.10, 0.09);
uniform float wave_scale = 0.06;
uniform float wave_speed = 0.03;
uniform float wave_strength = 0.5;
uniform vec2 flow_dir = vec2(1.0, 0.35);

varying vec3 wpos;

void vertex() {
	wpos = (MODEL_MATRIX * vec4(VERTEX, 1.0)).xyz;
}

void fragment() {
	// две волновые сетки, движутся в разные стороны — «живая» рябь
	vec2 uv1 = wpos.xz * wave_scale + flow_dir * TIME * wave_speed;
	vec2 uv2 = wpos.xz * wave_scale * 2.7 - flow_dir.yx * TIME * wave_speed * 1.6;
	float h1 = texture(wave_tex, uv1).r;
	float h2 = texture(wave_tex, uv2).r;

	// нормаль из градиента шума (в мировом пространстве, земля ~горизонтальна)
	float e = 0.012;
	float dx = texture(wave_tex, uv1 + vec2(e, 0.0)).r - h1
	         + (texture(wave_tex, uv2 + vec2(e, 0.0)).r - h2) * 0.6;
	float dz = texture(wave_tex, uv1 + vec2(0.0, e)).r - h1
	         + (texture(wave_tex, uv2 + vec2(0.0, e)).r - h2) * 0.6;
	vec3 wn = normalize(vec3(-dx * wave_strength * 12.0, 1.0, -dz * wave_strength * 12.0));
	NORMAL = normalize((VIEW_MATRIX * vec4(wn, 0.0)).xyz);

	// френель: под острым углом — зеркало, сверху — цвет воды
	vec3 view = normalize(CAMERA_POSITION_WORLD - wpos);
	float fres = pow(1.0 - clamp(dot(view, wn), 0.0, 1.0), 2.2);   // сверху тоже заметное отражение неба

	vec3 base = mix(shallow_color, deep_color, clamp(h1 * 0.6 + 0.3, 0.0, 1.0));
	ALBEDO = base;
	METALLIC = mix(0.35, 0.9, fres);         // к горизонту — зеркальнее
	ROUGHNESS = mix(0.18, 0.04, fres);
	SPECULAR = 0.9;
	// блики на гребнях
	float crest = smoothstep(0.72, 0.95, h1 * 0.6 + h2 * 0.4);
	EMISSION = vec3(0.25, 0.3, 0.32) * crest * 0.35;
	ALPHA = mix(0.82, 0.98, fres);
}
