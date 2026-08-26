extends RefCounted
## Библиотека детальных юнитов (варианты для согласования и боевого использования).
## Все меши процедурные: примитивы + SurfaceTool, камуфляж — процедурные текстуры (triplanar).
## Юниты смотрят в +X. Ключи: tank1..4, apc1..3, sold1..3, civ1..3 (наборы жителей).

var _tex_cache := {}


# ============================ общие помощники ============================

func _mat(color: Color) -> StandardMaterial3D:
	var mt := StandardMaterial3D.new()
	mt.albedo_color = color
	mt.roughness = 0.92
	return mt


func _append(mesh: ArrayMesh, prim: PrimitiveMesh, xform: Transform3D, color: Color) -> void:
	_append_arrays(mesh, prim.get_mesh_arrays(), xform, _mat(color))


func _append_tex(mesh: ArrayMesh, prim: PrimitiveMesh, xform: Transform3D, tex: Texture2D, scale := 0.45) -> void:
	var mt := StandardMaterial3D.new()
	mt.albedo_texture = tex
	mt.roughness = 0.92
	mt.uv1_triplanar = true
	mt.uv1_scale = Vector3(scale, scale, scale)
	_append_arrays(mesh, prim.get_mesh_arrays(), xform, mt)


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
	var mt := StandardMaterial3D.new()
	mt.albedo_texture = tex; mt.roughness = 0.92
	mt.uv1_triplanar = true; mt.uv1_scale = Vector3(scale, scale, scale)
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
func build_set(key: String) -> Array:
	var variant := int(key.substr(key.length() - 1))
	if key.begins_with("tank"):
		return [[tank(variant), 0.0]]
	if key.begins_with("apc"):
		return [[apc(variant), 0.0]]
	if key.begins_with("sold"):
		return [[soldier(variant), 0.0]]
	return civ_set(variant)
