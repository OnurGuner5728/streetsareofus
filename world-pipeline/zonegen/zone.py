"""Turns parsed OSM data into the engine-neutral zone format (see README)."""
from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from . import geo
from .osm import OsmData, OsmWay

ZONE_FORMAT = 2
DEFAULT_LEVEL_HEIGHT = 3.1

ROAD_WIDTHS = {
    "motorway": 14.0, "trunk": 12.0, "primary": 11.0, "secondary": 9.0,
    "tertiary": 8.0, "unclassified": 6.0, "residential": 6.0,
    "living_street": 5.0, "service": 4.0, "pedestrian": 6.0, "track": 3.0,
    "footway": 2.5, "path": 2.0, "cycleway": 2.0, "steps": 2.5,
    "bridleway": 2.0,
}
NOT_WALKABLE = {"motorway", "trunk", "motorway_link", "trunk_link"}
SKIP_HIGHWAYS = {"proposed", "construction", "elevator", "platform", "bus_stop",
                 "corridor", "raceway", "abandoned", "razed"}

AREA_KINDS = [
    (("leisure", "park"), "park"), (("leisure", "garden"), "park"),
    (("leisure", "playground"), "playground"), (("leisure", "pitch"), "pitch"),
    (("landuse", "grass"), "grass"), (("landuse", "recreation_ground"), "grass"),
    (("landuse", "village_green"), "grass"), (("amenity", "parking"), "parking"),
    (("place", "square"), "plaza"), (("natural", "water"), "water"),
]

SMALL_BUILDINGS = {"kiosk", "garage", "garages", "shed", "hut", "cabin", "toilets",
                   "service", "transformer_tower", "carport"}
KIND_BY_BUILDING = {
    "residential": "residential", "apartments": "residential", "house": "residential",
    "detached": "residential", "terrace": "residential", "dormitory": "residential",
    "commercial": "commercial", "retail": "commercial", "office": "commercial",
    "hotel": "commercial", "supermarket": "commercial", "kiosk": "commercial",
    "mosque": "religious", "church": "religious", "synagogue": "religious",
    "religious": "religious", "roof": "canopy", "school": "civic",
    "university": "civic", "public": "civic", "hospital": "civic",
    "government": "civic", "train_station": "civic", "transportation": "civic",
}

_NUMBER = re.compile(r"-?\d+(?:[.,]\d+)?")


def parse_length(value: Optional[str]) -> Optional[float]:
    """Parse OSM length values such as '12', '12 m', '12.5m' or "40'"."""
    if not value:
        return None
    match = _NUMBER.search(value)
    if not match:
        return None
    number = float(match.group(0).replace(",", "."))
    if "'" in value or "ft" in value:
        number *= 0.3048
    return number


def building_height(tags: Dict[str, str], key: str) -> Tuple[float, float, str]:
    """Return (height, min_height, source) in metres."""
    building = tags.get("building", "yes")
    min_height = parse_length(tags.get("min_height"))
    if min_height is None and tags.get("building:min_level"):
        levels = parse_length(tags.get("building:min_level"))
        min_height = levels * DEFAULT_LEVEL_HEIGHT if levels is not None else None
    if building == "roof" and min_height is None:
        min_height = 2.6

    height = parse_length(tags.get("height"))
    source = "osm:height"
    if height is None and tags.get("building:levels"):
        levels = parse_length(tags.get("building:levels"))
        if levels is not None and levels > 0:
            roof_levels = parse_length(tags.get("roof:levels")) or 0.0
            height = (levels + roof_levels) * DEFAULT_LEVEL_HEIGHT
            source = "osm:levels"
    if height is None:
        source = "estimated"
        roll = geo.stable_unit(key)
        if building in SMALL_BUILDINGS:
            height = 2.8 + roll * 1.5
        elif building == "roof":
            height = 3.2
        elif building in ("mosque", "church"):
            height = 14.0 + roll * 4.0
        else:
            # Dense Istanbul neighbourhoods are mostly 4-6 storeys.
            height = (3 + int(roll * 4)) * DEFAULT_LEVEL_HEIGHT
    min_height = min_height or 0.0
    height = max(height, min_height + 1.0)
    return round(height, 2), round(min_height, 2), source


def area_kind(tags: Dict[str, str]) -> Optional[str]:
    for (key, value), kind in AREA_KINDS:
        if tags.get(key) == value:
            return kind
    if tags.get("highway") in ("pedestrian", "footway") and tags.get("area") == "yes":
        return "plaza"
    return None


def _round_pts(points) -> List[List[float]]:
    return [[round(p[0], 2), round(p[1], 2)] for p in points]


class ZoneBuilder:
    def __init__(self, zone_id: str, lat: float, lon: float, size_m: float, version: int,
                 name: Optional[str] = None):
        self.zone_id = zone_id
        self.name = name or zone_id
        self.size_m = size_m
        self.version = version
        self.proj = geo.LocalProjection(lat, lon)
        self.half = size_m / 2.0
        self.stats: Dict[str, int] = {}
        self.warnings: List[str] = []

    def _count(self, key: str) -> None:
        self.stats[key] = self.stats.get(key, 0) + 1

    def _local(self, way: OsmWay) -> List[geo.Point]:
        return [self.proj.to_local(lat, lon) for lat, lon in way.coords]

    def _inside(self, p: geo.Point) -> bool:
        return -self.half <= p[0] <= self.half and -self.half <= p[1] <= self.half

    def build(self, osm: OsmData) -> dict:
        h = self.half
        buildings, roads, areas, pois = [], [], [], []
        trees, crossings, lamps = [], [], []

        for way in list(osm.ways) + list(osm.relation_rings):
            tags = way.tags
            if tags.get("natural") == "tree_row":
                for piece in geo.clip_polyline(self._local(way), -h, -h, h, h):
                    for p in geo.sample_polyline(piece, 7.0):
                        trees.append([round(p[0], 2), round(p[1], 2), 0.0])
                continue
            if tags.get("railway"):
                continue  # tracks come from route relations (transit.py)
            if "building" in tags and tags.get("building") != "no":
                if not way.closed:
                    self._count("building_open_ring_skipped")
                    continue
                ring = geo.clean_ring(self._local(way))
                if len(ring) < 3 or abs(geo.signed_area(ring)) < 4.0:
                    self._count("building_degenerate_skipped")
                    continue
                # A building belongs to the zone that contains its centroid,
                # so neighbouring zones never both own the same building.
                if not self._inside(geo.centroid(ring)):
                    continue
                ring = geo.ensure_ccw(ring)
                key = f"{'r' if way.id < 0 else 'w'}{abs(way.id)}"
                height, min_height, source = building_height(tags, key)
                kind = KIND_BY_BUILDING.get(tags.get("building", "yes"), "generic")
                entry = {"id": key, "kind": kind, "height": height,
                         "min_height": min_height, "height_source": source,
                         "footprint": _round_pts(ring)}
                if tags.get("name"):
                    entry["name"] = tags["name"]
                buildings.append(entry)
                self._count("buildings")
                continue

            kind = area_kind(tags)
            if kind and way.closed:
                ring = geo.clean_ring(self._local(way))
                clipped = geo.clip_polygon_rect(ring, -h, -h, h, h)
                clipped = geo.clean_ring(clipped)
                if len(clipped) >= 3 and abs(geo.signed_area(clipped)) >= 4.0:
                    areas.append({"id": f"w{way.id}", "kind": kind,
                                  "polygon": _round_pts(geo.ensure_ccw(clipped))})
                    self._count(f"area_{kind}")
                continue

            if tags.get("natural") == "coastline":
                self.warnings.append("coastline present: sea polygons are not generated yet")
                continue

            highway = tags.get("highway")
            if highway and highway not in SKIP_HIGHWAYS:
                if tags.get("tunnel") == "yes" or tags.get("indoor") == "yes":
                    self._count("road_underground_skipped")
                    continue
                layer = parse_length(tags.get("layer")) or 0
                if layer < 0:
                    self._count("road_underground_skipped")
                    continue
                base = highway.replace("_link", "")
                width = parse_length(tags.get("width")) or ROAD_WIDTHS.get(base, 5.0)
                width = max(1.5, min(width, 20.0))
                for idx, piece in enumerate(geo.clip_polyline(self._local(way), -h, -h, h, h)):
                    if geo.polyline_length(piece) < 1.0:
                        continue
                    road = {"id": f"w{way.id}" + (f"_{idx}" if idx else ""),
                            "kind": base, "width": round(width, 2),
                            "walkable": highway not in NOT_WALKABLE,
                            "points": _round_pts(piece)}
                    if tags.get("name"):
                        road["name"] = tags["name"]
                    roads.append(road)
                    self._count("roads")

        for node in osm.nodes:
            p = self.proj.to_local(node.lat, node.lon)
            if not self._inside(p):
                continue
            here = [round(p[0], 2), round(p[1], 2)]
            if node.tags.get("natural") == "tree":
                trees.append(here + [parse_length(node.tags.get("height")) or 0.0])
                continue
            if node.tags.get("highway") == "crossing":
                crossings.append(here)
                continue
            if node.tags.get("highway") == "street_lamp":
                lamps.append(here)
                continue
            for category in ("amenity", "shop", "tourism"):
                if category in node.tags:
                    poi = {"id": f"n{node.id}", "category": category,
                           "kind": node.tags[category], "e": round(p[0], 2), "n": round(p[1], 2)}
                    if node.tags.get("name"):
                        poi["name"] = node.tags["name"]
                    pois.append(poi)
                    self._count("pois")
                    break

        if osm.skipped_relation_members:
            self.warnings.append(
                f"{osm.skipped_relation_members} multipolygon outer members need ring assembly (skipped)")

        # Ways through buildings (Kadıköy's arcades are mapped as footways
        # under the building) cannot be walked in a world of solid buildings.
        solid = [(min(q[0] for q in b["footprint"]), min(q[1] for q in b["footprint"]),
                  max(q[0] for q in b["footprint"]), max(q[1] for q in b["footprint"]),
                  [tuple(q) for q in b["footprint"]]) for b in buildings if b["min_height"] < 2.2]
        for road in roads:
            samples = geo.sample_polyline([tuple(q) for q in road["points"]], 2.0) or [tuple(road["points"][0])]
            inside = sum(1 for p in samples if any(x0 <= p[0] <= x1 and y0 <= p[1] <= y1 and geo.point_in_polygon(p, poly)
                                                   for x0, y0, x1, y1, poly in solid))
            if inside / len(samples) > 0.25:
                road["walkable"] = False
                road["through_building"] = True
                self._count("road_through_building")

        # Wider roads first so narrow paths render on top.
        roads.sort(key=lambda r: -r["width"])
        south, west, north, east = self.proj.bbox(self.size_m)
        return {
            "format": ZONE_FORMAT,
            "zone_id": self.zone_id,
            "name": self.name,
            "version": self.version,
            "origin": {"lat": self.proj.lat0, "lon": self.proj.lon0},
            "size_m": self.size_m,
            "bbox": {"south": round(south, 7), "west": round(west, 7),
                     "north": round(north, 7), "east": round(east, 7)},
            "coordinate_system": "local ENU metres, x=east, y=north; Godot uses Vector3(e, h, -n)",
            "terrain": {"type": "flat", "elevation_m": 0.0},
            "buildings": buildings,
            "roads": roads,
            "areas": areas,
            "pois": pois,
            "trees": trees,
            "crossings": crossings,
            "lamps": lamps,
        }
