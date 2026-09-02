extends Node3D
## Внешняя модель дрона игрока (units.drone_fpv7) и всё вокруг неё:
## - вид от ТРЕТЬЕГО лица: клавиша U — 1-е ⇄ 3-е лицо; chase-камера с плавным хвостом,
##   модель наклоняется как корпус flycam.body, пропеллеры крутятся по газу;
## - ВЕРТУШКА в главном меню: модель крупно вращается в трёх осях перед камерой облёта;
## - СКИНЫ 1..3 (классика / полевой / ночной) — пункт меню «скин», user://settings.cfg.
## В FPV-очках (F) модель скрыта (иначе видна изнутри камерой видеотракта).

var main: Node3D
var skin := 1
var third := false
const SKIN_NAMES := ["классика", "полевой", "ночной"]

var model: Node3D
var _props: Array = []
var _chase: Camera3D
var _spin := 0.0
var _menu_t := 0.0
var _user_rot := Basis()      # ручное вращение вертушки мышью (трекбол в осях камеры)
var _idle := 99.0             # секунд с последнего драга; авто-вращение после паузы


## Драг мышью в меню: вращение модели на 360° по всем осям (в экранных осях).
func orbit(rel: Vector2) -> void:
	_idle = 0.0
	_user_rot = Basis(Vector3.UP, -rel.x * 0.01) * Basis(Vector3(1, 0, 0), -rel.y * 0.01) * _user_rot


func setup(m: Node3D) -> void:
	main = m
	process_priority = 30                       # после menu._process (позиция от камеры облёта)
	var cfg := ConfigFile.new()
	if cfg.load("user://settings.cfg") == OK:
		skin = clampi(int(cfg.get_value("game", "drone_skin", 1)), 1, 3)
	_build_model()
	_chase = Camera3D.new()
	_chase.near = 0.2
	_chase.far = 150000.0
	_chase.fov = 72.0
	add_child(_chase)


var _built_for := ""
var _built_weapon := -2

func _cur_weapon() -> int:
	return int(main.targets.weapon) if main.get("targets") != null and main.targets != null else -1

func _build_model() -> void:
	if model != null:
		model.queue_free()
	var U = load("res://scripts/units.gd").new()
	_built_for = str(main.cam.drone_id) if main.cam != null and main.cam.get("drone_id") != null else "fpv7"
	_built_weapon = _cur_weapon()
	var d: Dictionary = U.build_drone(_built_for, skin, _built_weapon)
	model = d.root
	_props = d.props
	model.visible = false
	add_child(model)


func set_skin(s: int) -> void:
	skin = posmod(s - 1, 3) + 1
	var cfg := ConfigFile.new()
	cfg.load("user://settings.cfg")
	cfg.set_value("game", "drone_skin", skin)
	cfg.save("user://settings.cfg")
	_build_model()


func skin_name() -> String:
	return SKIN_NAMES[skin - 1]


func toggle_third() -> void:
	third = not third
	if third and main.hud != null and main.hud.fpv_on:
		main.hud._toggle_fpv()                  # из очков выходим в обычный вид
	if not third:
		_to_first()
	elif main.hud != null and main.hud.has_method("toast"):
		main.hud.toast("ВИД · ТРЕТЬЕ ЛИЦО", "U — вернуться к виду с борта", Color(0.62, 0.86, 1.0))


func _to_first() -> void:
	if _chase.current:
		main.cam.make_current()
	model.visible = false
	if main.hud != null and main.hud.has_method("toast"):
		main.hud.toast("ВИД · С БОРТА", "", Color(0.62, 0.86, 1.0))


func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and not e.echo and e.keycode == KEY_U:
		if main == null or main.get("menu_open") == true:
			return
		toggle_third()


func _process(dt: float) -> void:
	if main == null or main.cam == null or model == null:
		return
	if (main.cam.get("drone_id") != null and str(main.cam.drone_id) != _built_for) or _cur_weapon() != _built_weapon:
		_build_model()                          # сменили профиль (B/меню) или оружие (V/меню) — модель перестраивается
	var thr := 0.35
	if main.cam.get("throttle") != null:
		thr = clampf(float(main.cam.throttle), 0.0, 1.0)
	_spin += dt * (16.0 + 120.0 * thr)
	var menu: bool = main.get("menu_open") == true
	var fpv: bool = main.hud != null and main.hud.get("fpv_on") == true

	if menu:
		# вертушка: крупная модель перед камерой облёта, вращение в трёх осях
		if _chase.current:
			main.cam.make_current()
		_idle += dt
		if _idle > 3.0:
			_menu_t += dt                       # авто-вращение возобновляется после паузы драга
		model.visible = true
		var ct: Transform3D = main.cam.global_transform
		var rot := _user_rot * Basis(Vector3.UP, _menu_t * 0.7) \
			* Basis(Vector3(1, 0, 0), sin(_menu_t * 0.41) * 0.34) \
			* Basis(Vector3(0, 0, 1), sin(_menu_t * 0.23) * 0.2)
		var msc: float = {"fpv7": 6.5, "fpv5": 7.5, "mavic": 6.0, "mship": 1.9, "wing": 1.0}.get(_built_for, 6.5)
		# модель — в центре ИГРОВОЙ области экрана (окно минус панель меню 434 px слева)
		var vps := get_viewport().get_visible_rect().size
		var pos: Vector3 = main.cam.project_position(Vector2((434.0 + vps.x) * 0.5, vps.y * 0.5), 3.6)
		model.global_transform = Transform3D(ct.basis * rot * Basis.from_scale(Vector3.ONE * msc), pos)
	elif third and not fpv and not main.get("replaying"):
		model.visible = true
		var b: Basis = main.cam.body if main.cam.get("body") != null else main.cam.global_transform.basis
		var dp: Vector3 = main.cam.global_position
		model.global_transform = Transform3D(b, dp)
		var fwd: Vector3 = -b.z
		fwd.y = 0.0
		fwd = fwd.normalized() if fwd.length_squared() > 0.001 else Vector3.FORWARD
		var big := _built_for in ["mship", "wing"]
		var tgt: Vector3 = dp - fwd * (4.4 if big else 1.55) + Vector3(0, 1.3 if big else 0.42, 0)
		tgt.y = maxf(tgt.y, main.height_at(tgt.x, tgt.z) + 0.35)
		var k := 1.0 - exp(-dt * 8.0)
		if _chase.global_position.distance_to(tgt) > 60.0:
			k = 1.0                              # телепорт/рестарт — догоняем мгновенно
		_chase.global_position = _chase.global_position.lerp(tgt, k)
		_chase.look_at(dp + fwd * (2.8 if big else 1.1) + Vector3(0, 0.06, 0), Vector3.UP)
		if not _chase.current:
			_chase.make_current()
	else:
		model.visible = false
		if _chase.current:
			main.cam.make_current()

	if model.visible:
		for i in _props.size():
			var pr: Node3D = _props[i]
			pr.rotation.y = _spin * (1.0 if i % 2 == 0 else -1.0)
