class_name ZoneData
extends RefCounted
## A zone package produced by world-pipeline/build_zone.py.
## Stored coordinates are local east/north metres around the zone origin;
## Godot space is Vector3(east, height, -north).

const ZONES_DIR := "res://zones"
const SUPPORTED_FORMAT := 2

var zone_id := ""
var display_name := ""
var version := 0
var origin_lat := 0.0
var origin_lon := 0.0
var size_m := 512.0
var buildings: Array = []
var roads: Array = []
var areas: Array = []
var pois: Array = []
var spawn_points: Array = []
var attribution: Array = []
var trees: Array = []  # [e, n, height]
var crossings: Array = []  # [e, n]
var lamps: Array = []  # [e, n]
var transit: TransitNetwork
var terrain: Terrain
var _graph: RoadGraph = null

var _m_lat := 111000.0
var _m_lon := 111000.0


static func available_zones() -> PackedStringArray:
	var out := PackedStringArray()
	for dir in DirAccess.get_directories_at(ZONES_DIR):
		if FileAccess.file_exists("%s/%s/zone.json" % [ZONES_DIR, dir]):
			out.append(dir)
	return out


static func load_zone(id: String) -> ZoneData:
	var base := "%s/%s" % [ZONES_DIR, id]
	var zone_json: Variant = _read_json(base + "/zone.json")
	if typeof(zone_json) != TYPE_DICTIONARY:
		push_error("zone %s: zone.json missing or invalid" % id)
		return null
	var z: Dictionary = zone_json
	if int(z.get("format", 0)) != SUPPORTED_FORMAT:
		push_error("zone %s: unsupported format %s" % [id, z.get("format")])
		return null
	var zone := ZoneData.new()
	zone.zone_id = str(z.zone_id)
	zone.version = int(z.version)
	zone.display_name = str(z.get("name", zone.zone_id))
	zone.origin_lat = float(z.origin.lat)
	zone.origin_lon = float(z.origin.lon)
	zone.size_m = float(z.size_m)
	zone.buildings = z.get("buildings", [])
	zone.roads = z.get("roads", [])
	zone.areas = z.get("areas", [])
	zone.pois = z.get("pois", [])
	zone.trees = z.get("trees", [])
	zone.crossings = z.get("crossings", [])
	zone.lamps = z.get("lamps", [])
	zone.terrain = Terrain.from_zone(z.get("terrain"), zone.size_m / 2.0)
	zone.transit = TransitNetwork.from_zone(z.get("transit"), zone.size_m / 2.0)
	zone.transit.terrain = zone.terrain
	var spawn_json: Variant = _read_json(base + "/spawn_points.json")
	if typeof(spawn_json) == TYPE_DICTIONARY:
		zone.spawn_points = spawn_json.get("points", [])
	var attribution_json: Variant = _read_json(base + "/attribution.json")
	if typeof(attribution_json) == TYPE_DICTIONARY:
		zone.attribution = attribution_json.get("sources", [])
	zone._compute_scale()
	return zone


static func _read_json(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


func _compute_scale() -> void:
	# Same series as world-pipeline/zonegen/geo.py meters_per_degree().
	var phi := deg_to_rad(origin_lat)
	_m_lat = 111132.92 - 559.82 * cos(2 * phi) + 1.175 * cos(4 * phi) - 0.0023 * cos(6 * phi)
	_m_lon = 111412.84 * cos(phi) - 93.5 * cos(3 * phi) + 0.118 * cos(5 * phi)


static func to_godot(e: float, n: float, height := 0.0) -> Vector3:
	return Vector3(e, height, -n)


static func to_en(pos: Vector3) -> Vector2:
	return Vector2(pos.x, -pos.z)


## Ground-level point for east/north coordinates, lifted by `lift`.
func ground(e: float, n: float, lift := 0.0) -> Vector3:
	return Vector3(e, terrain.height(e, -n) + lift, -n)


## Returns [latitude, longitude] for a Godot-space position. 64-bit on
## purpose: a Vector2 would round coordinates to roughly half a metre.
func to_geo(pos: Vector3) -> PackedFloat64Array:
	var en := to_en(pos)
	return PackedFloat64Array([origin_lat + en.y / _m_lat, origin_lon + en.x / _m_lon])


func half_size() -> float:
	return size_m / 2.0


## Walking network, built on first use (only clients plan routes).
func road_graph() -> RoadGraph:
	if _graph == null:
		_graph = RoadGraph.from_zone(self)
	return _graph


func attribution_text() -> String:
	var parts := PackedStringArray()
	for src in attribution:
		if typeof(src) == TYPE_DICTIONARY and src.has("attribution"):
			parts.append(str(src.attribution))
	return " · ".join(parts)


## Name of the nearest named street within `max_distance` metres (at most
## STREET_CELL), or "". Uses a grid of named road segments built on first use.
func nearest_street(pos: Vector3, max_distance := 25.0) -> String:
	if _street_cells.is_empty():
		_index_streets()
	var p := to_en(pos)
	var best := minf(max_distance, STREET_CELL)
	var best_name := ""
	var c := Vector2i(floori(p.x / STREET_CELL), floori(p.y / STREET_CELL))
	for dx in range(-1, 2):
		for dy in range(-1, 2):
			for seg in _street_cells.get(c + Vector2i(dx, dy), []):
				var d := p.distance_to(Geometry2D.get_closest_point_to_segment(p, seg[0], seg[1]))
				if d < best:
					best = d
					best_name = seg[2]
	return best_name


const STREET_CELL := 32.0
var _street_cells := {}  # Vector2i -> [[a: Vector2, b: Vector2, name], ...]


func _index_streets() -> void:
	_street_cells[Vector2i(1 << 20, 0)] = []  # marks the index as built even for empty zones
	for road in roads:
		var road_name: String = road.get("name", "")
		if road_name.is_empty():
			continue
		var pts: Array = road.points
		for i in pts.size() - 1:
			var a := Vector2(pts[i][0], pts[i][1])
			var b := Vector2(pts[i + 1][0], pts[i + 1][1])
			var box := Rect2(a, Vector2.ZERO).expand(b)
			for x in range(floori(box.position.x / STREET_CELL), floori(box.end.x / STREET_CELL) + 1):
				for y in range(floori(box.position.y / STREET_CELL), floori(box.end.y / STREET_CELL) + 1):
					var key := Vector2i(x, y)
					if not _street_cells.has(key):
						_street_cells[key] = []
					_street_cells[key].append([a, b, road_name])
