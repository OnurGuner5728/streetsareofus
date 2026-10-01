class_name RemotePlayer
extends Node3D
## Another player as seen by this client: rendered slightly in the past,
## interpolated between server snapshots.

const INTERP_DELAY := 0.12
const MAX_EXTRAPOLATION := 0.15
const NAME_RANGE := 15.0
const BUBBLE_SECONDS := 6.0
## After a chat line the speaker keeps talking (arms and jaw) for this long,
## and the others in the circle turn their heads to them.
const SPEAK_SECONDS := 3.0
const GAZE_LIMIT := 1.0  # radians: heads do not turn further than this

static var _marker_mesh: SphereMesh
static var _marker_mats := {}  # group colour index -> material

var id := 0
var display_name := ""
var avatar := {}
var view: AvatarView
var in_conversation := false
var muted := false
var group_color := -1  ## palette index of this player's group, -1 for none
var group_name := ""
var ride: Array = []  # [line, vehicle, slot] while on a tram
var transit: TransitNetwork

var _samples: Array = []  # {t, pos, yaw, pitch, speed}
var _interval := 1.0 / 15.0
var _label: Label3D
var _bubble: Label3D
var _bubble_left := 0.0
var _marker: MeshInstance3D
var _speak_left := 0.0
var _gaze_node: Node3D
var _gaze_left := 0.0
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
	_marker = MeshInstance3D.new()
	_marker.visible = false
	_marker.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(_marker)
	set_avatar(info.get("avatar", {}))
	var r: Variant = info.get("ride", [])
	ride = r if typeof(r) == TYPE_ARRAY else []
	set_injury(str(info.get("injury", "")))


func set_injury(kind: String) -> void:
	view.set_injury(kind if kind in ["bruise", "arm", "leg"] else "")


func set_avatar(new_avatar: Dictionary) -> void:
	view.build(new_avatar, GraphicsQuality.level > GraphicsQuality.LOW)
	avatar = view.avatar
	_label.position.y = view.visual_height + 0.25
	_bubble.position.y = view.visual_height + 0.55
	_marker.position.y = view.visual_height + 0.13
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
	_speak_left = SPEAK_SECONDS


## Somebody in the circle is speaking: turn the head to them for a while.
func gaze_at(node: Node3D) -> void:
	_gaze_node = node
	_gaze_left = SPEAK_SECONDS


## The group this player belongs to (colour index into Protocol.GROUP_COLORS,
## -1 for none): a coloured bead over the head and a nameplate to match.
func set_group(color_index: int, group_label: String) -> void:
	group_color = color_index
	group_name = group_label if color_index >= 0 else ""
	if color_index >= 0 and color_index < Protocol.GROUP_COLORS.size():
		if _marker_mesh == null:
			_marker_mesh = SphereMesh.new()
			_marker_mesh.radius = 0.08
			_marker_mesh.height = 0.16
			_marker_mesh.radial_segments = 10
			_marker_mesh.rings = 5
		if not _marker_mats.has(color_index):
			var mat := StandardMaterial3D.new()
			mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
			mat.albedo_color = Protocol.GROUP_COLORS[color_index]
			_marker_mats[color_index] = mat
		_marker.mesh = _marker_mesh
		_marker.material_override = _marker_mats[color_index]
		_marker.visible = true
		_label.modulate = Protocol.GROUP_COLORS[color_index].lightened(0.35)
	else:
		_marker.visible = false
		_label.modulate = Color.WHITE
	_refresh_label()


func push_sample(t: float, pos: Vector3, yaw: float, pitch: float, speed: float, flags := 0) -> void:
	view.sitting = flags & SnapshotCodec.FLAG_SITTING != 0
	view.knocked = flags & SnapshotCodec.FLAG_KNOCKED != 0
	view.winded = flags & SnapshotCodec.FLAG_WINDED != 0
	view.limp = flags & SnapshotCodec.FLAG_LIMP != 0
	view.hop = flags & SnapshotCodec.FLAG_HOP != 0
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
	# Talking is per line: the arms move while somebody speaks, and the circle
	# looks at the speaker.
	if _speak_left > 0.0:
		_speak_left -= delta
	view.talking = in_conversation and _speak_left > 0.0
	view.gaze_yaw = 0.0
	if _gaze_left > 0.0:
		_gaze_left -= delta
		if is_instance_valid(_gaze_node) and _gaze_node.is_inside_tree() and in_conversation:
			var to := _gaze_node.global_position - global_position
			if to.length_squared() > 0.01:
				var rel := wrapf(atan2(-to.x, -to.z) - rotation.y, -PI, PI)
				view.gaze_yaw = clampf(rel, -GAZE_LIMIT, GAZE_LIMIT)
	# Limbs of people far away are a few pixels tall: animate them less often.
	_anim_skip += delta
	if dist < 40.0 or _anim_skip > 0.1:
		view.animate(_speed, _anim_skip if dist >= 40.0 else delta, _pitch, absf(_vy) > 1.3 and not view.knocked)
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
	if group_color >= 0 and group_name != "":
		text += "  · %s" % group_name
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
