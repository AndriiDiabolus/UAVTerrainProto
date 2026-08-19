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
	print("Yards: домов с участками %d в %d чанках" % [house_list.size(), houses.size()])


## Штакетник: вертикальные доски с просветами + две перекладины; серо-бурое выветренное дерево.
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
	var built := 0
	for cy in range(cc.y - r, cc.y + r + 1):
		for cx in range(cc.x - r, cc.x + r + 1):
			var c := Vector2i(cx, cy)
			if chunks.has(c) or not houses.has(c):
				continue
			var center := Vector2((cx + 0.5) * CHUNK, (cy + 0.5) * CHUNK)
			if center.distance_to(Vector2(p.x, p.z)) <= RADIUS and built < 2:
				_gen(c); built += 1
	for c: Vector2i in chunks.keys():
		var center := Vector2((c.x + 0.5) * CHUNK, (c.y + 0.5) * CHUNK)
		if center.distance_to(Vector2(p.x, p.z)) > RADIUS + CHUNK * 1.5:
			if chunks[c] != null: chunks[c].queue_free()
			chunks.erase(c)
			gardens.erase(c)


func _gen(c: Vector2i) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = (int(c.x) * 92821) ^ (int(c.y) * 68917)
	var holder := Node3D.new()
	add_child(holder)
	var fences: Array[Transform3D] = []
	var trees: Array[Transform3D] = []
	var tree_cols: Array[Color] = []
	for h: Array in houses[c]:
		var x: float = h[0]; var z: float = h[1]; var w: float = h[2]; var d: float = h[3]; var ang: float = h[4]
		if rng.randf() < 0.25:
			continue                                 # не у всех домов забор (и так плотно)
		var yaw := Basis(Vector3.UP, -ang)
		# участок: ширина по фасаду w+10, вглубь d+16; дом смещён к фасадной стороне
		var pw := w + 10.0 + rng.randf_range(0.0, 6.0)
		var pd := d + 14.0 + rng.randf_range(0.0, 10.0)
		var back := Vector3(0, 0, 1)                 # «назад» в локальных координатах дома
		var center_off: Vector3 = yaw * (back * (pd * 0.5 - d * 0.5 - 3.0))
		var pc := Vector3(x, 0, z) + center_off
		# забор по периметру: 4 стороны, панели по 2 м, с калиткой-проёмом на фасаде
		var sides := [[Vector3(-pw * 0.5, 0, -pd * 0.5), Vector3(pw * 0.5, 0, -pd * 0.5)],
			[Vector3(pw * 0.5, 0, -pd * 0.5), Vector3(pw * 0.5, 0, pd * 0.5)],
			[Vector3(pw * 0.5, 0, pd * 0.5), Vector3(-pw * 0.5, 0, pd * 0.5)],
			[Vector3(-pw * 0.5, 0, pd * 0.5), Vector3(-pw * 0.5, 0, -pd * 0.5)]]
		var side_i := 0
		for sd: Array in sides:
			var a: Vector3 = sd[0]; var b: Vector3 = sd[1]
			var L := a.distance_to(b)
			var n := int(L / 2.0)
			var gate := rng.randi_range(0, maxi(n - 1, 0)) if side_i == 0 else -1
			for i in n:
				if i == gate: continue
				var t0 := (i + 0.5) / n
				var lp: Vector3 = a.lerp(b, t0)
				var wp: Vector3 = pc + yaw * lp
				var gy: float = main.height_at(wp.x, wp.z)
				var dirv: Vector3 = (yaw * (b - a)).normalized()
				var bs := Basis(Vector3.UP, atan2(-dirv.z, dirv.x) + PI * 0.5)  # квад в плоскости XY смотрит по -Z → развернуть вдоль стороны
				bs = Basis.looking_at(dirv.cross(Vector3.UP), Vector3.UP)
				fences.append(Transform3D(bs, Vector3(wp.x, gy - 0.05, wp.z)))
			side_i += 1
		# огород — decal сзади участка
		var gl := pd * 0.45
		var gcenter: Vector3 = pc + yaw * Vector3(0, 0, pd * 0.5 - gl * 0.5 - 1.0)
		var gy0: float = main.height_at(gcenter.x, gcenter.z)
		if rng.randf() < 0.8:
			if not gardens.has(c): gardens[c] = []
			gardens[c].append([gcenter.x, gcenter.z, -ang, (pw - 2.0) * 0.5, gl * 0.5])
			var dec := Decal.new()
			dec.texture_albedo = _garden_tex
			dec.size = Vector3(pw - 2.0, 6.0, gl)
			dec.albedo_mix = 0.85
			dec.cull_mask = 1
			dec.distance_fade_enabled = true
			dec.distance_fade_begin = 500.0
			dec.distance_fade_length = 150.0
			dec.transform = Transform3D(yaw, Vector3(gcenter.x, gy0, gcenter.z))
			holder.add_child(dec)
		# AO-пятно под домом
		var ao := Decal.new()
		ao.texture_albedo = _ao_tex
		ao.size = Vector3(w + 6.0, 5.0, d + 6.0)
		ao.albedo_mix = 0.8
		ao.distance_fade_enabled = true
		ao.distance_fade_begin = 400.0
		ao.distance_fade_length = 120.0
		ao.transform = Transform3D(yaw, Vector3(x, main.height_at(x, z), z))
		holder.add_child(ao)
		# плодовые деревья во дворе/огороде
		var nt := rng.randi_range(0, 3)
		for i in nt:
			var lp := Vector3(rng.randf_range(-pw * 0.4, pw * 0.4), 0, rng.randf_range(d * 0.5 + 2.0, pd * 0.5 - 2.0) - (pd * 0.5 - d * 0.5 - 3.0))
			var wp: Vector3 = pc + yaw * lp
			var sc := rng.randf_range(0.35, 0.55)
			trees.append(Transform3D(Basis(Vector3.UP, rng.randf() * TAU).scaled(Vector3(sc, sc, sc)), Vector3(wp.x, main.height_at(wp.x, wp.z) - 0.2, wp.z)))
			tree_cols.append(Color(rng.randf_range(0.85, 1.0), rng.randf_range(0.9, 1.1), rng.randf_range(0.8, 0.95)))
	if not fences.is_empty():
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.mesh = _fence_mesh
		mm.instance_count = fences.size()
		for i in fences.size(): mm.set_instance_transform(i, fences[i])
		var mi := MultiMeshInstance3D.new(); mi.multimesh = mm
		mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		holder.add_child(mi)
	if _tree_mesh != null and not trees.is_empty():
		var tm := MultiMesh.new()
		tm.transform_format = MultiMesh.TRANSFORM_3D
		tm.use_colors = true
		tm.mesh = _tree_mesh
		tm.instance_count = trees.size()
		for i in trees.size():
			tm.set_instance_transform(i, trees[i]); tm.set_instance_color(i, tree_cols[i])
		var tmi := MultiMeshInstance3D.new(); tmi.multimesh = tm
		holder.add_child(tmi)
	chunks[c] = holder


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
