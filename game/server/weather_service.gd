class_name WeatherService
extends Node
## The zone's real weather, fetched by the server from Open-Meteo (free, no
## key) every 15 minutes and shared with every client, so everyone in the
## zone stands in the same rain. Only the zone's public coordinates are sent.
##
## mode: "live" (default), "off" (always clear) or a preset for tests and
## screenshots: "clear", "cloudy", "rain", "storm", "fog", "snow".

signal changed(info: Dictionary)

const REFRESH := 900.0
const RETRY := 120.0
const URL := "https://api.open-meteo.com/v1/forecast?latitude=%.5f&longitude=%.5f&current=temperature_2m,precipitation,cloud_cover,wind_speed_10m,wind_direction_10m,weather_code&timezone=auto"
const PRESETS := {
	"clear": {"code": 0, "cloud": 0.05, "rain_mm": 0.0, "wind_kmh": 8.0, "wind_dir": 40.0, "temp_c": 22.0},
	"cloudy": {"code": 3, "cloud": 0.95, "rain_mm": 0.0, "wind_kmh": 14.0, "wind_dir": 40.0, "temp_c": 16.0},
	"rain": {"code": 63, "cloud": 1.0, "rain_mm": 3.0, "wind_kmh": 18.0, "wind_dir": 200.0, "temp_c": 13.0},
	"storm": {"code": 95, "cloud": 1.0, "rain_mm": 8.0, "wind_kmh": 40.0, "wind_dir": 210.0, "temp_c": 14.0},
	"fog": {"code": 45, "cloud": 0.9, "rain_mm": 0.0, "wind_kmh": 3.0, "wind_dir": 0.0, "temp_c": 9.0},
	"snow": {"code": 73, "cloud": 1.0, "rain_mm": 1.5, "wind_kmh": 12.0, "wind_dir": 20.0, "temp_c": -1.0},
}

var current := {}
var _mode := "live"
var _lat := 41.0
var _lon := 29.0
var _http: HTTPRequest
var _next_fetch := 0.0


func setup(zone: ZoneData, mode: String) -> void:
	_lat = zone.origin_lat
	_lon = zone.origin_lon
	_mode = mode
	current = (PRESETS.get(mode, PRESETS.clear) as Dictionary).duplicate()
	current.source = "preset" if PRESETS.has(mode) else "default"
	if mode != "live":
		set_process(false)
		return
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	add_child(_http)
	_http.request_completed.connect(_on_response)


func _process(_delta: float) -> void:
	var t := Time.get_ticks_msec() / 1000.0
	if t < _next_fetch or _http.get_http_client_status() != HTTPClient.STATUS_DISCONNECTED:
		return
	_next_fetch = t + RETRY
	var err := _http.request(URL % [_lat, _lon])
	if err != OK:
		ZoneServer.log_line("weather: request failed to start (%s)" % error_string(err))


func _on_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		ZoneServer.log_line("weather: fetch failed (result %d, http %d), keeping %s" % [result, code, describe(current)])
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	var parsed := parse_open_meteo(data)
	if parsed.is_empty():
		ZoneServer.log_line("weather: unexpected response")
		return
	_next_fetch = Time.get_ticks_msec() / 1000.0 + REFRESH
	parsed.source = "open-meteo"
	current = parsed
	ZoneServer.log_line("weather: %s" % describe(current))
	changed.emit(current)


## Open-Meteo "current" block -> our weather dictionary, {} if malformed.
static func parse_open_meteo(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("current")) != TYPE_DICTIONARY:
		return {}
	var c: Dictionary = data.current
	if not c.has("weather_code"):
		return {}
	return {
		"code": int(c.get("weather_code", 0)),
		"cloud": clampf(float(c.get("cloud_cover", 0.0)) / 100.0, 0.0, 1.0),
		"rain_mm": maxf(0.0, float(c.get("precipitation", 0.0))),
		"wind_kmh": maxf(0.0, float(c.get("wind_speed_10m", 0.0))),
		"wind_dir": float(c.get("wind_direction_10m", 0.0)),
		"temp_c": float(c.get("temperature_2m", 15.0)),
	}


## Turkish words for a WMO weather code.
static func describe_code(code: int) -> String:
	if code == 0:
		return "Açık"
	if code == 1:
		return "Az bulutlu"
	if code == 2:
		return "Parçalı bulutlu"
	if code == 3:
		return "Kapalı"
	if code in [45, 48]:
		return "Sisli"
	if code in [51, 53, 55, 56, 57]:
		return "Çiseliyor"
	if code in [61, 66, 80]:
		return "Hafif yağmur"
	if code in [63, 81]:
		return "Yağmurlu"
	if code in [65, 67, 82]:
		return "Sağanak"
	if code in [71, 73, 75, 77, 85, 86]:
		return "Karlı"
	if code >= 95:
		return "Gök gürültülü fırtına"
	return "Değişken"


static func describe(w: Dictionary) -> String:
	return "%s, %d°C, bulut %%%d, yağış %.1f mm/sa, rüzgâr %d km/sa" % [describe_code(int(w.get("code", 0))),
		roundi(float(w.get("temp_c", 0.0))), roundi(float(w.get("cloud", 0.0)) * 100.0), float(w.get("rain_mm", 0.0)),
		roundi(float(w.get("wind_kmh", 0.0)))]
