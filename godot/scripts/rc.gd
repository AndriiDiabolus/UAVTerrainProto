extends Node
## Пилотский модуль: RC-пульт по USB + Betaflight Actual Rates.
##  - Мастер калибровки: назначает оси T/Y/P/R и инверсии по реальным движениям стиков
##    (работает с любым пультом в режиме USB-джойстика: RadioMaster, Jumper, BetaFPV…).
##  - Rates ACTUAL (как в Betaflight): centerSensitivity/maxRate/expo, пресеты + сохранение.
## Всё хранится в user://settings.cfg [rc]; flycam читает стики и кривые отсюда.

var main: Node3D
var configured := false            # мастер пройден (или валидный конфиг загружен)
var axes := [1, 0, 3, 2]           # индексы осей: T, Y, P, R
var inv := [true, false, true, false]
var deadband := 0.02               # у пультов люфт меньше, чем у геймпадов

# --- Betaflift Actual Rates (по осям RP и Y), градусы/с ---
var rates_on := true
var rc_center := 220.0             # centerSensitivity RP
var rc_max := 670.0                # maxRate RP
var rc_expo := 0.54
var yaw_center := 200.0
var yaw_max := 560.0
var yaw_expo := 0.5
const PRESETS := [
	{"name": "новачок", "c": 160.0, "m": 360.0, "e": 0.3, "yc": 140.0, "ym": 280.0, "ye": 0.3},
	{"name": "стандарт BF", "c": 220.0, "m": 670.0, "e": 0.54, "yc": 200.0, "ym": 560.0, "ye": 0.5},
	{"name": "кіно", "c": 120.0, "m": 300.0, "e": 0.4, "yc": 110.0, "ym": 240.0, "ye": 0.4},
	{"name": "власні", "c": -1.0, "m": 0.0, "e": 0.0, "yc": 0.0, "ym": 0.0, "ye": 0.0},
]
var preset_idx := 1

# --- мастер калибровки ---
var wizard_active := false
var wizard_step := 0
var wizard_hint := ""
var _wiz_base: Array = []          # базовые значения всех осей (стики в центре, газ вниз)
var _wiz_found: Array = []         # [ось, знак] по шагам
const WIZ_STEPS := [
	["ГАЗ — плавно ВГОРУ до упору і тримай", "T"],
	["РИСКАННЯ — газ-стік ВПРАВО до упору і тримай", "Y"],
	["ТАНГАЖ — правий стік ВІД СЕБЕ (вперед) і тримай", "P"],
	["КРЕН — правий стік ВПРАВО і тримай", "R"],
]
const N_AXES := 8


func setup(m: Node3D) -> void:
	main = m
	load_cfg()


func joy_name() -> String:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		return ""
	return Input.get_joy_name(pads[0])


## Стики пульта по текущему маппингу: {t, y, p, r} в -1..1, уже с мёртвой зоной.
func read(id: int) -> Dictionary:
	var out := {}
	var keys := ["t", "y", "p", "r"]
	for i in 4:
		var v := Input.get_joy_axis(id, axes[i])
		if inv[i]:
			v = -v
		out[keys[i]] = _db(v)
	return out


func _db(v: float) -> float:
	if absf(v) < deadband:
		return 0.0
	return signf(v) * (absf(v) - deadband) / (1.0 - deadband)


## Betaflight ACTUAL rates: вход — стик -1..1, выход — угловая скорость, рад/с.
func actual_rate(x: float, is_yaw: bool = false) -> float:
	var c := yaw_center if is_yaw else rc_center
	var m := yaw_max if is_yaw else rc_max
	var e := yaw_expo if is_yaw else rc_expo
	var ex := x * absf(x) * absf(x) * absf(x) * e + x * (1.0 - e)   # x·|x|³·expo + x·(1−expo)
	var deg := c * ex + maxf(m - c, 0.0) * absf(ex) * ex
	return deg_to_rad(deg)


func preset_name() -> String:
	return str(PRESETS[preset_idx]["name"])


func rates_label() -> String:
	return "%s · %d/%d/%.2f" % [preset_name(), int(rc_center), int(rc_max), rc_expo]


func cycle_preset(dir: int) -> void:
	preset_idx = posmod(preset_idx + dir, PRESETS.size())
	var p: Dictionary = PRESETS[preset_idx]
	if float(p["c"]) > 0.0:              # «свои» не перетирают числа
		rc_center = p["c"]; rc_max = p["m"]; rc_expo = p["e"]
		yaw_center = p["yc"]; yaw_max = p["ym"]; yaw_expo = p["ye"]
	save_cfg()


# ---------------- мастер калибровки ----------------

func wizard_start() -> void:
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		if main.hud != null:
			main.hud.toast("ПУЛЬТ НЕ ЗНАЙДЕНО", "підключи пульт по USB у режимі джойстика", Color(1.0, 0.6, 0.4))
		return
	wizard_active = true
	wizard_step = -1                      # -1 = снятие базы
	wizard_hint = "Стіки в ЦЕНТР, газ УНИЗ — не торкайся 2 секунди"
	_wiz_found = []
	_wiz_base = []
	_wiz_timer = 2.0


var _wiz_timer := 0.0
var _wiz_hold := 0.0
var _wiz_best_axis := -1
var _wiz_best_val := 0.0


func _process(dt: float) -> void:
	if not wizard_active:
		return
	var pads := Input.get_connected_joypads()
	if pads.is_empty():
		wizard_active = false
		return
	var id: int = pads[0]
	if wizard_step == -1:
		_wiz_timer -= dt
		if _wiz_timer <= 0.0:
			_wiz_base = []
			for a in N_AXES:
				_wiz_base.append(Input.get_joy_axis(id, a))
			wizard_step = 0
			wizard_hint = WIZ_STEPS[0][0]
			_wiz_hold = 0.0
		return
	# ищем ось с максимальным отклонением от базы; держать 0.8 с для фиксации
	var best_a := -1
	var best_d := 0.0
	for a in N_AXES:
		var d := Input.get_joy_axis(id, a) - float(_wiz_base[a])
		if absf(d) > absf(best_d):
			best_d = d; best_a = a
	if absf(best_d) > 0.5:
		if best_a == _wiz_best_axis:
			_wiz_hold += dt
		else:
			_wiz_best_axis = best_a; _wiz_best_val = best_d; _wiz_hold = 0.0
		if _wiz_hold >= 0.8:
			# газ: «вверх» должен дать +1 → инверсия, если ось пошла в минус.
			# остальные: «вправо/вперёд» = +1 (вперёд по тангажу в игре = +p)
			var used := false
			for f: Array in _wiz_found:
				if int(f[0]) == best_a:
					used = true
			if not used:
				_wiz_found.append([best_a, best_d < 0.0])
				wizard_step += 1
				_wiz_best_axis = -1; _wiz_hold = 0.0
				if wizard_step >= WIZ_STEPS.size():
					_wizard_finish()
				else:
					wizard_hint = WIZ_STEPS[wizard_step][0]
	else:
		_wiz_best_axis = -1
		_wiz_hold = 0.0


func _wizard_finish() -> void:
	for i in 4:
		axes[i] = int(_wiz_found[i][0])
		inv[i] = bool(_wiz_found[i][1])
	configured = true
	wizard_active = false
	save_cfg()
	if main.hud != null:
		main.hud.toast("ПУЛЬТ НАЛАШТОВАНО", "T/Y/P/R = осі %s · «%s»" % [str(axes), joy_name()], Color(0.55, 1.0, 0.59))


func wizard_cancel() -> void:
	wizard_active = false


# ---------------- сохранение ----------------

func save_cfg() -> void:
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("rc", "axes", axes)
	cfg.set_value("rc", "inv", inv)
	cfg.set_value("rc", "configured", configured)
	cfg.set_value("rc", "preset", preset_idx)
	cfg.set_value("rc", "center", rc_center)
	cfg.set_value("rc", "max", rc_max)
	cfg.set_value("rc", "expo", rc_expo)
	cfg.set_value("rc", "yaw_center", yaw_center)
	cfg.set_value("rc", "yaw_max", yaw_max)
	cfg.set_value("rc", "yaw_expo", yaw_expo)
	cfg.save("user://settings.cfg")


func load_cfg() -> void:
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") != OK:
		return
	if cfg.has_section("rc"):
		axes = cfg.get_value("rc", "axes", axes)
		inv = cfg.get_value("rc", "inv", inv)
		configured = bool(cfg.get_value("rc", "configured", false))
		preset_idx = int(cfg.get_value("rc", "preset", 1))
		rc_center = float(cfg.get_value("rc", "center", rc_center))
		rc_max = float(cfg.get_value("rc", "max", rc_max))
		rc_expo = float(cfg.get_value("rc", "expo", rc_expo))
		yaw_center = float(cfg.get_value("rc", "yaw_center", yaw_center))
		yaw_max = float(cfg.get_value("rc", "yaw_max", yaw_max))
		yaw_expo = float(cfg.get_value("rc", "yaw_expo", yaw_expo))
