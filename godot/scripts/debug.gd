extends Node
## Отладочные режимы: пресеты видовых точек, --screenshot и производные флаги, --targetreport.

var main: Node3D


func setup(m: Node3D) -> void:
	main = m
	if "--targetreport" in OS.get_cmdline_user_args():
		_debug_report_targets()
	if "--screenshot" in OS.get_cmdline_user_args():
		_schedule_screenshot()


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

