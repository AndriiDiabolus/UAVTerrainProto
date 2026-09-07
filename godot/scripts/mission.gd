extends Node3D

## Физический код клавиши — хоткеи не зависят от раскладки.
func _kc(event: InputEventKey) -> int:
	return event.physical_keycode if event.physical_keycode != 0 else event.keycode
## Миссии-упражнения тренажёра: ворота, посадка, разведка, удар. Скоринг + результат в файл.
##
## N — следующая миссия (нет → 1 → 2 → … → нет), --mission=N — стартовать сразу.
## Координаты шагов — смещения (dx, dz) в метрах от точки старта миссии (home) и высота AGL,
## поэтому миссии переносимы между регионами.
##
## Скоринг: 100 базовых − штраф за время сверх норматива (1 балл / 2 с) − 15 за пропуск ворот
## − 20 за краш (миссия при краше НЕ заканчивается: R — рестарт с текущего шага, но штраф остаётся).
## Батарея 0 → провал.

var main: Node3D
var active := false
var mission_id := 0                  # 0 = нет
var step := 0
var t := 0.0
var score := 100.0
var crashes := 0
var missed := 0
var max_speed := 0.0
var _agl_sum := 0.0
var _agl_n := 0
var _prev_pos := Vector3.ZERO
var _steps: Array = []               # текущие шаги (Dictionary с "kind", "pos", ...)
var _origin := Vector3.ZERO
var _origin_yaw := 0.0
var _gate_nodes: Array = []
var _pad_node: MeshInstance3D
var _hold_t := 0.0
var _result_label: Label
var _strike_targets: Array = []
var _marked_snapshot: Array = []
var _mission_marks: Array = []       # власна група цілей для mark із "kinds" (чужі мітки не рахуються)
var _quest: Array = []               # фази квесту (копія з місії, з done-прапорцями сабів)
var last_result := {}          # разбор последнего вылета для карточки результатов (hud_min)
var result_text := ""
var _hint_t := 0.0

const MISSIONS := [
	{},   # 0 — нет
	{"name": "1 · Зліт — коридор — посадка", "mode": "angle", "par": 90.0,
	 "steps": [
		{"kind": "takeoff", "agl": 8.0},
		{"kind": "gate", "dx": 0, "dz": -120, "agl": 15, "r": 7},
		{"kind": "gate", "dx": 60, "dz": -260, "agl": 20, "r": 7},
		{"kind": "gate", "dx": -40, "dz": -420, "agl": 25, "r": 7},
		{"kind": "gate", "dx": 20, "dz": -600, "agl": 18, "r": 7},
		{"kind": "gate", "dx": 0, "dz": -760, "agl": 12, "r": 7},
		{"kind": "land", "dx": 0, "dz": -840, "r": 6},
	 ]},
	{"name": "2 · Слалом ACRO (низько)", "mode": "acro", "par": 60.0,
	 "steps": [
		{"kind": "gate", "dx": 40, "dz": -90, "agl": 6, "r": 5},
		{"kind": "gate", "dx": -40, "dz": -170, "agl": 8, "r": 5},
		{"kind": "gate", "dx": 45, "dz": -250, "agl": 6, "r": 5},
		{"kind": "gate", "dx": -45, "dz": -330, "agl": 10, "r": 5},
		{"kind": "gate", "dx": 40, "dz": -410, "agl": 6, "r": 5},
		{"kind": "gate", "dx": -30, "dz": -490, "agl": 14, "r": 5},
		{"kind": "gate", "dx": 0, "dz": -560, "agl": 5, "r": 5},
		{"kind": "gate", "dx": 0, "dz": -640, "agl": 5, "r": 5},
	 ]},
	{"name": "3 · Розвідка за хребтом", "mode": "angle", "par": 240.0,
	 "steps": [
		{"kind": "takeoff", "agl": 8.0},
		{"kind": "recon", "auto": true, "hold": 5.0, "r": 120.0},   # точка выбирается там, где LOS от home < 0.3
		{"kind": "gate", "dx": 0, "dz": -60, "agl": 20, "r": 12},   # вернуться в зону сигнала
		{"kind": "land", "dx": 0, "dz": 0, "r": 8},
	 ]},
	{"name": "4 · Ударний захід", "mode": "angle", "par": 150.0,
	 "steps": [
		{"kind": "takeoff", "agl": 8.0},
		{"kind": "strike", "dx": 0, "dz": -900, "kinds": ["tank", "apc"]},
		{"kind": "land", "dx": 0, "dz": 0, "r": 8},
	 ]},
	{"name": "5 · Розвідка і удар", "mode": "angle", "par": 420.0,
	 "steps": [
		{"kind": "mark", "n": 2},           # SHARK: катапульта, зум, ЛКМ — відмітити 2 цілі
		{"kind": "strike_marked", "n": 2},  # FPV: знищити відмічені цілі
	 ]},
	# Комбіновані місії: погоду задає сама місія ("weather" — індекс пресету weather.gd).
	# mark із "kinds"/"dx/dz" спавнить ВЛАСНУ групу цілей біля дороги — чужі мітки не рахуються.
	{"name": "6 · Повний цикл: SHARK → матка → FPV", "mode": "angle", "par": 600.0, "weather": 1,
	 "steps": [
		{"kind": "mark", "n": 3, "dx": 0, "dz": -1800, "kinds": ["tank", "apc", "soldier"]},
		{"kind": "relay_at", "dx": 0, "dz": -900, "agl": 60, "r": 150},
		{"kind": "strike_marked", "n": 3},
		{"kind": "recon", "dx": 0, "dz": -1800, "agl": 80, "hold": 4.0, "r": 120.0},   # БДА
	 ],
	 "quest": [
		{"who": "SHARK · розвідка", "step": 0, "subs": [
			{"t": "перемкнись на крило SHARK (B)", "k": "drone", "id": "wing"},
			{"t": "катапультний старт — набери хід", "k": "agl", "v": 15.0},
			{"t": "займи безпечну висоту 300 м (поза ППО)", "k": "agl", "v": 300.0},
			{"t": "вийди в район цілей", "k": "reach", "v": 700.0},
			{"t": "відміть цілі %d/%d (зум −/=, ЛКМ)", "k": "marks"},
		]},
		{"who": "МАТКА · ретранслятор", "step": 1, "subs": [
			{"t": "перемкнись на матку-носій (B)", "k": "drone", "id": "mship"},
			{"t": "дійди до рубежу звʼязку", "k": "reach", "v": 160.0},
			{"t": "розгорни ретранслятор (H) чи відділи FPV (J)", "k": "step"},
		]},
		{"who": "FPV · удар", "step": 2, "subs": [
			{"t": "перемкнись на FPV (B)", "k": "drone", "id": "fpv"},
			{"t": "дістанься відміток", "k": "near_mark", "v": 400.0},
			{"t": "знищ відмічені цілі %d/%d", "k": "kills"},
		]},
		{"who": "SHARK · БДА", "step": 3, "subs": [
			{"t": "повернись на крило (B)", "k": "drone", "id": "wing"},
			{"t": "вийди над точку удару", "k": "reach", "v": 130.0},
			{"t": "утримуйся 4 с — підтвердь ураження", "k": "step"},
		]},
	 ]},
	{"name": "7 · Нічна засідка", "mode": "angle", "par": 480.0, "weather": 4,
	 "steps": [
		{"kind": "mark", "n": 2, "dx": 0, "dz": -1200, "kinds": ["apc", "soldier"]},
		{"kind": "relay_at", "dx": 0, "dz": -600, "agl": 50, "r": 120},
		{"kind": "strike_marked", "n": 2},
	 ],
	 "quest": [
		{"who": "SHARK · нічна розвідка", "step": 0, "subs": [
			{"t": "перемкнись на крило SHARK (B)", "k": "drone", "id": "wing"},
			{"t": "увімкни тепловізор (T)", "k": "cam", "v": 3},
			{"t": "займи висоту 250 м", "k": "agl", "v": 250.0},
			{"t": "вийди в район засідки", "k": "reach", "v": 600.0},
			{"t": "відміть теплі цілі %d/%d (зум, ЛКМ)", "k": "marks"},
		]},
		{"who": "МАТКА · ретранслятор", "step": 1, "subs": [
			{"t": "перемкнись на матку-носій (B)", "k": "drone", "id": "mship"},
			{"t": "дійди до рубежу впотемки", "k": "reach", "v": 130.0},
			{"t": "розгорни ретранслятор (H) чи відділи FPV (J)", "k": "step"},
		]},
		{"who": "FPV · удар", "step": 2, "subs": [
			{"t": "перемкнись на FPV (B)", "k": "drone", "id": "fpv"},
			{"t": "тепловізор або нічна камера (T/C)", "k": "cam_any", "v": 2},
			{"t": "дістанься відміток", "k": "near_mark", "v": 350.0},
			{"t": "знищ цілі %d/%d", "k": "kills"},
		]},
	 ]},
]


func setup(m: Node3D) -> void:
	main = m
	if main.targets != null:
		main.targets.target_killed.connect(_on_kill)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--mission="):
			call_deferred("start", int(a.substr(10)))


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if _kc(event) == KEY_N:
			var nxt := (mission_id + 1) % MISSIONS.size()
			if nxt == 0:
				stop()
			else:
				start(nxt)


func mission_name() -> String:
	return str(MISSIONS[mission_id].get("name", "")) if mission_id > 0 else ""


func start(id: int) -> void:
	if id <= 0 or id >= MISSIONS.size():
		return
	stop()
	mission_id = id
	active = true
	step = 0; t = 0.0; score = 100.0; crashes = 0; missed = 0; max_speed = 0.0
	_agl_sum = 0.0; _agl_n = 0; _hold_t = 0.0
	result_text = ""
	last_result = {}
	if _result_label != null: _result_label.visible = false
	var m: Dictionary = MISSIONS[id]
	# origin — текущая home-точка (точка взлёта), курс — на юг вдоль долины (как стартовая камера)
	_origin = _clear_spot(main._home_pos)
	# курс миссии = текущий курс дрона: «dz < 0» — вперёд по курсу на момент старта
	_origin_yaw = main.cam.attitude().get_euler().y if main.cam.has_method("attitude") else 0.0
	main._home_pos = _origin + Vector3(0, 0.4, 0)     # R-рестарт — на площадку, не в воздух
	if main._fpv_osd != null:
		main._fpv_osd.home = main._home_pos
	# дрон ставим на землю в origin, режим — рекомендованный
	main.crashed = false
	main.cam.global_position = _origin + Vector3(0, 0.4, 0)
	if main.cam.has_method("reset"):
		main.cam.reset()
	if main.targets != null:
		main.targets.reset_ammo()
	# рекомендованный режим: с пультом ставим сразу; на клавиатуре из GPS — не ломаем привычное управление,
	# только подсказываем (Tab). В любом случае показываем шпаргалку по управлению на 8 с.
	var want: String = str(m.get("mode", "angle"))
	var want_i: int = {"gps": 0, "angle": 1, "acro": 2}.get(want, 1)
	var has_joy: bool = str(main.cam.get("joy_name")) != ""
	var switched := false
	if has_joy or int(main.cam.mode) != 0:
		main.cam.mode = want_i
		switched = true
	var names := ["GPS", "ANGLE", "ACRO"]
	var tips := {
		0: "GPS: W/S вперед-назад · A/D вбік · E/Q вгору-вниз · миша — камера",
		1: "ANGLE: W/S нахил · A/D крен · E/Q газ (без утримання висоти) · миша/←→ рискання",
		2: "ACRO: W/S — швидкість тангажа · A/D — крену · E/Q газ · миша/←→ рискання · вирівнювання немає",
	}
	var cur: int = int(main.cam.mode)
	var hint := "МІСІЯ %s\nРежим польоту: %s%s\n%s\nTab — змінити режим · N — наступна місія" % [
		m["name"], names[cur], "" if switched or cur == want_i else "  (рекомендовано %s — натисни Tab)" % names[want_i], tips[cur]]
	if _result_label != null:
		_result_label.text = hint
		_result_label.visible = true
		_hint_t = 8.0
	_marked_snapshot = []
	_mission_marks = []
	_quest = []
	for ph: Dictionary in m.get("quest", []):
		var pc := ph.duplicate(true)
		for sub: Dictionary in pc["subs"]:
			sub["done"] = false
		_quest.append(pc)
	# погода місії: комбіновані вильоти самі ставлять умови (вітер, ніч)
	if m.has("weather") and main.weather != null:
		main.weather.apply(int(m["weather"]), true)
	# старий ретранслятор у зоні відразу закрив би relay_at — знімаємо
	if main.relay_node != null:
		main.relay_node.queue_free()
		main.relay_node = null
	_steps = []
	for s: Dictionary in m["steps"]:
		var st := s.duplicate()
		st["pos"] = _resolve(st)
		st["done"] = false
		_steps.append(st)
	_build_visuals()
	if main.get("telemetry") != null:
		main.telemetry.event("mission_start", {"id": id, "name": m["name"]})
	print("MISSION start: ", m["name"])
	_prev_pos = main.cam.global_position


func stop() -> void:
	active = false
	mission_id = 0
	_steps = []
	_strike_targets = []
	_mission_marks = []
	for g in _gate_nodes: g.queue_free()
	_gate_nodes = []
	if _pad_node != null:
		_pad_node.queue_free(); _pad_node = null


## Свободная площадка на земле рядом с точкой: без зданий/столбов/деревьев в столбе взлёта 0–12 м.
func _clear_spot(near: Vector3) -> Vector3:
	var best := Vector3(near.x, main.height_at(near.x, near.z), near.z)
	for ring in range(0, 12):
		var r := ring * 18.0
		var n := 1 if ring == 0 else ring * 6
		for i in n:
			var a := TAU * i / n
			var x := near.x + cos(a) * r; var z := near.z + sin(a) * r
			var g: float = main.height_at(x, z)
			var clean := true
			for h: float in [1.0, 4.0, 8.0, 12.0]:
				if main.check_crash(Vector3(x, g + h, z)) != "":
					clean = false; break
			if clean:
				return Vector3(x, g, z)
	return best


## Позиция шага в мире.
func _resolve(s: Dictionary) -> Vector3:
	var kind: String = s["kind"]
	if kind == "takeoff" or kind == "strike_marked" or (kind == "mark" and not s.has("dx")):
		return _origin
	if kind == "recon" and s.get("auto", false):
		return _find_hidden_point()
	var dx: float = float(s.get("dx", 0)); var dz: float = float(s.get("dz", 0))
	var rot := Basis(Vector3.UP, _origin_yaw)
	var off: Vector3 = rot * Vector3(dx, 0, dz)
	var x := _origin.x + off.x; var z := _origin.z + off.z
	var g: float = main.height_at(x, z)
	return Vector3(x, g + float(s.get("agl", 0.0)), z)


## Точка разведки: 900–1600 м от home, где радиовидимость от оператора (home+2 м) хуже всего.
func _find_hidden_point() -> Vector3:
	var op := _origin + Vector3(0, 2, 0)
	var best := _origin + Vector3(0, 30, -1200)
	var best_los := 2.0
	for i in 48:
		var a := TAU * i / 48.0
		for d: float in [900.0, 1200.0, 1600.0]:
			var x := _origin.x + cos(a) * d; var z := _origin.z + sin(a) * d
			var p := Vector3(x, main.height_at(x, z) + 30.0, z)
			var l: float = main.los_factor(op, p)
			if l < best_los:
				best_los = l; best = p
	print("MISSION recon point LOS=%.2f at %s" % [best_los, best])
	return best


func _build_visuals() -> void:
	for i in _steps.size():
		var s: Dictionary = _steps[i]
		if s["kind"] == "gate":
			var mi := MeshInstance3D.new()
			var tor := TorusMesh.new()
			tor.inner_radius = float(s["r"]) - 0.6
			tor.outer_radius = float(s["r"])
			tor.rings = 24; tor.ring_segments = 12
			mi.mesh = tor
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = Color(0.3, 0.9, 0.4)
			mat.emission_enabled = true
			mat.emission = Color(0.3, 0.9, 0.4)
			mat.emission_energy_multiplier = 1.5
			mi.material_override = mat
			mi.position = s["pos"]
			# ворота смотрят на предыдущую точку (или на origin)
			var prev: Vector3 = _steps[i - 1]["pos"] if i > 0 else _origin
			var n: Vector3 = (s["pos"] - prev); n.y = 0.0
			if n.length() < 0.1: n = Vector3(0, 0, -1)
			s["n"] = n.normalized()
			mi.look_at_from_position(mi.position, mi.position + s["n"], Vector3.UP)
			mi.rotate_object_local(Vector3.RIGHT, PI * 0.5)     # тор лежит в XZ → ставим стоймя
			add_child(mi)
			s["node"] = mi
			_gate_nodes.append(mi)
		elif s["kind"] == "land":
			var mi := MeshInstance3D.new()
			var cyl := CylinderMesh.new()
			cyl.top_radius = float(s["r"]); cyl.bottom_radius = float(s["r"]); cyl.height = 0.3
			mi.mesh = cyl
			var mat := StandardMaterial3D.new()
			mat.albedo_color = Color(0.9, 0.85, 0.2)
			mat.emission_enabled = true; mat.emission = Color(0.9, 0.85, 0.2); mat.emission_energy_multiplier = 0.6
			mi.material_override = mat
			var p: Vector3 = s["pos"]
			mi.position = Vector3(p.x, main.height_at(p.x, p.z) + 0.15, p.z)
			add_child(mi)
			s["node"] = mi
			_gate_nodes.append(mi)
		elif s["kind"] == "recon" or s["kind"] == "relay_at":
			var mi := MeshInstance3D.new()
			var sph := SphereMesh.new(); sph.radius = 6.0; sph.height = 12.0
			mi.mesh = sph
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			# розвідка — блакитна, рубіж ретранслятора — бурштинова (як мітки НСУ)
			mat.albedo_color = Color(0.4, 0.7, 1.0, 0.7) if s["kind"] == "recon" else Color(1.0, 0.65, 0.2, 0.7)
			mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			mi.material_override = mat
			var p: Vector3 = s["pos"]
			mi.position = Vector3(p.x, main.height_at(p.x, p.z) + 3.0, p.z)
			add_child(mi)
			s["node"] = mi
			_gate_nodes.append(mi)
	_refresh_colors()


func _refresh_colors() -> void:
	for i in _steps.size():
		var s: Dictionary = _steps[i]
		if not s.has("node"): continue
		var mat: StandardMaterial3D = s["node"].material_override
		if s["done"]:
			s["node"].visible = false
		elif i == step:
			mat.albedo_color = Color(0.3, 1.0, 0.4); mat.emission_energy_multiplier = 2.5
			if s["kind"] == "gate": mat.albedo_color = Color(0.3, 1.0, 0.4)
		else:
			mat.albedo_color = Color(0.5, 0.6, 0.6); mat.emission_energy_multiplier = 0.4


func current_step() -> Dictionary:
	if not active or step >= _steps.size():
		return {}
	return _steps[step]


func _process(dt: float) -> void:
	if _hint_t > 0.0:
		_hint_t -= dt
		if _hint_t <= 0.0 and _result_label != null and result_text == "":
			_result_label.visible = false
	if not active or main == null or main.cam == null:
		return
	if step >= _steps.size():
		return
	t += dt
	var cam: Camera3D = main.cam
	var pos: Vector3 = cam.global_position
	var spd: float = cam.speed()
	max_speed = maxf(max_speed, spd)
	var agl: float = pos.y - main.height_at(pos.x, pos.z)
	_agl_sum += agl; _agl_n += 1
	if main.crashed:
		_prev_pos = pos
		return
	var s: Dictionary = _steps[step]
	var done := false
	match s["kind"]:
		"takeoff":
			done = agl >= float(s["agl"])
		"gate":
			done = _crossed_gate(s, _prev_pos, pos)
			# пропуск: пролетели мимо плоскости ворот дальше 3 радиусов и уже за ней на 40 м
			var n: Vector3 = s["n"]
			var beyond: float = (pos - s["pos"]).dot(n)
			if not done and beyond > 40.0:
				missed += 1
				score -= 15.0
				done = true
				if main.get("telemetry") != null: main.telemetry.event("gate_missed", {"step": step})
		"land":
			var d := Vector2(pos.x - s["pos"].x, pos.z - s["pos"].z).length()
			done = cam.get("landed") == true and d < float(s["r"])
		"recon":
			var d := pos.distance_to(s["pos"])
			if d < float(s["r"]):
				_hold_t += dt
			else:
				_hold_t = maxf(0.0, _hold_t - dt * 0.5)
			done = _hold_t >= float(s["hold"])
		"strike":
			if _strike_targets.is_empty():
				_strike_targets = main.targets.spawn_near(s["pos"], s["kinds"])
			var alive := 0
			for tg in _strike_targets:
				if tg.alive: alive += 1
			done = alive == 0 and not _strike_targets.is_empty()
		"mark":
			if s.has("kinds") and main.targets != null:
				# власна група: спавн один раз біля дальньої дороги, рахуємо мітки лише з неї
				if _mission_marks.is_empty():
					_mission_marks = main.targets.spawn_near(s["pos"], s["kinds"])
				var mked := 0
				for tg in _mission_marks:
					if tg.alive and tg.get("marked", false): mked += 1
				done = not _mission_marks.is_empty() and mked >= int(s["n"])
			else:
				done = main.targets != null and main.targets.marked_list().size() >= int(s["n"])
		"relay_at":
			# ретранслятор (H) або матка після відділення FPV (J) — у радіусі від рубежу
			if main.relay_node != null:
				var rd := Vector2(main.relay_pos.x - s["pos"].x, main.relay_pos.z - s["pos"].z).length()
				done = rd < float(s["r"])
		"strike_marked":
			# фиксируем отмеченный набор один раз, затем считаем уничтоженных из него
			if _marked_snapshot.is_empty():
				var src: Array = _mission_marks if not _mission_marks.is_empty() else \
					(main.targets.targets if main.targets != null else [])
				for tg in src:
					if tg.get("marked", false):
						_marked_snapshot.append(tg)
			var killed := 0
			for tg in _marked_snapshot:
				if not tg.alive: killed += 1
			done = not _marked_snapshot.is_empty() and killed >= int(s["n"])
	_quest_tick(pos, agl)
	if done:
		s["done"] = true
		if main.get("telemetry") != null: main.telemetry.event("step_done", {"step": step, "kind": s["kind"], "t": t})
		step += 1
		_hold_t = 0.0
		_refresh_colors()
		if step >= _steps.size():
			_finish(true)
	# батарея (FPV OSD) села → провал
	if main._fpv_osd != null and main._fpv_osd.battery <= 0.0:
		_finish(false)
	_prev_pos = pos


func _crossed_gate(s: Dictionary, a: Vector3, b: Vector3) -> bool:
	var c: Vector3 = s["pos"]; var n: Vector3 = s["n"]
	var d0 := (a - c).dot(n); var d1 := (b - c).dot(n)
	if d0 > 0.0 or d1 < 0.0:
		return false
	if absf(d1 - d0) < 1e-6:
		return false
	var k := d0 / (d0 - d1)
	var p := a.lerp(b, k)
	return (p - c).length() < float(s["r"])


func on_crash() -> void:
	if not active:
		return
	crashes += 1
	score -= 20.0
	if main.get("telemetry") != null: main.telemetry.event("crash", {"step": step})


func _on_kill(kind: String, pos: Vector3) -> void:
	if main.get("telemetry") != null: main.telemetry.event("kill", {"kind": kind, "x": pos.x, "z": pos.z})


func _finish(success: bool) -> void:
	var m: Dictionary = MISSIONS[mission_id]
	var par: float = float(m.get("par", 120.0))
	if success:
		score -= maxf(0.0, t - par) / 2.0
	else:
		score = 0.0
	score = clampf(score, 0.0, 100.0)
	var avg_agl := _agl_sum / maxf(1.0, float(_agl_n))
	var res := {
		"mission": m["name"], "success": success, "score": int(round(score)),
		"time_s": snappedf(t, 0.1), "par_s": par, "crashes": crashes, "gates_missed": missed,
		"max_speed_ms": snappedf(max_speed, 0.1), "avg_agl_m": snappedf(avg_agl, 0.1),
		"drone": str(main.cam.drone_id), "mode": str(main.cam.mode_name()),
		"date": Time.get_datetime_string_from_system(false, true),
		"pen_time": int(round(maxf(0.0, t - par) / 2.0)) if success else 0,
		"pen_crash": crashes * 20, "pen_gates": missed * 15,
	}
	last_result = res
	result_text = "%s\n%s   ОЦІНКА %d / 100\nчас %.0f с (норматив %.0f) · крашів %d · пропущено воріт %d\nмакс. швидкість %.0f м/с · середня AGL %.0f м\nN — наступна місія" % [
		m["name"], "ВИКОНАНО" if success else "ПРОВАЛ", int(round(score)), t, par, crashes, missed, max_speed, avg_agl]
	if _result_label != null:
		_result_label.visible = false            # стартовая шпаргалка не должна лежать на карточке
		_hint_t = 0.0
	_save_result(res)
	if main.get("telemetry") != null: main.telemetry.event("mission_end", res)
	print("MISSION %s: %s" % ["OK" if success else "FAIL", JSON.stringify(res)])
	active = false


func _save_result(res: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://results"))
	var csv := "user://results/results.csv"
	var new_file := not FileAccess.file_exists(csv)
	var f := FileAccess.open(csv, FileAccess.READ_WRITE if not new_file else FileAccess.WRITE)
	if f == null:
		return
	if new_file:
		f.store_line("date,mission,success,score,time_s,par_s,crashes,gates_missed,max_speed_ms,avg_agl_m,drone,mode")
	else:
		f.seek_end()
	f.store_line("%s,\"%s\",%s,%d,%.1f,%.0f,%d,%d,%.1f,%.1f,%s,\"%s\"" % [
		res.date, res.mission, res.success, res.score, res.time_s, res.par_s, res.crashes,
		res.gates_missed, res.max_speed_ms, res.avg_agl_m, res.drone, res.mode])
	f.close()
	print("Результат записан: ", ProjectSettings.globalize_path(csv))


## Самотест (--missiontest): телепортируем дрон через шаги миссии 1 и проверяем скоринг/запись.
func self_test() -> bool:
	start(1)
	var cam: Camera3D = main.cam
	var ok := active and _steps.size() == 7
	print("MISSIONTEST старт: active=%s steps=%d" % [active, _steps.size()])
	# взлёт
	cam.global_position = _origin + Vector3(0, 12, 0); _prev_pos = cam.global_position
	_process(0.1)
	ok = ok and step == 1
	print("MISSIONTEST takeoff → step=%d (ждём 1)" % step)
	# ворота 1..5: подлёт с фронта, пролёт сквозь центр
	for i in range(1, 6):
		var g: Dictionary = _steps[i]
		var n: Vector3 = g["n"]
		cam.global_position = g["pos"] - n * 5.0; _prev_pos = cam.global_position
		_process(0.05)
		cam.global_position = g["pos"] + n * 5.0
		_process(0.05)
	ok = ok and step == 6 and missed == 0
	print("MISSIONTEST 5 ворот → step=%d missed=%d (ждём 6, 0)" % [step, missed])
	# посадка: ставим на площадку, landed = true
	var l: Dictionary = _steps[6]
	cam.global_position = Vector3(l["pos"].x, main.height_at(l["pos"].x, l["pos"].z) + 0.35, l["pos"].z)
	cam.landed = true
	_process(0.05)
	ok = ok and not active and result_text != "" and score > 90.0
	print("MISSIONTEST посадка → active=%s score=%.0f (ждём false, >90)" % [active, score])
	# пропуск ворот
	start(2)
	var g2: Dictionary = _steps[0]
	cam.global_position = g2["pos"] + g2["n"] * 60.0 + Vector3(30, 0, 0); _prev_pos = cam.global_position
	_process(0.05)
	ok = ok and step == 1 and missed == 1
	print("MISSIONTEST пропуск ворот → step=%d missed=%d (ждём 1, 1)" % [step, missed])
	# комбинированная миссия 6: своя группа целей → рубеж ретранслятора → удар → БДА
	start(6)
	var ok6 := active and _steps.size() == 4
	_process(0.05)                                    # первый тик спавнит группу mark
	ok6 = ok6 and not _mission_marks.is_empty()
	for tg in _mission_marks: tg.marked = true
	_process(0.05)
	ok6 = ok6 and step == 1
	print("MISSIONTEST м6 mark: группа=%d step=%d (ждём >0, 1)" % [_mission_marks.size(), step])
	var rz: Dictionary = _steps[1]
	cam.global_position = rz["pos"]; _prev_pos = cam.global_position
	main.toggle_relay()
	_process(0.05)
	ok6 = ok6 and step == 2
	print("MISSIONTEST м6 relay_at → step=%d (ждём 2)" % step)
	_process(0.05)                                    # снапшот отмеченных
	for tg in _marked_snapshot: tg.alive = false
	_process(0.05)
	ok6 = ok6 and step == 3
	print("MISSIONTEST м6 strike_marked → step=%d (ждём 3)" % step)
	var bda: Dictionary = _steps[3]
	cam.global_position = bda["pos"]; _prev_pos = cam.global_position
	_process(4.2)                                     # hold 4 c в зоне БДА одним тиком
	ok6 = ok6 and not active
	print("MISSIONTEST м6 БДА/финиш: active=%s (ждём false)" % active)
	if main.relay_node != null:
		main.toggle_relay()                           # прибрать ретранслятор за собой
	ok = ok and ok6
	stop()
	var csv_ok := FileAccess.file_exists("user://results/results.csv")
	ok = ok and csv_ok
	print("MISSIONTEST results.csv: %s" % csv_ok)
	print("MISSIONTEST итог: %s" % ("ВСЕ OK" if ok else "ЕСТЬ FAIL"))
	return ok


# ---------------- квест: тактичні саб-задачі (панель зліва, місії 6-7) ----------------

## Латчимо виконання сабів АКТИВНОЇ фази; пройдені фази закриваються цілком.
func _quest_tick(pos: Vector3, agl: float) -> void:
	for ph: Dictionary in _quest:
		var pstep := int(ph["step"])
		if pstep < step:
			for sub: Dictionary in ph["subs"]:
				sub["done"] = true
			continue
		if pstep > step or pstep >= _steps.size():
			continue
		var stp: Dictionary = _steps[pstep]
		for sub: Dictionary in ph["subs"]:
			if sub["done"]:
				continue
			var ok := false
			match str(sub["k"]):
				"drone":
					var did := str(main.cam.get("drone_id"))
					ok = did == str(sub.get("id")) or (str(sub.get("id")) == "fpv" and did in ["fpv7", "fpv5", "mavic"])
				"agl": ok = agl >= float(sub["v"])
				"cam": ok = main.hud != null and main.hud.fpv_link != null and int(main.hud.fpv_link.camera) == int(sub["v"])
				"cam_any": ok = main.hud != null and main.hud.fpv_link != null and int(main.hud.fpv_link.camera) >= int(sub["v"])
				"reach": ok = Vector2(pos.x - stp["pos"].x, pos.z - stp["pos"].z).length() < float(sub["v"])
				"near_mark":
					for tg in (main.targets.marked_list() if main.targets != null else []):
						if pos.distance_to(tg.node.position) < float(sub["v"]):
							ok = true; break
				"marks", "kills", "step": ok = false   # закриваються разом із кроком (гілка pstep < step)
			if ok:
				sub["done"] = true


## Рядки для панелі квесту: {h: заголовок фази} або {t: текст, st: 0 попереду / 1 поточна / 2 готово}.
func quest_lines() -> Array:
	var out: Array = []
	if _quest.is_empty() or not active:
		return out
	var mked := 0
	for tg in _mission_marks:
		if tg.alive and tg.get("marked", false): mked += 1
	var killed := 0
	for tg in _marked_snapshot:
		if not tg.alive: killed += 1
	for ph: Dictionary in _quest:
		var pstep := int(ph["step"])
		var phase_state := 2 if pstep < step else (1 if pstep == step else 0)
		out.append({"h": ph["who"], "st": phase_state})
		var first_active := true
		for sub: Dictionary in ph["subs"]:
			var txt := str(sub["t"])
			var n := int(_steps[pstep].get("n", 0)) if pstep < _steps.size() else 0
			if str(sub["k"]) == "marks": txt = txt % [mked, n]
			elif str(sub["k"]) == "kills": txt = txt % [killed, n]
			var st := 0
			if bool(sub["done"]) or phase_state == 2:
				st = 2
			elif phase_state == 1 and first_active:
				st = 1
			if st != 2 and phase_state == 1:
				first_active = false
			out.append({"t": txt, "st": st})
	return out


## Строка для HUD.
func hud_line() -> String:
	if not active:
		if result_text != "": return ""
		return "N — почати місію"
	var s := current_step()
	if s.is_empty(): return ""
	var pos: Vector3 = main.cam.global_position
	var what := ""
	match s["kind"]:
		"takeoff": what = "зліт до %d м AGL" % int(s["agl"])
		"gate": what = "ворота %d м" % int(pos.distance_to(s["pos"]))
		"land": what = "посадка на майданчик %d м" % int(Vector2(pos.x - s["pos"].x, pos.z - s["pos"].z).length())
		"recon": what = "розвідка: точка %d м, утримання %.0f/%.0f с" % [int(pos.distance_to(s["pos"])), _hold_t, float(s["hold"])]
		"strike":
			var alive := 0
			for tg in _strike_targets:
				if tg.alive: alive += 1
			what = "знищити цілі біля дороги (%d м), лишилось %d" % [int(pos.distance_to(s["pos"])), alive]
		"mark":
			var mk := 0
			if not _mission_marks.is_empty():
				for tg in _mission_marks:
					if tg.alive and tg.get("marked", false): mk += 1
			elif main.targets != null:
				mk = main.targets.marked_list().size()
			var far_s := (" · група %d м" % int(pos.distance_to(s["pos"]))) if s.has("dx") else ""
			what = "розвідник SHARK (B): відміть цілей %d/%d (зум — колесо/−=, ЛКМ — мітка)%s" % [mk, int(s["n"]), far_s]
		"relay_at":
			var rd := Vector2(pos.x - s["pos"].x, pos.z - s["pos"].z).length()
			what = "рубіж %d м: розгорни ретранслятор у зоні (H · або J — відділити FPV від матки)" % int(rd)
		"strike_marked":
			var killed := 0
			for tg in _marked_snapshot:
				if not tg.alive: killed += 1
			what = "FPV (B): знищ відмічені цілі %d/%d" % [killed, int(s["n"])]
	return "МІСІЯ %s · крок %d/%d · %s · %02d:%02d" % [mission_name(), step + 1, _steps.size(), what,
		int(t) / 60, int(t) % 60]


## Направление к текущей цели шага (для маркера на HUD).
func target_pos() -> Variant:
	var s := current_step()
	if s.is_empty() or s["kind"] == "takeoff":
		return null
	return s["pos"]
