"""A deterministic grid town for offline development and automated tests."""
from __future__ import annotations

from . import geo
from .zone import ZONE_FORMAT, DEFAULT_LEVEL_HEIGHT

BLOCK = 48.0     # street centre-line spacing
STREET = 10.0    # street width


def build_synthetic_zone(zone_id: str, size_m: float = 256.0, version: int = 1) -> dict:
    half = size_m / 2.0
    count = int(size_m // BLOCK)
    offset = -count * BLOCK / 2.0
    lines = [offset + i * BLOCK for i in range(count + 1)]

    roads = []
    # Vertices at every crossing, as in OSM where intersecting ways share a node.
    for i, x in enumerate(lines):
        roads.append({"id": f"ns{i}", "kind": "residential", "width": STREET, "walkable": True,
                      "name": f"Test Sokak {i + 1}", "points": [[x, -half]] + [[x, y] for y in lines] + [[x, half]]})
    for i, y in enumerate(lines):
        roads.append({"id": f"ew{i}", "kind": "residential", "width": STREET, "walkable": True,
                      "name": f"Test Cadde {i + 1}", "points": [[-half, y]] + [[x, y] for x in lines] + [[half, y]]})
    mid = count // 2
    roads.append({"id": "plaza_walk", "kind": "pedestrian", "width": 6.0, "walkable": True,
                  "name": "Test Meydanı",
                  "points": [[lines[mid - 1] + 6, lines[mid - 1] + 6], [lines[mid] - 6, lines[mid] - 6]]})

    buildings, areas, pois = [], [], []
    inset = STREET / 2.0 + 2.0
    for i in range(count):
        for j in range(count):
            x0, y0 = lines[i] + inset, lines[j] + inset
            x1, y1 = lines[i + 1] - inset, lines[j + 1] - inset
            if i == mid - 1 and j == mid - 1:
                areas.append({"id": f"park{i}_{j}", "kind": "park",
                              "polygon": [[x0, y0], [x1, y0], [x1, y1], [x0, y1]]})
                continue
            xm, ym = (x0 + x1) / 2.0, (y0 + y1) / 2.0
            quads = [(x0, y0, xm - 1, ym - 1), (xm + 1, y0, x1, ym - 1),
                     (x0, ym + 1, xm - 1, y1), (xm + 1, ym + 1, x1, y1)]
            for k, (a, b, c, d) in enumerate(quads):
                key = f"s{i}_{j}_{k}"
                levels = 2 + int(geo.stable_unit(key) * 5)
                buildings.append({
                    "id": key, "kind": "residential" if k % 3 else "commercial",
                    "height": round(levels * DEFAULT_LEVEL_HEIGHT, 2), "min_height": 0.0,
                    "height_source": "synthetic",
                    "footprint": [[a, b], [c, b], [c, d], [a, d]],
                })
            pois.append({"id": f"p{i}_{j}", "category": "amenity", "kind": "cafe",
                         "e": x0 + 1.0, "n": y0 - 3.0})

    return {
        "format": ZONE_FORMAT,
        "zone_id": zone_id,
        "name": "Test Mahallesi",
        "version": version,
        "origin": {"lat": 0.0, "lon": 0.0},
        "size_m": size_m,
        "bbox": None,
        "coordinate_system": "local ENU metres, x=east, y=north; Godot uses Vector3(e, h, -n)",
        "terrain": {"type": "flat", "elevation_m": 0.0},
        "buildings": buildings,
        "roads": roads,
        "areas": areas,
        "pois": pois,
        "trees": [],
        "crossings": [],
        "lamps": [],
    }
