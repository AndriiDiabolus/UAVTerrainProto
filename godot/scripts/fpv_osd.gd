extends Control
## OSD полётного контроллера (стиль Betaflight/MAX7456): белые символы с чёрной обводкой,
## «впечатаны» в видеосигнал (рисуется внутри SubViewport видеотракта fpv_link).
## Считает RSSI (дальность × LOS × РЭБ) и батарею всегда — их читают HUD/телеметрия/flycam.

var main: Node3D
var home := Vector3.ZERO
var flight_t := 0.0
var battery := 1.0
var signal_q := 1.0
var link_type := 0          # 0 аналог / 1 цифра (меняет раскладку и подписи)
var lost := false           # цифра: фриз + SIGNAL LOST

const OSD := Color(0.96, 0.96, 0.94, 0.96)
const OSD_DIM := Color(0.96, 0.96, 0.94, 0.55)
const WARN := Color(1.0, 0.95, 0.85, 1.0)
const OUTL := Color(0, 0, 0, 0.85)
const CELLS := 4            # 4S
var _mah := 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(dt: float) -> void:
	flight_t += dt
	# ~10 мин на висении; расход растёт с газом (полный газ ≈ ×2.2)
	var thr := 0.35
	if main != null and main.cam != null and main.cam.get("throttle") != null:
		thr = float(main.cam.throttle)
	battery = maxf(0.0, battery - dt * 0.0016 * (0.55 + thr * 1.9))
	_mah += dt * (4.0 + thr * 30.0) * 1.1          # условный расход, мА·ч (≈1500 за полёт)
	if main != null and main.cam != null:
		var dp: Vector3 = main.cam.global_position
		var d := home.distance_to(dp)
		var dist_q := clampf(1.0 - maxf(0.0, d - 900.0) / 4000.0, 0.0, 1.0)
		var los: float = main.los_factor(home + Vector3(0, 2, 0), dp)
		var jam := 1.0
		if main.get("ew") != null:
			jam = main.ew.jam_factor(dp)
		var target := clampf(dist_q * (0.12 + 0.88 * los) * jam, 0.0, 1.0)
		signal_q = lerpf(signal_q, target, clampf(dt * 2.5, 0.0, 1.0))
	queue_redraw()


## Текст с чёрной обводкой.
func _txt(f: Font, pos: Vector2, s: String, size: int, col: Color = OSD) -> void:
	draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 3, OUTL)
	draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _line(a: Vector2, b: Vector2, col: Color = OSD, w: float = 2.0) -> void:
	draw_line(a, b, OUTL, w + 2.0)
	draw_line(a, b, col, w)


func _draw() -> void:
	if main == null or main.cam == null:
		return
	var vp := get_viewport_rect().size
	var cx := vp.x * 0.5
	var cy := vp.y * 0.5
	var f := get_theme_default_font()
	var fs := 18 if vp.x < 1000.0 else 20
	var blink := fmod(flight_t, 0.5) < 0.25

	# --- авиагоризонт по ориентации корпуса ---
	var b: Basis = main.cam.attitude() if main.cam.has_method("attitude") else main.cam.global_transform.basis
	var fwd: Vector3 = -b.z
	var pitch := asin(clampf(fwd.y, -1.0, 1.0))
	var roll := atan2(b.x.y, b.y.y)
	var hy := cy + pitch * vp.y * 0.55
	var dirv := Vector2(cos(roll), sin(roll))
	var half := vp.x * 0.16
	var ctr := Vector2(cx, hy)
	_line(ctr - dirv * half, ctr - dirv * (half * 0.3))
	_line(ctr + dirv * (half * 0.3), ctr + dirv * half)
	for s: float in [-1.0, 1.0]:
		var e: Vector2 = ctr + dirv * half * s
		_line(e, e + Vector2(-dirv.y, dirv.x) * 8.0)

	# --- перекрестие ---
	_line(Vector2(cx - 20, cy), Vector2(cx - 7, cy))
	_line(Vector2(cx + 7, cy), Vector2(cx + 20, cy))
	_line(Vector2(cx, cy - 5), Vector2(cx, cy + 5))

	# --- левая/правая шкалы ---
	var spd: float = main.cam.speed() if main.cam.has_method("speed") else 0.0
	_ladder(Vector2(64, cy), spd * 3.6, "KM/H", f, fs)
	var p: Vector3 = main.cam.global_position
	var agl: float = p.y - main.height_at(p.x, p.z)
	_ladder(Vector2(vp.x - 64, cy), agl, "ALT M", f, fs)

	# --- верхняя строка: ARMED · таймер · режим ---
	var mm := int(flight_t) / 60
	var ss := int(flight_t) % 60
	var mode_s := "ANGLE"
	if main.cam.has_method("mode_name"):
		mode_s = str(main.cam.mode_name()).split(" ")[0]
		if mode_s == "GPS": mode_s = "GPS HOLD"
	_txt(f, Vector2(24, 30), "ARMED" if not main.crashed else "DISARMED", fs)
	_txt(f, Vector2(cx - 34, 30), "%02d:%02d" % [mm, ss], fs + 2)
	_txt(f, Vector2(vp.x - 150, 30), mode_s, fs)
	if main.get("hud") != null and main.hud.get("fpv_link") != null and main.hud.fpv_link != null:
		_txt(f, Vector2(vp.x - 190, 56), main.hud.fpv_link.camera_name(), fs - 3)
	if link_type == 0:
		draw_circle(Vector2(cx + 38, 24), 5.0, OUTL)
		draw_circle(Vector2(cx + 38, 24), 4.0, Color(1, 0.25, 0.2, 0.4 + 0.6 * float(blink)))
		_txt(f, Vector2(cx + 48, 30), "REC", fs - 2)

	# --- курс и дом ---
	var yaw := rad_to_deg(atan2(-fwd.x, -fwd.z))
	if yaw < 0.0: yaw += 360.0
	_txt(f, Vector2(cx - 110, 56), "HDG %03d" % int(yaw), fs - 2)
	# стрелка домой (относительно курса)
	var to_home := home - p
	var hb := rad_to_deg(atan2(-to_home.x, -to_home.z))
	var rel := deg_to_rad(hb - yaw)
	var ap := Vector2(cx + 60, 52)
	var av := Vector2(sin(rel), -cos(rel)) * 10.0
	_line(ap - av, ap + av)
	_line(ap + av, ap + av.rotated(2.6) * 0.5)
	_line(ap + av, ap + av.rotated(-2.6) * 0.5)
	_txt(f, Vector2(cx + 78, 56), "%dm" % int(to_home.length()), fs - 2)

	# --- низ слева: батарея (вольты на ячейку), mAh, ток ---
	var vcell := lerpf(3.5, 4.2, battery)
	var thr := 0.3
	if main.cam.get("throttle") != null: thr = float(main.cam.throttle)
	var amps := 2.0 + thr * 38.0
	var bcol := OSD if battery > 0.22 else WARN
	_txt(f, Vector2(24, vp.y - 92), "%.1fV" % (vcell * CELLS), fs + 2, bcol)
	_txt(f, Vector2(24, vp.y - 66), "%.2fV/c" % vcell, fs - 2, bcol)
	_txt(f, Vector2(24, vp.y - 40), "%4dmAh  %4.1fA" % [int(_mah), amps], fs - 2)

	# --- низ справа: RSSI/LQ ---
	var dbm := lerpf(-108.0, -52.0, signal_q)
	var lq := int(signal_q * 100.0)
	var scol := OSD if signal_q > 0.3 else WARN
	if link_type == 0:
		_txt(f, Vector2(vp.x - 190, vp.y - 66), "RSSI %4ddBm" % int(dbm), fs - 2, scol)
		_txt(f, Vector2(vp.x - 190, vp.y - 40), "LQ %3d%%" % lq, fs - 2, scol)
	else:
		_txt(f, Vector2(vp.x - 190, vp.y - 66), "LINK %3d%%" % lq, fs - 2, scol)
		_txt(f, Vector2(vp.x - 190, vp.y - 40), "%s" % ("1080p60" if signal_q > 0.6 else ("720p30" if signal_q > 0.3 else "--")), fs - 2, scol)
	# столбики
	var sx := vp.x - 60.0
	var sy := vp.y - 44.0
	for i in 5:
		var on := signal_q >= (i + 1) / 5.0 - 0.12
		var hgt := 5.0 + i * 4.0
		draw_rect(Rect2(sx + i * 9.0 - 1, sy - hgt - 1, 8, hgt + 2), OUTL)
		draw_rect(Rect2(sx + i * 9.0, sy - hgt, 6, hgt), OSD if on else OSD_DIM, on)

	# --- газ внизу по центру ---
	_txt(f, Vector2(cx - 40, vp.y - 40), "THR %3d%%" % int(thr * 100.0), fs - 2)

	# --- предупреждения (мигают) ---
	var warn := ""
	if lost: warn = "SIGNAL LOST"
	elif main.cam.get("failsafe") == true: warn = "FAILSAFE"
	elif main.crashed: warn = "CRASH"
	elif battery < 0.2: warn = "LOW BATTERY"
	elif signal_q < 0.3: warn = "RSSI LOW"
	elif battery < 0.35: warn = "LAND NOW"
	if warn != "" and (blink or lost):
		var w := f.get_string_size(warn, HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 6).x
		_txt(f, Vector2(cx - w * 0.5, cy + 70), warn, fs + 6, WARN)


## Вертикальная шкала-«лесенка» со значением в рамке.
func _ladder(at: Vector2, val: float, label: String, f: Font, fs: int) -> void:
	for i in range(-4, 5):
		var y := at.y + i * 24.0
		var w := 10.0 if i % 2 == 0 else 6.0
		_line(Vector2(at.x - w, y), Vector2(at.x + w, y), OSD_DIM, 1.5)
	draw_rect(Rect2(at.x - 36, at.y - 14, 72, 28), OUTL, false, 4.0)
	draw_rect(Rect2(at.x - 36, at.y - 14, 72, 28), OSD, false, 1.5)
	_txt(f, Vector2(at.x - 30, at.y + 7), "%4d" % int(val), fs)
	_txt(f, Vector2(at.x - 22, at.y + 34), label, fs - 6, OSD_DIM)
