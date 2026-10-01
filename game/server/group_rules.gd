class_name GroupRules
extends RefCounted
## Player groups ("Grup kur"), free of networking like SocialRules: every
## method returns effects {"to": peer, "rpc": "s_...", "args": [...]} for the
## zone server to deliver. State lives in memory only.
##
## - A group has a name and a colour no other live group shares (ten colours,
##   so at most ten groups), and at most Protocol.GROUP_MAX_MEMBERS people.
## - Joining goes through the request flow of SocialRules (kind "group"), so
##   it is consent-first; the request is validated again when it is accepted.
## - The last member leaving deletes the group; a disconnect leaves it.
## - Group chat reaches every member wherever they are in the zone and is a
##   separate channel from the conversation chat (s_group_chat, not s_chat).
## - Everyone in the zone is told who wears which colour (s_group_marks) so
##   groupmates can be told apart at a glance; names and chat stay private.

var groups := {}  # id -> {id, name, color, members: Array[int]}
var _of := {}  # peer -> group id
var _next_id := 1
var _chat_tokens := {}  # peer -> {tokens, at}

## Callable(peer: int) -> String, the player's display name.
var name_of: Callable
## Callable() -> Array[int] of everyone in the zone (for the colour marks).
var everyone: Callable


func _init(name_fn: Callable, everyone_fn: Callable) -> void:
	name_of = name_fn
	everyone = everyone_fn


func group_of(peer: int) -> int:
	return int(_of.get(peer, 0))


func members_of(peer: int) -> Array:
	return groups[_of[peer]].members.duplicate() if _of.has(peer) else []


## Palette index of the peer's group, or -1.
func color_of(peer: int) -> int:
	return int(groups[_of[peer]].color) if _of.has(peer) else -1


func same_group(a: int, b: int) -> bool:
	return _of.has(a) and _of.get(a) == _of.get(b)


## The first palette colour no live group wears, or -1 when all are taken.
func free_color() -> int:
	var used := {}
	for g in groups.values():
		used[int(g.color)] = true
	for i in Protocol.GROUP_COLORS.size():
		if not used.has(i):
			return i
	return -1


## Why `from` may not invite `to` right now ("" when it is fine): a notice code.
func invite_problem(from: int, to: int) -> String:
	if from == to:
		return "bad_target"
	if _of.has(to):
		return "target_in_group" if not same_group(from, to) else "already_in_group"
	if _of.has(from):
		if groups[_of[from]].members.size() >= Protocol.GROUP_MAX_MEMBERS:
			return "group_full"
	elif free_color() < 0:
		return "groups_full"
	return ""


## Makes a group with `peer` in it. `raw_name` is optional ("Grup N" otherwise).
func create(peer: int, raw_name := "") -> Array:
	if _of.has(peer):
		return [SocialRules._notice(peer, "already_in_group")]
	var color := free_color()
	if color < 0:
		return [SocialRules._notice(peer, "groups_full")]
	var name := SocialRules.sanitize_text(raw_name).substr(0, Protocol.GROUP_NAME_MAX).strip_edges()
	if name.is_empty():
		name = _default_name()
	var id := _next_id
	_next_id += 1
	groups[id] = {"id": id, "name": name, "color": color, "members": [peer]}
	_of[peer] = id
	var effects := [SocialRules._notice(peer, "group_created", name)]
	effects.append(_state_for(peer))
	effects.append_array(_marks())
	return effects


## An accepted invitation: `to` joins the group of `from` (made on the spot
## when the inviter had none). Checked again, since things change in 20 s.
func accept_invite(from: int, to: int) -> Array:
	var problem := invite_problem(from, to)
	if problem != "":
		return [SocialRules._notice(from, problem), SocialRules._notice(to, problem)]
	var effects := []
	if not _of.has(from):
		effects.append_array(create(from))
	var group: Dictionary = groups[_of[from]]
	group.members.append(to)
	_of[to] = group.id
	for m: int in group.members:
		if m == to:
			effects.append(SocialRules._notice(m, "group_joined_you", group.name))
		else:
			effects.append(SocialRules._notice(m, "group_joined", str(name_of.call(to))))
		effects.append(_state_for(m))
	effects.append_array(_marks())
	return effects


## `peer` leaves (or was disconnected). Deletes the group when nobody is left.
func leave(peer: int) -> Array:
	if not _of.has(peer):
		return [SocialRules._notice(peer, "not_in_group")]
	var group: Dictionary = groups[_of[peer]]
	_of.erase(peer)
	_chat_tokens.erase(peer)
	group.members.erase(peer)
	var effects := [SocialRules._notice(peer, "group_left_you", group.name), _empty_state(peer)]
	if group.members.is_empty():
		groups.erase(group.id)
	else:
		for m: int in group.members:
			effects.append(SocialRules._notice(m, "group_left", str(name_of.call(peer))))
			effects.append(_state_for(m))
	effects.append_array(_marks())
	return effects


func on_disconnect(peer: int) -> Array:
	_chat_tokens.erase(peer)
	if not _of.has(peer):
		return []
	var effects := leave(peer)
	# The leaver is gone; only the others hear about it.
	return effects.filter(func(e: Dictionary) -> bool: return e.to != peer)


## Group chat: to every member, sender included. Rate limited like normal chat.
func chat(from: int, raw_text: String, now: float) -> Array:
	var text := SocialRules.sanitize_text(raw_text)
	if text.is_empty():
		return []
	if not _of.has(from):
		return [SocialRules._notice(from, "not_in_group")]
	if not _take_chat_token(from, now):
		return [SocialRules._notice(from, "rate_limited")]
	var effects := []
	for m: int in groups[_of[from]].members:
		effects.append(SocialRules._rpc(m, "s_group_chat", [from, text]))
	return effects


## What a new arrival needs to know: the colour marks of everyone in a group.
func marks_for(peer: int) -> Array:
	return [SocialRules._rpc(peer, "s_group_marks", [marks()])]


## Flat [peer, color, peer, color, ...] for everyone who is in a group.
func marks() -> Array:
	var out := []
	for peer: int in _of:
		out.append(peer)
		out.append(int(groups[_of[peer]].color))
	return out


func _marks() -> Array:
	var flat := marks()
	var effects := []
	for p: int in everyone.call():
		effects.append(SocialRules._rpc(p, "s_group_marks", [flat]))
	return effects


func _state_for(peer: int) -> Dictionary:
	var g: Dictionary = groups[_of[peer]]
	var members := []
	for m: int in g.members:
		members.append({"id": m, "name": str(name_of.call(m))})
	return SocialRules._rpc(peer, "s_group_state", [{"id": g.id, "name": g.name, "color": g.color, "members": members}])


static func _empty_state(peer: int) -> Dictionary:
	return SocialRules._rpc(peer, "s_group_state", [{}])


func _default_name() -> String:
	var taken := {}
	for g in groups.values():
		taken[str(g.name)] = true
	var n := 1
	while taken.has("Grup %d" % n):
		n += 1
	return "Grup %d" % n


func _take_chat_token(peer: int, now: float) -> bool:
	var b: Dictionary = _chat_tokens.get(peer, {"tokens": float(Protocol.CHAT_BURST), "at": now})
	b.tokens = minf(Protocol.CHAT_BURST, float(b.tokens) + (now - float(b.at)) * Protocol.CHAT_REFILL_PER_SEC)
	b.at = now
	_chat_tokens[peer] = b
	if b.tokens < 1.0:
		return false
	b.tokens -= 1.0
	return true
