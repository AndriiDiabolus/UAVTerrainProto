extends CanvasLayer
## Головне меню: п'ять екранів поверх живого світу (камера облітає точку старту).
##   ТИТУЛ (кіно-мінімал)  → Почати/Продовжити · Місії · Ангар · Реплеї · Налаштування · Вихід
##   МІСІЇ (брифінг)       → супутникова карта з маршрутом місії (той самий розрахунок, що в mission.start) + завдання
##   АНГАР                 → модель борту в окремому SubViewport, ТТХ, спорядження, вибір борту
##   НАЛАШТУВАННЯ, РЕПЛЕЇ  → решта пунктів старого меню
## Малюється в дизайн-просторі 1600×900 (висота фіксована, ширина тягнеться) через draw_set_transform.
## Клавіатура + миша: зони кліку збираються під час малювання (_hits).
## Esc: з підекрана — назад на титул, з титулу — вихід із гри.

var main: Node3D
var open := false
var _panel: Control
var _orbit_t := 0.0

enum Screen { TITLE, MISSIONS, HANGAR, SETTINGS, REPLAYS }
var screen := Screen.TITLE
var title_sel := 0
var mission_pick := 1
var hangar_row := 0          # 0 — борт, 1..4 — слоти спорядження
var settings_sel := 0
var replay_pick := 0
var replay_files: PackedStringArray = []
var _started := false         # гравець уже злітав у цій сесії → «Продовжити»
var _flight_yaw := 0.0        # курс борту на момент відкриття меню — для плану місії

var _hits: Array = []         # [{r: Rect2 (дизайн-простір), a: String, i: int}]
var _k := 1.0                 # масштаб дизайн-простору → екран
var _W := 1600.0              # ширина дизайн-простору (залежить від пропорцій вікна)
var _mouse := Vector2(-1, -1)
var _plans := {}              # id → план місії для карти брифінгу
var _plans_home := Vector3.INF
var _stats := {}              # id → {best, done}

const TITLE_ITEMS := ["play", "missions", "hangar", "replays", "settings", "exit"]
const SETTINGS_ITEMS := ["region", "weather", "quality", "trees", "sound", "rc", "rates"]
const HANGAR := [
	{"id": "wing", "t": "SHARK", "s": "розвідник · зум ×60", "cls": "РОЗВІДНИК · КРИЛО", "sub": "КРИЛО · РОЗМАХ 3.4 м",
	 "desc": "Крило для розвідки з висоти 800 м: гімбал із зумом до ×60, автозахоплення й закріплення цілей для всієї групи."},
	{"id": "mship", "t": "МАТКА", "s": "носій · ретранслятор", "cls": "НОСІЙ · РЕТРАНСЛЯТОР", "sub": "ГЕКСАКОПТЕР-НОСІЙ",
	 "desc": "Важкий гексакоптер: доносить FPV до рубежу зі свіжою батареєю і лишається висіти як ретранслятор каналу."},
	{"id": "fpv7", "t": "FPV 7″", "s": "ударний", "cls": "УДАРНИЙ FPV · КАМІКАДЗЕ", "sub": "CHIMERA-КЛАС · 7 ДЮЙМІВ",
	 "desc": "Основний борт ударних місій. Несе скид або бойову частину, працює з автодоводом на закріплену ціль."},
	{"id": "fpv5", "t": "FPV 5″", "s": "швидкий · ACRO", "cls": "ШВИДКИЙ FPV", "sub": "ГОНОЧНИЙ · 5 ДЮЙМІВ",
	 "desc": "Легкий і дуже спритний: максимальна кутова швидкість, для перехоплення і вправ ACRO."},
	{"id": "mavic", "t": "MAVIC-КЛАС", "s": "спостереження", "cls": "КВАДРОКОПТЕР СПОСТЕРЕЖЕННЯ", "sub": "СКЛАДНИЙ КВАДРОКОПТЕР",
	 "desc": "Стабільний спостерігач із GPS-утриманням: коригування, огляд, навчання новачків."},
]

# палітра
const BG := Color(0.043, 0.055, 0.047)
const INK := Color(0.894, 0.914, 0.886)
const DIMC := Color(0.62, 0.66, 0.62)
const MUTE := Color(0.43, 0.47, 0.42)
const LINE := Color(1, 1, 1, 0.08)
const AMBER := Color(0.94, 0.67, 0.24)
const RED := Color(0.85, 0.36, 0.26)
const GREEN := Color(0.56, 0.84, 0.58)
const ORANGE := Color(1.0, 0.42, 0.17)
const WARM := Color(1.0, 0.70, 0.48)


func setup(m: Node3D) -> void:
	main = m
	layer = 20
	_panel = Control.new()
	_panel.set_anchors_preset(Control.PRESET_FULL_RECT)
	_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS   # супутникова підкладка без «цеглинок»
	_panel.draw.connect(_draw_panel)
	add_child(_panel)
	_refresh_replays()
	_load_stats()
	var args := OS.get_cmdline_user_args()
	var auto := true
	for a in args:
		for f in ["--screenshot", "--bench", "--selftest", "--flytest", "--missiontest", "--coltest", "--replay", "--mission", "--targetreport", "--nomenu", "--fxshot", "--animshot", "--resultshot", "--menutest"]:
			if a.begins_with(f):
				auto = false
	if "--menushot" in args:
		auto = true                              # скрин меню при --screenshot
	for a in args:                              # --menuscreen=missions|hangar|settings|replays, --menumission=N — для скрин-перевірки
		if a.begins_with("--menumission="):
			mission_pick = int(a.substr(14))
		if a.begins_with("--menuscreen="):
			screen = {"missions": Screen.MISSIONS, "hangar": Screen.HANGAR, "settings": Screen.SETTINGS,
				"replays": Screen.REPLAYS}.get(a.substr(13), Screen.TITLE)
	set_open(auto)


func _refresh_replays() -> void:
	replay_files = []
	var d := DirAccess.open("user://flights")
	if d != null:
		for f in d.get_files():
			if f.ends_with(".csv"):
				replay_files.append(f)
		replay_files.sort()
		replay_files.reverse()
	replay_pick = clampi(replay_pick, 0, maxi(replay_files.size() - 1, 0))


## Кращі результати з user://results/results.csv (id місії — число перед « · » у назві).
func _load_stats() -> void:
	_stats = {}
	var f := FileAccess.open("user://results/results.csv", FileAccess.READ)
	if f == null:
		return
	var head := f.get_csv_line()
	var ci_m := head.find("mission"); var ci_s := head.find("success"); var ci_sc := head.find("score")
	if ci_m < 0 or ci_sc < 0:
		return
	while not f.eof_reached():
		var row := f.get_csv_line()
		if row.size() <= maxi(ci_m, ci_sc):
			continue
		var idp := row[ci_m].split(" ·")[0].strip_edges()
		if not idp.is_valid_int():
			continue
		var id := int(idp)
		var ok := ci_s >= 0 and row[ci_s].to_lower() == "true"
		var sc := int(row[ci_sc])
		var cur: Dictionary = _stats.get(id, {"best": -1, "done": false})
		if ok:
			cur["done"] = true
			cur["best"] = maxi(int(cur["best"]), sc)
		_stats[id] = cur


func set_open(v: bool) -> void:
	if v and not open and main.cam != null and main.cam.has_method("attitude"):
		_flight_yaw = main.cam.attitude().get_euler().y
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
		_load_stats()
	else:
		screen = Screen.TITLE
	if main.hud != null and main.hud._min != null:
		main.hud._min.visible = not v
	if main.hud != null:
		for cr in main.hud.crosshair:
			(cr as Control).visible = not v
	_update_showcase_mode()


func _process(dt: float) -> void:
	if not open or main == null or main.cam == null:
		return
	# кінематографічний обліт села навколо точки старту
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
	_step_showcase(dt)
	_panel.queue_redraw()


# ============================ ввід ============================

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
		if kc == KEY_M and main.hud != null:
			main.hud._toggle_sound()
		elif kc == KEY_ESCAPE or kc == KEY_BACKSPACE:
			if screen == Screen.TITLE:
				if kc == KEY_ESCAPE:
					main.get_tree().quit()
			else:
				_go(Screen.TITLE)
		else:
			_key(kc)
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseMotion:
		_mouse = event.position
		if screen == Screen.HANGAR and (event.button_mask & MOUSE_BUTTON_MASK_LEFT) != 0 and _over_showcase(event.position):
			_sc_user_yaw += event.relative.x * 0.01
			_sc_idle = 0.0
		else:
			var h := _hit_at(event.position)
			if not h.is_empty():
				_hover(str(h["a"]), int(h["i"]))
		get_viewport().set_input_as_handled()
	elif event is InputEventMouseButton:
		if event.pressed and event.button_index == MOUSE_BUTTON_LEFT and not (main.rc != null and main.rc.wizard_active):
			var h := _hit_at(event.position)
			if not h.is_empty():
				_click(str(h["a"]), int(h["i"]))
		elif event.pressed and screen == Screen.MISSIONS and event.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN]:
			_pick_mission(mission_pick + (1 if event.button_index == MOUSE_BUTTON_WHEEL_DOWN else -1))
		get_viewport().set_input_as_handled()


func _key(kc: int) -> void:
	var enter: bool = kc in [KEY_ENTER, KEY_KP_ENTER, KEY_SPACE]
	match screen:
		Screen.TITLE:
			if kc == KEY_UP: title_sel = posmod(title_sel - 1, TITLE_ITEMS.size())
			elif kc == KEY_DOWN: title_sel = posmod(title_sel + 1, TITLE_ITEMS.size())
			elif enter: _title_action(TITLE_ITEMS[title_sel])
		Screen.MISSIONS:
			if kc in [KEY_LEFT, KEY_UP]: _pick_mission(mission_pick - 1)
			elif kc in [KEY_RIGHT, KEY_DOWN]: _pick_mission(mission_pick + 1)
			elif kc >= KEY_1 and kc <= KEY_9: _pick_mission(kc - KEY_0)
			elif enter: _launch_mission()
			elif kc == KEY_F: _start_flight()
		Screen.HANGAR:
			if kc == KEY_UP: hangar_row = posmod(hangar_row - 1, 5)
			elif kc == KEY_DOWN: hangar_row = posmod(hangar_row + 1, 5)
			elif kc == KEY_LEFT: _hangar_adjust(hangar_row, -1)
			elif kc == KEY_RIGHT: _hangar_adjust(hangar_row, 1)
			elif enter: _start_flight()
		Screen.SETTINGS:
			if kc == KEY_UP: settings_sel = posmod(settings_sel - 1, SETTINGS_ITEMS.size())
			elif kc == KEY_DOWN: settings_sel = posmod(settings_sel + 1, SETTINGS_ITEMS.size())
			elif kc == KEY_LEFT: _setting_adjust(SETTINGS_ITEMS[settings_sel], -1)
			elif kc == KEY_RIGHT or enter: _setting_adjust(SETTINGS_ITEMS[settings_sel], 1)
		Screen.REPLAYS:
			if replay_files.is_empty(): return
			if kc == KEY_UP: replay_pick = posmod(replay_pick - 1, replay_files.size())
			elif kc == KEY_DOWN: replay_pick = posmod(replay_pick + 1, replay_files.size())
			elif enter: _play_replay(replay_pick)


func _hit_at(p: Vector2) -> Dictionary:
	var dp := p / _k
	for i in range(_hits.size() - 1, -1, -1):
		var h: Dictionary = _hits[i]
		if (h["r"] as Rect2).has_point(dp):
			return h
	return {}


func _hover(a: String, i: int) -> void:
	match a:
		"title": title_sel = i
		"hdrone": pass
		"hslot": hangar_row = i
		"setting": settings_sel = i
		"replay": replay_pick = i


func _click(a: String, i: int) -> void:
	match a:
		"title": _title_action(TITLE_ITEMS[i])
		"mtab": _pick_mission(i)
		"mgo": _launch_mission()
		"mfree": _start_flight()
		"back": _go(Screen.TITLE)
		"hdrone": _set_drone(i)
		"hslot": _hangar_adjust(i, 1)
		"hslotl": _hangar_adjust(i, -1)
		"hgo": _start_flight()
		"setting": _setting_adjust(SETTINGS_ITEMS[i], 1)
		"settingl": _setting_adjust(SETTINGS_ITEMS[i], -1)
		"replay": _play_replay(i)


# ============================ самотест ============================

func _press(kc: int) -> void:
	var ev := InputEventKey.new()
	ev.physical_keycode = kc
	ev.pressed = true
	_input(ev)


## Клік по зоні, зібраній під час останнього кадру малювання.
func _click_hit(a: String, i: int) -> bool:
	for h: Dictionary in _hits:
		if str(h["a"]) == a and int(h["i"]) == i:
			var ev := InputEventMouseButton.new()
			ev.button_index = MOUSE_BUTTON_LEFT
			ev.pressed = true
			ev.position = (h["r"] as Rect2).get_center() * _k
			_input(ev)
			return true
	return false


func _frames(n: int) -> void:
	for i in n:
		await get_tree().process_frame
	await RenderingServer.frame_post_draw


## --menutest: реальні обробники вводу — клавіші й кліки по зонам з відмальованого кадру.
func self_test() -> bool:
	var ok := true
	var keep_drone := str(main.cam.drone_id)
	var check := func(name: String, cond: bool) -> void:
		print("MENUTEST %s → %s" % [name, "OK" if cond else "FAIL"])
		ok = ok and cond
	set_open(true)
	title_sel = 0
	await _frames(2)
	check.call("титул відкрито", open and screen == Screen.TITLE and not _hits.is_empty())
	_press(KEY_DOWN); _press(KEY_ENTER)
	check.call("↓ Enter → Місії", screen == Screen.MISSIONS)
	_press(KEY_RIGHT)
	check.call("→ місія 2", mission_pick == 2)
	_press(KEY_6)
	check.call("цифра 6 → місія 6", mission_pick == 6)
	await _frames(2)
	check.call("клік по вкладці 3", _click_hit("mtab", 3) and mission_pick == 3)
	check.call("клік «назад» → титул", _click_hit("back", 0) and screen == Screen.TITLE and open)
	await _frames(2)
	check.call("клік «Ангар»", _click_hit("title", 2) and screen == Screen.HANGAR)
	main.cam.set_drone("fpv7")
	hangar_row = 0
	_press(KEY_RIGHT)
	check.call("→ наступний борт (FPV 5″)", str(main.cam.drone_id) == "fpv5")
	await _frames(4)
	check.call("вітрина: модель збудована", _sc_model != null and _sv != null)
	check.call("клік по борту SHARK", _click_hit("hdrone", 0) and str(main.cam.drone_id) == "wing")
	_press(KEY_ESCAPE)
	check.call("Esc з ангара → титул (не вихід)", screen == Screen.TITLE and open)
	var muted: bool = main.hud._sound_muted
	_go(Screen.SETTINGS)
	settings_sel = SETTINGS_ITEMS.find("sound")
	_press(KEY_ENTER)
	check.call("налаштування: звук перемикається", main.hud._sound_muted != muted)
	_press(KEY_ENTER)
	_go(Screen.MISSIONS)
	mission_pick = 1
	_press(KEY_ENTER)
	check.call("Enter у брифінгу → місія 1 стартувала, меню закрите",
		not open and main.mission.active and int(main.mission.mission_id) == 1)
	main.mission.stop()
	main.cam.set_drone(keep_drone)
	return ok


# ============================ дії ============================

func _go(s: int) -> void:
	screen = s
	_update_showcase_mode()


func _title_action(it: String) -> void:
	match it:
		"play": _start_flight()
		"missions": _go(Screen.MISSIONS)
		"hangar":
			hangar_row = 0
			_go(Screen.HANGAR)
		"replays":
			_refresh_replays()
			_go(Screen.REPLAYS)
		"settings": _go(Screen.SETTINGS)
		"exit": main.get_tree().quit()


func _start_flight() -> void:
	_started = true
	set_open(false)
	if main.telemetry != null and main.telemetry.replaying:
		main.telemetry.stop_replay()


func _pick_mission(id: int) -> void:
	var n: int = main.mission.MISSIONS.size() - 1 if main.mission != null else 1
	mission_pick = clampi(id, 1, n)


func _launch_mission() -> void:
	var pl := _plan_for(mission_pick)
	_started = true
	set_open(false)
	if main.telemetry != null and main.telemetry.replaying:
		main.telemetry.stop_replay()
	main.mission.start(mission_pick, float(pl.get("yaw", NAN)))


func _play_replay(i: int) -> void:
	if i < 0 or i >= replay_files.size():
		return
	_started = true
	set_open(false)
	main.telemetry.start_replay("user://flights/" + replay_files[i])


func _set_drone(i: int) -> void:
	var id: String = HANGAR[i]["id"]
	if main.cam.has_method("set_drone"):
		main.cam.set_drone(id)


func _hangar_idx() -> int:
	var cur := str(main.cam.get("drone_id"))
	for i in HANGAR.size():
		if HANGAR[i]["id"] == cur:
			return i
	return 2


func _hangar_adjust(row: int, dir: int) -> void:
	match row:
		0: _set_drone(posmod(_hangar_idx() + dir, HANGAR.size()))
		1:
			if main.targets != null and str(main.cam.get("drone_id")) != "wing":
				main.targets.cycle_weapon(dir)
		2:
			if main.hud != null and main.hud.fpv_link != null:
				main.hud.fpv_link.set_camera(posmod(int(main.hud.fpv_link.camera) + dir, 4))
		3:
			if str(main.cam.get("drone_id")) != "wing":
				main.cam.mode = posmod(int(main.cam.mode) + dir, 3)
		4:
			if main.get("droneview") != null:
				main.droneview.set_skin(main.droneview.skin + dir)
				_sc_for = ""                     # перебудувати модель вітрини з новим скіном


func _setting_adjust(it: String, dir: int) -> void:
	match it:
		"region": _switch_region()
		"weather": main.weather.apply(posmod(int(main.weather.idx) + dir, main.weather.PRESETS.size()))
		"quality":
			main._quality_from_flag = false
			main.apply_quality(posmod(main.quality + dir, 3))
		"trees": _switch_trees()
		"sound":
			if main.hud != null: main.hud._toggle_sound()
		"rc": main.rc.wizard_start()
		"rates": main.rc.cycle_preset(dir)


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


## План місії для карти — кеш скидається, коли зміщується точка старту (після попередньої місії).
func _plan_for(id: int) -> Dictionary:
	if main.mission == null:
		return {}
	if _plans_home != main._home_pos:
		_plans = {}
		_plans_home = main._home_pos
	if not _plans.has(id):
		_plans[id] = main.mission.plan(id, _flight_yaw)
	return _plans[id]


# ============================ тактична карта ============================

var _map_sv: SubViewport
var _map_bg: ColorRect
var _map_vec: Control
var _map_key := ""
var _map_view := Rect2()
var _vec_roads: Array = []      # [{c, p: PackedVector2Array, bb: Rect2}]
var _vec_water: Array = []
var _vec_lakes: Array = []      # [{p, bb, ok}] — ok: полігон тріангулюється
var _vec_bld := PackedFloat32Array()   # x, z, w, d, ang по 5


func _ensure_map() -> void:
	if _map_sv != null:
		return
	_map_sv = SubViewport.new()
	_map_sv.disable_3d = true
	_map_sv.msaa_2d = Viewport.MSAA_4X
	_map_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_map_sv)
	_map_bg = ColorRect.new()
	var sm := ShaderMaterial.new()
	sm.shader = load("res://scripts/tactical_map.gdshader")
	# сирі висоти як RG8 без копіювання: 16 біт little-endian = R молодший, G старший
	var img := Image.create_from_data(main.px, main.px, false, Image.FORMAT_RG8, main.height_bytes)
	sm.set_shader_parameter("height_tex", ImageTexture.create_from_image(img))
	sm.set_shader_parameter("px", float(main.px))
	sm.set_shader_parameter("e_min", float(main.e_min))
	sm.set_shader_parameter("e_max", float(main.e_max))
	sm.set_shader_parameter("size_m", float(main.size_m))
	if main.terrain_mat != null:
		sm.set_shader_parameter("mask_tex", main.terrain_mat.get_shader_parameter("mask_tex"))
		var mpx: Variant = main.terrain_mat.get_shader_parameter("mask_px")
		sm.set_shader_parameter("mask_px", float(mpx) if mpx != null else 4096.0)
	_map_bg.material = sm
	_map_sv.add_child(_map_bg)
	_map_vec = Control.new()
	_map_vec.draw.connect(_draw_map_vectors)
	_map_sv.add_child(_map_vec)
	_load_vectors()


func _poly_entry(pts: Array) -> Dictionary:
	var pv := PackedVector2Array()
	var mn := Vector2(INF, INF)
	var mx := Vector2(-INF, -INF)
	for q: Array in pts:
		var v := Vector2(float(q[0]), float(q[1]))
		pv.append(v)
		mn = mn.min(v)
		mx = mx.max(v)
	return {"p": pv, "bb": Rect2(mn, mx - mn)}


func _load_vectors() -> void:
	var t0 := Time.get_ticks_msec()
	var rj: Variant = JSON.parse_string(FileAccess.get_file_as_string(main.asset_path("roads.json")))
	if rj is Dictionary:
		for rd: Dictionary in rj["roads"]:
			var e := _poly_entry(rd["p"])
			e["c"] = str(rd["c"])
			_vec_roads.append(e)
	var wj: Variant = JSON.parse_string(FileAccess.get_file_as_string(main.asset_path("water.json")))
	if wj is Dictionary:
		for wd: Dictionary in wj["w"]:
			var e := _poly_entry(wd["p"])
			e["c"] = str(wd["c"])
			_vec_water.append(e)
	if FileAccess.file_exists(main.asset_path("lakes.json")):
		var lj: Variant = JSON.parse_string(FileAccess.get_file_as_string(main.asset_path("lakes.json")))
		if lj is Dictionary:
			for lk: Array in lj["a"]:
				var e := _poly_entry(lk)
				e["ok"] = not Geometry2D.triangulate_polygon(e["p"]).is_empty()
				_vec_lakes.append(e)
	var bj: Variant = JSON.parse_string(FileAccess.get_file_as_string(main.asset_path("buildings.json")))
	if bj is Dictionary:
		for b: Array in bj["b"]:
			_vec_bld.append_array(PackedFloat32Array([float(b[0]), float(b[1]), float(b[2]), float(b[3]), float(b[4])]))
	print("Тактична карта: вектори регіону за %d мс (доріг %d, водотоків %d, будівель %d)" % [
		Time.get_ticks_msec() - t0, _vec_roads.size(), _vec_water.size(), _vec_bld.size() / 5])


## Перемальовує карту лише коли змінились вікно світу або розмір у пікселях.
func _prepare_map(view: Rect2, size_px: Vector2i) -> void:
	_ensure_map()
	var key := "%s|%s" % [view, size_px]
	if key == _map_key:
		return
	_map_key = key
	_map_view = view
	_map_sv.size = size_px
	_map_bg.size = Vector2(size_px)
	_map_vec.size = Vector2(size_px)
	var sm := _map_bg.material as ShaderMaterial
	sm.set_shader_parameter("view_min", view.position)
	sm.set_shader_parameter("view_size", view.size)
	_map_vec.queue_redraw()
	_map_sv.render_target_update_mode = SubViewport.UPDATE_ONCE


func _draw_map_vectors() -> void:
	var v := _map_view
	var sz := _map_vec.size
	var k := sz.x / v.size.x                      # пікселів на метр
	var vis := v.grow(200.0)
	var tr := func(pv: PackedVector2Array) -> PackedVector2Array:
		var out := PackedVector2Array()
		out.resize(pv.size())
		for i in pv.size():
			out[i] = (pv[i] - v.position) * k
		return out
	for lk: Dictionary in _vec_lakes:
		if bool(lk["ok"]) and vis.intersects(lk["bb"]):
			_map_vec.draw_colored_polygon(tr.call(lk["p"]), Color(0.16, 0.26, 0.32))
	for wd: Dictionary in _vec_water:
		if vis.intersects(wd["bb"]):
			var river := str(wd["c"]) == "river"
			_map_vec.draw_polyline(tr.call(wd["p"]), Color(0.30, 0.48, 0.58, 0.95) if river else Color(0.26, 0.40, 0.48, 0.8),
				maxf(18.0 * k, 2.4) if river else maxf(3.0 * k, 1.1), true)
	var styles := {"track": [Color(0.62, 0.58, 0.46, 0.28), 0.9, 0.0], "service": [Color(0.74, 0.72, 0.64, 0.45), 1.0, 0.0],
		"residential": [Color(0.80, 0.78, 0.70, 0.65), 1.4, 0.0], "unclassified": [Color(0.80, 0.78, 0.70, 0.65), 1.5, 0.0],
		"tertiary": [Color(0.90, 0.86, 0.72, 0.9), 2.2, 3.4], "secondary": [Color(0.96, 0.80, 0.52), 2.8, 4.2],
		"primary": [Color(0.97, 0.78, 0.48), 3.0, 4.6]}
	for pass_i in 2:                               # 0 — темна обводка великих доріг, 1 — самі лінії
		for rd: Dictionary in _vec_roads:
			if not vis.intersects(rd["bb"]):
				continue
			var st: Array = styles.get(str(rd["c"]), styles["track"])
			if pass_i == 0:
				if float(st[2]) > 0.0:
					_map_vec.draw_polyline(tr.call(rd["p"]), Color(0.04, 0.05, 0.04, 0.8), float(st[2]), true)
			else:
				_map_vec.draw_polyline(tr.call(rd["p"]), st[0], float(st[1]), true)
	var bcol := Color(0.80, 0.77, 0.70, 0.9)
	for i in range(0, _vec_bld.size(), 5):
		var c := Vector2(_vec_bld[i], _vec_bld[i + 1])
		if not vis.has_point(c):
			continue
		var sp := (c - v.position) * k
		var hw := maxf(_vec_bld[i + 2] * 0.5 * k, 1.1)
		var hd := maxf(_vec_bld[i + 3] * 0.5 * k, 1.1)
		var a := _vec_bld[i + 4]
		var ax := Vector2(cos(a), sin(a))         # як у main: Basis(UP, -ang) → ширина вздовж (cos, sin)
		var az := Vector2(-sin(a), cos(a))
		_map_vec.draw_colored_polygon(PackedVector2Array([sp - ax * hw - az * hd, sp + ax * hw - az * hd,
			sp + ax * hw + az * hd, sp - ax * hw + az * hd]), bcol)


# ============================ вітрина ангара ============================

var _sv: SubViewport
var _sv_world: Node3D
var _sc_model: Node3D
var _sc_props: Array = []
var _sc_cam: Camera3D
var _sc_for := ""
var _sc_frame := 0
var _sc_yaw := 0.0
var _sc_user_yaw := 0.0
var _sc_idle := 99.0
var _sc_rect := Rect2()       # дизайн-простір — де намальована вітрина


func _ensure_showcase() -> void:
	if _sv != null:
		return
	_sv = SubViewport.new()
	_sv.size = Vector2i(1280, 720)
	_sv.transparent_bg = true
	_sv.own_world_3d = true
	_sv.msaa_3d = Viewport.MSAA_4X
	_sv.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_sv)
	_sv_world = Node3D.new()
	_sv.add_child(_sv_world)
	var we := WorldEnvironment.new()
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.55, 0.58, 0.62)
	e.ambient_light_energy = 0.9
	e.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	we.environment = e
	_sv_world.add_child(we)
	var key := DirectionalLight3D.new()
	key.light_energy = 2.2
	key.rotation_degrees = Vector3(-38, -35, 0)
	_sv_world.add_child(key)
	var rim := DirectionalLight3D.new()
	rim.light_energy = 1.7
	rim.light_color = Color(1.0, 0.55, 0.3)
	rim.rotation_degrees = Vector3(-12, 150, 0)
	_sv_world.add_child(rim)
	_sc_cam = Camera3D.new()
	_sc_cam.fov = 30.0
	_sv_world.add_child(_sc_cam)
	_sc_cam.current = true


func _update_showcase_mode() -> void:
	var on := open and screen == Screen.HANGAR
	if on:
		_ensure_showcase()
	if _sv != null:
		_sv.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED


func _step_showcase(dt: float) -> void:
	if screen != Screen.HANGAR or _sv == null:
		return
	var want := str(main.cam.get("drone_id"))
	var wkey := "%s_%d_%d" % [want, int(main.droneview.skin) if main.get("droneview") != null else 1,
		int(main.targets.weapon) if main.targets != null else -1]
	if wkey != _sc_for:
		_sc_for = wkey
		if _sc_model != null:
			_sc_model.queue_free()
		var U = load("res://scripts/units.gd").new()
		var d: Dictionary = U.build_drone(want, int(main.droneview.skin) if main.get("droneview") != null else 1,
			int(main.targets.weapon) if main.targets != null and want != "wing" else -1)
		_sc_model = d.root
		_sc_props = d.props
		_sv_world.add_child(_sc_model)
		_sc_frame = 0
	_sc_frame += 1
	if _sc_frame == 2 and _sc_model != null:
		# кадр після додавання: global_transform мешів уже валідний — кадруємо за AABB
		var aabb := AABB()
		for mi in _sc_model.find_children("*", "MeshInstance3D", true, false):
			var g: AABB = (mi as MeshInstance3D).global_transform * (mi as MeshInstance3D).get_aabb()
			aabb = g if aabb.size == Vector3.ZERO else aabb.merge(g)
		var c := aabb.get_center()
		var r := maxf(aabb.size.length(), 0.1)
		_sc_cam.look_at_from_position(c + Vector3(r * 0.66, r * 0.30, r * 0.74), c, Vector3.UP)
	_sc_idle += dt
	if _sc_idle > 2.5:
		_sc_yaw += dt * 0.25
	if _sc_model != null:
		_sc_model.rotation.y = _sc_yaw + _sc_user_yaw
		for i in _sc_props.size():
			(_sc_props[i] as Node3D).rotation.y += dt * 40.0 * (1.0 if i % 2 == 0 else -1.0)


func _over_showcase(p: Vector2) -> bool:
	return _sc_rect.has_point(p / _k)


# ============================ малювання: базові ============================

var _fonts := {}

func _font(fam: String, w: int, sp: float = 0.0) -> Font:
	var key := "%s|%d|%.1f" % [fam, w, sp]
	if _fonts.has(key):
		return _fonts[key]
	var fv := FontVariation.new()
	if fam == "mono":
		var files := {400: "Regular", 500: "Medium", 600: "SemiBold"}
		fv.base_font = load("res://assets/fonts/IBMPlexMono-%s.ttf" % files.get(w, "Medium"))
	else:
		fv.base_font = load("res://assets/fonts/%s-VF.ttf" % fam)
		fv.variation_opentype = {TextServerManager.get_primary_interface().name_to_tag("wght"): w}
	fv.spacing_glyph = int(round(sp))
	_fonts[key] = fv
	return fv


func _tw(text: String, fam: String, w: int, size: int, sp: float = 0.0) -> float:
	return _font(fam, w, sp).get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x


## Текст; al: 0 — зліва від x, 1 — по центру, 2 — справа до x. y — базова лінія.
func _t(text: String, x: float, y: float, fam: String, w: int, size: int, col: Color, sp: float = 0.0, al: int = 0) -> float:
	var f := _font(fam, w, sp)
	var wd := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x
	var xx: float = x - (wd * 0.5 if al == 1 else (wd if al == 2 else 0.0))
	_panel.draw_string(f, Vector2(xx, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	return wd


func _para(text: String, x: float, y: float, width: float, fam: String, w: int, size: int, col: Color, line_h: float) -> float:
	var f := _font(fam, w)
	var words := text.split(" ")
	var line := ""
	var yy := y
	for wd in words:
		var probe := (line + " " + wd).strip_edges()
		if f.get_string_size(probe, HORIZONTAL_ALIGNMENT_LEFT, -1, size).x > width and line != "":
			_panel.draw_string(f, Vector2(x, yy), line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
			yy += line_h
			line = wd
		else:
			line = probe
	if line != "":
		_panel.draw_string(f, Vector2(x, yy), line, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)
	return yy


func _grad(r: Rect2, a: Color, b: Color, vertical: bool = true) -> void:
	var p := PackedVector2Array([r.position, Vector2(r.end.x, r.position.y), r.end, Vector2(r.position.x, r.end.y)])
	var c: PackedColorArray = PackedColorArray([a, a, b, b]) if vertical else PackedColorArray([a, b, b, a])
	_panel.draw_polygon(p, c)


func _hit(r: Rect2, a: String, i: int = 0) -> void:
	_hits.append({"r": r, "a": a, "i": i})


func _hovered(r: Rect2) -> bool:
	return _mouse.x >= 0.0 and r.has_point(_mouse / _k)


func _gates_word(n: int) -> String:
	return "%d %s" % [n, "ворота" if n % 10 in [2, 3, 4] and not n % 100 in [12, 13, 14] else "воріт"]


func _cap1(s: String) -> String:
	return s.left(1).to_upper() + s.substr(1).to_lower() if s.length() > 0 else s


func _mission_name(id: int) -> String:
	var nm := str(main.mission.MISSIONS[id]["name"])
	var parts := nm.split(" · ", true, 1)
	return parts[1] if parts.size() > 1 else nm


func _fmt_time(sec: float) -> String:
	return "%d:%02d" % [int(sec) / 60, int(sec) % 60]


func _region_name() -> String:
	return "Степ" if main.region == "steppe" else "Карпати"


func _draw_panel() -> void:
	var vp := _panel.get_viewport_rect().size
	_k = vp.y / 900.0
	_W = vp.x / _k
	_hits = []
	_panel.draw_set_transform(Vector2.ZERO, 0.0, Vector2(_k, _k))
	match screen:
		Screen.TITLE: _draw_title()
		Screen.MISSIONS: _draw_missions()
		Screen.HANGAR: _draw_hangar()
		Screen.SETTINGS: _draw_settings()
		Screen.REPLAYS: _draw_replays()
	if main.rc != null and main.rc.wizard_active:
		_draw_wizard()


# ============================ ТИТУЛ ============================

func _draw_title() -> void:
	var W := _W
	_grad(Rect2(0, 0, W, 270), Color(0.06, 0.04, 0.03, 0.35), Color(0.06, 0.04, 0.03, 0.0))
	_grad(Rect2(0, 480, W, 420), Color(0.05, 0.03, 0.02, 0.0), Color(0.05, 0.03, 0.02, 0.92))
	_grad(Rect2(0, 0, W * 0.62, 900), Color(0.04, 0.03, 0.02, 0.86), Color(0.04, 0.03, 0.02, 0.0), false)
	_panel.draw_rect(Rect2(0, 0, W, 46), Color(0.04, 0.025, 0.02))
	_panel.draw_rect(Rect2(0, 854, W, 46), Color(0.04, 0.025, 0.02))

	var x := 96.0
	_t("ТРЕНАЖЕР ОПЕРАТОРА БпЛА", x, 225, "Manrope", 600, 13, Color(1.0, 0.84, 0.75, 0.78), 5.0)
	var w1 := _t("UAV", x, 330, "Unbounded", 500, 100, Color.WHITE, 6.0)
	_t("TERRAIN", x + w1 + 30, 330, "Unbounded", 200, 100, Color.WHITE, 6.0)
	_t("Реальний рельєф України", x, 372, "Manrope", 400, 17, Color(0.965, 0.93, 0.91, 0.72))

	var labels := {"play": "Продовжити" if _started else "Почати політ", "missions": "Місії", "hangar": "Ангар",
		"replays": "Реплеї", "settings": "Налаштування", "exit": "Вихід"}
	var hints := {"play": _play_hint(), "missions": "%d завдань" % (main.mission.MISSIONS.size() - 1),
		"hangar": str(main.cam.drone_name()), "replays": "%d записів" % replay_files.size(), "settings": "", "exit": ""}
	var y := 470.0
	for i in TITLE_ITEMS.size():
		var it: String = TITLE_ITEMS[i]
		var on := i == title_sel
		var col: Color = Color.WHITE if on else Color(0.965, 0.93, 0.91, 0.5)
		var xx := x
		if on:
			_panel.draw_line(Vector2(x, y - 11), Vector2(x + 46, y - 11), WARM, 1.5)
			xx = x + 68
		var wd := _t(str(labels[it]), xx, y, "Unbounded", 300, 29, col, 0.5)
		if on and str(hints[it]) != "":
			_t(str(hints[it]), xx + wd + 18, y - 2, "Manrope", 600, 13, Color(1.0, 0.75, 0.59, 0.9), 1.0)
		_hit(Rect2(x - 10, y - 40, 620, 54), "title", i)
		y += 58.0

	# статус праворуч
	var done := 0
	var best_sum := 0
	for id in _stats:
		var st: Dictionary = _stats[id]
		if bool(st["done"]):
			done += 1
			best_sum += int(st["best"])
	var total: int = main.mission.MISSIONS.size() - 1
	var rc_s: String = "налаштовано" if main.rc.configured else ("знайдено" if main.rc.joy_name() != "" else "не підключено")
	var cols := [["ПРОЙДЕНО", "%d / %d" % [done, total], Color.WHITE],
		["СЕРЕДНІЙ БАЛ", str(best_sum / done) if done > 0 else "—", Color.WHITE],
		["ПУЛЬТ", rc_s, GREEN if main.rc.configured else WARM]]
	var rx := W - 96.0
	for j in range(cols.size() - 1, -1, -1):
		var c: Array = cols[j]
		var vw := _tw(str(c[1]), "Unbounded", 300, 20)
		var lw := _tw(str(c[0]), "Manrope", 600, 11, 2.5)
		var bw := maxf(vw, lw)
		_t(str(c[0]), rx, 772, "Manrope", 600, 11, Color(0.965, 0.93, 0.91, 0.45), 2.5, 2)
		_t(str(c[1]), rx, 802, "Unbounded", 300, 20, c[2], 0.0, 2)
		rx -= bw + 48.0

	_keys([["↑↓", "вибір"], ["ENTER", "підтвердити"], ["ESC", "вийти з гри"]], x, 826, Color(0.965, 0.93, 0.91, 0.42))


func _play_hint() -> String:
	if main.mission != null and main.mission.active:
		var ln: Array = main.mission.quest_lines()
		for l: Dictionary in ln:
			if l.has("h") and int(l["st"]) == 1:
				return "місія %d · %s" % [main.mission.mission_id, str(l["h"])]
		return "місія %d" % main.mission.mission_id
	return "вільний політ · %s" % str(main.cam.drone_name()) if _started else ""


func _keys(pairs: Array, x: float, y: float, col: Color) -> void:
	var xx := x
	for p: Array in pairs:
		var kw := _tw(str(p[0]), "Manrope", 600, 11, 1.0) + 14.0
		_panel.draw_rect(Rect2(xx, y - 15, kw, 21), Color(col.r, col.g, col.b, col.a * 0.6), false, 1.0)
		_t(str(p[0]), xx + 7, y, "Manrope", 600, 11, Color(col.r, col.g, col.b, minf(col.a * 1.7, 1.0)), 1.0)
		xx += kw + 8
		xx += _t(str(p[1]), xx, y, "Manrope", 500, 12, col, 1.5) + 26.0


# ============================ МІСІЇ ============================

func _draw_missions() -> void:
	var W := _W
	var side_w := 620.0
	var map_r := Rect2(0, 0, W - side_w, 900)
	_panel.draw_rect(Rect2(0, 0, W, 900), BG)
	var pl := _plan_for(mission_pick)
	_draw_map(map_r, pl)
	_draw_brief(Rect2(W - side_w, 0, side_w, 900), pl)


func _draw_map(r: Rect2, pl: Dictionary) -> void:
	var origin: Vector3 = pl.get("origin", main._home_pos)
	var steps: Array = pl.get("steps", [])
	# охоплення: старт + усі точки місії (+ зона пошуку для місій без точок)
	var pts: Array = [origin]
	for st: Dictionary in steps:
		pts.append(st["pos"])
	var mn := Vector2(origin.x, origin.z)
	var mx := mn
	for p: Vector3 in pts:
		mn = Vector2(minf(mn.x, p.x), minf(mn.y, p.z))
		mx = Vector2(maxf(mx.x, p.x), maxf(mx.y, p.z))
	var ctr := (mn + mx) * 0.5
	var half := maxf(maxf(mx.x - mn.x, mx.y - mn.y) * 0.5 * 1.45, 1600.0)
	var sc := minf(r.size.x, r.size.y) * 0.5 / half           # пікселів на метр
	var hx := r.size.x * 0.5 / sc
	var hz := r.size.y * 0.5 / sc
	var w2s := func(x: float, z: float) -> Vector2:
		return r.position + r.size * 0.5 + Vector2(x - ctr.x, z - ctr.y) * sc
	# тактична топокарта: рельєф/горизонталі/покрив у шейдері + OSM-вектори, відмальовано в SubViewport
	var size_px := Vector2i(int(r.size.x * _k), int(r.size.y * _k))
	var lim := 2560.0 / float(maxi(size_px.x, size_px.y))
	if lim < 1.0:
		size_px = Vector2i(int(size_px.x * lim), int(size_px.y * lim))
	_prepare_map(Rect2(ctr.x - hx, ctr.y - hz, hx * 2.0, hz * 2.0), size_px)
	if _map_sv != null:
		_panel.draw_texture_rect(_map_sv.get_texture(), r, false)
	# сітка 500 м у світових координатах
	var gstep := 500.0 if half < 2600.0 else 1000.0
	var gx := ceilf((ctr.x - hx) / gstep) * gstep
	while gx < ctr.x + hx:
		var sx: float = w2s.call(gx, 0.0).x
		_panel.draw_line(Vector2(sx, r.position.y), Vector2(sx, r.end.y), Color(0.86, 0.92, 0.86, 0.07), 1.0)
		gx += gstep
	var gz := ceilf((ctr.y - hz) / gstep) * gstep
	while gz < ctr.y + hz:
		var sy: float = w2s.call(0.0, gz).y
		_panel.draw_line(Vector2(r.position.x, sy), Vector2(r.end.x, sy), Color(0.86, 0.92, 0.86, 0.07), 1.0)
		gz += gstep
	# віньєтка країв
	_grad(Rect2(r.position.x, r.position.y, r.size.x, 150), Color(0.03, 0.04, 0.03, 0.8), Color(0.03, 0.04, 0.03, 0.0))
	_grad(Rect2(r.position.x, r.end.y - 170, r.size.x, 170), Color(0.03, 0.04, 0.03, 0.0), Color(0.03, 0.04, 0.03, 0.85))
	_grad(Rect2(r.end.x - 120, r.position.y, 120, r.size.y), Color(0.05, 0.07, 0.05, 0.0), Color(0.05, 0.07, 0.05, 0.9), false)

	# маршрут
	var o2: Vector2 = w2s.call(origin.x, origin.z)
	var prev := o2
	var km := func(p: Vector3) -> String:
		return "%.1f км" % (Vector2(p.x - origin.x, p.z - origin.z).length() / 1000.0)
	for st: Dictionary in steps:
		var p: Vector3 = st["pos"]
		var s2: Vector2 = w2s.call(p.x, p.z)
		if s2.distance_to(prev) > 6.0:
			_panel.draw_line(prev, s2, Color(0.02, 0.03, 0.02, 0.75), 6.0, true)
			_panel.draw_dashed_line(prev, s2, Color(1.0, 1.0, 0.96), 2.4, 10.0)
			prev = s2
	var placed: Array = []                        # підписи в одній точці (ціль і БДА) розсуваються вниз
	var label := func(pos: Vector2, text: String, col: Color) -> void:
		var tw2 := _tw(text, "mono", 600, 12, 1.0)
		var box := Rect2(pos.x - 6, pos.y - 15, tw2 + 12, 21)
		var moved := true
		while moved:
			moved = false
			for pr: Rect2 in placed:
				if pr.intersects(box):
					box.position.y = pr.end.y + 4.0
					moved = true
		placed.append(box)
		_panel.draw_rect(box, Color(0.03, 0.04, 0.03, 0.82))
		_t(text, box.position.x + 6, box.position.y + 15, "mono", 600, 12, col, 1.0)
	var gate_n := 0
	for st: Dictionary in steps:
		var p: Vector3 = st["pos"]
		var s2: Vector2 = w2s.call(p.x, p.z)
		match str(st["kind"]):
			"gate":
				gate_n += 1
				_panel.draw_circle(s2, 7.5, Color(0.02, 0.03, 0.02, 0.85))
				_panel.draw_arc(s2, 7.0, 0, TAU, 20, GREEN, 2.0, true)
			"land":
				_panel.draw_rect(Rect2(s2 - Vector2(6, 6), Vector2(12, 12)), Color(0.95, 0.85, 0.3), false, 2.0)
				label.call(s2 + Vector2(14, 5), "ПОСАДКА", Color(0.95, 0.85, 0.3))
			"recon":
				var rr := maxf(float(st.get("r", 100.0)) * sc, 10.0)
				_panel.draw_circle(s2, rr, Color(0.45, 0.75, 1.0, 0.12))
				_panel.draw_arc(s2, rr, 0, TAU, 40, Color(0.45, 0.75, 1.0), 2.0)
				label.call(s2 + Vector2(rr + 10, 5), ("БДА · " if st.has("frac") else "РОЗВІДКА · ") + km.call(p), Color(0.55, 0.8, 1.0))
			"relay_at":
				var rr := maxf(float(st.get("r", 150.0)) * sc, 10.0)
				_panel.draw_circle(s2, rr, Color(0.94, 0.67, 0.24, 0.12))
				_panel.draw_arc(s2, rr, 0, TAU, 40, AMBER, 2.0)
				_panel.draw_circle(s2, 3.5, AMBER)
				label.call(s2 + Vector2(rr + 10, 5), "РУБІЖ МАТКИ · " + km.call(p), AMBER)
			"mark":
				if st.has("hidden") or st.has("dx"):
					var rr := maxf(150.0 * sc, 22.0)
					_panel.draw_circle(s2, rr, Color(0.85, 0.36, 0.26, 0.10))
					_panel.draw_arc(s2, rr, 0, TAU, 48, Color(0.85, 0.36, 0.26, 0.9), 1.5)
					for q: Vector2 in [Vector2(-9, -7), Vector2(6, -1), Vector2(-3, 8)]:
						_panel.draw_rect(Rect2(s2 + q - Vector2(5, 5), Vector2(10, 10)), Color(1.0, 0.36, 0.24), false, 2.0)
					label.call(s2 + Vector2(rr + 10, 5), "ЦІЛІ ×%d · %s" % [int(st.get("n", 1)), km.call(p)], Color(1.0, 0.42, 0.3))
				else:
					var rr := 1500.0 * sc
					_panel.draw_arc(s2, rr, 0, TAU, 64, Color(0.85, 0.36, 0.26, 0.7), 1.5)
					label.call(s2 + Vector2(-60, -rr - 12), "РАЙОН ПОШУКУ · 1.5 км", Color(1.0, 0.42, 0.3))
			"strike":
				var rr := maxf(120.0 * sc, 16.0)
				_panel.draw_arc(s2, rr, 0, TAU, 40, Color(1.0, 0.36, 0.24), 2.0)
				_panel.draw_rect(Rect2(s2 - Vector2(6, 6), Vector2(12, 12)), Color(1.0, 0.36, 0.24), false, 2.0)
				label.call(s2 + Vector2(rr + 10, 5), "КОЛОНА · " + km.call(p), Color(1.0, 0.42, 0.3))
	if gate_n == 1:
		label.call(prev + Vector2(14, -14), "КОНТРОЛЬНА ТОЧКА", GREEN)
	elif gate_n > 1:
		label.call(prev + Vector2(14, -14), "КОРИДОР · %s" % _gates_word(gate_n), GREEN)
	# старт
	_panel.draw_colored_polygon(PackedVector2Array([o2 + Vector2(0, -11), o2 + Vector2(10, 7), o2 + Vector2(-10, 7)]), GREEN)
	label.call(o2 + Vector2(16, 24), "СТАРТ · " + _start_drone_label(mission_pick), GREEN)

	# шапка карти
	_t("UAV TERRAIN", 30, 50, "Oswald", 600, 22, INK, 3.0)
	var cx := 30.0 + _tw("UAV TERRAIN", "Oswald", 600, 22, 3.0) + 22.0
	for chip in ["%s · 52×52 км" % _region_name().to_upper(), _mission_weather_label(mission_pick)]:
		var cw := _tw(chip, "mono", 500, 12, 1.0) + 20.0
		_panel.draw_rect(Rect2(cx, 30, cw, 28), Color(0.03, 0.04, 0.03, 0.7))
		_panel.draw_rect(Rect2(cx, 30, cw, 28), Color(0.89, 0.91, 0.89, 0.25), false, 1.0)
		_t(chip, cx + 10, 49, "mono", 500, 12, INK, 1.0)
		cx += cw + 8
	# координати кутів
	if main.has_method("_latlon_at"):
		var ll_tl: Vector2 = main._latlon_at(ctr.x - hx, ctr.y - hz)
		var ll_br: Vector2 = main._latlon_at(ctr.x + hx, ctr.y + hz)
		_t("%.3f°N  %.3f°E" % [ll_tl.x, ll_tl.y], 30, 84, "mono", 500, 11, Color(0.86, 0.92, 0.86, 0.55))
		_t("%.3f°N  %.3f°E" % [ll_br.x, ll_br.y], r.end.x - 140, r.end.y - 22, "mono", 500, 11, Color(0.86, 0.92, 0.86, 0.55), 0.0, 2)
	# легенда і масштаб
	var ly := r.end.y - 30.0
	var lx := 30.0
	_panel.draw_rect(Rect2(lx - 12, ly - 22, 380, 34), Color(0.03, 0.04, 0.03, 0.8))
	_panel.draw_colored_polygon(PackedVector2Array([Vector2(lx + 5, ly - 12), Vector2(lx + 10, ly - 2), Vector2(lx, ly - 2)]), GREEN)
	lx += 18 + _t("старт", lx + 18, ly, "mono", 500, 12, DIMC)
	_panel.draw_arc(Vector2(lx + 22, ly - 6), 6, 0, TAU, 16, AMBER, 2.0)
	lx += 36 + _t("рубіж", lx + 36, ly, "mono", 500, 12, DIMC)
	_panel.draw_rect(Rect2(lx + 18, ly - 11, 10, 10), Color(1.0, 0.36, 0.24), false, 2.0)
	lx += 36 + _t("ціль", lx + 36, ly, "mono", 500, 12, DIMC)
	_panel.draw_dashed_line(Vector2(lx + 18, ly - 6), Vector2(lx + 40, ly - 6), INK, 2.0, 5.0)
	_t("маршрут", lx + 48, ly, "mono", 500, 12, DIMC)
	var bar := gstep * sc
	var bx := r.end.x - 150.0 - bar
	_panel.draw_line(Vector2(bx, r.end.y - 50), Vector2(bx + bar, r.end.y - 50), INK, 2.0)
	_panel.draw_line(Vector2(bx, r.end.y - 56), Vector2(bx, r.end.y - 50), INK, 2.0)
	_panel.draw_line(Vector2(bx + bar, r.end.y - 56), Vector2(bx + bar, r.end.y - 50), INK, 2.0)
	_t("%d м" % int(gstep), bx + bar * 0.5, r.end.y - 62, "mono", 500, 11, INK, 0.0, 1)


func _start_drone_label(id: int) -> String:
	var m: Dictionary = main.mission.MISSIONS[id]
	var q: Array = m.get("quest", [])
	if not q.is_empty():
		return {"wing": "SHARK", "mship": "МАТКА", "fpv7": "FPV 7″"}.get(str((q[0] as Dictionary).get("drone", "")), "FPV")
	for st: Dictionary in m["steps"]:
		if str(st["kind"]) == "mark":
			return "SHARK"
	return "FPV 7″"


func _mission_weather_label(id: int) -> String:
	var m: Dictionary = main.mission.MISSIONS[id]
	var name: String = main.weather.PRESETS[int(m["weather"])]["name"] if m.has("weather") else str(main.weather.label)
	return name.to_upper()


## Порядок дій: фази квесту або кроки, згорнуті в людські рядки.
func _mission_sequence(id: int, pl: Dictionary) -> Array:
	var m: Dictionary = main.mission.MISSIONS[id]
	var origin: Vector3 = pl.get("origin", Vector3.ZERO)
	var out: Array = []
	var dist := func(p: Vector3) -> String:
		return "%.1f км" % (Vector2(p.x - origin.x, p.z - origin.z).length() / 1000.0)
	if m.has("quest"):
		var steps: Array = pl.get("steps", [])
		for ph: Dictionary in m["quest"]:
			var who: PackedStringArray = str(ph["who"]).split(" · ")
			var subs: Array = ph["subs"]
			var desc: String = str((subs[subs.size() - 1] as Dictionary)["t"]).replace(" %d/%d", "").split(" (")[0]
			var si := int(ph["step"])
			var dd: String = dist.call(steps[si]["pos"]) if si < steps.size() and str(steps[si]["kind"]) != "strike_marked" else ""
			out.append([who[0].to_upper(), desc, dd])
		return out
	var gates := 0
	for st: Dictionary in pl.get("steps", []):
		match str(st["kind"]):
			"takeoff": out.append(["ЗЛІТ", "набір %d м AGL" % int(st["agl"]), ""])
			"gate": gates += 1
			"land":
				if gates == 1:
					out.append(["ТОЧКА", "повернутись у зону зв'язку", ""])
				elif gates > 1:
					out.append(["КОРИДОР", "%s на різних висотах" % _gates_word(gates), ""])
				gates = 0
				out.append(["ПОСАДКА", "точно на майданчик", dist.call(st["pos"])])
			"recon": out.append(["РОЗВІДКА", "утримати точку %d с" % int(st.get("hold", 5)), dist.call(st["pos"])])
			"strike": out.append(["УДАР", "знищити колону", dist.call(st["pos"])])
			"mark": out.append(["SHARK", "відмітити %d цілі" % int(st.get("n", 1)), ""])
			"strike_marked": out.append(["FPV", "знищити відмічені цілі", ""])
	if gates > 0:
		out.append(["КОРИДОР", "%s змійкою" % _gates_word(gates), ""])
	return out


func _draw_brief(r: Rect2, pl: Dictionary) -> void:
	var m: Dictionary = main.mission.MISSIONS[mission_pick]
	_panel.draw_rect(r, Color(0.051, 0.067, 0.055))
	_panel.draw_line(r.position, Vector2(r.position.x, r.end.y), Color(0.15, 0.19, 0.16), 1.0)
	var x := r.position.x + 40.0
	var right := r.end.x - 40.0
	# вкладки місій
	var n: int = main.mission.MISSIONS.size() - 1
	for i in range(1, n + 1):
		var tr := Rect2(x + (i - 1) * 50.0, 30, 44, 44)
		var st: Dictionary = _stats.get(i, {})
		var on := i == mission_pick
		var hov := _hovered(tr)
		if on:
			_panel.draw_rect(tr, INK)
		else:
			_panel.draw_rect(tr, Color(0.21, 0.35, 0.23) if bool(st.get("done", false)) else (Color(0.3, 0.36, 0.31) if hov else Color(0.16, 0.2, 0.18)), false, 1.0)
		var tc: Color = Color(0.051, 0.067, 0.055) if on else (GREEN if bool(st.get("done", false)) else DIMC)
		_t(str(i), tr.get_center().x, 59, "mono", 600, 15, tc, 0.0, 1)
		_hit(tr, "mtab", i)
	var bk := Rect2(right - 110, 36, 110, 32)
	_t("ESC · НАЗАД", right, 57, "mono", 500, 11, INK if _hovered(bk) else MUTE, 1.5, 2)
	_hit(bk, "back")

	_t("%s № %d" % [str(m.get("tag", "ЗАВДАННЯ")), mission_pick], x, 122, "mono", 600, 12, RED, 3.0)
	var yy := _para(_mission_name(mission_pick), x, 170, right - x, "Oswald", 600, 42, INK, 46.0)
	yy = _para(str(m.get("brief", "")), x, yy + 38, right - x, "Manrope", 500, 16, Color(0.68, 0.72, 0.67), 24.0)

	yy += 40.0
	_t("ПОРЯДОК ДІЙ", x, yy, "mono", 500, 11, MUTE, 3.0)
	yy += 12.0
	_panel.draw_line(Vector2(x, yy), Vector2(right, yy), Color(0.13, 0.17, 0.14), 1.0)
	var seq := _mission_sequence(mission_pick, pl)
	var i2 := 0
	for row: Array in seq:
		i2 += 1
		yy += 38.0
		_t(str(i2), x, yy, "mono", 600, 12, MUTE)
		_t(str(row[0]), x + 28, yy, "Oswald", 600, 17, INK, 1.0)
		_t(str(row[1]), x + 150, yy, "Manrope", 500, 15, Color(0.68, 0.72, 0.67))
		if str(row[2]) != "":
			_t(str(row[2]), right, yy, "mono", 500, 12, MUTE, 0.0, 2)
		_panel.draw_line(Vector2(x, yy + 14), Vector2(right, yy + 14), Color(0.10, 0.13, 0.11), 1.0)

	# умови
	var cy := 730.0
	var best: Dictionary = _stats.get(mission_pick, {})
	var conds := [["НОРМАТИВ", _fmt_time(float(m.get("par", 0))), INK],
		["РЕЖИМ", str(m.get("mode", "angle")).to_upper(), INK],
		["ПОГОДА", _mission_weather_label(mission_pick).split(" ", true, 1)[-1].split(",")[0].capitalize(), INK],
		["КРАЩИЙ", str(best["best"]) if bool(best.get("done", false)) else "—", GREEN if bool(best.get("done", false)) else MUTE]]
	var cw := (right - x) / 4.0
	for j in conds.size():
		var c: Array = conds[j]
		_t(str(c[0]), x + j * cw, cy, "mono", 500, 10, MUTE, 2.0)
		_t(str(c[1]), x + j * cw, cy + 28, "Oswald", 500, 21, c[2], 0.5)

	# кнопки
	var fr := Rect2(x, 800, 160, 64)
	var gr := Rect2(x + 172, 800, right - x - 172, 64)
	_panel.draw_rect(fr, Color(1, 1, 1, 0.05) if _hovered(fr) else Color(0, 0, 0, 0))
	_panel.draw_rect(fr, Color(0.23, 0.27, 0.24), false, 1.0)
	_t("ВІЛЬНИЙ ПОЛІТ", fr.get_center().x, 838, "Oswald", 500, 15, DIMC, 1.5, 1)
	_hit(fr, "mfree")
	_panel.draw_rect(gr, RED.lightened(0.08) if _hovered(gr) else RED)
	var gw := _tw("ДО ВИЛЬОТУ", "Oswald", 600, 23, 3.0)
	var kw := _tw("ENTER", "mono", 600, 12, 1.0) + 16.0
	var gx := gr.get_center().x - (gw + 14 + kw) * 0.5
	_t("ДО ВИЛЬОТУ", gx, 841, "Oswald", 600, 23, Color.WHITE, 3.0)
	_panel.draw_rect(Rect2(gx + gw + 14, 820, kw, 24), Color.WHITE, false, 1.5)
	_t("ENTER", gx + gw + 22, 837, "mono", 600, 12, Color.WHITE, 1.0)
	_hit(gr, "mgo")


# ============================ АНГАР ============================

func _draw_hangar() -> void:
	var W := _W
	_panel.draw_rect(Rect2(0, 0, W, 900), Color(0.047, 0.055, 0.063, 0.9))
	_grad(Rect2(0, 470, W, 430), Color(0.047, 0.055, 0.063, 0.0), Color(0.047, 0.055, 0.063, 0.96))
	# сцена: перспективна сітка підлоги і кільця підсвітки
	var cxs := W * 0.5 + 80.0
	for gi in range(-14, 15):
		var top := Vector2(cxs + gi * 34.0, 560)
		var bot := Vector2(cxs + gi * 150.0, 900)
		_panel.draw_line(top, bot, Color(1, 1, 1, 0.035), 1.0)
	for gj in 7:
		var yy := 560.0 + pow(float(gj) / 6.0, 1.6) * 340.0
		_panel.draw_line(Vector2(0, yy), Vector2(W, yy), Color(1, 1, 1, 0.03 + gj * 0.004), 1.0)
	_ellipse(Vector2(cxs, 575), Vector2(300, 44), Color(1.0, 0.42, 0.17, 0.55), 1.5)
	_ellipse(Vector2(cxs, 575), Vector2(360, 62), Color(1, 1, 1, 0.07), 1.0)
	# модель
	if _sv != null:
		var sr := Rect2(cxs - 460, 110, 920, 518)
		_sc_rect = sr
		_panel.draw_texture_rect(_sv.get_texture(), sr, false)

	# шапка
	_t("UAV TERRAIN", 48, 60, "Oswald", 500, 22, Color.WHITE, 4.0)
	var tabs := [["ВИЛІТ", "missions"], ["АНГАР", ""], ["РЕПЛЕЇ", "replays"], ["НАЛАШТУВАННЯ", "settings"]]
	var tx := 290.0
	for tb: Array in tabs:
		var on := str(tb[1]) == ""
		var tw := _t(str(tb[0]), tx, 60, "Oswald", 500, 15, Color.WHITE if on else Color(0.49, 0.52, 0.5), 2.5)
		if on:
			_panel.draw_rect(Rect2(tx, 70, tw, 2), ORANGE)
		tx += tw + 34
	var bk := Rect2(W - 170, 40, 130, 30)
	_t("ESC · НАЗАД", W - 48, 60, "Manrope", 600, 12, Color.WHITE if _hovered(bk) else Color(0.6, 0.64, 0.61), 1.5, 2)
	_hit(bk, "back")

	var hi := _hangar_idx()
	var h: Dictionary = HANGAR[hi]
	var P: Dictionary = main.cam.DRONES[h["id"]]
	var x := 48.0
	_t(str(h["cls"]), x, 166, "Manrope", 700, 12, ORANGE, 3.0)
	_t(str(h["t"]), x, 250, "Oswald", 500, 78, Color.WHITE)
	_t(str(h["sub"]), x, 294, "Oswald", 300, 26, Color(0.67, 0.7, 0.68), 1.5)
	var yy := _para(str(h["desc"]), x, 340, 440, "Manrope", 500, 15, Color(0.6, 0.63, 0.61), 24.0)
	# ТТХ
	var specs := [["ТЯГООЗБРОЄНІСТЬ", "%.1f" % float(P["tw"]), float(P["tw"]) / 5.5],
		["КУТОВА ШВИДКІСТЬ", "%d °/с" % int(P["rate"]), float(P["rate"]) / 800.0],
		["МАСА", "%.2f кг" % float(P["mass"]), float(P["mass"]) / 7.5],
		["ЗУМ ГІМБАЛА" if h["id"] == "wing" else "ШВИДКІСТЬ GPS", "×60" if h["id"] == "wing" else "%d м/с" % int(P["gps_v"]),
			1.0 if h["id"] == "wing" else float(P["gps_v"]) / 30.0]]
	yy += 48.0
	for sp: Array in specs:
		_t(str(sp[0]), x, yy, "Manrope", 700, 11, Color(0.49, 0.52, 0.5), 2.0)
		_t(str(sp[1]), x + 440, yy + 1, "Oswald", 500, 18, Color(0.93, 0.95, 0.94), 0.5, 2)
		_panel.draw_rect(Rect2(x, yy + 12, 440, 3), Color(0.15, 0.17, 0.16))
		_panel.draw_rect(Rect2(x, yy + 12, 440 * clampf(float(sp[2]), 0.04, 1.0), 3), ORANGE)
		yy += 48.0

	# спорядження (праворуч)
	var wing := str(h["id"]) == "wing"
	var weap: String = "— без зброї" if wing else (_cap1(str(main.targets.WEAPONS[main.targets.weapon])) if main.targets != null else "—")
	var ammo: String = "" if wing or main.targets == null else "×%d" % int(main.targets.weapon_ammo())
	var cam_s: String = main.hud.fpv_link.camera_name() if main.hud != null and main.hud.fpv_link != null else "—"
	var mode_s: String = "автопілот крила" if wing else ["GPS", "ANGLE", "ACRO"][int(main.cam.mode)]
	var skin_s: String = _cap1(str(main.droneview.skin_name())) if main.get("droneview") != null else "—"
	var slots := [["БОЄПРИПАС", weap, ammo], ["КАМЕРА", cam_s, ""], ["РЕЖИМ ПОЛЬОТУ", mode_s, ""],
		["КАМУФЛЯЖ", skin_s, "%d / 3" % (int(main.droneview.skin) if main.get("droneview") != null else 1)]]
	var sx := W - 48.0 - 300.0
	var sy := 140.0
	for j in slots.size():
		var s: Array = slots[j]
		var sr2 := Rect2(sx, sy, 300, 64)
		var on := hangar_row == j + 1
		_panel.draw_rect(sr2, Color(0.08, 0.094, 0.09, 0.85))
		_panel.draw_rect(sr2, ORANGE if on else (Color(0.25, 0.28, 0.26) if _hovered(sr2) else Color(0.165, 0.19, 0.18)), false, 1.0)
		_t(str(s[0]), sx + 16, sy + 24, "Manrope", 700, 10, Color(0.44, 0.47, 0.45), 3.0)
		_t(str(s[1]), sx + 16, sy + 50, "Oswald", 500, 17, Color(0.93, 0.95, 0.94), 0.5)
		if str(s[2]) != "":
			_t(str(s[2]), sx + 262, sy + 50, "Manrope", 600, 13, Color(0.49, 0.52, 0.5), 0.0, 2)
		_t("◂ ▸" if on else "›", sx + 286, sy + 50, "Manrope", 600, 13, ORANGE if on else Color(0.35, 0.38, 0.36), 0.0, 2)
		_hit(Rect2(sx, sy, 150, 64), "hslotl", j + 1)
		_hit(Rect2(sx + 150, sy, 150, 64), "hslot", j + 1)
		sy += 74.0

	# карусель бортів
	var cy := 900.0 - 34.0 - 72.0
	var goW := 260.0
	var cw := (W - 96.0 - goW - 12.0 * HANGAR.size()) / float(HANGAR.size())
	var cx := 48.0
	for i in HANGAR.size():
		var dr: Dictionary = HANGAR[i]
		var rr := Rect2(cx, cy, cw, 72)
		var on := i == hi
		var foc := on and hangar_row == 0
		_panel.draw_rect(rr, Color(1.0, 0.42, 0.17, 0.09) if on else Color(0.07, 0.082, 0.078, 0.85))
		_panel.draw_rect(rr, ORANGE if on else (Color(0.3, 0.33, 0.31) if _hovered(rr) else Color(0.165, 0.19, 0.18)), false, 2.0 if foc else 1.0)
		_t(str(dr["t"]), cx + 18, cy + 32, "Oswald", 500, 19, Color.WHITE if on else Color(0.81, 0.84, 0.82), 1.0)
		_t(str(dr["s"]), cx + 18, cy + 55, "Manrope", 500, 12, Color(0.44, 0.47, 0.45))
		_hit(rr, "hdrone", i)
		cx += cw + 12.0
	var go := Rect2(W - 48.0 - goW, cy, goW, 72)
	_panel.draw_rect(go, ORANGE.lightened(0.1) if _hovered(go) else ORANGE)
	_t("ДО ВИЛЬОТУ →", go.position.x + 24, cy + 36, "Oswald", 600, 22, Color(0.08, 0.03, 0.0), 3.0)
	_t("Enter · вільний політ", go.position.x + 24, cy + 57, "Manrope", 600, 12, Color(0.08, 0.03, 0.0, 0.75))
	_hit(go, "hgo")
	_keys([["↑↓", "рядок"], ["◂▸", "змінити"], ["ENTER", "до вильоту"], ["ESC", "назад"]], 48, 780, Color(1, 1, 1, 0.35))


func _ellipse(c: Vector2, rad: Vector2, col: Color, width: float) -> void:
	var pts := PackedVector2Array()
	for i in 65:
		var a := TAU * i / 64.0
		pts.append(c + Vector2(cos(a) * rad.x, sin(a) * rad.y))
	_panel.draw_polyline(pts, col, width, true)


# ============================ НАЛАШТУВАННЯ / РЕПЛЕЇ ============================

func _side_screen(title: String, sub: String) -> float:
	_panel.draw_rect(Rect2(0, 0, 720, 900), Color(0.035, 0.045, 0.04, 0.93))
	_grad(Rect2(720, 0, 220, 900), Color(0.035, 0.045, 0.04, 0.93), Color(0.035, 0.045, 0.04, 0.0), false)
	var bk := Rect2(64, 48, 140, 30)
	_t("← ESC · НАЗАД", 64, 70, "mono", 500, 12, INK if _hovered(bk) else MUTE, 1.5)
	_hit(bk, "back")
	_t(sub, 64, 150, "mono", 600, 12, AMBER, 3.0)
	_t(title, 64, 212, "Unbounded", 300, 44, Color.WHITE, 1.0)
	return 290.0


func _draw_settings() -> void:
	var y := _side_screen("Налаштування", "ПАРАМЕТРИ ТРЕНАЖЕРА")
	var rc_v: String = ("налаштовано · " + str(main.rc.joy_name()).left(16)) if main.rc.configured else \
		(("знайдено: " + str(main.rc.joy_name()).left(14) + " — майстер") if main.rc.joy_name() != "" else "не підключено")
	var vals := {
		"region": ["Регіон", _region_name(), "перезапуск сцени"],
		"weather": ["Погода", str(main.weather.label), ""],
		"quality": ["Якість графіки", str(main.QUALITY_NAMES[main.quality]).capitalize(), ""],
		"trees": ["Дерева", "Версія 2 · Meshy" if int(main.trees_ver) == 2 else "Версія 1 · класика", "перезапуск сцени"],
		"sound": ["Звук", "вимкнено" if main.hud != null and main.hud._sound_muted else "увімкнено", "M"],
		"rc": ["Пульт", rc_v, "Enter — майстер калібрування"],
		"rates": ["Рейти", str(main.rc.rates_label()), "Betaflight Actual"],
	}
	for i in SETTINGS_ITEMS.size():
		var it: String = SETTINGS_ITEMS[i]
		var v: Array = vals[it]
		var rr := Rect2(48, y - 34, 610, 62)
		var on := i == settings_sel
		if on:
			_panel.draw_rect(rr, Color(0.94, 0.67, 0.24, 0.08))
			_panel.draw_rect(Rect2(48, y - 34, 2, 62), AMBER)
		_t(str(v[0]), 64, y, "Manrope", 600, 18, Color.WHITE if on else Color(0.78, 0.8, 0.78))
		if str(v[2]) != "":
			_t(str(v[2]), 64, y + 20, "Manrope", 500, 12, MUTE)
		var val: String = ("◂  %s  ▸" % v[1]) if on else str(v[1])
		_t(val, 640, y + 4, "mono", 500, 14, AMBER if on else DIMC, 0.0, 2)
		_hit(Rect2(48, y - 34, 420, 62), "setting", i)
		_hit(Rect2(468, y - 34, 90, 62), "settingl", i)
		_hit(Rect2(558, y - 34, 100, 62), "setting", i)
		y += 74.0
	# пам'ятка керування
	var px := 800.0
	var py := 250.0
	_panel.draw_rect(Rect2(px, py, 560, 440), Color(0.03, 0.04, 0.035, 0.8))
	_panel.draw_rect(Rect2(px, py, 560, 440), Color(1, 1, 1, 0.08), false, 1.0)
	_t("КЕРУВАННЯ", px + 28, py + 42, "mono", 600, 12, AMBER, 3.0)
	_t("у грі — тримай I", px + 532, py + 42, "mono", 500, 11, MUTE, 0.0, 2)
	var rows := [["W/S · A/D · E/Q", "тангаж · крен · газ"], ["миша / ← →", "рискання (у GPS — огляд)"],
		["Tab · B · C", "режим · дрон · камера"], ["U", "вид з борту ⇄ третя особа"],
		["F · T · Y", "FPV-окуляри · тепловізор · палітра"],
		["ЛКМ / Пробіл", "мітка SHARK · автодовід FPV"], ["колесо / − =", "зум SHARK · швидкість GPS"],
		["V · H · J", "зброя · ретранслятор · матка"], ["N · R", "наступна місія · рестарт"],
		["1–5, 8 · 6 · 7", "погода · туман · дощ"], ["G · M · Esc", "якість · звук · меню"]]
	var yy := py + 86.0
	for rw: Array in rows:
		var kw := _tw(str(rw[0]), "mono", 500, 12) + 14.0
		_panel.draw_rect(Rect2(px + 28, yy - 16, kw, 22), Color(1, 1, 1, 0.07))
		_t(str(rw[0]), px + 35, yy, "mono", 500, 12, INK)
		_t(str(rw[1]), px + 220, yy, "Manrope", 500, 14, DIMC)
		yy += 32.0


func _draw_replays() -> void:
	var y := _side_screen("Реплеї", "ТЕЛЕМЕТРІЯ ВИЛЬОТІВ")
	if replay_files.is_empty():
		_para("Записів ще немає. Кожен виліт автоматично пишеться в телеметрію — після польоту він з'явиться тут.", 64, y, 560, "Manrope", 500, 16, DIMC, 26.0)
		return
	var shown := mini(replay_files.size(), 9)
	var start := clampi(replay_pick - 4, 0, maxi(replay_files.size() - shown, 0))
	for i in range(start, start + shown):
		var f := replay_files[i]
		var stamp := f.trim_prefix("flight_").trim_suffix(".csv")
		var parts := stamp.split("_")
		var date: String = parts[0] if parts.size() > 0 else stamp
		var time: String = parts[1].replace("-", ":") if parts.size() > 1 else ""
		var rr := Rect2(48, y - 30, 610, 56)
		var on := i == replay_pick
		if on:
			_panel.draw_rect(rr, Color(0.94, 0.67, 0.24, 0.08))
			_panel.draw_rect(Rect2(48, y - 30, 2, 56), AMBER)
		_t(date, 64, y + 2, "mono", 500, 16, Color.WHITE if on else DIMC)
		_t(time, 230, y + 2, "mono", 500, 16, AMBER if on else MUTE)
		if on:
			_t("ENTER — відтворити", 640, y + 2, "mono", 500, 12, AMBER, 0.0, 2)
		_hit(rr, "replay", i)
		y += 62.0


func _draw_wizard() -> void:
	var W := _W
	_panel.draw_rect(Rect2(0, 0, W, 900), Color(0, 0, 0, 0.55))
	var cw := 700.0
	var ch := 170.0
	var cx := (W - cw) * 0.5
	var cy := (900.0 - ch) * 0.5
	_panel.draw_rect(Rect2(cx, cy, cw, ch), Color(0.03, 0.05, 0.06, 0.97))
	_panel.draw_rect(Rect2(cx, cy, cw, ch), Color(0.55, 0.85, 1.0, 0.7), false, 1.5)
	_t("НАЛАШТУВАННЯ ПУЛЬТА · КРОК %d / 4" % maxi(main.rc.wizard_step + 1, 1), cx + 32, cy + 48, "mono", 600, 13, Color(0.55, 0.85, 1.0), 2.5)
	_t(str(main.rc.wizard_hint), cx + 32, cy + 98, "Manrope", 600, 22, Color.WHITE)
	_t("ESC — скасувати", cx + 32, cy + 140, "mono", 500, 12, MUTE, 1.5)
