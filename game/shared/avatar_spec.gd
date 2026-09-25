class_name AvatarSpec
extends RefCounted
## Avatar description sent over the network (IDs and parameters, never meshes)
## plus the rules that separate how an avatar looks from how it plays.
## A 150 cm or 205 cm avatar is fine to look at, but the server clamps the
## physics capsule and eye height so body shape never becomes an advantage.
##
## Every field is validated by sanitize(): unknown styles fall back to the
## default, colours must be valid, sliders are clamped to 0..1. Older
## clients' avatars (without the newer fields) simply get the defaults.

const VISUAL_HEIGHT_MIN := 1.50
const VISUAL_HEIGHT_MAX := 2.05
const GAMEPLAY_HEIGHT_MIN := 1.55
const GAMEPLAY_HEIGHT_MAX := 1.95
const RADIUS_MIN := 0.28
const RADIUS_MAX := 0.33
const EYE_BELOW_TOP := 0.11

const SKINS := {
	"skin_01": "f6dcc6", "skin_02": "eac2a0", "skin_03": "d6a27a", "skin_04": "c68e63",
	"skin_05": "b57a52", "skin_06": "8d5a3b", "skin_07": "6e4430", "skin_08": "4e2f20",
}
const BODY_KEYS := ["height", "weight", "muscle", "shoulders", "chest", "hips", "legs", "head"]
const FACES := ["oval", "round", "square", "long"]
const EYE_COLORS := {"brown": "5a3a22", "dark": "2a1d15", "hazel": "8a6a3a", "green": "4f7a4a", "blue": "4a74a8", "grey": "7c8790"}
const BROWS := ["normal", "thin", "thick"]
const BEARDS := ["none", "stubble", "mustache", "goatee", "short", "full"]
const BODY_TYPES := ["male", "female"]
const HAIR_STYLES := ["none", "buzz", "short", "long", "bun", "curly", "afro"]
## Older hairstyles -> the closest current one.
const LEGACY_HAIR := {"cap": "short", "side": "short", "bob": "long", "ponytail": "bun", "braid": "long"}
const TOPS := ["tshirt", "longsleeve", "shirt", "polo", "tank", "hoodie", "sweater", "jacket", "coat", "dress"]
const PATTERNS := ["plain", "stripes", "two_tone"]
const BOTTOMS := ["jeans", "trousers", "sweatpants", "shorts", "skirt", "long_skirt"]
const SHOES := ["sneakers", "boots", "formal", "sandals"]
const HEADWEAR := ["none", "cap", "beanie", "hat", "headscarf", "bandana"]
const GLASSES := ["none", "round", "square", "sun"]
const BAGS := ["none", "backpack", "shoulder", "tote"]
const SCARVES := ["none", "scarf"]

const NAME_MIN := 3
const NAME_MAX := 20


static func defaults() -> Dictionary:
	return {
		"body": {"height": 0.45, "weight": 0.4, "muscle": 0.3, "shoulders": 0.5,
			"chest": 0.4, "hips": 0.45, "legs": 0.5, "head": 0.5},
		"appearance": {"body_type": "male", "skin": "skin_03", "face": "oval", "eyes": "brown", "brows": "normal",
			"hair": "short", "hair_color": "#37251c", "beard": "none"},
		"clothing": {
			"top": "hoodie", "top_color": "#3a6ea5", "top_color2": "#e8e8e8", "pattern": "plain",
			"bottom": "jeans", "bottom_color": "#2d3a55",
			"shoes": "sneakers", "shoes_color": "#e8e8e8",
		},
		"accessories": {
			"headwear": "none", "headwear_color": "#2b2d30",
			"glasses": "none",
			"bag": "none", "bag_color": "#5b4636",
			"scarf": "none", "scarf_color": "#a8323a",
		},
	}


static func sanitize(raw: Variant) -> Dictionary:
	var out := defaults()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = raw
	var body := _section(src, "body")
	for key in BODY_KEYS:
		out.body[key] = _unit(body.get(key), out.body[key])
	var app := _section(src, "appearance")
	out.appearance.body_type = _choice(app.get("body_type"), BODY_TYPES, _guess_body(src))
	out.appearance.skin = _choice(app.get("skin"), SKINS.keys(), out.appearance.skin)
	out.appearance.face = _choice(app.get("face"), FACES, out.appearance.face)
	out.appearance.eyes = _choice(app.get("eyes"), EYE_COLORS.keys(), out.appearance.eyes)
	out.appearance.brows = _choice(app.get("brows"), BROWS, out.appearance.brows)
	out.appearance.hair = _choice(_legacy_hair(app.get("hair")), HAIR_STYLES, out.appearance.hair)
	out.appearance.hair_color = _color(app.get("hair_color"), out.appearance.hair_color)
	out.appearance.beard = _choice(app.get("beard"), BEARDS, out.appearance.beard)
	var cl := _section(src, "clothing")
	out.clothing.top = _choice(cl.get("top"), TOPS, out.clothing.top)
	out.clothing.pattern = _choice(cl.get("pattern"), PATTERNS, out.clothing.pattern)
	out.clothing.bottom = _choice(cl.get("bottom"), BOTTOMS, out.clothing.bottom)
	out.clothing.shoes = _choice(cl.get("shoes"), SHOES, out.clothing.shoes)
	for key in ["top_color", "top_color2", "bottom_color", "shoes_color"]:
		out.clothing[key] = _color(cl.get(key), out.clothing[key])
	var acc := _section(src, "accessories")
	# The old "cap" hairstyle became a separate cap.
	if str(app.get("hair", "")) == "cap" and not acc.has("headwear"):
		acc = acc.duplicate()
		acc.headwear = "cap"
	out.accessories.headwear = _choice(acc.get("headwear"), HEADWEAR, out.accessories.headwear)
	out.accessories.glasses = _choice(acc.get("glasses"), GLASSES, out.accessories.glasses)
	out.accessories.bag = _choice(acc.get("bag"), BAGS, out.accessories.bag)
	out.accessories.scarf = _choice(acc.get("scarf"), SCARVES, out.accessories.scarf)
	for key in ["headwear_color", "bag_color", "scarf_color"]:
		out.accessories[key] = _color(acc.get(key), out.accessories[key])
	return out


## A random but plausible look (bots, the "Rastgele" button).
static func random(rng: RandomNumberGenerator) -> Dictionary:
	var av := defaults()
	for key in BODY_KEYS:
		av.body[key] = rng.randf_range(0.1, 0.9)
	av.appearance.body_type = BODY_TYPES[rng.randi() % BODY_TYPES.size()]
	var fem: bool = av.appearance.body_type == "female"
	av.appearance.skin = SKINS.keys()[rng.randi() % SKINS.size()]
	av.appearance.face = FACES[rng.randi() % FACES.size()]
	av.appearance.eyes = EYE_COLORS.keys()[rng.randi() % EYE_COLORS.size()]
	av.appearance.brows = BROWS[rng.randi() % BROWS.size()]
	var hairs := ["long", "bun", "curly", "afro", "short", "long", "bun"] if fem else ["short", "buzz", "short", "curly", "afro", "none", "long"]
	av.appearance.hair = hairs[rng.randi() % hairs.size()]
	av.appearance.hair_color = "#" + Color.from_hsv(rng.randf_range(0.02, 0.1), rng.randf_range(0.3, 0.7), rng.randf_range(0.08, 0.7)).to_html(false)
	av.appearance.beard = BEARDS[rng.randi() % BEARDS.size()] if not fem and rng.randf() < 0.5 else "none"
	av.clothing.top = TOPS[rng.randi() % TOPS.size()]
	av.clothing.pattern = PATTERNS[rng.randi() % PATTERNS.size()] if rng.randf() < 0.4 else "plain"
	av.clothing.bottom = BOTTOMS[rng.randi() % BOTTOMS.size()] if fem else ["jeans", "trousers", "sweatpants", "shorts"][rng.randi() % 4]
	if not fem and av.clothing.top == "dress":
		av.clothing.top = "shirt"
	av.clothing.shoes = SHOES[rng.randi() % SHOES.size()]
	for key in ["top_color", "top_color2", "bottom_color", "shoes_color"]:
		av.clothing[key] = "#" + Color.from_hsv(rng.randf(), rng.randf_range(0.1, 0.75), rng.randf_range(0.2, 0.92)).to_html(false)
	av.accessories.headwear = HEADWEAR[rng.randi() % HEADWEAR.size()] if rng.randf() < 0.35 else "none"
	av.accessories.glasses = GLASSES[rng.randi() % GLASSES.size()] if rng.randf() < 0.35 else "none"
	av.accessories.bag = BAGS[rng.randi() % BAGS.size()] if rng.randf() < 0.4 else "none"
	av.accessories.scarf = "scarf" if rng.randf() < 0.2 else "none"
	for key in ["headwear_color", "bag_color", "scarf_color"]:
		av.accessories[key] = "#" + Color.from_hsv(rng.randf(), rng.randf_range(0.2, 0.7), rng.randf_range(0.2, 0.8)).to_html(false)
	return sanitize(av)


static func visual_height(avatar: Dictionary) -> float:
	return lerpf(VISUAL_HEIGHT_MIN, VISUAL_HEIGHT_MAX, float(avatar.body.height))


static func gameplay_height(avatar: Dictionary) -> float:
	return clampf(visual_height(avatar), GAMEPLAY_HEIGHT_MIN, GAMEPLAY_HEIGHT_MAX)


static func eye_height(avatar: Dictionary) -> float:
	return gameplay_height(avatar) - EYE_BELOW_TOP


static func capsule_radius(avatar: Dictionary) -> float:
	return lerpf(RADIUS_MIN, RADIUS_MAX, float(avatar.body.weight))


static func skin_color(avatar: Dictionary) -> Color:
	return Color("#" + str(SKINS.get(avatar.appearance.skin, SKINS.skin_03)))


static func eye_color(avatar: Dictionary) -> Color:
	return Color("#" + str(EYE_COLORS.get(avatar.appearance.get("eyes", "brown"), EYE_COLORS.brown)))


## Returns "" when the name is not acceptable.
static func sanitize_name(raw: Variant) -> String:
	if typeof(raw) != TYPE_STRING:
		return ""
	var text: String = raw
	var re := RegEx.create_from_string("\\s+")
	text = re.sub(text.strip_edges(), " ", true)
	var allowed := RegEx.create_from_string("^[\\p{L}\\p{N} _.\\-]+$")
	if text.length() < NAME_MIN or text.length() > NAME_MAX or allowed.search(text) == null:
		return ""
	return text


static func _section(src: Dictionary, key: String) -> Dictionary:
	return src.get(key, {}) if typeof(src.get(key)) == TYPE_DICTIONARY else {}


static func _legacy_hair(value: Variant) -> Variant:
	return LEGACY_HAIR.get(value, value) if typeof(value) == TYPE_STRING else value


## Avatars made before body types existed: a reasonable first guess.
static func _guess_body(src: Dictionary) -> String:
	var app := _section(src, "appearance")
	var cl := _section(src, "clothing")
	if str(app.get("hair", "")) in ["long", "bob", "ponytail", "bun", "braid"] 			or str(cl.get("bottom", "")) in ["skirt", "long_skirt"] or str(cl.get("top", "")) == "dress":
		return "female"
	return "male"


static func _unit(value: Variant, fallback: float) -> float:
	if typeof(value) == TYPE_FLOAT or typeof(value) == TYPE_INT:
		var v := float(value)
		if is_finite(v):
			return clampf(v, 0.0, 1.0)
	return fallback


static func _choice(value: Variant, options: Array, fallback: String) -> String:
	if typeof(value) == TYPE_STRING and options.has(value):
		return value
	return fallback


static func _color(value: Variant, fallback: String) -> String:
	if typeof(value) == TYPE_STRING and Color.html_is_valid(value):
		return "#" + Color.html(value).to_html(false)
	return fallback
