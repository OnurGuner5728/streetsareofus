"""Tram network for a zone.

Real lines come from OSM route relations with their full geometry (also the
part outside the zone), so loop lengths, stop order and timetables stay real.
Real coverage of a 512 m cell is sparse, so extra lines are generated on the
drivable street graph until nearly every building has a stop within walking
distance. Generated lines are marked source="generated" and the game labels
them as simulation lines.
"""
from __future__ import annotations

import heapq
import math
import re
from typing import Dict, List, Optional, Tuple

from . import geo
from .osm import OsmData

CAR_KINDS = {"primary", "secondary", "tertiary", "unclassified", "residential", "living_street"}
LINE_COLORS = ["#1f6fd1", "#8e44ad", "#e67e22", "#c0392b"]
STOP_SPACING = 230.0
COVERAGE_RADIUS = 110.0  # about 45 s on foot at game walking speed
MIN_LINE_LENGTH = 320.0
MAX_LINE_LENGTH = 1200.0
LANDMARK_WORDS = ("opera", "kültür", "camii", "cami", "kilise", "park", "meydan", "çarşı", "pasaj",
                  "han", "okul", "lise", "hastane", "çeşme", "sinema", "tiyatro", "müze", "kütüphane",
                  "merkez", "vergi dairesi", "belediye", "istasyon")

Point = Tuple[float, float]


# --- small geometry helpers ----------------------------------------------------

def _cumulative(path: List[Point]) -> List[float]:
    out = [0.0]
    for i in range(len(path) - 1):
        out.append(out[-1] + math.hypot(path[i + 1][0] - path[i][0], path[i + 1][1] - path[i][1]))
    return out


def project_onto_path(path: List[Point], p: Point) -> Tuple[float, float]:
    """(arc length of the closest point, distance to it)."""
    cum = _cumulative(path)
    best = (0.0, float("inf"))
    for i in range(len(path) - 1):
        ax, ay = path[i]
        bx, by = path[i + 1]
        dx, dy = bx - ax, by - ay
        seg = dx * dx + dy * dy
        t = 0.0 if seg == 0 else max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / seg))
        qx, qy = ax + t * dx, ay + t * dy
        d = math.hypot(p[0] - qx, p[1] - qy)
        if d < best[1]:
            best = (cum[i] + t * math.sqrt(seg), d)
    return best


def short_line_name(name: str) -> str:
    name = name.split(":", 1)[-1]
    for noise in ("Nostaljik Tramvay Hattı", "Tramvay Hattı", "Nostalgic Tram Line"):
        name = name.replace(noise, "")
    return name.replace("↔", "–").strip()


def _inside(p: Point, half: float) -> bool:
    return abs(p[0]) <= half and abs(p[1]) <= half


def _round(points) -> List[List[float]]:
    return [[round(p[0], 2), round(p[1], 2)] for p in points]


# --- naming -------------------------------------------------------------------

def short_street(name: str) -> str:
    return re.sub(r"\s+(Caddesi|Sokağı|Sokak|Bulvarı|Çıkmazı)$", "", name).strip()


def stop_name(p: Point, zone: dict) -> str:
    best: Optional[Tuple[float, str]] = None
    for b in zone["buildings"]:
        name = b.get("name")
        if not name or not (b["kind"] in ("civic", "religious") or any(w in name.lower() for w in LANDMARK_WORDS)):
            continue
        c = geo.centroid([tuple(q) for q in b["footprint"]])
        d = math.hypot(c[0] - p[0], c[1] - p[1])
        if d < 70 and (best is None or d < best[0]):
            best = (d, name)
    if best:
        return best[1]
    best = None
    for road in zone["roads"]:
        name = road.get("name")
        if not name:
            continue
        pts = road["points"]
        for i in range(len(pts) - 1):
            d = geo.distance_point_segment(p, tuple(pts[i]), tuple(pts[i + 1]))
            if d < 30 and (best is None or d < best[0]):
                best = (d, short_street(name))
    return best[1] if best else "Durak"


# --- real lines from OSM ------------------------------------------------------

def _chain(ways: List[List[Tuple[float, float]]]) -> List[Tuple[float, float]]:
    if not ways:
        return []
    path = list(ways[0])
    if len(ways) > 1 and path[0] in (ways[1][0], ways[1][-1]) and path[-1] not in (ways[1][0], ways[1][-1]):
        path.reverse()
    for w in ways[1:]:
        if path[-1] == w[0]:
            path += w[1:]
        elif path[-1] == w[-1]:
            path += list(reversed(w))[1:]
        elif path[0] == w[-1]:  # first way was the wrong way round
            path = list(reversed(path)) + list(reversed(w))[1:]
        else:
            path += w  # gap in the relation; keep going
    return path


def osm_lines(osm: OsmData, proj: geo.LocalProjection, half: float) -> List[dict]:
    tram_ways = {w.id for w in osm.ways if w.tags.get("railway") in ("tram", "light_rail")}
    names = {n.id: n.tags for n in osm.nodes}
    names.update(osm.extra_node_tags)
    lines = []
    for rel in osm.routes:
        ways = [m for m in rel.members if m.type == "way" and m.role in ("", "forward", "backward")]
        # Relations for proposed or unbuilt lines reference no existing track.
        if not any(m.ref in tram_ways for m in ways):
            continue
        latlon = _chain([m.coords for m in ways])
        path = geo.clean_ring([proj.to_local(lat, lon) for lat, lon in latlon], 0.5) \
            if latlon[0] == latlon[-1] else [proj.to_local(lat, lon) for lat, lon in latlon]
        loop = rel.tags.get("roundtrip") == "yes" or latlon[0] == latlon[-1]
        if loop and path[0] != path[-1]:
            path = path + [path[0]]
        stops = []
        for m in rel.members:
            if m.type != "node" or not m.role.startswith("stop"):
                continue
            p = proj.to_local(*m.coords[0])
            s, _ = project_onto_path(path, p)
            tags = names.get(m.ref, {})
            stops.append({"osm_id": m.ref, "name": tags.get("name", ""), "s": s, "e": p[0], "n": p[1]})
        if len(stops) < 2:
            continue
        length = _cumulative(path)[-1]
        # Member order is travel order; if arc lengths mostly run backwards,
        # the chained path is reversed relative to the stops.
        backwards = sum(1 for a, b in zip(stops, stops[1:]) if (b["s"] - a["s"]) % length > length / 2)
        if backwards > len(stops) / 2:
            path.reverse()
            for st in stops:
                st["s"] = project_onto_path(path, (st["e"], st["n"]))[0]
        if loop:
            stops.sort(key=lambda st: st["s"])
        for i, st in enumerate(stops):
            st["id"] = f"{rel.tags.get('ref', rel.id)}-{i}"
            st["in_zone"] = _inside((st["e"], st["n"]), half - 5.0)
            st["name"] = st["name"] or f"Durak {i + 1}"
            st["s"] = round(st["s"], 2)
            st["e"], st["n"] = round(st["e"], 2), round(st["n"], 2)
        ref = rel.tags.get("ref", str(rel.id))
        nostalgic = "nostalji" in rel.tags.get("name", "").lower() or "nostalgic" in rel.tags.get("name:en", "").lower()
        lines.append({
            "id": ref, "ref": ref,
            "name": rel.tags.get("name", ref),
            "short_name": short_line_name(rel.tags.get("name", ref)),
            "color": rel.tags.get("colour", "#a86528"),
            "source": "osm", "osm_relation": rel.id,
            "kind": "loop" if loop else "shuttle",
            "path": _round(path), "length": round(length, 2),
            "stops": stops,
            "speed": 5.0 if nostalgic else 7.0, "accel": 0.8 if nostalgic else 1.0,
            "dwell": 15.0, "layover": 30.0,
            "vehicles": 2 if nostalgic else 3,
            "vehicle_type": "nostalgic" if nostalgic else "modern",
            "track_offset": 0.0 if loop else 1.6,
        })
    return lines


# --- generated lines ----------------------------------------------------------

def _graph(zone: dict) -> Tuple[Dict[Tuple[int, int], Point], Dict[Tuple[int, int], List[Tuple[Tuple[int, int], float]]]]:
    nodes: Dict[Tuple[int, int], Point] = {}
    adj: Dict[Tuple[int, int], List] = {}
    for road in zone["roads"]:
        if road["kind"] not in CAR_KINDS:
            continue
        keys = []
        for p in road["points"]:
            k = (round(p[0] * 10), round(p[1] * 10))
            nodes[k] = (p[0], p[1])
            keys.append(k)
        for a, b in zip(keys, keys[1:]):
            if a == b:
                continue
            d = math.hypot(nodes[a][0] - nodes[b][0], nodes[a][1] - nodes[b][1])
            adj.setdefault(a, []).append((b, d))
            adj.setdefault(b, []).append((a, d))
    return nodes, adj


def _dijkstra(adj, source):
    dist = {source: 0.0}
    prev = {}
    heap = [(0.0, source)]
    while heap:
        d, u = heapq.heappop(heap)
        if d > dist[u]:
            continue
        for v, w in adj.get(u, []):
            nd = d + w
            if nd < dist.get(v, float("inf")):
                dist[v] = nd
                prev[v] = u
                heapq.heappush(heap, (nd, v))
    return dist, prev


def _place_stops(path_keys, nodes) -> List[int]:
    """Indices into the path where stops go: ends plus roughly every STOP_SPACING m."""
    idx = [0]
    since = 0.0
    for i in range(1, len(path_keys)):
        a, b = nodes[path_keys[i - 1]], nodes[path_keys[i]]
        since += math.hypot(b[0] - a[0], b[1] - a[1])
        if since >= STOP_SPACING:
            idx.append(i)
            since = 0.0
    last = len(path_keys) - 1
    if idx[-1] != last:
        if since < 110 and len(idx) > 1:
            idx[-1] = last
        else:
            idx.append(last)
    return idx


def generated_lines(zone: dict, existing: List[dict], max_lines: int = 4) -> List[dict]:
    nodes, adj = _graph(zone)
    if not adj:
        return []
    # Largest connected component only.
    seen, best_comp = set(), []
    for k in adj:
        if k in seen:
            continue
        comp, stack = [], [k]
        seen.add(k)
        while stack:
            u = stack.pop()
            comp.append(u)
            for v, _ in adj[u]:
                if v not in seen:
                    seen.add(v)
                    stack.append(v)
        if len(comp) > len(best_comp):
            best_comp = comp
    comp = set(best_comp)
    half = zone["size_m"] / 2.0
    termini = [k for k in comp if len(adj[k]) == 1 or max(abs(nodes[k][0]), abs(nodes[k][1])) > half - 30]
    if len(termini) < 2:
        return []

    demand = [geo.centroid([tuple(q) for q in b["footprint"]]) for b in zone["buildings"]]
    covered = [False] * len(demand)
    for line in existing:
        for st in line["stops"]:
            if st.get("in_zone"):
                for i, c in enumerate(demand):
                    if math.hypot(c[0] - st["e"], c[1] - st["n"]) < COVERAGE_RADIUS:
                        covered[i] = True
    near_cache: Dict[Tuple[int, int], List[int]] = {}

    def near(k):
        if k not in near_cache:
            p = nodes[k]
            near_cache[k] = [i for i, c in enumerate(demand) if math.hypot(c[0] - p[0], c[1] - p[1]) < COVERAGE_RADIUS]
        return near_cache[k]

    candidates = []
    for a in termini:
        dist, prev = _dijkstra(adj, a)
        for b in termini:
            if b <= a or b not in dist or not (MIN_LINE_LENGTH <= dist[b] <= MAX_LINE_LENGTH):
                continue
            path = [b]
            while path[-1] != a:
                path.append(prev[path[-1]])
            path.reverse()
            candidates.append((dist[b], path))

    used_edges = set()
    lines = []
    for n in range(max_lines):
        best = None
        for length, path in candidates:
            stops = _place_stops(path, nodes)
            gain = len({i for s in stops for i in near(path[s]) if not covered[i]})
            edges = {frozenset(e) for e in zip(path, path[1:])}
            overlap = len(edges & used_edges) / max(1, len(edges))
            score = gain * (1.0 - 0.7 * overlap)
            if best is None or score > best[0]:
                best = (score, length, path, stops)
        if best is None or best[0] < 0.03 * len(demand):
            break
        _, length, path, stop_idx = best
        for s in stop_idx:
            for i in near(path[s]):
                covered[i] = True
        used_edges |= {frozenset(e) for e in zip(path, path[1:])}
        pts = [nodes[k] for k in path]
        cum = _cumulative(pts)
        ref = f"K{n + 1}"
        stops, used_names = [], set()
        arcs = [cum[s] for s in stop_idx]
        # A terminus on the zone edge would sit in the boundary wall; pull
        # it back along the line so it is a usable stop.
        if max(abs(pts[0][0]), abs(pts[0][1])) > half - 15.0:
            arcs[0] = min(20.0, cum[-1] / 4)
        if max(abs(pts[-1][0]), abs(pts[-1][1])) > half - 15.0:
            arcs[-1] = max(cum[-1] - 20.0, cum[-1] * 3 / 4)
        for j, s in enumerate(arcs):
            p, _ = _point_and_tangent(pts, cum, s)
            name = stop_name(p, zone)
            if name in used_names:
                name = f"{name} {sum(1 for u in used_names if u.startswith(name)) + 1}"
            used_names.add(name)
            stops.append({"id": f"{ref}-{j}", "name": name, "s": round(s, 2),
                          "e": round(p[0], 2), "n": round(p[1], 2), "in_zone": True})
        vehicles = max(1, min(4, round((2 * cum[-1] / 7.0 + 2 * 25 + len(stops) * 14 * 2) / 150)))
        lines.append({
            "id": ref, "ref": ref,
            "name": f"{ref} {stops[0]['name']} – {stops[-1]['name']}",
            "short_name": f"{stops[0]['name']} – {stops[-1]['name']}",
            "color": LINE_COLORS[n % len(LINE_COLORS)],
            "source": "generated", "kind": "shuttle",
            "path": _round(pts), "length": round(cum[-1], 2),
            "stops": stops,
            "speed": 7.0, "accel": 1.0, "dwell": 14.0, "layover": 25.0,
            "vehicles": vehicles, "vehicle_type": "modern", "track_offset": 1.6,
        })
    uncovered = covered.count(False)
    print(f"  transit: {len(lines)} generated lines, {len(demand) - uncovered}/{len(demand)} buildings "
          f"within {COVERAGE_RADIUS:.0f} m of a stop")
    return lines


def _point_and_tangent(path: List[Point], cum: List[float], s: float) -> Tuple[Point, Point]:
    s = max(0.0, min(cum[-1], s))
    for i in range(len(path) - 1):
        if cum[i + 1] >= s:
            seg = cum[i + 1] - cum[i]
            t = (s - cum[i]) / seg if seg > 0 else 0.0
            a, b = path[i], path[i + 1]
            d = math.hypot(b[0] - a[0], b[1] - a[1]) or 1.0
            return (a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t), ((b[0] - a[0]) / d, (b[1] - a[1]) / d)
    return path[-1], (1.0, 0.0)


def _clearance(p: Point, direction: Point, footprints, limit: float = 8.0) -> float:
    """Metres from p along direction to the first building wall (limit if none)."""
    end = (p[0] + direction[0] * limit, p[1] + direction[1] * limit)
    best = limit
    for x0, y0, x1, y1, poly in footprints:
        if max(p[0], end[0]) < x0 or min(p[0], end[0]) > x1 or max(p[1], end[1]) < y0 or min(p[1], end[1]) > y1:
            continue
        for i in range(len(poly)):
            a, b = poly[i], poly[(i + 1) % len(poly)]
            hit = _segment_hit(p, end, a, b)
            if hit is not None:
                best = min(best, hit * limit)
    return best


def _segment_hit(p, q, a, b):
    rx, ry = q[0] - p[0], q[1] - p[1]
    sx, sy = b[0] - a[0], b[1] - a[1]
    den = rx * sy - ry * sx
    if abs(den) < 1e-9:
        return None
    t = ((a[0] - p[0]) * sy - (a[1] - p[1]) * sx) / den
    u = ((a[0] - p[0]) * ry - (a[1] - p[1]) * rx) / den
    return t if 0.0 <= t <= 1.0 and 0.0 <= u <= 1.0 else None


def add_platforms(lines: List[dict], zone: dict) -> None:
    """Platform distance from the line centre on each side of every stop,
    kept clear of buildings so riders never step off into a wall."""
    footprints = []
    for b in zone["buildings"]:
        if b.get("min_height", 0.0) > 2.2:
            continue
        pts = [tuple(q) for q in b["footprint"]]
        xs, ys = [q[0] for q in pts], [q[1] for q in pts]
        footprints.append((min(xs), min(ys), max(xs), max(ys), pts))
    for line in lines:
        path = [tuple(p) for p in line["path"]]
        cum = _cumulative(path)
        track = line["track_offset"]
        for st in line["stops"]:
            p, (tx, ty) = _point_and_tangent(path, cum, st["s"])
            out = {}
            for key, normal in (("r", (ty, -tx)), ("l", (-ty, tx))):
                room = _clearance(p, normal, footprints)
                out[key] = round(max(track + 1.0, min(track + 2.4, room - 0.9)), 2)
                out[key + "_room"] = round(room, 2)
            st["platform"] = out


def build_transit(osm: Optional[OsmData], proj: Optional[geo.LocalProjection], zone: dict) -> dict:
    half = zone["size_m"] / 2.0
    real = osm_lines(osm, proj, half) if osm is not None else []
    lines = real + generated_lines(zone, real)
    add_platforms(lines, zone)
    return {"lines": lines}
