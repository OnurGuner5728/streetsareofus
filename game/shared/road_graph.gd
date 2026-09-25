class_name RoadGraph
extends RefCounted
## Walking network built from the zone's walkable roads. OSM ways that meet
## share a node, so identical coordinates become the same graph vertex.
## Coordinates are local EN metres (Vector2(east, north)).

var nodes := PackedVector2Array()
var adj: Array = []  # node -> Array of [neighbour, metres]
var edges: Array = []  # [a, b]


static func from_zone(zone: ZoneData) -> RoadGraph:
	var g := RoadGraph.new()
	var index := {}
	for road in zone.roads:
		if not bool(road.get("walkable", true)):
			continue
		var prev := -1
		for p in road.points:
			var key := Vector2i(roundi(float(p[0]) * 10.0), roundi(float(p[1]) * 10.0))
			var id: int = index.get(key, -1)
			if id < 0:
				id = g.nodes.size()
				index[key] = id
				g.nodes.append(Vector2(float(p[0]), float(p[1])))
				g.adj.append([])
			if prev >= 0 and prev != id:
				var d := g.nodes[prev].distance_to(g.nodes[id])
				g.adj[prev].append([id, d])
				g.adj[id].append([prev, d])
				g.edges.append([prev, id])
			prev = id
	return g


## Closest point on the network: {edge, point, dist}.
func snap(p: Vector2) -> Dictionary:
	var best := {"edge": -1, "point": p, "dist": INF}
	for i in edges.size():
		var a := nodes[edges[i][0]]
		var b := nodes[edges[i][1]]
		var q := Geometry2D.get_closest_point_to_segment(p, a, b)
		var d := p.distance_to(q)
		if d < float(best.dist):
			best = {"edge": i, "point": q, "dist": d}
	return best


## Shortest walking distances from p to every node. The result also works as
## a "search" handle for cost_to() and path_to().
func search(p: Vector2) -> Dictionary:
	var s := snap(p)
	var n := nodes.size()
	var dist := PackedFloat64Array()
	dist.resize(n)
	dist.fill(INF)
	var prev := PackedInt32Array()
	prev.resize(n)
	prev.fill(-1)
	var heap := []
	if s.edge >= 0:
		var q: Vector2 = s.point
		for end in edges[s.edge]:
			var d := float(s.dist) + q.distance_to(nodes[end])
			if d < dist[end]:
				dist[end] = d
				_push(heap, [d, end])
	while not heap.is_empty():
		var top: Array = _pop(heap)
		var u: int = top[1]
		if float(top[0]) > dist[u]:
			continue
		for nb in adj[u]:
			var v: int = nb[0]
			var nd := dist[u] + float(nb[1])
			if nd < dist[v]:
				dist[v] = nd
				prev[v] = u
				_push(heap, [nd, v])
	return {"origin": p, "snap": s, "dist": dist, "prev": prev}


## Walking metres from a search origin to point q.
func cost_to(search_result: Dictionary, q: Vector2) -> float:
	return float(_best_end(search_result, q).cost)


## Walking route from a search origin to q, as EN points.
func path_to(search_result: Dictionary, q: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	var origin: Vector2 = search_result.origin
	var start_snap: Dictionary = search_result.snap
	var end := _best_end(search_result, q)
	out.append(origin)
	if end.direct:
		out.append(start_snap.point)
	else:
		var chain := PackedVector2Array()
		var cur: int = end.node
		var prev: PackedInt32Array = search_result.prev
		while cur >= 0:
			chain.append(nodes[cur])
			cur = prev[cur]
		chain.reverse()
		out.append(start_snap.point)
		out.append_array(chain)
	out.append(end.point)
	out = _dedupe(out)
	out.append(q)
	if out.size() > 2 and out[out.size() - 2].distance_to(q) < 0.2:
		out.remove_at(out.size() - 2)
	return out


func _best_end(search_result: Dictionary, q: Vector2) -> Dictionary:
	var s := snap(q)
	var best := {"cost": INF, "node": -1, "point": q, "direct": false}
	if s.edge < 0:
		return best
	var dist: PackedFloat64Array = search_result.dist
	var qp: Vector2 = s.point
	for end in edges[s.edge]:
		var c := dist[end] + qp.distance_to(nodes[end]) + float(s.dist)
		if c < float(best.cost):
			best = {"cost": c, "node": end, "point": qp, "direct": false}
	# Both points on the same street segment: walk straight along it.
	var start_snap: Dictionary = search_result.snap
	if start_snap.edge == s.edge:
		var direct := float(start_snap.dist) + (start_snap.point as Vector2).distance_to(qp) + float(s.dist)
		if direct <= float(best.cost):
			best = {"cost": direct, "node": -1, "point": qp, "direct": true}
	return best


static func _dedupe(points: PackedVector2Array) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in points:
		if out.is_empty() or out[out.size() - 1].distance_to(p) > 0.2:
			out.append(p)
	return out


static func length_of(points: PackedVector2Array) -> float:
	var total := 0.0
	for i in points.size() - 1:
		total += points[i].distance_to(points[i + 1])
	return total


# Binary min-heap of [priority, value].
static func _push(heap: Array, item: Array) -> void:
	heap.append(item)
	var i := heap.size() - 1
	while i > 0:
		var parent := (i - 1) / 2
		if float(heap[parent][0]) <= float(item[0]):
			break
		heap[i] = heap[parent]
		i = parent
	heap[i] = item


static func _pop(heap: Array) -> Array:
	var top: Array = heap[0]
	var last: Array = heap.pop_back()
	if heap.is_empty():
		return top
	var i := 0
	var n := heap.size()
	while true:
		var l := 2 * i + 1
		if l >= n:
			break
		var c := l
		if l + 1 < n and float(heap[l + 1][0]) < float(heap[l][0]):
			c = l + 1
		if float(heap[c][0]) >= float(last[0]):
			break
		heap[i] = heap[c]
		i = c
	heap[i] = last
	return top
