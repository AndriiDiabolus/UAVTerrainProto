extends Control
## HUD «адаптивный минимум» (вариант G): постоянно — только строка статуса внизу по центру
## (режим · ● камера · AGL · скорость · канал) и перекрестие. Остальное — по событию:
## батарея < 40 % (верх-лево), канал < 70 % / РЭБ / failsafe (верх-право), миссия (верх-центр),
## ветер > 5 м/с (низ-лево, вместе с флажком), стики — только с пультом. Тост при смене камеры/режима.
## Полная телеметрия — пока удерживается I (hud_label).

var main: Node3D
var toast_text := ""
var toast_sub := ""
var toast_col := Color(1, 1, 1)
var _toast_t := 0.0
const TXT := Color(0.91, 0.91, 0.89, 0.92)
const DIM := Color(0.82, 0.82, 0.80, 0.67)
const OUT := Color(0, 0, 0, 0.6)
const CAM_COL := [Color(1.0, 0.75, 0.31), Color(0.43, 0.67, 1.0), Color(0.55, 1.0, 0.59), Color(0.96, 0.96, 0.96)]
const CAM_SHORT := ["ANALOG", "DJI O3", "NIGHT", "THERMAL"]


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func toast(text: String, sub: String = "", col: Color = Color(1, 1, 1), dur: float = 2.5) -> void:
	toast_text = text; toast_sub = sub; toast_col = col; _toast_t = dur


func _process(dt: float) -> void:
	if _toast_t > 0.0:
		_toast_t -= dt
	queue_redraw()


func _txt(f: Font, pos: Vector2, s: String, size: int, col: Color = TXT) -> void:
	draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 2, OUT)
	draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _panel(r: Rect2, a: float = 0.43, border: Color = Color(0, 0, 0, 0)) -> void:
	draw_rect(r, Color(0, 0, 0, a))
	if border.a > 0.0:
		draw_rect(r, border, false, 1.0)


func _draw() -> void:
	if main == null or main.cam == null:
		return
	var vp := get_viewport_rect().size
	var f := get_theme_default_font()
	var cam: Camera3D = main.cam
	var p: Vector3 = cam.global_position
	var agl: float = p.y - main.height_at(p.x, p.z)
	var spd: float = cam.speed() if cam.has_method("speed") else 0.0
	var lq: float = 1.0; var bat: float = 1.0
	if main._fpv_osd != null:
		lq = main._fpv_osd.signal_q; bat = main._fpv_osd.battery
	var cam_i := 0
	if main.hud != null and main.hud.fpv_link != null:
		cam_i = int(main.hud.fpv_link.camera)
	var mode_s := str(cam.mode_name()).split(" ")[0] if cam.has_method("mode_name") else "—"

	# --- строка статуса ---
	var fs := 15
	var segs: Array = [[mode_s, TXT], ["·", DIM], ["CAM", CAM_COL[cam_i]], ["·", DIM], ["%d м" % int(agl), TXT], ["·", DIM],
		["%d м/с" % int(spd), TXT], ["·", DIM], ["канал %d %%" % int(lq * 100.0), TXT if lq > 0.7 else Color(1.0, 0.75, 0.45)]]
	if main.targets != null:
		segs.append(["·", DIM])
		if main.targets.weapon == 1:
			segs.append(["БЧ ⚠ ВЗВЕДЕНА" if main.targets.armed else "БЧ снята", Color(1.0, 0.45, 0.35) if main.targets.armed else DIM])
		else:
			segs.append(["сброс ×%d" % int(main.targets.ammo), TXT])
	if cam.get("landed") == true:
		segs.append(["·", DIM]); segs.append(["на земле", DIM])
	var widths: Array = []
	var total := 0.0
	for sg in segs:
		var w: float = f.get_string_size(CAM_SHORT[cam_i] if sg[0] == "CAM" else sg[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		if sg[0] == "CAM": w += 16.0
		widths.append(w); total += w + 10.0
	total -= 10.0
	var x := vp.x * 0.5 - total * 0.5
	var y := vp.y - 54.0
	_panel(Rect2(x - 14, y, total + 28, 30), 0.43)
	for i in segs.size():
		var sg: Array = segs[i]
		if sg[0] == "CAM":
			draw_circle(Vector2(x + 5, y + 15), 5.0, CAM_COL[cam_i])
			_txt(f, Vector2(x + 16, y + 21), CAM_SHORT[cam_i], fs, CAM_COL[cam_i])
		else:
			_txt(f, Vector2(x, y + 21), sg[0], fs, sg[1])
		x += widths[i] + 10.0

	# --- контекст: батарея ---
	if bat < 0.4:
		var col := Color(1.0, 0.55, 0.5) if bat < 0.2 else Color(1.0, 0.78, 0.55)
		_panel(Rect2(14, 14, 236, 44), 0.35, Color(col.r, col.g, col.b, 0.45))
		var blocks := ""
		for i in 5: blocks += "▮" if bat > (i + 0.5) / 5.0 else "▯"
		_txt(f, Vector2(24, 34), "БАТАРЕЯ %d %%   %s" % [int(bat * 100.0), blocks], 14, col)
		_txt(f, Vector2(24, 52), "садись" if bat < 0.2 else "возвращайся", 11, Color(col.r, col.g, col.b, 0.7))
	# --- контекст: канал / РЭБ / failsafe ---
	var jam_s := ""
	if main.get("ew") != null:
		var ji: Dictionary = main.ew.nearest_info(p)
		if not ji.is_empty() and float(ji.edge) < 0.0:
			jam_s = "РЭБ: подавление %d %%" % int(float(ji.jam) * 100.0)
	var fsafe: bool = cam.get("failsafe") == true
	if lq < 0.7 or jam_s != "" or fsafe:
		var col := Color(1.0, 0.5, 0.45) if (fsafe or lq < 0.3) else Color(1.0, 0.78, 0.47)
		_panel(Rect2(vp.x - 250, 14, 236, 44), 0.35, Color(col.r, col.g, col.b, 0.45))
		var bars := ""
		for i in 5: bars += "▂▃▅▆▇"[i] if lq > (i + 0.5) / 5.0 else " "
		_txt(f, Vector2(vp.x - 240, 34), ("✖ FAILSAFE" if fsafe else "КАНАЛ %d %%   %s" % [int(lq * 100.0), bars]), 14, col)
		_txt(f, Vector2(vp.x - 240, 52), jam_s if jam_s != "" else "вернись в прямую видимость", 11, Color(col.r, col.g, col.b, 0.7))
	# --- контекст: миссия ---
	if main.mission != null and main.mission.active:
		var ml: String = main.mission.hud_line()
		var w := f.get_string_size(ml, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		_panel(Rect2(vp.x * 0.5 - w * 0.5 - 14, 14, w + 28, 30), 0.4, Color(1.0, 0.9, 0.6, 0.35))
		_txt(f, Vector2(vp.x * 0.5 - w * 0.5, 35), ml, 13, Color(1.0, 0.92, 0.66))
	# --- контекст: ветер > 5 м/с (рядом с флажком) ---
	if main.weather != null:
		var w3: Vector3 = main.weather.wind_vec()
		if w3.length() >= 5.0:
			_panel(Rect2(10, vp.y - 64, 176, 36), 0.35, Color(0.78, 0.86, 1.0, 0.35))
			_txt(f, Vector2(20, vp.y - 40), "ветер %d м/с %s" % [int(w3.length()), main.hud._wind_arrow(w3)], 14, Color(0.8, 0.88, 1.0))
	# --- тост ---
	if _toast_t > 0.0:
		var a := clampf(_toast_t / 0.5, 0.0, 1.0)
		var w1 := f.get_string_size(toast_text, HORIZONTAL_ALIGNMENT_LEFT, -1, 24).x
		var w2 := f.get_string_size(toast_sub, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
		var w := maxf(w1, w2)
		var ty := 64.0
		draw_rect(Rect2(vp.x * 0.5 - w * 0.5 - 28, ty, w + 56, 66 if toast_sub != "" else 46), Color(0, 0, 0, 0.55 * a))
		draw_rect(Rect2(vp.x * 0.5 - w * 0.5 - 28, ty, w + 56, 66 if toast_sub != "" else 46), Color(toast_col.r, toast_col.g, toast_col.b, 0.6 * a), false, 2.0)
		draw_circle(Vector2(vp.x * 0.5 - w1 * 0.5 - 6, ty + 23), 6.0, Color(toast_col.r, toast_col.g, toast_col.b, a))
		_txt(f, Vector2(vp.x * 0.5 - w1 * 0.5 + 8, ty + 31), toast_text, 24, Color(toast_col.r, toast_col.g, toast_col.b, a))
		if toast_sub != "":
			_txt(f, Vector2(vp.x * 0.5 - w2 * 0.5, ty + 56), toast_sub, 13, Color(DIM.r, DIM.g, DIM.b, DIM.a * a))
