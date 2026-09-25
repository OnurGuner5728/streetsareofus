class_name AvatarView
extends Node3D
## Procedural stand-in for the MakeHuman/MPFB pipeline: built from
## primitives, driven by the same avatar dictionary the network carries.
## Faces -Z, like the camera, so rotation.y = yaw.
##
## The figure is jointed (hips, knees, shoulders, elbows, neck), each part
## one merged mesh, so it walks with bending knees and swinging arms for
## about ten draw calls. `detail = false` (distant players, low quality)
## drops the knee/elbow joints and the small face parts.

var avatar := {}
var visual_height := 1.7
var detail := true
var _root: Node3D
var _hip_l: Node3D
var _hip_r: Node3D
var _knee_l: Node3D
var _knee_r: Node3D
var _shoulder_l: Node3D
var _shoulder_r: Node3D
var _elbow_l: Node3D
var _elbow_r: Node3D
var _head: Node3D
var _chest: Node3D
var _phase := 0.0
var _breath := 0.0
var _emote := ""
var _emote_time := 0.0
var _look_pitch := 0.0

# Proportions of the current build, in metres.
var _h := 1.7
var _hip_y := 0.85
var _knee := 0.48
var _shoulder_y := 1.38
var _neck_y := 1.43
var _head_r := 0.11


func build(new_avatar: Dictionary, with_detail := true) -> void:
	avatar = AvatarSpec.sanitize(new_avatar)
	detail = with_detail
	for child in get_children():
		child.queue_free()
	_root = Node3D.new()
	_root.name = "Figure"
	add_child(_root)
	var b: Dictionary = avatar.body
	var app: Dictionary = avatar.appearance
	var cl: Dictionary = avatar.clothing
	var acc: Dictionary = avatar.accessories
	var h := AvatarSpec.visual_height(avatar)
	_h = h
	visual_height = h
	var w := lerpf(0.85, 1.35, float(b.weight))
	var muscle := lerpf(1.0, 1.35, float(b.muscle))
	_hip_y = h * lerpf(0.47, 0.53, float(b.legs))
	_knee = _hip_y * 0.53
	_shoulder_y = h * 0.815
	_neck_y = h * 0.845
	_head_r = 0.063 * h * lerpf(0.92, 1.1, float(b.head))
	var shoulder_x := 0.108 * h * lerpf(0.9, 1.2, float(b.shoulders))
	var hip_x := 0.072 * h * lerpf(0.85, 1.25, float(b.hips)) * sqrt(w)
	var skin := AvatarSpec.skin_color(avatar)
	var top_c := Color(str(cl.top_color))
	var top2 := Color(str(cl.top_color2))
	var bottom_c := Color(str(cl.bottom_color))
	var shoe_c := Color(str(cl.shoes_color))
	var hair_c := Color(str(app.hair_color))
	var top: String = cl.top
	var bottom: String = cl.bottom
	var dress := top == "dress"
	var m := MeshMerger.new()

	# --- legs: thigh on the hip joint, shin and shoe on the knee joint.
	var thigh_r := 0.05 * h * pow(w, 0.6)
	var shin_r := 0.036 * h * pow(w, 0.4)
	var thigh_c := skin if (dress or bottom in ["skirt", "long_skirt"]) else bottom_c
	var shin_c := skin if (dress or bottom in ["skirt", "long_skirt", "shorts"]) else bottom_c
	for side: float in [-1.0, 1.0]:
		var hip := Node3D.new()
		hip.position = Vector3(side * hip_x, _hip_y, 0)
		_root.add_child(hip)
		var knee := Node3D.new()
		knee.position = Vector3(0, -(_hip_y - _knee), 0)
		hip.add_child(knee)
		var tg := "thigh%d" % side
		var sg := "shin%d" % side if detail else tg
		var shin_origin := Vector3.ZERO if detail else knee.position
		var thigh_len := _hip_y - _knee
		m.capsule(tg, thigh_r, thigh_len + thigh_r, Vector3(0, -thigh_len / 2.0, 0), thigh_c, Vector3.ONE, 8)
		if bottom == "shorts" and not dress:
			m.capsule(tg, thigh_r * 0.92, thigh_len * 0.45, Vector3(0, -thigh_len * 0.82, 0), skin, Vector3.ONE, 8)
		m.capsule(sg, shin_r, _knee + shin_r, shin_origin + Vector3(0, -_knee / 2.0, 0), shin_c, Vector3.ONE, 8)
		if bottom == "sweatpants" and not dress:
			m.cylinder(sg, shin_r * 1.08, shin_r * 1.08, 0.025 * h, Transform3D(Basis(), shin_origin + Vector3(0, -_knee + 0.07 * h, 0)), bottom_c.darkened(0.25))
		_shoe(m, sg, shin_origin + Vector3(0, -_knee, 0), h, str(cl.shoes), shoe_c, skin, shin_c)
		if detail:
			m.emit(tg, hip, _material())
			m.emit(sg, knee, _material())
		else:
			m.emit(tg, hip, _material())
		if side < 0:
			_hip_l = hip
			_knee_l = knee
		else:
			_hip_r = hip
			_knee_r = knee

	# --- torso: pelvis, waist, chest and neck; clothes and accessories on it.
	var waist_y := h * 0.6
	var chest_y := h * 0.715
	var waist_r := 0.068 * h * w
	var chest_r := 0.075 * h * lerpf(0.95, 1.12, float(b.muscle) * 0.5 + float(b.weight) * 0.5)
	var depth := lerpf(0.6, 0.78, float(b.chest))
	var pelvis_c := top_c if (dress or top == "coat") else bottom_c
	var hip_w := hip_x + thigh_r * 0.85
	var body_d := chest_r * depth * 1.25  # half depth of the chest
	# Hips: a short block rounded at the bottom, in the trousers' colour.
	m.cylinder("torso", waist_r * 1.02, hip_w, 0.09 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.78)), Vector3(0, _hip_y + 0.045 * h, 0)), pelvis_c)
	m.sphere("torso", 1.0, Vector3(0, _hip_y, 0), pelvis_c, Vector3(hip_w, 0.045 * h, hip_w * 0.78), 12)
	var torso_c := skin if top == "tank" else top_c
	# Torso: narrows from the shoulders to the waist, with rounded shoulders.
	var torso_top := _shoulder_y + 0.005 * h
	var torso_bottom := _hip_y + 0.085 * h
	var torso_len := torso_top - torso_bottom
	var shoulder_w := shoulder_x * 0.92
	var torso_xf := Transform3D(Basis().scaled(Vector3(1, 1, body_d / shoulder_w)), Vector3(0, torso_bottom + torso_len / 2.0, 0))
	m.cylinder("torso", shoulder_w, waist_r * 1.02, torso_len, torso_xf, top_c)
	m.sphere("torso", 1.0, Vector3(0, torso_top, 0), torso_c, Vector3(shoulder_w, 0.035 * h, body_d), 12)
	# Chest (or bust) forward of the ribcage.
	m.sphere("torso", 1.0, Vector3(0, chest_y, -body_d * 0.18), top_c,
		Vector3(shoulder_w * 0.86, 0.085 * h, body_d * lerpf(0.86, 1.02, float(b.chest))), 12)
	if top == "tank":
		# Bare shoulders and upper chest, with straps.
		m.sphere("torso", 1.0, Vector3(0, chest_y + 0.05 * h, 0), skin, Vector3(shoulder_x * 0.9, 0.06 * h, chest_r * depth * 1.1), 10)
		for side: float in [-1.0, 1.0]:
			m.box("torso", Vector3(0.025 * h, 0.08 * h, chest_r * depth * 2.2), Vector3(side * shoulder_x * 0.45, chest_y + 0.075 * h, 0), top_c)
	for side: float in [-1.0, 1.0]:
		m.sphere("torso", 0.033 * h * muscle, Vector3(side * shoulder_x, _shoulder_y - 0.012 * h, 0), torso_c, Vector3(1.0, 1.0, 1.0), 8)
	m.capsule("torso", 0.028 * h, 0.07 * h, Vector3(0, _neck_y, 0), skin, Vector3.ONE, 8)
	_stripes(m, str(cl.pattern), top, h, torso_bottom, torso_len, waist_r * 1.02, shoulder_w, body_d / shoulder_w, top2)
	_top_details(m, top, str(cl.pattern), h, waist_y, chest_y, waist_r, shoulder_x, chest_r * depth, top_c, top2, _hip_y, hip_x + thigh_r)
	_bottom_details(m, bottom, dress, h, _hip_y, hip_x + thigh_r, bottom_c)
	_bag(m, str(acc.bag), Color(str(acc.bag_color)), h, chest_y, shoulder_x, chest_r * depth, _hip_y)
	if acc.scarf == "scarf":
		var sc := Color(str(acc.scarf_color))
		m.cylinder("torso", 0.05 * h, 0.055 * h, 0.04 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.9)), Vector3(0, _neck_y - 0.01 * h, 0)), sc)
		m.box("torso", Vector3(0.035 * h, 0.16 * h, 0.012 * h), Vector3(0.025 * h, chest_y + 0.02 * h, -chest_r * depth * 1.2 - 0.004 * h), sc.darkened(0.08))
	m.emit("torso", _root, _material())

	# --- arms: upper arm on the shoulder, forearm and hand on the elbow.
	var arm_r := 0.028 * h * muscle * sqrt(w)
	var upper_len := 0.17 * h
	var fore_len := 0.15 * h
	var sleeve := top_c
	var upper_c := skin if top == "tank" else sleeve
	var fore_c := skin if top in ["tshirt", "polo", "tank", "dress"] else sleeve
	for side: float in [-1.0, 1.0]:
		var shoulder := Node3D.new()
		shoulder.position = Vector3(side * (shoulder_x + arm_r * 0.3), _shoulder_y - 0.02 * h, 0)
		_root.add_child(shoulder)
		var elbow := Node3D.new()
		elbow.position = Vector3(0, -upper_len, 0)
		shoulder.add_child(elbow)
		var ug := "upper%d" % side
		var fg := "fore%d" % side if detail else ug
		var fore_origin := Vector3.ZERO if detail else elbow.position
		m.capsule(ug, arm_r, upper_len + arm_r, Vector3(0, -upper_len / 2.0, 0), upper_c, Vector3.ONE, 8)
		if top in ["tshirt", "polo", "dress"]:
			m.capsule(ug, arm_r * 0.92, upper_len * 0.5, Vector3(0, -upper_len * 0.78, 0), skin, Vector3.ONE, 8)
		m.capsule(fg, arm_r * 0.88, fore_len + arm_r, fore_origin + Vector3(0, -fore_len / 2.0, 0), fore_c, Vector3.ONE, 8)
		if fore_c == sleeve and top != "tank":
			var cuff := top2 if top == "shirt" else sleeve.darkened(0.15)
			m.cylinder(fg, arm_r * 0.95, arm_r * 0.95, 0.018 * h, Transform3D(Basis(), fore_origin + Vector3(0, -fore_len + 0.01 * h, 0)), cuff)
		# Hand: palm and thumb.
		m.box(fg, Vector3(0.045 * h, 0.06 * h, 0.022 * h), fore_origin + Vector3(0, -fore_len - 0.035 * h, 0), skin)
		m.box(fg, Vector3(0.014 * h, 0.03 * h, 0.014 * h), fore_origin + Vector3(-side * 0.02 * h, -fore_len - 0.03 * h, -0.012 * h), skin)
		m.emit(ug, shoulder, _material())
		if detail:
			m.emit(fg, elbow, _material())
		if side < 0:
			_shoulder_l = shoulder
			_elbow_l = elbow
		else:
			_shoulder_r = shoulder
			_elbow_r = elbow

	# --- head on the neck joint.
	_head = Node3D.new()
	_head.position = Vector3(0, _neck_y + 0.02 * h, 0)
	_root.add_child(_head)
	_build_head(m, h, skin, hair_c, app, acc)
	m.emit("head", _head, _material())


static func _material() -> StandardMaterial3D:
	return MeshMerger.vertex_colour_material(0.85)


# --- parts -----------------------------------------------------------------------

func _shoe(m: MeshMerger, g: String, ankle: Vector3, h: float, kind: String, c: Color, skin: Color, leg: Color) -> void:
	var foot := Vector3(0, 0, -0.035 * h)
	match kind:
		"boots":
			m.box(g, Vector3(0.07 * h, 0.012 * h, 0.16 * h), ankle + foot + Vector3(0, -0.012 * h, 0), Color(0.12, 0.1, 0.09))
			m.box(g, Vector3(0.066 * h, 0.075 * h, 0.14 * h), ankle + foot + Vector3(0, 0.03 * h, 0.005 * h), c)
		"formal":
			m.box(g, Vector3(0.058 * h, 0.01 * h, 0.155 * h), ankle + foot + Vector3(0, -0.013 * h, 0), Color(0.08, 0.07, 0.07))
			m.box(g, Vector3(0.056 * h, 0.035 * h, 0.14 * h), ankle + foot + Vector3(0, 0.01 * h, 0.005 * h), c)
			m.sphere(g, 0.028 * h, ankle + foot + Vector3(0, 0.005 * h, -0.065 * h), c, Vector3(1.0, 0.6, 1.2), 6)
		"sandals":
			m.box(g, Vector3(0.06 * h, 0.012 * h, 0.155 * h), ankle + foot + Vector3(0, -0.013 * h, 0), c)
			m.box(g, Vector3(0.05 * h, 0.025 * h, 0.13 * h), ankle + foot + Vector3(0, 0.006 * h, 0), skin)
			for z in [-0.04, 0.02]:
				m.box(g, Vector3(0.062 * h, 0.01 * h, 0.012 * h), ankle + foot + Vector3(0, 0.018 * h, z * h), c.darkened(0.2))
		_:  # sneakers
			m.box(g, Vector3(0.064 * h, 0.018 * h, 0.16 * h), ankle + foot + Vector3(0, -0.01 * h, 0), Color(0.93, 0.93, 0.9))
			m.box(g, Vector3(0.06 * h, 0.04 * h, 0.145 * h), ankle + foot + Vector3(0, 0.018 * h, 0.004 * h), c)
			m.box(g, Vector3(0.03 * h, 0.006 * h, 0.06 * h), ankle + foot + Vector3(0, 0.039 * h, -0.02 * h), c.lightened(0.4))


func _top_details(m: MeshMerger, top: String, pattern: String, h: float, waist_y: float, chest_y: float, waist_r: float,
		shoulder_x: float, chest_d: float, c: Color, c2: Color, hip_y: float, hip_w: float) -> void:
	var front := -chest_d * 1.25  # z of the chest's front surface (approx.)
	if pattern == "two_tone" and top != "tank":
		m.capsule("torso", waist_r * 1.04, 0.1 * h, Vector3(0, waist_y - 0.005 * h, 0), c2, Vector3(1.0, 1.0, 0.76), 12)
	match top:
		"shirt", "polo":
			for side: float in [-1.0, 1.0]:
				m.box("torso", Vector3(0.05 * h, 0.022 * h, 0.006 * h), Vector3(side * 0.025 * h, _neck_y - 0.03 * h, front * 0.55),
					c.lightened(0.05), Basis(Vector3.FORWARD, side * 0.5))
			var buttons := 5 if top == "shirt" else 2
			for k in buttons:
				m.sphere("torso", 0.005 * h, Vector3(0, chest_y + 0.06 * h - k * 0.04 * h, front - 0.002 * h), c2, Vector3.ONE, 6)
		"hoodie":
			m.sphere("torso", 0.06 * h, Vector3(0, _neck_y - 0.02 * h, 0.05 * h), c.darkened(0.08), Vector3(1.15, 0.85, 0.75), 10)
			m.box("torso", Vector3(0.12 * h, 0.07 * h, 0.012 * h), Vector3(0, waist_y + 0.02 * h, -waist_r * 0.74), c.darkened(0.06))
			for side: float in [-1.0, 1.0]:
				m.box("torso", Vector3(0.004 * h, 0.07 * h, 0.004 * h), Vector3(side * 0.02 * h, chest_y + 0.02 * h, front - 0.003 * h), c2)
		"sweater":
			m.cylinder("torso", 0.034 * h, 0.036 * h, 0.022 * h, Transform3D(Basis(), Vector3(0, _neck_y - 0.03 * h, 0)), c.darkened(0.15))
			m.cylinder("torso", waist_r * 1.05, waist_r * 1.05, 0.03 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.76)), Vector3(0, hip_y + 0.05 * h, 0)), c.darkened(0.15))
		"jacket":
			m.box("torso", Vector3(0.07 * h, 0.2 * h, 0.01 * h), Vector3(0, chest_y - 0.02 * h, front - 0.002 * h), c2)
			for side: float in [-1.0, 1.0]:
				m.box("torso", Vector3(0.03 * h, 0.1 * h, 0.008 * h), Vector3(side * 0.045 * h, chest_y + 0.04 * h, front - 0.006 * h),
					c.darkened(0.1), Basis(Vector3.FORWARD, side * 0.25))
		"coat":
			m.cylinder("torso", hip_w * 1.08, hip_w * 1.2, 0.2 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.8)), Vector3(0, hip_y - 0.07 * h, 0)), c)
			for k in 4:
				m.sphere("torso", 0.007 * h, Vector3(0.018 * h, chest_y + 0.03 * h - k * 0.07 * h, front - 0.003 * h), c2, Vector3.ONE, 6)
			m.cylinder("torso", 0.038 * h, 0.042 * h, 0.03 * h, Transform3D(Basis(), Vector3(0, _neck_y - 0.025 * h, 0)), c.darkened(0.1))
		"dress":
			m.cylinder("torso", hip_w * 1.02, hip_w * 1.45, 0.22 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.85)), Vector3(0, hip_y - 0.09 * h, 0)), c)
			m.cylinder("torso", waist_r * 1.02, waist_r * 1.02, 0.015 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.76)), Vector3(0, waist_y, 0)), c2)
		"tshirt", "longsleeve":
			m.cylinder("torso", 0.032 * h, 0.034 * h, 0.012 * h, Transform3D(Basis(), Vector3(0, _neck_y - 0.03 * h, 0)), c.darkened(0.12))


## Horizontal bands that follow the torso's taper (and its depth).
func _stripes(m: MeshMerger, pattern: String, top: String, h: float, bottom_y: float, length: float,
		waist_r: float, shoulder_w: float, depth_scale: float, c2: Color) -> void:
	if pattern != "stripes" or top == "tank":
		return
	for k in 6:
		var f := (k + 0.5) / 6.0
		var r := lerpf(waist_r, shoulder_w, f) * 1.025
		var y := bottom_y + length * f
		m.cylinder("torso", r, r, 0.016 * h, Transform3D(Basis().scaled(Vector3(1.0, 1.0, depth_scale)), Vector3(0, y, 0)), c2)


func _bottom_details(m: MeshMerger, bottom: String, dress: bool, h: float, hip_y: float, hip_w: float, c: Color) -> void:
	if dress:
		return
	match bottom:
		"skirt":
			m.cylinder("torso", hip_w * 1.02, hip_w * 1.35, 0.15 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.85)), Vector3(0, hip_y - 0.055 * h, 0)), c)
		"long_skirt":
			m.cylinder("torso", hip_w * 1.02, hip_w * 1.55, 0.44 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.9)), Vector3(0, hip_y - 0.2 * h, 0)), c)
		"jeans", "trousers":
			m.cylinder("torso", hip_w * 0.98, hip_w * 0.98, 0.018 * h, Transform3D(Basis().scaled(Vector3(1, 1, 0.8)), Vector3(0, hip_y + 0.075 * h, 0)), Color(0.13, 0.1, 0.08))
			m.box("torso", Vector3(0.03 * h, 0.02 * h, 0.006 * h), Vector3(0, hip_y + 0.075 * h, -hip_w * 0.82), Color(0.75, 0.7, 0.55))


func _bag(m: MeshMerger, kind: String, c: Color, h: float, chest_y: float, shoulder_x: float, chest_d: float, hip_y: float) -> void:
	var back := chest_d * 1.25
	match kind:
		"backpack":
			m.box("torso", Vector3(0.2 * h, 0.24 * h, 0.09 * h), Vector3(0, chest_y - 0.03 * h, back + 0.045 * h), c)
			m.box("torso", Vector3(0.16 * h, 0.08 * h, 0.03 * h), Vector3(0, chest_y - 0.1 * h, back + 0.1 * h), c.darkened(0.12))
			for side: float in [-1.0, 1.0]:
				m.box("torso", Vector3(0.022 * h, 0.2 * h, 0.012 * h), Vector3(side * shoulder_x * 0.5, chest_y + 0.01 * h, -chest_d * 1.1), c.darkened(0.25))
		"shoulder":
			m.box("torso", Vector3(0.035 * h, 0.1 * h, 0.12 * h), Vector3(shoulder_x * 1.15, hip_y + 0.05 * h, 0), c)
			m.box("torso", Vector3(0.02 * h, 0.42 * h, 0.012 * h), Vector3(0, chest_y - 0.02 * h, -chest_d * 1.18), c.darkened(0.2), Basis(Vector3.FORWARD, 0.72))
		"tote":
			m.box("torso", Vector3(0.03 * h, 0.16 * h, 0.14 * h), Vector3(-shoulder_x * 1.25, hip_y + 0.02 * h, 0), c)
			m.box("torso", Vector3(0.012 * h, 0.2 * h, 0.012 * h), Vector3(-shoulder_x * 1.12, _shoulder_y - 0.1 * h, 0), c.darkened(0.2))


func _build_head(m: MeshMerger, h: float, skin: Color, hair: Color, app: Dictionary, acc: Dictionary) -> void:
	var r := _head_r
	var c := Vector3(0, r * 1.05, 0)
	var face_scale: Vector3 = {"oval": Vector3(0.9, 1.08, 1.0), "round": Vector3(0.98, 1.0, 1.0),
		"square": Vector3(0.97, 1.02, 0.98), "long": Vector3(0.87, 1.16, 0.97)}.get(str(app.face), Vector3(0.9, 1.08, 1.0))
	m.sphere("head", r, c, skin, face_scale, 14)
	# Jaw and chin.
	var jaw := Vector3(0.78, 0.55, 0.85) if app.face != "square" else Vector3(0.88, 0.58, 0.88)
	m.sphere("head", r, c + Vector3(0, -r * 0.38, -r * 0.08), skin, jaw, 12)
	var front := -r * face_scale.z
	if detail:
		m.box("head", Vector3(r * 0.2, r * 0.32, r * 0.2), c + Vector3(0, -r * 0.08, front - r * 0.05), skin.darkened(0.04))  # nose
		for side: float in [-1.0, 1.0]:
			m.sphere("head", r * 0.2, c + Vector3(side * r * face_scale.x, -r * 0.05, r * 0.05), skin.darkened(0.06), Vector3(0.45, 1.0, 0.8), 6)  # ears
		m.box("head", Vector3(r * 0.4, r * 0.06, r * 0.05), c + Vector3(0, -r * 0.42, front * 0.9), skin.darkened(0.28).lerp(Color(0.6, 0.25, 0.25), 0.3))  # mouth
	var eye := AvatarSpec.eye_color(avatar)
	var brow_t: float = {"thin": 0.04, "normal": 0.07, "thick": 0.11}.get(str(app.brows), 0.07)
	for side: float in [-1.0, 1.0]:
		var ep := c + Vector3(side * r * 0.36, r * 0.12, front * 0.88)
		m.sphere("head", r * 0.15, ep, Color(0.95, 0.94, 0.9), Vector3(1.0, 0.8, 0.6), 8)
		m.sphere("head", r * 0.085, ep + Vector3(0, 0, -r * 0.07), eye.darkened(0.2), Vector3(1.0, 1.0, 0.5), 6)
		if detail:
			m.box("head", Vector3(r * 0.32, r * brow_t, r * 0.06), ep + Vector3(0, r * 0.2, -r * 0.03), hair.darkened(0.1), Basis(Vector3.FORWARD, -side * 0.08))
	_hair(m, str(app.hair), r, c, face_scale, hair)
	_beard(m, str(app.beard), r, c, front, skin, hair)
	_glasses(m, str(acc.glasses), r, c, front)
	_headwear(m, str(acc.headwear), Color(str(acc.headwear_color)), r, c, face_scale)


func _hair(m: MeshMerger, style: String, r: float, c: Vector3, f: Vector3, color: Color) -> void:
	var cap := f * Vector3(1.06, 0.96, 1.05)
	var top := c + Vector3(0, r * 0.2, r * 0.16)  # centre of the hair cap
	match style:
		"buzz":
			m.sphere("head", r * 1.015, c + Vector3(0, r * 0.14, r * 0.12), color.lerp(Color(0.5, 0.45, 0.4), 0.15), f * Vector3(1.0, 0.9, 1.0), 12)
		"short", "side":
			m.sphere("head", r * 1.04, top, color, cap * Vector3(1.0, 0.92, 1.0), 12)
			if style == "side":
				m.box("head", Vector3(r * 1.1, r * 0.22, r * 0.5), c + Vector3(r * 0.12, r * 0.74, -r * 0.5), color, Basis(Vector3.FORWARD, 0.25))
		"curly":
			for k in 14:
				var a := k * 2.4
				var ring := 0.55 + 0.35 * float(k % 3) / 2.0
				m.sphere("head", r * 0.32, c + Vector3(cos(a) * r * ring, r * (0.85 - 0.15 * float(k % 3)), sin(a) * r * ring + r * 0.24), color, Vector3.ONE, 6)
			m.sphere("head", r * 1.02, top, color, cap * Vector3(1.0, 0.9, 1.0), 10)
		"afro":
			m.sphere("head", r, c + Vector3(0, r * 0.5, r * 0.42), color, Vector3(1.45, 1.3, 1.25), 12)
		"bob":
			m.sphere("head", r * 1.06, top, color, cap, 12)
			m.box("head", Vector3(r * 2.1, r * 1.2, r * 1.5), c + Vector3(0, -r * 0.35, r * 0.32), color)
		"long":
			m.sphere("head", r * 1.06, top, color, cap, 12)
			m.box("head", Vector3(r * 1.9, r * 2.6, r * 0.55), c + Vector3(0, -r * 1.0, r * 0.66), color)
			for side: float in [-1.0, 1.0]:
				m.box("head", Vector3(r * 0.3, r * 1.9, r * 0.55), c + Vector3(side * r * 0.95, -r * 0.6, r * 0.16), color)
		"ponytail":
			m.sphere("head", r * 1.04, top, color, cap, 12)
			m.add("head", _capsule_mesh(r * 0.22, r * 1.6), Transform3D(Basis(Vector3.RIGHT, 0.45), c + Vector3(0, -r * 0.15, r * 1.25)), color)
		"bun":
			m.sphere("head", r * 1.04, top, color, cap, 12)
			m.sphere("head", r * 0.42, c + Vector3(0, r * 0.95, r * 0.55), color, Vector3.ONE, 8)
		"braid":
			m.sphere("head", r * 1.04, top, color, cap, 12)
			for k in 7:
				m.sphere("head", r * (0.26 - k * 0.012), c + Vector3(0, -r * (0.1 + k * 0.33), r * (1.0 + k * 0.02)), color, Vector3.ONE, 6)


func _beard(m: MeshMerger, style: String, r: float, c: Vector3, front: float, skin: Color, hair: Color) -> void:
	match style:
		"stubble":
			m.sphere("head", r * 1.01, c + Vector3(0, -r * 0.38, -r * 0.08), skin.lerp(hair, 0.35), Vector3(0.8, 0.56, 0.86), 12)
		"mustache":
			m.box("head", Vector3(r * 0.5, r * 0.1, r * 0.1), c + Vector3(0, -r * 0.28, front * 0.97), hair)
		"goatee":
			m.box("head", Vector3(r * 0.45, r * 0.09, r * 0.1), c + Vector3(0, -r * 0.28, front * 0.97), hair)
			m.sphere("head", r * 0.25, c + Vector3(0, -r * 0.7, front * 0.72), hair, Vector3(1.0, 1.1, 0.8), 8)
		"short", "full":
			var big := 1.04 if style == "short" else 1.09
			m.sphere("head", r * big, c + Vector3(0, -r * 0.42, -r * 0.04), hair, Vector3(0.8, 0.55, 0.86), 12)
			m.box("head", Vector3(r * 0.52, r * 0.11, r * 0.12), c + Vector3(0, -r * 0.28, front * 0.97), hair)
			if style == "full":
				m.sphere("head", r * 0.3, c + Vector3(0, -r * 0.82, front * 0.7), hair, Vector3(1.0, 0.9, 0.8), 8)


func _glasses(m: MeshMerger, style: String, r: float, c: Vector3, front: float) -> void:
	if style == "none":
		return
	var frame := Color(0.1, 0.1, 0.11)
	var lens := Color(0.06, 0.07, 0.08) if style == "sun" else Color(0.72, 0.8, 0.86)
	for side: float in [-1.0, 1.0]:
		var p := c + Vector3(side * r * 0.36, r * 0.12, front - r * 0.02)
		if style == "round":
			m.cylinder("head", r * 0.2, r * 0.2, r * 0.03, Transform3D(Basis(Vector3.RIGHT, PI / 2), p), frame)
			m.cylinder("head", r * 0.16, r * 0.16, r * 0.035, Transform3D(Basis(Vector3.RIGHT, PI / 2), p + Vector3(0, 0, -r * 0.004)), lens)
		else:
			m.box("head", Vector3(r * 0.42, r * 0.3, r * 0.03), p, frame)
			m.box("head", Vector3(r * 0.36, r * 0.24, r * 0.035), p + Vector3(0, 0, -r * 0.004), lens)
		m.box("head", Vector3(r * 0.03, r * 0.03, r * 0.9), c + Vector3(side * r * 0.86, r * 0.14, front * 0.45), frame)  # arms
	m.box("head", Vector3(r * 0.18, r * 0.04, r * 0.03), c + Vector3(0, r * 0.16, front - r * 0.02), frame)  # bridge


func _headwear(m: MeshMerger, kind: String, color: Color, r: float, c: Vector3, f: Vector3) -> void:
	match kind:
		"cap":
			m.sphere("head", r * 1.08, c + Vector3(0, r * 0.28, 0.0), color, Vector3(0.96, 0.7, 1.02), 12)
			m.box("head", Vector3(r * 1.35, r * 0.08, r * 0.95), c + Vector3(0, r * 0.38, -r * 1.2), color.darkened(0.2))
		"beanie":
			m.sphere("head", r * 1.1, c + Vector3(0, r * 0.3, r * 0.03), color, Vector3(0.97, 0.85, 1.02), 12)
			m.cylinder("head", r * 1.02, r * 1.04, r * 0.3, Transform3D(Basis().scaled(Vector3(f.x, 1, 1.02)), c + Vector3(0, r * 0.28, r * 0.02)), color.darkened(0.12))
		"hat":
			m.cylinder("head", r * 1.75, r * 1.75, r * 0.06, Transform3D(Basis(), c + Vector3(0, r * 0.62, 0.0)), color)
			m.cylinder("head", r * 0.82, r * 0.98, r * 0.75, Transform3D(Basis(), c + Vector3(0, r * 0.98, 0.0)), color)
			m.cylinder("head", r * 0.99, r * 0.99, r * 0.14, Transform3D(Basis(), c + Vector3(0, r * 0.7, 0.0)), color.darkened(0.45))
		"headscarf":
			# Covers the hair, frames the face and falls over the neck.
			m.sphere("head", r * 1.16, c + Vector3(0, r * 0.12, r * 0.12), color, f * Vector3(1.06, 1.02, 1.06), 12)
			m.cylinder("head", r * 1.1, r * 1.7, r * 1.4, Transform3D(Basis().scaled(Vector3(1, 1, 0.9)), c + Vector3(0, -r * 1.1, r * 0.12)), color.darkened(0.05))
		"bandana":
			m.cylinder("head", r * f.x * 1.03, r * f.x * 1.03, r * 0.28, Transform3D(Basis().scaled(Vector3(1, 1, f.z / f.x)), c + Vector3(0, r * 0.42, 0.0)), color)


static func _capsule_mesh(radius: float, height: float) -> CapsuleMesh:
	var cm := CapsuleMesh.new()
	cm.radius = radius
	cm.height = maxf(height, radius * 2.0)
	cm.radial_segments = 8
	cm.rings = 2
	return cm


# --- animation ---------------------------------------------------------------------

## speed in m/s; pitch in radians (camera pitch of that player).
func animate(speed: float, delta: float, pitch := 0.0) -> void:
	if _hip_l == null:
		return
	var amount := clampf(speed / Protocol.WALK_SPEED, 0.0, 1.4)
	var running := speed > Protocol.WALK_SPEED + 0.5
	_phase = fmod(_phase + delta * (2.0 + speed * 1.9), TAU)
	_breath = fmod(_breath + delta * 1.6, TAU)
	var swing := sin(_phase) * (0.45 if not running else 0.7) * amount
	_hip_l.rotation.x = swing
	_hip_r.rotation.x = -swing
	# Knees bend while each leg swings through behind the body.
	_knee_l.rotation.x = -maxf(0.0, sin(_phase + 1.3)) * (0.7 if not running else 1.3) * amount
	_knee_r.rotation.x = -maxf(0.0, sin(_phase + 1.3 + PI)) * (0.7 if not running else 1.3) * amount
	_shoulder_l.rotation = Vector3(-swing * 0.85, 0, -0.06)
	_shoulder_r.rotation = Vector3(swing * 0.85, 0, 0.06)
	var elbow := 0.25 + (0.35 if running else 0.15) * amount
	_elbow_l.rotation.x = elbow
	_elbow_r.rotation.x = elbow
	# Bob while walking, breathe while standing.
	_root.position.y = absf(sin(_phase)) * 0.025 * amount
	var breathe := sin(_breath) * 0.006 * (1.0 - clampf(amount, 0.0, 1.0))
	_root.scale = Vector3(1.0 + breathe, 1.0, 1.0 + breathe)
	_root.rotation.x = -0.08 * amount if running else 0.0
	_look_pitch = lerpf(_look_pitch, clampf(pitch, -0.7, 0.7) * 0.6, minf(1.0, delta * 10.0))
	_head.rotation.x = _look_pitch
	if _emote_time > 0.0:
		_emote_time -= delta
		var t := _emote_time
		match _emote:
			"wave":
				_shoulder_r.rotation = Vector3(0, 0, 2.7)
				_elbow_r.rotation.x = 0.0
				_elbow_r.rotation.z = sin(t * 14.0) * 0.5
			"nod":
				_head.rotation.x = _look_pitch - absf(sin(t * 9.0)) * 0.35
		if _emote_time <= 0.0:
			_elbow_r.rotation.z = 0.0


func play_emote(kind: String) -> void:
	_emote = kind
	_emote_time = 1.6 if kind == "wave" else 0.8
