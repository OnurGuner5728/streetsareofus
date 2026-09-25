class_name GameClient
extends Node3D
## A connected player (or bot). Predicts its own movement with the shared
## PlayerMotor, reconciles against server snapshots, and renders everyone
## else interpolated in the past.

signal finished(message: String)

const CONNECT_TIMEOUT := 8.0
const MAX_PENDING_INPUTS := 90
const SNAP_CORRECTION_ABOVE := 3.0
const CORRECTION_DECAY := 10.0
const MAX_TICKS_PER_FRAME := 2

const NOTICES := {
	"too_far": "Konuşma isteği için daha yakına gel (4 m).",
	"cooldown": "Biraz bekle; aynı kişiye hemen tekrar istek gönderemezsin.",
	"request_pending": "Zaten yanıt bekleyen bir isteğin var.",
	"already_talking": "Zaten sohbettesiniz.",
	"you_blocked": "Bu kişiyi engelledin.",
	"not_in_conversation": "Mesaj için önce bir konuşma isteğinin kabul edilmesi gerekir.",
	"rate_limited": "Çok hızlı; biraz yavaşla.",
	"blocked": "Engellendi. Artık birbirinizi görmeyeceksiniz. Geri almak için: Menü → Engellenenler.",
	"unblocked": "%s artık engelli değil; birbirinizi yeniden görebilirsiniz.",
	"reported": "Şikayet alındı. Olay numarası: %s",
	"tram_not_boardable": "Bu tramvaya şu an binilemez: durakta değil ya da bölgeden çıkıyor.",
	"too_far_tram": "Tramvayın kapısına biraz daha yaklaş.",
	"tram_full": "Tramvay dolu, bir sonrakini bekle.",
}
const REJECTS := {
	"protocol_mismatch": "Sürüm uyuşmuyor; istemciyi güncelle.",
	"bad_name": "Geçersiz isim: 3-20 karakter; harf, rakam, boşluk, _ . - kullanılabilir.",
	"auth_failed": "Kimlik doğrulanamadı.",
	"already_connected": "Bu hesap zaten bağlı.",
}
const REPORT_KEYS := {KEY_1: "harassment", KEY_2: "hate", KEY_3: "spam", KEY_4: "impersonation", KEY_5: "other"}

var options := {}
var zone: ZoneData
var my_id := 0
var display_name := ""
var avatar := {}
var joined := false
var body: CharacterBody3D
var camera: Camera3D
var hud: GameHud
var touch: TouchControls
var bot: BotBrain
var transit: TransitNetwork
var fleet: TramFleet
var navigator: Navigator
var city_map: CityMap
var sky: SkyController
var sounds: CitySounds
var props_view: PropView
var weather_view: WeatherView
var crowd_view: CrowdView
var critters: Critters
var _boards: Array = []
var _board_timer := 0.0
var _bob_phase := 0.0
var riding := {}  # {line, vehicle, slot, stop_request} while on a tram
var population := PackedByteArray()
var night := 0.0
var yaw := 0.0
var pitch := 0.0
var remotes := {}  # id -> RemotePlayer
var conversations := {}  # other id -> true
var incoming := {}  # request id -> {from, expires}
var outgoing_request := -1
var muted := {}  # id -> true, local only

var _eye_height := 1.6
var _input_seq := 0
var _pending_inputs: Array = []
var _latest_snapshot := {}
var _last_snapshot_tick := -1
var _clock_offset := 0.0
var _clock_ready := false
var _prev_pos := Vector3.ZERO
var _curr_pos := Vector3.ZERO
var _correction := Vector3.ZERO
var _connect_started := 0.0
var _outgoing_target := 0
var _block_confirm := {"id": 0, "until": 0.0}
var _report_target := {"id": 0, "until": 0.0}
var _hud_refresh := 0.0
var _screenshot_done := false
var _screenshot_busy := false
var _joined_at := 0.0
var _stats := {"snapshots": 0, "replays": 0, "corrections": 0.0, "correction_max": 0.0, "at": 0.0, "rate": 0.0}
var _headless := false
var _finished := false
var _tick_frame := -1
var _ticks_this_frame := 0
var _rtt_ms := 0.0
var _touch_mode := false
var _person_target := -1
var _quality_setting := GraphicsQuality.AUTO
var _fps_window := {"frames": 0, "time": 0.0, "slow": 0}
var _render_scale := 1.0
var _hud_tick := 0.0
var _step_visual := 0.0  # eases the camera up kerbs and platforms
var _flashing := false
var _shake := 0.0
var _tram_hit_at := -INF
var _tram_warned_at := -INF


static func now() -> float:
	return Time.get_ticks_usec() / 1000000.0


## options: address ("host:port" or ws(s):// URL), name, avatar, spawn_mode,
## account_id, account_secret, bot ("" | "wander" | "social" | "idle"),
## quit_after, screenshot, yaw, pitch, mouse_sensitivity, touch
func start(opts: Dictionary) -> void:
	options = opts
	_headless = DisplayServer.get_name() == "headless"
	display_name = str(opts.name)
	if str(opts.get("bot", "")) != "":
		bot = BotBrain.new(str(opts.bot), hash(display_name))
		bot.block_test = opts.has("block_test")
	Net.client = self
	multiplayer.connected_to_server.connect(_on_connected)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)
	_touch_mode = not _headless and bot == null \
		and (DisplayServer.is_touchscreen_available() or bool(opts.get("touch", false)))
	var err := Net.connect_to(str(opts.address))
	if err != OK:
		_finish("Bağlantı kurulamadı: %s" % error_string(err))
		return
	_connect_started = now()
	log_line("connecting to %s" % opts.address)


func _exit_tree() -> void:
	if Net.client == self:
		Net.client = null
		Net.close()
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func log_line(text: String) -> void:
	if bot:
		print("[bot %s] %s" % [display_name, text])


func _finish(message: String) -> void:
	if _finished:
		return
	_finished = true
	log_line("finished: %s" % message)
	joined = false
	set_physics_process(false)
	set_process(false)
	finished.emit.call_deferred(message)


func _on_connected() -> void:
	log_line("connected, sending hello")
	Net.disable_throttling(1)
	Net.c_hello.rpc_id(1, {
		"protocol": Protocol.PROTOCOL_VERSION,
		"client_build": Protocol.CLIENT_BUILD,
		"account_id": options.account_id,
		"account_secret": options.account_secret,
		"name": display_name,
		"avatar": options.avatar,
		"spawn_mode": options.get("spawn_mode", "social"),
	})


func _on_connection_failed() -> void:
	_finish("Sunucuya bağlanılamadı.")


func _on_server_disconnected() -> void:
	_finish("Sunucu bağlantısı koptu.")


# --- server messages ---------------------------------------------------------

func on_reject(reason: String) -> void:
	_finish(REJECTS.get(reason, "Sunucu bağlantıyı reddetti: %s" % reason))


func on_welcome(info: Dictionary) -> void:
	zone = ZoneData.load_zone(str(info.zone_id))
	if zone == null or zone.version != int(info.zone_version):
		_finish("Bu istemcide '%s' bölgesinin v%s paketi yok." % [info.zone_id, info.zone_version])
		return
	my_id = int(info.id)
	avatar = info.avatar
	display_name = str(info.name)
	transit = zone.transit
	# Trams need a clock before the first snapshot arrives.
	_clock_offset = now() - float(info.get("server_time", 0.0))
	if not _headless:
		_quality_setting = GraphicsQuality.from_key(str(options.get("quality", "auto")))
		GraphicsQuality.level = GraphicsQuality.initial_level(_quality_setting)
		CityMaterials.set_lite(GraphicsQuality.lite_shaders())
	var world := WorldBuilder.build(zone, self, not _headless)
	if not _headless:
		var city: Dictionary = world.get_meta("city", {})
		_boards = city.get("boards", [])
		sky = SkyController.new()
		sky.name = "Sky"
		add_child(sky)
		var compat := RenderingServer.get_current_rendering_method() == "gl_compatibility"
		if options.has("time"):
			var hm := str(options.time).split(":")
			sky.hours_override = float(hm[0]) + (float(hm[1]) / 60.0 if hm.size() > 1 else 0.0)
		sky.setup(zone, city.get("lamps", PackedVector3Array()), compat)
		weather_view = WeatherView.new()
		weather_view.name = "Weather"
		add_child(weather_view)
		weather_view.setup(self)
		fleet = TramFleet.new()
		fleet.name = "Trams"
		add_child(fleet)
		fleet.setup(transit, zone.half_size())
		props_view = PropView.new()
		props_view.name = "Props"
		add_child(props_view)
		props_view.setup(zone)
		crowd_view = CrowdView.new()
		crowd_view.name = "Crowd"
		add_child(crowd_view)
		critters = Critters.new()
		critters.name = "Critters"
		add_child(critters)
	body = PlayerMotor.make_body(avatar)
	body.name = "LocalPlayer"
	add_child(body)
	body.global_position = info.spawn
	_prev_pos = body.global_position
	_curr_pos = _prev_pos
	_eye_height = AvatarSpec.eye_height(avatar)
	yaw = float(info.yaw)
	if options.has("yaw"):
		yaw = deg_to_rad(float(options.yaw))
	if options.has("pitch"):
		pitch = deg_to_rad(float(options.pitch))
	if not _headless:
		camera = Camera3D.new()
		camera.fov = 75.0
		camera.near = 0.05
		camera.far = 1500.0
		camera.top_level = true
		add_child(camera)
		camera.make_current()
		apply_quality(GraphicsQuality.level)
		crowd_view.setup(self)
		critters.setup(self)
		if bot == null:
			hud = GameHud.new()
			add_child(hud)
			hud.chat_submitted.connect(send_chat)
			hud.resume_requested.connect(_set_paused.bind(false))
			hud.disconnect_requested.connect(_finish.bind("Bağlantı kesildi."))
			hud.person_action.connect(_on_person_action)
			hud.blocked_list_requested.connect(func(): Net.c_blocked_list.rpc_id(1))
			hud.unblock_requested.connect(unblock)
			hud.quality_requested.connect(set_quality_setting)
			hud.fps_toggled.connect(func(show: bool):
				var settings := LocalProfile.load_settings()
				settings.show_fps = show
				LocalProfile.save_settings(settings))
			hud.set_quality_key(GraphicsQuality.key_of(_quality_setting))
			hud.set_fps_visible(bool(options.get("show_fps", false)))
			if _touch_mode:
				hud.apply_touch_layout()
				hud.set_attribution("Harita verisi: " + zone.attribution_text())
				hud.notice("Hoş geldin, %s. Sol başparmak yürür, sağ taraf bakar." % display_name, 6.0)
				touch = TouchControls.new()
				add_child(touch)
				touch.action.connect(_on_touch_action)
			else:
				hud.set_attribution("Harita verisi: " + zone.attribution_text() + "  ·  F1 yardım")
				hud.notice("Hoş geldin, %s. Yardım için F1, harita için Tab." % display_name, 5.0)
				if not (options.has("screenshot") or options.has("perf")):
					Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
			navigator = Navigator.new()
			navigator.name = "Navigator"
			add_child(navigator)
			navigator.setup(self)
			city_map = CityMap.new()
			city_map.name = "CityMap"
			add_child(city_map)
			city_map.setup(self)
			city_map.destination_chosen.connect(func(en: Vector2):
				navigator.set_destination(en)
				city_map.refresh_info())
			city_map.route_cleared.connect(navigator.clear)
			sounds = CitySounds.new()
			sounds.name = "Sounds"
			add_child(sounds)
			sounds.setup(self)
			if props_view:
				props_view.sounds = sounds
			if touch:
				touch.exclude = [Rect2(get_viewport().get_visible_rect().size.x - 2 * CityMap.MINI_RADIUS - 16, 70,
					2 * CityMap.MINI_RADIUS, 2 * CityMap.MINI_RADIUS)]
	joined = true
	_joined_at = now()
	log_line("welcome id=%d zone=%s spawn=%s" % [my_id, zone.zone_id, body.global_position.snapped(Vector3.ONE * 0.1)])


func on_snapshot(data: PackedByteArray) -> void:
	if not joined:
		return
	var snap := SnapshotCodec.decode_snapshot(data)
	if snap.is_empty() or int(snap.tick) <= _last_snapshot_tick:
		return  # malformed or arrived out of order
	_last_snapshot_tick = int(snap.tick)
	_latest_snapshot = snap
	_stats.snapshots += 1
	var server_time := int(snap.tick) * Protocol.DT
	var offset := now() - server_time
	if not _clock_ready or offset < _clock_offset:
		_clock_offset = offset
		_clock_ready = true
	else:
		_clock_offset = lerpf(_clock_offset, offset, 0.02)
	for e in snap.entities:
		var r: RemotePlayer = remotes.get(e.id)
		if r:
			r.push_sample(server_time, e.pos, e.yaw, e.pitch, e.speed)
	if props_view and not (snap.props as Array).is_empty():
		props_view.push(server_time, snap.props)
	if bot and not (snap.props as Array).is_empty():
		bot.on_props_moving(self, snap.props)


func on_entity_enter(id: int, info: Dictionary) -> void:
	if remotes.has(id) or id == my_id:
		return
	var r := RemotePlayer.new()
	r.transit = transit
	add_child(r)
	r.setup(id, info)
	r.set_conversation(conversations.has(id))
	r.set_muted(muted.has(id))
	remotes[id] = r
	log_line("sees %s (%d)" % [r.display_name, id])


func on_entity_leave(id: int) -> void:
	if remotes.has(id):
		remotes[id].queue_free()
		remotes.erase(id)


func on_avatar(id: int, new_avatar: Dictionary) -> void:
	if id == my_id:
		avatar = new_avatar
		_eye_height = AvatarSpec.eye_height(avatar)
	elif remotes.has(id):
		remotes[id].set_avatar(new_avatar)


func on_interaction_incoming(request_id: int, from_id: int, _kind: String) -> void:
	if muted.has(from_id):
		return  # muted players' requests are silently ignored
	incoming[request_id] = {"from": from_id, "expires": now() + Protocol.REQUEST_TIMEOUT}
	if sounds:
		sounds.chime()
	log_line("incoming request %d from %s" % [request_id, _name_of(from_id)])
	if bot:
		bot.on_incoming(self, request_id, from_id)


func on_interaction_result(request_id: int, result: String) -> void:
	if incoming.has(request_id):
		incoming.erase(request_id)
		return
	match result:
		"sent":
			outgoing_request = request_id
		"accepted":
			outgoing_request = -1
		"no_response":
			outgoing_request = -1
			_notice("Yanıt gelmedi.")
	log_line("request %d: %s" % [request_id, result])


func on_conversation_open(other_id: int) -> void:
	conversations[other_id] = true
	if remotes.has(other_id):
		remotes[other_id].set_conversation(true)
	log_line("conversation open with %s" % _name_of(other_id))
	if hud:
		hud.add_system_line("%s ile sohbet başladı." % _name_of(other_id))
		hud.notice("%s ile sohbet başladı. %s" % [_name_of(other_id), "Yazmak için Yaz'a dokun." if touch else "Yazmak için Enter."])


func on_conversation_close(other_id: int, reason: String) -> void:
	conversations.erase(other_id)
	if remotes.has(other_id):
		remotes[other_id].set_conversation(false)
	log_line("conversation closed with %s (%s)" % [_name_of(other_id), reason])
	if hud:
		var why := {"distance": "uzaklaştınız", "left": "sohbet bitti", "blocked": "engellendi", "ended": "sohbet bitti"}
		hud.add_system_line("%s ile sohbet kapandı: %s." % [_name_of(other_id), why.get(reason, reason)])


func on_chat(from_id: int, text: String) -> void:
	if muted.has(from_id):
		return
	log_line("chat from %s: %s" % [_name_of(from_id), text])
	if remotes.has(from_id):
		remotes[from_id].say(text)
	if hud:
		hud.add_chat_line(_name_of(from_id), text, from_id == my_id)


func on_emote(from_id: int, kind: String) -> void:
	if muted.has(from_id):
		return
	if remotes.has(from_id):
		remotes[from_id].view.play_emote(kind)
	if from_id != my_id:
		log_line("%s did %s" % [_name_of(from_id), kind])
		_notice("%s %s." % [_name_of(from_id), "el salladı" if kind == "wave" else "selam verdi"])


func on_ride(info: Dictionary) -> void:
	var line_index := int(info.get("line", -1))
	if bool(info.get("update", false)):
		riding.stop_request = bool(info.stop_request)
		_notice("Durak isteği alındı; bir sonraki durakta ineceksin." if riding.stop_request else "Durak isteği iptal edildi.")
		return
	var ack := int(info.get("ack", 0))
	while not _pending_inputs.is_empty() and int(_pending_inputs[0].seq) <= ack:
		_pending_inputs.pop_front()
	if line_index >= 0:
		riding = {"line": line_index, "vehicle": int(info.vehicle), "slot": int(info.slot), "stop_request": false}
		var line: TransitNetwork.TransitLine = transit.lines[line_index]
		log_line("boarded %s" % line.id)
		_notice("%s tramvayına bindin: %s yönü." % [line.id, line.destination(ride_state().dir)])
		return
	riding = {}
	# Back on foot: continue predicting from the platform with whatever
	# inputs the server has not processed yet.
	body.global_position = info.pos
	body.velocity = Vector3.ZERO
	for inp in _pending_inputs:
		PlayerMotor.step(body, inp, transit)
		inp.pos = body.global_position
		inp.vel = body.velocity
	_prev_pos = body.global_position
	_curr_pos = _prev_pos
	_correction = Vector3.ZERO
	log_line("alighted at %s (%s)" % [info.get("stop", "?"), info.get("reason", "")])
	if str(info.get("reason", "")) == "end_of_line":
		_notice("Hat burada bölgeden çıkıyor; %s durağında indin." % info.get("stop", ""))
	else:
		_notice("%s durağında indin." % info.get("stop", ""))


func on_rider(id: int, ride: Array) -> void:
	if remotes.has(id):
		remotes[id].ride = ride


func on_weather(info: Dictionary) -> void:
	log_line("weather: %s" % WeatherService.describe(info))
	if weather_view:
		weather_view.set_info(info)


func on_props(data: PackedByteArray) -> void:
	var poses: Variant = SnapshotCodec.decode_props(data)
	if poses != null and props_view:
		props_view.apply_now(poses)


func on_blocked_list(list: Array) -> void:
	log_line("blocked list: %s" % ", ".join(list.map(func(e): return str(e.get("name", "?")) if typeof(e) == TYPE_DICTIONARY else "?")))
	if bot:
		bot.on_blocked_list(self, list)
	if hud:
		hud.show_blocked(list)


func unblock(account_id: String) -> void:
	Net.c_unblock.rpc_id(1, account_id)


func block_player(id: int) -> void:
	Net.c_block.rpc_id(1, id)


func on_population(counts: PackedByteArray) -> void:
	population = counts


func server_now() -> float:
	return now() - _clock_offset


func ride_state() -> Dictionary:
	if riding.is_empty():
		return {}
	return transit.lines[riding.line].state(riding.vehicle, server_now())


## Board the tram at the doors next to you, or (on board) step off / request a stop.
func tram_action() -> void:
	if not riding.is_empty():
		Net.c_alight.rpc_id(1)
		return
	var st := transit.boardable_near(ZoneData.to_en(body.global_position), server_now(), Protocol.BOARD_RADIUS)
	if st.is_empty():
		_notice("Yakında kapıları açık bir tramvay yok.")
		return
	Net.c_board.rpc_id(1, int(st.line), int(st.vehicle))


func _on_tram_hit() -> void:
	_shake = 1.0
	if now() - _tram_hit_at > 3.0:
		_tram_hit_at = now()
		log_line("hit by a tram")
		_notice("Tramvay çarptı! Rayların üstünde durma.")


## Warns (and rings the bell) when a moving tram is coming straight at you.
func _tram_warning() -> void:
	if not riding.is_empty() or now() - _tram_warned_at < 6.0:
		return
	var p := Vector2(body.global_position.x, body.global_position.z)
	for box in transit.boxes_near(roundi(server_now() / Protocol.DT), p, 40.0):
		var a: Vector2 = box[1]
		var d: Vector2 = p - (box[0] as Vector2)
		var ahead := d.dot(a) - float(box[2])
		var across := absf(d.dot(Vector2(-a.y, a.x)))
		if float(box[4]) > 1.0 and ahead > 0.0 and ahead < 30.0 and across < float(box[3]) + 0.6:
			_tram_warned_at = now()
			_notice("Dikkat, tramvay geliyor! Raylardan çekil.")
			if sounds:
				sounds.tram_bell(Vector3((box[0] as Vector2).x, 2.0, (box[0] as Vector2).y))
			return


func on_notice(code: String, detail: String) -> void:
	var text: String = NOTICES.get(code, code)
	if text.contains("%s"):
		text = text % detail
	log_line("notice %s %s" % [code, detail])
	_notice(text)


# --- social actions (keys and bots) -----------------------------------------

func request_talk(target_id: int) -> void:
	if conversations.has(target_id):
		_notice(NOTICES.already_talking)
		return
	_outgoing_target = target_id
	Net.c_interaction_request.rpc_id(1, target_id, "talk")


func respond_incoming(request_id: int, accept: bool) -> void:
	if incoming.erase(request_id):
		Net.c_interaction_response.rpc_id(1, request_id, accept)


func send_chat(text: String) -> void:
	Net.c_chat.rpc_id(1, text)


func send_emote(kind: String) -> void:
	Net.c_emote.rpc_id(1, kind)


func leave_conversation(other_id: int) -> void:
	Net.c_conversation_leave.rpc_id(1, other_id)


func toggle_mute(id: int) -> void:
	if muted.erase(id):
		_notice("%s artık susturulmuş değil." % _name_of(id))
	else:
		muted[id] = true
		_notice("%s susturuldu (yalnızca sende)." % _name_of(id))
	if remotes.has(id):
		remotes[id].set_muted(muted.has(id))


func nearest_remote(max_distance: float) -> int:
	var best := -1
	var best_d := max_distance
	for id in remotes:
		var d := body.global_position.distance_to(remotes[id].global_position)
		if d <= best_d:
			best_d = d
			best = id
	return best


func _name_of(id: int) -> String:
	if id == my_id:
		return display_name
	return remotes[id].display_name if remotes.has(id) else "Biri"


func _notice(text: String) -> void:
	if hud:
		hud.notice(text)


# --- simulation --------------------------------------------------------------

func _physics_process(_delta: float) -> void:
	if not joined:
		if _connect_started > 0.0 and now() - _connect_started > CONNECT_TIMEOUT:
			_finish("Sunucu yanıt vermedi.")
		return
	# After a stall (loading the world, a hitch) Godot runs the missed physics
	# ticks back to back. Sending them as a burst would overflow the server's
	# input queue, so the lost time is dropped instead.
	var frame := Engine.get_process_frames()
	_ticks_this_frame = _ticks_this_frame + 1 if frame == _tick_frame else 1
	_tick_frame = frame
	if _ticks_this_frame > MAX_TICKS_PER_FRAME:
		return
	_reconcile()

	var mx := 0.0
	var my := 0.0
	var buttons := 0
	if bot:
		var cmd := bot.think(self, now())
		mx = cmd.mx
		my = cmd.my
		yaw = cmd.yaw
		buttons = cmd.buttons
	elif _can_move() and touch:
		mx = touch.move.x
		my = touch.move.y
		if touch.jump_held:
			buttons |= PlayerMotor.BUTTON_JUMP
		if touch.sprint:
			buttons |= PlayerMotor.BUTTON_SPRINT
	elif _can_move():
		mx = float(Input.is_physical_key_pressed(KEY_D)) - float(Input.is_physical_key_pressed(KEY_A))
		my = float(Input.is_physical_key_pressed(KEY_W)) - float(Input.is_physical_key_pressed(KEY_S))
		if Input.is_physical_key_pressed(KEY_SPACE):
			buttons |= PlayerMotor.BUTTON_JUMP
		if Input.is_physical_key_pressed(KEY_SHIFT):
			buttons |= PlayerMotor.BUTTON_SPRINT

	_input_seq += 1
	# Stamped with the server tick we are looking at, so trams stand in the
	# same place for this input here and on the server.
	var wt := roundi(server_now() / Protocol.DT)
	var inp := SnapshotCodec.quantize_input(_input_seq, mx, my, yaw, pitch, buttons, wt)
	_prev_pos = body.global_position
	if riding.is_empty():
		var events := PlayerMotor.step(body, inp, transit)
		if events & PlayerMotor.EVENT_STEPPED:
			_step_visual -= body.global_position.y - _prev_pos.y
		if events & PlayerMotor.EVENT_TRAM_HIT:
			_on_tram_hit()
	else:
		body.global_position = transit.rider_position(riding.line, riding.vehicle, riding.slot, server_now())
	_curr_pos = body.global_position
	inp.pos = body.global_position  # predicted result, compared on ack
	inp.vel = body.velocity
	inp.t = now()
	_pending_inputs.append(inp)
	if _pending_inputs.size() > MAX_PENDING_INPUTS:
		_pending_inputs.pop_front()
	# Unreliable, so every packet repeats all inputs the server has not
	# acknowledged yet; a lost packet costs nothing unless many are lost in a row.
	Net.c_inputs.rpc_id(1, SnapshotCodec.encode_inputs(_pending_inputs))

	_expire_incoming()
	_check_quit()


## Rewind to the server's state for the last acknowledged input and replay
## everything the server has not processed yet.
func _reconcile() -> void:
	if _latest_snapshot.is_empty():
		return
	var snap := _latest_snapshot
	_latest_snapshot = {}
	var ack := int(snap.ack)
	var acked := {}
	while not _pending_inputs.is_empty() and int(_pending_inputs[0].seq) <= ack:
		acked = _pending_inputs.pop_front()
	if not acked.is_empty() and int(acked.seq) == ack:
		# Input-to-acknowledgement time: what "ping" means to the player.
		var sample := (now() - float(acked.t)) * 1000.0
		_rtt_ms = sample if _rtt_ms == 0.0 else lerpf(_rtt_ms, sample, 0.15)
	if not riding.is_empty():
		return  # the tram carries us; nothing to predict or correct
	# Usually the prediction was right and there is nothing to replay.
	if not acked.is_empty() and int(acked.seq) == ack 			and (acked.pos as Vector3).distance_to(snap.self_pos) < 0.01 			and (acked.vel as Vector3).distance_to(snap.self_vel) < 0.05:
		return
	_stats.replays += 1
	var before := body.global_position
	body.global_position = snap.self_pos
	body.velocity = snap.self_vel
	for inp in _pending_inputs:
		PlayerMotor.step(body, inp, transit)
		inp.pos = body.global_position
		inp.vel = body.velocity
	var error := before - body.global_position
	var err_len := error.length()
	if err_len > 0.5:
		log_line("correction %.2fm at ack=%d pending=%d tick=%d server=%s server_vel=%s predicted=%s predicted_vel=%s" % [err_len, ack, _pending_inputs.size(), int(snap.tick),
			snap.self_pos, snap.self_vel, acked.get("pos"), acked.get("vel")])
	_stats.corrections += err_len
	_stats.correction_max = maxf(_stats.correction_max, err_len)
	if err_len > SNAP_CORRECTION_ABOVE:
		_correction = Vector3.ZERO
	else:
		_correction += error
	_curr_pos = body.global_position


func _process(delta: float) -> void:
	if not joined:
		return
	_correction = _correction.lerp(Vector3.ZERO, 1.0 - exp(-CORRECTION_DECAY * delta))
	var frac := Engine.get_physics_interpolation_fraction()
	var render_pos := _prev_pos.lerp(_curr_pos, frac) + _correction
	if not riding.is_empty():
		render_pos = transit.rider_position(riding.line, riding.vehicle, riding.slot, server_now())
	if sky:
		night = sky.night
	if weather_view:
		weather_view.update(delta)
		sky.cloud = weather_view.cloud
		sky.rain = weather_view.rain
		sky.fog = weather_view.fog
		if weather_view._flash > 0.0 or _flashing:
			sky.flash(weather_view._flash)
			_flashing = weather_view._flash > 0.0
	var t0 := FrameProfiler.start()
	if fleet:
		if camera:
			fleet.camera_pos = camera.global_position
			fleet.view_distance = camera.far
		fleet.update(server_now(), night)
	FrameProfiler.add("fleet", t0)
	_step_visual = lerpf(_step_visual, 0.0, 1.0 - exp(-12.0 * delta))
	var cam_pos := render_pos + Vector3(0, _eye_height + _step_visual, 0)
	if touch:
		var size := get_viewport().get_visible_rect().size
		hud.set_portrait_warning(size.y > size.x)
		touch.enabled = not (hud.is_chat_open() or hud.is_modal_open() or size.y > size.x or _map_open())
		var look := touch.take_look()
		yaw = wrapf(yaw - look.x, -PI, PI)
		pitch = clampf(pitch - look.y, -1.45, 1.45)
	if camera:
		# A little walking sway and a wider view when running.
		var speed := Vector2(body.velocity.x, body.velocity.z).length() if riding.is_empty() else 0.0
		_bob_phase = fmod(_bob_phase + delta * (1.5 + speed * 2.2), TAU)
		var bob := sin(_bob_phase * 2.0) * 0.03 * clampf(speed / Protocol.WALK_SPEED, 0.0, 1.5)
		_shake = maxf(0.0, _shake - delta * 1.5)
		var jolt := Vector3(sin(now() * 71.0), sin(now() * 53.0), 0.0) * 0.05 * _shake
		camera.global_position = cam_pos + Vector3(0, bob, 0)
		camera.rotation = Vector3(pitch + jolt.y, yaw + jolt.x, sin(_bob_phase) * 0.004 * speed)
		camera.fov = lerpf(camera.fov, 75.0 + (7.0 if speed > Protocol.WALK_SPEED + 0.5 else 0.0), 1.0 - exp(-6.0 * delta))
	t0 = FrameProfiler.start()
	if sky:
		sky.update_lights(cam_pos, delta)
	FrameProfiler.add("lights", t0)
	t0 = FrameProfiler.start()
	if sounds:
		sounds.update(night, delta)
		if riding.is_empty():
			sounds.footsteps(Vector2(body.velocity.x, body.velocity.z).length(), body.is_on_floor(), delta)
	FrameProfiler.add("sounds", t0)
	t0 = FrameProfiler.start()
	_board_timer -= delta
	if _board_timer <= 0.0 and not _boards.is_empty():
		_board_timer = 1.0
		_refresh_boards()
	FrameProfiler.add("boards", t0)
	t0 = FrameProfiler.start()
	var server_now := now() - _clock_offset
	for r in remotes.values():
		r.update_render(server_now, delta, cam_pos)
	if props_view:
		props_view.update(server_now)
	t0 = FrameProfiler.start()
	if crowd_view and crowd_view.crowd:
		crowd_view.update(server_now, sky.local_hours())
	if critters and critters.client:
		critters.update(server_now, delta)
	FrameProfiler.add("crowd", t0)
	FrameProfiler.add("remotes", t0)
	t0 = FrameProfiler.start()
	# Prompts and hints only need to follow the player at 10 Hz.
	_hud_tick += delta
	if hud and _hud_tick >= 0.1:
		_update_hud(_hud_tick)
		_hud_tick = 0.0
	FrameProfiler.add("hud", t0)
	_auto_quality(delta)
	_perf_probe(delta)
	_maybe_screenshot()


var _perf := {"frames": 0, "time": 0.0, "worst": 0.0, "at": 0.0}


## --perf: frame statistics every two seconds on stdout, for tuning.
func _perf_probe(delta: float) -> void:
	if not options.get("perf", false) or camera == null:
		return
	if _perf.at == 0.0:
		_perf.at = now()
		FrameProfiler.enabled = true
		# --perf=Prefix1,Prefix2 hides scene parts to measure what they cost.
		var hide := str(options.perf).split(",", false) if str(options.perf) != "true" else PackedStringArray()
		for node in find_children("*", "Node3D", true, false):
			for prefix in hide:
				if str(node.name).begins_with(prefix):
					(node as Node3D).visible = false
		if hide.has("post") and sky:
			sky.environment.glow_enabled = false
			sky.environment.fog_enabled = false
			sky.environment.adjustment_enabled = false
			sky.environment.tonemap_mode = Environment.TONE_MAPPER_LINEAR
		DisplayServer.window_set_vsync_mode(DisplayServer.VSYNC_DISABLED)
		return
	_perf.frames += 1
	_perf.time += delta
	_perf.worst = maxf(_perf.worst, delta)
	if now() - float(_perf.at) < 2.0:
		return
	print("[perf] fps=%.0f worst_ms=%.1f process_ms=%.2f physics_ms=%.2f draw_calls=%d objects=%d prims=%dk nodes=%d" % [
		_perf.frames / _perf.time, _perf.worst * 1000.0,
		Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0,
		Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_OBJECTS_IN_FRAME),
		Performance.get_monitor(Performance.RENDER_TOTAL_PRIMITIVES_IN_FRAME) / 1000,
		Performance.get_monitor(Performance.OBJECT_NODE_COUNT)])
	print("[perf] sections_ms " + FrameProfiler.report(_perf.frames))
	_perf = {"frames": 0, "time": 0.0, "worst": 0.0, "at": now()}


## Applies a GraphicsQuality level to everything already built.
func apply_quality(level: int) -> void:
	GraphicsQuality.level = clampi(level, GraphicsQuality.LOW, GraphicsQuality.HIGH)
	CityMaterials.set_lite(GraphicsQuality.lite_shaders())
	if sky:
		sky.apply_quality()
	if camera:
		camera.far = GraphicsQuality.camera_far()
	for node in get_tree().get_nodes_in_group("ranged"):
		var gi := node as GeometryInstance3D
		gi.visibility_range_end = float(gi.get_meta("range")) * GraphicsQuality.range_scale()
	for node in get_tree().get_nodes_in_group("detail"):
		(node as Node3D).visible = GraphicsQuality.detail_props()
	log_line("graphics quality %s" % GraphicsQuality.NAMES[GraphicsQuality.level])


## Player choice from the pause menu ("auto" re-enables automatic steps).
func set_quality_setting(key: String) -> void:
	_quality_setting = GraphicsQuality.from_key(key)
	_set_render_scale(1.0)
	apply_quality(GraphicsQuality.initial_level(_quality_setting))
	var settings := LocalProfile.load_settings()
	settings.quality = key
	LocalProfile.save_settings(settings)


## On "auto", steps quality down when the frame rate stays poor for a few
## seconds; below LOW it renders the 3D view at a lower resolution.
func _auto_quality(delta: float) -> void:
	if _quality_setting != GraphicsQuality.AUTO or now() - _joined_at < 8.0:
		return
	_fps_window.frames += 1
	_fps_window.time += delta
	if _fps_window.time < 3.0:
		return
	var fps: float = _fps_window.frames / _fps_window.time
	_fps_window.slow = int(_fps_window.slow) + 1 if fps < 24.0 else 0
	_fps_window.frames = 0
	_fps_window.time = 0.0
	if int(_fps_window.slow) < 2:
		return
	_fps_window.slow = 0
	if GraphicsQuality.level > GraphicsQuality.LOW:
		apply_quality(GraphicsQuality.level - 1)
		_notice("Akıcılık için görüntü kalitesi %s yapıldı (Menü'den değiştirebilirsin)." % GraphicsQuality.NAMES[GraphicsQuality.level])
	elif _render_scale > 0.6:
		_set_render_scale(_render_scale - 0.2)
		_notice("Akıcılık için çözünürlük %%%d yapıldı." % roundi(_render_scale * 100.0))


func _set_render_scale(scale: float) -> void:
	_render_scale = scale
	var vp := get_viewport()
	vp.scaling_3d_mode = Viewport.SCALING_3D_MODE_BILINEAR
	vp.scaling_3d_scale = scale


func _map_open() -> bool:
	return city_map != null and city_map.is_big_open()


## Live departures on every stop's board.
func _refresh_boards() -> void:
	var t := server_now()
	var me := body.global_position
	for board in _boards:
		var label: Label3D = board.label
		if label.global_position.distance_to(me) > 70.0:
			continue
		var rows := PackedStringArray()
		for serve in board.serves:
			var line: TransitNetwork.TransitLine = transit.lines[serve[0]]
			var dep := line.departure_after(serve[1], serve[2], t)
			if dep.is_empty():
				continue
			var wait := float(dep.arrive) - t
			rows.append("%s  %s   %s" % [line.id, line.destination(serve[2]),
				"Durakta" if wait <= 0.0 else ("%d dk" % ceili(wait / 60.0) if wait >= 60.0 else "%d sn" % ceili(wait))])
		label.text = "\n".join(rows)


func _can_move() -> bool:
	if hud == null or hud.is_chat_open() or hud.is_modal_open() or _map_open():
		return false
	return touch != null or Input.mouse_mode == Input.MOUSE_MODE_CAPTURED


func _expire_incoming() -> void:
	var t := now()
	for id in incoming.keys():
		if t > float(incoming[id].expires):
			incoming.erase(id)


func _check_quit() -> void:
	var quit_after := float(options.get("quit_after", 0.0))
	if quit_after > 0.0 and now() - _joined_at > quit_after:
		var n := maxi(1, _stats.snapshots)
		log_line("stats snapshots=%d replays=%d avg_correction=%.3fm max_correction=%.3fm rtt=%dms remotes=%d conversations=%d" % [
			_stats.snapshots, _stats.replays, _stats.corrections / n, _stats.correction_max, roundi(_rtt_ms), remotes.size(), conversations.size()])
		joined = false
		Net.close()
		get_tree().quit()


func _maybe_screenshot() -> void:
	var path := str(options.get("screenshot", ""))
	if path.is_empty() or _screenshot_done or _screenshot_busy or now() - _joined_at < float(options.get("screenshot_after", 4.0)):
		return
	if options.has("route_to") and navigator and not navigator.has_plan():
		var at := str(options.route_to).split(",")
		navigator.set_destination(Vector2(float(at[0]), float(at[1])))
	if options.has("open_map") and city_map and not city_map.is_big_open():
		city_map.open_big()
	if options.has("look_sign") and not _screenshot_busy:
		# Debug framing: face the nearest shop sign in sight.
		var holder := find_child("ShopSigns", true, false)
		var best := Vector3.INF
		for sign: Node3D in (holder.get_children() if holder else []):
			var p := sign.global_position
			var d := p.distance_to(camera.global_position)
			var ray := PhysicsRayQueryParameters3D.create(camera.global_position, p, Protocol.LAYER_WORLD)
			var hit := get_world_3d().direct_space_state.intersect_ray(ray)
			if d > 5.0 and d < 35.0 and (hit.is_empty() or (hit.position as Vector3).distance_to(p) < 0.6) 					and (best == Vector3.INF or d < best.distance_to(camera.global_position)):
				best = p
		if best != Vector3.INF:
			var to := best - camera.global_position
			yaw = atan2(-to.x, -to.z)
			pitch = asin(clampf(to.normalized().y, -1.0, 1.0)) - 0.1
			_screenshot_busy = true
			await get_tree().create_timer(0.3).timeout
	if options.has("look_npc") and crowd_view and not _screenshot_busy:
		# Debug framing: face the nearest pedestrian in view of the camera.
		var best := Vector3.INF
		for i in crowd_view._count:
			var p: Vector3 = crowd_view._last[i]
			var d := p.distance_to(camera.global_position)
			var ray := PhysicsRayQueryParameters3D.create(camera.global_position, p + Vector3(0, 1.2, 0), Protocol.LAYER_WORLD)
			if d > 4.0 and d < 40.0 and get_world_3d().direct_space_state.intersect_ray(ray).is_empty() 					and (best == Vector3.INF or d < best.distance_to(camera.global_position)):
				best = p
		if best != Vector3.INF:
			var to := best + Vector3(0, 1.0, 0) - camera.global_position
			yaw = atan2(-to.x, -to.z)
			pitch = asin(clampf(to.normalized().y, -1.0, 1.0))
			_screenshot_busy = true
			await get_tree().create_timer(0.3).timeout
	if options.has("tram_shot") and fleet:
		# Debug framing: wait for a tram to come close, then look at it.
		var best := {}
		for veh in fleet.vehicle_nodes():
			var st := (transit.lines[veh.line] as TransitNetwork.TransitLine).state(veh.vehicle, server_now())
			var p := TransitNetwork.en_to_godot(st.pos, 1.6)
			var d := p.distance_to(camera.global_position)
			var ray := PhysicsRayQueryParameters3D.create(camera.global_position, p, Protocol.LAYER_WORLD)
			var seen := get_world_3d().direct_space_state.intersect_ray(ray).is_empty()
			if seen and d < 45.0 and d > 9.0 and (best.is_empty() or d < float(best.d)):
				best = {"d": d, "p": p}
		if best.is_empty():
			if now() - _joined_at < 150.0:
				return
		else:
			var to: Vector3 = best.p - camera.global_position
			yaw = atan2(-to.x, -to.z)
			pitch = -0.05
			_screenshot_busy = true
			await get_tree().create_timer(0.3).timeout
	_screenshot_done = true
	await RenderingServer.frame_post_draw
	var err := get_viewport().get_texture().get_image().save_png(path)
	print("[client] screenshot %s -> %s" % [path, error_string(err)])
	get_tree().quit()


# --- player input ------------------------------------------------------------

func _unhandled_input(event: InputEvent) -> void:
	if hud == null or not joined:
		return
	if event is InputEventMouseMotion and Input.mouse_mode == Input.MOUSE_MODE_CAPTURED:
		var sens := float(options.get("mouse_sensitivity", 0.0025))
		yaw = wrapf(yaw - event.relative.x * sens, -PI, PI)
		pitch = clampf(pitch - event.relative.y * sens, -1.45, 1.45)
	elif event is InputEventMouseButton and event.pressed and not hud.is_modal_open() and touch == null and not _map_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED
	elif event is InputEventKey and event.pressed and not event.echo:
		_on_key(event.physical_keycode)


func _on_key(key: Key) -> void:
	var t := now()
	if key == KEY_ESCAPE and _map_open():
		city_map.close_big()
		return
	if key == KEY_TAB and city_map:
		if _map_open():
			city_map.close_big()
		else:
			city_map.open_big()
		return
	if key == KEY_ESCAPE:
		_set_paused(not hud.is_paused())
		return
	if hud.is_paused():
		return
	if REPORT_KEYS.has(key) and t < float(_report_target.until):
		report_player(int(_report_target.id), REPORT_KEYS[key])
		_report_target.until = 0.0
		return
	var target := _look_target()
	match key:
		KEY_F:
			tram_action()
		KEY_F1:
			hud.toggle_help()
		KEY_F3:
			hud.toggle_stats()
		KEY_ENTER, KEY_KP_ENTER:
			if conversations.is_empty():
				_notice(NOTICES.not_in_conversation)
			else:
				hud.open_chat()
		KEY_E:
			if target > 0:
				request_talk(target)
			elif _cat_in_reach() >= 0:
				critters.pet(_cat_in_reach())
		KEY_G:
			send_emote("wave")
		KEY_H:
			send_emote("nod")
		KEY_Y, KEY_N:
			var latest := _latest_incoming()
			if latest >= 0:
				respond_incoming(latest, key == KEY_Y)
		KEY_M:
			if target > 0:
				toggle_mute(target)
		KEY_X:
			var other: int = target if conversations.has(target) else (conversations.keys().back() if not conversations.is_empty() else -1)
			if other > 0:
				leave_conversation(other)
		KEY_B:
			if target > 0:
				if int(_block_confirm.id) == target and t < float(_block_confirm.until):
					Net.c_block.rpc_id(1, target)
					_block_confirm.until = 0.0
				else:
					_block_confirm = {"id": target, "until": t + 3.0}
					_notice("%s engellensin mi? Onaylamak için tekrar B." % _name_of(target))
		KEY_R:
			if target > 0:
				_report_target = {"id": target, "until": t + 6.0}
				_notice("%s şikayet nedeni: 1 taciz · 2 nefret söylemi · 3 spam · 4 taklit · 5 diğer" % _name_of(target))


func report_player(id: int, reason: String) -> void:
	Net.c_report.rpc_id(1, id, reason)


func _set_paused(paused: bool) -> void:
	hud.set_paused(paused)
	if touch == null:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE if paused else Input.MOUSE_MODE_CAPTURED


func _on_touch_action(id: String) -> void:
	var target := _look_target()
	match id:
		"talk":
			if target > 0:
				request_talk(target)
			else:
				_notice("Konuşmak için birine bak ve yaklaş (4 m).")
		"leave":
			if target > 0:
				leave_conversation(target)
		"person":
			if target > 0:
				_person_target = target
				hud.show_person_menu(_name_of(target), muted.has(target))
		"wave":
			send_emote("wave")
		"nod":
			send_emote("nod")
		"chat":
			hud.open_chat()
		"menu":
			_set_paused(true)
		"accept", "decline":
			var latest := _latest_incoming()
			if latest >= 0:
				respond_incoming(latest, id == "accept")
		"tram":
			tram_action()
		"pet":
			if _cat_in_reach() >= 0:
				critters.pet(_cat_in_reach())


## What the tram button does right now, for the touch UI and hints.
func _tram_context() -> Dictionary:
	if not riding.is_empty():
		var st := ride_state()
		var line: TransitNetwork.TransitLine = transit.lines[riding.line]
		if st.dwelling and line.stops[st.stop].in_zone:
			return {"label": "İn", "tint": line.color}
		return {"label": "İptal" if riding.get("stop_request", false) else "Durak iste", "tint": line.color}
	var st := transit.boardable_near(ZoneData.to_en(body.global_position), server_now(), Protocol.BOARD_RADIUS)
	if st.is_empty():
		return {}
	var line: TransitNetwork.TransitLine = transit.lines[st.line]
	var key := "" if touch else " (F)"
	return {"label": "Bin %s" % line.id, "tint": line.color,
		"hint": "%s → %s kapıları açık: binmek için%s" % [line.id, line.destination(int(st.dir)), key if key else " Bin'e dokun"]}


func _ride_text() -> String:
	var st := ride_state()
	var line: TransitNetwork.TransitLine = transit.lines[riding.line]
	var next_name: String = line.stops[st.next].name
	var status := "kapılar açık" if st.dwelling else "sonraki durak %s (%s)" % [next_name, RoutePlanner.describe_seconds(float(st.leg_left))]
	var req := " · durak isteği verildi" if riding.get("stop_request", false) else ""
	return "%s → %s · %s%s" % [line.id, line.destination(int(st.dir)), status, req]


func _on_person_action(what: String) -> void:
	var id := _person_target
	if not remotes.has(id):
		return
	if what == "mute":
		toggle_mute(id)
	elif what == "block":
		Net.c_block.rpc_id(1, id)
	elif what.begins_with("report:"):
		report_player(id, what.trim_prefix("report:"))


## A cat right in front of you (for stroking), or -1.
func _cat_in_reach() -> int:
	if critters == null or critters.client == null or camera == null:
		return -1
	return critters.cat_near(camera.global_position - Vector3(0, 1.0, 0), -camera.global_transform.basis.z, 2.2)


func _latest_incoming() -> int:
	var best := -1
	for id in incoming:
		best = maxi(best, id)
	return best


## The remote player under the crosshair within interaction range, or -1.
func _look_target() -> int:
	if camera == null:
		return -1
	var origin := camera.global_position
	var forward := -camera.global_transform.basis.z
	var best := -1
	var best_along := INF
	for id in remotes:
		var r: RemotePlayer = remotes[id]
		if origin.distance_to(r.global_position + Vector3(0, 1.0, 0)) > Protocol.INTERACTION_RANGE + 0.5:
			continue
		var pts := Geometry3D.get_closest_points_between_segments(origin, origin + forward * 6.0,
			r.global_position + Vector3(0, 0.2, 0), r.global_position + Vector3(0, r.height(), 0))
		# Of everyone under the crosshair, the nearest one is the one you see.
		var along := origin.distance_to(pts[0])
		if pts[0].distance_to(pts[1]) < 0.6 and along < best_along:
			best_along = along
			best = id
	return best


func _update_hud(delta: float) -> void:
	_tram_warning()
	var t0 := FrameProfiler.start()
	var target := _look_target()
	var latest := _latest_incoming()
	var tram := _tram_context()
	FrameProfiler.add("hud.tram_ctx", t0)
	if touch:
		touch.set_context({"target": target > 0, "cat": target <= 0 and _cat_in_reach() >= 0, "talking_to_target": conversations.has(target),
			"in_conversation": not conversations.is_empty(), "incoming": latest >= 0,
			"tram_label": tram.get("label", ""), "tram_tint": tram.get("tint", Color("2e86de"))})
	t0 = FrameProfiler.start()
	if navigator:
		navigator.update()
		var route := navigator.instruction()
		if route == "" and not riding.is_empty():
			route = _ride_text()
		elif route == "" and tram.has("hint"):
			route = tram.hint
		hud.set_route(route)
	FrameProfiler.add("hud.nav", t0)
	if target > 0:
		var r: RemotePlayer = remotes[target]
		var line := r.display_name + "   "
		if touch:
			line += "sohbettesiniz" if conversations.has(target) else "konuşmak için Konuş'a dokun"
		else:
			line += "[X] sohbetten ayrıl" if conversations.has(target) else "[E] konuşma isteği"
			line += " · [G] el salla · [H] selam · [M] %s · [B] engelle · [R] şikayet" % ("sesi aç" if muted.has(target) else "sustur")
		hud.set_target(line)
	elif _cat_in_reach() >= 0:
		hud.set_target("Sokak kedisi  ·  " + ("sevmek için Sev'e dokun" if touch else "sevmek için [E]"))
	elif crowd_view and crowd_view.crowd and camera 			and crowd_view.look_target(camera.global_position, -camera.global_transform.basis.z, Protocol.INTERACTION_RANGE) >= 0:
		hud.set_target("Yaya  [NPC]  ·  yapay bir figür; sohbet edilemez")
	else:
		hud.set_target("")
	if latest >= 0:
		var req: Dictionary = incoming[latest]
		var keys := "" if touch else "   [Y] kabul   [N] reddet"
		hud.set_incoming("%s seninle konuşmak istiyor%s   (%d)" % [
			_name_of(int(req.from)), keys, ceili(float(req.expires) - now())])
	else:
		hud.set_incoming("")
	hud.set_outgoing("%s kişisine istek gönderildi, yanıt bekleniyor..." % _name_of(_outgoing_target) if outgoing_request >= 0 else "")

	_hud_refresh -= delta
	if _hud_refresh > 0.0:
		return
	_hud_refresh = 0.5
	t0 = FrameProfiler.start()
	hud.set_fps("%d FPS · %s%s" % [Engine.get_frames_per_second(), GraphicsQuality.NAMES[GraphicsQuality.level],
		" · %%%d" % roundi(_render_scale * 100.0) if _render_scale < 1.0 else ""])
	var pos := body.global_position
	var geo := zone.to_geo(pos)
	var street := zone.nearest_street(pos)
	var sky_line := weather_view.summary() if weather_view else ""
	hud.set_location("%s%s\n%s%.5f, %.5f   ·   yakında %d kişi" % [
		zone.display_name, ("   ·   " + sky_line) if sky_line else "", (street + "   ") if street else "", geo[0], geo[1], remotes.size()])
	var names := []
	for id in conversations:
		names.append(_name_of(id))
	hud.set_conversations(names)
	var span := maxf(0.001, now() - float(_stats.at))
	_stats.rate = _stats.snapshots / span if _stats.at > 0.0 else 0.0
	hud.set_stats("gecikme %d ms\nsnapshot %.0f/s\ndüzeltme max %.2f m\nbekleyen input %d" % [
		roundi(_rtt_ms), _stats.rate, _stats.correction_max, _pending_inputs.size()])
	_stats.snapshots = 0
	_stats.correction_max = 0.0
	_stats.at = now()
	FrameProfiler.add("hud.slow", t0)
