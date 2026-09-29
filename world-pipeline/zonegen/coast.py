"""Land and sea from OpenStreetMap's coastline.

OSM draws the coast as `natural=coastline` ways with the land on their left.
Chained together and clipped to the zone square, the pieces are closed along
the zone edge (walking it counter-clockwise, which keeps the land on the
left) into land polygons; everything else in the square is sea.

The shore is classified from nearby OSM features: beaches where a
`natural=beach|sand|shingle` area touches it, a quay around ferry piers and
`man_made=quay`, rocks (riprap) elsewhere, which is what most of Istanbul's
Asian shore is.

zone.json "coast":
  {"sea_level": -1.6,                  # Godot y of the sea surface
   "land": [[[e, n], ...], ...],        # CCW land polygons, clipped to the zone
   "shore": [{"kind": "quay|rocks|beach", "points": [[e, n], ...]}, ...],
   "piers": [{"name": "...", "points": [[e, n], ...], "closed": true}]}
"""
from __future__ import annotations

import math
from typing import Dict, List, Optional, Sequence, Tuple

from . import geo
from .osm import OsmData

Point = geo.Point

# Height of the land's edge above the sea (metres): Kadıköy's quays and the
# top of the Moda riprap stand about this high.
SHORE_HEIGHT_M = 1.6
QUAY_RADIUS = 110.0
BEACH_RADIUS = 14.0
ROCK_RADIUS = 12.0
MASK_CELL = 2.0


def _chain(ways: List[List[Point]]) -> List[List[Point]]:
    """Join coastline ways sharing end points into longer chains."""
    pending = [list(w) for w in ways if len(w) >= 2]
    chains: List[List[Point]] = []

    def key(p: Point) -> Tuple[int, int]:
        return (round(p[0] * 20), round(p[1] * 20))

    while pending:
        cur = pending.pop()
        grown = True
        while grown:
            grown = False
            for i, w in enumerate(pending):
                if key(w[0]) == key(cur[-1]):
                    cur += w[1:]
                elif key(w[-1]) == key(cur[0]):
                    cur = w[:-1] + cur
                else:
                    continue
                pending.pop(i)
                grown = True
                break
        chains.append(cur)
    return chains


def _perimeter_t(p: Point, h: float) -> float:
    """Position along the zone edge, counter-clockwise from the south-west corner."""
    x, y = p
    s = 2 * h
    eps = 1e-6
    if abs(y + h) < eps:
        return x + h
    if abs(x - h) < eps:
        return s + (y + h)
    if abs(y - h) < eps:
        return 2 * s + (h - x)
    return 3 * s + (h - y)


def _corner_after(t: float, h: float) -> List[Tuple[float, Point]]:
    s = 2 * h
    return [(s, (h, -h)), (2 * s, (h, h)), (3 * s, (-h, h)), (4 * s, (-h, -h))]


def _snap_to_edge(p: Point, h: float) -> Point:
    """Push an end point that stops inside the zone straight out to its nearest edge."""
    x, y = p
    d = {"w": x + h, "e": h - x, "s": y + h, "n": h - y}
    side = min(d, key=d.get)
    return {"w": (-h, y), "e": (h, y), "s": (x, -h), "n": (x, h)}[side]


def land_polygons(chains: List[List[Point]], h: float, warnings: List[str]) -> Tuple[List[List[Point]], List[List[Point]]]:
    """(land polygons, shore polylines) inside the square [-h, h]^2."""
    pieces: List[List[Point]] = []
    islands: List[List[Point]] = []
    for chain in chains:
        closed = len(chain) >= 4 and math.hypot(chain[0][0] - chain[-1][0], chain[0][1] - chain[-1][1]) < 0.05
        inside = all(-h < p[0] < h and -h < p[1] < h for p in chain)
        if closed and inside:
            islands.append(geo.ensure_ccw(geo.clean_ring(chain)))
            continue
        for piece in geo.clip_polyline(chain, -h, -h, h, h):
            pieces.append(piece)
    # Pieces must start and end on the zone edge; data that stops short is
    # extended to the nearest edge (and reported).
    for piece in pieces:
        for idx in (0, -1):
            p = piece[idx]
            if -h + 1e-6 < p[0] < h - 1e-6 and -h + 1e-6 < p[1] < h - 1e-6:
                warnings.append(f"coastline ends inside the zone at ({p[0]:.0f}, {p[1]:.0f}); extended to the edge")
                q = _snap_to_edge(p, h)
                if idx == 0:
                    piece.insert(0, q)
                else:
                    piece.append(q)
    shore = [list(p) for p in pieces] + [ring + [ring[0]] for ring in islands]
    polys: List[List[Point]] = []
    if pieces:
        starts = sorted(((_perimeter_t(p[0], h), i) for i, p in enumerate(pieces)))
        used = [False] * len(pieces)
        perim = 8 * h
        for first in range(len(pieces)):
            if used[first]:
                continue
            ring: List[Point] = []
            cur = first
            for _ in range(len(pieces) + 1):
                used[cur] = True
                ring += pieces[cur]
                t_exit = _perimeter_t(pieces[cur][-1], h)
                # Next entry counter-clockwise from the exit.
                best = None
                for t_start, i in starts:
                    d = (t_start - t_exit) % perim
                    if best is None or d < best[0]:
                        best = (d, i)
                d_next, nxt = best
                # Corners passed on the way there.
                for t_c, corner in sorted(_corner_after(t_exit, h), key=lambda c: (c[0] - t_exit) % perim):
                    if 1e-6 < (t_c - t_exit) % perim < d_next - 1e-6:
                        ring.append(corner)
                if nxt == first:
                    break
                cur = nxt
            ring = geo.clean_ring(ring)
            if len(ring) >= 3 and abs(geo.signed_area(ring)) > 1.0:
                polys.append(ring)
    polys += islands
    return polys, shore


class LandMask:
    """Rasterised land polygons (2 m cells) for fast land/sea tests."""

    def __init__(self, polys: List[List[Point]], h: float, cell: float = MASK_CELL):
        self.h = h
        self.cell = cell
        self.n = int(math.ceil(2 * h / cell))
        self.rows: List[bytearray] = []
        edges = []
        for poly in polys:
            for i in range(len(poly)):
                edges.append((poly[i], poly[(i + 1) % len(poly)]))
        for j in range(self.n):
            y = -h + (j + 0.5) * cell
            xs = []
            for a, b in edges:
                if (a[1] > y) != (b[1] > y):
                    xs.append(a[0] + (y - a[1]) * (b[0] - a[0]) / (b[1] - a[1]))
            xs.sort()
            row = bytearray(self.n)
            for k in range(0, len(xs) - 1, 2):
                i0 = max(0, int(math.ceil((xs[k] + h) / cell - 0.5)))
                i1 = min(self.n - 1, int(math.floor((xs[k + 1] + h) / cell - 0.5)))
                for i in range(i0, i1 + 1):
                    row[i] = 1
            self.rows.append(row)

    def is_land(self, p: Point) -> bool:
        i = int((p[0] + self.h) / self.cell)
        j = int((p[1] + self.h) / self.cell)
        if i < 0 or j < 0 or i >= self.n or j >= self.n:
            return True  # outside the zone: not our sea
        return bool(self.rows[j][i])

    def near_land(self, p: Point, radius: float) -> bool:
        if self.is_land(p):
            return True
        for k in range(12):
            a = k * math.pi / 6
            for r in (radius / 2, radius):
                if self.is_land((p[0] + math.cos(a) * r, p[1] + math.sin(a) * r)):
                    return True
        return False

    def shore_distance_ok(self, p: Point, clearance: float) -> bool:
        """True if p is on land and at least `clearance` metres from the sea."""
        if not self.is_land(p):
            return False
        for k in range(8):
            a = k * math.pi / 4
            if not self.is_land((p[0] + math.cos(a) * clearance, p[1] + math.sin(a) * clearance)):
                return False
        return True


def clip_polyline_to_land(points: Sequence[Point], mask: LandMask, step: float = 1.0) -> List[List[Point]]:
    """Pieces of a polyline that run over land (tested every `step` metres)."""
    samples: List[Tuple[Point, bool]] = []  # (point, is an original vertex)
    for i in range(len(points) - 1):
        a, b = points[i], points[i + 1]
        n = max(1, int(math.ceil(math.hypot(b[0] - a[0], b[1] - a[1]) / step)))
        for k in range(n):
            samples.append(((a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n), k == 0))
    samples.append((points[-1], True))
    pieces: List[List[Point]] = []
    run: List[Tuple[Point, bool]] = []
    for sample in samples + [None]:
        if sample is not None and mask.is_land(sample[0]):
            run.append(sample)
            continue
        if len(run) >= 2:
            pts = [run[0][0]] + [q for q, vertex in run[1:-1] if vertex] + [run[-1][0]]
            if geo.polyline_length(pts) >= 1.0:
                pieces.append(pts)
        run = []
    return pieces


def _segments_near(p: Point, lines: List[List[Point]], radius: float) -> bool:
    for line in lines:
        for i in range(len(line) - 1):
            if geo.distance_point_segment(p, line[i], line[i + 1]) < radius:
                return True
    return False


def classify_shore(shore: List[List[Point]], osm: OsmData, proj: geo.LocalProjection) -> List[Dict]:
    """Splits the shore into runs of quay, beach and rocks."""
    beaches: List[List[Point]] = []
    rocks: List[List[Point]] = []
    quays: List[List[Point]] = []
    ferry: List[Point] = []
    for way in osm.ways:
        t = way.tags
        pts = [proj.to_local(lat, lon) for lat, lon in way.coords]
        if t.get("natural") in ("beach", "sand", "shingle"):
            beaches.append(pts)
        elif t.get("natural") == "bare_rock" or t.get("man_made") in ("breakwater", "groyne"):
            rocks.append(pts)
        elif t.get("man_made") in ("pier", "quay") or t.get("amenity") == "ferry_terminal":
            quays.append(pts)
    for node in osm.nodes:
        if node.tags.get("amenity") == "ferry_terminal":
            ferry.append(proj.to_local(node.lat, node.lon))

    def kind_at(p: Point) -> str:
        for poly in beaches:
            if len(poly) >= 4 and geo.point_in_polygon(p, poly):
                return "beach"
        if _segments_near(p, beaches, BEACH_RADIUS):
            return "beach"
        if _segments_near(p, rocks, ROCK_RADIUS):
            return "rocks"
        if _segments_near(p, quays, QUAY_RADIUS) or any(math.hypot(p[0] - f[0], p[1] - f[1]) < QUAY_RADIUS for f in ferry):
            return "quay"
        return "rocks"

    runs: List[Dict] = []
    for line in shore:
        pts = [line[0]]
        # Densify so a long straight edge can change kind half way.
        for i in range(len(line) - 1):
            a, b = line[i], line[i + 1]
            n = max(1, int(math.ceil(math.hypot(b[0] - a[0], b[1] - a[1]) / 10.0)))
            for k in range(1, n + 1):
                pts.append((a[0] + (b[0] - a[0]) * k / n, a[1] + (b[1] - a[1]) * k / n))
        current: Optional[Dict] = None
        for i in range(len(pts) - 1):
            mid = ((pts[i][0] + pts[i + 1][0]) / 2, (pts[i][1] + pts[i + 1][1]) / 2)
            kind = kind_at(mid)
            if current is None or current["kind"] != kind:
                current = {"kind": kind, "points": [pts[i]]}
                runs.append(current)
            current["points"].append(pts[i + 1])
    # Drop the densified collinear points again.
    for run in runs:
        simplified = [run["points"][0]]
        for i in range(1, len(run["points"]) - 1):
            a, b, c = simplified[-1], run["points"][i], run["points"][i + 1]
            cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
            if abs(cross) > 0.05 or math.hypot(b[0] - a[0], b[1] - a[1]) > 60.0:
                simplified.append(b)
        simplified.append(run["points"][-1])
        run["points"] = [[round(p[0], 2), round(p[1], 2)] for p in simplified]
    return runs


def piers(osm: OsmData, proj: geo.LocalProjection, h: float) -> List[Dict]:
    out = []
    for way in osm.ways:
        if way.tags.get("man_made") != "pier":
            continue
        pts = [proj.to_local(lat, lon) for lat, lon in way.coords]
        if way.closed:
            ring = geo.clip_polygon_rect(geo.clean_ring(pts), -h, -h, h, h)
            ring = geo.clean_ring(ring)
            if len(ring) >= 3 and abs(geo.signed_area(ring)) > 4.0:
                entry = {"id": f"w{way.id}", "closed": True, "points": [[round(p[0], 2), round(p[1], 2)] for p in geo.ensure_ccw(ring)]}
            else:
                continue
        else:
            parts = geo.clip_polyline(pts, -h, -h, h, h)
            if not parts:
                continue
            width = 3.0
            try:
                width = float(way.tags.get("width", "3").split()[0])
            except ValueError:
                pass
            entry = {"id": f"w{way.id}", "closed": False, "width": max(1.5, min(width, 12.0)),
                     "points": [[round(p[0], 2), round(p[1], 2)] for p in parts[0]]}
        if way.tags.get("name"):
            entry["name"] = way.tags["name"]
        out.append(entry)
    return out


def ferry_terminals(osm: OsmData, proj: geo.LocalProjection, h: float) -> List[Dict]:
    out = []
    for node in osm.nodes:
        if node.tags.get("amenity") == "ferry_terminal":
            p = proj.to_local(node.lat, node.lon)
            if abs(p[0]) <= h and abs(p[1]) <= h:
                out.append({"name": node.tags.get("name", ""), "e": round(p[0], 2), "n": round(p[1], 2)})
    return out


def build_coast(osm: OsmData, proj: geo.LocalProjection, size_m: float, warnings: List[str]) -> Optional[dict]:
    """Coast block for zone.json, or None if the zone has no coastline."""
    h = size_m / 2.0
    ways = [[proj.to_local(lat, lon) for lat, lon in w.coords] for w in osm.ways if w.tags.get("natural") == "coastline"]
    if not ways:
        return None
    chains = _chain(ways)
    land, shore = land_polygons(chains, h, warnings)
    if not shore:
        return None
    return {
        "sea_level": 0.0,  # filled in once the terrain's base height is known
        "shore_height_m": SHORE_HEIGHT_M,
        "land": [[[round(p[0], 2), round(p[1], 2)] for p in poly] for poly in land],
        "shore": classify_shore(shore, osm, proj),
        "piers": piers(osm, proj, h),
        "ferry_terminals": ferry_terminals(osm, proj, h),
    }
