class_name AvatarPoser
extends SkeletonModifier3D
## Runs after the animation each frame: tilts the neck and head towards where
## the player looks, and layers gestures and conditions on top of whatever
## the body is doing (walking, sitting...): waving, nodding, a broken arm
## held in a sling, bending over out of breath, limping on a leg in a cast.
## Skeleton space: +Z is the character's front, +X its left.
##
## Arms are posed with absolute targets built from the bones' T-pose rest
## (not by turning the animated bones the shortest way), so the hand and
## palm end up the same whatever the animation underneath does. Targets are
## relative to the chest, so they lean with the upper body (sitting, walking).

## Waving (right arm): upper arm out to the side and up, forearm up, palm
## to the front; the forearm swings about the palm's axis.
const WAVE_UPPER := Vector3(-0.85, 0.42, 0.22)
const WAVE_FORE := Vector3(-0.12, 1.0, 0.14)
const WAVE_SWING := 0.4
## A sling (left arm): upper arm hanging a little forward, forearm across
## the belly, palm towards the body.
const HOLD_UPPER := Vector3(0.1, -0.97, 0.24)
const HOLD_FORE := Vector3(-0.78, 0.14, 0.6)

var look_pitch := 0.0   # radians, + looks up
var look_yaw := 0.0     # radians, head turn relative to the body
var wave := 0.0         # 0..1 blend
var wave_time := 0.0
var nod := 0.0          # 0..1 blend
var nod_time := 0.0
var hold_arm := 0.0     # 0..1: left arm in a sling
var bend := 0.0         # 0..1: bent forward, out of breath
var limp := 0.0         # 0..1: favouring the left leg
var limp_phase := 0.0   # 0..1 through the walk cycle

var _neck := -1
var _head := -1
var _chest := -1
var _spine1 := -1
var _spine2 := -1
var _calf_l := -1
var _arms := {}  # "r"/"l" -> [upper, fore, hand]


func _ready() -> void:
	var sk := get_skeleton()
	if sk:
		_neck = sk.find_bone("neck_01")
		_head = sk.find_bone("Head")
		_chest = sk.find_bone("spine_03")
		_spine1 = sk.find_bone("spine_01")
		_spine2 = sk.find_bone("spine_02")
		_calf_l = sk.find_bone("calf_l")
		for side in ["r", "l"]:
			_arms[side] = [sk.find_bone("upperarm_" + side), sk.find_bone("lowerarm_" + side), sk.find_bone("hand_" + side)]


func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null or _head < 0:
		return
	if bend > 0.001:
		for b in [_spine1, _spine2]:
			_rotate_global(sk, b, Basis(Vector3.RIGHT, bend * 0.2))
	if limp > 0.001:
		# The cast keeps the left knee stiff; the body lurches over the good leg.
		var rest := sk.get_bone_rest(_calf_l).basis.get_rotation_quaternion()
		sk.set_bone_pose_rotation(_calf_l, sk.get_bone_pose_rotation(_calf_l).slerp(rest, limp * 0.55))
		_rotate_global(sk, _spine1, Basis(Vector3.BACK, sin(limp_phase * TAU) * 0.08 * limp))
	var pitch := -look_pitch - nod * absf(sin(nod_time * 9.0)) * 0.45 - bend * 0.3
	if absf(pitch) > 0.001 or absf(look_yaw) > 0.001:
		for b in [_neck, _head]:
			_rotate_global(sk, b, Basis(Vector3.UP, look_yaw * 0.5) * Basis(Vector3.RIGHT, pitch * 0.5))
	if hold_arm > 0.001:
		_pose_arm(sk, "l", HOLD_UPPER, HOLD_FORE, 0.0, hold_arm)
	if wave > 0.001:
		_pose_arm(sk, "r", WAVE_UPPER, WAVE_FORE, sin(wave_time * 11.0) * WAVE_SWING, wave)


## Blends one arm towards an absolute pose: the upper arm along `upper_dir`,
## the forearm along `fore_dir` (both in the chest's rest frame), bent at
## the elbow like a hinge, the forearm then turned by `swing` radians about
## the palm's axis; the wrist stays straight.
func _pose_arm(sk: Skeleton3D, side: String, upper_dir: Vector3, fore_dir: Vector3, swing: float, weight: float) -> void:
	var bones: Array = _arms[side]
	var upper: int = bones[0]
	var fore: int = bones[1]
	var hand: int = bones[2]
	if upper < 0 or fore < 0 or hand < 0:
		return
	var rest_u := sk.get_bone_global_rest(upper)
	var rest_f := sk.get_bone_global_rest(fore)
	var rest_h := sk.get_bone_global_rest(hand)
	var axis_u := (rest_f.origin - rest_u.origin).normalized()
	var axis_f := (rest_h.origin - rest_f.origin).normalized()
	var u := upper_dir.normalized()
	var f := fore_dir.normalized()
	# T-pose: palms down, elbow creases to the front. The crease turns to face
	# the forearm, so the elbow bends as a hinge.
	var crease := f - u * u.dot(f)
	if crease.length_squared() < 0.0001:
		crease = Vector3.BACK
	var q_upper := _frame_map(axis_u, Vector3.BACK, u, crease)
	var palm := q_upper * Vector3.DOWN
	var q_fore := _frame_map(axis_f, Vector3.DOWN, f, palm)
	var palm_axis := (palm - f * f.dot(palm)).normalized()
	if swing != 0.0:
		q_fore = Basis(palm_axis, swing) * q_fore
	# In the chest's current frame, so the pose leans with the upper body.
	var chest_now := sk.get_bone_global_pose(_chest).basis.orthonormalized()
	var lean := chest_now * sk.get_bone_global_rest(_chest).basis.orthonormalized().inverse()
	var want_u := lean * q_upper * rest_u.basis.orthonormalized()
	var want_f := lean * q_fore * rest_f.basis.orthonormalized()
	var want_h := want_f * rest_f.basis.orthonormalized().inverse() * rest_h.basis.orthonormalized()
	_blend_global(sk, upper, want_u, weight)
	_blend_global(sk, fore, want_f, weight)
	_blend_global(sk, hand, want_h, weight)


## The rotation taking direction a0 to a1 and (the part of) b0 across a0
## to the part of b1 across a1.
static func _frame_map(a0: Vector3, b0: Vector3, a1: Vector3, b1: Vector3) -> Basis:
	var x0 := a0.normalized()
	var y0 := (b0 - x0 * x0.dot(b0)).normalized()
	var x1 := a1.normalized()
	var y1 := (b1 - x1 * x1.dot(b1)).normalized()
	var from := Basis(x0, y0, x0.cross(y0))
	var to := Basis(x1, y1, x1.cross(y1))
	return to * from.transposed()


static func _blend_global(sk: Skeleton3D, bone: int, target: Basis, weight: float) -> void:
	var gp := sk.get_bone_global_pose(bone)
	var scale := gp.basis.get_scale()
	var q := gp.basis.get_rotation_quaternion().slerp(target.get_rotation_quaternion(), clampf(weight, 0.0, 1.0))
	sk.set_bone_global_pose(bone, Transform3D(Basis(q).scaled(scale), gp.origin))


static func _rotate_global(sk: Skeleton3D, bone: int, rot: Basis) -> void:
	var gp := sk.get_bone_global_pose(bone)
	sk.set_bone_global_pose(bone, Transform3D(rot * gp.basis, gp.origin))
