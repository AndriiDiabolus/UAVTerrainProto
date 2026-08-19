extends Node3D
## Туман по долинам: объёмные пятна (FogVolume + 3D-шум) вдоль рек и низин вокруг камеры —
## где-то гуще, где-то прозрачно; сползают по ветру и РАССЕИВАЮТСЯ со временем (утренний туман
## на солнце уходит за ~10 мин; в пасмурную/дождливую погоду держится). Вместо однородного слоя.

var main: Node3D
var enabled := false
var strength := 0.0            # 0..1 текущая плотность (с распадом)
var persistent := false        # не рассеивается (пасмурно/дождь)
var _cands: Array[Vector3] = []   # точки-кандидаты (дно долин: вдоль рек), мировые
var _vols: Array[FogVolume] = []
var _tex: NoiseTexture3D
var _acc := 0.0
var _drift := Vector3.ZERO
var _rng := RandomNumberGenerator.new()
const N_VOL := 40
const RANGE := 2600.0


func setup(m: Node3D) -> void:
	main = m
	_rng.seed = 4242
	# кандидаты: точки вдоль рек/ручьёв (это и есть дно долин) каждые ~250 м + низины сетки
	var f := FileAccess.get_file_as_string(main.asset_path("water.json"))
	var seen := {}
	if not f.is_empty():
		for w: Dictionary in JSON.parse_string(f)["w"]:
			var pts: Array = w["p"]
			var acc := 0.0
			for i in range(1, pts.size()):
				var a := Vector2(pts[i - 1][0], pts[i - 1][1]); var b := Vector2(pts[i][0], pts[i][1])
				acc += a.distance_to(b)
				if acc >= 250.0:
					acc = 0.0
					var key := Vector2i(int(b.x / 220.0), int(b.y / 220.0))
					if seen.has(key): continue
					seen[key] = true
					_cands.append(Vector3(b.x, main.height_at(b.x, b.y), b.y))
	# 3D-шум плотности — общий для всех объёмов
	_tex = NoiseTexture3D.new()
	_tex.width = 48; _tex.height = 32; _tex.depth = 48
	_tex.seamless = true
	var n := FastNoiseLite.new()
	n.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	n.frequency = 0.06
	n.fractal_octaves = 3
	_tex.noise = n
	for i in N_VOL:
		var v := FogVolume.new()
		v.shape = RenderingServer.FOG_VOLUME_SHAPE_BOX
		var fm := FogMaterial.new()
		fm.density = 0.0
		fm.albedo = Color(0.86, 0.89, 0.93)
		fm.height_falloff = 1.2
		fm.edge_fade = 0.35
		fm.density_texture = _tex
		v.material = fm
		v.visible = false
		add_child(v)
		_vols.append(v)
	print("ValleyFog: точек долин %d" % _cands.size())


## Включить/выключить. reset — начать с полной плотности.
func set_enabled(on: bool, reset: bool = true, persist: bool = false, s0: float = 1.0) -> void:
	enabled = on
	persistent = persist
	if on and reset:
		strength = s0
	if not on:
		strength = 0.0
	for v in _vols:
		v.visible = on
	if main.environment != null:
		main.environment.volumetric_fog_enabled = on or int(main.quality) == 2
		if on:
			main.environment.volumetric_fog_length = 3500.0
			main.environment.volumetric_fog_detail_spread = 2.0
			main.environment.volumetric_fog_temporal_reprojection_amount = 0.9


func _process(dt: float) -> void:
	if not enabled or main == null or main.cam == null:
		return
	# распад: на солнце туман уходит (тау ~7 мин), в пасмурную держится
	if not persistent:
		strength = maxf(0.0, strength - dt / 420.0)
		if strength <= 0.0:
			set_enabled(false)
			return
	# дрейф по ветру
	if main.weather != null:
		var w: Vector3 = main.weather.wind_vec()
		_drift += w * dt * 0.25
		if _drift.length() > 160.0:
			_drift = Vector3.ZERO
	_acc += dt
	if _acc < 0.5:
		return
	_acc = 0.0
	var cp: Vector3 = main.cam.global_position
	# ближайшие кандидаты
	var near: Array = []
	for c in _cands:
		var d := Vector2(c.x - cp.x, c.z - cp.z).length()
		if d < RANGE:
			near.append([d, c])
	near.sort_custom(func(a, b): return a[0] < b[0])
	for i in N_VOL:
		var v := _vols[i]
		if i >= near.size():
			v.visible = false
			continue
		var c: Vector3 = near[i][1]
		# детерминированная вариация по точке: размер, плотность, высота слоя
		var h := hash(Vector2i(int(c.x), int(c.z)))
		var r1 := float(h & 1023) / 1023.0
		var r2 := float((h >> 10) & 1023) / 1023.0
		var r3 := float((h >> 20) & 1023) / 1023.0
		var sx := 360.0 + r1 * 360.0
		var sz := 360.0 + r2 * 360.0
		var sy := 40.0 + r3 * 50.0 * strength + 15.0
		v.size = Vector3(sx, sy, sz)
		v.position = Vector3(c.x + _drift.x, c.y + sy * 0.35, c.z + _drift.z)
		v.visible = true
		var fm := v.material as FogMaterial
		# плотность: пятна разной густоты (0.3–1.0), всё × strength; ниже — гуще
		fm.density = (0.025 + 0.06 * r3) * (0.3 + 0.7 * r1) * strength
