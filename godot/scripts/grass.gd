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
	if photo != null:
		photo.generate_mipmaps()
		_mat.set_shader_parameter("tex", ImageTexture.create_from_image(photo))
		_mat.set_shader_parameter("tint", Color(0.98, 0.96, 0.9))   # фото уже в реальном цвете
		_mat.set_shader_parameter("alpha_cut", 0.14)
		_mat.set_shader_parameter("alpha_boost", 1.6)
	else:
		_mat.set_shader_parameter("tex", _grass_tex())
	_mat.set_shader_parameter("sat_tex", main._load_albedo())
	_mat.set_shader_parameter("world_size", main.size_m)
	_mat.set_shader_parameter("fade_start", radius * 0.55)
	_mat.set_shader_parameter("fade_end", radius)
	_mesh = ArrayMesh.new()
	_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _clump_arrays(1.4, 0.85) if photo != null else _clump_arrays(1.5, 0.62))
	_mesh.surface_set_material(0, _mat)
	_rock_mesh = SphereMesh.new(); _rock_mesh.radius = 1.0; _rock_mesh.height = 2.0
	_rock_mesh.radial_segments = 7; _rock_mesh.rings = 4
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.42, 0.40, 0.36); rmat.roughness = 0.95
	_rock_mesh.material = rmat


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
	var p: Vector3 = main.cam.global_position
	var agl: float = p.y - main.height_at(p.x, p.z)
	var show := enabled and agl < 160.0
	visible = show
	if not show:
		return
	_mat.set_shader_parameter("fade_start", radius * 0.55)
	_mat.set_shader_parameter("fade_end", radius)
	_yards = main.get_node_or_null("Yards")
	# нужные чанки: квадрат вокруг камеры с запасом (чанк по курсу готов до того, как войдёт в fade)
	var reach := radius + CH * 1.5
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
					n.visible = d <= radius + CH
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
			buf.append_array(PackedFloat32Array([
				ca, 0.0, sa, wx,
				0.0, s, 0.0, gy - 0.02,
				-sa, 0.0, ca, wz,
				0.9 + r2 * 0.25, 0.85 + r3 * 0.2, 0.75 + r1 * 0.3, 1.0,
				float(variant), 0.0, 0.0, 0.0]))
			count += 1
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
