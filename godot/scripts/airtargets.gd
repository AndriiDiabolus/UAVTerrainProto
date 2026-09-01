extends Node3D
## Воздушные цели: вражеские разведывательные БпЛА (крыло и квадрокоптер) летят маршрутом
## над районом. Наш дрон перехватывает их: таран корпусом на скорости или «дробовик» (ЛКМ вблизи,
## конус поражения). Учит новому классу задач — воздушному перехвату (сближение, ракурс, дистанция).
##
## Спавн вокруг камеры (до N в воздухе), маркер-ромб с дистанцией, сбитый падает по баллистике с дымом.

var main: Node3D
var enemies: Array = []              # {node, kind, wp:Array, seg, t, speed, alive, fall_v, mark}
const N_AIR := 2
const SPAWN_R := 1400.0
const DESPAWN_R := 2200.0
const RAM_R := 12.0                  # таран: сблизиться на 12 м
const SHOT_R := 90.0                 # дробовик: дальность
const SHOT_CONE := 0.90             # косинус полураствора конуса (~25°)
var _rng := RandomNumberGenerator.new()
var _acc := 0.0
var _wing_mesh: ArrayMesh
var _quad_mesh: ArrayMesh
var kills := 0


func setup(m: Node3D) -> void:
	main = m
	_rng.seed = 9182
	_wing_mesh = _make_wing()
	_quad_mesh = _make_quad()


func _process(dt: float) -> void:
	if main == null or main.cam == null:
		return
	var cp: Vector3 = main.cam.global_position
	_acc += dt
	if _acc > 1.0:
		_acc = 0.0
		for e: Dictionary in enemies.duplicate():
			if e.alive and Vector2(e.node.position.x - cp.x, e.node.position.z - cp.z).length() > DESPAWN_R:
				e.node.queue_free(); enemies.erase(e)
		var alive := 0
		for e: Dictionary in enemies:
			if e.alive: alive += 1
		if alive < N_AIR:
			_try_spawn(cp)
	for e: Dictionary in enemies:
		if e.alive:
			_fly(e, dt, cp)
		else:
			_fall(e, dt)


func _try_spawn(cp: Vector3) -> void:
	var kind := "wing" if _rng.randf() < 0.5 else "quad"
	# маршрут: 4 путевые точки по большому кругу вокруг случайного центра рядом с камерой
	var c := Vector2(cp.x, cp.z) + Vector2(_rng.randf_range(-500, 500), _rng.randf_range(-500, 500))
	var alt := _rng.randf_range(90.0, 220.0)
	var wp: Array = []
	var r := _rng.randf_range(350.0, 700.0)
	var a0 := _rng.randf() * TAU
	for k in 4:
		var a := a0 + TAU * k / 4.0
		var px := c.x + cos(a) * r
		var pz := c.y + sin(a) * r
		wp.append(Vector3(px, main.height_at(px, pz) + alt, pz))
	var mi := MeshInstance3D.new()
	mi.mesh = _wing_mesh if kind == "wing" else _quad_mesh
	mi.position = wp[0]
	add_child(mi)
	var mark := _add_marker(mi)
	enemies.append({"node": mi, "kind": kind, "wp": wp, "seg": 0, "t": 0.0,
		"speed": _rng.randf_range(16.0, 26.0) if kind == "wing" else _rng.randf_range(8.0, 14.0),
		"alive": true, "fall_v": Vector3.ZERO, "mark": mark, "spin": 0.0})


func _fly(e: Dictionary, dt: float, cp: Vector3) -> void:
	var wp: Array = e.wp
	var a: Vector3 = wp[e.seg]
	var b: Vector3 = wp[(e.seg + 1) % wp.size()]
	var seg_len: float = a.distance_to(b)
	e.t += e.speed * dt / maxf(seg_len, 1.0)
	if e.t >= 1.0:
		e.t -= 1.0
		e.seg = (e.seg + 1) % wp.size()
		a = wp[e.seg]; b = wp[(e.seg + 1) % wp.size()]
	var pos: Vector3 = a.lerp(b, e.t)
	e.node.position = pos
	var fwd := (b - a).normalized()
	var yaw := atan2(-fwd.z, fwd.x)
	if e.kind == "wing":
		# крыло: банковит в поворот, слегка кабрирует
		var basis := Basis(Vector3.UP, yaw) * Basis(Vector3.RIGHT, -0.05)
		e.node.transform.basis = basis.scaled(Vector3.ONE)
	else:
		# квадрик: держит горизонт, крутит корпус по курсу + винты
		e.spin += dt * 40.0
		e.node.transform.basis = Basis(Vector3.UP, yaw + e.spin * 0.0)
	# перехват тараном: наш дрон сблизился на RAM_R
	if cp.distance_to(pos) < RAM_R:
		_kill(e)


func _fall(e: Dictionary, dt: float) -> void:
	e.fall_v += Vector3(0, -9.8, 0) * dt
	e.node.position += e.fall_v * dt
	e.node.rotate_z(dt * 3.0)
	var g: float = main.height_at(e.node.position.x, e.node.position.z)
	if e.node.position.y <= g + 0.5:
		if main.get("fx") != null:
			main.fx.explosion(Vector3(e.node.position.x, g, e.node.position.z), false)
		e.node.queue_free()
		enemies.erase(e)


## Дробовик по воздушной цели: ЛКМ, если цель в конусе перед дроном и ближе SHOT_R.
func shoot(cam: Camera3D) -> bool:
	var fwd: Vector3 = -cam.global_transform.basis.z
	var best: Dictionary = {}
	var best_d := SHOT_R
	for e: Dictionary in enemies:
		if not e.alive:
			continue
		var to: Vector3 = e.node.position - cam.global_position
		var d := to.length()
		if d < best_d and to.normalized().dot(fwd) > SHOT_CONE:
			best_d = d; best = e
	if best.is_empty():
		return false
	if main.get("sound") != null:
		main.sound.shot()
	# трассеры дробины
	for k in 5:
		var spread := Vector3(_rng.randf_range(-1, 1), _rng.randf_range(-1, 1), _rng.randf_range(-1, 1)) * best_d * 0.03
		_tracer(cam.global_position, best.node.position + spread)
	# шанс поражения падает с дистанцией (дробь рассеивается)
	if _rng.randf() < 1.0 - best_d / SHOT_R * 0.7:
		_kill(best)
	return true


func _kill(e: Dictionary) -> void:
	if not e.alive:
		return
	e.alive = false
	kills += 1
	e.fall_v = Vector3(_rng.randf_range(-4, 4), -2.0, _rng.randf_range(-4, 4))
	if is_instance_valid(e.mark):
		e.mark.queue_free()
	if main.get("fx") != null:
		main.fx.wreck_fire(e.node)          # дымит при падении
	if main.hud != null:
		main.hud.toast("ВОЗДУШНАЯ ЦЕЛЬ СБИТА", "", Color(0.6, 1.0, 0.6))
	if main.get("telemetry") != null:
		main.telemetry.event("air_kill", {"kind": e.kind})


## Ближайшая живая воздушная цель (для HUD-указателя).
func nearest(pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var bd := 1e20
	for e: Dictionary in enemies:
		if not e.alive: continue
		var d: float = pos.distance_squared_to(e.node.position)
		if d < bd: bd = d; best = e
	if best.is_empty():
		return {}
	return {"pos": best.node.position, "kind": "air_" + str(best.kind), "dist": sqrt(bd)}


func active_count() -> int:
	var n := 0
	for e in enemies:
		if e.alive: n += 1
	return n


# ---------------- меши ----------------

func _add_marker(node: Node3D) -> MeshInstance3D:
	if "--nomarkers" in OS.get_cmdline_user_args():
		return null
	var cap := MeshInstance3D.new()
	cap.name = "AirMarker"
	var sph := SphereMesh.new(); sph.radius = 1.6; sph.height = 3.2; sph.radial_segments = 8; sph.rings = 4
	cap.mesh = sph
	cap.position = Vector3(0, 4.0, 0)
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.albedo_color = Color(0.3, 0.7, 1.0)          # синий — воздушная цель (отличать от наземных красных)
	cm.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	cap.mesh.surface_set_material(0, cm)
	node.add_child(cap)
	return cap


func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new(); m.albedo_color = c; m.roughness = 0.6; return m


func _add(mesh: ArrayMesh, prim: PrimitiveMesh, xf: Transform3D, c: Color) -> void:
	var arr: Array = prim.get_mesh_arrays()
	var v: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	for i in v.size(): v[i] = xf * v[i]
	arr[Mesh.ARRAY_VERTEX] = v
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	mesh.surface_set_material(mesh.get_surface_count() - 1, _mat(c))


## Разведчик-крыло (Zala/Орлан-класс): фюзеляж + прямое крыло + двухбалочное оперение.
func _make_wing() -> ArrayMesh:
	var m := ArrayMesh.new()
	var body := Color(0.7, 0.7, 0.66)
	var f := CylinderMesh.new(); f.top_radius = 0.12; f.bottom_radius = 0.18; f.height = 1.6; f.radial_segments = 8
	_add(m, f, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3.ZERO), body)
	var wing := BoxMesh.new(); wing.size = Vector3(0.5, 0.05, 3.2)
	_add(m, wing, Transform3D(Basis(), Vector3(0.1, 0.05, 0)), body)
	var tail := BoxMesh.new(); tail.size = Vector3(0.4, 0.04, 1.1)
	_add(m, tail, Transform3D(Basis(), Vector3(-0.8, 0.05, 0)), body)
	var fin := BoxMesh.new(); fin.size = Vector3(0.4, 0.4, 0.04)
	for fz in [0.5, -0.5]:
		_add(m, fin, Transform3D(Basis(), Vector3(-0.8, 0.2, fz)), body)
	var nose := SphereMesh.new(); nose.radius = 0.16; nose.height = 0.32; nose.radial_segments = 8; nose.rings = 4
	_add(m, nose, Transform3D(Basis(), Vector3(0.82, 0, 0)), Color(0.2, 0.2, 0.22))    # оптика в носу
	return m


## Разведчик-квадрокоптер: центр + 4 луча с моторами + гимбал снизу.
func _make_quad() -> ArrayMesh:
	var m := ArrayMesh.new()
	var dark := Color(0.13, 0.13, 0.15)
	var body := BoxMesh.new(); body.size = Vector3(0.5, 0.18, 0.5)
	_add(m, body, Transform3D(), dark)
	var arm := BoxMesh.new(); arm.size = Vector3(0.9, 0.05, 0.06)
	for a in 4:
		var ang := PI / 4.0 + TAU * a / 4.0
		var b := Basis(Vector3.UP, ang)
		_add(m, arm, Transform3D(b, Vector3.ZERO), dark)
		var motor := CylinderMesh.new(); motor.top_radius = 0.09; motor.bottom_radius = 0.09; motor.height = 0.1; motor.radial_segments = 8
		var mp := b * Vector3(0.42, 0.03, 0)
		_add(m, motor, Transform3D(Basis(), mp), Color(0.2, 0.2, 0.22))
		var prop := CylinderMesh.new(); prop.top_radius = 0.28; prop.bottom_radius = 0.28; prop.height = 0.015; prop.radial_segments = 10
		_add(m, prop, Transform3D(Basis(), mp + Vector3(0, 0.08, 0)), Color(0.3, 0.3, 0.32, 1.0))
	var gimbal := SphereMesh.new(); gimbal.radius = 0.11; gimbal.height = 0.22; gimbal.radial_segments = 8; gimbal.rings = 4
	_add(m, gimbal, Transform3D(Basis(), Vector3(0, -0.14, 0)), Color(0.08, 0.08, 0.09))
	return m


func _tracer(a: Vector3, b: Vector3) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(a); im.surface_add_vertex(b)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.85, 0.4)
	mat.emission_enabled = true; mat.emission = Color(1.0, 0.8, 0.3); mat.emission_energy_multiplier = 2.0
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.2)
	tw.tween_callback(mi.queue_free)
