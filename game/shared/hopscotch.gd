class_name Hopscotch
extends RefCounted
## Seksek (hopscotch) grids painted on the ground at a few fixed spots of the
## zone. The spots are derived deterministically from the zone itself (play
## areas, squares and parks first, then walkable spawn points), so the server
## and every client compute the same grids and nothing goes over the wire.
##
## A grid is {id, origin: Vector2 (XZ of the middle of the start line),
## yaw, y (ground height at the origin)}; it runs away from the start line
## along the grid's forward direction (a yaw-rotated -Z). In grid-local
## coordinates (u to the right, v forward from the start line):
##   start strip   v in [-START_DEPTH, 0), |u| <= SQ        (square 0)
##   row r         v in [r*SQ, (r+1)*SQ), ROWS[r] squares wide (one or two)
## Squares are numbered 1.. in row order (a pair row has left, then right).
## locate() judges a point: a numbered square, the start strip, a chalk line
## (a thin margin around every edge) or outside the grid.

const SQ := 1.4
const ROWS := [1, 1, 2, 1, 2, 1]
const START_DEPTH := 1.8
const LINE_MARGIN := 0.09
const MAX_GRIDS := 6
const MIN_SPACING := 80.0
const FLAT_TOLERANCE := 0.35
const MAX_CANDIDATES := 500

const OUTSIDE := -1
const LINE := -2
const START := 0

var grids: Array = []


static func for_zone(z: ZoneData) -> Hopscotch:
	if z.has_meta("hopscotch"):
		return z.get_meta("hopscotch")
	var h := Hopscotch.new(z)
	z.set_meta("hopscotch", h)
	return h


func _init(zone: ZoneData) -> void:
	var streets := StreetLayout.for_zone(zone)
	for spot: Vector2 in _candidates(zone):
		if grids.size() >= MAX_GRIDS:
			break
		var too_close := false
		for g: Dictionary in grids:
			if (g.origin as Vector2).distance_to(spot) < MIN_SPACING:
				too_close = true
				break
		if too_close:
			continue
		for turn in 4:
			var yaw := turn * PI / 2.0
			if _fits(zone, streets, spot, yaw):
				grids.append({"id": grids.size(), "origin": spot, "yaw": yaw, "y": zone.terrain.height(spot.x, spot.y)})
				break


## Where to try, in order of preference: the middle of plazas, playgrounds
## and parks (shifted a little so the chalk is not under a ball), then the
## walkable spawn points.
func _candidates(zone: ZoneData) -> Array:
	var out := []
	for kind in ["playground", "plaza", "park", "pitch"]:
		for area in zone.areas:
			if str(area.kind) != kind:
				continue
			var poly := WorldBuilder.footprint_xz(area.polygon)
			if poly.size() < 3:
				continue
			var c := Vector2.ZERO
			for p in poly:
				c += p
			c /= poly.size()
			for off in [Vector2.ZERO, Vector2(6, 0), Vector2(-6, 0), Vector2(0, 6), Vector2(0, -6), Vector2(10, 10), Vector2(-10, -10)]:
				if Geometry2D.is_point_in_polygon(c + off, poly):
					out.append(c + off)
	var step := maxi(1, zone.spawn_points.size() / MAX_CANDIDATES)
	var i := 0
	while i < zone.spawn_points.size():
		var sp: Dictionary = zone.spawn_points[i]
		out.append(Vector2(float(sp.e), -float(sp.n)))
		i += step
	return out


## True when the whole footprint (start strip included) is open, flat ground:
## no building, rails, road, bench or lamp on it.
func _fits(zone: ZoneData, streets: StreetLayout, origin: Vector2, yaw: float) -> bool:
	var y0 := zone.terrain.height(origin.x, origin.y)
	var length := SQ * ROWS.size()
	var v := -START_DEPTH
	while v <= length + 0.01:
		var u := -SQ
		while u <= SQ + 0.01:
			var p := to_world({"origin": origin, "yaw": yaw}, Vector2(u, v))
			if not streets.inside_zone(p, 6.0) or streets.building_clearance(p) < 0.8 or streets.near_track(p, 2.5) \
					or streets._occupied(p, 0.3) or PropLayout._on_road(streets, p, 0.3) \
					or absf(zone.terrain.height(p.x, p.y) - y0) > FLAT_TOLERANCE:
				return false
			u += 0.7
		v += 0.7
	return true


## Forward and right directions of a grid in XZ.
static func forward(grid: Dictionary) -> Vector2:
	var yaw: float = grid.yaw
	return Vector2(-sin(yaw), -cos(yaw))


static func right(grid: Dictionary) -> Vector2:
	var yaw: float = grid.yaw
	return Vector2(cos(yaw), -sin(yaw))


static func to_local(grid: Dictionary, xz: Vector2) -> Vector2:
	var d := xz - (grid.origin as Vector2)
	return Vector2(d.dot(right(grid)), d.dot(forward(grid)))


static func to_world(grid: Dictionary, local: Vector2) -> Vector2:
	return (grid.origin as Vector2) + right(grid) * local.x + forward(grid) * local.y


static func square_count() -> int:
	var n := 0
	for w: int in ROWS:
		n += w
	return n


## Row index (0-based) of a numbered square, -1 for the start strip.
static func row_of(square: int) -> int:
	var n := 0
	for r in ROWS.size():
		n += int(ROWS[r])
		if square <= n:
			return r if square > 0 else -1
	return ROWS.size() - 1


## Grid-local centre of a numbered square.
static func square_centre(square: int) -> Vector2:
	var r := row_of(square)
	if r < 0:
		return Vector2(0.0, -START_DEPTH / 2.0)
	var first := 1
	for k in r:
		first += int(ROWS[k])
	var u := 0.0
	if int(ROWS[r]) == 2:
		u = -SQ / 2.0 if square == first else SQ / 2.0
	return Vector2(u, (r + 0.5) * SQ)


## What a grid-local point is: a square number (> 0), START, LINE or OUTSIDE.
static func locate(local: Vector2) -> int:
	var u := local.x
	var v := local.y
	var length := SQ * ROWS.size()
	if v < -START_DEPTH or v > length + LINE_MARGIN or absf(u) > SQ + LINE_MARGIN:
		return OUTSIDE
	# The start strip includes the first line, so toeing it is not a fault.
	if v < LINE_MARGIN:
		return START if absf(u) <= SQ else OUTSIDE
	if v > length - LINE_MARGIN:
		return LINE
	var r := clampi(floori(v / SQ), 0, ROWS.size() - 1)
	var v_in := v - r * SQ
	if v_in < LINE_MARGIN or v_in > SQ - LINE_MARGIN:
		return LINE
	var first := 1
	for k in r:
		first += int(ROWS[k])
	if int(ROWS[r]) == 1:
		var half := SQ / 2.0
		if absf(u) > half + LINE_MARGIN:
			return OUTSIDE
		return LINE if absf(u) > half - LINE_MARGIN else first
	if absf(u) < LINE_MARGIN or absf(u) > SQ - LINE_MARGIN:
		return LINE if absf(u) <= SQ + LINE_MARGIN else OUTSIDE
	return first if u < 0.0 else first + 1


## Index of the grid whose start strip or squares hold this XZ point, or -1.
func grid_at(xz: Vector2) -> int:
	for g: Dictionary in grids:
		var l := to_local(g, xz)
		if l.y > -START_DEPTH - 0.5 and l.y < SQ * ROWS.size() + 0.5 and absf(l.x) < SQ + 0.5:
			return int(g.id)
	return -1
