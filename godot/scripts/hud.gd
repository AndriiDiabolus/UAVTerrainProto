extends CanvasLayer
## HUD прототипа: текстовые строки, маркеры целей/миссии, ветрометр, стики, FPV-слой (пост-эффект + OSD),
## надписи краша/результата/реплея, кнопка звука. Всё, что рисуется поверх 3D.

var main: Node3D
var hud_label: Label
var _crash_label: Label
var fpv_link: Node
var _fpv_osd: Control
var fpv_on := false
var target_marker: Label
var _sound_btn: Button
var _sound_muted := true          # старт без звука; включается M (или --sound)
var _wind_label: Label
var _wind_flag: Control
var _sticks: Control
var _result_label: Label
var _replay_label: Label
var mission_marker: Label

## Вкл/выкл весь звук (кнопка в углу или клавиша M).
func _toggle_sound() -> void:
	_sound_muted = not _sound_muted
	AudioServer.set_bus_mute(0, _sound_muted)
	toast("ЗВУК: ВИМК" if _sound_muted else "ЗВУК: УВІМК", "", Color(0.8, 0.8, 0.8), 1.2)


var _min: Control
var crosshair: Array = []
var _info_held := false

## Тост по центру сверху (смена камеры/режима/звука).
func toast(text: String, sub: String = "", col: Color = Color(1, 1, 1), dur: float = 2.5) -> void:
	if _min != null:
		_min.toast(text, sub, col, dur)



## FPV-подача: широкий угол + «аналоговое видео» + OSD дрона.
func _toggle_fpv() -> void:
	fpv_on = not fpv_on
	target_marker.visible = not fpv_on
	# обычный HUD прячем — в FPV своя приборка (OSD живёт внутри видеотракта);
	# _min остаётся видимым: в FPV он рисует только FPS-плашку (см. hud_min._draw)
	for c: Node in [_wind_label, _wind_flag]:
		if c != null:
			c.visible = not fpv_on
	if fpv_link != null:
		fpv_link.set_enabled(fpv_on)
	if not fpv_on and main.thermal != null and main.thermal.active:
		main.thermal.set_active(false)
	if fpv_on:
		_fpv_osd.flight_t = 0.0



func setup(m: Node3D) -> void:
	main = m
	if "--nohud" in OS.get_cmdline_user_args():
		visible = false
	if "--sound" in OS.get_cmdline_user_args():
		_sound_muted = false
	AudioServer.set_bus_mute(0, _sound_muted)     # по умолчанию тихо, M — включить
	var layer := self
	hud_label = Label.new()
	hud_label.position = Vector2(16, 12)
	hud_label.add_theme_font_size_override("font_size", 15)
	hud_label.add_theme_color_override("font_color", Color(0.9, 0.9, 0.88, 0.95))
	hud_label.visible = false                     # полная телеметрия — пока удерживается I
	hud_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	hud_label.add_theme_constant_override("shadow_offset_x", 1)
	hud_label.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(hud_label)

	# кнопка звука в правом верхнем углу
	_sound_btn = Button.new()
	_sound_btn.text = "  Звук: УВІМК  "
	_sound_btn.focus_mode = Control.FOCUS_NONE
	_sound_btn.add_theme_font_size_override("font_size", 15)
	_sound_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_sound_btn.position = Vector2(-150, 12)
	_sound_btn.pressed.connect(_toggle_sound)
	_sound_btn.visible = false                    # вариант G: без кнопки, звук — M (тост)
	layer.add_child(_sound_btn)

	# перекрестие (меню ховає його через crosshair)
	for size_off: Array in [[Vector2(14, 2), Vector2(-7, -1)], [Vector2(2, 14), Vector2(-1, -7)]]:
		var cr := ColorRect.new()
		cr.color = Color(1, 1, 1, 0.8)
		cr.size = size_off[0]
		cr.set_anchors_preset(Control.PRESET_CENTER)
		cr.position = size_off[1]
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud_label.get_parent().add_child(cr)
		crosshair.append(cr)

	# указатель на ближайшую цель
	target_marker = Label.new()
	target_marker.text = "◆ ЦІЛЬ"
	target_marker.add_theme_font_size_override("font_size", 16)
	target_marker.add_theme_color_override("font_color", Color(1, 0.25, 0.15))
	target_marker.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	target_marker.add_theme_constant_override("shadow_offset_x", 1)
	target_marker.add_theme_constant_override("shadow_offset_y", 1)
	target_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(target_marker)

	# маркеры целей, отмеченных разведчиком (оранжевые, видны с любого дрона)
	for i in 12:
		var mk := Label.new()
		mk.add_theme_font_size_override("font_size", 14)
		mk.add_theme_color_override("font_color", Color(1.0, 0.62, 0.2))
		mk.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
		mk.add_theme_constant_override("shadow_offset_x", 1)
		mk.add_theme_constant_override("shadow_offset_y", 1)
		mk.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mk.visible = false
		layer.add_child(mk)
		_marked_labels.append(mk)

	# флажок-ветрометр в левом нижнем углу
	_wind_flag = Control.new()
	_wind_flag.set_script(load("res://scripts/windflag.gd"))
	_wind_flag.set("main", main)
	_wind_flag.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_wind_flag.position = Vector2(10, -152)   # прижат к левому нижнему углу; блок «ветер N м/с» — под ним
	_wind_flag.custom_minimum_size = Vector2(110, 92)
	_wind_flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_wind_flag)

	# скорость ветра под флажком
	_wind_label = Label.new()
	_wind_label.add_theme_font_size_override("font_size", 16)
	_wind_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_wind_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_wind_label.add_theme_constant_override("shadow_offset_x", 1)
	_wind_label.add_theme_constant_override("shadow_offset_y", 1)
	_wind_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_wind_label.position = Vector2(16, -54)
	_wind_label.visible = false
	layer.add_child(_wind_label)

	# индикатор стиков пульта — правый нижний угол
	_sticks = Control.new()
	_sticks.set_script(load("res://scripts/sticks.gd"))
	_sticks.set("main", main)
	_sticks.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_sticks.position = Vector2(-178, -235)
	layer.add_child(_sticks)

	# минимальный HUD (вариант G): строка статуса, контекстные блоки, тосты
	_min = Control.new()
	_min.set_script(load("res://scripts/hud_min.gd"))
	_min.set("main", main)
	_min.set_anchors_preset(Control.PRESET_FULL_RECT)
	layer.add_child(_min)

	# надпись о столкновении по центру экрана
	_crash_label = Label.new()
	_crash_label.set_anchors_preset(Control.PRESET_CENTER)
	_crash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crash_label.add_theme_font_size_override("font_size", 30)
	_crash_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.25))
	_crash_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_crash_label.add_theme_constant_override("shadow_offset_x", 2)
	_crash_label.add_theme_constant_override("shadow_offset_y", 2)
	_crash_label.position = Vector2(-360, -60)
	_crash_label.custom_minimum_size = Vector2(720, 0)
	_crash_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crash_label.visible = false
	layer.add_child(_crash_label)

	# FPV: OSD (считает RSSI/батарею всегда, рисуется внутри видеотракта fpv_link) + видеотракт
	_fpv_osd = Control.new()
	_fpv_osd.set_script(load("res://scripts/fpv_osd.gd"))
	_fpv_osd.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fpv_osd.set("main", main)
	_fpv_osd.home = main._home_pos          # точка оператора = точка взлёта
	fpv_link = Node.new()
	fpv_link.name = "FPVLink"
	fpv_link.set_script(load("res://scripts/fpv_link.gd"))
	main.add_child(fpv_link)
	fpv_link.setup(main, _fpv_osd)

	# результат миссии по центру
	_result_label = Label.new()
	_result_label.set_anchors_preset(Control.PRESET_CENTER)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 22)
	_result_label.add_theme_color_override("font_color", Color(0.9, 1.0, 0.85))
	_result_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_result_label.add_theme_constant_override("shadow_offset_x", 2)
	_result_label.add_theme_constant_override("shadow_offset_y", 2)
	_result_label.position = Vector2(-380, -160)
	_result_label.custom_minimum_size = Vector2(760, 0)
	_result_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_label.visible = false
	layer.add_child(_result_label)

	# маркер цели миссии (ворота/площадка/точка)
	mission_marker = Label.new()
	mission_marker.add_theme_font_size_override("font_size", 16)
	mission_marker.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	mission_marker.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	mission_marker.add_theme_constant_override("shadow_offset_x", 1)
	mission_marker.add_theme_constant_override("shadow_offset_y", 1)
	mission_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mission_marker.visible = false
	layer.add_child(mission_marker)

	# строка реплея (сверху по центру)
	_replay_label = Label.new()
	_replay_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_replay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_replay_label.add_theme_font_size_override("font_size", 16)
	_replay_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_replay_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_replay_label.position = Vector2(-300, 40)
	_replay_label.custom_minimum_size = Vector2(600, 0)
	_replay_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_replay_label)

	var attrib := Label.new()
	attrib.text = str(main.meta.get("attribution", ""))
	attrib.add_theme_font_size_override("font_size", 11)
	attrib.add_theme_color_override("font_color", Color(1, 1, 1, 0.38))
	attrib.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	attrib.position = Vector2(16, -24)
	layer.add_child(attrib)



func _process(_dt: float) -> void:
	if main == null or main.cam == null or hud_label == null:
		return
	var cam: Camera3D = main.cam
	var p := cam.global_position
	var ground: float = main.height_at(p.x, p.z)
	var ll: Vector2 = main._latlon_at(p.x, p.z)
	var spd: float = cam.speed() if cam.has_method("speed") else 0.0
	var tline := ""
	if main.targets != null:
		tline = "\nПоражено: %d   |   целей в зоне: %d   |   боеприпас %d/%d" % [main.targets.score, main.targets.active_count(),
			main.targets.ammo, main.targets.AMMO_MAX]
	if main._fpv_osd != null:
		var lq: float = main._fpv_osd.signal_q
		var jline := ""
		if main.get("ew") != null:
			var ji: Dictionary = main.ew.nearest_info(p)
			if not ji.is_empty():
				if float(ji.edge) < 0.0:
					jline = "   ⚠ РЕБ: придушення %d%%" % int(float(ji.jam) * 100.0)
				elif float(ji.edge) < 400.0:
					jline = "   РЕБ-зона через %d м" % int(ji.edge)
		var fs: String = "   ✖ FAILSAFE" if cam.get("failsafe") == true else ""
		tline += "\nКанал: %d%%%s%s" % [int(lq * 100.0), jline, fs]
	if main.mission != null:
		var ml: String = main.mission.hud_line()
		if ml != "": tline += "\n" + ml
	var wline := ""
	if main.weather != null:
		var w: Vector3 = main.weather.wind_vec()
		wline = "\n%s   ветер %d м/с %s" % [main.weather.label, int(w.length()), _wind_arrow(w)]
		if _wind_label != null:
			_wind_label.text = "Вітер: %d м/с %s" % [int(w.length()), _wind_arrow(w)]
	var fline := ""
	if cam.has_method("mode_name"):
		var src: String = ("пульт: " + str(cam.joy_name)) if str(cam.joy_name) != "" else "клавиатура"
		fline = "\n[%s]  %s  ·  %s%s  ·  качество: %s (G)" % [cam.mode_name(), cam.drone_name(), src,
			("  ·  НА ЗЕМЛЕ" if cam.landed else ""), main.QUALITY_NAMES[main.quality]]
	hud_label.text = "%.5f°N  %.5f°E\nMSL %d м   AGL %d м\nшвидкість %d м/с   FPS %d%s%s%s\nW/S тангаж · A/D крен · E/Q газ · ←/→ рискання · Tab режим · B дрон · Shift буст · ЛКМ вогонь · 1-5/8/P погода · 6 туман · 7 дощ · M звук · F FPV · C камера · T тепло · R рестарт" % [
		ll.x, ll.y, int(p.y), int(p.y - ground), int(spd), int(Engine.get_frames_per_second()), fline, tline, wline]
	_update_target_marker(p)
	_update_marked_markers()
	_update_mission_marker()
	# полная телеметрия — по удержанию I; флажок ветра — при ветре ≥ 5 м/с; стики — только с пультом (или I)
	_info_held = Input.is_key_pressed(KEY_I)
	hud_label.visible = _info_held and not fpv_on
	if _wind_flag != null and main.weather != null:
		_wind_flag.visible = (not fpv_on) and (main.weather.wind_vec().length() >= 5.0 or _info_held)
	if _sticks != null:
		_sticks.visible = (str(cam.joy_name) != "" or _info_held)




func _update_mission_marker() -> void:
	if mission_marker == null or main.mission == null:
		return
	var tp = main.mission.target_pos()
	if tp == null:
		mission_marker.visible = false
		return
	mission_marker.visible = true
	var vp := get_viewport().get_visible_rect().size
	var cam: Camera3D = main.cam
	var behind := cam.is_position_behind(tp)
	var sp := cam.unproject_position(tp)
	if behind:
		sp.x = vp.x - sp.x
		sp.y = vp.y
	var margin := 40.0
	sp.x = clampf(sp.x, margin, vp.x - margin)
	sp.y = clampf(sp.y, margin, vp.y - margin)
	mission_marker.position = sp - mission_marker.size * 0.5
	mission_marker.text = "◎ %d м" % int(cam.global_position.distance_to(tp))


func _wind_arrow(w: Vector3) -> String:
	if w.length() < 0.5:
		return "—"
	var a := atan2(w.z, w.x)
	var dirs := ["→", "↘", "↓", "↙", "←", "↖", "↑", "↗"]
	return dirs[int(round(a / (PI / 4.0))) & 7]


var _marked_labels: Array = []

## Маркеры целей, отмеченных разведчиком: «◇ ВИД · дистанция», живут пока цель жива.
func _update_marked_markers() -> void:
	var names := {"tank": "ТАНК", "apc": "БТР", "soldier": "ПЕХОТА"}
	var lst: Array = main.targets.marked_list() if main.targets != null else []
	var cam: Camera3D = main.cam
	var vp := get_viewport().get_visible_rect().size
	for i in _marked_labels.size():
		var mk: Label = _marked_labels[i]
		if fpv_on or i >= lst.size():
			mk.visible = false
			continue
		var t: Dictionary = lst[i]
		var tpos: Vector3 = t.node.position + Vector3(0, 12, 0)
		if cam.is_position_behind(tpos):
			mk.visible = false
			continue
		var sp := cam.unproject_position(tpos)
		if sp.x < -40 or sp.x > vp.x + 40 or sp.y < -40 or sp.y > vp.y + 40:
			mk.visible = false
			continue
		mk.visible = true
		mk.text = "◇ %s  %d м" % [names.get(t.kind, "ЦІЛЬ"), int(cam.global_position.distance_to(t.node.position))]
		mk.position = sp - mk.size * 0.5
	if lst.size() > _marked_labels.size():
		pass                                        # хвост списка не влезает в пул — не критично


func _update_target_marker(p: Vector3) -> void:
	if target_marker == null or main.targets == null:
		return
	var n: Dictionary = main.targets.nearest(p)
	# воздушная цель: выбираем ближайшую из наземной и воздушной
	if main.get("airtargets") != null:
		var na: Dictionary = main.airtargets.nearest(p)
		if not na.is_empty() and (n.is_empty() or float(na.dist) < float(n.dist)):
			n = na
	if n.is_empty() or fpv_on:
		target_marker.visible = false
		return
	target_marker.visible = true
	var tpos: Vector3 = n.pos + Vector3(0, 30, 0)
	var vp := get_viewport().get_visible_rect().size
	var cam: Camera3D = main.cam
	var behind := cam.is_position_behind(tpos)
	var sp := cam.unproject_position(tpos)
	if behind:
		sp.x = vp.x - sp.x
		sp.y = vp.y
	# держим ярлык у края экрана, если цель вне кадра
	var margin := 40.0
	sp.x = clampf(sp.x, margin, vp.x - margin)
	sp.y = clampf(sp.y, margin, vp.y - margin)
	target_marker.position = sp - target_marker.size * 0.5
	var names := {"tank": "ТАНК", "apc": "БТР", "soldier": "ПІХОТА", "air_wing": "БпЛА-крило", "air_quad": "БпЛА-квадро"}
	var name_ru: String = names.get(n.kind, "ЦІЛЬ")
	var air: bool = str(n.kind).begins_with("air_")
	target_marker.add_theme_color_override("font_color", Color(0.35, 0.7, 1.0) if air else Color(1, 0.25, 0.15))
	target_marker.text = "◆ %s  %d м" % [name_ru, int(n.dist)]


