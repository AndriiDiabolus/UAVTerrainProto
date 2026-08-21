extends Node3D
## Объёмное дорожное полотно из OSM-линий (roads.json): асфальт (трассы/улицы)
## и гравий (просёлки). Полотно-лента ложится по рельефу, ширина по классу.

const STEP := 6.0          # шаг ресемплинга вдоль дороги, м
const TILE := 7.0          # период текстуры, м

# класс -> [полуширина(м), асфальт?]
const CLASS := {
	"motorway": [4.5, true], "trunk": [4.0, true], "primary": [3.75, true],
	"secondary": [3.25, true], "tertiary": [2.75, true], "unclassified": [2.25, false],
	"residential": [2.2, true], "service": [1.8, false], "track": [1.5, false],
}


func setup(main: Node3D) -> void:
	var f := FileAccess.get_file_as_string(main.asset_path("roads.json"))
	if f.is_empty():
		return
	var roads: Array = JSON.parse_string(f)["roads"]
	var t0 := Time.get_ticks_msec()

	# арены вершин для двух материалов
	var av := {"asph": _arena(), "grav": _arena()}
	for r: Dictionary in roads:
		var cls: String = r["c"]
		if not CLASS.has(cls):
			continue
		var hw: float = CLASS[cls][0]
		var asph: bool = CLASS[cls][1]
		_ribbon(main, r["p"], hw, 0.22 if asph else 0.15, av["asph" if asph else "grav"])
		_index(main, r["p"], hw)

	_emit(main, av["asph"], _asph_mat(main), "Asphalt")
	_emit(main, av["grav"], _grav_mat(main), "Gravel")
	print("Roads built in %d ms (asph v=%d, grav v=%d)" % [
		Time.get_ticks_msec() - t0, av["asph"].V.size(), av["grav"].V.size()])


## Пространственный индекс сегментов дорог (ячейки 32 м) — для исключения травы/клаттера с полотна.
const IDX_CELL := 32.0
func _index(main: Node3D, pts: Array, hw: float) -> void:
	for i in range(1, pts.size()):
		var a := Vector2(pts[i - 1][0], pts[i - 1][1]); var b := Vector2(pts[i][0], pts[i][1])
		var seg := [a.x, a.y, b.x, b.y, hw]
		var L := a.distance_to(b)
		var steps := int(L / IDX_CELL) + 1
		var seen := {}
		for k in steps + 1:
			var q := a.lerp(b, float(k) / steps)
			for dx in [-1, 0, 1]:
				for dz in [-1, 0, 1]:
					var c := Vector2i(int(floor(q.x / IDX_CELL)) + dx, int(floor(q.y / IDX_CELL)) + dz)
					if seen.has(c): continue
					seen[c] = true
					if not main.road_index.has(c): main.road_index[c] = []
					main.road_index[c].append(seg)


func _arena() -> Dictionary:
	return {"V": PackedVector3Array(), "N": PackedVector3Array(),
		"U": PackedVector2Array(), "I": PackedInt32Array()}


func _resample(pts: Array) -> Array:
	var out: Array[Vector2] = []
	var prev := Vector2(pts[0][0], pts[0][1])
	out.append(prev)
	for k in range(1, pts.size()):
		var cur := Vector2(pts[k][0], pts[k][1])
		var dd := prev.distance_to(cur)
		var n := maxi(1, int(dd / STEP))
		for s in range(1, n + 1):
			out.append(prev.lerp(cur, float(s) / n))
		prev = cur
	return out


func _ribbon(main: Node3D, pts: Array, hw: float, off: float, a: Dictionary) -> void:
	var s := _resample(pts)
	if s.size() < 2:
		return
	var V: PackedVector3Array = a.V
	var N: PackedVector3Array = a.N
	var U: PackedVector2Array = a.U
	var I: PackedInt32Array = a.I
	var start := V.size()
	var cum := 0.0
	for j in s.size():
		var dir: Vector2
		if j == 0: dir = s[1] - s[0]
		elif j == s.size() - 1: dir = s[j] - s[j - 1]
		else: dir = s[j + 1] - s[j - 1]
		if dir.length_squared() < 1e-6: dir = Vector2(1, 0)
		dir = dir.normalized()
		if j > 0: cum += s[j].distance_to(s[j - 1])
		var perp := Vector2(-dir.y, dir.x)
		var sj: Vector2 = s[j]
		var l: Vector2 = sj + perp * hw
		var rr: Vector2 = sj - perp * hw
		V.append(Vector3(l.x, main.height_at(l.x, l.y) + off, l.y))
		N.append(Vector3.UP); U.append(Vector2(cum / TILE, 0.0))
		V.append(Vector3(rr.x, main.height_at(rr.x, rr.y) + off, rr.y))
		N.append(Vector3.UP); U.append(Vector2(cum / TILE, hw * 2.0 / TILE))
	for j in s.size() - 1:
		var b := start + j * 2
		I.append(b); I.append(b + 2); I.append(b + 1)
		I.append(b + 1); I.append(b + 2); I.append(b + 3)


func _emit(main: Node3D, a: Dictionary, mat: Material, nm: String) -> void:
	if a.V.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = a.V
	arr[Mesh.ARRAY_NORMAL] = a.N
	arr[Mesh.ARRAY_TEX_UV] = a.U
	arr[Mesh.ARRAY_INDEX] = a.I
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = nm
	mi.mesh = mesh
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # плоское на земле — тень не видна
	add_child(mi)


func _asph_mat(main: Node3D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = main._load_tex("asphalt_diff.jpg")
	m.albedo_color = Color(0.78, 0.78, 0.8)
	m.normal_enabled = true
	m.normal_texture = main._load_tex("asphalt_norm.jpg")
	m.roughness = 0.82
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


func _grav_mat(main: Node3D) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_texture = main._load_tex("gravel_diff.jpg")
	m.albedo_color = Color(0.78, 0.74, 0.66)
	m.normal_enabled = true
	m.normal_texture = main._load_tex("gravel_norm.jpg")
	m.roughness = 1.0
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m
