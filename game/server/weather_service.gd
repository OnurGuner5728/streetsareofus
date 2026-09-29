class_name WeatherService
extends Node
## The zone's real weather, fetched by the server from Open-Meteo (free, no
## key) every 15 minutes and shared with every client, so everyone in the
## zone stands in the same rain. Only the zone's public coordinates are sent.
##
## Zones with a real coastline (ZoneData.coast) also get sea state from the
## Open-Meteo Marine API (wave height, direction, period), which drives the
## water shader and shore sound on clients. Where marine data is unavailable
## (offline, or the API has no coverage there), wave height falls back to a
## rough wind-chop estimate for the Sea of Marmara's short fetch.
##
## mode: "live" (default), "off" (always clear) or a preset for tests and
## screenshots: "clear", "cloudy", "rain", "storm", "fog", "snow".

signal changed(info: Dictionary)

const REFRESH := 900.0
const RETRY := 120.0
const URL := "https://api.open-meteo.com/v1/forecast?latitude=%.5f&longitude=%.5f&current=temperature_2m,precipitation,cloud_cover,wind_speed_10m,wind_direction_10m,weather_code&timezone=auto"
const MARINE_URL := "https://marine-api.open-meteo.com/v1/marine?latitude=%.5f&longitude=%.5f&current=wave_height,wave_direction,wave_period&timezone=auto"
const PRESETS := {
	"clear": {"code": 0, "cloud": 0.05, "rain_mm": 0.0, "wind_kmh": 8.0, "wind_dir": 40.0, "temp_c": 22.0, "wave_m": 0.1, "wave_dir": 40.0, "wave_period": 3.0},
	"cloudy": {"code": 3, "cloud": 0.95, "rain_mm": 0.0, "wind_kmh": 14.0, "wind_dir": 40.0, "temp_c": 16.0, "wave_m": 0.25, "wave_dir": 40.0, "wave_period": 3.5},
	"rain": {"code": 63, "cloud": 1.0, "rain_mm": 3.0, "wind_kmh": 18.0, "wind_dir": 200.0, "temp_c": 13.0, "wave_m": 0.4, "wave_dir": 200.0, "wave_period": 4.0},
	"storm": {"code": 95, "cloud": 1.0, "rain_mm": 8.0, "wind_kmh": 40.0, "wind_dir": 210.0, "temp_c": 14.0, "wave_m": 1.3, "wave_dir": 210.0, "wave_period": 5.5},
	"fog": {"code": 45, "cloud": 0.9, "rain_mm": 0.0, "wind_kmh": 3.0, "wind_dir": 0.0, "temp_c": 9.0, "wave_m": 0.08, "wave_dir": 0.0, "wave_period": 2.5},
	"snow": {"code": 73, "cloud": 1.0, "rain_mm": 1.5, "wind_kmh": 12.0, "wind_dir": 20.0, "temp_c": -1.0, "wave_m": 0.2, "wave_dir": 20.0, "wave_period": 3.2},
}

var current := {}
var _mode := "live"
var _lat := 41.0
var _lon := 29.0
var _has_coast := false
var _http: HTTPRequest
var _marine_http: HTTPRequest
var _next_fetch := 0.0


func setup(zone: ZoneData, mode: String) -> void:
	_lat = zone.origin_lat
	_lon = zone.origin_lon
	_mode = mode
	_has_coast = zone.coast != null
	current = (PRESETS.get(mode, PRESETS.clear) as Dictionary).duplicate()
	current.source = "preset" if PRESETS.has(mode) else "default"
	if not current.has("wave_m"):
		current.merge(estimate_wave(float(current.get("wind_kmh", 10.0))))
	if mode != "live":
		set_process(false)
		return
	_http = HTTPRequest.new()
	_http.timeout = 15.0
	add_child(_http)
	_http.request_completed.connect(_on_response)
	if _has_coast:
		_marine_http = HTTPRequest.new()
		_marine_http.timeout = 15.0
		add_child(_marine_http)
		_marine_http.request_completed.connect(_on_marine_response)


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
	if current.has("wave_m"):
		parsed.wave_m = current.wave_m
		parsed.wave_dir = current.wave_dir
		parsed.wave_period = current.wave_period
	else:
		parsed.merge(estimate_wave(parsed.wind_kmh))
	current = parsed
	ZoneServer.log_line("weather: %s" % describe(current))
	changed.emit(current)
	if _has_coast and _marine_http:
		var err := _marine_http.request(MARINE_URL % [_lat, _lon])
		if err != OK:
			ZoneServer.log_line("weather: marine request failed to start (%s)" % error_string(err))


func _on_marine_response(result: int, code: int, _headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS or code != 200:
		ZoneServer.log_line("weather: marine fetch failed (result %d, http %d), keeping estimated waves" % [result, code])
		return
	var data: Variant = JSON.parse_string(body.get_string_from_utf8())
	var waves := parse_marine(data)
	if waves.is_empty():
		ZoneServer.log_line("weather: unexpected marine response")
		return
	current.merge(waves, true)
	ZoneServer.log_line("weather: waves %.2f m from %d°, period %.1f s" % [waves.wave_m, int(waves.wave_dir), waves.wave_period])
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


## Open-Meteo Marine "current" block -> {wave_m, wave_dir, wave_period}, {} if malformed.
static func parse_marine(data: Variant) -> Dictionary:
	if typeof(data) != TYPE_DICTIONARY or typeof(data.get("current")) != TYPE_DICTIONARY:
		return {}
	var c: Dictionary = data.current
	if not c.has("wave_height"):
		return {}
	return {
		"wave_m": clampf(float(c.get("wave_height", 0.2)), 0.0, 6.0),
		"wave_dir": float(c.get("wave_direction", 0.0)),
		"wave_period": clampf(float(c.get("wave_period", 4.0)), 1.5, 16.0),
	}


## Offline/no-marine-coverage fallback: a rough wave height from wind speed,
## for the Sea of Marmara's short fetch (wind chop, not ocean swell).
static func estimate_wave(wind_kmh: float) -> Dictionary:
	return {"wave_m": clampf(0.05 + wind_kmh * 0.018, 0.05, 1.6), "wave_dir": 0.0, "wave_period": 3.5}


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
