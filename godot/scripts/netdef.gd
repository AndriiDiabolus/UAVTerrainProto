extends Node3D
## ПОЛИГОН «СЕТЕВОЙ ЗАСЛОН» — 3D-сцена.
##
## Искусственная испытательная среда на рельефе симулятора: объект защиты (АЗС / подстанция /
## нефтебаза), заслон из аэростатов или коптеров с сетью, закреплённой за грунтовые анкеры,
## и волны угроз (Шахед, Гербера, Ланцет, «Молния», FPV).
##
## Исход каждого перехвата считает netdef_model.gd — сцена ТОЛЬКО отыгрывает посчитанное,
## поэтому картинка и статистика не расходятся.
##
## Запуск: ./run.sh -- --netdef [--netscen=azs_aero_hd] [--region=steppe] [--netwave=shahed]
## Клавиши: P — пуск волны · O — конфигурация заслона · I — тип угрозы · K — ветер
##          L — замедление ×0.25 · U — показать/скрыть полотно · [ ] — рубеж ближе/дальше

const M := preload("res://scripts/netdef_model.gd")
const B := preload("res://scripts/netdef_batch.gd")

var main: Node3D
var hud: CanvasLayer

var site_pos := Vector3.ZERO
var bar: Dictionary = {}
var scen_keys: Array = []
var scen_i := 0
var threat_keys: Array = []
var threat_i := 0
var wind := 3.0
var slow := false
var show_net := true

var live: Array = []                  # летящие угрозы: {node, pos, vel, state, res, ...}
var log_lines: Array = []             # последние исходы (для HUD)
var stats := {}                       # ключ исхода → счётчик
var shots := 0
var stopped := 0
var site_killed := 0

var _rng := RandomNumberGenerator.new()
var _units: RefCounted
var _site_root: Node3D
var _bar_root: Node3D
var _net_tex: ImageTexture
var _wave_left := 0
var _wave_t := 0.0
var _wave_kind := ""
var _r_stand_add := 0.0


func setup(m: Node3D) -> void:
	main = m
	_rng.seed = 424242
	_units = load("res://scripts/units.gd").new()
	scen_keys = B.SCENARIOS.keys()
	threat_keys = B.THREAT_ORDER.duplicate()
	var args := OS.get_cmdline_user_args()
	for a in args:
		if a.begins_with("--netscen="):
			var k := a.substr(10)
			if scen_keys.has(k):
				scen_i = scen_keys.find(k)
		elif a.begins_with("--netwave="):
			var t := a.substr(10)
			if threat_keys.has(t):
				threat_i = threat_keys.find(t)
		elif a.begins_with("--netwind="):
			wind = float(a.substr(10).split(",")[0])
	# полигон — чистая среда: обычные наземные цели и трафик не мешают
	if main.targets != null:
		main.targets.set_process(false)
	if main.get("traffic") != null and main.traffic != null:
		main.traffic.set_process(false)
	# полигон открывается сразу в полёте: титульное меню водит камеру по облёту
	if main.menu != null and bool(main.menu.get("open")):
		main.menu.set_open(false)
	site_pos = _pick_flat_spot()
	_net_tex = _make_net_texture()
	_build_site()
	rebuild_barrier()
	_build_hud()
	_place_observer()
	print("ПОЛІГОН: об'єкт у (%.0f, %.0f), сценарій %s" % [site_pos.x, site_pos.z, scen_keys[scen_i]])
	if "--netshot" in args:
		_netshot()


func scen() -> Dictionary:
	var cfg: Dictionary = B.SCENARIOS[str(scen_keys[scen_i])].duplicate()
	cfg["r_stand"] = float(cfg["r_stand"]) + _r_stand_add
	return cfg


func threat_id() -> String:
	return str(threat_keys[threat_i])


# ─────────────────────────── ПЛОЩАДКА ───────────────────────────

## Площадка под объект: ровная, свободная от застройки, у дороги (АЗС стоит на трассе).
## Заслон строится вокруг неё, поэтому в пятне рубежа не должно быть домов и ЛЭП.
func _pick_flat_spot() -> Vector3:
	var home: Vector3 = main._home_pos
	var best := Vector2(home.x, home.z)
	var best_score := -1e9
	for i in 420:
		# золотой угол по спирали: равномерный разброс кандидатов 400…2600 м от старта
		var a := float(i) * 2.399963
		var d := 400.0 + 2200.0 * sqrt(float(i) / 420.0)
		var c := Vector2(home.x + cos(a) * d, home.z + sin(a) * d)
		var lo := 1e9
		var hi := -1e9
		for k in 9:
			var ox := float(k % 3 - 1) * 55.0
			var oz := float(k / 3 - 1) * 55.0
			var h: float = main.height_at(c.x + ox, c.y + oz)
			lo = minf(lo, h); hi = maxf(hi, h)
		var spread := hi - lo
		if spread > 14.0:
			continue
		# застройка/ЛЭП/деревья в пятне площадки и на рубеже оттяжек
		var blocked := 0
		for k in 16:
			var ang := TAU * float(k) / 16.0
			var rr: float = 35.0 if k % 2 == 0 else 85.0
			var px := c.x + cos(ang) * rr
			var pz := c.y + sin(ang) * rr
			if main.check_crash(Vector3(px, main.height_at(px, pz) + 3.0, pz)) != "":
				blocked += 1
		if main.check_crash(Vector3(c.x, main.height_at(c.x, c.y) + 3.0, c.y)) != "":
			blocked += 4
		var road: bool = main.near_road(c.x, c.y, 60.0)
		var score := -spread * 2.5 - float(blocked) * 12.0 + (18.0 if road else 0.0) - d * 0.002
		if score > best_score:
			best_score = score; best = c
	return Vector3(best.x, main.height_at(best.x, best.y), best.y)


func _mat(c: Color, rough := 0.8, metal := 0.0) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c; m.roughness = rough; m.metallic = metal
	return m


func _box(parent: Node3D, size: Vector3, pos: Vector3, c: Color, rough := 0.8, metal := 0.0) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new(); b.size = size
	mi.mesh = b; mi.position = pos
	mi.material_override = _mat(c, rough, metal)
	parent.add_child(mi)
	return mi


func _cyl(parent: Node3D, r: float, h: float, pos: Vector3, c: Color, rough := 0.6, metal := 0.3) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r; cm.bottom_radius = r; cm.height = h; cm.radial_segments = 12
	mi.mesh = cm; mi.position = pos
	mi.material_override = _mat(c, rough, metal)
	parent.add_child(mi)
	return mi


## Объект защиты. Геометрия — по описанию элементов из модели (радиусы совпадают с расчётом).
func _build_site() -> void:
	if _site_root != null:
		_site_root.queue_free()
	_site_root = Node3D.new()
	_site_root.name = "NetDefSite"
	_site_root.position = site_pos
	add_child(_site_root)
	var site: Dictionary = M.SITES[str(scen()["site"])]
	var sid := str(scen()["site"])
	# бетонная площадка
	var pad := _box(_site_root, Vector3(float(site["radius"]) * 2.0, 0.3, float(site["radius"]) * 1.6),
		Vector3(0, 0.15, 0), Color(0.42, 0.42, 0.40), 0.95)
	pad.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	match sid:
		"azs": _build_azs()
		"substation": _build_substation()
		_: _build_depot()
	# маркеры элементов модели: низкие столбики с подписью в HUD не нужны, но габарит виден
	main.col_add_box(site_pos.x, site_pos.z, 18.0, 12.0, 0.0, site_pos.y + 7.0)


func _build_azs() -> void:
	var r := _site_root
	# навес 22×14 на четырёх колоннах
	_box(r, Vector3(24, 0.7, 15), Vector3(0, 6.2, 0), Color(0.86, 0.86, 0.88), 0.35, 0.25)
	_box(r, Vector3(24.4, 0.5, 15.4), Vector3(0, 5.6, 0), Color(0.15, 0.32, 0.55), 0.4)
	for sx: float in [-9.5, 9.5]:
		for sz: float in [-5.5, 5.5]:
			_cyl(r, 0.35, 5.6, Vector3(sx, 2.8, sz), Color(0.8, 0.8, 0.82), 0.4, 0.3)
	# 4 колонки ПРК под навесом
	for i in 4:
		var x := -7.5 + float(i) * 5.0
		var p := Node3D.new(); p.position = Vector3(x, 0.3, 0); r.add_child(p)
		_box(p, Vector3(1.1, 1.9, 0.6), Vector3(0, 0.95, 0), Color(0.90, 0.36, 0.12), 0.5)
		_box(p, Vector3(0.9, 0.5, 0.65), Vector3(0, 1.55, 0.02), Color(0.06, 0.06, 0.07), 0.3)
		_box(p, Vector3(2.4, 0.25, 1.4), Vector3(0, 0.12, 0), Color(0.3, 0.3, 0.29), 0.95)
	# магазин/операторная 14×9
	var shop := Node3D.new(); shop.position = Vector3(0, 0.3, -20.0); r.add_child(shop)
	_box(shop, Vector3(15, 4.2, 9), Vector3(0, 2.1, 0), Color(0.88, 0.88, 0.85), 0.7)
	_box(shop, Vector3(15.6, 0.4, 9.6), Vector3(0, 4.3, 0), Color(0.16, 0.34, 0.56), 0.5)
	_box(shop, Vector3(12, 2.2, 0.15), Vector3(0, 2.2, 4.55), Color(0.32, 0.45, 0.55, 1.0), 0.15, 0.1)
	# люки подземных резервуаров
	for i in 4:
		_cyl(r, 0.6, 0.12, Vector3(-6.0 + float(i) * 4.0, 0.36, 11.0), Color(0.35, 0.33, 0.30), 0.9, 0.2)
	_box(r, Vector3(18, 0.06, 5), Vector3(0, 0.33, 11.0), Color(0.5, 0.5, 0.48), 0.95)
	# модуль СУГ (газ) в стороне
	var lpg := Node3D.new(); lpg.position = Vector3(20.0, 0.3, 12.0); r.add_child(lpg)
	var tank := MeshInstance3D.new()
	var cm := CapsuleMesh.new(); cm.radius = 1.1; cm.height = 6.0; cm.radial_segments = 16
	tank.mesh = cm
	tank.rotation = Vector3(0, 0, PI * 0.5)
	tank.position = Vector3(0, 1.5, 0)
	tank.material_override = _mat(Color(0.92, 0.90, 0.86), 0.45, 0.2)
	lpg.add_child(tank)
	_box(lpg, Vector3(7.5, 0.2, 3.2), Vector3(0, 0.1, 0), Color(0.45, 0.45, 0.43), 0.95)
	_box(lpg, Vector3(0.9, 1.7, 0.5), Vector3(3.6, 0.85, 1.6), Color(0.85, 0.30, 0.10), 0.5)
	# бензовоз под сливом
	var tr := Node3D.new(); tr.position = Vector3(-16.0, 0.3, 10.0); tr.rotation.y = 0.25; r.add_child(tr)
	_box(tr, Vector3(6.2, 2.6, 2.5), Vector3(-4.0, 1.7, 0), Color(0.25, 0.42, 0.62), 0.55)
	var cyl := MeshInstance3D.new()
	var cc := CylinderMesh.new(); cc.top_radius = 1.3; cc.bottom_radius = 1.3; cc.height = 9.0; cc.radial_segments = 16
	cyl.mesh = cc; cyl.rotation = Vector3(0, 0, PI * 0.5); cyl.position = Vector3(3.2, 2.0, 0)
	cyl.material_override = _mat(Color(0.80, 0.80, 0.83), 0.35, 0.55)
	tr.add_child(cyl)
	for wx: float in [-6.0, -4.2, 1.0, 3.0, 5.0]:
		_cyl(tr, 0.55, 0.4, Vector3(wx, 0.55, 1.25), Color(0.08, 0.08, 0.08), 0.95, 0.0)
		_cyl(tr, 0.55, 0.4, Vector3(wx, 0.55, -1.25), Color(0.08, 0.08, 0.08), 0.95, 0.0)
	# стела и освещение
	_cyl(r, 0.45, 9.0, Vector3(-26.0, 4.5, -6.0), Color(0.85, 0.85, 0.88), 0.4, 0.3)
	_box(r, Vector3(3.6, 4.4, 0.5), Vector3(-26.0, 10.5, -6.0), Color(0.90, 0.36, 0.12), 0.4)


func _build_substation() -> void:
	var r := _site_root
	for i in 2:
		var t := Node3D.new(); t.position = Vector3(-14.0 + float(i) * 26.0, 0.3, 0); r.add_child(t)
		_box(t, Vector3(7.0, 5.0, 5.0), Vector3(0, 2.5, 0), Color(0.55, 0.56, 0.52), 0.6, 0.5)
		for k in 3:
			_cyl(t, 0.5, 2.6, Vector3(-2.0 + float(k) * 2.0, 6.3, 0), Color(0.75, 0.72, 0.62), 0.35, 0.1)
		_box(t, Vector3(8.0, 0.4, 6.0), Vector3(0, 0.2, 0), Color(0.4, 0.4, 0.38), 0.95)
	# портал ОРУ
	for i in 4:
		var x := -30.0 + float(i) * 20.0
		_box(r, Vector3(0.6, 14.0, 0.6), Vector3(x, 7.0, 22.0), Color(0.62, 0.62, 0.6), 0.6, 0.4)
	_box(r, Vector3(64.0, 0.5, 0.5), Vector3(0, 13.5, 22.0), Color(0.62, 0.62, 0.6), 0.6, 0.4)
	_box(r, Vector3(16, 4.0, 10), Vector3(0, 2.3, -18.0), Color(0.85, 0.85, 0.82), 0.7)


func _build_depot() -> void:
	var r := _site_root
	for i in 2:
		var t := Node3D.new(); t.position = Vector3(-25.0 + float(i) * 50.0, 0.3, 0); r.add_child(t)
		var mi := MeshInstance3D.new()
		var cm := CylinderMesh.new(); cm.top_radius = 9.0; cm.bottom_radius = 9.0; cm.height = 12.0; cm.radial_segments = 24
		mi.mesh = cm; mi.position = Vector3(0, 6.0, 0)
		mi.material_override = _mat(Color(0.80, 0.81, 0.78), 0.45, 0.35)
		t.add_child(mi)
		_box(t, Vector3(22, 0.4, 22), Vector3(0, 0.2, 0), Color(0.45, 0.45, 0.42), 0.95)
	_box(r, Vector3(12, 4.0, 8), Vector3(0, 2.3, -15.0), Color(0.82, 0.82, 0.8), 0.7)
	_box(r, Vector3(40, 0.4, 6), Vector3(0, 3.0, 60.0), Color(0.55, 0.55, 0.52), 0.8, 0.3)


# ─────────────────────────── ЗАСЛОН ───────────────────────────

## Текстура сетки: тонкие нити с прозрачностью между ними (одна ячейка на тайл).
func _make_net_texture() -> ImageTexture:
	var s := 48
	var img := Image.create(s, s, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.9, 0.9, 0.86, 0.0))
	var col := Color(0.93, 0.93, 0.89, 1.0)
	for i in s:
		for w in 3:
			img.set_pixel(i, w, col)
			img.set_pixel(w, i, col)
	# без мип-уровней: тонкие нити на альфа-отсечке гибнут на дальних мипах
	# (та же грабля, что с фото-травой), поэтому полотно рисуем смешиванием
	return ImageTexture.create_from_image(img)


func rebuild_barrier() -> void:
	var cfg := scen()
	bar = M.build_barrier(cfg)
	if _bar_root != null:
		_bar_root.queue_free()
	_bar_root = Node3D.new()
	_bar_root.name = "NetDefBarrier"
	add_child(_bar_root)
	var ws := M.wind_state(bar, wind)
	var r: float = float(bar["r_stand"])
	var n: int = int(bar["n_seg"])
	var arc: float = deg_to_rad(float(bar["arc_deg"]))
	var h_top: float = float(ws["h_eff"])
	var h_bot: float = float(bar["h_bot"])
	var tilt: float = deg_to_rad(float(ws["tilt_deg"]))
	# в сцене строим представительный участок: полный круг из 63 секций не нужен и не читается
	var n_show: int = mini(n, 80)
	var step := arc / float(maxi(n, 1))
	var a0 := -step * float(n_show) * 0.5
	if float(bar["arc_deg"]) >= 359.0 and n_show >= n:
		a0 = 0.0                       # замкнутое кольцо строится целиком
	for i in n_show + 1:
		var a := a0 + step * float(i)
		_make_carrier(a, r, h_top, h_bot, tilt)
		if i < n_show and show_net and not bool(ws["down"]):
			_make_panel(a, a + step, r, h_top, h_bot, tilt)


func _carrier_pos(a: float, r: float, h_top: float, tilt: float) -> Vector3:
	# при наклоне привязи носитель сносит по ветру наружу и вниз
	var lean := sin(tilt) * float(bar["h_top"])
	var x := site_pos.x + cos(a) * (r + lean * 0.5)
	var z := site_pos.z + sin(a) * (r + lean * 0.5)
	return Vector3(x, main.height_at(x, z) + h_top, z)


func _make_carrier(a: float, r: float, h_top: float, h_bot: float, tilt: float) -> void:
	var top := _carrier_pos(a, r, h_top, tilt)
	var gx := site_pos.x + cos(a) * r
	var gz := site_pos.z + sin(a) * r
	var ground := Vector3(gx, main.height_at(gx, gz), gz)
	var kind := str(bar["carrier"]["kind"])
	var node := Node3D.new()
	node.position = top
	_bar_root.add_child(node)
	if kind == "aerostat":
		var vol: float = float(bar["carrier"]["vol"])
		var rad: float = pow(vol * 0.75 / PI, 1.0 / 3.0) * 0.8
		var hull := MeshInstance3D.new()
		var sm := SphereMesh.new()
		sm.radius = rad; sm.height = rad * 2.0; sm.radial_segments = 20; sm.rings = 12
		hull.mesh = sm
		hull.scale = Vector3(1.0, 0.85, 1.9)          # вытянут по потоку
		hull.rotation.y = a + PI * 0.5
		hull.material_override = _mat(Color(0.74, 0.75, 0.72), 0.55)
		node.add_child(hull)
		var belly := MeshInstance3D.new()
		var bs := SphereMesh.new()
		bs.radius = rad * 0.98; bs.height = rad * 1.2; bs.radial_segments = 16; bs.rings = 6
		belly.mesh = bs
		belly.scale = Vector3(1.0, 0.5, 1.85)
		belly.position = Vector3(0, -rad * 0.35, 0)
		belly.rotation.y = a + PI * 0.5
		belly.material_override = _mat(Color(0.30, 0.31, 0.30), 0.7)
		node.add_child(belly)
		var lamp := MeshInstance3D.new()
		var ls := SphereMesh.new(); ls.radius = 0.45; ls.height = 0.9
		lamp.mesh = ls
		lamp.position = Vector3(0, -rad * 0.75, 0)
		var lm := _mat(Color(1.0, 0.25, 0.2), 0.3)
		lm.emission_enabled = true; lm.emission = Color(1.0, 0.25, 0.2)
		lm.emission_energy_multiplier = 4.0
		lamp.material_override = lm
		node.add_child(lamp)
		for f in 3:
			var fin := MeshInstance3D.new()
			var bm := BoxMesh.new(); bm.size = Vector3(rad * 0.1, rad * 0.9, rad * 0.9)
			fin.mesh = bm
			var fa := TAU * float(f) / 3.0
			fin.position = Vector3(0, 0, rad * 1.5).rotated(Vector3.UP, a + PI * 0.5)
			fin.position += Vector3(0, cos(fa) * rad * 0.7, 0)
			fin.rotation = Vector3(fa, a + PI * 0.5, 0)
			fin.material_override = _mat(Color(0.60, 0.62, 0.58), 0.6)
			node.add_child(fin)
	elif kind == "multirotor":
		var d: Node3D = _units.glb_unit("fpv7", 2.6, -PI * 0.5, false)
		if d == null:
			var mi := MeshInstance3D.new()
			var bm := BoxMesh.new(); bm.size = Vector3(1.6, 0.4, 1.6)
			mi.mesh = bm; mi.material_override = _mat(Color(0.15, 0.15, 0.17), 0.5)
			d = mi
		node.add_child(d)
	else:
		# мачта: ферма от земли до верхней кромки
		var mast := MeshInstance3D.new()
		var cm := CylinderMesh.new()
		cm.top_radius = 0.25; cm.bottom_radius = 0.7; cm.height = h_top
		cm.radial_segments = 8
		mast.mesh = cm
		mast.position = Vector3(0, -h_top * 0.5, 0)
		mast.material_override = _mat(Color(0.55, 0.55, 0.52), 0.7, 0.4)
		node.add_child(mast)
	# привязной трос до лебёдки
	if kind != "mast":
		_line(_bar_root, top, ground, Color(0.75, 0.75, 0.72), 0.6)
		_box(_bar_root, Vector3(2.2, 1.2, 1.6), ground + Vector3(0, 0.6, 0), Color(0.30, 0.34, 0.28), 0.8)


## Полотно между двумя носителями: провис по параболе, низ притянут к анкерам.
func _make_panel(a0: float, a1: float, r: float, h_top: float, h_bot: float, tilt: float) -> void:
	var p0 := _carrier_pos(a0, r, h_top, tilt)
	var p1 := _carrier_pos(a1, r, h_top, tilt)
	var b0 := Vector3(site_pos.x + cos(a0) * r, 0, site_pos.z + sin(a0) * r)
	var b1 := Vector3(site_pos.x + cos(a1) * r, 0, site_pos.z + sin(a1) * r)
	b0.y = main.height_at(b0.x, b0.z) + h_bot
	b1.y = main.height_at(b1.x, b1.z) + h_bot
	var nu := 8
	var nv := 10
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var sag: float = minf(p0.distance_to(p1) * 0.06, 6.0)
	var verts: Array = []
	for iu in nu + 1:
		var u := float(iu) / float(nu)
		var col: Array = []
		for iv in nv + 1:
			var v := float(iv) / float(nv)
			var top := p0.lerp(p1, u)
			var bot := b0.lerp(b1, u)
			var p := top.lerp(bot, v)
			# провис верхней кромки между носителями + выдув полотна по ветру
			p.y -= sag * sin(PI * u) * (1.0 - v)
			var bow: float = sin(PI * u) * sin(PI * v) * float(bar["r_stand"]) * 0.0
			p += Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5)) * (sin(PI * u) * sin(PI * v) * tan(tilt) * 6.0)
			col.append(p)
		verts.append(col)
	var w_m: float = p0.distance_to(p1)
	var h_m: float = maxf(float(bar["h_top"]) - h_bot, 1.0)
	var cell: float = float(bar["net"]["cell"])
	for iu in nu:
		for iv in nv:
			var a: Vector3 = verts[iu][iv]
			var b: Vector3 = verts[iu + 1][iv]
			var c: Vector3 = verts[iu + 1][iv + 1]
			var d: Vector3 = verts[iu][iv + 1]
			var ua := Vector2(float(iu) / float(nu) * w_m / cell, float(iv) / float(nv) * h_m / cell)
			var ub := Vector2(float(iu + 1) / float(nu) * w_m / cell, float(iv) / float(nv) * h_m / cell)
			var uc := Vector2(float(iu + 1) / float(nu) * w_m / cell, float(iv + 1) / float(nv) * h_m / cell)
			var ud := Vector2(float(iu) / float(nu) * w_m / cell, float(iv + 1) / float(nv) * h_m / cell)
			st.set_uv(ua); st.add_vertex(a)
			st.set_uv(ub); st.add_vertex(b)
			st.set_uv(uc); st.add_vertex(c)
			st.set_uv(ua); st.add_vertex(a)
			st.set_uv(uc); st.add_vertex(c)
			st.set_uv(ud); st.add_vertex(d)
	st.generate_normals()
	var mi := MeshInstance3D.new()
	mi.mesh = st.commit()
	var mat := StandardMaterial3D.new()
	mat.albedo_texture = _net_tex
	mat.albedo_color = Color(1, 1, 1, 1)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mat.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	mat.texture_repeat = true
	mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_PER_PIXEL
	mat.roughness = 0.95
	mat.emission_enabled = true
	mat.emission = Color(0.55, 0.57, 0.55)
	mat.emission_energy_multiplier = 0.25
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_bar_root.add_child(mi)
	# нижние оттяжки к грунтовым анкерам
	for k in 4:
		var u := float(k) / 3.0
		var bot: Vector3 = verts[clampi(int(u * nu), 0, nu)][nv]
		var out := Vector3(cos((a0 + a1) * 0.5), 0, sin((a0 + a1) * 0.5))
		var anch := bot + out * 8.0
		anch.y = main.height_at(anch.x, anch.z)
		_line(_bar_root, bot, anch, Color(0.78, 0.74, 0.60), 0.8)
		_box(_bar_root, Vector3(0.8, 0.5, 0.8), anch + Vector3(0, 0.25, 0), Color(0.35, 0.33, 0.28), 0.9)


func _line(parent: Node3D, a: Vector3, b: Vector3, col: Color, alpha := 1.0) -> MeshInstance3D:
	var im := ImmediateMesh.new()
	im.surface_begin(Mesh.PRIMITIVE_LINES)
	im.surface_add_vertex(a); im.surface_add_vertex(b)
	im.surface_end()
	var mi := MeshInstance3D.new()
	mi.mesh = im
	var mat := StandardMaterial3D.new()
	mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	mat.albedo_color = Color(col.r, col.g, col.b, alpha)
	mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)
	return mi


# ─────────────────────────── УГРОЗЫ ───────────────────────────

func _threat_node(kind: String) -> Node3D:
	var root := Node3D.new()
	match kind:
		"shahed", "shahed_jet", "gerbera":
			var light: bool = kind == "gerbera"
			var col: Color = Color(0.78, 0.70, 0.52) if light else Color(0.16, 0.17, 0.18)
			_box(root, Vector3(3.4, 0.45, 0.45), Vector3.ZERO, col, 0.7)
			_box(root, Vector3(1.5, 0.12, 2.5), Vector3(-0.3, 0.0, 0.0), col, 0.7)
			_box(root, Vector3(0.7, 0.10, 1.2), Vector3(-1.4, 0.0, 0.0), col, 0.7)
			for sz: float in [-1.15, 1.15]:
				var fin := _box(root, Vector3(0.6, 0.55, 0.08), Vector3(-1.45, 0.25, sz), col, 0.7)
				fin.rotation.x = 0.35 * signf(sz)
			if kind == "shahed_jet":
				_cyl(root, 0.22, 0.9, Vector3(-1.9, 0.10, 0.0), Color(0.25, 0.25, 0.27), 0.4, 0.6)
			else:
				var pr := _cyl(root, 0.62, 0.04, Vector3(-1.85, 0.0, 0.0), Color(0.35, 0.33, 0.30), 0.6)
				pr.rotation.z = PI * 0.5
				pr.name = "Prop"
			_box(root, Vector3(0.5, 0.35, 0.35), Vector3(1.65, 0.0, 0.0), Color(0.12, 0.12, 0.13), 0.4)
		"lancet":
			_box(root, Vector3(1.5, 0.22, 0.22), Vector3.ZERO, Color(0.30, 0.33, 0.28), 0.7)
			for pair in 2:
				var xo: float = -0.35 + float(pair) * 0.75
				for k in 2:
					var ang: float = PI * 0.25 + PI * 0.5 * float(k)
					var w := _box(root, Vector3(0.28, 0.05, 1.5), Vector3(xo, 0, 0), Color(0.30, 0.33, 0.28), 0.7)
					w.rotation.x = ang
			_box(root, Vector3(0.3, 0.26, 0.26), Vector3(0.8, 0, 0), Color(0.10, 0.10, 0.12), 0.3)
		"molniya":
			_box(root, Vector3(1.4, 0.22, 0.20), Vector3.ZERO, Color(0.74, 0.66, 0.48), 0.8)
			_box(root, Vector3(0.45, 0.06, 1.8), Vector3(-0.1, 0.10, 0), Color(0.74, 0.66, 0.48), 0.8)
			_box(root, Vector3(0.35, 0.05, 0.7), Vector3(-0.65, 0.10, 0), Color(0.74, 0.66, 0.48), 0.8)
			_box(root, Vector3(0.3, 0.4, 0.05), Vector3(-0.65, 0.3, 0), Color(0.74, 0.66, 0.48), 0.8)
			var pr2 := _cyl(root, 0.32, 0.03, Vector3(-0.85, 0.05, 0), Color(0.3, 0.3, 0.3), 0.6)
			pr2.rotation.z = PI * 0.5
			pr2.name = "Prop"
		_:
			var d: Node3D = _units.glb_unit("fpv7", 0.9, -PI * 0.5, false)
			if d == null:
				_box(root, Vector3(0.35, 0.12, 0.35), Vector3.ZERO, Color(0.12, 0.12, 0.14), 0.5)
			else:
				root.add_child(d)
	return root


## Запустить волну: n изделий выбранного типа с разных азимутов.
func launch_wave(kind := "", n := 1) -> void:
	if kind == "":
		kind = threat_id()
	_wave_kind = kind
	_wave_left = n
	_wave_t = 0.0
	_spawn_one(kind)
	_wave_left -= 1


func _spawn_one(kind: String) -> void:
	var th: Dictionary = M.THREATS[kind]
	var az := _rng.randf_range(0.0, TAU)
	var v: float = maxf(float(th["v"]) + _rng.randfn(0.0, float(th["v_sd"])), 5.0)
	var h: float = maxf(float(th["alt"]) + _rng.randfn(0.0, float(th["alt_sd"])), 20.0)
	var shot := M.shot_of(kind, h, v, str(th["prof"]), az,
		Vector2(_rng.randfn(0.0, 12.0), _rng.randfn(0.0, 12.0)))
	var d0: float = maxf(float(bar["r_stand"]) + 500.0, float(shot["r_dive"]) + 250.0)
	var node := _threat_node(kind)
	var px := site_pos.x + cos(az) * d0
	var pz := site_pos.z + sin(az) * d0
	node.position = Vector3(px, main.height_at(px, pz) + M.shot_height_at(shot, d0), pz)
	add_child(node)
	live.append({
		"kind": kind, "node": node, "shot": shot, "az": az, "v": v,
		"state": "fly", "engaged": false, "res": {}, "t": 0.0,
		"vel": Vector3.ZERO, "spin": Vector3.ZERO, "hang": 0.0
	})


func _process(dt: float) -> void:
	if main == null or bool(main.get("menu_open")):
		return
	if _wave_left > 0:
		_wave_t += dt
		if _wave_t > 2.5:
			_wave_t = 0.0
			_spawn_one(_wave_kind)
			_wave_left -= 1
	for t_v: Variant in live.duplicate():
		var t: Dictionary = t_v
		_step_threat(t, dt)


func _step_threat(t: Dictionary, dt: float) -> void:
	var node: Node3D = t["node"]
	if not is_instance_valid(node):
		live.erase(t); return
	t["t"] = float(t["t"]) + dt
	var prop := node.get_node_or_null("Prop")
	if prop != null:
		prop.rotate_x(dt * 60.0)
	match str(t["state"]):
		"fly": _step_fly(t, dt)
		"decel": _step_decel(t, dt)
		"hang": _step_hang(t, dt)
		"fall": _step_fall(t, dt)
		"leave": _step_leave(t, dt)


func _step_fly(t: Dictionary, dt: float) -> void:
	var node: Node3D = t["node"]
	var shot: Dictionary = t["shot"]
	var to := Vector2(site_pos.x - node.position.x, site_pos.z - node.position.z)
	var d := to.length()
	var dir := to.normalized()
	var v: float = float(t["v"])
	var nx := node.position.x + dir.x * v * dt
	var nz := node.position.z + dir.y * v * dt
	var d2: float = maxf(d - v * dt, 0.0)
	var ny: float = main.height_at(nx, nz) + M.shot_height_at(shot, d2)
	var newp := Vector3(nx, ny, nz)
	_aim(node, newp - node.position)
	node.position = newp
	# пересечение рубежа — здесь модель решает исход
	if not bool(t["engaged"]) and d2 <= float(bar["r_stand"]):
		t["engaged"] = true
		_resolve(t)
		return
	if d2 < 8.0:
		_impact_site(t)


## Исход от модели → поведение в сцене.
func _resolve(t: Dictionary) -> void:
	var res := M.engage(bar, t["shot"], _rng, wind)
	t["res"] = res
	shots += 1
	var oc := str(res["outcome"])
	stats[oc] = int(stats.get(oc, 0)) + 1
	if bool(res["stopped"]):
		stopped += 1
	var dmg: Dictionary = res.get("damage", {})
	if bool(dmg.get("crit", false)):
		site_killed += 1
	var th: Dictionary = M.THREATS[str(t["kind"])]
	log_lines.append({
		"kind": str(th["short"]), "oc": oc, "note": str(res["note"]),
		"ng": float(res["n_g"]), "e": float(res["e_kj"]),
		"crit": bool(dmg.get("crit", false)), "t": 6.0
	})
	if log_lines.size() > 7:
		log_lines.pop_front()
	var node: Node3D = t["node"]
	match oc:
		"caught":
			t["state"] = "decel"
			# реальный ход торможения из силовой схемы модели (полотно + лента тормоза)
			t["stroke"] = maxf(float(res.get("travel", 4.0)), 0.5)
			t["v0"] = float(t["v"])
			t["gone"] = 0.0
			t["dir"] = (Vector3(site_pos.x, node.position.y, site_pos.z) - node.position).normalized()
		"breach", "breach_wreck", "through_cell":
			t["state"] = "fall" if oc == "breach_wreck" else "fly"
			var vr: float = float(res.get("v_res", t["v"]))
			t["v"] = maxf(vr, 4.0)
			if oc == "breach_wreck":
				t["vel"] = (Vector3(site_pos.x, node.position.y, site_pos.z) - node.position).normalized() * vr
				t["spin"] = Vector3(_rng.randf_range(-4, 4), _rng.randf_range(-2, 2), _rng.randf_range(-5, 5))
				if main.fx != null:
					main.fx.drone_hit(node.position)
		"evaded":
			t["state"] = "leave"
		_:
			pass       # утечки: продолжает лететь на объект


func _step_decel(t: Dictionary, dt: float) -> void:
	var node: Node3D = t["node"]
	var s: float = float(t["stroke"])
	var v0: float = float(t["v0"])
	var gone: float = float(t["gone"])
	# равнозамедленное торможение на ходе выборки сети
	var a := v0 * v0 / (2.0 * maxf(s, 0.5))
	var v: float = sqrt(maxf(v0 * v0 - 2.0 * a * gone, 0.0))
	var step := v * dt
	node.position += (t["dir"] as Vector3) * step
	t["gone"] = gone + step
	node.rotate_z(dt * 1.2)
	if v <= 0.6 or gone + step >= s:
		t["state"] = "hang"
		t["hang"] = 0.0
		if main.hud != null:
			main.hud.toast("ЗАТРИМАНО СІТКОЮ", "%s · %.0f g" % [M.THREATS[str(t["kind"])]["short"], t["res"]["n_g"]],
				Color(0.55, 1.0, 0.6))


func _step_hang(t: Dictionary, dt: float) -> void:
	var node: Node3D = t["node"]
	t["hang"] = float(t["hang"]) + dt
	node.rotate_x(sin(float(t["t"]) * 2.0) * dt * 0.4)
	if bool(t["res"]["deton"]) and float(t["hang"]) > 0.35:
		_detonate(t, node.position)
		return
	# без подрыва изделие остаётся в «мешке» полотна: секцию потом спускают лебёдкой,
	# поэтому сцена его просто снимает, не роняя и не взрывая
	if float(t["hang"]) > 8.0:
		_remove(t)


func _step_fall(t: Dictionary, dt: float) -> void:
	var node: Node3D = t["node"]
	var vel: Vector3 = t["vel"]
	vel += Vector3(0, -M.G, 0) * dt
	node.position += vel * dt
	t["vel"] = vel
	var sp: Vector3 = t["spin"]
	node.rotation += sp * dt
	var g: float = main.height_at(node.position.x, node.position.z)
	if node.position.y <= g + 0.6:
		var p := Vector3(node.position.x, g, node.position.z)
		if bool(t["res"].get("deton", false)):
			_detonate(t, p)
		else:
			if main.fx != null:
				main.fx.drone_hit(p)            # удар обломков без подрыва — пыль и искры, не взрыв
			_remove(t)


func _step_leave(t: Dictionary, dt: float) -> void:
	var node: Node3D = t["node"]
	var away := (node.position - site_pos).normalized()
	away.y = 0.05
	node.position += away * float(t["v"]) * dt
	_aim(node, away)
	if node.position.distance_to(site_pos) > float(bar["r_stand"]) + 900.0:
		_remove(t)


func _impact_site(t: Dictionary) -> void:
	var node: Node3D = t["node"]
	var miss: Vector2 = t["shot"]["miss"]
	var p := site_pos + Vector3(miss.x, 2.0, miss.y)
	if not bool(t.get("engaged", false)):
		# заслон обошли по геометрии ещё до рубежа (низкий проход) — фиксируем как утечку
		_resolve(t)
	if bool(t["res"].get("deton", true)):
		_detonate(t, p)
	else:
		_remove(t)


func _detonate(t: Dictionary, p: Vector3) -> void:
	var th: Dictionary = M.THREATS[str(t["kind"])]
	if main.fx != null:
		main.fx.explosion(p, float(th["wh"]) > 10.0)
	var dmg: Dictionary = t["res"].get("damage", {})
	if bool(dmg.get("crit", false)) and main.hud != null:
		main.hud.toast("ОБ'ЄКТ ВИБУВ З ЛАДУ", ", ".join(dmg.get("elements", [])), Color(1.0, 0.45, 0.35), 4.0)
	_remove(t)


func _remove(t: Dictionary) -> void:
	var node: Node3D = t["node"]
	if is_instance_valid(node):
		node.queue_free()
	live.erase(t)


func _aim(node: Node3D, dir: Vector3) -> void:
	if dir.length_squared() < 0.0001:
		return
	var f := dir.normalized()
	var yaw := atan2(-f.z, f.x)
	var pitch := asin(clampf(f.y, -1.0, 1.0))
	node.transform.basis = Basis(Vector3.UP, yaw) * Basis(Vector3.BACK, pitch)


# ─────────────────────────── УПРАВЛЕНИЕ И ВИД ───────────────────────────

func _place_observer() -> void:
	var cam: Camera3D = main.cam
	if cam == null:
		return
	var r: float = float(bar["r_stand"]) + 260.0
	var p := site_pos + Vector3(-r * 0.75, 0, r * 0.65)
	p.y = main.height_at(p.x, p.z) + 130.0
	cam.position = p
	cam.look_at(site_pos + Vector3(0, 60, 0))
	if cam.has_method("zero_velocity"):
		cam.zero_velocity()


func _kc(event: InputEventKey) -> int:
	return event.physical_keycode if event.physical_keycode != 0 else event.keycode


func _unhandled_input(event: InputEvent) -> void:
	if not (event is InputEventKey and event.pressed and not event.echo):
		return
	if bool(main.get("menu_open")):
		return
	match _kc(event):
		KEY_Z:
			launch_wave(threat_id(), 3)
			_toast("ХВИЛЯ: %s ×3" % M.THREATS[threat_id()]["short"], str(M.THREATS[threat_id()]["name"]))
		KEY_O:
			scen_i = (scen_i + 1) % scen_keys.size()
			_r_stand_add = 0.0
			_build_site()
			rebuild_barrier()
			_place_observer()
			_toast("КОНФІГУРАЦІЯ", str(B.SCENARIOS[str(scen_keys[scen_i])]["name"]))
		KEY_U:
			threat_i = (threat_i + 1) % threat_keys.size()
			var th: Dictionary = M.THREATS[threat_id()]
			_toast("ЗАГРОЗА: %s" % th["short"], "%.0f кг · БЧ %.0f кг · %.0f м/с · %s"
				% [th["mass"], th["wh"], th["v"], M.PROFILES[str(th["prof"])]["name"]])
		KEY_K:
			wind = fmod(wind + 3.5, 21.0)
			rebuild_barrier()
			var ws := M.wind_state(bar, wind)
			_toast("ВІТЕР %.0f м/с" % wind, "робоча кромка %.0f м, нахил %.0f°%s"
				% [ws["h_eff"], ws["tilt_deg"], " · ЗАСЛІН ОПУЩЕНО" if ws["down"] else ""])
		KEY_L:
			slow = not slow
			Engine.time_scale = 0.25 if slow else 1.0
			_toast("ЧАС ×%.2f" % Engine.time_scale, "")
		KEY_X:
			show_net = not show_net
			rebuild_barrier()
		KEY_BRACKETLEFT:
			_r_stand_add = maxf(_r_stand_add - 50.0, -100.0)
			rebuild_barrier()
			_toast("РУБІЖ %.0f м" % bar["r_stand"], "")
		KEY_BRACKETRIGHT:
			_r_stand_add = minf(_r_stand_add + 50.0, 400.0)
			rebuild_barrier()
			_toast("РУБІЖ %.0f м" % bar["r_stand"], "")


func _toast(a: String, b: String) -> void:
	if main.hud != null:
		main.hud.toast(a, b, Color(0.75, 0.88, 1.0), 3.0)


func _build_hud() -> void:
	hud = CanvasLayer.new()
	hud.name = "NetDefHUD"
	hud.layer = 6
	var c := Control.new()
	c.set_script(load("res://scripts/netdef_hud.gd"))
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hud.add_child(c)
	add_child(hud)
	c.set("nd", self)

## --netshot — съёмка полигона: общий вид заслона, затем момент перехвата.
func _netshot() -> void:
	main.replaying = true                       # камера строго по расчёту, дрон не сносит
	var cam: Camera3D = main.cam
	var eye := site_pos + Vector3(-(float(bar["r_stand"]) + 340.0) * 0.8, 0, (float(bar["r_stand"]) + 340.0) * 0.55)
	eye.y = main.height_at(eye.x, eye.z) + 185.0
	var look := site_pos + Vector3(0, 70, 0)
	for i in 150:
		await get_tree().process_frame
		cam.global_position = eye
		cam.look_at(look)
	await _shot("netshot_barrier")
	# волна выбранного типа: ждём до момента остановки в сетке
	launch_wave(threat_id(), 6)
	var frames := 0
	var caught := false
	while frames < 6000:
		await get_tree().process_frame
		if live.is_empty() and _wave_left <= 0:
			launch_wave(threat_id(), 4)
		cam.global_position = eye
		cam.look_at(look)
		frames += 1
		for t_v: Variant in live:
			var t: Dictionary = t_v
			if str(t["state"]) in ["decel", "hang"]:
				caught = true
				# подвести камеру к точке контакта
				var np: Vector3 = (t["node"] as Node3D).position
				eye = np + (np - site_pos).normalized() * 90.0 + Vector3(0, 35, 0)
				look = np
				break
		if caught:
			break
	for i in 25:
		await get_tree().process_frame
		cam.global_position = eye
		cam.look_at(look)
	await _shot("netshot_catch")
	get_tree().quit()


func _shot(nm: String) -> void:
	await RenderingServer.frame_post_draw
	var img := main.get_viewport().get_texture().get_image()
	var out := ProjectSettings.globalize_path("res://../%s.png" % nm)
	img.save_png(out)
	print("Screenshot saved: ", out)
