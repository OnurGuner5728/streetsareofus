class_name PlayerMotor
extends RefCounted
## The one movement function. The server runs it to decide where a player
## is; the client runs the exact same code to predict its own movement and
## to replay unacknowledged inputs after a server correction.
##
## Everything here depends only on the body's state, the input and static
## geometry (plus trams and road traffic, which are pure functions of the
## input's world tick), so prediction and replays land exactly where the server does.
##
## Body state beyond position and velocity lives in metas on the body:
##   knock (int ticks left of being knocked down, incl. getting up),
##   stamina (int 0..STAMINA_MAX, integer math only), winded (bool),
##   hit_speed (float, speed of the tram or car that last knocked you down);
## and parameters the server decides (not simulated here):
##   fitness (float 0..1), limp (bool, a leg injury).

const BUTTON_JUMP := 1
const BUTTON_SPRINT := 2

## Ledges up to this height (kerbs, tram platforms, a step) are walked onto.
const STEP_HEIGHT := 0.36
## A moving tram that catches you knocks you down and flings you: along
## with it at most of its speed, sideways out of its path, and up.
const TRAM_FLING_ALONG := 0.8
const TRAM_FLING_SIDE := 3.5
const TRAM_FLING_UP := 3.0
const TRAM_REACH := 16.0
## Cars do the same, more gently: slower than CAR_HIT_SPEED they only push
## you out of their way like a wall.
const CAR_FLING_ALONG := 0.6
const CAR_FLING_SIDE := 2.5
const CAR_FLING_UP := 2.4
const CAR_REACH := 6.0
const CAR_HIT_SPEED := 2.5  # m/s, about 9 km/h

## Knocked down: inputs ignored, sliding to a stop, then getting up.
const KNOCK_TICKS := 96  # 3.2 s in all
const KNOCK_GETUP_TICKS := 30  # the last second is standing up again
const KNOCK_FRICTION := 7.0  # m/s² sliding along the ground
const KNOCK_AIR_ACCEL := 0.5

## Stamina: sprinting drains it (a fit person lasts longer), not sprinting
## refills it. Out of breath at zero: no sprinting and a slower walk until
## it is back up to WINDED_RECOVER.
const STAMINA_MAX := 10000
const WINDED_RECOVER := 3000
const ENDURANCE_MIN := 10.0  # seconds of sprinting at fitness 0
const ENDURANCE_MAX := 40.0  # ... and at fitness 1
const RECOVER_MOVING := 20  # per tick (~17 s to full while walking)
const RECOVER_IDLE := 45  # per tick (~7 s to full standing still)
const WINDED_WALK := 0.85
const DEFAULT_FITNESS := 0.35
## A leg injury: no running, no jumping, a slow walk.
const LIMP_SPEED := 1.3

## step() result flags.
const EVENT_TRAM_HIT := 1
const EVENT_STEPPED := 2
const EVENT_SPRINTED := 4  # stamina was spent sprinting this tick
const EVENT_CAR_HIT := 8  # a car knocked the player down


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


## Where a seated body's feet go for a bench seat: a little in front of it
## (the sitting animation keeps the hips 34 cm behind the feet).
static func seat_origin(bench: Dictionary, side: int) -> Vector3:
	var basis := Basis(Vector3.UP, float(bench.yaw))
	return (bench.pos as Vector3) + basis * Vector3(Protocol.BENCH_SEATS[side], 0.0, -0.29)


static func sit(body: CharacterBody3D, origin: Vector3) -> void:
	body.set_meta("seat", origin)
	body.global_position = origin
	body.velocity = Vector3.ZERO


## Sizes the capsule for an avatar (clamped: looks never change how you play).
static func fit_capsule(body: CharacterBody3D, avatar: Dictionary) -> void:
	var col: CollisionShape3D = body.get_node("Capsule")
	var shape: CapsuleShape3D = col.shape
	shape.height = AvatarSpec.gameplay_height(avatar)
	shape.radius = AvatarSpec.capsule_radius(avatar)
	col.position.y = shape.height / 2.0  # body origin sits at the feet


## The simulated part of the body state: what snapshots carry and what
## reconciliation compares and restores.
static func motor_state(body: CharacterBody3D) -> Dictionary:
	return {
		"stamina": int(body.get_meta("stamina", STAMINA_MAX)),
		"knock": int(body.get_meta("knock", 0)),
		"winded": bool(body.get_meta("winded", false)),
	}


static func apply_state(body: CharacterBody3D, st: Dictionary) -> void:
	body.set_meta("stamina", clampi(int(st.get("stamina", STAMINA_MAX)), 0, STAMINA_MAX))
	body.set_meta("knock", maxi(0, int(st.get("knock", 0))))
	body.set_meta("winded", bool(st.get("winded", false)))


static func knock_ticks(body: CharacterBody3D) -> int:
	return int(body.get_meta("knock", 0))


## Lying on the ground (knocked down and not yet getting up).
static func is_down(body: CharacterBody3D) -> bool:
	return knock_ticks(body) > KNOCK_GETUP_TICKS


## Stamina spent per sprinting tick: all of it in `endurance` seconds.
static func sprint_drain(fitness: float) -> int:
	var endurance := lerpf(ENDURANCE_MIN, ENDURANCE_MAX, clampf(fitness, 0.0, 1.0))
	return maxi(1, roundi(STAMINA_MAX / (endurance * Protocol.TICK_RATE)))


## `input` is a quantized input dictionary from SnapshotCodec; its "wt" is
## the server tick at which trams and cars are placed. Returns EVENT_* flags.
static func step(body: CharacterBody3D, input: Dictionary, transit: TransitNetwork = null, traffic: Traffic = null) -> int:
	var mx: float = input.mx
	var my: float = input.my
	var buttons: int = input.buttons
	var events := 0
	# Knocked down: the player's input does nothing until back on their feet.
	var knock := int(body.get_meta("knock", 0))
	if knock > 0:
		knock -= 1
		body.set_meta("knock", knock)
		mx = 0.0
		my = 0.0
		buttons = 0
	var limp := bool(body.get_meta("limp", false))
	var winded := bool(body.get_meta("winded", false))
	if limp:
		buttons &= ~(BUTTON_JUMP | BUTTON_SPRINT)
	if winded:
		buttons &= ~BUTTON_SPRINT
	var moving := mx != 0.0 or my != 0.0
	# Stamina, in whole units so every machine counts exactly the same.
	var stamina := int(body.get_meta("stamina", STAMINA_MAX))
	if buttons & BUTTON_SPRINT and moving:
		stamina = maxi(0, stamina - sprint_drain(float(body.get_meta("fitness", DEFAULT_FITNESS))))
		events |= EVENT_SPRINTED
		if stamina == 0:
			winded = true
	else:
		stamina = mini(STAMINA_MAX, stamina + (RECOVER_MOVING if moving else RECOVER_IDLE))
		if winded and stamina >= WINDED_RECOVER:
			winded = false
	body.set_meta("stamina", stamina)
	body.set_meta("winded", winded)
	# Seated on a bench: stay put until the player moves or jumps. Server and
	# client prediction both run this, so standing up is predicted exactly.
	if body.has_meta("seat"):
		if moving or buttons & BUTTON_JUMP:
			body.remove_meta("seat")
		else:
			body.velocity = Vector3.ZERO
			return events
	var v := body.velocity
	var grounded := is_grounded(body)
	if grounded:
		v.y = 0.0
		if buttons & BUTTON_JUMP:
			v.y = Protocol.JUMP_VELOCITY
	else:
		v.y -= Protocol.GRAVITY * Protocol.DT

	var move := Vector2(mx, my).limit_length(1.0)
	var dir := Basis(Vector3.UP, float(input.yaw)) * Vector3(move.x, 0.0, -move.y)
	var speed := Protocol.SPRINT_SPEED if buttons & BUTTON_SPRINT else Protocol.WALK_SPEED
	if winded:
		speed *= WINDED_WALK
	if limp:
		speed = minf(speed, LIMP_SPEED)
	var accel := Protocol.GROUND_ACCEL if grounded else Protocol.AIR_ACCEL
	if knock > 0:
		accel = KNOCK_FRICTION if grounded else KNOCK_AIR_ACCEL
	var horizontal := Vector2(v.x, v.z).move_toward(Vector2(dir.x, dir.z) * speed, accel * Protocol.DT)
	v.x = horizontal.x
	v.z = horizontal.y
	body.velocity = v
	var start := body.global_transform
	body.move_and_slide()
	if grounded and v.y <= 0.0 and horizontal.length() > 0.1 and body.is_on_wall():
		if _step_up(body, start, Vector3(v.x, 0.0, v.z) * Protocol.DT):
			events |= EVENT_STEPPED
	var tick := int(input.get("wt", 0))
	if transit != null:
		var at := Vector2(body.global_position.x, body.global_position.z)
		events |= _collide_vehicles(body, transit.boxes_near(tick, at, TRAM_REACH), EVENT_TRAM_HIT, 0.5,
			TRAM_FLING_ALONG, TRAM_FLING_SIDE, TRAM_FLING_UP, 3.6)
	if traffic != null:
		var at := Vector2(body.global_position.x, body.global_position.z)
		events |= _collide_vehicles(body, traffic.boxes_near(tick, at, CAR_REACH), EVENT_CAR_HIT, CAR_HIT_SPEED,
			CAR_FLING_ALONG, CAR_FLING_SIDE, CAR_FLING_UP, 3.4)
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


## Trams and cars are solid boxes (see TransitNetwork.boxes_near and
## Traffic.boxes_near). Walking into one stops you like a wall; one faster
## than `hit_speed` that runs into you from the front knocks you down and
## throws you out of its path (once: while you are down it only keeps you
## out of its way).
static func _collide_vehicles(body: CharacterBody3D, boxes: Array, event: int, hit_speed: float, fling_along: float,
		fling_side: float, fling_up: float, height: float) -> int:
	var radius := 0.3
	var capsule := body.get_node_or_null("Capsule") as CollisionShape3D
	if capsule:
		radius = (capsule.shape as CapsuleShape3D).radius
	var events := 0
	for box in boxes:
		if body.global_position.y - float(box[5]) > height:
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
		if speed > hit_speed and normal.dot(a) > 0.7:
			# Caught by the front of a moving vehicle: out of its path, sideways.
			var side := n * (1.0 if across >= 0.0 else -1.0)
			push = side * (hw + radius - absf(across) + 0.05)
			if int(body.get_meta("knock", 0)) == 0:
				v = Vector3(a.x * speed * fling_along + side.x * fling_side, fling_up,
					a.y * speed * fling_along + side.y * fling_side)
				body.set_meta("knock", KNOCK_TICKS)
				body.set_meta("hit_speed", speed)
				body.remove_meta("seat")
				events |= event
		else:
			var into := Vector2(v.x, v.z).dot(normal)
			if into < 0.0:
				v.x -= normal.x * into
				v.z -= normal.y * into
		body.move_and_collide(Vector3(push.x, 0.0, push.y))
		body.velocity = v
	return events
