class_name TouchControls
extends CanvasLayer
## On-screen controls for phones. A floating joystick appears wherever the
## left thumb lands, dragging anywhere else looks around, and round buttons
## sit under the right thumb. Touches are handled per finger (index), since
## regular GUI buttons only ever see the first finger.

signal action(id: String)

const JOY_RADIUS := 60.0
const KNOB_RADIUS := 26.0
const LOOK_SENSITIVITY := 0.0065  # radians per logical pixel
const FONT_SIZE := 13

var move := Vector2.ZERO  ## x = right, y = forward, length <= 1
var jump_held := false
var sprint := false
var enabled := true:
	set(value):
		if enabled and not value:
			_release_all()
		enabled = value

var _look_delta := Vector2.ZERO
var _joy_index := -1
var _joy_origin := Vector2.ZERO
var _joy_knob := Vector2.ZERO
var _look_index := -1
var _look_last := Vector2.ZERO
var _held := {}  # finger index -> button id
var _context := {}
var _surface: Control
var exclude: Array = []  ## Rect2s (e.g. the minimap) where touches are left alone


func _ready() -> void:
	layer = 5
	_surface = Control.new()
	_surface.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_surface.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_surface.draw.connect(_draw_controls)
	add_child(_surface)


## ctx: target (someone under the crosshair), talking_to_target, in_conversation, incoming
func set_context(ctx: Dictionary) -> void:
	if ctx != _context:
		_context = ctx
	_surface.visible = enabled
	_surface.queue_redraw()


## Look movement since the last call, in radians (x = yaw, y = pitch).
func take_look() -> Vector2:
	var d := _look_delta * LOOK_SENSITIVITY
	_look_delta = Vector2.ZERO
	return d


func _buttons() -> Array:
	var size := _surface.size
	var w := size.x
	var h := size.y
	var list := [
		{"id": "jump", "label": "Zıpla", "pos": Vector2(w - 62, h - 70), "r": 40.0},
		{"id": "sprint", "label": "Koş", "pos": Vector2(w - 150, h - 44), "r": 30.0, "on": sprint},
		{"id": "wave", "label": "El salla", "pos": Vector2(w - 150, h - 120), "r": 30.0},
		{"id": "nod", "label": "Selam", "pos": Vector2(w - 228, h - 50), "r": 28.0},
		{"id": "menu", "label": "Menü", "pos": Vector2(w - 40, 40), "r": 26.0},
	]
	if _context.get("target", false):
		if _context.get("talking_to_target", false):
			list.append({"id": "leave", "label": "Ayrıl", "pos": Vector2(w - 62, h - 170), "r": 34.0})
		else:
			list.append({"id": "talk", "label": "Konuş", "pos": Vector2(w - 62, h - 170), "r": 38.0, "tint": Color("3d8bfd")})
		list.append({"id": "person", "label": "Kişi", "pos": Vector2(w - 140, h - 200), "r": 26.0})
	if _context.get("in_conversation", false):
		list.append({"id": "chat", "label": "Yaz", "pos": Vector2(w - 228, h - 130), "r": 30.0, "tint": Color("2f9e6f")})
	var tram_label: String = _context.get("tram_label", "")
	if tram_label != "":
		list.append({"id": "tram", "label": tram_label, "pos": Vector2(w - 240, h - 205), "r": 32.0,
			"tint": _context.get("tram_tint", Color("2e86de"))})
	if _context.get("incoming", false):
		list.append({"id": "accept", "label": "Kabul", "pos": Vector2(w / 2.0 - 70, 120), "r": 34.0, "tint": Color("2f9e6f")})
		list.append({"id": "decline", "label": "Reddet", "pos": Vector2(w / 2.0 + 70, 120), "r": 34.0, "tint": Color("c0392b")})
	return list


func _button_at(pos: Vector2) -> String:
	for b in _buttons():
		if pos.distance_to(b.pos) <= float(b.r) + 8.0:
			return b.id
	return ""


func _input(event: InputEvent) -> void:
	if not enabled:
		return
	if event is InputEventScreenTouch:
		var touch := event as InputEventScreenTouch
		if touch.pressed:
			_on_press(touch.index, touch.position)
		else:
			_on_release(touch.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var drag := event as InputEventScreenDrag
		if drag.index == _joy_index:
			_joy_knob = (drag.position - _joy_origin).limit_length(JOY_RADIUS)
			move = Vector2(_joy_knob.x, -_joy_knob.y) / JOY_RADIUS
		elif drag.index == _look_index:
			_look_delta += drag.position - _look_last
			_look_last = drag.position
		get_viewport().set_input_as_handled()


func _on_press(index: int, pos: Vector2) -> void:
	for r in exclude:
		if (r as Rect2).has_point(pos):
			return
	var id := _button_at(pos)
	if id != "":
		_held[index] = id
		match id:
			"jump":
				jump_held = true
			"sprint":
				sprint = not sprint
			_:
				action.emit(id)
	elif _joy_index < 0 and pos.x < _surface.size.x * 0.45:
		_joy_index = index
		_joy_origin = pos
		_joy_knob = Vector2.ZERO
	elif _look_index < 0:
		_look_index = index
		_look_last = pos
	_surface.queue_redraw()


func _on_release(index: int) -> void:
	if _held.get(index, "") == "jump":
		jump_held = false
	_held.erase(index)
	if index == _joy_index:
		_joy_index = -1
		_joy_knob = Vector2.ZERO
		move = Vector2.ZERO
	if index == _look_index:
		_look_index = -1
	_surface.queue_redraw()


func _release_all() -> void:
	_held.clear()
	_joy_index = -1
	_look_index = -1
	_joy_knob = Vector2.ZERO
	move = Vector2.ZERO
	jump_held = false


func _draw_controls() -> void:
	if not enabled:
		return
	var font := ThemeDB.fallback_font
	var h := _surface.size.y
	if _joy_index >= 0:
		_surface.draw_circle(_joy_origin, JOY_RADIUS, Color(1, 1, 1, 0.12))
		_surface.draw_arc(_joy_origin, JOY_RADIUS, 0, TAU, 40, Color(1, 1, 1, 0.45), 2.0)
		_surface.draw_circle(_joy_origin + _joy_knob, KNOB_RADIUS, Color(1, 1, 1, 0.5))
	else:
		var hint := Vector2(100, h - 100)
		_surface.draw_arc(hint, JOY_RADIUS, 0, TAU, 40, Color(1, 1, 1, 0.25), 2.0)
		_label(font, hint, "Yürü", Color(1, 1, 1, 0.5))
	var pressed := _held.values()
	for b in _buttons():
		var tint: Color = b.get("tint", Color(0, 0, 0))
		var active: bool = b.get("on", false) or pressed.has(b.id)
		var fill := tint.lerp(Color.WHITE, 0.25) if active else Color(tint, 0.45)
		_surface.draw_circle(b.pos, b.r, fill)
		_surface.draw_arc(b.pos, b.r, 0, TAU, 32, Color(1, 1, 1, 0.7), 2.0)
		_label(font, b.pos, b.label, Color.WHITE)


func _label(font: Font, center: Vector2, text: String, color: Color) -> void:
	var width := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE).x
	_surface.draw_string_outline(font, center + Vector2(-width / 2.0, FONT_SIZE * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, 4, Color(0, 0, 0, 0.7))
	_surface.draw_string(font, center + Vector2(-width / 2.0, FONT_SIZE * 0.35), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, FONT_SIZE, color)
