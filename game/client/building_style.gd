class_name BuildingStyle
extends RefCounted
## What a building looks like, decided once and the same on every client:
## facade material and colour, roof shape and colour, and the things on the
## roof. Pure functions of the zone entry (`id`, `kind`, `height`, footprint
## and the optional OSM appearance tags), so the rules are testable and the
## geometry (RoofBuilder) and shaders (CityMaterials) only follow them.
## Most OSM buildings carry no appearance tags, so the untagged case is
## derived from the height and a per-building hash, the way Kadikoy looks:
## low houses under red-tile hipped roofs, apartment blocks with flat roofs.

## Facade material codes; they travel in the wall vertex alpha (see wall_alpha).
const MAT_PLASTER := 0
const MAT_BRICK := 1
const MAT_STONE := 2
const MAT_CONCRETE := 3
## Roof surface codes, in the roof vertex alpha (see roof_alpha).
const SURF_FLAT := 0
const SURF_TILES := 1
const SURF_METAL := 2
const SURF_PLASTER := 3
const SURF_BRICK := 4

const FLAT := "flat"
const GABLED := "gabled"
const HIPPED := "hipped"
const DOME := "dome"

const FLOOR_HEIGHT := 3.1
## Roofs need a footprint this close to a rectangle and this wide.
const MIN_FILL := 0.8
const MIN_HALF_WIDTH := 2.2
const MAX_PITCHED_AREA := 700.0

const FACADES := ["ecdcc0", "e4c9a0", "d9b48a", "e8c7a6", "d99a78", "e6d4a8", "d5c3ab", "c9b7a0",
	"e9e1d2", "cf8f70", "b9a48c", "dcd2c2", "c7cdc6", "e3cdb2", "e2b98a", "d6a06f"]
const FACADES_COMMERCIAL := ["c8ccd0", "b8c0c8", "d8d4cc", "bcc4c4", "d2cbc0"]
const CONCRETES := ["a9a8a3", "b5b3ac", "9d9c98", "bcb8ae"]
const BRICKS := ["b4694f", "a55c45", "c07a58", "9a5643", "b98763", "8f5a4a"]
const STONES := ["dcc39f", "e0cba8", "d2b78f", "e6d8bc", "c9b393"]
const TILES := ["b9593b", "a94f37", "c4653f", "9d4a34", "b46a4a", "a35a3c", "c07048"]
const FLAT_ROOFS := ["7b7973", "6d6b67", "8a8782", "5f5e5b", "9a958c", "74706a"]
const METAL_ROOFS := ["8d979d", "7f8a90", "9aa3a6"]
const SLATE := "5a5d60"


# --- footprint --------------------------------------------------------------

## Smallest rectangle around a footprint, tried over the footprint's own edge
## directions. `u` runs along the long side, `v` is its left perpendicular;
## `hl` >= `hw` are the half sizes and `c` the centre (all in footprint units).
static func obb(poly: PackedVector2Array) -> Dictionary:
	var best_area := INF
	var best_u := Vector2.RIGHT
	var best_lo := Vector2.ZERO
	var best_hi := Vector2.ZERO
	for i in poly.size():
		var e := poly[(i + 1) % poly.size()] - poly[i]
		if e.length() < 0.2:
			continue
		var u := e.normalized()
		var v := Vector2(-u.y, u.x)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for p in poly:
			var q := Vector2(p.dot(u), p.dot(v))
			lo = Vector2(minf(lo.x, q.x), minf(lo.y, q.y))
			hi = Vector2(maxf(hi.x, q.x), maxf(hi.y, q.y))
		var a := (hi.x - lo.x) * (hi.y - lo.y)
		if a < best_area:
			best_area = a
			best_u = u
			best_lo = lo
			best_hi = hi
	if best_area == INF:
		return {}
	var v := Vector2(-best_u.y, best_u.x)
	var half := (best_hi - best_lo) / 2.0
	var mid := (best_hi + best_lo) / 2.0
	var centre := best_u * mid.x + v * mid.y
	if half.x < half.y:
		# The long side must be `u`; turning the frame a quarter keeps it right-handed.
		return {"c": centre, "u": v, "v": -best_u, "hl": half.y, "hw": half.x, "area": best_area}
	return {"c": centre, "u": best_u, "v": v, "hl": half.x, "hw": half.y, "area": best_area}


static func polygon_area(poly: PackedVector2Array) -> float:
	var a := 0.0
	for i in poly.size():
		var p := poly[i]
		var q := poly[(i + 1) % poly.size()]
		a += p.x * q.y - q.x * p.y
	return absf(a) / 2.0


## A point of the footprint's rectangle frame in footprint units.
static func to_world(box: Dictionary, local: Vector2) -> Vector2:
	return (box.c as Vector2) + (box.u as Vector2) * local.x + (box.v as Vector2) * local.y


# --- facade -----------------------------------------------------------------

static func floors_of(top: float) -> int:
	return maxi(1, roundi(top / FLOOR_HEIGHT))


## Facade material: what OSM says, else mostly plaster with some brick and
## stone houses, stone for places of worship.
static func facade_material(b: Dictionary, key: String, kind: String, top: float) -> int:
	match str(b.get("material", "")):
		"brick": return MAT_BRICK
		"stone": return MAT_STONE
		"concrete", "glass", "metal": return MAT_CONCRETE
		"plaster": return MAT_PLASTER
	if kind == "religious":
		return MAT_STONE
	var h := WorldBuilder._hash01(key + "mat")
	var low := floors_of(top) <= 3
	if kind == "commercial" or kind == "civic":
		if h < 0.25:
			return MAT_STONE
		if h < 0.4:
			return MAT_BRICK
		return MAT_CONCRETE if h < 0.75 else MAT_PLASTER
	if h < (0.2 if low else 0.1):
		return MAT_BRICK
	if h < (0.3 if low else 0.2):
		return MAT_STONE
	return MAT_PLASTER


## The facade colour the shader multiplies the texture with (sRGB, alpha 1).
static func facade_colour(b: Dictionary, key: String, kind: String, material: int) -> Color:
	var col: Color
	if b.has("colour"):
		# What the mapper saw, softened: OSM colours are often pure primaries.
		col = Color(str(b.colour)).lerp(Color("d8cbb4"), 0.25)
		if material == MAT_BRICK:
			col = col.lerp(Color(str(BRICKS[0])), 0.3)
	else:
		var palette: Array = FACADES
		match material:
			MAT_BRICK: palette = BRICKS
			MAT_STONE: palette = STONES
			MAT_CONCRETE: palette = CONCRETES
			_:
				if kind == "commercial" or kind == "civic":
					palette = FACADES_COMMERCIAL
		if kind == "religious":
			palette = ["efe8dc", "e6dcc8"]
		col = Color(str(palette[int(WorldBuilder._hash01(key) * palette.size())]))
	col = col.darkened((WorldBuilder._hash01(key + "dark") - 0.5) * 0.14)
	col.a = 1.0
	return col


## Wall vertex alpha: material (bits 1-2), "shopfront on the ground floor"
## (bit 0) and "this wall faces a street" (bit 3, doors and railings).
static func wall_alpha(material: int, shop: bool, street := false) -> float:
	return float(material * 2 + (1 if shop else 0) + (8 if street else 0)) / 15.0


static func roof_alpha(surface: int) -> float:
	return float(surface) / 15.0


# --- roof -------------------------------------------------------------------

## The roof of a building: {shape, rise (m above the wall top), surface, colour}.
## `box` is obb(footprint), `area` the footprint area in m2.
static func roof(b: Dictionary, key: String, kind: String, top: float, bottom: float, box: Dictionary,
		area: float) -> Dictionary:
	var flat := {"shape": FLAT, "rise": 0.0, "surface": SURF_FLAT, "colour": flat_roof_colour(b, key)}
	if bottom > 0.1 or box.is_empty() or str(b.get("type", "")) == "roof":
		return flat
	var hl: float = box.hl
	var hw: float = box.hw
	var fill: float = area / maxf(float(box.area), 0.01)
	var floors := floors_of(top)
	var shape := FLAT
	var tagged := str(b.get("roof", ""))
	if tagged == "dome":
		shape = DOME if kind == "religious" else FLAT
	elif tagged in [GABLED, HIPPED, "pyramidal"]:
		shape = HIPPED if tagged == "pyramidal" else tagged
	elif tagged == "flat" or tagged == "skillion":
		shape = FLAT
	elif str(b.get("type", "")) == "mosque":
		shape = DOME
	elif str(b.get("type", "")) == "church":
		shape = GABLED
	else:
		var share := 0.06
		if floors <= 3:
			share = 0.9
		elif floors == 4:
			share = 0.7
		elif floors <= 6:
			share = 0.3
		if kind == "commercial" or kind == "civic" or kind == "religious":
			share *= 0.3
		if WorldBuilder._hash01(key + "pitch") < share:
			shape = HIPPED if hl / hw < 1.35 or WorldBuilder._hash01(key + "hip") < 0.6 else GABLED
	if shape == DOME:
		if fill < 0.6 or hw < 4.0:
			shape = HIPPED if str(b.get("type", "")) == "mosque" else FLAT
		else:
			return {"shape": DOME, "rise": minf(hw * 0.8, 9.0), "surface": SURF_METAL,
				"colour": Color(str(METAL_ROOFS[int(WorldBuilder._hash01(key + "metal") * METAL_ROOFS.size())]))}
	if shape != FLAT and (fill < MIN_FILL or hw < MIN_HALF_WIDTH or area > MAX_PITCHED_AREA):
		shape = FLAT
	if shape == FLAT:
		return flat
	var rise := 0.0
	if b.has("roof_height"):
		rise = clampf(float(b.roof_height), 0.6, 8.0)
	elif b.has("roof_levels"):
		rise = clampf(float(b.roof_levels) * 2.5, 1.0, 6.0)
	else:
		# Attic-style low slopes on the taller blocks, steeper on houses.
		var angle := lerpf(22.0, 34.0, WorldBuilder._hash01(key + "pitch2"))
		if floors >= 5:
			angle = lerpf(14.0, 22.0, WorldBuilder._hash01(key + "pitch2"))
		rise = clampf(hw * tan(deg_to_rad(angle)), 0.9, 3.6 if floors < 5 else 2.3)
	var surface := SURF_TILES
	var col := Color(str(TILES[int(WorldBuilder._hash01(key + "tile") * TILES.size())]))
	match str(b.get("roof_material", "")):
		"metal":
			surface = SURF_METAL
			col = Color(str(METAL_ROOFS[int(WorldBuilder._hash01(key + "metal") * METAL_ROOFS.size())]))
		"slate":
			col = Color(SLATE)
	if b.has("roof_colour"):
		col = Color(str(b.roof_colour))
	return {"shape": shape, "rise": rise, "surface": surface, "colour": col}


static func flat_roof_colour(b: Dictionary, key: String) -> Color:
	if b.has("roof_colour"):
		return Color(str(b.roof_colour))
	return Color(str(FLAT_ROOFS[int(WorldBuilder._hash01(key + "roof") * FLAT_ROOFS.size())]))


# --- roof props ---------------------------------------------------------------

## Things standing on a roof, as [{kind, at: Vector2 (footprint units), yaw,
## size: Vector2 (footprint of the thing)}]. All of them lie inside the
## footprint. Flat roofs get a stair house, water tank, air conditioners and
## aerials; pitched roofs get a chimney (`at` is then in the roof's local
## u,v frame, see RoofBuilder.chimney).
static func roof_props(key: String, poly: PackedVector2Array, box: Dictionary, roof_shape: String, top: float,
		area: float) -> Array:
	var out := []
	if box.is_empty():
		return out
	var floors := floors_of(top)
	var hl: float = box.hl
	var hw: float = box.hw
	if roof_shape == HIPPED or roof_shape == GABLED:
		if WorldBuilder._hash01(key + "chim") < 0.55:
			var slot := WorldBuilder._hash01(key + "chimat")
			var along := (slot - 0.5) * 2.0 * maxf(hl - hw, 0.0) * 0.8 + (slot - 0.5) * hw * 0.5
			var v := WorldBuilder._hash01(key + "chimv") - 0.5
			out.append({"kind": "chimney", "at": Vector2(along, v * hw * 0.5), "yaw": 0.0, "size": Vector2(0.55, 0.55)})
		return out
	if roof_shape != FLAT or area < 60.0 or floors < 3:
		return out
	var u: Vector2 = box.u
	var v: Vector2 = box.v
	var yaw := atan2(-u.y, u.x)  # Basis(UP, yaw) turns local +X onto `u` in the XZ plane
	var slots := [Vector2(0.55, 0.0), Vector2(-0.55, 0.0), Vector2(0.0, 0.5), Vector2(0.0, -0.5), Vector2(0.7, 0.45), Vector2(-0.7, -0.45)]
	# A deterministic shuffle: the hash picks where each thing goes.
	var order := range(slots.size())
	order.sort_custom(func(a: int, b: int) -> bool:
		return WorldBuilder._hash01("%s:slot%d" % [key, a]) < WorldBuilder._hash01("%s:slot%d" % [key, b]))
	var wanted := []
	if floors >= 4 and area > 80.0 and WorldBuilder._hash01(key + "stairs") < 0.65:
		wanted.append({"kind": "stairs", "size": Vector2(3.2, 2.6)})
	if WorldBuilder._hash01(key + "tank") < 0.6:
		wanted.append({"kind": "tank", "size": Vector2(1.3, 1.3)})
	if WorldBuilder._hash01(key + "ac") < 0.5:
		wanted.append({"kind": "ac", "size": Vector2(1.0, 0.7)})
	if WorldBuilder._hash01(key + "aerial") < 0.7:
		wanted.append({"kind": "aerial", "size": Vector2(0.6, 0.6)})
	if WorldBuilder._hash01(key + "dish") < 0.55:
		wanted.append({"kind": "dish", "size": Vector2(0.8, 0.8)})
	var k := 0
	for w in wanted:
		var size: Vector2 = w.size
		for _try in slots.size():
			var s: Vector2 = slots[order[k % slots.size()]]
			k += 1
			var local := Vector2(s.x * hl, s.y * hw)
			var at: Vector2 = (box.c as Vector2) + u * local.x + v * local.y
			if _fits(poly, at, u, v, size):
				out.append({"kind": w.kind, "at": at, "yaw": yaw, "size": size})
				break
	return out


## True if a rectangle `size` (along u, v), centred at `at`, sits inside the
## polygon with a little air to the parapet.
static func _fits(poly: PackedVector2Array, at: Vector2, u: Vector2, v: Vector2, size: Vector2) -> bool:
	var hx := size.x / 2.0 + 0.5
	var hz := size.y / 2.0 + 0.5
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			if not Geometry2D.is_point_in_polygon(at + u * (sx * hx) + v * (sz * hz), poly):
				return false
	return true
