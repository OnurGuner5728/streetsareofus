class_name TramFleet
extends Node3D
## Every tram in the zone, positioned each frame from the shared timetable
## (TransitNetwork) at the client's estimate of server time. Nothing about
## trams travels over the network.
##
## T3 is drawn as the red and cream Moda nostalgic car; generated lines as
## three-section modern low-floor trams in the line colour. Vehicles serving
## the player's planned route light up green.

const MODERN_SEGMENTS := [-8.3, 0.0, 8.3]  # section centres along the car
const MODERN_SECTION := 8.0
const WIDTH := 2.4
const HEIGHT := 3.3
const GREEN := Color("2ee27a")

var transit: TransitNetwork
var zone_half := 256.0
var highlight_line := -1
var highlight_dir := 0
var _vehicles: Array = []  # {line, vehicle, root, sections: [Node3D], doors: [Node3D], lights: [..], signs: [..]}
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


func update(t: float, night: float) -> void:
	for veh in _vehicles:
		var line: TransitNetwork.TransitLine = transit.lines[veh.line]
		var st := line.state(veh.vehicle, t)
		var pos: Vector2 = st.pos
		var in_view := absf(pos.x) < zone_half + 30.0 and absf(pos.y) < zone_half + 30.0
		veh.root.visible = in_view
		if not in_view:
			continue
		var dir: int = st.dir
		var offsets: Array = veh.offsets
		var sections: Array = veh.sections
		for i in sections.size():
			var s := float(st.s) + float(offsets[i]) * dir
			var p := line.track_point(s, dir, float(st.side))
			var h := line.tangent_at(s) * dir
			var node: Node3D = sections[i]
			node.global_transform = Transform3D(
				Basis.looking_at(Vector3(h.x, 0.0, -h.y), Vector3.UP), Vector3(p.x, 0.0, -p.y))
		var open: bool = st.dwelling
		for d in veh.doors:
			d.visible = not open
		var lit := highlight_line == line.index and highlight_dir == dir
		for m in veh.status:
			(m as MeshInstance3D).material_override = _emissive(GREEN if lit else Color("2a2f36"), 3.0 if lit else 0.0)
		var text := "%s  %s" % [line.id, line.destination(dir)]
		if veh.get("sign_text", "") != text or veh.get("sign_lit", false) != lit:
			veh.sign_text = text
			veh.sign_lit = lit
			for lbl in veh.signs:
				(lbl as Label3D).text = text
				(lbl as Label3D).modulate = GREEN if lit else Color("ffb347")
		for l in veh.headlights:
			(l as MeshInstance3D).material_override = _emissive(Color("fff4d6"), 0.6 + 3.0 * night)


func vehicle_nodes() -> Array:
	return _vehicles


func _build_vehicle(line: TransitNetwork.TransitLine, v: int) -> Dictionary:
	var root := Node3D.new()
	root.name = "Tram_%s_%d" % [line.id, v]
	add_child(root)
	var veh := {"line": line.index, "vehicle": v, "root": root, "sections": [], "offsets": [],
		"doors": [], "status": [], "signs": [], "headlights": []}
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
	var body := Color("eef1f4")
	var accent := line.color
	var glass := Color("1b2530")
	var seg_len := MODERN_SECTION
	var end := index == 0 or index == MODERN_SEGMENTS.size() - 1
	_box(node, Vector3(WIDTH, 0.9, seg_len), Vector3(0, 0.75, 0), accent)  # skirt in line colour
	_box(node, Vector3(WIDTH, 1.05, seg_len), Vector3(0, 1.72, 0), body)
	_box(node, Vector3(WIDTH + 0.02, 1.1, seg_len - 0.6), Vector3(0, 2.3, 0), glass)  # window band
	_box(node, Vector3(WIDTH, 0.35, seg_len), Vector3(0, 3.0, 0), body)
	_box(node, Vector3(WIDTH - 0.3, 0.25, seg_len * 0.6), Vector3(0, 3.28, 0), Color("9aa3ad"))  # roof gear
	for side in [-1.0, 1.0]:
		for z in [-seg_len * 0.22, seg_len * 0.22]:
			var door := _box(node, Vector3(0.05, 2.0, 1.3), Vector3(side * (WIDTH / 2 + 0.03), 1.3, z), Color("c9d0d6"))
			veh.doors.append(door)
	if end:
		var front := -seg_len / 2.0 if index == 0 else seg_len / 2.0
		var sgn := -1.0 if index == 0 else 1.0
		_box(node, Vector3(WIDTH - 0.1, 1.2, 0.4), Vector3(0, 2.3, front + sgn * 0.05), glass)  # windscreen
		var sign := _sign(node, Vector3(0, 3.02, front + sgn * 0.22), sgn)
		veh.signs.append(sign)
		for x in [-0.8, 0.8]:
			veh.headlights.append(_box(node, Vector3(0.35, 0.18, 0.08), Vector3(x, 0.95, front + sgn * 0.02), Color.WHITE))
		if index == 0:
			var pantograph := _box(node, Vector3(0.08, 0.9, 1.4), Vector3(0, 3.8, 0), Color("3a3f45"))
			pantograph.rotation.x = 0.5
	if index == 1:
		veh.status.append(_box(node, Vector3(0.9, 0.18, 0.9), Vector3(0, 3.45, 0), Color("2a2f36")))
	return node


func _nostalgic_section(veh: Dictionary, line: TransitNetwork.TransitLine) -> Node3D:
	var node := Node3D.new()
	var red := Color("8e1f1b")
	var cream := Color("efe2c2")
	var wood := Color("3b2a1e")
	var seg_len := 10.6
	var w := 2.25
	_box(node, Vector3(w, 1.1, seg_len), Vector3(0, 0.95, 0), red)
	_box(node, Vector3(w + 0.02, 0.95, seg_len - 1.4), Vector3(0, 2.0, 0), Color("22303a"))  # open-ish windows
	for z in range(-4, 5):
		_box(node, Vector3(w + 0.04, 0.95, 0.12), Vector3(0, 2.0, z * 1.1), cream)  # window posts
	_box(node, Vector3(w, 0.35, seg_len), Vector3(0, 2.62, 0), cream)
	var roof := _box(node, Vector3(w - 0.1, 0.25, seg_len + 0.3), Vector3(0, 2.92, 0), Color("5b1512"))
	roof.scale = Vector3(1, 1, 1)
	_box(node, Vector3(0.06, 0.06, 5.5), Vector3(0, 3.9, 1.6), wood).rotation.x = 0.35  # trolley pole
	for sgn in [-1.0, 1.0]:
		var front: float = sgn * seg_len / 2.0
		_box(node, Vector3(w, 1.9, 0.3), Vector3(0, 1.6, front), red)
		_box(node, Vector3(w - 0.4, 0.8, 0.32), Vector3(0, 2.1, front), Color("22303a"))
		veh.headlights.append(_box(node, Vector3(0.3, 0.3, 0.1), Vector3(0, 1.1, front + sgn * 0.16), Color.WHITE))
		veh.signs.append(_sign(node, Vector3(0, 2.72, front + sgn * 0.17), sgn))
		for side in [-1.0, 1.0]:
			veh.doors.append(_box(node, Vector3(0.05, 1.8, 0.9), Vector3(side * (w / 2 + 0.03), 1.3, front - sgn * 1.0), red.darkened(0.2)))
	veh.status.append(_box(node, Vector3(0.6, 0.16, 0.6), Vector3(0, 3.12, 0), Color("2a2f36")))
	return node


func _sign(parent: Node3D, pos: Vector3, facing: float) -> Label3D:
	var l := Label3D.new()
	l.font_size = 44
	l.pixel_size = 0.006
	l.outline_size = 6
	l.position = pos
	l.rotation.y = PI if facing < 0.0 else 0.0  # text faces +Z; front signs face forward
	l.modulate = Color("ffb347")
	parent.add_child(l)
	return l


func _box(parent: Node3D, size: Vector3, pos: Vector3, color: Color) -> MeshInstance3D:
	var mesh := BoxMesh.new()
	mesh.size = size
	var mi := MeshInstance3D.new()
	mi.mesh = mesh
	mi.position = pos
	mi.material_override = _mat(color)
	parent.add_child(mi)
	return mi


static func _mat(color: Color) -> StandardMaterial3D:
	var key := color.to_html()
	if not _mats.has(key):
		var m := StandardMaterial3D.new()
		m.albedo_color = color
		m.roughness = 0.35
		m.metallic = 0.1
		_mats[key] = m
	return _mats[key]


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
