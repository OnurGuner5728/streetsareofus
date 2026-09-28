class_name CrowdView
extends Node3D
## Draws the Crowd (ambient NPC pedestrians). Every pedestrian has a real
## avatar (Crowd.look: the same random but plausible person on every client).
## The few nearest the camera are drawn as that avatar, rigged and animated
## like players (a pool of AvatarViews, reassigned as people come and go);
## everyone else is one MultiMesh of simple figures wearing the same
## colours, legs and arms swung by the vertex shader. How many walk depends
## on the hour and on quality. Pedestrians step aside for real people (a
## visual nudge off their route) and stop to look at shop windows.
## Up close each carries a small "NPC" tag, so nobody takes them for a player.

const NEAR := 55.0
const COUNT_BY_QUALITY := [24, 50, 90]
## How many of the nearest pedestrians are drawn as full avatars.
const PEOPLE_BY_QUALITY := [6, 12, 24]
const PEOPLE_RANGE := 50.0
const TAG_RANGE := 18.0
const PICK_EVERY := 12  # frames between choosing who is drawn as an avatar
const FIGURE_HEIGHT := 1.72  # the simple figure's height before scaling
# Body part codes in the mesh's vertex colour (red channel).
const SKIN := 0.1
const FOREARM := 0.2
const TOP := 0.3
const BOTTOM := 0.45
const SHIN := 0.55
const HAIR := 0.7
const SHOES := 0.9
const SLEEVED := ["longsleeve", "shirt", "hoodie", "sweater", "jacket", "coat"]

## Per instance: x top colour, z bottom colour (both 4-4-3 bit RGB codes),
## y cadence (+16 with long sleeves), w skin/hair/body flags. Every value is
## an integer below 2048 so it survives the Compatibility renderer's half floats.
const SHADER := """
shader_type spatial;
const vec3 SKINS[8] = {vec3(0.965, 0.863, 0.776), vec3(0.918, 0.761, 0.627), vec3(0.839, 0.635, 0.478), vec3(0.776, 0.557, 0.388),
	vec3(0.71, 0.478, 0.322), vec3(0.553, 0.353, 0.231), vec3(0.431, 0.267, 0.188), vec3(0.306, 0.184, 0.125)};
varying vec3 col;
vec3 srgb(vec3 c) { return mix(c / 12.92, pow((c + 0.055) / 1.055, vec3(2.4)), step(0.04045, c)); }
vec3 unpack(int v) { return vec3(float(v & 15) / 15.0, float((v >> 4) & 15) / 15.0, float((v >> 8) & 7) / 7.0); }
vec3 turn_x(vec3 v, vec3 pivot, float a) {
	vec3 d = v - pivot;
	return pivot + vec3(d.x, d.y * cos(a) - d.z * sin(a), d.y * sin(a) + d.z * cos(a));
}
void vertex() {
	float sleeves = step(15.5, INSTANCE_CUSTOM.y);
	float cadence = INSTANCE_CUSTOM.y - sleeves * 16.0;
	float walking = step(0.01, cadence);
	float phase = float(INSTANCE_ID) * 1.7 + TIME * cadence;
	float swing = sin(phase) * 0.5 * walking;
	int body = int(INSTANCE_CUSTOM.w + 0.5);
	float part = UV.x;
	float side = UV.y * 2.0 - 1.0;
	if ((body & 256) != 0) {
		// Female build: narrower shoulders, a little more hip.
		if (UV2.x >= 0.75) VERTEX.x *= 0.9;
		else if (UV2.x < 0.25 && VERTEX.y > 1.12 && part > 0.25 && part < 0.4) VERTEX.x *= 0.92;
		else if (UV2.x < 0.25 && VERTEX.y < 1.0) VERTEX.x *= 1.08;
	}
	if (part >= 0.6 && part < 0.8 && UV.y < 0.25 && (body & 64) == 0) {
		VERTEX = vec3(0.0, 1.6, 0.0);  // long hair, only for those who have it
	}
	if (UV2.x > 0.25 && UV2.x < 0.75) {
		VERTEX = turn_x(VERTEX, vec3(0.0, 0.87, 0.0), swing * side);
	} else if (UV2.x >= 0.75) {
		VERTEX = turn_x(VERTEX, vec3(0.0, 1.4, 0.0), -swing * side * 0.8);
	}
	VERTEX.y += abs(sin(phase)) * 0.025 * walking;
	vec3 skin = SKINS[body & 7];
	vec3 top = unpack(int(INSTANCE_CUSTOM.x + 0.5));
	vec3 bottom = unpack(int(INSTANCE_CUSTOM.z + 0.5));
	vec3 c = skin;
	if (part > 0.15 && part < 0.25) c = mix(skin, top, sleeves);
	else if (part >= 0.25 && part < 0.4) c = top;
	else if (part >= 0.4 && part < 0.5) c = bottom;
	else if (part >= 0.5 && part < 0.6) c = (body & 128) != 0 ? skin : bottom;
	else if (part >= 0.6 && part < 0.8) {
		c = mix(vec3(0.07, 0.05, 0.04), vec3(0.62, 0.46, 0.3), float((body >> 3) & 7) / 7.0);
		if ((body & 512) != 0) c = skin;
	}
	else if (part >= 0.8) c = (body & 1024) != 0 ? vec3(0.82, 0.82, 0.8) : vec3(0.09, 0.08, 0.08);
	col = srgb(c);
}
void fragment() {
	ALBEDO = col;
	ROUGHNESS = 0.85;
}
"""


## One pooled avatar: whose look it wears, and who it is drawn for now.
class Slot:
	extends RefCounted
	var holder: Node3D
	var view: AvatarView
	var tag: Label3D
	var walker := -1  # drawn for this pedestrian, or -1 when free
	var built := -1  # whose look the avatar currently wears
	var active := false  # built and shown (the figure is hidden)
	var freed_at := 0  # frame it was last released, to reuse the oldest first
	var anim_wait := 0.0


var client: GameClient
var crowd: Crowd
var _mm: MultiMesh
var _count := 0
var _frame := 0
var _last := []  # last position per walker (Vector3), for the near/far split
var _cadence := PackedFloat32Array()
var _sleeves := PackedFloat32Array()  # 16 when the top has long sleeves (see SHADER)
var _aside := PackedVector2Array()  # current sidestep per walker (XZ)
var _yaw := PackedFloat32Array()  # current facing per walker, smoothed
var _size := PackedFloat32Array()  # figure scale per walker (the avatar's height)
var _slot_of := PackedInt32Array()  # walker -> pooled avatar, or -1
var _slots: Array = []  # of Slot
var _queue: Array = []  # slots waiting to be built, one per frame
const GIVE_WAY := 1.1  # metres at which a pedestrian starts stepping aside


func setup(game: GameClient) -> void:
	client = game
	crowd = Crowd.for_zone(game.zone)
	_mm = MultiMesh.new()
	_mm.transform_format = MultiMesh.TRANSFORM_3D
	_mm.use_custom_data = true
	_mm.mesh = _body_mesh()
	_mm.instance_count = crowd.walkers.size()
	_mm.visible_instance_count = 0
	for i in crowd.walkers.size():
		var av := crowd.look(i)
		var sleeves := 16.0 if str(av.clothing.top) in SLEEVED else 0.0
		_mm.set_instance_custom_data(i, Color(_top_code(av), sleeves, _bottom_code(av), _body_code(av)))
		_last.append(Vector3(0, -100, 0))
		_cadence.append(0.0)
		_sleeves.append(sleeves)
		_aside.append(Vector2.ZERO)
		_yaw.append(0.0)
		_size.append(AvatarSpec.visual_height(av) / FIGURE_HEIGHT)
		_slot_of.append(-1)
	var mmi := MultiMeshInstance3D.new()
	mmi.name = "Crowd"
	mmi.multimesh = _mm
	mmi.extra_cull_margin = 16384.0
	var mat := ShaderMaterial.new()
	var shader := Shader.new()
	shader.code = SHADER
	mat.shader = shader
	mmi.material_override = mat
	add_child(mmi)


func update(now_server: float, hours: float) -> void:
	_frame += 1
	var target := mini(crowd.walkers.size(), roundi(COUNT_BY_QUALITY[GraphicsQuality.level] * Crowd.density(hours)))
	if target != _count:
		_count = target
		_mm.visible_instance_count = _count
	var cam := client.camera.global_position if client.camera else Vector3.ZERO
	if client.camera and _frame % PICK_EVERY == 0:
		_pick(cam, -client.camera.global_transform.basis.z)
	var t0 := FrameProfiler.start()
	_build_next()
	FrameProfiler.add("crowd.build", t0)
	# Where real people are, to give way to them.
	var people := PackedVector2Array()
	if client.body:
		people.append(Vector2(client.body.global_position.x, client.body.global_position.z))
	for r in client.remotes.values():
		var rp := (r as Node3D).global_position
		if rp.distance_to(cam) < NEAR:
			people.append(Vector2(rp.x, rp.z))
	var dt := minf(get_process_delta_time(), 0.1)
	for i in _count:
		var si := _slot_of[i]
		var slot: Slot = _slots[si] if si >= 0 and (_slots[si] as Slot).active else null
		# People near the camera move every frame, the rest a few times a second.
		var near := (_last[i] as Vector3).distance_to(cam) < NEAR
		if not near and slot == null and (i + _frame) % 6 != 0:
			continue
		var step := dt if near or slot != null else dt * 6.0
		var w: Crowd.Walker = crowd.walkers[i]
		var pose := w.pose(now_server)
		var p: Vector2 = pose[0]
		var h: Vector2 = pose[1]
		var walking: bool = pose[2]
		var xz := Vector2(p.x, -p.y)
		var want := Vector2.ZERO
		if near:
			for q in people:
				var away := xz + _aside[i] - q
				var d := away.length()
				if d < GIVE_WAY and d > 0.001:
					# Sideways relative to their walk, towards whichever side they are on.
					var side := Vector2(h.y, h.x)
					want += side * signf(side.dot(away) + 0.001) * (GIVE_WAY - d) * 1.4
		_aside[i] = _aside[i].lerp(want.limit_length(1.2), 1.0 - exp(-4.0 * step))
		xz += _aside[i]
		var pos := Vector3(xz.x, client.zone.terrain.height(xz.x, xz.y), xz.y)
		# Facing: along the walk, or, when stopped, towards the shop windows
		# on their right (people keep to the right-hand pavement).
		var face := atan2(-h.x, h.y) if walking else atan2(-h.y, -h.x)
		if (_last[i] as Vector3).y < -50.0:
			_yaw[i] = face
		else:
			_yaw[i] = lerp_angle(_yaw[i], face, 1.0 - exp(-(7.0 if walking else 2.5) * step))
		_last[i] = pos
		if slot:
			_drive(slot, pos, _yaw[i], w.speed if walking else 0.0, cam, dt)
			continue
		_mm.set_instance_transform(i, _figure_transform(i))
		var cadence := w.speed * 4.6 if walking else 0.0
		if _cadence[i] != cadence:
			_cadence[i] = cadence
			var custom := _mm.get_instance_custom_data(i)
			custom.g = cadence + _sleeves[i]
			_mm.set_instance_custom_data(i, custom)


## Moves and animates a pooled avatar. Limbs far away are a few pixels
## tall, so they are animated less often.
func _drive(slot: Slot, pos: Vector3, yaw: float, speed: float, cam: Vector3, dt: float) -> void:
	slot.holder.position = pos
	slot.holder.rotation.y = yaw
	var dist := pos.distance_to(cam)
	var every := 0.0 if dist < 12.0 else (0.05 if dist < 25.0 else 0.12)
	if GraphicsQuality.level == GraphicsQuality.LOW:
		every *= 1.5
	slot.anim_wait += dt
	if slot.anim_wait >= every:
		slot.view.animate(speed, slot.anim_wait)
		slot.anim_wait = 0.0
	var show_tag := dist < TAG_RANGE
	if slot.tag.visible != show_tag:
		slot.tag.visible = show_tag


func _figure_transform(i: int) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, _yaw[i]).scaled(Vector3.ONE * _size[i]), _last[i])


## Chooses who is drawn as a full avatar: the nearest pedestrians, those in
## front of the camera first. Whoever already has one keeps it unless
## clearly farther than the rest, so nobody flickers between the two looks.
func _pick(cam: Vector3, forward: Vector3) -> void:
	var n: int = PEOPLE_BY_QUALITY[GraphicsQuality.level]
	while _slots.size() < n:
		_slots.append(_new_slot())
	var scored: Array = []
	for i in _count:
		var p: Vector3 = _last[i]
		var d := p.distance_to(cam)
		if d > PEOPLE_RANGE or p.y < -50.0:
			continue
		var score := d
		if d > 6.0 and (p - cam).dot(forward) < 0.0:
			score *= 2.5  # behind the camera
		if _slot_of[i] >= 0:
			score *= 0.8
		scored.append(Vector2(score, i))
	scored.sort()
	var chosen := {}
	for k in mini(n, scored.size()):
		chosen[int(scored[k].y)] = true
	for si in _slots.size():
		var slot: Slot = _slots[si]
		if slot.walker >= 0 and (si >= n or not chosen.has(slot.walker)):
			_release(si)
	for i: int in chosen:
		if _slot_of[i] >= 0:
			continue
		var si := _free_slot(i, n)
		if si < 0:
			break
		var slot: Slot = _slots[si]
		slot.walker = i
		_slot_of[i] = si
		if slot.built == i:
			_activate(si)
		elif not _queue.has(si):
			_queue.append(si)


## A free slot, preferring one that already wears this pedestrian's look,
## then the one released longest ago.
func _free_slot(walker: int, n: int) -> int:
	var best := -1
	for si in mini(n, _slots.size()):
		var slot: Slot = _slots[si]
		if slot.walker >= 0:
			continue
		if slot.built == walker:
			return si
		if best < 0 or slot.freed_at < (_slots[best] as Slot).freed_at:
			best = si
	return best


## Builds at most one avatar per frame, so newcomers never cause a hitch.
func _build_next() -> void:
	while not _queue.is_empty():
		var si: int = _queue.pop_front()
		var slot: Slot = _slots[si]
		if slot.walker < 0 or slot.active:
			continue
		slot.view.build(crowd.look(slot.walker), GraphicsQuality.level > GraphicsQuality.LOW)
		slot.built = slot.walker
		slot.tag.position.y = slot.view.visual_height + 0.18
		_activate(si)
		return


func _activate(si: int) -> void:
	var slot: Slot = _slots[si]
	var i := slot.walker
	slot.active = true
	slot.anim_wait = 1.0  # pose it on the first update
	slot.holder.position = _last[i]
	slot.holder.rotation.y = _yaw[i]
	slot.holder.visible = true
	# The figure stays in the MultiMesh, shrunk out of sight.
	_mm.set_instance_transform(i, Transform3D(Basis().scaled(Vector3.ONE * 0.0001), _last[i]))


func _release(si: int) -> void:
	var slot: Slot = _slots[si]
	var i := slot.walker
	if slot.active:
		_mm.set_instance_transform(i, _figure_transform(i))
	_slot_of[i] = -1
	slot.walker = -1
	slot.active = false
	slot.freed_at = _frame
	slot.holder.visible = false


func _new_slot() -> Slot:
	var slot := Slot.new()
	slot.holder = Node3D.new()
	slot.holder.name = "Pedestrian%d" % _slots.size()
	slot.holder.visible = false
	add_child(slot.holder)
	slot.view = AvatarView.new()
	slot.view.gestures = false
	slot.holder.add_child(slot.view)
	slot.tag = Label3D.new()
	slot.tag.text = "NPC"
	slot.tag.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	slot.tag.font_size = 26
	slot.tag.pixel_size = 0.004
	slot.tag.outline_size = 8
	slot.tag.modulate = Color(0.78, 0.84, 0.9, 0.85)
	slot.tag.visible = false
	slot.holder.add_child(slot.tag)
	return slot


## The pedestrian under the crosshair within `reach`, or -1.
func look_target(origin: Vector3, forward: Vector3, reach: float) -> int:
	var best := -1
	var best_along := INF
	for i in _count:
		var p: Vector3 = _last[i]
		if origin.distance_to(p + Vector3(0, 1.0, 0)) > reach + 0.5:
			continue
		var pts := Geometry3D.get_closest_points_between_segments(origin, origin + forward * 6.0, p + Vector3(0, 0.2, 0), p + Vector3(0, 1.7, 0))
		var along := origin.distance_to(pts[0])
		if pts[0].distance_to(pts[1]) < 0.5 and along < best_along:
			best_along = along
			best = i
	return best


# --- the far figures' colours, from the avatar ------------------------------------

## 4-4-3 bit RGB (sRGB), at most 2047.
static func _colour_code(c: Color) -> float:
	return float(roundi(c.r * 15.0) + roundi(c.g * 15.0) * 16 + roundi(c.b * 7.0) * 256)


static func _top_code(av: Dictionary) -> float:
	return _colour_code(Color(str(av.clothing.top_color)))


static func _bottom_code(av: Dictionary) -> float:
	# A dress colours the thighs too.
	var key := "top_color" if av.clothing.top == "dress" else "bottom_color"
	return _colour_code(Color(str(av.clothing[key])))


## skin index (0-7) + 8 * hair shade (0-7) + 64 long hair + 128 bare shins
## + 256 female + 512 bald + 1024 light shoes.
static func _body_code(av: Dictionary) -> float:
	var app: Dictionary = av.appearance
	var cl: Dictionary = av.clothing
	var code := maxi(0, AvatarSpec.SKINS.keys().find(app.skin))
	code += clampi(roundi(Color(str(app.hair_color)).v / 0.7 * 7.0), 0, 7) * 8
	if app.hair == "long":
		code += 64
	if cl.bottom in ["shorts", "skirt"] or cl.top == "dress":
		code += 128
	if app.body_type == "female":
		code += 256
	if app.hair == "none":
		code += 512
	if Color(str(cl.shoes_color)).v > 0.6:
		code += 1024
	return float(code)


## A plain figure, 1.72 m, facing -Z. Codes for the shader (authored as
## vertex colour, stored in UVs): UV.x = part (skin/sleeve/top/bottom/shin/
## hair/shoes), UV.y = side (or 0 for the long-hair piece), UV2.x = limb
## (0.5 legs, 1 arms).
static func _body_mesh() -> Mesh:
	var m := MeshMerger.new()
	for side: float in [-1.0, 1.0]:
		var g := (side + 1.0) / 2.0
		m.capsule("b", 0.08, 0.5, Vector3(side * 0.09, 0.62, 0), Color(BOTTOM, g, 0.5), Vector3(1.0, 1.0, 1.05), 6)
		m.capsule("b", 0.062, 0.48, Vector3(side * 0.09, 0.27, 0.01), Color(SHIN, g, 0.5), Vector3.ONE, 6)
		m.box("b", Vector3(0.105, 0.08, 0.26), Vector3(side * 0.09, 0.04, -0.04), Color(SHOES, g, 0.5))
		m.capsule("b", 0.054, 0.34, Vector3(side * 0.21, 1.22, 0), Color(TOP, g, 1.0), Vector3.ONE, 6)
		m.capsule("b", 0.045, 0.32, Vector3(side * 0.215, 0.96, 0), Color(FOREARM, g, 1.0), Vector3.ONE, 6)
		m.sphere("b", 0.045, Vector3(side * 0.215, 0.78, 0), Color(SKIN, g, 1.0), Vector3(0.75, 1.2, 0.95), 6)
	m.capsule("b", 0.17, 0.6, Vector3(0, 1.15, 0), Color(TOP, 0.5, 0.0), Vector3(1.0, 1.0, 0.62), 8)
	m.capsule("b", 0.16, 0.24, Vector3(0, 0.9, 0), Color(BOTTOM, 0.5, 0.0), Vector3(1.0, 1.0, 0.66), 8)
	m.capsule("b", 0.05, 0.14, Vector3(0, 1.47, 0), Color(SKIN, 0.5, 0.0), Vector3.ONE, 6)
	m.sphere("b", 0.1, Vector3(0, 1.6, 0), Color(SKIN, 0.5, 0.0), Vector3(0.9, 1.12, 1.0), 8)
	m.box("b", Vector3(0.028, 0.04, 0.03), Vector3(0, 1.585, -0.1), Color(SKIN, 0.5, 0.0))
	m.sphere("b", 0.105, Vector3(0, 1.64, 0.015), Color(HAIR, 0.5, 0.0), Vector3(0.95, 0.85, 1.0), 8)
	m.box("b", Vector3(0.19, 0.26, 0.07), Vector3(0, 1.52, 0.075), Color(HAIR, 0.0, 0.0))
	# The codes move from the vertex colour to UV and UV2: the Compatibility
	# renderer multiplies COLOR by the (unused) instance colour.
	var arrays := m.commit("b").surface_get_arrays(0)
	var colours: PackedColorArray = arrays[Mesh.ARRAY_COLOR]
	var uv := PackedVector2Array()
	var uv2 := PackedVector2Array()
	for c in colours:
		uv.append(Vector2(c.r, c.g))
		uv2.append(Vector2(c.b, 0.0))
	arrays[Mesh.ARRAY_COLOR] = null
	arrays[Mesh.ARRAY_TEX_UV] = uv
	arrays[Mesh.ARRAY_TEX_UV2] = uv2
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	return mesh
