class_name PropView
extends Node3D
## Client side of the loose props: one MultiMesh per kind (a draw call each,
## however many chairs there are), starting at their deterministic homes
## and following server poses, interpolated a little in the past like other
## players. Knocks make a sound.

const INTERP_DELAY := 0.12

var layout: PropLayout
var sounds: CitySounds
var _mm := {}  # kind -> MultiMesh
var _slot := []  # id -> [kind, instance]
var _samples := {}  # id -> [[t, Transform3D], ...]
var _active := {}  # id -> true while samples are being played back
var _last_speed := {}  # id -> m/s, for knock sounds


func setup(zone: ZoneData) -> void:
	layout = PropLayout.for_zone(zone)
	var by_kind := {}
	for p in layout.props:
		if not by_kind.has(p.kind):
			by_kind[p.kind] = []
		_slot.append([p.kind, by_kind[p.kind].size()])
		by_kind[p.kind].append(p)
	for kind in by_kind:
		var list: Array = by_kind[kind]
		var mm := MultiMesh.new()
		mm.transform_format = MultiMesh.TRANSFORM_3D
		mm.use_colors = true
		mm.mesh = _mesh(kind)
		mm.instance_count = list.size()
		for i in list.size():
			mm.set_instance_transform(i, PropWorld.home_transform(list[i]))
			mm.set_instance_color(i, list[i].tint)
		var mmi := MultiMeshInstance3D.new()
		mmi.name = "Props_" + kind
		mmi.multimesh = mm
		mmi.material_override = MeshMerger.vertex_colour_material(0.6)
		add_child(mmi)
		_mm[kind] = mm


## Poses sent on joining: jump straight there.
func apply_now(poses: Array) -> void:
	for entry in poses:
		_place(int(entry[0]), entry[1])


## Poses from a snapshot generated at server time t.
func push(t: float, poses: Array) -> void:
	for entry in poses:
		var id := int(entry[0])
		if id < 0 or id >= _slot.size():
			continue
		if not _samples.has(id):
			_samples[id] = []
		var list: Array = _samples[id]
		if not list.is_empty() and float(list[-1][0]) >= t:
			continue
		list.append([t, entry[1]])
		if list.size() > 10:
			list.pop_front()
		_active[id] = true


func update(now_server: float) -> void:
	var t := now_server - INTERP_DELAY
	for id in _active.keys():
		var list: Array = _samples[id]
		var last: Array = list[-1]
		if t >= float(last[0]):
			_place(id, last[1])
			if t > float(last[0]) + 1.0:
				_active.erase(id)
				_samples[id] = [last]
			continue
		for i in range(list.size() - 1, 0, -1):
			var a: Array = list[i - 1]
			var b: Array = list[i]
			if float(a[0]) <= t:
				var f := (t - float(a[0])) / maxf(0.0001, float(b[0]) - float(a[0]))
				_place(id, (a[1] as Transform3D).interpolate_with(b[1], f))
				_knock(id, a, b)
				break


func _place(id: int, xf: Transform3D) -> void:
	if id < 0 or id >= _slot.size():
		return
	var slot: Array = _slot[id]
	(_mm[slot[0]] as MultiMesh).set_instance_transform(int(slot[1]), xf)


## A sudden change of speed between samples is a kick or a crash.
func _knock(id: int, a: Array, b: Array) -> void:
	if sounds == null:
		return
	var dt := maxf(0.001, float(b[0]) - float(a[0]))
	var speed := (b[1] as Transform3D).origin.distance_to((a[1] as Transform3D).origin) / dt
	var before := float(_last_speed.get(id, 0.0))
	_last_speed[id] = speed
	if absf(speed - before) > 1.6:
		var kind: String = _slot[id][0]
		sounds.knock((b[1] as Transform3D).origin, kind, clampf(absf(speed - before) / 6.0, 0.2, 1.0))


# --- models (origin at the base centre; balls at their centre) --------------------

func _mesh(kind: String) -> Mesh:
	var m := MeshMerger.new()
	var size: Vector3 = PropLayout.KINDS[kind].size
	match kind:
		"ball":
			m.sphere("p", PropWorld.BALL_RADIUS, Vector3.ZERO, Color.WHITE)
			# Dark patches on an icosahedron's corners read as a football.
			var g := (1.0 + sqrt(5.0)) / 2.0
			for v in [Vector3(-1, g, 0), Vector3(1, g, 0), Vector3(-1, -g, 0), Vector3(1, -g, 0), Vector3(0, -1, g), Vector3(0, 1, g),
					Vector3(0, -1, -g), Vector3(0, 1, -g), Vector3(g, 0, -1), Vector3(g, 0, 1), Vector3(-g, 0, -1), Vector3(-g, 0, 1)]:
				m.sphere("p", 0.034, (v as Vector3).normalized() * 0.092, Color(0.08, 0.08, 0.08), Vector3.ONE, 6)
		"bin":
			# Municipal 1100 l container: grey body, dark lid, four castors.
			var body := Color(0.42, 0.45, 0.47)
			m.box("p", Vector3(size.x, size.y - 0.2, size.z), Vector3(0, 0.2 + (size.y - 0.2) / 2.0, 0), body)
			m.box("p", Vector3(size.x + 0.04, 0.06, size.z + 0.06), Vector3(0, size.y + 0.01, 0.02), Color(0.2, 0.22, 0.23))
			m.box("p", Vector3(size.x - 0.2, 0.08, 0.08), Vector3(0, size.y - 0.25, -size.z / 2.0 - 0.05), Color(0.2, 0.22, 0.23))
			for x in [-1.0, 1.0]:
				for z in [-1.0, 1.0]:
					m.box("p", Vector3(0.08, 0.2, 0.12), Vector3(x * (size.x / 2.0 - 0.12), 0.1, z * (size.z / 2.0 - 0.12)), Color(0.08, 0.08, 0.08))
		"chair":
			# Tinted per café through the instance colour (white = plastic).
			for x in [-1.0, 1.0]:
				for z in [-1.0, 1.0]:
					m.box("p", Vector3(0.035, 0.45, 0.035), Vector3(x * 0.19, 0.225, z * 0.19), Color(0.85, 0.85, 0.85))
			m.box("p", Vector3(0.44, 0.04, 0.42), Vector3(0, 0.46, 0), Color.WHITE)
			m.box("p", Vector3(0.42, 0.38, 0.04), Vector3(0, 0.67, 0.2), Color.WHITE)
		"table":
			m.cylinder("p", size.x / 2.0, size.x / 2.0, 0.03, Transform3D(Basis(), Vector3(0, size.y - 0.015, 0)), Color.WHITE)
			m.cylinder("p", 0.035, 0.035, size.y - 0.05, Transform3D(Basis(), Vector3(0, (size.y - 0.05) / 2.0, 0)), Color(0.3, 0.3, 0.3))
			m.cylinder("p", 0.22, 0.25, 0.03, Transform3D(Basis(), Vector3(0, 0.015, 0)), Color(0.3, 0.3, 0.3))
	return m.commit("p")
