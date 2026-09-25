class_name LocalProfile
extends RefCounted
## Per-install identity and menu settings stored under user://.

const IDENTITY_PATH := "user://identity.json"
const SETTINGS_PATH := "user://settings.json"


static func new_identity() -> Dictionary:
	var crypto := Crypto.new()
	return {
		"account_id": crypto.generate_random_bytes(16).hex_encode(),
		"account_secret": crypto.generate_random_bytes(32).hex_encode(),
	}


static func load_identity() -> Dictionary:
	var data: Variant = _read(IDENTITY_PATH)
	if typeof(data) == TYPE_DICTIONARY and data.has("account_id") and data.has("account_secret"):
		return data
	var identity := new_identity()
	_write(IDENTITY_PATH, identity)
	return identity


static func load_settings() -> Dictionary:
	var defaults := {
		"name": "",
		"server": "127.0.0.1:%d" % Protocol.DEFAULT_PORT,
		"zone": Protocol.DEFAULT_ZONE,
		"spawn_mode": "social",
		"avatar": AvatarSpec.defaults(),
		"mouse_sensitivity": 0.0025,
		"quality": "auto",
		"show_fps": false,
	}
	var data: Variant = _read(SETTINGS_PATH)
	if typeof(data) == TYPE_DICTIONARY:
		defaults.merge(data, true)
	defaults.avatar = AvatarSpec.sanitize(defaults.avatar)
	if OS.has_feature("web"):
		defaults.server = page_server_url()
	return defaults


## In a browser the game server sits behind the same host that served the
## page (tools/web_host.py proxies /game to it), over wss:// on https pages.
static func page_server_url() -> String:
	var url: Variant = JavaScriptBridge.eval(
		"(location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/game'", true)
	return str(url) if url != null else "ws://127.0.0.1:8080/game"


static func save_settings(settings: Dictionary) -> void:
	_write(SETTINGS_PATH, settings)


static func _read(path: String) -> Variant:
	if not FileAccess.file_exists(path):
		return null
	return JSON.parse_string(FileAccess.get_file_as_string(path))


static func _write(path: String, data: Variant) -> void:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(data, "\t"))
