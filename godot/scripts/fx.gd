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


## Биллборд для ОДИНОЧНОГО меша (не частиц): вспышки, дульный огонь.
func _flash_mat(col: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	m.albedo_texture = _soft
	m.albedo_color = col
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 4.0
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
	deb.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
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


# ============================ БОЕВЫЕ VFX (гиперреализм) ============================
# Оружейный огонь: летящие болиды-трассеры (не мгновенные линии), дульные вспышки с дымом.
# Профили по типу стрелка: ЗПУ танка (12.7), КПВТ БТР (14.5), АК пехоты.
const GUN_PROFILES := {
	"tank":    {"rounds": 7, "rate": 0.09, "speed": 340.0, "tracer_every": 3, "size": 0.55,
		"col": Color(0.65, 1.0, 0.45), "flash": 2.6, "dim": Color(1.0, 0.75, 0.4, 0.55)},
	"apc":     {"rounds": 5, "rate": 0.13, "speed": 380.0, "tracer_every": 2, "size": 0.7,
		"col": Color(1.0, 0.45, 0.3), "flash": 3.2, "dim": Color(1.0, 0.6, 0.35, 0.6)},
	"soldier": {"rounds": 4, "rate": 0.1, "speed": 280.0, "tracer_every": 4, "size": 0.3,
		"col": Color(1.0, 0.8, 0.45), "flash": 0.9, "dim": Color(1.0, 0.8, 0.5, 0.35)},
}


## Очередь по цели: болиды вылетают по одному с темпом rate, летят с реальной скоростью.
## targets_pts — конечная точка каждой пули (промахи уже с разбросом от вызывающего).
func gun_burst(origin: Vector3, targets_pts: Array, kind: String) -> void:
	var prof: Dictionary = GUN_PROFILES.get(kind, GUN_PROFILES["soldier"])
	for i in targets_pts.size():
		var delay := float(i) * float(prof.rate)
		get_tree().create_timer(delay).timeout.connect(func() -> void:
			if not is_instance_valid(self): return
			muzzle_flash(origin, (targets_pts[i] as Vector3 - origin).normalized(), float(prof.flash), prof.dim)
			var tracer := (i % int(prof.tracer_every)) == 0
			_bolt(origin, targets_pts[i], float(prof.speed), float(prof.size), prof.col, tracer))


## Болид: короткий яркий штрих, летящий из origin в tgt с реальной скоростью пули.
func _bolt(origin: Vector3, tgt: Vector3, speed: float, size: float, col: Color, tracer: bool) -> void:
	var dir := (tgt - origin).normalized()
	var dist := origin.distance_to(tgt)
	var t_fly := dist / speed
	var mi := MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.16 * size; cyl.bottom_radius = 0.16 * size
	cyl.height = (13.0 if tracer else 4.5) * size          # трассер длиннее и ярче
	cyl.radial_segments = 5
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.albedo_color = col if tracer else Color(col.r, col.g, col.b, 0.5)
	m.emission_enabled = true
	m.emission = col
	m.emission_energy_multiplier = 16.0 if tracer else 3.0
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	cyl.material = m
	mi.mesh = cyl
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# цилиндр осью Y → развернуть вдоль полёта
	mi.global_position = origin
	var up := Vector3.UP if absf(dir.dot(Vector3.UP)) < 0.98 else Vector3.RIGHT
	mi.look_at_from_position(origin, tgt, up)
	mi.rotate_object_local(Vector3.RIGHT, PI * 0.5)
	add_child(mi)
	var tw := create_tween()
	tw.tween_property(mi, "global_position", tgt, t_fly)
	tw.tween_callback(mi.queue_free)


## Дульная вспышка: конус света + billboard-вспышка на 2 кадра + клуб дыма у среза.
func muzzle_flash(pos: Vector3, dir: Vector3, size: float, smoke_col: Color) -> void:
	var l := OmniLight3D.new()
	l.position = pos + dir * 0.8
	l.light_color = Color(1.0, 0.8, 0.45)
	l.light_energy = 3.5 * size
	l.omni_range = 7.0 + 3.0 * size
	l.shadow_enabled = false
	add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, 0.07)
	tw.tween_callback(l.queue_free)
	var fmesh := MeshInstance3D.new()
	fmesh.mesh = _pquad(0.35 * size, _flash_mat(Color(1.0, 0.9, 0.6, 1.0)))
	fmesh.position = pos + dir * 0.6
	fmesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(fmesh)
	_free_later(fmesh, 0.06)
	var p := GPUParticles3D.new()
	p.one_shot = true; p.emitting = true
	p.amount = 3; p.lifetime = 0.7; p.explosiveness = 1.0
	var pm := ParticleProcessMaterial.new()
	pm.direction = dir; pm.spread = 16.0
	pm.initial_velocity_min = 1.2; pm.initial_velocity_max = 2.6
	pm.gravity = Vector3(0, 0.7, 0)
	pm.scale_min = 0.25 * size; pm.scale_max = 0.5 * size
	var g := Gradient.new()
	g.set_color(0, smoke_col); g.set_color(1, Color(smoke_col.r, smoke_col.g, smoke_col.b, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	p.draw_pass_1 = _pquad(0.8, _billboard_mat(_soft))
	p.position = pos + dir * 0.9
	add_child(p)
	_free_later(p, 1.0)


## Попадание стрелковым по дрону: сноп искр + мелкие осколки пластика, без взрыва.
func drone_hit(pos: Vector3) -> void:
	var sp := GPUParticles3D.new()
	sp.one_shot = true; sp.emitting = true
	sp.amount = 22; sp.lifetime = 0.5; sp.explosiveness = 1.0
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.1
	pm.direction = Vector3(0, 0.4, 0); pm.spread = 180.0
	pm.initial_velocity_min = 5.0; pm.initial_velocity_max = 14.0
	pm.gravity = Vector3(0, -14.0, 0)
	pm.scale_min = 0.035; pm.scale_max = 0.08
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.85, 0.45, 1.0)); g.set_color(1, Color(1.0, 0.4, 0.1, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = g
	pm.color_ramp = gt
	sp.process_material = pm
	sp.draw_pass_1 = _pquad(0.3, _billboard_mat(_soft, true))
	sp.position = pos
	add_child(sp)
	_free_later(sp, 0.9)


## Шлейф повреждённого дрона: тонкий серый дым из корпуса (LiPo/регулятор дымит).
func damage_trail(node: Node3D) -> GPUParticles3D:
	var p := GPUParticles3D.new()
	p.amount = 26; p.lifetime = 1.6
	p.local_coords = false
	p.visibility_aabb = AABB(Vector3(-30, -30, -30), Vector3(60, 60, 60))
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0); pm.spread = 24.0
	pm.initial_velocity_min = 0.4; pm.initial_velocity_max = 1.0
	pm.gravity = Vector3(0, 1.6, 0)
	pm.scale_min = 0.2; pm.scale_max = 0.45
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.35)); sc.add_point(Vector2(1.0, 1.8))
	var sct := CurveTexture.new(); sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, Color(0.35, 0.35, 0.36, 0.5)); g.set_color(1, Color(0.5, 0.5, 0.52, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	p.draw_pass_1 = _pquad(0.7, _billboard_mat(_soft))
	node.add_child(p)
	return p


## Гибель дрона — УНИКАЛЬНАЯ по типу:
##  fpv7/fpv5 — подрыв БЧ: резкая бело-оранжевая вспышка, чёрный клуб, разлёт лучей/пропов;
##  mavic — LiPo-пожар: фонтан искр, бело-серый едкий дым, без огненного шара;
##  mship — двухступенчато: хлопок + факел батарей и густой белый дым;
##  wing/shark — без БЧ: пыль удара, куски пенопласта, белый дымок.
func drone_explosion(pos: Vector3, kind: String) -> void:
	match kind:
		"fpv7", "fpv5":
			var k := 1.0 if kind == "fpv7" else 0.7
			_flash(pos, Color(1.0, 0.85, 0.6), 30.0 * k, 55.0 * k, 0.16)
			_burst_smoke(pos, Color(0.09, 0.085, 0.08, 0.9), 18, 2.8 * k, 6.0)
			_shrapnel(pos, 24, 26.0 * k, Color(0.13, 0.13, 0.13), 0.05, 0.16)
			_shrapnel(pos, 8, 14.0 * k, Color(0.9, 0.9, 0.92), 0.03, 0.1)   # пропеллеры/карбон
		"mavic":
			_flash(pos, Color(1.0, 0.95, 0.8), 8.0, 20.0, 0.1)
			_spark_fountain(pos, 2.2)
			_burst_smoke(pos, Color(0.82, 0.82, 0.8, 0.7), 14, 1.6, 6.0)   # белый едкий LiPo-дым
			_shrapnel(pos, 10, 9.0, Color(0.75, 0.75, 0.78), 0.04, 0.1)
		"mship":
			_flash(pos, Color(1.0, 0.8, 0.5), 26.0, 50.0, 0.14)
			_spark_fountain(pos, 3.4)
			_burst_smoke(pos, Color(0.85, 0.85, 0.83, 0.75), 20, 2.6, 8.0)
			_burst_smoke(pos, Color(0.12, 0.11, 0.1, 0.7), 8, 2.0, 5.0)
			_shrapnel(pos, 30, 22.0, Color(0.2, 0.2, 0.22), 0.06, 0.2)
			# вторая ступень: батареи рвутся через полсекунды
			get_tree().create_timer(0.5).timeout.connect(func() -> void:
				if not is_instance_valid(self): return
				_flash(pos, Color(1.0, 0.9, 0.7), 14.0, 30.0, 0.12)
				_spark_fountain(pos, 2.6))
		_:
			# крыло/шарк: удар о землю без подрыва
			_burst_smoke(pos, Color(0.55, 0.5, 0.42, 0.6), 12, 1.8, 3.5)   # пыль
			_burst_smoke(pos + Vector3(0, 0.5, 0), Color(0.85, 0.85, 0.82, 0.5), 6, 1.0, 5.0)
			_shrapnel(pos, 16, 11.0, Color(0.88, 0.88, 0.85), 0.08, 0.25)  # пенопласт


func _flash(pos: Vector3, col: Color, energy: float, rng: float, dur: float) -> void:
	var l := OmniLight3D.new()
	l.position = pos
	l.light_color = col
	l.light_energy = energy
	l.omni_range = rng
	l.shadow_enabled = false
	add_child(l)
	var tw := create_tween()
	tw.tween_property(l, "light_energy", 0.0, dur)
	tw.tween_callback(l.queue_free)
	var fmesh := MeshInstance3D.new()
	fmesh.mesh = _pquad(1.2 + energy * 0.09, _flash_mat(Color(col.r, col.g, col.b, 0.95)))
	fmesh.position = pos
	fmesh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	fmesh.scale = Vector3.ONE * 0.5
	add_child(fmesh)
	var tws := create_tween()
	tws.tween_property(fmesh, "scale", Vector3.ONE * 1.6, dur)   # вспышка расширяется и гаснет
	tws.tween_callback(fmesh.queue_free)


func _burst_smoke(pos: Vector3, col: Color, n: int, size: float, life: float) -> void:
	var p := GPUParticles3D.new()
	p.one_shot = true; p.emitting = true
	p.amount = n; p.lifetime = life; p.explosiveness = 0.9
	var pm := ParticleProcessMaterial.new()
	pm.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_SPHERE
	pm.emission_sphere_radius = 0.5
	pm.direction = Vector3(0, 1, 0); pm.spread = 75.0
	pm.initial_velocity_min = 2.5; pm.initial_velocity_max = 7.0
	pm.damping_min = 2.0; pm.damping_max = 4.0        # резкий выброс, потом клубы «зависают»
	pm.gravity = Vector3(0, 1.1, 0)
	pm.turbulence_enabled = true
	pm.turbulence_noise_strength = 0.6
	pm.turbulence_noise_scale = 2.2
	pm.scale_min = size * 0.6; pm.scale_max = size * 1.3
	var sc := Curve.new()
	sc.add_point(Vector2(0.0, 0.4)); sc.add_point(Vector2(1.0, 2.2))
	var sct := CurveTexture.new(); sct.curve = sc
	pm.scale_curve = sct
	var g := Gradient.new()
	g.set_color(0, col); g.set_color(1, Color(col.r, col.g, col.b, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	p.draw_pass_1 = _pquad(2.0, _billboard_mat(_soft))
	p.position = pos
	add_child(p)
	_free_later(p, life + 0.5)


func _shrapnel(pos: Vector3, n: int, vel: float, col: Color, s0: float, s1: float) -> void:
	var p := GPUParticles3D.new()
	p.one_shot = true; p.emitting = true
	p.amount = n; p.lifetime = 1.4; p.explosiveness = 1.0
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 0.3, 0); pm.spread = 180.0
	pm.initial_velocity_min = vel * 0.4; pm.initial_velocity_max = vel
	pm.gravity = Vector3(0, -22.0, 0)
	pm.scale_min = s0; pm.scale_max = s1
	pm.angular_velocity_min = -540.0; pm.angular_velocity_max = 540.0
	p.process_material = pm
	var bb := BoxMesh.new(); bb.size = Vector3(0.5, 0.12, 0.5)
	var bmat := StandardMaterial3D.new(); bmat.albedo_color = col; bmat.roughness = 0.9
	bb.material = bmat
	p.draw_pass_1 = bb
	p.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	p.position = pos
	add_child(p)
	_free_later(p, 1.8)


## Фонтан LiPo-искр: яркие бело-оранжевые, брызжут вверх и опадают, характерно для горящих батарей.
func _spark_fountain(pos: Vector3, k: float) -> void:
	var p := GPUParticles3D.new()
	p.one_shot = true; p.emitting = true
	p.amount = int(40 * k); p.lifetime = 1.1; p.explosiveness = 0.35
	var pm := ParticleProcessMaterial.new()
	pm.direction = Vector3(0, 1, 0); pm.spread = 42.0
	pm.initial_velocity_min = 6.0 * k; pm.initial_velocity_max = 13.0 * k
	pm.gravity = Vector3(0, -18.0, 0)
	pm.scale_min = 0.03; pm.scale_max = 0.09
	var g := Gradient.new()
	g.set_color(0, Color(1.0, 0.97, 0.85, 1.0))
	g.add_point(0.4, Color(1.0, 0.7, 0.3, 0.9))
	g.set_color(1, Color(0.9, 0.3, 0.08, 0.0))
	var gt := GradientTexture1D.new(); gt.gradient = g
	pm.color_ramp = gt
	p.process_material = pm
	p.draw_pass_1 = _pquad(0.22, _billboard_mat(_soft, true))
	p.position = pos
	add_child(p)
	_free_later(p, 1.6)
