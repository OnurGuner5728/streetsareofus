class_name MainMenu
extends Control
## Launcher: name, server, spawn mode and avatar editor with a live preview.

signal play_requested(settings: Dictionary, host_locally: bool)

const SPAWN_MODES := [["social", "Birileriyle karşılaşabileceğim bir yer"], ["random", "Tamamen rastgele bir yer"], ["resume", "Kaldığım yerden devam"]]
const HAIR_LABELS := {"none": "Yok", "short": "Kısa", "long": "Uzun", "bun": "Topuz", "cap": "Şapka"}
const TOP_LABELS := {"tshirt": "Tişört", "hoodie": "Kapüşonlu", "jacket": "Ceket"}
const BOTTOM_LABELS := {"jeans": "Kot", "trousers": "Kumaş pantolon", "shorts": "Şort", "skirt": "Etek"}
const BODY_SLIDERS := [["height", "Boy"], ["weight", "Kilo"], ["muscle", "Kas"], ["shoulders", "Omuz"]]

var settings := {}
var _name: LineEdit
var _server: LineEdit
var _zone: OptionButton = null
var _spawn: OptionButton
var _status: Label
var _preview: AvatarView
var _height_label: Label
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
	var web := OS.has_feature("web")

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
	_server = _line_edit(left, "Sunucu", str(settings.server), "adres:port veya wss://")
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
	elif compact:
		var full := Button.new()
		full.text = "Tam ekran"
		full.custom_minimum_size = Vector2(0, 40)
		full.pressed.connect(func(): DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN))
		left.add_child(full)
	_status = Label.new()
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_status.add_theme_color_override("font_color", Color("ffcf70"))
	left.add_child(_status)
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
	var cam := Camera3D.new()
	cam.position = Vector3(0, 1.05, 4.2)
	cam.fov = 34
	stage.add_child(cam)
	_preview = AvatarView.new()
	stage.add_child(_preview)

	# Right: avatar controls.
	var right := VBoxContainer.new()
	right.custom_minimum_size = Vector2(320, 0)
	right.add_theme_constant_override("separation", 6)
	columns.add_child(right)
	var avatar_title := Label.new()
	avatar_title.text = "Görünüm"
	avatar_title.add_theme_font_size_override("font_size", 24)
	right.add_child(avatar_title)
	var av: Dictionary = settings.avatar
	for spec in BODY_SLIDERS:
		var key: String = spec[0]
		var row := HBoxContainer.new()
		right.add_child(row)
		var label := Label.new()
		label.text = spec[1]
		label.custom_minimum_size = Vector2(110, 0)
		row.add_child(label)
		if key == "height":
			_height_label = label
		var slider := HSlider.new()
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		slider.min_value = 0.0
		slider.max_value = 1.0
		slider.step = 0.01
		slider.value = float(av.body[key])
		slider.value_changed.connect(func(v): _set_avatar("body", key, v))
		row.add_child(slider)
	var skins := AvatarSpec.SKINS.keys()
	var skin_row := HBoxContainer.new()
	right.add_child(skin_row)
	var skin_opt := _option(skin_row, "Ten", skins, str(av.appearance.skin))
	skin_opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in skins.size():
		skin_opt.set_item_text(i, "Ton %d" % (i + 1))
	skin_opt.item_selected.connect(func(i): _set_avatar("appearance", "skin", skins[i]))
	_choice_with_color(right, "Saç", AvatarSpec.HAIR_STYLES, HAIR_LABELS, "appearance", "hair", "hair_color")
	_choice_with_color(right, "Üst", AvatarSpec.TOPS, TOP_LABELS, "clothing", "top", "top_color")
	_choice_with_color(right, "Alt", AvatarSpec.BOTTOMS, BOTTOM_LABELS, "clothing", "bottom", "bottom_color")
	var shoes_row := HBoxContainer.new()
	var shoes_label := Label.new()
	shoes_label.text = "Ayakkabı"
	shoes_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	shoes_row.add_child(shoes_label)
	var shoes := ColorPickerButton.new()
	shoes.color = Color(str(av.clothing.shoes_color))
	shoes.edit_alpha = false
	shoes.custom_minimum_size = Vector2(72, 34)
	shoes.color_changed.connect(func(c): _set_avatar("clothing", "shoes_color", "#" + c.to_html(false)))
	shoes_row.add_child(shoes)
	right.add_child(shoes_row)
	var note := Label.new()
	note.text = "Boy ve kilo yalnızca görünüştür; oyun içi çarpışma ve göz yüksekliği herkes için dar bir aralıkta tutulur."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.modulate = Color("8792a0")
	right.add_child(note)


func _process(delta: float) -> void:
	if _preview:
		_preview.rotation.y += delta * 0.5
		_preview.animate(0.0, delta)


## A style dropdown and its colour on one row, to keep the column short.
func _choice_with_color(parent: Control, title: String, ids: Array, labels: Dictionary, group: String, key: String, color_key: String) -> void:
	var av: Dictionary = settings.avatar
	var row := HBoxContainer.new()
	var opt := _option(row, title, ids, str(av[group][key]))
	opt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for i in ids.size():
		opt.set_item_text(i, labels.get(ids[i], ids[i]))
	opt.item_selected.connect(func(i): _set_avatar(group, key, ids[i]))
	var picker := ColorPickerButton.new()
	picker.tooltip_text = title + " rengi"
	picker.color = Color(str(av[group][color_key]))
	picker.edit_alpha = false
	picker.custom_minimum_size = Vector2(72, 34)
	picker.color_changed.connect(func(c): _set_avatar(group, color_key, "#" + c.to_html(false)))
	row.add_child(picker)
	parent.add_child(row)


func _set_avatar(group: String, key: String, value: Variant) -> void:
	settings.avatar[group][key] = value
	_refresh_preview()


func _refresh_preview() -> void:
	settings.avatar = AvatarSpec.sanitize(settings.avatar)
	_preview.build(settings.avatar)
	_preview.position.y = -0.05 - (AvatarSpec.visual_height(settings.avatar) - 1.7) * 0.5
	_height_label.text = "Boy %d cm" % roundi(AvatarSpec.visual_height(settings.avatar) * 100.0)


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
