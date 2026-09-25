class_name SocialRules
extends RefCounted
## Consent-first social state machine, free of networking so it can be
## unit tested. Every method returns a list of effects for the zone server
## to deliver: {"to": peer_id, "rpc": "s_...", "args": [...]}.
##
## Rules from the plan:
## - Talking starts with a request; nothing opens without an accept.
## - Declining and ignoring look the same to the requester: once the
##   request times out they get "no_response", never "declined".
## - A request to someone who has blocked you is swallowed silently.
## - Same-target cooldown, and a longer one after repeated refusals.
## - Only people in an accepted conversation receive your text.

var requests := {}  # request_id -> {id, from, to, kind, expires, declined}
var conversations := {}  # "a:b" (a < b) -> {a, b, lines: []}
var _next_request_id := 1
var _last_request_at := {}  # "from>to" -> time
var _refusals := {}  # "from>to" -> {count, until}
var _chat_tokens := {}  # peer -> {tokens, at}
var _emote_at := {}  # peer -> time

## Callable(a: int, b: int) -> bool, true when either side blocks the other.
var is_blocked: Callable
## Callable(a: int) -> Array[int] of players within range, used for emotes.
var nearby: Callable


func _init(blocked_fn: Callable, nearby_fn: Callable) -> void:
	is_blocked = blocked_fn
	nearby = nearby_fn


static func conv_key(a: int, b: int) -> String:
	return "%d:%d" % [mini(a, b), maxi(a, b)]


func in_conversation(a: int, b: int) -> bool:
	return conversations.has(conv_key(a, b))


func partners(peer: int) -> Array:
	var out := []
	for c in conversations.values():
		if c.a == peer:
			out.append(c.b)
		elif c.b == peer:
			out.append(c.a)
	return out


func request(from: int, to: int, kind: String, now: float, distance: float, requester_blocked_target: bool) -> Array:
	if from == to or not Protocol.REQUEST_KINDS.has(kind):
		return []
	if requester_blocked_target:
		return [_notice(from, "you_blocked")]
	if distance > Protocol.INTERACTION_RANGE + Protocol.INTERACTION_RANGE_TOLERANCE:
		return [_notice(from, "too_far")]
	if in_conversation(from, to):
		return [_notice(from, "already_talking")]
	var pair := "%d>%d" % [from, to]
	var refusal: Dictionary = _refusals.get(pair, {})
	if now < float(refusal.get("until", 0.0)):
		return [_notice(from, "cooldown")]
	if now - float(_last_request_at.get(pair, -INF)) < Protocol.SAME_TARGET_COOLDOWN:
		return [_notice(from, "cooldown")]
	var incoming := 0
	for r in requests.values():
		if r.from == from:
			return [_notice(from, "request_pending")]
		if r.to == to:
			incoming += 1
	_last_request_at[pair] = now

	var id := _next_request_id
	_next_request_id += 1
	var silent: bool = is_blocked.call(to, from) or incoming >= Protocol.MAX_INCOMING_REQUESTS
	requests[id] = {"id": id, "from": from, "to": to, "kind": kind,
		"expires": now + Protocol.REQUEST_TIMEOUT, "declined": silent, "silent": silent}
	var effects := [_rpc(from, "s_interaction_result", [id, "sent"])]
	if not silent:
		effects.append(_rpc(to, "s_interaction_incoming", [id, from, kind]))
	return effects


func respond(responder: int, request_id: int, accept: bool, now: float) -> Array:
	if not requests.has(request_id):
		return []
	var r: Dictionary = requests[request_id]
	if r.to != responder or r.declined or now > float(r.expires):
		return []
	if not accept:
		# Keep it until expiry so a decline is indistinguishable from silence.
		r.declined = true
		return []
	requests.erase(request_id)
	_refusals.erase("%d>%d" % [r.from, r.to])
	conversations[conv_key(r.from, r.to)] = {"a": mini(r.from, r.to), "b": maxi(r.from, r.to), "lines": []}
	return [
		_rpc(r.from, "s_interaction_result", [request_id, "accepted"]),
		_rpc(r.from, "s_conversation_open", [r.to]),
		_rpc(r.to, "s_conversation_open", [r.from]),
	]


## Expires requests and closes conversations whose members drifted apart.
## distance_fn: Callable(a: int, b: int) -> float (INF if either is gone).
func update(now: float, distance_fn: Callable) -> Array:
	var effects := []
	for id in requests.keys():
		var r: Dictionary = requests[id]
		if now <= float(r.expires):
			continue
		requests.erase(id)
		effects.append(_rpc(r.from, "s_interaction_result", [id, "no_response"]))
		if not r.silent:
			effects.append(_rpc(r.to, "s_interaction_result", [id, "expired"]))
		_count_refusal(r.from, r.to, now)
	for key in conversations.keys():
		var c: Dictionary = conversations[key]
		if float(distance_fn.call(c.a, c.b)) > Protocol.CONVERSATION_RANGE:
			effects.append_array(close_conversation(c.a, c.b, "distance"))
	return effects


func close_conversation(a: int, b: int, reason: String) -> Array:
	var key := conv_key(a, b)
	if not conversations.has(key):
		return []
	conversations.erase(key)
	return [_rpc(a, "s_conversation_close", [b, reason]), _rpc(b, "s_conversation_close", [a, reason])]


func chat(from: int, raw_text: String, now: float) -> Array:
	var text := sanitize_text(raw_text)
	if text.is_empty():
		return []
	var to := partners(from)
	if to.is_empty():
		return [_notice(from, "not_in_conversation")]
	if not _take_chat_token(from, now):
		return [_notice(from, "rate_limited")]
	var effects := [_rpc(from, "s_chat", [from, text])]
	for p in to:
		effects.append(_rpc(p, "s_chat", [from, text]))
		var lines: Array = conversations[conv_key(from, p)].lines
		lines.append({"from": from, "text": text, "t": now})
		if lines.size() > 20:
			lines.pop_front()
	return effects


func emote(from: int, kind: String, now: float) -> Array:
	if not Protocol.EMOTES.has(kind):
		return []
	if now - float(_emote_at.get(from, -INF)) < Protocol.EMOTE_COOLDOWN:
		return []
	_emote_at[from] = now
	var effects := [_rpc(from, "s_emote", [from, kind])]
	for p in nearby.call(from):
		if p != from and not is_blocked.call(from, p):
			effects.append(_rpc(p, "s_emote", [from, kind]))
	return effects


## Called after `blocker` blocks `blocked`. The blocked side is not told.
func on_block(blocker: int, blocked: int) -> Array:
	for id in requests.keys():
		var r: Dictionary = requests[id]
		if (r.from == blocker and r.to == blocked) or (r.from == blocked and r.to == blocker):
			# Leave requests from the blocked player to time out silently.
			r.declined = true
			r.silent = true
	var effects := []
	var key := conv_key(blocker, blocked)
	if conversations.has(key):
		conversations.erase(key)
		effects.append(_rpc(blocker, "s_conversation_close", [blocked, "blocked"]))
		effects.append(_rpc(blocked, "s_conversation_close", [blocker, "ended"]))
	effects.append(_notice(blocker, "blocked"))
	return effects


func on_disconnect(peer: int) -> Array:
	var effects := []
	for id in requests.keys():
		var r: Dictionary = requests[id]
		if r.from == peer:
			requests.erase(id)
			if not r.silent:
				effects.append(_rpc(r.to, "s_interaction_result", [id, "expired"]))
		elif r.to == peer:
			r.declined = true  # requester still just sees no_response on expiry
			r.silent = true
	for p in partners(peer):
		effects.append_array(close_conversation(peer, p, "left"))
	_chat_tokens.erase(peer)
	_emote_at.erase(peer)
	return effects


## Recent lines of the conversation between a and b, for report context.
func recent_lines(a: int, b: int) -> Array:
	var key := conv_key(a, b)
	return conversations[key].lines.duplicate(true) if conversations.has(key) else []


static func sanitize_text(raw: String) -> String:
	var out := ""
	for ch in raw.strip_edges():
		var code: int = ch.unicode_at(0)
		if code >= 32 and code != 127:
			out += ch
	return out.substr(0, Protocol.CHAT_MAX_LEN)


func _count_refusal(from: int, to: int, now: float) -> void:
	var pair := "%d>%d" % [from, to]
	var refusal: Dictionary = _refusals.get(pair, {"count": 0, "until": 0.0})
	refusal.count = int(refusal.count) + 1
	if refusal.count >= Protocol.REPEATED_REFUSAL_LIMIT:
		refusal.count = 0
		refusal.until = now + Protocol.REPEATED_REFUSAL_COOLDOWN
	_refusals[pair] = refusal


func _take_chat_token(peer: int, now: float) -> bool:
	var b: Dictionary = _chat_tokens.get(peer, {"tokens": float(Protocol.CHAT_BURST), "at": now})
	b.tokens = minf(Protocol.CHAT_BURST, float(b.tokens) + (now - float(b.at)) * Protocol.CHAT_REFILL_PER_SEC)
	b.at = now
	_chat_tokens[peer] = b
	if b.tokens < 1.0:
		return false
	b.tokens -= 1.0
	return true


static func _rpc(to: int, method: String, args: Array) -> Dictionary:
	return {"to": to, "rpc": method, "args": args}


static func _notice(to: int, code: String, detail := "") -> Dictionary:
	return _rpc(to, "s_notice", [code, detail])
