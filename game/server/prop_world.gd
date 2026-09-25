class_name PropWorld
extends Node3D
## Server side of the loose props (PropLayout): rigid bodies in the zone's
## physics world. Players pass through them in their own movement (so client
## prediction never depends on them); instead the server pushes whatever a
## player walks, runs or jumps into. Trams are kinematic bodies following
## the timetable, so a tram sends a ball flying.
##
## Props that move are sent to clients in snapshots; props left displaced
## and untouched for a while are tidied back home when nobody is near.

const SYNC_TICKS := 30  # keep sending a prop this long after it settles
const RESET_AFTER := 300.0
const RESET_CLEAR := 25.0
const PLAYER_RADIUS := 0.32
const BALL_RADIUS := 0.11

var layout: PropLayout
var transit: TransitNetwork
var bodies: Array = []  # RigidBody3D per prop id
var _last_active := PackedInt32Array()
var _rest_since := PackedFloat64Array()
var _displaced := {}  # id -> true while away from home
var _tram_bodies: Array = []  # [line, vehicle, offset, AnimatableBody3D]
var _awake := {}  # id -> true while the body is simulated
var _pos := PackedVector3Array()  # where each prop is (refreshed for awake ones)
var _kind_spec: Array = []  # per id: PropLayout.KINDS entry
var _near_trams := {}  # Vector2i(line, vehicle) -> true when a prop is within reach
var _near_checked := -1000.0
var pushes := 0


func setup(zone: ZoneData) -> void:
	layout = PropLayout.for_zone(zone)
	transit = zone.transit
	_last_active.resize(layout.props.size())
	_last_active.fill(-1000000)
	_rest_since.resize(layout.props.size())
	for p in layout.props:
		var b := _make_body(p)
		bodies.append(b)
		_pos.append(b.global_position)
		_kind_spec.append(PropLayout.KINDS[p.kind])
		b.sleeping_state_changed.connect(_on_sleep_changed.bind(int(p.id)))
	for line: TransitNetwork.TransitLine in transit.lines:
		for v in line.vehicles:
			for off in line.section_offsets():
				var ab := AnimatableBody3D.new()
				ab.collision_layer = Protocol.LAYER_TRAMS
				ab.collision_mask = 0
				ab.sync_to_physics = true
				var shape := BoxShape3D.new()
				shape.size = Vector3(TransitNetwork.CAR_HALF_WIDTH * 2.0, 3.2, line.section_length())
				var cs := CollisionShape3D.new()
				cs.shape = shape
				cs.position.y = 1.7
				ab.add_child(cs)
				add_child(ab)
				ab.global_position = Vector3(0, -200, 0)
				_tram_bodies.append([line, v, float(off), ab])


func _on_sleep_changed(id: int) -> void:
	if (bodies[id] as RigidBody3D).sleeping:
		_awake.erase(id)
		_pos[id] = (bodies[id] as RigidBody3D).global_position
	else:
		_awake[id] = true


func _any_prop_near(en: Vector2, radius: float) -> bool:
	var q := Vector3(en.x, 0.0, -en.y)
	for i in _pos.size():
		var d := _pos[i] - q
		if absf(d.x) < radius and absf(d.z) < radius:
			return true
	return false


## Where a prop rests at home: balls by their centre, the rest by the middle
## of their base.
static func home_transform(p: Dictionary) -> Transform3D:
	var lift := BALL_RADIUS if p.kind == "ball" else 0.0
	return Transform3D(Basis(Vector3.UP, float(p.yaw)), (p.pos as Vector3) + Vector3(0, lift, 0))


func _make_body(p: Dictionary) -> RigidBody3D:
	var spec: Dictionary = PropLayout.KINDS[p.kind]
	var size: Vector3 = spec.size
	var b := RigidBody3D.new()
	b.name = "Prop_%d_%s" % [p.id, p.kind]
	b.mass = spec.mass
	var mat := PhysicsMaterial.new()
	mat.bounce = spec.bounce
	mat.friction = spec.friction
	b.physics_material_override = mat
	b.collision_layer = Protocol.LAYER_PROPS
	b.collision_mask = Protocol.LAYER_WORLD | Protocol.LAYER_PROPS | Protocol.LAYER_TRAMS
	var cs := CollisionShape3D.new()
	if p.kind == "ball":
		var sphere := SphereShape3D.new()
		sphere.radius = BALL_RADIUS
		cs.shape = sphere
		b.continuous_cd = true
		b.angular_damp = 1.2  # grass and asphalt eat a rolling ball's spin
		b.linear_damp = 0.25
	elif p.kind == "table":
		var cyl := CylinderShape3D.new()
		cyl.radius = size.x / 2.0
		cyl.height = size.y
		cs.shape = cyl
		cs.position.y = size.y / 2.0
	else:
		var box := BoxShape3D.new()
		box.size = size
		cs.shape = box
		cs.position.y = size.y / 2.0
	b.add_child(cs)
	add_child(b)
	b.global_transform = home_transform(p)
	b.sleeping = true
	return b


## Moves the tram bodies to where the timetable has them at `t`; only trams
## with a prop within reach take part in the physics at all.
func update_trams(t: float) -> void:
	var half := transit.zone_half + 30.0
	if t - _near_checked > 0.5:
		# Twice a second: which trams have any prop within 40 m (8 m/s trams
		# cannot close that gap before the next check).
		_near_checked = t
		_near_trams.clear()
		for line: TransitNetwork.TransitLine in transit.lines:
			for v in line.vehicles:
				var centre: Vector2 = line.state(v, t).pos
				if absf(centre.x) < half and absf(centre.y) < half and _any_prop_near(centre, 40.0):
					_near_trams[Vector2i(line.index, v)] = true
	var states := {}
	for entry in _tram_bodies:
		var line: TransitNetwork.TransitLine = entry[0]
		var ab: AnimatableBody3D = entry[3]
		var key := Vector2i(line.index, int(entry[1]))
		if not states.has(key):
			states[key] = line.state(int(entry[1]), t) if _near_trams.has(key) else {}
		var st: Dictionary = states[key]
		if st.is_empty():
			if ab.global_position.y > -100.0:
				ab.global_position = Vector3(0, -200, 0)
			continue
		var dir: int = st.dir
		var s := float(st.s) + float(entry[2]) * dir
		var c := line.track_point(s, dir, float(st.side))
		var h := line.tangent_at(s) * dir
		ab.global_transform = Transform3D(Basis.looking_at(Vector3(h.x, 0.0, -h.y), Vector3.UP), Vector3(c.x, 0.0, -c.y))


## Whatever a player moves into is pushed along at (a share of) their
## speed; running or jumping into a ball kicks it up.
func push_from_players(players: Array) -> void:
	for pl in players:
		if not pl.riding.is_empty():
			continue
		var body: CharacterBody3D = pl.body
		var pos := body.global_position
		var vel := body.velocity
		for id in _pos.size():
			var near := _pos[id] - pos
			if absf(near.x) > 1.6 or absf(near.z) > 1.6:
				continue
			var b: RigidBody3D = bodies[id]
			var d := b.global_position - pos
			var kind: String = layout.props[id].kind
			var spec: Dictionary = _kind_spec[id]
			var size: Vector3 = spec.size
			var bottom := b.global_position.y - (BALL_RADIUS if kind == "ball" else 0.0)
			if bottom > pos.y + 1.7 or bottom + size.y < pos.y - 0.05:
				continue
			var flat := Vector3(d.x, 0.0, d.z)
			var dist := flat.length()
			var reach := PLAYER_RADIUS + maxf(size.x, size.z) * 0.45
			if dist > reach:
				continue
			var n := flat / dist if dist > 0.01 else Basis(Vector3.UP, float(pl.yaw)) * Vector3.FORWARD
			var along := Vector3(vel.x, 0.0, vel.z).dot(n)
			var want := maxf(along, 0.0) * float(spec.push) + (reach - dist) * 3.0
			var have := b.linear_velocity.dot(n)
			if want <= have + 0.05:
				continue
			var impulse := n * (want - have) * float(spec.mass)
			var at := Vector3.ZERO
			if kind == "ball":
				if pl.buttons & PlayerMotor.BUTTON_SPRINT or vel.y > 0.5:
					impulse.y += (1.6 + along * 0.45) * float(spec.mass)
			else:
				at = Vector3(0, size.y * 0.7, 0)  # pushed high, tall things tip over
			b.sleeping = false
			b.apply_impulse(impulse, at)
			pushes += 1


## Bookkeeping after each tick: what is moving, what to tidy away.
func track(tick: int, players: Array) -> void:
	var now := tick * Protocol.DT
	for id in _awake.keys():
		var b: RigidBody3D = bodies[id]
		_pos[id] = b.global_position
		_last_active[id] = tick
		_displaced[id] = true
		_rest_since[id] = now
		if _pos[id].y < -5.0:
			_send_home(id, tick)
	if tick % Protocol.TICK_RATE != 0:
		return
	for id in _displaced.keys():
		if now - _rest_since[id] < RESET_AFTER:
			continue
		var home := home_transform(layout.props[id])
		var near := false
		for pl in players:
			var p: Vector3 = pl.body.global_position
			if p.distance_to(home.origin) < RESET_CLEAR or p.distance_to((bodies[id] as RigidBody3D).global_position) < RESET_CLEAR:
				near = true
				break
		if not near:
			_send_home(id, tick)


func _send_home(id: int, tick: int) -> void:
	var b: RigidBody3D = bodies[id]
	b.global_transform = home_transform(layout.props[id])
	b.linear_velocity = Vector3.ZERO
	b.angular_velocity = Vector3.ZERO
	b.sleeping = true
	_pos[id] = b.global_position
	_awake.erase(id)
	_displaced.erase(id)
	_last_active[id] = tick


## [[id, Transform3D]] for props moving now or settling in the last second.
func moving_poses(tick: int) -> Array:
	var out := []
	for id in bodies.size():
		if tick - _last_active[id] <= SYNC_TICKS:
			out.append([id, (bodies[id] as RigidBody3D).global_transform])
	return out


## [[id, Transform3D]] for every prop away from home (sent on join).
func displaced_poses() -> Array:
	var out := []
	for id in _displaced:
		out.append([id, (bodies[id] as RigidBody3D).global_transform])
	return out
