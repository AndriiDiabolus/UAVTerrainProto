extends Node3D
## РЭБ: зоны подавления радиоканала. Внутри купола сигнал (RSSI) падает тем сильнее, чем ближе к мачте;
## при слабом сигнале управление деградирует (см. flycam.link_quality), при потере — failsafe.
##
## Постановщики ставятся детерминированно от сида: 3 мачты в 1.2–2.5 км от точки старта, радиус 500–800 м.
## Купол показан полупрозрачной сферой (курсант должен видеть, чего избегать; --hidejam — скрыть купола,
## --nojam — отключить РЭБ совсем).

var main: Node3D
var jammers: Array = []        # [{pos: Vector3, r: float, node: Node3D}]
var enabled := true
var _show := true


func setup(m: Node3D) -> void:
	main = m
	var args := OS.get_cmdline_user_args()
	enabled = not ("--nojam" in args)
	_show = not ("--hidejam" in args)
	if not enabled:
		return
	var home: Vector3 = main._home_pos
	var rng := RandomNumberGenerator.new()
	rng.seed = hash("ew") + hash(main.get("seed_value") if main.get("seed_value") != null else 1)
	for i in 3:
		var a := rng.randf_range(0.0, TAU)
		var d := rng.randf_range(1200.0, 2500.0)
		var x := home.x + cos(a) * d; var z := home.z + sin(a) * d
		var g: float = main.height_at(x, z)
		var r := rng.randf_range(500.0, 800.0)
		jammers.append({"pos": Vector3(x, g, z), "r": r, "node": _make_visual(Vector3(x, g, z), r)})
	print("РЭБ: %d постановщиков" % jammers.size())


func _make_visual(p: Vector3, r: float) -> Node3D:
	var root := Node3D.new()
	root.position = p
	# мачта
	var mast := MeshInstance3D.new()
	var cyl := CylinderMesh.new(); cyl.top_radius = 0.25; cyl.bottom_radius = 0.4; cyl.height = 14.0
	mast.mesh = cyl; mast.position = Vector3(0, 7, 0)
	var mm := StandardMaterial3D.new(); mm.albedo_color = Color(0.25, 0.25, 0.28)
	mast.material_override = mm
	root.add_child(mast)
	# антенна-шар (красный, светится)
	var ball := MeshInstance3D.new()
	var sph := SphereMesh.new(); sph.radius = 1.2; sph.height = 2.4
	ball.mesh = sph; ball.position = Vector3(0, 15, 0)
	var bm := StandardMaterial3D.new()
	bm.albedo_color = Color(1.0, 0.2, 0.15); bm.emission_enabled = true
	bm.emission = Color(1.0, 0.2, 0.15); bm.emission_energy_multiplier = 3.0
	ball.material_override = bm
	root.add_child(ball)
	# купол
	if _show:
		var dome := MeshInstance3D.new()
		var ds := SphereMesh.new(); ds.radius = r; ds.height = r * 2.0
		ds.radial_segments = 32; ds.rings = 16
		dome.mesh = ds
		var dm := StandardMaterial3D.new()
		dm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
		dm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		dm.albedo_color = Color(1.0, 0.25, 0.2, 0.035)
		dm.cull_mode = BaseMaterial3D.CULL_DISABLED
		dm.no_depth_test = false
		dome.material_override = dm
		root.add_child(dome)
	add_child(root)
	return root


## Множитель качества канала в точке: 1 — вне зон, →0.05 у самой мачты.
func jam_factor(p: Vector3) -> float:
	if not enabled or jammers.is_empty():
		return 1.0
	var f := 1.0
	for j: Dictionary in jammers:
		var d: float = Vector2(p.x - j.pos.x, p.z - j.pos.z).length()
		var r: float = j.r
		if d < r:
			# внутри: плавно от 1 на границе до 0.05 у центра (высота помогает мало — купол)
			var t := d / r
			f = minf(f, 0.05 + 0.95 * t * t)
	return f


## Ближайшая зона (для HUD): расстояние до границы (<0 = внутри) и подавление.
func nearest_info(p: Vector3) -> Dictionary:
	if not enabled or jammers.is_empty():
		return {}
	var best: Dictionary = {}
	var best_d := 1e9
	for j: Dictionary in jammers:
		var d: float = Vector2(p.x - j.pos.x, p.z - j.pos.z).length() - j.r
		if d < best_d:
			best_d = d; best = j
	return {"edge": best_d, "jam": 1.0 - jam_factor(p)}
