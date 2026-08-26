extends Node3D
## Усадьбы вокруг сельских домов (стриминг чанками 512 м в радиусе ~1.2 км):
##   • забор-штакетник по периметру участка (MultiMesh панелей 2×1.3 м с процедурной текстурой),
##   • огород (полосы грядок) и мягкое AO-пятно под домом — Decal'ы, ложатся на склон,
##   • 1–3 плодовых дерева во дворе (меш лиственного из scatter, ×0.45).
## Участок: прямоугольник по ориентации дома, дом у «фасадной» стороны, огород сзади.

var main: Node3D
const CHUNK := 512.0
const RADIUS := 1200.0
var houses := {}              # Vector2i -> Array[Array] [x,z,w,d,ang]
var chunks := {}              # Vector2i -> Node3D
var gardens := {}             # Vector2i(чанк) -> Array[[cx, cz, yaw, hw, hd]] грядки (для исключения травы)
var _acc := 0.0
# инкрементальная генерация: очередь чанков, по HOUSES_PER_FRAME домов за кадр — без рывков над селом
var _q: Array[Vector2i] = []
var _cur: Vector2i
var _cur_houses: Array = []
var _cur_i := 0
var _cur_holder: Node3D = null
var _cur_fences: Array[Transform3D] = []
var _cur_trees: Array[Transform3D] = []
var _cur_wells: Array[Transform3D] = []
var _cur_lines: Array[Transform3D] = []
var _cur_folk: Array[Transform3D] = []
var _cur_folk_cols: Array[Color] = []
var _well_mesh: ArrayMesh
var _line_mesh: ArrayMesh
var _folk_mesh: ArrayMesh
var _cur_tree_cols: Array[Color] = []
var _cur_rng: RandomNumberGenerator = null
const HOUSES_PER_FRAME := 6
var _fence_mesh: QuadMesh
var _fence_mat: StandardMaterial3D
var _garden_tex: ImageTexture
var _ao_tex: ImageTexture
var _tree_mesh: ArrayMesh


func setup(m: Node3D, house_list: Array) -> void:
	main = m
	for hlist: Array in house_list:
		var c := Vector2i(int(floor(hlist[0] / CHUNK)), int(floor(hlist[1] / CHUNK)))
		if not houses.has(c): houses[c] = []
		houses[c].append(hlist)
	_fence_mesh = QuadMesh.new()
	_fence_mesh.size = Vector2(2.0, 1.3)
	_fence_mesh.center_offset = Vector3(0, 0.65, 0)
	_fence_mat = StandardMaterial3D.new()
	_fence_mat.albedo_texture = _fence_tex()
	_fence_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
	_fence_mat.alpha_scissor_threshold = 0.5
	_fence_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_fence_mat.roughness = 0.95
	_fence_mesh.material = _fence_mat
	_garden_tex = _garden_texture()
	_ao_tex = _ao_texture()
	var forest := main.get_node_or_null("Forest")
	if forest != null and forest.tree_meshes.size() > 2:
		_tree_mesh = forest.tree_meshes[2]
	_make_props()
	print("Yards: домов с участками %d в %d чанках" % [house_list.size(), houses.size()])


## Штакетник: вертикальные доски с просветами + две перекладины; серо-бурое выветренное дерево.
## Составной меш из примитивов: [mesh, Vector3 offset, Color, использовать instance color?]
func _combo(parts: Array) -> ArrayMesh:
	var out := ArrayMesh.new()
	for part: Array in parts:
		var arr: Array = part[0].get_mesh_arrays()
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		for i in verts.size():
			verts[i] += part[1]
		arr[Mesh.ARRAY_VERTEX] = verts
		out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var m := StandardMaterial3D.new()
		m.albedo_color = part[2]
		m.roughness = 0.9
		if part.size() > 3 and part[3]:
			m.vertex_color_use_as_albedo = true
		out.surface_set_material(out.get_surface_count() - 1, m)
	return out


## Микро-жизнь села: колодец, бельевая верёвка, житель.
func _make_props() -> void:
	var wood := Color(0.4, 0.3, 0.2)
	var b1 := BoxMesh.new(); b1.size = Vector3(1.3, 1.0, 1.3)                 # сруб колодца
	var p1 := BoxMesh.new(); p1.size = Vector3(0.12, 1.9, 0.12)
	var p2 := BoxMesh.new(); p2.size = Vector3(0.12, 1.9, 0.12)
	var rf := PrismMesh.new(); rf.size = Vector3(1.7, 0.6, 1.5)               # двускатная крыша
	_well_mesh = _combo([[b1, Vector3(0, 0.5, 0), Color(0.45, 0.42, 0.38)],
		[p1, Vector3(-0.6, 1.3, 0), wood], [p2, Vector3(0.6, 1.3, 0), wood],
		[rf, Vector3(0, 2.35, 0), Color(0.3, 0.24, 0.18)]])
	var post1 := BoxMesh.new(); post1.size = Vector3(0.09, 2.1, 0.09)
	var post2 := BoxMesh.new(); post2.size = Vector3(0.09, 2.1, 0.09)
	var wire := BoxMesh.new(); wire.size = Vector3(5.6, 0.02, 0.02)
	var parts := [[post1, Vector3(-2.8, 1.05, 0), wood], [post2, Vector3(2.8, 1.05, 0), wood],
		[wire, Vector3(0, 1.95, 0), Color(0.6, 0.6, 0.6)]]
	var cloth_cols := [Color(0.85, 0.85, 0.9), Color(0.7, 0.5, 0.5), Color(0.5, 0.6, 0.75), Color(0.9, 0.88, 0.7)]
	for i in 4:
		var c := BoxMesh.new(); c.size = Vector3(0.7, 0.9, 0.03)
		parts.append([c, Vector3(-2.0 + i * 1.3, 1.5, 0), cloth_cols[i]])
	_line_mesh = _combo(parts)
	var legs := BoxMesh.new(); legs.size = Vector3(0.34, 0.85, 0.24)
	var torso := BoxMesh.new(); torso.size = Vector3(0.44, 0.62, 0.28)
	var head := SphereMesh.new(); head.radius = 0.13; head.height = 0.26; head.radial_segments = 8; head.rings = 4
	_folk_mesh = _combo([[legs, Vector3(0, 0.42, 0), Color(0.25, 0.24, 0.28)],
		[torso, Vector3(0, 1.16, 0), Color(1, 1, 1), true],
		[head, Vector3(0, 1.62, 0), Color(0.85, 0.68, 0.55)]])


func _fence_tex() -> ImageTexture:
	var img := Image.create(128, 64, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.45, 0.40, 0.33, 0.0))
	var rng := RandomNumberGenerator.new(); rng.seed = 3
	var x := 1
	while x < 126:
		var wdt := rng.randi_range(4, 6)
		var c := 0.36 + rng.randf_range(-0.08, 0.1)
		var top := rng.randi_range(0, 6)
		for px in range(x, mini(x + wdt, 127)):
			for py in range(top, 64):
				var shade := c * (0.9 + 0.2 * rng.randf())
				img.set_pixel(px, py, Color(shade * 1.1, shade, shade * 0.85, 1.0))
		x += wdt + rng.randi_range(2, 4)
	for py in [18, 19, 20, 44, 45, 46]:
		for px in 128:
			img.set_pixel(px, py, Color(0.32, 0.28, 0.22, 1.0))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Огород: грядки — тёмно-бурые полосы с зелёной ботвой между.
func _garden_texture() -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	for y in 64:
		var row := (y / 6) % 2
		for x in 64:
			var n := rng.randf_range(-0.04, 0.04)
			var c := Color(0.22 + n, 0.16 + n, 0.10 + n, 0.85) if row == 0 else Color(0.20 + n, 0.30 + n, 0.12 + n, 0.8)
			img.set_pixel(x, y, c)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


## Мягкое тёмное пятно под домом (контакт с землёй + вытоптанный двор).
func _ao_texture() -> ImageTexture:
	var img := Image.create(64, 64, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 64:
			var d := Vector2(x - 31.5, y - 31.5).length() / 31.5
			var a := clampf(1.0 - d, 0.0, 1.0)
			a = a * a * 0.7
			img.set_pixel(x, y, Color(0.25, 0.22, 0.18, a))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)


func _process(dt: float) -> void:
	if main == null or main.cam == null:
		return
	_job_step()
	_acc += dt
	if _acc < 0.3:
		return
	_acc = 0.0
	var p: Vector3 = main.cam.global_position
	var agl: float = p.y - main.height_at(p.x, p.z)
	if agl > 900.0:
		return
	var cc := Vector2i(int(floor(p.x / CHUNK)), int(floor(p.z / CHUNK)))
	var r := int(ceil(RADIUS / CHUNK))
	for cy in range(cc.y - r, cc.y + r + 1):
		for cx in range(cc.x - r, cc.x + r + 1):
			var c := Vector2i(cx, cy)
			if chunks.has(c) or not houses.has(c) or _q.has(c) or (_cur_holder != null and _cur == c):
				continue
			var center := Vector2((cx + 0.5) * CHUNK, (cy + 0.5) * CHUNK)
			if center.distance_to(Vector2(p.x, p.z)) <= RADIUS:
				_q.append(c)
	for c: Vector2i in chunks.keys():
		var center := Vector2((c.x + 0.5) * CHUNK, (c.y + 0.5) * CHUNK)
		if center.distance_to(Vector2(p.x, p.z)) > RADIUS + CHUNK * 1.5:
			if chunks[c] != null: chunks[c].queue_free()
			chunks.erase(c)
			gardens.erase(c)


## Порция домов за кадр; чанк собирается за несколько кадров и добавляется атомарно.
func _job_step() -> void:
	if _cur_holder == null:
		if _q.is_empty():
			return
		# ближайший к камере чанк — первым
		var cp: Vector3 = main.cam.global_position
		var bi := 0; var bd := 1e18
		for qi in _q.size():
			var qc := _q[qi]
			var d := Vector2((qc.x + 0.5) * CHUNK - cp.x, (qc.y + 0.5) * CHUNK - cp.z).length_squared()
			if d < bd: bd = d; bi = qi
		_cur = _q[bi]
		_q.remove_at(bi)
		if chunks.has(_cur) or not houses.has(_cur):
			return
		_cur_houses = houses[_cur]
		_cur_i = 0
		_cur_holder = Node3D.new()
		_cur_fences = []; _cur_trees = []; _cur_tree_cols = []
		_cur_wells = []; _cur_lines = []; _cur_folk = []; _cur_folk_cols = []
		_cur_rng = RandomNumberGenerator.new()
		_cur_rng.seed = (int(_cur.x) * 92821) ^ (int(_cur.y) * 68917)
	var rng := _cur_rng
	var done := mini(_cur_i + HOUSES_PER_FRAME, _cur_houses.size())
	for hi in range(_cur_i, done):
		_gen_house(_cur_houses[hi], rng)
	_cur_i = done
	if _cur_i < _cur_houses.size():
		return
	# чанк готов — публикуем
	if not _cur_fences.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _fence_mesh
		mm.instance_count = _cur_fences.size()
		for i in _cur_fences.size(): mm.set_instance_transform(i, _cur_fences[i])
		var mi := MultiMeshInstance3D.new(); mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_cur_holder.add_child(mi)
	if _tree_mesh != null and not _cur_trees.is_empty():
		var tm := MultiMesh.new()
		tm.transform_format = MultiMesh.TRANSFORM_3D
		tm.use_colors = true
		tm.mesh = _tree_mesh
		tm.instance_count = _cur_trees.size()
		for i in _cur_trees.size():
			tm.set_instance_transform(i, _cur_trees[i]); tm.set_instance_color(i, _cur_tree_cols[i])
		var tmi := MultiMeshInstance3D.new(); tmi.multimesh = tm
		_cur_holder.add_child(tmi)
	for spec: Array in [[_well_mesh, _cur_wells, []], [_line_mesh, _cur_lines, []], [_folk_mesh, _cur_folk, _cur_folk_cols]]:
		var xs: Array = spec[1]
		if xs.is_empty(): continue
		var pm := MultiMesh.new()
		pm.transform_format = MultiMesh.TRANSFORM_3D
		var cols: Array = spec[2]
		pm.use_colors = not cols.is_empty()
		pm.mesh = spec[0]
		pm.instance_count = xs.size()
		for i in xs.size():
			pm.set_instance_transform(i, xs[i])
			if pm.use_colors: pm.set_instance_color(i, cols[i])
		var pmi := MultiMeshInstance3D.new(); pmi.multimesh = pm
		pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		_cur_holder.add_child(pmi)
	add_child(_cur_holder)
	chunks[_cur] = _cur_holder
	if OS.is_debug_build() and "--yardsdebug" in OS.get_cmdline_user_args():
		print("Yards: чанк %s домов %d заборов %d деревьев %d" % [_cur, _cur_houses.size(), _cur_fences.size(), _cur_trees.size()])
	_cur_holder = null


func _gen_house(h: Array, rng: RandomNumberGenerator) -> void:
	var x: float = h[0]; var z: float = h[1]; var w: float = h[2]; var d: float = h[3]; var ang: float = h[4]
	if rng.randf() < 0.25:
		return                                   # не у всех домов забор (и так плотно)
	var yaw := Basis(Vector3.UP, -ang)
	var pw := w + 10.0 + rng.randf_range(0.0, 6.0)
	var pd := d + 14.0 + rng.randf_range(0.0, 10.0)
	var back := Vector3(0, 0, 1)
	var center_off: Vector3 = yaw * (back * (pd * 0.5 - d * 0.5 - 3.0))
	var pc := Vector3(x, 0, z) + center_off
	var sides := [[Vector3(-pw * 0.5, 0, -pd * 0.5), Vector3(pw * 0.5, 0, -pd * 0.5)],
		[Vector3(pw * 0.5, 0, -pd * 0.5), Vector3(pw * 0.5, 0, pd * 0.5)],
		[Vector3(pw * 0.5, 0, pd * 0.5), Vector3(-pw * 0.5, 0, pd * 0.5)],
		[Vector3(-pw * 0.5, 0, pd * 0.5), Vector3(-pw * 0.5, 0, -pd * 0.5)]]
	var side_i := 0
	for sd: Array in sides:
		var a: Vector3 = sd[0]; var b: Vector3 = sd[1]
		var wa: Vector3 = pc + yaw * a
		var wb: Vector3 = pc + yaw * b
		# высота: по концам стороны + середина, панели интерполируются (3 запроса вместо 20+)
		var ha: float = main.height_at(wa.x, wa.z)
		var hb: float = main.height_at(wb.x, wb.z)
		var wm: Vector3 = (wa + wb) * 0.5
		var hm: float = main.height_at(wm.x, wm.z)
		var L := a.distance_to(b)
		var n := int(L / 2.0)
		var gate := rng.randi_range(0, maxi(n - 1, 0)) if side_i == 0 else -1
		var dirv: Vector3 = (wb - wa).normalized()
		var bs := Basis.looking_at(dirv.cross(Vector3.UP), Vector3.UP)
		for i in n:
			if i == gate: continue
			var t0 := (i + 0.5) / n
			var wp: Vector3 = wa.lerp(wb, t0)
			var gy := lerpf(ha, hm, t0 * 2.0) if t0 < 0.5 else lerpf(hm, hb, (t0 - 0.5) * 2.0)
			_cur_fences.append(Transform3D(bs, Vector3(wp.x, gy - 0.05, wp.z)))
		side_i += 1
	# огород — decal сзади участка
	var gl := pd * 0.45
	var gcenter: Vector3 = pc + yaw * Vector3(0, 0, pd * 0.5 - gl * 0.5 - 1.0)
	var gy0: float = main.height_at(gcenter.x, gcenter.z)
	if rng.randf() < 0.8:
		if not gardens.has(_cur): gardens[_cur] = []
		gardens[_cur].append([gcenter.x, gcenter.z, -ang, (pw - 2.0) * 0.5, gl * 0.5])
		var dec := Decal.new()
		dec.texture_albedo = _garden_tex
		dec.size = Vector3(pw - 2.0, 6.0, gl)
		dec.albedo_mix = 0.85
		dec.cull_mask = 1
		dec.distance_fade_enabled = true
		dec.distance_fade_begin = 500.0
		dec.distance_fade_length = 150.0
		dec.transform = Transform3D(yaw, Vector3(gcenter.x, gy0, gcenter.z))
		_cur_holder.add_child(dec)
	# AO-пятно под домом
	var ao := Decal.new()
	ao.texture_albedo = _ao_tex
	ao.size = Vector3(w + 6.0, 5.0, d + 6.0)
	ao.albedo_mix = 0.8
	ao.distance_fade_enabled = true
	ao.distance_fade_begin = 400.0
	ao.distance_fade_length = 120.0
	ao.transform = Transform3D(yaw, Vector3(x, main.height_at(x, z), z))
	_cur_holder.add_child(ao)
	# плодовые деревья
	var nt := rng.randi_range(0, 3)
	for i in nt:
		var lp := Vector3(rng.randf_range(-pw * 0.4, pw * 0.4), 0, rng.randf_range(d * 0.5 + 2.0, pd * 0.5 - 2.0) - (pd * 0.5 - d * 0.5 - 3.0))
		var wp: Vector3 = pc + yaw * lp
		var sc := rng.randf_range(0.35, 0.55)
		_cur_trees.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc, sc)), Vector3(wp.x, main.height_at(wp.x, wp.z) - 0.2, wp.z)))
		_cur_tree_cols.append(Color(rng.randf_range(0.85, 1.0), rng.randf_range(0.9, 1.1), rng.randf_range(0.8, 0.95)))
	# микро-жизнь: колодец / бельевая верёвка / житель во дворе
	if rng.randf() < 0.12:
		var wpp: Vector3 = pc + yaw * Vector3(pw * 0.35, 0, -pd * 0.25)
		_cur_wells.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(wpp.x, main.height_at(wpp.x, wpp.z), wpp.z)))
	if rng.randf() < 0.3:
		var lpp: Vector3 = pc + yaw * Vector3(rng.randf_range(-pw * 0.25, pw * 0.25), 0, pd * 0.18)
		_cur_lines.append(Transform3D(Basis(Vector3.UP, -ang + rng.randf_range(-0.4, 0.4)), Vector3(lpp.x, main.height_at(lpp.x, lpp.z), lpp.z)))
	if rng.randf() < 0.12:
		var fpp: Vector3 = pc + yaw * Vector3(rng.randf_range(-pw * 0.3, pw * 0.3), 0, -pd * 0.1)
		_cur_folk.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(fpp.x, main.height_at(fpp.x, fpp.z), fpp.z)))
		var shirts := [Color(0.75, 0.72, 0.65), Color(0.5, 0.55, 0.7), Color(0.65, 0.45, 0.4), Color(0.4, 0.5, 0.4), Color(0.8, 0.8, 0.85)]
		_cur_folk_cols.append(shirts[rng.randi_range(0, shirts.size() - 1)])


## Точка на грядках какого-нибудь огорода (локальные координаты участка)?
func in_garden(x: float, z: float) -> bool:
	var c := Vector2i(int(floor(x / CHUNK)), int(floor(z / CHUNK)))
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			for g: Array in gardens.get(c + Vector2i(dx, dz), []):
				var lx := x - float(g[0]); var lz := z - float(g[1])
				var ca := cos(float(g[2])); var sa := sin(float(g[2]))
				var rx := lx * ca - lz * sa; var rz := lx * sa + lz * ca   # обратный поворот Basis(UP, θ)
				if absf(rx) < float(g[3]) and absf(rz) < float(g[4]):
					return true
	return false
