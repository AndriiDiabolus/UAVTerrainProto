extends Node3D
## Трава у земли — ЧАНКАМИ 32 м с кэшем (как лес): чанк считается один раз (~800 точек), появляется заранее
## по курсу, при возврате берётся из кэша; никаких полных пересборок вокруг камеры.
## Только вне дорог (индекс OSM-сегментов), вне воды, внутри зданий и на грядках — нет; на крутом склоне — нет.
## Видна при AGL < 160 м; вдали пучки редеют в шейдере (fade), чанки дальше radius+CH скрываются.

var main: Node3D
var enabled := true
var radius := 70.0
const SPACING := 1.15
const CH := 32.0                    # размер чанка, м
const GEN_PER_FRAME := 1            # новых чанков за кадр
const CACHE_MAX := 220              # чанков в кэше (≈ 8 МБ)
var mask: Image
var mpx: int
var _mask_bytes := PackedByteArray()   # сырые байты маски (L8) — get_pixel слишком дорог для тысяч точек
var _mesh: ArrayMesh
var _mat: ShaderMaterial
var _mat_det: ShaderMaterial            # материал детального LOD (атлас элементов)
var _mesh_det_f: Array = []             # детальные меши: цветочная куртина (вариации)
var _mesh_det_c: Array = []             # детальные меши: злаковый ковёр (вариации)
var _mesh_det_d: Array = []             # детальные меши: сухостой (вариации)
var _fnoise := FastNoiseLite.new()      # пятна цветения (~15 м куртины)
var _mesh3d_f: ArrayMesh                # 3D-«герои» (Meshy GLB): цветущий/зелёный/сухой пучок
var _mesh3d_c: ArrayMesh
var _mesh3d_d: ArrayMesh
var _mats3d: Array = []                 # их материалы (ветер обновляется в _process)
const HERO_P := 0.11                    # доля 3D-пучков среди детальных точек
const DETAIL_R := 34.0                  # радиус детального LOD, м
var _rock_mesh: SphereMesh
var _chunks := {}                   # Vector2i -> Node3D (или null, если пусто)
var _touch := {}                    # Vector2i -> last-use tick (для LRU)
var _tick := 0
var _yards: Node = null
var _cur_dir := Vector2(1, 0)
var _cur_str := 0.2


func setup(m: Node3D) -> void:
	main = m
	mask = main.load_image(main.asset_path("mask.png"))
	if mask != null:
		mpx = mask.get_width()
		if mask.get_format() != Image.FORMAT_L8:
			mask.convert(Image.FORMAT_L8)
		_mask_bytes = mask.get_data()
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://scripts/grass.gdshader")
	# фото-атлас (magenta-key, tools/make_grass_atlas) — основной путь; процедурный — фоллбек
	var photo: Image = main.load_image("res://assets/tex/grass_atlas.png")
	var photo_top: Image = main.load_image("res://assets/tex/grass_atlas_top.png")
	var top_tex: ImageTexture = null
	if photo_top != null:
		photo_top.generate_mipmaps()
		top_tex = ImageTexture.create_from_image(photo_top)
	if photo != null:
		photo.generate_mipmaps()
		_mat.set_shader_parameter("tex", ImageTexture.create_from_image(photo))
		_mat.set_shader_parameter("tint", Color(0.98, 0.96, 0.9))   # фото уже в реальном цвете
		_mat.set_shader_parameter("alpha_cut", 0.14)
		_mat.set_shader_parameter("alpha_boost", 1.6)
		if top_tex != null:
			_mat.set_shader_parameter("tex_top", top_tex)
	else:
		_mat.set_shader_parameter("tex", _grass_tex())
	_mat.set_shader_parameter("sat_tex", main._load_albedo())
	if photo != null:
		radius = 106.0                             # фото-пучки с шапкой видны дальше — луг не «обрывается» с воздуха
	_mat.set_shader_parameter("world_size", main.size_m)
	_mat.set_shader_parameter("fade_start", radius * 0.7)
	_mat.set_shader_parameter("fade_end", radius)
	_mesh = ArrayMesh.new()
	var arrs: Array
	if photo != null and photo_top != null:
		arrs = _clump_arrays_vol(1.4, 0.85)      # объём: 3 плоскости + top-шапка
	elif photo != null:
		arrs = _clump_arrays(1.4, 0.85)
	else:
		arrs = _clump_arrays(1.5, 0.62)
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrs)
	# детальный LOD: атлас отдельных элементов (стебель/лист/цветок на ячейку 4×2)
	var elems: Image = main.load_image("res://assets/tex/grass_elements.png")
	if elems != null:
		elems.generate_mipmaps()
		_mat_det = ShaderMaterial.new()
		_mat_det.shader = _mat.shader
		_mat_det.set_shader_parameter("tex", ImageTexture.create_from_image(elems))
		_mat_det.set_shader_parameter("sat_tex", main._load_albedo())
		_mat_det.set_shader_parameter("world_size", main.size_m)
		_mat_det.set_shader_parameter("tint", Color(0.98, 0.96, 0.9))
		_mat_det.set_shader_parameter("alpha_cut", 0.30)
		_mat_det.set_shader_parameter("alpha_boost", 1.3)
		_mat_det.set_shader_parameter("detail_mode", 1.0)
		if top_tex != null:
			_mat_det.set_shader_parameter("tex_top", top_tex)
		_mat_det.set_shader_parameter("fade_start", DETAIL_R * 0.8)
		_mat_det.set_shader_parameter("fade_end", DETAIL_R + CH * 0.5)
		_fnoise.seed = 4217
		_fnoise.frequency = 0.045            # куртины цветения ~15–25 м
		_fnoise.noise_type = FastNoiseLite.TYPE_VALUE_CUBIC
		# композиции пучков (реализм: даже в цветочной куртине основа — злаки)
		for sv in 2:
			var mf := ArrayMesh.new()        # цветочная куртина: цветы/листья + злаковая основа
			mf.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
				_clump_arrays_detail([0, 1, 2, 3, 4, 5, 6, 7, 8, 10, 12, 15], 100 + sv))
			mf.surface_set_material(0, _mat_det)
			_mesh_det_f.append(mf)
			var mc := ArrayMesh.new()        # злаковый ковёр: травинки/метёлки + редкий цветок
			mc.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
				_clump_arrays_detail([8, 9, 10, 11, 12, 13, 14, 15, 8, 10, 13, 1], 300 + sv))
			mc.surface_set_material(0, _mat_det)
			_mesh_det_c.append(mc)
			var md := ArrayMesh.new()        # сухостой + пара живых травинок
			md.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES,
				_clump_arrays_detail([16, 17, 18, 19, 20, 21, 22, 23, 8], 200 + sv))
			md.surface_set_material(0, _mat_det)
			_mesh_det_d.append(md)
	_mesh.surface_set_material(0, _mat)
	# 3D-«герои» (Meshy): объёмные мешевые пучки, ~каждый десятый в детальной зоне
	_mesh3d_f = _glb_clump("res://assets/models/grass_flower.glb", 0.62)
	_mesh3d_c = _glb_clump("res://assets/models/grass_green.glb", 0.55)
	_mesh3d_d = _glb_clump("res://assets/models/grass_dry.glb", 0.55)
	_rock_mesh = SphereMesh.new(); _rock_mesh.radius = 1.0; _rock_mesh.height = 2.0
	_rock_mesh.radial_segments = 7; _rock_mesh.rings = 4
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.42, 0.40, 0.36); rmat.roughness = 0.95
	_rock_mesh.material = rmat


## 3D-пучок из Meshy GLB → ArrayMesh для MultiMesh: все сабмеши запекаются в один меш
## (масштаб к max_dim, низ на y=0, центр в 0), поверх — grass3d-шейдер с ветром и текстурой GLB.
func _glb_clump(path: String, max_dim: float) -> ArrayMesh:
	if not ResourceLoader.exists(path):
		return null
	var ps: PackedScene = load(path)
	if ps == null:
		return null
	var inst: Node = ps.instantiate()
	var mis: Array = []                      # [MeshInstance3D, global_xf]
	var stack: Array = [[inst, Transform3D()]]
	while not stack.is_empty():
		var it: Array = stack.pop_back()
		var n: Node = it[0]
		var xf: Transform3D = it[1]
		if n is Node3D:
			xf = xf * (n as Node3D).transform
		if n is MeshInstance3D and (n as MeshInstance3D).mesh != null:
			mis.append([n, xf])
		for ch in n.get_children():
			stack.append([ch, xf])
	if mis.is_empty():
		inst.free()
		return null
	# общий AABB в корневых координатах
	var aabb := AABB()
	var first := true
	for it: Array in mis:
		var a: AABB = (it[1] as Transform3D) * ((it[0] as MeshInstance3D).mesh.get_aabb())
		aabb = a if first else aabb.merge(a)
		first = false
	var s := max_dim / maxf(aabb.size.x, maxf(aabb.size.y, aabb.size.z))
	var c := aabb.get_center()
	var norm := Transform3D(Basis.from_scale(Vector3.ONE * s),
		Vector3(-c.x * s, -aabb.position.y * s, -c.z * s))
	# текстура из первого материала GLB
	var tex: Texture2D = null
	var m0: Mesh = (mis[0][0] as MeshInstance3D).mesh
	var bm := m0.surface_get_material(0)
	if bm is BaseMaterial3D:
		tex = (bm as BaseMaterial3D).albedo_texture
	var smat := ShaderMaterial.new()
	smat.shader = load("res://scripts/grass3d.gdshader")
	if tex != null:
		smat.set_shader_parameter("alb", tex)
	smat.set_shader_parameter("sat_tex", main._load_albedo())
	smat.set_shader_parameter("world_size", main.size_m)
	smat.set_shader_parameter("clump_h", max_dim * 0.9)
	_mats3d.append(smat)
	var out := ArrayMesh.new()
	for it: Array in mis:
		var mi := it[0] as MeshInstance3D
		var xf := norm * (it[1] as Transform3D)
		for si in mi.mesh.get_surface_count():
			var arr: Array = mi.mesh.surface_get_arrays(si)
			var V: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			for i in V.size():
				V[i] = xf * V[i]
			arr[Mesh.ARRAY_VERTEX] = V
			var NN = arr[Mesh.ARRAY_NORMAL]
			if NN != null:
				var N2: PackedVector3Array = NN
				for i in N2.size():
					N2[i] = (xf.basis * N2[i]).normalized()
				arr[Mesh.ARRAY_NORMAL] = N2
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
			out.surface_set_material(out.get_surface_count() - 1, smat)
	inst.free()
	return out


## Объёмный пучок для фото-атласа: 3 плоскости под 60° + горизонтальная «шапка» на 60 % высоты.
## Шапка размечена UV.y в [2..3] — шейдер сэмплит её из атласа вида СВЕРХУ (tex_top).
func _clump_arrays_vol(w: float, h: float) -> Array:
	var V := PackedVector3Array(); var N := PackedVector3Array()
	var UVs := PackedVector2Array(); var I := PackedInt32Array()
	for i in 3:
		var a := PI / 3.0 * i + 0.4
		var dx := Vector3(cos(a), 0, sin(a)) * (w * 0.5)
		var base := V.size()
		V.append_array([-dx, dx, dx + Vector3(0, h, 0), -dx + Vector3(0, h, 0)])
		for k in 4: N.append(Vector3.UP)
		UVs.append_array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
		I.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var base2 := V.size()
	var r := w * 0.52
	var hy := h * 0.6
	V.append_array([Vector3(-r, hy, -r), Vector3(r, hy, -r), Vector3(r, hy, r), Vector3(-r, hy, r)])
	for k in 4: N.append(Vector3.UP)
	UVs.append_array([Vector2(0, 3), Vector2(1, 3), Vector2(1, 2), Vector2(0, 2)])
	I.append_array([base2, base2 + 1, base2 + 2, base2, base2 + 2, base2 + 3])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V; arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TEX_UV] = UVs; arr[Mesh.ARRAY_INDEX] = I
	return arr


## ДЕТАЛЬНЫЙ пучок (LOD-0, вблизи): 14–16 карточек-элементов из атласа 4×2 (каждая — ОДИН
## стебель/лист/цветок), розеткой со случайным наклоном; карточка вертикально разбита на
## 3 ряда (гнётся дугой). UV2 = (фаза ветра, амплитуда) — каждый элемент шевелится сам по себе.
## cells — какие ячейки атласа сеять (зелёный луг или сухостой), seed — вариация композиции.
func _clump_arrays_detail(cells: Array, seed_v: int) -> Array:
	var V := PackedVector3Array(); var N := PackedVector3Array()
	var UVs := PackedVector2Array(); var UV2s := PackedVector2Array(); var I := PackedInt32Array()
	var rng := RandomNumberGenerator.new(); rng.seed = seed_v
	var n_cards := 15
	for c in n_cards:
		var cell: int = cells[rng.randi() % cells.size()]     # атлас 4×6: 0..7 цветы, 8..15 злаки, 16..23 сухостой
		var cu := float(cell % 4) * 0.25; var cv := float(cell / 4) / 6.0
		var yaw := rng.randf() * TAU
		var rad := rng.randf_range(0.02, 0.34)                    # смещение от центра розетки
		var tilt := rng.randf_range(0.06, 0.42) + rad * 0.5       # наружу сильнее с краю
		var w := rng.randf_range(0.13, 0.22)                      # ширина карточки элемента
		var h := rng.randf_range(0.30, 0.60)                      # растение заполняет ячейку целиком
		var ph := rng.randf()                                     # фаза ветра элемента
		var amp := rng.randf_range(0.6, 1.3)                      # амплитуда элемента
		var fwd := Vector3(cos(yaw), 0, sin(yaw))
		var side := Vector3(-sin(yaw), 0, cos(yaw)) * (w * 0.5)
		var base_p := fwd * rad
		var lean := fwd * tilt                                    # наклон наружу (на высоту)
		var base := V.size()
		for row in 3:                                             # 3 ряда вершин: низ/середина/верх
			var t := row / 2.0
			var bow := lean * (t * t) + Vector3(0, h * t, 0)      # дуга: изгиб растёт к верхушке
			V.append(base_p - side + bow); V.append(base_p + side + bow)
			N.append(Vector3.UP); N.append(Vector3.UP)
			var vy := cv + (1.0 - t) / 6.0
			UVs.append(Vector2(cu, vy)); UVs.append(Vector2(cu + 0.25, vy))
			UV2s.append(Vector2(ph, amp * t)); UV2s.append(Vector2(ph, amp * t))
		for row in 2:
			var b := base + row * 2
			I.append_array([b, b + 1, b + 3, b, b + 3, b + 2])
	# top-«шапка» (иначе злаковые пучки с воздуха невидимы): UV.y+2 → tex_top, ячейка по INSTANCE_CUSTOM
	var bc := V.size()
	var cr := 0.52
	var chy := 0.30
	V.append_array([Vector3(-cr, chy, -cr), Vector3(cr, chy, -cr), Vector3(cr, chy, cr), Vector3(-cr, chy, cr)])
	for k in 4: N.append(Vector3.UP)
	UVs.append_array([Vector2(0, 3), Vector2(1, 3), Vector2(1, 2), Vector2(0, 2)])
	var cph := rng.randf()
	for k in 4: UV2s.append(Vector2(cph, 0.45))
	I.append_array([bc, bc + 1, bc + 2, bc, bc + 2, bc + 3])

	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V; arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TEX_UV] = UVs; arr[Mesh.ARRAY_TEX_UV2] = UV2s; arr[Mesh.ARRAY_INDEX] = I
	return arr


## Два скрещённых квада, низ на y=0.
func _clump_arrays(w: float, h: float) -> Array:
	var V := PackedVector3Array(); var N := PackedVector3Array()
	var UVs := PackedVector2Array(); var I := PackedInt32Array()
	for i in 2:
		var a := PI * 0.5 * i + 0.4
		var dx := Vector3(cos(a), 0, sin(a)) * (w * 0.5)
		var base := V.size()
		V.append_array([-dx, dx, dx + Vector3(0, h, 0), -dx + Vector3(0, h, 0)])
		for k in 4: N.append(Vector3.UP)
		UVs.append_array([Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0)])
		I.append_array([base, base + 1, base + 2, base, base + 2, base + 3])
	var arr := []; arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V; arr[Mesh.ARRAY_NORMAL] = N
	arr[Mesh.ARRAY_TEX_UV] = UVs; arr[Mesh.ARRAY_INDEX] = I
	return arr


## Атлас 2×2 пучков (256²): 0 узкие злаки, 1 широкий пучок, 2 сухостой (солома), 3 цветущий (метёлки/цветки).
## Фон заливается цветом травы с альфой 0 — иначе альфа-вырезка даёт тёмную обводку.
func _grass_tex() -> ImageTexture:
	var S := 256
	var img := Image.create(S, S, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.42, 0.48, 0.22, 0.0))
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for v in 4:
		var ox := (v % 2) * 128; var oy := (v / 2) * 128
		var nb: int = [34, 18, 26, 28][v]
		for b in nb:
			var x0 := rng.randf_range(0.25, 0.75)
			var top := rng.randf_range(0.04, 0.35)
			var bend := rng.randf_range(-0.3, 0.3)
			var wid: float = [0.028, 0.06, 0.024, 0.03][v] * rng.randf_range(0.8, 1.3)
			var lum := rng.randf_range(0.7, 1.15)
			var col_base: Vector3 = [Vector3(0.86, 0.9, 0.5), Vector3(0.8, 0.9, 0.55), Vector3(1.1, 0.95, 0.55), Vector3(0.85, 0.9, 0.5)][v]
			var steps := 70
			for k in steps:
				var t := k / float(steps - 1)
				var y := lerpf(1.0, top, t)
				var x := x0 + bend * t * t
				var w := wid * (1.0 - t * 0.85)
				var l := lum * (0.55 + 0.6 * t)
				var px0 := int((x - w) * 128); var px1 := int((x + w) * 128)
				var py := int(y * 127)
				for px in range(maxi(px0, 0), mini(px1, 127) + 1):
					img.set_pixel(ox + px, oy + py, Color(l * col_base.x, l * col_base.y, l * col_base.z, 1.0))
			if v == 3 and rng.randf() < 0.6:      # цветок/метёлка на кончике
				var fx := int((x0 + bend) * 128); var fy := int(top * 127)
				var fc := Color(0.95, 0.9, 0.7) if rng.randf() < 0.5 else Color(0.95, 0.85, 0.3)
				for dy in range(-2, 3):
					for dx in range(-2, 3):
						if dx * dx + dy * dy <= 4:
							img.set_pixel(clampi(ox + fx + dx, ox, ox + 127), clampi(oy + fy + dy, oy, oy + 127), fc)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _process(dt: float) -> void:
	if main == null or main.cam == null or _mesh == null:
		return
	_tick += 1
	if main.get("weather") != null:
		var w: Vector3 = main.weather.wind_vec()
		var wl := w.length()
		_cur_str = lerpf(_cur_str, clampf(wl / 6.0, 0.15, 2.5), clampf(dt * 1.5, 0.0, 1.0))
		if wl > 0.01:
			_cur_dir = _cur_dir.lerp(Vector2(w.x, w.z).normalized(), clampf(dt * 1.2, 0.0, 1.0)).normalized()
		_mat.set_shader_parameter("wind_dir", _cur_dir)
		_mat.set_shader_parameter("wind_strength", _cur_str)
		if _mat_det != null:
			_mat_det.set_shader_parameter("wind_dir", _cur_dir)
			_mat_det.set_shader_parameter("wind_strength", _cur_str)
		for m3: ShaderMaterial in _mats3d:
			m3.set_shader_parameter("wind_dir", _cur_dir)
			m3.set_shader_parameter("wind_strength", _cur_str)
	var p: Vector3 = main.cam.global_position
	var agl: float = p.y - main.height_at(p.x, p.z)
	var show := enabled and agl < 160.0
	visible = show
	if not show:
		return
	# ночью траву не видно дальше пары десятков метров — радиусы меньше, FPS целее
	var r_eff := radius
	var det_r := DETAIL_R
	if main.get("weather") != null and int(main.weather.idx) == 4:
		r_eff = radius * 0.55
		det_r = DETAIL_R * 0.55
	_mat.set_shader_parameter("fade_start", r_eff * 0.7)
	_mat.set_shader_parameter("fade_end", r_eff)
	_yards = main.get_node_or_null("Yards")
	# нужные чанки: квадрат вокруг камеры с запасом (чанк по курсу готов до того, как войдёт в fade)
	var reach := r_eff + CH * 1.5
	var c0 := Vector2i(int(floor((p.x - reach) / CH)), int(floor((p.z - reach) / CH)))
	var c1 := Vector2i(int(floor((p.x + reach) / CH)), int(floor((p.z + reach) / CH)))
	var missing: Array = []
	for cz in range(c0.y, c1.y + 1):
		for cx in range(c0.x, c1.x + 1):
			var c := Vector2i(cx, cz)
			var center := Vector2((cx + 0.5) * CH, (cz + 0.5) * CH)
			var d := center.distance_to(Vector2(p.x, p.z))
			if d > reach:
				continue
			if _chunks.has(c):
				_touch[c] = _tick
				var n = _chunks[c]
				if n != null:
					n.visible = d <= r_eff + CH
					# LOD: близкие чанки — детальные пучки из независимых элементов, дальние — дешёвые
					if n.visible and n.has_meta("mi_d"):
						var near := d < det_r + CH * 0.5
						(n.get_meta("mi_s") as Node3D).visible = not near
						for dn: Node3D in n.get_meta("mi_d"):
							dn.visible = near
			else:
				missing.append([d, c])
	# генерируем ближайшие недостающие (по 2 за кадр)
	if not missing.is_empty():
		missing.sort_custom(func(a, b): return a[0] < b[0])
		for k in mini(GEN_PER_FRAME, missing.size()):
			_gen_chunk(missing[k][1])
	# скрыть чанки вне зоны; LRU-вытеснение из кэша
	if _chunks.size() > CACHE_MAX:
		var keys := _chunks.keys()
		keys.sort_custom(func(a, b): return int(_touch.get(a, 0)) < int(_touch.get(b, 0)))
		for i in (_chunks.size() - CACHE_MAX):
			var k: Vector2i = keys[i]
			if _chunks[k] != null: _chunks[k].queue_free()
			_chunks.erase(k); _touch.erase(k)


func _gen_chunk(c: Vector2i) -> void:
	var half: float = main.size_m * 0.5
	var buf := PackedFloat32Array()
	var buf_f := PackedFloat32Array()   # детальный LOD: цветочные куртины (transform+color)
	var buf_c := PackedFloat32Array()   # детальный LOD: злаковый ковёр
	var buf_d := PackedFloat32Array()   # детальный LOD: сухостой
	var buf3_f := PackedFloat32Array()  # 3D-«герои» (Meshy-меши, transform-only)
	var buf3_c := PackedFloat32Array()
	var buf3_d := PackedFloat32Array()
	var count := 0
	var rocks: Array[Transform3D] = []
	var n := int(CH / SPACING) + 1
	var ox := c.x * CH; var oz := c.y * CH
	# сегменты дорог, касающиеся чанка (+8 м), — один раз на чанк, а не 9 ячеек на каждую точку
	var segs: Array = []
	var seen := {}
	for cx in range(int(floor((ox - 8.0) / 32.0)), int(floor((ox + CH + 8.0) / 32.0)) + 1):
		for cz in range(int(floor((oz - 8.0) / 32.0)), int(floor((oz + CH + 8.0) / 32.0)) + 1):
			for sg in main.road_index.get(Vector2i(cx, cz), []):
				if not seen.has(sg):
					seen[sg] = true; segs.append(sg)
	# грядки усадеб, пересекающие чанк, — один раз на чанк
	var gards: Array = []
	if _yards != null:
		var yc := Vector2i(int(floor(ox / 512.0)), int(floor(oz / 512.0)))
		for dx in [-1, 0, 1]:
			for dz in [-1, 0, 1]:
				for g: Array in _yards.gardens.get(yc + Vector2i(dx, dz), []):
					var rr := maxf(float(g[3]), float(g[4])) + CH
					if absf(float(g[0]) - (ox + CH * 0.5)) < rr and absf(float(g[1]) - (oz + CH * 0.5)) < rr:
						gards.append(g)
	# склон — раз на чанк (ячейка меша 51 м больше чанка)
	var e := 6.0
	var mxz := ox + CH * 0.5; var mzz := oz + CH * 0.5
	var steep := absf(main.height_at(mxz + e, mzz) - main.height_at(mxz - e, mzz)) + absf(main.height_at(mxz, mzz + e) - main.height_at(mxz, mzz - e)) > 8.0
	if steep:
		_touch[c] = _tick; _chunks[c] = null
		return
	for i in n:
		for j in n:
			var gx := ox + i * SPACING; var gz := oz + j * SPACING
			if gx >= ox + CH or gz >= oz + CH:
				continue
			var hsh := int(gx * 3.7) * 73856093 ^ int(gz * 3.7) * 19349663
			var r1 := float((hsh & 1023)) / 1023.0
			var r2 := float(((hsh >> 10) & 1023)) / 1023.0
			var r3 := float(((hsh >> 20) & 1023)) / 1023.0
			var wx := gx + (r1 - 0.5) * SPACING; var wz := gz + (r2 - 0.5) * SPACING
			if absf(wx) >= half or absf(wz) >= half:
				continue
			var mv := 5
			if mpx > 0:
				var mx := int((wx / main.size_m + 0.5) * (mpx - 1))
				var mz := int((wz / main.size_m + 0.5) * (mpx - 1))
				mv = _mask_bytes[mz * mpx + mx]
				if mv == 2 or mv == 7:
					continue
			var variant := 0
			var keep := 1.0
			match mv:
				5: variant = [0, 0, 1, 3, 0, 1][int(r3 * 5.99)] as int
				4: variant = 2; keep = 0.35
				1: variant = [0, 1][int(r3 * 1.99)]; keep = 0.25
				6: variant = [2, 2, 0][int(r3 * 2.99)]; keep = 0.7
				9: variant = [0, 1, 1][int(r3 * 2.99)]
				3: variant = [0, 1, 3][int(r3 * 2.99)]; keep = 0.7
				_: variant = [0, 2][int(r3 * 1.99)]; keep = 0.6
			if r2 > keep:
				continue
			var on_road := false
			if not segs.is_empty():
				var pp := Vector2(wx, wz)
				for sg: Array in segs:
					var a := Vector2(sg[0], sg[1]); var ab := Vector2(sg[2], sg[3]) - a
					var tt := clampf((pp - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
					if pp.distance_squared_to(a + ab * tt) < (float(sg[4]) + 1.0) * (float(sg[4]) + 1.0):
						on_road = true; break
			if on_road:
				continue
			var gy: float = main.height_at(wx, wz)
			if mv == 3:
				if main.collision.in_building(wx, wz, 0.8):
					continue
				var ing := false
				for g: Array in gards:
					var lx := wx - float(g[0]); var lz := wz - float(g[1])
					var ca2 := cos(float(g[2])); var sa2 := sin(float(g[2]))
					if absf(lx * ca2 - lz * sa2) < float(g[3]) and absf(lx * sa2 + lz * ca2) < float(g[4]):
						ing = true; break
				if ing:
					continue
			var s := 0.75 + r3 * 0.6
			var ca := cos(r1 * TAU) * s; var sa := sin(r1 * TAU) * s
			# зональность луга: злаковая основа, цветочные куртины ~15–25 м, кромка — смешение;
			# вариант дальнего LOD согласуется с зоной (в куртине — «цветущий» пучок)
			var zone := 0
			if variant != 2:
				var fn := _fnoise.get_noise_2d(wx, wz)
				if fn > 0.34:
					zone = 2
					variant = 3
				elif fn > 0.16:
					zone = 1
				elif variant == 3:
					variant = 0
			buf.append_array(PackedFloat32Array([
				ca, 0.0, sa, wx,
				0.0, s, 0.0, gy - 0.02,
				-sa, 0.0, ca, wz,
				0.9 + r2 * 0.25, 0.85 + r3 * 0.2, 0.75 + r1 * 0.3, 1.0,
				float(variant), 0.0, 0.0, 0.0]))
			count += 1
			if _mat_det != null:
				# ~каждый десятый детальный пучок — объёмный 3D-«герой» из Meshy-меша
				if _mesh3d_c != null and fmod(r3 * 9.71, 1.0) < HERO_P:
					var h := PackedFloat32Array([
						ca, 0.0, sa, wx,
						0.0, s, 0.0, gy - 0.02,
						-sa, 0.0, ca, wz])
					if variant == 2:
						buf3_d.append_array(h)
					elif zone == 2 or (zone == 1 and r1 < 0.5):
						buf3_f.append_array(h)
					else:
						buf3_c.append_array(h)
				else:
					var det := PackedFloat32Array([
						ca, 0.0, sa, wx,
						0.0, s, 0.0, gy - 0.02,
						-sa, 0.0, ca, wz,
						0.9 + r2 * 0.25, 0.85 + r3 * 0.2, 0.75 + r1 * 0.3, 1.0,
						0.0, 0.0, 0.0, 0.0])
					if variant == 2:
						det[16] = 2.0            # ячейка top-атласа: сухостой
						buf_d.append_array(det)
					elif zone == 2 or (zone == 1 and r1 < 0.5):
						det[16] = 3.0            # цветущий верх
						buf_f.append_array(det)
					else:
						det[16] = 0.0            # злаковый верх
						buf_c.append_array(det)
			var rock_p := 0.012 if mv == 5 else (0.05 if mv == 8 else 0.004)
			if r1 * 0.37 + r2 * 0.63 < rock_p:
				var rs := 0.12 + r3 * 0.35
				rocks.append(Transform3D(Basis(Vector3.UP, r2 * TAU).scaled(Vector3(rs * 1.4, rs * 0.7, rs)), Vector3(wx + 0.6, gy - rs * 0.25, wz - 0.4)))
	_touch[c] = _tick
	if count == 0 and rocks.is_empty():
		_chunks[c] = null
		return
	var holder := Node3D.new()
	if count > 0:
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.use_custom_data = true
		mm.mesh = _mesh
		mm.instance_count = count
		mm.buffer = buf
		var mi := MultiMeshInstance3D.new()
		mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
		holder.set_meta("mi_s", mi)
		# детальный LOD (вблизи): те же точки, но пучки из независимых элементов
		if _mat_det != null:
			var mvar := (absi(c.x) * 31 + absi(c.y) * 17) % _mesh_det_c.size()
			var dets: Array = []
			for pair: Array in [[buf_f, _mesh_det_f[mvar]], [buf_c, _mesh_det_c[mvar]], [buf_d, _mesh_det_d[mvar]]]:
				var b: PackedFloat32Array = pair[0]
				if b.is_empty():
					continue
				var dm := MultiMesh.new()
				dm.transform_format = MultiMesh.TRANSFORM_3D
				dm.use_colors = true
				dm.use_custom_data = true      # custom.x — ячейка top-атласа для шапки
				dm.mesh = pair[1]
				dm.instance_count = b.size() / 20
				dm.buffer = b
				var dmi := MultiMeshInstance3D.new()
				dmi.multimesh = dm
				dmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				dmi.visible = false
				holder.add_child(dmi)
				dets.append(dmi)
			# 3D-«герои»: транформ-only мультимеши на Meshy-мешах
			for pair: Array in [[buf3_f, _mesh3d_f], [buf3_c, _mesh3d_c], [buf3_d, _mesh3d_d]]:
				var b3: PackedFloat32Array = pair[0]
				if b3.is_empty() or pair[1] == null:
					continue
				var hm := MultiMesh.new()
				hm.transform_format = MultiMesh.TRANSFORM_3D
				hm.mesh = pair[1]
				hm.instance_count = b3.size() / 12
				hm.buffer = b3
				var hmi := MultiMeshInstance3D.new()
				hmi.multimesh = hm
				hmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
				hmi.visible = false
				holder.add_child(hmi)
				dets.append(hmi)
			holder.set_meta("mi_d", dets)
	if not rocks.is_empty():
		var rm := MultiMesh.new()
		rm.transform_format = MultiMesh.TRANSFORM_3D
		rm.mesh = _rock_mesh
		rm.instance_count = rocks.size()
		for i in rocks.size(): rm.set_instance_transform(i, rocks[i])
		var rmi := MultiMeshInstance3D.new(); rmi.multimesh = rm
		holder.add_child(rmi)
	add_child(holder)
	_chunks[c] = holder
