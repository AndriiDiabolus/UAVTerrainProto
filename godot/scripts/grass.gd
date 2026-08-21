extends Node3D
## Трава у земли: пучки-кросс-карты на дрожащей сетке вокруг камеры (радиус `radius`),
## только вне дорог/застройки/леса по маске, только на пологом; пересобирается при смещении камеры.
## Видна только на малой высоте (AGL < 160 м) — иначе бессмысленна и жрёт кадры.

var main: Node3D
var enabled := true
var radius := 70.0
const SPACING := 1.15
var mask: Image
var mpx: int
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _mat: ShaderMaterial
var _rocks: MultiMesh
var _last_center := Vector3(1e9, 0, 1e9)
var _acc := 0.0
# инкрементальная пересборка: обходим сетку порциями по кадрам, чтобы не было микрофризов
var _job_active := false
var _job_center := Vector3.ZERO
var _job_i := 0
var _job_n := 0
var _job_xf: Array[Transform3D] = []
var _job_col: Array[Color] = []
var _job_cust: Array[Color] = []
var _job_rocks: Array[Transform3D] = []
var _yards: Node = null
const JOB_BUDGET := 900           # точек сетки за кадр
var _cur_dir := Vector2(1, 0)
var _cur_str := 0.2


func setup(m: Node3D) -> void:
	main = m
	mask = main.load_image(main.asset_path("mask.png"))
	if mask != null:
		mpx = mask.get_width()
	_mat = ShaderMaterial.new()
	_mat.shader = load("res://scripts/grass.gdshader")
	_mat.set_shader_parameter("tex", _grass_tex())
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, _clump_arrays(1.5, 0.62))
	mesh.surface_set_material(0, _mat)
	_mat.set_shader_parameter("sat_tex", main._load_albedo())
	_mat.set_shader_parameter("world_size", main.size_m)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.use_custom_data = true
	_mm.mesh = mesh
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)
	# камни — мелкий клаттер
	var rm := SphereMesh.new(); rm.radius = 1.0; rm.height = 2.0; rm.radial_segments = 7; rm.rings = 4
	var rmat := StandardMaterial3D.new()
	rmat.albedo_color = Color(0.42, 0.40, 0.36)
	rmat.roughness = 0.95
	rm.material = rmat
	_rocks = MultiMesh.new()
	_rocks.transform_format = MultiMesh.TRANSFORM_3D
	_rocks.mesh = rm
	var rmi := MultiMeshInstance3D.new()
	rmi.multimesh = _rocks
	add_child(rmi)


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
	if main == null or main.cam == null or _mm == null:
		return
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
	_mmi.visible = show
	if not show:
		return
	if _job_active:
		_job_step()
		return
	_acc += dt
	if _acc < 0.15:
		return
	_acc = 0.0
	if Vector2(p.x - _last_center.x, p.z - _last_center.z).length() < 5.0:
		return
	_last_center = p
	_start_job(p)


func _start_job(center: Vector3) -> void:
	_mat.set_shader_parameter("fade_start", radius * 0.55)
	_mat.set_shader_parameter("fade_end", radius)
	_job_center = center
	_job_i = 0
	_job_n = int(radius / SPACING)
	_job_xf = []; _job_col = []; _job_cust = []; _job_rocks = []
	_yards = main.get_node_or_null("Yards")
	_job_active = true


## Порция сетки за кадр; по завершении — атомарная подмена MultiMesh.
func _job_step() -> void:
	var n := _job_n
	var side := 2 * n + 1
	var total := side * side
	var center := _job_center
	var half: float = main.size_m * 0.5
	var cx := floorf(center.x / SPACING) * SPACING
	var cz := floorf(center.z / SPACING) * SPACING
	var xf := _job_xf; var col := _job_col; var cust := _job_cust; var rocks := _job_rocks
	var end := mini(_job_i + JOB_BUDGET, total)
	for idx in range(_job_i, end):
			var i := idx / side - n
			var j := idx % side - n
			var gx := cx + i * SPACING; var gz := cz + j * SPACING
			# детерминированный джиттер от координат ячейки — сетка не «ползёт» за камерой
			var hsh := int(gx * 3.7) * 73856093 ^ int(gz * 3.7) * 19349663
			var r1 := float((hsh & 1023)) / 1023.0
			var r2 := float(((hsh >> 10) & 1023)) / 1023.0
			var r3 := float(((hsh >> 20) & 1023)) / 1023.0
			var wx := gx + (r1 - 0.5) * SPACING; var wz := gz + (r2 - 0.5) * SPACING
			if Vector2(wx - center.x, wz - center.z).length() > radius:
				continue
			if absf(wx) >= half or absf(wz) >= half:
				continue
			var mv := 5
			if mask != null:
				var mx := int((wx / main.size_m + 0.5) * (mpx - 1))
				var mz := int((wz / main.size_m + 0.5) * (mpx - 1))
				mv = int(round(mask.get_pixel(mx, mz).r * 255.0))
				if mv == 2 or mv == 7:    # дорога / вода
					continue
			# вид пучка по биому: луг — злаки/широкие/цветущие, пашня — сухостой реже, лес — редкий подлесок, кустарник — сухой
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
			# полотно дороги (+1 м обочина); в застройке — внутри зданий и на грядках не растим
			if main.near_road(wx, wz, 1.0):
				continue
			var gy: float = main.height_at(wx, wz)
			if mv == 3:
				if main.check_crash(Vector3(wx, gy + 0.6, wz)) != "":
					continue
				if _yards != null and _yards.in_garden(wx, wz):
					continue
			# склон: не растим на крутом
			var e := 3.0
			var dy := absf(main.height_at(wx + e, wz) - main.height_at(wx - e, wz)) + absf(main.height_at(wx, wz + e) - main.height_at(wx, wz - e))
			if dy > 4.0:
				continue
			var s := 0.75 + r3 * 0.6
			var basis := Basis(Vector3.UP, r1 * TAU).scaled(Vector3(s, s, s))
			xf.append(Transform3D(basis, Vector3(wx, gy - 0.02, wz)))
			col.append(Color(0.9 + r2 * 0.25, 0.85 + r3 * 0.2, 0.75 + r1 * 0.3))
			cust.append(Color(float(variant), 0, 0, 0))
			# камни: редко на лугах/голой земле, чаще у воды
			var rock_p := 0.012 if mv == 5 else (0.05 if mv == 8 else 0.004)
			if r1 * 0.37 + r2 * 0.63 < rock_p:
				var rs := 0.12 + r3 * 0.35
				rocks.append(Transform3D(Basis(Vector3.UP, r2 * TAU).scaled(Vector3(rs * 1.4, rs * 0.7, rs)), Vector3(wx + 0.6, gy - rs * 0.25, wz - 0.4)))
	_job_i = end
	if _job_i < total:
		return
	_job_active = false
	_mm.instance_count = xf.size()
	for i in xf.size():
		_mm.set_instance_transform(i, xf[i])
		_mm.set_instance_color(i, col[i])
		_mm.set_instance_custom_data(i, cust[i])
	if _rocks != null:
		_rocks.instance_count = rocks.size()
		for i in rocks.size():
			_rocks.set_instance_transform(i, rocks[i])
