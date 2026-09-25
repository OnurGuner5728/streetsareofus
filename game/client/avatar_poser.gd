class_name AvatarPoser
extends SkeletonModifier3D
## Runs after the animation each frame: tilts the neck and head towards where
## the player looks, and layers the wave and nod gestures on top of whatever
## the body is doing (walking, sitting...). Skeleton space: +Z is the
## character's front, +X its left.

var look_pitch := 0.0   # radians, + looks up
var look_yaw := 0.0     # radians, head turn relative to the body
var wave := 0.0         # 0..1 blend
var wave_time := 0.0
var nod := 0.0          # 0..1 blend
var nod_time := 0.0

var _neck := -1
var _head := -1
var _upper := -1
var _fore := -1
var _hand := -1


func _ready() -> void:
	var sk := get_skeleton()
	if sk:
		_neck = sk.find_bone("neck_01")
		_head = sk.find_bone("Head")
		_upper = sk.find_bone("upperarm_r")
		_fore = sk.find_bone("lowerarm_r")
		_hand = sk.find_bone("hand_r")


func _process_modification() -> void:
	var sk := get_skeleton()
	if sk == null or _head < 0:
		return
	var pitch := -look_pitch - nod * absf(sin(nod_time * 9.0)) * 0.45
	if absf(pitch) > 0.001 or absf(look_yaw) > 0.001:
		for b in [_neck, _head]:
			_rotate_global(sk, b, Basis(Vector3.UP, look_yaw * 0.5) * Basis(Vector3.RIGHT, pitch * 0.5))
	if wave > 0.001:
		# Upper arm raised beside the head, forearm up, hand waving side to side.
		_aim(sk, _upper, Vector3(-0.32, 0.9, 0.22).normalized(), wave)
		var sway := Basis(Vector3.BACK, sin(wave_time * 11.0) * 0.45)
		_aim(sk, _fore, sway * Vector3(-0.05, 1.0, 0.15).normalized(), wave)
		_aim(sk, _hand, sway * Vector3(-0.02, 1.0, 0.05).normalized(), wave)


static func _rotate_global(sk: Skeleton3D, bone: int, rot: Basis) -> void:
	var gp := sk.get_bone_global_pose(bone)
	sk.set_bone_global_pose(bone, Transform3D(rot * gp.basis, gp.origin))


## Turns a bone so its length axis points along `dir`, blended by `weight`.
static func _aim(sk: Skeleton3D, bone: int, dir: Vector3, weight: float) -> void:
	var gp := sk.get_bone_global_pose(bone)
	var cur := gp.basis.y.normalized()
	if cur.dot(dir) > 0.9999:
		return
	var q := Quaternion(cur, dir)
	var turn := Basis(Quaternion.IDENTITY.slerp(q, clampf(weight, 0.0, 1.0)))
	sk.set_bone_global_pose(bone, Transform3D(turn * gp.basis, gp.origin))
