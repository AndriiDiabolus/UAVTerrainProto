extends Node3D
## Движущиеся цели (танки, БТР, пехота) на реальных дорогах OSM + поражение.

const MAX_VEHICLES := 18
const MAX_SQUADS := 6
const SPAWN_NEAR := 600.0
const SPAWN_FAR := 4000.0
var _spawn_near_override := 0.0     # для стартовой партии — спавн ближе
const DESPAWN := 5500.0
const FIRE_RANGE := 900.0
const FIRE_COOLDOWN := 0.5
const RAM_DIST := 8.0

var main: Node3D
var roads: Array = []          # [{p: [[x,z],...], len: [кумулятивные длины]}]
var targets: Array = []        # словари-цели
var score := 0
var _cool := 0.0
var _spawn_accum := 0.0

var _units: RefCounted            # units.gd: риги техники и меши пехоты
var soldier_mesh: ArrayMesh
var wreck_mat := StandardMaterial3D.new()


func setup(m: Node3D) -> void:
	main = m
	wreck_mat.albedo_color = Color(0.09, 0.08, 0.07)
	wreck_mat.roughness = 1.0
	# утверждённые варианты из units.gd: танк с «мангалом», БТР-80, солдат в оливе
	# (старые _make_* ниже оставлены как история, не вызываются)
	_units = load("res://scripts/units.gd").new()
	soldier_mesh = _units.soldier(2)
	_load_roads()
	_spawn_near_override = 200.0    # стартовая партия близко и на виду
	for i in 14:
		_try_spawn()
	_spawn_near_override = 0.0
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--weapon="):
			weapon = clampi(int(a.substr(9)), 0, WEAPONS.size() - 1)
	if "--targetdebug" in OS.get_cmdline_user_args():
		_debug_spawn_ahead()


## Гарантированные цели прямо перед стартовой камерой (для проверки).
func _debug_spawn_ahead() -> void:
	var cam_pos: Vector3 = main.cam.global_position
	var fwd: Vector3 = -main.cam.global_transform.basis.z
	var probe := cam_pos + fwd * 350.0
	var best: Dictionary = {}
	var best_d := 1e9
	var best_off := 0.0
	for road: Dictionary in roads:
		var lens: Array = road["len"]
		for i in range(0, lens.size(), 2):
			var p := _road_pos(road, lens[i])
			var d := Vector2(p.x - probe.x, p.y - probe.z).length()
			if d < best_d:
				best_d = d
				best = road
				best_off = lens[i]
	if not best.is_empty():
		if "--onetank" in OS.get_cmdline_user_args():
			_spawn_vehicle("tank", best, best_off)
		elif "--oneapc" in OS.get_cmdline_user_args():
			_spawn_vehicle("apc", best, best_off)
		elif "--onesquad" in OS.get_cmdline_user_args():
			_spawn_squad(best, best_off)
		else:
			_spawn_vehicle("tank", best, best_off)
			_spawn_vehicle("apc", best, best_off + 40.0)
			_spawn_squad(best, best_off + 80.0)


## Спавн заданных целей у ближайшей к точке дороги (для миссий). Возвращает словари целей.
func spawn_near(pos: Vector3, kinds: Array) -> Array:
	var best: Dictionary = {}
	var best_d := 1e9
	var best_off := 0.0
	for road: Dictionary in roads:
		var lens: Array = road["len"]
		for i in range(0, lens.size(), 2):
			var p := _road_pos(road, lens[i])
			var d := Vector2(p.x - pos.x, p.y - pos.z).length()
			if d < best_d:
				best_d = d
				best = road
				best_off = lens[i]
	var out: Array = []
	if best.is_empty():
		return out
	var off := best_off
	for k: String in kinds:
		var before := targets.size()
		if k == "soldier":
			_spawn_squad(best, off)
		else:
			_spawn_vehicle(k, best, off)
		for i in range(before, targets.size()):
			out.append(targets[i])
		off += 45.0
	return out


signal target_killed(kind: String, pos: Vector3)


func _load_roads() -> void:
	var f := FileAccess.get_file_as_string(main.asset_path("roads.json"))
	if f.is_empty():
		return
	for r: Dictionary in JSON.parse_string(f)["roads"]:
		var pts: Array = r["p"]
		if pts.size() < 2:
			continue
		var lens: Array[float] = [0.0]
		var total := 0.0
		for i in range(1, pts.size()):
			total += Vector2(pts[i][0] - pts[i-1][0], pts[i][1] - pts[i-1][1]).length()
			lens.append(total)
		if total > 150.0:
			roads.append({"p": pts, "len": lens, "total": total})
	print("Targets: дорог для патрулей: ", roads.size())


## Нормаль рельефа в точке (центральные разности).
func _terrain_normal(x: float, z: float) -> Vector3:
	var e := 4.0
	var hl: float = main.height_at(x - e, z); var hr: float = main.height_at(x + e, z)
	var hd: float = main.height_at(x, z - e); var hu: float = main.height_at(x, z + e)
	return Vector3(hl - hr, 2.0 * e, hd - hu).normalized()


func _road_pos(road: Dictionary, dist: float) -> Vector2:
	var lens: Array = road["len"]
	var pts: Array = road["p"]
	dist = clampf(dist, 0.0, road["total"])
	for i in range(1, lens.size()):
		if dist <= lens[i]:
			var t: float = (dist - lens[i-1]) / maxf(lens[i] - lens[i-1], 0.01)
			return Vector2(lerpf(pts[i-1][0], pts[i][0], t), lerpf(pts[i-1][1], pts[i][1], t))
	return Vector2(pts[-1][0], pts[-1][1])


func _try_spawn() -> void:
	if roads.is_empty() or main.cam == null:
		return
	var vehicles := 0
	var squads := 0
	for t in targets:
		if t.alive:
			if t.kind == "soldier": squads += (1 if t.leader else 0)
			else: vehicles += 1
	var cam_xz := Vector2(main.cam.global_position.x, main.cam.global_position.z)
	var tries := 60 if _spawn_near_override > 0.0 else 24
	for attempt in tries:
		var road: Dictionary = roads.pick_random()
		var d: float = randf() * road["total"]
		var p := _road_pos(road, d)
		var dist := p.distance_to(cam_xz)
		var near: float = _spawn_near_override if _spawn_near_override > 0.0 else SPAWN_NEAR
		var far: float = 2200.0 if _spawn_near_override > 0.0 else SPAWN_FAR
		if dist < near or dist > far:
			continue
		var roll := randf()
		if roll < 0.55 and vehicles < MAX_VEHICLES:
			_spawn_vehicle("tank" if randf() < 0.5 else "apc", road, d)
			return
		elif squads < MAX_SQUADS:
			_spawn_squad(road, d)
			return


func _spawn_vehicle(kind: String, road: Dictionary, d: float) -> void:
	var rig: Dictionary = _units.tank_node(2) if kind == "tank" else _units.apc_node(1)
	var mi: Node3D = rig.root
	_add_marker(mi, Color(1.0, 0.15, 0.1) if kind == "tank" else Color(1.0, 0.55, 0.05), 70.0)
	add_child(mi)
	# ~45 % техники идёт не по дороге, а полем — вейпоинты в стороне от дорог
	var offroad := randf() < 0.45
	var op := _road_pos(road, d)
	if offroad:
		var found := false
		for k in 8:
			var ang := randf() * TAU
			var cand := op + Vector2(cos(ang), sin(ang)) * randf_range(40.0, 160.0)
			if _offroad_ok(cand):
				op = cand; found = true
				break
		offroad = found
	targets.append({"kind": kind, "node": mi, "road": road, "d": d,
		"offroad": offroad, "ox": op.x, "oz": op.y, "hdg": randf() * TAU, "tgt": op,
		"turret": rig.turret, "tracks": rig.tracks, "wheels": rig.wheels, "wheel_r": float(rig.wheel_r),
		"gun": rig.get("gun"),
		"dir": 1.0 if randf() < 0.5 else -1.0,
		"speed": randf_range(3.0, 5.0) if kind == "tank" else randf_range(6.0, 9.0),
		"radius": 5.0, "alive": true, "leader": true, "wreck_t": 0.0, "offset": 0.0,
		"alert": false, "aa_t": randf_range(0.0, 1.5), "marked": false,
		"dust": main.fx.dust(mi) if main.get("fx") != null else null})


func _spawn_squad(road: Dictionary, d: float) -> void:
	var n := randi_range(3, 5)
	for i in n:
		var mi := MeshInstance3D.new()
		mi.mesh = soldier_mesh
		if i == 0:
			_add_marker(mi, Color(1.0, 0.9, 0.1), 50.0)   # маркер над командиром группы
		add_child(mi)
		targets.append({"kind": "soldier", "node": mi, "road": road,
			"d": d - i * 4.0, "dir": 1.0, "speed": randf_range(1.2, 1.7),
			"radius": 2.0, "alive": true, "leader": i == 0, "wreck_t": 0.0,
			"offset": randf_range(-2.5, 2.5), "alert": false, "aa_t": randf_range(0.0, 2.0),
			"marked": false, "hide_off": randf_range(9.0, 14.0) * (1.0 if randf() < 0.5 else -1.0)})


## Яркий столб-маркер над целью + billboard-ромб на вершине (видно с воздуха).
func _add_marker(node: Node3D, color: Color, h: float) -> void:
	if "--nomarkers" in OS.get_cmdline_user_args():
		return
	var beam := MeshInstance3D.new()
	beam.name = "Marker"
	var bm := BoxMesh.new()
	bm.size = Vector3(0.55, h, 0.55)          # тонкая нить: толстый столб закрывал саму цель
	beam.mesh = bm
	beam.position = Vector3(0, h * 0.5 + 3.0, 0)
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.albedo_color = Color(color.r, color.g, color.b, 0.38)
	mat.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED   # столб всегда развёрнут к камере
	mat.billboard_keep_scale = true
	beam.mesh.surface_set_material(0, mat)
	beam.set("no_depth_test", true)
	node.add_child(beam)
	var cap := MeshInstance3D.new()
	cap.name = "MarkerCap"
	var sph := SphereMesh.new(); sph.radius = 1.1; sph.height = 2.2
	cap.mesh = sph
	cap.position = Vector3(0, h + 4.0, 0)
	var cm := StandardMaterial3D.new()
	cm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	cm.albedo_color = color
	cap.mesh.surface_set_material(0, cm)
	node.add_child(cap)


func _process(dt: float) -> void:
	if main == null or main.cam == null:
		return
	_cool = maxf(0.0, _cool - dt)
	_spawn_accum += dt
	if _spawn_accum >= 2.0:
		_spawn_accum = 0.0
		_try_spawn()
		_cleanup()
	var cam_pos: Vector3 = main.cam.global_position
	_step_projs(dt)
	var agl: float = cam_pos.y - main.height_at(cam_pos.x, cam_pos.z)
	var drone_spd: float = main.cam.speed() if main.cam.has_method("speed") else 0.0
	for t: Dictionary in targets:
		if not t.alive:
			t.wreck_t += dt
			continue
		# --- обнаружение дрона и реакция ---
		var dist_d: float = cam_pos.distance_to(t.node.position)
		# в главном меню дрон «невидим»; высотный разведчик-крыло цели не замечают и не обстреливают
		var can_see: bool = not main.get("menu_open") and str(main.cam.get("drone_id")) != "wing"
		if not t.alert and can_see:
			var det := 250.0 if t.kind == "soldier" else 420.0
			if dist_d < det and agl < 220.0:
				t.alert = true
				if t.kind != "soldier":
					t.speed *= 2.4          # техника уходит на полном ходу
				if main.get("telemetry") != null:
					main.telemetry.event("target_alert", {"kind": t.kind})
		if t.alert and t.kind == "soldier":
			# пехота сходит с дороги в укрытие и залегает
			t.offset = lerpf(t.offset, t.hide_off, clampf(dt * 0.6, 0.0, 1.0))
			t.speed = lerpf(t.speed, 0.15, clampf(dt * 0.8, 0.0, 1.0))
		# --- ответный огонь (БТР — автопушка, танк — ЗПУ, пехота — стрелковое) ---
		if t.alert and _aa_enabled and can_see:
			t.aa_t -= dt
			var rng_max := 120.0 if t.kind == "soldier" else 450.0
			if t.aa_t <= 0.0 and dist_d < rng_max:
				t.aa_t = 1.6 if t.kind != "soldier" else 2.5
				var origin: Vector3 = t.node.position + Vector3(0, 2.2, 0)
				if _terrain_hit(origin, (cam_pos - origin).normalized(), dist_d) >= dist_d - 1.0:
					_aa_burst(t, origin, cam_pos, dist_d, rng_max, agl, drone_spd)
		# движение: по дороге туда-обратно либо по полям между вейпоинтами
		var dir3: Vector2
		var wx: float
		var wz: float
		if t.get("offroad", false):
			t.d += t.speed * dt                       # одометр — для траков/колёс
			var pos2 := Vector2(t.ox, t.oz)
			if pos2.distance_to(t.tgt) < 8.0:
				_pick_offroad_target(t)
			var want: Vector2 = t.tgt - pos2
			var des_yaw := atan2(-want.y, want.x)
			t.hdg = lerp_angle(t.hdg, des_yaw, clampf(dt * 0.55, 0.0, 1.0))   # разворот плавный
			dir3 = Vector2(cos(t.hdg), -sin(t.hdg))
			var nx: float = t.ox + dir3.x * t.speed * dt
			var nz: float = t.oz + dir3.y * t.speed * dt
			if main.collision != null and main.collision.in_building(nx, nz, 2.0):
				_pick_offroad_target(t)               # упёрлись в здание — новая точка
			else:
				t.ox = nx; t.oz = nz
			wx = t.ox; wz = t.oz
		else:
			t.d += t.dir * t.speed * dt
			var road: Dictionary = t.road
			if t.d <= 0.0 or t.d >= road["total"]:
				t.dir = -t.dir
				t.d = clampf(t.d, 0.0, road["total"])
			var p := _road_pos(road, t.d)
			var p2 := _road_pos(road, t.d + t.dir * 5.0)
			dir3 = Vector2(p2.x - p.x, p2.y - p.y)
			if dir3.length_squared() < 0.01:
				dir3 = Vector2(1, 0)
			dir3 = dir3.normalized()
			var side: Vector2 = Vector2(-dir3.y, dir3.x) * t.offset
			wx = p.x + side.x
			wz = p.y + side.y
		var y: float = main.height_at(wx, wz)
		if t.kind == "soldier":
			# лёгкое покачивание при ходьбе + мелкая рысканье
			var bob := sin(t.d * 3.2) * 0.05
			var yaw := atan2(-dir3.y, dir3.x) + sin(t.d * 1.6) * 0.06
			t.node.transform = Transform3D(Basis(Vector3.UP, yaw), Vector3(wx, y + bob, wz))
		else:
			# техника прижимается к рельефу, но крен ограничен (иначе тонет на кручах)
			var up := _terrain_normal(wx, wz)
			up = (up + Vector3.UP * 1.6).normalized()
			var fwd := Vector3(dir3.x, 0, dir3.y)
			fwd = (fwd - up * fwd.dot(up)).normalized()
			var rgt := fwd.cross(up).normalized()
			t.node.transform = Transform3D(Basis(fwd, up, rgt), Vector3(wx, y + 0.25, wz))
			if t.get("dust") != null:
				t.dust.emitting = t.speed > 2.5 and dist_d < 900.0
			# башня: при тревоге ведёт дрон, иначе медленно «сканирует»; траки бегут, колёса крутятся
			if t.get("turret") != null:
				var des: float = sin(t.d * 0.02) * 0.5
				if t.alert:
					var lp: Vector3 = t.node.to_local(cam_pos)
					des = atan2(-lp.z, lp.x)
				var tur: Node3D = t.turret
				tur.rotation.y = lerp_angle(tur.rotation.y, des, clampf(dt * 1.2, 0.0, 1.0))
				# орудие: вертикальная наводка на дрон (при тревоге), иначе горизонт
				if t.get("gun") != null:
					var gdes := 0.0
					if t.alert:
						var lp2: Vector3 = t.node.to_local(cam_pos)
						var hh := Vector2(lp2.x, lp2.z).length()
						gdes = clampf(atan2(lp2.y - 2.4, maxf(hh, 1.0)), -0.12, 1.15)
					var gn: Node3D = t.gun
					gn.rotation.z = lerpf(gn.rotation.z, gdes, clampf(dt * 1.5, 0.0, 1.0))
				if t.get("tracks") != null:
					var tr: Node3D = t.tracks
					tr.position.x = fposmod(t.d, 0.9) - 0.45
				for wn: Node3D in t.wheels:
					wn.rotation.z = -t.d / t.wheel_r
		# таран дроном
		if cam_pos.distance_to(t.node.position) < RAM_DIST + t.radius:
			_kill(t, t.node.position)
	# чистка старых обломков
	for t: Dictionary in targets.duplicate():
		if not t.alive and t.wreck_t > (90.0 if t.kind != "soldier" else 25.0):
			t.node.queue_free()
			targets.erase(t)


func _cleanup() -> void:
	var cam_xz := Vector2(main.cam.global_position.x, main.cam.global_position.z)
	for t: Dictionary in targets.duplicate():
		var p: Vector3 = t.node.position
		if Vector2(p.x, p.z).distance_to(cam_xz) > DESPAWN:
			t.node.queue_free()
			targets.erase(t)


func active_count() -> int:
	var n := 0
	for t in targets:
		if t.alive:
			n += 1
	return n


# ======================= Боеприпасы: сброс с баллистикой =======================
const AMMO_MAX := 6
const DROP_COOLDOWN := 1.2
const BOMB_DRAG := 0.004            # c/m: F/m = -c·v_air·|v_air|
const BLAST_R := 7.0                # радиус поражения техники, м (пехота ×1.3)
var ammo := AMMO_MAX

# --- вооружение дрона: 0 = сброс осколочный, 1 = сброс кумулятивный, 2 = БЧ-камикадзе ---
const WEAPONS := ["сброс ОСКОЛОЧНЫЙ", "сброс КУМУЛЯТИВНЫЙ", "БЧ (камикадзе)", "ВОЗДУХ дробовик"]
const WEAPON_HINTS := ["по пехоте, R≈10 м; технике нужен прямой", "по технике, класть точно (R≈4.5 м)", "взвод ЛКМ, подрыв при столкновении", "по воздушным целям: конус ЛКМ ≤90 м или таран"]
var weapon := 0
var armed := false                  # БЧ взведена (клавиша применения при выбранной БЧ)
const KAMI_R := 11.0                # радиус поражения БЧ, м (тяжелее сбросного боеприпаса)
var ammo_frag := 6                  # осколочные (лёгкие — больше на борту)
var ammo_heat := 4                  # кумулятивные


func cycle_weapon(dir: int = 1) -> void:
	weapon = posmod(weapon + dir, WEAPONS.size())
	armed = false
	if main.hud != null:
		main.hud.toast("оружие: %s" % WEAPONS[weapon], WEAPON_HINTS[weapon], Color(0.95, 0.9, 0.8))
	if main.get("telemetry") != null:
		main.telemetry.event("weapon", {"w": WEAPONS[weapon]})


func weapon_ammo() -> int:
	return ammo_frag if weapon == 0 else (ammo_heat if weapon == 1 else 1)


## Подрыв БЧ камикадзе в точке столкновения: поражение целей в радиусе, большой эффект.
func detonate(pos: Vector3) -> void:
	armed = false
	var any := false
	for t: Dictionary in targets:
		if not t.alive:
			continue
		var r := KAMI_R * (1.3 if t.kind == "soldier" else 1.0)
		if pos.distance_to(t.node.position) < r + t.radius * 0.5:
			_kill(t, t.node.position)
			any = true
	if main.get("sound") != null:
		main.sound.boom(pos)
	if main.get("fx") != null:
		main.fx.explosion(pos, true)
	if main.get("telemetry") != null:
		main.telemetry.event("kamikaze", {"x": pos.x, "z": pos.z, "hit": any})
var _projs: Array = []              # {node, pos, vel, t}


func reset_ammo() -> void:
	ammo = AMMO_MAX
	ammo_frag = 6
	ammo_heat = 4


## ЛКМ — сброс боеприпаса. Летит по баллистике: начальная скорость = скорость дрона, гравитация,
## сопротивление относительно воздуха (ветер сносит), взрыв при касании земли или прямом попадании.
## Ударный FPV — таран корпусом (RAM_DIST) работает всегда.
func fire(cam: Camera3D) -> void:
	if weapon == 2:
		# камикадзе: клавиша применения взводит/снимает БЧ
		armed = not armed
		if main.hud != null:
			main.hud.toast("БЧ ВЗВЕДЕНА — столкновение = подрыв" if armed else "БЧ снята с боевого взвода")
		if main.get("sound") != null and armed:
			main.sound.shot()
		return
	if _cool > 0.0 or weapon_ammo() <= 0:
		return
	_cool = DROP_COOLDOWN
	if weapon == 0: ammo_frag -= 1
	else: ammo_heat -= 1
	if main.get("sound") != null:
		main.sound.shot()
	var v0: Vector3 = cam.velocity if cam.get("velocity") != null else Vector3.ZERO
	var mi := MeshInstance3D.new()
	var sph := SphereMesh.new(); sph.radius = 0.28; sph.height = 0.56
	sph.radial_segments = 8; sph.rings = 4
	mi.mesh = sph
	var mat := StandardMaterial3D.new(); mat.albedo_color = Color(0.12, 0.12, 0.11)
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # мелкий снаряд тень не отбрасывает
	mi.position = cam.global_position - Vector3(0, 1.0, 0)
	add_child(mi)
	_projs.append({"node": mi, "pos": mi.position, "vel": v0 + Vector3(0, -1.5, 0), "t": 0.0, "wt": weapon})
	if main.get("telemetry") != null:
		main.telemetry.event("drop", {"ammo": weapon_ammo(), "wt": weapon})


func _step_projs(dt: float) -> void:
	if _projs.is_empty():
		return
	var wind := Vector3.ZERO
	if main.get("weather") != null:
		wind = main.weather.wind_vec()
	for pr: Dictionary in _projs.duplicate():
		pr.t += dt
		var v: Vector3 = pr.vel
		var v_air: Vector3 = v - wind
		v.y -= 9.81 * dt
		v -= v_air * v_air.length() * BOMB_DRAG * dt
		pr.vel = v
		var p: Vector3 = pr.pos + v * dt
		pr.pos = p
		pr.node.position = p
		var g: float = main.height_at(p.x, p.z)
		var hit: bool = p.y <= g + 0.2 or pr.t > 25.0
		if not hit:
			for t: Dictionary in targets:
				if t.alive and p.distance_to(t.node.position + Vector3(0, 1.2, 0)) < t.radius + 0.6:
					hit = true
					break
		if hit:
			_explode(Vector3(p.x, maxf(p.y, g), p.z), int(pr.get("wt", 1)))
			pr.node.queue_free()
			_projs.erase(pr)


## wt: 0 — осколочный (пехота R 10, технике нужен почти прямой), 1 — кумулятивный (техника R 4.5).
func _explode(pos: Vector3, wt: int = 1) -> void:
	var any := false
	for t: Dictionary in targets:
		if not t.alive:
			continue
		var r: float
		if wt == 0:
			r = 10.0 if t.kind == "soldier" else 2.5
		else:
			r = 4.0 if t.kind == "soldier" else 4.5
		if pos.distance_to(t.node.position) < r + t.radius * 0.5:
			_kill(t, t.node.position)
			any = true
	if not any:
		if main.get("sound") != null:
			main.sound.boom(pos)
		_puff(pos + Vector3(0, 1.5, 0), Color(0.55, 0.45, 0.32), 8.0)
		_puff(pos + Vector3(0, 3.0, 0), Color(0.3, 0.28, 0.25), 12.0)
		if main.get("fx") != null:
			main.fx.explosion(pos, false)
	if main.get("telemetry") != null:
		main.telemetry.event("impact", {"x": pos.x, "z": pos.z, "hit": any})


var _aa_enabled := not ("--noaa" in OS.get_cmdline_user_args())


## Отметка цели разведчиком (ЛКМ у wing): ближайшая к оптической оси живая цель
## в конусе max_ang_deg и до 6 км помечается (t.marked) — метку видят все дроны в HUD.
func mark_at(cam: Camera3D, max_ang_deg: float) -> Dictionary:
	var fwd: Vector3 = -cam.global_transform.basis.z
	var origin: Vector3 = cam.global_position
	var best_ang := deg_to_rad(max_ang_deg)
	var best: Dictionary = {}
	for t: Dictionary in targets:
		if not t.alive:
			continue
		var to: Vector3 = (t.node.position + Vector3(0, 1.5, 0)) - origin
		if to.length() > 6000.0:
			continue
		var ang := fwd.angle_to(to.normalized())
		if ang < best_ang:
			best_ang = ang
			best = t
	if not best.is_empty():
		best.marked = true
		if main.get("telemetry") != null:
			main.telemetry.event("target_marked", {"kind": best.kind})
	return best


## Живые отмеченные цели — для HUD-маркеров всех дронов.
func marked_list() -> Array:
	var out: Array = []
	for t: Dictionary in targets:
		if t.alive and t.get("marked", false):
			out.append(t)
	return out


## Очередь по дрону: вероятность попадания растёт вблизи, при малой скорости и малой высоте.
func _aa_burst(t: Dictionary, origin: Vector3, drone: Vector3, dist: float, rng_max: float, agl: float, spd: float) -> void:
	var base := 0.03 if t.kind == "soldier" else 0.11
	var p := base * (1.0 - dist / rng_max) * (0.35 + 0.65 * (1.0 - clampf(spd / 22.0, 0.0, 1.0)))
	if agl > 120.0: p *= 0.4
	var hit := randf() < p
	# трассер: линия к дрону (при промахе — мимо на 3–9 м)
	var miss := Vector3.ZERO if hit else Vector3(randf_range(-1, 1), randf_range(-0.6, 0.6), randf_range(-1, 1)).normalized() * randf_range(3.0, 9.0)
	_tracer(origin, drone + miss)
	if main.get("sound") != null:
		main.sound.shot()
	if main.get("telemetry") != null:
		main.telemetry.event("aa_fire", {"kind": t.kind, "dist": int(dist), "hit": hit})
	if hit and not main.crashed:
		main.crash("зенитный огонь (%s)" % {"tank": "ЗПУ танка", "apc": "автопушка БТР", "soldier": "стрелковое"}.get(t.kind, "огонь"))


func _tracer(a: Vector3, b: Vector3) -> void:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(a); im.surface_add_vertex(b)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(1.0, 0.75, 0.3)
	mat.emission_enabled = true; mat.emission = Color(1.0, 0.7, 0.3); mat.emission_energy_multiplier = 2.0
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # трассер — свет, не предмет
	add_child(mi)
	var tw := create_tween()
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.35)
	tw.tween_callback(mi.queue_free)


func _terrain_hit(origin: Vector3, dir: Vector3, max_d: float) -> float:
	var step := 20.0
	var d := step
	while d < max_d:
		var p := origin + dir * d
		if p.y < main.height_at(p.x, p.z):
			return d
		d += step
	return max_d


func _kill(t: Dictionary, pos: Vector3) -> void:
	t.alive = false
	score += 1
	target_killed.emit(t.kind, pos)
	if main.get("sound") != null:
		main.sound.boom(pos)
	for g: MeshInstance3D in _geo_list(t.node):
		g.material_override = wreck_mat
	for c in t.node.get_children():   # погасить маркер над подбитой целью (риг-узлы не трогаем)
		if str(c.name).begins_with("Marker"):
			c.queue_free()
	_puff(pos + Vector3(0, 2, 0), Color(1.0, 0.55, 0.15), 9.0)
	_puff(pos + Vector3(0, 4, 0), Color(0.25, 0.23, 0.2), 14.0)
	if main.get("fx") != null:
		main.fx.explosion(pos, t.kind != "soldier")
		if t.kind != "soldier":
			main.fx.wreck_fire(t.node)     # после чистки детей — пламя/дым остаются


## Пригодна ли точка для хода техники полем: не здание, не круча, не русло.
func _offroad_ok(pt: Vector2) -> bool:
	if main.collision != null and main.collision.in_building(pt.x, pt.y, 5.0):
		return false
	if _terrain_normal(pt.x, pt.y).y < 0.82:
		return false
	var rn := main.get_node_or_null("Roads")
	if rn != null and rn.has_method("_near_water") and rn._near_water(pt.x, pt.y, 4.0):
		return false
	return true


## Новый вейпоинт для техники в поле (80–350 м, с проверкой проходимости).
func _pick_offroad_target(t: Dictionary) -> void:
	var pos2 := Vector2(t.ox, t.oz)
	for k in 10:
		var ang := randf() * TAU
		var cand := pos2 + Vector2(cos(ang), sin(ang)) * randf_range(80.0, 350.0)
		if _offroad_ok(cand):
			t.tgt = cand
			return
	t.tgt = pos2 + Vector2(randf_range(-40.0, 40.0), randf_range(-40.0, 40.0))


## Все MeshInstance3D узла (рекурсивно), частицы и маркеры не включаются.
func _geo_list(n: Node) -> Array:
	var out := []
	if n is GPUParticles3D or str(n.name).begins_with("Marker"):
		return out
	if n is MeshInstance3D:
		out.append(n)
	for c in n.get_children():
		out.append_array(_geo_list(c))
	return out


## Ближайшая живая цель к точке и дистанция до неё (для HUD-указателя).
func nearest(pos: Vector3) -> Dictionary:
	var best: Dictionary = {}
	var best_d := 1e20
	for t: Dictionary in targets:
		if not t.alive:
			continue
		var d: float = pos.distance_squared_to(t.node.position)
		if d < best_d:
			best_d = d
			best = t
	if best.is_empty():
		return {}
	return {"pos": best.node.position, "kind": best.kind, "dist": sqrt(best_d)}


## Простой эффект: расширяющаяся затухающая сфера.
func _puff(pos: Vector3, color: Color, max_r: float) -> void:
	var mi := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radial_segments = 12; sph.rings = 6
	var mat := StandardMaterial3D.new()
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = color
	sph.material = mat
	mi.mesh = sph
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF   # эффект без тени
	mi.position = pos
	add_child(mi)
	var tw := create_tween().set_parallel(true)
	tw.tween_property(mi, "scale", Vector3.ONE * max_r, 0.7).from(Vector3.ONE * 0.5)
	tw.tween_property(mat, "albedo_color:a", 0.0, 0.7).from(0.9)
	tw.chain().tween_callback(mi.queue_free)


# ---------- сборка моделей из примитивов ----------

func _append(mesh: ArrayMesh, prim: PrimitiveMesh, xform: Transform3D, color: Color) -> void:
	var arr: Array = prim.get_mesh_arrays()
	var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
	for i in verts.size():
		verts[i] = xform * verts[i]
		norms[i] = xform.basis * norms[i]
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = norms
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	var mat := StandardMaterial3D.new()
	mat.albedo_color = color
	mat.roughness = 1.0
	mesh.surface_set_material(mesh.get_surface_count() - 1, mat)


const HULL_GREEN := Color(0.17, 0.20, 0.13)
const HULL_DARK := Color(0.13, 0.16, 0.10)
const METAL_DARK := Color(0.07, 0.075, 0.065)
const CAMO_TAN := Color(0.30, 0.28, 0.18)


## Прямоугольная призма со скосом переднего верхнего ребра (для лобовой брони/носа).
func _sloped_box(size: Vector3, slope: float) -> ArrayMesh:
	var sx := size.x * 0.5; var sy := size.y * 0.5; var sz := size.z * 0.5
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	# 8 вершин; верхние передние (+x,+y) утянуты назад по x на slope
	var v := [
		Vector3(-sx, -sy, -sz), Vector3(sx, -sy, -sz), Vector3(sx, -sy, sz), Vector3(-sx, -sy, sz),
		Vector3(-sx, sy, -sz), Vector3(sx - slope, sy, -sz), Vector3(sx - slope, sy, sz), Vector3(-sx, sy, sz)]
	var faces := [[0,1,2,3],[4,7,6,5],[0,4,5,1],[3,2,6,7],[1,5,6,2],[0,3,7,4]]
	for f in faces:
		var a: Vector3 = v[f[0]]; var b: Vector3 = v[f[1]]; var c: Vector3 = v[f[2]]; var d: Vector3 = v[f[3]]
		var nrm := (b - a).cross(c - a).normalized()
		for tri in [[a, b, c], [a, c, d]]:
			for p: Vector3 in tri:
				st.set_normal(nrm); st.add_vertex(p)
	st.index()
	return st.commit()


## Современный ОБТ (тип Т-72/Т-90): корпус со скошенным лбом, ДЗ, литая башня,
## ствол с эжектором и кожухом, 6 катков + гусеницы, башенка с ЗПУ, бочки, антенны.
func _make_tank() -> ArrayMesh:
	var m := ArrayMesh.new()
	var green := Color(0.37, 0.40, 0.25)
	var dgreen := Color(0.29, 0.31, 0.19)
	var era := Color(0.33, 0.35, 0.22)
	var track_c := Color(0.13, 0.13, 0.12)
	var rubber := Color(0.09, 0.09, 0.09)
	var steel := Color(0.22, 0.23, 0.20)

	# нижний корпус
	var lower := BoxMesh.new(); lower.size = Vector3(6.4, 0.9, 2.7)
	_append(m, lower, Transform3D(Basis(), Vector3(0, 0.95, 0)), dgreen)
	# верхний корпус со скошенным лбом
	_append_mesh(m, _sloped_box(Vector3(6.2, 0.75, 2.7), 1.9), Transform3D(Basis(), Vector3(0, 1.55, 0)), green)
	# надгусеничные полки
	var fender := BoxMesh.new(); fender.size = Vector3(6.6, 0.12, 0.55)
	_append(m, fender, Transform3D(Basis(), Vector3(0, 1.35, 1.5)), dgreen)
	_append(m, fender, Transform3D(Basis(), Vector3(0, 1.35, -1.5)), dgreen)

	# гусеницы + траки (насечки)
	var track := BoxMesh.new(); track.size = Vector3(6.8, 0.7, 0.7)
	_append(m, track, Transform3D(Basis(), Vector3(0, 0.55, 1.42)), track_c)
	_append(m, track, Transform3D(Basis(), Vector3(0, 0.55, -1.42)), track_c)
	var link := BoxMesh.new(); link.size = Vector3(0.16, 0.78, 0.78)
	for lx in range(-3, 4):
		var xx := lx * 0.9
		_append(m, link, Transform3D(Basis(), Vector3(xx, 0.55, 1.42)), steel)
		_append(m, link, Transform3D(Basis(), Vector3(xx, 0.55, -1.42)), steel)
	# катки (6/борт) + ведущее/направляющее по краям
	var wheel := CylinderMesh.new(); wheel.top_radius = 0.5; wheel.bottom_radius = 0.5; wheel.height = 0.28
	for rx in [-2.55, -1.53, -0.51, 0.51, 1.53, 2.55]:
		for rz in [1.42, -1.42]:
			_append(m, wheel, Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(rx, 0.55, rz)), rubber)
	var sprocket := CylinderMesh.new(); sprocket.top_radius = 0.42; sprocket.bottom_radius = 0.42; sprocket.height = 0.3
	for rx in [-3.15, 3.15]:
		for rz in [1.42, -1.42]:
			_append(m, sprocket, Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(rx, 0.75, rz)), steel)

	# блоки динамической защиты на лбу корпуса (ряд наклонных кирпичей)
	var era_b := BoxMesh.new(); era_b.size = Vector3(0.5, 0.28, 0.4)
	for ez in [-1.0, -0.5, 0.0, 0.5, 1.0]:
		_append(m, era_b, Transform3D(Basis(Vector3.BACK, -0.5), Vector3(2.9, 1.7, ez)), era)

	# литая башня — приплюснутый 8-гранный барабан со скосом
	var turret := _oct_turret(1.85, 1.35, 0.95)
	_append_mesh(m, turret, Transform3D(Basis(), Vector3(-0.5, 2.35, 0)), green)
	# ДЗ «щёки» на лбу башни
	for tz in [-0.85, -0.45, 0.45, 0.85]:
		_append(m, era_b, Transform3D(Basis(Vector3.BACK, -0.35), Vector3(0.95, 2.35, tz)), era)
	# бронемаска
	var mant := BoxMesh.new(); mant.size = Vector3(0.9, 0.75, 1.3)
	_append(m, mant, Transform3D(Basis(), Vector3(1.15, 2.35, 0)), dgreen)
	# ствол: казённая часть + теплозащитный кожух + эжектор + дульный срез
	var breech := CylinderMesh.new(); breech.top_radius = 0.2; breech.bottom_radius = 0.22; breech.height = 2.0
	_append(m, breech, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(2.6, 2.35, 0)), steel)
	var barrel := CylinderMesh.new(); barrel.top_radius = 0.12; barrel.bottom_radius = 0.14; barrel.height = 3.0
	_append(m, barrel, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(4.9, 2.35, 0)), Color(0.10, 0.11, 0.09))
	var evac := CylinderMesh.new(); evac.top_radius = 0.24; evac.bottom_radius = 0.24; evac.height = 0.7
	_append(m, evac, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(4.3, 2.35, 0)), steel)
	var muzzle := CylinderMesh.new(); muzzle.top_radius = 0.17; muzzle.bottom_radius = 0.17; muzzle.height = 0.35
	_append(m, muzzle, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(6.3, 2.35, 0)), steel)

	# командирская башенка + ЗПУ (зенитный пулемёт)
	var cupola := CylinderMesh.new(); cupola.top_radius = 0.42; cupola.bottom_radius = 0.46; cupola.height = 0.42
	_append(m, cupola, Transform3D(Basis(), Vector3(-1.0, 3.05, 0.6)), dgreen)
	var mg := CylinderMesh.new(); mg.top_radius = 0.05; mg.bottom_radius = 0.06; mg.height = 1.1
	_append(m, mg, Transform3D(Basis(Vector3.BACK, PI / 2.2), Vector3(-0.4, 3.35, 0.6)), rubber)
	# корзина ЗИП на корме башни
	var basket := BoxMesh.new(); basket.size = Vector3(1.2, 0.5, 1.9)
	_append(m, basket, Transform3D(Basis(), Vector3(-1.9, 2.3, 0)), Color(0.12, 0.13, 0.10))
	# бочки на корме корпуса
	var drum := CylinderMesh.new(); drum.top_radius = 0.28; drum.bottom_radius = 0.28; drum.height = 0.9
	_append(m, drum, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(-3.4, 1.6, 0.7)), dgreen)
	_append(m, drum, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(-3.4, 1.6, -0.7)), dgreen)
	# антенны
	var ant := CylinderMesh.new(); ant.top_radius = 0.015; ant.bottom_radius = 0.03; ant.height = 1.9
	_append(m, ant, Transform3D(Basis(), Vector3(-1.8, 3.4, -0.7)), rubber)
	_append(m, ant, Transform3D(Basis(), Vector3(-1.9, 3.3, 0.7)), rubber)
	return m


## Приплюснутый 8-гранный «барабан» литой башни (ось Y), радиусы xz и высота.
func _oct_turret(rx: float, rz: float, h: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := 8
	var top: Array[Vector3] = []
	var bot: Array[Vector3] = []
	for i in n:
		var a := TAU * i / n + PI / n
		# верх чуть у́же (скос литья)
		top.append(Vector3(cos(a) * rx * 0.82, h * 0.5, sin(a) * rz * 0.82))
		bot.append(Vector3(cos(a) * rx, -h * 0.5, sin(a) * rz))
	# боковые грани
	for i in n:
		var j := (i + 1) % n
		_quad(st, bot[i], bot[j], top[j], top[i])
	# крышка и дно
	var ct := Vector3(0, h * 0.5, 0); var cb := Vector3(0, -h * 0.5, 0)
	for i in n:
		var j := (i + 1) % n
		_tri(st, top[i], top[j], ct)
		_tri(st, bot[j], bot[i], cb)
	st.index()
	return st.commit()


func _quad(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3, d: Vector3) -> void:
	var nrm := (b - a).cross(c - a).normalized()
	for p: Vector3 in [a, b, c, a, c, d]:
		st.set_normal(nrm); st.add_vertex(p)


func _tri(st: SurfaceTool, a: Vector3, b: Vector3, c: Vector3) -> void:
	var nrm := (b - a).cross(c - a).normalized()
	for p: Vector3 in [a, b, c]:
		st.set_normal(nrm); st.add_vertex(p)


## БТР-4-подобный: длинный скошенный корпус, 8 колёс, башня с пушкой (вперёд = +X).
func _make_apc() -> ArrayMesh:
	var m := ArrayMesh.new()
	_append_mesh(m, _sloped_box(Vector3(6.8, 1.5, 2.7), 1.9), Transform3D(Basis(), Vector3(0, 1.55, 0)), CAMO_TAN)
	# скошенные борта (imитируем гранёный корпус узкой верхней вставкой)
	var top := BoxMesh.new(); top.size = Vector3(5.6, 0.6, 2.0)
	_append(m, top, Transform3D(Basis(), Vector3(-0.3, 2.35, 0)), CAMO_TAN)
	# башня + автопушка
	var tur := BoxMesh.new(); tur.size = Vector3(1.6, 0.7, 1.4)
	_append(m, tur, Transform3D(Basis(), Vector3(0.2, 2.9, 0)), Color(0.27, 0.25, 0.16))
	var cannon := CylinderMesh.new(); cannon.top_radius = 0.07; cannon.bottom_radius = 0.09; cannon.height = 2.6
	_append(m, cannon, Transform3D(Basis(Vector3.BACK, PI / 2), Vector3(2.0, 2.9, 0)), METAL_DARK)
	# 8 колёс (4 на борт) с выраженными арками
	var wheel := CylinderMesh.new(); wheel.top_radius = 0.62; wheel.bottom_radius = 0.62; wheel.height = 0.45
	var hub := CylinderMesh.new(); hub.top_radius = 0.22; hub.bottom_radius = 0.22; hub.height = 0.47
	for wx in [-2.5, -0.9, 0.9, 2.5]:
		for wz in [1.35, -1.35]:
			_append(m, wheel, Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(wx, 0.62, wz)), METAL_DARK)
			_append(m, hub, Transform3D(Basis(Vector3.RIGHT, PI / 2), Vector3(wx, 0.62, wz)), Color(0.16, 0.16, 0.14))
	return m


## Пехотинец: торс, голова в каске, ноги, автомат — читается силуэт с воздуха.
func _make_soldier() -> ArrayMesh:
	var m := ArrayMesh.new()
	var uniform := Color(0.20, 0.23, 0.14)
	var torso := BoxMesh.new(); torso.size = Vector3(0.5, 0.65, 0.28)
	_append(m, torso, Transform3D(Basis(), Vector3(0, 1.15, 0)), uniform)
	# рюкзак
	var pack := BoxMesh.new(); pack.size = Vector3(0.32, 0.45, 0.2)
	_append(m, pack, Transform3D(Basis(), Vector3(-0.28, 1.15, 0)), Color(0.16, 0.18, 0.11))
	# ноги
	var leg := BoxMesh.new(); leg.size = Vector3(0.2, 0.8, 0.22)
	_append(m, leg, Transform3D(Basis(), Vector3(0.02, 0.4, 0.14)), Color(0.17, 0.19, 0.12))
	_append(m, leg, Transform3D(Basis(), Vector3(0.02, 0.4, -0.14)), Color(0.17, 0.19, 0.12))
	# голова + каска
	var head := SphereMesh.new(); head.radius = 0.13; head.height = 0.26
	_append(m, head, Transform3D(Basis(), Vector3(0, 1.62, 0)), Color(0.42, 0.33, 0.26))
	var helmet := SphereMesh.new(); helmet.radius = 0.17; helmet.height = 0.2; helmet.is_hemisphere = true
	_append(m, helmet, Transform3D(Basis(), Vector3(0, 1.66, 0)), uniform)
	# автомат наперевес
	var rifle := BoxMesh.new(); rifle.size = Vector3(0.7, 0.07, 0.07)
	_append(m, rifle, Transform3D(Basis(Vector3.UP, 0.3), Vector3(0.35, 1.15, 0.2)), Color(0.04, 0.04, 0.04))
	return m


## Как _append, но принимает уже готовый ArrayMesh (переносит все его поверхности).
func _append_mesh(dst: ArrayMesh, src: ArrayMesh, xform: Transform3D, color: Color) -> void:
	for s in src.get_surface_count():
		var arr := src.surface_get_arrays(s)
		var verts: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
		var norms: PackedVector3Array = arr[Mesh.ARRAY_NORMAL]
		for i in verts.size():
			verts[i] = xform * verts[i]
			if norms.size() > i:
				norms[i] = (xform.basis * norms[i]).normalized()
		arr[Mesh.ARRAY_VERTEX] = verts
		arr[Mesh.ARRAY_NORMAL] = norms
		dst.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.95
		dst.surface_set_material(dst.get_surface_count() - 1, mat)
