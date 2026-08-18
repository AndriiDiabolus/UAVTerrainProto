extends Node3D
## Стриминг деревьев вокруг камеры по маске лесов (mask.png: 1 = лес).

const CHUNK := 512.0
var radius := 3000.0          # радиус стриминга (меняется пресетом качества)
const ATTEMPTS := 420          # попыток посадки на чанк (~сетка 25 м)
const GEN_PER_TICK := 2

var main: Node3D
var mask: Image
var mpx: int
var tree_meshes: Array[ArrayMesh] = []
var tree_weights := [0.40, 0.15, 0.30, 0.10, 0.05]   # ель/сосна/листв./берёза/куст
var chunks := {}               # Vector2i -> Node3D (набор MultiMesh) или null (пустой чанк)
var _accum := 0.0
var _queue: Array[Vector2i] = []
var _tree_mats: Array[ShaderMaterial] = []
var _cur_str := 0.2
var _cur_dir := Vector2(1, 0)


func setup(m: Node3D) -> void:
	main = m
	mask = main.load_image(main.asset_path("mask.png"))
	if mask == null:
		push_warning("scatter: mask.png не найдена")
		return
	mpx = mask.get_width()
	tree_meshes = _make_trees()


func _process(dt: float) -> void:
	if main == null or main.cam == null or mask == null:
		return
	# ветер в кронах — сглаживаем каждый кадр (амплитуду и направление),
	# чтобы сила/направление не менялись скачками
	if main.get("weather") != null:
		var w: Vector3 = main.weather.wind_vec()
		var wl := w.length()
		var tgt_str := clampf(wl / 6.0, 0.12, 2.6)
		var tgt_dir := Vector2(w.x, w.z).normalized() if wl > 0.01 else _cur_dir
		_cur_str = lerpf(_cur_str, tgt_str, clampf(dt * 1.8, 0.0, 1.0))
		_cur_dir = _cur_dir.lerp(tgt_dir, clampf(dt * 1.2, 0.0, 1.0))
		if _cur_dir.length() > 0.001:
			_cur_dir = _cur_dir.normalized()
		for m in _tree_mats:
			m.set_shader_parameter("wind_dir", _cur_dir)
			m.set_shader_parameter("wind_strength", _cur_str)
	_accum += dt
	if _accum >= 0.25:
		_accum = 0.0
		_update_wanted()
	for i in GEN_PER_TICK:
		if _queue.is_empty():
			break
		_gen_chunk(_queue.pop_front())


func _update_wanted() -> void:
	var p: Vector3 = main.cam.global_position
	var cc := Vector2i(int(floor(p.x / CHUNK)), int(floor(p.z / CHUNK)))
	var r := int(ceil(radius / CHUNK))
	for cy in range(cc.y - r, cc.y + r + 1):
		for cx in range(cc.x - r, cc.x + r + 1):
			var c := Vector2i(cx, cy)
			if chunks.has(c) or _queue.has(c):
				continue
			var center := Vector2((cx + 0.5) * CHUNK, (cy + 0.5) * CHUNK)
			if center.distance_to(Vector2(p.x, p.z)) <= radius:
				_queue.append(c)
	# выгрузка дальних
	var to_free: Array[Vector2i] = []
	for c: Vector2i in chunks:
		var center := Vector2((c.x + 0.5) * CHUNK, (c.y + 0.5) * CHUNK)
		if center.distance_to(Vector2(p.x, p.z)) > radius + 2.0 * CHUNK:
			to_free.append(c)
	for c in to_free:
		if chunks[c] != null:
			chunks[c].queue_free()
		chunks.erase(c)
		main.col_unregister_trees(c)


func _pick_type(r: float) -> int:
	var acc := 0.0
	for i in tree_weights.size():
		acc += tree_weights[i]
		if r <= acc:
			return i
	return 0


func _gen_chunk(c: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = (int(c.x) * 73856093) ^ (int(c.y) * 19349663)
	var half: float = main.size_m * 0.5
	var xf: Array = []; var cl: Array = []
	for k in tree_meshes.size():
		xf.append([] as Array[Transform3D]); cl.append([] as Array[Color])
	# коллизия: радиус ствола/кроны и высота по типу (× масштаб экземпляра)
	var col_r := [1.4, 1.2, 2.8, 1.6, 1.4]
	var col_h := [14.0, 18.0, 12.0, 13.0, 3.0]
	var tcol: Array[Dictionary] = []
	for i in ATTEMPTS:
		var wx := (c.x + rng.randf()) * CHUNK
		var wz := (c.y + rng.randf()) * CHUNK
		if absf(wx) >= half or absf(wz) >= half:
			continue
		var mx := int((wx / main.size_m + 0.5) * (mpx - 1))
		var mz := int((wz / main.size_m + 0.5) * (mpx - 1))
		if int(round(mask.get_pixel(mx, mz).r * 255.0)) != 1:
			continue
		var ti := _pick_type(rng.randf())
		var s := rng.randf_range(0.6, 1.45)
		var gy: float = main.height_at(wx, wz) - 0.3
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(s, s * rng.randf_range(0.85, 1.2), s))
		xf[ti].append(Transform3D(basis, Vector3(wx, gy, wz)))
		var g := rng.randf_range(0.82, 1.14)                       # вариация зелени/яркости
		cl[ti].append(Color(g * rng.randf_range(0.85, 1.0), g, g * rng.randf_range(0.72, 0.95)))
		tcol.append({"pos": Vector3(wx, gy, wz), "r": col_r[ti] * s * 0.6, "top": col_h[ti] * s})
	main.col_register_trees(c, tcol)
	var total := 0
	for k in xf.size():
		total += xf[k].size()
	if total == 0:
		chunks[c] = null
		return
	var holder := Node3D.new()
	add_child(holder)
	for k in tree_meshes.size():
		if xf[k].is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = tree_meshes[k]
		mm.instance_count = xf[k].size()
		for i in xf[k].size():
			mm.set_instance_transform(i, xf[k][i])
			mm.set_instance_color(i, cl[k][i])
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		holder.add_child(mmi)
	chunks[c] = holder


## Собирает дерево из примитивов [prim, y_offset, color]; instance color тонирует крону.
func _tree(parts: Array) -> ArrayMesh:
	var mesh := ArrayMesh.new()
	for part: Array in parts:
		var arr: Array = part[0].get_mesh_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i].y += part[1]
		arr[Mesh.ARRAY_VERTEX] = verts
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat := ShaderMaterial.new()
		mat.shader = load("res://scripts/tree.gdshader")
		mat.set_shader_parameter("base_color", part[2])
		mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
		_tree_mats.append(mat)
	return mesh


func _cone(botr: float, hgt: float, seg: int) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = 0.0; m.bottom_radius = botr; m.height = hgt
	m.radial_segments = seg; m.rings = 1
	return m


func _cyl(topr: float, botr: float, hgt: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = topr; m.bottom_radius = botr; m.height = hgt
	m.radial_segments = 5; m.rings = 1
	return m


func _ball(r: float, h: float) -> SphereMesh:
	var m := SphereMesh.new()
	m.radius = r; m.height = h; m.radial_segments = 8; m.rings = 5
	return m


## 5 видов: ель, сосна, лиственное, берёза, куст.
func _make_trees() -> Array[ArrayMesh]:
	var brown := Color(0.30, 0.21, 0.13)
	var birch_bark := Color(0.84, 0.84, 0.78)
	var out: Array[ArrayMesh] = []
	# ель — узкий конус
	out.append(_tree([[_cyl(0.32, 0.5, 3.0), 1.5, brown], [_cone(2.6, 13.0, 7), 9.0, Color(0.09, 0.20, 0.09)]]))
	# сосна — высокая, крона выше на голом стволе
	out.append(_tree([[_cyl(0.28, 0.42, 7.0), 3.5, brown], [_cone(2.3, 9.0, 7), 12.5, Color(0.12, 0.25, 0.12)]]))
	# лиственное — круглая крона
	out.append(_tree([[_cyl(0.5, 0.75, 4.5), 2.2, brown], [_ball(4.2, 8.0), 8.0, Color(0.17, 0.31, 0.13)]]))
	# берёза — тонкий светлый ствол, лёгкая крона
	out.append(_tree([[_cyl(0.2, 0.3, 8.0), 4.0, birch_bark], [_ball(2.6, 5.5), 9.5, Color(0.32, 0.44, 0.19)]]))
	# куст
	out.append(_tree([[_ball(1.7, 2.6), 1.1, Color(0.18, 0.30, 0.14)]]))
	return out
