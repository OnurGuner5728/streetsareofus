extends SceneTree
## Bakes Quaternius' Universal Animation Library (CC0, Rigify "DEF-" rig)
## onto the Universal Base Characters' skeletons (CC0, UE-style names):
##
##   "$GODOT" --headless --path game -s tools/bake_avatar_anims.gd
##
## Both rigs are in the same T-pose, so each bone's animated world rotation
## relative to its rest is carried over as-is, then turned back into the
## target's local rotations. The hips height is scaled by the hip-height
## ratio. Output: res://assets/characters/anims_<body>.res (AnimationLibrary).

const SOURCE := "res://../art-src/AnimationLibrary_Godot_Standard.glb"
const BODIES := {
	"male": "res://assets/characters/Superhero_Male_FullBody.gltf",
	"female": "res://assets/characters/Superhero_Female_FullBody.gltf",
}
const FPS := 30.0
## The library's idle is a ready-to-fight stance (wide, knees bent, fists).
## For standing in a street: legs and fingers eased towards the rest pose
## (legs straight down, hands open); the hips are then lowered or raised so
## the feet stay on the ground.
const RELAX := {"Idle_Loop": 0.65, "Idle_Talking_Loop": 0.55}
## Source clip -> our name.
const CLIPS := {
	"Idle_Loop": "idle", "Walk_Loop": "walk", "Jog_Fwd_Loop": "jog", "Sprint_Loop": "sprint",
	"Jump_Start": "jump_start", "Jump_Loop": "jump_loop", "Jump_Land": "jump_land",
	"Idle_Talking_Loop": "talk", "Interact": "interact", "Dance_Loop": "dance",
	"Walk_Formal_Loop": "walk_formal", "Push_Loop": "push", "Crouch_Idle_Loop": "crouch",
	"Crouch_Fwd_Loop": "crouch_walk", "Hit_Chest": "hit", "Roll": "roll",
	"Sitting_Enter": "sit_down", "Sitting_Idle_Loop": "sit", "Sitting_Talking_Loop": "sit_talk",
	"Sitting_Exit": "stand_up", "PickUp_Table": "pick_up", "Fixing_Kneeling": "kneel",
}


func _init() -> void:
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	var err := doc.append_from_file(ProjectSettings.globalize_path(SOURCE), state)
	assert(err == OK, "cannot read " + SOURCE)
	var src_root := doc.generate_scene(state)
	var src: Skeleton3D = src_root.find_children("*", "Skeleton3D", true, false)[0]
	var player: AnimationPlayer = src_root.find_children("*", "AnimationPlayer", true, false)[0]
	for body in BODIES:
		var tgt_root: Node = (load(BODIES[body]) as PackedScene).instantiate()
		var tgt: Skeleton3D = tgt_root.find_children("*", "Skeleton3D", true, false)[0]
		var lib := AnimationLibrary.new()
		for clip in CLIPS:
			var anim := player.get_animation(clip)
			if anim == null:
				push_error("missing clip " + clip)
				continue
			var baked := _bake(anim, src, tgt, str(tgt_root.get_path_to(tgt)), clip.ends_with("_Loop"), RELAX.get(clip, 0.0))
			if baked.has_meta("ground_speed") and CLIPS[clip] in ["walk", "jog", "sprint", "walk_formal", "crouch_walk"]:
				print("  %s %s: %.2f m/s over %.2f s" % [body, CLIPS[clip], baked.get_meta("ground_speed"), baked.length])
			lib.add_animation(CLIPS[clip], baked)
		var path := "res://assets/characters/anims_%s.res" % body
		print("%s: %d clips -> %s (%s)" % [body, lib.get_animation_list().size(), path, error_string(ResourceSaver.save(lib, path, ResourceSaver.FLAG_COMPRESS))])
		_bake_body(tgt_root, tgt, body)
		tgt_root.free()
	src_root.free()
	quit()


## Region codes stored in CUSTOM0.w (see avatar_body.gdshader).
const REGIONS := {"pelvis": 0, "spine": 0, "clavicle": 0, "upperarm": 1, "lowerarm": 1, "hand": 2,
	"index": 2, "middle": 2, "ring": 2, "pinky": 2, "thumb": 2, "thigh": 3, "calf": 3, "foot": 4, "ball": 4,
	"neck": 5, "Head": 6}


## The body mesh again, with each vertex's T-pose position and body region
## in CUSTOM0, so the shader can dress and shape the body. LODs are kept.
func _bake_body(scene: Node, skel: Skeleton3D, body: String) -> void:
	var mi: MeshInstance3D
	for m: MeshInstance3D in scene.find_children("*", "MeshInstance3D", true, false):
		if str(m.mesh.surface_get_material(0).resource_name).begins_with("MI_Superhero"):
			mi = m
	var src: ArrayMesh = mi.mesh
	var arrays := src.surface_get_arrays(0)
	var verts: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var bones: PackedInt32Array = arrays[Mesh.ARRAY_BONES]
	var weights: PackedFloat32Array = arrays[Mesh.ARRAY_WEIGHTS]
	var per := bones.size() / verts.size()
	var region_of_bone := []
	for b in skel.get_bone_count():
		var name := skel.get_bone_name(b)
		var r := 0
		for key in REGIONS:
			if name.begins_with(key):
				r = REGIONS[key]
		region_of_bone.append(r)
	var custom := PackedFloat32Array()
	custom.resize(verts.size() * 4)
	# Mesh space -> skeleton space (the mesh node may sit under the skeleton).
	var to_skel := mi.transform if mi.get_parent() == skel else Transform3D()
	for v in verts.size():
		var best := 0
		for k in per:
			if weights[v * per + k] > weights[v * per + best]:
				best = k
		var p := to_skel * verts[v]
		custom[v * 4] = p.x
		custom[v * 4 + 1] = p.y
		custom[v * 4 + 2] = p.z
		custom[v * 4 + 3] = float(region_of_bone[bones[v * per + best]])
	arrays[Mesh.ARRAY_CUSTOM0] = custom
	arrays[Mesh.ARRAY_CUSTOM1] = _drape(verts, arrays[Mesh.ARRAY_NORMAL], arrays[Mesh.ARRAY_INDEX])
	for extra in [Mesh.ARRAY_CUSTOM2, Mesh.ARRAY_CUSTOM3]:
		arrays[extra] = null  # stray UV sets from the glTF
	var lods := {}
	var surface := RenderingServer.mesh_get_surface(src.get_rid(), 0)
	var wide := verts.size() > 65535
	for lod: Dictionary in surface.get("lods", []):
		var bytes: PackedByteArray = lod.index_data
		lods[float(lod.edge_length)] = bytes.to_int32_array() if wide else _u16(bytes)
	var flags := (src.surface_get_format(0) & Mesh.ARRAY_FLAG_USE_8_BONE_WEIGHTS) \
		| (Mesh.ARRAY_CUSTOM_RGBA_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM0_SHIFT) 		| (Mesh.ARRAY_CUSTOM_R_FLOAT << Mesh.ARRAY_FORMAT_CUSTOM1_SHIFT)
	var out := ArrayMesh.new()
	out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays, [], lods, flags)
	# Landmarks for the shader and the attachments (skeleton space, metres).
	var g := func(n: String) -> Vector3: return skel.get_bone_global_rest(skel.find_bone(n)).origin
	var aabb := src.get_aabb()
	out.set_meta("landmarks", {
		"top": aabb.end.y, "head": g.call("Head"), "neck": g.call("neck_01"), "chest": g.call("spine_03"),
		"waist": g.call("spine_01"), "pelvis": g.call("pelvis"), "shoulder": g.call("upperarm_l"),
		"elbow": g.call("lowerarm_l"), "wrist": g.call("hand_l"), "hip": g.call("thigh_l"), "knee": g.call("calf_l"),
		"ankle": g.call("foot_l"), "toe": g.call("ball_leaf_l"),
	})
	var path := "res://assets/characters/body_%s.res" % body
	print("%s body: %d verts, %d lods -> %s" % [body, verts.size(), lods.size(), error_string(ResourceSaver.save(out, path, ResourceSaver.FLAG_COMPRESS))])


static func _relax_weight(bone: String, relax: float) -> float:
	if relax <= 0.0:
		return 0.0
	for leg in ["thigh", "calf", "foot", "ball"]:
		if bone.begins_with(leg):
			return relax
	for finger in ["index", "middle", "ring", "pinky"]:
		if bone.begins_with(finger):
			return minf(1.0, relax * 1.3)
	return 0.0


## How far the hips must move so the lower foot stands where it does at rest.
static func _feet_correction(tgt: Skeleton3D, globals: Array[Basis], hips: int, hip_world: Vector3) -> float:
	var lowest := INF
	for side in ["l", "r"]:
		var chain := []
		var b := tgt.find_bone("foot_" + side)
		while b >= 0 and b != hips:
			chain.push_front(b)
			b = tgt.get_bone_parent(b)
		var pos := hip_world
		for bone: int in chain:
			pos += globals[tgt.get_bone_parent(bone)] * tgt.get_bone_rest(bone).origin
		lowest = minf(lowest, pos.y)
	return tgt.get_bone_global_rest(tgt.find_bone("foot_l")).origin.y - lowest


## Cloth does not follow every muscle: how far each vertex would move
## outwards if the body were smoothed (Laplacian, welded across UV seams).
## The shader pushes clothed vertices out by this much, filling the grooves.
static func _drape(verts: PackedVector3Array, normals: PackedVector3Array, indices: PackedInt32Array) -> PackedFloat32Array:
	var weld := {}
	var id := PackedInt32Array()
	id.resize(verts.size())
	var pos := PackedVector3Array()
	for v in verts.size():
		var key := verts[v].snapped(Vector3.ONE * 0.0005)
		if not weld.has(key):
			weld[key] = pos.size()
			pos.append(verts[v])
		id[v] = weld[key]
	var neighbours := []
	neighbours.resize(pos.size())
	for i in pos.size():
		neighbours[i] = {}
	for t in range(0, indices.size(), 3):
		for k in 3:
			var a := id[indices[t + k]]
			var b := id[indices[t + (k + 1) % 3]]
			neighbours[a][b] = true
			neighbours[b][a] = true
	var smooth := pos.duplicate()
	for iteration in 14:
		var next := smooth.duplicate()
		for i in smooth.size():
			var n: Dictionary = neighbours[i]
			if n.is_empty():
				continue
			var sum := Vector3.ZERO
			for j: int in n:
				sum += smooth[j]
			next[i] = smooth[i].lerp(sum / n.size(), 0.6)
		smooth = next
	var out := PackedFloat32Array()
	out.resize(verts.size())
	for v in verts.size():
		var d := (smooth[id[v]] - pos[id[v]]).dot(normals[v])
		out[v] = clampf(d, 0.0, 0.03)
	return out


static func _u16(bytes: PackedByteArray) -> PackedInt32Array:
	var out := PackedInt32Array()
	out.resize(bytes.size() / 2)
	for i in out.size():
		out[i] = bytes.decode_u16(i * 2)
	return out


static func _map(src_name: String) -> String:
	var n := src_name.trim_prefix("DEF-")
	var side := ""
	if n.ends_with(".L") or n.ends_with(".R"):
		side = "_l" if n.ends_with(".L") else "_r"
		n = n.left(-2)
	var fixed := {"hips": "pelvis", "spine.001": "spine_01", "spine.002": "spine_02", "spine.003": "spine_03",
		"neck": "neck_01", "head": "Head", "shoulder": "clavicle", "upper_arm": "upperarm", "forearm": "lowerarm",
		"hand": "hand", "thigh": "thigh", "shin": "calf", "foot": "foot", "toe": "ball"}
	if fixed.has(n):
		return fixed[n] + side
	# f_index.01 -> index_01, thumb.02 -> thumb_02
	var parts := n.trim_prefix("f_").split(".")
	if parts.size() == 2:
		return "%s_%s%s" % [parts[0], parts[1], side]
	return ""


func _bake(anim: Animation, src: Skeleton3D, tgt: Skeleton3D, skel_path: String, loop: bool, relax := 0.0) -> Animation:
	# Source tracks by bone.
	var rot := {}
	var pos := {}
	for t in anim.get_track_count():
		var bone := str(anim.track_get_path(t).get_concatenated_subnames())
		match anim.track_get_type(t):
			Animation.TYPE_ROTATION_3D:
				rot[bone] = t
			Animation.TYPE_POSITION_3D:
				pos[bone] = t
	var pairs := []  # [src_idx, tgt_idx]
	var tgt_from_src := {}
	for i in src.get_bone_count():
		var j := tgt.find_bone(_map(src.get_bone_name(i)))
		if j >= 0:
			pairs.append([i, j])
			tgt_from_src[j] = i
	var hips_src := src.find_bone("DEF-hips")
	var hips_tgt := tgt.find_bone("pelvis")
	var height_ratio := tgt.get_bone_global_rest(hips_tgt).origin.y / src.get_bone_global_rest(hips_src).origin.y
	var out := Animation.new()
	out.length = anim.length
	out.loop_mode = Animation.LOOP_LINEAR if loop else Animation.LOOP_NONE
	var tracks := {}
	for p in pairs:
		var j: int = p[1]
		var t := out.add_track(Animation.TYPE_ROTATION_3D)
		out.track_set_path(t, NodePath("%s:%s" % [skel_path, tgt.get_bone_name(j)]))
		tracks[j] = t
	var hip_pos := out.add_track(Animation.TYPE_POSITION_3D)
	out.track_set_path(hip_pos, NodePath("%s:pelvis" % skel_path))
	var frames := maxi(1, ceili(anim.length * FPS))
	var toe := src.find_bone("DEF-toe.L")
	var toe_track := []  # [time, y, z] of the left toe, to measure the stride
	for f in frames + 1:
		var time := minf(f / FPS, anim.length)
		# Source pose: local transforms -> globals (parents come first).
		var sg: Array[Transform3D] = []
		sg.resize(src.get_bone_count())
		for i in src.get_bone_count():
			var name := src.get_bone_name(i)
			var local := src.get_bone_rest(i)
			var q := local.basis.get_rotation_quaternion()
			var o := local.origin
			if rot.has(name):
				q = anim.rotation_track_interpolate(rot[name], time)
			if pos.has(name):
				o = anim.position_track_interpolate(pos[name], time)
			local = Transform3D(Basis(q).scaled(local.basis.get_scale()), o)
			var parent := src.get_bone_parent(i)
			sg[i] = sg[parent] * local if parent >= 0 else local
		# Target: same world rotation relative to rest.
		var tg: Array[Basis] = []
		tg.resize(tgt.get_bone_count())
		var locals := {}
		for j in tgt.get_bone_count():
			var parent := tgt.get_bone_parent(j)
			var parent_g: Basis = tg[parent] if parent >= 0 else Basis()
			var rest_g := tgt.get_bone_global_rest(j).basis.orthonormalized()
			var g: Basis
			if tgt_from_src.has(j):
				var i: int = tgt_from_src[j]
				var delta := sg[i].basis.orthonormalized() * src.get_bone_global_rest(i).basis.orthonormalized().inverse()
				g = delta * rest_g
			else:
				g = parent_g * tgt.get_bone_rest(j).basis.orthonormalized()
			var local_q := (parent_g.inverse() * g).orthonormalized().get_rotation_quaternion()
			var ease := _relax_weight(tgt.get_bone_name(j), relax)
			if ease > 0.0:
				local_q = local_q.slerp(tgt.get_bone_rest(j).basis.get_rotation_quaternion(), ease)
				g = parent_g * Basis(local_q)
			tg[j] = g
			locals[j] = local_q
		toe_track.append([time, sg[toe].origin.y, sg[toe].origin.z])
		var hip_world := sg[hips_src].origin * height_ratio
		if relax > 0.0:
			hip_world.y += _feet_correction(tgt, tg, hips_tgt, hip_world)
		var root_g := tgt.get_bone_global_rest(tgt.get_bone_parent(hips_tgt))
		out.position_track_insert_key(hip_pos, time, root_g.affine_inverse() * hip_world)
		for j in tracks:
			out.rotation_track_insert_key(tracks[j], time, locals[j])
	out.optimize()
	# Ground speed of an in-place loop: how fast the planted foot slides back.
	if loop:
		var low := INF
		for e in toe_track:
			low = minf(low, e[1])
		var speeds := []
		for k in range(1, toe_track.size()):
			var a: Array = toe_track[k - 1]
			var b: Array = toe_track[k]
			if a[1] < low + 0.015 and b[1] < low + 0.015:
				speeds.append(-(b[2] - a[2]) / (b[0] - a[0]) * height_ratio)
		if speeds.size() > 2:
			speeds.sort()
			out.set_meta("ground_speed", absf(speeds[speeds.size() / 2]))
	return out
