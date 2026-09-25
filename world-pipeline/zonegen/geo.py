"""Coordinate and 2D geometry helpers for zone generation.

Local coordinates are metres in an east/north (EN) tangent plane centred on
the zone origin. The game converts EN to Godot space as Vector3(e, y, -n).
"""
from __future__ import annotations

import math
from typing import Iterable, List, Optional, Sequence, Tuple

Point = Tuple[float, float]


def meters_per_degree(lat_deg: float) -> Tuple[float, float]:
    """Return (metres per degree latitude, metres per degree longitude)."""
    phi = math.radians(lat_deg)
    m_lat = (111132.92 - 559.82 * math.cos(2 * phi)
             + 1.175 * math.cos(4 * phi) - 0.0023 * math.cos(6 * phi))
    m_lon = (111412.84 * math.cos(phi) - 93.5 * math.cos(3 * phi)
             + 0.118 * math.cos(5 * phi))
    return m_lat, m_lon


class LocalProjection:
    """Equirectangular projection around a zone origin.

    Accurate to a few centimetres over a 512 m cell, which is far below
    the precision of OSM geometry itself.
    """

    def __init__(self, lat0: float, lon0: float):
        self.lat0 = lat0
        self.lon0 = lon0
        self.m_lat, self.m_lon = meters_per_degree(lat0)

    def to_local(self, lat: float, lon: float) -> Point:
        return ((lon - self.lon0) * self.m_lon, (lat - self.lat0) * self.m_lat)

    def to_geo(self, e: float, n: float) -> Tuple[float, float]:
        return (self.lat0 + n / self.m_lat, self.lon0 + e / self.m_lon)

    def bbox(self, size_m: float) -> Tuple[float, float, float, float]:
        """(south, west, north, east) of a square cell of size_m."""
        half = size_m / 2.0
        south, west = self.to_geo(-half, -half)
        north, east = self.to_geo(half, half)
        return south, west, north, east


def signed_area(poly: Sequence[Point]) -> float:
    """Positive for counter-clockwise polygons in EN space."""
    total = 0.0
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        total += x1 * y2 - x2 * y1
    return total / 2.0


def ensure_ccw(poly: List[Point]) -> List[Point]:
    return poly if signed_area(poly) >= 0 else list(reversed(poly))


def centroid(poly: Sequence[Point]) -> Point:
    a = signed_area(poly)
    if abs(a) < 1e-9:
        xs = [p[0] for p in poly]
        ys = [p[1] for p in poly]
        return (sum(xs) / len(xs), sum(ys) / len(ys))
    cx = cy = 0.0
    for i in range(len(poly)):
        x1, y1 = poly[i]
        x2, y2 = poly[(i + 1) % len(poly)]
        cross = x1 * y2 - x2 * y1
        cx += (x1 + x2) * cross
        cy += (y1 + y2) * cross
    return (cx / (6 * a), cy / (6 * a))


def point_in_polygon(p: Point, poly: Sequence[Point]) -> bool:
    x, y = p
    inside = False
    j = len(poly) - 1
    for i in range(len(poly)):
        xi, yi = poly[i]
        xj, yj = poly[j]
        if (yi > y) != (yj > y):
            x_cross = (xj - xi) * (y - yi) / (yj - yi) + xi
            if x < x_cross:
                inside = not inside
        j = i
    return inside


def distance_point_segment(p: Point, a: Point, b: Point) -> float:
    ax, ay = a
    bx, by = b
    dx, dy = bx - ax, by - ay
    length_sq = dx * dx + dy * dy
    if length_sq == 0:
        return math.hypot(p[0] - ax, p[1] - ay)
    t = max(0.0, min(1.0, ((p[0] - ax) * dx + (p[1] - ay) * dy) / length_sq))
    return math.hypot(p[0] - (ax + t * dx), p[1] - (ay + t * dy))


def distance_to_polygon_edge(p: Point, poly: Sequence[Point]) -> float:
    return min(distance_point_segment(p, poly[i], poly[(i + 1) % len(poly)])
               for i in range(len(poly)))


def clean_ring(points: Iterable[Point], min_spacing: float = 0.25) -> List[Point]:
    """Drop the closing duplicate, near-duplicate and collinear vertices."""
    ring: List[Point] = []
    for p in points:
        if ring and math.hypot(p[0] - ring[-1][0], p[1] - ring[-1][1]) < min_spacing:
            continue
        ring.append(p)
    while len(ring) > 1 and math.hypot(ring[0][0] - ring[-1][0],
                                       ring[0][1] - ring[-1][1]) < min_spacing:
        ring.pop()
    changed = True
    while changed and len(ring) > 3:
        changed = False
        for i in range(len(ring)):
            a, b, c = ring[i - 1], ring[i], ring[(i + 1) % len(ring)]
            cross = (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0])
            if abs(cross) < 1e-3:
                del ring[i]
                changed = True
                break
    return ring


def clip_segment(a: Point, b: Point, xmin: float, ymin: float,
                 xmax: float, ymax: float) -> Optional[Tuple[Point, Point]]:
    """Liang-Barsky segment clipping against an axis-aligned rectangle."""
    x0, y0 = a
    dx, dy = b[0] - x0, b[1] - y0
    t0, t1 = 0.0, 1.0
    for p, q in ((-dx, x0 - xmin), (dx, xmax - x0), (-dy, y0 - ymin), (dy, ymax - y0)):
        if p == 0:
            if q < 0:
                return None
            continue
        r = q / p
        if p < 0:
            if r > t1:
                return None
            t0 = max(t0, r)
        else:
            if r < t0:
                return None
            t1 = min(t1, r)
    return ((x0 + t0 * dx, y0 + t0 * dy), (x0 + t1 * dx, y0 + t1 * dy))


def clip_polyline(points: Sequence[Point], xmin: float, ymin: float,
                  xmax: float, ymax: float) -> List[List[Point]]:
    """Clip a polyline to a rectangle; returns the pieces that stay inside."""
    pieces: List[List[Point]] = []
    current: List[Point] = []
    for i in range(len(points) - 1):
        clipped = clip_segment(points[i], points[i + 1], xmin, ymin, xmax, ymax)
        if clipped is None:
            if len(current) >= 2:
                pieces.append(current)
            current = []
            continue
        start, end = clipped
        if current and math.hypot(current[-1][0] - start[0], current[-1][1] - start[1]) < 1e-6:
            current.append(end)
        else:
            if len(current) >= 2:
                pieces.append(current)
            current = [start, end]
    if len(current) >= 2:
        pieces.append(current)
    return pieces


def clip_polygon_rect(poly: Sequence[Point], xmin: float, ymin: float,
                      xmax: float, ymax: float) -> List[Point]:
    """Sutherland-Hodgman clipping of a polygon to a rectangle."""
    def clip_edge(pts, inside, intersect):
        out: List[Point] = []
        for i in range(len(pts)):
            cur, prev = pts[i], pts[i - 1]
            if inside(cur):
                if not inside(prev):
                    out.append(intersect(prev, cur))
                out.append(cur)
            elif inside(prev):
                out.append(intersect(prev, cur))
        return out

    def lerp_x(x):
        return lambda p, q: (x, p[1] + (q[1] - p[1]) * (x - p[0]) / (q[0] - p[0]))

    def lerp_y(y):
        return lambda p, q: (p[0] + (q[0] - p[0]) * (y - p[1]) / (q[1] - p[1]), y)

    pts = list(poly)
    for inside, intersect in (
        (lambda p: p[0] >= xmin, lerp_x(xmin)),
        (lambda p: p[0] <= xmax, lerp_x(xmax)),
        (lambda p: p[1] >= ymin, lerp_y(ymin)),
        (lambda p: p[1] <= ymax, lerp_y(ymax)),
    ):
        if not pts:
            break
        pts = clip_edge(pts, inside, intersect)
    return pts


def polyline_length(points: Sequence[Point]) -> float:
    return sum(math.hypot(points[i + 1][0] - points[i][0], points[i + 1][1] - points[i][1])
               for i in range(len(points) - 1))


def sample_polyline(points: Sequence[Point], spacing: float) -> List[Point]:
    """Points every `spacing` metres along a polyline, starting half a step in."""
    out: List[Point] = []
    next_at = spacing / 2.0
    walked = 0.0
    for i in range(len(points) - 1):
        a, b = points[i], points[i + 1]
        seg = math.hypot(b[0] - a[0], b[1] - a[1])
        while seg > 0 and next_at <= walked + seg:
            t = (next_at - walked) / seg
            out.append((a[0] + t * (b[0] - a[0]), a[1] + t * (b[1] - a[1])))
            next_at += spacing
        walked += seg
    return out


def stable_unit(key: str) -> float:
    """Deterministic pseudo-random value in [0, 1) derived from a string."""
    h = 2166136261
    for ch in key.encode("utf-8"):
        h = ((h ^ ch) * 16777619) & 0xFFFFFFFF
    return h / 4294967296.0
