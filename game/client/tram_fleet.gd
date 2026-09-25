class_name TramFleet
extends Node3D
## Every tram in the zone, positioned each frame from the shared timetable
## (TransitNetwork) at the client's estimate of server time. Nothing about
## trams travels over the network.
##
## T3 is drawn as the red and cream Moda nostalgic car; generated lines as
## three-section modern low-floor trams in the line colour. Vehicles serving
## the player's planned route light up green.
##
## Each car section is one merged mesh (plus one for its doors), so a whole
## tram costs a handful of draw calls instead of dozens.

const MODERN_SEGMENTS := TransitNetwork.MODERN_OFFSETS  # section centres along the car
const MODERN_SECTION := TransitNetwork.MODERN_SECTION
const WIDTH := TransitNetwork.CAR_HALF_WIDTH * 2.0
const HEIGHT := 3.3
const GREEN := Color("2ee27a")
const DARK := Color("2a2f36")
const SIGN_RANGE := 90.0

var transit: TransitNetwork
var zone_half := 256.0
var highlight_line := -1
var highlight_dir := 0
var _vehicles: Array = []  # see _build_vehicle
var _states := {}  # Vector2i(line, vehicle) -> state dict for the current frame
var _night := -1.0
var _frame := 0
var camera_pos := Vector3.ZERO
var view_distance := 1500.0
static var _mats := {}


func setup(net: TransitNetwork, half: float) -> void:
	transit = net
	zone_half = half
	for line: TransitNetwork.TransitLine in transit.lines:
		for v in line.vehicles:
			_vehicles.append(_build_vehicle(line, v))


func set_highlight(line_index: int, dir: int) -> void:
	highlight_line = line_index
	highlight_dir = dir


## The state TransitLine.state() gave for this vehicle in the last update.
func state_of(line_index: int, vehicle: int) -> Dictionary:
	return _states.get(Vector2i(line_index, vehicle), {})


func update(t: float, night: float) -> void:
	var night_changed := absf(night - _night) > 0.02
	if night_changed:
		_night = night
		for veh in _vehicles:
			(veh.headlight_mat as StandardMaterial3D).emission_energy_multiplier = 0.6 + 3.0 * night
	_frame += 1
	for k in _vehicles.size():
		var veh: Dictionary = _vehicles[k]
		var line: TransitNetwork.TransitLine = transit.lines[veh.line]
		var st := line.state(veh.vehicle, t)
		_states[Vector2i(veh.line, veh.vehicle)] = st
		var pos: Vector2 = st.pos
		var dist := Vector2(camera_pos.x, -camera_pos.z).distance_to(pos)
		var in_view := absf(pos.x) < zone_half + 30.0 and absf(pos.y) < zone_half + 30.0 and dist < view_distance + 30.0
		# Far trams move in small steps; placing them every third frame is plenty.
		if in_view and veh.root.visible and dist > 120.0 and (k + _frame) % 3 != 0:
			continue
		if veh.root.visible != in_view:
			veh.root.visible = in_view
		if not in_view:
			continue
		var dir: int = st.dir
		var offsets: Array = veh.offsets
		var sections: Array = veh.sections
		for i in sections.size():
			var s := float(st.s) + float(offsets[i]) * dir
			var node: Node3D = sections[i]
			node.global_transform = transit.section_transform(line, s, dir, float(st.side), line.section_length())
		var closed: bool = not st.dwelling
		if veh.doors_closed != closed:
			veh.doors_closed = closed
			for d in veh.doors:
				(d as Node3D).visible = closed
		var lit := highlight_line == line.index and highlight_dir == dir
		var text := "%s  %s" % [line.id, line.destination(dir)]
		if veh.sign_text != text or veh.sign_lit != lit:
			veh.sign_text = text
			veh.sign_lit = lit
			for m in veh.status:
				(m as MeshInstance3D).material_override = _emissive(GREEN if lit else DARK, 3.0 if lit else 0.0)
			for lbl in veh.signs:
				(lbl as Label3D).text = text
				(lbl as Label3D).modulate = GREEN if lit else Color("ffb347")


func vehicle_nodes() -> Array:
	return _vehicles


func _build_vehicle(line: TransitNetwork.TransitLine, v: int) -> Dictionary:
	var root := Node3D.new()
	root.name = "Tram_%s_%d" % [line.id, v]
	add_child(root)
	var headlight_mat := StandardMaterial3D.new()
	headlight_mat.albedo_color = Color("fff4d6")
	headlight_mat.emission_enabled = true
	headlight_mat.emission = Color("fff4d6")
	var veh := {"line": line.index, "vehicle": v, "root": root, "sections": [], "offsets": [],
		"doors": [], "status": [], "signs": [], "headlight_mat": headlight_mat,
		"doors_closed": true, "sign_text": "", "sign_lit": false}
	if line.vehicle_type == "nostalgic":
		var sec := _nostalgic_section(veh, line)
		root.add_child(sec)
		veh.sections.append(sec)
		veh.offsets.append(0.0)
	else:
		for i in MODERN_SEGMENTS.size():
			var sec := _modern_section(veh, line, i)
			root.add_child(sec)
			veh.sections.append(sec)
			veh.offsets.append(MODERN_SEGMENTS[i])
	return veh


# --- models (length along -Z = forward) ------------------------------------------

func _modern_section(veh: Dictionary, line: TransitNetwork.TransitLine, index: int) -> Node3D:
	var node := Node3D.new()
	var m := MeshMerger.new()
	var body := Color("eef1f4")
	var glass := Color("1b2530")
	var seg_len := MODERN_SECTION
	var end := index == 0 or index == MODERN_SEGMENTS.size() - 1
	m.box("body", Vector3(WIDTH, 0.9, seg_len), Vector3(0, 0.75, 0), line.color)  # skirt in line colour
	m.box("body", Vector3(WIDTH, 1.05, seg_len), Vector3(0, 1.72, 0), body)
	m.box("body", Vector3(WIDTH + 0.02, 1.1, seg_len - 0.6), Vector3(0, 2.3, 0), glass)  # window band
	m.box("body", Vector3(WIDTH, 0.35, seg_len), Vector3(0, 3.0, 0), body)
	m.box("body", Vector3(WIDTH - 0.3, 0.25, seg_len * 0.6), Vector3(0, 3.28, 0), Color("9aa3ad"))  # roof gear
	# Bogies and wheels under the skirt.
	for z in [-seg_len * 0.3, seg_len * 0.3]:
		m.box("body", Vector3(WIDTH - 0.5, 0.35, 1.8), Vector3(0, 0.2, z), Color("2b2e33"))
	for side in [-1.0, 1.0]:
		for z in [-seg_len * 0.22, seg_len * 0.22]:
			m.box("doors", Vector3(0.05, 2.0, 1.3), Vector3(side * (WIDTH / 2 + 0.03), 1.3, z), Color("c9d0d6"))
	if end:
		var front := -seg_len / 2.0 if index == 0 else seg_len / 2.0
		var sgn := -1.0 if index == 0 else 1.0
		m.box("body", Vector3(WIDTH - 0.1, 1.2, 0.4), Vector3(0, 2.3, front + sgn * 0.05), glass)  # windscreen
		veh.signs.append(_sign(node, Vector3(0, 3.02, front + sgn * 0.22), sgn))
		for x in [-0.8, 0.8]:
			m.box("lights", Vector3(0.35, 0.18, 0.08), Vector3(x, 0.95, front + sgn * 0.02), Color.WHITE)
		if index == 0:
			m.box("body", Vector3(0.08, 0.9, 1.4), Vector3(0, 3.8, 0), Color("3a3f45"), Basis(Vector3.RIGHT, 0.5))  # pantograph
	if index == 1:
		m.box("status", Vector3(0.9, 0.18, 0.9), Vector3(0, 3.45, 0), Color.WHITE)
	_emit_parts(m, node, veh)
	return node


func _nostalgic_section(veh: Dictionary, _line: TransitNetwork.TransitLine) -> Node3D:
	var node := Node3D.new()
	var m := MeshMerger.new()
	var red := Color("8e1f1b")
	var cream := Color("efe2c2")
	var wood := Color("3b2a1e")
	var seg_len := 10.6
	var w := 2.25
	m.box("body", Vector3(w, 1.1, seg_len), Vector3(0, 0.95, 0), red)
	m.box("body", Vector3(w + 0.02, 0.95, seg_len - 1.4), Vector3(0, 2.0, 0), Color("22303a"))  # open-ish windows
	for z in range(-4, 5):
		m.box("body", Vector3(w + 0.04, 0.95, 0.12), Vector3(0, 2.0, z * 1.1), cream)  # window posts
	m.box("body", Vector3(w, 0.35, seg_len), Vector3(0, 2.62, 0), cream)
	m.box("body", Vector3(w - 0.1, 0.25, seg_len + 0.3), Vector3(0, 2.92, 0), Color("5b1512"))  # roof
	m.box("body", Vector3(0.06, 0.06, 5.5), Vector3(0, 3.9, 1.6), wood, Basis(Vector3.RIGHT, 0.35))  # trolley pole
	for z in [-3.2, 3.2]:
		m.box("body", Vector3(w - 0.4, 0.4, 1.6), Vector3(0, 0.25, z), Color("2b2e33"))  # trucks
	for sgn in [-1.0, 1.0]:
		var front: float = sgn * seg_len / 2.0
		m.box("body", Vector3(w, 1.9, 0.3), Vector3(0, 1.6, front), red)
		m.box("body", Vector3(w - 0.4, 0.8, 0.32), Vector3(0, 2.1, front), Color("22303a"))
		m.box("lights", Vector3(0.3, 0.3, 0.1), Vector3(0, 1.1, front + sgn * 0.16), Color.WHITE)
		veh.signs.append(_sign(node, Vector3(0, 2.72, front + sgn * 0.17), sgn))
		for side in [-1.0, 1.0]:
			m.box("doors", Vector3(0.05, 1.8, 0.9), Vector3(side * (w / 2 + 0.03), 1.3, front - sgn * 1.0), red.darkened(0.2))
	m.box("status", Vector3(0.6, 0.16, 0.6), Vector3(0, 3.12, 0), Color.WHITE)
	_emit_parts(m, node, veh)
	return node


func _emit_parts(m: MeshMerger, node: Node3D, veh: Dictionary) -> void:
	m.emit("body", node, MeshMerger.vertex_colour_material(0.35, 0.1))
	var doors := m.emit("doors", node, MeshMerger.vertex_colour_material(0.35, 0.1))
	if doors:
		veh.doors.append(doors)
	var lights := m.emit("lights", node, veh.headlight_mat)
	if lights:
		lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var status := m.emit("status", node, _emissive(DARK, 0.0))
	if status:
		status.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		veh.status.append(status)


func _sign(parent: Node3D, pos: Vector3, facing: float) -> Label3D:
	var l := Label3D.new()
	l.font_size = 44
	l.pixel_size = 0.006
	l.outline_size = 6
	l.position = pos
	l.rotation.y = PI if facing < 0.0 else 0.0  # text faces +Z; front signs face forward
	l.modulate = Color("ffb347")
	CityVisuals.set_range(l, SIGN_RANGE)
	parent.add_child(l)
	return l


static func _emissive(color: Color, energy: float) -> StandardMaterial3D:
	var key := "e%s%.2f" % [color.to_html(), energy]
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.emission_enabled = energy > 0.0
		m.emission = color
		m.emission_energy_multiplier = energy
		_mats[key] = m
	return _mats[key]
