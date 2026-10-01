class_name HideRules
extends RefCounted
## Saklambaç (hide-and-seek), free of networking like GameRules: every method
## returns effects {"to", "rpc", "args"} for the zone server to deliver.
##
## One player is the seeker ("ebe"): the one who asked for the game. The
## hiders are whoever accepted plus the seeker's group mates nearby. The
## seeker is held still facing a landmark for Protocol.HIDE_COUNT seconds
## (the "count" phase) while the hiders run off, then the "hunt" starts and
## lasts Protocol.HIDE_HUNT_TIME seconds.
##
## The SERVER decides everything: a hider is found when the seeker is closer
## than Protocol.HIDE_FIND_RADIUS (and not on another floor) AND a raycast
## from the seeker's eyes to the hider hits no world geometry, so a wall
## really hides you. A hider who reaches the base and taps E before being
## found is "kurtuldu" (safe). The round ends when every hider is found or
## safe, when time runs out, or when the seeker leaves.
##
## Everyone in the round hears it through s_party(event), ev being one of:
##   hide_start  {round, role: "seeker"|"hider", seeker, seeker_name, base, face,
##                place, hiders: [{id, name}], count, total}
##   hide_hunt   {total}                       the count is over
##   hide_found  {hider, name, left}           left = hiders still hidden
##   hide_free   {hider, name, left}           a hider reached the base
##   hide_left   {hider, name, reason}         a hider dropped out
##   hide_end    {reason, found, freed, total} reason: all, time, seeker_left, far, no_hiders, ended

var rounds := {}  # id -> round Dictionary
var _of := {}  # peer -> round id
var _next_id := 1

## Callable(peer: int) -> String, the player's display name.
var name_of: Callable
## Callable(a: int, b: int) -> bool, true when either side blocks the other.
var is_blocked: Callable


func _init(name_fn: Callable, blocked_fn: Callable) -> void:
	name_of = name_fn
	is_blocked = blocked_fn


func active() -> bool:
	return not rounds.is_empty()


func in_round(peer: int) -> bool:
	return _of.has(peer)


func round_of(peer: int) -> Dictionary:
	return rounds.get(_of.get(peer, 0), {})


func is_seeker(peer: int) -> bool:
	var r := round_of(peer)
	return not r.is_empty() and int(r.seeker) == peer


## True while this player must stand still (the seeker counting).
func frozen(peer: int) -> bool:
	var r := round_of(peer)
	return not r.is_empty() and int(r.seeker) == peer and r.phase == "count"


## Found: close enough horizontally, not on another floor, and a clear line.
static func can_find(horizontal: float, vertical: float, clear_line: bool) -> bool:
	return clear_line and horizontal < Protocol.HIDE_FIND_RADIUS and absf(vertical) < Protocol.HIDE_FIND_HEIGHT


## Safe: close enough to the base.
static func can_free(horizontal: float, vertical: float) -> bool:
	return horizontal <= Protocol.HIDE_BASE_RADIUS and absf(vertical) < Protocol.HIDE_FIND_HEIGHT


## "" when `seeker` may start a round with `target`, else a notice code.
func start_problem(seeker: int, target: int) -> String:
	if seeker == target or _of.has(seeker) or _of.has(target):
		return "game_busy"
	return ""


## Who plays besides the seeker: the accepter and the seeker's group mates
## in range, minus anyone busy or in a block with the seeker. distance_fn:
## Callable(a, b) -> float.
func invitees(seeker: int, target: int, group_mates: Array, distance_fn: Callable) -> Array:
	var out := []
	for p: int in [target] + group_mates:
		if p == seeker or out.has(p) or _of.has(p) or is_blocked.call(seeker, p):
			continue
		if p != target and float(distance_fn.call(seeker, p)) > Protocol.HIDE_JOIN_RANGE:
			continue
		out.append(p)
	return out


## base: where the seeker stands (and hiders run back to); face: the landmark
## the seeker faces; place: its name (may be empty).
func start(seeker: int, hiders: Array, base: Vector3, face: Vector3, place: String, now: float) -> Array:
	if _of.has(seeker) or hiders.is_empty():
		return [SocialRules._notice(seeker, "game_busy")]
	var id := _next_id
	_next_id += 1
	var list := []
	for h: int in hiders:
		if h != seeker and not _of.has(h) and not list.has(h):
			list.append(h)
	if list.is_empty():
		return [SocialRules._notice(seeker, "game_busy")]
	rounds[id] = {"id": id, "seeker": seeker, "hiders": list, "found": {}, "freed": {}, "base": base, "face": face,
		"place": place, "phase": "count", "count_until": now + Protocol.HIDE_COUNT, "ends_at": 0.0, "total": list.size()}
	_of[seeker] = id
	for h: int in list:
		_of[h] = id
	var roster := []
	for h: int in list:
		roster.append({"id": h, "name": str(name_of.call(h))})
	var effects := []
	for p: int in [seeker] + list:
		effects.append(_ev(p, {"ev": "hide_start", "round": id, "role": "seeker" if p == seeker else "hider",
			"seeker": seeker, "seeker_name": str(name_of.call(seeker)), "base": base, "face": face, "place": place,
			"hiders": roster, "count": Protocol.HIDE_COUNT, "total": Protocol.HIDE_HUNT_TIME}))
	return effects


## A hider taps E near the base. pos: the hider's position.
func tap_base(peer: int, pos: Vector3) -> Array:
	var r := round_of(peer)
	if r.is_empty() or int(r.seeker) == peer or not (r.hiders as Array).has(peer) or _resolved(r, peer):
		return []
	if r.phase == "count":
		return [SocialRules._notice(peer, "hide_counting")]
	var base: Vector3 = r.base
	var horizontal := Vector2(pos.x - base.x, pos.z - base.z).length()
	if not can_free(horizontal, pos.y - base.y):
		return [SocialRules._notice(peer, "hide_base_far")]
	r.freed[peer] = true
	var effects := _all(r, {"ev": "hide_free", "hider": peer, "name": str(name_of.call(peer)), "left": _hidden(r)})
	return effects + _check_done(r)


## Advances every round. pos_fn: Callable(peer) -> Vector3 (Vector3.INF if
## gone); los_fn: Callable(from: Vector3, to: Vector3) -> bool, true when
## nothing solid is between the two points.
func update(now: float, pos_fn: Callable, los_fn: Callable) -> Array:
	var effects := []
	for id in rounds.keys():
		if rounds.has(id):
			effects.append_array(_tick(rounds[id], now, pos_fn, los_fn))
	return effects


func _tick(r: Dictionary, now: float, pos_fn: Callable, los_fn: Callable) -> Array:
	var effects := []
	var base: Vector3 = r.base
	var seeker_pos: Vector3 = pos_fn.call(r.seeker)
	if not seeker_pos.is_finite():
		return _finish(r, "seeker_left")
	if Vector2(seeker_pos.x - base.x, seeker_pos.z - base.z).length() > Protocol.HIDE_AREA:
		return _finish(r, "far")
	# Hiders who wandered off (or vanished) drop out.
	for h: int in (r.hiders as Array).duplicate():
		var hp: Vector3 = pos_fn.call(h)
		if not hp.is_finite() or Vector2(hp.x - base.x, hp.z - base.z).length() > Protocol.HIDE_AREA:
			effects.append_array(_remove_hider(r, h, "far"))
			if not rounds.has(r.id):
				return effects
	if r.phase == "count":
		if now < float(r.count_until):
			return effects
		r.phase = "hunt"
		r.ends_at = now + Protocol.HIDE_HUNT_TIME
		effects.append_array(_all(r, {"ev": "hide_hunt", "total": Protocol.HIDE_HUNT_TIME}))
	if now >= float(r.ends_at):
		effects.append_array(_finish(r, "time"))
		return effects
	var eye := seeker_pos + Vector3(0.0, 1.5, 0.0)
	for h: int in (r.hiders as Array).duplicate():
		if _resolved(r, h):
			continue
		var hp: Vector3 = pos_fn.call(h)
		var horizontal := Vector2(hp.x - seeker_pos.x, hp.z - seeker_pos.z).length()
		var vertical := hp.y - seeker_pos.y
		# The raycast only runs for hiders that are already close enough.
		if horizontal >= Protocol.HIDE_FIND_RADIUS or absf(vertical) >= Protocol.HIDE_FIND_HEIGHT:
			continue
		if can_find(horizontal, vertical, bool(los_fn.call(eye, hp + Vector3(0.0, 1.0, 0.0)))):
			r.found[h] = true
			effects.append_array(_all(r, {"ev": "hide_found", "hider": h, "name": str(name_of.call(h)), "left": _hidden(r)}))
	effects.append_array(_check_done(r))
	return effects


## The peer leaves the round (quit, disconnect, wandering off).
func cancel(peer: int, reason: String) -> Array:
	var r := round_of(peer)
	if r.is_empty():
		return []
	if int(r.seeker) == peer:
		return _finish(r, "seeker_left")
	return _remove_hider(r, peer, reason)


## `blocker` blocked `blocked`: the blocker leaves the round (the other side
## is not told why, they just see the player leave).
func on_block(blocker: int, blocked: int) -> Array:
	var r := round_of(blocker)
	if r.is_empty() or round_of(blocked).get("id", -1) != r.id:
		return []
	return cancel(blocker, "ended")


func _remove_hider(r: Dictionary, peer: int, reason: String) -> Array:
	(r.hiders as Array).erase(peer)
	r.found.erase(peer)
	r.freed.erase(peer)
	_of.erase(peer)
	var effects := [_ev(peer, {"ev": "hide_end", "reason": reason, "found": r.found.size(), "freed": r.freed.size(), "total": r.total})]
	effects.append_array(_all(r, {"ev": "hide_left", "hider": peer, "name": str(name_of.call(peer)), "reason": reason}))
	return effects + _check_done(r)


## Ends the round when no hider is left hiding.
func _check_done(r: Dictionary) -> Array:
	if not rounds.has(r.id):
		return []
	if (r.hiders as Array).is_empty():
		return _finish(r, "no_hiders")
	if r.phase == "hunt" and _hidden(r) == 0:
		return _finish(r, "all")
	return []


func _finish(r: Dictionary, reason: String) -> Array:
	var effects := _all(r, {"ev": "hide_end", "reason": reason, "found": r.found.size(), "freed": r.freed.size(), "total": r.total})
	for p: int in [r.seeker] + r.hiders:
		_of.erase(p)
	rounds.erase(r.id)
	return effects


## Hiders neither found nor safe.
func _hidden(r: Dictionary) -> int:
	var n := 0
	for h: int in r.hiders:
		if not _resolved(r, h):
			n += 1
	return n


func _resolved(r: Dictionary, peer: int) -> bool:
	return r.found.has(peer) or r.freed.has(peer)


func _all(r: Dictionary, event: Dictionary) -> Array:
	var effects := []
	for p: int in [r.seeker] + r.hiders:
		effects.append(_ev(p, event))
	return effects


static func _ev(to: int, event: Dictionary) -> Dictionary:
	return SocialRules._rpc(to, "s_party", [event])
