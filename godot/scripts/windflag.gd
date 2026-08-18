extends Control
## Флажок-ветрометр: полосатый вымпел на флагштоке. Чем сильнее ветер, тем длиннее,
## горизонтальнее и быстрее развевается; в штиль обвисает вниз.

var main: Node3D
var _t := 0.0


func _process(dt: float) -> void:
	_t += dt
	queue_redraw()


func _draw() -> void:
	var wind := 0.0
	if main != null and main.get("weather") != null:
		wind = main.weather.wind_vec().length()
	var s := clampf(wind / 15.0, 0.0, 1.0)          # 0..1 сила ветра

	var px := 8.0
	var ptop := 8.0
	var pbot := 80.0
	# флагшток
	draw_line(Vector2(px, ptop), Vector2(px, pbot), Color(0.2, 0.2, 0.23, 0.9), 3.0)
	draw_circle(Vector2(px, ptop), 3.5, Color(0.85, 0.85, 0.5, 0.95))

	var flag_len := lerpf(16.0, 82.0, s)
	var droop := lerpf(48.0, 3.0, s)                 # провис вниз в штиль
	var n := 12
	var top := PackedVector2Array()
	var bot := PackedVector2Array()
	for i in n + 1:
		var f := float(i) / n
		var x := px + flag_len * f
		var wave := sin(f * 7.0 - _t * (3.0 + s * 10.0)) * (2.0 + s * 11.0) * f
		var cy := ptop + droop * f + wave
		var hh := lerpf(9.0, 2.5, f)                 # сужение к концу
		top.append(Vector2(x, cy - hh))
		bot.append(Vector2(x, cy + hh))
	# полосы вымпела
	for i in n:
		var quad := PackedVector2Array([top[i], top[i + 1], bot[i + 1], bot[i]])
		var col := Color(0.95, 0.42, 0.08, 0.96) if i % 2 == 0 else Color(0.95, 0.95, 0.92, 0.96)
		draw_colored_polygon(quad, col)
