extends Node3D
## Прототип: полёт над реальным рельефом (Карпаты, Говерла).
## Данные: AWS Terrain Tiles (высоты) + Sentinel-2 L2A COG, открытая лицензия (подложка).

const MESH_RES := 1024         # вершин по стороне
var region := ""               # "" = базовый регион (Карпаты) в res://assets/, иначе res://assets/regions/<name>/
var asset_dir := "res://assets/"


## Путь к файлу данных текущего региона (height.raw, meta.json, albedo.jpg, mask.png, *.json).
func asset_path(f: String) -> String:
	return asset_dir + f

var meta: Dictionary
var seed_value := 1
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
	seed_value = sv
	seed(hash(sv))
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--region="):
			region = a.substr(9)
			asset_dir = "res://assets/regions/%s/" % region
	_load_quality()
	collision = load("res://scripts/collision.gd").new(self)
	_load_data()
	_build_environment()
	_build_terrain()
	_build_water()
	_build_roads()
	_build_props()
	_build_buildings()
	_spawn_camera()
	_build_valley_fog()
	_build_weather()
	_build_forest()
	_build_yards()
	_build_grass()
	_build_smoke()
	_build_targets()
	_build_traffic()
	_build_ew()
	_build_thermal()
	_build_sound()
	_build_hud()
	_build_mission()
	_build_telemetry()
	apply_quality(quality)
	_build_selftest()
	_build_debug()


var _node_hs := PackedFloat32Array()   # кэш высот узлов меша — height_at зовётся тысячами за кадр

func _load_data() -> void:
	var mtxt := FileAccess.get_file_as_string(asset_path("meta.json"))
	if mtxt.is_empty():
		push_error("Регион '%s' не найден: нет %s (соберите tools/build_region.py)" % [region, asset_path("meta.json")])
		get_tree().quit(2)
		return
	meta = JSON.parse_string(mtxt)
	height_bytes = FileAccess.get_file_as_bytes(asset_path("height.raw"))
	px = int(meta["px"])
	size_m = float(meta["size_m"])
	e_min = float(meta["elev_min_m"])
	e_max = float(meta["elev_max_m"])
	# предрасчёт высот узлов (1024² float ≈ 4 МБ): decode_u16 на каждый вызов height_at был главным CPU-костом
	var n := MESH_RES
	_node_hs.resize(n * n)
	var espan := e_max - e_min
	for iz in n:
		var py := (iz * (px - 1)) / (n - 1)
		var row := py * px
		for ix in n:
			var pxx := (ix * (px - 1)) / (n - 1)
			_node_hs[iz * n + ix] = e_min + espan * height_bytes.decode_u16(2 * (row + pxx)) / 65535.0


## Высота узла ТЕРРЕЙН-МЕША (ix,iz) — та же выборка, что при построении меша
## (ближайший пиксель на грубой сетке MESH_RES), чтобы объекты садились ровно
## на видимую поверхность, а не на детальную карту 4096².
func _node_h(ix: int, iz: int) -> float:
	var n := MESH_RES
	return _node_hs[clampi(iz, 0, n - 1) * n + clampi(ix, 0, n - 1)]


## Высота рельефа в мировой точке (x, z) = ТОЧНАЯ поверхность террейн-меша.
## Меш в каждой ячейке сетки MESH_RES — два треугольника с диагональю (ix+1,iz)–(ix,iz+1);
## билинейная интерполяция отличается от них на метры на неровном рельефе → дороги/реки/трава «проваливались».
func height_at(x: float, z: float) -> float:
	var n := MESH_RES
	var gx := clampf((x / size_m + 0.5) * (n - 1), 0.0, float(n - 1) - 1e-4)
	var gz := clampf((z / size_m + 0.5) * (n - 1), 0.0, float(n - 1) - 1e-4)
	var x0 := int(gx); var z0 := int(gz)
	var tx := gx - x0; var tz := gz - z0
	var h00 := _node_h(x0, z0); var h10 := _node_h(x0 + 1, z0)
	var h01 := _node_h(x0, z0 + 1); var h11 := _node_h(x0 + 1, z0 + 1)
	if tx + tz <= 1.0:
		return h00 + (h10 - h00) * tx + (h01 - h00) * tz          # треугольник (00, 10, 01)
	return h11 + (h01 - h11) * (1.0 - tx) + (h10 - h11) * (1.0 - tz)   # треугольник (10, 11, 01)


func _build_terrain() -> void:
	var t0 := Time.get_ticks_msec()
	var n := MESH_RES
	var cache_path := "user://terrain_%s%d_%d_%d.res" % [region + "_" if region != "" else "", px, n,
		FileAccess.get_modified_time(ProjectSettings.globalize_path(asset_path("height.raw")))]
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
	mat.set_shader_parameter("albedo_tex", _load_albedo())
	for pair in [["grass", "grass"], ["dirt", "dirt"], ["rock", "rock"]]:
		mat.set_shader_parameter(pair[0] + "_tex", _load_tex(pair[1] + "_diff.jpg"))
		mat.set_shader_parameter(pair[0] + "_n", _load_tex(pair[1] + "_norm.jpg"))
	mat.set_shader_parameter("noise_tex", _make_detail_noise())
	var mimg := load_image(asset_path("mask.png"))
	if mimg != null:
		mat.set_shader_parameter("mask_tex", ImageTexture.create_from_image(mimg))
		mat.set_shader_parameter("mask_px", float(mimg.get_width()))
	mat.set_shader_parameter("uv_debug", "--uvdebug" in OS.get_cmdline_user_args())
	mat.set_shader_parameter("mask_debug", "--maskdebug" in OS.get_cmdline_user_args())
	print("mask_tex: ", mimg.get_width() if mimg != null else "НЕТ", " format ", mimg.get_format() if mimg != null else -1)
	mesh.surface_set_material(0, mat)

	var mi := MeshInstance3D.new()
	mi.name = "Terrain"
	mi.mesh = mesh
	add_child(mi)
	print("Terrain built in %d ms, AABB=%s" % [Time.get_ticks_msec() - t0, mesh.get_aabb()])



## Спутниковая подложка региона: через импорт (мипы/sRGB), а если регион ещё не импортирован — с диска.
func _load_albedo() -> Texture2D:
	var res := asset_path("albedo.jpg")
	if ResourceLoader.exists(res):
		return load(res)
	var img := Image.load_from_file(ProjectSettings.globalize_path(res))
	if img == null:
		push_error("albedo.jpg не найден: " + res)
		return null
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


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
	var f := FileAccess.get_file_as_string(asset_path("buildings.json"))
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
	var plaster := [Color(0.76,0.75,0.71), Color(0.70,0.74,0.78), Color(0.75,0.72,0.66),
		Color(0.80,0.79,0.75), Color(0.73,0.68,0.61), Color(0.62,0.70,0.64)]
	var wood := [Color(0.50,0.38,0.26), Color(0.44,0.34,0.24)]
	var blockc := [Color(0.78,0.78,0.76), Color(0.72,0.74,0.72), Color(0.82,0.80,0.75)]
	# крыши (множитель к текстуре черепицы): шифер серый 45 %, жесть зелёная 20 %, коричневая 15 %, красная 15 %, тёмная 5 %
	var roof_cols := [Color(0.55,0.55,0.57), Color(0.50,0.50,0.52), Color(0.60,0.60,0.62), Color(0.46,0.47,0.50), Color(0.58,0.57,0.55),
		Color(0.42,0.44,0.46), Color(0.52,0.53,0.56), Color(0.57,0.56,0.54), Color(0.48,0.48,0.50),
		Color(0.28,0.42,0.30), Color(0.24,0.38,0.28), Color(0.30,0.45,0.33), Color(0.26,0.40,0.30),
		Color(0.48,0.32,0.22), Color(0.44,0.30,0.20), Color(0.52,0.36,0.26),
		Color(0.68,0.30,0.22), Color(0.62,0.27,0.20), Color(0.72,0.34,0.26),
		Color(0.30,0.30,0.32)]
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
		if t == "cottage" or t == "house":
			yard_houses.append([b[0], b[1], w, d, float(b[4])])
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
var yard_houses: Array = []

func _build_smoke() -> void:
	if _chimney_pos.is_empty():
		return
	var sm := Node3D.new()
	sm.name = "Smoke"
	sm.set_script(load("res://scripts/smoke.gd"))
	add_child(sm)
	sm.setup(self, _chimney_pos)


var _lamp_mat: StandardMaterial3D

var road_index := {}       # Vector2i(32 м) -> Array[[ax,az,bx,bz,hw]] — заполняет roads.gd

## Точка ближе margin к полотну дороги (с учётом её полуширины)?
func near_road(x: float, z: float, margin: float) -> bool:
	var c := Vector2i(int(floor(x / 32.0)), int(floor(z / 32.0)))
	var p := Vector2(x, z)
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			for sg: Array in road_index.get(c + Vector2i(dx, dz), []):
				var a := Vector2(sg[0], sg[1]); var b := Vector2(sg[2], sg[3])
				var ab := b - a
				var t := clampf((p - a).dot(ab) / maxf(ab.length_squared(), 1e-6), 0.0, 1.0)
				if p.distance_to(a + ab * t) < float(sg[4]) + margin:
					return true
	return false


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
var _quality_from_flag := false
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
			_quality_from_flag = true            # флаг не должен перезаписывать сохранённый выбор игрока


func apply_quality(q: int) -> void:
	quality = clampi(q, 0, 2)
	var vp := get_viewport()
	var forest := get_node_or_null("Forest")
	var grass := get_node_or_null("Grass")
	match quality:
		0:
			vp.scaling_3d_scale = 0.7
			vp.use_taa = false
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			sun.shadow_enabled = false
			environment.ssr_enabled = false
			environment.glow_enabled = false
			environment.ssao_enabled = false
			environment.ssil_enabled = false
			environment.volumetric_fog_enabled = valley_fog != null and valley_fog.enabled
			if forest != null: forest.radius = 1400.0
			if grass != null: grass.enabled = false
			if props != null: props.pool = 6
		1:
			vp.scaling_3d_scale = 1.0
			vp.use_taa = true
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 2500.0
			environment.ssr_enabled = false
			environment.glow_enabled = true
			environment.ssao_enabled = true
			environment.ssil_enabled = false
			environment.volumetric_fog_enabled = valley_fog != null and valley_fog.enabled
			if forest != null: forest.radius = 2200.0
			if grass != null: grass.enabled = true; grass.radius = 45.0
			if props != null: props.pool = 12
		2:
			vp.scaling_3d_scale = 1.0
			vp.use_taa = true
			vp.screen_space_aa = Viewport.SCREEN_SPACE_AA_FXAA
			sun.shadow_enabled = true
			sun.directional_shadow_max_distance = 3500.0
			environment.ssr_enabled = true
			environment.glow_enabled = true
			environment.ssao_enabled = true
			environment.ssil_enabled = false          # SSIL дорог (−5–8 FPS), выигрыш малозаметен
			environment.volumetric_fog_enabled = valley_fog != null and valley_fog.enabled
			if forest != null: forest.radius = 3000.0
			if grass != null: grass.enabled = true; grass.radius = 70.0
			if props != null: props.pool = 24
	if not _quality_from_flag:
		var cfg := ConfigFile.new()
		cfg.load(SETTINGS_PATH)
		cfg.set_value("video", "quality", quality)
		cfg.save(SETTINGS_PATH)
	print("Качество: ", QUALITY_NAMES[quality])


# ======================= Столкновения, краш, HUD =======================
var collision: RefCounted
var crashed := false
var _home_pos := Vector3.ZERO
var hud: CanvasLayer
# ссылки на элементы HUD, которыми пользуются другие модули (mission, telemetry, debug)
var _crash_label: Label
var _fpv_osd: Control
var _result_label: Label
var _replay_label: Label


func _build_hud() -> void:
	hud = CanvasLayer.new()
	hud.name = "HUD"
	hud.set_script(load("res://scripts/hud.gd"))
	add_child(hud)
	hud.setup(self)
	_crash_label = hud._crash_label
	_fpv_osd = hud._fpv_osd
	_result_label = hud._result_label
	_replay_label = hud._replay_label


# --- тонкие обёртки над collision.gd (интерфейс для scatter/props/mission/flycam не менялся) ---
func col_add_box(cx: float, cz: float, w: float, d: float, ang: float, top: float) -> void:
	collision.col_add_box(cx, cz, w, d, ang, top)

func col_add_cyl(x: float, z: float, r: float, top: float) -> void:
	collision.col_add_cyl(x, z, r, top)

func col_register_trees(chunk: Vector2i, arr: Array) -> void:
	collision.col_register_trees(chunk, arr)

func col_unregister_trees(chunk: Vector2i) -> void:
	collision.col_unregister_trees(chunk)

func check_crash(pos: Vector3) -> String:
	return collision.check_crash(pos)

func los_factor(op: Vector3, drone: Vector3) -> float:
	return collision.los_factor(op, drone)


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
	if targets != null:
		targets.reset_ammo()
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
	if "--noforest" in OS.get_cmdline_user_args():
		return
	if not FileAccess.file_exists(ProjectSettings.globalize_path(asset_path("mask.png"))) \
			and not ResourceLoader.exists(asset_path("mask.png")):
		return
	var forest := Node3D.new()
	forest.name = "Forest"
	forest.set_script(load("res://scripts/scatter.gd"))
	add_child(forest)
	forest.setup(self)


func _build_yards() -> void:
	if yard_houses.is_empty() or "--noyards" in OS.get_cmdline_user_args():
		return
	var y := Node3D.new()
	y.name = "Yards"
	y.set_script(load("res://scripts/yards.gd"))
	add_child(y)
	y.setup(self, yard_houses)


func _build_grass() -> void:
	if "--nograss" in OS.get_cmdline_user_args():
		return
	var g := Node3D.new()
	g.name = "Grass"
	g.set_script(load("res://scripts/grass.gd"))
	add_child(g)
	g.setup(self)


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


var traffic: Node3D

func _build_traffic() -> void:
	if "--notraffic" in OS.get_cmdline_user_args():
		return
	traffic = Node3D.new()
	traffic.name = "Traffic"
	traffic.set_script(load("res://scripts/traffic.gd"))
	add_child(traffic)
	traffic.setup(self)


var thermal: Node

func _build_thermal() -> void:
	thermal = Node.new()
	thermal.name = "Thermal"
	thermal.set_script(load("res://scripts/thermal.gd"))
	add_child(thermal)
	thermal.setup(self)


var ew: Node3D

func _build_ew() -> void:
	ew = Node3D.new()
	ew.name = "EW"
	ew.set_script(load("res://scripts/ew.gd"))
	add_child(ew)
	ew.setup(self)


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
	sky.radiance_size = Sky.RADIANCE_SIZE_256
	var env := Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	# тонмаппинг: ACES (кино-кривая, естественные света и небо), без «мультяшной» яркости
	env.tonemap_mode = Environment.TONE_MAPPER_AGX
	env.tonemap_white = 4.0
	env.tonemap_exposure = 1.0
	env.adjustment_enabled = true
	env.adjustment_brightness = 1.0
	env.adjustment_contrast = 1.06
	env.adjustment_saturation = 1.0
	# bloom / свечение (окна, фонари, солнце, закат) — мягкий, HDR-порог
	env.glow_enabled = true
	env.glow_intensity = 0.35
	env.glow_bloom = 0.05
	env.glow_hdr_threshold = 1.15
	env.glow_hdr_scale = 2.0
	env.glow_blend_mode = Environment.GLOW_BLEND_MODE_SOFTLIGHT
	# контактные тени в складках/у домов/под кронами
	env.ssao_enabled = true
	env.ssao_radius = 2.0
	env.ssao_intensity = 1.6
	env.ssao_power = 1.5
	env.ssao_detail = 0.5
	env.ssao_light_affect = 0.2
	env.ssao_ao_channel_affect = 0.0
	# непрямое освещение с экрана — мягче тени под навесами, чуть цвета от земли
	env.ssil_enabled = true
	env.ssil_radius = 4.0
	env.ssil_intensity = 0.8
	# отражения: небо как источник + SSR (берега/дома в воде)
	env.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	env.ssr_enabled = true
	env.ssr_max_steps = 48
	env.ssr_fade_in = 0.2
	env.ssr_fade_out = 4.0
	env.fog_enabled = not ("--nofog" in OS.get_cmdline_user_args())
	env.fog_light_color = Color(0.78, 0.84, 0.92)
	env.fog_density = 0.0000015
	env.fog_sky_affect = 0.0
	env.fog_aerial_perspective = 0.7
	# объёмная дымка: лучи солнца сквозь кроны/дым, воздушная перспектива на средних дистанциях
	env.volumetric_fog_enabled = true
	env.volumetric_fog_density = 0.00008
	env.volumetric_fog_albedo = Color(0.9, 0.93, 1.0)
	env.volumetric_fog_length = 4000.0
	env.volumetric_fog_detail_spread = 1.6
	env.volumetric_fog_sky_affect = 0.0
	env.volumetric_fog_ambient_inject = 0.15
	environment = env
	var we := WorldEnvironment.new(); we.environment = env
	add_child(we)

	# текстура теней облаков — глобальный uniform для всех шейдеров поверхностей
	var cn := FastNoiseLite.new()
	cn.noise_type = FastNoiseLite.TYPE_SIMPLEX
	cn.frequency = 0.010
	cn.fractal_octaves = 4
	cn.seed = 7
	var cimg := cn.get_seamless_image(512, 512)
	cimg.generate_mipmaps()
	RenderingServer.global_shader_parameter_set("cloud_shadow_tex", ImageTexture.create_from_image(cimg))
	RenderingServer.global_shader_parameter_set("cloud_shadow_params", Vector4(0, 0, 0.4, 0.0004))

	sun = DirectionalLight3D.new()
	sun.rotation_degrees = Vector3(-38, -125, 0)
	sun.light_energy = 1.3
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.light_angular_distance = 0.53           # реальный угловой размер солнца → мягкие края теней
	sun.shadow_enabled = true
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS   # 2 каскада: −40 % треугольников, +10 FPS; при 4096 px и 3.5 км хватает
	sun.directional_shadow_split_1 = 0.03
	sun.directional_shadow_split_2 = 0.10
	sun.directional_shadow_split_3 = 0.32
	sun.directional_shadow_blend_splits = true
	sun.directional_shadow_max_distance = 6000.0
	sun.directional_shadow_fade_start = 0.85
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.6
	sun.shadow_opacity = 0.92
	add_child(sun)


var valley_fog: Node3D

func _build_valley_fog() -> void:
	valley_fog = Node3D.new()
	valley_fog.name = "ValleyFog"
	valley_fog.set_script(load("res://scripts/valley_fog.gd"))
	add_child(valley_fog)
	valley_fog.setup(self)


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
		# старт: базовый регион — над Ворохтой, низко над долиной с дорогой; иначе — start_lat/lon из meta
		var slat := float(meta.get("start_lat", 48.2839))
		var slon := float(meta.get("start_lon", 24.5610))
		var v := _world_from_latlon(slat, slon)
		var ground := height_at(v.x, v.y)
		cam.position = Vector3(v.x, ground + 220.0, v.y)
		add_child(cam)
		var tgt := _world_from_latlon(slat - 0.019, slon + 0.005)  # ~2 км на юг
		cam.look_at(Vector3(tgt.x, height_at(tgt.x, tgt.y) + 60.0, tgt.y))
	cam.set("main", self)
	cam.make_current()
	_home_pos = cam.position


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_M:
			hud._toggle_sound()
		elif event.keycode == KEY_F:
			hud._toggle_fpv()
		elif event.keycode == KEY_R and crashed:
			_respawn()
		elif event.keycode == KEY_G:
			_quality_from_flag = false
			apply_quality((quality + 1) % 3)
		elif event.keycode == KEY_T or event.keycode == KEY_C:
			if hud.fpv_link != null:
				if not hud.fpv_on:
					hud._toggle_fpv()          # камеры — это FPV-картинка
				if event.keycode == KEY_C:
					hud.fpv_link.set_camera(hud.fpv_link.camera + 1)
				else:
					hud.fpv_link.set_camera(3 if hud.fpv_link.camera != 3 else 0)
		elif event.keycode == KEY_Y and thermal != null:
			thermal.cycle_palette()


func _latlon_at(x: float, z: float) -> Vector2:
	var n_tiles := float(meta.get("n_tiles", 8))
	var two_z := pow(2.0, float(meta["zoom"]))
	var tx := float(meta["tile_x0"]) + (x / size_m + 0.5) * n_tiles
	var ty := float(meta["tile_y0"]) + (z / size_m + 0.5) * n_tiles
	var lon := tx / two_z * 360.0 - 180.0
	var lat := rad_to_deg(atan(sinh(PI * (1.0 - 2.0 * ty / two_z))))
	return Vector2(lat, lon)



var selftest: Node

func _build_selftest() -> void:
	selftest = Node.new()
	selftest.name = "SelfTest"
	selftest.set_script(load("res://scripts/selftest.gd"))
	add_child(selftest)
	selftest.setup(self)


var debug: Node

func _build_debug() -> void:
	debug = Node.new()
	debug.name = "Debug"
	debug.set_script(load("res://scripts/debug.gd"))
	add_child(debug)
	debug.setup(self)
