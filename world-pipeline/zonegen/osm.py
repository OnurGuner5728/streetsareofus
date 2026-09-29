"""Fetching and parsing raw OpenStreetMap data from Overpass.

One small bbox query per zone (plus one tag lookup for transit stops outside
the zone), cached on disk. This is intentionally not a tile client: OSM
public infrastructure must not be used as a game CDN.
"""
from __future__ import annotations

import json
import math
import time
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path
from typing import Dict, List, Optional, Tuple

OVERPASS_ENDPOINTS = [
    "https://overpass-api.de/api/interpreter",
    "https://overpass.kumi.systems/api/interpreter",
    "https://overpass.private.coffee/api/interpreter",
    "https://maps.mail.ru/osm/tools/overpass/api/interpreter",
]
USER_AGENT = "streetsareofus-world-pipeline/0.2 (+self-hosted game prototype)"
CACHE_FORMAT = 3  # 3: shore features (beaches, piers, breakwaters)


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
    return f"""[out:json][timeout:180];
(
  way["building"]({bbox});
  relation["building"]["type"="multipolygon"]({bbox});
  way["highway"]({bbox});
  way["leisure"~"^(park|garden|playground|pitch)$"]({bbox});
  way["landuse"~"^(grass|recreation_ground|village_green)$"]({bbox});
  way["amenity"="parking"]({bbox});
  way["place"="square"]({bbox});
  way["natural"~"^(water|coastline|tree_row|beach|bare_rock|shingle|sand)$"]({bbox});
  way["man_made"~"^(pier|breakwater|quay|groyne)$"]({bbox});
  way["amenity"="ferry_terminal"]({bbox});
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
                with urllib.request.urlopen(req, timeout=240) as resp:
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


# Busy public Overpass servers time out on a whole district; a bbox wider
# than this is fetched in tiles (each cached, so a retry resumes) and merged.
TILE_DEG = 0.0065


def fetch_tiled(cache_file: Path, bbox: Tuple[float, float, float, float]) -> dict:
    south, west, north, east = bbox
    rows = max(1, math.ceil((north - south) / TILE_DEG - 1e-9))
    cols = max(1, math.ceil((east - west) / (TILE_DEG * 1.35) - 1e-9))
    if rows * cols == 1:
        return fetch_overpass(build_query(*bbox))
    merged: Dict[Tuple[str, int], dict] = {}
    header: dict = {}
    for r in range(rows):
        for c in range(cols):
            tile_file = cache_file.with_name(f"{cache_file.stem}.tile{r}_{c}.json")
            if tile_file.exists():
                part = json.loads(tile_file.read_text(encoding="utf-8"))
            else:
                s = south + (north - south) * r / rows
                n = south + (north - south) * (r + 1) / rows
                w = west + (east - west) * c / cols
                e = west + (east - west) * (c + 1) / cols
                print(f"  tile {r * cols + c + 1}/{rows * cols}")
                part = fetch_overpass(build_query(s, w, n, e))
                tile_file.parent.mkdir(parents=True, exist_ok=True)
                tile_file.write_text(json.dumps(part), encoding="utf-8")
            header = header or {k: v for k, v in part.items() if k != "elements"}
            for el in part.get("elements", []):
                merged[(el.get("type"), el.get("id"))] = el
    out = dict(header)
    out["elements"] = list(merged.values())
    return out


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
    data = fetch_tiled(cache_file, bbox)
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
