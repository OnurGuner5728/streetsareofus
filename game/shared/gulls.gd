class_name Gulls
extends RefCounted
## Seagulls (martılar) over the strait. Like the ferries they are a pure
## function of the zone package and the world time: every client sees the
## same gull at the same place, no network traffic. Each gull circles a
## centre: some trail a ferry (the classic simit-chasing Kadıköy ferry
## gulls), some wheel over a pier, some soar wide over open water.

const MAX := 36
const FOLLOW_SHARE := 0.4
const PIER_SHARE := 0.3
const CALL_PERIOD := 9.0

class Gull:
	extends RefCounted
	var id := 0
	var kind := "sea"  # "ferry" | "pier" | "sea"
	var ship: Ferries.Ship  # ferry gulls trail this ship
	var centre := Vector2.ZERO  # pier and sea gulls circle this point (Godot XZ)
	var radius := 30.0
	var omega := 0.3  # rad/s, sign = turning direction
	var phase := 0.0
	var height := 12.0  # above the sea
	var period := 10.0  # call rhythm (s)
	var pos := Vector3.ZERO  # world position at the last place() (y relative to the sea)
	var dir := Vector2.RIGHT  # heading
	var bank := 0.0  # roll into the turn
	var visible := true

var gulls: Array = []
var _ferries: Ferries


static func for_ferries(f: Ferries, zone_id: String) -> Gulls:
	return Gulls.new(f, zone_id)


func _init(f: Ferries, zone_id: String) -> void:
	_ferries = f
	if f.lines.is_empty():
		return
	for i in MAX:
		var g := Gull.new()
		g.id = i
		var key := "gull:%s:%d" % [zone_id, i]
		var u := Traffic.h01(key + ":kind")
		g.phase = Traffic.h01(key + ":phase") * TAU
		g.omega = (0.22 + 0.25 * Traffic.h01(key + ":w")) * (1.0 if Traffic.h01(key + ":dir") < 0.5 else -1.0)
		g.period = CALL_PERIOD + 8.0 * Traffic.h01(key + ":call")
		if u < FOLLOW_SHARE and not f.ships.is_empty():
			g.kind = "ferry"
			g.ship = f.ships[i % f.ships.size()]
			g.radius = 12.0 + 22.0 * Traffic.h01(key + ":r")
			g.height = 5.0 + 9.0 * Traffic.h01(key + ":h")
		elif u < FOLLOW_SHARE + PIER_SHARE:
			g.kind = "pier"
			var line: Ferries.Line = f.lines[i % f.lines.size()]
			g.centre = line.berth_a if i % 2 == 0 or line.away_b else line.berth_b
			g.radius = 18.0 + 40.0 * Traffic.h01(key + ":r")
			g.height = 9.0 + 14.0 * Traffic.h01(key + ":h")
		else:
			g.kind = "sea"
			var line2: Ferries.Line = f.lines[i % f.lines.size()]
			var along := line2.length * (0.15 + 0.5 * Traffic.h01(key + ":along"))
			g.centre = line2.at(along)
			g.radius = 70.0 + 130.0 * Traffic.h01(key + ":r")
			g.height = 14.0 + 22.0 * Traffic.h01(key + ":h")
			g.omega *= 0.45
		gulls.append(g)


## Fills `g` with its place at world time `t`. A gull trailing a ship that
## is over the horizon is hidden.
func place(g: Gull, t: float) -> void:
	var a := g.omega * t + g.phase
	var c := g.centre
	g.visible = true
	if g.kind == "ferry":
		_ferries.place(g.ship, t)
		if g.ship.away:
			g.visible = false
		# Trail behind the stern while the ship sails (drifting back and forth a
		# little) and circle right over it at the berth; the ship's speed
		# ramps smoothly, so the centre never jumps when it reverses.
		var trail := clampf(g.ship.speed / 2.0, 0.0, 1.0)
		c = g.ship.pos - g.ship.dir * (14.0 + 6.0 * sin(0.17 * t + g.phase)) * trail
	var off := Vector2(cos(a), sin(a)) * g.radius
	var p := c + off
	g.pos = Vector3(p.x, g.height + 1.4 * sin(0.9 * t + g.phase * 3.0), p.y)
	# Tangent of the circle (derivative of off w.r.t. the angle), plus the ship's drift for followers.
	var tangent := Vector2(-sin(a), cos(a)) * signf(g.omega)
	g.dir = tangent
	g.bank = clampf(0.35 * signf(g.omega), -0.5, 0.5) if g.kind != "ferry" else 0.45 * signf(g.omega)


## True if the gull's call time falls inside (t0, t1].
func call_between(g: Gull, t0: float, t1: float) -> bool:
	var k0 := floorf((t0 + g.phase) / g.period)
	var k1 := floorf((t1 + g.phase) / g.period)
	if k1 <= k0:
		return false
	# Only some cycles carry a call.
	return Traffic.h01("gullcall:%d:%d" % [g.id, int(k1)]) < 0.55
