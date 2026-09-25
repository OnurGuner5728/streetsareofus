class_name PlayerMotor
extends RefCounted
## The one movement function. The server runs it to decide where a player
## is; the client runs the exact same code to predict its own movement and
## to replay unacknowledged inputs after a server correction.
##
## Everything here depends only on the body's state, the input and static
## geometry (plus trams, which are a pure function of the input's world
## tick), so prediction and replays land exactly where the server does.

const BUTTON_JUMP := 1
const BUTTON_SPRINT := 2

## Ledges up to this height (kerbs, tram platforms, a step) are walked onto.
const STEP_HEIGHT := 0.36
## A moving tram that catches you shoves you out of its path.
const TRAM_SHOVE_SIDE := 4.2
const TRAM_SHOVE_UP := 2.6
const TRAM_REACH := 16.0

## step() result flags.
const EVENT_TRAM_HIT := 1
const EVENT_STEPPED := 2


static func make_body(avatar: Dictionary) -> CharacterBody3D:
	var body := CharacterBody3D.new()
	body.collision_layer = Protocol.LAYER_PLAYERS
	body.collision_mask = Protocol.LAYER_WORLD  # players never block each other
	body.floor_snap_length = 0.3
	body.floor_max_angle = deg_to_rad(50.0)
	var col := CollisionShape3D.new()
	col.name = "Capsule"
	col.shape = CapsuleShape3D.new()
	body.add_child(col)
	fit_capsule(body, avatar)
	return body


## Sizes the capsule for an avatar (clamped: looks never change how you play).
static func fit_capsule(body: CharacterBody3D, avatar: Dictionary) -> void:
	var col: CollisionShape3D = body.get_node("Capsule")
	var shape: CapsuleShape3D = col.shape
	shape.height = AvatarSpec.gameplay_height(avatar)
	shape.radius = AvatarSpec.capsule_radius(avatar)
	col.position.y = shape.height / 2.0  # body origin sits at the feet


## `input` is a quantized input dictionary from SnapshotCodec; its "wt" is
## the server tick at which trams are placed. Returns EVENT_* flags.
static func step(body: CharacterBody3D, input: Dictionary, transit: TransitNetwork = null) -> int:
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
	var start := body.global_transform
	body.move_and_slide()
	var events := 0
	if grounded and v.y <= 0.0 and horizontal.length() > 0.1 and body.is_on_wall():
		if _step_up(body, start, Vector3(v.x, 0.0, v.z) * Protocol.DT):
			events |= EVENT_STEPPED
	if transit != null:
		events |= _collide_trams(body, transit, int(input.get("wt", 0)))
	return events


## Floor test that depends only on position, so it gives the same answer
## right after a reconciliation teleport as it does mid-simulation.
static func is_grounded(body: CharacterBody3D) -> bool:
	if body.velocity.y > 0.01:
		return false
	var hit := KinematicCollision3D.new()
	if body.test_move(body.global_transform, Vector3(0.0, -0.06, 0.0), hit):
		return hit.get_normal().y > 0.65
	return false


## Blocked while walking: try the same move lifted by up to STEP_HEIGHT and
## settle back down onto whatever is there. Only accepted if it lands on
## walkable ground higher than before, so walls stay walls.
static func _step_up(body: CharacterBody3D, start: Transform3D, motion: Vector3) -> bool:
	# The capsule's round bottom only sits flat on the ledge once its centre
	# is over it, so the step always carries it at least one radius forward.
	var radius := 0.3
	var capsule := body.get_node_or_null("Capsule") as CollisionShape3D
	if capsule:
		radius = (capsule.shape as CapsuleShape3D).radius
	motion = motion.normalized() * maxf(motion.length(), radius + 0.05)
	var xf := start
	var up := KinematicCollision3D.new()
	var rise := STEP_HEIGHT
	if body.test_move(xf, Vector3.UP * rise, up):
		rise = up.get_travel().y
		if rise < 0.05:
			return false
	xf.origin.y += rise
	if body.test_move(xf, motion):
		return false
	xf.origin += motion
	var down := KinematicCollision3D.new()
	if not body.test_move(xf, Vector3.DOWN * (rise + 0.05), down) or down.get_normal().y < 0.75:
		return false
	xf.origin += down.get_travel()
	if xf.origin.y - start.origin.y < 0.02:
		return false
	body.global_transform = xf
	body.velocity.y = 0.0
	return true


## Trams are solid boxes (see TransitNetwork.boxes_near). Walking into one
## stops you like a wall; one that runs into you from the front throws you
## sideways off the track.
static func _collide_trams(body: CharacterBody3D, transit: TransitNetwork, tick: int) -> int:
	var pos := body.global_position
	var radius := 0.3
	var capsule := body.get_node_or_null("Capsule") as CollisionShape3D
	if capsule:
		radius = (capsule.shape as CapsuleShape3D).radius
	var events := 0
	for box in transit.boxes_near(tick, Vector2(pos.x, pos.z), TRAM_REACH):
		if body.global_position.y - float(box[5]) > 3.6:
			continue  # above the roof
		var p := Vector2(body.global_position.x, body.global_position.z)
		var c: Vector2 = box[0]
		var a: Vector2 = box[1]
		var n := Vector2(-a.y, a.x)
		var hl: float = box[2]
		var hw: float = box[3]
		var along := (p - c).dot(a)
		var across := (p - c).dot(n)
		if absf(along) >= hl + radius or absf(across) >= hw + radius:
			continue
		var push := Vector2.ZERO
		var normal := Vector2.ZERO
		var closest := c + a * clampf(along, -hl, hl) + n * clampf(across, -hw, hw)
		var inside := absf(along) < hl and absf(across) < hw
		if not inside:
			var gap := p - closest
			var dist := gap.length()
			if dist >= radius or dist < 0.0001:
				continue
			normal = gap / dist
			push = normal * (radius - dist)
		elif hl - absf(along) < hw - absf(across):
			normal = a * signf(along)
			push = normal * (hl + radius - absf(along))
		else:
			normal = n * (1.0 if across >= 0.0 else -1.0)
			push = normal * (hw + radius - absf(across))
		var speed: float = box[4]
		var v := body.velocity
		if speed > 0.5 and normal.dot(a) > 0.7:
			# Caught by the front of a moving tram: out of its path, sideways.
			var side := n * (1.0 if across >= 0.0 else -1.0)
			push = side * (hw + radius - absf(across) + 0.05)
			v = Vector3(side.x * TRAM_SHOVE_SIDE + a.x * speed * 0.5, TRAM_SHOVE_UP, side.y * TRAM_SHOVE_SIDE + a.y * speed * 0.5)
			events |= EVENT_TRAM_HIT
		else:
			var into := Vector2(v.x, v.z).dot(normal)
			if into < 0.0:
				v.x -= normal.x * into
				v.z -= normal.y * into
		body.move_and_collide(Vector3(push.x, 0.0, push.y))
		body.velocity = v
	return events
