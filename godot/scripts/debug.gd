extends Node
## Отладочные режимы: пресеты видовых точек, --screenshot и производные флаги, --targetreport.

var main: Node3D


func setup(m: Node3D) -> void:
	main = m
	if "--bench" in OS.get_cmdline_user_args():
		_bench()
	if "--targetreport" in OS.get_cmdline_user_args():
		_debug_report_targets()
	if "--screenshot" in OS.get_cmdline_user_args():
		_schedule_screenshot()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--transshot="):
			_transshot(a.substr(12))


## Пресеты видовых точек для заявки/видео: cam lat/lon, AGL(м), target lat/lon, target +Δh(м).
const SHOT_PRESETS := [
	[48.070, 24.560, 2600.0, 48.160, 24.500, 0.0],    # 0 establishing: ЮВ→Говерла, высокий облёт
	[48.2839, 24.5610, 240.0, 48.2650, 24.5660, 60.0],# 1 low valley: долина Ворохты на юг
	[48.140, 24.560, 700.0, 48.180, 24.470, -100.0],  # 2 ridge: вдоль хребта к массиву
	[48.190, 24.470, 900.0, 48.160, 24.500, -50.0],   # 3 peak: подход к вершине Говерлы
]

func _preset_index() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			return int(a.substr(9))
	return -1

func _apply_preset(i: int) -> void:
	var p: Array = SHOT_PRESETS[i]
	var v: Vector2 = main._world_from_latlon(p[0], p[1])
	main.cam.global_position = Vector3(v.x, main.height_at(v.x, v.y) + float(p[2]), v.y)
	var t: Vector2 = main._world_from_latlon(p[3], p[4])
	main.cam.look_at(Vector3(t.x, main.height_at(t.x, t.y) + float(p[5]), t.y))


func _schedule_screenshot() -> void:
	await RenderingServer.frame_post_draw
	for i in 90:
		await get_tree().process_frame
	var preset := _preset_index()
	if preset >= 0 and preset < SHOT_PRESETS.size():
		_apply_preset(preset)
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
	# --unitshot=<tank1..4|apc1..3|sold1..3|civ1..3> — галерея юнитов: ставим у точки старта, камера в 3/4
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--unitshot="):
			main.replaying = true            # отключить управление дроном — камера строго по look_at
			var key := a.substr(11)
			var U = load("res://scripts/units.gd").new()
			var items: Array = U.build_set(key)
			var base: Vector3 = main._home_pos + Vector3(14, 0, 0)
			var vehicle := key.begins_with("tank") or key.begins_with("apc") or key.begins_with("car")
			var yaw := -0.2 if vehicle else -0.6     # техника — лоб+борт 3/4, люди — лицом к камере
			if key.begins_with("car"):
				yaw = -0.55                          # автопарк — передом 3/4
			for it: Array in items:
				var obj = it[0]
				var mi: Node3D
				if obj is Node3D:
					mi = obj
				else:
					mi = MeshInstance3D.new()
					mi.mesh = obj
				var pz := float(it[1])
				mi.transform = Transform3D(Basis(Vector3.UP, yaw),
					Vector3(base.x, main.height_at(base.x + 0.0, base.z + pz), base.z + pz))
				main.add_child(mi)
			var gy2: float = main.height_at(base.x, base.z)
			for _i in 40:
				await get_tree().process_frame
			if main.hud != null and main.hud.get("fpv_on") != null and main.hud.fpv_on:
				main.hud._toggle_fpv()               # галерея всегда обычной камерой
			if key.begins_with("car"):
				main.cam.global_position = Vector3(base.x + 11.0, gy2 + 5.0, base.z + 12.0)
				main.cam.look_at(Vector3(base.x, gy2 + 1.0, base.z + 0.5))
			elif vehicle:
				main.cam.global_position = Vector3(base.x + 6.2, gy2 + 3.0, base.z + 7.0)
				main.cam.look_at(Vector3(base.x, gy2 + 1.3, base.z))
			else:
				main.cam.global_position = Vector3(base.x + 2.4, gy2 + 1.45, base.z + 2.6)
				main.cam.look_at(Vector3(base.x, gy2 + 1.0, base.z))
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
	# --shotat=x,z,alt[,tx,tz] — камера в мировых координатах, взгляд на цель (или вниз-вперёд)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--shotat="):
			var q := a.substr(9).split(",")
			var sx := float(q[0]); var sz := float(q[1])
			var alt := float(q[2]) if q.size() > 2 else 40.0
			main.cam.global_position = Vector3(sx, main.height_at(sx, sz) + alt, sz)
			var tx := float(q[3]) if q.size() > 4 else sx + 60.0
			var tz := float(q[4]) if q.size() > 4 else sz
			main.cam.look_at(Vector3(tx, main.height_at(tx, tz), tz))
			for _i in 60:
				await get_tree().process_frame
			await RenderingServer.frame_post_draw
	if "--watershot" in OS.get_cmdline_user_args():
		var wt: Vector2 = main._world_from_latlon(48.23928, 24.33539)
		var gy: float = main.height_at(wt.x, wt.y)
		main.cam.global_position = Vector3(wt.x + 30.0, gy + 320.0, wt.y + 30.0)
		main.cam.look_at(Vector3(wt.x, gy, wt.y))
		for _i in 60:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if "--fpv" in OS.get_cmdline_user_args():
		main.hud._toggle_fpv()
		for a in OS.get_cmdline_user_args():
			if a.begins_with("--camera=") and main.hud.fpv_link != null:
				main.hud.fpv_link.set_camera(int(a.substr(9)))
		if "--thermal" in OS.get_cmdline_user_args() and main.hud.fpv_link != null:
			main.hud.fpv_link.set_camera(3)
		for _i in 30:
			await get_tree().process_frame
		main.hud._fpv_osd.flight_t = 143.0
		main.hud._fpv_osd.battery = 0.62
	if "--lowshot" in OS.get_cmdline_user_args():
		var lv: Vector2 = main._world_from_latlon(48.2760, 24.5640)
		main.cam.global_position = Vector3(lv.x, main.height_at(lv.x, lv.y) + 35.0, lv.y)
		var lt: Vector2 = main._world_from_latlon(48.2700, 24.5660)
		main.cam.look_at(Vector3(lt.x, main.height_at(lt.x, lt.y) + 8.0, lt.y))
		for _i in 90:                       # дать свету/дыму прилипнуть и накопиться
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if "--groundshot" in OS.get_cmdline_user_args():
		# кадр с 2.5 м над землёй — проверка травы/деревьев/земли вблизи
		var gv: Vector2 = main._world_from_latlon(48.2760, 24.5640)
		var gyy: float = main.height_at(gv.x, gv.y)
		main.cam.global_position = Vector3(gv.x, gyy + 2.5, gv.y)
		var gt: Vector2 = main._world_from_latlon(48.2700, 24.5660)
		main.cam.look_at(Vector3(gt.x, main.height_at(gt.x, gt.y) + 6.0, gt.y))
		for _i in 90:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if "--aircam" in OS.get_cmdline_user_args() and main.get("airtargets") != null:
		for _i in 30:
			await get_tree().process_frame
		var na: Dictionary = main.airtargets.nearest(main.cam.global_position)
		if not na.is_empty():
			var ap: Vector3 = na.pos
			main.cam.global_position = ap + Vector3(7, -1.5, 8)
			main.cam.look_at(ap + Vector3(0, -0.5, 0))
		await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if "--targetcam" in OS.get_cmdline_user_args() and main.targets != null:
		var want := "tank"
		if "--oneapc" in OS.get_cmdline_user_args(): want = "apc"
		elif "--onesquad" in OS.get_cmdline_user_args(): want = "soldier"
		var pick: Dictionary = main.targets.targets[-1] if not main.targets.targets.is_empty() else {}
		for t: Dictionary in main.targets.targets:
			if t.kind == want:
				pick = t
				break
		if not pick.is_empty():
			var tp: Vector3 = pick.node.position
			main.cam.global_position = tp + Vector3(8.0, 6.5, 8.5)
			main.cam.look_at(tp + Vector3(0, 1.9, 0))
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	var suffix := ("_%d" % preset) if preset >= 0 else ""
	var out := ProjectSettings.globalize_path("res://../shot%s.png" % suffix)
	img.save_png(out)
	print("Screenshot saved: ", out)
	get_tree().quit()


## --transshot=a,b — прогон смены погоды a→b: камера над селом (тени домов/деревьев),
## кадр до перехода и каждые 3 с в течение перехода (~18 с). Файлы trans_AtoB_tNN.png в корне проекта.
func _transshot(spec: String) -> void:
	var q := spec.split(",")
	var wa := clampi(int(q[0]), 0, 5)
	var wb := clampi(int(q[1]) if q.size() > 1 else 0, 0, 5)
	await RenderingServer.frame_post_draw
	for i in 90:
		await get_tree().process_frame
	main.replaying = true                        # физика дрона выключена — камера статична
	var gv: Vector2 = main._world_from_latlon(48.2760, 24.5640)
	var gy: float = main.height_at(gv.x, gv.y)
	main.cam.global_position = Vector3(gv.x, gy + 45.0, gv.y)
	var gt: Vector2 = main._world_from_latlon(48.2700, 24.5660)
	main.cam.look_at(Vector3(gt.x, main.height_at(gt.x, gt.y) + 5.0, gt.y))
	main.weather.apply(wa, true)
	for i in 150:                                # дать лесу/усадьбам/свету достроиться
		await get_tree().process_frame
	await _save_shot("trans_%dto%d_t00" % [wa, wb])
	main.weather.apply(wb)
	var t := 0.0
	while t < 18.5:
		var t0 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t0 < 3000:
			await get_tree().process_frame
		t += 3.0
		await _save_shot("trans_%dto%d_t%02d" % [wa, wb, int(t)])
	get_tree().quit()


func _save_shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	var out := ProjectSettings.globalize_path("res://../%s.png" % shot_name)
	img.save_png(out)
	print("Screenshot saved: ", out)


func _debug_report_targets() -> void:
	await get_tree().process_frame
	for i in 30:
		await get_tree().process_frame
	if main.targets == null:
		return
	var cp: Vector3 = main.cam.global_position
	var lst: Array = []
	for t: Dictionary in main.targets.targets:
		var d := cp.distance_to(t.node.position)
		lst.append([d, t.kind])
	lst.sort()
	print("=== ЦЕЛИ от камеры (", cp, ") ===")
	for e in lst:
		print("  %s  %.0f м" % [e[1], e[0]])
	get_tree().quit()



## Бенчмарк: 10 с полёта на 25 м AGL со скоростью 30 м/с над селом (от старта на юг), печатает
## средний/мин FPS, долю времени скриптов (process) и число объектов/примитивов в кадре.
func _bench() -> void:
	await get_tree().process_frame
	for i in 60:
		await get_tree().process_frame
	main.replaying = true                        # отключаем физику дрона — ведём камеру вручную
	var cam: Camera3D = main.cam
	var start: Vector3 = main._home_pos
	var dir := Vector3(0, 0, 1)                   # на юг вдоль долины
	var t := 0.0
	var frames := 0
	var fps_sum := 0.0; var fps_min := 1e9
	var proc_sum := 0.0; var render_sum := 0.0
	var objs := 0; var prims := 0
	while t < 10.0:
		var dt := get_process_delta_time()
		t += dt
		var pos := start + dir * (t * 30.0)
		pos.y = main.height_at(pos.x, pos.z) + 25.0
		cam.global_position = pos
		cam.global_transform.basis = Basis.looking_at(dir + Vector3(0, -0.25, 0), Vector3.UP)
		cam.body = cam.global_transform.basis
		if t > 1.0:
			var f := Engine.get_frames_per_second()
			frames += 1; fps_sum += f; fps_min = minf(fps_min, f)
			proc_sum += Performance.get_monitor(Performance.TIME_PROCESS)
			objs = int(Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME))
			prims = int(Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME))
		await get_tree().process_frame
	var avg := fps_sum / maxf(frames, 1)
	var proc_ms := proc_sum / maxf(frames, 1) * 1000.0
	print("BENCH fps avg=%.1f min=%.1f | process(script) %.1f мс/кадр из %.1f | объектов %d примитивов %.1fM | quality=%d" % [
		avg, fps_min, proc_ms, 1000.0 / maxf(avg, 1.0), objs, prims / 1e6, int(main.quality)])
	get_tree().quit()
