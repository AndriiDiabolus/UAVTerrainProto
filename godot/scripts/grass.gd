extends Node3D
## Трава у земли: пучки-кросс-карты на дрожащей сетке вокруг камеры (радиус `radius`),
## только вне дорог/застройки/леса по маске, только на пологом; пересобирается при смещении камеры.
## Видна только на малой высоте (AGL < 160 м) — иначе бессмысленна и жрёт кадры.

var main: Node3D
var enabled := true
var radius := 70.0
const SPACING := 1.4
var mask: Image
var mpx: int
var _mm: MultiMesh
var _mmi: MultiMeshInstance3D
var _mat: ShaderMaterial
var _last_center := Vector3(1e9, 0, 1e9)
var _acc := 0.0
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
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_colors = true
	_mm.mesh = mesh
	_mmi = MultiMeshInstance3D.new()
	_mmi.multimesh = _mm
	_mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_mmi)


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


## Процедурная текстура пучка: ~18 сужающихся к верху травинок с изгибом, светлее к кончику.
func _grass_tex() -> ImageTexture:
	var S := 128
	var img := Image.create(S, S, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var rng := RandomNumberGenerator.new(); rng.seed = 7
	for b in 18:
		var x0 := rng.randf_range(0.30, 0.70)
		var top := rng.randf_range(0.05, 0.35)          # y кончика (0 = верх)
		var bend := rng.randf_range(-0.28, 0.28)
		var wid := rng.randf_range(0.022, 0.04)
		var lum := rng.randf_range(0.7, 1.15)
		var steps := 90
		for k in steps:
			var t := k / float(steps - 1)               # 0 у корня, 1 у кончика
			var y := lerpf(1.0, top, t)
			var x := x0 + bend * t * t
			var w := wid * (1.0 - t * 0.85)
			var l := lum * (0.55 + 0.6 * t)
			var px0 := int((x - w) * S); var px1 := int((x + w) * S)
			var py := int(y * (S - 1))
			for px in range(maxi(px0, 0), mini(px1, S - 1) + 1):
				img.set_pixel(px, py, Color(l * 0.86, l * 0.9, l * 0.5, 1.0))
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
	_acc += dt
	if _acc < 0.15:
		return
	_acc = 0.0
	if Vector2(p.x - _last_center.x, p.z - _last_center.z).length() < 5.0:
		return
	_last_center = p
	_rebuild(p)


func _rebuild(center: Vector3) -> void:
	_mat.set_shader_parameter("fade_start", radius * 0.55)
	_mat.set_shader_parameter("fade_end", radius)
	var xf: Array[Transform3D] = []
	var col: Array[Color] = []
	var n := int(radius / SPACING)
	var half: float = main.size_m * 0.5
	var cx := floorf(center.x / SPACING) * SPACING
	var cz := floorf(center.z / SPACING) * SPACING
	for i in range(-n, n + 1):
		for j in range(-n, n + 1):
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
			if mask != null:
				var mx := int((wx / main.size_m + 0.5) * (mpx - 1))
				var mz := int((wz / main.size_m + 0.5) * (mpx - 1))
				var mv := int(round(mask.get_pixel(mx, mz).r * 255.0))
				if mv == 2 or mv == 3:          # дорога / застройка
					continue
			var gy: float = main.height_at(wx, wz)
			# склон: не растим на крутом
			var e := 3.0
			var dy := absf(main.height_at(wx + e, wz) - main.height_at(wx - e, wz)) + absf(main.height_at(wx, wz + e) - main.height_at(wx, wz - e))
			if dy > 4.0:
				continue
			var s := 0.75 + r3 * 0.6
			var basis := Basis(Vector3.UP, r1 * TAU).scaled(Vector3(s, s, s))
			xf.append(Transform3D(basis, Vector3(wx, gy - 0.02, wz)))
			col.append(Color(0.9 + r2 * 0.25, 0.85 + r3 * 0.2, 0.75 + r1 * 0.3))
	_mm.instance_count = xf.size()
	for i in xf.size():
		_mm.set_instance_transform(i, xf[i])
		_mm.set_instance_color(i, col[i])
