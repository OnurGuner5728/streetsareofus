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
## The nostalgic car is drawn in detail within this distance, as a box beyond.
const LOD_DISTANCE := 80.0
## Model size of the nostalgic car; inside the server's collision box.
const NOSTALGIC_LENGTH := 10.8
const NOSTALGIC_WIDTH := 2.3

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
		if line.vehicle_type == "nostalgic":
			text = _tr_upper(line.destination(dir))  # the T3's board carries no route number
		if veh.sign_text != text or veh.sign_lit != lit:
			veh.sign_text = text
			veh.sign_lit = lit
			for m in veh.status:
				(m as MeshInstance3D).material_override = _emissive(GREEN if lit else DARK, 3.0 if lit else 0.0)
			for lbl in veh.signs:
				(lbl as Label3D).text = text
				(lbl as Label3D).modulate = GREEN if lit else Color("ffb347")


## Uppercase with Turkish dotted and dotless i.
static func _tr_upper(text: String) -> String:
	return text.replace("i", "\u0130").replace("\u0131", "I").to_upper()


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


## The Moda nostalgic car (T3): cream upper body over a burgundy skirt, rounded
## ends, a monitor roof, wooden window frames with visible glazing and an
## interior (slat benches, standing poles), a destination board, a headlamp that
## glows at night, a route lamp, bogies with wheels, a coupler and a trolley pole
## that reaches the overhead wire (5.6 m, see CityVisuals._catenary). Beyond
## LOD_DISTANCE one box stands in for all of it. Visual only: the collision box
## the server uses (TransitNetwork.boxes_near) is unchanged and this stays inside it.
func _nostalgic_section(veh: Dictionary, line: TransitNetwork.TransitLine) -> Node3D:
	var node := Node3D.new()
	var m := MeshMerger.new()
	var red := Color("8e1f1b")
	var cream := Color("efe2c2")
	var wood := Color("6b4226")
	var dark := Color("2b2e33")
	var metal := Color("c8ccd0")
	var length := NOSTALGIC_LENGTH
	var r := NOSTALGIC_WIDTH / 2.0
	var cz := (length - NOSTALGIC_WIDTH) / 2.0  # centre of the round ends
	# Underframe, burgundy skirt, cream waist line and upper band.
	m.box("body", Vector3(NOSTALGIC_WIDTH - 0.3, 0.2, length - 1.4), Vector3(0, 0.45, 0), dark)
	_stadium(m, "body", r, 0.86, 0.93, red)
	_stadium(m, "body", r + 0.02, 0.1, 1.4, cream)
	_stadium(m, "body", r, 0.35, 2.685, cream)
	# Glazing: one translucent shell, wooden rails, and posts (a sash every 1.2 m).
	_stadium(m, "glass", r - 0.01, 1.1, 1.95, Color.WHITE)
	_stadium(m, "body", r + 0.02, 0.06, 1.44, wood)
	_stadium(m, "body", r + 0.02, 0.06, 2.49, wood)
	_stadium(m, "body", r + 0.012, 0.04, 2.05, wood)  # transom of the sashes
	var straight := length - NOSTALGIC_WIDTH
	for i in 9:
		var z := -straight / 2.0 + straight * i / 8.0
		for side in [-1.0, 1.0]:
			m.box("body", Vector3(0.06, 1.1, 0.09), Vector3(side * (r + 0.02), 1.95, z), wood)
	for end in [-1.0, 1.0]:
		for a in [-1.05, -0.52, 0.0, 0.52, 1.05]:
			var at := Vector3(r * sin(a), 1.95, end * (cz + r * cos(a)))
			var turn: float = a if end > 0.0 else PI - a
			m.box("body", Vector3(0.1, 1.1, 0.06), at, wood, Basis(Vector3.UP, turn))
	# Roof: a rounded, flattened slab with a monitor (clerestory) on top.
	var roof := CapsuleMesh.new()
	roof.radius = r + 0.02
	roof.height = length + 0.06
	roof.radial_segments = 14
	roof.rings = 3
	m.add("body", roof, Transform3D(Basis(Vector3.RIGHT, PI / 2.0) * Basis().scaled(Vector3(1, 1, 0.2)), Vector3(0, 2.92, 0)), Color("7a1f1a"))
	m.box("body", Vector3(1.5, 0.22, 7.4), Vector3(0, 3.22, 0), cream)
	m.box("glass", Vector3(1.53, 0.1, 6.8), Vector3(0, 3.22, 0), Color.WHITE)
	m.box("body", Vector3(1.58, 0.06, 7.6), Vector3(0, 3.37, 0), Color("d9cba6"))
	m.box("status", Vector3(0.5, 0.12, 0.5), Vector3(0, 3.46, 0), Color.WHITE)
	# Trolley pole trailing from the roof base up to the wire, with its wheel.
	m.box("body", Vector3(0.4, 0.12, 0.5), Vector3(0, 3.44, 1.2), dark)
	var pole_tilt := atan2(2.4, 2.15)
	m.cylinder("body", 0.025, 0.03, 3.22, Transform3D(Basis(Vector3.RIGHT, pole_tilt), Vector3(0, 4.52, 2.4)), dark)
	m.cylinder("body", 0.07, 0.07, 0.1, Transform3D(Basis(Vector3.BACK, PI / 2.0), Vector3(0, 5.57, 3.6)), dark)
	# Bogies with wheels.
	for bz in [-3.3, 3.3]:
		m.box("body", Vector3(NOSTALGIC_WIDTH - 0.6, 0.16, 2.0), Vector3(0, 0.4, bz), dark)
		for side in [-1.0, 1.0]:
			for wz in [-0.85, 0.85]:
				m.cylinder("body", 0.34, 0.34, 0.1, Transform3D(Basis(Vector3.BACK, PI / 2.0), Vector3(side * 0.72, 0.34, bz + wz)), Color("3a3d42"))
	# Nose: coupler, destination board, headlamp, route lamp, doors.
	for sgn in [-1.0, 1.0]:
		var front: float = sgn * length / 2.0
		m.box("body", Vector3(1.0, 0.16, 0.14), Vector3(0, 0.78, front), dark)
		m.box("body", Vector3(0.14, 0.14, 0.3), Vector3(0, 0.55, front), dark)
		m.box("body", Vector3(1.15, 0.26, 0.05), Vector3(0, 2.66, front + sgn * 0.02), Color("181b1f"))
		m.sphere("lights", 0.14, Vector3(0, 1.2, front + sgn * 0.02), Color.WHITE, Vector3(1, 1, 0.6))
		m.box("lights", Vector3(0.34, 0.24, 0.22), Vector3(0, 3.17, sgn * (length / 2.0 - 0.7)), Color.WHITE)
		m.box("lodlights", Vector3(0.4, 0.3, 0.1), Vector3(0, 1.2, front + sgn * 0.05), Color.WHITE)
		veh.signs.append(_sign(node, Vector3(0, 2.66, front + sgn * 0.05), sgn, 0.0026, 4))
		var number := _sign(node, Vector3(0, 3.17, sgn * (length / 2.0 - 0.7 + 0.12)), sgn, 0.004, 2)
		number.text = line.id.trim_prefix("T")
		number.modulate = red
		for side in [-1.0, 1.0]:
			m.box("doors", Vector3(0.06, 1.75, 0.95), Vector3(side * (r + 0.04), 1.5, sgn * 3.1), red.darkened(0.2))
	# Interior, seen through the windows: floor, slat benches with backs,
	# a luggage rail and standing poles.
	m.box("interior", Vector3(NOSTALGIC_WIDTH - 0.14, 0.05, length - 1.2), Vector3(0, 1.05, 0), Color("5a3d28"))
	for side in [-1.0, 1.0]:
		for slat in [-0.11, 0.11]:
			m.box("interior", Vector3(0.2, 0.04, 5.6), Vector3(side * (0.8 + slat), 1.45, 0), Color("a9743f"))
		for z in [-2.6, 0.0, 2.6]:
			m.box("interior", Vector3(0.4, 0.36, 0.06), Vector3(side * 0.8, 1.25, z), dark)
		for height in [1.7, 1.92]:
			m.box("interior", Vector3(0.03, 0.15, 5.6), Vector3(side * 1.04, height, 0), Color("a9743f"))
		m.box("interior", Vector3(0.04, 0.04, 7.0), Vector3(side * 0.4, 2.42, 0), metal)
		for z in [-3.0, -1.0, 1.0, 3.0]:
			m.cylinder("interior", 0.02, 0.02, 1.4, Transform3D(Basis(), Vector3(side * 0.4, 1.73, z)), metal)
	for sgn in [-1.0, 1.0]:
		m.box("interior", Vector3(NOSTALGIC_WIDTH - 0.2, 1.4, 0.05), Vector3(0, 1.75, sgn * 4.0), Color("b9a27a"))
	for z in [-3.0, 0.0, 3.0]:
		m.box("lights", Vector3(0.2, 0.03, 0.2), Vector3(0, 2.46, z), Color.WHITE)
	# Stand-in for distant views.
	m.box("lod", Vector3(NOSTALGIC_WIDTH, 1.0, length), Vector3(0, 0.95, 0), red)
	m.box("lod", Vector3(NOSTALGIC_WIDTH, 1.15, length), Vector3(0, 2.0, 0), cream)
	m.box("lod", Vector3(NOSTALGIC_WIDTH, 0.3, length), Vector3(0, 2.75, 0), Color("7a1f1a"))
	_emit_parts(m, node, veh, true)
	return node


## A rounded-ended slab: a box between two vertical cylinders (`radius` wide,
## `height` tall, centre height y): the plan view of the car's body.
func _stadium(m: MeshMerger, group: String, radius: float, height: float, y: float, colour: Color) -> void:
	var straight := NOSTALGIC_LENGTH - NOSTALGIC_WIDTH
	m.box(group, Vector3(radius * 2.0, height, straight), Vector3(0, y, 0), colour)
	for end in [-1.0, 1.0]:
		m.cylinder(group, radius, radius, height - 0.004, Transform3D(Basis(), Vector3(0, y, end * straight / 2.0)), colour)


func _emit_parts(m: MeshMerger, node: Node3D, veh: Dictionary, lod := false) -> void:
	var detail: Array = []
	detail.append(m.emit("body", node, MeshMerger.vertex_colour_material(0.35, 0.1)))
	var doors := m.emit("doors", node, MeshMerger.vertex_colour_material(0.35, 0.1))
	if doors:
		veh.doors.append(doors)
		detail.append(doors)
	var lights := m.emit("lights", node, veh.headlight_mat)
	if lights:
		lights.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		detail.append(lights)
	var status := m.emit("status", node, _emissive(DARK, 0.0))
	if status:
		status.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		veh.status.append(status)
		detail.append(status)
	if not lod:
		return
	var glass := m.emit("glass", node, _glass())
	if glass:
		glass.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		detail.append(glass)
	detail.append(m.emit("interior", node, MeshMerger.vertex_colour_material(0.8)))
	for mi in detail:
		if mi:
			mi.visibility_range_end = LOD_DISTANCE
			mi.visibility_range_end_margin = 3.0
	var far: Array = [m.emit("lod", node, MeshMerger.vertex_colour_material(0.5, 0.1)),
		m.emit("lodlights", node, veh.headlight_mat)]
	for mi in far:
		if mi:
			mi.visibility_range_begin = LOD_DISTANCE
			mi.visibility_range_begin_margin = 3.0
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF


## Window glass: dark and slightly see-through so the benches show.
static func _glass() -> StandardMaterial3D:
	if not _mats.has("glass"):
		var g := StandardMaterial3D.new()
		g.albedo_color = Color(0.16, 0.24, 0.3, 0.42)
		g.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		g.roughness = 0.1
		g.metallic = 0.3
		_mats["glass"] = g
	return _mats["glass"]


func _sign(parent: Node3D, pos: Vector3, facing: float, pixel_size := 0.006, outline := 6) -> Label3D:
	var l := Label3D.new()
	l.font_size = 44
	l.pixel_size = pixel_size
	l.outline_size = outline
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
