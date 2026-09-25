class_name RoutePlanner
extends RefCounted
## Door-to-door journeys: walk only, or walk - tram - walk using the exact
## timetable (the next vehicle that can actually be caught, not an average).
##
## A plan is {total, walk_total, arrive, legs, goal}; each leg is either
## {type: "walk", points, metres, seconds} or
## {type: "tram", line, dir, from, to, vehicle, board_at, depart, arrive, points}.
## Times are absolute server seconds; points are local EN.

const TRAM_ADVANTAGE := 0.85  # take the tram only if it is clearly faster
const MISS_MARGIN := 4.0  # arrive this many seconds before departure to count


static func plan(graph: RoadGraph, transit: TransitNetwork, start: Vector2, goal: Vector2,
		now: float, walk_speed: float) -> Dictionary:
	var from_start := graph.search(start)
	var from_goal := graph.search(goal)
	var walk_path := graph.path_to(from_start, goal)
	var walk_m := RoadGraph.length_of(walk_path)
	var walk_s := walk_m / walk_speed
	var best := {
		"total": walk_s, "walk_total": walk_s, "arrive": now + walk_s, "goal": goal,
		"legs": [{"type": "walk", "points": walk_path, "metres": walk_m, "seconds": walk_s}],
	}
	var best_tram := {}
	for line: TransitNetwork.TransitLine in transit.lines:
		for i in line.stops.size():
			if not line.stops[i].in_zone:
				continue
			for dir in ([1] if line.loop else [1, -1]):
				var targets: Array = line.reachable(i, dir)
				if targets.is_empty():
					continue
				var board: Vector2 = line.platform(i, dir)
				var to_stop := graph.cost_to(from_start, board) / walk_speed
				var dep := line.departure_after(i, dir, now + to_stop + MISS_MARGIN)
				if dep.is_empty():
					continue
				for j in targets:
					var alight: Vector2 = line.platform(j, dir)
					var arrive := float(dep.depart) + line.ride_time(i, j, dir)
					var total := arrive + graph.cost_to(from_goal, alight) / walk_speed - now
					if best_tram.is_empty() or total < float(best_tram.total):
						best_tram = {"total": total, "line": line, "from": i, "to": j, "dir": dir,
							"dep": dep, "arrive": arrive, "board": board, "alight": alight}
	if best_tram.is_empty() or float(best_tram.total) > walk_s * TRAM_ADVANTAGE:
		return best
	var line: TransitNetwork.TransitLine = best_tram.line
	var leg1 := graph.path_to(from_start, best_tram.board)
	var from_alight := graph.search(best_tram.alight)
	var leg3 := graph.path_to(from_alight, goal)
	var m1 := RoadGraph.length_of(leg1)
	var m3 := RoadGraph.length_of(leg3)
	return {
		"total": best_tram.total, "walk_total": walk_s, "goal": goal,
		"arrive": now + float(best_tram.total),
		"legs": [
			{"type": "walk", "points": leg1, "metres": m1, "seconds": m1 / walk_speed},
			{"type": "tram", "line": line.index, "dir": best_tram.dir, "from": best_tram.from,
				"to": best_tram.to, "vehicle": best_tram.dep.vehicle,
				"board_at": float(best_tram.dep.arrive), "depart": float(best_tram.dep.depart),
				"arrive": best_tram.arrive,
				"points": line.ride_path(best_tram.from, best_tram.to, best_tram.dir)},
			{"type": "walk", "points": leg3, "metres": m3, "seconds": m3 / walk_speed},
		],
	}


static func describe_seconds(s: float) -> String:
	var total := maxi(0, roundi(s))
	if total < 60:
		return "%d sn" % total
	return "%d dk %d sn" % [total / 60, total % 60] if total < 600 else "%d dk" % (total / 60)
