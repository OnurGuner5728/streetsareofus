class_name ServerStore
extends RefCounted
## File-backed persistence for the alpha: accounts, avatars, last location,
## blocks, reports and an audit log. Mirrors the plan's PostgreSQL tables
## (accounts, avatars, player_location, blocks, reports) so it can be
## swapped for a database without touching the zone server.
##
## Identity is trust-on-first-use: the client generates an account id and
## secret, and the server stores only a hash of the secret. This stands in
## for real authentication (Nakama) and is not meant to be more than that.

var dir := ""
var accounts := {}  # account_id -> {secret_hash, name, avatar, created_at, last_seen, location}
var blocks := {}  # blocker account -> {blocked account: created_at}
var _dirty := false
var _crypto := Crypto.new()
var _hex32 := RegEx.create_from_string("^[0-9a-f]{32}$")
var _hex64 := RegEx.create_from_string("^[0-9a-f]{64}$")


func _init(data_dir: String) -> void:
	dir = data_dir
	DirAccess.make_dir_recursive_absolute(dir)
	accounts = _load_dict("accounts.json")
	blocks = _load_dict("blocks.json")


static func now_iso() -> String:
	return Time.get_datetime_string_from_system(true) + "Z"


func authenticate(account_id: String, secret: String, display_name: String) -> bool:
	if _hex32.search(account_id) == null or _hex64.search(secret) == null:
		return false
	var secret_hash := ("%s:%s" % [account_id, secret]).sha256_text()
	if accounts.has(account_id):
		return accounts[account_id].secret_hash == secret_hash
	accounts[account_id] = {"secret_hash": secret_hash, "name": display_name, "created_at": now_iso()}
	_dirty = true
	flush()
	return true


func update_profile(account_id: String, display_name: String, avatar: Dictionary) -> void:
	var acc: Dictionary = accounts[account_id]
	acc.name = display_name
	acc.avatar = avatar
	acc.last_seen = now_iso()
	_dirty = true


func save_location(account_id: String, zone_id: String, zone_version: int, pos: Vector3, yaw: float, geo: PackedFloat64Array) -> void:
	if not accounts.has(account_id):
		return
	accounts[account_id].location = {
		"zone_id": zone_id, "zone_version": zone_version,
		"latitude": geo[0], "longitude": geo[1],
		"local_x": pos.x, "local_y": pos.y, "local_z": pos.z, "yaw": yaw,
		"updated_at": now_iso(),
	}
	_dirty = true


## Returns {} unless a saved location exists for this exact zone version.
func last_location(account_id: String, zone_id: String, zone_version: int) -> Dictionary:
	var loc: Variant = accounts.get(account_id, {}).get("location")
	if typeof(loc) != TYPE_DICTIONARY or loc.get("zone_id") != zone_id or int(loc.get("zone_version", -1)) != zone_version:
		return {}
	return loc


func blocked_by(account_id: String) -> Dictionary:
	return blocks.get(account_id, {})


func block(blocker: String, blocked: String) -> void:
	if not blocks.has(blocker):
		blocks[blocker] = {}
	blocks[blocker][blocked] = now_iso()
	_dirty = true
	flush()


func new_incident_id() -> String:
	return _crypto.generate_random_bytes(8).hex_encode()


func append_report(report: Dictionary) -> void:
	_append_line("reports.jsonl", report)


func audit(event: String, data: Dictionary) -> void:
	var entry := {"t": now_iso(), "event": event}
	entry.merge(data)
	_append_line("audit.jsonl", entry)


func flush() -> void:
	if not _dirty:
		return
	_write_atomic("accounts.json", accounts)
	_write_atomic("blocks.json", blocks)
	_dirty = false


func _load_dict(file_name: String) -> Dictionary:
	var path := dir.path_join(file_name)
	if not FileAccess.file_exists(path):
		return {}
	var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	if typeof(data) != TYPE_DICTIONARY:
		push_error("store: %s is corrupt, starting empty" % path)
		return {}
	return data


func _write_atomic(file_name: String, data: Variant) -> void:
	var path := dir.path_join(file_name)
	var tmp := path + ".tmp"
	var f := FileAccess.open(tmp, FileAccess.WRITE)
	if f == null:
		push_error("store: cannot write %s" % tmp)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()
	if FileAccess.file_exists(path):
		DirAccess.remove_absolute(path)
	DirAccess.rename_absolute(tmp, path)


func _append_line(file_name: String, data: Dictionary) -> void:
	var path := dir.path_join(file_name)
	var f := FileAccess.open(path, FileAccess.READ_WRITE if FileAccess.file_exists(path) else FileAccess.WRITE)
	if f == null:
		push_error("store: cannot append to %s" % path)
		return
	f.seek_end()
	f.store_line(JSON.stringify(data))
	f.close()
