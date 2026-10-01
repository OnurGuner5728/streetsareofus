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
## group_test (social, two bots): the one whose name sorts first invites the
## other to a group; both chat in the group, play a rock-paper-scissors match
## and a hand-slap match, then leave the group.
## hide_test (social, two bots): the first one plays seeker for two saklambaç
## rounds: the hider stays and is found, then runs off, taps the base too
## early and too far away, comes back and tries to be freed.
## seksek_test (one bot spawned on a chalk grid, --spawn-at=seksek): turns
## hop-walk on, starts a turn and hops through every row.

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
var group_test := false
var _gt := ""  # group test progress: "", "grouped", "playing", "leaving", "done"
var _due: Array = []  # [{at, act}]: things to do a little later
var _game_key := ""
var _game_at := 0.0
var hide_test := false
var seksek_test := false
var _hide_rounds := 0
var _hunt_at := 0.0
var _hide_flags := {}
var _seksek_state := ""
var _run_pos := Vector3.ZERO
var _run_at := 0.0
var _run_heading := 0.0


func _init(bot_mode: String, seed_value: int) -> void:
	mode = bot_mode
	rng.seed = seed_value
	_heading = rng.randf() * TAU


## Returns movement for this tick: {mx, my, yaw, buttons}.
func think(client: GameClient, now: float) -> Dictionary:
	if group_test or hide_test:
		_run_due(client, now)
	if group_test:
		_game_tick(client, now)
	if seksek_test:
		return _seksek_tick(client, now)
	if hide_test:
		var cmd := _hide_tick(client, now)
		if not cmd.is_empty():
			return cmd
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
		elif group_test and _gt == "" and _is_leader(client):
			_gt = "inviting"
			client.request_interaction(int(client.conversations.keys()[0]), "group")
		elif hide_test and _hide_rounds == 0 and not _hide_flags.has("asked") and _is_leader(client):
			_hide_flags["asked"] = true
			client.request_interaction(int(client.conversations.keys()[0]), "hide")
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


## The bot whose name sorts first drives the group test.
func _is_leader(client: GameClient) -> bool:
	if client.conversations.is_empty():
		return false
	return client.display_name < client._name_of(int(client.conversations.keys()[0]))


func _later(seconds: float, act: String) -> void:
	_due.append({"at": GameClient.now() + seconds, "act": act})


func _run_due(client: GameClient, now: float) -> void:
	var i := 0
	while i < _due.size():
		if now < float(_due[i].at):
			i += 1
			continue
		var act := str(_due[i].act)
		_due.remove_at(i)
		var other := int(client.conversations.keys()[0]) if not client.conversations.is_empty() else -1
		match act:
			"group_chat":
				client.send_group_chat("grup merhaba, ben %s" % client.display_name)
			"request_rps":
				if other > 0:
					client.request_interaction(other, "rps")
			"request_slap":
				if other > 0:
					client.request_interaction(other, "slap")
			"leave_group":
				client.group_leave()
			"request_hide":
				var near := client.nearest_remote(Protocol.INTERACTION_RANGE + 20.0)
				if near > 0:
					client.request_interaction(near, "hide")


## Plays whatever match is running: picks after a human-ish delay, presses on
## the cue (the top player slaps, the bottom one pulls away).
func _game_tick(client: GameClient, now: float) -> void:
	if not client.game_active():
		_game_key = ""
		return
	var g: Dictionary = client.game
	var key := "%s:%d:%s" % [g.kind, int(g.round), g.phase]
	if key != _game_key:
		_game_key = key
		_game_at = now + rng.randf_range(0.2, 0.5)
	if now < _game_at:
		return
	if g.kind == "rps" and str(g.phase) in ["count", "pick"] and int(g.pick) < 0:
		client.game_pick(rng.randi() % 3)
	elif g.kind == "slap" and str(g.phase) == "go" and not bool(g.pressed):
		client.game_press()


func on_group(client: GameClient) -> void:
	if not group_test:
		return
	if not client.group.is_empty() and _gt in ["", "inviting"]:
		_gt = "grouped"
		_later(0.5, "group_chat")
	elif client.group.is_empty() and _gt == "leaving":
		_gt = "done"
		client.log_line("group test complete")


func on_group_chat(client: GameClient, from_id: int, _text: String) -> void:
	# The leader starts the games once the other one has spoken in the group.
	if group_test and from_id != client.my_id and _gt == "grouped" and _is_leader(client):
		_gt = "playing"
		_later(0.5, "request_rps")


func on_game(client: GameClient, event: Dictionary) -> void:
	if not group_test or str(event.get("ev", "")) != "end":
		return
	if str(event.get("kind", "")) == "rps":
		if _is_leader(client):
			_later(1.0, "request_slap")
	elif _gt in ["grouped", "playing"]:
		_gt = "leaving"
		_later(1.0 if not _is_leader(client) else 3.0, "leave_group")


## Saklambaç and seksek events (hide_test and seksek_test bots).
func on_party(client: GameClient, event: Dictionary) -> void:
	var ev := str(event.get("ev", ""))
	if ev == "hide_start":
		_hide_rounds += 1
		_hide_flags = {"asked": true}
		_run_heading = 0.0
		_run_at = 0.0
	elif ev == "hide_hunt":
		_hunt_at = GameClient.now()
	elif ev == "hide_end" and hide_test:
		if _hide_rounds == 1:
			if _is_leader_name(client):
				_later(2.0, "request_hide")
		elif _hide_rounds >= 2:
			client.log_line("hide test complete")
	elif ev == "seksek_end" and seksek_test:
		_seksek_state = "done"
		client.log_line("seksek test complete score=%d/%d reason=%s" % [int(event.score), int(event.total), str(event.reason)])


## True for the bot whose name sorts first (the seeker), judged by the nearest player.
func _is_leader_name(client: GameClient) -> bool:
	var near := client.nearest_remote(1000.0)
	return near > 0 and client.display_name < client._name_of(near)


## Heads along `heading` at a run, turning when stuck against something.
func _run(client: GameClient, now: float, heading: float) -> Dictionary:
	var pos := client.body.global_position
	if now >= _run_at:
		if _run_at > 0.0 and pos.distance_to(_run_pos) < 0.6:
			_run_heading += rng.randf_range(0.8, 2.4)
		_run_pos = pos
		_run_at = now + 1.0
	return {"mx": 0.0, "my": 1.0, "yaw": heading + _run_heading, "buttons": PlayerMotor.BUTTON_SPRINT}


## Yaw that heads along the ground direction d (x east, y south).
static func _yaw_along(d: Vector2) -> float:
	return atan2(-d.x, -d.y)


## Drives the saklambaç test; an empty result means "behave as usual".
func _hide_tick(client: GameClient, now: float) -> Dictionary:
	if not client.party_active():
		return {}
	var idle := {"mx": 0.0, "my": 0.0, "yaw": _heading, "buttons": 0}
	var p: Dictionary = client.party
	var pos := client.body.global_position
	var base: Vector3 = p.base
	var from_base := Vector2(pos.x - base.x, pos.z - base.z)
	if str(p.role) == "seeker":
		# Round 2: walk away from the hider so the hider can get back to the base.
		if _hide_rounds >= 2 and str(p.phase) == "hunt" and now - _hunt_at < 7.0:
			var near := client.nearest_remote(1000.0)
			var d := from_base
			if near > 0:
				var rp: Vector3 = client.remotes[near].global_position
				d = Vector2(pos.x - rp.x, pos.z - rp.z)
			return _run(client, now, _yaw_along(d))
		return idle
	if _hide_rounds < 2 or str(p.me) != "hidden":
		return idle  # round 1: stay put and get found
	if str(p.phase) == "count":
		if not _hide_flags.has("early"):
			_hide_flags["early"] = true
			Net.c_party_action.rpc_id(1, "free")  # too early: "hide_counting"
		if now - float(p.started) < 5.0:
			var away := from_base if from_base.length() > 0.5 else Vector2(sin(_heading), cos(_heading))
			return _run(client, now, _yaw_along(away))
		return idle
	# Hunt: first tap the base from afar (refused), then run back and tap it.
	if now - _hunt_at > 45.0:
		client.leave_party()
		return idle
	if from_base.length() > 4.0 and not _hide_flags.has("far"):
		_hide_flags["far"] = true
		_hide_flags["far_at"] = now
		Net.c_party_action.rpc_id(1, "free")  # too far: "hide_base_far"
	if not _hide_flags.has("far") and now - _hunt_at > 6.0:
		_hide_flags["far"] = true  # never got far away: just come back
		_hide_flags["far_at"] = now
	if _hide_flags.has("far") and now - float(_hide_flags.far_at) > 1.5:
		if client._hide_free_ready():
			if not _hide_flags.has("freed"):
				_hide_flags["freed"] = true
				Net.c_party_action.rpc_id(1, "free")
			return idle
		return _run(client, now, _yaw_along(-from_base))
	return idle


## Hops through the grid: walk to the launch point inside the square, jump
## forward, repeat. The lane u = -0.45 stays clear of every chalk line.
func _seksek_tick(client: GameClient, now: float) -> Dictionary:
	var idle := {"mx": 0.0, "my": 0.0, "yaw": _heading, "buttons": PlayerMotor.BUTTON_HOP if client.hop_on else 0}
	if _seksek_state == "done" or client.hopscotch == null:
		return idle
	if client.seksek.is_empty() or bool(client.seksek.get("ended", false)):
		if _seksek_state == "starting" and now - _game_at > 5.0:
			_seksek_state = ""  # the request was refused or lost: ask again
		if _seksek_state == "" and now > 3.0 and client._seksek_ready():
			_seksek_state = "starting"
			_game_at = now
			client.start_seksek()
		return idle
	var grid: Dictionary = client.hopscotch.grids[int(client.seksek.grid)]
	var pos := client.body.global_position
	var local := Hopscotch.to_local(grid, Vector2(pos.x, pos.z))
	var row := maxi(floori(local.y / Hopscotch.SQ), -1)  # the row we stand in (-1: start strip), from our own position since the server score lags
	var launch_v := (row + 1) * Hopscotch.SQ - 0.32
	var on_floor := PlayerMotor.is_grounded(client.body)
	var aligned := absf(local.x + 0.45) < 0.2
	var buttons := PlayerMotor.BUTTON_HOP
	if on_floor and aligned and local.y >= launch_v:
		buttons |= PlayerMotor.BUTTON_JUMP
	var forward := 1.0 if (aligned or not on_floor) else 0.0
	return {"mx": clampf((-0.45 - local.x) * 3.0, -1.0, 1.0), "my": forward, "yaw": float(grid.yaw), "buttons": buttons}


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
