extends Node3D
## Придорожные объекты из OSM-линий: уличные фонари (светятся ночью) и столбы ЛЭП.

# фонари — вдоль улиц; столбы — вдоль дорог покрупнее
const LAMP_CLASSES := ["residential", "unclassified", "tertiary", "service", "secondary"]
const POLE_CLASSES := ["primary", "secondary", "tertiary", "unclassified", "track"]
const LAMP_STEP := 42.0
const POLE_STEP := 55.0

var pool := 24               # живых источников света вокруг камеры
const LIGHT_RANGE := 30.0

var lamp_head_mat: StandardMaterial3D
var _main: Node3D
var _lamp_pos: PackedVector3Array = PackedVector3Array()
var _lamp_grid := {}            # Vector2i(256 м) -> PackedInt32Array индексов фонарей — не перебирать 27k каждые 0.3 с
var _lights: Array[OmniLight3D] = []
var _accum := 0.0


func setup(main: Node3D) -> void:
	_main = main
	var f := FileAccess.get_file_as_string(main.asset_path("roads.json"))
	if f.is_empty():
		return
	var roads: Array = JSON.parse_string(f)["roads"]
	var t0 := Time.get_ticks_msec()

	var lamps: Array[Transform3D] = []
	var poles: Array[Transform3D] = []
	var wireV := PackedVector3Array()
	for r: Dictionary in roads:
		var cls: String = r["c"]
		if cls in LAMP_CLASSES:
			_walk(main, r["p"], LAMP_STEP, 3.0, lamps)
		if cls in POLE_CLASSES:
			var pr: Array[Transform3D] = []
			_walk(main, r["p"], POLE_STEP, -4.0, pr)
			poles.append_array(pr)
			_wire(pr, wireV)

	lamp_head_mat = _emissive()
	_mm("Lamps", _lamp_mesh(), lamps)
	_mm("Poles", _pole_mesh(), poles)
	_wire_mesh(wireV)
	main._lamp_mat = lamp_head_mat

	# препятствия для дрона: столбы толще, фонари тоньше
	for t: Transform3D in poles:
		main.col_add_cyl(t.origin.x, t.origin.z, 0.5, t.origin.y + 8.5)
	for t: Transform3D in lamps:
		main.col_add_cyl(t.origin.x, t.origin.z, 0.35, t.origin.y + 5.0)

	# позиции плафонов для стриминга живого света
	for t in lamps:
		_lamp_pos.append(t.origin + Vector3(0, 4.8, 0) + t.basis * Vector3(0.9, 0, 0))
	for i in _lamp_pos.size():
		var gk := Vector2i(int(floor(_lamp_pos[i].x / 256.0)), int(floor(_lamp_pos[i].z / 256.0)))
		if not _lamp_grid.has(gk): _lamp_grid[gk] = PackedInt32Array()
		_lamp_grid[gk].append(i)
	for i in pool:
		var l := OmniLight3D.new()
		l.light_color = Color(1.0, 0.80, 0.48)
		l.omni_range = LIGHT_RANGE
		l.omni_attenuation = 1.6
		l.light_energy = 0.0
		l.shadow_enabled = false
		l.visible = false
		add_child(l)
		_lights.append(l)
	print("Props: фонарей %d, столбов %d за %d мс" % [lamps.size(), poles.size(), Time.get_ticks_msec() - t0])


## Пул живого света прилипает к ближайшим фонарям; накал по времени суток.
func _process(dt: float) -> void:
	if _main == null or _main.cam == null or _lamp_pos.is_empty():
		return
	_accum += dt
	if _accum < 0.3:
		return
	_accum = 0.0
	var night := 0.0
	if _main._lamp_mat != null:
		night = _main._lamp_mat.emission_energy_multiplier
	if night <= 0.05:                       # день — свет выключен
		for l in _lights:
			l.visible = false
		return
	# найти pool ближайших плафонов к камере; с высоты пул сокращается — отдельные пятна света
	# на земле сверху неразличимы (emissive-плафоны остаются и дают вид ночного села)
	var cam: Vector3 = _main.cam.global_position
	var agl: float = cam.y - _main.height_at(cam.x, cam.z)
	var eff_pool: int = pool if agl <= 120.0 else maxi(4, int(lerpf(float(pool), 4.0, clampf((agl - 120.0) / 380.0, 0.0, 1.0))))
	var best: Array = []                    # [dist2, index]
	var gc := Vector2i(int(floor(cam.x / 256.0)), int(floor(cam.z / 256.0)))
	var cand := PackedInt32Array()
	for dx in [-1, 0, 1]:
		for dz in [-1, 0, 1]:
			cand.append_array(_lamp_grid.get(gc + Vector2i(dx, dz), PackedInt32Array()))
	for i in cand:
		var d2 := cam.distance_squared_to(_lamp_pos[i])
		if d2 > 300.0 * 300.0:
			continue
		if best.size() < eff_pool:
			best.append([d2, i])
			if best.size() == eff_pool:
				best.sort_custom(func(a, b): return a[0] < b[0])
		elif d2 < best[eff_pool - 1][0]:
			best[eff_pool - 1] = [d2, i]
			best.sort_custom(func(a, b): return a[0] < b[0])
	var energy := clampf(night * 1.1, 0.0, 5.0)
	for k in _lights.size():
		if k < best.size():
			_lights[k].global_position = _lamp_pos[best[k][1]]
			_lights[k].light_energy = energy
			_lights[k].visible = true
		else:
			_lights[k].visible = false


## Расставляет объекты вдоль полилинии с равным шагом, со сдвигом вбок (offset).
func _walk(main: Node3D, pts: Array, step: float, offset: float, out: Array) -> void:
	var leftover := step * 0.5
	for k in range(1, pts.size()):
		var a := Vector2(pts[k - 1][0], pts[k - 1][1])
		var b := Vector2(pts[k][0], pts[k][1])
		var seg := b - a
		var L := seg.length()
		if L < 0.01:
			continue
		var dir := seg / L
		var perp := Vector2(-dir.y, dir.x)
		var pos := leftover
		while pos < L:
			var c := a + dir * pos + perp * offset
			var y: float = main.height_at(c.x, c.y)
			out.append(Transform3D(Basis(Vector3.UP, atan2(dir.y, dir.x)), Vector3(c.x, y, c.y)))
			pos += step
		leftover = pos - L


## Провода между соседними столбами вдоль дороги (провисающие линии).
func _wire(pr: Array, V: PackedVector3Array) -> void:
	for i in range(pr.size() - 1):
		var a: Transform3D = pr[i]
		var b: Transform3D = pr[i + 1]
		if a.origin.distance_to(b.origin) > 90.0:
			continue
		for side in [-0.85, 0.85]:
			var pa: Vector3 = a.origin + a.basis * Vector3(side, 7.85, 0)
			var pb: Vector3 = b.origin + b.basis * Vector3(side, 7.85, 0)
			var prev := pa
			for s in range(1, 6):
				var t := float(s) / 5.0
				var pt := pa.lerp(pb, t)
				pt.y -= 0.7 * sin(PI * t)          # провис
				V.append(prev); V.append(pt)
				prev = pt


func _wire_mesh(V: PackedVector3Array) -> void:
	if V.is_empty():
		return
	var arr := []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = V
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_LINES, arr)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(0.06, 0.06, 0.07)
	mesh.surface_set_material(0, mat)
	var mi := MeshInstance3D.new()
	mi.name = "Wires"
	mi.mesh = mesh
	add_child(mi)


func _mm(nm: String, mesh: ArrayMesh, xforms: Array) -> void:
	if xforms.is_empty():
		return
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.mesh = mesh
	mm.instance_count = xforms.size()
	for i in xforms.size():
		mm.set_instance_transform(i, xforms[i])
	var mi := MultiMeshInstance3D.new()
	mi.name = nm
	mi.multimesh = mm
	add_child(mi)


func _emissive() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(1.0, 0.92, 0.7)
	m.emission_enabled = true
	m.emission = Color(1.0, 0.82, 0.48)
	m.emission_energy_multiplier = 0.0     # днём выключено; weather поднимает к ночи
	return m


func _metal() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.22, 0.22, 0.24)
	m.roughness = 0.7; m.metallic = 0.3
	return m


func _wood() -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(0.36, 0.30, 0.24)
	m.roughness = 1.0
	return m


func _part(mesh: ArrayMesh, prim: PrimitiveMesh, xform: Transform3D, mat: Material) -> void:
	var arr: Array = prim.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var n: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	for i in v.size():
		v[i] = xform * v[i]
		n[i] = xform.basis * n[i]
	arr[Mesh.ARRAY_VERTEX] = v
	arr[Mesh.ARRAY_NORMAL] = n
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(mesh.get_surface_count() - 1, mat)


func _cyl(r: float, h: float) -> CylinderMesh:
	var m := CylinderMesh.new()
	m.top_radius = r; m.bottom_radius = r * 1.15; m.height = h
	m.radial_segments = 6; m.rings = 1
	return m


func _box(x: float, y: float, z: float) -> BoxMesh:
	var m := BoxMesh.new(); m.size = Vector3(x, y, z); return m


## Фонарь: столбик + вынос + светящийся плафон.
func _lamp_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var metal := _metal()
	_part(mesh, _cyl(0.09, 5.0), Transform3D(Basis(), Vector3(0, 2.5, 0)), metal)
	_part(mesh, _box(0.9, 0.1, 0.1), Transform3D(Basis(), Vector3(0.45, 4.95, 0)), metal)
	_part(mesh, _box(0.6, 0.42, 0.5), Transform3D(Basis(), Vector3(0.9, 4.8, 0)), lamp_head_mat)
	return mesh


## Столб ЛЭП: высокая опора + траверса.
func _pole_mesh() -> ArrayMesh:
	var mesh := ArrayMesh.new()
	var wood := _wood()
	_part(mesh, _cyl(0.13, 8.5), Transform3D(Basis(), Vector3(0, 4.25, 0)), wood)
	_part(mesh, _box(1.8, 0.14, 0.14), Transform3D(Basis(), Vector3(0, 7.9, 0)), wood)
	_part(mesh, _box(1.2, 0.12, 0.12), Transform3D(Basis(), Vector3(0, 7.4, 0)), wood)
	return mesh
