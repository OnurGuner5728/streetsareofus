class_name BotBrain
extends RefCounted
## Autopilot for headless test and load clients (plan: headless_bot).
## "wander": random walk, answers requests randomly (accept/decline/ignore).
## "social": seeks conversations: requests anyone within range, accepts
## everything, chats a few lines and waves.
## "idle": stands still, accepts requests and waves now and then; a test
## partner to put next to a real player.
## "commuter": runs to the stop with the soonest tram, boards it, requests
## the next stop and gets off; exercises routing and the tram rules.
## block_test (social): after the chat, blocks the partner, opens the
## blocked list and unblocks them again.

var mode := "wander"
var rng := RandomNumberGenerator.new()
var _heading := 0.0
var _turn_at := 0.0
var _next_social := 0.0
var _check_at := 0.0
var _check_pos := Vector3.ZERO
var _lines_sent := 0
var _waved := false
var _path := PackedVector2Array()
var _wp := 0
var _commute := {}
var _phase := ""
var block_test := false
var _saw_props := false
var _block_phase := ""
var _block_at := 0.0


func _init(bot_mode: String, seed_value: int) -> void:
	mode = bot_mode
	rng.seed = seed_value
	_heading = rng.randf() * TAU


## Returns movement for this tick: {mx, my, yaw, buttons}.
func think(client: GameClient, now: float) -> Dictionary:
	if mode == "commuter":
		return _commute_tick(client)
	if mode == "idle":
		if now >= _next_social:
			_next_social = now + 6.0
			client.send_emote("wave")
		return {"mx": 0.0, "my": 0.0, "yaw": _heading + sin(now * 0.3) * 0.6, "buttons": 0}
	var pos := client.body.global_position
	if now >= _check_at:
		# Turn away when stuck against a wall.
		if pos.distance_to(_check_pos) < 0.5 and _check_at > 0.0:
			_heading = rng.randf() * TAU
		_check_pos = pos
		_check_at = now + 1.0
	if now >= _turn_at:
		_heading += rng.randf_range(-1.2, 1.2)
		_turn_at = now + rng.randf_range(2.0, 6.0)
	var buttons := PlayerMotor.BUTTON_JUMP if rng.randf() < 0.01 else 0
	var move := 1.0
	if now >= _next_social:
		_next_social = now + 2.0
		_social_tick(client)
	if mode == "social" and not client.conversations.is_empty():
		move = 0.0  # stand still while talking
	return {"mx": 0.0, "my": move, "yaw": _heading, "buttons": buttons}


func _social_tick(client: GameClient) -> void:
	if not client.conversations.is_empty():
		if _lines_sent < 3:
			_lines_sent += 1
			client.send_chat("merhaba %d, ben %s" % [_lines_sent, client.display_name])
		elif not _waved:
			_waved = true
			client.send_emote("wave")
		elif block_test and _block_phase == "":
			_block_phase = "blocked"
			_block_at = GameClient.now()
			client.block_player(int(client.conversations.keys()[0]))
		return
	if _block_phase == "blocked" and GameClient.now() - _block_at > 3.0:
		_block_phase = "listed"
		Net.c_blocked_list.rpc_id(1)
		return
	if mode != "social" or client.outgoing_request >= 0:
		return
	var target := client.nearest_remote(Protocol.INTERACTION_RANGE - 0.5)
	if target > 0:
		client.request_talk(target)


func on_blocked_list(client: GameClient, list: Array) -> void:
	if _block_phase == "listed" and not list.is_empty():
		_block_phase = "unblocked"
		client.log_line("unblocking %s" % list[0].name)
		client.unblock(str(list[0].account))


## Logs once that props are moving in snapshots (for the physics smoke test).
func on_props_moving(client: GameClient, poses: Array) -> void:
	if not _saw_props:
		_saw_props = true
		client.log_line("props moving: %d" % poses.size())


func on_incoming(client: GameClient, request_id: int, _from_id: int) -> void:
	var roll := rng.randf()
	if mode != "wander" or roll < 0.6:
		client.respond_incoming(request_id, true)
	elif roll < 0.8:
		client.respond_incoming(request_id, false)
	# else: ignore it and let it time out


func _commute_tick(client: GameClient) -> Dictionary:
	var idle := {"mx": 0.0, "my": 0.0, "yaw": _heading, "buttons": 0}
	var t := client.server_now()
	var pos := ZoneData.to_en(client.body.global_position)
	if not client.riding.is_empty():
		if _phase == "boarding":
			_phase = "riding"
		var st := client.ride_state()
		if _phase == "riding" and not st.dwelling:
			client.tram_action()  # moving: ask for the next stop
			_phase = "requested"
		return idle
	if _phase == "riding" or _phase == "requested":
		_phase = "done"
		client.log_line("commute complete")
	if _phase == "done":
		return idle
	if _commute.is_empty():
		_plan_commute(client, pos, t)
		if _commute.is_empty():
			return idle
	var st := client.transit.boardable_near(pos, t, Protocol.BOARD_RADIUS - 1.5)
	if _phase != "boarding" and not st.is_empty() and int(st.line) == int(_commute.line) and int(st.dir) == int(_commute.dir):
		client.tram_action()
		_phase = "boarding"
		return idle
	while _wp < _path.size() and pos.distance_to(_path[_wp]) < 1.2:
		_wp += 1
	if _wp >= _path.size():
		return idle
	var d := _path[_wp] - pos
	_heading = atan2(-d.x, d.y)
	return {"mx": 0.0, "my": 1.0, "yaw": _heading, "buttons": PlayerMotor.BUTTON_SPRINT}


func _plan_commute(client: GameClient, pos: Vector2, t: float) -> void:
	var graph := client.zone.road_graph()
	var from := graph.search(pos)
	var best := {}
	for line: TransitNetwork.TransitLine in client.transit.lines:
		for i in line.stops.size():
			if not line.stops[i].in_zone:
				continue
			for dir in ([1] if line.loop else [1, -1]):
				if line.reachable(i, dir).is_empty():
					continue
				var plat := line.platform(i, dir)
				var run := graph.cost_to(from, plat) / Protocol.SPRINT_SPEED
				var dep := line.departure_after(i, dir, t + run + 3.0)
				if not dep.is_empty() and (best.is_empty() or float(dep.depart) < float(best.depart)):
					best = {"line": line.index, "stop": i, "dir": dir, "depart": float(dep.depart), "plat": plat}
	if best.is_empty():
		return
	_commute = best
	_path = graph.path_to(from, best.plat)
	_wp = 0
	_phase = "walk"
	var line: TransitNetwork.TransitLine = client.transit.lines[best.line]
	client.log_line("commute plan: %s from %s, departs in %.0f s" % [line.id, line.stops[best.stop].name, float(best.depart) - t])
