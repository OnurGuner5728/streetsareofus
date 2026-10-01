class_name CitySounds
extends Node3D
## The city's sound, synthesised on the client (no audio files to download):
## a background hum that quietens at night, tram rumble that follows each
## car's speed, the tram bell, footsteps, gulls over the rooftops, sparrows
## in the trees, rain, a soft chime for incoming talk requests, and your
## own heavy breathing when you have run out of breath.
##
## Samples are generated a slice per frame after joining, so building them
## never stalls a phone.

const RATE := 22050
const MAX_TRAM_VOICES := 6
const MAX_CAR_VOICES := 5
const CAR_HEAR := 55.0
const TRAM_HEAR := 70.0
# Tram bell: inharmonic partials of a struck bell (Hz, level, decay per second).
const ENGINE_AMP := [1.0, 0.45, 0.3, 0.22, 0.17, 0.14]
const BELL_F := [1150.0, 2440.0, 3960.0, 5400.0]
const BELL_A := [0.5, 0.25, 0.13, 0.07]
const BELL_D := [3.0, 5.0, 8.0, 11.0]

var client: GameClient
var ready_to_play := false
var _samples := {}  # name -> AudioStreamWAV
var _ambient: AudioStreamPlayer
var _rain: AudioStreamPlayer
var _sea: AudioStreamPlayer
var _steps: AudioStreamPlayer
var _ui: AudioStreamPlayer
var _breath: AudioStreamPlayer
var _one_shots: Array = []  # AudioStreamPlayer3D pool
var _tram_voices := {}  # veh root -> AudioStreamPlayer3D
var _car_voices: Array = []  # {player, id} for the nearest road vehicles
var _next_critter := 0.0
var _step_phase := 0.0
var rain := 0.0  # 0..1, set by the weather
var sea := 0.0  # 0..1, set by WeatherView from distance to shore and wave height
var _rng := RandomNumberGenerator.new()


func setup(game: GameClient) -> void:
	client = game
	_rng.seed = hash(game.display_name)
	_ambient = _player2d(-16.0)
	_rain = _player2d(-80.0)
	_sea = _player2d(-80.0)
	_steps = _player2d(-28.0)
	_ui = _player2d(-8.0)
	_breath = _player2d(-80.0)
	for i in 4:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 12.0
		p.max_distance = 160.0
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_one_shots.append(p)
	for i in MAX_CAR_VOICES:
		var p := AudioStreamPlayer3D.new()
		p.unit_size = 7.0
		p.max_distance = CAR_HEAR
		p.attenuation_model = AudioStreamPlayer3D.ATTENUATION_INVERSE_DISTANCE
		add_child(p)
		_car_voices.append({"player": p, "id": -1})
	_generate()


func _player2d(db: float) -> AudioStreamPlayer:
	var p := AudioStreamPlayer.new()
	p.volume_db = db
	add_child(p)
	return p


# --- public cues -------------------------------------------------------------------

func tram_bell(at: Vector3) -> void:
	_one_shot("bell", at, 0.0, 1.0)


## A prop being kicked or crashing: a thump, or a clang for metal bins.
func knock(at: Vector3, kind: String, strength: float) -> void:
	var sample := "clang" if kind == "bin" else "thump"
	_one_shot(sample, at, linear_to_db(strength) - 2.0, _rng.randf_range(0.9, 1.15) * (1.5 if kind == "ball" else 1.0))


## A car horn from a driver at `at`; buses sound lower.
func horn(at: Vector3, pitch: float, heavy: bool) -> void:
	_one_shot("horn", at, -1.0 if heavy else -3.0, pitch * (0.72 if heavy else 1.0))


## Engine hum for the nearest road vehicles. `near` holds
## [distance, position, speed, kind, id] per vehicle within CAR_HEAR; the engine
## note follows the speed and the sound fades with distance (and is lower, and
## louder, for buses and minibuses).
func traffic_audio(near: Array) -> void:
	if not ready_to_play:
		return
	near.sort_custom(func(a, b): return a[0] < b[0])
	var wanted := {}
	for i in mini(near.size(), MAX_CAR_VOICES):
		wanted[int(near[i][4])] = near[i]
	# Keep voices on the vehicles they already follow, hand the rest out.
	for slot in _car_voices:
		if not wanted.has(int(slot.id)):
			slot.id = -1
	for id in wanted:
		var has := false
		for slot in _car_voices:
			if int(slot.id) == id:
				has = true
		if not has:
			for slot in _car_voices:
				if int(slot.id) == -1:
					slot.id = id
					break
	for slot in _car_voices:
		var p: AudioStreamPlayer3D = slot.player
		if int(slot.id) == -1:
			if p.playing:
				p.stop()
			continue
		var e: Array = wanted[int(slot.id)]
		var speed := float(e[2])
		var kind := int(e[3])
		var big := kind == Traffic.BUS or kind == Traffic.MINIBUS
		p.global_position = e[1]
		p.volume_db = lerpf(-24.0, -9.0, clampf(speed / 9.0, 0.0, 1.0)) + (4.0 if kind == Traffic.BUS else 0.0)
		p.pitch_scale = (0.62 if kind == Traffic.BUS else (0.8 if big else 1.0)) * (0.8 + speed * 0.05)
		if not p.playing:
			p.stream = _samples.engine
			p.play(_rng.randf() * 1.5)


## A ferry's whistle from `at`. It carries for kilometres, so the voice is
## placed at most 24 m away along the same bearing and its level follows the
## real distance instead of the player's inverse-distance falloff.
func ferry_horn(at: Vector3) -> void:
	if client == null or client.camera == null:
		return
	var cam := client.camera.global_position
	var offset := at - cam
	var d := offset.length()
	if d > 1800.0:
		return
	var db := clampf(7.0 - 20.0 * log(maxf(d, 40.0) / 40.0) / log(10.0) * 0.8, -34.0, 7.0)
	_one_shot("ferry_horn", cam + offset.normalized() * minf(d, 24.0), db, 1.0)


func purr(at: Vector3) -> void:
	_one_shot("purr", at, -2.0, _rng.randf_range(0.9, 1.1))


func thunder() -> void:
	if ready_to_play:
		_ui.stream = _samples.thunder
		_ui.volume_db = -4.0
		_ui.pitch_scale = _rng.randf_range(0.8, 1.1)
		_ui.play()


func chime() -> void:
	_ui.volume_db = -8.0
	_ui.pitch_scale = 1.0
	if _samples.has("chime"):
		_ui.stream = _samples.chime
		_ui.play()


## Called every frame with the local player's horizontal speed. A soft
## step under the ambience: about 1.8 steps a second walking, 2.7 running.
func footsteps(speed: float, grounded: bool, delta: float) -> void:
	if not ready_to_play or not grounded or speed < 0.6:
		_step_phase = 0.6  # the first step lands soon after starting
		return
	var running := speed > Protocol.WALK_SPEED + 0.5
	var cadence := 2.7 if running else 1.8
	_step_phase += delta * cadence
	if _step_phase >= 1.0:
		_step_phase -= 1.0
		_steps.stream = _samples.step
		_steps.pitch_scale = _rng.randf_range(0.9, 1.1)
		_steps.volume_db = (-23.0 if running else -28.0) + _rng.randf_range(-1.5, 1.0)
		_steps.play()


## Panting, as loud as `level` (0..1): nothing when you have breath left.
func breathing(level: float) -> void:
	if not ready_to_play or level < 0.02:
		if _breath and _breath.playing:
			_breath.stop()
		return
	if not _breath.playing:
		_breath.stream = _samples.breath
		_breath.play()
	_breath.volume_db = linear_to_db(level) - 13.0
	_breath.pitch_scale = 0.95 + 0.12 * level


func update(night: float, delta: float) -> void:
	if not ready_to_play:
		return
	if not _ambient.playing:
		_ambient.stream = _samples.ambient
		_ambient.play()
	_ambient.volume_db = lerpf(-14.0, -24.0, night)
	if rain > 0.02:
		if not _rain.playing:
			_rain.stream = _samples.rain
			_rain.play()
		_rain.volume_db = linear_to_db(rain) - 6.0
	elif _rain.playing:
		_rain.stop()
	if sea > 0.02:
		if not _sea.playing:
			_sea.stream = _samples.wave
			_sea.play()
		_sea.volume_db = linear_to_db(sea) - 4.0
	elif _sea.playing:
		_sea.stop()
	_update_trams()
	_next_critter -= delta
	if _next_critter <= 0.0:
		_next_critter = _rng.randf_range(9.0, 26.0)
		_critter(night)


# --- trams ---------------------------------------------------------------------------

func _update_trams() -> void:
	if client.fleet == null or client.camera == null:
		return
	var cam := client.camera.global_position
	var near := []
	for veh in client.fleet.vehicle_nodes():
		var root: Node3D = veh.root
		var sections: Array = veh.sections
		if not root.visible or sections.is_empty():
			continue
		var mid: Node3D = sections[sections.size() / 2]
		var d := mid.global_position.distance_to(cam)
		if d < TRAM_HEAR:
			near.append([d, veh, mid])
	near.sort_custom(func(a, b): return a[0] < b[0])
	var keep := {}
	for i in mini(near.size(), MAX_TRAM_VOICES):
		var veh: Dictionary = near[i][1]
		var mid: Node3D = near[i][2]
		var voice: AudioStreamPlayer3D = _tram_voices.get(mid)
		if voice == null:
			voice = AudioStreamPlayer3D.new()
			voice.stream = _samples.rumble
			voice.unit_size = 9.0
			voice.max_distance = TRAM_HEAR
			mid.add_child(voice)
			_tram_voices[mid] = voice
		var st := client.fleet.state_of(int(veh.line), int(veh.vehicle))
		var speed := float(st.get("speed", 0.0))
		voice.volume_db = lerpf(-30.0, -4.0, clampf(speed / 8.0, 0.0, 1.0))
		voice.pitch_scale = 0.8 + speed * 0.05
		if not voice.playing:
			voice.play(_rng.randf() * 1.0)
		keep[mid] = true
	for mid in _tram_voices.keys():
		if not keep.has(mid):
			var voice: AudioStreamPlayer3D = _tram_voices[mid]
			if is_instance_valid(voice):
				voice.stop()


func _critter(night: float) -> void:
	if client.camera == null:
		return
	var cam := client.camera.global_position
	var a := _rng.randf() * TAU
	if night < 0.5 and rain < 0.3:
		if _rng.randf() < 0.55:
			# A gull somewhere over the rooftops.
			_one_shot("gull", cam + Vector3(cos(a) * 45.0, 22.0, sin(a) * 45.0), -6.0, _rng.randf_range(0.9, 1.1))
		else:
			_one_shot("sparrow", cam + Vector3(cos(a) * 12.0, 5.0, sin(a) * 12.0), -10.0, _rng.randf_range(0.9, 1.2))
	elif _rng.randf() < 0.3:
		_one_shot("gull", cam + Vector3(cos(a) * 80.0, 30.0, sin(a) * 80.0), -14.0, 0.9)


func _one_shot(sample: String, at: Vector3, db: float, pitch: float) -> void:
	if not ready_to_play or not _samples.has(sample):
		return
	for p: AudioStreamPlayer3D in _one_shots:
		if not p.playing:
			p.stream = _samples[sample]
			p.global_position = at
			p.volume_db = db
			p.pitch_scale = pitch
			p.play()
			return


# --- synthesis -----------------------------------------------------------------------

func _generate() -> void:
	var specs := [["step", 0.12], ["thump", 0.25], ["clang", 0.7], ["chime", 0.7], ["bell", 1.4], ["sparrow", 0.5], ["gull", 1.1],
		["rumble", 2.0], ["engine", 2.0], ["horn", 0.5], ["ambient", 6.0], ["rain", 3.0], ["thunder", 3.5], ["purr", 1.8], ["breath", 1.9], ["wave", 7.0], ["ferry_horn", 2.6]]
	for spec in specs:
		var data := PackedFloat32Array()
		data.resize(int(float(spec[1]) * RATE))
		await _fill(str(spec[0]), data)
		var loop: bool = spec[0] in ["rumble", "engine", "ambient", "rain", "breath", "wave"]
		_samples[spec[0]] = _to_wav(data, loop)
	ready_to_play = true


## Writes one sound into `out`, yielding to the frame loop now and then.
func _fill(sound: String, out: PackedFloat32Array) -> void:
	var n := out.size()
	var lp := 0.0
	var lp2 := 0.0
	var phase := 0.0
	for i in n:
		var t := float(i) / RATE
		var s := 0.0
		match sound:
			"step":
				# A dull heel thud with a little scuff of grit on top.
				lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.06
				lp2 += (lp - lp2) * 0.3
				s = sin(TAU * 75.0 * t) * exp(-t * 55.0) * 0.6 + lp2 * exp(-t * 30.0) * 1.1
			"thump":
				lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.08
				s = (sin(TAU * 95.0 * t) * 0.7 + lp * 1.5) * exp(-t * 22.0)
			"clang":
				s = (sin(TAU * 310.0 * t) * 0.4 + sin(TAU * 787.0 * t) * 0.3 + sin(TAU * 1243.0 * t) * 0.2) * exp(-t * 7.0) 					+ _rng.randf_range(-1.0, 1.0) * 0.3 * exp(-t * 40.0)
			"chime":
				s = (sin(TAU * 659.0 * t) * exp(-t * 5.0) + 0.6 * sin(TAU * 988.0 * maxf(t - 0.14, 0.0)) * exp(-maxf(t - 0.14, 0.0) * 5.0) * float(t > 0.14)) * 0.35
			"bell":
				for strike: float in [0.0, 0.3]:
					var u := t - strike
					if u >= 0.0:
						for k in 4:
							s += sin(TAU * float(BELL_F[k]) * u) * float(BELL_A[k]) * exp(-u * float(BELL_D[k]))
			"sparrow":
				for chirp in 3:
					var u := t - chirp * 0.14
					if u >= 0.0 and u < 0.07:
						s += sin(TAU * (3600.0 + 28000.0 * u) * u) * sin(PI * u / 0.07) * 0.4
			"gull":
				for call in 3:
					var u := t - call * 0.34
					if u >= 0.0 and u < 0.3:
						var f := 1500.0 - 1800.0 * u + 60.0 * sin(TAU * 30.0 * u)
						phase += TAU * f / RATE
						s += tanh(3.0 * sin(phase)) * sin(PI * u / 0.3) * 0.22
			"rumble":
				lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.03
				lp2 += (lp - lp2) * 0.1
				var clack := exp(-fmod(t, 0.5) * 60.0) * 0.5
				s = lp2 * 2.6 + sin(TAU * 48.0 * t) * 0.18 + clack * lp * 3.0
			"engine":
				# A low firing note (38 Hz, whole cycles per loop) with its
				# harmonics, a lumpy idle and a breath of intake noise.
				var f0 := 38.0
				var lump := 0.8 + 0.2 * sin(TAU * f0 * 0.5 * t)
				for k in 6:
					s += sin(TAU * f0 * (k + 1) * t + k * 0.9) * float(ENGINE_AMP[k])
				lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.05
				s = s * lump * 0.3 + lp * 0.5
			"horn":
				var env := minf(1.0, t / 0.02) * minf(1.0, (0.5 - t) / 0.06)
				s = (tanh(2.5 * sin(TAU * 415.0 * t)) + tanh(2.5 * sin(TAU * 523.0 * t))) * 0.16 * env
			"ferry_horn":
				# A ship's whistle: a deep fifth (110 and 165 Hz) with a slow swell,
				# a touch of hull rumble and a long fade; two blasts one behind the other.
				var blast := t - 1.25 if t > 1.25 else t
				var dur := 1.25 if t > 1.25 else 1.2
				var env := minf(1.0, blast / 0.09) * minf(1.0, maxf(0.0, (dur - blast)) / 0.4)
				var wob := 1.0 + 0.004 * sin(TAU * 5.0 * t)
				s = (tanh(1.8 * sin(TAU * 110.0 * wob * t)) * 0.55 + tanh(1.8 * sin(TAU * 165.0 * wob * t)) * 0.4 + sin(TAU * 220.0 * t) * 0.15) * 0.3 * env
			"ambient":
				lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.012
				lp2 += (_rng.randf_range(-1.0, 1.0) - lp2) * 0.2
				s = lp * 3.2 + lp2 * 0.05 * (0.6 + 0.4 * sin(TAU * 0.3 * t))
			"purr":
				# A soft rumble pulsing with each breath.
				lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.05
				var breath := 0.5 + 0.5 * sin(TAU * 1.1 * t)
				s = lp * 2.2 * (0.6 + 0.4 * sin(TAU * 26.0 * t)) * breath * minf(1.0, t * 4.0) * minf(1.0, (1.8 - t) * 3.0)
			"thunder":
				# A crack, then a long rolling rumble.
				lp += (_rng.randf_range(-1.0, 1.0) - lp) * 0.02
				lp2 += (lp - lp2) * 0.05
				var roll := 1.0 + 0.6 * sin(TAU * 1.3 * t) * sin(TAU * 0.4 * t)
				s = lp2 * 9.0 * roll * exp(-t * 0.9) + _rng.randf_range(-1.0, 1.0) * 0.5 * exp(-t * 18.0)
			"breath":
				# Two quick breaths a cycle: a hissing gasp in, a longer huff out
				# through the mouth (noise shaped by a breathy formant).
				var u := fmod(t, 0.9)
				var env := 0.0
				var bright := 0.0
				if u < 0.32:
					env = sin(PI * u / 0.32) * 0.55
					bright = 0.5
				elif u > 0.36 and u < 0.84:
					env = pow(sin(PI * (u - 0.36) / 0.48), 0.7)
					bright = 0.25
				var white := _rng.randf_range(-1.0, 1.0)
				lp += (white - lp) * bright
				lp2 += (lp - lp2) * 0.35
				s = (lp - lp2 * 0.6) * env * 1.4
			"rain":
				var white := _rng.randf_range(-1.0, 1.0)
				lp += (white - lp) * 0.6
				s = (white - lp) * 0.5 + (0.3 if _rng.randf() < 0.0015 else 0.0)
			"wave":
				# Surf lapping the shore: filtered noise, swelling and receding.
				var white2 := _rng.randf_range(-1.0, 1.0)
				lp += (white2 - lp) * 0.08
				lp2 += (lp - lp2) * 0.012
				var swell := 0.5 + 0.5 * sin(TAU * t / 6.5)
				s = (lp - lp2) * (0.5 + 0.9 * swell)
		out[i] = s
		if i % 12000 == 11999:
			await get_tree().process_frame
	if sound in ["rumble", "engine", "ambient", "rain", "breath", "wave"]:
		_crossfade_loop(out)


## Blends the tail into the head so the loop point does not click.
static func _crossfade_loop(data: PackedFloat32Array) -> void:
	var fade := mini(RATE / 10, data.size() / 4)
	var n := data.size()
	for i in fade:
		var w := float(i) / fade
		data[i] = data[i] * w + data[n - fade + i] * (1.0 - w)
	data.resize(n - fade)


static func _to_wav(data: PackedFloat32Array, loop: bool) -> AudioStreamWAV:
	var bytes := PackedByteArray()
	bytes.resize(data.size() * 2)
	for i in data.size():
		bytes.encode_s16(i * 2, clampi(roundi(data[i] * 32767.0), -32767, 32767))
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.mix_rate = RATE
	wav.stereo = false
	wav.data = bytes
	if loop:
		wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
		wav.loop_begin = 0
		wav.loop_end = data.size()
	return wav
