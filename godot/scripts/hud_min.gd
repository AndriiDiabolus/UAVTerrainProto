extends Control
## HUD «адаптивный минимум» (вариант G): постоянно — только строка статуса внизу по центру
## (режим · ● камера · AGL · скорость · канал) и перекрестие. Остальное — по событию:
## батарея < 40 % (верх-лево), канал < 70 % / РЭБ / failsafe (верх-право), миссия (верх-центр),
## ветер > 5 м/с (низ-лево, вместе с флажком), стики — только с пультом. Тост при смене камеры/режима.
## Полная телеметрия — пока удерживается I (hud_label).

var main: Node3D
var _sh_prev_alt := 0.0          # для вертикальной скорости на панели SHARK
var _sh_vs := 0.0
var _sh_flt := 0.0               # время полёта SHARK (сброс на земле)
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
	# вертикальная скорость для панели SHARK (сглаженная) + счётчик времени полёта
	if main != null and main.cam != null and dt > 0.0:
		var y: float = main.cam.global_position.y
		_sh_vs = lerpf(_sh_vs, (y - _sh_prev_alt) / dt, clampf(dt * 4.0, 0.0, 1.0))
		_sh_prev_alt = y
		if main.cam.get("landed") == true:
			_sh_flt = 0.0
		elif main.get("menu_open") != true:
			_sh_flt += dt
	queue_redraw()


const MARK_RED := Color(1.0, 0.22, 0.14, 0.95)

## Квест-панель: тактичні саб-задачі місії дрібним шрифтом зліва (✓ готово · ▸ поточна · · попереду).
func _draw_quest(f: Font, vp: Vector2) -> void:
	if main.mission == null or main.mission.get("active") != true:
		return
	var lines: Array = main.mission.quest_lines()
	if lines.is_empty():
		return
	var fs := 11
	var lh := 16.0
	var w := 252.0
	var h := lines.size() * lh + 22.0
	var x := 14.0
	var y := clampf(vp.y * 0.5 - h * 0.5, 96.0, vp.y - h - 120.0)
	_panel(Rect2(x, y, w, h), 0.38)
	var yy := y + 16.0
	_txt(f, Vector2(x + 10, yy), "ЗАВДАННЯ", fs, DIM)
	yy += lh * 0.5
	for ln: Dictionary in lines:
		yy += lh
		if ln.has("h"):
			var hc := Color(1.0, 0.78, 0.35) if int(ln.st) == 1 else (Color(0.55, 1.0, 0.59, 0.75) if int(ln.st) == 2 else DIM)
			_txt(f, Vector2(x + 10, yy), str(ln.h).to_upper(), fs, hc)
		else:
			var st := int(ln.st)
			var pre := "✓ " if st == 2 else ("▸ " if st == 1 else "·  ")
			var c := Color(0.55, 1.0, 0.59, 0.62) if st == 2 else (Color(1.0, 0.78, 0.35) if st == 1 else Color(0.82, 0.82, 0.80, 0.5))
			_txt(f, Vector2(x + 18, yy), pre + str(ln.t), fs, c)

## Закріплені цілі: маленький червоний квадратик сталого екранного розміру (бачать усі дрони).
func _draw_marked_squares(f: Font, cam: Camera3D) -> void:
	if main.targets == null:
		return
	for t: Dictionary in main.targets.marked_list():
		var wp: Vector3 = t.node.position + Vector3(0, 1.0 if t.kind == "soldier" else 1.8, 0)
		if cam.is_position_behind(wp):
			continue
		var sp := cam.unproject_position(wp)
		var half := 8.0 if t.kind == "soldier" else 11.0
		var r := Rect2(sp - Vector2(half, half), Vector2(half, half) * 2.0)
		draw_rect(r.grow(1.0), Color(0, 0, 0, 0.55), false, 3.5)     # тёмная подложка — читается на любом фоне
		draw_rect(r, MARK_RED, false, 1.6)
		draw_line(sp + Vector2(-3, 0), sp + Vector2(3, 0), MARK_RED, 1.0)   # центральная точка-крестик
		draw_line(sp + Vector2(0, -3), sp + Vector2(0, 3), MARK_RED, 1.0)


## Приціл розвідника (wing): перехрестя + кути зони захоплення того ж конуса, що й mark_at.
## Порожньо — білий; ціль у конусі — бурштиновий + підпис; уже закріплена — червоний.
func _draw_wing_reticle(f: Font, vp: Vector2, cam: Camera3D) -> void:
	var c := vp * 0.5
	var cone_deg := clampf(cam.fov * 0.12, 0.5, 5.0)                 # тот же порог, что в mark_at
	var tg: Dictionary = main.targets.best_in_cone(cam, cone_deg) if main.targets != null else {}
	var col := Color(0.95, 0.95, 0.95, 0.85)
	var label := ""
	if not tg.is_empty():
		var nm := {"tank": "ТАНК", "apc": "БТР", "soldier": "ПІХОТА"}
		var d := int(cam.global_position.distance_to(tg.node.position))
		if tg.get("marked", false):
			col = MARK_RED
			label = "ЦІЛЬ ЗАКРІПЛЕНА · %s · %d м" % [nm.get(tg.kind, "ЦІЛЬ"), d]
		else:
			col = Color(1.0, 0.65, 0.2, 0.95)
			label = "ЗАХОПЛЕННЯ: %s · %d м · ЛКМ" % [nm.get(tg.kind, "ЦІЛЬ"), d]
	# зона захоплення: половина стороны = проекция конуса на экран
	var r_px := clampf(tan(deg_to_rad(cone_deg)) / tan(deg_to_rad(cam.fov * 0.5)) * vp.y * 0.5, 26.0, vp.y * 0.42)
	for sgn: Vector2 in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:   # уголки рамки
		var corner: Vector2 = c + sgn * r_px
		draw_line(corner, corner - Vector2(sgn.x, 0) * r_px * 0.28, col, 2.0)
		draw_line(corner, corner - Vector2(0, sgn.y) * r_px * 0.28, col, 2.0)
	# перехрестя з центральним зазором
	for a: Vector2 in [Vector2(1, 0), Vector2(-1, 0), Vector2(0, 1), Vector2(0, -1)]:
		draw_line(c + a * 6.0, c + a * 18.0, col, 2.0)
	draw_circle(c, 1.5, col)
	if label != "":
		var w := f.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
		_txt(f, Vector2(c.x - w * 0.5, c.y + r_px + 24.0), label, 14, col)
	# службові показники оптики над зоною: зум зліва, висота справа
	var zoom := float(cam.get("wing_zoom"))
	var zs := "×%.0f%s" % [zoom, " цифр" if zoom > 30.5 else ""]
	_txt(f, Vector2(c.x - r_px, c.y - r_px - 10.0), zs, 13, col)
	var agl: float = cam.global_position.y - main.height_at(cam.global_position.x, cam.global_position.z)
	var agl_s := "AGL %d м" % int(agl)
	var aw := f.get_string_size(agl_s, HORIZONTAL_ALIGNMENT_LEFT, -1, 13).x
	_txt(f, Vector2(c.x + r_px - aw, c.y - r_px - 10.0), agl_s, 13, col)
	# загроза ППО: борт у радіусі вогню живої цілі — тримай висоту
	if main.targets != null:
		var th: Dictionary = main.targets.aa_threat(cam.global_position)
		if float(th.level) > 0.0:
			var hot := float(th.level) >= 1.0
			var ts := ("⚠ ПІД ОБСТРІЛОМ · %d м" if hot else "⚠ ЗОНА ППО · %d м — НАБЕРИ ВИСОТУ") % int(th.dist)
			var tw := f.get_string_size(ts, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x
			_txt(f, Vector2(c.x - tw * 0.5, c.y - r_px - 32.0), ts, 14,
				Color(1.0, 0.3, 0.2) if hot else Color(1.0, 0.62, 0.2))


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
	# --- атмосфера на линзе: конденсат (пробой точки росы) и морозная кромка (обледенение) ---
	var lfog := float(main.cam.get("lens_fog")) if main.cam.get("lens_fog") != null else 0.0
	var licv := float(main.cam.get("ice")) if main.cam.get("ice") != null else 0.0
	if lfog > 0.02:
		draw_rect(Rect2(Vector2.ZERO, vp), Color(0.86, 0.89, 0.92, 0.30 * lfog))
		for bi in 3:                                   # к краям гуще — как настоящий конденсат
			var bw := vp.x * (0.06 + bi * 0.05)
			var ba := 0.10 * lfog
			draw_rect(Rect2(0, 0, bw, vp.y), Color(0.88, 0.91, 0.94, ba))
			draw_rect(Rect2(vp.x - bw, 0, bw, vp.y), Color(0.88, 0.91, 0.94, ba))
			draw_rect(Rect2(0, 0, vp.x, bw * 0.6), Color(0.88, 0.91, 0.94, ba))
			draw_rect(Rect2(0, vp.y - bw * 0.6, vp.x, bw * 0.6), Color(0.88, 0.91, 0.94, ba))
	if licv > 0.02:
		for bi in 4:                                   # изморозь наползает с краёв кадра
			var iw := (26.0 + bi * 22.0) * licv
			var ia := (0.16 - bi * 0.03) * licv
			var icc := Color(0.82, 0.90, 1.0, ia)
			draw_rect(Rect2(0, 0, iw, vp.y), icc)
			draw_rect(Rect2(vp.x - iw, 0, iw, vp.y), icc)
			draw_rect(Rect2(0, 0, vp.x, iw * 0.7), icc)
			draw_rect(Rect2(0, vp.y - iw * 0.7, vp.x, iw * 0.7), icc)
	# --- карточка результатов вылета (после миссии; видна и в FPV) ---
	if main.mission != null and not main.mission.active and main.get("menu_open") != true \
			and not (main.mission.get("last_result") as Dictionary).is_empty():
		_draw_mission_result(f, vp, main.mission.last_result)
	# --- квест-панель зліва (місії 6-7): видно і в FPV — задачі потрібні на кожному борті ---
	if main.get("menu_open") != true:
		_draw_quest(f, vp)
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
			segs.append(["мітки %d" % main.targets.marked_list().size(), Color(1.0, 0.62, 0.2)])
		elif str(cam.get("drone_id")) == "mship":
			segs.append(["носій FPV", DIM])
		elif main.targets.weapon == 2:
			segs.append(["БЧ ⚠ ЗВЕДЕНА" if main.targets.armed else "БЧ знята", Color(1.0, 0.45, 0.35) if main.targets.armed else DIM])
		elif main.targets.weapon == 0:
			segs.append(["оск ×%d" % int(main.targets.ammo_frag), TXT])
		else:
			segs.append(["кум ×%d" % int(main.targets.ammo_heat), TXT])
	if cam.get("landed") == true:
		segs.append(["·", DIM]); segs.append(["на землі", DIM])
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

	# --- панель НСУ (все дроны): авиагоризонт, скорость, высота, курс, строка станции ---
	if main.get("menu_open") != true:
		_draw_marked_squares(f, cam)
		if str(cam.get("drone_id")) == "wing":
			_draw_wing_reticle(f, vp, cam)
		_draw_shark_panel(f, vp, cam, agl)

	# --- контекст: батарея ---
	if bat < 0.4:
		var col := Color(1.0, 0.55, 0.5) if bat < 0.2 else Color(1.0, 0.78, 0.55)
		_panel(Rect2(14, 48, 236, 44), 0.35, Color(col.r, col.g, col.b, 0.45))
		var blocks := ""
		for i in 5: blocks += "▮" if bat > (i + 0.5) / 5.0 else "▯"
		_txt(f, Vector2(24, 68), "БАТАРЕЯ %d %%   %s" % [int(bat * 100.0), blocks], 14, col)
		_txt(f, Vector2(24, 86), "сідай" if bat < 0.2 else "повертайся", 11, Color(col.r, col.g, col.b, 0.7))
	# --- контекст: канал / РЭБ / failsafe ---
	var jam_s := ""
	if main.get("ew") != null:
		var ji: Dictionary = main.ew.nearest_info(p)
		if not ji.is_empty() and float(ji.edge) < 0.0:
			jam_s = "РЕБ: придушення %d %%" % int(float(ji.jam) * 100.0)
	var fsafe: bool = cam.get("failsafe") == true
	if lq < 0.7 or jam_s != "" or fsafe:
		var col := Color(1.0, 0.5, 0.45) if (fsafe or lq < 0.3) else Color(1.0, 0.78, 0.47)
		_panel(Rect2(vp.x - 250, 14, 236, 44), 0.35, Color(col.r, col.g, col.b, 0.45))
		var bars := ""
		for i in 5: bars += "▂▃▅▆▇"[i] if lq > (i + 0.5) / 5.0 else " "
		_txt(f, Vector2(vp.x - 240, 34), ("✖ FAILSAFE" if fsafe else "КАНАЛ %d %%   %s" % [int(lq * 100.0), bars]), 14, col)
		var hint := jam_s if jam_s != "" else "повернись у пряму видимість або розгорни ретранслятор (H)"
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
			_txt(f, Vector2(20, vp.y - 40), "вітер %d м/с %s" % [int(w3.length()), main.hud._wind_arrow(w3)], 14, Color(0.8, 0.88, 1.0))
	_draw_toast(f, vp)


## Панель наземной станции SHARK (центр-низ, над строкой статуса, масштаб k):
## авиагоризонт (крен/тангаж), ВОЗД/ВЕРТ, AGL/MSL, компас с меткой подвеса,
## зум/метки/режим/сваливание + строка НСУ: дом (дальность и стрелка), ветер, время полёта, батарея.
func _draw_shark_panel(f: Font, vp: Vector2, cam: Camera3D, agl: float) -> void:
	# масштаб от высоты окна: ~втрое компактнее прежнего, одинаковая доля экрана в окне и фуллскрине
	var k := clampf(vp.y / 1333.0, 0.6, 1.4)
	var PW := 336.0 * k
	var PH := 252.0 * k
	var px := vp.x * 0.5 - PW * 0.5
	var py := vp.y - 60.0 - PH
	var acc := Color(0.55, 0.85, 1.0)
	var org := Color(1.0, 0.62, 0.2)
	_panel(Rect2(px, py, PW, PH), 0.5, Color(acc.r, acc.g, acc.b, 0.35))
	var is_wing := str(cam.get("drone_id")) == "wing"
	var dname := str(cam.drone_name()) if cam.has_method("drone_name") else "ДРОН"
	_txt(f, Vector2(px + 12 * k, py + 20 * k), "НСУ · %s" % dname.to_upper(), int(13 * k), acc)

	var roll: float
	var pitch: float
	var air: float
	if is_wing:
		roll = float(cam.get("_wing_roll"))
		pitch = float(cam.get("_wing_pitch"))
		air = float(cam.get("_wing_air"))
	else:
		# ориентация корпуса коптера: крен/тангаж из базиса body
		var b: Basis = cam.get("body") if cam.get("body") != null else cam.global_transform.basis
		var fwdv: Vector3 = -b.z
		pitch = asin(clampf(fwdv.y, -1.0, 1.0))
		roll = asin(clampf(b.x.y, -1.0, 1.0))
		air = float(cam.speed()) if cam.has_method("speed") else 0.0
	var auto_c: bool = cam.get("_wing_auto") == true
	var zoom := float(cam.get("wing_zoom"))
	var gyaw := float(cam.get("_gim_yaw"))

	# --- авиагоризонт: весь круг — небо, земля — сегмент ниже линии горизонта ---
	var c := Vector2(px + PW * 0.5, py + 106.0 * k)
	var R := 62.0 * k
	draw_circle(c, R + 3.0, Color(0, 0, 0, 0.55))
	draw_circle(c, R, Color(0.30, 0.52, 0.78, 0.9))
	var ppx := clampf(rad_to_deg(pitch) * 3.2 * k, -R * 0.72, R * 0.72)
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
	# шкала тангажа ±20°
	for pd in [-20, -10, 10, 20]:
		var lw := (14.0 if pd % 20 == 0 else 9.0) * k
		var l1 := rot * Vector2(-lw, ppx - pd * 3.2 * k)
		var l2 := rot * Vector2(lw, ppx - pd * 3.2 * k)
		if l1.length() < R - 8.0 * k and l2.length() < R - 8.0 * k:
			draw_line(c + l1, c + l2, Color(1, 1, 1, 0.6), 1.0)
	# маркер самолёта + индекс крена
	draw_line(c + Vector2(-22 * k, 0), c + Vector2(-7 * k, 0), org, 3.0)
	draw_line(c + Vector2(22 * k, 0), c + Vector2(7 * k, 0), org, 3.0)
	draw_circle(c, 2.5 * k, org)
	var rmk := c + Vector2(sin(-roll), -cos(-roll)) * (R - 5.0 * k)
	draw_circle(rmk, 3.0 * k, Color(1, 1, 1, 0.9))

	# --- лента скорости (слева) ---
	var sx := px + 14.0 * k
	_panel(Rect2(sx, py + 62 * k, 64 * k, 88 * k), 0.45)
	_txt(f, Vector2(sx + 6 * k, py + 78 * k), "ПОВІТР" if is_wing else "ШВИД", int(10 * k), DIM)
	var scol := TXT if (not is_wing or air >= 16.0) else Color(1.0, 0.5, 0.45)
	_txt(f, Vector2(sx + 6 * k, py + 102 * k), "%d" % int(air), int(24 * k), scol)
	_txt(f, Vector2(sx + 40 * k, py + 102 * k), "м/с", int(10 * k), DIM)
	_txt(f, Vector2(sx + 6 * k, py + 122 * k), "ВЕРТ", int(10 * k), DIM)
	var vcol := TXT if absf(_sh_vs) < 6.0 else Color(1.0, 0.78, 0.45)
	_txt(f, Vector2(sx + 6 * k, py + 142 * k), "%+.1f" % _sh_vs, int(15 * k), vcol)

	# --- высота (справа) ---
	var hx := px + PW - 78.0 * k
	_panel(Rect2(hx, py + 62 * k, 64 * k, 88 * k), 0.45)
	_txt(f, Vector2(hx + 6 * k, py + 78 * k), "AGL", int(10 * k), DIM)
	_txt(f, Vector2(hx + 6 * k, py + 102 * k), "%d" % int(agl), int(24 * k), TXT)
	_txt(f, Vector2(hx + 6 * k, py + 122 * k), "MSL", int(10 * k), DIM)
	_txt(f, Vector2(hx + 6 * k, py + 142 * k), "%d" % int(cam.global_position.y), int(15 * k), DIM)

	# --- компас-лента (верх) ---
	var fwd := -cam.global_transform.basis.z
	var hdg := fposmod(rad_to_deg(atan2(fwd.x, -fwd.z)), 360.0)
	var cy := py + 34.0 * k
	_panel(Rect2(px + 70 * k, py + 26 * k, PW - 140 * k, 18 * k), 0.45)
	var names := ["С", "СВ", "В", "ЮВ", "Ю", "ЮЗ", "З", "СЗ"]
	var px_per_deg := (PW - 150.0 * k) / 120.0
	for hh in range(0, 360, 15):
		var d := fposmod(float(hh) - hdg + 180.0, 360.0) - 180.0
		if absf(d) > 55.0:
			continue
		var xx: float = px + PW * 0.5 + d * px_per_deg
		if hh % 45 == 0:
			_txt(f, Vector2(xx - 5 * k, cy + 6 * k), names[hh / 45], int(11 * k), TXT)
		else:
			draw_line(Vector2(xx, cy - 4 * k), Vector2(xx, cy + 2 * k), DIM, 1.0)
	draw_line(Vector2(px + PW * 0.5, py + 26 * k), Vector2(px + PW * 0.5, py + 44 * k), org, 2.0)
	_txt(f, Vector2(px + PW * 0.5 + 6 * k, py + 40 * k), "%03d°" % int(hdg), int(11 * k), org)
	if absf(gyaw) > 0.05:
		var gx: float = px + PW * 0.5 + clampf(rad_to_deg(gyaw), -58.0, 58.0) * px_per_deg
		draw_circle(Vector2(gx, cy + 8 * k), 3.0 * k, acc)

	# --- строка 1: зум, метки, режим, сваливание ---
	var by := py + 168.0 * k
	if is_wing:
		_txt(f, Vector2(px + 14 * k, by), "ЗУМ ×%.0f" % zoom, int(13 * k), acc if zoom > 1.0 else DIM)
	elif str(cam.get("drone_id")) == "mship":
		_txt(f, Vector2(px + 14 * k, by), "НОСІЙ", int(13 * k), DIM)
	elif main.targets != null:
		var wshort: Array = ["ОСК", "КУМ", "БЧ", "ДРОБ"]
		var wi: int = main.targets.weapon
		if wi == 2:
			var armed: bool = main.targets.armed
			_txt(f, Vector2(px + 14 * k, by), "БЧ ЗВЕДЕНА" if armed else "БЧ знята", int(13 * k),
				Color(1.0, 0.45, 0.35) if armed else DIM)
		else:
			_txt(f, Vector2(px + 14 * k, by), "%s ×%d" % [wshort[clampi(wi, 0, 3)], main.targets.weapon_ammo()], int(13 * k), TXT)
	var mk: int = main.targets.marked_list().size() if main.targets != null else 0
	_txt(f, Vector2(px + 116 * k, by), "МІТКИ %d" % mk, int(13 * k), org if mk > 0 else DIM)
	var mode_txt: String
	var mcol := TXT
	if is_wing:
		mode_txt = "АВТО-НАБІР" if auto_c else "РУЧНЕ"
		if auto_c: mcol = Color(0.55, 1.0, 0.59)
	else:
		mode_txt = str(cam.mode_name()).split(" ")[0] if cam.has_method("mode_name") else "—"
	_txt(f, Vector2(px + 196 * k, by), mode_txt, int(13 * k), mcol)
	if is_wing and air < 15.0 and cam.get("landed") != true:
		if fmod(Time.get_ticks_msec() / 250.0, 2.0) < 1.0:
			_txt(f, Vector2(px + 276 * k, by), "ЗВАЛ!", int(13 * k), Color(1.0, 0.4, 0.35))

	# --- строка 2 (НСУ): дом · ветер · время полёта · батарея ---
	var by2 := py + 196.0 * k
	draw_line(Vector2(px + 12 * k, by2 - 18 * k), Vector2(px + PW - 12 * k, by2 - 18 * k), Color(1, 1, 1, 0.14), 1.0)
	var home: Vector3 = main._home_pos
	var dh := Vector2(home.x - cam.global_position.x, home.z - cam.global_position.z)
	var brg := fposmod(rad_to_deg(atan2(dh.x, -dh.y)), 360.0)          # азимут на дом
	var rel := fposmod(brg - hdg + 180.0, 360.0) - 180.0               # относительно носа
	var arrows := ["↑", "↗", "→", "↘", "↓", "↙", "←", "↖"]
	var arrow: String = arrows[int(round(fposmod(rel + 360.0, 360.0) / 45.0)) % 8]
	var dl := dh.length()
	var dist_s := ("%d км" % int(dl / 1000.0)) if dl > 9500.0 else (("%.1f км" % (dl / 1000.0)) if dl > 1000.0 else ("%d м" % int(dl)))
	_txt(f, Vector2(px + 14 * k, by2), "ДІМ %s %s" % [dist_s, arrow], int(12 * k), TXT)
	if main.weather != null:
		var w3: Vector3 = main.weather.wind_vec()
		var wcol := TXT if w3.length() < 8.0 else Color(1.0, 0.78, 0.45)
		_txt(f, Vector2(px + 98 * k, by2), "ВІТЕР %d м/с %s" % [int(w3.length()), main.hud._wind_arrow(w3)], int(12 * k), wcol)
	_txt(f, Vector2(px + 192 * k, by2), "ПОЛІТ %02d:%02d" % [int(_sh_flt) / 60, int(_sh_flt) % 60], int(12 * k), TXT)
	var bat := 1.0
	if main._fpv_osd != null:
		bat = float(main._fpv_osd.battery)
	var bcol := TXT if bat > 0.4 else (Color(1.0, 0.78, 0.55) if bat > 0.2 else Color(1.0, 0.5, 0.45))
	_txt(f, Vector2(px + 274 * k, by2), "БАТ %d%%" % int(bat * 100.0), int(12 * k), bcol)

	# --- строка 3 (атмосфера): T воздуха · точка росы · лёд · линза ---
	var by3 := py + 220.0 * k
	if main.weather != null and main.weather.has_method("air_temp"):
		var ta: float = main.weather.air_temp(cam.global_position.y)
		var dp: float = main.weather.dew_point(ta)
		var tcol := TXT if ta > 2.0 else Color(0.7, 0.85, 1.0)
		_txt(f, Vector2(px + 14 * k, by3), "T %+.0f°" % ta, int(12 * k), tcol)
		_txt(f, Vector2(px + 78 * k, by3), "РОСА %+.0f°" % dp, int(12 * k), DIM)
		var icev := float(cam.get("ice")) if cam.get("ice") != null else 0.0
		if icev > 0.01:
			var blink := fmod(Time.get_ticks_msec() / 350.0, 2.0) < 1.2
			if blink or icev < 0.3:
				_txt(f, Vector2(px + 168 * k, by3), "ЛІД %d%%" % int(icev * 100.0), int(12 * k),
					Color(1.0, 0.5, 0.45) if icev > 0.5 else Color(0.75, 0.88, 1.0))
		var lfv := float(cam.get("lens_fog")) if cam.get("lens_fog") != null else 0.0
		if lfv > 0.1:
			_txt(f, Vector2(px + 246 * k, by3), "ЛІНЗА ✻", int(12 * k), Color(0.85, 0.9, 0.95))


## Карточка разбора вылета: оценка, метрики, штрафы — «тренажёрный» экран результатов.
func _draw_mission_result(f: Font, vp: Vector2, r: Dictionary) -> void:
	var k := clampf(vp.y / 1000.0, 0.8, 1.5)
	var W := 460.0 * k
	var H := 330.0 * k
	var px := vp.x * 0.5 - W * 0.5
	var py := vp.y * 0.5 - H * 0.5 - 40.0 * k
	var ok: bool = bool(r.get("success", false))
	var accent := Color(0.55, 1.0, 0.59) if ok else Color(1.0, 0.45, 0.4)
	_panel(Rect2(px, py, W, H), 0.72, Color(accent.r, accent.g, accent.b, 0.55))
	draw_rect(Rect2(px, py, W, 42 * k), Color(accent.r, accent.g, accent.b, 0.16))
	_txt(f, Vector2(px + 18 * k, py + 28 * k), str(r.get("mission", "")), int(17 * k), TXT)
	_txt(f, Vector2(px + 18 * k, py + 74 * k), "ВИКОНАНО" if ok else "ПРОВАЛ", int(22 * k), accent)
	# оценка крупно справа
	var sc := "%d" % int(r.get("score", 0))
	var scw := f.get_string_size(sc, HORIZONTAL_ALIGNMENT_LEFT, -1, int(52 * k)).x
	_txt(f, Vector2(px + W - scw - 60 * k, py + 86 * k), sc, int(52 * k), accent)
	_txt(f, Vector2(px + W - 52 * k, py + 86 * k), "/100", int(16 * k), DIM)
	# метрики
	var rows := [
		["Час", "%.0f с  (норматив %.0f)" % [float(r.get("time_s", 0)), float(r.get("par_s", 0))]],
		["Дрон · режим", "%s · %s" % [str(r.get("drone", "")), str(r.get("mode", ""))]],
		["Середня висота", "%.0f м AGL" % float(r.get("avg_agl_m", 0))],
		["Макс. швидкість", "%.0f м/с" % float(r.get("max_speed_ms", 0))],
	]
	var ry := py + 116.0 * k
	for row in rows:
		_txt(f, Vector2(px + 18 * k, ry), str(row[0]), int(13 * k), DIM)
		_txt(f, Vector2(px + 175 * k, ry), str(row[1]), int(13 * k), TXT)
		ry += 24.0 * k
	# разбор штрафов
	draw_line(Vector2(px + 14 * k, ry - 8 * k), Vector2(px + W - 14 * k, ry - 8 * k), Color(1, 1, 1, 0.14), 1.0)
	_txt(f, Vector2(px + 18 * k, ry + 12 * k), "РОЗБІР", int(12 * k), DIM)
	ry += 32.0 * k
	var pens := []
	if int(r.get("pen_crash", 0)) > 0:
		pens.append(["зіткнення ×%d" % int(r.get("crashes", 0)), -int(r.get("pen_crash", 0))])
	if int(r.get("pen_gates", 0)) > 0:
		pens.append(["пропущені ворота ×%d" % int(r.get("gates_missed", 0)), -int(r.get("pen_gates", 0))])
	if int(r.get("pen_time", 0)) > 0:
		pens.append(["перевищення нормативу", -int(r.get("pen_time", 0))])
	if pens.is_empty():
		_txt(f, Vector2(px + 18 * k, ry), "чистий виліт — без штрафів", int(13 * k), Color(0.55, 1.0, 0.59))
		ry += 24.0 * k
	else:
		for pn in pens:
			_txt(f, Vector2(px + 18 * k, ry), str(pn[0]), int(13 * k), TXT)
			_txt(f, Vector2(px + W - 70 * k, ry), "%d" % int(pn[1]), int(13 * k), Color(1.0, 0.6, 0.45))
			ry += 22.0 * k
	_txt(f, Vector2(px + 18 * k, py + H - 14 * k), "N — наступна місія · R — повторити · Esc — меню", int(12 * k), DIM)


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
