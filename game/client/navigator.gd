class_name Navigator
extends Node3D
## The journey the player asked for on the map: a moving arrow ribbon on the
## pavement, a light beam over the destination, a marker at the stop to
## board from, one-line directions, and the right tram lit green. On the
## planned tram it asks for the stop before yours by itself.

const ARRIVE_RADIUS := 6.0
const OFF_ROUTE := 20.0
const RIBBON_WIDTH := 0.9

const RIBBON_SHADER := """
shader_type spatial;
render_mode unshaded, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 tint : source_color = vec4(1.0, 1.0, 1.0, 1.0);
void fragment() {
	float along = UV.x;
	float across = abs(UV.y - 0.5) * 2.0;
	float chevron = fract((along - across * 0.6) * 0.5 - TIME * 0.9);
	float arrow = smoothstep(0.0, 0.08, chevron) * (1.0 - smoothstep(0.35, 0.45, chevron));
	float edge = 1.0 - smoothstep(0.75, 1.0, across);
	ALBEDO = tint.rgb;
	ALPHA = edge * (0.18 + 0.55 * arrow);
}
"""
const BEAM_SHADER := """
shader_type spatial;
render_mode unshaded, blend_add, cull_disabled, depth_draw_never, shadows_disabled;
uniform vec4 tint : source_color = vec4(1.0, 0.42, 0.29, 1.0);
void fragment() {
	float pulse = 0.75 + 0.25 * sin(TIME * 3.0);
	ALBEDO = tint.rgb * pulse;
	ALPHA = (1.0 - UV.y) * 0.6;
}
"""

var client: GameClient
var plan := {}
var _goal := Vector2.ZERO
var _ribbon: MeshInstance3D
var _beam: MeshInstance3D
var _board_marker: Label3D
var _check_at := 0.0
var _requested_leg := -1
var _rode := false  # got on the planned tram
var _walk_after_built := false


func setup(game: GameClient) -> void:
	client = game
	_ribbon = MeshInstance3D.new()
	_ribbon.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	var rm := ShaderMaterial.new()
	rm.shader = _shader(RIBBON_SHADER)
	_ribbon.material_override = rm
	add_child(_ribbon)
	_beam = MeshInstance3D.new()
	var cyl := CylinderMesh.new()
	cyl.top_radius = 0.25
	cyl.bottom_radius = 0.45
	cyl.height = 70.0
	cyl.cap_top = false
	cyl.cap_bottom = false
	_beam.mesh = cyl
	var bm := ShaderMaterial.new()
	bm.shader = _shader(BEAM_SHADER)
	_beam.material_override = bm
	_beam.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	_beam.visible = false
	add_child(_beam)
	_board_marker = Label3D.new()
	_board_marker.billboard = BaseMaterial3D.BILLBOARD_ENABLED
	_board_marker.font_size = 48
	_board_marker.pixel_size = 0.008
	_board_marker.outline_size = 10
	_board_marker.no_depth_test = true
	_board_marker.modulate = Color("2ee27a")
	_board_marker.visible = false
	add_child(_board_marker)


static func _shader(code: String) -> Shader:
	var s := Shader.new()
	s.code = code
	return s


func has_plan() -> bool:
	return not plan.is_empty()


func set_destination(goal: Vector2) -> void:
	_goal = goal
	_replan()


func clear() -> void:
	plan = {}
	_ribbon.mesh = null
	_beam.visible = false
	_board_marker.visible = false
	if client.fleet:
		client.fleet.set_highlight(-1, 0)


func _me() -> Vector2:
	return ZoneData.to_en(client.body.global_position)


func _replan() -> void:
	plan = RoutePlanner.plan(client.zone.road_graph(), client.transit, _me(), _goal, client.server_now(), Protocol.WALK_SPEED)
	_check_at = client.server_now() + 3.0
	_requested_leg = -1
	_rode = false
	_walk_after_built = false
	var tram := tram_leg()
	if client.fleet:
		client.fleet.set_highlight(int(tram.line) if not tram.is_empty() else -1, int(tram.get("dir", 0)))
	_beam.visible = true
	_beam.position = ZoneData.to_godot(_goal.x, _goal.y, 35.0)
	_board_marker.visible = not tram.is_empty()
	if not tram.is_empty():
		var line: TransitNetwork.TransitLine = client.transit.lines[tram.line]
		var plat := line.platform(int(tram.from), int(tram.dir))
		_board_marker.position = ZoneData.to_godot(plat.x, plat.y, 3.2)
		_board_marker.text = "Buradan bin: %s → %s" % [line.id, line.destination(int(tram.dir))]
	_build_ribbon()


func tram_leg() -> Dictionary:
	for leg in plan.get("legs", []):
		if leg.type == "tram":
			return leg
	return {}


## The walking leg the player is on now: the first one before boarding,
## the last one after getting off.
func _current_walk() -> Dictionary:
	var legs: Array = plan.get("legs", [])
	if legs.is_empty():
		return {}
	if legs.size() == 1:
		return legs[0]
	return legs[2] if _boarded_already() else legs[0]


## Rode the planned tram and got off again.
func _boarded_already() -> bool:
	return _rode and client.riding.is_empty()


func _build_ribbon() -> void:
	var walk := _current_walk()
	if walk.is_empty():
		_ribbon.mesh = null
		return
	var pts: PackedVector2Array = walk.points
	if pts.size() < 2:
		_ribbon.mesh = null
		return
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var along := 0.0
	for i in pts.size() - 1:
		var a := pts[i]
		var b := pts[i + 1]
		var d := (b - a).normalized()
		var n := Vector2(-d.y, d.x) * RIBBON_WIDTH / 2.0
		var seg := a.distance_to(b)
		var corners := [a + n, a - n, b - n, b + n]
		var uvs := [Vector2(along, 0), Vector2(along, 1), Vector2(along + seg, 1), Vector2(along + seg, 0)]
		for k in [0, 1, 2, 0, 2, 3]:
			st.set_uv(uvs[k])
			var c: Vector2 = corners[k]
			st.add_vertex(Vector3(c.x, 0.09, -c.y))
		along += seg
	_ribbon.mesh = st.commit()


func update() -> void:
	if plan.is_empty():
		return
	var me := _me()
	if me.distance_to(_goal) < ARRIVE_RADIUS and client.riding.is_empty():
		client.hud.notice("Vardın!", 3.0)
		clear()
		return
	var t := client.server_now()
	var tram := tram_leg()
	if not client.riding.is_empty() and not tram.is_empty() \
			and int(client.riding.line) == int(tram.line):
		_rode = true
		_board_marker.visible = false
		var st := client.ride_state()
		# Ask for your stop while approaching it, once.
		if not st.dwelling and int(st.next) == int(tram.to) and not bool(client.riding.get("stop_request", false)) \
				and _requested_leg != int(tram.to):
			_requested_leg = int(tram.to)
			client.tram_action()
		return
	if _boarded_already() and not _walk_after_built:
		_walk_after_built = true
		_build_ribbon()
	if t < _check_at:
		return
	_check_at = t + 3.0
	var missed := not tram.is_empty() and not _rode and client.riding.is_empty() and t > float(tram.depart) + 2.0
	if missed or _off_route(me):
		_replan()


func _off_route(me: Vector2) -> bool:
	var walk := _current_walk()
	if walk.is_empty():
		return false
	var pts: PackedVector2Array = walk.points
	var best := INF
	for i in pts.size() - 1:
		best = minf(best, me.distance_to(Geometry2D.get_closest_point_to_segment(me, pts[i], pts[i + 1])))
	return best > OFF_ROUTE


func summary() -> String:
	if plan.is_empty():
		return ""
	var tram := tram_leg()
	var total := RoutePlanner.describe_seconds(float(plan.arrive) - client.server_now())
	if tram.is_empty():
		return "Rota: yürüyerek %s" % total
	var line: TransitNetwork.TransitLine = client.transit.lines[tram.line]
	return "Rota: %s ile %s (yürüyerek %s)" % [line.id, total, RoutePlanner.describe_seconds(float(plan.walk_total))]


## One line of directions for the HUD.
func instruction() -> String:
	if plan.is_empty():
		return ""
	var t := client.server_now()
	var me := _me()
	var tram := tram_leg()
	if tram.is_empty():
		return "Hedefe yürü: %d m" % roundi(RoadGraph.length_of(_remaining(plan.legs[0].points, me)))
	var line: TransitNetwork.TransitLine = client.transit.lines[tram.line]
	var from_name: String = line.stops[tram.from].name
	var to_name: String = line.stops[tram.to].name
	if not client.riding.is_empty():
		if int(client.riding.line) != line.index:
			return "Bu tramvay rotanda değil"
		var st := client.ride_state()
		var next_name: String = line.stops[st.next].name
		var eta := RoutePlanner.describe_seconds(float(st.leg_left)) if not st.dwelling else "kapılar açık"
		return "%s'de · %s'de ineceksin · sonraki durak %s (%s)" % [line.id, to_name, next_name, eta]
	if _boarded_already():
		return "Hedefe yürü: %d m" % roundi(RoadGraph.length_of(_remaining(plan.legs[2].points, me)))
	var wait := float(tram.board_at) - t
	var walk_m := roundi(RoadGraph.length_of(_remaining(plan.legs[0].points, me)))
	var tram_when := "durakta" if wait <= 0.0 else RoutePlanner.describe_seconds(wait) + " sonra"
	return "%s durağına yürü (%d m) · %s → %s tramvayı %s · %s'de in" % [
		from_name, walk_m, line.id, line.destination(int(tram.dir)), tram_when, to_name]


static func _remaining(points: PackedVector2Array, me: Vector2) -> PackedVector2Array:
	var best := 0
	var best_d := INF
	for i in points.size() - 1:
		var d := me.distance_to(Geometry2D.get_closest_point_to_segment(me, points[i], points[i + 1]))
		if d < best_d:
			best_d = d
			best = i
	var out := PackedVector2Array([me])
	for i in range(best + 1, points.size()):
		out.append(points[i])
	return out
