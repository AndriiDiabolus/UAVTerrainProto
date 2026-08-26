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
	_build_water_index(main)

	# арены вершин: два дорожных материала + бетон мостов
	var av := {"asph": _arena(), "grav": _arena(), "bridge": _arena()}
	for r: Dictionary in roads:
		var cls: String = r["c"]
		if not CLASS.has(cls):
			continue
		var hw: float = CLASS[cls][0]
		var asph: bool = CLASS[cls][1]
		_ribbon(main, r["p"], hw, 0.22 if asph else 0.15, av["asph" if asph else "grav"], av["bridge"])
		_index(main, r["p"], hw)

	_emit(main, av["asph"], _asph_mat(main), "Asphalt")
	_emit(main, av["grav"], _grav_mat(main), "Gravel")
	_emit(main, av["bridge"], _bridge_mat(), "Bridges")
	print("Roads built in %d ms (asph v=%d, grav v=%d, мостовых ячеек %d)" % [
		Time.get_ticks_msec() - t0, av["asph"].V.size(), av["grav"].V.size(), main.deck_index.size()])


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


# ---------------- мосты: индекс водных линий (ячейки 32 м) ----------------
const WHALF := {"river": 5.5, "stream": 1.6}
var _wcells := {}                 # Vector2i -> Array сегментов [ax,ay,bx,by,hw]


func _build_water_index(main: Node3D) -> void:
	var f := FileAccess.get_file_as_string(main.asset_path("water.json"))
	if f.is_empty():
		return
	for w: Dictionary in JSON.parse_string(f)["w"]:
		var hw: float = WHALF.get(w["c"], 1.6)
		var pts: Array = w["p"]
		for i in range(1, pts.size()):
			var a := Vector2(pts[i - 1][0], pts[i - 1][1]); var b := Vector2(pts[i][0], pts[i][1])
			var seg := [a.x, a.y, b.x, b.y, hw]
			var steps := int(a.distance_to(b) / IDX_CELL) + 1
			var seen := {}
			for k in steps + 1:
				var q := a.lerp(b, float(k) / steps)
				for dx in [-1, 0, 1]:
					for dz in [-1, 0, 1]:
						var c := Vector2i(int(floor(q.x / IDX_CELL)) + dx, int(floor(q.y / IDX_CELL)) + dz)
						if seen.has(c): continue
						seen[c] = true
						if not _wcells.has(c): _wcells[c] = []
						_wcells[c].append(seg)


## Точка ближе (полуширина воды + margin) к водной линии?
func _near_water(x: float, z: float, margin: float) -> bool:
	var c := Vector2i(int(floor(x / IDX_CELL)), int(floor(z / IDX_CELL)))
	if not _wcells.has(c):
		return false
	var p := Vector2(x, z)
	for s: Array in _wcells[c]:
		var a := Vector2(s[0], s[1]); var b := Vector2(s[2], s[3])
		var ab := b - a
		var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
		if p.distance_to(a + ab * t) <= float(s[4]) + margin:
			return true
	return false


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


func _ribbon(main: Node3D, pts: Array, hw: float, off: float, a: Dictionary, br: Dictionary) -> void:
	var s := _resample(pts)
	if s.size() < 2:
		return
	var V: PackedVector3Array = a.V
	var N: PackedVector3Array = a.N
	var U: PackedVector2Array = a.U
	var I: PackedInt32Array = a.I
	var start := V.size()
	# первый проход: края, высоты, признак «над водой»
	var pl: Array[Vector2] = []; var pr: Array[Vector2] = []
	var hl := PackedFloat32Array(); var hr := PackedFloat32Array()
	var wet := PackedByteArray()
	pl.resize(s.size()); pr.resize(s.size())
	hl.resize(s.size()); hr.resize(s.size()); wet.resize(s.size())
	var any_wet := false
	for j in s.size():
		var dir: Vector2
		if j == 0: dir = s[1] - s[0]
		elif j == s.size() - 1: dir = s[j] - s[j - 1]
		else: dir = s[j + 1] - s[j - 1]
		if dir.length_squared() < 1e-6: dir = Vector2(1, 0)
		dir = dir.normalized()
		var perp := Vector2(-dir.y, dir.x)
		var sj: Vector2 = s[j]
		pl[j] = sj + perp * hw
		pr[j] = sj - perp * hw
		hl[j] = main.height_at(pl[j].x, pl[j].y)
		hr[j] = main.height_at(pr[j].x, pr[j].y)
		if _near_water(sj.x, sj.y, hw + 2.0):
			wet[j] = 1; any_wet = true
	# мосты: непрерывный «мокрый» отрезок → плоская палуба между берегами (не ныряет в русло)
	var deck := PackedByteArray(); deck.resize(s.size())
	if any_wet:
		var j := 0
		while j < s.size():
			if wet[j] == 0:
				j += 1; continue
			var j0 := j
			while j < s.size() and wet[j] == 1:
				j += 1
			var j1 := j - 1                                  # [j0..j1] над водой
			var ib := maxi(j0 - 1, 0); var ie := mini(j1 + 1, s.size() - 1)
			var hb := maxf(hl[ib], hr[ib]); var he := maxf(hl[ie], hr[ie])
			for k in range(j0, j1 + 1):
				var t := float(k - j0 + 1) / float(j1 - j0 + 2)
				var d := lerpf(hb, he, t) + 0.55
				if d > maxf(hl[k], hr[k]):                   # палуба только выше рельефа
					hl[k] = d; hr[k] = d; deck[k] = 1
	var cum := 0.0
	for j in s.size():
		if j > 0: cum += s[j].distance_to(s[j - 1])
		V.append(Vector3(pl[j].x, hl[j] + off, pl[j].y))
		N.append(Vector3.UP); U.append(Vector2(cum / TILE, 0.0))
		V.append(Vector3(pr[j].x, hr[j] + off, pr[j].y))
		N.append(Vector3.UP); U.append(Vector2(cum / TILE, hw * 2.0 / TILE))
	for j in s.size() - 1:
		var b := start + j * 2
		I.append(b); I.append(b + 2); I.append(b + 1)
		I.append(b + 1); I.append(b + 2); I.append(b + 3)
	# индекс палуб для трафика/машин (main.deck_h)
	if any_wet:
		for j in s.size() - 1:
			if deck[j] == 1 and deck[j + 1] == 1:
				var seg := [s[j].x, s[j].y, s[j + 1].x, s[j + 1].y, hw, hl[j] + off, hl[j + 1] + off]
				var cellset := {}
				for q2: Vector2 in [s[j], s[j + 1]]:
					for dx in [-1, 0, 1]:
						for dz in [-1, 0, 1]:
							var c2 := Vector2i(int(floor(q2.x / IDX_CELL)) + dx, int(floor(q2.y / IDX_CELL)) + dz)
							if cellset.has(c2): continue
							cellset[c2] = true
							if not main.deck_index.has(c2): main.deck_index[c2] = []
							main.deck_index[c2].append(seg)
	# мостовые конструкции (бетонная арена): юбка палубы, поручень-брус, стойки (кроме полевых track)
	if any_wet and hw >= 1.8:
		var j := 0
		while j < s.size() - 1:
			if deck[j] == 0 or deck[j + 1] == 0:
				j += 1; continue
			for side in 2:
				var e0: Vector2 = pl[j] if side == 0 else pr[j]
				var e1: Vector2 = pl[j + 1] if side == 0 else pr[j + 1]
				var y0 := hl[j] + off; var y1 := hl[j + 1] + off
				var out2 := Vector2(e0.x - s[j].x, e0.y - s[j].y).normalized() * 0.12
				# юбка: сплошная лента от +0.25 (бордюр) до −0.9 под палубой
				_bquad(br, Vector3(e0.x, y0 + 0.25, e0.y), Vector3(e1.x, y1 + 0.25, e1.y),
					Vector3(e1.x, y1 - 0.9, e1.y), Vector3(e0.x, y0 - 0.9, e0.y))
				# поручень: горизонтальный брус 0.14 м на высоте 1.05 м (внешняя грань + верх)
				_bquad(br, Vector3(e0.x, y0 + 1.05, e0.y), Vector3(e1.x, y1 + 1.05, e1.y),
					Vector3(e1.x, y1 + 0.91, e1.y), Vector3(e0.x, y0 + 0.91, e0.y))
				_bquad(br, Vector3(e0.x - out2.x, y0 + 1.05, e0.y - out2.y), Vector3(e1.x - out2.x, y1 + 1.05, e1.y - out2.y),
					Vector3(e1.x + out2.x, y1 + 1.05, e1.y + out2.y), Vector3(e0.x + out2.x, y0 + 1.05, e0.y + out2.y))
				# стойки перил: каждые ~3 м, крест из двух узких квадов от бордюра до поручня
				var seg_len := e0.distance_to(e1)
				var nposts := maxi(1, int(seg_len / 3.0))
				for pi2 in nposts:
					var tpi := (pi2 + 0.5) / float(nposts)
					var px := lerpf(e0.x, e1.x, tpi); var pz := lerpf(e0.y, e1.y, tpi)
					var py := lerpf(y0, y1, tpi)
					for ax in 2:
						var d2 := Vector3(0.07, 0, 0) if ax == 0 else Vector3(0, 0, 0.07)
						var base2 := Vector3(px, py + 0.25, pz)
						_bquad(br, base2 - d2, base2 + d2,
							base2 + d2 + Vector3(0, 0.66, 0), base2 - d2 + Vector3(0, 0.66, 0))
			j += 1


## Двусторонний квад в арену (мостовые конструкции).
func _bquad(a: Dictionary, p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3) -> void:
	var V: PackedVector3Array = a.V
	var N: PackedVector3Array = a.N
	var U: PackedVector2Array = a.U
	var I: PackedInt32Array = a.I
	var b := V.size()
	V.append_array([p0, p1, p2, p3])
	var nrm := (p1 - p0).cross(p3 - p0)
	nrm = nrm.normalized() if nrm.length_squared() > 1e-9 else Vector3.UP
	for k in 4: N.append(nrm)
	U.append_array([Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1)])
	I.append_array([b, b + 1, b + 2, b, b + 2, b + 3])
	I.append_array([b, b + 2, b + 1, b, b + 3, b + 2])


func _bridge_mat() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.58, 0.58, 0.57)      # старый бетон
	m.roughness = 0.95
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	return m


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
	# плоское на земле — тень не видна; мостовые конструкции наоборот дают читаемый объём
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if nm == "Bridges" else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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
