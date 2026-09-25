class_name AvatarView
extends Node3D
## Procedural stand-in for the MakeHuman/MPFB pipeline: built from
## primitives, driven by the same avatar dictionary the network carries.
## Faces -Z, like the camera, so rotation.y = yaw.

static var _materials := {}

var avatar := {}
var visual_height := 1.7
var _hip_l: Node3D
var _hip_r: Node3D
var _shoulder_l: Node3D
var _shoulder_r: Node3D
var _head: Node3D
var _phase := 0.0
var _emote := ""
var _emote_time := 0.0
var _look_pitch := 0.0


func build(new_avatar: Dictionary) -> void:
	avatar = AvatarSpec.sanitize(new_avatar)
	for child in get_children():
		child.queue_free()
	var body: Dictionary = avatar.body
	var app: Dictionary = avatar.appearance
	var cl: Dictionary = avatar.clothing
	var h := AvatarSpec.visual_height(avatar)
	visual_height = h
	var width := lerpf(0.85, 1.3, float(body.weight))
	var shoulders := lerpf(0.85, 1.2, float(body.shoulders))
	var muscle := lerpf(1.0, 1.35, float(body.muscle))
	var skin := AvatarSpec.skin_color(avatar)
	var top_color := Color(str(cl.top_color))
	var bottom_color := Color(str(cl.bottom_color))
	var shoes_color := Color(str(cl.shoes_color))
	var hair_color := Color(str(app.hair_color))

	var hip_y := 0.5 * h
	var shoulder_y := 0.81 * h
	var head_r := 0.062 * h
	var leg_r := 0.052 * h * lerpf(0.9, 1.2, float(body.weight))
	var leg_len := hip_y - 0.03 * h
	var hip_x := 0.05 * h * width

	# Legs: thigh + shin so shorts and skirts can show skin.
	var bottom: String = cl.bottom
	var shin_color := skin if bottom in ["shorts", "skirt"] else bottom_color
	var thigh_color := skin if bottom == "skirt" else bottom_color
	for side in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.position = Vector3(side * hip_x, hip_y, 0)
		add_child(hip)
		_capsule(hip, leg_r, leg_len * 0.55, Vector3(0, -leg_len * 0.25, 0), thigh_color)
		_capsule(hip, leg_r * 0.85, leg_len * 0.55, Vector3(0, -leg_len * 0.72, 0), shin_color)
		_box(hip, Vector3(leg_r * 2.1, 0.05 * h, 0.15 * h), Vector3(0, -leg_len - 0.005 * h, -0.03 * h), shoes_color)
		if side < 0:
			_hip_l = hip
		else:
			_hip_r = hip

	# Torso.
	var torso_r := 0.1 * h * width
	var torso_h := shoulder_y - hip_y + 0.1 * h
	var torso := _capsule(self, torso_r, torso_h, Vector3(0, (hip_y + shoulder_y) / 2.0, 0), top_color)
	torso.scale = Vector3(shoulders, 1.0, 0.62)
	if bottom == "skirt":
		var skirt := CylinderMesh.new()
		skirt.top_radius = torso_r * 0.95
		skirt.bottom_radius = torso_r * 1.35
		skirt.height = 0.14 * h
		_mesh(self, skirt, Vector3(0, hip_y - 0.05 * h, 0), bottom_color).scale = Vector3(1, 1, 0.75)
	else:
		_capsule(self, torso_r * 0.95, 0.12 * h, Vector3(0, hip_y + 0.02 * h, 0), bottom_color).scale = Vector3(1, 1, 0.62)
	var top: String = cl.top
	if top == "hoodie":
		_sphere(self, 0.052 * h, Vector3(0, shoulder_y - 0.01 * h, 0.06 * h), top_color.darkened(0.08)).scale = Vector3(1.1, 0.8, 0.7)
	elif top == "jacket":
		_box(self, Vector3(torso_r * 0.5, torso_h * 0.7, 0.01 * h), Vector3(0, (hip_y + shoulder_y) / 2.0 + 0.03 * h, -torso_r * 0.63), Color("f0f0f0"))

	# Arms hang from shoulder pivots so emotes can rotate them.
	var arm_r := 0.032 * h * muscle
	var arm_len := 0.36 * h
	var sleeve_color := top_color
	for side in [-1.0, 1.0]:
		var shoulder := Node3D.new()
		shoulder.position = Vector3(side * (torso_r * shoulders + arm_r * 0.6), shoulder_y - 0.02 * h, 0)
		add_child(shoulder)
		_capsule(shoulder, arm_r, arm_len * 0.55, Vector3(0, -arm_len * 0.25, 0), sleeve_color)
		_capsule(shoulder, arm_r * 0.9, arm_len * 0.55, Vector3(0, -arm_len * 0.72, 0), skin if top == "tshirt" else sleeve_color)
		_sphere(shoulder, arm_r * 1.2, Vector3(0, -arm_len - arm_r * 0.3, 0), skin)
		if side < 0:
			_shoulder_l = shoulder
		else:
			_shoulder_r = shoulder

	# Neck and head on a pivot so the head can follow look pitch and nod.
	_capsule(self, 0.028 * h, 0.07 * h, Vector3(0, shoulder_y + 0.03 * h, 0), skin)
	_head = Node3D.new()
	_head.position = Vector3(0, shoulder_y + 0.06 * h, 0)
	add_child(_head)
	var head_center := Vector3(0, head_r * 1.05, 0)
	_sphere(_head, head_r, head_center, skin).scale = Vector3(0.9, 1.1, 1.0)
	for side in [-1.0, 1.0]:
		_sphere(_head, head_r * 0.13, head_center + Vector3(side * head_r * 0.36, head_r * 0.12, -head_r * 0.9), Color("1d1d1f"))
	_hair(str(app.hair), head_r, head_center, hair_color)


func _hair(style: String, r: float, c: Vector3, color: Color) -> void:
	match style:
		"short":
			_sphere(_head, r * 1.04, c + Vector3(0, r * 0.18, r * 0.08), color).scale = Vector3(0.92, 0.9, 1.0)
		"long":
			_sphere(_head, r * 1.06, c + Vector3(0, r * 0.15, r * 0.08), color).scale = Vector3(0.95, 0.95, 1.0)
			_box(_head, Vector3(r * 1.8, r * 2.2, r * 0.6), c + Vector3(0, -r * 0.8, r * 0.55), color)
		"bun":
			_sphere(_head, r * 1.04, c + Vector3(0, r * 0.18, r * 0.08), color).scale = Vector3(0.92, 0.9, 1.0)
			_sphere(_head, r * 0.45, c + Vector3(0, r * 0.9, r * 0.6), color)
		"cap":
			_sphere(_head, r * 1.06, c + Vector3(0, r * 0.3, 0), color).scale = Vector3(0.95, 0.7, 1.0)
			_box(_head, Vector3(r * 1.3, r * 0.08, r * 0.9), c + Vector3(0, r * 0.35, -r * 1.2), color.darkened(0.2))


## speed in m/s; pitch in radians (camera pitch of that player).
func animate(speed: float, delta: float, pitch := 0.0) -> void:
	if _hip_l == null:
		return
	var amount := clampf(speed / Protocol.WALK_SPEED, 0.0, 1.4)
	_phase = fmod(_phase + delta * (2.0 + speed * 1.9), TAU)
	var swing := sin(_phase) * 0.55 * amount
	_hip_l.rotation.x = swing
	_hip_r.rotation.x = -swing
	_shoulder_l.rotation = Vector3(-swing * 0.8, 0, 0)
	_shoulder_r.rotation = Vector3(swing * 0.8, 0, 0)
	_look_pitch = lerpf(_look_pitch, clampf(pitch, -0.7, 0.7) * 0.6, minf(1.0, delta * 10.0))
	_head.rotation.x = _look_pitch
	if _emote_time > 0.0:
		_emote_time -= delta
		var t := _emote_time
		match _emote:
			"wave":
				_shoulder_r.rotation = Vector3(0, 0, 2.6 + sin(t * 14.0) * 0.35)
			"nod":
				_head.rotation.x = _look_pitch - absf(sin(t * 9.0)) * 0.35


func play_emote(kind: String) -> void:
	_emote = kind
	_emote_time = 1.6 if kind == "wave" else 0.8


func _capsule(parent: Node3D, radius: float, height: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var m := CapsuleMesh.new()
	m.radius = radius
	m.height = maxf(height, radius * 2.0)
	m.radial_segments = 12
	m.rings = 4
	return _mesh(parent, m, pos, color)


func _sphere(parent: Node3D, radius: float, pos: Vector3, color: Color) -> MeshInstance3D:
	var m := SphereMesh.new()
	m.radius = radius
	m.height = radius * 2.0
	m.radial_segments = 14
	m.rings = 7
	return _mesh(parent, m, pos, color)


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var m := BoxMesh.new()
	m.size = size
	return _mesh(parent, m, pos, color)


func _mesh(parent: Node3D, mesh: Mesh, pos: Vector3, color: Color) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _material(color)
	parent.add_child(mi)
	return mi


static func _material(color: Color) -> StandardMaterial3D:
	var key := color.to_html(false)
	if not _materials.has(key):
		var mat := StandardMaterial3D.new()
		mat.albedo_color = color
		mat.roughness = 0.85
		_materials[key] = mat
	return _materials[key]
