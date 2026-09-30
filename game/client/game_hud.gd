class_name GameHud
extends CanvasLayer
## In-game overlay, built in code. Owns no game state; GameClient drives it.

signal chat_submitted(text: String)
signal group_chat_submitted(text: String)
signal group_action(what: String)  ## "create", "invite" or "leave"
signal group_closed
signal chat_closed
signal resume_requested
signal disconnect_requested
signal person_action(action: String)  ## "mute", "block", "invite", "game:<kind>" or "report:<reason>"
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
[b]Sosyal[/b]  bakıyorken:  E konuşma isteği · G el salla · H selam ver · J dans
          M sustur/aç · B engelle (iki kez) · R şikayet et
[b]Oyun[/b]  bakıyorken:  T taş kâğıt makas · K el kızartmaca · maçta 1/2/3 seç (taş, kâğıt, makas) · E ya da tık: vur/çek · Q bırak
[b]Grup[/b]  I en yakını gruba davet et · P grup paneli (kur, üyeler, ayrıl) · Enter'da Tab: Yakın/Grup kanalı
[b]Gelen istek[/b]  Y kabul · N reddet (ya da hiçbir şey yapma)
[b]Sohbet[/b]  Enter yaz · X sohbetten ayrıl (üç kişi ve fazlası aynı sohbete girebilir)
[b]Şehir[/b]  Tab harita (dokun: rota çiz) · F tramvaya bin / durak iste / in · V kamera (tekerlek: uzaklık) · E bankın yanında: otur
          E kediyi sev · koşarak topa gir: şut · raylarda durma!
[b]Sağlık[/b]  koşmak yorar (alttaki çubuk), koştukça kondisyonun artar · yaralıyken eczanede E tedavi
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
var _stamina_bar: Control
var _stamina_fill: ColorRect
var _injury: Label
# Groups: the tag at the top, the panel, and which channel the chat box writes to.
var _group := {}
var _my_id := 0
var _chat_row: HBoxContainer
var _channel_button: Button
var _channel := "near"  # "near" (conversation) or "group"
var _conv_names: Array = []
var _group_tag: HBoxContainer
var _group_tag_swatch: ColorRect
var _group_tag_label: Label
var _group_panel: PanelContainer
var _group_swatch: ColorRect
var _group_title: Label
var _group_rows: VBoxContainer
var _group_create_button: Button
var _group_invite_button: Button
var _group_chat_button: Button
var _group_leave_button: Button
# The minigame overlay (score, big word, hint) at the top of the screen.
var _game_panel: PanelContainer
var _game_title: Label
var _game_score: Label
var _game_big: Label
var _game_sub: Label

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
	_place(_incoming_panel, Control.PRESET_CENTER_TOP, Vector2(-230, 34))
	_incoming_panel.custom_minimum_size = Vector2(460, 0)
	_incoming_panel.visible = false
	root.add_child(_incoming_panel)
	_incoming = Label.new()
	_incoming.add_theme_font_size_override("font_size", 20)
	_incoming.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_incoming_panel.add_child(_incoming)

	# Your group's colour and name, small, at the top centre.
	_group_tag = HBoxContainer.new()
	_group_tag.add_theme_constant_override("separation", 6)
	_group_tag.alignment = BoxContainer.ALIGNMENT_CENTER
	_group_tag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_group_tag.visible = false
	_place(_group_tag, Control.PRESET_CENTER_TOP, Vector2(-160, 6))
	_group_tag.custom_minimum_size = Vector2(320, 0)
	root.add_child(_group_tag)
	_group_tag_swatch = ColorRect.new()
	_group_tag_swatch.custom_minimum_size = Vector2(14, 14)
	_group_tag_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_group_tag_swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_group_tag.add_child(_group_tag_swatch)
	_group_tag_label = _label(_group_tag, 15, Control.PRESET_TOP_LEFT, Vector2.ZERO)

	_outgoing = _label(root, 16, Control.PRESET_CENTER_TOP, Vector2(-200, 100))
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

	# Stamina: a thin bar at the bottom, only while it is not full.
	_stamina_bar = ColorRect.new()
	(_stamina_bar as ColorRect).color = Color(0, 0, 0, 0.45)
	_stamina_bar.custom_minimum_size = Vector2(200, 8)
	_stamina_bar.size = Vector2(200, 8)
	_place(_stamina_bar, Control.PRESET_CENTER_BOTTOM, Vector2(-100, -58))
	_stamina_bar.offset_right = _stamina_bar.offset_left + 200
	_stamina_bar.offset_bottom = _stamina_bar.offset_top + 8
	_stamina_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamina_bar.visible = false
	root.add_child(_stamina_bar)
	_stamina_fill = ColorRect.new()
	_stamina_fill.position = Vector2(1, 1)
	_stamina_fill.size = Vector2(198, 6)
	_stamina_fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stamina_bar.add_child(_stamina_fill)

	_injury = _label(root, 16, Control.PRESET_CENTER_BOTTOM, Vector2(-180, -112))
	_injury.custom_minimum_size = Vector2(360, 0)
	_injury.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_injury.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_injury.add_theme_color_override("font_color", Color("ffc2b8"))

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
	# The row holds the channel switch (Yakın / Grup) and the text box; the
	# text box's own visibility is what "chat is open" means.
	_chat_row = HBoxContainer.new()
	_chat_row.visible = false
	_chat_panel.add_child(_chat_row)
	_channel_button = Button.new()
	_channel_button.custom_minimum_size = Vector2(76, 0)
	_channel_button.focus_mode = Control.FOCUS_NONE
	_channel_button.pressed.connect(toggle_channel)
	_chat_row.add_child(_channel_button)
	_chat_input = LineEdit.new()
	_chat_input.max_length = Protocol.CHAT_MAX_LEN
	_chat_input.placeholder_text = "Mesaj yaz, Enter ile gönder, Esc ile kapat"
	_chat_input.visible = false
	_chat_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_input.text_submitted.connect(_on_chat_submitted)
	_chat_input.gui_input.connect(_on_chat_gui_input)
	_chat_row.add_child(_chat_input)
	_refresh_channel()

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
	_build_group_panel(root)
	_build_game_overlay(root)
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


## Touch replacement for the person keys: play, invite, mute, block, report.
func _build_person_menu(root: Control) -> void:
	_person = PanelContainer.new()
	_place(_person, Control.PRESET_CENTER, Vector2(-150, -215))
	_person.custom_minimum_size = Vector2(300, 0)
	_person.visible = false
	root.add_child(_person)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_person.add_child(box)
	_person_title = Label.new()
	_person_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	box.add_child(_person_title)
	var games := GridContainer.new()
	games.columns = 2
	box.add_child(games)
	_menu_button(games, "Taş kâğıt makas", func(): _emit_person("game:rps"))
	_menu_button(games, "El kızartmaca", func(): _emit_person("game:slap"))
	_menu_button(box, "Gruba davet et", func(): _emit_person("invite"))
	var safety := GridContainer.new()
	safety.columns = 2
	box.add_child(safety)
	_mute_button = _menu_button(safety, "Sustur", func(): _emit_person("mute"))
	_block_button = _menu_button(safety, "Engelle", _on_block_pressed)
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


# --- groups -------------------------------------------------------------------

## The "Grup" panel: who is in your group, invite, group chat, leave. Works
## with a finger as well as a mouse (big buttons, two taps to leave).
func _build_group_panel(root: Control) -> void:
	_group_panel = PanelContainer.new()
	_place(_group_panel, Control.PRESET_CENTER, Vector2(-170, -200))
	_group_panel.custom_minimum_size = Vector2(340, 0)
	_group_panel.visible = false
	root.add_child(_group_panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 6)
	_group_panel.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)
	_group_swatch = ColorRect.new()
	_group_swatch.custom_minimum_size = Vector2(24, 24)
	_group_swatch.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	head.add_child(_group_swatch)
	_group_title = Label.new()
	_group_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_group_title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	head.add_child(_group_title)
	_group_rows = VBoxContainer.new()
	_group_rows.add_theme_constant_override("separation", 2)
	box.add_child(_group_rows)
	_group_create_button = _menu_button(box, "Grup kur", func(): group_action.emit("create"))
	_group_invite_button = _menu_button(box, "En yakını davet et", func(): group_action.emit("invite"))
	_group_chat_button = _menu_button(box, "Grup sohbeti", _open_group_chat)
	# Two taps, so a stray touch never drops you out of the group.
	_group_leave_button = _menu_button(box, "Gruptan ayrıl", func(): pass)
	_group_leave_button.pressed.connect(func():
		if _group_leave_button.text == "Gruptan ayrıl":
			_group_leave_button.text = "Emin misin? Tekrar dokun"
			get_tree().create_timer(3.0).timeout.connect(func(): _group_leave_button.text = "Gruptan ayrıl")
		else:
			_group_leave_button.text = "Gruptan ayrıl"
			group_action.emit("leave"))
	_menu_button(box, "Kapat", close_group_panel)
	_refresh_group_panel()


func open_group_panel() -> void:
	close_person_menu()
	_refresh_group_panel()
	_group_panel.visible = true


func close_group_panel() -> void:
	if not _group_panel.visible:
		return
	_group_panel.visible = false
	group_closed.emit()


func is_group_panel_open() -> bool:
	return _group_panel.visible


func _open_group_chat() -> void:
	_channel = "group"
	close_group_panel()
	open_chat()


## `info` is the server's s_group_state ({} when in none); my_id marks "(sen)".
func set_group(info: Dictionary, my_id: int) -> void:
	_group = info
	_my_id = my_id
	if _group.is_empty() and _channel == "group":
		_channel = "near"
	_refresh_group_panel()
	_refresh_group_tag()
	_refresh_chat_header()
	_refresh_channel()


func group_color(color_index: int) -> Color:
	return Protocol.GROUP_COLORS[clampi(color_index, 0, Protocol.GROUP_COLORS.size() - 1)]


func _refresh_group_tag() -> void:
	_group_tag.visible = not _group.is_empty()
	if _group.is_empty():
		return
	var color := group_color(int(_group.color))
	_group_tag_swatch.color = color
	_group_tag_label.text = "%s · %d kişi" % [_group.name, (_group.members as Array).size()]
	_group_tag_label.add_theme_color_override("font_color", color.lightened(0.25))


func _refresh_group_panel() -> void:
	for child in _group_rows.get_children():
		_group_rows.remove_child(child)
		child.queue_free()
	var in_group := not _group.is_empty()
	_group_swatch.visible = in_group
	_group_create_button.visible = not in_group
	_group_chat_button.visible = in_group
	_group_leave_button.visible = in_group
	_group_leave_button.text = "Gruptan ayrıl"
	if not in_group:
		_group_title.text = "Grup"
		var hint := Label.new()
		hint.text = "Bir grupta değilsin. Grup kur ya da yakındaki birini davet et; davet kabul edilince grup kurulur. Grup sohbeti bölgenin her yerinde çalışır."
		hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hint.custom_minimum_size = Vector2(320, 0)
		hint.add_theme_font_size_override("font_size", 14)
		_group_rows.add_child(hint)
		_group_invite_button.visible = true
		return
	var color := group_color(int(_group.color))
	var members: Array = _group.members
	_group_swatch.color = color
	_group_title.text = "%s · %s · %d/%d" % [_group.name, Protocol.GROUP_COLOR_NAMES[clampi(int(_group.color), 0, Protocol.GROUP_COLOR_NAMES.size() - 1)],
		members.size(), Protocol.GROUP_MAX_MEMBERS]
	for m: Dictionary in members:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		var dot := ColorRect.new()
		dot.color = color
		dot.custom_minimum_size = Vector2(10, 10)
		dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(dot)
		var who := Label.new()
		who.text = "%s%s" % [m.name, "  (sen)" if int(m.id) == _my_id else ""]
		row.add_child(who)
		_group_rows.add_child(row)
	_group_invite_button.visible = members.size() < Protocol.GROUP_MAX_MEMBERS


# --- minigame overlay ---------------------------------------------------------

func _build_game_overlay(root: Control) -> void:
	_game_panel = PanelContainer.new()
	_place(_game_panel, Control.PRESET_CENTER_TOP, Vector2(-230, 76))
	_game_panel.custom_minimum_size = Vector2(460, 0)
	_game_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_game_panel.visible = false
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.06, 0.09, 0.74)
	style.set_corner_radius_all(12)
	style.set_content_margin_all(10)
	_game_panel.add_theme_stylebox_override("panel", style)
	root.add_child(_game_panel)
	var box := VBoxContainer.new()
	box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	box.add_theme_constant_override("separation", 0)
	_game_panel.add_child(box)
	_game_title = _game_line(box, 15, Color("aab4c0"))
	_game_score = _game_line(box, 18, Color.WHITE)
	_game_big = _game_line(box, 44, Color.WHITE)
	_game_sub = _game_line(box, 16, Color("dfe6ee"))
	_game_sub.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_game_sub.custom_minimum_size = Vector2(440, 0)


func _game_line(parent: Control, size: int, color: Color) -> Label:
	var l := Label.new()
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_constant_override("outline_size", 5)
	l.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.85))
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func set_game(title: String, score: String, big: String, sub: String, tint: Color) -> void:
	_game_title.text = title
	_game_score.text = score
	_game_big.text = big
	_game_big.add_theme_color_override("font_color", tint)
	_game_sub.text = sub
	_game_sub.visible = not sub.is_empty()
	_game_panel.visible = true
	_route.visible = false  # the overlay takes the route line's place
	if touch_mode:
		_refresh_chat_header()


func hide_game() -> void:
	_game_panel.visible = false
	_route.visible = true
	_refresh_chat_header()


func is_game_shown() -> bool:
	return _game_panel.visible


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
	return _person.visible or _pause.visible or _blocked.visible or _group_panel.visible or _wardrobe != null


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
	_refresh_channel()
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


## stamina 0..1; winded (out of breath) shows it red.
func set_stamina(stamina: float, winded: bool) -> void:
	var show := stamina < 0.995 or winded
	if _stamina_bar.visible != show:
		_stamina_bar.visible = show
	if not show:
		return
	_stamina_fill.size.x = 198.0 * clampf(stamina, 0.0, 1.0)
	_stamina_fill.color = Color("e05545") if winded else (Color("f0c040") if stamina < 0.3 else Color("7fd18b"))


func set_injury(text: String) -> void:
	if _injury.text != text:
		_injury.text = text


func set_route(text: String) -> void:
	_route.text = text


func set_outgoing(text: String) -> void:
	_outgoing.text = text


func notice(text: String, seconds := 3.5) -> void:
	_notice.text = text
	_notice.modulate.a = 1.0
	_notice_left = seconds


func set_conversations(names: Array) -> void:
	_conv_names = names
	_refresh_chat_header()


func _refresh_chat_header() -> void:
	# On a phone the chat sits where the game overlay goes: it waits.
	var has_chat := not _conv_names.is_empty() or not _group.is_empty() or _chat_log.get_parsed_text().length() > 0
	_chat_panel.visible = has_chat and not (touch_mode and _game_panel.visible and not _chat_input.visible)
	var parts := PackedStringArray()
	if not _conv_names.is_empty():
		parts.append("Sohbet: " + ", ".join(PackedStringArray(_conv_names)))
	if not _group.is_empty():
		parts.append("Grup: %s" % _group.name)
	_chat_header.text = "  ·  ".join(parts) if not parts.is_empty() else "Sohbet kapalı"


func add_chat_line(who: String, text: String, own: bool) -> void:
	var color := "9fd3ff" if own else "ffe7a3"
	_chat_log.append_text("[color=#%s]%s:[/color] %s\n" % [color, who.xml_escape(), text.xml_escape()])
	_chat_panel.visible = true


## A group chat line: the whole line wears the group's colour, with a [Grup]
## tag, so it reads apart from the conversation nearby.
func add_group_line(who: String, text: String, own: bool, color_index: int) -> void:
	var color := group_color(color_index).lightened(0.2).to_html(false)
	_chat_log.append_text("[color=#%s][Grup] %s%s:[/color] %s\n" % [color, who.xml_escape(), " (sen)" if own else "", text.xml_escape()])
	_chat_panel.visible = true


func add_system_line(text: String) -> void:
	_chat_log.append_text("[i][color=#aaaaaa]%s[/color][/i]\n" % text.xml_escape())


func open_chat() -> void:
	# Write where somebody can read: the group when there is no conversation
	# (and the other way round).
	if _channel == "group" and _group.is_empty():
		_channel = "near"
	elif _channel == "near" and _conv_names.is_empty() and not _group.is_empty():
		_channel = "group"
	_refresh_channel()
	_chat_panel.visible = true
	_chat_row.visible = true
	_chat_input.visible = true
	_chat_input.grab_focus()


func is_chat_open() -> bool:
	return _chat_input.visible


func close_chat() -> void:
	_chat_input.text = ""
	_chat_input.visible = false
	_chat_row.visible = false
	_chat_input.release_focus()
	chat_closed.emit()


## Switches the chat box between the conversation and the group (Tab, or the
## button beside the box).
func toggle_channel() -> void:
	if _channel == "near" and not _group.is_empty():
		_channel = "group"
	elif _channel == "group" and not _conv_names.is_empty():
		_channel = "near"
	_refresh_channel()
	if _chat_input.visible:
		_chat_input.grab_focus()


func _refresh_channel() -> void:
	var group := _channel == "group"
	_channel_button.text = "Grup" if group else "Yakın"
	_chat_input.placeholder_text = ("Gruba yaz" if group else "Yakındakilere yaz") + (", Enter ile gönder" if touch_mode else ", Enter ile gönder, Tab kanal, Esc kapat")
	_channel_button.add_theme_color_override("font_color", group_color(int(_group.color)).lightened(0.3) if group and not _group.is_empty() else Color.WHITE)


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
		if _channel == "group":
			group_chat_submitted.emit(text)
		else:
			chat_submitted.emit(text)
	close_chat()


func _on_chat_gui_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE:
		close_chat()
		get_viewport().set_input_as_handled()
	elif event is InputEventKey and event.pressed and event.keycode == KEY_TAB:
		toggle_channel()
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
