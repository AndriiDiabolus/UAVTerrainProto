extends Node3D
## Дым из труб: пул GPUParticles3D прилипает к ближайшим дымящим трубам вокруг камеры.

const POOL := 10
const RADIUS := 260.0

var _main: Node3D
var _pos: PackedVector3Array
var _emit: Array[GPUParticles3D] = []
var _accum := 0.0


func setup(main: Node3D, positions: PackedVector3Array) -> void:
	_main = main
	_pos = positions
	var puff := _puff_texture()
	var mesh := QuadMesh.new()
	mesh.size = Vector2(2.4, 2.4)
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	mat.albedo_texture = puff
	mat.albedo_color = Color(0.72, 0.72, 0.74, 0.5)
	mat.blend_mode = BaseMaterial3D.BLEND_MODE_MIX
	mesh.material = mat
	for i in POOL:
		var p := GPUParticles3D.new()
		p.amount = 14
		p.lifetime = 4.5
		p.draw_pass_1 = mesh
		p.visibility_aabb = AABB(Vector3(-6, -2, -6), Vector3(12, 30, 12))
		p.process_material = _proc()
		p.emitting = false
		add_child(p)
		_emit.append(p)


func _proc() -> ParticleProcessMaterial:
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0)
	pm.spread = 12.0
	pm.initial_velocity_min = 1.2
	pm.initial_velocity_max = 2.2
	pm.gravity = Vector3(0, 0.6, 0)          # лёгкий подъём
	pm.damping_min = 0.2; pm.damping_max = 0.5
	pm.scale_min = 0.6; pm.scale_max = 1.2
	var curve := Curve.new()
	curve.add_point(Vector2(0.0, 0.3))
	curve.add_point(Vector2(0.4, 1.0))
	curve.add_point(Vector2(1.0, 2.4))
	var ct := CurveTexture.new(); ct.curve = curve
	pm.scale_curve = ct
	var grad := Gradient.new()
	grad.set_color(0, Color(0.8, 0.8, 0.82, 0.0))
	grad.set_color(1, Color(0.6, 0.6, 0.63, 0.0))
	grad.add_point(0.2, Color(0.82, 0.82, 0.84, 0.55))
	var gt := GradientTexture1D.new(); gt.gradient = grad
	pm.color_ramp = gt
	return pm


## Мягкая круглая текстура-клякса для частицы дыма.
func _puff_texture() -> ImageTexture:
	var n := 64
	var img := Image.create(n, n, false, Image.FORMAT_RGBA8)
	var c := (n - 1) * 0.5
	for y in n:
		for x in n:
			var dd := Vector2(x - c, y - c).length() / c
			var a := clampf(1.0 - dd, 0.0, 1.0)
			a = a * a
			img.set_pixel(x, y, Color(1, 1, 1, a))
	return ImageTexture.create_from_image(img)


func _process(dt: float) -> void:
	if _main == null or _main.cam == null or _pos.is_empty():
		return
	_accum += dt
	if _accum < 0.4:
		return
	_accum = 0.0
	# дым слабее ночью (топят вечером/утром — оставим лёгкий всегда)
	var wind := Vector3.ZERO
	if _main.get("weather") != null:
		wind = _main.weather.wind_vec()
	var cam: Vector3 = _main.cam.global_position
	var best: Array = []
	for i in _pos.size():
		var d2 := cam.distance_squared_to(_pos[i])
		if d2 > RADIUS * RADIUS:
			continue
		if best.size() < POOL:
			best.append([d2, i])
			if best.size() == POOL: best.sort_custom(func(a, b): return a[0] < b[0])
		elif d2 < best[POOL - 1][0]:
			best[POOL - 1] = [d2, i]; best.sort_custom(func(a, b): return a[0] < b[0])
	for k in _emit.size():
		if k < best.size():
			var e := _emit[k]
			e.global_position = _pos[best[k][1]]
			var pm := e.process_material as ParticleProcessMaterial
			pm.gravity = Vector3(wind.x * 0.25, 0.6, wind.z * 0.25)
			e.emitting = true
		else:
			_emit[k].emitting = false
