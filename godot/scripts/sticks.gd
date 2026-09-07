extends Control
## Индикатор стиков пульта (mode 2): слева газ+рыскание, справа тангаж+крен.
## Нужен курсанту и инструктору: видно, что делает рука, а не только что делает дрон.

var main: Node3D
const BOX := 64.0
const GAP := 14.0
const LINE := Color(1, 1, 1, 0.55)
const DOT := Color(0.55, 1.0, 0.55, 0.95)
const TXT := Color(1, 1, 1, 0.8)


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	custom_minimum_size = Vector2(BOX * 2 + GAP, BOX + 22)


func _process(_dt: float) -> void:
	queue_redraw()


func _draw() -> void:
	if main == null or main.cam == null:
		return
	var cam: Node = main.cam
	var f := get_theme_default_font()
	# левый: X = рыскание (-1..1), Y = газ (0..1, вверх)
	var thr: float = cam.get("st_thr")
	var yaw: float = cam.get("st_yaw")
	var pit: float = cam.get("st_pitch")
	var rol: float = cam.get("st_roll")
	_box(Vector2(0, 0), yaw, thr * 2.0 - 1.0, "ГАЗ / РИСК", f)
	_box(Vector2(BOX + GAP, 0), rol, pit, "ТАНГ / КРЕН", f)


func _box(at: Vector2, x: float, y: float, label: String, f: Font) -> void:
	draw_rect(Rect2(at, Vector2(BOX, BOX)), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(at, Vector2(BOX, BOX)), LINE, false, 1.2)
	var c := at + Vector2(BOX, BOX) * 0.5
	draw_line(Vector2(at.x, c.y), Vector2(at.x + BOX, c.y), Color(1, 1, 1, 0.18), 1.0)
	draw_line(Vector2(c.x, at.y), Vector2(c.x, at.y + BOX), Color(1, 1, 1, 0.18), 1.0)
	var p := c + Vector2(clampf(x, -1, 1), -clampf(y, -1, 1)) * (BOX * 0.5 - 4.0)
	draw_line(c, p, Color(0.55, 1.0, 0.55, 0.4), 1.5)
	draw_circle(p, 4.5, DOT)
	draw_string(f, at + Vector2(0, BOX + 15), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 11, TXT)
