extends Node
## Entry point. User arguments come after "--" on the command line:
##   --server [--port=7000] [--transport=enet|ws] [--zone=ID] [--data-dir=PATH] [--cluster] [--quit-after=S]
##            [--weather=live|off|clear|cloudy|rain|storm|fog|snow]
##   --bot=social|wander|idle --connect=ADDRESS [--name=N] [--quit-after=S]
##   --connect=ADDRESS [--name=N] [--spawn=MODE] [--touch] [--time=HH:MM] [--screenshot=PNG] [--yaw=DEG] [--pitch=DEG]
## ADDRESS is host:port for ENet (UDP) or a ws:// / wss:// URL for WebSocket.
##   --test
## No arguments opens the menu.

var _current: Node = null


func _ready() -> void:
	var args := parse_args(OS.get_cmdline_user_args())
	if DisplayServer.get_name() == "headless":
		# Headless servers and bots would otherwise spin a full core each.
		Engine.max_fps = Protocol.TICK_RATE * 2
	elif args.has("screenshot") or args.has("perf"):
		# Tooling windows must not steal the keyboard or mouse from whoever
		# is using the machine.
		get_window().set_flag(Window.FLAG_NO_FOCUS, true)
		# Parked almost entirely off the right edge of the screen; the game
		# still renders there and screenshots read the viewport, not the screen.
		var usable := DisplayServer.screen_get_usable_rect()
		get_window().position = Vector2i(usable.end.x - 24, usable.end.y - get_window().size.y)
	elif DisplayServer.is_touchscreen_available() or args.has("touch"):
		# Phones: a smaller logical canvas makes text and buttons thumb-sized.
		get_window().content_scale_size = Vector2i(854, 480)
	if args.has("test"):
		_run_tests()
	elif args.has("server"):
		_start_server(args)
	elif args.has("connect"):
		_start_client_from_args(args)
	else:
		_show_menu("")
		if args.has("screenshot"):
			await get_tree().create_timer(float(args.get("screenshot-after", 2.0))).timeout
			await RenderingServer.frame_post_draw
			get_viewport().get_texture().get_image().save_png(str(args.screenshot))
			get_tree().quit()


static func parse_args(raw: PackedStringArray) -> Dictionary:
	var out := {}
	for arg in raw:
		if not arg.begins_with("--"):
			continue
		var parts := arg.substr(2).split("=", true, 1)
		out[parts[0]] = parts[1] if parts.size() > 1 else "true"
	return out


func _swap(node: Node) -> void:
	if _current:
		_current.queue_free()
	_current = node
	add_child(node)


# --- server ------------------------------------------------------------------

func _start_server(args: Dictionary) -> void:
	var server := ZoneServer.new()
	server.name = "ZoneServer"
	_swap(server)
	var err := server.setup({
		"port": int(args.get("port", Protocol.DEFAULT_PORT)),
		"transport": str(args.get("transport", "enet")),
		"zone": str(args.get("zone", Protocol.DEFAULT_ZONE)),
		"data_dir": str(args.get("data-dir", "user://server_data")),
		"cluster": args.has("cluster") or args.has("spawn-at"),
		"spawn_at": str(args.get("spawn-at", "")),
		"quit_after": float(args.get("quit-after", 0.0)),
		"weather": str(args.get("weather", "live")),
	})
	if err != OK:
		printerr("server failed to start: %s" % error_string(err))
		get_tree().quit(1)


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and _current is ZoneServer:
		_current.shutdown()


# --- client ------------------------------------------------------------------

func _show_menu(message: String) -> void:
	Input.mouse_mode = Input.MOUSE_MODE_VISIBLE
	var menu := MainMenu.new()
	_swap(menu)
	menu.setup(LocalProfile.load_settings(), message)
	menu.play_requested.connect(_on_play_requested)


func _on_play_requested(settings: Dictionary, host_locally: bool) -> void:
	var address := str(settings.server)
	if host_locally:
		address = "127.0.0.1:%d" % Protocol.DEFAULT_PORT
		Net.spawn_local_server(Protocol.DEFAULT_PORT, str(settings.zone))
		# Give the server a moment to load the zone before connecting.
		await get_tree().create_timer(2.0).timeout
	var identity := LocalProfile.load_identity()
	_start_game({
		"address": address, "name": settings.name, "avatar": settings.avatar,
		"spawn_mode": settings.spawn_mode, "mouse_sensitivity": settings.get("mouse_sensitivity", 0.0025),
		"quality": settings.get("quality", "auto"), "show_fps": settings.get("show_fps", false),
		"account_id": identity.account_id, "account_secret": identity.account_secret,
	})


func _start_client_from_args(args: Dictionary) -> void:
	var bot_mode := str(args.get("bot", ""))
	var display_name := str(args.get("name", "Bot%d" % (randi() % 10000) if bot_mode else ""))
	var identity := LocalProfile.new_identity() if bot_mode or args.has("fresh-identity") else LocalProfile.load_identity()
	var avatar: Dictionary = _random_avatar(hash(display_name)) if bot_mode else LocalProfile.load_settings().avatar
	if display_name.is_empty():
		display_name = str(LocalProfile.load_settings().name)
	var opts := {
		"address": str(args.connect), "name": display_name, "avatar": avatar, "touch": args.has("touch"),
		"spawn_mode": str(args.get("spawn", "social")), "bot": bot_mode,
		"account_id": identity.account_id, "account_secret": identity.account_secret,
		"quit_after": float(args.get("quit-after", 0.0)),
	}
	for key in ["screenshot", "screenshot-after", "yaw", "pitch", "time", "tram-shot", "open-map", "route-to", "perf", "quality", "block-test", "look-npc", "look-sign"]:
		if args.has(key):
			opts[key.replace("-", "_")] = args[key]
	_start_game(opts)


func _start_game(opts: Dictionary) -> void:
	var client := GameClient.new()
	client.name = "GameClient"
	_swap(client)
	client.finished.connect(_on_game_finished)
	client.start(opts)


func _on_game_finished(message: String) -> void:
	if str(_current.options.get("bot", "")) != "" or _current.options.has("screenshot"):
		print("[client] %s" % message)
		get_tree().quit(1)
		return
	Net.stop_local_server()
	_show_menu(message)


static func _random_avatar(seed_value: int) -> Dictionary:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	var av := AvatarSpec.defaults()
	for key in av.body:
		av.body[key] = rng.randf()
	av.appearance.skin = AvatarSpec.SKINS.keys()[rng.randi() % AvatarSpec.SKINS.size()]
	av.appearance.hair = AvatarSpec.HAIR_STYLES[rng.randi() % AvatarSpec.HAIR_STYLES.size()]
	av.appearance.hair_color = "#" + Color.from_hsv(rng.randf_range(0.02, 0.1), 0.6, rng.randf_range(0.1, 0.6)).to_html(false)
	av.clothing.top = AvatarSpec.TOPS[rng.randi() % AvatarSpec.TOPS.size()]
	av.clothing.bottom = AvatarSpec.BOTTOMS[rng.randi() % AvatarSpec.BOTTOMS.size()]
	for key in ["top_color", "bottom_color", "shoes_color"]:
		av.clothing[key] = "#" + Color.from_hsv(rng.randf(), rng.randf_range(0.2, 0.8), rng.randf_range(0.3, 0.9)).to_html(false)
	return av


# --- tests -------------------------------------------------------------------

func _run_tests() -> void:
	var runner: Node = load("res://tests/test_runner.gd").new()
	_swap(runner)
