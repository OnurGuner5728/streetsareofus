class_name RemotePlayer
extends Node3D
## Another player as seen by this client: rendered slightly in the past,
## interpolated between server snapshots.

const INTERP_DELAY := 0.12
const MAX_EXTRAPOLATION := 0.15
const NAME_RANGE := 15.0
const BUBBLE_SECONDS := 6.0

var id := 0
var display_name := ""
var avatar := {}
var view: AvatarView
var in_conversation := false
var muted := false
var ride: Array = []  # [line, vehicle, slot] while on a tram
var transit: TransitNetwork

var _samples: Array = []  # {t, pos, yaw, pitch, speed}
var _interval := 1.0 / 15.0
var _label: Label3D
var _bubble: Label3D
var _bubble_left := 0.0
var _speed := 0.0
var _pitch := 0.0
var _anim_skip := 0.0
var _last_y := 0.0
var _vy := 0.0  # smoothed vertical speed: in the air when large


func setup(entity_id: int, info: Dictionary) -> void:
	id = entity_id
	name = "Remote_%d" % entity_id
	display_name = str(info.get("name", "?"))
	view = AvatarView.new()
	add_child(view)
	_label = _make_label(28, Color.WHITE)
	add_child(_label)
	_bubble = _make_label(26, Color("fff4c2"))
	_bubble.visible = false
	add_child(_bubble)
	set_avatar(info.get("avatar", {}))
	var r: Variant = info.get("ride", [])
	ride = r if typeof(r) == TYPE_ARRAY else []


func set_avatar(new_avatar: Dictionary) -> void:
	view.build(new_avatar, GraphicsQuality.level > GraphicsQuality.LOW)
	avatar = view.avatar
	_label.position.y = view.visual_height + 0.25
	_bubble.position.y = view.visual_height + 0.55
	_refresh_label()


func height() -> float:
	return view.visual_height


func set_conversation(active: bool) -> void:
	in_conversation = active
	_refresh_label()


func set_muted(value: bool) -> void:
	muted = value
	_refresh_label()
	if muted:
		_bubble.visible = false


func say(text: String) -> void:
	if muted:
		return
	_bubble.text = text if text.length() <= 60 else text.substr(0, 57) + "..."
	_bubble.visible = true
	_bubble_left = BUBBLE_SECONDS


func push_sample(t: float, pos: Vector3, yaw: float, pitch: float, speed: float, flags := 0) -> void:
	view.sitting = flags & SnapshotCodec.FLAG_SITTING != 0
	if not _samples.is_empty():
		var last: Dictionary = _samples[-1]
		if t <= float(last.t):
			return
		_interval = lerpf(_interval, clampf(t - float(last.t), 0.03, 1.0), 0.2)
	else:
		position = pos
		rotation.y = yaw
	_samples.append({"t": t, "pos": pos, "yaw": yaw, "pitch": pitch, "speed": speed})
	if _samples.size() > 24:
		_samples.pop_front()


## now_server: current server time estimate (client clock minus offset).
func update_render(now_server: float, delta: float, camera_pos: Vector3) -> void:
	if _samples.is_empty():
		return
	# Players far away arrive less often, so they are rendered further back.
	var t := now_server - maxf(INTERP_DELAY, _interval * 1.5)
	if ride.size() == 3 and transit:
		# Riders move with the tram's timetable, not with delayed snapshots.
		var last_sample: Dictionary = _samples[-1]
		_apply(transit.rider_position(ride[0], ride[1], ride[2], now_server), last_sample.yaw, last_sample.pitch, 0.0)
		view.animate(0.0, delta, _pitch)
		_label.visible = global_position.distance_to(camera_pos) < NAME_RANGE
		return
	var first: Dictionary = _samples[0]
	var last: Dictionary = _samples[-1]
	if t <= float(first.t):
		_apply(first.pos, first.yaw, first.pitch, first.speed)
	elif t >= float(last.t):
		var pos: Vector3 = last.pos
		if _samples.size() >= 2:
			var prev: Dictionary = _samples[-2]
			var span := float(last.t) - float(prev.t)
			var ahead := minf(t - float(last.t), MAX_EXTRAPOLATION)
			if span > 0.0:
				pos += (last.pos - prev.pos) / span * ahead
		_apply(pos, last.yaw, last.pitch, last.speed)
	else:
		for i in range(_samples.size() - 1, 0, -1):
			var a: Dictionary = _samples[i - 1]
			var b: Dictionary = _samples[i]
			if float(a.t) <= t:
				var f := (t - float(a.t)) / maxf(0.0001, float(b.t) - float(a.t))
				_apply(a.pos.lerp(b.pos, f), lerp_angle(float(a.yaw), float(b.yaw), f),
					lerpf(a.pitch, b.pitch, f), lerpf(a.speed, b.speed, f))
				break
	var dist := global_position.distance_to(camera_pos)
	if delta > 0.0:
		_vy = lerpf(_vy, (global_position.y - _last_y) / delta, minf(1.0, delta * 12.0))
	_last_y = global_position.y
	view.talking = in_conversation
	# Limbs of people far away are a few pixels tall: animate them less often.
	_anim_skip += delta
	if dist < 40.0 or _anim_skip > 0.1:
		view.animate(_speed, _anim_skip if dist >= 40.0 else delta, _pitch, absf(_vy) > 1.3)
		_anim_skip = 0.0
	var show_name := dist < NAME_RANGE
	if _label.visible != show_name:
		_label.visible = show_name
	if _bubble_left > 0.0:
		_bubble_left -= delta
		_bubble.visible = _bubble_left > 0.0


func _apply(pos: Vector3, yaw: float, pitch: float, speed: float) -> void:
	position = pos
	rotation.y = yaw
	_pitch = pitch
	_speed = speed


func _refresh_label() -> void:
	var text := display_name
	if in_conversation:
		text += "  · sohbette"
	if muted:
		text += "  · susturuldu"
	_label.text = text


func _make_label(size: int, color: Color) -> Label3D:
	var l := Label3D.new()
	l.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	l.font_size = size
	l.pixel_size = 0.004
	l.outline_size = 10
	l.modulate = color
	l.no_depth_test = false
	return l
