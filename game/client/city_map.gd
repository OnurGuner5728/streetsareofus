class_name CityMap
extends CanvasLayer
## The radar minimap in the corner and the full-screen city map.
##
## The static city (buildings, streets, parks, tram lines) is drawn once into
## a texture. The minimap samples it through a shader that rotates with the
## player's heading and masks it to a circle; everything that moves (people,
## trams, the route) is drawn on top every frame.

signal destination_chosen(en: Vector2)
signal route_cleared

const TEX_SIZE := 1024
const MINI_RADIUS := 78.0
const MINI_RANGE_M := 90.0  # metres from centre to rim
const COLORS := {
	"ground": Color("1b2128"), "building": Color("3a4452"), "building_edge": Color("56627a"),
	"car": Color("5c6674"), "foot": Color("6f6a5e"), "park": Color("2b4a31"), "grass": Color("2f5536"),
	"plaza": Color("3d3b35"), "parking": Color("2a2e33"), "water": Color("1d3a55"), "pitch": Color("2d5a33"),
}
const PERSON := Color("f5f7fa")
const FRIEND := Color("4fc3f7")
const ASKING := Color("ffca28")
const ROUTE_WALK := Color("ffffff")
const GOAL := Color("ff6b4a")
const TRAM_GREEN := Color("2ee27a")
const CAR_KINDS := ["primary", "secondary", "tertiary", "unclassified", "residential", "living_street", "service", "busway"]

var client: GameClient
var map_texture: Texture2D
var _viewport: SubViewport
var _mini: Control
var _mini_map: ColorRect
var _big: Control
var _big_canvas: Control
var _info: Label
var _sweep := 0.0
var _zoom := 1.6  # big map pixels per metre
var _center := Vector2.ZERO  # big map centre, EN metres
var _fingers := {}
var _drag_from := Vector2.ZERO
var _dragged := false
var _pinch := 0.0
var _selected_stop := {}


func setup(game: GameClient) -> void:
	client = game
	layer = 3
	_render_texture()
	_build_minimap()
	_build_big_map()


# --- static texture -----------------------------------------------------------------

func _render_texture() -> void:
	_viewport = SubViewport.new()
	_viewport.size = Vector2i(TEX_SIZE, TEX_SIZE)
	_viewport.transparent_bg = false
	_viewport.render_target_update_mode = SubViewport.UPDATE_ONCE
	_viewport.disable_3d = true
	add_child(_viewport)
	var painter := Node2D.new()
	painter.draw.connect(_paint.bind(painter))
	_viewport.add_child(painter)
	map_texture = _viewport.get_texture()


func to_tex(en: Vector2) -> Vector2:
	var k := TEX_SIZE / client.zone.size_m
	var h := client.zone.half_size()
	return Vector2((en.x + h) * k, (h - en.y) * k)


func _paint(c: Node2D) -> void:
	var k := TEX_SIZE / client.zone.size_m
	c.draw_rect(Rect2(0, 0, TEX_SIZE, TEX_SIZE), COLORS.ground)
	for area in client.zone.areas:
		var poly := PackedVector2Array()
		for p in area.polygon:
			poly.append(to_tex(Vector2(float(p[0]), float(p[1]))))
		if Geometry2D.triangulate_polygon(poly).size() > 0:
			c.draw_colored_polygon(poly, COLORS.get(area.kind, COLORS.plaza))
	for road in client.zone.roads:
		var pts := PackedVector2Array()
		for p in road.points:
			pts.append(to_tex(Vector2(float(p[0]), float(p[1]))))
		var car: bool = CAR_KINDS.has(road.kind)
		c.draw_polyline(pts, COLORS.car if car else COLORS.foot, maxf(1.5, float(road.width) * k), true)
	for b in client.zone.buildings:
		var poly := PackedVector2Array()
		for p in b.footprint:
			poly.append(to_tex(Vector2(float(p[0]), float(p[1]))))
		if Geometry2D.triangulate_polygon(poly).size() > 0:
			c.draw_colored_polygon(poly, COLORS.building)
		poly.append(poly[0])
		c.draw_polyline(poly, COLORS.building_edge, 1.0)
	for line: TransitNetwork.TransitLine in client.transit.lines:
		for dir in ([1] if line.loop else [1, -1]):
			var pts := PackedVector2Array()
			var s := 0.0
			while s <= line.length:
				pts.append(to_tex(line.track_point(s, dir)))
				s += 3.0
			c.draw_polyline(pts, line.color.darkened(0.15), 2.5, true)


# --- minimap -------------------------------------------------------------------------

func _build_minimap() -> void:
	_mini = Control.new()
	_mini.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	var r := MINI_RADIUS
	var top := 70.0 if client.touch else 16.0
	_mini.offset_left = -2 * r - 16
	_mini.offset_right = -16
	_mini.offset_top = top
	_mini.offset_bottom = top + 2 * r
	_mini.mouse_filter = Control.MOUSE_FILTER_STOP
	_mini.gui_input.connect(_on_mini_input)
	add_child(_mini)
	_mini_map = ColorRect.new()
	_mini_map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_mini_map.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var shader := Shader.new()
	shader.code = """
shader_type canvas_item;
uniform sampler2D map : filter_linear;
uniform vec2 centre_uv;
uniform float heading;
uniform float uv_per_px;
void fragment() {
	vec2 px = (UV - 0.5) * 2.0;
	float r = length(px);
	if (r > 1.0) discard;
	vec2 s = px * 0.5 / uv_per_px * uv_per_px;
	float c = cos(heading);
	float sn = sin(heading);
	vec2 local = (UV - 0.5) * vec2(1.0, 1.0);
	// Screen offset (right, down) -> east/north offset, then to texture space.
	float east = local.x * c + local.y * sn;
	float north = local.x * sn - local.y * c;
	vec2 uv = centre_uv + vec2(east, -north) * uv_per_px;
	vec3 col = texture(map, uv).rgb;
	if (uv.x < 0.0 || uv.y < 0.0 || uv.x > 1.0 || uv.y > 1.0) col = vec3(0.07, 0.08, 0.1);
	float rim = smoothstep(0.93, 1.0, r);
	COLOR = vec4(mix(col, vec3(0.9), rim * 0.6), 0.88);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = shader
	mat.set_shader_parameter("map", map_texture)
	_mini_map.material = mat
	_mini.add_child(_mini_map)
	var overlay := Control.new()
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	overlay.draw.connect(_draw_mini_overlay.bind(overlay))
	_mini.add_child(overlay)


func _on_mini_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		open_big()
		_mini.accept_event()


func _process(delta: float) -> void:
	if client == null or client.body == null:
		return
	_sweep = fmod(_sweep + delta * 1.4, TAU)
	var me := ZoneData.to_en(client.body.global_position)
	var mat := _mini_map.material as ShaderMaterial
	mat.set_shader_parameter("centre_uv", to_tex(me) / TEX_SIZE)
	mat.set_shader_parameter("heading", client.yaw)
	# Minimap is 2r pixels across and shows 2 * MINI_RANGE_M metres.
	mat.set_shader_parameter("uv_per_px", MINI_RANGE_M * 2.0 / client.zone.size_m)
	for child in _mini.get_children():
		child.queue_redraw()
	if _big.visible:
		_big_canvas.queue_redraw()


## EN point -> minimap pixels (heading up).
func _mini_point(me: Vector2, q: Vector2) -> Vector2:
	var d := q - me
	var c := cos(client.yaw)
	var s := sin(client.yaw)
	var screen := Vector2(d.x * c + d.y * s, d.x * s - d.y * c)
	return Vector2(MINI_RADIUS, MINI_RADIUS) + screen * (MINI_RADIUS / MINI_RANGE_M)


func _draw_mini_overlay(o: Control) -> void:
	var me := ZoneData.to_en(client.body.global_position)
	var centre := Vector2(MINI_RADIUS, MINI_RADIUS)
	var r := MINI_RADIUS
	# Radar sweep.
	var sweep_pts := PackedVector2Array([centre])
	for i in 13:
		var a := _sweep - 0.5 + i * 0.5 / 12.0
		sweep_pts.append(centre + Vector2(cos(a), sin(a)) * r)
	o.draw_colored_polygon(sweep_pts, Color(0.4, 0.9, 0.6, 0.08))
	o.draw_line(centre, centre + Vector2(cos(_sweep), sin(_sweep)) * r, Color(0.5, 1.0, 0.7, 0.35), 1.5)
	var nav := client.navigator
	if nav and nav.has_plan():
		for leg in nav.plan.legs:
			var col: Color = ROUTE_WALK if leg.type == "walk" else TRAM_GREEN
			_mini_polyline(o, me, leg.points, col, 3.0 if leg.type == "tram" else 2.0)
		_mini_marker(o, me, nav.plan.goal, GOAL, 5.0, true)
	for line: TransitNetwork.TransitLine in client.transit.lines:
		for st in line.stops:
			if st.in_zone and me.distance_to(st.pos) < MINI_RANGE_M:
				var p := _mini_point(me, st.pos)
				o.draw_rect(Rect2(p - Vector2(3, 3), Vector2(6, 6)), Color.WHITE)
				o.draw_rect(Rect2(p - Vector2(3, 3), Vector2(6, 6)), line.color, false, 1.5)
		for v in line.vehicles:
			var vs := line.state(v, client.server_now())
			if me.distance_to(vs.pos) > MINI_RANGE_M * 1.2:
				continue
			var lit := client.fleet != null and client.fleet.highlight_line == line.index and client.fleet.highlight_dir == int(vs.dir)
			var a := _mini_point(me, vs.pos - vs.heading * line.vehicle_length / 2.0)
			var b := _mini_point(me, vs.pos + vs.heading * line.vehicle_length / 2.0)
			_clip_line(o, a, b, TRAM_GREEN if lit else line.color, 5.0)
	for id in client.remotes:
		var rp: RemotePlayer = client.remotes[id]
		var col := PERSON
		if client.conversations.has(id):
			col = FRIEND
		elif client.muted.has(id):
			col = Color(0.6, 0.6, 0.6)
		for req in client.incoming.values():
			if int(req.from) == id:
				col = ASKING
		_mini_marker(o, me, ZoneData.to_en(rp.global_position), col, 3.5, true)
	# You, always pointing up.
	o.draw_colored_polygon(PackedVector2Array([centre + Vector2(0, -8), centre + Vector2(5.5, 6), centre + Vector2(0, 3), centre + Vector2(-5.5, 6)]), Color("ffd54f"))
	# North on the rim.
	var n := _mini_point(me, me + Vector2(0, 1000)) - centre
	var north := centre + n.normalized() * (r - 9)
	o.draw_circle(north, 8, Color(0.1, 0.12, 0.15, 0.9))
	var font := ThemeDB.fallback_font
	o.draw_string(font, north + Vector2(-4, 5), "K", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	o.draw_arc(centre, r, 0, TAU, 64, Color(1, 1, 1, 0.5), 1.5)


## Dot inside the radar, arrow on the rim for things further away.
func _mini_marker(o: Control, me: Vector2, q: Vector2, col: Color, size: float, rim_arrow: bool) -> void:
	var centre := Vector2(MINI_RADIUS, MINI_RADIUS)
	var p := _mini_point(me, q)
	var off := p - centre
	if off.length() <= MINI_RADIUS - 5:
		o.draw_circle(p, size, col)
		o.draw_arc(p, size, 0, TAU, 12, Color(0, 0, 0, 0.6), 1.0)
	elif rim_arrow:
		var dir := off.normalized()
		var tip := centre + dir * (MINI_RADIUS - 3)
		var side := Vector2(-dir.y, dir.x)
		o.draw_colored_polygon(PackedVector2Array([tip, tip - dir * 8 + side * 4, tip - dir * 8 - side * 4]), col)


func _mini_polyline(o: Control, me: Vector2, points: PackedVector2Array, col: Color, width: float) -> void:
	for i in points.size() - 1:
		_clip_line(o, _mini_point(me, points[i]), _mini_point(me, points[i + 1]), col, width)


func _clip_line(o: Control, a: Vector2, b: Vector2, col: Color, width: float) -> void:
	var centre := Vector2(MINI_RADIUS, MINI_RADIUS)
	var r := MINI_RADIUS - 2
	var ina := a.distance_to(centre) <= r
	var inb := b.distance_to(centre) <= r
	if not ina or not inb:
		var hits := Geometry2D.segment_intersects_circle(a, b, centre, r)
		if not ina and not inb:
			return
		var t := hits if hits >= 0.0 else 0.0
		if not ina:
			a = a.lerp(b, t)
		else:
			b = a.lerp(b, t)
	o.draw_line(a, b, col, width, true)


# --- big map ---------------------------------------------------------------------------

func _build_big_map() -> void:
	_big = Control.new()
	_big.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_big.visible = false
	add_child(_big)
	var bg := ColorRect.new()
	bg.color = Color("0e1216")
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_big.add_child(bg)
	_big_canvas = Control.new()
	_big_canvas.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_big_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_big_canvas.draw.connect(_draw_big.bind(_big_canvas))
	_big.add_child(_big_canvas)
	var bar := HBoxContainer.new()
	bar.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	bar.offset_left = -470
	bar.offset_right = -12
	bar.offset_top = 12
	bar.alignment = BoxContainer.ALIGNMENT_END
	bar.add_theme_constant_override("separation", 8)
	_big.add_child(bar)
	for spec in [["−", _zoom_by.bind(1.0 / 1.4)], ["+", _zoom_by.bind(1.4)], ["Konumum", _center_on_me],
			["Rotayı sil", _clear_route], ["Kapat", close_big]]:
		var b := Button.new()
		b.text = spec[0]
		b.custom_minimum_size = Vector2(52 if spec[0].length() == 1 else 96, 44)
		b.pressed.connect(spec[1])
		bar.add_child(b)
	_info = Label.new()
	_info.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_info.offset_left = 12
	_info.offset_top = -150
	_info.offset_right = 620
	_info.offset_bottom = -12
	_info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_info.vertical_alignment = VERTICAL_ALIGNMENT_BOTTOM
	_info.add_theme_font_size_override("font_size", 16)
	_info.add_theme_constant_override("outline_size", 6)
	_info.add_theme_color_override("font_outline_color", Color.BLACK)
	_big.add_child(_info)


func is_big_open() -> bool:
	return _big.visible


func open_big() -> void:
	_center_on_me()
	_big.visible = true
	_selected_stop = {}
	_update_info()
	if client.touch == null:
		Input.mouse_mode = Input.MOUSE_MODE_VISIBLE


func close_big() -> void:
	_big.visible = false
	_fingers.clear()
	if client.touch == null and not client.hud.is_modal_open():
		Input.mouse_mode = Input.MOUSE_MODE_CAPTURED


func _center_on_me() -> void:
	_center = ZoneData.to_en(client.body.global_position)


func _zoom_by(f: float) -> void:
	_zoom = clampf(_zoom * f, 0.5, 8.0)


func _clear_route() -> void:
	route_cleared.emit()
	_selected_stop = {}
	_update_info()


func _to_screen(en: Vector2) -> Vector2:
	return _big_canvas.size / 2.0 + Vector2(en.x - _center.x, -(en.y - _center.y)) * _zoom


func _to_world(screen: Vector2) -> Vector2:
	var d := (screen - _big_canvas.size / 2.0) / _zoom
	return Vector2(_center.x + d.x, _center.y - d.y)


func _draw_big(c: Control) -> void:
	var h := client.zone.half_size()
	var tl := _to_screen(Vector2(-h, h))
	var br := _to_screen(Vector2(h, -h))
	c.draw_texture_rect(map_texture, Rect2(tl, br - tl), false)
	var font := ThemeDB.fallback_font
	# Where people are, coarsely: counts per 64 m cell, never positions.
	var cells := ceili(client.zone.size_m / Protocol.POPULATION_CELL)
	for i in client.population.size():
		var n := client.population[i]
		if n == 0:
			continue
		var cx := (i % cells + 0.5) * Protocol.POPULATION_CELL - h
		var cn := h - (i / cells + 0.5) * Protocol.POPULATION_CELL
		c.draw_circle(_to_screen(Vector2(cx, cn)), Protocol.POPULATION_CELL * 0.5 * _zoom, Color(1.0, 0.6, 0.2, minf(0.12 + 0.06 * n, 0.4)))
	var nav := client.navigator
	if nav and nav.has_plan():
		for leg in nav.plan.legs:
			var pts := PackedVector2Array()
			for p in leg.points:
				pts.append(_to_screen(p))
			if pts.size() >= 2:
				c.draw_polyline(pts, TRAM_GREEN if leg.type == "tram" else ROUTE_WALK, 5.0 if leg.type == "tram" else 3.0, true)
		var g := _to_screen(nav.plan.goal)
		c.draw_circle(g, 9, GOAL)
		c.draw_circle(g, 4, Color.WHITE)
	var t := client.server_now()
	for line: TransitNetwork.TransitLine in client.transit.lines:
		for st in line.stops:
			if not st.in_zone:
				continue
			var p := _to_screen(st.pos)
			c.draw_circle(p, 7, Color.WHITE)
			c.draw_arc(p, 7, 0, TAU, 16, line.color, 3.0)
			if _zoom >= 1.2:
				c.draw_string_outline(font, p + Vector2(10, 5), st.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color.BLACK)
				c.draw_string(font, p + Vector2(10, 5), st.name, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		for v in line.vehicles:
			var vs := line.state(v, t)
			var lit := client.fleet != null and client.fleet.highlight_line == line.index and client.fleet.highlight_dir == int(vs.dir)
			var a := _to_screen(vs.pos - vs.heading * line.vehicle_length / 2.0)
			var b := _to_screen(vs.pos + vs.heading * line.vehicle_length / 2.0)
			c.draw_line(a, b, TRAM_GREEN if lit else line.color, maxf(6.0, 2.4 * _zoom), true)
	for id in client.remotes:
		var rp: RemotePlayer = client.remotes[id]
		var p := _to_screen(ZoneData.to_en(rp.global_position))
		c.draw_circle(p, 6, FRIEND if client.conversations.has(id) else PERSON)
		c.draw_string_outline(font, p + Vector2(8, -6), rp.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, 4, Color.BLACK)
		c.draw_string(font, p + Vector2(8, -6), rp.display_name, HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color.WHITE)
	var me := _to_screen(ZoneData.to_en(client.body.global_position))
	var fwd := Vector2(-sin(client.yaw), -cos(client.yaw))  # screen: x east, y south
	var side := Vector2(-fwd.y, fwd.x)
	c.draw_colored_polygon(PackedVector2Array([me + fwd * 12, me - fwd * 7 + side * 7, me - fwd * 3, me - fwd * 7 - side * 7]), Color("ffd54f"))
	# Legend.
	var y := 70.0
	for line: TransitNetwork.TransitLine in client.transit.lines:
		c.draw_rect(Rect2(12, y - 10, 22, 8), line.color)
		var label := "%s  %s%s" % [line.id, line.short_name, "" if line.source == "osm" else "  (simülasyon hattı)"]
		c.draw_string_outline(font, Vector2(42, y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, 4, Color.BLACK)
		c.draw_string(font, Vector2(42, y), label, HORIZONTAL_ALIGNMENT_LEFT, -1, 13, Color.WHITE)
		y += 20
	c.draw_string_outline(font, Vector2(12, 40), "Haritaya dokun: oraya rota çiz · Durağa dokun: sıradaki tramvaylar", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, 4, Color.BLACK)
	c.draw_string(font, Vector2(12, 40), "Haritaya dokun: oraya rota çiz · Durağa dokun: sıradaki tramvaylar", HORIZONTAL_ALIGNMENT_LEFT, -1, 14, Color("ffe08a"))


func _input(event: InputEvent) -> void:
	if not _big.visible:
		return
	if event is InputEventScreenTouch:
		var e := event as InputEventScreenTouch
		if e.pressed:
			if _over_buttons(e.position):
				return
			_fingers[e.index] = e.position
			_drag_from = e.position
			_dragged = false
			if _fingers.size() == 2:
				_pinch = (_fingers.values()[0] as Vector2).distance_to(_fingers.values()[1])
		else:
			if _fingers.has(e.index) and _fingers.size() == 1 and not _dragged:
				_tap(e.position)
			_fingers.erase(e.index)
		get_viewport().set_input_as_handled()
	elif event is InputEventScreenDrag:
		var e := event as InputEventScreenDrag
		if not _fingers.has(e.index):
			return
		var prev: Vector2 = _fingers[e.index]
		_fingers[e.index] = e.position
		if _fingers.size() >= 2:
			var d := (_fingers.values()[0] as Vector2).distance_to(_fingers.values()[1])
			if _pinch > 0.0:
				_zoom = clampf(_zoom * d / _pinch, 0.5, 8.0)
			_pinch = d
			_dragged = true
		else:
			if e.position.distance_to(_drag_from) > 10.0:
				_dragged = true
			_center -= Vector2(e.position.x - prev.x, -(e.position.y - prev.y)) / _zoom
		get_viewport().set_input_as_handled()
	elif client.touch == null and event is InputEventMouseButton:
		var m := event as InputEventMouseButton
		if _over_buttons(m.position):
			return
		if m.button_index == MOUSE_BUTTON_WHEEL_UP and m.pressed:
			_zoom_by(1.15)
		elif m.button_index == MOUSE_BUTTON_WHEEL_DOWN and m.pressed:
			_zoom_by(1.0 / 1.15)
		elif m.button_index == MOUSE_BUTTON_LEFT:
			if m.pressed:
				_drag_from = m.position
				_dragged = false
			elif not _dragged:
				_tap(m.position)
		get_viewport().set_input_as_handled()
	elif client.touch == null and event is InputEventMouseMotion and (event as InputEventMouseMotion).button_mask & MOUSE_BUTTON_MASK_LEFT:
		var mm := event as InputEventMouseMotion
		if mm.position.distance_to(_drag_from) > 6.0:
			_dragged = true
		_center -= Vector2(mm.relative.x, -mm.relative.y) / _zoom
		get_viewport().set_input_as_handled()


func _over_buttons(pos: Vector2) -> bool:
	for child in _big.get_children():
		if child is HBoxContainer and (child as Control).get_global_rect().has_point(pos):
			return true
	return false


func _tap(screen: Vector2) -> void:
	# A stop first: show its next trams.
	for line: TransitNetwork.TransitLine in client.transit.lines:
		for i in line.stops.size():
			if line.stops[i].in_zone and _to_screen(line.stops[i].pos).distance_to(screen) < 16.0:
				_selected_stop = {"name": line.stops[i].name, "pos": line.stops[i].pos}
				_update_info()
				destination_chosen.emit(line.stops[i].pos)
				return
	_selected_stop = {}
	destination_chosen.emit(_to_world(screen))
	_update_info()


func _update_info() -> void:
	var lines := PackedStringArray()
	if not _selected_stop.is_empty():
		lines.append("Durak: %s" % _selected_stop.name)
		lines.append_array(arrivals_at(_selected_stop.name))
	var nav := client.navigator
	if nav and nav.has_plan():
		lines.append(nav.summary())
	_info.text = "\n".join(lines)


## "K1 → Aytemiz İş Merkezi: 1 dk 20 sn" for every line serving a stop name.
func arrivals_at(stop_name: String) -> PackedStringArray:
	var out := PackedStringArray()
	var t := client.server_now()
	for line: TransitNetwork.TransitLine in client.transit.lines:
		for i in line.stops.size():
			if line.stops[i].name != stop_name or not line.stops[i].in_zone:
				continue
			for dir in ([1] if line.loop else [1, -1]):
				if line.reachable(i, dir).is_empty():
					continue
				var dep := line.departure_after(i, dir, t)
				if dep.is_empty():
					continue
				var wait := float(dep.arrive) - t
				out.append("  %s → %s: %s" % [line.id, line.destination(dir),
					"durakta" if wait <= 0.0 else RoutePlanner.describe_seconds(wait)])
	return out


func refresh_info() -> void:
	if _big.visible:
		_update_info()
