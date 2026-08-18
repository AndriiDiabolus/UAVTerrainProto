extends RefCounted
## Столкновения дрона с твёрдыми объектами (здания/столбы/деревья) и радиовидимость через рельеф.
## Пространственная сетка 64 м; деревья — по чанкам 512 м (регистрирует scatter.gd).

const COL_CELL := 64.0
const DRONE_R := 1.6
const CHUNK_M := 512.0
var main: Node3D
var _col_box := {}      # Vector2i(64м) -> Array[Dictionary] коробки зданий
var _col_cyl := {}      # Vector2i(64м) -> Array[Dictionary] столбы/фонари
var _tree_col := {}     # Vector2i(чанк 512м) -> Array[Dictionary] деревья


func _init(m: Node3D) -> void:
	main = m


func height_at(x: float, z: float) -> float:
	return main.height_at(x, z)


func stats() -> String:
	return "ячеек-коробок: %d, ячеек-цилиндров: %d, чанков деревьев: %d" % [_col_box.size(), _col_cyl.size(), _tree_col.size()]


func col_add_box(cx: float, cz: float, w: float, d: float, ang: float, top: float) -> void:
	var box := {"cx": cx, "cz": cz, "hw": w * 0.5, "hd": d * 0.5,
		"cs": cos(ang), "sn": sin(ang), "top": top}
	var r := maxf(w, d) * 0.5 + 2.0
	for gx in range(int(floor((cx - r) / COL_CELL)), int(floor((cx + r) / COL_CELL)) + 1):
		for gz in range(int(floor((cz - r) / COL_CELL)), int(floor((cz + r) / COL_CELL)) + 1):
			var k := Vector2i(gx, gz)
			if not _col_box.has(k): _col_box[k] = []
			_col_box[k].append(box)


func col_add_cyl(x: float, z: float, r: float, top: float) -> void:
	var k := Vector2i(int(floor(x / COL_CELL)), int(floor(z / COL_CELL)))
	if not _col_cyl.has(k): _col_cyl[k] = []
	_col_cyl[k].append({"x": x, "z": z, "r": r, "top": top})


func col_register_trees(chunk: Vector2i, arr: Array) -> void:
	_tree_col[chunk] = arr


func col_unregister_trees(chunk: Vector2i) -> void:
	_tree_col.erase(chunk)


## Проверка столкновения с твёрдыми объектами (не рельеф). "" если чисто.
func check_crash(pos: Vector3) -> String:
	var k := Vector2i(int(floor(pos.x / COL_CELL)), int(floor(pos.z / COL_CELL)))
	var g := height_at(pos.x, pos.z)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			var kk := k + Vector2i(dx, dz)
			for b: Dictionary in _col_box.get(kk, []):
				if pos.y - DRONE_R < b.top and pos.y + DRONE_R > g:
					var lx: float = (pos.x - b.cx) * b.cs + (pos.z - b.cz) * b.sn
					var lz: float = -(pos.x - b.cx) * b.sn + (pos.z - b.cz) * b.cs
					if absf(lx) < b.hw + DRONE_R and absf(lz) < b.hd + DRONE_R:
						return "здание"
			for c: Dictionary in _col_cyl.get(kk, []):
				if pos.y - DRONE_R < c.top and Vector2(pos.x - c.x, pos.z - c.z).length() < c.r + DRONE_R:
					return "столб / ЛЭП"
	var ck := Vector2i(int(floor(pos.x / CHUNK_M)), int(floor(pos.z / CHUNK_M)))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			for tr: Dictionary in _tree_col.get(ck + Vector2i(dx, dz), []):
				var tp: Vector3 = tr.pos
				if pos.y - DRONE_R < tp.y + tr.top and pos.y + DRONE_R > tp.y:
					if Vector2(pos.x - tp.x, pos.z - tp.z).length() < tr.r + DRONE_R:
						return "дерево"
	return ""


## Радиовидимость дрона с точки оператора: 1 = чистая прямая видимость,
## →0 = рельеф перекрывает линию (за горой/складкой сигнал теряется).
func los_factor(op: Vector3, drone: Vector3) -> float:
	var dist := op.distance_to(drone)
	if dist < 1.0:
		return 1.0
	var steps := clampi(int(dist / 30.0), 4, 120)
	var worst := 0.0                       # макс. «утопание» линии под рельеф, м
	for i in range(1, steps):
		var f := float(i) / steps
		var p := op.lerp(drone, f)
		var g := height_at(p.x, p.z)
		worst = maxf(worst, g - p.y)       # >0 — рельеф выше линии визирования
	if worst <= 0.0:
		return 1.0
	return clampf(1.0 - worst / 40.0, 0.0, 1.0)   # 40 м перекрытия = полная потеря


