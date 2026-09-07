extends Node
## Отладочные режимы: пресеты видовых точек, --screenshot и производные флаги, --targetreport.

var main: Node3D
var _hold_cam := Vector3.INF          # желаемая позиция камеры галереи (переприменяется перед кадром)
var _hold_look := Vector3.ZERO


func setup(m: Node3D) -> void:
	main = m
	if "--bench" in OS.get_cmdline_user_args():
		_bench()
	if "--targetreport" in OS.get_cmdline_user_args():
		_debug_report_targets()
	if "--screenshot" in OS.get_cmdline_user_args():
		_schedule_screenshot()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--fxshot="):
			_fx_shot(a.substr(9))
		elif a.begins_with("--animshot="):
			_anim_shot(a.substr(11))
	if "--squadtest" in OS.get_cmdline_user_args():
		_squad_test()
	if "--mapdump" in OS.get_cmdline_user_args():
		_mapdump()

	if "--rainshot" in OS.get_cmdline_user_args():
		_rainshot()
	if "--keytest" in OS.get_cmdline_user_args():
		_keytest()
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--transshot="):
			_transshot(a.substr(12))


func _keytest() -> void:
	await RenderingServer.frame_post_draw
	for i in 60:
		await get_tree().process_frame
	var ev := InputEventKey.new()
	ev.keycode = KEY_M
	ev.physical_keycode = KEY_M
	ev.pressed = true
	Input.parse_input_event(ev)
	await get_tree().process_frame
	await get_tree().process_frame
	print("KEYTEST M: muted=", AudioServer.is_bus_mute(0))
	get_tree().quit()


## --rainshot: серия кадров падающего дождя (шторм, точка groundshot, 6 кадров ~5 с).
func _rainshot() -> void:
	await RenderingServer.frame_post_draw
	for i in 90:
		await get_tree().process_frame
	main.replaying = true
	var gv: Vector2 = main._world_from_latlon(48.2760, 24.5640)
	var gyy: float = main.height_at(gv.x, gv.y)
	main.cam.global_position = Vector3(gv.x, gyy + 2.5, gv.y)
	var gt: Vector2 = main._world_from_latlon(48.2700, 24.5660)
	main.cam.look_at(Vector3(gt.x, main.height_at(gt.x, gt.y) + 6.0, gt.y))
	main.weather.apply(2, true)
	var t0 := Time.get_ticks_msec()
	while Time.get_ticks_msec() - t0 < 3000:
		await get_tree().process_frame
	for k in 6:
		var t1 := Time.get_ticks_msec()
		while Time.get_ticks_msec() - t1 < 800:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
		var img := main.get_viewport().get_texture().get_image()
		img.save_png(ProjectSettings.globalize_path("res://../rainshot_%d.png" % k))
		print("rainshot ", k)
	get_tree().quit()


## Пресеты видовых точек для заявки/видео: cam lat/lon, AGL(м), target lat/lon, target +Δh(м).
const SHOT_PRESETS := [
	[48.070, 24.560, 2600.0, 48.160, 24.500, 0.0],    # 0 establishing: ЮВ→Говерла, высокий облёт
	[48.2839, 24.5610, 240.0, 48.2650, 24.5660, 60.0],# 1 low valley: долина Ворохты на юг
	[48.140, 24.560, 700.0, 48.180, 24.470, -100.0],  # 2 ridge: вдоль хребта к массиву
	[48.190, 24.470, 900.0, 48.160, 24.500, -50.0],   # 3 peak: подход к вершине Говерлы
	[48.2839, 24.5610, 14.0, 48.2846, 24.5601, 0.0],  # 4 ground: луг у точки старта, 14 м
	[48.2760, 24.5850, 60.0, 48.2690, 24.5950, -20.0],# 5 forest: лесной склон вблизи
	[47.6800, 33.7600, 45.0, 47.6860, 33.7520, -10.0],# 6 steppe: пашня с 45 м (--region=steppe)
	[48.2839, 24.5610, 2.2, 48.2845, 24.5604, 1.0],   # 7 eye-level: трава в упор, 2 м
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
		for i in 110:                    # дать чанкам травы/леса сгенериться вокруг новой точки (1/кадр)
			await get_tree().process_frame
			_apply_preset(preset)        # переприменять: дрон могло снести ветром/гравитацией
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
			elif key.begins_with("dw"):
				yaw = 0.0                            # крыло — строгий профиль, нос вправо
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
			var droneg := key.begins_with("drone") or key.begins_with("d5") or key.begins_with("dm") or key.begins_with("dh") or key.begins_with("dw")
			if droneg:
				main.cam.near = 0.05          # дроны мелкие и близко — штатный near 2.0 их отсекает
				var dd := 2.6 if key.begins_with("dh") else 1.0   # крупные — камера дальше
				_hold_cam = Vector3(base.x + 0.45 * dd, gy2 + 1.41 + 0.21 * dd, base.z + 0.34 * dd)
				_hold_look = Vector3(base.x, gy2 + 1.41 + (0.28 if key.begins_with("dh") else 0.0), base.z)
				if key.begins_with("dw"):     # крыло: 3/4 сверху-сбоку («--wside» — строгий профиль)
					_hold_cam = Vector3(base.x + 2.4, gy2 + 2.6, base.z + 2.8)
					_hold_look = Vector3(base.x, gy2 + 1.3, base.z)
					if "--wside" in OS.get_cmdline_user_args():
						_hold_cam = Vector3(base.x, gy2 + 1.5, base.z + 4.0)
						_hold_look = Vector3(base.x, gy2 + 1.38, base.z)
				main.cam.global_position = _hold_cam
				main.cam.look_at(_hold_look)
			elif key.begins_with("car"):
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
	if "--third" in OS.get_cmdline_user_args() and main.get("droneview") != null:
		main.droneview.toggle_third()
		for _i in 45:
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
			if "--markdebug" in OS.get_cmdline_user_args():
				main.targets.mark_at(main.cam, 30.0)
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
	if _hold_cam != Vector3.INF:
		# камеру могли сместить между установкой и кадром — переприменить и дать кадр
		main.cam.global_position = _hold_cam
		main.cam.look_at(_hold_look)
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


## --fxshot=<fpv7|fpv5|mavic|mship|wing|burst_tank|burst_apc|burst_soldier|hit> —
## серия кадров боевого эффекта у точки старта: 3 снимка по ходу анимации, затем выход.
func _fx_shot(kind: String) -> void:
	await RenderingServer.frame_post_draw
	for i in 60:
		await get_tree().process_frame
	main.replaying = true
	var base: Vector3 = main._home_pos
	var gy: float = main.height_at(base.x, base.z)
	# сцена в воздухе, выше крон: взрыв дрона на 22 м — реалистичный контекст
	var tgt := Vector3(base.x, gy + 22.0, base.z)
	var cpos := Vector3(base.x + 14.0, gy + 24.0, base.z + 6.0)
	var clook := tgt
	var times: Array = []
	if kind.begins_with("burst_"):
		var gk := kind.substr(6)
		tgt = Vector3(base.x, gy + 42.0, base.z)          # превью: вся трасса против неба
		var muz := Vector3(base.x - 42.0, gy + 26.0, base.z - 16.0)
		var pts: Array = []
		for i in 7:
			pts.append(tgt + Vector3(randf_range(-1, 1), randf_range(-0.5, 0.5), randf_range(-1, 1)).normalized() * (0.0 if i == 4 else randf_range(2.0, 7.0)))
		# камера сбоку и чуть ниже середины траектории: болиды идут по небу, вспышка в кадре
		var mid := (muz + tgt) * 0.5
		cpos = mid + Vector3(8.0, -3.0, 26.0)
		clook = mid
		_apply_fx_cam(cpos, clook)
		await get_tree().process_frame
		main.fx.gun_burst(muz, pts, gk)
		times = [0.12, 0.35, 0.7]
	elif kind == "hit":
		_apply_fx_cam(cpos, clook)
		await get_tree().process_frame
		main.fx.drone_hit(tgt)
		times = [0.05, 0.18, 0.4]
	else:
		_apply_fx_cam(cpos, clook)
		await get_tree().process_frame
		main.fx.drone_explosion(tgt, kind)
		times = [0.07, 0.35, 1.1]
	var t0 := Time.get_ticks_msec()
	for si in times.size():
		while (Time.get_ticks_msec() - t0) / 1000.0 < float(times[si]):
			_apply_fx_cam(cpos, clook)         # держим камеру: дрон сносит физикой/ветром
			await get_tree().process_frame
		_apply_fx_cam(cpos, clook)
		await RenderingServer.frame_post_draw
		var img := main.get_viewport().get_texture().get_image()
		var out := ProjectSettings.globalize_path("res://../fx_%s_%d.png" % [kind, si])
		img.save_png(out)
		print("FXSHOT saved: ", out)
	get_tree().quit()


## --animshot=<walk|run|aim|crouch|react|death_a|death_b> — солдат у точки старта играет клип,
## 3 кадра по ходу анимации, затем выход.
func _anim_shot(clip: String) -> void:
	await RenderingServer.frame_post_draw
	for i in 60:
		await get_tree().process_frame
	main.replaying = true
	var U = load("res://scripts/units.gd").new()
	var ad: Dictionary = U.soldier_anim_scene()
	if ad.is_empty():
		print("ANIMSHOT: sold_*.glb не найдены")
		get_tree().quit()
		return
	var base: Vector3 = main._home_pos + Vector3(10, 0, 0)
	var gy: float = main.height_at(base.x, base.z)
	(ad.root as Node3D).position = Vector3(base.x, gy, base.z)
	main.add_child(ad.root)
	var cpos := Vector3(base.x + 4.5, gy + 1.7, base.z + 3.0)
	var clook := Vector3(base.x, gy + 1.0, base.z)
	_apply_fx_cam(cpos, clook)
	await get_tree().process_frame
	var cname := String((ad.clips as Dictionary).get(clip, ""))
	print("ANIMSHOT клипы: ", ad.clips.keys(), " → играю: ", cname)
	if cname != "":
		(ad.player as AnimationPlayer).play(cname)
	var t0 := Time.get_ticks_msec()
	for si in 3:
		var tgt_t: float = [0.25, 0.9, 1.6][si]
		while (Time.get_ticks_msec() - t0) / 1000.0 < tgt_t:
			_apply_fx_cam(cpos, clook)
			await get_tree().process_frame
		_apply_fx_cam(cpos, clook)
		await RenderingServer.frame_post_draw
		var img := main.get_viewport().get_texture().get_image()
		var out := ProjectSettings.globalize_path("res://../anim_%s_%d.png" % [clip, si])
		img.save_png(out)
		print("ANIMSHOT saved: ", out)
	get_tree().quit()


## --squadtest: дождаться спавна пехоты, форсировать тревогу, логать автомат анимаций 10 с.
func _squad_test() -> void:
	await RenderingServer.frame_post_draw
	for i in 90:
		await get_tree().process_frame
	var tg = main.targets
	var t0 := Time.get_ticks_msec()
	var sold: Dictionary = {}
	while (Time.get_ticks_msec() - t0) < 30000:
		for t: Dictionary in tg.targets:
			if t.kind == "soldier" and t.alive:
				sold = t
				break
		if not sold.is_empty():
			break
		await get_tree().process_frame
	if sold.is_empty():
		print("SQUADTEST: пехота не заспавнилась за 30 с")
		get_tree().quit()
		return
	print("SQUADTEST: отряд найден, форсирую тревогу")
	for t: Dictionary in tg.targets:
		if t.kind == "soldier":
			t.alert = true
	var t1 := Time.get_ticks_msec()
	var last := -1
	while (Time.get_ticks_msec() - t1) < 10000:
		var sec := int((Time.get_ticks_msec() - t1) / 500.0)
		if sec != last:
			last = sec
			var ad: Dictionary = sold.get("anim", {})
			var ap_s := "нет"
			if not ad.is_empty():
				var ap := ad.player as AnimationPlayer
				ap_s = "%s playing=%s" % [ap.current_animation, ap.is_playing()]
			print("SQUADTEST t=%.1fс offset=%.2f hide=%.2f cur=%s ap=[%s] alert=%s" %
				[(Time.get_ticks_msec() - t1) / 1000.0, float(sold.offset), float(sold.hide_off),
				str(sold.get("cur_anim", "?")), ap_s, str(sold.alert)])
		await get_tree().process_frame
	get_tree().quit()


func _apply_fx_cam(cpos: Vector3, clook: Vector3) -> void:
	main.cam.global_position = cpos
	main.cam.look_at(clook)
	if main.cam.get("body") != null:
		main.cam.body = main.cam.global_transform.basis


func _save_shot(shot_name: String) -> void:
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	var out := ProjectSettings.globalize_path("res://../%s.png" % shot_name)
	img.save_png(out)
	print("Screenshot saved: ", out)


## --mapdump: выгрузка геометрии для аудита пересечений (дороги/заборы/мосты) в mapdump.json.
## Ждёт стриминг усадеб вокруг старта, потом пишет клетки панелей заборов (сетка 1.2 м),
## сегменты полотна дорог (road_index) и палуб мостов (deck_index) + точку старта.
func _mapdump() -> void:
	await RenderingServer.frame_post_draw
	for i in 700:
		await get_tree().process_frame
	var yards := main.get_node_or_null("Yards")
	var cells: Array = []
	if yards != null:
		for c: Vector2i in yards.get("_panel_cells").keys():
			cells.append([c.x, c.y])
	var roads: Array = []
	for arr: Array in main.road_index.values():
		for sg: Array in arr:
			roads.append(sg)
	var decks: Array = []
	for arr: Array in main.deck_index.values():
		for sg: Array in arr:
			decks.append([sg[0], sg[1], sg[2], sg[3], sg[4]])
	var out := {"home": [main._home_pos.x, main._home_pos.z], "cells": cells, "roads": roads, "decks": decks}
	var f := FileAccess.open(ProjectSettings.globalize_path("res://../mapdump.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify(out))
	f.close()
	print("MAPDUMP: клеток забора %d, сегментов дорог %d, палуб %d" % [cells.size(), roads.size(), decks.size()])
	get_tree().quit()


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
