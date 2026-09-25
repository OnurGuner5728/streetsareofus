class_name PlayerMotor
extends RefCounted
## The one movement function. The server runs it to decide where a player
## is; the client runs the exact same code to predict its own movement and
## to replay unacknowledged inputs after a server correction.

const BUTTON_JUMP := 1
const BUTTON_SPRINT := 2


static func make_body(avatar: Dictionary) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.collision_layer = Protocol.LAYER_PLAYERS
	body.collision_mask = Protocol.LAYER_WORLD  # players never block each other
	body.floor_snap_length = 0.3
	body.floor_max_angle = deg_to_rad(50.0)
	var shape := CapsuleShape3D.new()
	shape.height = AvatarSpec.gameplay_height(avatar)
	shape.radius = AvatarSpec.capsule_radius(avatar)
	var col := CollisionShape3D.new()
	col.name = "Capsule"
	col.shape = shape
	col.position.y = shape.height / 2.0  # body origin sits at the feet
	body.add_child(col)
	return body


## `input` is a quantized input dictionary from SnapshotCodec.
static func step(body: CharacterBody3D, input: Dictionary) -> void:
	var v := body.velocity
	var grounded := is_grounded(body)
	var buttons: int = input.buttons
	if grounded:
		v.y = 0.0
		if buttons & BUTTON_JUMP:
			v.y = Protocol.JUMP_VELOCITY
	else:
		v.y -= Protocol.GRAVITY * Protocol.DT

	var move := Vector2(input.mx, input.my).limit_length(1.0)
	var dir := Basis(Vector3.UP, float(input.yaw)) * Vector3(move.x, 0.0, -move.y)
	var speed := Protocol.SPRINT_SPEED if buttons & BUTTON_SPRINT else Protocol.WALK_SPEED
	var accel := Protocol.GROUND_ACCEL if grounded else Protocol.AIR_ACCEL
	var horizontal := Vector2(v.x, v.z).move_toward(Vector2(dir.x, dir.z) * speed, accel * Protocol.DT)
	v.x = horizontal.x
	v.z = horizontal.y
	body.velocity = v
	body.move_and_slide()


## Floor test that depends only on position, so it gives the same answer
## right after a reconciliation teleport as it does mid-simulation.
static func is_grounded(body: CharacterBody3D) -> bool:
	if body.velocity.y > 0.01:
		return false
	var hit := KinematicCollision3D.new()
	if body.test_move(body.global_transform, Vector3(0.0, -0.06, 0.0), hit):
		return hit.get_normal().y > 0.65
	return false
