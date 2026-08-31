extends Node3D
## Мирные жители (набор 3 «расширенный»): пешеходы идут по сельским улицам, стоящие — у домов,
## велосипедист едет по дороге, бабушка с тележкой, ребёнок, собака. Стриминг вокруг камеры.
## Ночью село пустеет (остаются единицы). Учебный смысл: оператор учится отличать жителя от
## пехотинца — с высоты и в тепловизоре (см. thermal.gd: «Villagers» чуть холоднее солдат).

var main: Node3D
var roads: Array = []                # сельские дороги для маршрутов
var walkers: Array = []              # {node, road, d, dir, speed, bob}
var standers: Array = []             # {node, pos}
const R_SPAWN := 900.0
const R_DESPAWN := 1200.0
const N_WALK := 9
const N_STAND := 7
const N_CYCLE := 2
var _rng := RandomNumberGenerator.new()
var _acc := 0.0
var _t := 0.0
var _walk_meshes: Array[ArrayMesh] = []
var _stand_meshes: Array[ArrayMesh] = []
var _cycle_mesh: ArrayMesh


func setup(m: Node3D) -> void:
	main = m
	_rng.seed = 4242
	var U = load("res://scripts/units.gd").new()
	_walk_meshes = [
		U.civ_man(Color(0.55, 0.55, 0.6), true), U.civ_man(Color(0.35, 0.45, 0.35), true),
		U.civ_woman(Color(0.6, 0.45, 0.4), Color(0.75, 0.7, 0.6), true),
		U.civ_woman(Color(0.45, 0.5, 0.62), Color(0.85, 0.8, 0.7), true),
		U.civ_babushka(), U.civ_kid(Color(0.75, 0.35, 0.3)), U.civ_dog(),
	]
	_stand_meshes = [
		U.civ_man(Color(0.5, 0.52, 0.6), false), U.civ_man(Color(0.4, 0.42, 0.5), false),
		U.civ_woman(Color(0.6, 0.4, 0.4), Color(0.8, 0.75, 0.6), false),
		U.civ_kid(Color(0.4, 0.55, 0.75)),
	]
	_cycle_mesh = U.civ_cyclist()
	var f := FileAccess.get_file_as_string(main.asset_path("roads.json"))
	if f.is_empty():
		return
	for r: Dictionary in JSON.parse_string(f)["roads"]:
		var cls: String = r["c"]
		if not cls in ["residential", "unclassified", "track", "service"]:
			continue                     # жители ходят по сельским улицам и просёлкам
		var pts: Array = r["p"]
		if pts.size() < 2: continue
		var lens: Array[float] = [0.0]; var total := 0.0
		for i in range(1, pts.size()):
			total += Vector2(pts[i][0] - pts[i - 1][0], pts[i][1] - pts[i - 1][1]).length()
			lens.append(total)
		if total > 120.0:
			roads.append({"p": pts, "len": lens, "total": total})
	print("Villagers: дорог для жителей %d" % roads.size())


func _road_pos(road: Dictionary, dist: float) -> Vector2:
	var lens: Array = road["len"]; var pts: Array = road["p"]
	dist = clampf(dist, 0.0, road["total"])
	for i in range(1, lens.size()):
		if dist <= lens[i]:
			var t: float = (dist - lens[i - 1]) / maxf(lens[i] - lens[i - 1], 0.01)
			return Vector2(lerpf(pts[i - 1][0], pts[i][0], t), lerpf(pts[i - 1][1], pts[i][1], t))
	return Vector2(pts[-1][0], pts[-1][1])


func _night() -> bool:
	return main.get("weather") != null and int(main.weather.idx) == 4


## Целевые количества: днём полный набор, ночью почти никого, в дождь — вдвое меньше.
func _want_counts() -> Vector3i:
	if _night():
		return Vector3i(1, 1, 0)
	if main.get("weather") != null and main.weather.raining():
		return Vector3i(4, 3, 1)
	return Vector3i(N_WALK, N_STAND, N_CYCLE)


func _try_spawn_walker(cam_xz: Vector2, cyclist: bool) -> void:
	for attempt in 16:
		var road: Dictionary = roads[_rng.randi_range(0, roads.size() - 1)]
		var d := _rng.randf() * float(road["total"])
		var p := _road_pos(road, d)
		var dist := p.distance_to(cam_xz)
		if dist < 60.0 or dist > R_SPAWN:
			continue
		var mesh: ArrayMesh = _cycle_mesh if cyclist else _walk_meshes[_rng.randi_range(0, _walk_meshes.size() - 1)]
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		add_child(mi)
		walkers.append({"node": mi, "road": road, "d": d, "dir": 1.0 if _rng.randf() < 0.5 else -1.0,
			"speed": _rng.randf_range(4.0, 6.0) if cyclist else _rng.randf_range(0.8, 1.5),
			"bob": _rng.randf() * TAU, "cyclist": cyclist, "off": _rng.randf_range(2.5, 4.5) * (1.0 if _rng.randf() < 0.5 else -1.0)})
		return


func _try_spawn_stander(cam_xz: Vector2) -> void:
	for attempt in 16:
		var road: Dictionary = roads[_rng.randi_range(0, roads.size() - 1)]
		var d := _rng.randf() * float(road["total"])
		var p := _road_pos(road, d)
		var dist := p.distance_to(cam_xz)
		if dist < 60.0 or dist > R_SPAWN:
			continue
		# в стороне от дороги, у двора; не внутри здания
		var p2 := _road_pos(road, d + 5.0)
		var dirv := (p2 - p).normalized() if p2.distance_to(p) > 0.1 else Vector2(1, 0)
		var side := Vector2(-dirv.y, dirv.x) * _rng.randf_range(6.0, 13.0) * (1.0 if _rng.randf() < 0.5 else -1.0)
		var wp := p + side
		if main.collision != null and main.collision.in_building(wp.x, wp.y, 0.5):
			continue
		if not main.collision.in_building(wp.x, wp.y, 40.0):
			continue                     # стоят только там, где рядом есть дома
		var mi := MeshInstance3D.new()
		mi.mesh = _stand_meshes[_rng.randi_range(0, _stand_meshes.size() - 1)]
		var y: float = main.height_at(wp.x, wp.y)
		mi.transform = Transform3D(Basis(Vector3.UP, _rng.randf() * TAU), Vector3(wp.x, y, wp.y))
		add_child(mi)
		standers.append({"node": mi, "pos": wp})
		return


func _process(dt: float) -> void:
	if main == null or main.cam == null or roads.is_empty():
		return
	_t += dt
	var cp: Vector3 = main.cam.global_position
	var cam_xz := Vector2(cp.x, cp.z)
	_acc += dt
	if _acc > 0.7:
		_acc = 0.0
		var want := _want_counts()
		# деспаун далёких
		for w: Dictionary in walkers.duplicate():
			if _road_pos(w.road, w.d).distance_to(cam_xz) > R_DESPAWN:
				w.node.queue_free(); walkers.erase(w)
		for s: Dictionary in standers.duplicate():
			if s.pos.distance_to(cam_xz) > R_DESPAWN:
				s.node.queue_free(); standers.erase(s)
		# доспаун до целевых количеств
		var ncyc := 0
		for w: Dictionary in walkers:
			if w.cyclist: ncyc += 1
		if walkers.size() - ncyc < want.x:
			_try_spawn_walker(cam_xz, false)
		if standers.size() < want.y:
			_try_spawn_stander(cam_xz)
		if ncyc < want.z:
			_try_spawn_walker(cam_xz, true)
		# ночью лишних убираем
		while walkers.size() > want.x + want.z:
			var w0: Dictionary = walkers.pop_back(); w0.node.queue_free()
		while standers.size() > want.y:
			var s0: Dictionary = standers.pop_back(); s0.node.queue_free()
	# движение пешеходов
	for w: Dictionary in walkers:
		w.d += w.dir * w.speed * dt
		var road: Dictionary = w.road
		if w.d <= 0.0 or w.d >= float(road["total"]):
			w.dir = -w.dir
			w.d = clampf(w.d, 0.0, road["total"])
		var p := _road_pos(road, w.d)
		var p2 := _road_pos(road, w.d + w.dir * 3.0)
		var dv := Vector2(p2.x - p.x, p2.y - p.y)
		var yaw: float = atan2(-dv.y, dv.x) if dv.length_squared() > 0.001 else 0.0
		# пешеходы идут по обочине, велосипед — по краю полотна
		var rgt := Vector2(dv.y, -dv.x).normalized() if dv.length_squared() > 0.001 else Vector2(0, 1)
		var edge := 1.6 if w.cyclist else float(w.off)
		var wx: float = p.x + rgt.x * edge
		var wz: float = p.y + rgt.y * edge
		var y: float = maxf(main.height_at(wx, wz), main.deck_h(wx, wz))
		var bob := 0.0 if w.cyclist else absf(sin(_t * 5.5 + float(w.bob))) * 0.045
		w.node.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(wx, y + bob, wz))
