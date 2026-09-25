"""Writes a zone package directory with provenance and checksums."""
from __future__ import annotations

import datetime as dt
import hashlib
import json
from pathlib import Path
from typing import Dict, List, Optional


def _write_json(path: Path, payload) -> None:
    path.write_text(json.dumps(payload, ensure_ascii=False, separators=(",", ":")), encoding="utf-8")


def write_package(out_root: Path, zone: dict, spawn_points: List[Dict],
                  sources: List[Dict], stats: Dict[str, int],
                  warnings: Optional[List[str]] = None) -> Path:
    zone_dir = out_root / zone["zone_id"]
    zone_dir.mkdir(parents=True, exist_ok=True)
    now = dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat()

    _write_json(zone_dir / "zone.json", zone)
    _write_json(zone_dir / "spawn_points.json",
                {"zone_id": zone["zone_id"], "version": zone["version"], "points": spawn_points})
    _write_json(zone_dir / "attribution.json", {"zone_id": zone["zone_id"], "sources": sources})
    (zone_dir / "metadata.json").write_text(json.dumps({
        "zone_id": zone["zone_id"],
        "origin": zone["origin"],
        "size_m": zone["size_m"],
        "version": zone["version"],
        "format": zone["format"],
        "generated_at": now,
        "generator": "world-pipeline/build_zone.py",
        "data_sources": [s["source"] for s in sources],
        "counts": {"buildings": len(zone["buildings"]), "roads": len(zone["roads"]),
                   "areas": len(zone["areas"]), "pois": len(zone["pois"]),
                   "spawn_points": len(spawn_points)},
        "stats": stats,
        "warnings": warnings or [],
    }, ensure_ascii=False, indent=2), encoding="utf-8")

    checksums = {}
    for name in ("zone.json", "spawn_points.json", "attribution.json", "metadata.json"):
        checksums[name] = "sha256:" + hashlib.sha256((zone_dir / name).read_bytes()).hexdigest()
    (zone_dir / "checksum.json").write_text(json.dumps(checksums, indent=2), encoding="utf-8")
    return zone_dir
