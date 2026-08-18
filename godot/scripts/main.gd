extends Node3D
## Прототип: полёт над реальным рельефом (Карпаты, Говерла).
## Данные: AWS Terrain Tiles (высоты) + Sentinel-2 L2A COG, открытая лицензия (подложка).

const MESH_RES := 1024         # вершин по стороне
const RAW_PATH := "res://assets/height.raw"
const META_PATH := "res://assets/meta.json"
const ALBEDO_PATH := "res://assets/albedo.jpg"

var meta: Dictionary
var height_bytes: PackedByteArray
var px: int                    # пикселей heightmap по стороне
var size_m: float              # размер мира в метрах
var e_min: float
var e_max: float

@onready var cam: Camera3D


func _ready() -> void:
	# фиксированный сид — расстановка/движение целей повторяются от запуска к запуску
	# (нужно тренажёру для разбора «того же полёта»). Меняется флагом --seed=N.
	var sv := 1
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--seed="):
			sv = int(a.substr(7))
	seed(hash(sv))
	_load_quality()
	_load_data()
	_build_environment()
	_build_terrain()
	_build_water()
	_build_roads()
	_build_props()
	_build_buildings()
	_spawn_camera()
	_build_weather()
	_build_forest()
	_build_smoke()
	_build_targets()
	_build_sound()
	_build_hud()
	_build_mission()
	_build_telemetry()
	apply_quality(quality)
	if "--coltest" in OS.get_cmdline_user_args():
		_col_test()
	if "--missiontest" in OS.get_cmdline_user_args():
		var ok: bool = mission.self_test()
		get_tree().quit(0 if ok else 1)
	if "--flytest" in OS.get_cmdline_user_args():
		var ok: bool = cam.self_test()
		get_tree().quit(0 if ok else 1)
	if "--targetreport" in OS.get_cmdline_user_args():
		_debug_report_targets()
	if "--screenshot" in OS.get_cmdline_user_args():
		_schedule_screenshot()


func _load_data() -> void:
	meta = JSON.parse_string(FileAccess.get_file_as_string(META_PATH))
	height_bytes = FileAccess.get_file_as_bytes(RAW_PATH)
	px = int(meta["px"])
	size_m = float(meta["size_m"])
	e_min = float(meta["elev_min_m"])
	e_max = float(meta["elev_max_m"])


## Высота узла ТЕРРЕЙН-МЕША (ix,iz) — та же выборка, что при построении меша
## (ближайший пиксель на грубой сетке MESH_RES), чтобы объекты садились ровно
## на видимую поверхность, а не на детальную карту 4096².
func _node_h(ix: int, iz: int) -> float:
	var n := MESH_RES
	ix = clampi(ix, 0, n - 1)
	iz = clampi(iz, 0, n - 1)
	var pxx := (ix * (px - 1)) / (n - 1)
	var py := (iz * (px - 1)) / (n - 1)
	var v := height_bytes.decode_u16(2 * (py * px + pxx))
	return e_min + (e_max - e_min) * v / 65535.0


## Высота рельефа в мировой точке (x, z) = точная поверхность террейн-меша
## (билинейно между узлами сетки MESH_RES). Центр мира = центр карты.
func height_at(x: float, z: float) -> float:
	var n := MESH_RES
	var gx := clampf((x / size_m + 0.5) * (n - 1), 0.0, float(n - 1))
	var gz := clampf((z / size_m + 0.5) * (n - 1), 0.0, float(n - 1))
	var x0 := int(gx); var z0 := int(gz)
	var tx := gx - x0; var tz := gz - z0
	var h00 := _node_h(x0, z0); var h10 := _node_h(x0 + 1, z0)
	var h01 := _node_h(x0, z0 + 1); var h11 := _node_h(x0 + 1, z0 + 1)
	return lerpf(lerpf(h00, h10, tx), lerpf(h01, h11, tx), tz)


func _build_terrain() -> void:
	var t0 := Time.get_ticks_msec()
	var n := MESH_RES
	var cache_path := "user://terrain_%d_%d_%d.res" % [px, n, FileAccess.get_modified_time(ProjectSettings.globalize_path(RAW_PATH))]
	var mesh: ArrayMesh

	if FileAccess.file_exists(cache_path):
		mesh = load(cache_path)
		print("Terrain mesh из кеша (%s)" % cache_path)
	else:
		# высоты в узлах сетки — прямой decode ближайшего пикселя (сетка ~кратна карте высот)
		var hs := PackedFloat32Array(); hs.resize(n * n)
		var espan := e_max - e_min
		for iy in n:
			var py := (iy * (px - 1)) / (n - 1)
			var row := py * px
			for ix in n:
				var pxx := (ix * (px - 1)) / (n - 1)
				hs[iy * n + ix] = e_min + espan * height_bytes.decode_u16(2 * (row + pxx)) / 65535.0

		var verts := PackedVector3Array(); verts.resize(n * n)
		var norms := PackedVector3Array(); norms.resize(n * n)
		var uvs := PackedVector2Array(); uvs.resize(n * n)
		var step := size_m / (n - 1)
		for iy in n:
			var wz := (float(iy) / (n - 1) - 0.5) * size_m
			for ix in n:
				var i := iy * n + ix
				verts[i] = Vector3((float(ix) / (n - 1) - 0.5) * size_m, hs[i], wz)
				uvs[i] = Vector2(float(ix) / (n - 1), float(iy) / (n - 1))
				var hl := hs[i - 1] if ix > 0 else hs[i]
				var hr := hs[i + 1] if ix < n - 1 else hs[i]
				var hu := hs[i - n] if iy > 0 else hs[i]
				var hd := hs[i + n] if iy < n - 1 else hs[i]
				norms[i] = Vector3(hl - hr, 2.0 * step, hu - hd).normalized()

		var idx := PackedInt32Array(); idx.resize((n - 1) * (n - 1) * 6)
		var k := 0
		for iy in n - 1:
			var a := iy * n
			for ix in n - 1:
				var v := a + ix
				idx[k] = v; idx[k + 1] = v + 1; idx[k + 2] = v + n
				idx[k + 3] = v + 1; idx[k + 4] = v + n + 1; idx[k + 5] = v + n
				k += 6

		var arrays := []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = verts
		arrays[Mesh.ARRAY_NORMAL] = norms
		arrays[Mesh.ARRAY_TEX_UV] = uvs
		arrays[Mesh.ARRAY_INDEX] = idx
		mesh = ArrayMesh.new()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		ResourceSaver.save(mesh, cache_path)

	var mat := ShaderMaterial.new()
	var sh := "res://scripts/terrain_unshaded.gdshader" if "--unshaded" in OS.get_cmdline_user_args() else "res://scripts/terrain.gdshader"
	mat.shader = load(sh)
	mat.set_shader_parameter("albedo_tex", load(ALBEDO_PATH))
	for pair in [["grass", "grass"], ["dirt", "dirt"], ["rock", "rock"]]:
		mat.set_shader_parameter(pair[0] + "_tex", _load_tex(pair[1] + "_diff.jpg"))
		mat.set_shader_parameter(pair[0] + "_n", _load_tex(pair[1] + "_norm.jpg"))
	mat.set_shader_parameter("uv_debug", "--uvdebug" in OS.get_cmdline_user_args())
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	add_child(mi)
	print("Terrain built in %d ms, AABB=%s" % [Time.get_ticks_msec() - t0, mesh.get_aabb()])



## Загрузка текстуры мимо импорт-пайплайна (одинаково для albedo/normal;
## sRGB-декод делает source_color-сэмплер в шейдере, нормали остаются линейными).
func _load_tex(fname: String) -> Texture2D:
	var res := "res://assets/tex/" + fname
	var gp := ProjectSettings.globalize_path(res)
	if FileAccess.file_exists(gp):
		var img := Image.load_from_file(gp)
		img.generate_mipmaps()
		return ImageTexture.create_from_image(img)
	return load(res)                     # экспортированный билд: файл только в PCK → через импорт


## Image из res:// — с диска в редакторе/по --path, из PCK в экспортированном билде.
func load_image(res: String) -> Image:
	var gp := ProjectSettings.globalize_path(res)
	if FileAccess.file_exists(gp):
		return Image.load_from_file(gp)
	if ResourceLoader.exists(res):
		var t: Texture2D = load(res)
		return t.get_image()
	return null


## Бесшовный высотный шум (grayscale) — микрорельеф поверхности.
func _make_detail_noise() -> ImageTexture:
	var noise := FastNoiseLite.new()
	noise.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	noise.frequency = 0.035
	noise.fractal_octaves = 5
	noise.fractal_gain = 0.55
	var img := noise.get_seamless_image(512, 512)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Процедурная фактура земли: трава/грунт пятнами + контрастное зерно (бесшовная).
func _make_ground_detail() -> ImageTexture:
	var patch := FastNoiseLite.new()          # крупные пятна: трава ↔ грунт
	patch.noise_type = FastNoiseLite.TYPE_SIMPLEX
	patch.frequency = 0.02
	patch.fractal_octaves = 3
	var grain := FastNoiseLite.new()          # среднее зерно (клочья травы)
	grain.noise_type = FastNoiseLite.TYPE_SIMPLEX
	grain.frequency = 0.14
	grain.fractal_octaves = 4
	var speck := FastNoiseLite.new()          # мелкая крапина (травинки/земля)
	speck.noise_type = FastNoiseLite.TYPE_SIMPLEX
	speck.frequency = 0.9
	var pimg := patch.get_seamless_image(512, 512)
	var gimg := grain.get_seamless_image(512, 512)
	var simg := speck.get_seamless_image(512, 512)
	var out := Image.create(512, 512, false, Image.FORMAT_RGB8)
	var grass_a := Color(0.14, 0.22, 0.07)    # тёмная трава
	var grass_b := Color(0.34, 0.46, 0.18)    # светлая трава
	var dirt_a := Color(0.30, 0.24, 0.15)     # тёмный грунт
	var dirt_b := Color(0.50, 0.42, 0.28)     # светлый грунт/песок
	for y in 512:
		for x in 512:
			var pv := pimg.get_pixel(x, y).r
			var gv := gimg.get_pixel(x, y).r
			var sv := simg.get_pixel(x, y).r
			var t := clampf(gv * 0.7 + sv * 0.3, 0.0, 1.0)   # контрастная светотень
			var grass := grass_a.lerp(grass_b, t)
			var dirt := dirt_a.lerp(dirt_b, t)
			var c := grass.lerp(dirt, smoothstep(0.55, 0.72, pv))
			out.set_pixel(x, y, c)
	out.generate_mipmaps()
	return ImageTexture.create_from_image(out)


## Дома из OSM: 4 типа застройки (хата / 2-этажный / сарай / ПГТ) с фасадами
## (окна/двери/ставни), двускатными или плоскими крышами и трубами.
func _build_buildings() -> void:
	var f := FileAccess.get_file_as_string("res://assets/buildings.json")
	if f.is_empty():
		return
	var arr: Array = JSON.parse_string(f)["b"]

	# единый процедурный фасад (окна сеткой, дверь на фронтоне) — габариты per-instance
	var facade_mat := ShaderMaterial.new()
	facade_mat.shader = load("res://scripts/facade.gdshader")
	_facade_mat = facade_mat
	var roof_mat := StandardMaterial3D.new()
	roof_mat.albedo_texture = _load_tex("roof_diff.jpg")
	roof_mat.normal_enabled = true
	roof_mat.normal_texture = _load_tex("roof_norm.jpg")
	roof_mat.uv1_triplanar = true
	roof_mat.uv1_world_triplanar = true
	roof_mat.uv1_scale = Vector3(0.22, 0.22, 0.22)
	roof_mat.roughness = 0.85
	roof_mat.vertex_color_use_as_albedo = true
	var flat_mat := StandardMaterial3D.new()
	flat_mat.albedo_color = Color(0.3, 0.3, 0.32)
	flat_mat.roughness = 1.0
	var chim_mat := StandardMaterial3D.new()
	chim_mat.albedo_color = Color(0.4, 0.32, 0.28)
	chim_mat.roughness = 1.0

	# стены: единый список (габариты в custom data, цвет стены в color)
	var wall_x: Array[Transform3D] = []
	var wall_c: Array[Color] = []
	var wall_u: Array[Color] = []     # custom: (w,h,d,type)
	var gable_x: Array[Transform3D] = []; var gable_c: Array[Color] = []
	var flat_x: Array[Transform3D] = []
	var chimneys: Array[Transform3D] = []

	# палитры базового цвета стен по типам (белёная штукатурка / голубая / дерево / ПГТ)
	var plaster := [Color(0.90,0.89,0.85), Color(0.82,0.86,0.90), Color(0.88,0.85,0.78),
		Color(0.93,0.92,0.88), Color(0.86,0.80,0.72)]
	var wood := [Color(0.50,0.38,0.26), Color(0.44,0.34,0.24)]
	var blockc := [Color(0.78,0.78,0.76), Color(0.72,0.74,0.72), Color(0.82,0.80,0.75)]
	var roof_cols := [Color(1,1,1.02), Color(0.82,0.82,0.86), Color(1.15,0.6,0.42),
		Color(1.0,0.5,0.38), Color(0.75,0.72,0.7)]
	var cnt := {"cottage": 0, "house": 0, "barn": 0, "block": 0}

	for b: Array in arr:
		var w: float = b[2]; var d: float = b[3]; var h: float = b[5]
		var area := w * d
		var elong: float = maxf(w, d) / maxf(minf(w, d), 0.1)
		var t := "cottage"
		var typef := 0.0
		if h >= 11.0 or area >= 700.0:
			t = "block"; typef = 2.0
		elif area >= 110.0 and h < 6.5 and elong >= 1.8:
			t = "barn"; typef = 1.0
		elif h >= 6.0:
			t = "house"
		cnt[t] += 1
		var ht := height_at(b[0], b[1])
		var yaw := Basis(Vector3.UP, -float(b[4]))
		var hsh := int(abs(b[0]) * 7.0 + abs(b[1]) * 13.0)
		var wall_top := ht + h - 0.6

		wall_x.append(Transform3D(yaw * Basis.from_scale(Vector3(w, h, d)),
			Vector3(b[0], ht + h * 0.5 - 0.6, b[1])))
		col_add_box(b[0], b[1], w, d, float(b[4]), wall_top)   # препятствие для дрона
		var pal: Array = wood if t == "barn" else (blockc if t == "block" else plaster)
		wall_c.append(pal[hsh % pal.size()])
		wall_u.append(Color(w, h, d, typef))

		if t == "block":
			flat_x.append(Transform3D(yaw * Basis.from_scale(Vector3(w * 1.02, 0.6, d * 1.02)),
				Vector3(b[0], wall_top + 0.3, b[1])))
		else:
			var roof_h: float = clampf(minf(w, d) * 0.45, 1.4, 3.6)
			var rw := w; var rd := d; var rbasis := yaw
			if w > d:
				rbasis = yaw * Basis(Vector3.UP, PI * 0.5)
				rw = d; rd = w
			gable_x.append(Transform3D(rbasis * Basis.from_scale(Vector3(rw * 1.06, roof_h, rd * 1.06)),
				Vector3(b[0], wall_top + roof_h * 0.5, b[1])))
			gable_c.append(roof_cols[(hsh / 3) % roof_cols.size()])
			if t != "barn" and hsh % 10 < 7:
				var off := (rw * 0.2) * (1.0 if hsh % 2 == 0 else -1.0)
				var cpos := Vector3(b[0], 0, b[1]) + rbasis * Vector3(0, 0, off)
				var cy := wall_top + roof_h * 0.6
				chimneys.append(Transform3D(Basis.from_scale(Vector3(0.7, roof_h + 1.4, 0.7)),
					Vector3(cpos.x, cy, cpos.z)))
				if hsh % 5 < 2:            # ~40% труб дымят
					_chimney_pos.append(Vector3(cpos.x, cy + (roof_h + 1.4) * 0.5, cpos.z))

	_add_mm("Walls", BoxMesh.new(), facade_mat, wall_x, wall_c, wall_u)
	_add_mm("Roofs", PrismMesh.new(), roof_mat, gable_x, gable_c, [])
	_add_mm("BlockRoofs", BoxMesh.new(), flat_mat, flat_x, [], [])
	_add_mm("Chimneys", BoxMesh.new(), chim_mat, chimneys, [], [])
	print("Buildings: %d (хат %d, домов %d, сараев %d, ПГТ %d, труб %d)" % [
		arr.size(), cnt["cottage"], cnt["house"], cnt["barn"], cnt["block"], chimneys.size()])


func _build_water() -> void:
	var w := Node3D.new()
	w.name = "Water"
	w.set_script(load("res://scripts/water.gd"))
	add_child(w)
	w.setup(self)


func _build_roads() -> void:
	var r := Node3D.new()
	r.name = "Roads"
	r.set_script(load("res://scripts/roads.gd"))
	add_child(r)
	r.setup(self)


var _chimney_pos: PackedVector3Array = PackedVector3Array()

func _build_smoke() -> void:
	if _chimney_pos.is_empty():
		return
	var sm := Node3D.new()
	sm.name = "Smoke"
	sm.set_script(load("res://scripts/smoke.gd"))
	add_child(sm)
	sm.setup(self, _chimney_pos)


var _lamp_mat: StandardMaterial3D

var props: Node3D

func _build_props() -> void:
	var pr := Node3D.new()
	pr.name = "Props"
	pr.set_script(load("res://scripts/props.gd"))
	pr.pool = [6, 12, 24][quality]
	add_child(pr)
	pr.setup(self)
	props = pr


# ======================= Качество (пресеты под слабые ПК) =======================
var quality := 2                       # 0 низкое / 1 среднее / 2 высокое
const QUALITY_NAMES := ["низкое", "среднее", "высокое"]
const SETTINGS_PATH := "user://settings.cfg"

func _load_quality() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SETTINGS_PATH) == OK:
		quality = clampi(int(cfg.get_value("video", "quality", 2)), 0, 2)
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--quality="):
			var v := a.substr(10).to_lower()
			quality = {"low": 0, "0": 0, "medium": 1, "med": 1, "1": 1, "high": 2, "2": 2}.get(v, quality)


func apply_quality(q: int) -> void:
	quality = clampi(q, 0, 2)
	var vp := get_viewport()
	var forest := get_node_or_null("Forest")
	match quality:
		0:
			vp.scaling_3d_scale = 0.7
			vp.msaa_3d = Viewport.MSAA_DISABLED
			sun.shadow_enabled = false
			environment.ssr_enabled = false
			environment.glow_enabled = false
			if forest != null: forest.radius = 1400.0
			if props != null: props.pool = 6
		1:
			vp.scaling_3d_scale = 1.0
			vp.msaa_3d = Viewport.MSAA_DISABLED
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 6000.0
			environment.ssr_enabled = false
			environment.glow_enabled = true
			if forest != null: forest.radius = 2200.0
			if props != null: props.pool = 12
		2:
			vp.scaling_3d_scale = 1.0
			vp.msaa_3d = Viewport.MSAA_DISABLED
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 30000.0
			environment.ssr_enabled = true
			environment.glow_enabled = true
			if forest != null: forest.radius = 3000.0
			if props != null: props.pool = 24
	var cfg := ConfigFile.new()
	cfg.load(SETTINGS_PATH)
	cfg.set_value("video", "quality", quality)
	cfg.save(SETTINGS_PATH)
	print("Качество: ", QUALITY_NAMES[quality])


# ======================= Столкновения и краш =======================
const COL_CELL := 64.0
const DRONE_R := 1.6
const CHUNK_M := 512.0
var _col_box := {}      # Vector2i(64м) -> Array[Dictionary] коробки зданий
var _col_cyl := {}      # Vector2i(64м) -> Array[Dictionary] столбы/фонари
var _tree_col := {}     # Vector2i(чанк 512м) -> Array[Dictionary] деревья
var crashed := false
var _crash_label: Label
var _home_pos := Vector3.ZERO


func _col_test() -> void:
	var f := FileAccess.get_file_as_string("res://assets/buildings.json")
	var arr: Array = JSON.parse_string(f)["b"]
	var b: Array = arr[100]
	var gy := height_at(b[0], b[1])
	var inside := Vector3(b[0], gy + 2.0, b[1])
	var outside := Vector3(b[0] + 60.0, gy + 2.0, b[1])
	var above := Vector3(b[0], gy + 40.0, b[1])
	print("COLTEST здание #100 центр(%.0f,%.0f) h=%.1f" % [b[0], b[1], b[5]])
	print("  внутри  -> '%s' (ждём 'здание')" % check_crash(inside))
	print("  снаружи -> '%s' (ждём пусто)" % check_crash(outside))
	print("  сверху  -> '%s' (ждём пусто)" % check_crash(above))
	print("COLTEST ячеек-коробок: %d, ячеек-цилиндров: %d" % [_col_box.size(), _col_cyl.size()])
	# LOS: оператор в долине Ворохты, дрон высоко (чисто) и низко за 4 км (должно упасть)
	var op := _world_from_latlon(48.2839, 24.5610)
	var opp := Vector3(op.x, height_at(op.x, op.y) + 2.0, op.y)
	var hi := opp + Vector3(0, 400, 0)
	var far := _world_from_latlon(48.32, 24.60)
	var lowfar := Vector3(far.x, height_at(far.x, far.y) + 5.0, far.y)
	print("COLTEST LOS вверх(+400м) = %.2f (ждём ~1)" % los_factor(opp, hi))
	print("COLTEST LOS низко за ~5км = %.2f (ждём <1)" % los_factor(opp, lowfar))


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


## Столкновение → краш дрона (падает, ждёт перезапуска R).
func crash(what: String) -> void:
	if crashed:
		return
	crashed = true
	if mission != null:
		mission.on_crash()
	if telemetry != null:
		telemetry.event("crash_" + what)
	if _crash_label != null:
		_crash_label.text = "⚠  СТОЛКНОВЕНИЕ: %s\nR — перезапуск с точки взлёта" % what
		_crash_label.visible = true
	if sound != null:
		sound.boom(cam.global_position)


func _respawn() -> void:
	crashed = false
	if _crash_label != null:
		_crash_label.visible = false
	cam.global_position = _home_pos + Vector3(0, 5, 0)
	if cam.has_method("reset"):
		cam.reset()
	else:
		cam.set("velocity", Vector3.ZERO)


var _facade_mat: ShaderMaterial

## Доля светящихся окон (0 днём … ~0.6 ночью) + накал уличных фонарей.
func set_window_light(a: float) -> void:
	if _facade_mat != null:
		_facade_mat.set_shader_parameter("lit_amount", a)
	if _lamp_mat != null:
		_lamp_mat.emission_energy_multiplier = clampf(a * 9.0, 0.0, 6.0)


## Создаёт MultiMeshInstance3D из списка трансформов (+ опц. цвета и custom data).
func _add_mm(nm: String, mesh: Mesh, mat: Material, xforms: Array, colors: Array, custom: Array) -> void:
	if xforms.is_empty():
		return
	var m := mesh.duplicate()
	m.surface_set_material(0, mat)
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = not colors.is_empty()
	mm.use_custom_data = not custom.is_empty()
	mm.mesh = m
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
		if not colors.is_empty():
			mm.set_instance_color(i, colors[i])
		if not custom.is_empty():
			mm.set_instance_custom_data(i, custom[i])
	var mmi := MultiMeshInstance3D.new()
	mmi.name = nm
	mmi.multimesh = mm
	add_child(mmi)


func _build_forest() -> void:
	if not FileAccess.file_exists(ProjectSettings.globalize_path("res://assets/mask.png")) \
			and not ResourceLoader.exists("res://assets/mask.png"):
		return
	var forest := Node3D.new()
	forest.name = "Forest"
	forest.set_script(load("res://scripts/scatter.gd"))
	add_child(forest)
	forest.setup(self)


var sound: Node3D

func _build_sound() -> void:
	if "--screenshot" in OS.get_cmdline_user_args() or "--nosound" in OS.get_cmdline_user_args():
		return
	sound = Node3D.new()
	sound.name = "Sound"
	sound.set_script(load("res://scripts/sound.gd"))
	add_child(sound)
	sound.setup(self)


var mission: Node3D
var telemetry: Node
var replaying := false

func _build_mission() -> void:
	mission = Node3D.new()
	mission.name = "Mission"
	mission.set_script(load("res://scripts/mission.gd"))
	add_child(mission)
	mission.setup(self)
	mission._result_label = _result_label


func _build_telemetry() -> void:
	telemetry = Node.new()
	telemetry.name = "Telemetry"
	telemetry.set_script(load("res://scripts/telemetry.gd"))
	add_child(telemetry)
	telemetry.replay_label = _replay_label
	telemetry.setup(self)


var targets: Node3D

func _build_targets() -> void:
	targets = Node3D.new()
	targets.name = "Targets"
	targets.set_script(load("res://scripts/targets.gd"))
	add_child(targets)
	targets.setup(self)


func _world_from_latlon(lat: float, lon: float) -> Vector2:
	var two_z := pow(2.0, float(meta["zoom"]))
	var n_tiles := float(meta.get("n_tiles", 8))
	var tx := (lon + 180.0) / 360.0 * two_z
	var lr := deg_to_rad(lat)
	var ty := (1.0 - log(tan(lr) + 1.0 / cos(lr)) / PI) / 2.0 * two_z
	return Vector2(((tx - float(meta["tile_x0"])) / n_tiles - 0.5) * size_m,
			((ty - float(meta["tile_y0"])) / n_tiles - 0.5) * size_m)


var sun: DirectionalLight3D
var sky_material: ShaderMaterial
var environment: Environment

func _build_environment() -> void:
	sky_material = ShaderMaterial.new()
	sky_material.shader = load("res://scripts/sky.gdshader")
	var sky := Sky.new(); sky.sky_material = sky_material
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# bloom / свечение (окна, фонари, солнце, закат)
	env.glow_enabled = true
	env.glow_intensity = 0.5
	env.glow_bloom = 0.15
	env.glow_hdr_threshold = 1.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_ADDITIVE
	# отражения: небо как источник + SSR (берега/дома в воде)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssr_enabled = true
	env.ssr_max_steps = 32
	env.ssr_fade_in = 0.2
	env.ssr_fade_out = 4.0
	env.fog_enabled = not ("--nofog" in OS.get_cmdline_user_args())
	env.fog_light_color = Color(0.78, 0.84, 0.92)
	env.fog_density = 0.0000015
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.5
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.25
	env.adjustment_saturation = 1.15
	environment = env
	var we := WorldEnvironment.new(); we.environment = env
	add_child(we)

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, -125, 0)
	sun.light_energy = 1.3
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 30000.0
	add_child(sun)


var weather: Node3D

func _build_weather() -> void:
	weather = Node3D.new()
	weather.name = "Weather"
	weather.set_script(load("res://scripts/weather.gd"))
	add_child(weather)
	weather.setup(self, sun, environment, sky_material)


func _spawn_camera() -> void:
	cam = Camera3D.new()
	cam.name = "FlyCam"
	cam.set_script(load("res://scripts/flycam.gd"))
	cam.near = 2.0
	cam.far = 150000.0
	if "--topdown" in OS.get_cmdline_user_args():
		cam.position = Vector3(0, 30000, 0)
		add_child(cam)
		cam.look_at(Vector3(0, 0, 0), Vector3.FORWARD)
	else:
		# старт над Ворохтой, низко над долиной с дорогой
		var v := _world_from_latlon(48.2839, 24.5610)
		var ground := height_at(v.x, v.y)
		cam.position = Vector3(v.x, ground + 220.0, v.y)
		add_child(cam)
		var tgt := _world_from_latlon(48.2650, 24.5660)  # вдоль долины на юг
		cam.look_at(Vector3(tgt.x, height_at(tgt.x, tgt.y) + 60.0, tgt.y))
	cam.set("main", self)
	cam.make_current()
	_home_pos = cam.position


var hud_label: Label
var target_marker: Label
var _sound_btn: Button
var _sound_muted := false
var _wind_label: Label
var _wind_flag: Control
var _sticks: Control
var _result_label: Label
var _replay_label: Label
var mission_marker: Label

## Вкл/выкл весь звук (кнопка в углу или клавиша M).
func _toggle_sound() -> void:
	_sound_muted = not _sound_muted
	AudioServer.set_bus_mute(0, _sound_muted)
	if _sound_btn != null:
		_sound_btn.text = "  Звук: ВЫКЛ  " if _sound_muted else "  Звук: ВКЛ  "


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			_toggle_sound()
		elif event.keycode == KEY_F:
			_toggle_fpv()
		elif event.keycode == KEY_R and crashed:
			_respawn()
		elif event.keycode == KEY_G:
			apply_quality((quality + 1) % 3)


var _fpv_rect: ColorRect
var _fpv_osd: Control
var fpv_on := false

## FPV-подача: широкий угол + «аналоговое видео» + OSD дрона.
func _toggle_fpv() -> void:
	fpv_on = not fpv_on
	_fpv_rect.visible = fpv_on
	_fpv_osd.visible = fpv_on
	hud_label.visible = not fpv_on
	target_marker.visible = not fpv_on
	# обычный HUD прячем — в FPV своя приборка
	for c: Node in [_wind_label, _wind_flag, _sound_btn]:
		if c != null:
			c.visible = not fpv_on
	cam.fov = 105.0 if fpv_on else 75.0
	if fpv_on:
		_fpv_osd.home = cam.global_position
		_fpv_osd.flight_t = 0.0


func _build_hud() -> void:
	var layer := CanvasLayer.new()
	add_child(layer)
	hud_label = Label.new()
	hud_label.position = Vector2(16, 12)
	hud_label.add_theme_font_size_override("font_size", 15)
	hud_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	hud_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	hud_label.add_theme_constant_override("shadow_offset_x", 1)
	hud_label.add_theme_constant_override("shadow_offset_y", 1)
	layer.add_child(hud_label)

	# кнопка звука в правом верхнем углу
	_sound_btn = Button.new()
	_sound_btn.text = "  Звук: ВКЛ  "
	_sound_btn.focus_mode = Control.FOCUS_NONE
	_sound_btn.add_theme_font_size_override("font_size", 15)
	_sound_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_sound_btn.position = Vector2(-150, 12)
	_sound_btn.pressed.connect(_toggle_sound)
	layer.add_child(_sound_btn)

	# перекрестие
	for size_off: Array in [[Vector2(14, 2), Vector2(-7, -1)], [Vector2(2, 14), Vector2(-1, -7)]]:
		var cr := ColorRect.new()
		cr.color = Color(1, 1, 1, 0.8)
		cr.size = size_off[0]
		cr.set_anchors_preset(Control.PRESET_CENTER)
		cr.position = size_off[1]
		cr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hud_label.get_parent().add_child(cr)

	# указатель на ближайшую цель
	target_marker = Label.new()
	target_marker.text = "◆ ЦЕЛЬ"
	target_marker.add_theme_font_size_override("font_size", 16)
	target_marker.add_theme_color_override("font_color", Color(1, 0.25, 0.15))
	target_marker.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	target_marker.add_theme_constant_override("shadow_offset_x", 1)
	target_marker.add_theme_constant_override("shadow_offset_y", 1)
	target_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(target_marker)

	# флажок-ветрометр в левом нижнем углу
	_wind_flag = Control.new()
	_wind_flag.set_script(load("res://scripts/windflag.gd"))
	_wind_flag.set("main", self)
	_wind_flag.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_wind_flag.position = Vector2(14, -150)
	_wind_flag.custom_minimum_size = Vector2(110, 92)
	_wind_flag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_wind_flag)

	# скорость ветра под флажком
	_wind_label = Label.new()
	_wind_label.add_theme_font_size_override("font_size", 16)
	_wind_label.add_theme_color_override("font_color", Color(1, 1, 1, 0.95))
	_wind_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_wind_label.add_theme_constant_override("shadow_offset_x", 1)
	_wind_label.add_theme_constant_override("shadow_offset_y", 1)
	_wind_label.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_wind_label.position = Vector2(16, -54)
	layer.add_child(_wind_label)

	# индикатор стиков пульта — правый нижний угол
	_sticks = Control.new()
	_sticks.set_script(load("res://scripts/sticks.gd"))
	_sticks.set("main", self)
	_sticks.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_sticks.position = Vector2(-330, -118)
	layer.add_child(_sticks)

	# надпись о столкновении по центру экрана
	_crash_label = Label.new()
	_crash_label.set_anchors_preset(Control.PRESET_CENTER)
	_crash_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_crash_label.add_theme_font_size_override("font_size", 30)
	_crash_label.add_theme_color_override("font_color", Color(1.0, 0.35, 0.25))
	_crash_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_crash_label.add_theme_constant_override("shadow_offset_x", 2)
	_crash_label.add_theme_constant_override("shadow_offset_y", 2)
	_crash_label.position = Vector2(-360, -60)
	_crash_label.custom_minimum_size = Vector2(720, 0)
	_crash_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_crash_label.visible = false
	layer.add_child(_crash_label)

	# FPV-слой: пост-эффект видео + OSD (поверх всего, включается на F)
	var fpv_layer := CanvasLayer.new()
	fpv_layer.layer = 5
	add_child(fpv_layer)
	_fpv_rect = ColorRect.new()
	_fpv_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fpv_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fmat := ShaderMaterial.new()
	fmat.shader = load("res://scripts/fpv.gdshader")
	_fpv_rect.material = fmat
	_fpv_rect.visible = false
	fpv_layer.add_child(_fpv_rect)
	_fpv_osd = Control.new()
	_fpv_osd.set_script(load("res://scripts/fpv_osd.gd"))
	_fpv_osd.set_anchors_preset(Control.PRESET_FULL_RECT)
	_fpv_osd.set("main", self)
	_fpv_osd.visible = false
	fpv_layer.add_child(_fpv_osd)

	# результат миссии по центру
	_result_label = Label.new()
	_result_label.set_anchors_preset(Control.PRESET_CENTER)
	_result_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_result_label.add_theme_font_size_override("font_size", 22)
	_result_label.add_theme_color_override("font_color", Color(0.9, 1.0, 0.85))
	_result_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_result_label.add_theme_constant_override("shadow_offset_x", 2)
	_result_label.add_theme_constant_override("shadow_offset_y", 2)
	_result_label.position = Vector2(-380, -160)
	_result_label.custom_minimum_size = Vector2(760, 0)
	_result_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_result_label.visible = false
	layer.add_child(_result_label)

	# маркер цели миссии (ворота/площадка/точка)
	mission_marker = Label.new()
	mission_marker.add_theme_font_size_override("font_size", 16)
	mission_marker.add_theme_color_override("font_color", Color(0.4, 1.0, 0.5))
	mission_marker.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	mission_marker.add_theme_constant_override("shadow_offset_x", 1)
	mission_marker.add_theme_constant_override("shadow_offset_y", 1)
	mission_marker.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mission_marker.visible = false
	layer.add_child(mission_marker)

	# строка реплея (сверху по центру)
	_replay_label = Label.new()
	_replay_label.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_replay_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_replay_label.add_theme_font_size_override("font_size", 16)
	_replay_label.add_theme_color_override("font_color", Color(1.0, 0.85, 0.4))
	_replay_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.9))
	_replay_label.position = Vector2(-300, 40)
	_replay_label.custom_minimum_size = Vector2(600, 0)
	_replay_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	layer.add_child(_replay_label)

	var attrib := Label.new()
	attrib.text = str(meta.get("attribution", ""))
	attrib.add_theme_font_size_override("font_size", 11)
	attrib.add_theme_color_override("font_color", Color(1, 1, 1, 0.55))
	attrib.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	attrib.position = Vector2(16, -24)
	layer.add_child(attrib)


func _latlon_at(x: float, z: float) -> Vector2:
	var n_tiles := float(meta.get("n_tiles", 8))
	var two_z := pow(2.0, float(meta["zoom"]))
	var tx := float(meta["tile_x0"]) + (x / size_m + 0.5) * n_tiles
	var ty := float(meta["tile_y0"]) + (z / size_m + 0.5) * n_tiles
	var lon := tx / two_z * 360.0 - 180.0
	var lat := rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * ty / two_z))))
	return Vector2(lat, lon)


func _process(_dt: float) -> void:
	if cam == null or hud_label == null:
		return
	var p := cam.global_position
	var ground := height_at(p.x, p.z)
	var ll := _latlon_at(p.x, p.z)
	var spd: float = cam.speed() if cam.has_method("speed") else 0.0
	var tline := ""
	if targets != null:
		tline = "\nПоражено: %d   |   целей в зоне: %d" % [targets.score, targets.active_count()]
	if mission != null:
		var ml: String = mission.hud_line()
		if ml != "": tline += "\n" + ml
	var wline := ""
	if weather != null:
		var w: Vector3 = weather.wind_vec()
		wline = "\n%s   ветер %d м/с %s" % [weather.label, int(w.length()), _wind_arrow(w)]
		if _wind_label != null:
			_wind_label.text = "Ветер: %d м/с %s" % [int(w.length()), _wind_arrow(w)]
	var fline := ""
	if cam.has_method("mode_name"):
		var src: String = ("пульт: " + str(cam.joy_name)) if str(cam.joy_name) != "" else "клавиатура"
		fline = "\n[%s]  %s  ·  %s%s  ·  качество: %s (G)" % [cam.mode_name(), cam.drone_name(), src,
			("  ·  НА ЗЕМЛЕ" if cam.landed else ""), QUALITY_NAMES[quality]]
	hud_label.text = "%.5f°N  %.5f°E\nMSL %d м   AGL %d м\nскорость %d м/с   FPS %d%s%s%s\nW/S тангаж · A/D крен · E/Q газ · ←/→ рыскание · Tab режим · B дрон · Shift буст · ЛКМ огонь · 1-5/P погода · 6 туман · 7 дождь · M звук · F FPV · R рестарт" % [
		ll.x, ll.y, int(p.y), int(p.y - ground), int(spd), int(Engine.get_frames_per_second()), fline, tline, wline]
	_update_target_marker(p)
	_update_mission_marker()
	if fpv_on and _fpv_rect != null:
		# картинка сыпется по мере падения сигнала; при краше — полная статика
		var q: float = 0.0 if crashed else _fpv_osd.signal_q
		_fpv_rect.material.set_shader_parameter("noise_burst", clampf(1.0 - q, 0.0, 1.0) * 0.9)
		_fpv_rect.material.set_shader_parameter("grain", 0.05 + (1.0 - q) * 0.12)


func _update_mission_marker() -> void:
	if mission_marker == null or mission == null:
		return
	var tp = mission.target_pos()
	if tp == null:
		mission_marker.visible = false
		return
	mission_marker.visible = true
	var vp := get_viewport().get_visible_rect().size
	var behind := cam.is_position_behind(tp)
	var sp := cam.unproject_position(tp)
	if behind:
		sp.x = vp.x - sp.x
		sp.y = vp.y
	var margin := 40.0
	sp.x = clampf(sp.x, margin, vp.x - margin)
	sp.y = clampf(sp.y, margin, vp.y - margin)
	mission_marker.position = sp - mission_marker.size * 0.5
	mission_marker.text = "◎ %d м" % int(cam.global_position.distance_to(tp))


func _wind_arrow(w: Vector3) -> String:
	if w.length() < 0.5:
		return "—"
	var a := atan2(w.z, w.x)
	var dirs := ["→", "↘", "↓", "↙", "←", "↖", "↑", "↗"]
	return dirs[int(round(a / (PI / 4.0))) & 7]


func _update_target_marker(p: Vector3) -> void:
	if target_marker == null or targets == null:
		return
	var n: Dictionary = targets.nearest(p)
	if n.is_empty() or fpv_on:
		target_marker.visible = false
		return
	target_marker.visible = true
	var tpos: Vector3 = n.pos + Vector3(0, 30, 0)
	var vp := get_viewport().get_visible_rect().size
	var behind := cam.is_position_behind(tpos)
	var sp := cam.unproject_position(tpos)
	if behind:
		sp.x = vp.x - sp.x
		sp.y = vp.y
	# держим ярлык у края экрана, если цель вне кадра
	var margin := 40.0
	sp.x = clampf(sp.x, margin, vp.x - margin)
	sp.y = clampf(sp.y, margin, vp.y - margin)
	target_marker.position = sp - target_marker.size * 0.5
	var names := {"tank": "ТАНК", "apc": "БТР", "soldier": "ПЕХОТА"}
	var name_ru: String = names.get(n.kind, "ЦЕЛЬ")
	target_marker.text = "◆ %s  %d м" % [name_ru, int(n.dist)]


## Пресеты видовых точек для заявки/видео: cam lat/lon, AGL(м), target lat/lon, target +Δh(м).
const SHOT_PRESETS := [
	[48.070, 24.560, 2600.0, 48.160, 24.500, 0.0],    # 0 establishing: ЮВ→Говерла, высокий облёт
	[48.2839, 24.5610, 240.0, 48.2650, 24.5660, 60.0],# 1 low valley: долина Ворохты на юг
	[48.140, 24.560, 700.0, 48.180, 24.470, -100.0],  # 2 ridge: вдоль хребта к массиву
	[48.190, 24.470, 900.0, 48.160, 24.500, -50.0],   # 3 peak: подход к вершине Говерлы
]

func _preset_index() -> int:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--preset="):
			return int(a.substr(9))
	return -1

func _apply_preset(i: int) -> void:
	var p: Array = SHOT_PRESETS[i]
	var v := _world_from_latlon(p[0], p[1])
	cam.global_position = Vector3(v.x, height_at(v.x, v.y) + float(p[2]), v.y)
	var t := _world_from_latlon(p[3], p[4])
	cam.look_at(Vector3(t.x, height_at(t.x, t.y) + float(p[5]), t.y))


func _schedule_screenshot() -> void:
	await RenderingServer.frame_post_draw
	for i in 90:
		await get_tree().process_frame
	var preset := _preset_index()
	if preset >= 0 and preset < SHOT_PRESETS.size():
		_apply_preset(preset)
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
	if "--watershot" in OS.get_cmdline_user_args():
		var wt := _world_from_latlon(48.23928, 24.33539)
		var gy := height_at(wt.x, wt.y)
		cam.global_position = Vector3(wt.x + 30.0, gy + 320.0, wt.y + 30.0)
		cam.look_at(Vector3(wt.x, gy, wt.y))
		for _i in 60:
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if "--fpv" in OS.get_cmdline_user_args():
		_toggle_fpv()
		_fpv_osd.flight_t = 143.0
		_fpv_osd.battery = 0.62
	if "--lowshot" in OS.get_cmdline_user_args():
		var lv := _world_from_latlon(48.2760, 24.5640)
		cam.global_position = Vector3(lv.x, height_at(lv.x, lv.y) + 35.0, lv.y)
		var lt := _world_from_latlon(48.2700, 24.5660)
		cam.look_at(Vector3(lt.x, height_at(lt.x, lt.y) + 8.0, lt.y))
		for _i in 90:                       # дать свету/дыму прилипнуть и накопиться
			await get_tree().process_frame
		await RenderingServer.frame_post_draw
	if "--targetcam" in OS.get_cmdline_user_args() and targets != null:
		var want := "tank"
		if "--oneapc" in OS.get_cmdline_user_args(): want = "apc"
		elif "--onesquad" in OS.get_cmdline_user_args(): want = "soldier"
		var pick: Dictionary = targets.targets[-1] if not targets.targets.is_empty() else {}
		for t: Dictionary in targets.targets:
			if t.kind == want:
				pick = t
				break
		if not pick.is_empty():
			var tp: Vector3 = pick.node.position
			cam.global_position = tp + Vector3(8.0, 6.5, 8.5)
			cam.look_at(tp + Vector3(0, 1.9, 0))
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	var suffix := ("_%d" % preset) if preset >= 0 else ""
	var out := ProjectSettings.globalize_path("res://../shot%s.png" % suffix)
	img.save_png(out)
	print("Screenshot saved: ", out)
	get_tree().quit()


func _debug_report_targets() -> void:
	await get_tree().process_frame
	for i in 30:
		await get_tree().process_frame
	if targets == null:
		return
	var cp: Vector3 = cam.global_position
	var lst: Array = []
	for t: Dictionary in targets.targets:
		var d := cp.distance_to(t.node.position)
		lst.append([d, t.kind])
	lst.sort()
	print("=== ЦЕЛИ от камеры (", cp, ") ===")
	for e in lst:
		print("  %s  %.0f м" % [e[1], e[0]])
	get_tree().quit()
