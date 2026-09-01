extends Node
## Самотесты (--selftest — всё; --coltest / --flytest / --missiontest — по отдельности).
## Возвращает код выхода 0/1 — можно гонять из CI/скрипта: ./run.sh --selftest --nosound

var main: Node3D
var fails := 0


func setup(m: Node3D) -> void:
	main = m
	var args := OS.get_cmdline_user_args()
	var any := false
	if "--selftest" in args or "--coltest" in args:
		any = true
		_check("height_at на узлах меша", _test_height_at())
		_check("lat/lon ↔ мир (обратимость)", _test_latlon())
		_check("коллизии + LOS", _test_collision())
		_check("РЭБ: jam_factor", _test_ew())
		_check("баллистика сброса + поражение", _test_ballistics())
		_check("БЧ-камикадзе: подрыв при столкновении", _test_kamikaze())
		_check("ретранслятор: канал вторым хопом", _test_relay())
	if "--selftest" in args or "--flytest" in args:
		any = true
		_check("лётная модель", main.cam.self_test())
	if "--selftest" in args or "--missiontest" in args:
		any = true
		_check("миссии/скоринг", main.mission.self_test())
	if any:
		print("SELFTEST: %s (провалов: %d)" % ["ВСЕ OK" if fails == 0 else "ЕСТЬ FAIL", fails])
		main.get_tree().quit(0 if fails == 0 else 1)


func _check(name: String, ok: bool) -> void:
	print("SELFTEST [%s] %s" % ["OK" if ok else "FAIL", name])
	if not ok:
		fails += 1


## Ретранслятор в прямой видимости и станции, и дрона даёт канал не хуже прямого.
func _test_relay() -> bool:
	var home: Vector3 = main._home_pos + Vector3(0, 2, 0)
	var drone: Vector3 = main._home_pos + Vector3(300, 80, 0)
	var direct: Dictionary = main.link_los(main._home_pos, drone)
	if bool(direct.via):
		print("  без ретранслятора via=true — ошибка"); return false
	# развернём ретранслятор высоко между станцией и дроном
	main.relay_pos = main._home_pos + Vector3(150, 200, 0)
	main.relay_node = Node3D.new(); main.add_child(main.relay_node)
	var withr: Dictionary = main.link_los(main._home_pos, drone)
	var ok: bool = float(withr.los) >= float(direct.los) - 0.001
	print("  прямой los=%.2f, с ретранслятором los=%.2f via=%s" % [direct.los, withr.los, withr.via])
	main.relay_node.queue_free(); main.relay_node = null
	return ok


## Взведённая БЧ камикадзе поражает цель в радиусе точки столкновения.
func _test_kamikaze() -> bool:
	var tg: Node3D = main.targets
	if tg == null:
		return false
	var spawned: Array = tg.spawn_near(main._home_pos, ["tank"])
	if spawned.is_empty():
		print("  нет дорог для спавна — пропуск"); return true
	var t: Dictionary = spawned[0]
	t.speed = 0.0
	tg._process(0.01)
	tg.weapon = 2
	tg.armed = true
	tg.detonate(t.node.position + Vector3(3, 1, 0))     # «столкновение» в 3 м от цели
	var ok: bool = not bool(t.alive) and not bool(tg.armed)
	print("  цель жива=%s (ждём false), БЧ взведена=%s (ждём false)" % [t.alive, tg.armed])
	tg.weapon = 0
	return ok


## height_at в узле сетки меша должен совпадать с _node_h (иначе объекты «тонут» — грабля №4 README).
func _test_height_at() -> bool:
	var n: int = main.MESH_RES
	var ok := true
	for pair: Array in [[100, 200], [512, 512], [900, 30], [n - 1, n - 1], [0, 0]]:
		var ix: int = pair[0]; var iz: int = pair[1]
		var x: float = (float(ix) / (n - 1) - 0.5) * main.size_m
		var z: float = (float(iz) / (n - 1) - 0.5) * main.size_m
		var a: float = main.height_at(x, z)
		var b: float = main._node_h(ix, iz)
		if absf(a - b) > 0.05:
			print("  height_at(%d,%d)=%.2f != node %.2f" % [ix, iz, a, b]); ok = false
	# монотонность/диапазон
	var c: float = main.height_at(0.0, 0.0)
	if c < main.e_min - 1.0 or c > main.e_max + 1.0:
		print("  height_at(0,0)=%.1f вне [%.1f, %.1f]" % [c, main.e_min, main.e_max]); ok = false
	return ok


func _test_latlon() -> bool:
	var ok := true
	for ll: Array in [[48.2839, 24.5610], [48.16, 24.50], [48.32, 24.60]]:
		var w: Vector2 = main._world_from_latlon(ll[0], ll[1])
		var back: Vector2 = main._latlon_at(w.x, w.y)
		if absf(back.x - ll[0]) > 1e-4 or absf(back.y - ll[1]) > 1e-4:
			print("  latlon roundtrip %s → %s → %s" % [ll, w, back]); ok = false
	# центр карты = center_lat/lon из meta (для любого региона)
	var c: Vector2 = main._latlon_at(0.0, 0.0)
	if absf(c.x - float(main.meta["center_lat"])) > 0.05 or absf(c.y - float(main.meta["center_lon"])) > 0.05:   # мозаика выровнена по тайлам (½ тайла z13 ≈ 0.02°)
		print("  центр мира %s != meta center (%s, %s)" % [c, main.meta["center_lat"], main.meta["center_lon"]]); ok = false
	return ok


func _test_collision() -> bool:
	var ok := true
	var f := FileAccess.get_file_as_string(main.asset_path("buildings.json"))
	if f.is_empty():
		print("  buildings.json пуст — пропуск"); return true
	var arr: Array = JSON.parse_string(f)["b"]
	var b: Array = arr[100]
	var gy: float = main.height_at(b[0], b[1])
	var inside := Vector3(b[0], gy + 2.0, b[1])
	var outside := Vector3(b[0] + 60.0, gy + 2.0, b[1])
	var above := Vector3(b[0], gy + 40.0, b[1])
	var r_in: String = main.check_crash(inside)
	var r_out: String = main.check_crash(outside)
	var r_up: String = main.check_crash(above)
	print("  здание #100: внутри='%s' снаружи='%s' сверху='%s'  (%s)" % [r_in, r_out, r_up, main.collision.stats()])
	if r_in != "здание": ok = false
	if r_up != "": ok = false
	# LOS: вверх +400 м — чисто; за хребтом низко — падает. Точки — относительно старта.
	var op: Vector3 = main._home_pos
	op.y = main.height_at(op.x, op.z) + 2.0
	var hi := op + Vector3(0, 400, 0)
	var l_hi: float = main.los_factor(op, hi)
	# ищем точку в 2–5 км с худшим LOS
	var worst := 1.0
	for i in 24:
		var a := TAU * i / 24.0
		for d: float in [2000.0, 3500.0, 5000.0]:
			var p := Vector3(op.x + cos(a) * d, 0, op.z + sin(a) * d)
			p.y = main.height_at(p.x, p.z) + 5.0
			worst = minf(worst, main.los_factor(op, p))
	print("  LOS вверх=%.2f, худший низкий в 2–5 км=%.2f" % [l_hi, worst])
	if l_hi < 0.99: ok = false
	if worst > 0.9:
		print("  (предупреждение: рельеф региона не перекрывает сигнал — равнина?)")
	return ok


func _test_ew() -> bool:
	if main.ew == null or main.ew.jammers.is_empty():
		print("  РЭБ отключена — пропуск"); return true
	var j: Dictionary = main.ew.jammers[0]
	var at_center: float = main.ew.jam_factor(j.pos + Vector3(0, 30, 0))
	var at_edge: float = main.ew.jam_factor(j.pos + Vector3(j.r * 0.98, 30, 0))
	var far: float = main.ew.jam_factor(j.pos + Vector3(j.r * 3.0, 30, 0))
	print("  jam центр=%.2f край=%.2f вне=%.2f" % [at_center, at_edge, far])
	return at_center < 0.1 and at_edge > 0.9 and far == 1.0


func _test_ballistics() -> bool:
	var tg: Node3D = main.targets
	if tg == null:
		return false
	# цель у ближайшей дороги к дому, снаряд бросаем ровно над ней с 80 м без скорости → должна погибнуть
	var spawned: Array = tg.spawn_near(main._home_pos, ["apc"])
	if spawned.is_empty():
		print("  нет дорог для спавна — пропуск"); return true
	var t: Dictionary = spawned[0]
	t.speed = 0.0
	tg._process(0.01)                     # поставить на дорогу
	var tp: Vector3 = t.node.position
	var mi := MeshInstance3D.new(); tg.add_child(mi)
	tg._projs.append({"node": mi, "pos": tp + Vector3(0, 80, 0), "vel": Vector3.ZERO, "t": 0.0})
	var steps := 0
	while not tg._projs.is_empty() and steps < 3000:
		tg._step_projs(1.0 / 120.0)
		steps += 1
	var tflight := steps / 120.0
	print("  падение с 80 м: %.2f с (ждём ~4.0–4.6), цель жива=%s (ждём false)" % [tflight, t.alive])
	var ok: bool = tflight > 3.8 and tflight < 4.8 and not bool(t.alive)
	# промах: с 80 м при горизонтальной скорости 20 м/с снаряд улетает ~70–80 м вперёд
	var mi2 := MeshInstance3D.new(); tg.add_child(mi2)
	var start := tp + Vector3(0, 80, 0)
	tg._projs.append({"node": mi2, "pos": start, "vel": Vector3(20, 0, 0), "t": 0.0})
	var last := start
	steps = 0
	while not tg._projs.is_empty() and steps < 3000:
		last = tg._projs[0].pos
		tg._step_projs(1.0 / 120.0)
		steps += 1
	var carry := last.x - start.x
	print("  вынос при 20 м/с с 80 м: %.0f м (ждём 60–85)" % carry)
	ok = ok and carry > 60.0 and carry < 85.0
	tg.reset_ammo()
	return ok
