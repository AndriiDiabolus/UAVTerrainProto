extends Control
## HUD «адаптивный минимум» (вариант G): постоянно — только строка статуса внизу по центру
## (режим · ● камера · AGL · скорость · канал) и перекрестие. Остальное — по событию:
## батарея < 40 % (верх-лево), канал < 70 % / РЭБ / failsafe (верх-право), миссия (верх-центр),
## ветер > 5 м/с (низ-лево, вместе с флажком), стики — только с пультом. Тост при смене камеры/режима.
## Полная телеметрия — пока удерживается I (hud_label).

var main: Node3D
var _sh_prev_alt := 0.0          # для вертикальной скорости на панели SHARK
var _sh_vs := 0.0
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
	# вертикальная скорость для панели SHARK (сглаженная)
	if main != null and main.cam != null and dt > 0.0:
		var y: float = main.cam.global_position.y
		_sh_vs = lerpf(_sh_vs, (y - _sh_prev_alt) / dt, clampf(dt * 4.0, 0.0, 1.0))
		_sh_prev_alt = y
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

	# --- FPS (верх-лево, постоянно; в FPV — поверх сигнала, вне видеотракта) ---
	var fps := Engine.get_frames_per_second()
	var fcol := Color(0.55, 1.0, 0.59) if fps >= 50.0 else (Color(1.0, 0.82, 0.45) if fps >= 30.0 else Color(1.0, 0.5, 0.45))
	var fps_s := "FPS %d" % int(fps)
	var base_scale: float = float(main.get("fsr_scale"))
	var cur_scale := get_viewport().scaling_3d_scale
	if base_scale > 0.0 and cur_scale < base_scale - 0.005:
		fps_s += " ·%d%%" % int(cur_scale * 100.0)     # авто-скейл понизил внутреннее разрешение
	_panel(Rect2(14, 14, 30 + f.get_string_size(fps_s, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x, 26), 0.35)
	_txt(f, Vector2(24, 33), fps_s, 14, fcol)
	if main.hud != null and main.hud.get("fpv_on") == true:
		return          # в FPV остальным владеет OSD видеотракта

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
	if main._fpv_osd != null and main._fpv_osd.get("via_relay") == true:
		segs.append(["·", DIM]); segs.append(["РЕТР", Color(0.5, 0.85, 1.0)])
	if main.targets != null:
		segs.append(["·", DIM])
		if str(cam.get("drone_id")) == "wing":
			segs.append(["зум ×%.0f" % float(cam.get("wing_zoom")), TXT])
			segs.append(["·", DIM])
			segs.append(["метки %d" % main.targets.marked_list().size(), Color(1.0, 0.62, 0.2)])
		elif str(cam.get("drone_id")) == "mship":
			segs.append(["носитель FPV", DIM])
		elif main.targets.weapon == 2:
			segs.append(["БЧ ⚠ ВЗВЕДЕНА" if main.targets.armed else "БЧ снята", Color(1.0, 0.45, 0.35) if main.targets.armed else DIM])
		elif main.targets.weapon == 0:
			segs.append(["оск ×%d" % int(main.targets.ammo_frag), TXT])
		else:
			segs.append(["кум ×%d" % int(main.targets.ammo_heat), TXT])
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

	# --- панель НСУ разведчика SHARK (право-низ): авиагоризонт, скорость, высота, курс ---
	if str(cam.get("drone_id")) == "wing" and main.get("menu_open") != true:
		_draw_shark_panel(f, vp, cam, agl)

	# --- контекст: батарея ---
	if bat < 0.4:
		var col := Color(1.0, 0.55, 0.5) if bat < 0.2 else Color(1.0, 0.78, 0.55)
		_panel(Rect2(14, 48, 236, 44), 0.35, Color(col.r, col.g, col.b, 0.45))
		var blocks := ""
		for i in 5: blocks += "▮" if bat > (i + 0.5) / 5.0 else "▯"
		_txt(f, Vector2(24, 68), "БАТАРЕЯ %d %%   %s" % [int(bat * 100.0), blocks], 14, col)
		_txt(f, Vector2(24, 86), "садись" if bat < 0.2 else "возвращайся", 11, Color(col.r, col.g, col.b, 0.7))
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
		var hint := jam_s if jam_s != "" else "вернись в прямую видимость или разверни ретранслятор (H)"
		_txt(f, Vector2(vp.x - 240, 52), hint, 11, Color(col.r, col.g, col.b, 0.7))
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
	_draw_toast(f, vp)


## Панель наземной станции SHARK: круглый авиагоризонт (крен/тангаж), лента скорости и
## вертикальной, высота AGL/MSL, компас курса с меткой подвеса, зум/метки, режим и сваливание.
func _draw_shark_panel(f: Font, vp: Vector2, cam: Camera3D, agl: float) -> void:
	var PW := 336.0; var PH := 208.0
	var px := vp.x - PW - 14.0
	var py := vp.y - PH - 92.0
	var acc := Color(0.55, 0.85, 1.0)
	var org := Color(1.0, 0.62, 0.2)
	_panel(Rect2(px, py, PW, PH), 0.5, Color(acc.r, acc.g, acc.b, 0.35))
	_txt(f, Vector2(px + 12, py + 20), "НСУ · SHARK", 13, acc)

	var roll := float(cam.get("_wing_roll"))
	var pitch := float(cam.get("_wing_pitch"))
	var air := float(cam.get("_wing_air"))
	var auto_c: bool = cam.get("_wing_auto") == true
	var zoom := float(cam.get("wing_zoom"))
	var gyaw := float(cam.get("_gim_yaw"))

	# --- авиагоризонт (центр панели): весь круг — небо, земля — сегмент ниже линии горизонта ---
	var c := Vector2(px + PW * 0.5, py + 106.0)
	var R := 62.0
	draw_circle(c, R + 3.0, Color(0, 0, 0, 0.55))
	draw_circle(c, R, Color(0.30, 0.52, 0.78, 0.9))
	var ppx := clampf(rad_to_deg(pitch) * 3.2, -R * 0.72, R * 0.72)   # сдвиг горизонта по тангажу
	var rot := Transform2D(-roll, Vector2.ZERO)
	var half_w := sqrt(maxf(R * R - ppx * ppx, 1.0))
	var hl := rot * Vector2(-half_w, ppx)
	var hr := rot * Vector2(half_w, ppx)
	var start := hr.angle()
	var endv := hl.angle()
	if endv < start: endv += TAU
	var gpoly := PackedVector2Array([c + hl, c + hr])
	for i in 21:
		var a := start + (endv - start) * (i / 20.0)
		gpoly.append(c + Vector2(cos(a), sin(a)) * R)
	draw_colored_polygon(gpoly, Color(0.42, 0.30, 0.17, 0.95))
	draw_line(c + hl, c + hr, Color(1, 1, 1, 0.9), 2.0)
	# шкала тангажа ±20° (линии через 10°)
	for pd in [-20, -10, 10, 20]:
		var off := rot * Vector2(0, ppx - pd * 3.2)
		if off.length() < R - 8.0:
			var half := 14.0 if pd % 20 == 0 else 9.0
			var l1 := rot * Vector2(-half, ppx - pd * 3.2)
			var l2 := rot * Vector2(half, ppx - pd * 3.2)
			draw_line(c + l1, c + l2, Color(1, 1, 1, 0.6), 1.0)
	# маркер самолёта (неподвижный)
	draw_line(c + Vector2(-22, 0), c + Vector2(-7, 0), org, 3.0)
	draw_line(c + Vector2(22, 0), c + Vector2(7, 0), org, 3.0)
	draw_circle(c, 2.5, org)
	# индекс крена сверху
	var rmk := c + Vector2(sin(-roll), -cos(-roll)) * (R - 5.0)
	draw_circle(rmk, 3.0, Color(1, 1, 1, 0.9))

	# --- лента скорости (слева) ---
	var sx := px + 14.0
	_panel(Rect2(sx, py + 62, 64, 88), 0.45)
	_txt(f, Vector2(sx + 6, py + 78), "ВОЗД", 10, DIM)
	var scol := TXT if air >= 16.0 else Color(1.0, 0.5, 0.45)
	_txt(f, Vector2(sx + 6, py + 102), "%d" % int(air), 24, scol)
	_txt(f, Vector2(sx + 34, py + 102), "м/с", 10, DIM)
	_txt(f, Vector2(sx + 6, py + 122), "ВЕРТ", 10, DIM)
	var vcol := TXT if absf(_sh_vs) < 6.0 else Color(1.0, 0.78, 0.45)
	_txt(f, Vector2(sx + 6, py + 142), "%+.1f" % _sh_vs, 15, vcol)

	# --- высота (справа) ---
	var hx := px + PW - 78.0
	_panel(Rect2(hx, py + 62, 64, 88), 0.45)
	_txt(f, Vector2(hx + 6, py + 78), "AGL", 10, DIM)
	_txt(f, Vector2(hx + 6, py + 102), "%d" % int(agl), 24, TXT)
	_txt(f, Vector2(hx + 6, py + 122), "MSL", 10, DIM)
	_txt(f, Vector2(hx + 6, py + 142), "%d" % int(cam.global_position.y), 15, DIM)

	# --- компас-лента (верх панели) ---
	var fwd := -cam.global_transform.basis.z
	var hdg := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	var cy := py + 34.0
	_panel(Rect2(px + 70, py + 26, PW - 140, 18), 0.45)
	var names := ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
	for hh in range(0, 360, 15):
		var d := fposmod(float(hh) - hdg + 180.0, 360.0) - 180.0   # смещение отметки от курса, °
		if absf(d) > 55.0:
			continue
		var xx: float = px + PW * 0.5 + d * ((PW - 150.0) / 120.0)
		if hh % 45 == 0:
			_txt(f, Vector2(xx - 5, cy + 6), names[hh / 45], 11, TXT)
		else:
			draw_line(Vector2(xx, cy - 4), Vector2(xx, cy + 2), DIM, 1.0)
	draw_line(Vector2(px + PW * 0.5, py + 26), Vector2(px + PW * 0.5, py + 44), org, 2.0)
	_txt(f, Vector2(px + PW * 0.5 + 6, py + 40), "%03d°" % int(hdg), 11, org)
	# метка направления подвеса относительно курса
	if absf(gyaw) > 0.05:
		var gx: float = px + PW * 0.5 + clampf(rad_to_deg(gyaw), -58.0, 58.0) * ((PW - 150.0) / 120.0)
		draw_circle(Vector2(gx, cy + 8), 3.0, Color(0.55, 0.85, 1.0))

	# --- низ: зум, метки, режим ---
	var by := py + PH - 16.0
	_txt(f, Vector2(px + 14, by), "ЗУМ ×%.0f" % zoom, 13, acc if zoom > 1.0 else DIM)
	var mk: int = main.targets.marked_list().size() if main.targets != null else 0
	_txt(f, Vector2(px + 96, by), "МЕТКИ %d" % mk, 13, org if mk > 0 else DIM)
	var mode_txt := "АВТО-НАБОР" if auto_c else "РУЧНОЕ"
	_txt(f, Vector2(px + 186, by), mode_txt, 13, Color(0.55, 1.0, 0.59) if auto_c else TXT)
	if air < 15.0 and cam.get("landed") != true:
		if fmod(Time.get_ticks_msec() / 250.0, 2.0) < 1.0:      # мигание
			_txt(f, Vector2(px + 268, by), "СВАЛ!", 13, Color(1.0, 0.4, 0.35))


func _draw_toast(f: Font, vp: Vector2) -> void:
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
