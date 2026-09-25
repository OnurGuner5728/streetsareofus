"""Static spawn candidates on walkable ways.

The plan's score is:
    0.30 pedestrian_access + 0.20 street_imagery_coverage
  + 0.20 active_player_proximity + 0.15 POI_density
  + 0.10 terrain_safety + 0.05 novelty
Everything except active_player_proximity is known offline, so it is baked
here as `static_score`; the zone server adds the live term at spawn time.
"""
from __future__ import annotations

import math
from typing import Dict, List

from . import geo

PEDESTRIAN_ACCESS = {
    "pedestrian": 1.0, "footway": 1.0, "living_street": 1.0, "path": 0.8,
    "residential": 0.7, "unclassified": 0.6, "service": 0.5, "tertiary": 0.5,
    "secondary": 0.4, "primary": 0.3, "cycleway": 0.3, "track": 0.4,
}
WEIGHTS = {
    "pedestrian_access": 0.30, "street_imagery_coverage": 0.20,
    "poi_density": 0.15, "terrain_safety": 0.10, "novelty": 0.05,
}


def compute_spawn_points(zone: dict, spacing: float = 20.0, edge_margin: float = 12.0,
                         building_clearance: float = 1.5, min_separation: float = 12.0,
                         max_points: int = 250) -> List[Dict]:
    half = zone["size_m"] / 2.0 - edge_margin
    footprints = []
    for b in zone["buildings"]:
        if b.get("min_height", 0.0) > 2.2:
            continue  # canopies can be walked under
        pts = [tuple(p) for p in b["footprint"]]
        xs = [p[0] for p in pts]
        ys = [p[1] for p in pts]
        footprints.append((min(xs), min(ys), max(xs), max(ys), pts))
    pois = [(p["e"], p["n"]) for p in zone["pois"]]

    def blocked(p) -> bool:
        for x0, y0, x1, y1, poly in footprints:
            if p[0] < x0 - building_clearance or p[0] > x1 + building_clearance:
                continue
            if p[1] < y0 - building_clearance or p[1] > y1 + building_clearance:
                continue
            if geo.point_in_polygon(p, poly) or geo.distance_to_polygon_edge(p, poly) < building_clearance:
                return True
        return False

    candidates = []
    for road in zone["roads"]:
        access = PEDESTRIAN_ACCESS.get(road["kind"], 0.0)
        if access <= 0.0 or not road.get("walkable", True):
            continue
        for p in geo.sample_polyline([tuple(x) for x in road["points"]], spacing):
            if abs(p[0]) > half or abs(p[1]) > half or blocked(p):
                continue
            nearby = sum(1 for q in pois if math.hypot(q[0] - p[0], q[1] - p[1]) < 60.0)
            components = {
                "pedestrian_access": access,
                "street_imagery_coverage": 0.0,  # no imagery index yet
                "poi_density": min(1.0, nearby / 15.0),
                "terrain_safety": 1.0,  # flat terrain in format 1
                "novelty": geo.stable_unit(f"{road['id']}:{p[0]:.1f}:{p[1]:.1f}"),
            }
            score = sum(WEIGHTS[k] * v for k, v in components.items())
            candidates.append({"e": round(p[0], 2), "n": round(p[1], 2),
                               "street": road.get("name", ""),
                               "static_score": round(score, 4),
                               "components": {k: round(v, 3) for k, v in components.items()}})

    candidates.sort(key=lambda c: -c["static_score"])
    chosen: List[Dict] = []
    for c in candidates:
        if all(math.hypot(c["e"] - o["e"], c["n"] - o["n"]) >= min_separation for o in chosen):
            chosen.append(c)
            if len(chosen) >= max_points:
                break
    return chosen
