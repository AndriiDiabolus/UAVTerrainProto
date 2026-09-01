extends RefCounted
## Библиотека детальных юнитов (варианты для согласования и боевого использования).
## Все меши процедурные: примитивы + SurfaceTool, камуфляж — процедурные текстуры (triplanar).
## Юниты смотрят в +X. Ключи: tank1..4, apc1..3, sold1..3, civ1..3 (наборы жителей).

var _tex_cache := {}
var _mat_cache := {}


# ============================ общие помощники ============================

func _mat(color: Color) -> StandardMaterial3D:
	if _mat_cache.has(color):
		return _mat_cache[color]
	var mt := StandardMaterial3D.new()
	mt.albedo_color = color
	mt.roughness = 0.92
	_mat_cache[color] = mt
	return mt


func _append(mesh: ArrayMesh, prim: PrimitiveMesh, xform: Transform3D, color: Color) -> void:
	_append_arrays(mesh, prim.get_mesh_arrays(), xform, _mat(color))


func _append_tex(mesh: ArrayMesh, prim: PrimitiveMesh, xform: Transform3D, tex: Texture2D, scale := 0.45) -> void:
	_append_arrays(mesh, prim.get_mesh_arrays(), xform, _mat_tex(tex, scale))


func _append_mesh(dst: ArrayMesh, src: ArrayMesh, xform: Transform3D, color: Color) -> void:
	for s in src.get_surface_count():
		_append_arrays(dst, src.surface_get_arrays(s), xform, _mat(color))


func _append_arrays(mesh: ArrayMesh, arr: Array, xform: Transform3D, mt: Material) -> void:
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	var v2 := PackedVector3Array(); v2.resize(verts.size())
	var n2 := PackedVector3Array(); n2.resize(norms.size())
	for i in verts.size():
		v2[i] = xform * verts[i]
	for i in norms.size():
		n2[i] = xform.basis * norms[i]
	var out := []
	out.resize(Mesh.ARRAY_MAX)
	out[Mesh.ARRAY_VERTEX] = v2
	out[Mesh.ARRAY_NORMAL] = n2
	if arr[Mesh.ARRAY_INDEX] != null:
		out[Mesh.ARRAY_INDEX] = arr[Mesh.ARRAY_INDEX]
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, out)
	mesh.surface_set_material(mesh.get_surface_count() - 1, mt)


func _box(sx: float, sy: float, sz: float) -> BoxMesh:
	var b := BoxMesh.new(); b.size = Vector3(sx, sy, sz); return b


func _cyl(r: float, h: float, r2 := -1.0) -> CylinderMesh:
	var c := CylinderMesh.new()
	c.top_radius = r; c.bottom_radius = r if r2 < 0.0 else r2; c.height = h
	c.radial_segments = 10; c.rings = 1
	return c


func _sph(r: float, hemi := false) -> SphereMesh:
	var s := SphereMesh.new()
	s.radius = r; s.height = r * (1.0 if hemi else 2.0); s.is_hemisphere = hemi
	s.radial_segments = 10; s.rings = 5
	return s


## Бокс-«конечность» от точки a к точке b толщиной w (ориентируется вдоль отрезка).
func _limb(m: ArrayMesh, a: Vector3, b: Vector3, w: float, color: Color) -> void:
	_append_arrays(m, _box(w, a.distance_to(b), w).get_mesh_arrays(), _limb_xf(a, b), _mat(color))


func _limb_tex(m: ArrayMesh, a: Vector3, b: Vector3, w: float, tex: Texture2D) -> void:
	var mt := _mat_tex(tex, 1.6)
	_append_arrays(m, _box(w, a.distance_to(b), w).get_mesh_arrays(), _limb_xf(a, b), mt)


func _limb_xf(a: Vector3, b: Vector3) -> Transform3D:
	var y := (b - a).normalized()
	var helper := Vector3.FORWARD if absf(y.dot(Vector3.FORWARD)) < 0.9 else Vector3.RIGHT
	var x := y.cross(helper).normalized()
	var z := x.cross(y)
	return Transform3D(Basis(x, y, z), (a + b) * 0.5)


## Rx/Ry/Rz — короткие повороты.
func _rx(a: float) -> Basis: return Basis(Vector3.RIGHT, a)
func _ry(a: float) -> Basis: return Basis(Vector3.UP, a)
func _rz(a: float) -> Basis: return Basis(Vector3.BACK, a)


## Камуфляж: base + пятна цветов blots. pixel=true — «пиксель» (ММ-14), иначе крупные кляксы.
func camo_tex(base: Color, blots: Array, seed_v: int, pixel: bool) -> ImageTexture:
	var key := [base, blots, seed_v, pixel]
	if _tex_cache.has(key):
		return _tex_cache[key]
	var S := 128
	var img := Image.create(S, S, false, Image.FORMAT_RGB8)
	img.fill(base)
	var rng := RandomNumberGenerator.new(); rng.seed = seed_v
	if pixel:
		var cell := 4
		for by in range(0, S, cell):
			for bx in range(0, S, cell):
				var r := rng.randf()
				if r < 0.42:
					var c: Color = blots[rng.randi_range(0, blots.size() - 1)]
					for yy in range(by, mini(by + cell, S)):
						for xx in range(bx, mini(bx + cell, S)):
							img.set_pixel(xx, yy, c)
	else:
		for k in 26:
			var c: Color = blots[rng.randi_range(0, blots.size() - 1)]
			var cx := rng.randf() * S; var cy := rng.randf() * S
			var rx2 := rng.randf_range(9.0, 26.0); var ry2 := rng.randf_range(7.0, 18.0)
			var ang := rng.randf() * PI
			for yy in range(maxi(0, int(cy - 30)), mini(S, int(cy + 30))):
				for xx in range(maxi(0, int(cx - 30)), mini(S, int(cx + 30))):
					var dx := (xx - cx) * cos(ang) + (yy - cy) * sin(ang)
					var dy := -(xx - cx) * sin(ang) + (yy - cy) * cos(ang)
					if (dx * dx) / (rx2 * rx2) + (dy * dy) / (ry2 * ry2) < 1.0:
						img.set_pixel(xx, yy, c)
	var t := ImageTexture.create_from_image(img)
	_tex_cache[key] = t
	return t


func _sloped_box(size: Vector3, slope: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var hx := size.x * 0.5; var hy := size.y * 0.5; var hz := size.z * 0.5
	var fx := hx - slope
	var p := [Vector3(-hx, -hy, -hz), Vector3(hx, -hy, -hz), Vector3(hx, -hy, hz), Vector3(-hx, -hy, hz),
		Vector3(-hx, hy, -hz), Vector3(fx, hy, -hz), Vector3(fx, hy, hz), Vector3(-hx, hy, hz)]
	_quad(st, p[0], p[3], p[2], p[1])
	_quad(st, p[4], p[5], p[6], p[7])
	_quad(st, p[1], p[2], p[6], p[5])
	_quad(st, p[0], p[4], p[7], p[3])
	_quad(st, p[0], p[1], p[5], p[4])
	_quad(st, p[2], p[3], p[7], p[6])
	st.index()
	return st.commit()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var nrm := (b - a).cross(c - a).normalized()
	for p: Vector3 in [a, b, c, a, c, d]:
		st.set_normal(nrm); st.add_vertex(p)


# камуфляжи
func camo_green() -> ImageTexture:
	return camo_tex(Color(0.34, 0.37, 0.23), [Color(0.24, 0.28, 0.16), Color(0.20, 0.19, 0.13)], 7, false)
func camo_pixel() -> ImageTexture:   # ММ-14 «пиксель»
	return camo_tex(Color(0.42, 0.42, 0.33), [Color(0.28, 0.31, 0.2), Color(0.2, 0.22, 0.15), Color(0.5, 0.47, 0.36)], 11, true)
func camo_multicam() -> ImageTexture:
	return camo_tex(Color(0.45, 0.41, 0.3), [Color(0.3, 0.32, 0.2), Color(0.55, 0.48, 0.34), Color(0.25, 0.24, 0.18)], 21, false)
func camo_faded() -> ImageTexture:   # выцветший/пыльный
	return camo_tex(Color(0.42, 0.4, 0.3), [Color(0.35, 0.33, 0.24), Color(0.47, 0.44, 0.34)], 31, false)


# ============================ ТАНК (варианты 1–4) ============================

const T_TRACK := Color(0.12, 0.12, 0.11)
const T_STEEL := Color(0.2, 0.21, 0.18)
const T_RUBBER := Color(0.08, 0.08, 0.08)

## База шасси: корпус, гусеницы, катки, полки, юбки.
func _tank_chassis(m: ArrayMesh, hull_tex: Texture2D, dirty: bool) -> void:
	_append_tex(m, _box(6.4, 0.9, 2.7), Transform3D(Basis(), Vector3(0, 0.95, 0)), hull_tex)
	_append_mesh(m, _sloped_box(Vector3(6.2, 0.75, 2.7), 1.9), Transform3D(Basis(), Vector3(0, 1.55, 0)), Color(1, 1, 1))
	# верхний корпус перекрашиваем текстурой (поверх _append_mesh цветного — заменим последнюю поверхность)
	m.surface_set_material(m.get_surface_count() - 1, _mat_tex(hull_tex))
	for fz in [1.5, -1.5]:
		_append(m, _box(6.6, 0.12, 0.55), Transform3D(Basis(), Vector3(0, 1.35, fz)), Color(0.24, 0.26, 0.17))
	# резиновые юбки (грязный низ при dirty)
	for fz in [1.62, -1.62]:
		_append(m, _box(6.4, 0.5, 0.06), Transform3D(Basis(), Vector3(0, 1.05, fz)),
			Color(0.16, 0.15, 0.11) if not dirty else Color(0.22, 0.19, 0.13))
	for fz in [1.42, -1.42]:
		_append(m, _box(6.8, 0.7, 0.7), Transform3D(Basis(), Vector3(0, 0.55, fz)), T_TRACK)
		for lx in range(-3, 4):
			_append(m, _box(0.16, 0.78, 0.78), Transform3D(Basis(), Vector3(lx * 0.9, 0.55, fz)), T_STEEL)
		for rx in [-2.55, -1.53, -0.51, 0.51, 1.53, 2.55]:
			_append(m, _cyl(0.5, 0.28), Transform3D(_rx(PI / 2), Vector3(rx, 0.55, fz)), T_RUBBER)
		for rx in [-3.15, 3.15]:
			_append(m, _cyl(0.42, 0.3), Transform3D(_rx(PI / 2), Vector3(rx, 0.75, fz)), T_STEEL)


func _mat_tex(tex: Texture2D, scale := 0.45) -> StandardMaterial3D:
	var key := [tex, scale]
	if _mat_cache.has(key):
		return _mat_cache[key]
	var mt := StandardMaterial3D.new()
	mt.albedo_texture = tex; mt.roughness = 0.92
	mt.uv1_triplanar = true; mt.uv1_scale = Vector3(scale, scale, scale)
	_mat_cache[key] = mt
	return mt


## Башня с пушкой, ДЗ, башенкой, корзиной, бочками, антеннами.
func _tank_top(m: ArrayMesh, hull_tex: Texture2D, era_on: bool, hatches_open: bool) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 8
	var top: Array[Vector3] = []; var bot: Array[Vector3] = []
	for i in n:
		var a := TAU * i / n + PI / n
		top.append(Vector3(cos(a) * 1.85 * 0.82, 0.475, sin(a) * 1.35 * 0.82))
		bot.append(Vector3(cos(a) * 1.85, -0.475, sin(a) * 1.35))
	for i in n:
		var j := (i + 1) % n
		_quad(st, bot[i], bot[j], top[j], top[i])
	var ct := Vector3(0, 0.475, 0); var cb := Vector3(0, -0.475, 0)
	for i in n:
		var j := (i + 1) % n
		var nrm := Vector3.UP
		st.set_normal(nrm); st.add_vertex(top[i]); st.set_normal(nrm); st.add_vertex(top[j]); st.set_normal(nrm); st.add_vertex(ct)
		nrm = Vector3.DOWN
		st.set_normal(nrm); st.add_vertex(bot[j]); st.set_normal(nrm); st.add_vertex(bot[i]); st.set_normal(nrm); st.add_vertex(cb)
	st.index()
	var turret := st.commit()
	for s in turret.get_surface_count():
		_append_arrays(m, turret.surface_get_arrays(s), Transform3D(Basis(), Vector3(-0.5, 2.35, 0)), _mat_tex(hull_tex))
	if era_on:
		for ez in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			_append(m, _box(0.5, 0.28, 0.4), Transform3D(_rz(-0.5), Vector3(2.9, 1.7, ez)), Color(0.32, 0.34, 0.21))
		for tz in [-0.85, -0.45, 0.45, 0.85]:
			_append(m, _box(0.5, 0.28, 0.4), Transform3D(_rz(-0.35), Vector3(0.95, 2.35, tz)), Color(0.32, 0.34, 0.21))
	_append(m, _box(0.9, 0.75, 1.3), Transform3D(Basis(), Vector3(1.15, 2.35, 0)), Color(0.26, 0.28, 0.18))
	_append(m, _cyl(0.2, 2.0, 0.22), Transform3D(_rz(PI / 2), Vector3(2.6, 2.35, 0)), T_STEEL)
	_append(m, _cyl(0.12, 3.0, 0.14), Transform3D(_rz(PI / 2), Vector3(4.9, 2.35, 0)), Color(0.1, 0.11, 0.09))
	_append(m, _cyl(0.24, 0.7), Transform3D(_rz(PI / 2), Vector3(4.3, 2.35, 0)), T_STEEL)
	_append(m, _cyl(0.17, 0.35), Transform3D(_rz(PI / 2), Vector3(6.3, 2.35, 0)), T_STEEL)
	_append(m, _cyl(0.42, 0.42, 0.46), Transform3D(Basis(), Vector3(-1.0, 3.05, 0.6)), Color(0.26, 0.28, 0.18))
	if hatches_open:
		_append(m, _cyl(0.4, 0.06), Transform3D(_rx(1.2), Vector3(-1.0, 3.35, 0.95)), Color(0.24, 0.26, 0.17))
		_append(m, _cyl(0.36, 0.06), Transform3D(_rx(-1.2), Vector3(-0.6, 2.95, -0.75)), Color(0.24, 0.26, 0.17))
	_append(m, _cyl(0.05, 1.1, 0.06), Transform3D(_rz(PI / 2.2), Vector3(-0.4, 3.35, 0.6)), T_RUBBER)
	_append(m, _box(1.2, 0.5, 1.9), Transform3D(Basis(), Vector3(-1.9, 2.3, 0)), Color(0.12, 0.13, 0.1))
	for dz in [0.7, -0.7]:
		_append(m, _cyl(0.28, 0.9), Transform3D(_rz(PI / 2), Vector3(-3.4, 1.6, dz)), Color(0.28, 0.3, 0.19))
	# бревно самовытаскивания на корме
	_append(m, _cyl(0.14, 2.4), Transform3D(_rx(PI / 2), Vector3(-3.15, 1.15, 0)), Color(0.32, 0.24, 0.15))
	for av in [Vector3(-1.8, 3.4, -0.7), Vector3(-1.9, 3.3, 0.7)]:
		_append(m, _cyl(0.015, 1.9, 0.03), Transform3D(Basis(), av), T_RUBBER)


## Козырёк-«мангал» против FPV: рама на стойках + продольные полосы.
func _tank_mangal(m: ArrayMesh) -> void:
	var c := Color(0.17, 0.18, 0.14)
	var y := 3.75
	_append(m, _box(4.6, 0.07, 0.07), Transform3D(Basis(), Vector3(-0.5, y, 1.55)), c)
	_append(m, _box(4.6, 0.07, 0.07), Transform3D(Basis(), Vector3(-0.5, y, -1.55)), c)
	_append(m, _box(0.07, 0.07, 3.1), Transform3D(Basis(), Vector3(1.8, y, 0)), c)
	_append(m, _box(0.07, 0.07, 3.1), Transform3D(Basis(), Vector3(-2.8, y, 0)), c)
	for k in 7:
		_append(m, _box(4.6, 0.03, 0.05), Transform3D(Basis(), Vector3(-0.5, y, -1.16 + k * 0.387)), c)
	for k in 5:
		_append(m, _box(0.05, 0.03, 3.1), Transform3D(Basis(), Vector3(-2.1 + k * 0.78, y + 0.02, 0)), c)
	for lp in [Vector3(1.2, 0, 1.1), Vector3(1.2, 0, -1.1), Vector3(-2.2, 0, 1.1), Vector3(-2.2, 0, -1.1)]:
		_append(m, _cyl(0.045, 1.0), Transform3D(Basis(), Vector3(lp.x, 3.25, lp.z)), c)


## Маскировка ветками: кросс-карты «листвы» цветными пятнами по башне и корпусу.
func _tank_masking(m: ArrayMesh) -> void:
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	for k in 12:
		var px := rng.randf_range(-2.6, 2.4)
		var pz := rng.randf_range(-1.3, 1.3)
		var py := 3.0 if absf(px + 0.5) < 1.9 else 2.35    # поверх башни/корпуса, не внутри
		var sc := rng.randf_range(0.7, 1.15)
		var col := Color(0.2 + rng.randf() * 0.09, 0.3 + rng.randf() * 0.1, 0.13)
		for q in 2:
			var b := _ry(rng.randf() * PI) * _rx(rng.randf_range(-0.6, 0.6))
			_append(m, _box(1.8 * sc, 0.7 * sc, 0.05), Transform3D(b, Vector3(px, py, pz)), col)


func tank(variant: int) -> ArrayMesh:
	var m := ArrayMesh.new()
	var tex: ImageTexture
	match variant:
		1: tex = camo_green()
		2: tex = camo_green()
		3: tex = camo_multicam()
		_: tex = camo_faded()
	_tank_chassis(m, tex, variant == 3)
	_tank_top(m, tex, variant != 4, variant == 4)
	if variant == 2:
		_tank_mangal(m)
	if variant == 3:
		_tank_masking(m)
	return m


# ============================ БТР (варианты 1–3) ============================

## БТР-80: корытообразный корпус (скосы верха и низа), волноотбойник, башенка КПВТ, 8 колёс.
func _btr80_hull(m: ArrayMesh, tex: Texture2D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# профиль корыта: низ уже, середина шире, верх уже (характерные скосы)
	var L := 7.4
	var x0 := -L * 0.5
	var x1 := L * 0.5
	var zb := 1.05      # низ
	var zm := 1.45      # середина (максимум)
	var zt := 1.0       # верх
	var yb := 0.75; var ym := 1.45; var yt := 2.15
	# нос заострён (стыкуем к точке-клину)
	var nose := 1.35
	# строим три «кольца» профиля по длине: корма, середина-перед, нос
	var xs := [x0, x1 - nose]
	var rings := []
	for x in xs:
		rings.append([Vector3(x, yb, -zb), Vector3(x, yb, zb), Vector3(x, ym, zm), Vector3(x, yt, zt),
			Vector3(x, yt, -zt), Vector3(x, ym, -zm)])
	# носовое кольцо — сжатое (клин)
	var xn := x1
	rings.append([Vector3(xn, yb + 0.25, -zb * 0.35), Vector3(xn, yb + 0.25, zb * 0.35), Vector3(xn, ym, zm * 0.4),
		Vector3(xn, yt - 0.15, zt * 0.35), Vector3(xn, yt - 0.15, -zt * 0.35), Vector3(xn, ym, -zm * 0.4)])
	for ri in range(rings.size() - 1):
		var a: Array = rings[ri]; var b: Array = rings[ri + 1]
		for i in 6:
			var j := (i + 1) % 6
			_quad(st, a[i], a[j], b[j], b[i])
	# крышки: корма и палуба
	var r0: Array = rings[0]
	_quad(st, r0[0], r0[5], r0[4], r0[3]); _quad(st, r0[0], r0[3], r0[2], r0[1])
	for ri in [rings.size() - 1]:
		var rl: Array = rings[ri]
		_quad(st, rl[1], rl[2], rl[3], rl[4]); _quad(st, rl[1], rl[4], rl[5], rl[0])
	# палуба (верхняя грань между кольцами)
	st.index()
	var hull := st.commit()
	for s in hull.get_surface_count():
		_append_arrays(m, hull.surface_get_arrays(s), Transform3D(), _mat_tex(tex))
	# палубный настил (закрывает верх)
	_append_tex(m, _box(L - nose, 0.06, 2.0), Transform3D(Basis(), Vector3(-nose * 0.5, 2.14, 0)), tex)
	# волноотбойник на носу
	_append(m, _box(0.12, 0.35, 1.6), Transform3D(_rz(0.5), Vector3(3.35, 1.95, 0)), Color(0.2, 0.22, 0.15))
	# колёса 8 шт: 2 пары спереди, 2 сзади (с зазором посредине)
	for wx in [2.45, 1.45, -1.05, -2.05]:
		for wz in [1.3, -1.3]:
			_append(m, _cyl(0.58, 0.4), Transform3D(_rx(PI / 2), Vector3(wx, 0.58, wz)), T_RUBBER)
			_append(m, _cyl(0.2, 0.42), Transform3D(_rx(PI / 2), Vector3(wx, 0.58, wz)), Color(0.17, 0.17, 0.15))
	# боковые люки десанта
	for hx in [-0.2]:
		_append(m, _box(0.9, 0.8, 0.06), Transform3D(Basis(), Vector3(hx, 1.55, 1.44)), Color(0.24, 0.26, 0.17))
		_append(m, _box(0.9, 0.8, 0.06), Transform3D(Basis(), Vector3(hx, 1.55, -1.44)), Color(0.24, 0.26, 0.17))
	# фары
	for fz in [0.55, -0.55]:
		_append(m, _cyl(0.09, 0.08), Transform3D(_rz(PI / 2), Vector3(3.6, 1.9, fz)), Color(0.75, 0.75, 0.7))


## Башенка БТР-80: усечённый конус + КПВТ 14.5 + ПКТ.
func _btr80_turret(m: ArrayMesh, tex: Texture2D) -> void:
	_append_tex(m, _cyl(0.55, 0.55, 0.75), Transform3D(Basis(), Vector3(0.7, 2.45, 0)), tex)
	_append(m, _cyl(0.06, 1.9, 0.08), Transform3D(_rz(PI / 2 - 0.06), Vector3(1.9, 2.55, 0)), Color(0.09, 0.1, 0.08))
	_append(m, _cyl(0.035, 1.0), Transform3D(_rz(PI / 2), Vector3(1.5, 2.4, 0.22)), Color(0.09, 0.1, 0.08))
	# перископы
	_append(m, _box(0.18, 0.1, 0.14), Transform3D(Basis(), Vector3(0.85, 2.85, 0.2)), Color(0.1, 0.1, 0.1))


## Антенны, канистры, ЗИП на палубе.
func _btr_deck_stuff(m: ArrayMesh) -> void:
	_append(m, _cyl(0.015, 1.7, 0.03), Transform3D(Basis(), Vector3(-2.6, 3.0, -0.7)), T_RUBBER)
	_append(m, _box(0.5, 0.35, 0.25), Transform3D(Basis(), Vector3(-2.2, 2.35, 0.6)), Color(0.3, 0.31, 0.2))
	_append(m, _box(0.6, 0.25, 0.4), Transform3D(Basis(), Vector3(-3.0, 2.32, -0.4)), Color(0.22, 0.24, 0.15))


func _btr_mangal(m: ArrayMesh) -> void:
	var c := Color(0.17, 0.18, 0.14)
	var y := 3.35
	_append(m, _box(5.4, 0.06, 0.06), Transform3D(Basis(), Vector3(-0.4, y, 1.25)), c)
	_append(m, _box(5.4, 0.06, 0.06), Transform3D(Basis(), Vector3(-0.4, y, -1.25)), c)
	_append(m, _box(0.06, 0.06, 2.5), Transform3D(Basis(), Vector3(2.3, y, 0)), c)
	_append(m, _box(0.06, 0.06, 2.5), Transform3D(Basis(), Vector3(-3.1, y, 0)), c)
	for k in 6:
		_append(m, _box(5.4, 0.025, 0.045), Transform3D(Basis(), Vector3(-0.4, y, -0.9 + k * 0.36)), c)
	for lp in [Vector3(1.9, 0, 0.9), Vector3(1.9, 0, -0.9), Vector3(-2.7, 0, 0.9), Vector3(-2.7, 0, -0.9)]:
		_append(m, _cyl(0.04, 1.1), Transform3D(Basis(), Vector3(lp.x, 2.8, lp.z)), c)


## БТР-4 «Буцефал»: угловатый высокий корпус + необитаемый модуль с 30-мм.
func _btr4(m: ArrayMesh, tex: Texture2D) -> void:
	_append_mesh(m, _sloped_box(Vector3(7.2, 1.7, 2.7), 1.7), Transform3D(Basis(), Vector3(0, 1.75, 0)), Color(1, 1, 1))
	m.surface_set_material(m.get_surface_count() - 1, _mat_tex(tex))
	_append_tex(m, _box(6.0, 0.5, 2.4), Transform3D(Basis(), Vector3(-0.5, 2.75, 0)), tex)
	# модуль БМ-7 «Парус»
	_append_tex(m, _box(1.5, 0.6, 1.3), Transform3D(Basis(), Vector3(0.4, 3.3, 0)), tex)
	_append(m, _cyl(0.07, 2.4, 0.09), Transform3D(_rz(PI / 2 - 0.04), Vector3(1.9, 3.35, 0.2)), Color(0.09, 0.1, 0.08))
	_append(m, _box(0.3, 0.35, 0.25), Transform3D(Basis(), Vector3(0.9, 3.65, -0.35)), Color(0.1, 0.1, 0.1))
	for wx in [2.6, 1.55, -1.15, -2.2]:
		for wz in [1.32, -1.32]:
			_append(m, _cyl(0.62, 0.45), Transform3D(_rx(PI / 2), Vector3(wx, 0.62, wz)), T_RUBBER)
			_append(m, _cyl(0.22, 0.47), Transform3D(_rx(PI / 2), Vector3(wx, 0.62, wz)), Color(0.17, 0.17, 0.15))
	# лобовое бронестекло
	_append(m, _box(0.08, 0.45, 1.6), Transform3D(_rz(0.45), Vector3(2.9, 2.6, 0)), Color(0.12, 0.14, 0.16))
	_append(m, _cyl(0.015, 1.7, 0.03), Transform3D(Basis(), Vector3(-2.9, 3.6, -0.7)), T_RUBBER)


func apc(variant: int) -> ArrayMesh:
	var m := ArrayMesh.new()
	match variant:
		1:
			_btr80_hull(m, camo_green()); _btr80_turret(m, camo_green()); _btr_deck_stuff(m)
		2:
			_btr80_hull(m, camo_green()); _btr80_turret(m, camo_green()); _btr_deck_stuff(m); _btr_mangal(m)
		_:
			_btr4(m, camo_pixel())
	return m


# ============================ СОЛДАТ (варианты 1–3) ============================

const SKIN := Color(0.72, 0.57, 0.45)

## Фигура с руками и оружием. pose: 0 — наперевес, 1 — на груди стволом вниз, 2 — шаг/дозор.
func _soldier_fig(m: ArrayMesh, uni_tex: Texture2D, vest_c: Color, helm_c: Color, pose: int, pack_big: bool) -> void:
	var boots := Color(0.12, 0.1, 0.08)
	var step := 0.14 if pose == 2 else 0.0
	# ботинки и ноги (при шаге — вперёд/назад)
	for side: float in [1.0, -1.0]:
		var lx := step * side
		_append(m, _box(0.27, 0.11, 0.13), Transform3D(Basis(), Vector3(lx + 0.03, 0.055, 0.1 * side)), boots)
		_limb_tex(m, Vector3(lx, 0.1, 0.1 * side), Vector3(0.0, 0.92, 0.09 * side), 0.16, uni_tex)
	# таз и торс
	_append_tex(m, _box(0.34, 0.2, 0.24), Transform3D(Basis(), Vector3(0, 0.98, 0)), uni_tex, 1.6)
	_append_tex(m, _box(0.4, 0.5, 0.24), Transform3D(Basis(), Vector3(0, 1.33, 0)), uni_tex, 1.6)
	# плитник + подсумки
	_append(m, _box(0.12, 0.38, 0.3), Transform3D(Basis(), Vector3(0.15, 1.34, 0)), vest_c)
	_append(m, _box(0.1, 0.34, 0.26), Transform3D(Basis(), Vector3(-0.16, 1.34, 0)), vest_c)
	for pz in [-0.09, 0.0, 0.09]:
		_append(m, _box(0.08, 0.14, 0.08), Transform3D(Basis(), Vector3(0.2, 1.12, pz)), vest_c * 0.85)
	# рюкзак
	if pack_big:
		_append(m, _box(0.3, 0.5, 0.34), Transform3D(Basis(), Vector3(-0.32, 1.32, 0)), Color(0.24, 0.26, 0.16))
	# голова
	_append(m, _sph(0.105), Transform3D(Basis(), Vector3(0, 1.62, 0)), SKIN)
	if pose == 2:
		# кепка
		_append(m, _cyl(0.115, 0.09), Transform3D(Basis(), Vector3(0, 1.71, 0)), helm_c)
		_append(m, _box(0.12, 0.02, 0.1), Transform3D(Basis(), Vector3(0.13, 1.7, 0)), helm_c)
	else:
		# каска с чехлом
		_append(m, _sph(0.145, true), Transform3D(Basis(), Vector3(0, 1.63, 0)), helm_c)
	# оружие и руки по позе
	var gun := Color(0.06, 0.06, 0.06)
	if pose == 1:
		# на груди стволом вниз, руки опущены
		_append(m, _box(0.08, 0.68, 0.06), Transform3D(_rz(0.5), Vector3(0.2, 1.2, 0.05)), gun)
		_append(m, _box(0.06, 0.16, 0.04), Transform3D(_rz(0.9), Vector3(0.22, 1.1, 0.05)), gun)
		for side: float in [1.0, -1.0]:
			_limb_tex(m, Vector3(0.0, 1.5, 0.23 * side), Vector3(0.06, 0.98, 0.26 * side), 0.1, uni_tex)
			_append(m, _sph(0.045), Transform3D(Basis(), Vector3(0.06, 0.96, 0.26 * side)), SKIN)
	else:
		# наперевес (pose 0) или у бедра в дозоре (pose 2)
		var gy := 1.28 if pose == 0 else 1.1
		var pitch := -0.08 if pose == 0 else 0.28
		_append(m, _box(0.72, 0.07, 0.05), Transform3D(_ry(0.12) * _rz(pitch), Vector3(0.3, gy, 0.06)), gun)
		_append(m, _box(0.05, 0.16, 0.04), Transform3D(_rz(0.7 + pitch), Vector3(0.28, gy - 0.1, 0.06)), gun)
		_append(m, _box(0.16, 0.05, 0.04), Transform3D(_rz(pitch), Vector3(0.02, gy - 0.02, 0.06)), Color(0.28, 0.2, 0.12))
		# правая рука к рукояти, левая к цевью
		_limb_tex(m, Vector3(0.0, 1.48, -0.2), Vector3(0.24, gy + 0.02, 0.0), 0.1, uni_tex)
		_limb_tex(m, Vector3(0.0, 1.48, 0.2), Vector3(0.44, gy + 0.04, 0.06), 0.1, uni_tex)
		_append(m, _sph(0.045), Transform3D(Basis(), Vector3(0.26, gy, 0.0)), SKIN)
		_append(m, _sph(0.045), Transform3D(Basis(), Vector3(0.44, gy + 0.02, 0.06)), SKIN)
	# наколенники
	for side: float in [1.0, -1.0]:
		_append(m, _sph(0.075, true), Transform3D(_rz(-PI / 2), Vector3(0.12 + step * side, 0.62, 0.1 * side)), vest_c * 0.9)


func soldier(variant: int) -> ArrayMesh:
	var m := ArrayMesh.new()
	match variant:
		1: _soldier_fig(m, camo_pixel(), Color(0.25, 0.27, 0.18), Color(0.3, 0.33, 0.22), 0, false)
		2: _soldier_fig(m, camo_green(), Color(0.22, 0.24, 0.16), Color(0.28, 0.3, 0.2), 1, true)
		_: _soldier_fig(m, camo_multicam(), Color(0.32, 0.28, 0.2), Color(0.36, 0.32, 0.22), 2, false)
	return m


# ============================ МИРНЫЕ ЖИТЕЛИ (наборы 1–3) ============================

## Мужчина: кепка, рубашка, тёмные штаны. walk: поза шага.
func civ_man(shirt: Color, walk: bool) -> ArrayMesh:
	var m := ArrayMesh.new()
	var pants := Color(0.2, 0.2, 0.24)
	var step := 0.13 if walk else 0.0
	for side: float in [1.0, -1.0]:
		_append(m, _box(0.25, 0.1, 0.12), Transform3D(Basis(), Vector3(step * side + 0.02, 0.05, 0.09 * side)), Color(0.14, 0.11, 0.09))
		_limb(m, Vector3(step * side, 0.09, 0.09 * side), Vector3(0.0, 0.95, 0.09 * side), 0.15, pants)
	_append(m, _box(0.36, 0.55, 0.22), Transform3D(Basis(), Vector3(0, 1.24, 0)), shirt)
	for side: float in [1.0, -1.0]:
		var sw := (0.3 if walk else 0.04) * side
		_limb(m, Vector3(0.0, 1.47, 0.2 * side), Vector3(sw, 0.96, 0.23 * side), 0.1, shirt)
		_append(m, _sph(0.045), Transform3D(Basis(), Vector3(sw, 0.94, 0.23 * side)), SKIN)
	_append(m, _sph(0.105), Transform3D(Basis(), Vector3(0, 1.62, 0)), SKIN)
	_append(m, _cyl(0.115, 0.08), Transform3D(Basis(), Vector3(0, 1.7, 0)), Color(0.3, 0.28, 0.24))
	_append(m, _box(0.11, 0.02, 0.1), Transform3D(Basis(), Vector3(0.12, 1.69, 0)), Color(0.3, 0.28, 0.24))
	return m


## Женщина: платок, кофта, юбка.
func civ_woman(blouse: Color, scarf: Color, walk: bool) -> ArrayMesh:
	var m := ArrayMesh.new()
	var step := 0.1 if walk else 0.0
	for side: float in [1.0, -1.0]:
		_append(m, _box(0.22, 0.09, 0.11), Transform3D(Basis(), Vector3(step * side, 0.045, 0.08 * side)), Color(0.16, 0.12, 0.1))
	_append(m, _cyl(0.16, 0.62, 0.3), Transform3D(Basis(), Vector3(0, 0.55, 0)), blouse * 0.55 + Color(0.15, 0.12, 0.14))
	_append(m, _box(0.34, 0.5, 0.22), Transform3D(Basis(), Vector3(0, 1.16, 0)), blouse)
	for side: float in [1.0, -1.0]:
		var sw := (0.26 if walk else 0.03) * side
		_limb(m, Vector3(0.0, 1.38, 0.19 * side), Vector3(sw, 0.92, 0.22 * side), 0.09, blouse)
		_append(m, _sph(0.04), Transform3D(Basis(), Vector3(sw, 0.9, 0.22 * side)), SKIN)
	_append(m, _sph(0.1), Transform3D(Basis(), Vector3(0, 1.52, 0)), SKIN)
	_append(m, _sph(0.125, true), Transform3D(Basis(), Vector3(-0.01, 1.51, 0)), scarf)
	_append(m, _box(0.06, 0.16, 0.1), Transform3D(_rz(0.5), Vector3(-0.11, 1.42, 0)), scarf)
	return m


## Бабушка с тележкой: сгорбленная фигура + двухколёсная тачка.
func civ_babushka() -> ArrayMesh:
	var m := ArrayMesh.new()
	var coat := Color(0.32, 0.26, 0.28)
	for side: float in [1.0, -1.0]:
		_append(m, _box(0.2, 0.08, 0.1), Transform3D(Basis(), Vector3(0, 0.04, 0.07 * side)), Color(0.15, 0.12, 0.1))
	_append(m, _cyl(0.15, 0.55, 0.27), Transform3D(Basis(), Vector3(0, 0.5, 0)), coat * 0.8)
	_append(m, _box(0.32, 0.44, 0.24), Transform3D(_rz(-0.35), Vector3(0.06, 1.02, 0)), coat)
	_append(m, _sph(0.095), Transform3D(Basis(), Vector3(0.2, 1.28, 0)), SKIN)
	_append(m, _sph(0.115, true), Transform3D(_rz(-0.3), Vector3(0.19, 1.28, 0)), Color(0.5, 0.42, 0.5))
	for side: float in [1.0, -1.0]:
		_append(m, _box(0.08, 0.42, 0.08), Transform3D(_rz(-0.9), Vector3(0.3, 1.0, 0.16 * side)), coat)
	# тележка
	_append(m, _box(0.45, 0.5, 0.35), Transform3D(Basis(), Vector3(0.62, 0.45, 0)), Color(0.35, 0.3, 0.42))
	for side: float in [1.0, -1.0]:
		_append(m, _cyl(0.1, 0.04), Transform3D(_rx(PI / 2), Vector3(0.62, 0.1, 0.2 * side)), Color(0.1, 0.1, 0.1))
	_append(m, _cyl(0.02, 0.5), Transform3D(_rz(0.5), Vector3(0.44, 0.85, 0)), Color(0.4, 0.4, 0.42))
	return m


## Велосипедист: велосипед из цилиндров-колёс и рамы + седок.
func civ_cyclist() -> ArrayMesh:
	var m := ArrayMesh.new()
	var frame := Color(0.2, 0.25, 0.4)
	for wx in [0.55, -0.55]:
		_append(m, _cyl(0.33, 0.03), Transform3D(_rx(PI / 2), Vector3(wx, 0.33, 0)), Color(0.1, 0.1, 0.1))
		_append(m, _cyl(0.28, 0.02), Transform3D(_rx(PI / 2), Vector3(wx, 0.33, 0)), Color(0.55, 0.55, 0.55))
	_append(m, _cyl(0.02, 1.05), Transform3D(_rz(PI / 2 + 0.15), Vector3(0.0, 0.62, 0)), frame)
	_append(m, _cyl(0.02, 0.55), Transform3D(_rz(0.35), Vector3(-0.35, 0.62, 0)), frame)
	_append(m, _cyl(0.02, 0.6), Transform3D(_rz(-0.3), Vector3(0.45, 0.62, 0)), frame)
	_append(m, _box(0.22, 0.03, 0.4), Transform3D(Basis(), Vector3(0.55, 0.95, 0)), Color(0.15, 0.15, 0.15))
	_append(m, _box(0.2, 0.06, 0.14), Transform3D(Basis(), Vector3(-0.4, 0.92, 0)), Color(0.12, 0.1, 0.08))
	# седок (наклонён к рулю)
	var shirt := Color(0.5, 0.55, 0.65)
	_append(m, _box(0.32, 0.5, 0.22), Transform3D(_rz(-0.5), Vector3(-0.12, 1.18, 0)), shirt)
	_append(m, _sph(0.1), Transform3D(Basis(), Vector3(0.16, 1.42, 0)), SKIN)
	_append(m, _cyl(0.11, 0.07), Transform3D(Basis(), Vector3(0.16, 1.5, 0)), Color(0.3, 0.3, 0.28))
	for side: float in [1.0, -1.0]:
		_append(m, _box(0.09, 0.45, 0.09), Transform3D(_rz(-1.1), Vector3(0.22, 1.12, 0.16 * side)), shirt)
		_append(m, _box(0.11, 0.55, 0.13), Transform3D(_rz(0.75 * side * 0.4 + 0.5), Vector3(-0.2, 0.62, 0.1 * side)), Color(0.2, 0.2, 0.24))
	return m


## Ребёнок: уменьшенный человечек в яркой одежде.
func civ_kid(shirt: Color) -> ArrayMesh:
	var m := ArrayMesh.new()
	for side: float in [1.0, -1.0]:
		_append(m, _box(0.16, 0.07, 0.09), Transform3D(Basis(), Vector3(0.01, 0.035, 0.06 * side)), Color(0.2, 0.15, 0.1))
		_append(m, _box(0.1, 0.45, 0.11), Transform3D(Basis(), Vector3(0, 0.3, 0.06 * side)), Color(0.25, 0.3, 0.45))
	_append(m, _box(0.26, 0.36, 0.17), Transform3D(Basis(), Vector3(0, 0.72, 0)), shirt)
	for side: float in [1.0, -1.0]:
		_append(m, _box(0.07, 0.32, 0.07), Transform3D(_rz(0.25 * side), Vector3(-0.03, 0.72, 0.14 * side)), shirt)
	_append(m, _sph(0.09), Transform3D(Basis(), Vector3(0, 1.02, 0)), SKIN)
	return m


## Собака.
func civ_dog() -> ArrayMesh:
	var m := ArrayMesh.new()
	var fur := Color(0.35, 0.28, 0.2)
	_append(m, _box(0.55, 0.22, 0.18), Transform3D(Basis(), Vector3(0, 0.38, 0)), fur)
	_append(m, _box(0.18, 0.15, 0.14), Transform3D(Basis(), Vector3(0.34, 0.5, 0)), fur)
	_append(m, _box(0.1, 0.07, 0.08), Transform3D(Basis(), Vector3(0.45, 0.46, 0)), fur * 0.8)
	for e: float in [0.04, -0.04]:
		_append(m, _box(0.03, 0.07, 0.03), Transform3D(Basis(), Vector3(0.3, 0.6, e)), fur * 0.7)
	for lx: float in [0.2, -0.2]:
		for lz: float in [0.06, -0.06]:
			_append(m, _box(0.05, 0.28, 0.05), Transform3D(Basis(), Vector3(lx, 0.14, lz)), fur * 0.85)
	_append(m, _box(0.22, 0.04, 0.04), Transform3D(_rz(0.6), Vector3(-0.32, 0.48, 0)), fur)
	return m


## Наборы жителей для галереи: [меш, смещение по z].
func civ_set(variant: int) -> Array:
	match variant:
		1:
			return [[civ_man(Color(0.55, 0.55, 0.6), false), -1.4], [civ_woman(Color(0.6, 0.4, 0.4), Color(0.8, 0.75, 0.6), false), 0.0],
				[civ_man(Color(0.35, 0.45, 0.35), false), 1.4]]
		2:
			return [[civ_man(Color(0.5, 0.52, 0.6), true), -2.0], [civ_woman(Color(0.45, 0.5, 0.62), Color(0.85, 0.8, 0.7), true), -0.6],
				[civ_cyclist(), 1.2]]
		_:
			return [[civ_babushka(), -2.2], [civ_woman(Color(0.6, 0.45, 0.4), Color(0.75, 0.7, 0.6), false), -0.8],
				[civ_kid(Color(0.75, 0.35, 0.3)), 0.3], [civ_dog(), 1.2], [civ_man(Color(0.4, 0.42, 0.5), false), 2.2]]


## Единая точка входа для галереи: ключ вида tank2 / apc1 / sold3 / civ2.
## Техника возвращается ригом (Node3D), люди — мешами.
# ============================ ДРОНЫ (модели БпЛА игрока) ============================
# fpv7 — 7" ударный long-range класса Mark4 (реальные пропорции: X-рама 295 мм, карбон,
# камера между «щёк» с наклоном ~20°, VTX-антенна назад, липо 6S сверху под ремешком).
# Варианты: 1 «классика» (жёлтая липо, оранжевые пропы, БЧ под брюхом), 2 «полевой»
# (олива, GPS-стойка), 3 «ночной» (чёрный матовый, крупная ночная камера, красный габарит).
# Риг: {root, props: [4×Node3D]} — узлы пропеллеров вращаются по газу (3-е лицо/меню).

const CARBON := Color(0.13, 0.13, 0.145)

func drone_fpv7(variant: int) -> Dictionary:
	var root := Node3D.new()
	root.name = "DroneFPV7v%d" % variant
	var m := ArrayMesh.new()
	var accent: Color = [Color(0.9, 0.72, 0.12), Color(0.34, 0.38, 0.27), Color(0.07, 0.07, 0.085)][variant - 1]
	var prop_c: Color = [Color(0.92, 0.44, 0.1), Color(0.4, 0.52, 0.3), Color(0.1, 0.1, 0.12)][variant - 1]
	var y0 := 0.024                                             # низ рамы над опорой
	# рама: нижняя/верхняя пластины + стойки стека
	_append(m, _box(0.15, 0.0025, 0.048), Transform3D(Basis(), Vector3(0, y0, 0)), CARBON)
	_append(m, _box(0.125, 0.0025, 0.046), Transform3D(Basis(), Vector3(-0.005, y0 + 0.032, 0)), CARBON)
	for sx: float in [1.0, -1.0]:
		for sz: float in [1.0, -1.0]:
			_append(m, _cyl(0.0035, 0.032), Transform3D(Basis(), Vector3(sx * 0.045, y0 + 0.016, sz * 0.018)), Color(0.08, 0.08, 0.08))
	# лучи к моторам (X-рама 295 мм: моторы на ±0.104/±0.104) и моторы с колоколами
	for sx: float in [1.0, -1.0]:
		for sz: float in [1.0, -1.0]:
			var ang := atan2(sz, sx)
			_append(m, _box(0.135, 0.005, 0.015), Transform3D(Basis(Vector3.UP, -ang), Vector3(sx * 0.062, y0 + 0.006, sz * 0.062)), CARBON)
			_append(m, _cyl(0.0135, 0.017), Transform3D(Basis(), Vector3(sx * 0.104, y0 + 0.017, sz * 0.104)), Color(0.22, 0.22, 0.24))
			_append(m, _cyl(0.014, 0.006), Transform3D(Basis(), Vector3(sx * 0.104, y0 + 0.028, sz * 0.104)), Color(0.55, 0.55, 0.58))
	# камера между карбоновых щёк, наклон 20°
	var cam_s := 0.024 if variant == 3 else 0.019
	for sz: float in [1.0, -1.0]:
		_append(m, _box(0.03, 0.03, 0.003), Transform3D(Basis(), Vector3(0.07, y0 + 0.018, sz * 0.016)), CARBON)
	var cb := Basis(Vector3(0, 0, 1), deg_to_rad(-20.0))
	_append(m, _box(cam_s, cam_s, cam_s), Transform3D(cb, Vector3(0.072, y0 + 0.018, 0)), Color(0.1, 0.1, 0.1))
	_append(m, _cyl(0.008, 0.012), Transform3D(cb.rotated(Vector3(0, 0, 1), deg_to_rad(90)), Vector3(0.085, y0 + 0.022, 0)), Color(0.05, 0.05, 0.05))
	_append(m, _sph(0.0055), Transform3D(Basis(), Vector3(0.0915, y0 + 0.024, 0)), Color(0.2, 0.35, 0.6))
	# липо сверху под ремешком + XT60
	_append(m, _box(0.132, 0.038, 0.044), Transform3D(Basis(), Vector3(-0.01, y0 + 0.052, 0)), accent)
	_append(m, _box(0.018, 0.044, 0.05), Transform3D(Basis(), Vector3(-0.01, y0 + 0.052, 0)), Color(0.07, 0.07, 0.07))
	_append(m, _box(0.014, 0.01, 0.016), Transform3D(Basis(), Vector3(-0.083, y0 + 0.042, 0.01)), Color(0.85, 0.7, 0.1))
	# VTX-антенна назад-вверх с капсулой + два RX-усика
	var ab := Basis(Vector3(0, 0, 1), deg_to_rad(65.0))
	_append(m, _cyl(0.0028, 0.085), Transform3D(ab, Vector3(-0.1, y0 + 0.045, 0)), Color(0.1, 0.1, 0.1))
	_append(m, _sph(0.0075), Transform3D(Basis(), Vector3(-0.138, y0 + 0.063, 0)), Color(0.85, 0.85, 0.85) if variant != 3 else Color(0.15, 0.15, 0.15))
	for sz: float in [1.0, -1.0]:
		_append(m, _cyl(0.0014, 0.055), Transform3D(Basis(Vector3(1, 0, 0), sz * deg_to_rad(40.0)).rotated(Vector3(0, 0, 1), deg_to_rad(65.0)), Vector3(-0.078, y0 + 0.03, sz * 0.022)), Color(0.1, 0.1, 0.1))
	match variant:
		1:
			# БЧ под брюхом: цилиндр с носовым конусом и двумя скобами подвеса
			_append(m, _cyl(0.024, 0.13), Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(90.0)), Vector3(0.005, -0.006, 0)), Color(0.33, 0.36, 0.26))
			_append(m, _cyl(0.005, 0.035, 0.023), Transform3D(Basis(Vector3(0, 0, 1), deg_to_rad(-90.0)), Vector3(0.088, -0.006, 0)), Color(0.3, 0.32, 0.24))
			for px: float in [-0.03, 0.045]:
				_append(m, _box(0.012, 0.03, 0.052), Transform3D(Basis(), Vector3(px, y0 - 0.014, 0)), Color(0.09, 0.09, 0.09))
		2:
			# GPS-таблетка на стойке сзади
			_append(m, _cyl(0.0025, 0.05), Transform3D(Basis(), Vector3(-0.055, y0 + 0.06, 0.014)), Color(0.09, 0.09, 0.09))
			_append(m, _cyl(0.014, 0.007), Transform3D(Basis(), Vector3(-0.055, y0 + 0.088, 0.014)), Color(0.9, 0.9, 0.9))
		3:
			# красный габарит-светлячок сзади
			_append(m, _sph(0.004), Transform3D(Basis(), Vector3(-0.07, y0 + 0.036, 0)), Color(0.9, 0.12, 0.1))
	root.add_child(_mi(m, "Body"))
	# пропеллеры — отдельные узлы (вращение по газу); 7" = диск r0.089
	var props: Array = []
	for sx: float in [1.0, -1.0]:
		for sz: float in [1.0, -1.0]:
			var p := Node3D.new()
			p.name = "Prop%d%d" % [int(sx > 0), int(sz > 0)]
			p.position = Vector3(sx * 0.104, y0 + 0.034, sz * 0.104)
			var pm := ArrayMesh.new()
			_append(pm, _cyl(0.005, 0.009), Transform3D(Basis(), Vector3.ZERO), Color(0.12, 0.12, 0.12))
			for k in 2:
				var bb := Basis(Vector3.UP, PI * k) * Basis(Vector3(1, 0, 0), deg_to_rad(9.0))
				_append(pm, _box(0.078, 0.0016, 0.013), Transform3D(bb, bb * Vector3(0.049, 0, 0)), prop_c)
			p.add_child(_mi(pm, "PropMesh"))
			root.add_child(p)
			props.append(p)
	return {"root": root, "props": props}


## Дрон «в висении» для галереи --unitshot (на земле тонет в траве/буграх рельефа).
func _drone_hover(variant: int) -> Node3D:
	var holder := Node3D.new()
	holder.name = "DroneHover%d" % variant
	var d: Dictionary = drone_fpv7(variant)
	var dn: Node3D = d.root
	dn.position = Vector3(0, 1.4, 0)
	holder.add_child(dn)
	return holder


func build_set(key: String) -> Array:
	var variant := int(key.substr(key.length() - 1))
	if key.begins_with("tank"):
		return [[tank_node(variant).root, 0.0]]
	if key.begins_with("apc"):
		return [[apc_node(variant).root, 0.0]]
	if key.begins_with("sold"):
		return [[soldier(variant), 0.0]]
	if key.begins_with("car"):
		return [[car_sedan(), -6.0], [car_wagon(), -3.0], [car_van(), 0.0], [car_truck(), 3.5], [car_bus(), 7.5]]
	if key.begins_with("drone"):
		return [[_drone_hover(clampi(variant, 1, 3)), 0.0]]
	return civ_set(variant)


# ============================ РИГИ ТЕХНИКИ ============================
# Подвижная техника: корпус + отдельная башня (вращается), бегущие траки (узел
# с гребнями смещается циклично), колёса с болтами (вращение видно). Пивот башни —
# её ось; ствол крутится вместе с ней. Возврат: {root, turret, tracks, wheels, wheel_r}.

func _mi(mesh: Mesh, nm: String = "") -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	if nm != "": mi.name = nm
	return mi


## Корпус танка без гребней траков: ванна, лоб, полки, юбки, ленты, катки, ДЗ лба, бочки, бревно.
func _tank_hull_mesh(hull_tex: Texture2D, dirty: bool, era_on: bool) -> ArrayMesh:
	var m := ArrayMesh.new()
	_append_tex(m, _box(6.4, 0.9, 2.7), Transform3D(Basis(), Vector3(0, 0.95, 0)), hull_tex)
	_append_mesh(m, _sloped_box(Vector3(6.2, 0.75, 2.7), 1.9), Transform3D(Basis(), Vector3(0, 1.55, 0)), Color(1, 1, 1))
	m.surface_set_material(m.get_surface_count() - 1, _mat_tex(hull_tex))
	for fz in [1.5, -1.5]:
		_append(m, _box(6.6, 0.12, 0.55), Transform3D(Basis(), Vector3(0, 1.35, fz)), Color(0.24, 0.26, 0.17))
	for fz in [1.62, -1.62]:
		_append(m, _box(6.4, 0.5, 0.06), Transform3D(Basis(), Vector3(0, 1.05, fz)),
			Color(0.16, 0.15, 0.11) if not dirty else Color(0.22, 0.19, 0.13))
	for fz in [1.42, -1.42]:
		_append(m, _box(6.8, 0.7, 0.7), Transform3D(Basis(), Vector3(0, 0.55, fz)), T_TRACK)
		for rx in [-2.55, -1.53, -0.51, 0.51, 1.53, 2.55]:
			_append(m, _cyl(0.5, 0.28), Transform3D(_rx(PI / 2), Vector3(rx, 0.55, fz)), T_RUBBER)
		for rx in [-3.15, 3.15]:
			_append(m, _cyl(0.42, 0.3), Transform3D(_rx(PI / 2), Vector3(rx, 0.75, fz)), T_STEEL)
	if era_on:
		for ez in [-1.0, -0.5, 0.0, 0.5, 1.0]:
			_append(m, _box(0.5, 0.28, 0.4), Transform3D(_rz(-0.5), Vector3(2.9, 1.7, ez)), Color(0.32, 0.34, 0.21))
	for dz in [0.7, -0.7]:
		_append(m, _cyl(0.28, 0.9), Transform3D(_rz(PI / 2), Vector3(-3.4, 1.6, dz)), Color(0.28, 0.3, 0.19))
	_append(m, _cyl(0.14, 2.4), Transform3D(_rx(PI / 2), Vector3(-3.15, 1.15, 0)), Color(0.32, 0.24, 0.15))
	return m


## Гребни траков обоих бортов — отдельный меш, циклическое смещение по X = «бегущая» гусеница.
func _tank_cleats_mesh() -> ArrayMesh:
	var m := ArrayMesh.new()
	for fz in [1.42, -1.42]:
		for lx in range(-3, 4):
			_append(m, _box(0.16, 0.78, 0.78), Transform3D(Basis(), Vector3(lx * 0.9, 0.55, fz)), T_STEEL)
	return m


## Башня танка (координаты от пивота (-0.5, 2.35, 0)): восьмигранник, ДЗ, маска, ствол,
## башенка, ЗПУ, корзина, антенны; опционально «мангал» (он крепится к башне).
func _tank_turret_mesh(hull_tex: Texture2D, era_on: bool, hatches_open: bool, mangal: bool) -> ArrayMesh:
	var m := ArrayMesh.new()
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 8
	var top: Array[Vector3] = []; var bot: Array[Vector3] = []
	for i in n:
		var a := TAU * i / n + PI / n
		top.append(Vector3(cos(a) * 1.85 * 0.82, 0.475, sin(a) * 1.35 * 0.82))
		bot.append(Vector3(cos(a) * 1.85, -0.475, sin(a) * 1.35))
	for i in n:
		var j := (i + 1) % n
		_quad(st, bot[i], bot[j], top[j], top[i])
	var ct := Vector3(0, 0.475, 0); var cb := Vector3(0, -0.475, 0)
	for i in n:
		var j := (i + 1) % n
		st.set_normal(Vector3.UP); st.add_vertex(top[i])
		st.set_normal(Vector3.UP); st.add_vertex(top[j])
		st.set_normal(Vector3.UP); st.add_vertex(ct)
		st.set_normal(Vector3.DOWN); st.add_vertex(bot[j])
		st.set_normal(Vector3.DOWN); st.add_vertex(bot[i])
		st.set_normal(Vector3.DOWN); st.add_vertex(cb)
	st.index()
	var oct := st.commit()
	for si in oct.get_surface_count():
		_append_arrays(m, oct.surface_get_arrays(si), Transform3D(), _mat_tex(hull_tex))
	if era_on:
		for tz in [-0.85, -0.45, 0.45, 0.85]:
			_append(m, _box(0.5, 0.28, 0.4), Transform3D(_rz(-0.35), Vector3(1.45, 0.0, tz)), Color(0.32, 0.34, 0.21))
	_append(m, _cyl(0.42, 0.42, 0.46), Transform3D(Basis(), Vector3(-0.5, 0.7, 0.6)), Color(0.26, 0.28, 0.18))
	if hatches_open:
		_append(m, _cyl(0.4, 0.06), Transform3D(_rx(1.2), Vector3(-0.5, 1.0, 0.95)), Color(0.24, 0.26, 0.17))
	_append(m, _cyl(0.05, 1.1, 0.06), Transform3D(_rz(PI / 2.2), Vector3(0.1, 1.0, 0.6)), T_RUBBER)
	_append(m, _box(1.2, 0.5, 1.9), Transform3D(Basis(), Vector3(-1.4, -0.05, 0)), Color(0.12, 0.13, 0.1))
	for av in [Vector3(-1.3, 1.05, -0.7), Vector3(-1.4, 0.95, 0.7)]:
		_append(m, _cyl(0.015, 1.9, 0.03), Transform3D(Basis(), av), T_RUBBER)
	if mangal:
		var c := Color(0.17, 0.18, 0.14)
		var y := 1.4
		_append(m, _box(4.6, 0.07, 0.07), Transform3D(Basis(), Vector3(0, y, 1.55)), c)
		_append(m, _box(4.6, 0.07, 0.07), Transform3D(Basis(), Vector3(0, y, -1.55)), c)
		_append(m, _box(0.07, 0.07, 3.1), Transform3D(Basis(), Vector3(2.3, y, 0)), c)
		_append(m, _box(0.07, 0.07, 3.1), Transform3D(Basis(), Vector3(-2.3, y, 0)), c)
		for k in 7:
			_append(m, _box(4.6, 0.03, 0.05), Transform3D(Basis(), Vector3(0, y, -1.16 + k * 0.387)), c)
		for k in 5:
			_append(m, _box(0.05, 0.03, 3.1), Transform3D(Basis(), Vector3(-1.6 + k * 0.78, y + 0.02, 0)), c)
		for lp in [Vector3(1.7, 0, 1.1), Vector3(1.7, 0, -1.1), Vector3(-1.7, 0, 1.1), Vector3(-1.7, 0, -1.1)]:
			_append(m, _cyl(0.045, 1.0), Transform3D(Basis(), Vector3(lp.x, 0.9, lp.z)), c)
	return m


## Орудие танка: маска + казённик + ствол с эжектором (пивот — цапфы у маски).
func _tank_gun_mesh() -> ArrayMesh:
	var m := ArrayMesh.new()
	_append(m, _box(0.9, 0.75, 1.3), Transform3D(), Color(0.26, 0.28, 0.18))
	_append(m, _cyl(0.2, 2.0, 0.22), Transform3D(_rz(PI / 2), Vector3(1.45, 0.0, 0)), T_STEEL)
	_append(m, _cyl(0.12, 3.0, 0.14), Transform3D(_rz(PI / 2), Vector3(3.75, 0.0, 0)), Color(0.1, 0.11, 0.09))
	_append(m, _cyl(0.24, 0.7), Transform3D(_rz(PI / 2), Vector3(3.15, 0.0, 0)), T_STEEL)
	_append(m, _cyl(0.17, 0.35), Transform3D(_rz(PI / 2), Vector3(5.15, 0.0, 0)), T_STEEL)
	return m


func tank_node(variant: int) -> Dictionary:
	var tex: ImageTexture
	match variant:
		3: tex = camo_multicam()
		4: tex = camo_faded()
		_: tex = camo_green()
	var root := Node3D.new()
	root.add_child(_mi(_tank_hull_mesh(tex, variant == 3, variant != 4), "Hull"))
	var cleats := _mi(_tank_cleats_mesh(), "Cleats")
	root.add_child(cleats)
	var turret := _mi(_tank_turret_mesh(tex, variant != 4, variant == 4, variant == 2), "Turret")
	turret.position = Vector3(-0.5, 2.35, 0)
	root.add_child(turret)
	var gun := _mi(_tank_gun_mesh(), "Gun")
	gun.position = Vector3(1.65, 0, 0)
	turret.add_child(gun)
	if variant == 3:
		var mm := ArrayMesh.new()
		_tank_masking(mm)
		root.add_child(_mi(mm, "Masking"))
	return {"root": root, "turret": turret, "gun": gun, "tracks": cleats, "wheels": [], "wheel_r": 0.5, "cleat_step": 0.9}


## Корпус БТР-80 без колёс (корыто, палуба, волноотбойник, люки, фары, ЗИП).
func _apc_hull_mesh(tex: Texture2D) -> ArrayMesh:
	var m := ArrayMesh.new()
	_btr80_hull_shell(m, tex)
	_btr_deck_stuff(m)
	return m


## Колесо БТР с болтами на ступице (вращение читается). Ось колеса — Z узла.
func _apc_wheel_mesh() -> ArrayMesh:
	var m := ArrayMesh.new()
	_append(m, _cyl(0.58, 0.4), Transform3D(_rx(PI / 2), Vector3.ZERO), T_RUBBER)
	_append(m, _cyl(0.2, 0.42), Transform3D(_rx(PI / 2), Vector3.ZERO), Color(0.17, 0.17, 0.15))
	for k in 3:
		var a := TAU * k / 3.0
		for zz in [0.215, -0.215]:
			_append(m, _box(0.1, 0.1, 0.03), Transform3D(Basis(), Vector3(cos(a) * 0.36, sin(a) * 0.36, zz)), Color(0.1, 0.1, 0.09))
	return m


## Башенка БТР-80 (координаты от пивота (0.7, 2.45, 0)).
func _apc_turret_mesh(tex: Texture2D) -> ArrayMesh:
	var m := ArrayMesh.new()
	_append_tex(m, _cyl(0.55, 0.55, 0.75), Transform3D(), tex)
	_append(m, _box(0.18, 0.1, 0.14), Transform3D(Basis(), Vector3(0.15, 0.4, 0.2)), Color(0.1, 0.1, 0.1))
	return m


## Спарка КПВТ+ПКТ (пивот — цапфы на башенке, координаты от (0.4, 0.1, 0)).
func _apc_gun_mesh() -> ArrayMesh:
	var m := ArrayMesh.new()
	_append(m, _cyl(0.06, 1.9, 0.08), Transform3D(_rz(PI / 2 - 0.06), Vector3(0.8, 0.0, 0)), Color(0.09, 0.1, 0.08))
	_append(m, _cyl(0.035, 1.0), Transform3D(_rz(PI / 2), Vector3(0.4, -0.15, 0.22)), Color(0.09, 0.1, 0.08))
	return m


func apc_node(variant: int) -> Dictionary:
	var tex: ImageTexture = camo_pixel() if variant == 3 else camo_green()
	var root := Node3D.new()
	root.add_child(_mi(_apc_hull_mesh(tex), "Hull"))
	var turret := _mi(_apc_turret_mesh(tex), "Turret")
	turret.position = Vector3(0.7, 2.45, 0)
	root.add_child(turret)
	var gun := _mi(_apc_gun_mesh(), "Gun")
	gun.position = Vector3(0.4, 0.1, 0)
	turret.add_child(gun)
	var wheels: Array = []
	var wmesh := _apc_wheel_mesh()
	for wx in [2.45, 1.45, -1.05, -2.05]:
		for wz in [1.3, -1.3]:
			var wn := _mi(wmesh, "Wheel")
			wn.position = Vector3(wx, 0.58, wz)
			root.add_child(wn)
			wheels.append(wn)
	return {"root": root, "turret": turret, "gun": gun, "tracks": null, "wheels": wheels, "wheel_r": 0.58}


## Скорлупа БТР-80 без колёс (для рига).
func _btr80_hull_shell(m: ArrayMesh, tex: Texture2D) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# профиль корыта: низ уже, середина шире, верх уже (характерные скосы)
	var L := 7.4
	var x0 := -L * 0.5
	var x1 := L * 0.5
	var zb := 1.05      # низ
	var zm := 1.45      # середина (максимум)
	var zt := 1.0       # верх
	var yb := 0.75; var ym := 1.45; var yt := 2.15
	# нос заострён (стыкуем к точке-клину)
	var nose := 1.35
	# строим три «кольца» профиля по длине: корма, середина-перед, нос
	var xs := [x0, x1 - nose]
	var rings := []
	for x in xs:
		rings.append([Vector3(x, yb, -zb), Vector3(x, yb, zb), Vector3(x, ym, zm), Vector3(x, yt, zt),
			Vector3(x, yt, -zt), Vector3(x, ym, -zm)])
	# носовое кольцо — сжатое (клин)
	var xn := x1
	rings.append([Vector3(xn, yb + 0.25, -zb * 0.35), Vector3(xn, yb + 0.25, zb * 0.35), Vector3(xn, ym, zm * 0.4),
		Vector3(xn, yt - 0.15, zt * 0.35), Vector3(xn, yt - 0.15, -zt * 0.35), Vector3(xn, ym, -zm * 0.4)])
	for ri in range(rings.size() - 1):
		var a: Array = rings[ri]; var b: Array = rings[ri + 1]
		for i in 6:
			var j := (i + 1) % 6
			_quad(st, a[i], a[j], b[j], b[i])
	# крышки: корма и палуба
	var r0: Array = rings[0]
	_quad(st, r0[0], r0[5], r0[4], r0[3]); _quad(st, r0[0], r0[3], r0[2], r0[1])
	for ri in [rings.size() - 1]:
		var rl: Array = rings[ri]
		_quad(st, rl[1], rl[2], rl[3], rl[4]); _quad(st, rl[1], rl[4], rl[5], rl[0])
	# палуба (верхняя грань между кольцами)
	st.index()
	var hull := st.commit()
	for s in hull.get_surface_count():
		_append_arrays(m, hull.surface_get_arrays(s), Transform3D(), _mat_tex(tex))
	# палубный настил (закрывает верх)
	_append_tex(m, _box(L - nose, 0.06, 2.0), Transform3D(Basis(), Vector3(-nose * 0.5, 2.14, 0)), tex)
	# волноотбойник на носу
	_append(m, _box(0.12, 0.35, 1.6), Transform3D(_rz(0.5), Vector3(3.35, 1.95, 0)), Color(0.2, 0.22, 0.15))
	# боковые люки десанта
	for hx in [-0.2]:
		_append(m, _box(0.9, 0.8, 0.06), Transform3D(Basis(), Vector3(hx, 1.55, 1.44)), Color(0.24, 0.26, 0.17))
		_append(m, _box(0.9, 0.8, 0.06), Transform3D(Basis(), Vector3(hx, 1.55, -1.44)), Color(0.24, 0.26, 0.17))
	# фары
	for fz in [0.55, -0.55]:
		_append(m, _cyl(0.09, 0.08), Transform3D(_rz(PI / 2), Vector3(3.6, 1.9, fz)), Color(0.75, 0.75, 0.7))


# ============================ ГРАЖДАНСКИЕ МАШИНЫ ============================
# Детальные машины для трафика (вперёд = +X). Кузовные панели — материал с
# vertex_color_use_as_albedo: MultiMesh красит каждую машину instance-цветом.

var _body_mat_cache := {}

func _mat_body() -> StandardMaterial3D:
	if _body_mat_cache.has("body"):
		return _body_mat_cache["body"]
	var mt := StandardMaterial3D.new()
	mt.albedo_color = Color(1, 1, 1)
	mt.vertex_color_use_as_albedo = true
	mt.roughness = 0.35
	mt.metallic = 0.25
	_body_mat_cache["body"] = mt
	return mt


func _append_body(m: ArrayMesh, prim: PrimitiveMesh, xform: Transform3D) -> void:
	_append_arrays(m, prim.get_mesh_arrays(), xform, _mat_body())


const GLASS := Color(0.10, 0.13, 0.16)
const TIRE := Color(0.07, 0.07, 0.07)
const HUB := Color(0.45, 0.45, 0.45)
const BUMPER := Color(0.2, 0.2, 0.21)


func _car_wheels(m: ArrayMesh, xs: Array, r: float, w: float, z: float) -> void:
	for wx: float in xs:
		for wz: float in [z, -z]:
			_append(m, _cyl(r, w), Transform3D(_rx(PI / 2), Vector3(wx, r, wz)), TIRE)
			_append(m, _cyl(r * 0.4, w + 0.02), Transform3D(_rx(PI / 2), Vector3(wx, r, wz)), HUB)


func _car_lights(m: ArrayMesh, front_x: float, y: float, z: float) -> void:
	for lz: float in [z, -z]:
		_append(m, _box(0.06, 0.14, 0.3), Transform3D(Basis(), Vector3(front_x, y, lz)), Color(0.9, 0.9, 0.82))
		_append(m, _box(0.06, 0.12, 0.26), Transform3D(Basis(), Vector3(-front_x, y, lz)), Color(0.55, 0.1, 0.08))


## Стекло-скат (лобовое/заднее): тонкая пластина под углом.
func _car_glass(m: ArrayMesh, x: float, y: float, wz: float, h: float, tilt: float) -> void:
	_append(m, _box(0.05, h, wz), Transform3D(_rz(tilt), Vector3(x, y, 0)), GLASS)


## Лофт бокового силуэта: prof — точки Vector3(x, y, полуширина) ПРОТИВ часовой (вид с +Z).
## Строит обе боковины (триангуляция профиля) и «кожу» по периметру. Даёт настоящий силуэт
## машины вместо набора коробок: клин капота, скаты стёкол, скруглённые углы.
func _loft(m: ArrayMesh, prof: Array, mt: Material) -> void:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := prof.size()
	# кожа по периметру (обе стороны намотки — без дыр при любом обходе)
	for i in n:
		var a: Vector3 = prof[i]
		var b: Vector3 = prof[(i + 1) % n]
		var p0 := Vector3(a.x, a.y, -a.z); var p1 := Vector3(b.x, b.y, -b.z)
		var p2 := Vector3(b.x, b.y, b.z); var p3 := Vector3(a.x, a.y, a.z)
		_quad(st, p0, p1, p2, p3)
		_quad(st, p3, p2, p1, p0)
	# боковины
	var pts2 := PackedVector2Array()
	for v: Vector3 in prof:
		pts2.append(Vector2(v.x, v.y))
	var idx := Geometry2D.triangulate_polygon(pts2)
	for k in range(0, idx.size(), 3):
		var a2: Vector3 = prof[idx[k]]; var b2: Vector3 = prof[idx[k + 1]]; var c2: Vector3 = prof[idx[k + 2]]
		st.set_normal(Vector3.BACK); st.add_vertex(Vector3(a2.x, a2.y, a2.z))
		st.set_normal(Vector3.BACK); st.add_vertex(Vector3(b2.x, b2.y, b2.z))
		st.set_normal(Vector3.BACK); st.add_vertex(Vector3(c2.x, c2.y, c2.z))
		st.set_normal(Vector3.FORWARD); st.add_vertex(Vector3(c2.x, c2.y, -c2.z))
		st.set_normal(Vector3.FORWARD); st.add_vertex(Vector3(b2.x, b2.y, -b2.z))
		st.set_normal(Vector3.FORWARD); st.add_vertex(Vector3(a2.x, a2.y, -a2.z))
	st.index()
	var part := st.commit()
	for si in part.get_surface_count():
		_append_arrays(m, part.surface_get_arrays(si), Transform3D(), mt)


## Стойка кузова (наклонный брусок между точками, цвет кузова).
func _pillar(m: ArrayMesh, a: Vector3, b: Vector3, w: float) -> void:
	_append_arrays(m, _box(w, a.distance_to(b), w).get_mesh_arrays(), _limb_xf(a, b), _mat_body())


## Колёсная ниша: тёмная «бровь» над колесом.
func _arch(m: ArrayMesh, x: float, r: float, w: float, z: float) -> void:
	for zz: float in [z, -z]:
		_append(m, _box(r * 2.2, r * 0.5, w + 0.06), Transform3D(Basis(), Vector3(x, r * 1.32, zz)), Color(0.1, 0.1, 0.1))


## Седан ВАЗ-2107: лофт клиновидного профиля, салон-«теплица» со стойками, хром-решётка.
func car_sedan() -> ArrayMesh:
	var m := ArrayMesh.new()
	var chrome := Color(0.75, 0.76, 0.78)
	# нижний кузов: корма → низ → нос → капот → пояс (клин к носу)
	_loft(m, [Vector3(-2.06, 0.70, 0.80), Vector3(-2.06, 0.30, 0.80), Vector3(2.06, 0.30, 0.80),
		Vector3(2.06, 0.60, 0.80), Vector3(1.68, 0.70, 0.79), Vector3(0.98, 0.79, 0.79),
		Vector3(-1.10, 0.80, 0.80), Vector3(-1.60, 0.77, 0.80)], _mat_body())
	# салон: лобовое → крыша → заднее стекло (сужение к крыше)
	_loft(m, [Vector3(0.98, 0.79, 0.70), Vector3(0.52, 1.31, 0.60), Vector3(-0.70, 1.33, 0.60),
		Vector3(-1.10, 0.80, 0.70)], _mat(GLASS))
	_append_body(m, _box(1.24, 0.05, 1.24), Transform3D(_rz(0.012), Vector3(-0.1, 1.34, 0)))     # крыша
	_pillar(m, Vector3(0.96, 0.78, 0.66), Vector3(0.52, 1.3, 0.57), 0.07)                        # стойки A/B/C
	_pillar(m, Vector3(0.96, 0.78, -0.66), Vector3(0.52, 1.3, -0.57), 0.07)
	for sz: float in [0.66, -0.66]:
		_append_body(m, _box(0.07, 0.5, 0.06), Transform3D(Basis(), Vector3(-0.28, 1.04, sz)))
	_pillar(m, Vector3(-1.08, 0.78, 0.66), Vector3(-0.7, 1.31, 0.57), 0.08)
	_pillar(m, Vector3(-1.08, 0.78, -0.66), Vector3(-0.7, 1.31, -0.57), 0.08)
	_append(m, _box(0.04, 0.2, 1.05), Transform3D(Basis(), Vector3(2.07, 0.62, 0)), chrome)      # решётка
	for lz: float in [0.58, -0.58]:
		_append(m, _box(0.04, 0.13, 0.3), Transform3D(Basis(), Vector3(2.08, 0.62, lz)), Color(0.92, 0.92, 0.85))
		_append(m, _box(0.04, 0.12, 0.28), Transform3D(Basis(), Vector3(-2.07, 0.62, lz)), Color(0.5, 0.08, 0.07))
	for bx: float in [2.12, -2.12]:
		_append(m, _box(0.12, 0.1, 1.64), Transform3D(Basis(), Vector3(bx, 0.35, 0)), Color(0.16, 0.16, 0.17))
	for mz: float in [0.85, -0.85]:
		_append(m, _box(0.07, 0.07, 0.09), Transform3D(Basis(), Vector3(0.8, 0.92, mz)), BUMPER)
	_arch(m, 1.32, 0.29, 0.17, 0.72)
	_arch(m, -1.32, 0.29, 0.17, 0.72)
	_car_wheels(m, [1.32, -1.32], 0.29, 0.17, 0.72)
	return m


## Универсал ВАЗ-2104: тот же клин, длинная крыша, почти вертикальная корма, рейлинги.
func car_wagon() -> ArrayMesh:
	var m := ArrayMesh.new()
	_loft(m, [Vector3(-2.04, 0.74, 0.80), Vector3(-2.04, 0.30, 0.80), Vector3(2.06, 0.30, 0.80),
		Vector3(2.06, 0.60, 0.80), Vector3(1.68, 0.70, 0.79), Vector3(0.98, 0.79, 0.79),
		Vector3(-1.98, 0.80, 0.80)], _mat_body())
	_loft(m, [Vector3(0.98, 0.79, 0.70), Vector3(0.52, 1.32, 0.62), Vector3(-1.88, 1.34, 0.62),
		Vector3(-1.98, 0.80, 0.70)], _mat(GLASS))
	_append_body(m, _box(2.42, 0.05, 1.26), Transform3D(Basis(), Vector3(-0.68, 1.35, 0)))
	_pillar(m, Vector3(0.96, 0.78, 0.66), Vector3(0.52, 1.31, 0.59), 0.07)
	_pillar(m, Vector3(0.96, 0.78, -0.66), Vector3(0.52, 1.31, -0.59), 0.07)
	for px: float in [-0.35, -1.15]:
		for sz: float in [0.65, -0.65]:
			_append_body(m, _box(0.07, 0.52, 0.06), Transform3D(Basis(), Vector3(px, 1.05, sz)))
	_pillar(m, Vector3(-1.96, 0.78, 0.66), Vector3(-1.88, 1.33, 0.6), 0.08)
	_pillar(m, Vector3(-1.96, 0.78, -0.66), Vector3(-1.88, 1.33, -0.6), 0.08)
	for rz2: float in [0.5, -0.5]:
		_append(m, _box(2.1, 0.04, 0.04), Transform3D(Basis(), Vector3(-0.7, 1.4, rz2)), BUMPER)
	_append(m, _box(0.04, 0.2, 1.05), Transform3D(Basis(), Vector3(2.07, 0.62, 0)), Color(0.75, 0.76, 0.78))
	for lz: float in [0.58, -0.58]:
		_append(m, _box(0.04, 0.13, 0.3), Transform3D(Basis(), Vector3(2.08, 0.62, lz)), Color(0.92, 0.92, 0.85))
		_append(m, _box(0.04, 0.12, 0.28), Transform3D(Basis(), Vector3(-2.05, 0.62, lz)), Color(0.5, 0.08, 0.07))
	for bx: float in [2.12, -2.1]:
		_append(m, _box(0.12, 0.1, 1.64), Transform3D(Basis(), Vector3(bx, 0.35, 0)), Color(0.16, 0.16, 0.17))
	_arch(m, 1.32, 0.29, 0.17, 0.72)
	_arch(m, -1.32, 0.29, 0.17, 0.72)
	_car_wheels(m, [1.32, -1.32], 0.29, 0.17, 0.72)
	return m


## «ГАЗель» бортовая: полукапот лофтом (капот ниже и у́же кабины), кабина со скатом
## лобового, борта + тент на дугах, задние двускатные.
func car_van() -> ArrayMesh:
	var m := ArrayMesh.new()
	# капот + пояс кабины одним лофтом: нос → капот → излом → низ стёкол кабины
	_loft(m, [Vector3(0.70, 1.10, 0.98), Vector3(0.70, 0.40, 0.95), Vector3(2.60, 0.40, 0.86),
		Vector3(2.74, 0.55, 0.86), Vector3(2.74, 0.96, 0.84), Vector3(2.12, 1.04, 0.84),
		Vector3(1.96, 1.10, 0.96)], _mat_body())
	# остекление кабины: лобовое со скатом → крыша → задняя стенка
	_loft(m, [Vector3(1.96, 1.10, 0.90), Vector3(1.58, 1.76, 0.86), Vector3(0.74, 1.78, 0.86),
		Vector3(0.70, 1.10, 0.90)], _mat(GLASS))
	_append_body(m, _box(0.9, 0.06, 1.78), Transform3D(Basis(), Vector3(1.15, 1.8, 0)))          # крыша
	_pillar(m, Vector3(1.94, 1.08, 0.9), Vector3(1.58, 1.74, 0.84), 0.08)
	_pillar(m, Vector3(1.94, 1.08, -0.9), Vector3(1.58, 1.74, -0.84), 0.08)
	_append_body(m, _box(0.1, 0.72, 1.8), Transform3D(Basis(), Vector3(0.72, 1.45, 0)))          # задняя стенка кабины
	_append(m, _box(0.04, 0.26, 1.35), Transform3D(Basis(), Vector3(2.75, 0.75, 0)), Color(0.2, 0.2, 0.21))
	for lz: float in [0.62, -0.62]:
		_append(m, _box(0.04, 0.16, 0.32), Transform3D(Basis(), Vector3(2.76, 0.8, lz)), Color(0.92, 0.92, 0.85))
	_append(m, _box(0.14, 0.13, 1.9), Transform3D(Basis(), Vector3(2.78, 0.42, 0)), BUMPER)
	# платформа: борта + серый тент на дугах
	_append(m, _box(3.1, 0.42, 2.0), Transform3D(Basis(), Vector3(-0.95, 0.93, 0)), Color(0.35, 0.4, 0.45))
	_append(m, _box(3.05, 0.92, 1.94), Transform3D(Basis(), Vector3(-0.95, 1.6, 0)), Color(0.62, 0.63, 0.6))
	for rib: float in [-0.2, -0.95, -1.7]:
		_append(m, _box(0.05, 0.96, 1.98), Transform3D(Basis(), Vector3(rib, 1.6, 0)), Color(0.55, 0.56, 0.53))
	for mz: float in [1.0, -1.0]:
		_append(m, _box(0.07, 0.1, 0.11), Transform3D(Basis(), Vector3(1.9, 1.5, mz)), BUMPER)
	_arch(m, 1.75, 0.34, 0.2, 0.8)
	_car_wheels(m, [1.75], 0.34, 0.2, 0.8)
	_car_wheels(m, [-1.35], 0.34, 0.34, 0.78)
	return m


## КамАЗ: бескапотная кабина лофтом (лоб чуть завален, козырёк), тент с дугами,
## бак, запаска, тележка из двух двускатных осей.
func car_truck() -> ArrayMesh:
	var m := ArrayMesh.new()
	# кабина: низ → плоская морда → козырёк над лобовым → крыша → задняя стенка
	_loft(m, [Vector3(1.55, 0.85, 1.2), Vector3(1.55, 2.6, 1.2), Vector3(3.18, 2.56, 1.16),
		Vector3(3.3, 1.9, 1.2), Vector3(3.3, 0.85, 1.18)], _mat_body())
	_append(m, _box(1.05, 0.62, 2.42), Transform3D(_rz(-0.08), Vector3(2.75, 2.1, 0)), GLASS)    # лобовое+боковые
	_append(m, _box(0.05, 0.55, 2.2), Transform3D(Basis(), Vector3(3.32, 1.35, 0)), Color(0.12, 0.12, 0.12))
	_append(m, _box(0.18, 0.26, 2.44), Transform3D(Basis(), Vector3(3.32, 0.72, 0)), Color(0.78, 0.78, 0.76))
	for lz: float in [0.95, -0.95]:
		_append(m, _box(0.05, 0.16, 0.3), Transform3D(Basis(), Vector3(3.34, 0.82, lz)), Color(0.92, 0.92, 0.85))
	_append(m, _box(4.6, 0.35, 2.3), Transform3D(Basis(), Vector3(-0.85, 1.15, 0)), Color(0.2, 0.2, 0.19))
	_append(m, _box(4.5, 0.5, 2.42), Transform3D(Basis(), Vector3(-0.85, 1.6, 0)), Color(0.3, 0.32, 0.28))
	_append(m, _box(4.45, 1.35, 2.38), Transform3D(Basis(), Vector3(-0.85, 2.52, 0)), Color(0.32, 0.38, 0.28))
	for rib: float in [0.5, -0.4, -1.3, -2.2]:
		_append(m, _box(0.06, 1.38, 2.42), Transform3D(Basis(), Vector3(rib, 2.52, 0)), Color(0.27, 0.32, 0.24))
	_append(m, _cyl(0.3, 0.65), Transform3D(_rz(PI / 2), Vector3(0.9, 0.75, 1.15)), Color(0.55, 0.55, 0.52))
	_append(m, _cyl(0.5, 0.28), Transform3D(_rx(PI / 2), Vector3(1.15, 0.9, -1.0)), TIRE)
	for mz: float in [1.32, -1.32]:
		_append(m, _box(0.07, 0.12, 0.13), Transform3D(Basis(), Vector3(3.05, 2.35, mz)), BUMPER)
	_arch(m, 2.35, 0.5, 0.3, 0.95)
	_car_wheels(m, [2.35], 0.5, 0.3, 0.95)
	_car_wheels(m, [-1.05, -2.15], 0.5, 0.44, 0.92)
	return m


## ПАЗ-3205: лофт со скруглёнными верхними углами, юбка, 5 окон со стойками,
## двери, белая крыша, табличка маршрута.
func car_bus() -> ArrayMesh:
	var m := ArrayMesh.new()
	_loft(m, [Vector3(-3.4, 0.45, 1.2), Vector3(3.4, 0.45, 1.2), Vector3(3.44, 1.75, 1.2),
		Vector3(3.38, 2.42, 1.18), Vector3(3.05, 2.88, 1.08), Vector3(-3.08, 2.9, 1.08),
		Vector3(-3.4, 2.48, 1.18)], _mat_body())
	_append(m, _box(6.7, 0.42, 2.42), Transform3D(Basis(), Vector3(0, 0.62, 0)), Color(0.22, 0.22, 0.23))  # юбка
	_append(m, _box(6.2, 0.72, 2.42), Transform3D(Basis(), Vector3(-0.15, 2.26, 0)), GLASS)      # лента окон
	for px: float in [2.05, 0.95, -0.15, -1.25, -2.35]:
		_append_body(m, _box(0.1, 0.76, 2.44), Transform3D(Basis(), Vector3(px, 2.26, 0)))
	_append(m, _box(0.72, 0.72, 2.44), Transform3D(Basis(), Vector3(2.72, 1.55, 0)), Color(0.2, 0.22, 0.24))
	_append(m, _box(0.72, 0.72, 2.44), Transform3D(Basis(), Vector3(-0.7, 1.55, 0)), Color(0.2, 0.22, 0.24))
	_append(m, _box(0.05, 0.85, 1.95), Transform3D(_rz(-0.06), Vector3(3.43, 2.1, 0)), GLASS)    # лобовое
	_append(m, _box(0.26, 0.22, 1.7), Transform3D(Basis(), Vector3(3.3, 2.62, 0)), Color(0.85, 0.85, 0.82))
	_append(m, _box(0.05, 0.75, 1.9), Transform3D(Basis(), Vector3(-3.41, 2.1, 0)), GLASS)       # заднее
	for lz: float in [0.82, -0.82]:
		_append(m, _box(0.05, 0.18, 0.34), Transform3D(Basis(), Vector3(3.45, 0.95, lz)), Color(0.92, 0.92, 0.85))
		_append(m, _box(0.05, 0.16, 0.3), Transform3D(Basis(), Vector3(-3.43, 1.0, lz)), Color(0.5, 0.08, 0.07))
	for bx: float in [3.46, -3.46]:
		_append(m, _box(0.16, 0.2, 2.44), Transform3D(Basis(), Vector3(bx, 0.5, 0)), BUMPER)
	for mz: float in [1.3, -1.3]:
		_append(m, _box(0.07, 0.11, 0.13), Transform3D(Basis(), Vector3(3.25, 2.3, mz)), BUMPER)
	_arch(m, 2.15, 0.45, 0.3, 0.95)
	_arch(m, -1.8, 0.45, 0.3, 0.95)
	_car_wheels(m, [2.15, -1.8], 0.45, 0.3, 0.95)
	return m
