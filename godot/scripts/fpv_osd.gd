extends Control
## OSD видеопередатчика: авиагоризонт, батарея, сигнал (падает с дальностью),
## высота/скорость, таймер полёта, метка REC. Рисуется поверх FPV-картинки.

var main: Node3D
var home := Vector3.ZERO
var flight_t := 0.0
var battery := 1.0
var signal_q := 1.0

const OSD := Color(0.55, 1.0, 0.55, 0.92)      # характерный зелёный OSD
const OSD_DIM := Color(0.55, 1.0, 0.55, 0.5)
const WARN := Color(1.0, 0.45, 0.25, 0.95)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(dt: float) -> void:
	flight_t += dt
	# ~10 мин на висении; расход растёт с газом (полный газ ≈ ×2.2)
	var thr := 0.35
	if main != null and main.cam != null and main.cam.get("throttle") != null:
		thr = float(main.cam.throttle)
	battery = maxf(0.0, battery - dt * 0.0016 * (0.55 + thr * 1.9))
	if main != null and main.cam != null:
		var dp: Vector3 = main.cam.global_position
		var d := home.distance_to(dp)
		var dist_q := clampf(1.0 - maxf(0.0, d - 900.0) / 4000.0, 0.0, 1.0)
		# прямая видимость от оператора (точка взлёта + 2 м) до дрона
		var los: float = main.los_factor(home + Vector3(0, 2, 0), dp)
		# сигнал плавно следует за худшим из факторов (без дёрганья)
		var jam := 1.0
		if main.get("ew") != null:
			jam = main.ew.jam_factor(dp)
		var target := clampf(dist_q * (0.12 + 0.88 * los) * jam, 0.0, 1.0)
		signal_q = lerpf(signal_q, target, clampf(dt * 2.5, 0.0, 1.0))
	queue_redraw()


func _draw() -> void:
	if main == null or main.cam == null:
		return
	var vp := get_viewport_rect().size
	var cx := vp.x * 0.5
	var cy := vp.y * 0.5
	var f := get_theme_default_font()
	var fs := 15

	# --- авиагоризонт: линия горизонта с креном и тангажом ---
	# горизонт — по ориентации КОРПУСА (камера FPV наклонена вверх, это не должно смещать горизонт)
	var b: Basis = main.cam.attitude() if main.cam.has_method("attitude") else main.cam.global_transform.basis
	var fwd: Vector3 = -b.z
	var pitch := asin(clampf(fwd.y, -1.0, 1.0))
	var roll := atan2(b.x.y, b.y.y)
	var hy := cy + pitch * vp.y * 0.55
	var dirv := Vector2(cos(roll), sin(roll))
	var half := vp.x * 0.17
	var ctr := Vector2(cx, hy)
	draw_line(ctr - dirv * half, ctr - dirv * (half * 0.28), OSD, 1.6)
	draw_line(ctr + dirv * (half * 0.28), ctr + dirv * half, OSD, 1.6)
	# метки крена по краям
	for s: float in [-1.0, 1.0]:
		var e: Vector2 = ctr + dirv * half * s
		draw_line(e, e + Vector2(-dirv.y, dirv.x) * 7.0, OSD, 1.6)

	# --- перекрестие дрона ---
	draw_line(Vector2(cx - 18, cy), Vector2(cx - 6, cy), OSD, 2.0)
	draw_line(Vector2(cx + 6, cy), Vector2(cx + 18, cy), OSD, 2.0)
	draw_rect(Rect2(cx - 2, cy - 2, 4, 4), OSD, false, 1.5)

	# --- левая шкала: скорость ---
	var spd: float = main.cam.speed() if main.cam.has_method("speed") else 0.0
	_ladder(Vector2(70, cy), spd, "M/S", f, fs)

	# --- правая шкала: высота AGL ---
	var p: Vector3 = main.cam.global_position
	var agl: float = p.y - main.height_at(p.x, p.z)
	_ladder(Vector2(vp.x - 70, cy), agl, "ALT", f, fs)

	# --- батарея ---
	var bx := 24.0
	var by := vp.y - 108.0
	var bcol := OSD if battery > 0.25 else WARN
	draw_rect(Rect2(bx, by, 54, 16), bcol, false, 1.6)
	draw_rect(Rect2(bx + 54, by + 4, 4, 8), bcol)
	draw_rect(Rect2(bx + 2, by + 2, 50.0 * battery, 12), bcol)
	draw_string(f, Vector2(bx + 66, by + 14), "%d%%" % int(battery * 100),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, bcol)

	# --- сигнал: столбики ---
	var sx := vp.x - 96.0
	var sy := vp.y - 96.0
	for i in 5:
		var lvl := (i + 1) / 5.0
		var hgt := 4.0 + i * 4.0
		var on := signal_q >= lvl - 0.12
		draw_rect(Rect2(sx + i * 9.0, sy - hgt, 6, hgt),
			(OSD if on else OSD_DIM), on)
	draw_string(f, Vector2(sx - 4, sy + 16), "RSSI %d%%" % int(signal_q * 100),
		HORIZONTAL_ALIGNMENT_LEFT, -1, 13, OSD if signal_q > 0.3 else WARN)

	# --- таймер и REC ---
	var mm := int(flight_t) / 60
	var ss := int(flight_t) % 60
	draw_string(f, Vector2(cx - 34, 30), "%02d:%02d" % [mm, ss],
		HORIZONTAL_ALIGNMENT_LEFT, -1, 18, OSD)
	draw_circle(Vector2(cx - 52, 24), 5.0, Color(1, 0.25, 0.2,
		0.35 + 0.65 * absf(sin(flight_t * 2.2))))
	draw_string(f, Vector2(cx + 26, 30), "REC", HORIZONTAL_ALIGNMENT_LEFT, -1, 15,
		Color(1, 0.4, 0.35, 0.9))

	# --- курс сверху ---
	var yaw := rad_to_deg(atan2(-fwd.x, -fwd.z))
	if yaw < 0.0: yaw += 360.0
	draw_string(f, Vector2(cx - 96, 56), "HDG %03d" % int(yaw),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, OSD)
	draw_string(f, Vector2(cx + 52, 56), "HOME %dм" % int(home.distance_to(p)),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs, OSD)

	# --- режим полёта и газ (внизу по центру) ---
	if main.cam.has_method("mode_name"):
		var thr := int(float(main.cam.throttle) * 100.0)
		var ms: String = str(main.cam.mode_name()).split(" ")[0]
		draw_string(f, Vector2(cx - 60, vp.y - 40), "%s   THR %d%%" % [ms, thr],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, OSD)


## Вертикальная шкала-«лесенка» со значением в рамке.
func _ladder(at: Vector2, val: float, label: String, f: Font, fs: int) -> void:
	for i in range(-4, 5):
		var y := at.y + i * 22.0
		var w := 10.0 if i % 2 == 0 else 6.0
		draw_line(Vector2(at.x - w, y), Vector2(at.x + w, y), OSD_DIM, 1.2)
	draw_rect(Rect2(at.x - 34, at.y - 12, 68, 24), OSD, false, 1.5)
	draw_string(f, Vector2(at.x - 30, at.y + 6), "%4d" % int(val),
		HORIZONTAL_ALIGNMENT_LEFT, -1, fs + 1, OSD)
	draw_string(f, Vector2(at.x - 16, at.y + 30), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, 11, OSD_DIM)
