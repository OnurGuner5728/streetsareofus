class_name ZoneServer
extends Node3D
## Authoritative zone server. Clients send inputs, never positions; the
## server runs PlayerMotor for everyone, sends each client only the players
## it should know about (interest management), and enforces social rules.

const MAX_QUEUED_INPUTS := 24
const MAX_INPUT_CREDIT := float(Protocol.TICK_RATE)  # at most one second of saved-up movement
const MAX_INPUTS_PER_TICK := 3
const STARVED_TICKS_BEFORE_IDLE := 6  # 200 ms jitter allowance
const SAVE_INTERVAL := 30.0
const STATS_INTERVAL := 10.0
const AVATAR_CHANGE_COOLDOWN := 2.0
const REPORTS_PER_MINUTE := 5
# How far an input's world tick may lag behind (or run ahead of) the server.
const MAX_INPUT_LAG_TICKS := 45
const MAX_INPUT_LEAD_TICKS := 3


class Player:
	extends RefCounted
	var id := 0
	var account_id := ""
	var display_name := ""
	var avatar := {}
	var body: CharacterBody3D
	var yaw := 0.0
	var pitch := 0.0
	var buttons := 0
	var queue: Array = []
	var last_received_seq := 0
	var last_input := {}
	var last_processed_seq := 0
	var input_credit := 0.0
	var starved_ticks := 0
	var known := {}  # entity id -> true
	var snapshot_count := 0
	var blocked_accounts := {}  # accounts this player blocked
	var avatar_changed_at := -INF
	var report_times: Array = []
	var riding := {}  # {line, vehicle, slot, boarded_at, stop_request}
	var board_times: Array = []
	var tram_hit_at := -INF
	var last_input_at := 0.0  # server time of the last input packet
	var seat := -1  # bench * 2 + side while sitting
	var seat_yaw := 0.0
	var joined_at := 0.0


var zone: ZoneData
var store: ServerStore
var social: SocialRules
var spawner: SpawnPicker
var transit: TransitNetwork
var props: PropWorld
var weather: WeatherService
var options := {}
var players := {}  # peer id -> Player
var pending := {}  # peer id -> connect time, until c_hello arrives
var tick := 0

var _grid := {}  # Vector2i -> Array[int]
var _last_save := 0.0
var _seats := {}  # seat id -> peer
var _stats := {"ticks": 0, "tick_us": 0, "tick_us_max": 0, "sim_us": 0, "sim_steps": 0, "idle_steps": 0, "dropped": 0, "gap_filled": 0, "snap_us": 0, "snap_bytes": 0, "snap_entities": 0, "snaps": 0, "trams_us": 0, "motor_us": 0, "props_us": 0, "at": 0.0}
var _started_at := 0.0


static func now() -> float:
	return Time.get_ticks_msec() / 1000.0


## The clock trams run on; clients estimate it from snapshot ticks.
func server_time() -> float:
	return tick * Protocol.DT


## options: port, transport ("enet" | "ws"), zone, data_dir, cluster (bool),
## quit_after (seconds, 0 = never)
func setup(opts: Dictionary) -> Error:
	options = opts
	zone = ZoneData.load_zone(str(opts.zone))
	if zone == null:
		return ERR_FILE_NOT_FOUND
	WorldBuilder.build(zone, self, false)
	store = ServerStore.new(str(opts.data_dir))
	social = SocialRules.new(_blocked_either, _players_near.bind(Protocol.EMOTE_RANGE))
	spawner = SpawnPicker.new(zone)
	transit = zone.transit
	props = PropWorld.new()
	props.name = "Props"
	add_child(props)
	props.setup(zone)
	weather = WeatherService.new()
	weather.name = "Weather"
	add_child(weather)
	weather.setup(zone, str(opts.get("weather", "live")))
	weather.changed.connect(func(info: Dictionary):
		for pl in players.values():
			if Net.is_open(pl.id):
				Net.s_weather.rpc_id(pl.id, info))
	var err := Net.start_server(int(opts.port), str(opts.get("transport", "enet")))
	if err != OK:
		return err
	Net.server = self
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	_started_at = now()
	_last_save = now()
	_stats.at = now()
	var layout := StreetLayout.for_zone(zone)
	log_line("street furniture: %d lamps, %d parked cars, %d benches, %d bollards, %d stops; %d loose props" % [
		layout.lamps.size(), layout.cars.size(), layout.benches.size(), layout.bollards.size(), layout.stops.size(),
		props.bodies.size()])
	log_line("zone %s v%d (%d buildings, %d spawn points, %s) listening on %s/%d, data in %s" % [
		zone.zone_id, zone.version, zone.buildings.size(), zone.spawn_points.size(),
		ProjectSettings.get_setting("physics/3d/physics_engine"),
		"websocket" if opts.get("transport", "enet") == "ws" else "udp", opts.port, store.dir])
	return OK


static func log_line(text: String) -> void:
	print("[server %s] %s" % [Time.get_time_string_from_system(), text])


func _on_peer_connected(peer: int) -> void:
	if players.size() + pending.size() >= Protocol.MAX_PEERS:
		log_line("server full, refusing peer %d" % peer)
		Net.kick(peer)
		return
	pending[peer] = now()
	Net.disable_throttling(peer)


func _on_peer_disconnected(peer: int) -> void:
	pending.erase(peer)
	if not players.has(peer):
		return
	var pl: Player = players[peer]
	_release_seat(pl)
	_save_location(pl)
	players.erase(peer)
	_dispatch(social.on_disconnect(peer))
	for other in players.values():
		if other.known.erase(peer) and Net.is_open(other.id):
			Net.s_entity_leave.rpc_id(other.id, peer)
	pl.body.queue_free()
	store.audit("leave", {"account": pl.account_id, "peer": peer})
	store.flush()
	# How long the player had been silent tells a timeout from a clean close.
	log_line("%s left (%d online; in game %.0f s, last input %.1f s ago)" % [pl.display_name, players.size(),
		now() - pl.joined_at, now() - pl.last_input_at])


# --- join --------------------------------------------------------------------

func on_hello(peer: int, payload: Dictionary) -> void:
	if players.has(peer) or not pending.has(peer):
		return
	if int(payload.get("protocol", -1)) != Protocol.PROTOCOL_VERSION:
		_reject(peer, "protocol_mismatch")
		return
	var display_name := AvatarSpec.sanitize_name(payload.get("name"))
	if display_name.is_empty():
		_reject(peer, "bad_name")
		return
	var account_id := str(payload.get("account_id", ""))
	if not store.authenticate(account_id, str(payload.get("account_secret", "")), display_name):
		_reject(peer, "auth_failed")
		return
	for other in players.values():
		if other.account_id == account_id:
			_reject(peer, "already_connected")
			return

	var pl := Player.new()
	pl.id = peer
	pl.account_id = account_id
	pl.display_name = display_name
	pl.avatar = AvatarSpec.sanitize(payload.get("avatar"))
	pl.blocked_accounts = store.blocked_by(account_id).duplicate()
	pl.joined_at = now()
	pl.last_input_at = now()
	pl.body = PlayerMotor.make_body(pl.avatar)
	pl.body.name = "Player_%d" % peer
	add_child(pl.body)

	var mode := str(payload.get("spawn_mode", "social"))
	var spawn := _choose_spawn(pl, mode)
	spawn.pos = free_spot(pl.body, spawn.pos)
	pl.body.global_position = spawn.pos
	pl.yaw = spawn.yaw
	pending.erase(peer)
	players[peer] = pl
	store.update_profile(account_id, display_name, pl.avatar)
	store.audit("join", {"account": account_id, "peer": peer, "zone": zone.zone_id, "mode": mode})

	Net.s_welcome.rpc_id(peer, {
		"id": peer, "zone_id": zone.zone_id, "zone_version": zone.version,
		"tick_rate": Protocol.TICK_RATE, "tick": tick, "server_time": server_time(),
		"spawn": spawn.pos, "yaw": spawn.yaw, "name": display_name, "avatar": pl.avatar,
	})
	var moved := props.displaced_poses()
	if not moved.is_empty():
		Net.s_props.rpc_id(peer, SnapshotCodec.encode_props(moved))
	Net.s_weather.rpc_id(peer, weather.current)
	log_line("%s joined at %s via %s (%d online)" % [display_name, spawn.pos.snapped(Vector3.ONE * 0.1), spawn.how, players.size()])


func _choose_spawn(pl: Player, mode: String) -> Dictionary:
	if options.get("cluster", false):
		# Test mode: everyone appears next to each other on the best spawn
		# point, or on --spawn-at=e,n.
		var p: Dictionary = zone.spawn_points[0] if not zone.spawn_points.is_empty() else {"e": 0.0, "n": 0.0}
		if str(options.get("spawn_at", "")) != "":
			var at := str(options.spawn_at).split(",")
			p = {"e": float(at[0]), "n": float(at[1])}
		var offset := Vector3((players.size() % 4) * 1.5, 0, (players.size() / 4) * 1.5)
		var at := zone.ground(float(p.e), float(p.n), 0.05) + offset
		at.y = zone.terrain.height(at.x, at.z) + 0.05
		return {"pos": at, "yaw": 0.0, "how": "cluster"}
	if mode == "resume":
		var loc := store.last_location(pl.account_id, zone.zone_id, zone.version)
		if not loc.is_empty():
			var saved := Vector3(float(loc.local_x), float(loc.local_y) + 0.05, float(loc.local_z))
			return {"pos": saved, "yaw": float(loc.get("yaw", 0.0)), "how": "resume"}
		mode = "social"
	var others := []
	for other in players.values():
		others.append(other.body.global_position)
	var pos := spawner.pick("random" if mode == "random" else "social", others)
	return {"pos": pos, "yaw": spawner.rng.randf() * TAU, "how": mode}


## [feet position] if a player fits standing at EN point `en` (on the
## ground or a platform, not in a car, bench or wall), else [].
func standing_spot(body: CharacterBody3D, en: Vector2) -> Array:
	var space := get_world_3d().direct_space_state
	var ground := zone.terrain.height_en(en)
	var top := Vector3(en.x, ground + 3.0, -en.y)
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(top, top - Vector3(0, 4.5, 0), Protocol.LAYER_WORLD))
	if hit.is_empty() or hit.position.y > ground + 0.5 or hit.normal.y < 0.7:
		return []
	var spot := Vector3(en.x, hit.position.y + 0.03, -en.y)
	if body.test_move(Transform3D(Basis(), spot), Vector3.ZERO):
		return []
	return [spot]


## `pos` if someone can stand there, otherwise the nearest spot that fits
## (searched in rings up to `search` metres).
func free_spot(body: CharacterBody3D, pos: Vector3, search := 5.0) -> Vector3:
	var centre := ZoneData.to_en(pos)
	for ring in int(search / 0.8) + 1:
		var count := 1 if ring == 0 else 8 * ring
		for k in count:
			var a := TAU * k / count
			var spot := standing_spot(body, centre + Vector2(cos(a), sin(a)) * ring * 0.8)
			if not spot.is_empty():
				return spot[0]
	return pos


func _reject(peer: int, reason: String) -> void:
	log_line("rejecting peer %d: %s" % [peer, reason])
	Net.s_reject.rpc_id(peer, reason)
	pending.erase(peer)
	Net.kick(peer)


# --- simulation --------------------------------------------------------------

func on_inputs(peer: int, data: PackedByteArray) -> void:
	if players.has(peer):
		(players[peer] as Player).last_input_at = now()
	var pl: Player = players.get(peer)
	if pl == null:
		return
	for inp in SnapshotCodec.decode_inputs(data):
		if inp.seq <= pl.last_received_seq or inp.seq > pl.last_received_seq + 120:
			continue
		inp.wt = clampi(SnapshotCodec.unwrap_tick(int(inp.wt), tick), tick - MAX_INPUT_LAG_TICKS, tick + MAX_INPUT_LEAD_TICKS)
		# Inputs that never arrived are replaced by the one before them, which
		# is what the player was most likely still doing.
		var missing: int = inp.seq - pl.last_received_seq - 1
		if missing > 0 and not pl.last_input.is_empty() and missing <= Protocol.MAX_GAP_FILL:
			for i in missing:
				var copy := pl.last_input.duplicate()
				copy.seq = pl.last_received_seq + 1 + i
				copy.wt = int(pl.last_input.wt) + 1 + i
				pl.queue.append(copy)
			_stats.gap_filled += missing
		pl.queue.append(inp)
		pl.last_received_seq = inp.seq
		pl.last_input = inp
	while pl.queue.size() > MAX_QUEUED_INPUTS:
		pl.queue.pop_front()
		_stats.dropped += 1


func _physics_process(_delta: float) -> void:
	var t0 := Time.get_ticks_usec()
	tick += 1
	props.update_trams(server_time())
	var t_trams := Time.get_ticks_usec()
	var everyone := players.values()
	for pl in everyone:
		_simulate(pl)
	var t_motor := Time.get_ticks_usec()
	props.push_from_players(everyone)
	props.track(tick, everyone)
	var t_sim := Time.get_ticks_usec()
	_stats.trams_us += t_trams - t0
	_stats.motor_us += t_motor - t_trams
	_stats.props_us += t_sim - t_motor
	_stats.sim_us += t_sim - t0
	if tick % 10 == 0:
		_dispatch(social.update(now(), _distance_between))
	if tick % Protocol.SNAPSHOT_EVERY_TICKS == 0:
		var t_snap := Time.get_ticks_usec()
		_send_snapshots()
		_stats.snap_us += Time.get_ticks_usec() - t_snap
	if tick % Protocol.TICK_RATE == 0:
		_drop_silent_peers()
	if tick % Protocol.POPULATION_EVERY_TICKS == 0:
		_send_population()
	var t := now()
	if t - _last_save > SAVE_INTERVAL:
		_last_save = t
		for pl in players.values():
			_save_location(pl)
		store.flush()
	var spent := Time.get_ticks_usec() - t0
	_stats.ticks += 1
	_stats.tick_us += spent
	_stats.tick_us_max = maxi(_stats.tick_us_max, spent)
	if t - _stats.at > STATS_INTERVAL:
		_log_stats(t)
	var quit_after := float(options.get("quit_after", 0.0))
	if quit_after > 0.0 and t - _started_at > quit_after:
		shutdown()
		get_tree().quit()


func _simulate(pl: Player) -> void:
	if not pl.riding.is_empty():
		_simulate_rider(pl)
		return
	# Each input is one client tick, so over time a client can never have more
	# inputs processed than server ticks have passed (no speed hacks). The
	# saved-up credit lets a backlog after a hitch drain instead of turning
	# into permanent extra latency.
	pl.input_credit = minf(pl.input_credit + 1.0, MAX_INPUT_CREDIT)
	var processed := 0
	var limit := MAX_INPUTS_PER_TICK if pl.queue.size() > 2 else 1
	while not pl.queue.is_empty() and pl.input_credit >= 1.0 and processed < limit:
		var inp: Dictionary = pl.queue.pop_front()
		var events := PlayerMotor.step(pl.body, inp, transit)
		if events & PlayerMotor.EVENT_TRAM_HIT and now() - pl.tram_hit_at > 3.0:
			pl.tram_hit_at = now()
			log_line("%s was hit by a tram" % pl.display_name)
		_stats.sim_steps += 1
		pl.yaw = inp.yaw
		pl.pitch = inp.pitch
		pl.buttons = inp.buttons
		pl.last_processed_seq = inp.seq
		pl.input_credit -= 1.0
		processed += 1
	if pl.seat >= 0 and not pl.body.has_meta("seat"):
		_release_seat(pl)  # stood up by moving
	if processed > 0:
		pl.starved_ticks = 0
		return
	# Briefly wait for late inputs instead of inventing movement; after
	# that, keep gravity running so nobody hangs in the air.
	pl.starved_ticks += 1
	if pl.starved_ticks > STARVED_TICKS_BEFORE_IDLE:
		_stats.idle_steps += 1
		PlayerMotor.step(pl.body, SnapshotCodec.quantize_input(pl.last_processed_seq, 0, 0, pl.yaw, pl.pitch, 0, tick), transit)


func _send_snapshots() -> void:
	_rebuild_grid()
	var prop_data := SnapshotCodec.encode_props(props.moving_poses(tick))
	for pl in players.values():
		if not Net.is_open(pl.id):
			continue
		pl.snapshot_count += 1
		var pos: Vector3 = pl.body.global_position
		var entities := []
		var interested := {}
		for other_id in _query_grid(pos, Protocol.INTEREST_FAR + Protocol.INTEREST_HYSTERESIS):
			if other_id == pl.id or _blocked_either(pl.id, other_id):
				continue
			var other: Player = players[other_id]
			var other_pos := other.body.global_position
			var d := pos.distance_to(other_pos)
			var fresh: bool = not pl.known.has(other_id)
			if d > Protocol.INTEREST_FAR + (0.0 if fresh else Protocol.INTEREST_HYSTERESIS):
				continue
			interested[other_id] = true
			if fresh:
				pl.known[other_id] = true
				Net.s_entity_enter.rpc_id(pl.id, other_id, _entity_info(other))
			var every := 1
			if d > Protocol.INTEREST_MID:
				every = Protocol.FAR_EVERY
			elif d > Protocol.INTEREST_NEAR:
				every = Protocol.MID_EVERY
			if fresh or (pl.snapshot_count + other_id) % every == 0:
				var flags := 0
				if other.body.is_on_floor():
					flags |= SnapshotCodec.FLAG_GROUNDED
				if other.buttons & PlayerMotor.BUTTON_SPRINT:
					flags |= SnapshotCodec.FLAG_SPRINT
				if not other.riding.is_empty():
					flags |= SnapshotCodec.FLAG_RIDING
				if other.seat >= 0:
					flags |= SnapshotCodec.FLAG_SITTING
				entities.append({"id": other_id, "pos": other_pos, "yaw": other.seat_yaw if other.seat >= 0 else other.yaw, "pitch": other.pitch,
					"speed": Vector2(other.body.velocity.x, other.body.velocity.z).length(), "flags": flags})
		for known_id in pl.known.keys():
			if not interested.has(known_id):
				pl.known.erase(known_id)
				Net.s_entity_leave.rpc_id(pl.id, known_id)
		var data := SnapshotCodec.encode_snapshot(tick, pl.last_processed_seq, pos, pl.body.velocity, entities, prop_data)
		Net.s_snapshot.rpc_id(pl.id, data)
		_stats.snap_bytes += data.size()
		_stats.snap_entities += entities.size()
		_stats.snaps += 1


func _entity_info(pl: Player) -> Dictionary:
	return {"name": pl.display_name, "avatar": pl.avatar, "ride": _ride_array(pl)}


static func _ride_array(pl: Player) -> Array:
	if pl.riding.is_empty():
		return []
	return [int(pl.riding.line), int(pl.riding.vehicle), int(pl.riding.slot)]


# --- trams -----------------------------------------------------------------------

## Riders do not walk: inputs still update where they look and are
## acknowledged, but the body is carried by the tram's timetable position.
func _simulate_rider(pl: Player) -> void:
	pl.input_credit = minf(pl.input_credit + 1.0, MAX_INPUT_CREDIT)
	var processed := 0
	while not pl.queue.is_empty() and pl.input_credit >= 1.0 and processed < MAX_INPUTS_PER_TICK:
		var inp: Dictionary = pl.queue.pop_front()
		pl.yaw = inp.yaw
		pl.pitch = inp.pitch
		pl.buttons = 0
		pl.last_processed_seq = inp.seq
		pl.input_credit -= 1.0
		processed += 1
	var r := pl.riding
	var t := server_time()
	var line: TransitNetwork.TransitLine = transit.lines[r.line]
	pl.body.global_position = transit.rider_position(r.line, r.vehicle, r.slot, t)
	pl.body.velocity = Vector3.ZERO
	var st := line.state(r.vehicle, t)
	# Only stops reached after boarding count, not the one you got on at.
	if st.dwelling and float(st.dwell_started) > float(r.boarded_at) + 0.5:
		var stop: int = st.stop
		var leaving := line.is_terminus(stop) or not line.continues_in_zone(stop, st.dir)
		if r.stop_request or leaving:
			_alight(pl, st, "stop" if r.stop_request else "end_of_line")


func on_board(peer: int, line_index: int, vehicle: int) -> void:
	var pl: Player = players.get(peer)
	if pl == null or not pl.riding.is_empty() or line_index < 0 or line_index >= transit.lines.size():
		return
	var line: TransitNetwork.TransitLine = transit.lines[line_index]
	if vehicle < 0 or vehicle >= line.vehicles:
		return
	var t := server_time()
	var wall := now()
	pl.board_times = pl.board_times.filter(func(x): return wall - float(x) < 5.0)
	if pl.board_times.size() >= 4:
		return
	pl.board_times.append(wall)
	var st := line.state(vehicle, t)
	if not st.dwelling or not line.stops[st.stop].in_zone or not line.continues_in_zone(st.stop, st.dir):
		_dispatch([SocialRules._notice(peer, "tram_not_boardable")])
		return
	var p := ZoneData.to_en(pl.body.global_position)
	var half_len := line.vehicle_length / 2.0
	var door := Geometry2D.get_closest_point_to_segment(p, st.pos - st.heading * half_len, st.pos + st.heading * half_len)
	if p.distance_to(door) > Protocol.BOARD_RADIUS + 1.5:
		_dispatch([SocialRules._notice(peer, "too_far_tram")])
		return
	var taken := {}
	for other in players.values():
		if not other.riding.is_empty() and other.riding.line == line_index and other.riding.vehicle == vehicle:
			taken[int(other.riding.slot)] = true
	var capacity := int(line.vehicle_length / 1.4) * 2
	var slot := 0
	while taken.has(slot):
		slot += 1
	if slot >= capacity:
		_dispatch([SocialRules._notice(peer, "tram_full")])
		return
	pl.riding = {"line": line_index, "vehicle": vehicle, "slot": slot, "boarded_at": t, "stop_request": false}
	pl.body.global_position = transit.rider_position(line_index, vehicle, slot, t)
	pl.body.velocity = Vector3.ZERO
	Net.s_ride.rpc_id(peer, {"line": line_index, "vehicle": vehicle, "slot": slot, "ack": pl.last_processed_seq})
	_broadcast_rider(pl)
	log_line("%s boarded %s at %s" % [pl.display_name, line.id, line.stops[st.stop].name])


func on_alight(peer: int) -> void:
	var pl: Player = players.get(peer)
	if pl == null or pl.riding.is_empty():
		return
	var line: TransitNetwork.TransitLine = transit.lines[pl.riding.line]
	var st := line.state(pl.riding.vehicle, server_time())
	# In the last second of a stop the doors are closing: a press then (often
	# sent just as the rider saw the tram leave) asks for the next stop.
	if st.dwelling and line.stops[st.stop].in_zone and float(st.leg_left) > 1.0:
		_alight(pl, st, "request")
		return
	pl.riding.stop_request = not pl.riding.stop_request
	Net.s_ride.rpc_id(peer, {"line": pl.riding.line, "vehicle": pl.riding.vehicle, "slot": pl.riding.slot,
		"stop_request": pl.riding.stop_request, "update": true})


func _alight(pl: Player, st: Dictionary, reason: String) -> void:
	var line: TransitNetwork.TransitLine = transit.lines[pl.riding.line]
	var stop: int = st.stop
	var dir: int = st.dir
	var heading := line.tangent_at(float(line.stops[stop].s)) * dir
	var platform := line.platform(stop, dir) + heading * ((int(pl.riding.slot) % 6) - 2.5) * 0.8
	# Narrow streets: never drop anyone into a wall; slide back towards the track.
	var track := line.track_point(float(line.stops[stop].s), dir)
	var pos := zone.ground(platform.x, platform.y, StreetLayout.PLATFORM_HEIGHT + 0.03)
	for k in 5:
		var spot := standing_spot(pl.body, platform.lerp(track, k / 4.0 * 0.6))
		if not spot.is_empty():
			pos = spot[0]
			break
	pl.body.global_position = pos
	pl.body.velocity = Vector3.ZERO
	pl.riding = {}
	Net.s_ride.rpc_id(pl.id, {"line": -1, "pos": pos, "ack": pl.last_processed_seq, "reason": reason,
		"stop": line.stops[stop].name, "line_id": line.id})
	_broadcast_rider(pl)
	log_line("%s left %s at %s (%s)" % [pl.display_name, line.id, line.stops[stop].name, reason])


func _broadcast_rider(pl: Player) -> void:
	var ride := _ride_array(pl)
	for other in players.values():
		if other.known.has(pl.id) and Net.is_open(other.id):
			Net.s_rider.rpc_id(other.id, pl.id, ride)


func _send_population() -> void:
	var cells := ceili(zone.size_m / Protocol.POPULATION_CELL)
	var counts := PackedByteArray()
	counts.resize(cells * cells)
	var half := zone.half_size()
	for pl in players.values():
		var p: Vector3 = pl.body.global_position
		var cx := clampi(floori((p.x + half) / Protocol.POPULATION_CELL), 0, cells - 1)
		var cz := clampi(floori((p.z + half) / Protocol.POPULATION_CELL), 0, cells - 1)
		var i := cz * cells + cx
		counts[i] = mini(255, counts[i] + 1)
	for pl in players.values():
		if Net.is_open(pl.id):
			Net.s_population.rpc_id(pl.id, counts)


func _rebuild_grid() -> void:
	_grid.clear()
	for pl in players.values():
		var cell := _cell(pl.body.global_position)
		if not _grid.has(cell):
			_grid[cell] = []
		_grid[cell].append(pl.id)


func _cell(pos: Vector3) -> Vector2i:
	return Vector2i(floori(pos.x / Protocol.INTEREST_CELL), floori(pos.z / Protocol.INTEREST_CELL))


func _query_grid(pos: Vector3, radius: float) -> Array:
	var out := []
	var c := _cell(pos)
	var r := ceili(radius / Protocol.INTEREST_CELL)
	for x in range(c.x - r, c.x + r + 1):
		for z in range(c.y - r, c.y + r + 1):
			var ids: Variant = _grid.get(Vector2i(x, z))
			if ids != null:
				out.append_array(ids)
	return out


func _drop_silent_peers() -> void:
	var t := now()
	for peer in pending.keys():
		if t - float(pending[peer]) > Protocol.HELLO_TIMEOUT:
			log_line("peer %d never said hello, disconnecting" % peer)
			pending.erase(peer)
			if Net.peer:
				Net.peer.disconnect_peer(peer)


# --- social ------------------------------------------------------------------

func on_interaction_request(peer: int, target: int, kind: String) -> void:
	var a: Player = players.get(peer)
	var b: Player = players.get(target)
	if a == null or b == null:
		return
	var d := a.body.global_position.distance_to(b.body.global_position)
	_dispatch(social.request(peer, target, kind, now(), d, a.blocked_accounts.has(b.account_id)))


func on_interaction_response(peer: int, request_id: int, accept: bool) -> void:
	if players.has(peer):
		_dispatch(social.respond(peer, request_id, accept, now()))


func on_conversation_leave(peer: int, other: int) -> void:
	if players.has(peer):
		_dispatch(social.close_conversation(peer, other, "left"))


func on_chat(peer: int, text: String) -> void:
	if players.has(peer):
		_dispatch(social.chat(peer, text, now()))


func on_emote(peer: int, kind: String) -> void:
	if players.has(peer):
		_dispatch(social.emote(peer, kind, now()))


func on_block(peer: int, target: int) -> void:
	var a: Player = players.get(peer)
	var b: Player = players.get(target)
	if a == null or b == null or peer == target or a.blocked_accounts.has(b.account_id):
		return
	a.blocked_accounts[b.account_id] = true
	store.block(a.account_id, b.account_id)
	store.audit("block", {"blocker": a.account_id, "blocked": b.account_id})
	_dispatch(social.on_block(peer, target))
	# Blocked pairs stop seeing each other entirely.
	for pair in [[a, b], [b, a]]:
		if pair[0].known.erase(pair[1].id):
			Net.s_entity_leave.rpc_id(pair[0].id, pair[1].id)
	log_line("%s blocked %s" % [a.display_name, b.display_name])


func on_blocked_list(peer: int) -> void:
	var pl: Player = players.get(peer)
	if pl != null:
		Net.s_blocked_list.rpc_id(peer, store.blocked_list(pl.account_id))


## Unblocking restores visibility on the next snapshot (unless the other
## person has blocked you too); nothing tells the other person.
func on_unblock(peer: int, account_id: String) -> void:
	var pl: Player = players.get(peer)
	if pl == null or not pl.blocked_accounts.has(account_id):
		return
	pl.blocked_accounts.erase(account_id)
	store.unblock(pl.account_id, account_id)
	store.audit("unblock", {"blocker": pl.account_id, "blocked": account_id})
	var other_name := str(store.accounts.get(account_id, {}).get("name", "?"))
	_dispatch([SocialRules._notice(peer, "unblocked", other_name)])
	Net.s_blocked_list.rpc_id(peer, store.blocked_list(pl.account_id))
	log_line("%s unblocked %s" % [pl.display_name, other_name])


func on_report(peer: int, target: int, reason: String) -> void:
	var a: Player = players.get(peer)
	var b: Player = players.get(target)
	if a == null or b == null or peer == target:
		return
	var t := now()
	a.report_times = a.report_times.filter(func(x): return t - float(x) < 60.0)
	if a.report_times.size() >= REPORTS_PER_MINUTE:
		_dispatch([SocialRules._notice(peer, "rate_limited")])
		return
	a.report_times.append(t)
	var lines := []
	for line in social.recent_lines(peer, target):
		lines.append({"from": players[line.from].account_id if players.has(line.from) else "", "text": line.text})
	var incident := store.new_incident_id()
	store.append_report({
		"id": incident, "created_at": ServerStore.now_iso(), "zone_id": zone.zone_id,
		"reporter_id": a.account_id, "reporter_name": a.display_name,
		"target_id": b.account_id, "target_name": b.display_name,
		"reason": reason if Protocol.REPORT_REASONS.has(reason) else "other",
		"context": {
			"tick": tick,
			"distance_m": snappedf(a.body.global_position.distance_to(b.body.global_position), 0.1),
			"in_conversation": social.in_conversation(peer, target),
			"recent_lines": lines,
		},
	})
	store.audit("report", {"id": incident, "reporter": a.account_id, "target": b.account_id})
	_dispatch([SocialRules._notice(peer, "reported", incident)])
	log_line("report %s: %s -> %s (%s)" % [incident, a.display_name, b.display_name, reason])


## Sit on the nearest free seat of a bench next to the player.
func on_sit(peer: int, bench: int) -> void:
	var pl: Player = players.get(peer)
	var benches: Array = StreetLayout.for_zone(zone).benches
	if pl == null or not pl.riding.is_empty() or bench < 0 or bench >= benches.size():
		return
	var b: Dictionary = benches[bench]
	var best := -1
	var best_d := Protocol.SIT_RANGE
	for side in Protocol.BENCH_SEATS.size():
		var id: int = bench * 2 + side
		if _seats.has(id) and _seats[id] != peer:
			continue
		var d := PlayerMotor.seat_origin(b, side).distance_to(pl.body.global_position)
		if d < best_d:
			best_d = d
			best = side
	if best < 0:
		Net.s_notice.rpc_id(peer, "bench_full", "")
		return
	_release_seat(pl)
	var origin := PlayerMotor.seat_origin(b, best)
	PlayerMotor.sit(pl.body, origin)
	pl.seat = bench * 2 + best
	pl.seat_yaw = float(b.yaw)
	_seats[pl.seat] = peer
	Net.s_sat.rpc_id(peer, origin, pl.seat_yaw)


func _release_seat(pl: Player) -> void:
	if pl.seat >= 0:
		_seats.erase(pl.seat)
		pl.seat = -1
	if pl.body and pl.body.has_meta("seat"):
		pl.body.remove_meta("seat")


func on_avatar(peer: int, raw: Dictionary) -> void:
	var pl: Player = players.get(peer)
	if pl == null or now() - pl.avatar_changed_at < AVATAR_CHANGE_COOLDOWN:
		return
	pl.avatar_changed_at = now()
	pl.avatar = AvatarSpec.sanitize(raw)
	PlayerMotor.fit_capsule(pl.body, pl.avatar)
	store.update_profile(pl.account_id, pl.display_name, pl.avatar)
	Net.s_avatar.rpc_id(peer, peer, pl.avatar)
	for other in players.values():
		if other.known.has(peer):
			Net.s_avatar.rpc_id(other.id, peer, pl.avatar)


# --- helpers -----------------------------------------------------------------

func _dispatch(effects: Array) -> void:
	for e in effects:
		if players.has(e.to) and Net.is_open(e.to):
			Net.callv("rpc_id", [e.to, StringName(e.rpc)] + e.args)


func _blocked_either(a: int, b: int) -> bool:
	var pa: Player = players.get(a)
	var pb: Player = players.get(b)
	if pa == null or pb == null:
		return false
	return pa.blocked_accounts.has(pb.account_id) or pb.blocked_accounts.has(pa.account_id)


func _players_near(peer: int, radius: float) -> Array:
	var out := []
	var pl: Player = players.get(peer)
	if pl == null:
		return out
	for other in players.values():
		if other.id != peer and other.body.global_position.distance_to(pl.body.global_position) <= radius:
			out.append(other.id)
	return out


func _distance_between(a: int, b: int) -> float:
	if not players.has(a) or not players.has(b):
		return INF
	return players[a].body.global_position.distance_to(players[b].body.global_position)


func _save_location(pl: Player) -> void:
	var pos := pl.body.global_position
	store.save_location(pl.account_id, zone.zone_id, zone.version, pos, pl.yaw, zone.to_geo(pos))


func _log_stats(t: float) -> void:
	var span := t - float(_stats.at)
	var ticks := maxi(1, _stats.ticks)
	log_line("stats: players=%d tick_avg=%.2fms (sim %.2f [trams %.2f motor %.2f props %.2f], snapshots %.2f) tick_max=%.2fms steps/s=%.0f idle=%d dropped=%d gap_filled=%d snapshots=%.1fKB/s entities/snapshot=%.1f prop_pushes=%d" % [
		players.size(), _stats.tick_us / 1000.0 / ticks, _stats.sim_us / 1000.0 / ticks,
		_stats.trams_us / 1000.0 / ticks, _stats.motor_us / 1000.0 / ticks, _stats.props_us / 1000.0 / ticks, _stats.snap_us / 1000.0 / ticks,
		_stats.tick_us_max / 1000.0, _stats.sim_steps / span, _stats.idle_steps, _stats.dropped, _stats.gap_filled,
		_stats.snap_bytes / 1024.0 / span, float(_stats.snap_entities) / maxi(1, _stats.snaps), props.pushes])
	props.pushes = 0
	_stats = {"ticks": 0, "tick_us": 0, "tick_us_max": 0, "sim_us": 0, "sim_steps": 0, "idle_steps": 0, "dropped": 0, "gap_filled": 0, "snap_us": 0, "snap_bytes": 0, "snap_entities": 0, "snaps": 0, "trams_us": 0, "motor_us": 0, "props_us": 0, "at": t}


func shutdown() -> void:
	for pl in players.values():
		_save_location(pl)
	store.flush()
	log_line("shut down")
