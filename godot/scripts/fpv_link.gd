extends Node
## FPV-видеотракт: мир рендерится в низкоразрешённый SubViewport (камера-копия дрона, FOV 150°),
## OSD рисуется ВНУТРИ сигнала, затем кадр выводится на экран через fpv.gdshader
## (эквидистантный «рыбий глаз», интерлейс, размытая цветность, ступенчатая деградация аналога,
## jello от газа, характер камеры, veiling glare от солнца). Главный 3D-вьюпорт при этом выключен — +FPS.
##
## Тип линка по профилю дрона: fpv7/fpv5 — аналог 5.8 ГГц (960×720 4:3, 30 к/с, плавная деградация),
## mavic — цифра (1280×720 16:9, 60 к/с, блочность при падении битрейта, фриз + SIGNAL LOST).

var main: Node3D
var enabled := false
var vp: SubViewport
var cam: Camera3D
var rect: TextureRect
var mat: ShaderMaterial
var osd_layer: CanvasLayer
var osd_vp: SubViewport
var link_type := 0                 # 0 аналог, 1 цифра
var camera := 0                    # 0 аналог (Caddx/Runcam), 1 цифра DJI O3, 2 ночная ч/б (Night Eagle), 3 тепловизор
const CAMERA_NAMES := ["ANALOG 1200TVL", "DJI O3", "NIGHT EAGLE B/W", "THERMAL 256"]
var link_eff := 1.0                # эффективное качество канала (с бурстами)
var frozen := false
var lost_t := 0.0
var _acc := 0.0
var _burst_t := 0.0
var _rng := RandomNumberGenerator.new()
var _sun_vis := 0.0
var _frame_t := 0.0
const FOV_H := 150.0
const FOV_THERMAL := 42.0
var _ffc_t := 0.0          # до следующего FFC (калибровки затвора)
var _ffc_hold := 0.0       # длительность фриза


func setup(m: Node3D, osd: Control) -> void:
	main = m
	_rng.seed = 12345
	vp = SubViewport.new()
	vp.name = "FPVView"
	vp.size = Vector2i(960, 720)
	vp.world_3d = main.get_viewport().world_3d
	vp.own_world_3d = false
	vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	vp.msaa_3d = Viewport.MSAA_DISABLED
	vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
	vp.use_taa = false
	vp.positional_shadow_atlas_size = 2048
	main.add_child(vp)
	cam = Camera3D.new()
	cam.name = "FPVCam"
	cam.keep_aspect = Camera3D.KEEP_WIDTH
	cam.fov = FOV_H
	cam.near = 0.3
	cam.far = 150000.0
	var attr := CameraAttributesPractical.new()
	attr.auto_exposure_enabled = true
	attr.auto_exposure_speed = 2.2            # запаздывание экспонометра: выход из тени «выбеливает» кадр
	attr.auto_exposure_min_sensitivity = 40.0
	attr.auto_exposure_max_sensitivity = 1600.0
	attr.auto_exposure_scale = 0.45
	cam.attributes = attr
	vp.add_child(cam)
	# OSD — отдельный прозрачный SubViewport: накладывается ПОСЛЕ объектива (как OSD полётника на видеосигнал),
	# но ДО помех/срывов — рвётся и шумит вместе с картинкой
	osd_vp = SubViewport.new()
	osd_vp.name = "FPVOSD"
	osd_vp.size = Vector2i(960, 720)
	osd_vp.transparent_bg = true
	osd_vp.disable_3d = true
	osd_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	main.add_child(osd_vp)
	osd_layer = CanvasLayer.new()
	osd_vp.add_child(osd_layer)
	if osd.get_parent() != null:
		osd.get_parent().remove_child(osd)
	osd_layer.add_child(osd)
	osd.set_anchors_preset(Control.PRESET_FULL_RECT)
	osd.visible = true
	# экран «очков»: TextureRect под HUD-слоем (слой 0), письмо 4:3 в 16:9 — чёрные поля
	var layer := CanvasLayer.new()
	layer.layer = 0
	main.add_child(layer)
	rect = TextureRect.new()
	rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.texture = vp.get_texture()
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mat = ShaderMaterial.new()
	mat.shader = load("res://scripts/fpv.gdshader")
	rect.material = mat
	rect.visible = false
	layer.add_child(rect)
	var bg := ColorRect.new()          # чёрное за письмом
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	bg.show_behind_parent = true
	rect.add_child(bg)


func set_enabled(on: bool) -> void:
	enabled = on
	rect.visible = on
	main.get_viewport().disable_3d = on          # основной 3D не нужен — картинка идёт из SubViewport
	vp.render_target_update_mode = SubViewport.UPDATE_ONCE if on else SubViewport.UPDATE_DISABLED
	osd_vp.render_target_update_mode = SubViewport.UPDATE_ALWAYS if on else SubViewport.UPDATE_DISABLED
	if on:
		_apply_profile()
		_sync_cam()
		frozen = false; lost_t = 0.0


## Переключение камеры (C — цикл, T — тепло). Тип линка: цифра только у DJI O3, остальные — аналог 5.8 ГГц.
func set_camera(c: int) -> void:
	camera = posmod(c, 4)
	if main.thermal != null:
		main.thermal.set_active(camera == 3)
	_apply_profile()
	print("Камера: ", CAMERA_NAMES[camera])


func camera_name() -> String:
	return CAMERA_NAMES[camera]


func _apply_profile() -> void:
	link_type = 1 if camera == 1 else 0
	# разрешение рендера: эквидистантная проекция увеличивает центр ×2.8, поэтому рендерим крупнее «сигнала»
	var q: int = int(main.quality)
	if link_type == 1:
		vp.size = [Vector2i(960, 540), Vector2i(1280, 720), Vector2i(1920, 1080)][q]
		osd_vp.size = Vector2i(1280, 720)
	else:
		vp.size = [Vector2i(640, 480), Vector2i(960, 720), Vector2i(1280, 960)][q]
		osd_vp.size = Vector2i(960, 720)
	rect.texture = vp.get_texture()
	mat.set_shader_parameter("video", vp.get_texture())
	mat.set_shader_parameter("osd", osd_vp.get_texture())
	mat.set_shader_parameter("link_type", link_type)
	mat.set_shader_parameter("tex_size", Vector2(vp.size))


func _sync_cam() -> void:
	cam.global_transform = main.cam.global_transform


func _process(dt: float) -> void:
	if not enabled or main == null or main.cam == null:
		return
	_sync_cam()
	_frame_t += dt
	# --- качество канала: RSSI с OSD + бурсты помех (Пуассон) ---
	var q := 1.0
	if main._fpv_osd != null:
		q = float(main._fpv_osd.signal_q)
	if main.crashed:
		q = 0.0
	if _burst_t > 0.0:
		_burst_t -= dt
		q *= 0.25
	elif q < 0.85:
		var rate := (1.0 - q) * 2.5           # бурстов в секунду
		if _rng.randf() < rate * dt:
			_burst_t = _rng.randf_range(0.05, 0.22)
	link_eff = lerpf(link_eff, q, clampf(dt * 8.0, 0.0, 1.0))
	# --- цифра: фриз кадра при провале, SIGNAL LOST через 1.5 с ---
	if link_type == 1:
		if link_eff < 0.22:
			frozen = true
			lost_t += dt
		else:
			frozen = false
			lost_t = 0.0
	# --- тепловизор: узкий FOV, 25 к/с, FFC-фриз 0.4 с каждые 45–120 с ---
	var th: bool = camera == 3 and main.thermal != null and main.thermal.active
	cam.fov = FOV_THERMAL if th else FOV_H
	(cam.attributes as CameraAttributesPractical).auto_exposure_enabled = not th
	mat.set_shader_parameter("fov_render", cam.fov)
	mat.set_shader_parameter("fov_target", FOV_THERMAL if th else FOV_H)
	mat.set_shader_parameter("thermal", 1.0 if th else 0.0)
	mat.set_shader_parameter("thermal_palette", main.thermal.palette if th else 0)
	var ffc_now := false
	if th:
		if _ffc_hold > 0.0:
			_ffc_hold -= dt; ffc_now = true
		else:
			_ffc_t -= dt
			if _ffc_t <= 0.0:
				_ffc_t = _rng.randf_range(45.0, 120.0)
				_ffc_hold = 0.4
				if main.sound != null: main.sound.shot()     # щелчок затвора (условно)
	# --- частота кадров видеолинка: 30 (аналог) / 60 (цифра) / 25 (тепло) ---
	_acc += dt
	var period := 1.0 / 30.0 if link_type == 0 else 1.0 / 60.0
	if th: period = 1.0 / 25.0
	if _acc >= period and not frozen and not ffc_now:
		_acc = fmod(_acc, period)
		vp.render_target_update_mode = SubViewport.UPDATE_ONCE
	# --- солнце в объектив ---
	var sun_uv := Vector2(-1, -1)
	var target_vis := 0.0
	if main.sun != null:
		var sdir: Vector3 = -main.sun.global_transform.basis.z
		if sdir.y > 0.0:
			var p := cam.global_position + sdir * 2000.0
			if not cam.is_position_behind(p):
				var sp := cam.unproject_position(p)
				sun_uv = sp / Vector2(vp.size)
				if sun_uv.x > -0.3 and sun_uv.x < 1.3 and sun_uv.y > -0.3 and sun_uv.y < 1.3:
					target_vis = main.los_factor(cam.global_position, cam.global_position + sdir * 4000.0)
					target_vis *= clampf(float(main.sun.light_energy) / 1.5, 0.0, 1.0)
	_sun_vis = lerpf(_sun_vis, target_vis, clampf(dt * 6.0, 0.0, 1.0))
	# --- параметры шейдера ---
	var thr := float(main.cam.throttle)
	var jello := 0.0005 + 0.0022 * sin(clampf(thr, 0.0, 1.0) * PI)   # пик на 50–80 % газа
	if main.crashed: jello *= 3.0
	var night := 0.0
	if main.weather != null and int(main.weather.idx) == 4: night = 1.0
	mat.set_shader_parameter("link_q", link_eff)
	mat.set_shader_parameter("jello_amp", jello)
	mat.set_shader_parameter("sun_uv", sun_uv)
	mat.set_shader_parameter("sun_vis", _sun_vis)
	mat.set_shader_parameter("night", night)
	mat.set_shader_parameter("night_cam", 1.0 if camera == 2 else 0.0)
	mat.set_shader_parameter("lost", 1.0 if (frozen and lost_t > 1.5) else 0.0)
	mat.set_shader_parameter("frame_t", _frame_t)
	if main._fpv_osd != null:
		main._fpv_osd.link_type = link_type
		main._fpv_osd.lost = frozen and lost_t > 1.5
