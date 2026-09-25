class_name AvatarSpec
extends RefCounted
## Avatar description sent over the network (IDs and parameters, never meshes)
## plus the rules that separate how an avatar looks from how it plays.
## A 150 cm or 205 cm avatar is fine to look at, but the server clamps the
## physics capsule and eye height so body shape never becomes an advantage.

const VISUAL_HEIGHT_MIN := 1.50
const VISUAL_HEIGHT_MAX := 2.05
const GAMEPLAY_HEIGHT_MIN := 1.55
const GAMEPLAY_HEIGHT_MAX := 1.95
const RADIUS_MIN := 0.28
const RADIUS_MAX := 0.33
const EYE_BELOW_TOP := 0.11

const SKINS := {
	"skin_01": "f6dcc6", "skin_02": "eac2a0", "skin_03": "d6a27a",
	"skin_04": "b57a52", "skin_05": "8d5a3b", "skin_06": "5e3a26",
}
const HAIR_STYLES := ["none", "short", "long", "bun", "cap"]
const TOPS := ["tshirt", "hoodie", "jacket"]
const BOTTOMS := ["jeans", "trousers", "shorts", "skirt"]

const NAME_MIN := 3
const NAME_MAX := 20


static func defaults() -> Dictionary:
	return {
		"body": {"height": 0.45, "weight": 0.4, "muscle": 0.3, "shoulders": 0.5},
		"appearance": {"skin": "skin_03", "hair": "short", "hair_color": "#37251c"},
		"clothing": {
			"top": "hoodie", "top_color": "#3a6ea5",
			"bottom": "jeans", "bottom_color": "#2d3a55",
			"shoes_color": "#e8e8e8",
		},
	}


static func sanitize(raw: Variant) -> Dictionary:
	var out := defaults()
	if typeof(raw) != TYPE_DICTIONARY:
		return out
	var src: Dictionary = raw
	var body: Dictionary = src.get("body", {}) if typeof(src.get("body")) == TYPE_DICTIONARY else {}
	for key in ["height", "weight", "muscle", "shoulders"]:
		out.body[key] = _unit(body.get(key), out.body[key])
	var app: Dictionary = src.get("appearance", {}) if typeof(src.get("appearance")) == TYPE_DICTIONARY else {}
	out.appearance.skin = _choice(app.get("skin"), SKINS.keys(), out.appearance.skin)
	out.appearance.hair = _choice(app.get("hair"), HAIR_STYLES, out.appearance.hair)
	out.appearance.hair_color = _color(app.get("hair_color"), out.appearance.hair_color)
	var cl: Dictionary = src.get("clothing", {}) if typeof(src.get("clothing")) == TYPE_DICTIONARY else {}
	out.clothing.top = _choice(cl.get("top"), TOPS, out.clothing.top)
	out.clothing.bottom = _choice(cl.get("bottom"), BOTTOMS, out.clothing.bottom)
	for key in ["top_color", "bottom_color", "shoes_color"]:
		out.clothing[key] = _color(cl.get(key), out.clothing[key])
	return out


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
