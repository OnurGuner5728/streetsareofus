class_name GraphicsQuality
extends RefCounted
## One knob for everything that costs frames. Phones and browsers start on
## LOW; the client steps down by itself if the frame rate stays poor.
##
## LOW    no shadows, no glow, no night lamp lights, cheap one-octave
##        surface shaders, short prop and label ranges, fog hides the far city.
## MEDIUM short sun shadows, a few lamp lights, full shaders.
## HIGH   everything, as on a desktop GPU.

const LOW := 0
const MEDIUM := 1
const HIGH := 2
const AUTO := -1
const NAMES := {AUTO: "Otomatik", LOW: "Düşük", MEDIUM: "Orta", HIGH: "Yüksek"}
const KEYS := {"auto": AUTO, "low": LOW, "medium": MEDIUM, "high": HIGH}

static var level := MEDIUM


static func from_key(key: String) -> int:
	return int(KEYS.get(key, AUTO))


static func key_of(value: int) -> String:
	for k in KEYS:
		if KEYS[k] == value:
			return k
	return "auto"


## Where "auto" starts: phones and browsers low, desktops high.
static func initial_level(setting: int) -> int:
	if setting != AUTO:
		return setting
	if OS.has_feature("web") or OS.has_feature("mobile") or DisplayServer.is_touchscreen_available():
		return LOW
	return HIGH if RenderingServer.get_current_rendering_method() != "gl_compatibility" else MEDIUM


static func shadows() -> bool:
	return level >= MEDIUM


static func shadow_distance() -> float:
	return [0.0, 55.0, 150.0][level]


static func night_lights() -> int:
	return [0, 4, 10][level]


static func glow() -> bool:
	return level >= HIGH


static func lite_shaders() -> bool:
	return level == LOW


## Multiplier for every prop's visibility range.
static func range_scale() -> float:
	return [0.5, 0.8, 1.0][level]


static func camera_far() -> float:
	return [380.0, 700.0, 1500.0][level]


static func fog_density() -> float:
	return [0.0065, 0.0035, 0.0028][level]


## Street furniture that is pure decoration (awnings, AC units...) is only
## built from MEDIUM up; see CityVisuals.
static func detail_props() -> bool:
	return level >= MEDIUM
