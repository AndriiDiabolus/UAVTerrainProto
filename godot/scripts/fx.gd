extends Node3D
## Боевые эффекты: вспышка+обломки+подпалина при взрыве, пожар с дымным столбом на подбитой
## технике, пыль за движущейся техникой. Все текстуры процедурные, частицы — GPUParticles3D.

var main: Node3D
var _soft: ImageTexture          # мягкий круг для дыма/пыли
var _scorch: ImageTexture        # радиальная подпалина для Decal
var _scorches: Array = []        # живые декали (ограничиваем количество)
const MAX_SCORCH := 24


func setup(m: Node3D) -> void:
	main = m
	_soft = _radial_tex(64, Color(1, 1, 1), 1.0, 0.0)
	_scorch = _radial_tex(128, Color(0.05, 0.045, 0.04), 0.9, 0.0)


## Мягкий радиальный градиент: центр alpha a0 → край a1, с шумной кромкой.
func _radial_tex(s: int, col: Color, a0: float, a1: float) -> ImageTexture:
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	var rng := RandomNumberGenerator.new(); rng.seed = 5
	for y in s:
		for x in s:
			var d := Vector2(x - s / 2.0, y - s / 2.0).length() / (s / 2.0)
			var edge := 1.0 - smoothstep(0.55 + rng.randf() * 0.25, 1.0, d)
			var a := lerpf(a0, a1, clampf(d, 0.0, 1.0)) * edge
			img.set_pixel(x, y, Color(col.r, col.g, col.b, a))
	return ImageTexture.create_from_image(img)


func _billboard_mat(tex: Texture2D, emissive: bool = false) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_PARTICLES
	m.vertex_color_use_as_albedo = true
	m.albedo_texture = tex
	if emissive:
		m.emission_enabled = true
		m.emission = Color(1.0, 0.55, 0.15)
		m.emission_energy_multiplier = 2.5
	return m


func _pquad(size: float, mat: Material) -> QuadMesh:
	var q := QuadMesh.new()
	q.size = Vector2(size, size)
	q.material = mat
	return q


## Взрыв: вспышка света, сноп обломков, огненный клуб, подпалина на земле.
func explosion(pos: Vector3, big: bool) -> void:
	var k := 1.4 if big else 1.0
	# вспышка
	var l := OmniLight3D.new()
	l.position = pos + Vector3(0, 2, 0)
	l.light_color = Color(1.0, 0.7, 0.35)
	l.light_energy = 22.0 * k
	l.omni_range = 45.0 * k
	l.shadow_enabled = false
	add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.22)
	tw.tween_callback(l.queue_free)
	# обломки: тёмные кубики веером вверх
	var deb := GPUParticles3D.new()
	deb.one_shot = true; deb.emitting = true
	deb.amount = 26; deb.lifetime = 1.7; deb.explosiveness = 1.0
	var dm := ParticleProcessMaterial.new()
	dm.direction = Vector3(0, 1, 0); dm.spread = 65.0
	dm.initial_velocity_min = 9.0 * k; dm.initial_velocity_max = 24.0 * k
	dm.gravity = Vector3(0, -26.0, 0)
	dm.scale_min = 0.10; dm.scale_max = 0.34
	dm.angular_velocity_min = -360.0; dm.angular_velocity_max = 360.0
	deb.process_material = dm
	var bb := BoxMesh.new(); bb.size = Vector3(0.5, 0.5, 0.5)
	var bmat := StandardMaterial3D.new(); bmat.albedo_color = Color(0.16, 0.14, 0.12); bmat.roughness = 1.0
	bb.material = bmat
	deb.draw_pass_1 = bb
	deb.position = pos + Vector3(0, 1.0, 0)
	add_child(deb)
	_free_later(deb, 2.5)
	# огненный клуб → быстро гаснет в тёмный дым
	var fire := GPUParticles3D.new()
	fire.one_shot = true; fire.emitting = true
	fire.amount = 14; fire.lifetime = 0.9; fire.explosiveness = 1.0
	var fm := ParticleProcessMaterial.new()
	fm.direction = Vector3(0, 1, 0); fm.spread = 40.0
	fm.initial_velocity_min = 4.0; fm.initial_velocity_max = 9.0
	fm.gravity = Vector3(0, 3.0, 0)
	fm.scale_min = 1.2 * k; fm.scale_max = 2.2 * k
	var grad := Gradient.new()
	grad.set_color(0, Color(1.0, 0.72, 0.25, 0.95))
	grad.set_color(1, Color(0.16, 0.14, 0.13, 0.0))
	grad.add_point(0.35, Color(0.35, 0.24, 0.16, 0.75))
	var gt := GradientTexture1D.new(); gt.gradient = grad
	fm.color_ramp = gt
	fire.process_material = fm
	fire.draw_pass_1 = _pquad(2.6 * k, _billboard_mat(_soft, true))
	fire.position = pos + Vector3(0, 1.8, 0)
	add_child(fire)
	_free_later(fire, 1.6)
	# подпалина
	var d := Decal.new()
	d.texture_albedo = _scorch
	var r := 7.5 * k
	d.size = Vector3(r, 3.0, r)
	d.position = Vector3(pos.x, main.height_at(pos.x, pos.z), pos.z)
	d.rotate_y(randf() * TAU)
	d.albedo_mix = 0.85
	d.distance_fade_enabled = true
	d.distance_fade_begin = 500.0; d.distance_fade_length = 120.0
	add_child(d)
	_scorches.append(d)
	if _scorches.size() > MAX_SCORCH:
		var old: Decal = _scorches.pop_front()
		if is_instance_valid(old): old.queue_free()
	_free_later(d, 300.0)


## Пожар на подбитой технике: пламя + столб дыма, дрейфующий по ветру. Живёт с узлом.
func wreck_fire(node: Node3D) -> void:
	var wind := Vector3.ZERO
	if main.get("weather") != null:
		var w: Vector3 = main.weather.wind_vec()
		wind = Vector3(w.x, 0, w.z) * 0.45
	var fl := GPUParticles3D.new()
	fl.amount = 12; fl.lifetime = 0.7
	var fm := ParticleProcessMaterial.new()
	fm.direction = Vector3(0, 1, 0); fm.spread = 18.0
	fm.initial_velocity_min = 1.5; fm.initial_velocity_max = 3.0
	fm.gravity = Vector3(0, 4.0, 0)
	fm.scale_min = 0.6; fm.scale_max = 1.1
	var g1 := Gradient.new()
	g1.set_color(0, Color(1.0, 0.75, 0.2, 0.9)); g1.set_color(1, Color(0.9, 0.3, 0.05, 0.0))
	var gt1 := GradientTexture1D.new(); gt1.gradient = g1
	fm.color_ramp = gt1
	fl.process_material = fm
	fl.draw_pass_1 = _pquad(1.5, _billboard_mat(_soft, true))
	fl.position = Vector3(0, 1.6, 0)
	node.add_child(fl)
	var sm := GPUParticles3D.new()
	sm.amount = 22; sm.lifetime = 7.0
	var smm := ParticleProcessMaterial.new()
	smm.direction = Vector3(0, 1, 0); smm.spread = 10.0
	smm.initial_velocity_min = 2.0; smm.initial_velocity_max = 3.2
	smm.gravity = Vector3(0, 0.9, 0) + wind
	smm.scale_min = 1.4; smm.scale_max = 2.4
	var g2 := Gradient.new()
	g2.set_color(0, Color(0.08, 0.075, 0.07, 0.55)); g2.set_color(1, Color(0.25, 0.24, 0.23, 0.0))
	var gt2 := GradientTexture1D.new(); gt2.gradient = g2
	smm.color_ramp = gt2
	sm.process_material = smm
	sm.draw_pass_1 = _pquad(3.4, _billboard_mat(_soft))
	sm.position = Vector3(0, 2.2, 0)
	node.add_child(sm)


## Пыль за движущейся техникой; вызывающий включает/выключает .emitting.
## Частицы в мировых координатах: клубы остаются на дороге и растут шлейфом,
## а не «кружками возле машины». Появление через fade-in, размер растёт по кривой.
func dust(node: Node3D) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 34; p.lifetime = 3.2; p.emitting = false
	p.local_coords = false                 # ключевое: шлейф отстаёт от машины
	p.visibility_aabb = AABB(Vector3(-40, -10, -40), Vector3(80, 30, 80))
	var m := ParticleProcessMaterial.new()
	m.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	m.emission_sphere_radius = 0.9
	m.direction = Vector3(0, 1, 0); m.spread = 70.0
	m.initial_velocity_min = 0.3; m.initial_velocity_max = 1.1
	m.gravity = Vector3(0, 0.55, 0)
	m.scale_min = 0.5; m.scale_max = 0.9
	var sc := Curve.new()                  # клуб растёт всю жизнь: 0.3 → 1.0 → 2.6
	sc.add_point(Vector2(0.0, 0.3)); sc.add_point(Vector2(0.35, 1.0)); sc.add_point(Vector2(1.0, 2.6))
	var sct := CurveTexture.new(); sct.curve = sc
	m.scale_curve = sct
	var g := Gradient.new()                # fade-in → пик → растворение
	g.set_color(0, Color(0.5, 0.44, 0.33, 0.0))
	g.add_point(0.18, Color(0.52, 0.45, 0.34, 0.3))
	g.set_color(1, Color(0.56, 0.51, 0.42, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = g
	m.color_ramp = gt
	p.process_material = m
	p.draw_pass_1 = _pquad(2.0, _billboard_mat(_soft))
	p.position = Vector3(-2.4, 0.4, 0)     # за кормой (эмиттер едет с машиной, клубы — нет)
	node.add_child(p)
	return p


func _free_later(n: Node, sec: float) -> void:
	get_tree().create_timer(sec).timeout.connect(func() -> void:
		if is_instance_valid(n): n.queue_free())
