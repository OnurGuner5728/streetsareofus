class_name PropLayout
extends RefCounted
## Loose objects the server simulates as rigid bodies: footballs in parks,
## big street bin containers on corners, café tables and chairs in front of
## real cafés. Their starting places are a deterministic function of the
## zone, so a client knows every prop's id and home without being told;
## only props that moved are sent over the network.

const KINDS := {
	"ball": {"mass": 0.43, "size": Vector3(0.22, 0.22, 0.22), "bounce": 0.62, "friction": 0.6, "push": 1.7},
	"bin": {"mass": 32.0, "size": Vector3(1.25, 1.2, 1.0), "bounce": 0.05, "friction": 0.7, "push": 0.85},
	"chair": {"mass": 3.0, "size": Vector3(0.44, 0.86, 0.44), "bounce": 0.15, "friction": 0.6, "push": 1.15},
	"table": {"mass": 8.0, "size": Vector3(0.7, 0.74, 0.7), "bounce": 0.1, "friction": 0.6, "push": 0.95},
}
const CAFE_KINDS := ["cafe", "restaurant", "bar", "pub", "fast_food", "confectionery", "bakery", "ice_cream"]
const MAX_CAFES := 34
const MAX_BINS := 36

## [{id, kind, pos: Vector3 (bottom centre), yaw, tint: Color}]
var props: Array = []
var _terrain: Terrain


static func for_zone(z: ZoneData) -> PropLayout:
	if z.has_meta("prop_layout"):
		return z.get_meta("prop_layout")
	var layout := PropLayout.new(z)
	z.set_meta("prop_layout", layout)
	return layout


func _init(zone: ZoneData) -> void:
	_terrain = zone.terrain
	var streets := StreetLayout.for_zone(zone)
	_balls(zone, streets)
	_bins(zone, streets)
	_cafes(zone, streets)


## `pos` is only used for x and z: props rest on the ground there.
func _add(kind: String, pos: Vector3, yaw: float, tint := Color.WHITE) -> void:
	var at := _terrain.on_ground(Vector2(pos.x, pos.z), 0.01)
	props.append({"id": props.size(), "kind": kind, "pos": at, "yaw": yaw, "tint": tint})


func _clear(streets: StreetLayout, p: Vector2, radius: float) -> bool:
	if not streets.inside_zone(p, 4.0) or streets.building_clearance(p) < radius + 0.2 \
			or streets.near_track(p, 2.2) or streets._occupied(p, radius):
		return false
	for other in props:
		var q: Vector3 = other.pos
		if p.distance_to(Vector2(q.x, q.z)) < radius + 0.6:
			return false
	return true


## A football in every park, pitch and playground (and the square).
func _balls(zone: ZoneData, streets: StreetLayout) -> void:
	for area in zone.areas:
		if not str(area.kind) in ["park", "pitch", "playground", "plaza", "grass"]:
			continue
		var poly := WorldBuilder.footprint_xz(area.polygon)
		if poly.size() < 3:
			continue
		var c := Vector2.ZERO
		for p in poly:
			c += p
		c /= poly.size()
		for k in 6:
			var p := c + Vector2(k * 1.7, -k * 1.1)
			if Geometry2D.is_point_in_polygon(p, poly) and _clear(streets, p, 0.3):
				_add("ball", Vector3(p.x, 0.0, p.y), 0.0)
				break


## A bin container on one corner of most road junctions.
func _bins(zone: ZoneData, streets: StreetLayout) -> void:
	var keys := streets.junctions.keys()
	keys.sort()
	for k in keys:
		if props.filter(func(x): return x.kind == "bin").size() >= MAX_BINS:
			return
		var j := Vector2(k.x / 10.0, k.y / 10.0)
		var reach: float = streets.junctions[k] + 1.6
		var h := WorldBuilder._hash01("bin%d:%d" % [k.x, k.y])
		if h < 0.35:
			continue
		for turn in 4:
			var a := h * TAU + turn * PI / 2.0 + PI / 4.0
			var p := j + Vector2(cos(a), sin(a)) * reach
			if _clear(streets, p, 0.9) and not _on_road(streets, p, 0.9):
				_add("bin", Vector3(p.x, 0.0, p.y), a)
				break


## One table with two chairs outside each (named) café, on the pavement
## between its door and the street.
func _cafes(zone: ZoneData, streets: StreetLayout) -> void:
	var placed := 0
	for poi in zone.pois:
		if placed >= MAX_CAFES:
			return
		if not str(poi.get("kind", "")) in CAFE_KINDS or str(poi.get("name", "")) == "":
			continue
		var p := Vector2(float(poi.e), -float(poi.n))
		var best: Array = []
		var best_d := 30.0
		for seg in streets.roads_near(p):
			var q := Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1])
			if p.distance_to(q) < best_d:
				best_d = p.distance_to(q)
				best = [q, float(seg[2])]
		if best.is_empty():
			continue
		var to_road: Vector2 = ((best[0] as Vector2) - p).normalized()
		if to_road == Vector2.ZERO:
			continue
		# Step from the door towards the street until clear of the building.
		var spot := Vector2.INF
		var probe := p
		for step in 30:
			probe += to_road * 0.3
			if (best[0] as Vector2).distance_to(probe) < float(best[1]) / 2.0 + 0.9:
				break
			if streets.building_clearance(probe) > 1.1:
				spot = probe
				break
		if spot == Vector2.INF or not _clear(streets, spot, 1.0) or _on_road(streets, spot, 0.8):
			continue
		var along := Vector2(-to_road.y, to_road.x)
		var wooden := WorldBuilder._hash01(str(poi.id)) < 0.5
		var tint := Color("7a5334") if wooden else Color("f1f1ee")
		_add("table", Vector3(spot.x, 0.0, spot.y), 0.0, tint)
		for side: float in [-1.0, 1.0]:
			var c := spot + along * side * 0.75
			# Chairs face the table.
			_add("chair", Vector3(c.x, 0.0, c.y), atan2(along.x * side, along.y * side), tint)
		placed += 1


static func _on_road(streets: StreetLayout, p: Vector2, margin: float) -> bool:
	for seg in streets.roads_near(p):
		if str(seg[3]) in ["footway", "steps", "pedestrian"]:
			continue
		if p.distance_to(Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1])) < float(seg[2]) / 2.0 + margin:
			return true
	return false
