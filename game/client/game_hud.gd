class_name GameHud
extends CanvasLayer
## In-game overlay, built in code. Owns no game state; GameClient drives it.

signal chat_submitted(text: String)
signal chat_closed
signal resume_requested
signal disconnect_requested
signal person_action(action: String)  ## "mute", "block" or "report:<reason>"
signal blocked_list_requested
signal unblock_requested(account_id: String)
signal quality_requested(key: String)
signal fps_toggled(show: bool)
signal camera_requested
signal volume_requested
signal wardrobe_requested
signal wardrobe_changed(avatar: Dictionary)
signal wardrobe_closed(save: bool, avatar: Dictionary)

const HELP := """[b]Hareket[/b]  WASD · Shift koş · Space zıpla · Fare bak
[b]Sosyal[/b]  bakıyorken:  E konuşma isteği · G el salla · H selam ver
          M sustur/aç · B engelle (iki kez) · R şikayet et
[b]Gelen istek[/b]  Y kabul · N reddet (ya da hiçbir şey yapma)
[b]Sohbet[/b]  Enter yaz · X sohbetten ayrıl
[b]Şehir[/b]  Tab harita (dokun: rota çiz) · F tramvaya bin / durak iste / in · V kamera (tekerlek: uzaklık)
          E kediyi sev · koşarak topa gir: şut · raylarda durma!
F1 yardım · F3 ağ bilgisi · Esc menü (engellenenler, grafik, FPS)"""

var _location: Label
var _stats: Label
var _target: Label
var _incoming: Label
var _incoming_panel: PanelContainer
var _outgoing: Label
var _notice: Label
var _notice_left := 0.0
var _chat_panel: VBoxContainer
var _chat_header: Label
var _chat_log: RichTextLabel
var _chat_input: LineEdit
var _pause: Control
var _help: PanelContainer
var _person: PanelContainer
var _person_title: Label
var _block_button: Button
var _mute_button: Button
var _portrait: Label
var _route: Label
var _fps: Label
var _blocked: PanelContainer
var _blocked_rows: VBoxContainer
var _quality_button: Button
var _fps_button: Button
var _quality_key := "auto"
var _camera_button: Button
var _volume_button: Button
var _wardrobe: PanelContainer
var _wardrobe_editor: AvatarEditor
var touch_mode := false

const REPORT_LABELS := [["harassment", "Taciz"], ["hate", "Nefret söylemi"], ["spam", "Spam"], ["impersonation", "Taklit"], ["other", "Diğer"]]


func _ready() -> void:
	var root := Control.new()
	root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(root)

	var cross := ColorRect.new()
	cross.color = Color(1, 1, 1, 0.85)
	cross.custom_minimum_size = Vector2(4, 4)
	_place(cross, Control.PRESET_CENTER, Vector2(-2, -2))
	cross.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(cross)

	_location = _label(root, 18, Control.PRESET_TOP_LEFT, Vector2(16, 12))
	_stats = _label(root, 14, Control.PRESET_TOP_RIGHT, Vector2(-16, 12))
	_stats.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	_stats.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	_stats.visible = false

	_incoming_panel = PanelContainer.new()
	_place(_incoming_panel, Control.PRESET_CENTER_TOP, Vector2(-230, 16))
	_incoming_panel.custom_minimum_size = Vector2(460, 0)
	_incoming_panel.visible = false
	root.add_child(_incoming_panel)
	_incoming = Label.new()
	_incoming.add_theme_font_size_override("font_size", 20)
	_incoming.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_incoming_panel.add_child(_incoming)

	_outgoing = _label(root, 16, Control.PRESET_CENTER_TOP, Vector2(-200, 90))
	_outgoing.custom_minimum_size = Vector2(400, 0)
	_outgoing.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_target = _label(root, 18, Control.PRESET_CENTER, Vector2(-320, 60))
	_target.custom_minimum_size = Vector2(640, 0)
	_target.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	_route = _label(root, 17, Control.PRESET_CENTER_TOP, Vector2(-330, 170))
	_route.custom_minimum_size = Vector2(660, 0)
	_route.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_route.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_route.add_theme_color_override("font_color", Color("9ef0c0"))

	_notice = _label(root, 20, Control.PRESET_CENTER, Vector2(-320, -120))
	_notice.custom_minimum_size = Vector2(640, 0)
	_notice.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_notice.add_theme_color_override("font_color", Color("ffe08a"))

	_chat_panel = VBoxContainer.new()
	_place(_chat_panel, Control.PRESET_BOTTOM_LEFT, Vector2(16, -290))
	_chat_panel.custom_minimum_size = Vector2(440, 250)
	_chat_panel.visible = false
	root.add_child(_chat_panel)
	_chat_header = Label.new()
	_chat_header.add_theme_font_size_override("font_size", 15)
	_chat_panel.add_child(_chat_header)
	_chat_log = RichTextLabel.new()
	_chat_log.bbcode_enabled = true
	_chat_log.scroll_following = true
	_chat_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_chat_log.add_theme_color_override("default_color", Color.WHITE)
	_chat_log.add_theme_constant_override("outline_size", 4)
	_chat_log.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.8))
	_chat_log.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_chat_panel.add_child(_chat_log)
	_chat_input = LineEdit.new()
	_chat_input.max_length = Protocol.CHAT_MAX_LEN
	_chat_input.placeholder_text = "Mesaj yaz, Enter ile gönder, Esc ile kapat"
	_chat_input.visible = false
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_input.gui_input.connect(_on_chat_gui_input)
	_chat_panel.add_child(_chat_input)

	var attribution := _label(root, 12, Control.PRESET_BOTTOM_RIGHT, Vector2(-16, -26))
	attribution.name = "Attribution"
	attribution.grow_horizontal = Control.GROW_DIRECTION_BEGIN
	attribution.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_help = PanelContainer.new()
	_place(_help, Control.PRESET_CENTER, Vector2(-300, -110))
	_help.custom_minimum_size = Vector2(600, 0)
	var help_text := RichTextLabel.new()
	help_text.bbcode_enabled = true
	help_text.fit_content = true
	help_text.text = HELP
	_help.add_child(help_text)
	_help.visible = false
	root.add_child(_help)

	_pause = ColorRect.new()
	(_pause as ColorRect).color = Color(0, 0, 0, 0.55)
	_pause.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_pause.visible = false
	root.add_child(_pause)
	var box := VBoxContainer.new()
	_place(box, Control.PRESET_CENTER, Vector2(-130, -205))
	box.custom_minimum_size = Vector2(260, 0)
	box.add_theme_constant_override("separation", 6)
	_pause.add_child(box)
	_menu_button(box, "Devam et", resume_requested.emit)
	_menu_button(box, "Görünüm (kıyafet)", wardrobe_requested.emit)
	_camera_button = _menu_button(box, "Kamera: Birinci şahıs", camera_requested.emit)
	_volume_button = _menu_button(box, "Ses: Açık", volume_requested.emit)
	_menu_button(box, "Engellenenler", blocked_list_requested.emit)
	_quality_button = _menu_button(box, "", _cycle_quality)
	_fps_button = _menu_button(box, "", func(): set_fps_visible(not _fps.visible); fps_toggled.emit(_fps.visible))
	# Two taps, so a stray touch on a phone never ends the session.
	var leave := _menu_button(box, "Bağlantıyı kes", func(): pass)
	leave.pressed.connect(func():
		if leave.text == "Bağlantıyı kes":
			leave.text = "Emin misin? Tekrar dokun"
			get_tree().create_timer(3.0).timeout.connect(func(): leave.text = "Bağlantıyı kes")
		else:
			disconnect_requested.emit())
	_build_person_menu(root)
	_build_blocked_panel(root)
	_fps = _label(root, 13, Control.PRESET_TOP_LEFT, Vector2(16, 58))
	_fps.modulate = Color(0.75, 1.0, 0.8)
	set_fps_visible(false)
	set_quality_key("auto")

	_portrait = Label.new()
	_portrait.text = "Oynamak için telefonu yatay çevir"
	_portrait.add_theme_font_size_override("font_size", 28)
	_portrait.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_portrait.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	_portrait.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_portrait.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var shade := StyleBoxFlat.new()
	shade.bg_color = Color(0.08, 0.1, 0.13, 0.94)
	_portrait.add_theme_stylebox_override("normal", shade)
	_portrait.visible = false
	root.add_child(_portrait)


## Touch replacement for the M / B / R keys: mute, block, report someone.
func _build_person_menu(root: Control) -> void:
	_person = PanelContainer.new()
	_place(_person, Control.PRESET_CENTER, Vector2(-150, -170))
	_person.custom_minimum_size = Vector2(300, 0)
	_person.visible = false
	root.add_child(_person)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_person.add_child(box)
	_person_title = Label.new()
	_person_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_person_title)
	_mute_button = _menu_button(box, "Sustur", func(): _emit_person("mute"))
	_block_button = _menu_button(box, "Engelle", _on_block_pressed)
	var report := Label.new()
	report.text = "Şikayet et:"
	box.add_child(report)
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	for spec in REPORT_LABELS:
		_menu_button(grid, spec[1], func(): _emit_person("report:" + spec[0]))
	_menu_button(box, "Kapat", close_person_menu)


## "Engellenenler": everyone you blocked, each with a two-tap unblock.
func _build_blocked_panel(root: Control) -> void:
	_blocked = PanelContainer.new()
	_place(_blocked, Control.PRESET_CENTER, Vector2(-180, -170))
	_blocked.custom_minimum_size = Vector2(360, 0)
	_blocked.visible = false
	root.add_child(_blocked)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_blocked.add_child(box)
	var title := Label.new()
	title.text = "Engellediğin kişiler"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(title)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(340, 200)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(scroll)
	_blocked_rows = VBoxContainer.new()
	_blocked_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(_blocked_rows)
	var note := Label.new()
	note.text = "Engeli kaldırdığında birbirinizi yeniden görürsünüz. Karşı tarafa bildirim gitmez."
	note.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	note.add_theme_font_size_override("font_size", 12)
	note.modulate = Color("aab4c0")
	box.add_child(note)
	_menu_button(box, "Kapat", func(): _blocked.visible = false)


func show_blocked(list: Array) -> void:
	for child in _blocked_rows.get_children():
		child.queue_free()
	if list.is_empty():
		var empty := Label.new()
		empty.text = "Kimseyi engellemedin."
		empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_blocked_rows.add_child(empty)
	for entry in list:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var row := HBoxContainer.new()
		var who := Label.new()
		who.text = "%s
%s" % [str(entry.get("name", "?")), str(entry.get("since", "")).substr(0, 10)]
		who.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		who.add_theme_font_size_override("font_size", 14)
		row.add_child(who)
		var account := str(entry.get("account", ""))
		var b := Button.new()
		b.text = "Engeli kaldır"
		b.custom_minimum_size = Vector2(150, 40)
		b.pressed.connect(func():
			if b.text == "Engeli kaldır":
				b.text = "Emin misin? Dokun"
			else:
				b.disabled = true
				unblock_requested.emit(account))
		row.add_child(b)
		_blocked_rows.add_child(row)
	_blocked.visible = true


func is_blocked_panel_open() -> bool:
	return _blocked.visible


func set_camera_name(text: String) -> void:
	_camera_button.text = "Kamera: " + text


func set_volume_name(text: String) -> void:
	_volume_button.text = "Ses: " + text


## The in-game wardrobe: the avatar editor on the right, you on the left.
func open_wardrobe(current: Dictionary) -> void:
	if _wardrobe:
		_wardrobe.queue_free()
	_wardrobe = PanelContainer.new()
	_wardrobe.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	_wardrobe.offset_left = -minf(440.0, get_viewport().get_visible_rect().size.x * 0.6)
	_wardrobe.offset_top = 8
	_wardrobe.offset_bottom = -30  # above the attribution line
	_wardrobe.offset_right = -8
	get_child(0).add_child(_wardrobe)
	var box := VBoxContainer.new()
	_wardrobe.add_child(box)
	_wardrobe_editor = AvatarEditor.new()
	_wardrobe_editor.size_flags_vertical = Control.SIZE_EXPAND_FILL
	box.add_child(_wardrobe_editor)
	_wardrobe_editor.setup(current)
	_wardrobe_editor.changed.connect(func(av: Dictionary): wardrobe_changed.emit(av))
	var row := HBoxContainer.new()
	box.add_child(row)
	_menu_button(row, "Vazgeç", func(): close_wardrobe(false))
	_menu_button(row, "Kaydet ve giy", func(): close_wardrobe(true))


func close_wardrobe(save: bool) -> void:
	if _wardrobe == null:
		return
	var chosen := _wardrobe_editor.avatar
	_wardrobe.queue_free()
	_wardrobe = null
	wardrobe_closed.emit(save, chosen)


func is_wardrobe_open() -> bool:
	return _wardrobe != null


## How much of the screen width the wardrobe panel covers (0 when closed).
func wardrobe_fraction() -> float:
	if _wardrobe == null:
		return 0.0
	return absf(_wardrobe.offset_left) / maxf(1.0, get_viewport().get_visible_rect().size.x)


func set_quality_key(key: String) -> void:
	_quality_key = key
	_quality_button.text = "Grafik: %s" % GraphicsQuality.NAMES[GraphicsQuality.from_key(key)]


func _cycle_quality() -> void:
	var order := ["auto", "low", "medium", "high"]
	set_quality_key(order[(order.find(_quality_key) + 1) % order.size()])
	quality_requested.emit(_quality_key)


func set_fps_visible(show: bool) -> void:
	_fps.visible = show
	_fps_button.text = "FPS göstergesi: %s" % ("açık" if show else "kapalı")


func set_fps(text: String) -> void:
	_fps.text = text


func _menu_button(parent: Control, text: String, callback: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(140, 40)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(callback)
	parent.add_child(b)
	return b


func show_person_menu(who: String, is_muted: bool) -> void:
	_person_title.text = who
	_mute_button.text = "Sesini aç" if is_muted else "Sustur"
	_block_button.text = "Engelle"
	_person.visible = true


func close_person_menu() -> void:
	_person.visible = false


func is_modal_open() -> bool:
	return _person.visible or _pause.visible or _blocked.visible or _wardrobe != null


func _on_block_pressed() -> void:
	if _block_button.text == "Engelle":
		_block_button.text = "Emin misin? Tekrar dokun"
	else:
		_emit_person("block")


func _emit_person(what: String) -> void:
	close_person_menu()
	person_action.emit(what)


func set_portrait_warning(show: bool) -> void:
	_portrait.visible = show


## Phones: the bottom-left belongs to the joystick, so chat moves up.
func apply_touch_layout() -> void:
	touch_mode = true
	_place(_chat_panel, Control.PRESET_TOP_LEFT, Vector2(16, 64))
	_chat_panel.custom_minimum_size = Vector2(360, 150)
	_chat_input.placeholder_text = "Mesaj yaz ve gönder"
	_target.add_theme_font_size_override("font_size", 16)
	var attribution := find_child("Attribution", true, false) as Label
	_place(attribution, Control.PRESET_CENTER_BOTTOM, Vector2(-160, -22))
	attribution.custom_minimum_size = Vector2(320, 0)
	attribution.grow_horizontal = Control.GROW_DIRECTION_END
	attribution.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER


func set_attribution(text: String) -> void:
	(find_child("Attribution", true, false) as Label).text = text


func set_location(text: String) -> void:
	_location.text = text


func set_stats(text: String) -> void:
	_stats.text = text


func toggle_stats() -> void:
	_stats.visible = not _stats.visible


func toggle_help() -> void:
	_help.visible = not _help.visible


func set_target(text: String) -> void:
	_target.text = text


func set_incoming(text: String) -> void:
	_incoming.text = text
	_incoming_panel.visible = not text.is_empty()


func set_route(text: String) -> void:
	_route.text = text


func set_outgoing(text: String) -> void:
	_outgoing.text = text


func notice(text: String, seconds := 3.5) -> void:
	_notice.text = text
	_notice.modulate.a = 1.0
	_notice_left = seconds


func set_conversations(names: Array) -> void:
	_chat_panel.visible = not names.is_empty() or _chat_log.get_parsed_text().length() > 0
	_chat_header.text = "Sohbet: " + ", ".join(PackedStringArray(names)) if not names.is_empty() else "Sohbet kapalı"


func add_chat_line(who: String, text: String, own: bool) -> void:
	var color := "9fd3ff" if own else "ffe7a3"
	_chat_log.append_text("[color=#%s]%s:[/color] %s\n" % [color, who.xml_escape(), text.xml_escape()])
	_chat_panel.visible = true


func add_system_line(text: String) -> void:
	_chat_log.append_text("[i][color=#aaaaaa]%s[/color][/i]\n" % text.xml_escape())


func open_chat() -> void:
	_chat_panel.visible = true
	_chat_input.visible = true
	_chat_input.grab_focus()


func is_chat_open() -> bool:
	return _chat_input.visible


func close_chat() -> void:
	_chat_input.text = ""
	_chat_input.visible = false
	_chat_input.release_focus()
	chat_closed.emit()


func set_paused(paused: bool) -> void:
	_pause.visible = paused


func is_paused() -> bool:
	return _pause.visible


func _process(delta: float) -> void:
	if _notice_left > 0.0:
		_notice_left -= delta
		_notice.modulate.a = clampf(_notice_left / 0.6, 0.0, 1.0)


func _on_chat_submitted(text: String) -> void:
	if not text.strip_edges().is_empty():
		chat_submitted.emit(text)
	close_chat()


func _on_chat_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_chat()
		get_viewport().set_input_as_handled()


func _label(parent: Control, size: int, preset: Control.LayoutPreset, offset: Vector2) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_constant_override("outline_size", 6)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_place(l, preset, offset)
	parent.add_child(l)
	return l


## Anchors a control to a preset and offsets its top-left corner from that anchor.
func _place(c: Control, preset: Control.LayoutPreset, offset: Vector2) -> void:
	c.set_anchors_preset(preset)
	c.offset_left = offset.x
	c.offset_right = offset.x
	c.offset_top = offset.y
	c.offset_bottom = offset.y
