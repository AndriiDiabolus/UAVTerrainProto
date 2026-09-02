extends Node3D
## Погода и время суток. Клавиши 1-5 — пресеты, P — цикл. Ветер сносит дрон и дождь.

var main: Node3D
var sun: DirectionalLight3D
var env: Environment
var sky: ShaderMaterial

var wind := Vector3.ZERO
var wind_speed := 0.0
var label := ""
var idx := 0

var _rain_holder: Node3D
var _rain: GPUParticles3D
var _t := 0.0
var _flash := 0.0
var _cloud_strength := 0.4
var _cloud_off := Vector2.ZERO

# Пресеты: имя, поворот солнца(°), энергия/цвет солнца, ambient, цвета неба, туман, тон, дождь(0/1), ветер(м/с), направление(°)
const PRESETS := [
	{"name": "☀ Ясный день", "srot": Vector3(-52, -120, 0), "se": 1.35, "sc": Color(1.0, 0.97, 0.9),
	 "amb": Color(0.52, 0.6, 0.72), "ae": 0.35, "top": Color(0.16, 0.38, 0.80), "hor": Color(0.70, 0.80, 0.92),
	 "gnd": Color(0.55, 0.62, 0.7), "fog": 0.0000012, "fogc": Color(0.78, 0.84, 0.92),
	 "br": 1.25, "sat": 1.15, "rain": 0.0, "lit": 0.02, "cov": 0.32, "ccol": Color(1,1,1), "cdark": Color(0.62,0.66,0.72), "wind": 3.0, "wdir": 40.0},

	{"name": "☁ Облачно, ветер", "srot": Vector3(-58, -100, 0), "se": 0.5, "sc": Color(0.85, 0.87, 0.9),
	 "amb": Color(0.55, 0.58, 0.62), "ae": 0.5, "top": Color(0.55, 0.6, 0.66), "hor": Color(0.7, 0.72, 0.75),
	 "gnd": Color(0.6, 0.62, 0.65), "fog": 0.000006, "fogc": Color(0.72, 0.74, 0.77),
	 "br": 1.05, "sat": 0.85, "rain": 0.0, "lit": 0.05, "cov": 0.74, "ccol": Color(0.86,0.87,0.9), "cdark": Color(0.5,0.52,0.56), "wind": 12.0, "wdir": 200.0},

	{"name": "🌧 Дождь, шторм", "srot": Vector3(-62, -90, 0), "se": 0.32, "sc": Color(0.7, 0.72, 0.76),
	 "amb": Color(0.4, 0.42, 0.46), "ae": 0.45, "top": Color(0.38, 0.4, 0.44), "hor": Color(0.5, 0.51, 0.54),
	 "gnd": Color(0.44, 0.45, 0.48), "fog": 0.000016, "fogc": Color(0.55, 0.57, 0.6),
	 "br": 0.92, "sat": 0.7, "rain": 1.0, "lit": 0.12, "fh": 1150, "fhd": 0.0, "cov": 0.92, "ccol": Color(0.6,0.62,0.66), "cdark": Color(0.3,0.32,0.36), "wind": 10.0, "wdir": 220.0},

	{"name": "🌇 Закат", "srot": Vector3(-8, -95, 0), "se": 1.4, "sc": Color(1.0, 0.62, 0.32),
	 "amb": Color(0.5, 0.4, 0.42), "ae": 0.3, "top": Color(0.28, 0.3, 0.55), "hor": Color(0.95, 0.55, 0.32),
	 "gnd": Color(0.5, 0.42, 0.42), "fog": 0.000004, "fogc": Color(0.85, 0.55, 0.4),
	 "br": 1.2, "sat": 1.3, "rain": 0.0, "lit": 0.22, "fh": 940, "fhd": 0.0, "cov": 0.48, "ccol": Color(1.0,0.82,0.66), "cdark": Color(0.62,0.44,0.5), "wind": 2.5, "wdir": 300.0},

	{"name": "🌙 Ночь", "srot": Vector3(-42, -60, 0), "se": 0.14, "sc": Color(0.6, 0.68, 0.9),
	 "amb": Color(0.12, 0.15, 0.24), "ae": 0.4, "top": Color(0.03, 0.04, 0.1), "hor": Color(0.09, 0.11, 0.2),
	 "gnd": Color(0.06, 0.07, 0.12), "fog": 0.000009, "fogc": Color(0.1, 0.12, 0.2),
	 "br": 0.95, "sat": 0.8, "rain": 0.0, "lit": 0.45, "fh": 900, "fhd": 0.0, "cov": 0.5, "ccol": Color(0.22,0.24,0.32), "cdark": Color(0.07,0.08,0.13), "wind": 5.0, "wdir": 120.0},

	{"name": "☁☁ Пасмурно (overcast)", "srot": Vector3(-55, -110, 0), "se": 0.30, "sc": Color(0.9, 0.91, 0.93),
	 "amb": Color(0.62, 0.64, 0.67), "ae": 0.75, "top": Color(0.58, 0.60, 0.64), "hor": Color(0.72, 0.73, 0.75),
	 "gnd": Color(0.62, 0.63, 0.65), "fog": 0.000009, "fogc": Color(0.72, 0.73, 0.75),
	 "br": 1.0, "sat": 0.78, "rain": 0.0, "lit": 0.08, "cov": 1.0, "ccol": Color(0.70,0.71,0.73), "cdark": Color(0.52,0.53,0.56), "wind": 6.0, "wdir": 250.0},
]


func setup(m: Node3D, s: DirectionalLight3D, e: Environment, sk: ShaderMaterial) -> void:
	main = m
	sun = s
	env = e
	sky = sk
	_build_rain()
	_parse_time_flags()
	_fog_extra = "--fog" in OS.get_cmdline_user_args()
	_noshadows = "--noshadows" in OS.get_cmdline_user_args()
	var start := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--weather="):
			start = clampi(int(a.substr(10)), 0, PRESETS.size() - 1)
	apply(start)


# Дождь по игровому канону (AC4/Cyberpunk GDC): слои стриков-билбордов с мягкой текстурой
# (ближний — крупные редкие, дальний — мелкие плотные), весь узел наклоняется по ветру
# (штрих летит ВДОЛЬ траектории, а не «вертикальные пиксели»), у земли — брызги-кольца.
var _rain_far: GPUParticles3D
var _splash: GPUParticles3D
var _streak_tex: ImageTexture

func _streak_texture() -> ImageTexture:
	if _streak_tex != null:
		return _streak_tex
	var img := Image.create(16, 128, true, Image.FORMAT_RGBA8)
	for y in 128:
		var fy := 1.0 - absf(y / 127.0 * 2.0 - 1.0)          # растворение к концам штриха
		fy = pow(fy, 0.6)
		for x in 16:
			var fx := 1.0 - absf(x / 15.0 * 2.0 - 1.0)       # мягкий гауссов профиль поперёк
			fx = pow(fx, 1.6)
			img.set_pixel(x, y, Color(0.82, 0.87, 0.95, fx * fy))
	img.generate_mipmaps()
	_streak_tex = ImageTexture.create_from_image(img)
	return _streak_tex


func _make_rain_layer(amount: int, box: float, sw: float, sh: float, alpha: float) -> GPUParticles3D:
	var gp := GPUParticles3D.new()
	gp.amount = amount
	gp.lifetime = 4.2
	gp.local_coords = true                       # частицы в локале наклонённого узла — штрих вдоль падения
	gp.visibility_aabb = AABB(Vector3(-box - 40, -80, -box - 40), Vector3(box * 2 + 80, 160, box * 2 + 80))
	gp.position = Vector3(0, 26, 0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(box, 30, box)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 0.0
	pm.initial_velocity_min = 13.0
	pm.initial_velocity_max = 18.0
	pm.gravity = Vector3.ZERO                    # ветер — наклоном узла, не гравитацией
	pm.scale_min = 0.7
	pm.scale_max = 1.35
	gp.process_material = pm
	var quad := QuadMesh.new()
	quad.size = Vector2(sw, sh)
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_texture = _streak_texture()
	rmat.albedo_color = Color(1, 1, 1, alpha)
	rmat.billboard_mode = BaseMaterial3D.BILLBOARD_FIXED_Y   # крутится к камере вокруг оси падения
	rmat.billboard_keep_scale = true
	quad.material = rmat
	gp.draw_pass_1 = quad
	gp.emitting = false
	return gp


func _make_splash() -> GPUParticles3D:
	var gp := GPUParticles3D.new()
	gp.amount = 420
	gp.lifetime = 0.34
	gp.local_coords = false
	gp.visibility_aabb = AABB(Vector3(-30, -4, -30), Vector3(60, 8, 60))
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(24, 0.1, 24)
	pm.gravity = Vector3.ZERO
	pm.initial_velocity_min = 0.0
	pm.initial_velocity_max = 0.0
	var curve := Curve.new()                     # кольцо разрастается за жизнь
	curve.add_point(Vector2(0, 0.25)); curve.add_point(Vector2(1, 1.0))
	var ct := CurveTexture.new(); ct.curve = curve
	pm.scale_curve = ct
	var grad := Gradient.new()                   # и растворяется
	grad.set_color(0, Color(0.85, 0.9, 1.0, 0.5)); grad.set_color(1, Color(0.85, 0.9, 1.0, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
	gp.process_material = pm
	var ring := PlaneMesh.new()
	ring.size = Vector2(0.34, 0.34)
	var rm := StandardMaterial3D.new()
	rm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rm.albedo_texture = _ring_texture()
	rm.vertex_color_use_as_albedo = true
	ring.material = rm
	gp.draw_pass_1 = ring
	gp.emitting = false
	return gp


func _ring_texture() -> ImageTexture:
	var img := Image.create(32, 32, true, Image.FORMAT_RGBA8)
	for y in 32:
		for x in 32:
			var d := Vector2(x - 15.5, y - 15.5).length() / 15.5
			var a := clampf(1.0 - absf(d - 0.72) * 5.0, 0.0, 1.0)   # тонкое кольцо
			img.set_pixel(x, y, Color(1, 1, 1, a * 0.8))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


# «Куртины» дождя (метод WoW/MMO): вложенные цилиндры вокруг камеры со скроллящейся
# текстурой из сотен штрихов — плотная стена воды на любом фоне, параллакс между слоями.
var _curtains: Array = []

func _curtain_texture() -> ImageTexture:
	var img := Image.create(256, 256, true, Image.FORMAT_RGBA8)
	img.fill(Color(1, 1, 1, 0))
	var rng := RandomNumberGenerator.new(); rng.seed = 11
	for i in 240:
		var x := rng.randi_range(0, 255)
		var y0i := rng.randi_range(0, 255)
		var ln := rng.randi_range(18, 64)
		var al := rng.randf_range(0.16, 0.5)
		var wdt := 1 if rng.randf() < 0.7 else 2
		for k in ln:
			var y := (y0i + k) % 256
			var fade := sin(float(k) / ln * PI)          # мягкие концы штриха
			for wx in wdt:
				img.set_pixel((x + wx) % 256, y, Color(1, 1, 1, al * fade))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


const CURTAIN_SHADER := "
shader_type spatial;
render_mode unshaded, blend_mix, cull_disabled, depth_draw_never;
uniform sampler2D streaks;
uniform float speed = 1.0;
uniform float reps = 6.0;
uniform float vreps = 1.0;
uniform float amount = 1.0;
uniform vec4 tint : source_color = vec4(0.78, 0.83, 0.92, 0.16);
void fragment() {
	vec2 uv = vec2(UV.x * reps, UV.y * vreps + TIME * speed);
	float a = texture(streaks, uv).a;
	float edge = smoothstep(0.0, 0.12, UV.y) * smoothstep(1.0, 0.88, UV.y);
	ALBEDO = tint.rgb;
	ALPHA = a * tint.a * edge * amount;
}"

func _make_curtain(radius: float, h: float, reps: float, vreps: float, speed: float, alpha: float) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = radius; cyl.bottom_radius = radius; cyl.height = h
	cyl.cap_top = false; cyl.cap_bottom = false
	cyl.radial_segments = 24; cyl.rings = 1
	mi.mesh = cyl
	var sh := Shader.new(); sh.code = CURTAIN_SHADER
	var mat := ShaderMaterial.new(); mat.shader = sh
	mat.set_shader_parameter("streaks", _streak_curtain_tex)
	mat.set_shader_parameter("reps", reps)
	mat.set_shader_parameter("vreps", vreps)
	mat.set_shader_parameter("speed", speed)
	mat.set_shader_parameter("tint", Color(0.78, 0.83, 0.92, alpha))
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mi.visible = false
	return mi


var _streak_curtain_tex: ImageTexture

func _build_rain() -> void:
	_rain_holder = Node3D.new()
	add_child(_rain_holder)
	_streak_curtain_tex = _curtain_texture()
	# три вложенных куртины: ближняя быстрая крупная, дальние плотнее и медленнее по UV
	for cfg in [[7.0, 26.0, 3.0, 1.0, 1.35, 0.075], [16.0, 44.0, 5.0, 1.6, 0.8, 0.095], [36.0, 70.0, 8.0, 2.4, 0.5, 0.12]]:
		var c := _make_curtain(cfg[0], cfg[1], cfg[2], cfg[3], cfg[4], cfg[5])
		_rain_holder.add_child(c)
		_curtains.append(c)
	_rain = _make_rain_layer(1100, 26.0, 0.030, 0.8, 0.3)     # ближние крупные капли-штрихи
	_rain_far = _make_rain_layer(1400, 90.0, 0.1, 2.6, 0.15)   # редкие дальние акценты
	_rain_holder.add_child(_rain)
	_rain_holder.add_child(_rain_far)
	_splash = _make_splash()
	add_child(_splash)


## Непрерывные параметры пресета (интерполируются при смене погоды).
func _cont_of(p: Dictionary, i: int) -> Dictionary:
	var night := 1.0 if i == 4 else 0.0
	return {
		"srot": Vector3(p.srot),
		"se": float(p.se) * 1.35 * (2.6 if i == 4 else 1.0),
		"sc": Color(p.sc), "amb": Color(p.amb),
		"ae": float(p.ae) * 1.1 * (2.6 if i == 4 else 1.0),
		"top": Color(p.top), "hor": Color(p.hor), "gnd": Color(p.gnd),
		"cov": float(p.get("cov", 0.4)), "ccol": Color(p.get("ccol", Color(1, 1, 1))),
		"cdark": Color(p.get("cdark", Color(0.55, 0.58, 0.62))),
		"night": night,
		"fogd": float(p.fog) * (40.0 if i == 0 else 20.0),
		"fogc": Color(p.fogc).lerp(Color(p.hor), 0.5),
		"br": 0.92 + (float(p.br) - 1.0) * 0.5 + (0.22 if i == 4 else 0.0),
		"sat": 0.86 + (float(p.sat) - 1.0) * 0.5,
		"wind": float(p.wind), "wdir": float(p.wdir),
		"lit": float(p.get("lit", 0.03)),
		"cldstr": {0: 0.45, 1: 0.22, 2: 0.0, 3: 0.40, 4: 0.12, 5: 0.0}.get(i, 0.3),
		# тени: плотность (0 = нет прямого солнца) и угловой размер источника (диффузный свет → мягче края)
		"shop": {0: 0.92, 1: 0.45, 2: 0.0, 3: 0.88, 4: 0.5, 5: 0.12}.get(i, 0.6),
		"sang": {0: 0.53, 1: 2.2, 2: 3.5, 3: 0.9, 4: 1.5, 5: 4.0}.get(i, 1.0),
	}


func _mix_cont(a: Dictionary, b: Dictionary, t: float) -> Dictionary:
	var o := {}
	for k in b:
		var vb = b[k]
		var va = a.get(k, vb)
		if vb is Color: o[k] = (va as Color).lerp(vb, t)
		elif k == "wdir": o[k] = rad_to_deg(lerp_angle(deg_to_rad(float(va)), deg_to_rad(float(vb)), t))
		elif vb is Vector3: o[k] = (va as Vector3).lerp(vb, t)
		else: o[k] = lerpf(float(va), float(vb), t)
	return o


## Применить непрерывный набор к сцене.
func _apply_cont(c: Dictionary) -> void:
	_cur_cont = c
	sun.light_color = c.sc
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = c.amb
	env.ambient_light_energy = c.ae
	sky.set_shader_parameter("top_color", c.top)
	sky.set_shader_parameter("horizon_color", c.hor)
	sky.set_shader_parameter("ground_color", c.gnd)
	sky.set_shader_parameter("sun_color", c.sc)
	sky.set_shader_parameter("coverage", c.cov)
	sky.set_shader_parameter("cloud_color", c.ccol)
	sky.set_shader_parameter("cloud_dark", c.cdark)
	sky.set_shader_parameter("night", c.night)
	var wa: float = deg_to_rad(float(c.wdir))
	sky.set_shader_parameter("wind_dir", Vector2(cos(wa), sin(wa)))
	env.fog_density = c.fogd
	env.fog_light_color = c.fogc
	env.adjustment_brightness = c.br
	env.adjustment_saturation = c.sat
	_cloud_strength = c.cldstr
	wind_speed = c.wind
	wind = Vector3(cos(wa), 0, sin(wa)) * wind_speed
	if main != null and main.has_method("set_window_light"):
		main.set_window_light(c.lit)


var _cur_cont := {}
var _trans_from := {}
var _trans_to := {}
var _trans := 1.0
const TRANS_SEC := 18.0        # плавная смена погоды ~18 с


func apply(i: int, instant: bool = false) -> void:
	idx = (i + PRESETS.size()) % PRESETS.size()
	var p: Dictionary = PRESETS[idx]
	label = p.name
	_ephem_announce = _sun_by_time
	# дискретное — сразу (целевые флаги); тени — непрерывно в _update_sun (shop/sang в _cont_of)
	env.fog_aerial_perspective = 0.85
	env.fog_sky_affect = 0.18
	env.fog_height = p.get("fh", 0.0)
	env.glow_intensity = 0.6 if idx == 4 else 0.35
	# глобальная плотность объёмного тумана почти нулевая: туман живёт в пятнах по долинам (valley_fog)
	env.volumetric_fog_density = 0.00001 + float(p.fog) * 1.5
	env.background_energy_multiplier = 1.0
	# непрерывное — через переход
	_trans_to = _cont_of(p, idx)
	if instant or _cur_cont.is_empty():
		_trans = 1.0
		_apply_cont(_trans_to)
	else:
		_trans_from = _cur_cont.duplicate()
		_trans = 0.0
	# ручные тумблеры (6/7) поверх любого пресета
	# туман по долинам (объёмный, пятнами): клавиша 6 — включить с полной плотностью (рассеется на солнце);
	# пасмурно/дождь/ночь/закат — держится сам с меньшей плотностью
	env.fog_height_density = 0.0
	if main.get("valley_fog") != null:
		if _fog_extra:
			main.valley_fog.set_enabled(true, true, idx in [1, 2, 5], 1.0)
		else:
			var auto := {2: 0.5, 5: 0.35}      # сам включается только в дождь/шторм и пасмурно; остальное — клавиша 6
			if auto.has(idx):
				main.valley_fog.set_enabled(true, true, idx in [1, 2, 5], float(auto[idx]))
			else:
				main.valley_fog.set_enabled(false)
	var raining_now: bool = (float(p.rain) > 0.0) or _rain_extra
	_rain.emitting = raining_now
	_rain_far.emitting = raining_now
	_splash.emitting = raining_now
	var amt := 0.85 if float(p.rain) > 0.0 else 0.6   # шторм — полная стена, клавиша 7 — умереннее
	for c: MeshInstance3D in _curtains:
		c.visible = raining_now
		(c.material_override as ShaderMaterial).set_shader_parameter("amount", amt)


var _fog_extra := false
var _rain_extra := false


## Идёт ли дождь (пресет шторма или клавиша 7) — для звука, мокрости, капель на линзе.
func raining() -> bool:
	return _rain_extra or float(PRESETS[idx].get("rain", 0.0)) > 0.0
var wetness := 0.0       # мокрая земля: растёт в дождь (~45 с), сохнет (~4 мин)
var _wet_applied := -1.0

# --- солнце по дате/времени (--date=YYYY-MM-DD --time=HH:MM, локальное время Киева UTC+3) ---
var _sun_by_time := false
var _date := [2026, 8, 18]
var _time_h := 14.0

func _parse_time_flags() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--date="):
			var p := a.substr(7).split("-")
			if p.size() == 3:
				_date = [int(p[0]), int(p[1]), int(p[2])]; _sun_by_time = true
		elif a.begins_with("--time="):
			var p := a.substr(7).split(":")
			if p.size() >= 1:
				_time_h = float(p[0]) + (float(p[1]) / 60.0 if p.size() > 1 else 0.0); _sun_by_time = true
		elif a.begins_with("--timescale="):
			_timescale = maxf(0.0, float(a.substr(12)))


## Положение солнца (упрощённый NOAA-алгоритм: склонение + уравнение времени + часовой угол),
## точность ~0.5° — достаточно, чтобы тени и свет соответствовали дате/часу.
func sun_position(lat: float, lon: float, y: int, m: int, d: int, local_h: float, tz: float) -> Vector2:
	var a := int((14 - m) / 12)
	var yy := y + 4800 - a
	var mm := m + 12 * a - 3
	var jdn := d + int((153 * mm + 2) / 5) + 365 * yy + int(yy / 4) - int(yy / 100) + int(yy / 400) - 32045
	var jd := float(jdn) + (local_h - tz) / 24.0 - 0.5
	var n := jd - 2451545.0
	var L := fmod(280.460 + 0.9856474 * n, 360.0)
	var g := deg_to_rad(fmod(357.528 + 0.9856003 * n, 360.0))
	var lam := deg_to_rad(L + 1.915 * sin(g) + 0.020 * sin(2.0 * g))
	var eps := deg_to_rad(23.439 - 0.0000004 * n)
	var decl := asin(sin(eps) * sin(lam))
	var ra := atan2(cos(eps) * sin(lam), cos(lam))
	var gmst := fmod(18.697374558 + 24.06570982441908 * n, 24.0)
	var lst := deg_to_rad(fmod(gmst * 15.0 + lon, 360.0))
	var ha := lst - ra
	var latr := deg_to_rad(lat)
	var alt := asin(sin(latr) * sin(decl) + cos(latr) * cos(decl) * cos(ha))
	var az := atan2(-sin(ha), tan(decl) * cos(latr) - sin(latr) * cos(ha))   # от севера по часовой
	return Vector2(rad_to_deg(alt), fmod(rad_to_deg(az) + 360.0, 360.0))


func _apply_ephemeris(base_e: float, announce: bool = false) -> void:
	var lat := float(main.meta.get("center_lat", 48.16))
	var lon := float(main.meta.get("center_lon", 24.5))
	var sp := sun_position(lat, lon, _date[0], _date[1], _date[2], _time_h, 3.0)
	var alt := sp.x; var az := sp.y
	# Godot: DirectionalLight светит по -Z; rotation.x = -alt (вниз), rotation.y = поворот к азимуту (север = -Z мира)
	sun.rotation_degrees = Vector3(-maxf(alt, -2.0), 180.0 - az, 0.0)
	var k := clampf(alt / 25.0, 0.0, 1.0)              # низкое солнце — теплее и слабее
	sun.light_color = Color(1.0, 0.6 + 0.38 * k, 0.3 + 0.6 * k)
	if alt < 0.0:
		sun.light_energy = 0.05
	else:
		sun.light_energy = base_e * clampf(0.25 + 0.75 * sin(deg_to_rad(minf(alt, 90.0))) * 1.2, 0.2, 1.3)
	sky.set_shader_parameter("sun_color", sun.light_color)
	if announce:
		label += "  %02d:%02d солнце %d°" % [int(_time_h), int(fmod(_time_h, 1.0) * 60.0), int(alt)]
		print("Солнце по эфемеридам: %s %.1f ч → высота %.1f°, азимут %.0f°" % [_date, _time_h, alt, az])


# --- пер-кадровое солнце: дрейф по небу, облако над камерой, непрерывные тени ---
var _occ := 0.0              # 0..1 — насколько кучевое облако сейчас закрывает солнце
var _sun_drift := 0.0        # накопленный ход солнца по азимуту, °
var _timescale := 1.0        # --timescale=N: ускорение хода солнца (1 = реальное время)
var _ephem_announce := false
var _noshadows := false      # --noshadows: диагностика цены теневого прохода


## Насколько облако закрывает солнце над камерой (0..1) — по той же карте и смещению,
## что пятна cloud_shadow на земле: пятно наехало на камеру → прямое солнце гаснет.
func _cloud_occlusion() -> float:
	if main == null or main.cam == null:
		return 0.0
	var img: Image = main.get("cloud_shadow_img")
	if img == null:
		return 0.0
	var p: Vector3 = main.cam.global_position
	var uv := Vector2(p.x, p.z) * 0.0004 + _cloud_off
	var n := img.get_pixel(posmod(int(uv.x * 512.0), 512), posmod(int(uv.y * 512.0), 512)).r
	return smoothstep(0.50, 0.72, n) * clampf(_cloud_strength / 0.45, 0.0, 1.0)


## Каждый кадр: положение солнца (эфемериды или пресет + реальный дрейф ~0.25°/мин),
## затенение облаком (тени плавно тают и возвращаются, ~4 с), плотность и мягкость теней.
func _update_sun(dt: float) -> void:
	var c := _cur_cont
	if c.is_empty():
		return
	_occ = move_toward(_occ, _cloud_occlusion(), dt / 4.0)
	var base_e: float = float(c.se) * (1.0 - 0.45 * _occ)
	if _sun_by_time:
		_time_h += dt * _timescale / 3600.0
		_apply_ephemeris(base_e, _ephem_announce)
		_ephem_announce = false
	else:
		_sun_drift += dt * _timescale * 0.25 / 60.0
		sun.rotation_degrees = (c.srot as Vector3) + Vector3(0, -_sun_drift, 0)
		sun.light_energy = base_e
	var shop: float = float(c.get("shop", 0.9)) * (1.0 - 0.85 * _occ)
	sun.shadow_opacity = shop
	sun.light_angular_distance = float(c.get("sang", 0.53))
	sun.shadow_enabled = int(main.get("quality")) != 0 and shop > 0.02 and not _noshadows
	sky.set_shader_parameter("sun_dir", -sun.global_transform.basis.z)

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var kc: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		match kc:
			KEY_1: apply(0)
			KEY_2: apply(1)
			KEY_3: apply(2)
			KEY_4: apply(3)
			KEY_5: apply(4)
			KEY_8: apply(5)
			KEY_6: _fog_extra = not _fog_extra; apply(idx)     # туман вкл/выкл
			KEY_7: _rain_extra = not _rain_extra; apply(idx)   # дождь вкл/выкл
			KEY_P: apply(idx + 1)


func _process(dt: float) -> void:
	# движение теней облаков по ветру (uv-смещение; масштаб 1/2500 м на текстуру)
	_cloud_off += Vector2(wind.x, wind.z) * dt * 0.0004 * 1.5
	RenderingServer.global_shader_parameter_set("cloud_shadow_params",
		Vector4(_cloud_off.x, _cloud_off.y, _cloud_strength, 0.0004))
	_t += dt
	var wet_tgt := 1.0 if raining() else 0.0
	wetness = move_toward(wetness, wet_tgt, dt / (45.0 if raining() else 240.0))
	if absf(wetness - _wet_applied) > 0.02:
		_wet_applied = wetness
		_push_wetness()
	if _trans < 1.0:
		_trans = minf(1.0, _trans + dt / TRANS_SEC)
		var tt := smoothstep(0.0, 1.0, _trans)
		_apply_cont(_mix_cont(_trans_from, _trans_to, tt))
	_update_sun(dt)
	if main != null and main.cam != null:
		var cp: Vector3 = main.cam.global_position
		_rain_holder.global_position = cp
		# наклон дождя по ветру: штрихи летят вдоль реальной траектории капель
		var wv := wind_vec()
		var wh := Vector2(wv.x, wv.z)
		var tilt := atan(wh.length() * 0.55 / 15.0)
		var axis := Vector3(wh.y, 0, -wh.x).normalized() if wh.length() > 0.5 else Vector3.RIGHT
		var tgt_b := Basis(axis, tilt) if wh.length() > 0.5 else Basis()
		_rain_holder.global_transform.basis = _rain_holder.global_transform.basis.slerp(tgt_b, clampf(dt * 2.0, 0.0, 1.0))
		# брызги — на земле под камерой, видны только на малой высоте
		var gy: float = main.height_at(cp.x, cp.z)
		_splash.global_position = Vector3(cp.x, gy + 0.12, cp.z)
		_splash.visible = (cp.y - gy) < 50.0
	# порывы ветра гуляют по направлению и силе
	# молнии — только при включённом дожде (7)
	if _rain_extra:
		_flash = maxf(0.0, _flash - dt * 3.5)
		if randf() < dt * 0.09:
			_flash = 1.0
			if main.get("sound") != null:
				main.sound.thunder()
		env.adjustment_brightness = float(_cur_cont.get("br", 1.0)) + _flash * 0.9
		env.background_energy_multiplier = 1.0 + _flash * 2.0


## Мокрая земля/дороги: террейну — uniform, дорогам — roughness/albedo напрямую.
func _push_wetness() -> void:
	if main == null:
		return
	var tm = main.get("terrain_mat")
	if tm != null:
		tm.set_shader_parameter("wetness", wetness)
	var rn := main.get_node_or_null("Roads")
	if rn != null:
		for mi in rn.get_children():
			if mi is MeshInstance3D and mi.mesh != null and mi.mesh.get_surface_count() > 0:
				var m: Material = mi.mesh.surface_get_material(0)
				if m is StandardMaterial3D:
					m.roughness = lerpf(0.82, 0.18, wetness)
					var base := 0.78 if mi.name == "Asphalt" else 0.9
					var g := base * (1.0 - 0.3 * wetness)
					m.albedo_color = Color(g, g, g * 1.02)


## Текущий вектор ветра с порывами (для дрона и HUD).
func wind_vec() -> Vector3:
	var gust := 1.0 + 0.35 * sin(_t * 0.7) + 0.15 * sin(_t * 2.1)
	return wind * gust
