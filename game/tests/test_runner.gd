extends Node
## Headless test suite: godot --headless --path game -- --test
## Exits with code 1 if any check fails.

var _checks := 0
var _failures: Array = []
var _test := ""


func _ready() -> void:
	var tests := [
		test_avatar_sanitize, test_names, test_input_codec, test_input_world_tick, test_snapshot_codec,
		test_social_request_flow, test_social_conversation, test_social_blocks,
		test_store, test_spawn_picker, test_zone_load,
		test_world_collision, test_motor_walks_and_is_blocked, test_replay_matches_realtime,
		test_client_and_server_worlds_agree, test_step_up, test_tram_shoves_and_blocks, test_props, test_crowd,
		test_terrain,
		test_transit_network, test_transit_timetable, test_walking_routes, test_route_prefers_tram,
	]
	for t in tests:
		_test = t.get_method()
		await t.call()
	print("")
	if _failures.is_empty():
		print("ALL TESTS PASSED (%d checks)" % _checks)
		get_tree().quit(0)
	else:
		for f in _failures:
			printerr("FAIL " + f)
		print("%d of %d checks failed" % [_failures.size(), _checks])
		get_tree().quit(1)


func check(cond: bool, what: String) -> void:
	_checks += 1
	if not cond:
		_failures.append("%s: %s" % [_test, what])


func near(a: float, b: float, eps: float, what: String) -> void:
	check(absf(a - b) <= eps, "%s (got %s, want %s ± %s)" % [what, a, b, eps])


static func rpcs(effects: Array, to: int) -> Array:
	var out := []
	for e in effects:
		if e.to == to:
			out.append(e.rpc if e.rpc != "s_notice" else "notice:" + str(e.args[0]))
	return out


# --- pure logic --------------------------------------------------------------

func test_avatar_sanitize() -> void:
	check(AvatarSpec.sanitize(null) == AvatarSpec.defaults(), "null becomes defaults")
	var a := AvatarSpec.sanitize({"body": {"height": 5, "weight": "heavy"}, "appearance": {"hair": "mohawk", "hair_color": "nope"},
		"clothing": {"top_color": "#ff0000", "bottom": "kilt"}})
	check(a.body.height == 1.0, "height clamped to 1")
	check(a.body.weight == AvatarSpec.defaults().body.weight, "non-numeric weight falls back")
	check(a.appearance.hair == "short", "unknown hair falls back")
	check(a.appearance.hair_color == AvatarSpec.defaults().appearance.hair_color, "bad colour falls back")
	check(a.clothing.top_color == "#ff0000", "valid colour kept")
	check(a.clothing.bottom == "jeans", "unknown bottom falls back")
	near(AvatarSpec.visual_height(a), 2.05, 0.001, "tallest visual height")
	near(AvatarSpec.gameplay_height(a), AvatarSpec.GAMEPLAY_HEIGHT_MAX, 0.001, "gameplay height clamped high")
	a.body.height = 0.0
	near(AvatarSpec.visual_height(a), 1.50, 0.001, "shortest visual height")
	near(AvatarSpec.gameplay_height(a), AvatarSpec.GAMEPLAY_HEIGHT_MIN, 0.001, "gameplay height clamped low")


func test_names() -> void:
	check(AvatarSpec.sanitize_name("Ay") == "", "too short")
	check(AvatarSpec.sanitize_name("Ayşe Yılmaz") == "Ayşe Yılmaz", "Turkish letters allowed")
	check(AvatarSpec.sanitize_name("  Ali    Veli ") == "Ali Veli", "whitespace collapsed")
	check(AvatarSpec.sanitize_name("<script>") == "", "markup rejected")
	check(AvatarSpec.sanitize_name("x".repeat(25)) == "", "too long")
	check(AvatarSpec.sanitize_name(42) == "", "non-string rejected")


func test_input_codec() -> void:
	var a := SnapshotCodec.quantize_input(7, 0.5, -1.0, 3.5, 0.3, 3)
	var b := SnapshotCodec.quantize_input(8, 0.0, 1.0, -0.2, -1.0, 0)
	var decoded := SnapshotCodec.decode_inputs(SnapshotCodec.encode_inputs([a, b]))
	check(decoded.size() == 2, "two inputs decoded")
	if decoded.size() == 2:
		check(decoded[0].seq == 7 and decoded[1].seq == 8, "sequence numbers survive")
		check(decoded[0].mx == a.mx and decoded[0].my == a.my, "decoded move equals the quantized move")
		check(decoded[0].yaw == a.yaw and decoded[1].yaw == b.yaw, "decoded yaw equals the quantized yaw")
		check(decoded[0].buttons == 3, "buttons survive")
	near(a.mx, 0.5, 1.0 / 127.0, "move quantization error")
	near(b.yaw, fposmod(-0.2, TAU), 0.0002, "yaw quantization error")
	check(SnapshotCodec.decode_inputs(PackedByteArray([5, 1, 2])).is_empty(), "truncated packet rejected")
	check(SnapshotCodec.decode_inputs(PackedByteArray([200])).is_empty(), "absurd count rejected")


func test_input_world_tick() -> void:
	var inp := SnapshotCodec.quantize_input(3, 0, 1, 0, 0, 0, 70000)
	var back: Dictionary = SnapshotCodec.decode_inputs(SnapshotCodec.encode_inputs([inp]))[0]
	check(SnapshotCodec.unwrap_tick(int(back.wt), 70010) == 70000, "world tick unwraps just behind the server")
	check(SnapshotCodec.unwrap_tick(int(back.wt), 69999) == 70000, "world tick unwraps just ahead of the server")
	check(SnapshotCodec.unwrap_tick(65535, 65540) == 65535, "world tick unwraps across the 16-bit boundary")


func test_snapshot_codec() -> void:
	var entities := [
		{"id": 12345, "pos": Vector3(1.5, 0.0, -20.25), "yaw": 1.0, "pitch": 0.2, "speed": 4.2, "flags": 1},
		{"id": 2000000000, "pos": Vector3(-100, 3, 50), "yaw": 6.0, "pitch": -0.5, "speed": 0.0, "flags": 0},
	]
	var data := SnapshotCodec.encode_snapshot(99, 42, Vector3(1, 2, 3), Vector3(0.5, -1, 0), entities)
	check(data.size() == 34 + 2 * SnapshotCodec.ENTITY_BYTES + 2, "snapshot size is compact")
	var snap := SnapshotCodec.decode_snapshot(data)
	check(snap.tick == 99 and snap.ack == 42, "header survives")
	check(snap.self_pos == Vector3(1, 2, 3), "self position survives")
	check(snap.entities.size() == 2, "entities survive")
	if snap.entities.size() == 2:
		check(snap.entities[1].id == 2000000000, "large peer id survives")
		check(snap.entities[0].pos.is_equal_approx(Vector3(1.5, 0.0, -20.25)), "entity position survives")
		near(snap.entities[0].speed, 4.2, 0.05, "speed")
	check(SnapshotCodec.decode_snapshot(data.slice(0, data.size() - 1)).is_empty(), "truncated snapshot rejected")
	var tilt := Transform3D(Basis(Vector3(1, 0, 1).normalized(), 0.8), Vector3(12.34, 0.56, -200.1))
	var props := SnapshotCodec.encode_props([[7, tilt], [300, Transform3D.IDENTITY]])
	check(props.size() == 2 + 2 * SnapshotCodec.PROP_BYTES, "props are 16 bytes each")
	var with_props := SnapshotCodec.decode_snapshot(SnapshotCodec.encode_snapshot(5, 1, Vector3.ZERO, Vector3.ZERO, [], props))
	check(with_props.props.size() == 2 and with_props.props[0][0] == 7, "props survive in a snapshot")
	if with_props.props.size() == 2:
		var got: Transform3D = with_props.props[0][1]
		check(got.origin.distance_to(tilt.origin) < 0.01, "prop position to a centimetre")
		check(got.basis.get_rotation_quaternion().angle_to(tilt.basis.get_rotation_quaternion()) < 0.002, "prop rotation survives")


func _rules(blocks: Dictionary) -> SocialRules:
	return SocialRules.new(func(a, b): return blocks.has("%d>%d" % [a, b]) or blocks.has("%d>%d" % [b, a]),
		func(_a): return [2, 3])


func test_social_request_flow() -> void:
	var s := _rules({})
	check(rpcs(s.request(1, 2, "talk", 0.0, 9.0, false), 1) == ["notice:too_far"], "too far is refused")
	var fx := s.request(1, 2, "talk", 0.0, 3.0, false)
	check(rpcs(fx, 1) == ["s_interaction_result"] and fx[0].args[1] == "sent", "requester told it was sent")
	check(rpcs(fx, 2) == ["s_interaction_incoming"], "target sees the request")
	var req: int = fx[0].args[0]
	check(rpcs(s.request(1, 3, "talk", 0.5, 3.0, false), 1) == ["notice:request_pending"], "one outgoing request at a time")
	check(s.respond(2, req, false, 1.0).is_empty(), "decline sends nothing yet")
	check(s.update(10.0, func(_a, _b): return 1.0).is_empty(), "nothing happens before timeout")
	fx = s.update(21.0, func(_a, _b): return 1.0)
	check(rpcs(fx, 1) == ["s_interaction_result"] and fx[0].args[1] == "no_response", "decline looks like silence")
	check(rpcs(fx, 2) == ["s_interaction_result"], "target prompt is closed")
	check(rpcs(s.request(1, 2, "talk", 22.0, 3.0, false), 1) == ["s_interaction_result"], "can ask again later")
	s.update(43.0, func(_a, _b): return 1.0)  # ignored: second refusal
	s.request(1, 2, "talk", 44.0, 3.0, false)
	s.update(65.0, func(_a, _b): return 1.0)  # third refusal
	check(rpcs(s.request(1, 2, "talk", 70.0, 3.0, false), 1) == ["notice:cooldown"], "long cooldown after 3 refusals")
	check(rpcs(s.request(1, 2, "talk", 126.0, 3.0, false), 1) == ["s_interaction_result"], "long cooldown ends")

	var quick := _rules({})
	var qreq: int = quick.request(1, 2, "talk", 0.0, 3.0, false)[0].args[0]
	quick.respond(2, qreq, true, 1.0)
	quick.close_conversation(1, 2, "left")
	check(rpcs(quick.request(1, 2, "talk", 3.0, 3.0, false), 1) == ["notice:cooldown"], "same-target cooldown")
	check(rpcs(quick.request(1, 2, "talk", 6.0, 3.0, false), 1) == ["s_interaction_result"], "same-target cooldown ends")


func test_social_conversation() -> void:
	var s := _rules({})
	var req: int = s.request(1, 2, "talk", 0.0, 3.0, false)[0].args[0]
	check(s.respond(3, req, true, 1.0).is_empty(), "only the target can answer")
	var fx := s.respond(2, req, true, 1.0)
	check(rpcs(fx, 1) == ["s_interaction_result", "s_conversation_open"], "requester learns of accept")
	check(rpcs(fx, 2) == ["s_conversation_open"], "target joins conversation")
	fx = s.chat(1, "  merhaba\u0007 ", 2.0)
	check(rpcs(fx, 1) == ["s_chat"] and rpcs(fx, 2) == ["s_chat"], "chat reaches both")
	check(fx[0].args[1] == "merhaba", "control characters stripped")
	check(rpcs(s.chat(3, "hey", 2.0), 3) == ["notice:not_in_conversation"], "strangers cannot text")
	check(rpcs(s.chat(1, "x".repeat(500), 3.0), 2) == ["s_chat"], "long message delivered")
	check(s.recent_lines(1, 2).back().text.length() == Protocol.CHAT_MAX_LEN, "long message truncated")
	var limited := false
	for i in 10:
		if rpcs(s.chat(1, "spam", 4.0), 1) == ["notice:rate_limited"]:
			limited = true
	check(limited, "chat is rate limited")
	check(rpcs(s.emote(1, "wave", 5.0), 2) == ["s_emote"], "emote reaches nearby")
	check(s.emote(1, "wave", 5.2).is_empty(), "emote cooldown")
	check(s.emote(1, "dance", 9.0).is_empty(), "unknown emote ignored")
	fx = s.update(10.0, func(_a, _b): return 31.0)
	check(rpcs(fx, 1) == ["s_conversation_close"] and rpcs(fx, 2) == ["s_conversation_close"], "walking away ends it")
	check(not s.in_conversation(1, 2), "conversation gone")


func test_social_blocks() -> void:
	var blocks := {"2>1": true}  # 2 blocked 1
	var s := _rules(blocks)
	var fx := s.request(1, 2, "talk", 0.0, 3.0, false)
	check(rpcs(fx, 1) == ["s_interaction_result"], "blocked requester still sees 'sent'")
	check(rpcs(fx, 2).is_empty(), "blocker never sees the request")
	fx = s.update(21.0, func(_a, _b): return 1.0)
	check(rpcs(fx, 1) == ["s_interaction_result"] and rpcs(fx, 2).is_empty(), "silent expiry")
	check(rpcs(s.request(2, 1, "talk", 30.0, 3.0, true), 2) == ["notice:you_blocked"], "blocker cannot request")
	check(not rpcs(s.emote(1, "wave", 40.0), 2).has("s_emote"), "blocked players miss emotes")
	var s2 := _rules({})
	var req: int = s2.request(1, 2, "talk", 0.0, 3.0, false)[0].args[0]
	s2.respond(2, req, true, 1.0)
	fx = s2.on_block(2, 1)
	check(not s2.in_conversation(1, 2), "block ends conversation")
	check(rpcs(fx, 2).has("notice:blocked"), "blocker gets confirmation")
	fx = s2.on_disconnect(1)
	check(fx.is_empty(), "nothing left to clean up")


func test_store() -> void:
	var dir := "user://test_store_%d" % Time.get_ticks_usec()
	var store := ServerStore.new(dir)
	var id := "0123456789abcdef0123456789abcdef"
	var secret := "ab".repeat(32)
	check(store.authenticate(id, secret, "Test"), "first use registers")
	check(not store.authenticate(id, "cd".repeat(32), "Test"), "wrong secret refused")
	check(not store.authenticate("short", secret, "Test"), "malformed id refused")
	store.update_profile(id, "Test", AvatarSpec.defaults())
	store.save_location(id, "zone_a", 3, Vector3(1, 0, 2), 0.5, PackedFloat64Array([41.0, 29.0]))
	store.block(id, "fedcba9876543210fedcba9876543210")
	store.flush()
	var reloaded := ServerStore.new(dir)
	check(reloaded.authenticate(id, secret, "Test"), "secret survives reload")
	check(reloaded.blocked_by(id).has("fedcba9876543210fedcba9876543210"), "block survives reload")
	check(reloaded.last_location(id, "zone_a", 3).local_z == 2.0, "location survives reload")
	check(reloaded.last_location(id, "zone_a", 4).is_empty(), "location ignored for another zone version")
	var other := "fedcba9876543210fedcba9876543210"
	reloaded.authenticate(other, "ef".repeat(32), "Öteki")
	var listed := reloaded.blocked_list(id)
	check(listed.size() == 1 and listed[0].account == other and listed[0].name == "Öteki", "blocked list names the blocked account")
	check(reloaded.unblock(id, other), "unblock lifts the block")
	check(not reloaded.unblock(id, other), "second unblock is a no-op")
	check(ServerStore.new(dir).blocked_by(id).is_empty(), "unblock survives reload")
	for f in DirAccess.get_files_at(dir):
		DirAccess.remove_absolute(dir.path_join(f))
	DirAccess.remove_absolute(dir)


func test_spawn_picker() -> void:
	near(SpawnPicker.proximity_term(Vector3.ZERO, [Vector3(60, 0, 0)]), 1.0, 0.001, "meetable distance scores 1")
	near(SpawnPicker.proximity_term(Vector3.ZERO, [Vector3(1, 0, 0)]), 1.0 / 15.0, 0.001, "too close scores low")
	check(SpawnPicker.proximity_term(Vector3.ZERO, [Vector3(400, 0, 0)]) == 0.0, "far away scores 0")
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var picker := SpawnPicker.new(zone)
	var other := ZoneData.to_godot(float(zone.spawn_points[5].e), float(zone.spawn_points[5].n))
	var close_count := 0
	for i in 20:
		if picker.pick("social", [other]).distance_to(other) < 150.0:
			close_count += 1
	check(close_count >= 15, "social spawns land near the active player (%d/20)" % close_count)


func test_zone_load() -> void:
	var grid := ZoneData.load_zone("test_grid_001")
	check(grid != null and grid.buildings.size() == 96, "synthetic zone loads")
	var kadikoy := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	check(kadikoy != null and kadikoy.buildings.size() > 500, "Kadıköy zone loads")
	check(kadikoy.display_name == "Kadıköy, İstanbul", "zone has a display name")
	check(kadikoy.attribution_text().contains("OpenStreetMap"), "OSM attribution present")
	var geo := kadikoy.to_geo(Vector3.ZERO)
	near(geo[0], kadikoy.origin_lat, 1e-9, "origin latitude")
	var north := kadikoy.to_geo(ZoneData.to_godot(0.0, 100.0))
	near((north[0] - kadikoy.origin_lat) * 111000.0, 100.0, 0.5, "100 m north is ~0.0009 degrees")
	var east := kadikoy.to_geo(ZoneData.to_godot(0.37, 0.0))
	check(east[1] > kadikoy.origin_lon, "centimetre-scale longitude changes survive")
	var named := ""
	for p in kadikoy.spawn_points:
		if str(p.street) != "":
			named = kadikoy.nearest_street(ZoneData.to_godot(float(p.e), float(p.n)))
			break
	check(named != "", "nearest street found for a spawn point")
	check(ZoneData.load_zone("does_not_exist") == null, "missing zone returns null")


# --- physics -----------------------------------------------------------------

func _grid_world() -> Array:
	var zone := ZoneData.load_zone("test_grid_001")
	var holder := Node3D.new()
	add_child(holder)
	WorldBuilder.build(zone, holder, false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	return [zone, holder]


func test_world_collision() -> void:
	var made: Array = await _grid_world()
	var zone: ZoneData = made[0]
	var holder: Node3D = made[1]
	var b: Dictionary = zone.buildings[0]
	var poly := WorldBuilder.footprint_xz(b.footprint)
	var center := Vector2.ZERO
	for p in poly:
		center += p
	center /= poly.size()
	var space := holder.get_world_3d().direct_space_state
	var hit := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(center.x, 100, center.y), Vector3(center.x, -10, center.y)))
	check(not hit.is_empty(), "ray hits building")
	if not hit.is_empty():
		near(hit.position.y, float(b.height), 0.05, "roof collision at building height")
	var street := ZoneData.to_godot(float(zone.roads[0].points[0][0]), 0.0)  # mid-street, away from zone walls
	hit = space.intersect_ray(PhysicsRayQueryParameters3D.create(street + Vector3(0, 50, 0), street + Vector3(0, -5, 0)))
	check(not hit.is_empty() and absf(hit.position.y) < 0.01, "street ground at y=0")
	holder.queue_free()


func test_motor_walks_and_is_blocked() -> void:
	var made: Array = await _grid_world()
	var zone: ZoneData = made[0]
	var holder: Node3D = made[1]
	var body := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(body)
	# Open street: walk north along the first north-south street.
	var start := ZoneData.to_godot(float(zone.roads[0].points[0][0]), -40.0, 0.05)
	body.global_position = start
	await get_tree().physics_frame
	for i in Protocol.TICK_RATE:
		await get_tree().physics_frame
		PlayerMotor.step(body, SnapshotCodec.quantize_input(i + 1, 0, 1, 0.0, 0, 0))
	var walked := start.distance_to(body.global_position)
	check(walked > Protocol.WALK_SPEED * 0.8 and walked < Protocol.WALK_SPEED + 0.01, "one second of walking covers ~walk speed (%.2f m)" % walked)
	check(PlayerMotor.is_grounded(body), "standing on the ground")

	# Walk east into the west wall of a building.
	var b: Dictionary = zone.buildings[0]
	var poly := WorldBuilder.footprint_xz(b.footprint)
	var min_x := INF
	var mid_z := 0.0
	for p in poly:
		min_x = minf(min_x, p.x)
		mid_z += p.y / poly.size()
	body.global_position = Vector3(min_x - 2.0, 0.05, mid_z)
	body.velocity = Vector3.ZERO
	for i in Protocol.TICK_RATE * 2:
		await get_tree().physics_frame
		PlayerMotor.step(body, SnapshotCodec.quantize_input(100 + i, 0, 1, -PI / 2.0, 0, PlayerMotor.BUTTON_SPRINT))
	check(body.global_position.x < min_x, "building wall stops the player (x=%.2f wall=%.2f)" % [body.global_position.x, min_x])
	check(body.global_position.x > min_x - 1.0, "player actually reached the wall")
	holder.queue_free()


## Client-side reconciliation replays several inputs inside one physics
## frame. That must land exactly where tick-by-tick simulation lands.
func test_replay_matches_realtime() -> void:
	var made: Array = await _grid_world()
	var zone: ZoneData = made[0]
	var holder: Node3D = made[1]
	var start := ZoneData.to_godot(float(zone.roads[0].points[0][0]), -60.0, 0.05)
	var inputs := []
	for i in 60:
		var jump := PlayerMotor.BUTTON_JUMP if i == 10 or i == 35 else 0
		inputs.append(SnapshotCodec.quantize_input(i + 1, sin(i * 0.2), 1.0, 0.3 * sin(i * 0.1), 0, jump))

	var realtime := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(realtime)
	realtime.global_position = start
	var checkpoint := {}
	await get_tree().physics_frame
	for i in inputs.size():
		await get_tree().physics_frame
		PlayerMotor.step(realtime, inputs[i])
		if i == 19:
			checkpoint = {"pos": realtime.global_position, "vel": realtime.velocity}

	var replay := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(replay)
	await get_tree().physics_frame
	await get_tree().physics_frame
	replay.global_position = checkpoint.pos
	replay.velocity = checkpoint.vel
	for i in range(20, inputs.size()):
		PlayerMotor.step(replay, inputs[i])
	var diff := realtime.global_position.distance_to(replay.global_position)
	check(diff < 0.001, "replay matches realtime simulation (diff %.5f m)" % diff)
	check(realtime.global_position.distance_to(start) > 3.0, "the test actually moved")
	holder.queue_free()


## The client predicts in its own physics world; the server simulates in
## another one that also holds every other player. Same inputs must give the
## same path in both, including sliding along walls and jumping at corners.
func test_client_and_server_worlds_agree() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var worlds := []
	for i in 2:
		var vp := SubViewport.new()
		vp.own_world_3d = true
		vp.disable_3d = false
		add_child(vp)
		var holder := Node3D.new()
		vp.add_child(holder)
		WorldBuilder.build(zone, holder, false)
		worlds.append(holder)
	# The "server" world also contains other players moving around.
	var crowd := []
	for i in 10:
		var other := PlayerMotor.make_body(AvatarSpec.defaults())
		worlds[1].add_child(other)
		var sp: Dictionary = zone.spawn_points[i]
		other.global_position = zone.ground(float(sp.e), float(sp.n), 0.05)
		crowd.append(other)
	await get_tree().physics_frame
	await get_tree().physics_frame

	var rng := RandomNumberGenerator.new()
	var worst := 0.0
	var diverged_at := -1
	for trial in 6:
		rng.seed = 1000 + trial
		var sp: Dictionary = zone.spawn_points[trial * 7]
		var bodies := []
		for w in worlds:
			var b := PlayerMotor.make_body(AvatarSpec.defaults())
			w.add_child(b)
			b.global_position = zone.ground(float(sp.e), float(sp.n), 0.05)
			bodies.append(b)
		await get_tree().physics_frame
		var heading := rng.randf() * TAU
		for t in 240:
			if t % 25 == 0:
				heading += rng.randf_range(-2.0, 2.0)
			var jump := PlayerMotor.BUTTON_JUMP if rng.randf() < 0.04 else 0
			var inp := SnapshotCodec.quantize_input(t + 1, rng.randf_range(-0.5, 0.5), 1.0, heading, 0, jump | PlayerMotor.BUTTON_SPRINT)
			await get_tree().physics_frame
			for c in crowd:
				PlayerMotor.step(c, SnapshotCodec.quantize_input(t + 1, 0, 1, t * 0.05, 0, 0))
			for b in bodies:
				PlayerMotor.step(b, inp)
			var d: float = bodies[0].global_position.distance_to(bodies[1].global_position)
			if d > worst:
				worst = d
			if d > 0.001 and diverged_at < 0:
				diverged_at = trial * 1000 + t
		for b in bodies:
			b.queue_free()
	check(worst < 0.001, "client and server worlds agree (worst %.4f m, first divergence trial*1000+tick=%d)" % [worst, diverged_at])
	for w in worlds:
		w.get_parent().queue_free()



func _box_collider(parent: Node3D, size: Vector3, center: Vector3) -> void:
	var body := StaticBody3D.new()
	body.collision_layer = Protocol.LAYER_WORLD
	var cs := CollisionShape3D.new()
	var shape := BoxShape3D.new()
	shape.size = size
	cs.shape = shape
	body.add_child(cs)
	parent.add_child(body)
	body.global_position = center


## Kerb-high ledges are walked onto; anything taller is a wall.
func test_step_up() -> void:
	var made: Array = await _grid_world()
	var zone: ZoneData = made[0]
	var holder: Node3D = made[1]
	var x := float(zone.roads[0].points[0][0])
	_box_collider(holder, Vector3(3, 0.25, 3), Vector3(x, 0.125, 30.0))  # a tram platform
	_box_collider(holder, Vector3(3, 0.6, 3), Vector3(x, 0.3, 50.0))  # a low wall
	await get_tree().physics_frame
	var body := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(body)
	body.global_position = Vector3(x, 0.05, 36.0)
	await get_tree().physics_frame
	var stepped := false
	for i in Protocol.TICK_RATE * 2:
		await get_tree().physics_frame
		if PlayerMotor.step(body, SnapshotCodec.quantize_input(i + 1, 0, 1, 0.0, 0, 0)) & PlayerMotor.EVENT_STEPPED:
			stepped = true
	check(stepped, "walking into a 25 cm platform steps up")
	near(body.global_position.y, 0.25, 0.04, "standing on the platform")
	body.global_position = Vector3(x, 0.05, 56.0)
	body.velocity = Vector3.ZERO
	for i in Protocol.TICK_RATE * 2:
		await get_tree().physics_frame
		PlayerMotor.step(body, SnapshotCodec.quantize_input(100 + i, 0, 1, 0.0, 0, 0))
	check(body.global_position.y < 0.1 and body.global_position.z > 51.4, "a 60 cm wall is not climbed (y=%.2f z=%.2f)" % [body.global_position.y, body.global_position.z])
	holder.queue_free()


## A moving tram throws a player standing on its track sideways, the same
## way every time; a stopped one is a wall.
func test_tram_shoves_and_blocks() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var holder := Node3D.new()
	add_child(holder)
	WorldBuilder.build(zone, holder, false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var net := zone.transit
	var line: TransitNetwork.TransitLine = null
	for l: TransitNetwork.TransitLine in net.lines:
		if not l.loop and line == null:
			line = l
	check(line != null, "a shuttle line to test with")
	if line == null:
		return
	# A moment when vehicle 0 runs at full speed well inside the zone.
	var t0 := -1.0
	var t := 0.0
	while t < line.cycle and t0 < 0.0:
		var st := line.state(0, t)
		var ahead := line.track_point(float(st.s) + int(st.dir) * 20.0, int(st.dir))
		if not st.dwelling and float(st.speed) > line.speed * 0.9 and absf(ahead.x) < 200.0 and absf(ahead.y) < 200.0:
			t0 = t
		t += 0.5
	check(t0 >= 0.0, "found a tram at speed")
	var st0 := line.state(0, t0)
	var dir: int = st0.dir
	var front := float(st0.s) + dir * (12.4 + 4.0)
	var en := line.track_point(front, dir)
	var tick0 := roundi(t0 / Protocol.DT)
	var finals := []
	var hits := 0
	for run in 2:
		var body := PlayerMotor.make_body(AvatarSpec.defaults())
		holder.add_child(body)
		body.global_position = zone.ground(en.x, en.y, 0.05)
		await get_tree().physics_frame
		for k in 75:
			var inp := SnapshotCodec.quantize_input(k + 1, 0, 0, 0.0, 0, 0, tick0 + k)
			if PlayerMotor.step(body, inp, net) & PlayerMotor.EVENT_TRAM_HIT:
				hits += 1
		finals.append(body.global_position)
		# Nowhere near the inside of a tram afterwards.
		var p := Vector2(body.global_position.x, body.global_position.z)
		for box in net.boxes_near(tick0 + 75, p, 20.0):
			var a: Vector2 = box[1]
			var d: Vector2 = p - (box[0] as Vector2)
			var inside := absf(d.dot(a)) < float(box[2]) and absf(d.dot(Vector2(-a.y, a.x))) < float(box[3])
			check(not inside, "run %d: player is not left inside a tram" % run)
		body.queue_free()
	check(hits >= 2, "the tram hit the player in both runs (%d hit ticks)" % hits)
	check((finals[0] as Vector3).distance_to(finals[1]) < 0.001, "tram collisions are deterministic")
	var side := (finals[0] as Vector3) - TransitNetwork.en_to_godot(en, 0.0)
	check(Vector2(side.x, side.z).length() > 1.2, "shoved off the track (%.2f m)" % Vector2(side.x, side.z).length())

	# A tram waiting at a stop: walking into its side stops you at its skin.
	var dwell_t := -1.0
	t = 0.0
	while t < line.cycle and dwell_t < 0.0:
		var st := line.state(0, t)
		if st.dwelling and line.stops[int(st.stop)].in_zone and float(st.leg_left) > 4.0 and not line.is_terminus(int(st.stop)):
			dwell_t = t
		t += 0.5
	if dwell_t >= 0.0:
		var st := line.state(0, dwell_t)
		var h: Vector2 = st.heading
		var right := Vector2(h.y, -h.x)
		var start_en: Vector2 = (st.pos as Vector2) + right * 3.2
		var body := PlayerMotor.make_body(AvatarSpec.defaults())
		holder.add_child(body)
		body.global_position = zone.ground(start_en.x, start_en.y, 0.05)
		await get_tree().physics_frame
		var toward := (st.pos as Vector2) - start_en
		var heading := atan2(-toward.x, toward.y)
		var tick := roundi(dwell_t / Protocol.DT)
		for k in 45:
			PlayerMotor.step(body, SnapshotCodec.quantize_input(k + 1, 0, 1, heading, 0, 0, tick + k), net)
		var gap := ZoneData.to_en(body.global_position).distance_to(st.pos)
		check(gap > TransitNetwork.CAR_HALF_WIDTH + 0.2, "a stopped tram is solid (%.2f m from its centre line)" % gap)
		body.queue_free()
	holder.queue_free()


## Loose props: laid out the same way every time, kicked by a running
## player, pushed by trams, reported while moving.
func test_props() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var layout := PropLayout.for_zone(zone)
	var kinds := {}
	for p in layout.props:
		kinds[p.kind] = int(kinds.get(p.kind, 0)) + 1
	check(kinds.get("ball", 0) >= 3 and kinds.get("bin", 0) >= 10 and kinds.get("chair", 0) >= 10,
		"zone has balls, bins and café chairs (%s)" % [kinds])
	var again := PropLayout.new(zone)
	check(again.props.size() == layout.props.size() and (again.props[-1].pos as Vector3).is_equal_approx(layout.props[-1].pos),
		"prop layout is deterministic")
	var vp := SubViewport.new()
	vp.own_world_3d = true
	add_child(vp)
	var holder := Node3D.new()
	vp.add_child(holder)
	WorldBuilder.build(zone, holder, false)
	var world := PropWorld.new()
	holder.add_child(world)
	world.setup(zone)
	for i in 3:
		await get_tree().physics_frame
	# Run into the first ball from 3 m away.
	var ball_id := -1
	for p in layout.props:
		if p.kind == "ball" and ball_id < 0:
			ball_id = int(p.id)
	var ball: RigidBody3D = world.bodies[ball_id]
	var home := ball.global_position
	var pl := ZoneServer.Player.new()
	pl.body = PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(pl.body)
	# Take a run-up from a side with nothing in the way (park trees, benches).
	var space := holder.get_world_3d().direct_space_state
	var approach := 0.0
	for turn in 16:
		var a := turn * TAU / 16.0
		var clear := true
		for h: float in [0.25, 0.9]:
			var from := home + Vector3(sin(a), 0, cos(a)) * 3.5 + Vector3(0, h, 0)
			var to := home + Vector3(0, h, 0) - Vector3(sin(a), 0, cos(a)) * 1.0
			for side: float in [-0.35, 0.35]:
				var off := Vector3(cos(a), 0, -sin(a)) * side
				if not space.intersect_ray(PhysicsRayQueryParameters3D.create(from + off, to + off, Protocol.LAYER_WORLD)).is_empty():
					clear = false
		if clear:
			approach = a
			break
	var start := home + Vector3(sin(approach), 0, cos(approach)) * 3.5 + Vector3(0, -PropWorld.BALL_RADIUS + 0.05, 0)
	pl.body.global_position = start
	pl.buttons = PlayerMotor.BUTTON_SPRINT
	await get_tree().physics_frame
	var moving_seen := false
	for k in 60:
		await get_tree().physics_frame
		PlayerMotor.step(pl.body, SnapshotCodec.quantize_input(k + 1, 0, 1, approach, 0, PlayerMotor.BUTTON_SPRINT))

		world.push_from_players([pl])
		world.track(k, [pl])
		if not world.moving_poses(k).is_empty():
			moving_seen = true

	var moved := ball.global_position.distance_to(home)
	check(moved > 2.0, "a running player kicks the ball (%.1f m)" % moved)
	check(moving_seen, "a moving prop is reported for snapshots")
	check(world.displaced_poses().size() >= 1, "displaced props are remembered for joiners")
	vp.queue_free()


## The real lie of the land: the collider is exactly where Terrain.height()
## says, buildings stand on it, and a player can walk uphill.
func test_terrain() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var t := zone.terrain
	check(not t.flat and t.high - t.low > 10.0, "Kadıköy has real relief (%.1f m)" % (t.high - t.low))
	near(t.height(-t.half, -t.half), t.heights[0], 0.001, "height() hits the north-west sample")
	var vp := SubViewport.new()
	vp.own_world_3d = true
	add_child(vp)
	var holder := Node3D.new()
	vp.add_child(holder)
	WorldBuilder.build(zone, holder, false)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := holder.get_world_3d().direct_space_state
	var rng := RandomNumberGenerator.new()
	rng.seed = 5
	var worst := 0.0
	var probes := 0
	for k in 60:
		var x := rng.randf_range(-240.0, 240.0)
		var z := rng.randf_range(-240.0, 240.0)
		var ray := PhysicsRayQueryParameters3D.create(Vector3(x, 200, z), Vector3(x, -50, z), Protocol.LAYER_WORLD)
		var hit := space.intersect_ray(ray)
		# Only where nothing stands on the ground (buildings, cars...).
		if hit.is_empty() or absf(hit.position.y - t.height(x, z)) > 0.5:
			continue
		probes += 1
		worst = maxf(worst, absf(hit.position.y - t.height(x, z)))
	check(probes > 15 and worst < 0.02, "ground collider matches height() (%d probes, worst %.3f m)" % [probes, worst])
	var b: Dictionary = zone.buildings[10]
	var poly := WorldBuilder.footprint_xz(b.footprint)
	var c := Vector2.ZERO
	for p in poly:
		c += p
	c /= poly.size()
	var roof := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(c.x, 300, c.y), Vector3(c.x, -50, c.y), Protocol.LAYER_WORLD))
	if Geometry2D.is_point_in_polygon(c, poly) and not roof.is_empty():
		near(roof.position.y, t.ground_under(poly) + float(b.height), 0.05, "roof stands on the building's ground")
	# Walk up the steepest nearby slope for three seconds.
	var start := Vector2(-150, 40)
	var up := Vector2(t.height(start.x + 1, start.y) - t.height(start.x - 1, start.y), t.height(start.x, start.y + 1) - t.height(start.x, start.y - 1))
	var body := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(body)
	body.global_position = t.on_ground(start, 0.05)
	await get_tree().physics_frame
	var yaw := atan2(-up.x, -up.y)
	for k in 90:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(k + 1, 0, 1, yaw, 0, 0))
	var climbed := body.global_position.y - t.height(start.x, start.y)
	var ground_gap := body.global_position.y - t.height(body.global_position.x, body.global_position.z)
	check(up.length() < 0.01 or climbed > 0.05, "walking uphill gains height (%.2f m)" % climbed)
	check(absf(ground_gap) < 0.1, "feet stay on the ground on a slope (%.3f m)" % ground_gap)
	vp.queue_free()


## Ambient pedestrians: plenty of them, on pavements (not in buildings),
## moving smoothly, the same for everyone.
func test_crowd() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var crowd := Crowd.for_zone(zone)
	check(crowd.walkers.size() >= 60, "crowd has walkers (%d)" % crowd.walkers.size())
	var streets := StreetLayout.for_zone(zone)
	var inside := 0
	var worst_jump := 0.0
	for w: Crowd.Walker in crowd.walkers:
		var prev: Vector2 = w.pose(1000.0)[0]
		for k in 40:
			var pose := w.pose(1000.0 + k * 0.5)
			var p: Vector2 = pose[0]
			worst_jump = maxf(worst_jump, p.distance_to(prev))
			prev = p
			if streets.building_clearance(Vector2(p.x, -p.y)) < 0.0:
				inside += 1
	check(worst_jump < Crowd.WALK_MAX * 0.5 + 1.5, "walkers move smoothly (worst %.2f m per 0.5 s)" % worst_jump)
	check(inside < crowd.walkers.size() * 2, "walkers stay out of buildings (%d samples inside)" % inside)
	var again := Crowd.new(zone)
	check((again.walkers[5].pose(77.0)[0] as Vector2).is_equal_approx(crowd.walkers[5].pose(77.0)[0]), "crowd is deterministic")
	print("crowd sample: %s %s" % [crowd.walkers[0].pose(1000.0), crowd.walkers[1].pose(1000.0)])


# --- transit and routing --------------------------------------------------------

func test_transit_network() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var net := zone.transit
	check(net.lines.size() >= 3, "Kadıköy has the real T3 plus generated lines (%d)" % net.lines.size())
	var t3: TransitNetwork.TransitLine = null
	for line: TransitNetwork.TransitLine in net.lines:
		if line.id == "T3":
			t3 = line
	check(t3 != null and t3.loop and t3.source == "osm", "T3 is a real one-way loop")
	if t3:
		near(t3.length, 2609.0, 30.0, "T3 loop length is the real one")
		var names := []
		for st in t3.stops:
			if st.in_zone:
				names.append(st.name)
		check(names == ["Altıyol", "Bahariye"], "T3 stops inside the zone: %s" % [names])
		check(t3.reachable(names.size() - 1 + t3.stops.find(t3.stops.filter(func(x): return x.name == "Altıyol")[0]), 1).is_empty(),
			"riders cannot stay on past Bahariye, where T3 leaves the zone")


func test_transit_timetable() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	for line: TransitNetwork.TransitLine in zone.transit.lines:
		for v in line.vehicles:
			var worst := 0.0
			var prev: Vector2 = line.state(v, 0.0).pos
			var t := 0.0
			while t < line.cycle + 1.0:
				t += 0.1
				var st := line.state(v, t)
				var jump := prev.distance_to(st.pos)
				if not st.dwelling:
					worst = maxf(worst, jump)
				prev = st.pos
			# Outside a bend the offset track is a little longer, so allow some
			# speed-up there; what must never happen is a jump.
			check(worst < line.speed * 0.1 * 2.2 + 0.3, "%s vehicle %d moves continuously (worst %.2f m per 0.1 s)" % [line.id, v, worst])
		for i in line.stops.size():
			if not line.stops[i].in_zone:
				continue
			for dir in ([1] if line.loop else [1, -1]):
				var dep := line.departure_after(i, dir, 1000.0)
				if dep.is_empty():
					continue
				var at := line.state(int(dep.vehicle), float(dep.depart) - 0.05)
				check(at.dwelling and int(at.stop) == i, "%s: departure_after finds a vehicle at stop %d" % [line.id, i])
				for j in line.reachable(i, dir):
					var arrive := float(dep.depart) + line.ride_time(i, j, dir)
					var there := line.state(int(dep.vehicle), arrive + 0.05)
					check(there.dwelling and int(there.stop) == j, "%s: ride %d->%d arrives on time" % [line.id, i, j])
				var board := zone.transit.boardable_near(line.platform(i, dir), float(dep.arrive) + 1.0)
				if line.continues_in_zone(i, dir):
					check(not board.is_empty() and int(board.line) == line.index, "%s: tram at stop %d is boardable from the platform" % [line.id, i])


func test_walking_routes() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var graph := zone.road_graph()
	check(graph.nodes.size() > 200, "walking graph built (%d nodes)" % graph.nodes.size())
	var a := Vector2(float(zone.spawn_points[0].e), float(zone.spawn_points[0].n))
	var b := Vector2(float(zone.spawn_points[40].e), float(zone.spawn_points[40].n))
	var path := graph.path_to(graph.search(a), b)
	var metres := RoadGraph.length_of(path)
	check(path[0] == a and path[path.size() - 1] == b, "route starts and ends where asked")
	check(metres >= a.distance_to(b) - 0.01 and metres < a.distance_to(b) * 3.0 + 50.0,
		"route length is sensible (%.0f m for %.0f m straight)" % [metres, a.distance_to(b)])
	near(graph.cost_to(graph.search(a), b), metres, 0.5, "cost matches path length")


func test_route_prefers_tram() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var graph := zone.road_graph()
	var found := {}
	var slower_tram_plans := 0
	for line: TransitNetwork.TransitLine in zone.transit.lines:
		for i in line.stops.size():
			if not line.stops[i].in_zone:
				continue
			for dir in ([1] if line.loop else [1, -1]):
				for j in line.reachable(i, dir):
					var start := line.platform(i, dir) + Vector2(2, 2)
					var goal := line.platform(j, dir) + Vector2(2, 2)
					var dep := line.departure_after(i, dir, 700.0)
					var plan := RoutePlanner.plan(graph, zone.transit, start, goal, float(dep.depart) - 20.0, Protocol.WALK_SPEED)
					var tram_legs: Array = plan.legs.filter(func(leg): return leg.type == "tram")
					if not tram_legs.is_empty():
						if float(plan.total) >= float(plan.walk_total):
							slower_tram_plans += 1
						if found.is_empty():
							found = {"plan": plan, "line": line}
	check(not found.is_empty(), "some trips in Kadıköy are faster by tram")
	check(slower_tram_plans == 0, "the planner never picks a tram that is slower than walking")
	if found.is_empty():
		return
	var plan: Dictionary = found.plan
	var types := []
	for leg in plan.legs:
		types.append(leg.type)
	check(types == ["walk", "tram", "walk"], "tram plans are walk - tram - walk (%s)" % [types])
	var tram: Dictionary = plan.legs[1]
	var line: TransitNetwork.TransitLine = found.line
	var there := line.state(int(tram.vehicle), float(tram.arrive) + 0.05)
	check(there.dwelling and int(there.stop) == int(tram.to), "planned vehicle really arrives at the alighting stop")
	var walk_in: Dictionary = plan.legs[0]
	check(float(walk_in.seconds) + 4.0 <= float(tram.depart) - (float(tram.depart) - 20.0) + 25.0,
		"the plan leaves time to reach the stop")
