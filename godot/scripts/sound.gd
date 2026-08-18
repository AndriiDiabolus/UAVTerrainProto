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
	_fill()


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


func _wav(data: PackedByteArray) -> AudioStreamWAV:
	var w := AudioStreamWAV.new()
	w.format = AudioStreamWAV.FORMAT_16_BITS
	w.mix_rate = RATE
	w.stereo = false
	w.data = data
	return w
