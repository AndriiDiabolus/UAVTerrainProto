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

# Пресеты: имя, поворот солнца(°), энергия/цвет солнца, ambient, цвета неба, туман, тон, дождь(0/1), ветер(м/с), направление(°)
const PRESETS := [
	{"name": "☀ Ясный день", "srot": Vector3(-52, -120, 0), "se": 1.35, "sc": Color(1.0, 0.97, 0.9),
	 "amb": Color(0.52, 0.6, 0.72), "ae": 0.35, "top": Color(0.22, 0.43, 0.75), "hor": Color(0.72, 0.81, 0.9),
	 "gnd": Color(0.55, 0.62, 0.7), "fog": 0.0000012, "fogc": Color(0.78, 0.84, 0.92),
	 "br": 1.25, "sat": 1.15, "rain": 0.0, "lit": 0.02, "cov": 0.32, "ccol": Color(1,1,1), "cdark": Color(0.62,0.66,0.72), "wind": 3.0, "wdir": 40.0},

	{"name": "☁ Облачно, ветер", "srot": Vector3(-58, -100, 0), "se": 0.5, "sc": Color(0.85, 0.87, 0.9),
	 "amb": Color(0.55, 0.58, 0.62), "ae": 0.5, "top": Color(0.55, 0.6, 0.66), "hor": Color(0.7, 0.72, 0.75),
	 "gnd": Color(0.6, 0.62, 0.65), "fog": 0.000006, "fogc": Color(0.72, 0.74, 0.77),
	 "br": 1.05, "sat": 0.85, "rain": 0.0, "lit": 0.05, "cov": 0.74, "ccol": Color(0.86,0.87,0.9), "cdark": Color(0.5,0.52,0.56), "wind": 12.0, "wdir": 200.0},

	{"name": "🌧 Дождь, шторм", "srot": Vector3(-62, -90, 0), "se": 0.32, "sc": Color(0.7, 0.72, 0.76),
	 "amb": Color(0.4, 0.42, 0.46), "ae": 0.45, "top": Color(0.38, 0.4, 0.44), "hor": Color(0.5, 0.51, 0.54),
	 "gnd": Color(0.44, 0.45, 0.48), "fog": 0.000016, "fogc": Color(0.55, 0.57, 0.6),
	 "br": 0.92, "sat": 0.7, "rain": 0.0, "lit": 0.12, "fh": 1150, "fhd": 0.0, "cov": 0.92, "ccol": Color(0.6,0.62,0.66), "cdark": Color(0.3,0.32,0.36), "wind": 10.0, "wdir": 220.0},

	{"name": "🌇 Закат", "srot": Vector3(-8, -95, 0), "se": 1.4, "sc": Color(1.0, 0.62, 0.32),
	 "amb": Color(0.5, 0.4, 0.42), "ae": 0.3, "top": Color(0.28, 0.3, 0.55), "hor": Color(0.95, 0.55, 0.32),
	 "gnd": Color(0.5, 0.42, 0.42), "fog": 0.000004, "fogc": Color(0.85, 0.55, 0.4),
	 "br": 1.2, "sat": 1.3, "rain": 0.0, "lit": 0.28, "fh": 940, "fhd": 0.0, "cov": 0.48, "ccol": Color(1.0,0.82,0.66), "cdark": Color(0.62,0.44,0.5), "wind": 2.5, "wdir": 300.0},

	{"name": "🌙 Ночь", "srot": Vector3(-42, -60, 0), "se": 0.14, "sc": Color(0.6, 0.68, 0.9),
	 "amb": Color(0.12, 0.15, 0.24), "ae": 0.4, "top": Color(0.03, 0.04, 0.1), "hor": Color(0.09, 0.11, 0.2),
	 "gnd": Color(0.06, 0.07, 0.12), "fog": 0.000009, "fogc": Color(0.1, 0.12, 0.2),
	 "br": 0.95, "sat": 0.8, "rain": 0.0, "lit": 0.6, "fh": 900, "fhd": 0.0, "cov": 0.5, "ccol": Color(0.32,0.35,0.44), "cdark": Color(0.1,0.12,0.18), "wind": 5.0, "wdir": 120.0},
]


func setup(m: Node3D, s: DirectionalLight3D, e: Environment, sk: ShaderMaterial) -> void:
	main = m
	sun = s
	env = e
	sky = sk
	_build_rain()
	var start := 0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--weather="):
			start = clampi(int(a.substr(10)), 0, PRESETS.size() - 1)
	apply(start)


func _build_rain() -> void:
	_rain_holder = Node3D.new()
	add_child(_rain_holder)
	_rain = GPUParticles3D.new()
	_rain.amount = 2400
	_rain.lifetime = 1.7
	_rain.local_coords = false
	_rain.visibility_aabb = AABB(Vector3(-90, -90, -90), Vector3(180, 180, 180))
	_rain.position = Vector3(0, 34, 0)
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	pm.emission_box_extents = Vector3(60, 1, 60)
	pm.direction = Vector3(0, -1, 0)
	pm.spread = 0.0
	pm.initial_velocity_min = 16.0
	pm.initial_velocity_max = 20.0
	pm.gravity = Vector3(0, -12, 0)
	_rain.process_material = pm
	var streak := BoxMesh.new()
	streak.size = Vector3(0.035, 0.55, 0.035)
	var rmat := StandardMaterial3D.new()
	rmat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	rmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	rmat.albedo_color = Color(0.72, 0.78, 0.88, 0.4)
	streak.material = rmat
	_rain.draw_pass_1 = streak
	_rain.emitting = false
	_rain_holder.add_child(_rain)


func apply(i: int) -> void:
	idx = (i + PRESETS.size()) % PRESETS.size()
	var p: Dictionary = PRESETS[idx]
	label = p.name
	sun.rotation_degrees = p.srot
	sun.light_energy = p.se
	sun.light_color = p.sc
	sun.shadow_enabled = p.se > 0.25
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = p.amb
	env.ambient_light_energy = p.ae
	sky.set_shader_parameter("top_color", p.top)
	sky.set_shader_parameter("horizon_color", p.hor)
	sky.set_shader_parameter("ground_color", p.gnd)
	sky.set_shader_parameter("sun_color", p.sc)
	sky.set_shader_parameter("sun_dir", -sun.global_transform.basis.z)
	sky.set_shader_parameter("coverage", p.get("cov", 0.4))
	sky.set_shader_parameter("cloud_color", p.get("ccol", Color(1, 1, 1)))
	sky.set_shader_parameter("cloud_dark", p.get("cdark", Color(0.55, 0.58, 0.62)))
	sky.set_shader_parameter("night", 1.0 if idx == 4 else 0.0)
	var wa := deg_to_rad(p.wdir)
	sky.set_shader_parameter("wind_dir", Vector2(cos(wa), sin(wa)))
	env.fog_density = p.fog
	env.fog_light_color = p.fogc
	env.fog_height = p.get("fh", 0.0)
	env.fog_height_density = p.get("fhd", 0.0)
	# под ACES-тонмаппинг: пресеты писались под FILMIC с br 1.25 — приводим к естественному
	env.adjustment_brightness = 0.92 + (float(p.br) - 1.0) * 0.5
	env.adjustment_saturation = 1.0 + (float(p.sat) - 1.0) * 0.6
	sun.light_energy = float(p.se) * 1.35
	env.ambient_light_energy = float(p.ae) * 1.1
	if idx == 4:                                   # ночь: под ACES темнее, чем задумано — компенсируем
		env.ambient_light_energy *= 3.2
		env.adjustment_brightness += 0.22
		sun.light_energy *= 2.6                    # «луна» — иначе рельеф не читается вовсе
		env.glow_intensity = 0.6
	else:
		env.glow_intensity = 0.35
	# объёмная дымка гуще в пасмурную/дождливую погоду
	env.volumetric_fog_density = 0.00006 + float(p.fog) * 12.0
	env.background_energy_multiplier = 1.0
	wind_speed = p.wind
	var a := deg_to_rad(p.wdir)
	wind = Vector3(cos(a), 0, sin(a)) * wind_speed
	if main != null and main.has_method("set_window_light"):
		main.set_window_light(p.get("lit", 0.03))
	# ручные тумблеры (6/7) поверх любого пресета
	if _fog_extra:
		env.fog_height = 940.0
		env.fog_height_density = 0.006
	_rain.emitting = (p.rain > 0.0) or _rain_extra
	var pm := _rain.process_material as ParticleProcessMaterial
	pm.gravity = Vector3(wind.x * 0.7, -12.0, wind.z * 0.7)


var _fog_extra := false
var _rain_extra := false

func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		match event.keycode:
			KEY_1: apply(0)
			KEY_2: apply(1)
			KEY_3: apply(2)
			KEY_4: apply(3)
			KEY_5: apply(4)
			KEY_6: _fog_extra = not _fog_extra; apply(idx)     # туман вкл/выкл
			KEY_7: _rain_extra = not _rain_extra; apply(idx)   # дождь вкл/выкл
			KEY_P: apply(idx + 1)


func _process(dt: float) -> void:
	_t += dt
	if main != null and main.cam != null:
		_rain_holder.global_position = main.cam.global_position
	# порывы ветра гуляют по направлению и силе
	# молнии — только при включённом дожде (7)
	if _rain_extra:
		_flash = maxf(0.0, _flash - dt * 3.5)
		if randf() < dt * 0.09:
			_flash = 1.0
		env.adjustment_brightness = 0.92 + (float(PRESETS[idx].br) - 1.0) * 0.5 + _flash * 0.9
		env.background_energy_multiplier = 1.0 + _flash * 2.0


## Текущий вектор ветра с порывами (для дрона и HUD).
func wind_vec() -> Vector3:
	var gust := 1.0 + 0.35 * sin(_t * 0.7) + 0.15 * sin(_t * 2.1)
	return wind * gust
