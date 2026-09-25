class_name MainMenu
extends Control
## Launcher: name, server, spawn mode and avatar editor with a live preview.

signal play_requested(settings: Dictionary, host_locally: bool)

const SPAWN_MODES := [["social", "Birileriyle karşılaşabileceğim bir yer"], ["random", "Tamamen rastgele bir yer"], ["resume", "Kaldığım yerden devam"]]

var settings := {}
var _name: LineEdit
var _server: LineEdit
var _zone: OptionButton = null
var _spawn: OptionButton
var _status: Label
var _preview: AvatarView
var _zones := PackedStringArray()


func setup(initial: Dictionary, message: String) -> void:
	settings = initial.duplicate(true)
	_build()
	_status.text = message
	_refresh_preview()


func _build() -> void:
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var bg := ColorRect.new()
	bg.color = Color("1b2430")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	# Phones get two tabs instead of three columns side by side.
	var compact := get_viewport().get_visible_rect().size.x < 1100.0
	# Browsers and phones cannot start a server process: they only connect.
	var web := OS.has_feature("web") or OS.has_feature("mobile")

	var margin := MarginContainer.new()
	margin.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 12 if compact else 32)
	add_child(margin)
	var columns := HBoxContainer.new()
	columns.add_theme_constant_override("separation", 20 if compact else 40)
	var tabs := TabContainer.new()
	margin.add_child(tabs if compact else columns)

	# Left: identity, server, spawn.
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(420, 0)
	left.add_theme_constant_override("separation", 6 if compact else 10)
	if compact:
		tabs.add_child(left)
		tabs.set_tab_title(0, "Oyna")
	else:
		columns.add_child(left)
	var title := Label.new()
	title.text = "Streets Are Of Us"
	title.add_theme_font_size_override("font_size", 26 if compact else 40)
	left.add_child(title)
	if not compact:
		var subtitle := Label.new()
		subtitle.text = "Gerçek sokaklar, gerçek insanlar. Konuşma yalnızca iki taraf da isterse başlar."
		subtitle.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		subtitle.modulate = Color("aab4c0")
		left.add_child(subtitle)
		left.add_child(HSeparator.new())

	_name = _line_edit(left, "Görünen isim", str(settings.name), "3-20 karakter")
	_server = _line_edit(left, "Sunucu", str(settings.server), "telefon linki (https://…), adres:port veya wss://")
	_zones = ZoneData.available_zones()
	if not web:
		# Browsers cannot start a server process, so the zone only matters locally.
		_zone = _option(left, "Bölge (yerel sunucu için)", Array(_zones), str(settings.zone))
	var spawn_ids := []
	for m in SPAWN_MODES:
		spawn_ids.append(m[0])
	_spawn = _option(left, "Nereye?", spawn_ids, str(settings.spawn_mode))
	for i in SPAWN_MODES.size():
		_spawn.set_item_text(i, SPAWN_MODES[i][1])

	var connect_btn := Button.new()
	connect_btn.text = "Bağlan"
	connect_btn.custom_minimum_size = Vector2(0, 44)
	connect_btn.pressed.connect(_on_play.bind(false))
	left.add_child(connect_btn)
	if not web:
		var host_btn := Button.new()
		host_btn.text = "Yerel sunucu başlat ve bağlan"
		host_btn.custom_minimum_size = Vector2(0, 44)
		host_btn.pressed.connect(_on_play.bind(true))
		left.add_child(host_btn)
	elif compact and OS.has_feature("web"):
		var full := Button.new()
		full.text = "Tam ekran"
		full.custom_minimum_size = Vector2(0, 40)
		full.pressed.connect(func(): DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN))
		left.add_child(full)
	var android_browser := OS.has_feature("web") and str(JavaScriptBridge.eval("navigator.userAgent", true)).contains("Android")
	if android_browser:
		# The app runs natively (no browser in between): smoother on phones.
		var apk := Button.new()
		apk.text = "Android uygulamasını indir (daha akıcı)"
		apk.custom_minimum_size = Vector2(0, 40)
		apk.pressed.connect(func():
			var origin := str(JavaScriptBridge.eval("location.origin", true))
			JavaScriptBridge.eval("try { navigator.clipboard.writeText(location.origin) } catch (e) {} location.href = 'streetsareofus.apk'", true)
			_status.text = "İndiriliyor. Kurduktan sonra uygulamada Sunucu alanına şu adresi yapıştır (panoya kopyalandı): " + origin)
		left.add_child(apk)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color("ffcf70"))
	left.add_child(_status)
	if OS.has_feature("android") and not Net.normalize_address(str(settings.server)).begins_with("ws"):
		_status.text = "Sunucu alanına telefon linkini yapıştır (https://….trycloudflare.com)."
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(spacer)
	var credit := Label.new()
	credit.text = "Harita verisi © OpenStreetMap katkıcıları (ODbL). Gerçek konumun hiçbir zaman istenmez."
	credit.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	credit.add_theme_font_size_override("font_size", 12)
	credit.modulate = Color("8792a0")
	left.add_child(credit)

	# Middle: avatar preview.
	var container := SubViewportContainer.new()
	container.stretch = true
	container.custom_minimum_size = Vector2(200 if compact else 320, 0)
	container.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if compact:
		tabs.add_child(columns)
		tabs.set_tab_title(1, "Görünüm")
	columns.add_child(container)
	var viewport := SubViewport.new()
	viewport.own_world_3d = true
	container.add_child(viewport)
	var stage := Node3D.new()
	viewport.add_child(stage)
	var env := Environment.new()
	env.background_mode = Environment.BG_COLOR
	env.background_color = Color("24303e")
	env.ambient_light_color = Color("8894a8")
	env.ambient_light_energy = 0.6
	var world_env := WorldEnvironment.new()
	world_env.environment = env
	stage.add_child(world_env)
	var light := DirectionalLight3D.new()
	light.rotation_degrees = Vector3(-30, 30, 0)
	stage.add_child(light)
	var fill := DirectionalLight3D.new()
	fill.rotation_degrees = Vector3(-10, -140, 0)
	fill.light_energy = 0.45
	fill.light_color = Color("c9d8ff")
	stage.add_child(fill)
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.05, 4.2)
	cam.fov = 34
	stage.add_child(cam)
	_preview = AvatarView.new()
	stage.add_child(_preview)

	# Right: every avatar option, in tabs.
	var editor := AvatarEditor.new()
	editor.custom_minimum_size = Vector2(340, 0)
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	columns.add_child(editor)
	editor.setup(settings.avatar)
	editor.changed.connect(func(av: Dictionary):
		settings.avatar = av
		_refresh_preview())


func _process(delta: float) -> void:
	if _preview:
		_preview.rotation.y += delta * 0.5
		_preview.animate(0.0, delta)


func _refresh_preview() -> void:
	settings.avatar = AvatarSpec.sanitize(settings.avatar)
	_preview.build(settings.avatar)
	_preview.position.y = -0.05 - (AvatarSpec.visual_height(settings.avatar) - 1.7) * 0.5


func _on_play(host_locally: bool) -> void:
	var display_name := AvatarSpec.sanitize_name(_name.text)
	if display_name.is_empty():
		_status.text = "İsim 3-20 karakter olmalı; harf, rakam, boşluk, _ . - kullanılabilir."
		return
	settings.name = display_name
	settings.server = _server.text.strip_edges()
	if _zone and _zone.selected >= 0 and _zone.selected < _zones.size():
		settings.zone = _zones[_zone.selected]
	settings.spawn_mode = SPAWN_MODES[_spawn.selected][0]
	LocalProfile.save_settings(settings)
	_status.text = "Bağlanılıyor..."
	play_requested.emit(settings, host_locally)


func _line_edit(parent: Control, title: String, value: String, placeholder: String) -> LineEdit:
	var label := Label.new()
	label.text = title
	parent.add_child(label)
	var edit := LineEdit.new()
	edit.text = value
	edit.placeholder_text = placeholder
	edit.custom_minimum_size = Vector2(0, 36)
	parent.add_child(edit)
	return edit


func _option(parent: Control, title: String, ids: Array, selected: String) -> OptionButton:
	var label := Label.new()
	label.text = title
	parent.add_child(label)
	if parent is HBoxContainer:
		label.custom_minimum_size = Vector2(44, 0)
	var opt := OptionButton.new()
	for id in ids:
		opt.add_item(str(id))
	var idx := ids.find(selected)
	opt.select(idx if idx >= 0 else 0)
	opt.custom_minimum_size = Vector2(0, 34)
	parent.add_child(opt)
	return opt
