extends Node3D
## Процедурный звук без аудиофайлов:
##  • моторы дрона (тон/громкость от газа) + свист ветра — real-time синтез;
##  • выстрел (2D) и позиционные взрывы (3D) — заранее синтезированные буферы.

const RATE := 22050

var main: Node3D
var gen_player: AudioStreamPlayer
var playback: AudioStreamGeneratorPlayback

var _thr := 0.2         # сглаженный «газ» 0..1
var _windlvl := 0.0     # сглаженный уровень ветра/скорости

# фазы осцилляторов моторов (4 слегка расстроенных винта + вой)
var _ph := [0.0, 0.0, 0.0, 0.0]
var _phw := 0.0
var _wind_lp := 0.0

var _booms: Array[AudioStreamPlayer3D] = []
var _boom_i := 0
var shot_stream: AudioStreamWAV
var _rainlvl := 0.0     # сглаженный уровень шума дождя
var _rain_lp1 := 0.0
var _rain_lp2 := 0.0
var _thunder: AudioStreamWAV
var _amb_t := 0.0       # таймер редких одиночных звуков (собаки/птицы)
var _dog: AudioStreamWAV
var _bird: AudioStreamWAV
var _amb_players: Array[AudioStreamPlayer3D] = []
var _amb_i := 0


func setup(m: Node3D) -> void:
	main = m
	# непрерывный синтез (моторы + ветер)
	gen_player = AudioStreamPlayer.new()
	var gen := AudioStreamGenerator.new()
	gen.mix_rate = RATE
	gen.buffer_length = 0.12
	gen_player.stream = gen
	gen_player.bus = "Master"
	add_child(gen_player)
	gen_player.play()
	playback = gen_player.get_stream_playback()

	# пул позиционных взрывов
	var boom_stream := _make_explosion()
	for i in 6:
		var p := AudioStreamPlayer3D.new()
		p.stream = boom_stream
		p.unit_size = 260.0
		p.max_distance = 7000.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		p.volume_db = 6.0
		add_child(p)
		_booms.append(p)

	shot_stream = _make_shot()
	var sp := AudioStreamPlayer.new()
	sp.name = "Shot"
	sp.stream = shot_stream
	sp.volume_db = -4.0
	add_child(sp)

	_thunder = _make_thunder()
	_dog = _make_dog()
	_bird = _make_bird()
	for i in 4:
		var ap := AudioStreamPlayer3D.new()
		ap.unit_size = 60.0
		ap.max_distance = 1200.0
		ap.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(ap)
		_amb_players.append(ap)


func _process(dt: float) -> void:
	if playback == null or main == null or main.cam == null:
		return
	# цель газа/ветра
	var v: float = main.cam.velocity.length() if main.cam.get("velocity") != null else 0.0
	var thr_t := clampf(0.18 + v / 160.0, 0.0, 1.0)
	if main.cam.get("throttle") != null:          # лётная модель отдаёт реальный газ
		thr_t = clampf(0.1 + float(main.cam.throttle) * 0.9, 0.0, 1.0)
	var windf := 0.0
	if main.get("weather") != null:
		windf = main.weather.wind_vec().length()
	var wind_t := clampf(v / 150.0 * 0.55 + windf / 12.0 * 0.6, 0.0, 1.0)
	_thr = lerpf(_thr, thr_t, clampf(dt * 3.0, 0.0, 1.0))
	_windlvl = lerpf(_windlvl, wind_t, clampf(dt * 2.0, 0.0, 1.0))
	# дождь: шум тем громче, чем ниже дрон (у земли слышно капли по листве)
	var rain_t := 0.0
	if main.get("weather") != null and main.weather.raining():
		var cp0: Vector3 = main.cam.global_position
		var agl0: float = cp0.y - main.height_at(cp0.x, cp0.z)
		rain_t = 0.65 * clampf(1.0 - agl0 / 400.0, 0.25, 1.0)
	_rainlvl = lerpf(_rainlvl, rain_t, clampf(dt * 0.8, 0.0, 1.0))
	_ambient_oneshots(dt)
	_fill()


## Редкие одиночные звуки среды: собаки у села (низко над застройкой), птицы у леса днём.
func _ambient_oneshots(dt: float) -> void:
	_amb_t -= dt
	if _amb_t > 0.0:
		return
	_amb_t = randf_range(6.0, 14.0)
	var cp: Vector3 = main.cam.global_position
	var agl: float = cp.y - main.height_at(cp.x, cp.z)
	if agl > 260.0:
		return
	var night: bool = main.get("weather") != null and int(main.weather.idx) == 4
	# точка источника — в стороне от дрона
	var ang := randf() * TAU
	var d := randf_range(60.0, 260.0)
	var src := Vector3(cp.x + cos(ang) * d, 0.0, cp.z + sin(ang) * d)
	src.y = main.height_at(src.x, src.z) + 1.5
	var near_bld: bool = main.collision != null and main.collision.in_building(src.x, src.z, 60.0)
	var p := _amb_players[_amb_i]
	_amb_i = (_amb_i + 1) % _amb_players.size()
	if near_bld and randf() < 0.6:
		p.stream = _dog
		p.volume_db = -6.0
	elif not night and randf() < 0.5:
		p.stream = _bird
		p.volume_db = -10.0
	else:
		return
	p.global_position = src
	p.play()


## Гром с задержкой (звук идёт от вспышки) — вызывает weather при молнии.
func thunder() -> void:
	var delay := randf_range(0.6, 3.5)
	get_tree().create_timer(delay).timeout.connect(func() -> void:
		var p := AudioStreamPlayer.new()
		p.stream = _thunder
		p.volume_db = lerpf(-2.0, -14.0, delay / 3.5)   # дальняя молния — тише
		add_child(p)
		p.play()
		p.finished.connect(p.queue_free))


func _fill() -> void:
	var n := playback.get_frames_available()
	if n <= 0:
		return
	var base := 46.0 + _thr * 74.0                 # осн. частота винтов, Гц
	var detune := [1.0, 1.006, 0.993, 1.012]
	var inv := 1.0 / RATE
	var vol := 0.12 + _thr * 0.5
	var buf := PackedVector2Array()
	buf.resize(n)
	for i in n:
		var s := 0.0
		for k in 4:
			_ph[k] = fposmod(_ph[k] + base * float(detune[k]) * inv, 1.0)
			s += sin(_ph[k] * TAU) * 0.11
		# высокий вой (4-я гармоника), громче на газу
		_phw = fposmod(_phw + base * 4.0 * inv, 1.0)
		s += sin(_phw * TAU) * 0.05 * _thr
		# широкополосный шум моторов
		s += (randf() * 2.0 - 1.0) * 0.05 * (0.4 + _thr)
		s *= vol
		# свист ветра — сглаженный шум
		_wind_lp += ((randf() * 2.0 - 1.0) - _wind_lp) * 0.06
		s += _wind_lp * _windlvl * 0.5
		# шум дождя: двухкаскадный НЧ-фильтр белого шума + редкие «капли»
		if _rainlvl > 0.005:
			_rain_lp1 += ((randf() * 2.0 - 1.0) - _rain_lp1) * 0.35
			_rain_lp2 += (_rain_lp1 - _rain_lp2) * 0.4
			var drops := 0.0
			if randf() < 0.004:
				drops = (randf() * 2.0 - 1.0) * 0.8
			s += (_rain_lp2 * 0.55 + drops) * _rainlvl
		s = clampf(s, -1.0, 1.0)
		buf[i] = Vector2(s, s)
	playback.push_buffer(buf)


func shot() -> void:
	var sp := get_node_or_null("Shot")
	if sp:
		sp.play()


func boom(pos: Vector3) -> void:
	if _booms.is_empty():
		return
	var p := _booms[_boom_i]
	_boom_i = (_boom_i + 1) % _booms.size()
	p.global_position = pos
	p.play()
	# эхо от склонов: 1–2 тихих повтора с задержкой
	for k in 2:
		var dl := 0.7 + k * 0.8 + randf() * 0.3
		get_tree().create_timer(dl).timeout.connect(func() -> void:
			if _booms.is_empty(): return
			var e := _booms[_boom_i]
			_boom_i = (_boom_i + 1) % _booms.size()
			e.global_position = pos + Vector3(randf_range(-300, 300), 60, randf_range(-300, 300))
			e.volume_db = -10.0 - k * 7.0
			e.play()
			get_tree().create_timer(1.4).timeout.connect(func() -> void:
				if is_instance_valid(e): e.volume_db = 6.0))


## Взрыв: рокот (нисходящий свип) + затухающий шумовой всплеск, ~1.3 с.
func _make_explosion() -> AudioStreamWAV:
	var dur := 1.3
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var lp := 0.0
	for i in n:
		var t := i / float(RATE)
		var env := exp(-t * 3.2)
		var rumble := sin(TAU * (120.0 - 78.0 * t) * t) * exp(-t * 1.8)
		var crack := randf() * 2.0 - 1.0
		lp += (crack - lp) * 0.32
		var s: float = clampf((lp * 0.85 + rumble * 0.6) * env, -1.0, 1.0)
		data.encode_s16(i * 2, int(s * 32767.0))
	return _wav(data)


## Выстрел: короткий «тумп» + щелчок, ~0.14 с.
func _make_shot() -> AudioStreamWAV:
	var dur := 0.14
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := i / float(RATE)
		var env := exp(-t * 34.0)
		var s: float = clampf(((randf() * 2.0 - 1.0) * 0.7 + sin(TAU * 190.0 * t) * 0.5) * env, -1.0, 1.0)
		data.encode_s16(i * 2, int(s * 32767.0))
	return _wav(data)


## Гром: длинный НЧ-рокот с двумя перекатами, ~3.5 с.
func _make_thunder() -> AudioStreamWAV:
	var dur := 3.5
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	var lp := 0.0; var lp2 := 0.0
	for i in n:
		var t := i / float(RATE)
		var env := exp(-t * 1.1) + 0.55 * exp(-absf(t - 1.4) * 2.4) + 0.3 * exp(-absf(t - 2.4) * 3.0)
		var nz := randf() * 2.0 - 1.0
		lp += (nz - lp) * 0.06
		lp2 += (lp - lp2) * 0.08
		var s: float = clampf(lp2 * 3.2 * env, -1.0, 1.0)
		data.encode_s16(i * 2, int(s * 32767.0))
	return _wav(data)


## Собака: два коротких «гав» — импульсы шума через резонансный тон.
func _make_dog() -> AudioStreamWAV:
	var dur := 0.9
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := i / float(RATE)
		var s := 0.0
		for t0 in [0.05, 0.45]:
			var lt: float = t - float(t0)
			if lt >= 0.0 and lt < 0.22:
				var env := exp(-lt * 26.0) * sin(minf(lt * 60.0, PI))
				s += (sin(TAU * (240.0 - 120.0 * lt) * lt) * 0.8 + (randf() * 2.0 - 1.0) * 0.4) * env
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


## Птица: 3 коротких свип-свиста.
func _make_bird() -> AudioStreamWAV:
	var dur := 1.1
	var n := int(RATE * dur)
	var data := PackedByteArray()
	data.resize(n * 2)
	for i in n:
		var t := i / float(RATE)
		var s := 0.0
		for t0 in [0.05, 0.35, 0.7]:
			var lt: float = t - float(t0)
			if lt >= 0.0 and lt < 0.16:
				var f := 2600.0 + 1400.0 * sin(lt * 40.0)
				s += sin(TAU * f * lt) * exp(-lt * 20.0) * 0.5
		data.encode_s16(i * 2, int(clampf(s, -1.0, 1.0) * 32767.0))
	return _wav(data)


func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w
