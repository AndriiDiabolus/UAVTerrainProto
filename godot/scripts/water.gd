extends Node3D
## Вода: реки/ручьи лентами по руслу + водоёмы полигонами (плоское зеркало).

const STEP := 8.0
const HALF := {"river": 5.5, "stream": 1.6}


func setup(main: Node3D) -> void:
	var t0 := Time.get_ticks_msec()
	var mat := ShaderMaterial.new()
	mat.shader = load("res://scripts/water.gdshader")
	mat.set_shader_parameter("wave_tex", _wave_noise())

	var V := PackedVector3Array()
	var N := PackedVector3Array()
	var I := PackedInt32Array()

	var nriv := 0
	var f := FileAccess.get_file_as_string("res://assets/water.json")
	if not f.is_empty():
		for w: Dictionary in JSON.parse_string(f)["w"]:
			var hw: float = HALF.get(w["c"], 1.6)
			_ribbon(main, w["p"], hw, V, N, I)
			nriv += 1

	var nlake := 0
	var lf := FileAccess.get_file_as_string("res://assets/lakes.json")
	if not lf.is_empty():
		for poly: Array in JSON.parse_string(lf)["a"]:
			if _polygon(main, poly, V, N, I):
				nlake += 1

	if V.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V
	arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_INDEX] = I
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "WaterSurface"
	mi.mesh = mesh
	add_child(mi)
	print("Water: %d водотоков, %d водоёмов, %d вершин за %d мс" % [
		nriv, nlake, V.size(), Time.get_ticks_msec() - t0])


## Высота уреза воды: минимум рельефа поперёк русла (вода лежит в низине).
func _bed_h(main: Node3D, c: Vector2, perp: Vector2, hw: float) -> float:
	var h: float = main.height_at(c.x, c.y)
	for k: float in [-1.4, -0.7, 0.7, 1.4]:
		var p: Vector2 = c + perp * hw * k
		h = minf(h, main.height_at(p.x, p.y))
	return h


func _ribbon(main: Node3D, pts: Array, hw: float, V: PackedVector3Array,
		N: PackedVector3Array, I: PackedInt32Array) -> void:
	# ресемплинг
	var s: Array[Vector2] = []
	var prev := Vector2(pts[0][0], pts[0][1])
	s.append(prev)
	for k in range(1, pts.size()):
		var cur := Vector2(pts[k][0], pts[k][1])
		var n := maxi(1, int(prev.distance_to(cur) / STEP))
		for j in range(1, n + 1):
			s.append(prev.lerp(cur, float(j) / n))
		prev = cur
	if s.size() < 2:
		return

	# высоты уреза + сглаживание вдоль потока (вода не скачет по грубой сетке)
	var hs := PackedFloat32Array(); hs.resize(s.size())
	for j in s.size():
		var d: Vector2
		if j == 0: d = s[1] - s[0]
		elif j == s.size() - 1: d = s[j] - s[j - 1]
		else: d = s[j + 1] - s[j - 1]
		if d.length_squared() < 1e-6: d = Vector2(1, 0)
		d = d.normalized()
		hs[j] = _bed_h(main, s[j], Vector2(-d.y, d.x), hw)
	for _pass in 3:
		var sm := hs.duplicate()
		for j in range(1, hs.size() - 1):
			sm[j] = (hs[j - 1] + hs[j] * 2.0 + hs[j + 1]) * 0.25
		hs = sm

	var start := V.size()
	for j in s.size():
		var d: Vector2
		if j == 0: d = s[1] - s[0]
		elif j == s.size() - 1: d = s[j] - s[j - 1]
		else: d = s[j + 1] - s[j - 1]
		if d.length_squared() < 1e-6: d = Vector2(1, 0)
		d = d.normalized()
		var perp := Vector2(-d.y, d.x)
		var y := hs[j] + 0.12
		var l: Vector2 = s[j] + perp * hw
		var r: Vector2 = s[j] - perp * hw
		V.append(Vector3(l.x, y, l.y)); N.append(Vector3.UP)
		V.append(Vector3(r.x, y, r.y)); N.append(Vector3.UP)
	for j in s.size() - 1:
		var b := start + j * 2
		I.append(b); I.append(b + 2); I.append(b + 1)
		I.append(b + 1); I.append(b + 2); I.append(b + 3)


## Водоём: плоское зеркало на уровне минимальной высоты берега.
func _polygon(main: Node3D, poly: Array, V: PackedVector3Array,
		N: PackedVector3Array, I: PackedInt32Array) -> bool:
	var pts := PackedVector2Array()
	var y := 1e9
	var cx := 0.0; var cz := 0.0
	for p: Array in poly:
		pts.append(Vector2(p[0], p[1]))
		y = minf(y, main.height_at(p[0], p[1]))
		cx += p[0]; cz += p[1]
	if pts.size() < 3:
		return false
	cx /= pts.size(); cz /= pts.size()
	# Рельеф (51 м/узел) не разрешает котловины горных озёр: центр часто ВЫШЕ
	# берега, и плоское зеркало тонет. Ставим воду поверх внутреннего «горба»,
	# ограничив подъём, чтобы не залить окрестности.
	var y_min := y
	var y_in := -1e9
	var bmin := Vector2(1e9, 1e9); var bmax := Vector2(-1e9, -1e9)
	for p in pts:
		bmin = bmin.min(p); bmax = bmax.max(p)
	for gi in 6:
		for gj in 6:
			var s := Vector2(lerpf(bmin.x, bmax.x, (gi + 0.5) / 6.0),
				lerpf(bmin.y, bmax.y, (gj + 0.5) / 6.0))
			if Geometry2D.is_point_in_polygon(s, pts):
				y_in = maxf(y_in, main.height_at(s.x, s.y))
	if y_in > -1e8:
		y = clampf(y_in + 0.35, y_min, y_min + 9.0)
	if "--waterdebug" in OS.get_cmdline_user_args():
		print("  озеро центр(%.0f,%.0f) h_центра=%.1f h_воды=%.1f" % [
			cx, cz, main.height_at(cx, cz), y])
	var tri := Geometry2D.triangulate_polygon(pts)
	if tri.is_empty():
		return false
	y += 0.15
	var start := V.size()
	for p in pts:
		V.append(Vector3(p.x, y, p.y))
		N.append(Vector3.UP)
	for k in range(0, tri.size(), 3):     # разворот обхода под Godot
		I.append(start + tri[k])
		I.append(start + tri[k + 2])
		I.append(start + tri[k + 1])
	return true


## Бесшовный шум для волн.
func _wave_noise() -> ImageTexture:
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX
	n.frequency = 0.03
	n.fractal_octaves = 3
	var img := n.get_seamless_image(256, 256)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)
