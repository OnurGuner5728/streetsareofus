class_name SeksekRules
extends RefCounted
## Seksek (hopscotch) turns, free of networking like the other rule modules:
## methods return effects {"to", "rpc", "args"} and take plain data (a
## position, the grounded flag, the hop button) instead of reaching into the
## world, so the whole rule set is unit-testable.
##
## A turn starts on a grid's start strip with hop-walk on. After that the
## player must HOP (leave the ground and land) from square to square, one
## row at a time, in order. The server judges every landing:
##   - landing on a chalk line or off the grid ends the turn ("line"),
##   - landing on the wrong row, or back on the start strip, ends it ("wrong"),
##   - sliding to another square without ever leaving the ground ends it
##     ("walked"),
##   - dropping hop-walk ends it ("no_hop"), standing around too long ends it
##     ("timeout"), moving away or quitting ends it ("left").
## Hopping twice on the same square is allowed, it just earns nothing. The
## score is the number of rows reached; the last row completes the grid.
##
## Events go to the player only, through s_party(event):
##   seksek_start {grid, total}
##   seksek_hop   {score, total, square}
##   seksek_end   {reason, score, total, best}

## Seconds after a landing during which sliding onto a line is forgiven.
const SLIDE_GRACE := 0.3

var hop: Hopscotch
var turns := {}  # peer -> turn Dictionary
var best := {}  # peer -> best score of this session


func _init(grids: Hopscotch) -> void:
	hop = grids


func active() -> bool:
	return not turns.is_empty()


func in_turn(peer: int) -> bool:
	return turns.has(peer)


func total_rows() -> int:
	return Hopscotch.ROWS.size()


## "" when `peer` may start a turn here, else a notice code.
func start_problem(peer: int, pos: Vector3, hopping: bool) -> String:
	if turns.has(peer):
		return "seksek_busy"
	var xz := Vector2(pos.x, pos.z)
	var gi := hop.grid_at(xz)
	if gi < 0 or Hopscotch.locate(Hopscotch.to_local(hop.grids[gi], xz)) != Hopscotch.START:
		return "seksek_none"
	if not hopping:
		return "seksek_hop"
	return ""


func start(peer: int, pos: Vector3, hopping: bool, now: float) -> Array:
	var problem := start_problem(peer, pos, hopping)
	if problem != "":
		return [SocialRules._notice(peer, problem)]
	var gi := hop.grid_at(Vector2(pos.x, pos.z))
	turns[peer] = {"grid": gi, "row": -1, "last": Hopscotch.START, "air": false, "score": 0,
		"started": now, "since": now, "landed": now}
	return [_ev(peer, {"ev": "seksek_start", "grid": gi, "total": total_rows()})]


## Called every server tick for a player in a turn. pos: the player's feet;
## grounded: standing on something; hopping: the hop-walk button is down.
func update(peer: int, pos: Vector3, grounded: bool, hopping: bool, now: float) -> Array:
	var t: Dictionary = turns.get(peer, {})
	if t.is_empty():
		return []
	if now - float(t.started) > Protocol.SEKSEK_MAX_TIME or now - float(t.since) > Protocol.SEKSEK_IDLE_TIMEOUT:
		return _end(peer, "timeout")
	if not hopping:
		return _end(peer, "no_hop")
	if not grounded:
		t.air = true
		return []
	var grid: Dictionary = hop.grids[int(t.grid)]
	var loc := Hopscotch.locate(Hopscotch.to_local(grid, Vector2(pos.x, pos.z)))
	if not bool(t.air):
		# Still on the ground: nothing to judge unless we slid somewhere new.
		if loc == int(t.last):
			return []
		if loc > 0 or loc == Hopscotch.START:
			return _end(peer, "walked")
		if now - float(t.landed) > SLIDE_GRACE:
			return _end(peer, "line")
		return []
	# A landing.
	t.air = false
	t.landed = now
	if loc == Hopscotch.LINE or loc == Hopscotch.OUTSIDE:
		return _end(peer, "line")
	if loc == Hopscotch.START:
		return _end(peer, "wrong") if int(t.row) >= 0 else _landed(t, loc)
	var row := Hopscotch.row_of(loc)
	if row == int(t.row):
		return _landed(t, loc)
	if row != int(t.row) + 1:
		return _end(peer, "wrong")
	t.row = row
	t.score = row + 1
	t.since = now
	t.last = loc
	var effects := [_ev(peer, {"ev": "seksek_hop", "score": t.score, "total": total_rows(), "square": loc})]
	if row == total_rows() - 1:
		effects.append_array(_end(peer, "done"))
	return effects


func _landed(t: Dictionary, loc: int) -> Array:
	t.last = loc
	return []


## Ends the peer's turn without judging (quit, disconnect, moved away).
func cancel(peer: int, reason := "left") -> Array:
	return _end(peer, reason) if turns.has(peer) else []


func _end(peer: int, reason: String) -> Array:
	var t: Dictionary = turns.get(peer, {})
	if t.is_empty():
		return []
	turns.erase(peer)
	var score: int = t.score
	best[peer] = maxi(int(best.get(peer, 0)), score)
	return [_ev(peer, {"ev": "seksek_end", "reason": reason, "score": score, "total": total_rows(), "best": best[peer]})]


static func _ev(to: int, event: Dictionary) -> Dictionary:
	return SocialRules._rpc(to, "s_party", [event])
