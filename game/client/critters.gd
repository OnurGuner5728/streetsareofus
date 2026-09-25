class_name Critters
extends Node3D
## Kadıköy's other residents. Street cats doze on car bonnets and benches
## or stroll along a pavement (placed from the zone and timed by server
## time, so everyone sees the same cats); you can stroke one. Pigeon flocks
## peck around squares and parks and take off when someone comes close.
## Everything is one MultiMesh per species, animated in the vertex shader.

const CATS := 14
const FLOCKS := 6
const BIRDS_PER_FLOCK := 11
const SCARE := 4.5
const SCARE_RUNNING := 8.0

const CAT_SHADER := """
shader_type spatial;
// Ginger, black, grey, cream, brown tabby, dark tabby.
const vec3 COATS[6] = {vec3(0.85, 0.54, 0.23), vec3(0.16, 0.16, 0.17), vec3(0.56, 0.57, 0.59), vec3(0.94, 0.9, 0.85),
	vec3(0.72, 0.48, 0.27), vec3(0.36, 0.31, 0.28)};
varying vec3 col;
vec3 srgb(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
void vertex() {
	// Tail (vertex colour b = 1) sways; walking cats bob a little.
	float t = TIME * (1.2 + INSTANCE_CUSTOM.y) + INSTANCE_CUSTOM.x;
	if (COLOR.b > 0.5) {
		float a = sin(t) * 0.35 * COLOR.b;
		VERTEX.x += sin(a) * (VERTEX.z - 0.18);
	}
	VERTEX.y += abs(sin(t * 3.0)) * 0.012 * step(0.01, INSTANCE_CUSTOM.y);
	vec3 coat = COATS[int(INSTANCE_CUSTOM.z + 0.5) % 6];
	col = srgb(mix(coat, coat * 0.55, COLOR.r));  // r: darker stripes and ears
}
void fragment() {
	ALBEDO = col;
	ROUGHNESS = 0.95;
}
"""

const BIRD_SHADER := """
shader_type spatial;
varying float shade;
void vertex() {
	float flying = INSTANCE_CUSTOM.y;
	float t = TIME * mix(3.0, 18.0, flying) + INSTANCE_CUSTOM.x;
	if (COLOR.b > 0.5) {
		// Wings: flap in flight, folded on the ground.
		float side = COLOR.g * 2.0 - 1.0;
		float a = mix(0.0, sin(t) * 0.9, flying);
		VERTEX.y += abs(VERTEX.x) * sin(a) * 1.2;
	}
	if (COLOR.r > 0.5 && flying < 0.5) {
		// Head: pecking at the ground.
		VERTEX.y -= max(0.0, sin(t * 0.7)) * 0.04;
		VERTEX.z -= max(0.0, sin(t * 0.7)) * 0.02;
	}
	shade = COLOR.r + COLOR.b * 2.0;
}
void fragment() {
	// Slate body, pale barred wings, dark green-violet neck.
	vec3 body = vec3(0.21, 0.23, 0.29);
	vec3 col = shade > 1.5 ? vec3(0.52, 0.54, 0.6) : mix(body, vec3(0.12, 0.2, 0.18), shade);
	ALBEDO = col;
	ROUGHNESS = 0.8;
	SPECULAR = 0.4 + shade * 0.2;
}
"""

var client: GameClient
var _cats: MultiMesh
var _cat_specs: Array = []  # {kind: "sleep"|"walk", pos, yaw, a, b, speed, phase}
var _birds: MultiMesh
var _flocks: Array = []  # {home: Vector3, state, t, from, to, offsets}
var _rng := RandomNumberGenerator.new()
var _petted_at := -INF


func setup(game: GameClient) -> void:
	client = game
	_rng.randomize()
	var streets := StreetLayout.for_zone(game.zone)
	_place_cats(game.zone, streets)
	_cats = _multimesh(_cat_mesh(), CAT_SHADER, _cat_specs.size(), false)
	for i in _cat_specs.size():
		var spec: Dictionary = _cat_specs[i]
		_cats.set_instance_custom_data(i, Color(float(i) * 2.3, 0.0, float(spec.coat), 0.0))
		_cats.set_instance_transform(i, Transform3D(Basis(Vector3.UP, spec.yaw), spec.pos))
	_place_flocks(game.zone, streets)
	_birds = _multimesh(_bird_mesh(), BIRD_SHADER, _flocks.size() * BIRDS_PER_FLOCK, false)
	for f in _flocks.size():
		for k in BIRDS_PER_FLOCK:
			_birds.set_instance_custom_data(f * BIRDS_PER_FLOCK + k, Color(_rng.randf() * 10.0, 0.0, 0.0, 0.0))


func _multimesh(mesh: Mesh, code: String, count: int, colours: bool) -> MultiMesh:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = colours
	mm.use_custom_data = true
	mm.mesh = mesh
	mm.instance_count = count
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.extra_cull_margin = 16384.0
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = code
	mat.shader = shader
	mmi.material_override = mat
	add_child(mmi)
	return mm


# --- cats ----------------------------------------------------------------------------

func _place_cats(zone: ZoneData, streets: StreetLayout) -> void:
	var coats := 6  # palette size in CAT_SHADER
	var picks := []
	# Sleeping on a bonnet or a bench.
	for c in streets.cars:
		picks.append(["car", c])
	for b in streets.benches:
		picks.append(["bench", b])
	var i := 0
	var order := range(picks.size())
	order.sort_custom(func(a, b): return WorldBuilder._hash01("cat%d" % a) < WorldBuilder._hash01("cat%d" % b))
	for idx in order:
		if _cat_specs.size() >= CATS * 2 / 3:
			break
		var pick: Array = picks[idx]
		var item: Dictionary = pick[1]
		var yaw := float(item.yaw)
		var pos: Vector3 = item.pos
		if pick[0] == "car":
			pos += Basis(Vector3.UP, yaw) * Vector3(0, 1.08, -1.3)  # on the bonnet
		else:
			pos += Basis(Vector3.UP, yaw) * Vector3(0.5, 0.47, 0.0)  # at one end of the seat
		_cat_specs.append({"kind": "sleep", "pos": pos, "yaw": yaw + WorldBuilder._hash01("catyaw%d" % i) * 2.0,
			"coat": int(WorldBuilder._hash01("coat%d" % i) * coats)})
		i += 1
	# A few strolling along pavements, back and forth.
	var crowd := Crowd.for_zone(zone)
	var k := 0
	while _cat_specs.size() < CATS and k < crowd.walkers.size():
		var w: Crowd.Walker = crowd.walkers[crowd.walkers.size() - 1 - k]
		k += 1
		var start: Vector2 = w.path[0]
		var end: Vector2 = w.path[mini(6, w.path.size() - 1)]
		_cat_specs.append({"kind": "walk", "a": start, "b": end, "speed": 0.45, "phase": k * 13.0, "pos": zone.ground(start.x, start.y),
			"yaw": 0.0, "coat": k % coats})


func _update_cats(t: float) -> void:
	for i in _cat_specs.size():
		var spec: Dictionary = _cat_specs[i]
		if spec.kind != "walk":
			continue
		var a: Vector2 = spec.a
		var b: Vector2 = spec.b
		var length := maxf(a.distance_to(b), 0.5)
		# Walk, sit a while, walk back, sit again.
		var cycle := 2.0 * (length / float(spec.speed) + 12.0)
		var tau := fposmod(t + float(spec.phase), cycle)
		var leg := length / float(spec.speed)
		var f := 0.0
		var moving := false
		var heading := b - a
		if tau < leg:
			f = tau / leg
			moving = true
		elif tau < leg + 12.0:
			f = 1.0
		elif tau < 2.0 * leg + 12.0:
			f = 1.0 - (tau - leg - 12.0) / leg
			moving = true
			heading = a - b
		var p := a.lerp(b, f)
		spec.pos = Vector3(p.x, client.zone.terrain.height_en(p), -p.y)
		var h := heading.normalized()
		_cats.set_instance_transform(i, Transform3D(Basis(Vector3.UP, atan2(-h.x, h.y)), spec.pos))
		_cats.set_instance_custom_data(i, Color(float(i) * 2.3, 2.0 if moving else 0.0, float(spec.coat), 0.0))


## The cat within reach in front of the camera, or -1.
func cat_near(origin: Vector3, forward: Vector3, reach: float) -> int:
	for i in _cat_specs.size():
		var p: Vector3 = _cat_specs[i].pos
		var to := p - origin
		if to.length() < reach and to.normalized().dot(forward) > 0.6:
			return i
	return -1


func pet(i: int) -> void:
	if GameClient.now() - _petted_at < 2.0:
		return
	_petted_at = GameClient.now()
	if client.sounds:
		client.sounds.purr(_cat_specs[i].pos)
	client.hud.notice("Kedi mırlıyor.", 2.0)


# --- pigeons ------------------------------------------------------------------------

func _place_flocks(zone: ZoneData, streets: StreetLayout) -> void:
	var spots := []
	for area in zone.areas:
		if str(area.kind) in ["plaza", "park", "playground"]:
			var poly := WorldBuilder.footprint_xz(area.polygon)
			var c := Vector2.ZERO
			for p in poly:
				c += p
			spots.append(c / maxf(1.0, poly.size()))
	for s in streets.stops:
		var o: Vector3 = (s.xf as Transform3D).origin
		spots.append(Vector2(o.x, o.z) + Vector2(3, 3))
	for i in mini(FLOCKS, spots.size()):
		var home: Vector2 = spots[i]
		var offsets := []
		for k in BIRDS_PER_FLOCK:
			offsets.append(Vector3(_rng.randf_range(-2.2, 2.2), 0.0, _rng.randf_range(-2.2, 2.2)))
		var ground := zone.terrain.on_ground(home)
		_flocks.append({"home": ground, "at": ground, "state": "ground",
			"t": 0.0, "from": Vector3.ZERO, "to": Vector3.ZERO, "offsets": offsets, "yaws": offsets.map(func(_o): return _rng.randf() * TAU)})


func _update_birds(delta: float, people: Array) -> void:
	for f in _flocks.size():
		var flock: Dictionary = _flocks[f]
		if flock.state == "ground":
			for p: Array in people:
				var d := (p[0] as Vector3).distance_to(flock.at)
				if d < (SCARE_RUNNING if float(p[1]) > 3.5 else SCARE):
					flock.state = "flying"
					flock.t = 0.0
					flock.from = flock.at
					var a := _rng.randf() * TAU
					var land: Vector3 = flock.home + Vector3(cos(a), 0, sin(a)) * _rng.randf_range(4.0, 16.0)
					flock.to = client.zone.terrain.on_ground(Vector2(land.x, land.z))
					break
		else:
			flock.t = float(flock.t) + delta
			if float(flock.t) >= 7.0:
				flock.state = "ground"
				flock.at = flock.to
		var flying: bool = flock.state == "flying"
		var u := clampf(float(flock.t) / 7.0, 0.0, 1.0)
		var centre: Vector3 = (flock.from as Vector3).lerp(flock.to, u) if flying else flock.at
		var lift := sin(u * PI) * 9.0 if flying else 0.0
		for k in BIRDS_PER_FLOCK:
			var off: Vector3 = flock.offsets[k]
			var pos := centre + off * (1.6 if flying else 1.0) + Vector3(0, lift + (sin(float(flock.t) * 3.0 + k) * 0.6 if flying else 0.0), 0)
			var yaw: float = flock.yaws[k]
			if flying:
				var dir: Vector3 = (flock.to as Vector3) - (flock.from as Vector3)
				yaw = atan2(-dir.x, -dir.z)
			var i := f * BIRDS_PER_FLOCK + k
			_birds.set_instance_transform(i, Transform3D(Basis(Vector3.UP, yaw), pos))
			var custom := _birds.get_instance_custom_data(i)
			custom.g = 1.0 if flying else 0.0
			_birds.set_instance_custom_data(i, custom)


func update(t: float, delta: float) -> void:
	_update_cats(t)
	var people := []
	if client.body:
		people.append([client.body.global_position, Vector2(client.body.velocity.x, client.body.velocity.z).length()])
	for r in client.remotes.values():
		people.append([(r as RemotePlayer).global_position, (r as RemotePlayer)._speed])
	_update_birds(delta, people)


# --- models ------------------------------------------------------------------------

## A cat curled or standing, about 45 cm long, facing -Z. Vertex colour:
## r = darker patches, b = tail.
static func _cat_mesh() -> Mesh:
	var m := MeshMerger.new()
	m.sphere("c", 0.13, Vector3(0, 0.14, 0.02), Color(0, 0, 0), Vector3(0.85, 0.75, 1.6), 8)  # body
	m.sphere("c", 0.075, Vector3(0, 0.24, -0.2), Color(0, 0, 0), Vector3(1.0, 0.95, 1.0), 8)  # head
	for x in [-0.04, 0.04]:
		m.box("c", Vector3(0.03, 0.05, 0.02), Vector3(x, 0.31, -0.21), Color(1, 0, 0))  # ears
		m.box("c", Vector3(0.035, 0.1, 0.035), Vector3(x * 1.4, 0.05, -0.1), Color(0, 0, 0))  # front legs
		m.box("c", Vector3(0.035, 0.1, 0.035), Vector3(x * 1.4, 0.05, 0.14), Color(0, 0, 0))  # back legs
	for k in 4:
		m.box("c", Vector3(0.03, 0.03, 0.07), Vector3(0, 0.16 + k * 0.035, 0.24 + k * 0.03), Color(0.6, 0, 1))  # tail
	m.box("c", Vector3(0.2, 0.012, 0.06), Vector3(0, 0.27, 0.0), Color(1, 0, 0))  # a stripe
	return m.commit("c")


## A pigeon, 30 cm, facing -Z. Vertex colour: r = head/neck, b = wings, g = side.
static func _bird_mesh() -> Mesh:
	var m := MeshMerger.new()
	m.sphere("b", 0.07, Vector3(0, 0.1, 0.02), Color(0, 0, 0), Vector3(0.8, 0.8, 1.5), 6)
	m.sphere("b", 0.04, Vector3(0, 0.17, -0.09), Color(1, 0, 0), Vector3.ONE, 6)
	m.box("b", Vector3(0.012, 0.012, 0.03), Vector3(0, 0.165, -0.13), Color(1, 0, 0))
	for side: float in [-1.0, 1.0]:
		m.box("b", Vector3(0.16, 0.01, 0.1), Vector3(side * 0.09, 0.13, 0.03), Color(0, (side + 1.0) / 2.0, 1))
	m.box("b", Vector3(0.06, 0.01, 0.08), Vector3(0, 0.1, 0.14), Color(0, 0, 0))
	return m.commit("b")
