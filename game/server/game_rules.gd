class_name GameRules
extends RefCounted
## Two-player minigames ("Taş kâğıt makas" and "El kızartmaca"), free of
## networking like SocialRules: every method returns effects {"to", "rpc",
## "args"} for the zone server to deliver. The SERVER is the referee; clients
## only send their pick or their press and draw what the events tell them.
##
## A match starts once a request of kind "rps" or "slap" was accepted (the
## same consent flow as talking). Everything the two players see comes through
## one RPC, s_game(event), where event["ev"] is one of:
##   start   {match, kind, opp, opp_name, wins, rounds}
##   round   {round, score: [you, opp], role: "top"|"bottom" (slap only)}
##   count   {n}             rps: 3, 2, 1 (fist shaking)
##   go      {}              rps: shoot, picks close soon; slap: the cue
##   picked  {value}         rps: your pick was locked in (to you)
##   opp_ready {}            rps: the opponent has picked (to you)
##   reveal  {...}           the round result, see _rps_reveal / _slap_reveal
##   end     {winner: "you"|"opp"|"none", reason, score: [you, opp]}
## Emotes for the hand signs and the slap are sent from here, never by
## clients (c_emote only accepts Protocol.EMOTES).
##
## Cheating: only the two players of a match may input, picks lock in once,
## moving further apart than Protocol.GAME_RANGE ends the match, a press
## before the cue loses the round, and reaction times are measured on the
## server minus the player's round-trip time (capped), so latency does not
## decide a round; a small tie window favours the player on top.

var matches := {}  # id -> match Dictionary
var _of := {}  # peer -> match id
var _next_id := 1
var rng := RandomNumberGenerator.new()

## Callable(peer: int) -> Array[int] of players within emote range.
var nearby: Callable
## Callable(a: int, b: int) -> bool, true when either side blocks the other.
var is_blocked: Callable
## Callable(peer: int) -> String, the player's display name.
var name_of: Callable
## Callable(peer: int) -> float, round-trip time in seconds (0.0 if unknown).
var rtt_of: Callable


func _init(nearby_fn: Callable, blocked_fn: Callable, name_fn: Callable, rtt_fn: Callable) -> void:
	nearby = nearby_fn
	is_blocked = blocked_fn
	name_of = name_fn
	rtt_of = rtt_fn
	rng.randomize()


func active() -> bool:
	return not matches.is_empty()


func in_match(peer: int) -> bool:
	return _of.has(peer)


func match_of(peer: int) -> Dictionary:
	return matches.get(_of.get(peer, 0), {})


## RPS: 1 when x beats y, -1 when y beats x, 0 for a draw. 0 rock, 1 paper,
## 2 scissors, -1 no pick (any pick beats no pick; two empty hands draw).
static func rps_winner(x: int, y: int) -> int:
	if x == y:
		return 0
	if x < 0:
		return -1
	if y < 0:
		return 1
	return 1 if (x - y + 3) % 3 == 1 else -1


## Hand slap: who takes the round, "top", "bottom" or "none". Times are the
## compensated reaction times in seconds, -1 when the player did nothing.
## The player on top slaps and the one below pulls away: both react to the
## same cue, so the faster one wins, and the top player keeps a tie window.
static func slap_outcome(top_rt: float, bottom_rt: float) -> String:
	var top_ok := top_rt >= 0.0
	var bottom_ok := bottom_rt >= 0.0
	if not top_ok and not bottom_ok:
		return "none"
	if top_ok and not bottom_ok:
		return "top"
	if bottom_ok and not top_ok:
		return "bottom"
	return "bottom" if bottom_rt + Protocol.SLAP_TIE < top_rt else "top"


## "" when a match between these two may start, else a notice code.
func start_problem(a: int, b: int) -> String:
	if a == b or _of.has(a) or _of.has(b):
		return "game_busy"
	return ""


func start(kind: String, a: int, b: int, now: float) -> Array:
	if not Protocol.GAME_KINDS.has(kind):
		return []
	if start_problem(a, b) != "":
		return [SocialRules._notice(a, "game_busy"), SocialRules._notice(b, "game_busy")]
	var id := _next_id
	_next_id += 1
	matches[id] = {"id": id, "kind": kind, "a": a, "b": b, "phase": "intro", "at": now + Protocol.GAME_INTRO,
		"round": 0, "score_a": 0, "score_b": 0, "pick_a": -1, "pick_b": -1, "rt_a": -1.0, "rt_b": -1.0,
		"top": "a", "count": 0, "round_t": 0.0, "go_at": 0.0, "go_time": 0.0}
	_of[a] = id
	_of[b] = id
	var effects := []
	for p in [a, b]:
		var opp: int = b if p == a else a
		effects.append(_ev(p, {"ev": "start", "match": id, "kind": kind, "opp": opp, "opp_name": str(name_of.call(opp)),
			"wins": Protocol.RPS_WINS if kind == "rps" else Protocol.SLAP_WINS,
			"rounds": Protocol.RPS_MAX_ROUNDS if kind == "rps" else Protocol.SLAP_ROUNDS}))
	return effects


## A pick (rps: 0..2) or a press (slap: anything) from `peer`.
func input(peer: int, match_id: int, value: int, now: float) -> Array:
	var m := match_of(peer)
	if m.is_empty() or int(m.id) != match_id:
		return []
	var side := _side(m, peer)
	if m.kind == "rps":
		if value < 0 or value > 2 or m.phase not in ["count", "pick"] or int(m["pick_" + side]) >= 0:
			return []
		m["pick_" + side] = value
		var other: int = m.b if side == "a" else m.a
		return [_ev(peer, {"ev": "picked", "value": value}), _ev(other, {"ev": "opp_ready"})]
	if m.phase == "ready":
		return _slap_resolve(m, now, side)  # pressed before the cue
	if m.phase != "go" or float(m["rt_" + side]) >= 0.0:
		return []
	var rt: float = now - float(m.go_time) - clampf(float(rtt_of.call(peer)), 0.0, Protocol.SLAP_MAX_RTT)
	if rt < Protocol.SLAP_MIN_REACTION:
		return _slap_resolve(m, now, side)  # faster than a human can be: anticipation
	m["rt_" + side] = rt
	if float(m.rt_a) >= 0.0 and float(m.rt_b) >= 0.0:
		return _slap_resolve(m, now, "")
	return []


## Ends the peer's match without a winner (quit, disconnect, block).
func cancel(peer: int, reason: String) -> Array:
	var m := match_of(peer)
	return _finish(m, "none", reason) if not m.is_empty() else []


func on_block(a: int, b: int) -> Array:
	var m := match_of(a)
	if not m.is_empty() and (m.a == b or m.b == b):
		return _finish(m, "none", "ended")
	return []


## Advances every match; distance_fn: Callable(a, b) -> float (INF if gone).
func update(now: float, distance_fn: Callable) -> Array:
	var effects := []
	for id in matches.keys():
		var m: Dictionary = matches[id]
		if float(distance_fn.call(m.a, m.b)) > Protocol.GAME_RANGE:
			effects.append_array(_finish(m, "none", "distance"))
		elif m.kind == "rps":
			effects.append_array(_tick_rps(m, now))
		else:
			effects.append_array(_tick_slap(m, now))
	return effects


# --- rock paper scissors -----------------------------------------------------

func _tick_rps(m: Dictionary, now: float) -> Array:
	var effects := []
	match m.phase:
		"intro":
			if now >= float(m.at):
				effects.append_array(_rps_round(m, now))
		"count":
			while int(m.count) < 3 and now >= float(m.round_t) + int(m.count) * Protocol.RPS_COUNT_STEP:
				effects.append_array(_both(m, {"ev": "count", "n": 3 - int(m.count)}))
				m.count = int(m.count) + 1
			if now >= float(m.round_t) + 3 * Protocol.RPS_COUNT_STEP:
				m.phase = "pick"
				effects.append_array(_both(m, {"ev": "go"}))
		"pick":
			var deadline: float = float(m.round_t) + 3 * Protocol.RPS_COUNT_STEP + Protocol.RPS_PICK_TIME
			if (int(m.pick_a) >= 0 and int(m.pick_b) >= 0) or now >= deadline:
				effects.append_array(_rps_reveal(m, now))
		"reveal":
			if now >= float(m.at):
				effects.append_array(_rps_next(m, now))
	return effects


func _rps_round(m: Dictionary, now: float) -> Array:
	m.round = int(m.round) + 1
	m.pick_a = -1
	m.pick_b = -1
	m.count = 0
	m.phase = "count"
	m.round_t = now
	var effects := []
	for side in ["a", "b"]:
		effects.append(_ev(m[side], {"ev": "round", "round": m.round, "score": _score(m, side)}))
	effects.append_array(_emote(m.a, "shake", m.b))
	effects.append_array(_emote(m.b, "shake", m.a))
	return effects


func _rps_reveal(m: Dictionary, now: float) -> Array:
	var w := rps_winner(int(m.pick_a), int(m.pick_b))
	if w > 0:
		m.score_a = int(m.score_a) + 1
	elif w < 0:
		m.score_b = int(m.score_b) + 1
	m.phase = "reveal"
	m.at = now + Protocol.GAME_REVEAL
	var effects := []
	for side in ["a", "b"]:
		var mine := int(m["pick_" + side])
		var theirs := int(m["pick_" + _flip(side)])
		var verdict := "draw"
		if w != 0:
			verdict = "you" if (w > 0) == (side == "a") else "opp"
		effects.append(_ev(m[side], {"ev": "reveal", "round": m.round, "you": mine, "opp": theirs,
			"winner": verdict, "score": _score(m, side)}))
		if mine >= 0:
			effects.append_array(_emote(m[side], ["rock", "paper", "scissors"][mine], m[_flip(side)]))
	return effects


func _rps_next(m: Dictionary, now: float) -> Array:
	var need := Protocol.RPS_WINS
	if int(m.score_a) >= need or int(m.score_b) >= need or int(m.round) >= Protocol.RPS_MAX_ROUNDS:
		return _finish(m, _leader(m), "done")
	return _rps_round(m, now)


# --- hand slap -----------------------------------------------------------------

func _tick_slap(m: Dictionary, now: float) -> Array:
	var effects := []
	match m.phase:
		"intro":
			if now >= float(m.at):
				effects.append_array(_slap_round(m, now))
		"ready":
			if now >= float(m.go_at):
				m.phase = "go"
				m.go_time = now
				effects.append_array(_both(m, {"ev": "go"}))
		"go":
			var slack := maxf(float(rtt_of.call(m.a)), float(rtt_of.call(m.b)))
			if now >= float(m.go_time) + Protocol.SLAP_WINDOW + minf(slack, Protocol.SLAP_MAX_RTT):
				effects.append_array(_slap_resolve(m, now, ""))
		"reveal":
			if now >= float(m.at):
				effects.append_array(_slap_next(m, now))
	return effects


func _slap_round(m: Dictionary, now: float) -> Array:
	m.round = int(m.round) + 1
	m.top = "a" if int(m.round) % 2 == 1 else "b"  # the roles swap every round
	m.rt_a = -1.0
	m.rt_b = -1.0
	m.phase = "ready"
	m.go_at = now + Protocol.SLAP_READY + rng.randf_range(Protocol.SLAP_DELAY_MIN, Protocol.SLAP_DELAY_MAX)
	var effects := []
	for side in ["a", "b"]:
		effects.append(_ev(m[side], {"ev": "round", "round": m.round, "score": _score(m, side),
			"role": "top" if side == m.top else "bottom"}))
	return effects


## Settles the round. `false_start` is the side that pressed too early, or "".
func _slap_resolve(m: Dictionary, now: float, false_start: String) -> Array:
	var top: String = m.top
	var bottom := _flip(top)
	var winner := ""
	var how := "none"
	if false_start != "":
		winner = _flip(false_start)
		how = "false_start"
	else:
		match slap_outcome(float(m["rt_" + top]), float(m["rt_" + bottom])):
			"top":
				winner = top
				how = "slapped"
			"bottom":
				winner = bottom
				how = "dodged"
	if winner != "":
		m["score_" + winner] = int(m["score_" + winner]) + 1
	m.phase = "reveal"
	m.at = now + Protocol.GAME_REVEAL
	var effects := []
	for side in ["a", "b"]:
		var verdict := "none"
		if winner != "":
			verdict = "you" if winner == side else "opp"
		effects.append(_ev(m[side], {"ev": "reveal", "round": m.round, "winner": verdict, "how": how,
			"role": "top" if side == top else "bottom", "you_rt": snappedf(float(m["rt_" + side]), 0.001),
			"opp_rt": snappedf(float(m["rt_" + _flip(side)]), 0.001), "false_start": false_start == side,
			"score": _score(m, side)}))
	if how == "slapped" or how == "dodged":
		effects.append_array(_emote(m[top], "slap", m[bottom]))
	if how == "dodged":
		effects.append_array(_emote(m[bottom], "dodge", m[top]))
	return effects


func _slap_next(m: Dictionary, now: float) -> Array:
	if int(m.score_a) >= Protocol.SLAP_WINS or int(m.score_b) >= Protocol.SLAP_WINS or int(m.round) >= Protocol.SLAP_ROUNDS:
		return _finish(m, _leader(m), "done")
	return _slap_round(m, now)


# --- helpers -----------------------------------------------------------------

## The match's final result: "a", "b" or "none" for a draw.
func _leader(m: Dictionary) -> String:
	if int(m.score_a) == int(m.score_b):
		return "none"
	return "a" if int(m.score_a) > int(m.score_b) else "b"


func _finish(m: Dictionary, winner: String, reason: String) -> Array:
	var effects := []
	for side in ["a", "b"]:
		var verdict := "none"
		if winner != "none":
			verdict = "you" if winner == side else "opp"
		effects.append(_ev(m[side], {"ev": "end", "kind": m.kind, "winner": verdict, "reason": reason, "score": _score(m, side)}))
		_of.erase(m[side])
	matches.erase(m.id)
	return effects


func _side(m: Dictionary, peer: int) -> String:
	return "a" if m.a == peer else "b"


static func _flip(side: String) -> String:
	return "b" if side == "a" else "a"


## [your score, their score] from `side`'s point of view.
static func _score(m: Dictionary, side: String) -> Array:
	return [int(m["score_" + side]), int(m["score_" + _flip(side)])]


static func _ev(to: int, event: Dictionary) -> Dictionary:
	return SocialRules._rpc(to, "s_game", [event])


func _both(m: Dictionary, event: Dictionary) -> Array:
	return [_ev(m.a, event), _ev(m.b, event)]


## A hand sign or slap seen by both players and by whoever stands near them.
func _emote(peer: int, kind: String, opponent: int) -> Array:
	var effects := [SocialRules._rpc(peer, "s_emote", [peer, kind]), SocialRules._rpc(opponent, "s_emote", [peer, kind])]
	for p: int in nearby.call(peer):
		if p != peer and p != opponent and not is_blocked.call(peer, p):
			effects.append(SocialRules._rpc(p, "s_emote", [peer, kind]))
	return effects
