extends Node3D
## Гражданский трафик: легковые/грузовые коробки едут по дорогам OSM вокруг камеры (до N машин в 3 км),
## разворачиваются на концах, ночью светят фарами. Это «жизнь» кадра + движущиеся нецелевые объекты
## (оператор должен отличать гражданскую машину от техники).

var main: Node3D
var roads: Array = []
var cars: Array = []                 # {road, d, dir, speed, kind, color}
var _mm_body: MultiMesh
var _mm_cab: MultiMesh
var _mm_lamp: MultiMesh
var _lamp_mat: StandardMaterial3D
const N_CARS := 40
const SPAWN_R := 3000.0
const DESPAWN_R := 4000.0
const COLORS := [Color(0.85, 0.85, 0.85), Color(0.15, 0.15, 0.17), Color(0.55, 0.58, 0.62), Color(0.45, 0.12, 0.1),
	Color(0.2, 0.3, 0.5), Color(0.7, 0.6, 0.3), Color(0.25, 0.4, 0.3)]
var _rng := RandomNumberGenerator.new()
var _acc := 0.0
var _spots: Array[SpotLight3D] = []       # конусы фар ночью (пул на ближайшие машины)


func setup(m: Node3D) -> void:
	main = m
	_rng.seed = 777
	var f := FileAccess.get_file_as_string(main.asset_path("roads.json"))
	if f.is_empty():
		return
	for r: Dictionary in JSON.parse_string(f)["roads"]:
		var cls: String = r["c"]
		if cls == "track" or cls == "service":
			continue                     # по полевым и служебным почти не ездят
		var pts: Array = r["p"]
		if pts.size() < 2: continue
		var lens: Array[float] = [0.0]; var total := 0.0
		for i in range(1, pts.size()):
			total += Vector2(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]).length()
			lens.append(total)
		if total > 200.0:
			roads.append({"p": pts, "len": lens, "total": total, "cls": cls})
	# меши: кузов, кабина/крыша, фары
	var body := BoxMesh.new(); body.size = Vector3(4.3, 0.75, 1.8)
	var bmat := StandardMaterial3D.new(); bmat.vertex_color_use_as_albedo = true; bmat.roughness = 0.35; bmat.metallic = 0.3
	body.material = bmat
	_mm_body = _mm(body, true)
	var cab := BoxMesh.new(); cab.size = Vector3(2.2, 0.7, 1.6)
	var cmat := StandardMaterial3D.new(); cmat.albedo_color = Color(0.12, 0.13, 0.15); cmat.roughness = 0.2; cmat.metallic = 0.4
	cab.material = cmat
	_mm_cab = _mm(cab, false)
	var lamp := BoxMesh.new(); lamp.size = Vector3(0.1, 0.25, 1.5)
	_lamp_mat = StandardMaterial3D.new()
	_lamp_mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	_lamp_mat.albedo_color = Color(1.0, 0.95, 0.8)
	_lamp_mat.emission_enabled = true; _lamp_mat.emission = Color(1.0, 0.95, 0.8); _lamp_mat.emission_energy_multiplier = 0.0
	lamp.material = _lamp_mat
	_mm_lamp = _mm(lamp, false)
	for i in 6:
		var sp := SpotLight3D.new()
		sp.light_color = Color(1.0, 0.93, 0.75)
		sp.light_energy = 0.0
		sp.spot_range = 42.0
		sp.spot_angle = 19.0
		sp.spot_attenuation = 0.6
		sp.shadow_enabled = false
		add_child(sp)
		_spots.append(sp)
	print("Traffic: дорог для машин %d" % roads.size())


func _mm(mesh: Mesh, colors: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colors
	mm.mesh = mesh
	mm.instance_count = N_CARS
	for i in N_CARS:
		mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -1000, 0)))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(mi)
	return mm


func _road_pos(road: Dictionary, dist: float) -> Vector2:
	var lens: Array = road["len"]; var pts: Array = road["p"]
	dist = clampf(dist, 0.0, road["total"])
	for i in range(1, lens.size()):
		if dist <= lens[i]:
			var t: float = (dist - lens[i - 1]) / maxf(lens[i] - lens[i - 1], 0.01)
			return Vector2(lerpf(pts[i - 1][0], pts[i][0], t), lerpf(pts[i - 1][1], pts[i][1], t))
	return Vector2(pts[-1][0], pts[-1][1])


func _try_spawn(cam_xz: Vector2) -> void:
	for attempt in 20:
		var road: Dictionary = roads[_rng.randi_range(0, roads.size() - 1)]
		var d := _rng.randf() * float(road["total"])
		var p := _road_pos(road, d)
		var dist := p.distance_to(cam_xz)
		if dist < 150.0 or dist > SPAWN_R:
			continue
		var cls: String = road["cls"]
		var spd := _rng.randf_range(9.0, 16.0) if cls in ["residential", "unclassified"] else _rng.randf_range(14.0, 24.0)
		cars.append({"road": road, "d": d, "dir": 1.0 if _rng.randf() < 0.5 else -1.0, "speed": spd,
			"color": COLORS[_rng.randi_range(0, COLORS.size() - 1)], "truck": _rng.randf() < 0.2, "yaw": 0.0})
		return


func _process(dt: float) -> void:
	if main == null or main.cam == null or roads.is_empty():
		return
	var cp: Vector3 = main.cam.global_position
	var cam_xz := Vector2(cp.x, cp.z)
	_acc += dt
	if _acc > 0.5:
		_acc = 0.0
		# деспаун далёких, доспаун до N
		for c: Dictionary in cars.duplicate():
			if _road_pos(c.road, c.d).distance_to(cam_xz) > DESPAWN_R:
				cars.erase(c)
		if cars.size() < N_CARS:
			_try_spawn(cam_xz)
	var night := 0.0
	if main.weather != null and int(main.weather.idx) == 4: night = 1.0
	_lamp_mat.emission_energy_multiplier = 4.0 * night
	for i in N_CARS:
		if i >= cars.size():
			_mm_body.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -1000, 0)))
			_mm_cab.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -1000, 0)))
			_mm_lamp.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ZERO), Vector3(0, -1000, 0)))
			continue
		var c: Dictionary = cars[i]
		c.d += c.dir * c.speed * dt
		var road: Dictionary = c.road
		if c.d <= 0.0 or c.d >= float(road["total"]):
			c.dir = -c.dir
			c.d = clampf(c.d, 0.0, road["total"])
		var p := _road_pos(road, c.d)
		var p2 := _road_pos(road, c.d + c.dir * 4.0)
		var dv := Vector2(p2.x - p.x, p2.y - p.y)
		if dv.length_squared() > 0.001:
			c.yaw = atan2(-dv.y, dv.x)
		# правая сторона дороги
		var side := Vector2(-sin(c.yaw), -cos(c.yaw)) * 1.4
		var wx := p.x + side.x * 0.0; var wz := p.y + side.y * 0.0
		var rgt := Vector2(dv.y, -dv.x).normalized() * 1.3
		wx = p.x + rgt.x; wz = p.y + rgt.y
		var y: float = maxf(main.height_at(wx, wz), main.deck_h(wx, wz)) + 0.55
		var b := Basis(Vector3.UP, c.yaw)
		var sc := 1.35 if c.truck else 1.0
		_mm_body.set_instance_transform(i, Transform3D(b.scaled(Vector3(sc, sc, sc)), Vector3(wx, y, wz)))
		_mm_body.set_instance_color(i, c.color)
		var cab_off: Vector3 = b * Vector3(-0.3 if not c.truck else 1.3, 0.72 * sc, 0.0)
		_mm_cab.set_instance_transform(i, Transform3D(b.scaled(Vector3(sc * (0.6 if c.truck else 1.0), sc, sc)), Vector3(wx, y, wz) + cab_off))
		var lamp_off: Vector3 = b * Vector3(2.15 * sc, 0.05, 0.0)
		_mm_lamp.set_instance_transform(i, Transform3D(b, Vector3(wx, y, wz) + lamp_off))
		# конус фар: первые 6 машин освещают дорогу перед собой
		if i < _spots.size():
			var sp := _spots[i]
			sp.light_energy = 6.0 * night
			if night > 0.0:
				var fwd3: Vector3 = b * Vector3(1, 0, 0)
				sp.global_position = Vector3(wx, y + 0.4, wz) + fwd3 * 2.3
				sp.global_transform.basis = Basis.looking_at((fwd3 - Vector3(0, 0.28, 0)).normalized(), Vector3.UP)
