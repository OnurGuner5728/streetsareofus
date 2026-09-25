"""Fetching and parsing raw OpenStreetMap data from Overpass.

One small bbox query per zone (plus one tag lookup for transit stops outside
the zone), cached on disk. This is intentionally not a tile client: OSM
public infrastructure must not be used as a game CDN.
"""
from __future__ import annotations

import json
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
USER_AGENT = "streetsareofus-world-pipeline/0.2 (+self-hosted game prototype)"
CACHE_FORMAT = 2


@dataclass
class OsmWay:
    id: int
    tags: Dict[str, str]
    coords: List[Tuple[float, float]]  # (lat, lon)

    @property
    def closed(self) -> bool:
        return len(self.coords) >= 4 and self.coords[0] == self.coords[-1]


@dataclass
class OsmNode:
    id: int
    tags: Dict[str, str]
    lat: float
    lon: float


@dataclass
class OsmMember:
    type: str
    ref: int
    role: str
    coords: List[Tuple[float, float]]  # a way's geometry, or [(lat, lon)] for a node


@dataclass
class OsmRelation:
    id: int
    tags: Dict[str, str]
    members: List[OsmMember]


@dataclass
class OsmData:
    ways: List[OsmWay] = field(default_factory=list)
    nodes: List[OsmNode] = field(default_factory=list)
    # Outer rings of multipolygon relations, flattened into pseudo-ways.
    relation_rings: List[OsmWay] = field(default_factory=list)
    # Public transport route relations with full member geometry, also
    # outside the zone, so line lengths and timetables stay real.
    routes: List[OsmRelation] = field(default_factory=list)
    # Tags of nodes referenced by routes but lying outside the bbox.
    extra_node_tags: Dict[int, Dict[str, str]] = field(default_factory=dict)
    timestamp: Optional[str] = None
    skipped_relation_members: int = 0


def build_query(south: float, west: float, north: float, east: float) -> str:
    bbox = f"{south:.7f},{west:.7f},{north:.7f},{east:.7f}"
    return f"""[out:json][timeout:90];
(
  way["building"]({bbox});
  relation["building"]["type"="multipolygon"]({bbox});
  way["highway"]({bbox});
  way["leisure"~"^(park|garden|playground|pitch)$"]({bbox});
  way["landuse"~"^(grass|recreation_ground|village_green)$"]({bbox});
  way["amenity"="parking"]({bbox});
  way["place"="square"]({bbox});
  way["natural"~"^(water|coastline|tree_row)$"]({bbox});
  way["railway"~"^(tram|light_rail)$"]({bbox});
  relation["route"~"^(tram|light_rail)$"]({bbox});
  node["amenity"]({bbox});
  node["shop"]({bbox});
  node["tourism"]({bbox});
  node["natural"="tree"]({bbox});
  node["highway"~"^(crossing|street_lamp)$"]({bbox});
  node["railway"="tram_stop"]({bbox});
);
out body geom;"""


def fetch_overpass(query: str, retries_per_endpoint: int = 2) -> dict:
    last_error: Optional[Exception] = None
    body = urllib.parse.urlencode({"data": query}).encode("utf-8")
    for endpoint in OVERPASS_ENDPOINTS:
        for attempt in range(retries_per_endpoint):
            try:
                req = urllib.request.Request(endpoint, data=body, headers={
                    "User-Agent": USER_AGENT,
                    "Accept": "application/json",
                })
                with urllib.request.urlopen(req, timeout=120) as resp:
                    raw = resp.read().decode("utf-8")
                data = json.loads(raw)
                if "elements" not in data:
                    raise ValueError(f"unexpected Overpass payload from {endpoint}")
                if data.get("remark", "").startswith("runtime error"):
                    raise ValueError(data["remark"])
                return data
            except (urllib.error.URLError, ValueError, json.JSONDecodeError, TimeoutError) as exc:
                last_error = exc
                print(f"  overpass {endpoint} attempt {attempt + 1} failed: {exc}")
                time.sleep(3 * (attempt + 1))
    raise RuntimeError(f"all Overpass endpoints failed: {last_error}")


def _route_stop_ids(data: dict) -> List[int]:
    ids = []
    for el in data.get("elements", []):
        if el.get("type") == "relation" and el.get("tags", {}).get("route") in ("tram", "light_rail"):
            ids += [m["ref"] for m in el.get("members", []) if m.get("type") == "node"]
    return ids


def load_or_fetch(cache_file: Path, bbox: Tuple[float, float, float, float],
                  refresh: bool = False) -> dict:
    if cache_file.exists() and not refresh:
        data = json.loads(cache_file.read_text(encoding="utf-8"))
        if data.get("streetsareofus_cache_format") == CACHE_FORMAT:
            print(f"  using cached OSM extract {cache_file}")
            return data
        print("  cached extract predates transit data, re-fetching")
    print("  querying Overpass ...")
    data = fetch_overpass(build_query(*bbox))
    stop_ids = _route_stop_ids(data)
    if stop_ids:
        # Route stops outside the zone only come back as coordinates; one more
        # small query gives their names for destination signs and timetables.
        ids = ",".join(str(i) for i in sorted(set(stop_ids)))
        extra = fetch_overpass(f"[out:json][timeout:60];node(id:{ids});out tags;")
        data["extra_node_tags"] = {str(e["id"]): e.get("tags", {}) for e in extra.get("elements", [])}
    data["streetsareofus_cache_format"] = CACHE_FORMAT
    cache_file.parent.mkdir(parents=True, exist_ok=True)
    cache_file.write_text(json.dumps(data), encoding="utf-8")
    return data


def parse(data: dict) -> OsmData:
    out = OsmData(timestamp=data.get("osm3s", {}).get("timestamp_osm_base"))
    out.extra_node_tags = {int(k): v for k, v in data.get("extra_node_tags", {}).items()}
    for el in data.get("elements", []):
        kind = el.get("type")
        tags = el.get("tags", {}) or {}
        if kind == "node":
            if tags:
                out.nodes.append(OsmNode(el["id"], tags, el["lat"], el["lon"]))
        elif kind == "way":
            geom = el.get("geometry") or []
            coords = [(g["lat"], g["lon"]) for g in geom if g]
            if len(coords) >= 2:
                out.ways.append(OsmWay(el["id"], tags, coords))
        elif kind == "relation":
            if tags.get("route") in ("tram", "light_rail"):
                members = []
                for m in el.get("members", []):
                    if m.get("type") == "way":
                        coords = [(g["lat"], g["lon"]) for g in (m.get("geometry") or []) if g]
                    elif m.get("type") == "node" and "lat" in m:
                        coords = [(m["lat"], m["lon"])]
                    else:
                        continue
                    members.append(OsmMember(m["type"], m["ref"], m.get("role", ""), coords))
                out.routes.append(OsmRelation(el["id"], tags, members))
                continue
            for member in el.get("members", []):
                if member.get("type") != "way" or member.get("role") != "outer":
                    continue
                geom = member.get("geometry") or []
                coords = [(g["lat"], g["lon"]) for g in geom if g]
                ring = OsmWay(-el["id"], dict(tags), coords)
                if ring.closed:
                    out.relation_rings.append(ring)
                else:
                    # Outer rings split over several ways need ring assembly;
                    # not worth it for the pilot, but count them.
                    out.skipped_relation_members += 1
    return out
