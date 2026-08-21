extends Node3D
## Стриминг деревьев вокруг камеры по маске лесов (mask.png: 1 = лес).

const CHUNK := 512.0
var radius := 3000.0          # радиус стриминга (меняется пресетом качества)
const ATTEMPTS := 420          # попыток посадки на чанк (~сетка 25 м)
const ATTEMPTS_PER_FRAME := 300    # бюджет посадок за кадр (чанк 420–1300 попыток строится за 1–3 кадра)

var main: Node3D
var mask: Image
var mpx: int
var _mask_bytes := PackedByteArray()
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
	if mask.get_format() != Image.FORMAT_L8:
		mask.convert(Image.FORMAT_L8)
	_mask_bytes = mask.get_data()
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
	_gen_step()


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
	# тени деревьев — только вблизи (4 каскада × все чанки слишком дорого)
	for c: Vector2i in chunks:
		var h = chunks[c]
		if h == null: continue
		var center := Vector2((c.x + 0.5) * CHUNK, (c.y + 0.5) * CHUNK)
		var near := center.distance_to(Vector2(p.x, p.z)) < 1200.0
		for mmi in h.get_children():
			if mmi is GeometryInstance3D:
				mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_ON if near else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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


# --- инкрементальная генерация чанка: состояние текущей работы ---
var _cg_active := false
var _cg_c: Vector2i
var _cg_rng: RandomNumberGenerator
var _cg_i := 0
var _cg_attempts := 0
var _cg_xf: Array = []
var _cg_cl: Array = []
var _cg_tcol: Array[Dictionary] = []
const COL_R := [1.4, 1.2, 2.8, 1.6, 1.4, 1.7]
const COL_H := [14.0, 18.0, 12.0, 13.0, 3.0, 2.8]


func _gen_step() -> void:
	if not _cg_active:
		if _queue.is_empty():
			return
		# ближайший к камере чанк — первым (на скорости важно, что появляется прямо по курсу)
		var cp: Vector3 = main.cam.global_position
		var best_i := 0
		var best_d := 1e18
		for qi in _queue.size():
			var qc := _queue[qi]
			var d := Vector2((qc.x + 0.5) * CHUNK - cp.x, (qc.y + 0.5) * CHUNK - cp.z).length_squared()
			if d < best_d:
				best_d = d; best_i = qi
		_cg_c = _queue[best_i]
		_queue.remove_at(best_i)
		if chunks.has(_cg_c):
			return
		_cg_rng = RandomNumberGenerator.new()
		_cg_rng.seed = (int(_cg_c.x) * 73856093) ^ (int(_cg_c.y) * 19349663)
		_cg_i = 0
		_cg_attempts = [420, 800, 1300][clampi(int(main.quality), 0, 2)]
		_cg_xf = []; _cg_cl = []
		for k in tree_meshes.size():
			_cg_xf.append([] as Array[Transform3D]); _cg_cl.append([] as Array[Color])
		_cg_tcol = []
		_cg_active = true
	var rng := _cg_rng
	var half: float = main.size_m * 0.5
	var c := _cg_c
	var end := mini(_cg_i + ATTEMPTS_PER_FRAME, _cg_attempts)
	for i in range(_cg_i, end):
		var wx := (c.x + rng.randf()) * CHUNK
		var wz := (c.y + rng.randf()) * CHUNK
		if absf(wx) >= half or absf(wz) >= half:
			continue
		var mx := int((wx / main.size_m + 0.5) * (mpx - 1))
		var mz := int((wz / main.size_m + 0.5) * (mpx - 1))
		var mv := int(_mask_bytes[mz * mpx + mx])
		var gy: float = main.height_at(wx, wz) - 0.3
		var elev := gy
		var accept := 0.0
		var w: Array = [0.0, 0.0, 0.0, 0.0, 0.0, 0.0]
		var scale_k := 1.0
		match mv:
			1:
				if elev < 1150.0:
					accept = 1.0; w = [0.25, 0.10, 0.50, 0.15, 0.0, 0.0]
				elif elev < 1550.0:
					accept = 1.0; w = [0.72, 0.12, 0.08, 0.08, 0.0, 0.0]
				elif elev < 1750.0:
					accept = 0.55; w = [0.45, 0.0, 0.0, 0.05, 0.5, 0.0]; scale_k = 0.55
				else:
					accept = 0.15; w = [0.1, 0.0, 0.0, 0.0, 0.9, 0.0]; scale_k = 0.5
			6:
				accept = 0.45; w = [0.05, 0.0, 0.1, 0.1, 0.75, 0.0]
			5:
				accept = 0.05 if elev < 1500.0 else 0.012; w = [0.12, 0.04, 0.26, 0.14, 0.19, 0.25]
			9:
				accept = 0.2; w = [0.0, 0.0, 0.5, 0.2, 0.3, 0.0]; scale_k = 0.75
			4:
				accept = 0.004; w = [0.0, 0.0, 0.6, 0.4, 0.0, 0.0]
			_:
				accept = 0.01; w = [0.0, 0.0, 0.4, 0.2, 0.4, 0.0]
		if rng.randf() > accept:
			continue
		var ti := 0
		var rr := rng.randf(); var acc := 0.0
		for k in w.size():
			acc += w[k]
			if rr <= acc:
				ti = k; break
		var sc := rng.randf_range(0.65, 1.4) * scale_k
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc * rng.randf_range(0.85, 1.2), sc))
		_cg_xf[ti].append(Transform3D(basis, Vector3(wx, gy, wz)))
		var g := rng.randf_range(0.72, 1.18)
		_cg_cl[ti].append(Color(g * rng.randf_range(0.88, 1.0), g, g * rng.randf_range(0.75, 0.96)))
		_cg_tcol.append({"pos": Vector3(wx, gy, wz), "r": COL_R[ti] * sc * 0.6, "top": COL_H[ti] * sc})
	_cg_i = end
	if _cg_i < _cg_attempts:
		return
	_cg_active = false
	main.col_register_trees(c, _cg_tcol)
	var total := 0
	for k in _cg_xf.size():
		total += _cg_xf[k].size()
	if total == 0:
		chunks[c] = null
		return
	var holder := Node3D.new()
	add_child(holder)
	for k in tree_meshes.size():
		if _cg_xf[k].is_empty():
			continue
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = tree_meshes[k]
		mm.instance_count = _cg_xf[k].size()
		var buf := PackedFloat32Array()
		buf.resize(_cg_xf[k].size() * 16)
		for i in _cg_xf[k].size():
			var tf: Transform3D = _cg_xf[k][i]; var col: Color = _cg_cl[k][i]
			var o: int = i * 16
			buf[o] = tf.basis.x.x; buf[o + 1] = tf.basis.y.x; buf[o + 2] = tf.basis.z.x; buf[o + 3] = tf.origin.x
			buf[o + 4] = tf.basis.x.y; buf[o + 5] = tf.basis.y.y; buf[o + 6] = tf.basis.z.y; buf[o + 7] = tf.origin.y
			buf[o + 8] = tf.basis.x.z; buf[o + 9] = tf.basis.y.z; buf[o + 10] = tf.basis.z.z; buf[o + 11] = tf.origin.z
			buf[o + 12] = col.r; buf[o + 13] = col.g; buf[o + 14] = col.b; buf[o + 15] = col.a
		mm.buffer = buf
		var mmi := MultiMeshInstance3D.new()
		mmi.multimesh = mm
		holder.add_child(mmi)
	chunks[c] = holder


## Собирает дерево: ствол (примитив, tree.gdshader) + крона из кросс-карт (foliage.gdshader).
## parts: [prim, y_offset, color] для ствола; crown: {tex, w, h, y0, color, flutter}
func _tree(parts: Array, crown: Dictionary) -> ArrayMesh:
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
	if not crown.is_empty():
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
			_cards(float(crown.w), float(crown.h), float(crown.y0), 3, bool(crown.get("top", true))))
		var fm := ShaderMaterial.new()
		fm.shader = load("res://scripts/foliage.gdshader")
		fm.set_shader_parameter("tex", crown.tex)
		fm.set_shader_parameter("base_color", crown.color)
		fm.set_shader_parameter("leaf_flutter", float(crown.get("flutter", 1.0)))
		mesh.surface_set_material(mesh.get_surface_count() - 1, fm)
		_tree_mats.append(fm)
	return mesh


## Кросс-карты: n вертикальных квадов через центр (повёрнуты на 180°/n) + горизонтальная карта
## (вид сверху с дрона — крона не выглядит звездой).
func _cards(w: float, h: float, y0: float, n: int, top: bool) -> Array:
	var V := PackedVector3Array(); var N := PackedVector3Array()
	var UVs := PackedVector2Array(); var I := PackedInt32Array()
	var add_quad := func(a: Vector3, b: Vector3, c: Vector3, d: Vector3, nrm: Vector3) -> void:
		var base := V.size()
		V.append_array([a, b, c, d])
		for k in 4: N.append(nrm)
		UVs.append_array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
		I.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	for i in n:
		var a := PI * i / n
		var dx := Vector3(cos(a), 0, sin(a)) * (w * 0.5)
		var nrm := Vector3(-sin(a), 0, cos(a))
		add_quad.call(-dx + Vector3(0, y0, 0), dx + Vector3(0, y0, 0), dx + Vector3(0, y0 + h, 0), -dx + Vector3(0, y0 + h, 0), nrm)
	if top:
		var yy := y0 + h * 0.55
		var hw := w * 0.5
		add_quad.call(Vector3(-hw, yy, -hw), Vector3(hw, yy, -hw), Vector3(hw, yy, hw), Vector3(-hw, yy, hw), Vector3.UP)
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V; arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TEX_UV] = UVs; arr[Mesh.ARRAY_INDEX] = I
	return arr


## Процедурная текстура кроны 256² RGBA. Крона = набор пучков (кластеров) с просветами между ними;
## внутри пучка — мелкие «листья»/хвоинки с дырками. kind: conifer / leaf / birch / bush.
func _foliage_tex(kind: String, seed_v: int) -> ImageTexture:
	var S := 256
	var img := Image.create(S, S, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new(); rng.seed = seed_v
	# --- пучки ---
	var clusters: Array = []          # [cx, cy, rx, ry, lum]
	match kind:
		"conifer":
			# ярусы веток: 12 ярусов, пучки растут от ствола в стороны, нижние шире и гуще; макушка
			var tiers := 12
			for t in tiers:
				var cy := lerpf(0.06, 0.97, (t + 0.5) / tiers)
				var half := lerpf(0.025, 0.47, pow((cy - 0.06) / 0.91, 0.85))
				var n := 3 + t
				for k in n:
					var cx := 0.5 + (rng.randf() * 2.0 - 1.0) * half
					var rx := rng.randf_range(0.07, 0.15) * (0.45 + half)
					var ry := rng.randf_range(0.022, 0.04)
					var cyy := cy + absf(cx - 0.5) * 0.08 * rng.randf()
					clusters.append([cx, cyy, rx, ry, 0.0])
			clusters.append([0.5, 0.045, 0.035, 0.05, 0.0])   # макушка
			for t in 8:                                        # ствольный столб хвои — плотная середина
				clusters.append([0.5, lerpf(0.15, 0.95, t / 7.0), 0.06, 0.05, 0.0])
		"bush":
			for k in 14:
				var ang := rng.randf() * TAU; var rr := sqrt(rng.randf()) * 0.34
				clusters.append([0.5 + cos(ang) * rr, 0.58 + sin(ang) * rr * 0.75,
					rng.randf_range(0.11, 0.17), rng.randf_range(0.09, 0.14), 0.0])
		_:
			var n := 18 if kind == "birch" else 22
			for k in n:
				var ang := rng.randf() * TAU; var rr := pow(rng.randf(), 0.55) * 0.36
				var cx := 0.5 + cos(ang) * rr; var cy := 0.5 + sin(ang) * rr * 0.9
				var r := rng.randf_range(0.11, 0.18) * (0.75 if kind == "birch" else 1.0)
				clusters.append([cx, cy, r, r * rng.randf_range(0.7, 1.0), 0.0])
	# яркость пучка: верхние и внешние — на солнце, внутренние/нижние — в тени
	for c in clusters:
		var top := 1.0 - float(c[1])
		var outer := clampf(absf(float(c[0]) - 0.5) * 2.0 + (0.5 - float(c[1])) * 0.6, 0.0, 1.0)
		c[4] = clampf(0.45 + top * 0.45 + outer * 0.35 + rng.randf_range(-0.18, 0.18), 0.28, 1.35)
	# --- листья внутри пучков ---
	var leaf_r := 0.011 if kind == "conifer" else 0.016
	if kind == "birch": leaf_r = 0.012
	var per := 120 if kind == "conifer" else 60
	for c in clusters:
		var cx: float = c[0]; var cy: float = c[1]; var rx: float = c[2]; var ry: float = c[3]; var lum: float = c[4]
		var count := int(per * (rx * ry) / (0.14 * 0.12)) + 6
		for k in count:
			var ang := rng.randf() * TAU; var rr := sqrt(rng.randf())
			var lx := cx + cos(ang) * rr * rx; var ly := cy + sin(ang) * rr * ry
			var lr := leaf_r * rng.randf_range(0.6, 1.5)
			var lrx := lr * (2.2 if kind == "conifer" else rng.randf_range(0.8, 1.3))
			var lry := lr * (0.7 if kind == "conifer" else rng.randf_range(0.8, 1.3))
			var l := lum * rng.randf_range(0.7, 1.25) * (1.0 - rr * 0.2)
			var tint := Vector3(0.9 + rng.randf_range(-0.1, 0.1), 1.0, 0.85 + rng.randf_range(-0.12, 0.12))
			var x0 := int((lx - lrx) * S); var x1 := int((lx + lrx) * S)
			var y0 := int((ly - lry) * S); var y1 := int((ly + lry) * S)
			for py in range(maxi(y0, 0), mini(y1, S - 1) + 1):
				for px in range(maxi(x0, 0), mini(x1, S - 1) + 1):
					var dx := (px / float(S) - lx) / lrx; var dy := (py / float(S) - ly) / lry
					if dx * dx + dy * dy > 1.0: continue
					img.set_pixel(px, py, Color(l * tint.x, l * tint.y, l * tint.z, 1.0))
	img.generate_mipmaps()
	if "--foliagedump" in OS.get_cmdline_user_args():
		img.save_png(ProjectSettings.globalize_path("res://../foliage_%s.png" % kind))
	return ImageTexture.create_from_image(img)


func _cyl(topr: float, botr: float, hgt: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = topr; m.bottom_radius = botr; m.height = hgt
	m.radial_segments = 6; m.rings = 1
	return m


## 5 видов: ель, сосна, лиственное, берёза, куст. Кроны — кросс-карты с процедурной листвой.
func _make_trees() -> Array[ArrayMesh]:
	var brown := Color(0.30, 0.21, 0.13)
	var birch_bark := Color(0.84, 0.84, 0.78)
	var conif := _foliage_tex("conifer", 11)
	var leaf := _foliage_tex("leaf", 22)
	var birch := _foliage_tex("birch", 33)
	var bush := _foliage_tex("bush", 44)
	var out: Array[ArrayMesh] = []
	# ель — узкий высокий треугольник, хвоя тёмная
	out.append(_tree([[_cyl(0.30, 0.48, 3.0), 1.5, brown]],
		{"tex": conif, "w": 5.6, "h": 13.0, "y0": 1.2, "color": Color(0.16, 0.30, 0.14), "flutter": 0.4}))
	# сосна — крона выше на голом стволе
	out.append(_tree([[_cyl(0.26, 0.40, 8.0), 4.0, brown]],
		{"tex": conif, "w": 6.4, "h": 8.5, "y0": 7.5, "color": Color(0.20, 0.34, 0.16), "flutter": 0.5}))
	# лиственное — широкая круглая крона
	out.append(_tree([[_cyl(0.48, 0.72, 4.5), 2.2, brown]],
		{"tex": leaf, "w": 9.5, "h": 9.0, "y0": 3.2, "color": Color(0.30, 0.46, 0.18), "flutter": 1.0}))
	# берёза — тонкий светлый ствол, лёгкая крона
	out.append(_tree([[_cyl(0.18, 0.28, 8.0), 4.0, birch_bark]],
		{"tex": birch, "w": 6.0, "h": 7.5, "y0": 5.0, "color": Color(0.46, 0.58, 0.24), "flutter": 1.4}))
	# куст
	out.append(_tree([], {"tex": bush, "w": 3.2, "h": 2.6, "y0": 0.0, "color": Color(0.30, 0.44, 0.18), "flutter": 1.0}))
	# стог сена (цилиндр + купол), соломенный
	var straw := Color(0.62, 0.52, 0.30)
	var dome := SphereMesh.new(); dome.radius = 1.7; dome.height = 2.2; dome.radial_segments = 10; dome.rings = 5
	out.append(_tree([[_cyl(1.7, 1.5, 1.6), 0.8, straw], [dome, 1.6, straw]], {}))
	return out
