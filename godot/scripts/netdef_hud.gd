extends Control
## HUD полигона «сетевой заслон»: конфигурация рубежа, живая статистика перехватов,
## план-схема сверху и лог исходов. Все числа берутся из netdef_model — HUD ничего не считает сам.

const M := preload("res://scripts/netdef_model.gd")

var nd: Node3D                     # netdef.gd
const TXT := Color(0.92, 0.92, 0.90, 0.95)
const DIM := Color(0.80, 0.80, 0.78, 0.70)
const OUT := Color(0, 0, 0, 0.65)
const OK_C := Color(0.52, 1.0, 0.58)
const BAD_C := Color(1.0, 0.46, 0.38)
const WARN_C := Color(1.0, 0.82, 0.42)
const NET_C := Color(0.62, 0.86, 1.0)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _process(dt: float) -> void:
	if nd != null:
		for l_v: Variant in nd.log_lines:
			var l: Dictionary = l_v
			l["t"] = float(l["t"]) - dt
	queue_redraw()


func _txt(f: Font, pos: Vector2, s: String, size: int, col: Color = TXT) -> void:
	draw_string_outline(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, 2, OUT)
	draw_string(f, pos, s, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


func _panel(r: Rect2, a := 0.46) -> void:
	draw_rect(r, Color(0, 0, 0, a))
	draw_rect(r, Color(1, 1, 1, 0.10), false, 1.0)


func _draw() -> void:
	if nd == null or nd.main == null or nd.bar.is_empty():
		return
	var vp := get_viewport_rect().size
	var k: float = clampf(vp.y / 900.0, 0.65, 1.6)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
	var w: float = vp.x / k
	var f := get_theme_default_font()
	_draw_config(f)
	_draw_stats(f, w)
	_draw_plan(f, w)
	_draw_log(f, vp.y / k)
	_draw_keys(f, w, vp.y / k)


## Левая панель: из чего состоит заслон и что с ним делает ветер.
func _draw_config(f: Font) -> void:
	var bar: Dictionary = nd.bar
	var net: Dictionary = bar["net"]
	var ws := M.wind_state(bar, nd.wind)
	var lines: Array = []
	lines.append(["ЗАСЛІН", str(nd.scen()["name"]), NET_C])
	lines.append(["рубіж", "%.0f м · полотно %.0f…%.0f м" % [bar["r_stand"], bar["h_bot"], bar["h_top"]], TXT])
	lines.append(["носій", "%s × %d (запас ×%.1f)" % [bar["carrier"]["name"], bar["carriers_n"], bar["reserve"]],
		TXT if bool(bar["lift_ok"]) else BAD_C])
	lines.append(["полотно", "вічко %.2f м · %.1f мм %s · %.0f кг/секцію"
		% [net["cell"], net["d"], net["mat"], bar["net_mass_seg"]], TXT])
	lines.append(["поглинач", "%s · %.0f кДж" % [bar["absorber"]["name"], float(bar["e_abs"]) * 0.001], TXT])
	var wcol: Color = BAD_C if bool(ws["down"]) else (WARN_C if float(ws["h_eff"]) < float(bar["h_top"]) * 0.75 else OK_C)
	lines.append(["вітер", "%.0f м/с → кромка %.0f м (нахил %.0f°), анкери %.0f кН"
		% [nd.wind, ws["h_eff"], ws["tilt_deg"], ws["anchor_kn"]], wcol])
	var th: Dictionary = M.THREATS[nd.threat_id()]
	lines.append(["ЗАГРОЗА", "%s · %.0f кг · БЧ %.0f кг · %.0f м/с" % [th["short"], th["mass"], th["wh"], th["v"]], WARN_C])
	lines.append(["профіль", "%s · розмах %.1f м · %s" % [M.PROFILES[str(th["prof"])]["name"], th["span"],
		"вічко тримає" if float(th["span"]) > float(net["cell"]) else "менше вічка!"], DIM])
	var h := 20.0 + float(lines.size()) * 17.0
	_panel(Rect2(12, 12, 430, h))
	var y := 32.0
	for l_v: Variant in lines:
		var l: Array = l_v
		_txt(f, Vector2(22, y), str(l[0]), 12, DIM)
		_txt(f, Vector2(112, y), str(l[1]), 13, l[2])
		y += 17.0


## Правая панель: накопленная статистика полигона.
func _draw_stats(f: Font, w: float) -> void:
	var x := w - 372.0
	var n: int = nd.shots
	_panel(Rect2(x, 12, 360, 132))
	_txt(f, Vector2(x + 10, 32), "РЕЗУЛЬТАТИ ПОЛІГОНУ", 13, NET_C)
	if n == 0:
		_txt(f, Vector2(x + 10, 54), "Z — запустити хвилю загроз", 13, DIM)
		return
	var p_stop := float(nd.stopped) / float(n) * 100.0
	var p_kill := float(nd.site_killed) / float(n) * 100.0
	_txt(f, Vector2(x + 10, 54), "спроб: %d" % n, 13, TXT)
	_txt(f, Vector2(x + 120, 54), "затримано: %.0f %%" % p_stop, 14, OK_C if p_stop > 60.0 else WARN_C)
	_txt(f, Vector2(x + 10, 74), "об'єкт вибув з ладу: %.0f %%" % p_kill, 14, BAD_C if p_kill > 30.0 else OK_C)
	# полоса-индикатор
	var bw := 340.0
	draw_rect(Rect2(x + 10, 84, bw, 7), Color(0.25, 0.25, 0.25, 0.8))
	draw_rect(Rect2(x + 10, 84, bw * clampf(p_stop / 100.0, 0.0, 1.0), 7), OK_C)
	var y := 108.0
	var keys: Array = nd.stats.keys()
	keys.sort_custom(func(a, b): return int(nd.stats[a]) > int(nd.stats[b]))
	var shown := 0
	for kk_v: Variant in keys:
		if shown >= 2:
			break
		var kk := str(kk_v)
		_txt(f, Vector2(x + 10, y), "%s — %d" % [M.outcome_name(kk), int(nd.stats[kk])], 12, DIM)
		y += 16.0
		shown += 1


## План-схема сверху: объект, кольцо заслона, летящие изделия.
func _draw_plan(f: Font, w: float) -> void:
	var bar: Dictionary = nd.bar
	var size := 178.0
	var org := Vector2(w - 372.0 + 182.0, 156.0 + size * 0.5)
	var rect := Rect2(org.x - size * 0.5, org.y - size * 0.5, size, size)
	_panel(rect, 0.5)
	var r_m: float = float(bar["r_stand"])
	var sc: float = (size * 0.42) / maxf(r_m + 120.0, 1.0)
	# кольцо заслона
	var pts: PackedVector2Array = PackedVector2Array()
	var arc: float = deg_to_rad(float(bar["arc_deg"]))
	var n := 48
	for i in n + 1:
		var a := -arc * 0.5 + arc * float(i) / float(n)
		pts.append(org + Vector2(cos(a), sin(a)) * r_m * sc)
	draw_polyline(pts, NET_C, 2.0)
	# объект
	var site_r: float = float(M.SITES[str(nd.scen()["site"])]["radius"])
	draw_circle(org, maxf(site_r * sc, 3.0), Color(1.0, 0.65, 0.25, 0.85))
	# летящие изделия
	for t_v: Variant in nd.live:
		var t: Dictionary = t_v
		var node: Node3D = t["node"]
		if not is_instance_valid(node):
			continue
		var d := Vector2(node.position.x - nd.site_pos.x, node.position.z - nd.site_pos.z) * sc
		if d.length() > size * 0.47:
			d = d.normalized() * size * 0.47
		var col: Color = BAD_C
		match str(t["state"]):
			"decel", "hang": col = OK_C
			"fall": col = WARN_C
		draw_rect(Rect2(org + d - Vector2(2.5, 2.5), Vector2(5, 5)), col)
	_txt(f, Vector2(rect.position.x + 6, rect.position.y + 14), "%.0f м" % r_m, 11, DIM)


func _draw_log(f: Font, h: float) -> void:
	var y := h - 210.0
	_panel(Rect2(12, y - 18, 560, 186), 0.42)
	_txt(f, Vector2(22, y), "ЖУРНАЛ ПЕРЕХОПЛЕНЬ", 12, NET_C)
	y += 20.0
	for l_v: Variant in nd.log_lines:
		var l: Dictionary = l_v
		var fresh: float = clampf(float(l["t"]) / 6.0, 0.25, 1.0)
		var col: Color = BAD_C if bool(l["crit"]) else OK_C
		col.a = fresh
		_txt(f, Vector2(22, y), "%-9s %s" % [str(l["kind"]), M.outcome_name(str(l["oc"]))], 13, col)
		_txt(f, Vector2(300, y), "%.0f кДж · %.0f g" % [l["e"], l["ng"]], 12, Color(DIM.r, DIM.g, DIM.b, fresh))
		y += 17.0
		_txt(f, Vector2(34, y), str(l["note"]), 11, Color(DIM.r, DIM.g, DIM.b, fresh * 0.85))
		y += 17.0


func _draw_keys(f: Font, w: float, h: float) -> void:
	var s := "Z хвиля · U загроза · O конфігурація · K вітер · [ ] рубіж · L сповільнення · X полотно"
	_txt(f, Vector2(w * 0.5 - 300.0, h - 14.0), s, 12, DIM)
