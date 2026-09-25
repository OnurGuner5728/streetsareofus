class_name SpawnPicker
extends RefCounted
## Chooses spawn points from the zone's precomputed walkable candidates.
## "random" ignores other players; "social" adds the plan's live
## active_player_proximity term so newcomers land where someone is around,
## without ever telling anyone where that someone is.

const SOCIAL_WEIGHT := 0.6
const MIN_GAP := 2.5

var points: Array = []
var rng := RandomNumberGenerator.new()
var zone: ZoneData


func _init(z: ZoneData) -> void:
	zone = z
	points = z.spawn_points
	rng.randomize()


func pick(mode: String, others: Array) -> Vector3:
	if points.is_empty():
		return Vector3(0, 0.05, 0)
	var social := mode == "social" and not others.is_empty()
	var samples := mini(points.size(), 40 if social else 12)
	var best := Vector3.ZERO
	var best_score := -INF
	for i in samples:
		var p: Dictionary = points[rng.randi() % points.size()]
		var pos := zone.ground(float(p.e), float(p.n), 0.05)
		var score := float(p.static_score) + rng.randf() * (0.1 if social else 0.35)
		if social:
			score += SOCIAL_WEIGHT * proximity_term(pos, others)
		for o in others:
			if pos.distance_to(o) < MIN_GAP:
				score -= 1.0
		if score > best_score:
			best_score = score
			best = pos
	return best


## 1.0 when another player is close enough to meet but not on top of you.
static func proximity_term(pos: Vector3, others: Array) -> float:
	var best := 0.0
	for o in others:
		var d := pos.distance_to(o)
		var v := 0.0
		if d < 15.0:
			v = d / 15.0
		elif d <= 120.0:
			v = 1.0
		elif d < 250.0:
			v = 1.0 - (d - 120.0) / 130.0
		best = maxf(best, v)
	return best
