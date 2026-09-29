extends Node
## Headless test suite: godot --headless --path game -- --test
## Exits with code 1 if any check fails.

var _checks := 0
var _failures: Array = []
var _test := ""


func _ready() -> void:
	var tests := [
		test_avatar_sanitize, test_names, test_input_codec, test_input_world_tick, test_snapshot_codec,
		test_social_request_flow, test_social_conversation, test_social_blocks, test_social_circle, test_social_kinds,
		test_groups, test_group_limits, test_group_chat_and_disconnect, test_rps_rules, test_rps_match, test_slap_rules, test_slap_match,
		test_store, test_spawn_picker, test_zone_load,
		test_world_collision, test_motor_walks_and_is_blocked, test_replay_matches_realtime,
		test_client_and_server_worlds_agree, test_step_up, test_tram_shoves_and_blocks, test_props, test_crowd,
		test_crowd_view_pool, test_terrain, test_bench_sitting, test_knockdown, test_stamina, test_limp, test_ball_kick, test_poser_arm,
		test_coastline, test_coast_sea_blocking, test_weather_wave_mapping, test_tree_road_grid,
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
	# Newer fields: unknown styles fall back, the old "cap" hairstyle becomes a cap.
	var b := AvatarSpec.sanitize({"appearance": {"hair": "cap", "beard": "wizard", "eyes": "green"},
		"clothing": {"shoes": "skates", "pattern": "stripes"}, "accessories": {"glasses": "monocle", "bag": "tote"}})
	check(b.accessories.headwear == "cap" and b.appearance.hair == "short", "legacy cap hair becomes headwear")
	check(b.appearance.beard == "none" and b.clothing.shoes == "sneakers", "unknown beard/shoes fall back")
	check(b.appearance.eyes == "green" and b.clothing.pattern == "stripes" and b.accessories.bag == "tote", "known options kept")
	check(b.accessories.glasses == "none", "unknown glasses fall back")
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	var r := AvatarSpec.random(rng)
	check(r == AvatarSpec.sanitize(r), "random avatars are already sanitized")
	# Changing avatars resizes the capsule, but only within the gameplay clamp.
	var body := PlayerMotor.make_body(a)
	var tall := AvatarSpec.defaults()
	tall.body.height = 1.0
	tall.body.weight = 1.0
	PlayerMotor.fit_capsule(body, tall)
	var shape: CapsuleShape3D = body.get_node("Capsule").shape
	near(shape.height, AvatarSpec.GAMEPLAY_HEIGHT_MAX, 0.001, "capsule height follows the new avatar")
	near(shape.radius, AvatarSpec.RADIUS_MAX, 0.001, "capsule radius clamped")
	near(body.get_node("Capsule").position.y, shape.height / 2.0, 0.001, "capsule stands on the feet")
	body.free()


func test_names() -> void:
	check(AvatarSpec.sanitize_name("Ay") == "", "too short")
	check(AvatarSpec.sanitize_name("Ayşe Yılmaz") == "Ayşe Yılmaz", "Turkish letters allowed")
	check(AvatarSpec.sanitize_name("  Ali    Veli ") == "Ali Veli", "whitespace collapsed")
	check(AvatarSpec.sanitize_name("<script>") == "", "markup rejected")
	check(AvatarSpec.sanitize_name("x".repeat(25)) == "", "too long")
	check(AvatarSpec.sanitize_name(42) == "", "non-string rejected")
	# Server addresses pasted into the menu (the phone link works in the app too).
	check(Net.normalize_address(" https://a-b.trycloudflare.com/ ") == "wss://a-b.trycloudflare.com/game", "tunnel link -> wss")
	check(Net.normalize_address("a-b.trycloudflare.com") == "wss://a-b.trycloudflare.com/game", "bare tunnel host -> wss")
	check(Net.normalize_address("http://192.168.1.5:8080") == "ws://192.168.1.5:8080/game", "LAN page -> ws")
	check(Net.normalize_address("192.168.1.5:7000") == "192.168.1.5:7000", "host:port stays ENet")


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
	var state := {"stamina": 1234, "knock": 50, "winded": true}
	var data := SnapshotCodec.encode_snapshot(99, 42, Vector3(1, 2, 3), Vector3(0.5, -1, 0), state, entities)
	check(data.size() == 38 + 2 * SnapshotCodec.ENTITY_BYTES + 2, "snapshot size is compact")
	var snap := SnapshotCodec.decode_snapshot(data)
	check(snap.tick == 99 and snap.ack == 42, "header survives")
	check(snap.self_pos == Vector3(1, 2, 3), "self position survives")
	check(snap.self_state == state, "own stamina, knock and winded survive (%s)" % [snap.get("self_state")])
	check(snap.entities.size() == 2, "entities survive")
	if snap.entities.size() == 2:
		check(snap.entities[1].id == 2000000000, "large peer id survives")
		check(snap.entities[0].pos.is_equal_approx(Vector3(1.5, 0.0, -20.25)), "entity position survives")
		near(snap.entities[0].speed, 4.2, 0.05, "speed")
	check(SnapshotCodec.decode_snapshot(data.slice(0, data.size() - 1)).is_empty(), "truncated snapshot rejected")
	var tilt := Transform3D(Basis(Vector3(1, 0, 1).normalized(), 0.8), Vector3(12.34, 0.56, -200.1))
	var props := SnapshotCodec.encode_props([[7, tilt], [300, Transform3D.IDENTITY]])
	check(props.size() == 2 + 2 * SnapshotCodec.PROP_BYTES, "props are 16 bytes each")
	var with_props := SnapshotCodec.decode_snapshot(SnapshotCodec.encode_snapshot(5, 1, Vector3.ZERO, Vector3.ZERO, {}, [], props))
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
	check(s.emote(1, "cartwheel", 9.0).is_empty(), "unknown emote ignored")
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


## Three or more people talking form one circle: whoever joins a talk is also
## talking with everybody in it, so every line reaches everybody.
func test_social_circle() -> void:
	var s := _rules({})
	var r1: int = s.request(1, 2, "talk", 0.0, 3.0, false)[0].args[0]
	s.respond(2, r1, true, 1.0)
	var r2: int = s.request(3, 2, "talk", 10.0, 3.0, false)[0].args[0]
	var fx := s.respond(2, r2, true, 11.0)
	check(s.in_conversation(3, 2) and s.in_conversation(3, 1) and s.in_conversation(1, 2), "the newcomer joins the whole circle")
	check(rpcs(fx, 1) == ["s_conversation_open"], "the first talker is told about the newcomer")
	check(rpcs(fx, 3) == ["s_interaction_result", "s_conversation_open", "s_conversation_open"], "the newcomer meets everyone")
	fx = s.chat(3, "selam", 12.0)
	check(rpcs(fx, 1) == ["s_chat"] and rpcs(fx, 2) == ["s_chat"] and rpcs(fx, 3) == ["s_chat"], "a line from the newcomer reaches the whole circle")
	fx = s.chat(1, "merhaba", 12.0)
	check(rpcs(fx, 2) == ["s_chat"] and rpcs(fx, 3) == ["s_chat"], "and one from the first talker reaches everyone")
	# A fourth person who is blocked by one member joins the others only.
	var blocked := _rules({"1>4": true})
	var b1: int = blocked.request(1, 2, "talk", 0.0, 3.0, false)[0].args[0]
	blocked.respond(2, b1, true, 1.0)
	var b2: int = blocked.request(3, 2, "talk", 10.0, 3.0, false)[0].args[0]
	blocked.respond(2, b2, true, 11.0)
	var b3: int = blocked.request(4, 2, "talk", 20.0, 3.0, false)[0].args[0]
	blocked.respond(2, b3, true, 21.0)
	check(blocked.in_conversation(4, 2) and blocked.in_conversation(4, 3) and not blocked.in_conversation(4, 1), "a blocked person is not pulled into the block")
	# Walking out of the circle ends every link of that person, the rest keep talking.
	fx = s.leave_all(3)
	check(not s.in_conversation(3, 1) and not s.in_conversation(3, 2) and s.in_conversation(1, 2), "leaving ends only your own links")
	check(rpcs(fx, 3) == ["s_conversation_close", "s_conversation_close"] and rpcs(fx, 1) == ["s_conversation_close"], "everyone concerned is told")
	check(s.leave_all(3).is_empty(), "leaving twice does nothing")
	# Drifting away from one member of the circle only ends that link.
	var far := _rules({})
	var f1: int = far.request(1, 2, "talk", 0.0, 3.0, false)[0].args[0]
	far.respond(2, f1, true, 1.0)
	var f2: int = far.request(3, 2, "talk", 10.0, 3.0, false)[0].args[0]
	far.respond(2, f2, true, 11.0)
	far.update(12.0, func(a, b): return 31.0 if (a == 1 and b == 3) else 2.0)
	check(not far.in_conversation(1, 3) and far.in_conversation(2, 3) and far.in_conversation(1, 2), "distance ends only the far pair")
	# A disconnect closes every conversation of that person.
	fx = s.on_disconnect(1)
	check(not s.in_conversation(1, 2) and rpcs(fx, 2) == ["s_conversation_close"], "disconnect leaves the circle")


## Group invitations and minigame challenges ride on the request flow.
func test_social_kinds() -> void:
	var s := _rules({})
	var fx := s.request(1, 2, "rps", 0.0, 3.0, false)
	check(rpcs(fx, 2) == ["s_interaction_incoming"] and fx[1].args[2] == "rps", "the target is told which kind it is")
	var req: int = fx[0].args[0]
	fx = s.respond(2, req, true, 1.0)
	check(rpcs(fx, 1) == ["s_interaction_result"] and rpcs(fx, 2).is_empty(), "an accepted game opens no conversation")
	var acc := s.take_accepted()
	check(acc.size() == 1 and acc[0].kind == "rps" and acc[0].from == 1 and acc[0].to == 2, "the accept is queued for the server")
	check(s.take_accepted().is_empty(), "the queue is drained")
	check(not s.in_conversation(1, 2), "no conversation from a game")
	check(s.request(1, 2, "duel", 10.0, 3.0, false).is_empty(), "unknown kinds are ignored")
	# Talking to someone does not stop you challenging them, and a decline stays silent.
	var t: int = s.request(1, 2, "talk", 20.0, 3.0, false)[0].args[0]
	s.respond(2, t, true, 21.0)
	fx = s.request(1, 2, "slap", 30.0, 3.0, false)
	check(rpcs(fx, 2) == ["s_interaction_incoming"], "a game request during a talk is fine")
	s.respond(2, fx[0].args[0], false, 31.0)
	check(s.take_accepted().is_empty(), "a declined challenge queues nothing")
	check(rpcs(s.request(1, 2, "talk", 32.0, 3.0, false), 1) == ["notice:already_talking"], "talk is still refused inside a conversation")


func _groups() -> GroupRules:
	return GroupRules.new(func(p): return "P%d" % p, func() -> Array: return [1, 2, 3, 4])


func test_groups() -> void:
	var g := _groups()
	var fx := g.create(1)
	check(rpcs(fx, 1) == ["notice:group_created", "s_group_state", "s_group_marks"], "creating tells the creator")
	check(g.groups[g.group_of(1)].name == "Grup 1", "the default name is Grup 1")
	check(g.color_of(1) == 0, "the first group takes the first colour")
	check(rpcs(fx, 4) == ["s_group_marks"], "everyone learns the colour marks")
	check(rpcs(g.create(1), 1) == ["notice:already_in_group"], "one group at a time")
	# Inviting: the request flow decides, the group is made on accept.
	check(g.invite_problem(1, 1) == "bad_target", "no inviting yourself")
	check(g.invite_problem(1, 2) == "", "a free player can be invited")
	fx = g.accept_invite(1, 2)
	check(g.same_group(1, 2) and g.members_of(1) == [1, 2], "the invited player joins")
	check(rpcs(fx, 2).has("notice:group_joined_you") and rpcs(fx, 1).has("notice:group_joined"), "both sides are told")
	var state: Dictionary = fx.filter(func(e): return e.to == 1 and e.rpc == "s_group_state")[0].args[0]
	check(state.members.size() == 2 and state.name == "Grup 1" and state.color == 0, "the state lists the members")
	check(g.invite_problem(1, 2) == "already_in_group", "already a member")
	# A second group gets another colour and the next default name.
	g.create(3)
	check(g.color_of(3) == 1 and g.groups[g.group_of(3)].name == "Grup 2", "a second group is Grup 2 in the next colour")
	check(g.invite_problem(1, 3) == "target_in_group", "cannot invite someone in another group")
	# The inviter without a group gets one made on accept.
	var fresh := _groups()
	fresh.accept_invite(1, 2)
	check(fresh.same_group(1, 2) and fresh.groups.size() == 1, "accepting an invite from a lone player makes the group")
	# Leaving: the rest are told, the last one out deletes the group and frees the colour.
	fx = g.leave(2)
	check(rpcs(fx, 2).has("notice:group_left_you") and rpcs(fx, 1).has("notice:group_left"), "leaving is announced")
	check(fx.filter(func(e): return e.to == 2 and e.rpc == "s_group_state")[0].args[0].is_empty(), "the leaver gets an empty state")
	check(g.group_of(2) == 0 and g.members_of(1) == [1], "the group shrank")
	check(rpcs(g.leave(2), 2) == ["notice:not_in_group"], "leaving without a group is refused")
	g.leave(1)
	check(g.groups.size() == 1 and g.group_of(1) == 0, "the last member leaving deletes the group")
	check(g.free_color() == 0, "its colour is free again")
	g.create(4)
	check(g.color_of(4) == 0 and g.color_of(3) == 1, "a new group reuses the freed colour, colours stay unique")
	# Custom names are cleaned and cut.
	var named := _groups()
	named.create(1, "  Kadıköy\u0007 Ekibi çok uzun bir isim  ")
	var nm: String = named.groups[named.group_of(1)].name
	check(nm.length() <= Protocol.GROUP_NAME_MAX and nm.begins_with("Kadıköy Ekibi") and not nm.contains("\u0007"), "a custom name is sanitized and cut")


func test_group_limits() -> void:
	# At most ten groups (one per colour), each in its own colour.
	var g := GroupRules.new(func(p): return "P%d" % p, func() -> Array: return [])
	var colours := {}
	for i in Protocol.GROUP_COLORS.size():
		g.create(100 + i)
		colours[g.color_of(100 + i)] = true
	check(colours.size() == Protocol.GROUP_COLORS.size(), "ten groups wear ten different colours")
	check(rpcs(g.create(200), 200) == ["notice:groups_full"], "an eleventh group is refused")
	check(g.invite_problem(200, 201) == "groups_full", "so is inviting when no colour is left")
	check(g.invite_problem(100, 201) == "", "but an existing group can still recruit")
	g.leave(103)
	check(g.free_color() == 3, "leaving frees a colour")
	check(rpcs(g.create(200), 200).has("s_group_state"), "and then a new group can be made")
	# At most eight members.
	var big := _groups()
	big.create(1)
	for p in range(2, 9):
		big.accept_invite(1, p)
	check(big.members_of(1).size() == Protocol.GROUP_MAX_MEMBERS, "a group holds eight")
	check(big.invite_problem(1, 9) == "group_full", "the ninth is refused up front")
	var fx := big.accept_invite(1, 9)
	check(not big.same_group(1, 9) and rpcs(fx, 9) == ["notice:group_full"], "and refused again on accept")


func test_group_chat_and_disconnect() -> void:
	var g := _groups()
	g.create(1)
	g.accept_invite(1, 2)
	g.create(3)
	var fx := g.chat(1, "  selam  ", 1.0)
	check(rpcs(fx, 1) == ["s_group_chat"] and rpcs(fx, 2) == ["s_group_chat"], "group chat reaches every member, sender included")
	check(rpcs(fx, 3).is_empty() and rpcs(fx, 4).is_empty(), "and nobody outside the group")
	check(fx[0].args[0] == 1 and fx[0].args[1] == "selam", "it carries the sender and the cleaned text")
	check(rpcs(g.chat(4, "hey", 1.0), 4) == ["notice:not_in_group"], "no group, no group chat")
	check(g.chat(1, "   ", 1.0).is_empty(), "empty text is ignored")
	var limited := false
	for i in 12:
		if rpcs(g.chat(1, "spam", 2.0), 1) == ["notice:rate_limited"]:
			limited = true
	check(limited, "group chat is rate limited")
	# Group chat is its own channel: it never produces conversation traffic.
	var s := _rules({})
	check(rpcs(s.chat(1, "hey", 0.0), 1) == ["notice:not_in_conversation"], "group members are not in a conversation")
	# Marks: [peer, colour, ...] for people in groups only.
	check(g.marks() == [1, 0, 2, 0, 3, 1] or g.marks().size() == 6, "marks list every grouped player with the group colour")
	check(rpcs(g.marks_for(4), 4) == ["s_group_marks"], "a newcomer gets the marks")
	# A disconnect leaves the group; the leaver is not sent anything.
	fx = g.on_disconnect(2)
	check(rpcs(fx, 2).is_empty() and rpcs(fx, 1).has("notice:group_left") and not g.same_group(1, 2), "a disconnect removes the member")
	check(fx.filter(func(e): return e.to == 1 and e.rpc == "s_group_state")[0].args[0].members.size() == 1, "the rest see the new list")
	check(g.on_disconnect(2).is_empty(), "disconnecting twice does nothing")
	g.on_disconnect(1)
	check(g.groups.size() == 1, "the last disconnect deletes the group")
	check(g.on_disconnect(4).is_empty(), "a player without a group leaves quietly")


func _games(rtts := {}) -> GameRules:
	var g := GameRules.new(func(_p): return [], func(_a, _b): return false, func(p): return "P%d" % p,
		func(p): return float(rtts.get(p, 0.0)))
	g.rng.seed = 11
	return g


static func _ev_of(effects: Array, to: int, ev: String) -> Dictionary:
	for e in effects:
		if e.to == to and e.rpc == "s_game" and e.args[0].ev == ev:
			return e.args[0]
	return {}


## Emote kinds `emoter` made in the effects (as the emoter saw them).
static func _emotes_of(effects: Array, emoter: int) -> Array:
	var out := []
	for e in effects:
		if e.to == emoter and e.rpc == "s_emote" and e.args[0] == emoter:
			out.append(e.args[1])
	return out


## Steps `g` in 50 ms ticks (clock[0] is the time) until an event `until_ev`
## shows up or `limit` seconds pass; returns every effect on the way.
func _play(g: GameRules, clock: Array, until_ev: String, dist := 2.0, limit := 30.0) -> Array:
	var seen := []
	var stop: float = clock[0] + limit
	while clock[0] < stop:
		clock[0] += 0.05
		var fx := g.update(clock[0], func(_a, _b): return dist)
		seen.append_array(fx)
		for e in fx:
			if e.rpc == "s_game" and e.args[0].ev == until_ev:
				return seen
	return seen


func test_rps_rules() -> void:
	# 0 rock, 1 paper, 2 scissors, -1 no pick.
	var table := [[0, 0, 0], [1, 1, 0], [2, 2, 0], [1, 0, 1], [2, 1, 1], [0, 2, 1], [0, 1, -1], [1, 2, -1], [2, 0, -1],
		[0, -1, 1], [-1, 2, -1], [-1, -1, 0]]
	for row in table:
		check(GameRules.rps_winner(row[0], row[1]) == row[2], "rps %d vs %d -> %d" % [row[0], row[1], row[2]])


func test_rps_match() -> void:
	var g := _games()
	var clock := [0.0]
	var fx := g.start("rps", 1, 2, 0.0)
	var start := _ev_of(fx, 1, "start")
	check(start.opp == 2 and start.kind == "rps" and start.wins == Protocol.RPS_WINS and _ev_of(fx, 2, "start").opp == 1, "both players get the start event")
	var id: int = start["match"]
	check(g.in_match(1) and g.in_match(2) and g.start_problem(1, 3) == "game_busy" and g.start_problem(3, 2) == "game_busy", "players in a match are busy")
	check(rpcs(g.start("rps", 1, 3, 0.0), 3) == ["notice:game_busy"], "a busy player cannot start another")
	check(g.input(1, id, 0, 0.5).is_empty(), "a pick before the round starts is ignored")
	fx = _play(g, clock, "round")
	check(_ev_of(fx, 1, "round").score == [0, 0] and _emotes_of(fx, 1) == ["shake"] and _emotes_of(fx, 2) == ["shake"], "the round starts with both fists shaking")
	var round_start: float = clock[0]
	# Picks: bad ones are ignored, a good one locks in and cannot change.
	check(g.input(1, id, 7, clock[0]).is_empty() and g.input(1, id, -1, clock[0]).is_empty(), "invalid picks are ignored")
	check(g.input(9, id, 0, clock[0]).is_empty() and g.input(1, id + 5, 0, clock[0]).is_empty(), "strangers and wrong matches are ignored")
	fx = g.input(1, id, 1, clock[0])  # paper
	check(_ev_of(fx, 1, "picked").value == 1 and not _ev_of(fx, 2, "opp_ready").is_empty(), "a pick is acknowledged, the opponent sees only that you are ready")
	check(g.input(1, id, 2, clock[0]).is_empty(), "a pick cannot be changed")
	g.input(2, id, 0, clock[0])  # rock
	# Both picked, but the reveal waits for the end of the countdown.
	fx = _play(g, clock, "reveal")
	check(clock[0] - round_start >= 3 * Protocol.RPS_COUNT_STEP - 0.001, "the reveal comes after the countdown")
	check(not _ev_of(fx, 1, "count").is_empty() and not _ev_of(fx, 1, "go").is_empty(), "the countdown and the shoot cue were sent")
	var r1 := _ev_of(fx, 1, "reveal")
	var r2 := _ev_of(fx, 2, "reveal")
	check(r1.winner == "you" and r1.you == 1 and r1.opp == 0 and r1.score == [1, 0], "paper beats rock: player 1 wins the round")
	check(r2.winner == "opp" and r2.you == 0 and r2.opp == 1 and r2.score == [0, 1], "player 2 sees the same round from its side")
	check(_emotes_of(fx, 1) == ["paper"] and _emotes_of(fx, 2) == ["rock"], "the hand signs are played")
	# A draw replays the round and does not count.
	fx = _play(g, clock, "round")
	check(_ev_of(fx, 1, "round").round == 2, "the next round starts after the pause")
	g.input(1, id, 2, clock[0])
	g.input(2, id, 2, clock[0])
	fx = _play(g, clock, "reveal")
	check(_ev_of(fx, 1, "reveal").winner == "draw" and _ev_of(fx, 1, "reveal").score == [1, 0], "same hands draw")
	fx = _play(g, clock, "round")
	check(_ev_of(fx, 1, "round").round == 3 and _ev_of(fx, 1, "round").score == [1, 0], "a draw is replayed")
	# Player 2 says nothing; the picking window closes and player 1 takes the round and the match.
	g.input(1, id, 0, clock[0])
	fx = _play(g, clock, "reveal")
	var late := _ev_of(fx, 1, "reveal")
	check(late.winner == "you" and late.opp == -1 and late.score == [2, 0], "no pick loses to a pick")
	fx = _play(g, clock, "end")
	var end := _ev_of(fx, 1, "end")
	check(end.winner == "you" and end.score == [2, 0] and _ev_of(fx, 2, "end").winner == "opp", "first to two wins the match")
	check(not g.in_match(1) and not g.in_match(2) and not g.active(), "the match is cleaned up")

	# Nobody picks at all: draws until the round cap, then a draw.
	var idle := _games()
	var c2 := [0.0]
	idle.start("rps", 1, 2, 0.0)
	fx = _play(idle, c2, "end", 2.0, 80.0)
	var idle_end := _ev_of(fx, 1, "end")
	check(idle_end.winner == "none" and idle_end.score == [0, 0], "endless draws end as a draw")
	var rounds := 0
	for e in fx:
		if e.to == 1 and e.rpc == "s_game" and e.args[0].ev == "round":
			rounds += 1
	check(rounds == Protocol.RPS_MAX_ROUNDS, "a match is capped at %d rounds" % Protocol.RPS_MAX_ROUNDS)

	# Moving away cancels the match without a winner.
	var away := _games()
	var c3 := [0.0]
	away.start("rps", 1, 2, 0.0)
	fx = _play(away, c3, "end", Protocol.GAME_RANGE + 1.0, 5.0)
	check(_ev_of(fx, 1, "end").winner == "none" and _ev_of(fx, 1, "end").reason == "distance" and not away.active(), "walking out of range cancels")
	# So do quitting, blocking and disconnecting.
	var q := _games()
	q.start("rps", 1, 2, 0.0)
	fx = q.cancel(2, "quit")
	check(_ev_of(fx, 1, "end").reason == "quit" and _ev_of(fx, 1, "end").winner == "none" and not q.active(), "quitting ends it for both")
	check(q.cancel(2, "quit").is_empty(), "cancelling twice does nothing")
	q.start("rps", 1, 2, 0.0)
	check(q.on_block(3, 1).is_empty() and q.active(), "an unrelated block changes nothing")
	fx = q.on_block(2, 1)
	check(_ev_of(fx, 1, "end").reason == "ended" and not q.active(), "a block between the two ends the match")
	# A player who disappears from the world (distance INF) also ends it.
	q.start("rps", 1, 2, 0.0)
	fx = q.update(0.1, func(_a, _b): return INF)
	check(not q.active() and _ev_of(fx, 1, "end").reason == "distance", "a vanished player cancels")


func test_slap_rules() -> void:
	check(GameRules.slap_outcome(0.30, -1.0) == "top", "a slap nobody dodges lands")
	check(GameRules.slap_outcome(-1.0, 0.30) == "bottom", "pulling away when nobody slaps is a point for the one below")
	check(GameRules.slap_outcome(-1.0, -1.0) == "none", "nobody moving is no point")
	check(GameRules.slap_outcome(0.20, 0.30) == "top", "the faster top player hits")
	check(GameRules.slap_outcome(0.30, 0.20) == "bottom", "the faster player below escapes")
	check(GameRules.slap_outcome(0.30, 0.28) == "top", "a near tie goes to the top player")
	check(GameRules.slap_outcome(0.30, 0.30 - Protocol.SLAP_TIE - 0.01) == "bottom", "beyond the tie window the one below wins")


func _slap_round(g: GameRules, clock: Array, id: int, rt_a: float, rt_b: float) -> Array:
	## Plays one round to its reveal: presses at go + rt (negative: none).
	var seen := _play(g, clock, "go")
	var m := g.match_of(1)
	var go_time: float = m.go_time
	if rt_a >= 0.0:
		seen.append_array(g.input(1, id, 1, go_time + rt_a))
	if rt_b >= 0.0:
		seen.append_array(g.input(2, id, 1, go_time + rt_b))
	if _ev_of(seen, 1, "reveal").is_empty():
		seen.append_array(_play(g, clock, "reveal"))
	return seen


func test_slap_match() -> void:
	var g := _games()
	var clock := [0.0]
	var fx := g.start("slap", 1, 2, 0.0)
	var id: int = _ev_of(fx, 1, "start")["match"]
	check(_ev_of(fx, 1, "start").kind == "slap" and _ev_of(fx, 1, "start").wins == Protocol.SLAP_WINS, "the start event describes the game")
	check(g.input(1, id, 1, 0.3).is_empty(), "a press during the intro is ignored")
	fx = _play(g, clock, "round")
	check(_ev_of(fx, 1, "round").role == "top" and _ev_of(fx, 2, "round").role == "bottom", "player 1 starts on top")
	# Round 1: the one below jumps the gun and loses on the spot.
	fx = g.input(2, id, 1, clock[0] + 0.2)
	var fs := _ev_of(fx, 1, "reveal")
	check(fs.winner == "you" and fs.how == "false_start" and fs.score == [1, 0], "pressing before the cue loses the round")
	check(_ev_of(fx, 2, "reveal").false_start and not fs.false_start, "the offender is told it was a false start")
	check(g.input(1, id, 1, clock[0] + 0.3).is_empty(), "presses after the round is settled are ignored")
	# Round 2: roles swap, player 2 is on top and reacts faster than the one below.
	fx = _play(g, clock, "round")
	check(_ev_of(fx, 1, "round").role == "bottom" and _ev_of(fx, 2, "round").role == "top", "the roles swap every round")
	fx = _slap_round(g, clock, id, 0.25, 0.20)
	var r := _ev_of(fx, 2, "reveal")
	check(r.winner == "you" and r.how == "slapped" and r.score == [1, 1], "the faster top player slaps")
	check(_emotes_of(fx, 2) == ["slap"] and _emotes_of(fx, 1).is_empty(), "the slap is played by the top player only")
	# Round 3: player 1 is on top but the one below is clearly faster and pulls away.
	fx = _play(g, clock, "round")
	fx = _slap_round(g, clock, id, 0.30, 0.18)
	r = _ev_of(fx, 1, "reveal")
	check(r.winner == "opp" and r.how == "dodged" and r.score == [1, 2], "a clearly faster player below escapes")
	check(_emotes_of(fx, 1) == ["slap"] and _emotes_of(fx, 2) == ["dodge"], "the miss and the dodge are both played")
	# Round 4: player 2 on top, a near tie goes to the top player and wins them the match.
	fx = _play(g, clock, "round")
	fx = _slap_round(g, clock, id, 0.20, 0.21)
	check(_ev_of(fx, 2, "reveal").winner == "you" and _ev_of(fx, 2, "reveal").score == [3, 1], "a near tie favours the top player")
	fx = _play(g, clock, "end")
	check(_ev_of(fx, 2, "end").winner == "you" and _ev_of(fx, 1, "end").winner == "opp" and _ev_of(fx, 2, "end").score == [3, 1], "first to three wins the match")
	check(not g.active(), "and the match is over")

	# Nobody presses: no point. A lone press on top still lands once the window ends.
	var quiet := _games()
	var c2 := [0.0]
	var qid: int = _ev_of(quiet.start("slap", 1, 2, 0.0), 1, "start")["match"]
	_play(quiet, c2, "round")
	fx = _slap_round(quiet, c2, qid, -1.0, -1.0)
	check(_ev_of(fx, 1, "reveal").winner == "none" and _ev_of(fx, 1, "reveal").how == "none" and _ev_of(fx, 1, "reveal").score == [0, 0], "no one moving scores nothing")
	_play(quiet, c2, "round")
	fx = _slap_round(quiet, c2, qid, -1.0, 0.3)  # round 2: player 2 is on top and slaps alone
	check(_ev_of(fx, 2, "reveal").winner == "you" and _ev_of(fx, 2, "reveal").how == "slapped", "the top player who slaps alone scores")
	check(quiet.match_of(1).phase == "reveal", "the round is settled")

	# Timing rules: too fast is anticipation, double presses count once, the go cue is random.
	var t := _games()
	var c3 := [0.0]
	var tid: int = _ev_of(t.start("slap", 1, 2, 0.0), 1, "start")["match"]
	_play(t, c3, "round")
	_play(t, c3, "go")
	var go: float = t.match_of(1).go_time
	fx = t.input(1, tid, 1, go + 0.02)
	check(_ev_of(fx, 1, "reveal").false_start, "a reaction faster than a human can be is a false start")
	var t2 := _games()
	var c4 := [0.0]
	var t2id: int = _ev_of(t2.start("slap", 1, 2, 0.0), 1, "start")["match"]
	_play(t2, c4, "round")
	_play(t2, c4, "go")
	var go2: float = t2.match_of(1).go_time
	check(t2.input(1, t2id, 1, go2 + 0.3).is_empty(), "the first press waits for the other player or the window")
	check(t2.input(1, t2id, 1, go2 + 0.1).is_empty() and absf(float(t2.match_of(1).rt_a) - 0.3) < 0.001, "a second press does not replace the first")
	check(t2.input(9, t2id, 1, go2 + 0.1).is_empty(), "strangers cannot press")
	var delays := {}
	for seed_value in 6:
		var tg := _games()
		tg.rng.seed = seed_value + 100
		var cg := [0.0]
		tg.start("slap", 1, 2, 0.0)
		_play(tg, cg, "round")
		var began: float = cg[0]
		_play(tg, cg, "go")
		var wait: float = tg.match_of(1).go_time - began
		check(wait >= Protocol.SLAP_READY + Protocol.SLAP_DELAY_MIN - 0.06 and wait <= Protocol.SLAP_READY + Protocol.SLAP_DELAY_MAX + 0.06, "the cue comes %.2f s after the round starts (in range)" % wait)
		delays[snappedf(wait, 0.1)] = true
	check(delays.size() > 1, "the cue delay is random")

	# Latency: a player with a 200 ms round trip who reacted in 200 ms beats a
	# 0 ms player who reacted in 250 ms, although the message arrives later.
	var lag2 := _games({2: 0.2})
	var c6 := [0.0]
	var l2id: int = _ev_of(lag2.start("slap", 1, 2, 0.0), 1, "start")["match"]
	_play(lag2, c6, "round")
	# Player 1 (top) presses at 250 ms, player 2 (below) arrives at 400 ms = 200 ms + 200 ms trip.
	_play(lag2, c6, "go")
	var lgo: float = lag2.match_of(1).go_time
	lag2.input(1, l2id, 1, lgo + 0.25)
	fx = lag2.input(2, l2id, 1, lgo + 0.40)
	check(_ev_of(fx, 2, "reveal").winner == "you" and _ev_of(fx, 2, "reveal").how == "dodged", "latency is compensated: 200 ms + 200 ms trip beats 250 ms")
	check(_ev_of(fx, 2, "reveal").you_rt > 0.19 and _ev_of(fx, 2, "reveal").you_rt < 0.21, "the compensated time is what is reported")
	# A rtt bigger than the cap is capped, so a huge lag cannot buy a win.
	var huge := _games({2: 5.0})
	var c7 := [0.0]
	var hid: int = _ev_of(huge.start("slap", 1, 2, 0.0), 1, "start")["match"]
	_play(huge, c7, "round")
	_play(huge, c7, "go")
	var hgo: float = huge.match_of(1).go_time
	huge.input(1, hid, 1, hgo + 0.25)
	fx = huge.input(2, hid, 1, hgo + 0.9)
	check(_ev_of(fx, 1, "reveal").winner == "you", "the latency credit is capped")

	# Nobody presses through five rounds: a drawn match; leaving mid-match cancels.
	var draw := _games()
	var c8 := [0.0]
	draw.start("slap", 1, 2, 0.0)
	fx = _play(draw, c8, "end", 2.0, 120.0)
	check(_ev_of(fx, 1, "end").winner == "none" and _ev_of(fx, 1, "end").score == [0, 0], "five quiet rounds draw the match")
	var away := _games()
	var c9 := [0.0]
	away.start("slap", 1, 2, 0.0)
	fx = _play(away, c9, "end", Protocol.GAME_RANGE + 2.0, 5.0)
	check(_ev_of(fx, 2, "end").reason == "distance" and not away.active(), "out of range cancels a slap match too")


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
	near(reloaded.fitness(id, 0.35), 0.35, 0.0001, "fitness defaults")
	reloaded.set_fitness(id, 0.61)
	reloaded.set_injury(id, {"kind": "arm", "until": 1234.5, "treated": false})
	reloaded.flush()
	var again := ServerStore.new(dir)
	near(again.fitness(id, 0.35), 0.61, 0.0001, "fitness survives reload")
	check(again.injury(id).kind == "arm" and float(again.injury(id).until) == 1234.5, "injury survives reload")
	again.set_injury(id, {})
	check(again.injury(id).is_empty(), "healing clears the injury")
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
	var reach := zone.half_size() - 56.0
	var t0 := -1.0
	var t := 0.0
	while t < line.cycle and t0 < 0.0:
		var st := line.state(0, t)
		var ahead := line.track_point(float(st.s) + int(st.dir) * 20.0, int(st.dir))
		if not st.dwelling and float(st.speed) > line.speed * 0.9 and absf(ahead.x) < reach and absf(ahead.y) < reach:
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
	var hit_tick := -1
	var states := []  # run 0: [pos, vel, motor state] after each tick
	var final_state := {}
	for run in 2:
		var body := PlayerMotor.make_body(AvatarSpec.defaults())
		holder.add_child(body)
		body.global_position = zone.ground(en.x, en.y, 0.05)
		await get_tree().physics_frame
		for k in 75:
			var inp := SnapshotCodec.quantize_input(k + 1, 0, 0, 0.0, 0, 0, tick0 + k)
			if PlayerMotor.step(body, inp, net) & PlayerMotor.EVENT_TRAM_HIT:
				hits += 1
				if run == 0 and hit_tick < 0:
					hit_tick = k
					check(PlayerMotor.knock_ticks(body) == PlayerMotor.KNOCK_TICKS, "the hit knocks the player down")
					near(float(body.get_meta("hit_speed", 0.0)), float(st0.speed), 1.5, "the hit speed is recorded")
					var fling := Vector2(body.velocity.x, body.velocity.z).length()
					check(fling > 3.5 and body.velocity.y > 2.0, "flung along, sideways and up (%.1f m/s, up %.1f)" % [fling, body.velocity.y])
			if run == 0:
				states.append([body.global_position, body.velocity, PlayerMotor.motor_state(body)])
		finals.append(body.global_position)
		if run == 0:
			final_state = PlayerMotor.motor_state(body)
		# Nowhere near the inside of a tram afterwards.
		var p := Vector2(body.global_position.x, body.global_position.z)
		for box in net.boxes_near(tick0 + 75, p, 20.0):
			var a: Vector2 = box[1]
			var d: Vector2 = p - (box[0] as Vector2)
			var inside := absf(d.dot(a)) < float(box[2]) and absf(d.dot(Vector2(-a.y, a.x))) < float(box[3])
			check(not inside, "run %d: player is not left inside a tram" % run)
		body.queue_free()
	check(hits == 2, "the tram hit the player once in each run, not again while down (%d hits)" % hits)
	# A client that reconciles just before the hit replays it the same way.
	if hit_tick >= 3:
		var from := hit_tick - 3
		var replay := PlayerMotor.make_body(AvatarSpec.defaults())
		holder.add_child(replay)
		await get_tree().physics_frame
		replay.global_position = states[from][0]
		replay.velocity = states[from][1]
		PlayerMotor.apply_state(replay, states[from][2])
		var replay_hits := 0
		for k in range(from + 1, 75):
			if PlayerMotor.step(replay, SnapshotCodec.quantize_input(k + 1, 0, 0, 0.0, 0, 0, tick0 + k), net) & PlayerMotor.EVENT_TRAM_HIT:
				replay_hits += 1
		check(replay_hits == 1, "the replay sees the hit too")
		var diff := replay.global_position.distance_to(finals[0])
		check(diff < 0.001, "replaying a tram hit lands where the realtime run did (%.4f m)" % diff)
		check(PlayerMotor.motor_state(replay) == final_state, "and in the same state (%s vs %s)" % [PlayerMotor.motor_state(replay), final_state])
		replay.queue_free()
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
		for h: float in [0.35, 0.9]:
			var from := home + Vector3(sin(a), 0, cos(a)) * 3.5 + Vector3(0, h, 0)
			var to := home + Vector3(0, h, 0) - Vector3(sin(a), 0, cos(a)) * 1.0
			for side: float in [-0.35, 0.35]:
				var off := Vector3(cos(a), 0, -sin(a)) * side
				if not space.intersect_ray(PhysicsRayQueryParameters3D.create(from + off, to + off, Protocol.LAYER_WORLD)).is_empty():
					clear = false
		if clear:
			approach = a
			break
	var run_up := home + Vector3(sin(approach), 0, cos(approach)) * 3.5
	var start := zone.terrain.on_ground(Vector2(run_up.x, run_up.z), 0.05)
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


# --- coast and weather ---------------------------------------------------------------

## Trees keep off roads through a bucketed grid; it must agree with the
## plain test against every road segment.
func test_tree_road_grid() -> void:
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var mismatches := 0
	var on_road := 0
	var roads: Array = []
	for road in zone.roads:
		roads.append([WorldBuilder.footprint_xz(road.points), float(road.width) / 2.0 + 1.2])
	for k in 300:
		# Half the probes sit right beside a road so both answers occur.
		var p := Vector2(rng.randf_range(-800.0, 800.0), rng.randf_range(-800.0, 800.0))
		if k % 2 == 0:
			var pts: PackedVector2Array = roads[rng.randi() % roads.size()][0]
			p = pts[rng.randi() % pts.size()] + Vector2(rng.randf_range(-6.0, 6.0), rng.randf_range(-6.0, 6.0))
		var want := false
		for r in roads:
			var pts: PackedVector2Array = r[0]
			for i in pts.size() - 1:
				if p.distance_to(Geometry2D.get_closest_point_to_segment(p, pts[i], pts[i + 1])) < float(r[1]):
					want = true
					break
			if want:
				break
		if want:
			on_road += 1
		if WorldBuilder._on_road(zone, p) != want:
			mismatches += 1
	check(mismatches == 0, "road grid matches the brute-force test (%d mismatches of 300)" % mismatches)
	check(on_road > 30 and on_road < 270, "probes cover both answers (%d on a road)" % on_road)
	check(WorldBuilder.tree_points(zone) is Array and WorldBuilder.tree_points(zone).size() > 100, "trees are planted")


func test_coastline() -> void:
	var coast := Coast.from_zone({
		"sea_level": -1.6, "shore_height_m": 1.6,
		"land": [[[-10.0, -10.0], [10.0, -10.0], [10.0, 10.0], [-10.0, 10.0]]],
		"shore": [{"kind": "quay", "points": [[10.0, -10.0], [10.0, 10.0]]}],
		"piers": [{"id": "w1", "closed": false, "width": 3.0, "name": "Test İskelesi",
			"points": [[10.0, 0.0], [20.0, 0.0]]}],
		"ferry_terminals": [{"name": "Test İskele", "e": 20.0, "n": 0.0}],
	})
	check(coast != null, "coast block parses")
	near(coast.sea_level, -1.6, 0.001, "sea level read")
	check(coast.is_land(Vector2(0, 0)), "zone centre is land")
	check(not coast.is_land(Vector2(12, 12)), "outside the land square, still within the zone: sea")
	near(coast.distance_to_shore(Vector2(15, 0)), 5.0, 0.01, "distance to the east shore run")
	check(coast.piers.size() == 1 and str(coast.piers[0].name) == "Test İskelesi", "pier parsed with its name")
	check(coast.ferry_terminals.size() == 1 and (coast.ferry_terminals[0].pos as Vector2).is_equal_approx(Vector2(20, 0)),
		"ferry terminal position converted to Godot XZ")
	check(Coast.from_zone(null) == null, "zones without a coastline get null")


## The shore is a real, physical wall: a player (or here, a bare raycast)
## cannot cross from land into the sea.
func test_coast_sea_blocking() -> void:
	var zone := ZoneData.new()
	zone.size_m = 100.0
	zone.coast = Coast.from_zone({
		"sea_level": -1.6, "shore_height_m": 1.6,
		"land": [[[-10.0, -10.0], [10.0, -10.0], [10.0, 10.0], [-10.0, 10.0]]],
		"shore": [{"kind": "quay", "points": [[10.0, -10.0], [10.0, 10.0]]}],
		"piers": [], "ferry_terminals": [],
	})
	var holder := Node3D.new()
	add_child(holder)
	var sink := WorldBuilder._CollisionSink.new(holder)
	WorldBuilder._build_coast(zone, sink)
	await get_tree().physics_frame
	await get_tree().physics_frame
	var space := holder.get_world_3d().direct_space_state
	# The shore wall sits on the land square's east edge (x=10); a ray through
	# it at head height must be blocked.
	var blocked := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(5, 1.0, 0), Vector3(20, 1.0, 0)))
	check(not blocked.is_empty(), "shore wall blocks a ray from land out to sea")
	var clear := space.intersect_ray(PhysicsRayQueryParameters3D.create(Vector3(5, 1.0, 40), Vector3(6, 1.0, 40)))
	check(clear.is_empty(), "well away from the shore, nothing blocks")
	holder.queue_free()


func test_weather_wave_mapping() -> void:
	var marine := {"current": {"time": "2026-01-01T00:00", "wave_height": 0.85, "wave_direction": 210.0, "wave_period": 4.5}}
	var waves := WeatherService.parse_marine(marine)
	near(waves.wave_m, 0.85, 0.001, "marine wave height parsed")
	near(waves.wave_dir, 210.0, 0.001, "marine wave direction parsed")
	near(waves.wave_period, 4.5, 0.001, "marine wave period parsed")
	check(WeatherService.parse_marine({"current": {"no_wave": true}}).is_empty(), "malformed marine response yields nothing")
	check(WeatherService.parse_marine(null).is_empty(), "non-dictionary marine response yields nothing")
	var calm := WeatherService.estimate_wave(5.0)
	var stormy := WeatherService.estimate_wave(50.0)
	check(calm.wave_m < stormy.wave_m, "stronger wind estimates bigger waves")
	check(stormy.wave_m <= 1.6, "wave estimate stays clamped")
	# Offline presets (used when the marine fetch is unavailable) carry their
	# own plausible wave state too.
	for key in WeatherService.PRESETS:
		var preset: Dictionary = WeatherService.PRESETS[key]
		check(preset.has("wave_m") and float(preset.wave_m) > 0.0, "preset '%s' has a wave height" % key)
	var zone := ZoneData.new()
	zone.origin_lat = 40.98
	zone.origin_lon = 29.02
	var svc := WeatherService.new()
	svc.setup(zone, "storm")
	check(svc.current.wave_m == WeatherService.PRESETS.storm.wave_m, "preset mode uses the preset's own wave state")


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
	check(again.look(5) == crowd.look(5) and crowd.look(5) != crowd.look(6), "pedestrians look the same everywhere, and different from each other")
	check(AvatarSpec.sanitize(crowd.look(7)) == crowd.look(7), "pedestrian looks are valid avatars")
	print("crowd sample: %s %s" % [crowd.walkers[0].pose(1000.0), crowd.walkers[1].pose(1000.0)])


## The near/far split: nearest pedestrians get a pooled AvatarView, tied to
## graphics quality, without flicker when the camera moves a little. Reaches
## into CrowdView's private pooling state directly since it has no other
## public surface to probe from outside a running GameClient.
func test_crowd_view_pool() -> void:
	var prev_level := GraphicsQuality.level
	var zone := ZoneData.load_zone("tr_istanbul_kadikoy_001")
	var view := CrowdView.new()
	add_child(view)
	view.crowd = Crowd.for_zone(zone)
	view._count = mini(view.crowd.walkers.size(), 20)
	for i in view._count:
		view._last.append(Vector3(float(i) * 2.0, 0.0, 0.0))  # all within PEOPLE_RANGE
		view._slot_of.append(-1)

	GraphicsQuality.level = GraphicsQuality.LOW
	view._pick(Vector3.ZERO, Vector3(0, 0, -1))
	var n_low: int = CrowdView.PEOPLE_BY_QUALITY[GraphicsQuality.LOW]
	var pooled_low := 0
	for i in view._count:
		if view._slot_of[i] >= 0:
			pooled_low += 1
	check(pooled_low == n_low, "as many pedestrians pooled as LOW quality allows (%d of %d)" % [pooled_low, n_low])
	check(view._slot_of[0] >= 0, "the nearest pedestrian is drawn as a real avatar")
	check((view._slots[0] as CrowdView.Slot).tag.text == "NPC", "pooled pedestrians still carry the NPC tag")

	var kept: int = view._slot_of[0]
	view._pick(Vector3(2.0, 0, 0), Vector3(0, 0, -1))
	check(view._slot_of[0] == kept, "an already-pooled pedestrian keeps the same avatar (no flicker)")

	GraphicsQuality.level = GraphicsQuality.HIGH
	view._pick(Vector3.ZERO, Vector3(0, 0, -1))
	var n_high: int = CrowdView.PEOPLE_BY_QUALITY[GraphicsQuality.HIGH]
	var pooled_high := 0
	for i in view._count:
		if view._slot_of[i] >= 0:
			pooled_high += 1
	check(pooled_high > pooled_low, "higher graphics quality pools more pedestrians (%d > %d)" % [pooled_high, pooled_low])
	check(pooled_high == mini(n_high, view._count), "HIGH pools up to its own quality count (%d)" % pooled_high)

	GraphicsQuality.level = prev_level
	view.queue_free()


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
		# The enlarged zone (İskele to Moda) now holds the whole real loop.
		check(names.size() == t3.stops.size(), "every T3 stop is inside the zone (%d of %d)" % [names.size(), t3.stops.size()])
		var altiyol: int = t3.stops.find(t3.stops.filter(func(x): return x.name == "Altıyol")[0])
		check(t3.reachable(altiyol, 1).size() == t3.stops.size(), "riders can now ride the whole loop without leaving the zone")


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


func test_bench_sitting() -> void:
	var body := PlayerMotor.make_body(AvatarSpec.defaults())
	add_child(body)
	var bench := {"pos": Vector3(10, 2, 5), "yaw": 0.0}
	var origin := PlayerMotor.seat_origin(bench, 0)
	near(origin.z, 5.0 - 0.29, 0.001, "feet in front of the bench (it faces -Z)")
	PlayerMotor.sit(body, origin)
	for i in 10:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(i, 0, 0, 0.3, 0, 0))
	check(body.has_meta("seat") and body.global_position.is_equal_approx(origin), "seated body stays put (no gravity, no drift)")
	PlayerMotor.step(body, SnapshotCodec.quantize_input(11, 0, 1, 0, 0, 0))
	check(not body.has_meta("seat"), "moving stands up")
	check(body.global_position.distance_to(origin) > 0.0, "and walks off")
	body.free()


func _flat_speed(body: CharacterBody3D) -> float:
	return Vector2(body.velocity.x, body.velocity.z).length()


## Knocked down: input does nothing, the body slides to a stop, and after
## KNOCK_TICKS the player walks again.
func test_knockdown() -> void:
	var made: Array = await _grid_world()
	var zone: ZoneData = made[0]
	var holder: Node3D = made[1]
	var body := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(body)
	body.global_position = ZoneData.to_godot(float(zone.roads[0].points[0][0]), -60.0, 0.05)
	await get_tree().physics_frame
	for i in 5:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(i + 1, 0, 0, 0.0, 0, 0))
	PlayerMotor.apply_state(body, {"stamina": PlayerMotor.STAMINA_MAX, "knock": PlayerMotor.KNOCK_TICKS, "winded": false})
	body.velocity = Vector3(0, 0, -3.0)
	var all := PlayerMotor.BUTTON_JUMP | PlayerMotor.BUTTON_SPRINT
	for i in 10:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(10 + i, 1, 1, 0.0, 0, all))
	near(_flat_speed(body), 3.0 - PlayerMotor.KNOCK_FRICTION * 10.0 / Protocol.TICK_RATE, 0.05, "sliding friction while down")
	check(body.velocity.y <= 0.0 and PlayerMotor.is_grounded(body), "no jumping while knocked down")
	check(PlayerMotor.is_down(body), "still down after a third of a second")
	for i in PlayerMotor.KNOCK_TICKS - 11:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(20 + i, 1, 1, 0.0, 0, all))
	check(PlayerMotor.knock_ticks(body) == 1 and _flat_speed(body) < 0.01, "lying still until the last tick")
	check(not PlayerMotor.is_down(body), "getting up at the end")
	PlayerMotor.step(body, SnapshotCodec.quantize_input(200, 0, 1, 0.0, 0, 0))
	check(PlayerMotor.knock_ticks(body) == 0, "the knockdown ends")
	for i in 20:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(201 + i, 0, 1, 0.0, 0, 0))
	near(_flat_speed(body), Protocol.WALK_SPEED, 0.01, "walking again afterwards")
	holder.queue_free()


## Sprinting drains stamina (faster when unfit); at zero you are winded:
## no sprint and a slower walk until stamina is back to 30 %.
func test_stamina() -> void:
	check(PlayerMotor.sprint_drain(0.0) == 33 and PlayerMotor.sprint_drain(1.0) == 8, "10 s of sprinting unfit, 40 s fit (%d, %d)" % [
		PlayerMotor.sprint_drain(0.0), PlayerMotor.sprint_drain(1.0)])
	var made: Array = await _grid_world()
	var zone: ZoneData = made[0]
	var holder: Node3D = made[1]
	var body := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(body)
	body.global_position = ZoneData.to_godot(float(zone.roads[0].points[0][0]), -60.0, 0.05)
	body.set_meta("fitness", 0.0)
	await get_tree().physics_frame
	var sprint := PlayerMotor.BUTTON_SPRINT
	var events := 0
	for i in 30:
		events = PlayerMotor.step(body, SnapshotCodec.quantize_input(i + 1, 0, 1, 0.0, 0, sprint))
	check(events & PlayerMotor.EVENT_SPRINTED != 0, "sprinting is reported")
	check(int(body.get_meta("stamina")) == PlayerMotor.STAMINA_MAX - 30 * 33, "a second of sprinting costs a tenth (%d)" % body.get_meta("stamina"))
	near(_flat_speed(body), Protocol.SPRINT_SPEED, 0.01, "full sprint speed with breath left")
	PlayerMotor.apply_state(body, {"stamina": 200, "knock": 0, "winded": false})
	for i in 7:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(40 + i, 0, 1, 0.0, 0, sprint))
	check(int(body.get_meta("stamina")) == 0 and body.get_meta("winded"), "out of breath at zero")
	for i in 30:
		events = PlayerMotor.step(body, SnapshotCodec.quantize_input(50 + i, 0, 1, 0.0, 0, sprint))
	near(_flat_speed(body), Protocol.WALK_SPEED * PlayerMotor.WINDED_WALK, 0.01, "winded: no sprint, a slower walk")
	check(events & PlayerMotor.EVENT_SPRINTED == 0, "winded sprinting spends nothing")
	check(int(body.get_meta("stamina")) == 30 * PlayerMotor.RECOVER_MOVING, "breath comes back while walking")
	# Standing still refills faster; winded until 30 %.
	var ticks := 0
	while body.get_meta("winded") and ticks < 200:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(100 + ticks, 0, 0, 0.0, 0, sprint))
		ticks += 1
	var stamina := int(body.get_meta("stamina"))
	check(stamina >= PlayerMotor.WINDED_RECOVER and stamina < PlayerMotor.WINDED_RECOVER + PlayerMotor.RECOVER_IDLE,
		"winded until 30 %% (%d after %d ticks)" % [stamina, ticks])
	for i in 10:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(400 + i, 0, 1, 0.0, 0, sprint))
	near(_flat_speed(body), Protocol.SPRINT_SPEED, 0.01, "sprinting again once recovered")
	holder.queue_free()


## A leg in a cast: no sprint, no jump, a slow walk.
func test_limp() -> void:
	var made: Array = await _grid_world()
	var zone: ZoneData = made[0]
	var holder: Node3D = made[1]
	var body := PlayerMotor.make_body(AvatarSpec.defaults())
	holder.add_child(body)
	body.global_position = ZoneData.to_godot(float(zone.roads[0].points[0][0]), -60.0, 0.05)
	body.set_meta("limp", true)
	await get_tree().physics_frame
	var top := 0.0
	for i in 30:
		PlayerMotor.step(body, SnapshotCodec.quantize_input(i + 1, 0, 1, 0.0, 0, PlayerMotor.BUTTON_SPRINT | PlayerMotor.BUTTON_JUMP))
		top = maxf(top, body.velocity.y)
	near(_flat_speed(body), PlayerMotor.LIMP_SPEED, 0.01, "limping caps the speed")
	check(top <= 0.0, "no jumping on a broken leg")
	check(int(body.get_meta("stamina")) == PlayerMotor.STAMINA_MAX, "and no sprinting")
	holder.queue_free()


## The shared kick: a shot when running, a dribble when walking, a nudge
## standing still.
func test_ball_kick() -> void:
	var run := PropLayout.kick_velocity(Vector3(0, 0, -5.2), Vector3(0, 0, -1), true, false)
	near(Vector2(run.x, run.z).length(), 1.5 * 5.2 + 1.0, 0.01, "a running kick")
	near(run.y, 2.0 + 0.3 * 5.2, 0.01, "lifted")
	var walk := PropLayout.kick_velocity(Vector3(2.4, 0, 0), Vector3(1, 0, 1).normalized(), false, false)
	near(Vector2(walk.x, walk.z).length(), 1.15 * 2.4, 0.01, "a dribble")
	check(walk.y == 0.0 and walk.x > walk.z and walk.z > 0.0, "along the ground, mostly where you walk")
	var still := PropLayout.kick_velocity(Vector3.ZERO, Vector3(0, 0, 1), false, false)
	check(still.length() < 1.0 and still.z > 0.0, "a nudge standing still")


## The wave and sling reach the same absolute arm pose whatever the base
## animation (standing or sitting): the palm faces front when waving.
func test_poser_arm() -> void:
	var view := AvatarView.new()
	add_child(view)
	view.build(AvatarSpec.defaults())
	var sk: Skeleton3D = view.find_children("*", "Skeleton3D", true, false)[0]
	var poser: AvatarPoser = sk.find_children("*", "AvatarPoser", false, false)[0]
	var fore := sk.find_bone("lowerarm_r")
	var hand := sk.find_bone("hand_r")
	var results := []
	for sitting in [false, true]:
		view.sitting = sitting
		for k in 90:
			view.animate(0.0, 1.0 / 30.0)
		view.play_emote("wave")
		view.animate(0.0, 0.5)
		poser.wave_time = 0.0  # no swing: compare the pose itself
		await poser.modification_processed
		var chest := sk.get_bone_global_pose(sk.find_bone("spine_03")).basis.orthonormalized()
		var lean := chest * sk.get_bone_global_rest(sk.find_bone("spine_03")).basis.orthonormalized().inverse()
		var up := lean.inverse() * (sk.get_bone_global_pose(hand).origin - sk.get_bone_global_pose(fore).origin).normalized()
		results.append(up)
	check((results[0] as Vector3).y > 0.9 and (results[1] as Vector3).y > 0.9, "the forearm points up when waving (%s, %s)" % results)
	check((results[0] as Vector3).distance_to(results[1]) < 0.05, "same wave standing and sitting")
	view.queue_free()
