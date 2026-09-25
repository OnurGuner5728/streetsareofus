class_name AvatarView
extends Node3D
## A real, rigged person: Quaternius' Universal Base Characters (CC0, male
## and female bodies, ~14k triangles, 8 LODs) animated with the Universal
## Animation Library (CC0), retargeted by tools/bake_avatar_anims.gd.
##
## Everything comes from the avatar dictionary the network carries:
## - height scales the model, legs/head scale bones, face shape the head;
## - weight, muscle, chest, hips and shoulders reshape the body in
##   avatar_body.gdshader, which also paints the clothes on (with a bit of
##   thickness) from each vertex's T-pose position;
## - hair, brows and beards are the pack's meshes on the head bone;
## - skirts, coat tails, hoods, collars, hats, glasses, bags and scarves are
##   small merged meshes on bones.
## Locomotion follows the speed (idle, walk, jog, sprint, jump, fall); an
## AvatarPoser adds where the player looks, waving and nodding.
## Faces -Z, like the camera, so rotation.y = yaw.

const DIR := "res://assets/characters/"
const BODY_SCENES := {
	"male": preload("res://assets/characters/Superhero_Male_FullBody.gltf"),
	"female": preload("res://assets/characters/Superhero_Female_FullBody.gltf"),
}
const BODY_MESHES := {
	"male": preload("res://assets/characters/body_male.res"),
	"female": preload("res://assets/characters/body_female.res"),
}
const ANIMS := {
	"male": preload("res://assets/characters/anims_male.res"),
	"female": preload("res://assets/characters/anims_female.res"),
}
const BODY_SHADER := preload("res://client/shaders/avatar_body.gdshader")
const HAIR_SHADER := preload("res://client/shaders/avatar_hair.gdshader")
const EYE_SHADER := preload("res://client/shaders/avatar_eyes.gdshader")
## Our hairstyle -> pack mesh per body type (the pack models each for one body).
const HAIR_MESHES := {
	"buzz": {"male": "Hair_Buzzed", "female": "Hair_BuzzedFemale"},
	"short": {"male": "Hair_SimpleParted", "female": "Hair_SimpleParted"},
	"long": {"male": "Hair_Long", "female": "Hair_Long"},
	"bun": {"male": "Hair_Buns", "female": "Hair_Buns"},
}
const HAIR_BODY := {"Hair_Buzzed": "male", "Hair_SimpleParted": "male", "Hair_Beard": "male", "Eyebrows_Regular": "male",
	"Hair_BuzzedFemale": "female", "Hair_Buns": "female", "Hair_Long": "female", "Eyebrows_Female": "female"}
## The base texture's skin colour (sRGB), recoloured to the chosen skin.
const SKIN_REFERENCE := Color(0.665, 0.467, 0.323)
## Natural ground speed of the in-place loops (m/s), for foot-matched playback.
const CLIP_SPEED := {"walk": 1.25, "jog": 3.4, "sprint": 6.0}
const FACE_SCALE := {"oval": Vector3(0.97, 1.02, 1.0), "round": Vector3(1.04, 0.97, 1.0),
	"square": Vector3(1.04, 1.0, 1.0), "long": Vector3(0.95, 1.06, 1.0)}

static var _skeleton_rest := {}  # body type -> {bone name: global rest}
static var _hair_cache := {}  # name -> [Mesh, Transform3D]

var avatar := {}
var visual_height := 1.7
var detail := true
var talking := false
var sitting := false

var _body := "male"
var _model: Node3D
var _skel: Skeleton3D
var _anim: AnimationPlayer
var _poser: AvatarPoser
var _clip := ""
var _air := 0.0
var _land := 0.0
var _emote := ""
var _emote_left := 0.0
var _dance_left := 0.0
var _transition := 0.0  # sitting down / standing up in progress
var _lm := {}
var _mat: ShaderMaterial


func build(new_avatar: Dictionary, with_detail := true) -> void:
	avatar = AvatarSpec.sanitize(new_avatar)
	detail = with_detail
	for child in get_children():
		child.queue_free()
	_clip = ""
	var app: Dictionary = avatar.appearance
	_body = str(app.body_type)
	var mesh: ArrayMesh = BODY_MESHES[_body]
	_lm = mesh.get_meta("landmarks")
	visual_height = AvatarSpec.visual_height(avatar)
	# The model: the pack's scene (skeleton, eyes), our body mesh.
	_model = BODY_SCENES[_body].instantiate()
	_model.name = "Model"
	_model.rotation.y = PI  # the pack faces +Z
	_model.scale = Vector3.ONE * (visual_height / float(_lm.top))
	add_child(_model)
	_skel = _model.find_children("*", "Skeleton3D", true, false)[0]
	for mi: MeshInstance3D in _skel.find_children("*", "MeshInstance3D", true, false):
		var mat_name := str(mi.mesh.surface_get_material(0).resource_name)
		if mat_name.begins_with("MI_Superhero"):
			mi.mesh = mesh
			_mat = _body_material()
			mi.material_override = _mat
		elif mat_name == "MI_Eyes":
			var eyes := ShaderMaterial.new()
			eyes.shader = EYE_SHADER
			eyes.set_shader_parameter("eye_tex", load(DIR + "T_Eye_Brown.png"))
			eyes.set_shader_parameter("iris_color", AvatarSpec.eye_color(avatar))
			mi.material_override = eyes
		else:
			mi.free()  # the built-in brows: replaced below
			continue
		if not detail:
			mi.lod_bias = 0.4
	_shape_bones()
	# Hair, brows, beard.
	var hair_c := Color(str(app.hair_color))
	var thin: bool = app.brows == "thin" or (_body == "female" and app.brows == "normal")
	var brow_node := _hair_mesh("Eyebrows_Female" if thin else "Eyebrows_Regular", hair_c.darkened(0.15))
	if app.brows == "thick":
		# Thicker around the brows' own centre, not the skeleton's origin.
		var centre := brow_node.transform * (brow_node.mesh as Mesh).get_aabb().get_center()
		brow_node.transform = Transform3D(Basis(), centre) * Transform3D(Basis().scaled(Vector3(1.03, 1.3, 1.03)), Vector3.ZERO) 			* Transform3D(Basis(), -centre) * brow_node.transform
	var style := str(app.hair)
	if HAIR_MESHES.has(style):
		_hair_mesh(HAIR_MESHES[style][_body], hair_c)
	if app.beard == "full":
		_hair_mesh("Hair_Beard", hair_c)
	# Everything else that sits on bones.
	var m := MeshMerger.new()
	_hair_extras(m, style, hair_c)
	_clothes_extras(m)
	_accessories(m)
	for bone: String in m.groups():
		m.emit(bone, _attach(bone), MeshMerger.vertex_colour_material(0.85))
	# Animation.
	_anim = AnimationPlayer.new()
	_anim.name = "Anim"
	_model.add_child(_anim)
	_anim.root_node = _anim.get_path_to(_model)
	_anim.add_animation_library("", ANIMS[_body])
	_anim.callback_mode_process = AnimationMixer.ANIMATION_CALLBACK_MODE_PROCESS_MANUAL
	_poser = AvatarPoser.new()
	_skel.add_child(_poser)
	_play("idle", 0.0)
	_anim.advance(randf() * 2.0)  # people don't breathe in sync


func _body_material() -> ShaderMaterial:
	var app: Dictionary = avatar.appearance
	var cl: Dictionary = avatar.clothing
	var b: Dictionary = avatar.body
	var lm := _lm
	var mat := ShaderMaterial.new()
	mat.shader = BODY_SHADER
	var tex_name := "T_Superhero_Male_Ligh.png" if _body == "male" else "T_Superhero_Female_Light_BaseColor.png"
	mat.set_shader_parameter("skin_tex", load(DIR + tex_name))
	mat.set_shader_parameter("normal_tex", load(DIR + "T_Superhero_%s_Normal.png" % _body.capitalize()))
	var skin := AvatarSpec.skin_color(avatar).srgb_to_linear()
	var ref := SKIN_REFERENCE.srgb_to_linear()
	mat.set_shader_parameter("skin_tint", Vector3(skin.r / ref.r, skin.g / ref.g, skin.b / ref.b))
	mat.set_shader_parameter("face_hair_color", Color(str(app.hair_color)).darkened(0.1))
	mat.set_shader_parameter("face_hair", {"stubble": 1, "mustache": 2, "goatee": 3, "short": 4, "full": 4}.get(str(app.beard), 0))
	mat.set_shader_parameter("lm_y", Vector4(lm.neck.y, lm.chest.y, lm.waist.y, lm.pelvis.y))
	mat.set_shader_parameter("lm_x", Vector4(lm.shoulder.x, lm.elbow.x, lm.wrist.x, lm.hip.x))
	mat.set_shader_parameter("lm_y2", Vector4(lm.knee.y, lm.ankle.y, lm.head.y, lm.top))
	mat.set_shader_parameter("female", 1.0 if _body == "female" else 0.0)
	var d: Dictionary = AvatarSpec.defaults().body
	for key in ["weight", "muscle", "chest", "hips", "shoulders"]:
		mat.set_shader_parameter(key + "_d", float(b[key]) - float(d[key]))
	# Top.
	var top := str(cl.top)
	var sh: float = lm.shoulder.x
	var el: float = lm.elbow.x
	var wr: float = lm.wrist.x
	var pelvis_y: float = lm.pelvis.y
	var knee_y: float = lm.knee.y
	var sleeve: float = {"tshirt": lerpf(sh, el, 0.45), "polo": lerpf(sh, el, 0.45), "dress": lerpf(sh, el, 0.3), "tank": 0.0,
		"longsleeve": wr - 0.02, "shirt": wr - 0.015, "hoodie": wr - 0.01, "sweater": wr - 0.015, "jacket": wr - 0.01,
		"coat": wr}.get(top, wr)
	var hem: float = {"tshirt": pelvis_y - 0.04, "tank": pelvis_y - 0.02, "polo": pelvis_y - 0.04, "shirt": pelvis_y - 0.07,
		"longsleeve": pelvis_y - 0.04, "hoodie": pelvis_y - 0.06, "sweater": pelvis_y - 0.05,
		"jacket": pelvis_y - 0.09, "coat": knee_y + 0.12, "dress": knee_y + 0.06}.get(top, pelvis_y)
	mat.set_shader_parameter("top_color", Color(str(cl.top_color)))
	mat.set_shader_parameter("top_color2", Color(str(cl.top_color2)))
	mat.set_shader_parameter("sleeve_x", sleeve)
	mat.set_shader_parameter("top_hem_y", hem)
	mat.set_shader_parameter("neck_front", {"tank": 0.1, "dress": 0.08, "shirt": 0.07, "polo": 0.05, "tshirt": 0.045,
		"jacket": 0.13, "coat": 0.06, "hoodie": 0.02, "sweater": 0.02, "longsleeve": 0.04}.get(top, 0.04))
	mat.set_shader_parameter("neck_high", {"hoodie": 0.02, "coat": 0.05, "sweater": 0.03}.get(top, 0.0))
	mat.set_shader_parameter("open_front", 0.07 if top == "jacket" else 0.0)
	mat.set_shader_parameter("bare_shoulders", 1.0 if top == "tank" else 0.0)
	mat.set_shader_parameter("top_thick", {"tank": 0.003, "tshirt": 0.004, "polo": 0.004, "shirt": 0.005, "longsleeve": 0.004,
		"dress": 0.004, "hoodie": 0.012, "sweater": 0.01, "jacket": 0.014, "coat": 0.02}.get(top, 0.006))
	mat.set_shader_parameter("top_drape", {"tank": 0.5, "tshirt": 0.8, "polo": 0.8, "dress": 0.7, "longsleeve": 0.75}.get(top, 1.0))
	mat.set_shader_parameter("bottom_drape", {"sweatpants": 1.0, "trousers": 0.9, "shorts": 0.9}.get(str(cl.bottom), 0.7))
	mat.set_shader_parameter("top_rough", {"jacket": 0.55, "coat": 0.7, "shirt": 0.75}.get(top, 0.88))
	var pattern: int = {"plain": 0, "stripes": 1, "two_tone": 2}.get(str(cl.pattern), 0)
	if pattern == 0 and top in ["shirt", "polo"]:
		pattern = 3
	elif pattern == 0 and top == "hoodie":
		pattern = 4
	mat.set_shader_parameter("pattern", pattern)
	# Bottom.
	var bottom := str(cl.bottom)
	var hip_y: float = lm.hip.y
	mat.set_shader_parameter("bottom_color", Color(str(cl.bottom_color)))
	mat.set_shader_parameter("bottom_waist_y", float(lm.waist.y) - 0.03)
	mat.set_shader_parameter("bottom_hem_y", {"shorts": knee_y + 0.1, "skirt": hip_y - 0.06, "long_skirt": hip_y - 0.06}.get(bottom, float(lm.ankle.y) + 0.035))
	mat.set_shader_parameter("bottom_thick", {"jeans": 0.005, "trousers": 0.006, "sweatpants": 0.011, "shorts": 0.006}.get(bottom, 0.004))
	mat.set_shader_parameter("denim", 1.0 if bottom == "jeans" else 0.0)
	# Shoes.
	var shoes := str(cl.shoes)
	var ankle_y: float = lm.ankle.y
	mat.set_shader_parameter("shoe_color", Color(str(cl.shoes_color)))
	mat.set_shader_parameter("sole_color", Color(0.92, 0.92, 0.9) if shoes == "sneakers" else Color(0.1, 0.08, 0.07))
	mat.set_shader_parameter("shoe_top_y", {"boots": ankle_y + 0.1, "sneakers": ankle_y + 0.03, "formal": ankle_y + 0.01, "sandals": 0.03}.get(shoes, 0.1))
	mat.set_shader_parameter("shoe_thick", {"boots": 0.014, "sneakers": 0.012, "formal": 0.008, "sandals": 0.004}.get(shoes, 0.01))
	mat.set_shader_parameter("sandal", 1.0 if shoes == "sandals" else 0.0)
	return mat


## Legs and head size, face shape: bone scales (the animation never keys scale).
func _shape_bones() -> void:
	var b: Dictionary = avatar.body
	var legs := lerpf(0.94, 1.06, float(b.legs))
	for side in ["l", "r"]:
		_skel.set_bone_pose_scale(_skel.find_bone("thigh_" + side), Vector3(1.0, legs, 1.0))
	_model.position.y = (legs - 1.0) * float(_lm.hip.y) * _model.scale.y
	var head := lerpf(0.93, 1.07, float(b.head))
	var face: Vector3 = FACE_SCALE.get(str(avatar.appearance.face), Vector3.ONE)
	_skel.set_bone_pose_scale(_skel.find_bone("Head"), face * head)


## A node that follows `bone`, in which content is placed in T-pose
## skeleton space (so attachments are authored against the landmarks).
func _attach(bone: String) -> Node3D:
	var holder := BoneAttachment3D.new()
	holder.bone_name = bone
	_skel.add_child(holder)
	var inner := Node3D.new()
	inner.transform = _skel.get_bone_global_rest(_skel.find_bone(bone)).affine_inverse()
	holder.add_child(inner)
	return inner


func _hair_mesh(name: String, color: Color) -> Node3D:
	if not _hair_cache.has(name):
		var scene: Node = load(DIR + "hair/%s.gltf" % name).instantiate()
		var mi: MeshInstance3D = scene.find_children("*", "MeshInstance3D", true, false)[0]
		_hair_cache[name] = [mi.mesh, mi.transform]
		scene.free()
	var entry: Array = _hair_cache[name]
	var node := MeshInstance3D.new()
	node.mesh = entry[0]
	# Moved from the head it was modelled on to this body's head.
	var src_head := _rest(str(HAIR_BODY.get(name, _body)), "Head")
	var dst_head := _skel.get_bone_global_rest(_skel.find_bone("Head"))
	node.transform = Transform3D(Basis(), dst_head.origin - src_head.origin) * (entry[1] as Transform3D)
	var mat := ShaderMaterial.new()
	mat.shader = HAIR_SHADER
	var tex := "T_Hair_2" if HAIR_BODY.get(name) == "female" else "T_Hair_1"
	mat.set_shader_parameter("hair_tex", load(DIR + "hair/%s_BaseColor.png" % tex))
	mat.set_shader_parameter("normal_tex", load(DIR + "hair/%s_Normal.png" % tex))
	mat.set_shader_parameter("hair_color", color)
	node.material_override = mat
	_attach("Head").add_child(node)
	return node


static func _rest(body: String, bone: String) -> Transform3D:
	if not _skeleton_rest.has(body):
		var scene: Node = BODY_SCENES[body].instantiate()
		var sk: Skeleton3D = scene.find_children("*", "Skeleton3D", true, false)[0]
		var rests := {}
		for i in sk.get_bone_count():
			rests[sk.get_bone_name(i)] = sk.get_bone_global_rest(i)
		_skeleton_rest[body] = rests
		scene.free()
	return _skeleton_rest[body].get(bone, Transform3D())


# --- attachments (T-pose skeleton space: +Z front, +X the left side) --------------

func _head_frame() -> Array:
	var head: Vector3 = _lm.head
	var r := (float(_lm.top) - head.y) * 0.5
	return [Vector3(0, head.y + r, head.z + 0.012), r]


func _hair_extras(m: MeshMerger, style: String, color: Color) -> void:
	var hf := _head_frame()
	var c: Vector3 = hf[0]
	var r: float = hf[1]
	match style:
		"curly":
			for k in 26:
				var a := k * 2.39996
				var up := 0.35 + 0.6 * fmod(k * 0.618, 1.0)
				var flat := sqrt(1.0 - up * up)
				var dir := Vector3(cos(a) * flat, up, sin(a) * flat - 0.25).normalized()
				if dir.z > 0.55 and dir.y < 0.6:
					continue  # keep the face clear
				m.sphere("Head", r * 0.3, c + dir * r * 0.98, color.darkened(fmod(k * 0.37, 0.2)), Vector3.ONE, 6)
			m.sphere("Head", r * 1.04, c + Vector3(0, r * 0.18, -r * 0.12), color, Vector3(1.0, 0.9, 1.0), 10)
		"afro":
			m.sphere("Head", r * 1.55, c + Vector3(0, r * 0.45, -r * 0.35), color, Vector3(1.0, 0.88, 0.92), 12)


func _clothes_extras(m: MeshMerger) -> void:
	var cl: Dictionary = avatar.clothing
	var top := str(cl.top)
	var bottom := str(cl.bottom)
	var tc := Color(str(cl.top_color))
	var t2 := Color(str(cl.top_color2))
	var bc := Color(str(cl.bottom_color))
	var lm := _lm
	var pelvis: Vector3 = lm.pelvis
	var hip_w: float = float(lm.hip.x) + (0.085 if _body == "female" else 0.075) \
		+ (float(avatar.body.weight) - 0.4) * 0.05 + (float(avatar.body.hips) - 0.45) * 0.06
	var knee: float = lm.knee.y
	# Skirts and the lower part of dresses and coats: cones on the pelvis.
	var skirts := []  # [top_y, bottom_y, flare, colour]
	match bottom:
		"skirt":
			skirts.append([pelvis.y + 0.07, knee + 0.1, 1.45, bc])
		"long_skirt":
			skirts.append([pelvis.y + 0.07, float(lm.ankle.y) + 0.05, 2.1, bc])
	if top == "dress":
		skirts.append([pelvis.y + 0.06, knee + 0.02, 1.35, tc])
	elif top == "coat":
		skirts.append([pelvis.y + 0.05, knee + 0.1, 1.22, tc])
	for sk: Array in skirts:
		var top_y: float = sk[0]
		var low_y: float = sk[1]
		var flare: float = sk[2]
		var col: Color = sk[3]
		var squash := Basis().scaled(Vector3(1.0, 1.0, 0.82))
		m.cylinder("pelvis", hip_w, hip_w * flare, top_y - low_y, Transform3D(squash, Vector3(0, (top_y + low_y) * 0.5, pelvis.z + 0.01)), col)
		m.cylinder("pelvis", hip_w * flare * 1.01, hip_w * flare * 1.01, 0.012, Transform3D(squash, Vector3(0, low_y + 0.006, pelvis.z + 0.01)), col.darkened(0.15))
	var neck: Vector3 = lm.neck
	var chest_y: float = lm.chest.y
	match top:
		"hoodie":
			# The hood, bunched up behind the neck.
			m.sphere("spine_03", 0.1, Vector3(0, neck.y - 0.01, neck.z - 0.09), tc.darkened(0.06), Vector3(1.25, 0.7, 0.8), 10)
		"shirt", "polo":
			for side: float in [-1.0, 1.0]:
				m.box("neck_01", Vector3(0.05, 0.028, 0.006), Vector3(side * 0.03, neck.y - 0.015, neck.z + 0.075),
					tc.lightened(0.06), Basis(Vector3.FORWARD, side * 0.6) * Basis(Vector3.RIGHT, -0.4))
		"coat":
			m.cylinder("spine_03", 0.085, 0.1, 0.06, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.9)), Vector3(0, neck.y - 0.01, neck.z + 0.005)), tc.darkened(0.1))
			for k in 4:
				m.sphere("spine_03", 0.008, Vector3(0.03, chest_y + 0.05 - k * 0.1, 0.13), t2, Vector3.ONE, 6)
		"jacket":
			for side: float in [-1.0, 1.0]:
				m.box("spine_03", Vector3(0.035, 0.13, 0.008), Vector3(side * 0.06, chest_y + 0.07, 0.125),
					tc.darkened(0.12), Basis(Vector3.FORWARD, side * 0.3) * Basis(Vector3.RIGHT, -0.25))


func _accessories(m: MeshMerger) -> void:
	var acc: Dictionary = avatar.accessories
	var hf := _head_frame()
	var c: Vector3 = hf[0]
	var r: float = hf[1]
	var hc := Color(str(acc.headwear_color))
	var lm := _lm
	var eye_y := float(lm.head.y) + r * 0.95
	var front := c.z + r * 0.92
	match str(acc.headwear):
		"cap":
			m.add("Head", _dome(r * 1.1, r * 1.0), Transform3D(Basis(), c + Vector3(0, r * 0.28, -r * 0.05)), hc)
			m.cylinder("Head", r * 0.8, r * 0.8, 0.008, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.75)), c + Vector3(0, r * 0.3, r * 0.85)), hc.darkened(0.1))
		"beanie":
			m.add("Head", _dome(r * 1.12, r * 1.3), Transform3D(Basis(), c + Vector3(0, r * 0.2, -r * 0.05)), hc)
			m.cylinder("Head", r * 1.14, r * 1.14, r * 0.3, Transform3D(Basis(), c + Vector3(0, r * 0.32, -r * 0.05)), hc.darkened(0.12))
		"hat":
			m.cylinder("Head", r * 1.75, r * 1.75, 0.01, Transform3D(Basis(), c + Vector3(0, r * 0.45, -r * 0.05)), hc)
			m.cylinder("Head", r * 0.92, r * 1.05, r * 0.85, Transform3D(Basis(), c + Vector3(0, r * 0.88, -r * 0.05)), hc)
			m.cylinder("Head", r * 1.06, r * 1.07, r * 0.2, Transform3D(Basis(), c + Vector3(0, r * 0.55, -r * 0.05)), hc.darkened(0.35))
		"headscarf":
			m.add("Head", _dome(r * 1.14, r * 1.2), Transform3D(Basis(), c + Vector3(0, r * 0.05, -r * 0.06)), hc)
			m.cylinder("Head", r * 1.12, r * 1.2, r * 1.5, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.9)), c + Vector3(0, -r * 0.7, -r * 0.28)), hc)
			m.cylinder("neck_01", 0.07, 0.11, 0.1, Transform3D(Basis(), Vector3(0, float(lm.neck.y) - 0.03, float(lm.neck.z) + 0.01)), hc.darkened(0.05))
		"bandana":
			m.cylinder("Head", r * 1.06, r * 1.06, r * 0.28, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 1.08)), c + Vector3(0, r * 0.45, -r * 0.03)), hc)
	var glasses := str(acc.glasses)
	if glasses != "none" and detail:
		var frame := Color(0.08, 0.08, 0.09) if glasses != "round" else Color(0.45, 0.33, 0.18)
		for side: float in [-1.0, 1.0]:
			var lens := Vector3(side * 0.032, eye_y, front + 0.012)
			if glasses == "sun":
				m.box("Head", Vector3(0.044, 0.028, 0.004), lens, Color(0.05, 0.05, 0.06))
			if glasses == "round":
				for k in 10:
					var a := k * TAU / 10.0
					m.box("Head", Vector3(0.008, 0.003, 0.003), lens + Vector3(cos(a), sin(a), 0) * 0.019, frame, Basis(Vector3.BACK, a + PI / 2.0))
			else:
				m.box("Head", Vector3(0.046, 0.004, 0.004), lens + Vector3(0, 0.015, 0), frame)
				m.box("Head", Vector3(0.046, 0.003, 0.004), lens + Vector3(0, -0.014, 0), frame)
				m.box("Head", Vector3(0.004, 0.03, 0.004), lens + Vector3(side * 0.023, 0, 0), frame)
			m.box("Head", Vector3(0.004, 0.004, r * 1.05), Vector3(side * r * 0.9, eye_y + 0.01, front - r * 0.5), frame)
		m.box("Head", Vector3(0.018, 0.004, 0.004), Vector3(0, eye_y + 0.008, front + 0.014), frame)
	var bag_c := Color(str(acc.bag_color))
	var chest: Vector3 = lm.chest
	var hip_x: float = lm.hip.x
	var pelvis_y: float = lm.pelvis.y
	match str(acc.bag):
		"backpack":
			m.box("spine_03", Vector3(0.28, 0.36, 0.13), Vector3(0, chest.y - 0.1, chest.z - 0.19), bag_c)
			m.box("spine_03", Vector3(0.22, 0.12, 0.04), Vector3(0, chest.y - 0.2, chest.z - 0.27), bag_c.darkened(0.12))
			for side: float in [-1.0, 1.0]:
				m.box("spine_03", Vector3(0.035, 0.28, 0.012), Vector3(side * 0.085, chest.y + 0.02, chest.z + 0.125), bag_c.darkened(0.25), Basis(Vector3.RIGHT, 0.2))
		"shoulder":
			m.box("spine_02", Vector3(0.03, 0.6, 0.012), Vector3(0.0, chest.y - 0.12, chest.z + 0.13), bag_c.darkened(0.2), Basis(Vector3.BACK, 0.75))
			m.box("pelvis", Vector3(0.06, 0.2, 0.24), Vector3(-hip_x - 0.12, pelvis_y + 0.02, 0.0), bag_c)
		"tote":
			m.box("clavicle_l", Vector3(0.012, 0.32, 0.02), Vector3(float(lm.shoulder.x) - 0.03, chest.y - 0.05, 0.02), bag_c.darkened(0.2))
			m.box("spine_01", Vector3(0.06, 0.3, 0.28), Vector3(hip_x + 0.12, pelvis_y - 0.02, 0.0), bag_c)
	if acc.scarf == "scarf":
		var sc := Color(str(acc.scarf_color))
		var neck: Vector3 = lm.neck
		m.cylinder("neck_01", 0.078, 0.085, 0.07, Transform3D(Basis().scaled(Vector3(1.0, 1.0, 0.95)), Vector3(0, neck.y - 0.03, neck.z + 0.01)), sc)
		m.box("spine_03", Vector3(0.07, 0.3, 0.02), Vector3(0.05, chest.y - 0.02, chest.z + 0.14), sc.darkened(0.08), Basis(Vector3.RIGHT, -0.12))


static func _dome(radius: float, height: float) -> SphereMesh:
	var sm := SphereMesh.new()
	sm.is_hemisphere = true
	sm.radius = radius
	sm.height = height
	sm.radial_segments = 14
	sm.rings = 5
	return sm


# --- animation ---------------------------------------------------------------------

## speed in m/s; pitch in radians (camera pitch of that player); air when
## the player is off the ground.
func animate(speed: float, delta: float, pitch := 0.0, air := false) -> void:
	if _anim == null:
		return
	var want := "idle"
	var rate := 1.0
	var seated_clips := ["sit", "sit_talk", "sit_down"]
	if speed > 0.6 or air or sitting:
		_dance_left = 0.0
	if _transition > 0.0:
		_transition -= delta
	if sitting:
		if not _clip in seated_clips:
			want = "sit_down"
			_transition = 1.1
		elif _transition > 0.0:
			want = _clip
		else:
			want = "sit_talk" if talking else "sit"
	elif _clip in seated_clips and speed < 0.6:
		want = "stand_up"
		_transition = 0.8
	elif _clip == "stand_up" and _transition > 0.0 and speed < 0.6:
		want = "stand_up"
	elif _dance_left > 0.0:
		_dance_left -= delta
		want = "dance"
	elif air:
		_air += delta
		want = "jump_loop" if _air > 0.12 or _clip == "" else _clip
	else:
		if _air > 0.35:
			_land = 0.3
		_air = 0.0
		if _land > 0.0:
			_land -= delta
			want = "jump_land"
		elif speed > 4.3:
			want = "sprint"
			rate = clampf(speed / CLIP_SPEED.sprint, 0.7, 1.3)
		elif speed > 2.9:
			want = "jog"
			rate = clampf(speed / CLIP_SPEED.jog, 0.75, 1.4)
		elif speed > 0.2:
			want = "walk"
			rate = clampf(speed / CLIP_SPEED.walk, 0.6, 1.9)
		elif talking:
			want = "talk"
	if want != _clip:
		_play(want, 0.12 if want == "jump_land" else 0.25)
	_anim.speed_scale = rate
	_anim.advance(delta)
	_poser.look_pitch = lerpf(_poser.look_pitch, clampf(pitch, -0.8, 0.8), minf(1.0, delta * 10.0))
	if _emote_left > 0.0:
		_emote_left -= delta
		var total := 1.6 if _emote == "wave" else 0.9
		var fade := clampf(minf(_emote_left, total - _emote_left) * 5.0, 0.0, 1.0)
		if _emote == "wave":
			_poser.wave = fade
			_poser.wave_time += delta
		else:
			_poser.nod = fade
			_poser.nod_time += delta
	else:
		_poser.wave = 0.0
		_poser.nod = 0.0


func _play(clip: String, blend: float) -> void:
	_clip = clip
	_anim.play(clip, blend)


func play_emote(kind: String) -> void:
	if kind == "dance":
		_dance_left = 8.0
		return
	_emote = kind
	_emote_left = 1.6 if kind == "wave" else 0.9
	if _poser:
		_poser.wave_time = 0.0
		_poser.nod_time = 0.0
