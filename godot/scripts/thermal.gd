extends Node
## Тепловизор (LWIR): глобальный uniform thermal_params для своих шейдеров + material_override
## (unshaded emission = «температура» 0..1) для мешей со StandardMaterial3D: дороги, крыши, столбы, техника,
## машины, вода-озёра, мачты РЭБ. Техника/люди/двигатели — горячие, взрывы — очень горячие с остыванием.
## Пост-обработка (256×192, шум, AGC, ореол, палитры, FFC-фризы) — в fpv.gdshader, управляется из fpv_link.

var main: Node3D
var active := false
var palette := 0                  # 0 white-hot, 1 black-hot, 2 ironbow
const PALETTES := ["WHITE HOT", "BLACK HOT", "IRONBOW"]
var _mats := {}                   # temp -> StandardMaterial3D
var _saved := {}                  # instance_id -> прежний material_override (восстанавливаем при выключении)
var _acc := 0.0
# температуры по группам (день); ночью ×0.8 кроме техники/людей
const T_ROAD := 0.66
const T_ROOF := 0.68
const T_PROP := 0.45
const T_VEHICLE := 0.88
const T_SOLDIER := 0.95
const T_CAR := 0.80
const T_WRECK := 1.0
const T_LAKE := 0.14
const T_EW := 0.55


func setup(m: Node3D) -> void:
	main = m
	RenderingServer.global_shader_parameter_set("thermal_params", Vector4(0, 0, 0, 0))


func _mat(t: float) -> StandardMaterial3D:
	var key := snappedf(t, 0.01)
	if not _mats.has(key):
		var mt := StandardMaterial3D.new()
		mt.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		mt.albedo_color = Color(t, t, t)
		mt.vertex_color_use_as_albedo = false
		_mats[key] = mt
	return _mats[key]


func toggle() -> void:
	set_active(not active)


func set_active(on: bool) -> void:
	active = on
	_apply_overrides()
	if not active:
		for id in _saved.keys():
			var g = instance_from_id(id)
			if g != null and is_instance_valid(g):
				g.material_override = _saved[id]
		_saved.clear()
	_update_global()
	print("Тепловизор: ", "ВКЛ (%s)" % PALETTES[palette] if on else "ВЫКЛ")


func cycle_palette() -> void:
	palette = (palette + 1) % PALETTES.size()


func _update_global() -> void:
	var night := 0.0
	if main.weather != null and int(main.weather.idx) == 4: night = 1.0
	RenderingServer.global_shader_parameter_set("thermal_params", Vector4(1.0 if active else 0.0, night, 0.0, 0.0))


func _night_k() -> float:
	if main.weather != null and int(main.weather.idx) == 4: return 0.8
	return 1.0


func _override(node: Node, t: float) -> void:
	if node is GeometryInstance3D:
		_set_override(node, _mat(t * _night_k()))
	for ch in node.get_children():
		_override(ch, t)


## Ставит/снимает тепловой override, сохраняя прежний (купола РЭБ, ворота миссий и т.п. живут на material_override).
func _set_override(g: GeometryInstance3D, mt: Material) -> void:
	var id := g.get_instance_id()
	if active:
		if not _saved.has(id):
			_saved[id] = g.material_override
		g.material_override = mt
	else:
		if _saved.has(id):
			g.material_override = _saved[id]
			_saved.erase(id)
		elif g.material_override != null and _mats.values().has(g.material_override):
			g.material_override = null


func _apply_overrides() -> void:
	var nk := _night_k()
	for nm_t: Array in [["Roads", T_ROAD], ["Roofs", T_ROOF], ["BlockRoofs", T_ROOF], ["Chimneys", T_ROOF + 0.1],
			["Props", T_PROP], ["Traffic", T_CAR], ["Yards", T_PROP],
			["Villagers", T_SOLDIER - 0.06]]:   # житель чуть холоднее пехотинца — оператор учится различать. EW не трогаем
		var n := main.get_node_or_null(str(nm_t[0]))
		if n != null:
			_override(n, float(nm_t[1]))
	# вода-озёра/реки — свой шейдер (ветка в water.gdshader); цели — по типу
	if main.targets != null:
		for t: Dictionary in main.targets.targets:
			var temp: float = T_SOLDIER if t.kind == "soldier" else T_VEHICLE
			if not t.alive: temp = T_WRECK * clampf(1.0 - float(t.wreck_t) / 60.0, 0.4, 1.0)
			if t.node is GeometryInstance3D:
				_set_override(t.node, _mat(temp))
			for ch in t.node.get_children():
				if ch is GeometryInstance3D:
					ch.visible = not active       # маркеры-столбы в тепле не видны
	# снаряды/взрывы — обломки горячие (через targets._projs: мелкие сферы)
	if main.targets != null:
		for pr: Dictionary in main.targets._projs:
			if pr.node is GeometryInstance3D:
				_set_override(pr.node, _mat(0.7))


func _process(dt: float) -> void:
	if not active:
		return
	_acc += dt
	if _acc < 0.5:
		return
	_acc = 0.0
	_apply_overrides()          # новые цели/машины/снаряды получают override
	_update_global()
