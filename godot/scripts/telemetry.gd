extends Node
## Телеметрия полёта: запись CSV (10 Гц) + журнал событий, реплей записанного полёта.
##
## Запись всегда включена (кроме --screenshot/--replay): user://flights/flight_<дата>.csv
## Колонки: t,x,y,z,agl,vx,vy,vz,speed,pitch,yaw,roll,throttle,mode,st_p,st_r,st_y,st_t,rssi,battery,event
## Реплей: --replay=<путь.csv> (или имя файла из user://flights) — дрон ведётся по записи, ввод отключён,
##   пробел — пауза, ←/→ — перемотка на 5 с, [ ] — скорость ×0.5/×2. Кадры интерполируются.

var main: Node3D
var recording := false
var replaying := false
var path := ""
var _f: FileAccess
var _t := 0.0
var _acc := 0.0
var _pending_events: Array[String] = []
const RATE := 0.1

# реплей
var _frames: Array = []          # массив PackedFloat32Array-подобных Array (числа) по колонкам
var _events: Array = []          # [t, text]
var _rt := 0.0
var _speed := 1.0
var _paused := false
var _idx := 0
var replay_label: Label


func setup(m: Node3D) -> void:
	main = m
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--replay="):
			_load_replay(a.substr(9))
			return
	if "--screenshot" in args or "--flytest" in args or "--coltest" in args:
		return
	_start_recording()


func _start_recording() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://flights"))
	var stamp := Time.get_datetime_string_from_system(false, true).replace(":", "-").replace(" ", "_")
	path = "user://flights/flight_%s.csv" % stamp
	_f = FileAccess.open(path, FileAccess.WRITE)
	if _f == null:
		push_warning("Телеметрия: не удалось открыть " + path)
		return
	_f.store_line("t,x,y,z,agl,vx,vy,vz,speed,pitch,yaw,roll,throttle,mode,st_p,st_r,st_y,st_t,rssi,battery,event")
	recording = true
	print("Телеметрия пишется в ", ProjectSettings.globalize_path(path))


## Событие в журнал (пишется в колонку event ближайшего кадра, несколько — через ';').
func event(name: String, data: Dictionary = {}) -> void:
	if not recording:
		return
	var s := name
	if not data.is_empty():
		s += ":" + JSON.stringify(data).replace(",", "|").replace("\"", "'")
	_pending_events.append(s)


func _process(dt: float) -> void:
	if replaying:
		_step_replay(dt)
		return
	if not recording or main == null or main.cam == null:
		return
	_t += dt
	_acc += dt
	if _acc < RATE:
		return
	_acc -= RATE
	var cam: Camera3D = main.cam
	var p: Vector3 = cam.global_position
	var v: Vector3 = cam.velocity
	var e: Vector3 = cam.attitude().get_euler() if cam.has_method("attitude") else cam.global_transform.basis.get_euler()
	var rssi := 1.0; var bat := 1.0
	if main._fpv_osd != null:
		rssi = main._fpv_osd.signal_q; bat = main._fpv_osd.battery
	var ev := ";".join(_pending_events)
	_pending_events.clear()
	_f.store_line("%.2f,%.2f,%.2f,%.2f,%.1f,%.2f,%.2f,%.2f,%.2f,%.1f,%.1f,%.1f,%.2f,%d,%.2f,%.2f,%.2f,%.2f,%.2f,%.2f,%s" % [
		_t, p.x, p.y, p.z, p.y - main.height_at(p.x, p.z), v.x, v.y, v.z, v.length(),
		rad_to_deg(e.x), rad_to_deg(e.y), rad_to_deg(e.z), float(cam.throttle), int(cam.mode),
		float(cam.st_pitch), float(cam.st_roll), float(cam.st_yaw), float(cam.st_thr), rssi, bat, ev])


func _exit_tree() -> void:
	if _f != null:
		_f.close()
		if recording:
			print("Телеметрия сохранена: ", ProjectSettings.globalize_path(path))


# ============================ реплей ============================

func _load_replay(p: String) -> void:
	if not p.contains("/"):
		p = "user://flights/" + p
	var f := FileAccess.open(p, FileAccess.READ)
	if f == null:
		push_error("Реплей: файл не найден: " + p)
		return
	var header := f.get_line()
	var cols := header.split(",")
	var ci := {}
	for i in cols.size(): ci[cols[i]] = i
	while not f.eof_reached():
		var line := f.get_line()
		if line.strip_edges() == "":
			continue
		var parts := line.split(",")
		if parts.size() < 20:
			continue
		var fr := {
			"t": float(parts[ci.t]), "pos": Vector3(float(parts[ci.x]), float(parts[ci.y]), float(parts[ci.z])),
			"vel": Vector3(float(parts[ci.vx]), float(parts[ci.vy]), float(parts[ci.vz])),
			"eul": Vector3(deg_to_rad(float(parts[ci.pitch])), deg_to_rad(float(parts[ci.yaw])), deg_to_rad(float(parts[ci.roll]))),
			"thr": float(parts[ci.throttle]), "mode": int(parts[ci.mode]),
			"st": Vector4(float(parts[ci.st_p]), float(parts[ci.st_r]), float(parts[ci.st_y]), float(parts[ci.st_t])),
			"rssi": float(parts[ci.rssi]), "bat": float(parts[ci.battery]),
		}
		_frames.append(fr)
		if ci.has("event") and parts.size() > int(ci.event) and parts[ci.event] != "":
			_events.append([fr.t, parts[ci.event]])
	f.close()
	if _frames.is_empty():
		push_error("Реплей: пустой файл")
		return
	replaying = true
	path = p
	main.replaying = true
	print("Реплей: %d кадров, %.0f с, %d событий" % [_frames.size(), _frames[-1].t, _events.size()])


func _unhandled_input(ev: InputEvent) -> void:
	if not replaying or not (ev is InputEventKey and ev.pressed and not ev.echo):
		return
	match ev.keycode:
		KEY_SPACE: _paused = not _paused
		KEY_LEFT: _rt = maxf(0.0, _rt - 5.0)
		KEY_RIGHT: _rt = minf(_frames[-1].t, _rt + 5.0)
		KEY_BRACKETLEFT: _speed = maxf(0.125, _speed * 0.5)
		KEY_BRACKETRIGHT: _speed = minf(8.0, _speed * 2.0)


func _step_replay(dt: float) -> void:
	if _frames.is_empty() or main.cam == null:
		return
	if not _paused:
		_rt += dt * _speed
	var tend: float = _frames[-1].t
	if _rt >= tend:
		_rt = tend
	# найти кадр (последовательный поиск от _idx с откатом при перемотке назад)
	if _idx >= _frames.size() - 1 or _frames[_idx].t > _rt:
		_idx = 0
	while _idx < _frames.size() - 2 and _frames[_idx + 1].t <= _rt:
		_idx += 1
	var a: Dictionary = _frames[_idx]
	var b: Dictionary = _frames[mini(_idx + 1, _frames.size() - 1)]
	var k := 0.0
	if b.t > a.t:
		k = clampf((_rt - a.t) / (b.t - a.t), 0.0, 1.0)
	var cam: Camera3D = main.cam
	cam.global_position = a.pos.lerp(b.pos, k)
	var ba := Basis.from_euler(a.eul); var bb := Basis.from_euler(b.eul)
	var body: Basis = ba.slerp(bb, k)
	cam.body = body
	cam.velocity = a.vel.lerp(b.vel, k)
	cam.throttle = lerpf(a.thr, b.thr, k)
	cam.mode = a.mode
	var st: Vector4 = a.st.lerp(b.st, k)
	cam.st_pitch = st.x; cam.st_roll = st.y; cam.st_yaw = st.z; cam.st_thr = st.w
	# камера: как в полёте — подвес в GPS, жёстко на корпусе в остальных
	if a.mode == 0:
		var e: Vector3 = body.get_euler()
		cam.global_transform.basis = Basis.from_euler(Vector3(0.0, e.y, 0.0))
	else:
		cam.global_transform.basis = body * Basis(Vector3.RIGHT, deg_to_rad(float(cam.P["cam_tilt"])))
	if main._fpv_osd != null:
		main._fpv_osd.signal_q = lerpf(a.rssi, b.rssi, k)
		main._fpv_osd.battery = lerpf(a.bat, b.bat, k)
	if replay_label != null:
		var evs := ""
		for e2 in _events:
			if absf(float(e2[0]) - _rt) < 2.0:
				evs += "\n" + str(e2[1]).left(80)
		replay_label.text = "▶ РЕПЛЕЙ %s  %02d:%02d / %02d:%02d  ×%.2f%s\nпробел — пауза · ←/→ ±5 с · [ ] скорость%s" % [
			path.get_file(), int(_rt) / 60, int(_rt) % 60, int(tend) / 60, int(tend) % 60, _speed,
			"  ⏸" if _paused else "", evs]
