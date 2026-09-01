extends Camera3D
## Дрон: лётная модель + управление с пульта/геймпада/клавиатуры.
##
## Режимы (Tab / кнопка Y на геймпаде / --mode=gps|angle|acro):
##   GPS   — «как Mavic»: стики задают скорость, отпустил — завис, высота держится. Камера — подвес (мышь).
##   ANGLE — самовыравнивание: стик = угол наклона, газ прямой (без удержания высоты). Камера жёстко на борту.
##   ACRO  — стик = угловая скорость, никакого выравнивания. Так учат в FPV-школах.
##
## Пульт (mode 2, любой USB-джойстик / RC-передатчик в режиме джойстика):
##   левый стик: газ (вверх/вниз) + рыскание; правый: тангаж + крен.
##   Оси/инверсия перенастраиваются флагами --axes=T,Y,P,R  --invert=TYPR (буквы осей для инверсии).
##   --joydebug печатает сырые оси, чтобы найти раскладку своего пульта.
## Клавиатура: W/S тангаж, A/D крен (в GPS — движение), E/Q газ, ←/→ (или мышь) рыскание, Shift буст (GPS).
## Профиль дрона: B / --drone=fpv7|fpv5|mavic.

var main: Node3D
var current_speed := 45.0            # GPS: предел скорости (колесо), м/с
var mouse_captured := false
var velocity := Vector3.ZERO         # мировая скорость, м/с
var throttle := 0.0                  # доля тяги 0..1 (звук/OSD/батарея)
var body: Basis = Basis.IDENTITY     # ориентация корпуса (в GPS — визуальная)
var mode := MODE_GPS
var drone_id := "fpv7"
var landed := false
var joy_name := ""                   # имя подключённого пульта ("" = клавиатура)

# стики после обработки (для индикатора на HUD): -1..1, газ 0..1
var st_pitch := 0.0
var st_roll := 0.0
var st_yaw := 0.0
var st_thr := 0.0

enum { MODE_GPS, MODE_ANGLE, MODE_ACRO }
const MODE_NAMES := ["GPS · удержание", "ANGLE · стабилизация", "ACRO"]

const G := 9.81
const SPEED_MIN := 8.0
const SPEED_MAX := 1500.0
const MOUSE_SENS := 0.0022
const ACCEL := 65.0                  # GPS: отзывчивость, м/с²
const DRAG_GPS := 2.3                # GPS: выбег
const BOOST := 3.5
const CLIMB_MAX := 28.0              # GPS: предел вертикали, м/с
const DEADZONE := 0.06
const CLEARANCE := 0.35              # высота «ног» над землёй, м

## Профили: масса, тяговооружённость, drag (F=-c·v|v|), макс. наклон (ANGLE), макс. угловые скорости,
## отклик по угл. скорости (сек), экспонента стиков, наклон камеры (FPV), предел GPS-скорости.
const DRONES := {
	"fpv7":  {"name": "FPV 7\" ударный", "mass": 1.15, "tw": 3.2, "drag": 0.016, "tilt": 55.0,
		"rate": 560.0, "yaw_rate": 360.0, "tau": 0.06, "expo": 0.45, "cam_tilt": 25.0, "gps_v": 26.0},
	"fpv5":  {"name": "FPV 5\" гоночный", "mass": 0.68, "tw": 5.5, "drag": 0.011, "tilt": 60.0,
		"rate": 800.0, "yaw_rate": 480.0, "tau": 0.045, "expo": 0.5, "cam_tilt": 32.0, "gps_v": 30.0},
	"mavic": {"name": "квадрокоптер (класс Mavic)", "mass": 0.9, "tw": 2.0, "drag": 0.022, "tilt": 35.0,
		"rate": 200.0, "yaw_rate": 120.0, "tau": 0.12, "expo": 0.2, "cam_tilt": 0.0, "gps_v": 20.0},
}
var P: Dictionary = DRONES["fpv7"]

# --- внутреннее ---
var _yaw := 0.0                      # GPS: курс подвеса/корпуса
var _pitch := 0.0                    # GPS: тангаж подвеса (мышь)
var _omega := Vector3.ZERO           # угловая скорость корпуса, рад/с (body frame)
var _t := 0.0
var _kb := Vector4.ZERO              # сглаженные клавиатурные стики (p, r, y, thr)
var _mouse_acc := Vector2.ZERO       # накопленная мышь за кадр (ANGLE/ACRO → стик)
var _turb: Array[FastNoiseLite] = []
var _axes := [1, 0, 3, 2]            # индексы осей джойстика: T, Y, P, R (mode 2)
var _inv := [true, false, true, false]  # инверсия осей: стик вверх у Godot = -1 → газ/тангаж инвертируем
var _joydebug := false
var _novibe := false


func _ready() -> void:
	_yaw = rotation.y
	_pitch = rotation.x
	body = Basis.from_euler(Vector3(0.0, _yaw, 0.0))
	_setup_actions()
	_parse_flags()
	for i in 3:
		var n := FastNoiseLite.new()
		n.seed = 100 + i
		n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
		n.frequency = 1.0
		_turb.append(n)
	Input.joy_connection_changed.connect(func(_id: int, _c: bool) -> void: _refresh_joy())
	_refresh_joy()


func _refresh_joy() -> void:
	var pads := Input.get_connected_joypads()
	joy_name = Input.get_joy_name(pads[0]) if not pads.is_empty() else ""
	if joy_name != "":
		print("Пульт: '%s' (оси T,Y,P,R = %s, инверсия %s)" % [joy_name, _axes, _inv])


## Действия InputMap создаются в рантайме (project.godot остаётся чистым); если пользователь
## переопределил их в проекте — не трогаем.
func _setup_actions() -> void:
	var defs := {
		"fly_pitch_fwd": [KEY_W], "fly_pitch_back": [KEY_S],
		"fly_roll_left": [KEY_A], "fly_roll_right": [KEY_D],
		"fly_thr_up": [KEY_E], "fly_thr_down": [KEY_Q],
		"fly_yaw_left": [KEY_LEFT], "fly_yaw_right": [KEY_RIGHT],
		"fly_boost": [KEY_SHIFT],
		"fly_mode": [KEY_TAB], "fly_drone": [KEY_B],
	}
	for a: String in defs:
		if InputMap.has_action(a):
			continue
		InputMap.add_action(a)
		for k: int in defs[a]:
			var ev := InputEventKey.new()
			ev.physical_keycode = k
			InputMap.action_add_event(a, ev)
	# кнопки геймпада: Y — режим, X — профиль дрона, RB — буст
	for pair: Array in [["fly_mode", JOY_BUTTON_Y], ["fly_drone", JOY_BUTTON_X], ["fly_boost", JOY_BUTTON_RIGHT_SHOULDER]]:
		var jb := InputEventJoypadButton.new()
		jb.button_index = pair[1]
		InputMap.action_add_event(pair[0], jb)


func _parse_flags() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mode="):
			var m := a.substr(7).to_lower()
			mode = {"gps": MODE_GPS, "angle": MODE_ANGLE, "acro": MODE_ACRO}.get(m, MODE_GPS)
		elif a.begins_with("--drone="):
			set_drone(a.substr(8).to_lower())
		elif a.begins_with("--axes="):
			var parts := a.substr(7).split(",")
			if parts.size() == 4:
				for i in 4: _axes[i] = int(parts[i])
		elif a.begins_with("--invert="):
			var s := a.substr(9).to_upper()
			_inv = ["T" in s, "Y" in s, "P" in s, "R" in s]
		elif a == "--joydebug":
			_joydebug = true
		elif a == "--novibe":
			_novibe = true


func set_drone(id: String) -> void:
	if DRONES.has(id):
		drone_id = id
		P = DRONES[id]


func cycle_mode() -> void:
	mode = (mode + 1) % 3
	if main != null and main.hud != null and main.hud.has_method("toast"):
		var tips := ["W/S вперёд-назад · A/D вбок · E/Q вверх-вниз · мышь — камера",
			"W/S наклон · A/D крен · E/Q газ · мышь/←→ рыскание · выравнивается сам",
			"стики = угловая скорость · E/Q газ · выравнивания нет"]
		main.hud.toast("РЕЖИМ · " + MODE_NAMES[mode], tips[mode], Color(0.9, 0.9, 0.9))
	if mode == MODE_GPS:
		# при возврате в GPS подвес выравнивается по текущему курсу
		var e := body.get_euler()
		_yaw = e.y
		_pitch = 0.0
	_omega = Vector3.ZERO


func cycle_drone() -> void:
	var keys := DRONES.keys()
	set_drone(keys[(keys.find(drone_id) + 1) % keys.size()])
	if main != null and main.hud != null and main.hud.has_method("toast"):
		main.hud.toast("ДРОН · " + drone_name(), "масса %.2f кг · T/W %.1f · до %d°/с" % [float(P["mass"]), float(P["tw"]), int(P["rate"])], Color(0.9, 0.9, 0.9))


func mode_name() -> String:
	return MODE_NAMES[mode]


func drone_name() -> String:
	return str(P["name"])


## Ориентация корпуса (для авиагоризонта OSD и HUD).
func attitude() -> Basis:
	return body


func speed() -> float:
	return velocity.length()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed:
		match event.button_index:
			MOUSE_BUTTON_LEFT:
				if not mouse_captured:
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
					mouse_captured = true
				elif main != null and main.targets != null:
					if main.targets.weapon == 3:
						if main.get("airtargets") != null:
							main.airtargets.shoot(self)
					else:
						main.targets.fire(self)
			MOUSE_BUTTON_WHEEL_UP:
				current_speed = clampf(current_speed * 1.15, SPEED_MIN, SPEED_MAX)
			MOUSE_BUTTON_WHEEL_DOWN:
				current_speed = clampf(current_speed / 1.15, SPEED_MIN, SPEED_MAX)
	elif event is InputEventMouseMotion and mouse_captured:
		if mode == MODE_GPS:
			_yaw -= event.relative.x * MOUSE_SENS
			_pitch = clampf(_pitch - event.relative.y * MOUSE_SENS, -1.5, 1.5)
		else:
			_mouse_acc += event.relative
	elif event.is_action_pressed("fly_mode"):
		cycle_mode()
	elif event.is_action_pressed("fly_drone"):
		cycle_drone()
	elif event.is_action_pressed("ui_cancel"):
		if mouse_captured:
			Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
			mouse_captured = false
		elif main != null and main.menu != null:
			main.menu.set_open(true)          # выход из игры — из меню


# ============================ ввод ============================

func _dz(v: float) -> float:
	if absf(v) < DEADZONE:
		return 0.0
	return signf(v) * (absf(v) - DEADZONE) / (1.0 - DEADZONE)


func _expo(v: float, e: float) -> float:
	return v * (1.0 - e) + v * v * v * e


## Считывает стики: pitch/roll/yaw в -1..1 (+ = вперёд/вправо/вправо), thr 0..1 (газ),
## thr_c -1..1 (газ вокруг центра — для GPS и клавиатуры).
func _read_sticks(dt: float) -> Dictionary:
	var pads := Input.get_connected_joypads()
	var kb_p := Input.get_action_strength("fly_pitch_fwd") - Input.get_action_strength("fly_pitch_back")
	var kb_r := Input.get_action_strength("fly_roll_right") - Input.get_action_strength("fly_roll_left")
	var kb_y := Input.get_action_strength("fly_yaw_right") - Input.get_action_strength("fly_yaw_left")
	var kb_t := Input.get_action_strength("fly_thr_up") - Input.get_action_strength("fly_thr_down")
	# мышь в ANGLE/ACRO — эмуляция правого стика (X → рыскание, Y → тангаж), сама возвращается в центр
	if mode != MODE_GPS and mouse_captured:
		kb_y += clampf(_mouse_acc.x * 0.02, -1.0, 1.0)
		kb_p += clampf(-_mouse_acc.y * 0.02, -1.0, 1.0)
	_mouse_acc = Vector2.ZERO
	# клавиши — цифровые: сглаживаем, чтобы стик не «бил» (0→1 за ~0.12 с)
	var k := clampf(dt / 0.12, 0.0, 1.0)
	_kb.x = lerpf(_kb.x, clampf(kb_p, -1.0, 1.0), k)
	_kb.y = lerpf(_kb.y, clampf(kb_r, -1.0, 1.0), k)
	_kb.z = lerpf(_kb.z, clampf(kb_y, -1.0, 1.0), k)
	_kb.w = lerpf(_kb.w, clampf(kb_t, -1.0, 1.0), k)

	var out := {"p": _kb.x, "r": _kb.y, "y": _kb.z, "thr_c": _kb.w, "thr": -1.0, "joy": false}
	link_q = 1.0
	if main != null and main.get("_fpv_osd") != null and main._fpv_osd != null:
		link_q = float(main._fpv_osd.signal_q)
	if not pads.is_empty():
		var id: int = pads[0]
		var raw := []
		for i in 4:
			var v := Input.get_joy_axis(id, _axes[i])
			raw.append(-v if _inv[i] else v)
		if _joydebug:
			var all := []
			for ax in 6: all.append("%.2f" % Input.get_joy_axis(id, ax))
			print("JOY axes: ", all, "  → T=%.2f Y=%.2f P=%.2f R=%.2f" % [raw[0], raw[1], raw[2], raw[3]])
		var jt := _dz(raw[0]); var jy := _dz(raw[1]); var jp := _dz(raw[2]); var jr := _dz(raw[3])
		# джойстик перекрывает клавиатуру, если стик отклонён
		if absf(jp) > 0.0 or absf(jr) > 0.0 or absf(jy) > 0.0 or absf(jt) > 0.0:
			out.joy = true
			out.p = jp; out.r = jr; out.y = jy
			out.thr_c = jt                    # центр стика = 0
			out.thr = clampf((jt + 1.0) * 0.5, 0.0, 1.0)   # низ = 0, верх = 1
	_degrade_link(out)
	return out


var link_q := 1.0                    # качество канала управления (RSSI с OSD): 1 — чисто
var failsafe := false

## Деградация управления при слабом канале (РЭБ / за рельефом / дальность):
## ниже 0.5 — стики ослабевают и шумят, ниже 0.1 — failsafe (стики в ноль: GPS висит, ANGLE ровняется).
func _degrade_link(out: Dictionary) -> void:
	failsafe = link_q < 0.1
	if link_q >= 0.5:
		return
	var k := clampf((link_q - 0.1) / 0.4, 0.0, 1.0)
	var nz := (1.0 - k) * 0.12
	out.p = float(out.p) * k + _turb[0].get_noise_1d(_t * 6.0) * nz
	out.r = float(out.r) * k + _turb[1].get_noise_1d(_t * 5.0) * nz
	out.y = float(out.y) * k
	out.thr_c = float(out.thr_c) * k
	if float(out.thr) >= 0.0:
		var hover := clampf(1.0 / float(P["tw"]), 0.0, 1.0)
		out.thr = lerpf(hover, float(out.thr), k)


# ============================ физика ============================

const H := 1.0 / 240.0               # фиксированный шаг интегрирования, с
var _acc := 0.0

## Сброс состояния (рестарт после краша / телепорт).
func reset() -> void:
	velocity = Vector3.ZERO
	_omega = Vector3.ZERO
	landed = false
	_acc = 0.0
	body = Basis.from_euler(Vector3(0.0, _yaw, 0.0))
	_pitch = 0.0


func _process(dt: float) -> void:
	if main == null or main.get("replaying") == true or main.get("menu_open") == true:
		return
	dt = minf(dt, 0.1)
	_t += dt

	# после краша дрон падает и лежит, управление отключено (R — перезапуск)
	if main.crashed:
		velocity.y -= G * dt
		velocity.x *= 0.9; velocity.z *= 0.9
		position += velocity * dt
		var gc: float = main.height_at(position.x, position.z)
		if position.y < gc + CLEARANCE:
			position.y = gc + CLEARANCE
			velocity = Vector3.ZERO
		body = body.slerp(Basis.from_euler(Vector3(0.0, body.get_euler().y, 1.2)), clampf(dt * 2.0, 0.0, 1.0))
		global_transform.basis = body
		throttle = 0.0
		return

	var s := _read_sticks(dt)
	st_pitch = s.p; st_roll = s.r; st_yaw = s.y
	var wind := Vector3.ZERO
	if main.get("weather") != null:
		wind = main.weather.wind_vec()

	# фиксированный шаг — устойчивые контуры угловых скоростей и повторяемость
	_acc += dt
	while _acc >= H:
		_acc -= H
		if mode == MODE_GPS:
			_step_gps(H, s, wind)
		else:
			_step_physical(H, s, wind)
		_ground_and_obstacles(H)
		if main.crashed:
			return
	_apply_camera(dt, wind)


## GPS-режим: команда скорости + удержание высоты (упрощённая, «как у потребительского дрона»).
func _step_gps(dt: float, s: Dictionary, wind: Vector3) -> void:
	var boost := BOOST if Input.is_action_pressed("fly_boost") else 1.0
	var ctl := Basis.from_euler(Vector3(0.0, _yaw, 0.0))
	# рыскание со стика (мышь тоже крутит _yaw напрямую)
	_yaw -= float(s.y) * deg_to_rad(float(P["yaw_rate"])) * 0.5 * dt
	var wish: Vector3 = -ctl.z * float(s.p) + ctl.x * float(s.r)
	wish.y = 0.0
	var vmax := minf(current_speed, float(P["gps_v"])) * boost if s.joy else current_speed * boost
	if wish.length_squared() > 0.0:
		velocity += wish.limit_length(1.0) * ACCEL * boost * dt
	var vh := Vector3(velocity.x, 0, velocity.z)
	vh -= vh * DRAG_GPS * dt
	vh = vh.limit_length(vmax)
	velocity.x = vh.x; velocity.z = vh.z
	# вертикаль: стик = вертикальная скорость, отпустил — держим высоту
	var vz_cmd: float = float(s.thr_c) * CLIMB_MAX
	velocity.y = lerpf(velocity.y, vz_cmd, clampf(dt * 4.0, 0.0, 1.0))
	# ветер: GPS держит позицию, но не идеально — часть сноса + буфтинг
	velocity += wind * dt * 0.35
	velocity += _turbulence(wind) * dt
	st_thr = clampf(0.5 + float(s.thr_c) * 0.5, 0.0, 1.0)
	throttle = clampf(0.3 + vh.length() / maxf(vmax, 1.0) * 0.5 + maxf(0.0, float(s.thr_c)) * 0.2, 0.0, 1.0)
	position += velocity * dt
	# корпус (визуально): наклон по ускорению, курс = _yaw
	var acc: Vector3 = wish * ACCEL * boost - vh * DRAG_GPS
	var tilt_p := clampf(-(ctl.inverse() * acc).z / G, -0.5, 0.5)     # вперёд → нос вниз
	var tilt_r := clampf(-(ctl.inverse() * acc).x / G, -0.5, 0.5)
	body = body.slerp(Basis.from_euler(Vector3(-tilt_p * 0.6, _yaw, tilt_r * 0.6)), clampf(dt * 4.0, 0.0, 1.0))


## ANGLE / ACRO: полноценная динамика: тяга по оси корпуса, гравитация, аэродинамическое
## сопротивление относительно воздуха (ветер!), угловые скорости с откликом моторов.
func _step_physical(dt: float, s: Dictionary, wind: Vector3) -> void:
	var m: float = P["mass"]
	var t_max: float = P["tw"] * m * G
	var hover := clampf(m * G / t_max, 0.0, 1.0)
	var expo: float = P["expo"]

	# --- газ ---
	if s.thr >= 0.0:
		st_thr = s.thr                                   # джойстик: сырой стик
	else:
		# клавиатура: без клавиш — висим (с компенсацией наклона), E → полный, Q → ноль
		var c: float = s.thr_c
		var hov := clampf(hover / clampf(body.y.y, 0.5, 1.0), 0.0, 1.0)
		st_thr = hov + (c * (1.0 - hov) if c > 0.0 else c * hov)
	if landed and st_thr < hover * 0.9:
		st_thr = minf(st_thr, hover * 0.5)
	throttle = st_thr
	var thrust := t_max * st_thr

	# --- желаемые угловые скорости (body frame): x — тангаж, y — рыскание, z — крен ---
	var rate := deg_to_rad(P["rate"])
	var yaw_rate := deg_to_rad(P["yaw_rate"])
	var w_d := Vector3.ZERO
	if mode == MODE_ACRO:
		w_d.x = -_expo(s.p, expo) * rate
		w_d.z = -_expo(s.r, expo) * rate
		w_d.y = -_expo(s.y, expo) * yaw_rate
	else:
		var e := body.get_euler()                        # (pitch, yaw, roll), порядок YXZ
		var tilt := deg_to_rad(P["tilt"])
		var p_d := -_expo(s.p, expo * 0.5) * tilt
		var r_d := -_expo(s.r, expo * 0.5) * tilt
		var kp := 6.0
		w_d.x = clampf((p_d - e.x) * kp, -rate, rate)
		w_d.z = clampf((r_d - e.z) * kp, -rate, rate)
		w_d.y = -_expo(s.y, expo) * yaw_rate
	# буфтинг ветром — небольшие возмущения по крену/тангажу
	var wf := wind.length()
	w_d.x += _turb[0].get_noise_1d(_t * 1.7) * wf * 0.03
	w_d.z += _turb[1].get_noise_1d(_t * 1.9) * wf * 0.03
	# отклик моторов: первый порядок с постоянной времени tau
	_omega = _omega.lerp(w_d, clampf(dt / float(P["tau"]), 0.0, 1.0))
	if landed:
		_omega = _omega.lerp(Vector3.ZERO, clampf(dt * 8.0, 0.0, 1.0))
	# интегрируем ориентацию (вращение в системе корпуса)
	var ang := _omega.length() * dt
	if ang > 1e-6:
		body = body * Basis(_omega.normalized(), ang)
	body = body.orthonormalized()
	if landed:
		# на земле корпус выравнивается по поверхности
		var lvl := Basis.from_euler(Vector3(0.0, body.get_euler().y, 0.0))
		body = body.slerp(lvl, clampf(dt * 5.0, 0.0, 1.0))

	# --- силы ---
	var v_air := velocity - wind
	var f := body.y * thrust
	f += Vector3(0.0, -m * G, 0.0)
	f -= v_air * v_air.length() * float(P["drag"])
	f += _turbulence(wind) * m
	velocity += f / m * dt
	position += velocity * dt


func _turbulence(wind: Vector3) -> Vector3:
	var wf := wind.length()
	if wf < 0.1:
		return Vector3.ZERO
	return Vector3(_turb[0].get_noise_1d(_t * 2.3), _turb[1].get_noise_1d(_t * 1.6) * 0.5,
		_turb[2].get_noise_1d(_t * 2.1)) * wf * 0.35


func _ground_and_obstacles(dt: float) -> void:
	var ground: float = main.height_at(position.x, position.z)
	var was_landed := landed
	landed = false
	if position.y - CLEARANCE < ground:
		var vdown := -velocity.y
		var spd := velocity.length()
		if (vdown > 6.0) or (spd > 14.0 and velocity.y < -3.0):
			main.crash("рельеф")
			return
		position.y = ground + CLEARANCE
		if velocity.y < 0.0: velocity.y = 0.0
		# трение о грунт
		velocity.x -= velocity.x * clampf(dt * 6.0, 0.0, 1.0)
		velocity.z -= velocity.z * clampf(dt * 6.0, 0.0, 1.0)
		landed = true
		if not was_landed and mode == MODE_GPS:
			velocity = Vector3.ZERO
	else:
		var hit: String = main.check_crash(position)
		if hit != "":
			main.crash(hit)


## Самотест лётной модели (флаг --flytest): детерминированные прогоны без ввода.
func self_test() -> bool:
	var ok := true
	var start := position
	var g0: float = main.height_at(start.x, start.z)
	var no := {"p": 0.0, "r": 0.0, "y": 0.0, "thr_c": 0.0, "thr": -1.0, "joy": false}
	# 1) ANGLE, клавиатура без ввода → висит (|vy| мал, наклон ≈ 0)
	mode = MODE_ANGLE; reset(); position = Vector3(start.x, g0 + 120.0, start.z)
	for i in 480: _step_physical(H, no, Vector3.ZERO)
	var hover_ok := absf(velocity.y) < 0.6 and body.y.y > 0.99
	print("FLYTEST hover ANGLE: vy=%.2f up.y=%.3f → %s" % [velocity.y, body.y.y, "OK" if hover_ok else "FAIL"])
	ok = ok and hover_ok
	# 2) газ в ноль (джойстик) → падает
	reset(); position = Vector3(start.x, g0 + 120.0, start.z)
	var zero := no.duplicate(); zero.thr = 0.0; zero.joy = true
	for i in 240: _step_physical(H, zero, Vector3.ZERO)
	var fall_ok := velocity.y < -7.0
	print("FLYTEST throttle=0 1s: vy=%.2f (ждём < -7) → %s" % [velocity.y, "OK" if fall_ok else "FAIL"])
	ok = ok and fall_ok
	# 3) ACRO, крен вправо 0.25 с при %.0f°/с → корпус повернулся заметно
	mode = MODE_ACRO; reset(); position = Vector3(start.x, g0 + 120.0, start.z)
	var rr := no.duplicate(); rr.r = 1.0
	for i in 60: _step_physical(H, rr, Vector3.ZERO)
	var roll := rad_to_deg(body.get_euler().z)
	var acro_ok := roll < -60.0
	print("FLYTEST ACRO roll 0.25s: roll=%.0f° (ждём < -60, вправо = отрицательный) → %s" % [roll, "OK" if acro_ok else "FAIL"])
	ok = ok and acro_ok
	# 4) ANGLE, тангаж вперёд 2 с → наклон к -tilt, движение вперёд (по -Z корпуса)
	mode = MODE_ANGLE; reset(); position = Vector3(start.x, g0 + 120.0, start.z)
	var fw := no.duplicate(); fw.p = 1.0
	for i in 480: _step_physical(H, fw, Vector3.ZERO)
	var pitch := rad_to_deg(body.get_euler().x)
	var fwd_v := velocity.dot(-Basis.from_euler(Vector3(0, _yaw, 0)).z)
	var ang_ok := pitch < -35.0 and fwd_v > 8.0
	print("FLYTEST ANGLE pitch fwd 2s: pitch=%.0f° v_fwd=%.1f м/с (ждём < -35°, > 8) → %s" % [pitch, fwd_v, "OK" if ang_ok else "FAIL"])
	ok = ok and ang_ok
	# 5) ANGLE без ввода при ветре 10 м/с → сносит по ветру
	reset(); position = Vector3(start.x, g0 + 120.0, start.z)
	var w := Vector3(10.0, 0.0, 0.0)
	for i in 720: _step_physical(H, no, w)
	var wind_ok := velocity.x > 2.0
	print("FLYTEST wind 10 m/s 3s: vx=%.1f (ждём > 2) → %s" % [velocity.x, "OK" if wind_ok else "FAIL"])
	ok = ok and wind_ok
	# 6) посадка: снижение с газом ниже висения не должно крашить, landed = true
	reset(); position = Vector3(start.x, g0 + 3.0, start.z)
	var soft := no.duplicate(); soft.thr_c = -0.3
	for i in 720:
		_step_physical(H, soft, Vector3.ZERO)
		_ground_and_obstacles(H)
	var land_ok: bool = landed and not main.crashed
	print("FLYTEST мягкая посадка: landed=%s crashed=%s → %s" % [landed, main.crashed, "OK" if land_ok else "FAIL"])
	ok = ok and land_ok
	# восстановление
	mode = MODE_GPS; reset(); position = start; main.crashed = false
	print("FLYTEST итог: %s" % ("ВСЕ OK" if ok else "ЕСТЬ FAIL"))
	return ok


func _apply_camera(dt: float, wind: Vector3) -> void:
	# вибрация винтов — едва заметная дрожь (растёт с газом и ветром); --novibe отключает
	var amp := 0.0 if _novibe else (0.0004 + throttle * 0.0006 + wind.length() * 0.00015)
	var wob_p := sin(_t * 9.3) * amp + sin(_t * 15.1) * amp * 0.4
	var wob_r := cos(_t * 7.1) * amp * 1.3
	var cam_b: Basis
	if mode == MODE_GPS:
		# подвес: горизонт стабилизирован, тангаж — мышью
		cam_b = Basis.from_euler(Vector3(_pitch, _yaw, 0.0))
	else:
		# камера жёстко на корпусе с наклоном вверх (FPV)
		cam_b = body * Basis(Vector3.RIGHT, deg_to_rad(P["cam_tilt"]))
	global_transform.basis = cam_b * Basis.from_euler(Vector3(wob_p, 0.0, wob_r))
