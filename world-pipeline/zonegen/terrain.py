"""Ground elevation for a zone from free public DEMs.

A coarse grid of points over the zone (plus a margin) is looked up in the
OpenTopoData API (SRTM 30 m, falling back to ASTER 30 m) or, failing that,
Open-Meteo's elevation API (Copernicus 90 m). Radar DEMs see dense city
blocks as bumps, so the grid is smoothed before it is resampled to the
game's terrain grid: what survives is the lie of the land (hills, slopes),
not the rooftops. Results are cached next to the OSM extract.

Terrain in zone.json:
  {"type": "grid", "spacing_m": 8, "size": 65, "base_m": 12.3,
   "heights_cm": [...]}   # size*size ints, row-major from the north-west
                          # corner (x east, z south), relative to base_m
"""
from __future__ import annotations

import json
import math
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Callable, List, Optional, Sequence, Tuple

from .geo import LocalProjection

USER_AGENT = "streetsareofus-world-pipeline/0.3 (+self-hosted game prototype)"
OPENTOPODATA = "https://api.opentopodata.org/v1/{dataset}?locations={locations}"
OPEN_METEO = "https://api.open-meteo.com/v1/elevation?latitude={lat}&longitude={lon}"
BATCH = 100
CACHE_FORMAT = 1


def sample_points(size_m: float, spacing: float, margin: float) -> Tuple[List[Tuple[float, float]], int]:
    """Grid points (e, n) row by row from the north-west corner; returns (points, per_side)."""
    half = size_m / 2.0 + margin
    per_side = int(round(2 * half / spacing)) + 1
    pts = []
    for j in range(per_side):
        n = half - j * spacing
        for i in range(per_side):
            pts.append((-half + i * spacing, n))
    return pts, per_side


def _get_json(url: str) -> dict:
    req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
    with urllib.request.urlopen(req, timeout=60) as resp:
        return json.loads(resp.read().decode("utf-8"))


def fetch_opentopodata(latlons: Sequence[Tuple[float, float]], dataset: str) -> List[float]:
    out: List[float] = []
    for start in range(0, len(latlons), BATCH):
        chunk = latlons[start:start + BATCH]
        locations = "|".join(f"{lat:.6f},{lon:.6f}" for lat, lon in chunk)
        data = _get_json(OPENTOPODATA.format(dataset=dataset, locations=urllib.parse.quote(locations, safe="|,.")))
        if data.get("status") != "OK":
            raise RuntimeError(f"opentopodata {dataset}: {data.get('error', data.get('status'))}")
        for r in data["results"]:
            if r.get("elevation") is None:
                raise RuntimeError(f"opentopodata {dataset}: no data at {r.get('location')}")
            out.append(float(r["elevation"]))
        time.sleep(1.1)  # public API: one request per second
    return out


def fetch_open_meteo(latlons: Sequence[Tuple[float, float]]) -> List[float]:
    out: List[float] = []
    for start in range(0, len(latlons), BATCH):
        chunk = latlons[start:start + BATCH]
        data = _get_json(OPEN_METEO.format(lat=",".join(f"{a:.6f}" for a, _ in chunk),
                                           lon=",".join(f"{b:.6f}" for _, b in chunk)))
        out.extend(float(v) for v in data["elevation"])
        time.sleep(0.5)
    return out


def load_or_fetch(cache_file: Path, proj: LocalProjection, size_m: float, spacing: float, margin: float,
                  refresh: bool = False) -> dict:
    """Raw DEM samples {per_side, spacing, margin, source, heights}, cached."""
    if cache_file.exists() and not refresh:
        data = json.loads(cache_file.read_text(encoding="utf-8"))
        if data.get("format") == CACHE_FORMAT and data.get("spacing") == spacing and data.get("margin") == margin:
            print(f"  using cached elevation {cache_file}")
            return data
    points, per_side = sample_points(size_m, spacing, margin)
    latlons = [proj.to_geo(e, n) for e, n in points]
    sources: List[Tuple[str, Callable[[], List[float]]]] = [
        ("SRTM 30 m (OpenTopoData)", lambda: fetch_opentopodata(latlons, "srtm30m")),
        ("ASTER 30 m (OpenTopoData)", lambda: fetch_opentopodata(latlons, "aster30m")),
        ("Copernicus 90 m (Open-Meteo)", lambda: fetch_open_meteo(latlons)),
    ]
    last_error: Optional[Exception] = None
    for name, fetch in sources:
        try:
            print(f"  fetching elevation: {len(points)} points from {name}")
            heights = fetch()
            data = {"format": CACHE_FORMAT, "per_side": per_side, "spacing": spacing, "margin": margin,
                    "source": name, "heights": heights}
            cache_file.parent.mkdir(parents=True, exist_ok=True)
            cache_file.write_text(json.dumps(data), encoding="utf-8")
            return data
        except (urllib.error.URLError, RuntimeError, KeyError, ValueError, TimeoutError) as err:
            print(f"  {name} failed: {err}")
            last_error = err
    raise RuntimeError(f"no elevation source answered: {last_error}")


def smooth(grid: List[float], per_side: int, sigma_cells: float) -> List[float]:
    """Separable Gaussian blur with clamped edges."""
    radius = max(1, int(math.ceil(sigma_cells * 2.5)))
    weights = [math.exp(-0.5 * (k / sigma_cells) ** 2) for k in range(-radius, radius + 1)]
    total = sum(weights)
    weights = [w / total for w in weights]

    def at(g, i, j):
        i = min(max(i, 0), per_side - 1)
        j = min(max(j, 0), per_side - 1)
        return g[j * per_side + i]

    tmp = [0.0] * len(grid)
    for j in range(per_side):
        for i in range(per_side):
            tmp[j * per_side + i] = sum(w * at(grid, i + k - radius, j) for k, w in enumerate(weights))
    out = [0.0] * len(grid)
    for j in range(per_side):
        for i in range(per_side):
            out[j * per_side + i] = sum(w * at(tmp, i, j + k - radius) for k, w in enumerate(weights))
    return out


def bilinear(grid: List[float], per_side: int, fx: float, fy: float) -> float:
    fx = min(max(fx, 0.0), per_side - 1.000001)
    fy = min(max(fy, 0.0), per_side - 1.000001)
    i, j = int(fx), int(fy)
    u, v = fx - i, fy - j
    g = grid
    top = g[j * per_side + i] * (1 - u) + g[j * per_side + i + 1] * u
    bottom = g[(j + 1) * per_side + i] * (1 - u) + g[(j + 1) * per_side + i + 1] * u
    return top * (1 - v) + bottom * v


def build_terrain(raw: dict, size_m: float, out_spacing: float = 8.0, sigma_m: float = 28.0) -> dict:
    """Smoothed, resampled terrain block for zone.json (see module docstring)."""
    per_side = int(raw["per_side"])
    spacing = float(raw["spacing"])
    margin = float(raw["margin"])
    heights = smooth([float(h) for h in raw["heights"]], per_side, sigma_m / spacing)
    half = size_m / 2.0
    size = int(round(size_m / out_spacing)) + 1
    out: List[float] = []
    for j in range(size):
        z = -half + j * out_spacing  # Godot z (south), row 0 at the north edge
        n = -z
        for i in range(size):
            e = -half + i * out_spacing
            fx = (e + half + margin) / spacing
            fy = (half + margin - n) / spacing
            out.append(bilinear(heights, per_side, fx, fy))
    base = min(out)
    rel = [h - base for h in out]
    return {
        "type": "grid", "spacing_m": out_spacing, "size": size, "base_m": round(base, 2),
        "relief_m": round(max(rel), 2), "source": raw.get("source", ""),
        "heights_cm": [int(round(h * 100.0)) for h in rel],
    }
