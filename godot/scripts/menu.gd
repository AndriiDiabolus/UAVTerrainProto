extends CanvasLayer
## Главное меню (вариант «боковая панель»): тёмная панель слева, за ней ЖИВОЙ мир —
## камера медленно облетает село. Управление: ↑↓ — пункт, ←→ — значение, Enter — выбрать, Esc — закрыть.
## Пункты: Полёт · Миссия · Реплей · Регион · Дрон · Камера · Погода · Качество · Выход.
## Смена региона перезагружает сцену (выбор хранится в user://settings.cfg).

var main: Node3D
var open := false
var sel := 0
var mission_pick := 1
var replay_pick := 0
var replay_files: PackedStringArray = []
var _orbit_t := 0.0
var _panel: Control
const ITEMS := ["полёт", "миссия", "реплей", "регион", "деревья", "дрон", "скин", "оружие", "камера", "пульт", "рейты", "погода", "качество", "выход"]
const ACC := Color(1.0, 0.78, 0.35)
const TXT := Color(0.92, 0.92, 0.9)
const DIM := Color(0.78, 0.78, 0.76, 0.8)


func setup(m: Node3D) -> void:
	main = m
	layer = 20
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.draw.connect(_draw_panel)
	add_child(_panel)
	_refresh_replays()
	var args := OS.get_cmdline_user_args()
	var auto := true
	for a in args:
		for f in ["--screenshot", "--bench", "--selftest", "--flytest", "--missiontest", "--coltest", "--replay", "--mission", "--targetreport", "--nomenu", "--fxshot", "--animshot", "--resultshot"]:
			if a.begins_with(f):
				auto = false
	if "--menushot" in args:
		auto = true                              # скрин меню (вертушка дрона) при --screenshot
	set_open(auto)


func _refresh_replays() -> void:
	replay_files = []
	var d := DirAccess.open("user://flights")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".csv"):
				replay_files.append(f)
		replay_files.reverse()
	replay_pick = 0


func set_open(v: bool) -> void:
	open = v
	main.menu_open = v
	_panel.visible = v
	if v:
		if main.hud != null and main.hud.fpv_on:
			main.hud._toggle_fpv()
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
		if main.cam != null:
			main.cam.mouse_captured = false
		_refresh_replays()
	if main.hud != null and main.hud._min != null:
		main.hud._min.visible = not v


func _process(dt: float) -> void:
	if not open or main == null or main.cam == null:
		return
	# кинематографичный облёт села вокруг точки старта
	_orbit_t += dt * 0.03
	var c: Vector3 = main._home_pos
	var r := 420.0
	var pos := Vector3(c.x + cos(_orbit_t) * r, 0.0, c.z + sin(_orbit_t) * r)
	pos.y = maxf(main.height_at(pos.x, pos.z) + 60.0, main.height_at(c.x, c.z) + 150.0)
	main.cam.global_position = pos
	var look := Vector3(c.x, main.height_at(c.x, c.z) + 20.0, c.z)
	main.cam.look_at(look, Vector3.UP)
	if main.cam.get("body") != null:
		main.cam.body = main.cam.global_transform.basis
	_panel.queue_redraw()


func _input(event: InputEvent) -> void:
	if not open:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		var kc: int = event.physical_keycode if event.physical_keycode != 0 else event.keycode
		if main.rc != null and main.rc.wizard_active:
			if kc == KEY_ESCAPE:
				main.rc.wizard_cancel()
			get_viewport().set_input_as_handled()
			return
		match kc:
			KEY_ESCAPE: _start_flight(false)
			KEY_UP: sel = posmod(sel - 1, ITEMS.size())
			KEY_DOWN: sel = posmod(sel + 1, ITEMS.size())
			KEY_LEFT: _adjust(-1)
			KEY_RIGHT: _adjust(1)
			KEY_ENTER, KEY_KP_ENTER, KEY_SPACE: _activate()
			KEY_M:
				if main.hud != null:
					main.hud._toggle_sound()     # звук можно глушить не выходя из меню
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0:
		# драг ЛКМ — вращение модели дрона на витрине по всем осям
		if main.get("droneview") != null:
			main.droneview.orbit(event.relative)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		get_viewport().set_input_as_handled()


func _adjust(dir: int) -> void:
	match ITEMS[sel]:
		"миссия": mission_pick = clampi(mission_pick + dir, 1, 5)
		"реплей":
			if not replay_files.is_empty():
				replay_pick = posmod(replay_pick + dir, replay_files.size())
		"регион":
			_switch_region()
		"деревья":
			_switch_trees()
		"дрон": main.cam.cycle_drone()
		"скин":
			if main.get("droneview") != null:
				main.droneview.set_skin(main.droneview.skin + dir)
		"оружие":
			if main.targets != null:
				main.targets.cycle_weapon(dir)
		"камера":
			if main.hud.fpv_link != null:
				main.hud.fpv_link.set_camera(main.hud.fpv_link.camera + dir)
		"пульт":
			main.rc.wizard_start()
		"рейты":
			main.rc.cycle_preset(dir)
		"погода": main.weather.apply(int(main.weather.idx) + dir)
		"качество":
			main._quality_from_flag = false
			main.apply_quality(posmod(main.quality + dir, 3))


func _activate() -> void:
	match ITEMS[sel]:
		"полёт": _start_flight(true)
		"миссия":
			set_open(false)
			main.mission.start(mission_pick)
		"реплей":
			if not replay_files.is_empty():
				set_open(false)
				main.telemetry.start_replay("user://flights/" + replay_files[replay_pick])
		"регион": _switch_region()
		"деревья": _switch_trees()
		"дрон": main.cam.cycle_drone()
		"скин":
			if main.get("droneview") != null:
				main.droneview.set_skin(main.droneview.skin + 1)
		"оружие":
			if main.targets != null:
				main.targets.cycle_weapon(1)
		"камера":
			if main.hud.fpv_link != null:
				main.hud.fpv_link.set_camera(main.hud.fpv_link.camera + 1)
		"пульт":
			main.rc.wizard_start()
		"рейты":
			main.rc.cycle_preset(1)
		"погода": main.weather.apply(int(main.weather.idx) + 1)
		"качество":
			main._quality_from_flag = false
			main.apply_quality((main.quality + 1) % 3)
		"выход": main.get_tree().quit()


func _start_flight(reset: bool) -> void:
	set_open(false)
	if main.telemetry != null and main.telemetry.replaying:
		main.telemetry.stop_replay()
	if reset and main.cam.has_method("reset"):
		main.crashed = false
		main.drone_dmg = 0.0
		main.cam.global_position = main._home_pos + Vector3(0, 0.1, 0)
		main.cam.reset()


## Переключение версии деревьев: 1 — процедурные, 2 — Meshy-герои + фото-кроны. Перезагружает сцену.
func _switch_trees() -> void:
	var next := 1 if int(main.trees_ver) == 2 else 2
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("game", "trees", next)
	cfg.save("user://settings.cfg")
	main.get_tree().reload_current_scene()


func _switch_region() -> void:
	var cur: String = "carpathians" if main.region == "" else main.region
	var next := "steppe" if cur != "steppe" else ""
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("game", "region", next)
	cfg.save("user://settings.cfg")
	main.get_tree().reload_current_scene()


func _draw_panel() -> void:
	var d := _panel
	var vp := d.get_viewport_rect().size
	var f := d.get_theme_default_font()
	d.draw_rect(Rect2(0, 0, 434, vp.y), Color(0.03, 0.04, 0.055, 0.86))
	d.draw_line(Vector2(434, 0), Vector2(434, vp.y), Color(1, 1, 1, 0.12), 1.0)
	d.draw_string(f, Vector2(40, 78), "UAV TERRAIN", HORIZONTAL_ALIGNMENT_LEFT, -1, 42, TXT)
	d.draw_string(f, Vector2(41, 104), "тренажёр оператора БпЛА · реальный рельеф", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, DIM)
	var vals := {
		"полёт": "",
		"миссия": "%d · %s" % [mission_pick, str(main.mission.MISSIONS[mission_pick]["name"]).split("· ")[1] if main.mission != null else ""],
		"реплей": (replay_files[replay_pick].trim_prefix("flight_").trim_suffix(".csv") if not replay_files.is_empty() else "нет записей"),
		"регион": ("степь" if main.region == "steppe" else "Карпаты"),
		"деревья": ("версия 2 · Meshy" if int(main.trees_ver) == 2 else "версия 1 · классика"),
		"дрон": ("%s · зум ×30" % str(main.cam.drone_name())) if str(main.cam.get("drone_id")) == "wing" \
			else "%s · T/W %.1f" % [str(main.cam.drone_name()), float(main.cam.P["tw"])],
		"скин": (str(main.droneview.skin_name()) if main.get("droneview") != null else "—"),
		"оружие": ("— разведчик" if str(main.cam.get("drone_id")) == "wing" else ("%s ×%d" % [main.targets.WEAPONS[main.targets.weapon], main.targets.weapon_ammo()]) + (" · для FPV" if str(main.cam.get("drone_id")) == "mship" else "")) if main.targets != null else "—",
		"камера": (main.hud.fpv_link.camera_name() if main.hud != null and main.hud.fpv_link != null else "—"),
		"пульт": (("настроен · " + str(main.rc.joy_name()).left(18)) if main.rc.configured else
			(("найден: " + str(main.rc.joy_name()).left(14) + " — Enter") if main.rc.joy_name() != "" else "не подключен")),
		"рейты": str(main.rc.rates_label()),
		"погода": str(main.weather.label) if main.weather != null else "—",
		"качество": main.QUALITY_NAMES[main.quality],
		"выход": "",
	}
	var icons := {"полёт": "▶", "миссия": "◎", "реплей": "↺", "регион": "🗺", "деревья": "🌳", "дрон": "🛠", "скин": "🎨", "оружие": "✚", "камера": "📷", "пульт": "🎛", "рейты": "📈", "погода": "☀", "качество": "⚙", "выход": "⏻"}
	var y := 170.0
	for i in ITEMS.size():
		var it: String = ITEMS[i]
		var selc := i == sel
		if selc:
			d.draw_rect(Rect2(22, y - 24, 390, 36), Color(ACC.r, ACC.g, ACC.b, 0.15))
			d.draw_rect(Rect2(22, y - 24, 390, 36), Color(ACC.r, ACC.g, ACC.b, 0.7), false, 1.5)
		var name := it.capitalize()
		d.draw_string(f, Vector2(40, y), icons[it] + "  " + name, HORIZONTAL_ALIGNMENT_LEFT, -1, 20, ACC if selc else TXT)
		var v: String = vals[it]
		if v != "":
			var arrows := ("◂ %s ▸" % v) if selc and it != "полёт" else v
			d.draw_string(f, Vector2(408 - f.get_string_size(arrows, HORIZONTAL_ALIGNMENT_LEFT, -1, 14).x, y), arrows, HORIZONTAL_ALIGNMENT_LEFT, -1, 14, ACC if selc else DIM)
		y += 50.0
	d.draw_string(f, Vector2(40, y + 6), "↑↓ пункт · ◂▸ значение · Enter — выбрать · Esc — продолжить", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, DIM)
	# оверлей мастера калибровки пульта
	if main.rc != null and main.rc.wizard_active:
		var cw := 640.0; var chh := 130.0
		var cx := (vp.x - cw) * 0.5; var cyy := (vp.y - chh) * 0.5
		d.draw_rect(Rect2(cx, cyy, cw, chh), Color(0.03, 0.05, 0.08, 0.94))
		d.draw_rect(Rect2(cx, cyy, cw, chh), Color(0.55, 0.85, 1.0, 0.8), false, 2.0)
		d.draw_string(f, Vector2(cx + 24, cyy + 36), "НАСТРОЙКА ПУЛЬТА  ·  шаг %d/4" % maxi(main.rc.wizard_step + 1, 1), HORIZONTAL_ALIGNMENT_LEFT, -1, 20, Color(0.55, 0.85, 1.0))
		d.draw_string(f, Vector2(cx + 24, cyy + 72), str(main.rc.wizard_hint), HORIZONTAL_ALIGNMENT_LEFT, -1, 18, TXT)
		d.draw_string(f, Vector2(cx + 24, cyy + 104), "Esc — отмена", HORIZONTAL_ALIGNMENT_LEFT, -1, 13, DIM)
	# памятка справа внизу
	var px := vp.x - 560.0; var py := vp.y - 324.0
	d.draw_rect(Rect2(px, py, 520, 286), Color(0.03, 0.04, 0.055, 0.72))
	d.draw_rect(Rect2(px, py, 520, 286), Color(1, 1, 1, 0.14), false, 1.0)
	d.draw_string(f, Vector2(px + 20, py + 26), "ПАМЯТКА  (в игре — удерживай I)", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, TXT)
	var rows := [["W/S · A/D · E/Q", "тангаж · крен · газ"], ["мышь / ←→", "рыскание (в GPS — обзор)"],
		["Tab · B · C", "режим · дрон · камера"], ["U", "вид с борта ⇄ третье лицо"],
		["F · T · Y", "FPV-очки · тепловизор · палитра"],
		["ЛКМ", "захват мыши / сброс боеприпаса"], ["N", "следующая миссия"],
		["V · H · J", "оружие · ретранслятор · матка"],
		["1–5, 8 · 6 · 7", "погода · туман · дождь"], ["G · M", "качество · звук"], ["R · Esc", "рестарт · меню"]]
	var yy := py + 52.0
	for r in rows:
		d.draw_rect(Rect2(px + 20, yy - 14, f.get_string_size(r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 12).x + 12, 20), Color(1, 1, 1, 0.1))
		d.draw_string(f, Vector2(px + 26, yy), r[0], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, TXT)
		d.draw_string(f, Vector2(px + 210, yy), r[1], HORIZONTAL_ALIGNMENT_LEFT, -1, 13, DIM)
		yy += 23.0
