#!/usr/bin/env python3
"""Build a zone package for the game.

Examples:
  python build_zone.py osm --zone-id tr_istanbul_kadikoy_001 --lat 40.9895 --lon 29.02965
  python build_zone.py synthetic --zone-id test_grid_001 --size 256
"""
from __future__ import annotations

import argparse
import datetime as dt
import sys
from pathlib import Path

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))

from zonegen import osm, terrain  # noqa: E402
from zonegen.package import write_package  # noqa: E402
from zonegen.spawn import compute_spawn_points  # noqa: E402
from zonegen.synthetic import build_synthetic_zone  # noqa: E402
from zonegen.transit import build_transit  # noqa: E402
from zonegen.zone import ZoneBuilder  # noqa: E402

DEFAULT_OUT = HERE.parent / "game" / "zones"


def cmd_osm(args) -> int:
    builder = ZoneBuilder(args.zone_id, args.lat, args.lon, args.size, args.version, args.name)
    bbox = builder.proj.bbox(args.size)
    print(f"zone {args.zone_id}: bbox S{bbox[0]:.5f} W{bbox[1]:.5f} N{bbox[2]:.5f} E{bbox[3]:.5f}")
    raw = osm.load_or_fetch(HERE / "cache" / f"{args.zone_id}.overpass.json", bbox, args.refresh)
    data = osm.parse(raw)
    zone = builder.build(data)
    if not args.flat:
        dem = terrain.load_or_fetch(HERE / "cache" / f"{args.zone_id}.dem.json", builder.proj, args.size,
                                    16.0, 48.0, args.refresh)
        zone["terrain"] = terrain.build_terrain(dem, args.size)
        print(f"  terrain: {zone['terrain']['relief_m']} m of relief above {zone['terrain']['base_m']} m ({dem['source']})")
    zone["transit"] = build_transit(data, builder.proj, zone)
    spawns = compute_spawn_points(zone)
    if not spawns:
        print("error: no walkable spawn points found in this zone", file=sys.stderr)
        return 1
    sources = [{
        "source": "openstreetmap",
        "license": "ODbL-1.0",
        "attribution": "© OpenStreetMap contributors",
        "url": "https://www.openstreetmap.org/copyright",
        "snapshot": data.timestamp,
        "acquired_via": "Overpass API bbox query",
        "acquired_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat(),
    }]
    if zone["terrain"].get("type") == "grid":
        sources.append({
            "source": "elevation", "license": "public domain (NASA SRTM / ASTER GDEM) or CC BY 4.0 (Copernicus DEM)",
            "attribution": "Yükseklik: " + zone["terrain"].get("source", "DEM"),
            "acquired_via": "OpenTopoData / Open-Meteo elevation API",
        })
    out = write_package(Path(args.out), zone, spawns, sources, builder.stats, builder.warnings)
    _report(out, zone, spawns, builder.stats, builder.warnings)
    return 0


def cmd_synthetic(args) -> int:
    zone = build_synthetic_zone(args.zone_id, args.size, args.version)
    zone["transit"] = build_transit(None, None, zone)
    spawns = compute_spawn_points(zone)
    sources = [{"source": "synthetic", "license": "CC0-1.0", "attribution": "generated test data"}]
    out = write_package(Path(args.out), zone, spawns, sources, {})
    _report(out, zone, spawns, {}, [])
    return 0


def _report(out, zone, spawns, stats, warnings) -> None:
    print(f"wrote {out}")
    print(f"  buildings={len(zone['buildings'])} roads={len(zone['roads'])} "
          f"areas={len(zone['areas'])} pois={len(zone['pois'])} spawn_points={len(spawns)} "
          f"trees={len(zone['trees'])} crossings={len(zone['crossings'])}")
    for line in zone["transit"]["lines"]:
        stops = ", ".join(s["name"] + ("" if s["in_zone"] else "*") for s in line["stops"])
        print(f"  line {line['id']} [{line['source']}, {line['kind']}, {line['length']:.0f} m, "
              f"{line['vehicles']} vehicles]: {stops}")
    for key, value in sorted(stats.items()):
        print(f"  {key}: {value}")
    for w in warnings:
        print(f"  warning: {w}")


def main(argv=None) -> int:
    if hasattr(sys.stdout, "reconfigure"):
        sys.stdout.reconfigure(encoding="utf-8")
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="command", required=True)

    p_osm = sub.add_parser("osm", help="build a zone from an OpenStreetMap extract")
    p_osm.add_argument("--zone-id", required=True)
    p_osm.add_argument("--lat", type=float, required=True, help="zone centre latitude")
    p_osm.add_argument("--lon", type=float, required=True, help="zone centre longitude")
    p_osm.add_argument("--name", help="human readable zone name shown in game")
    p_osm.add_argument("--size", type=float, default=512.0, help="cell edge length in metres")
    p_osm.add_argument("--version", type=int, default=2)
    p_osm.add_argument("--refresh", action="store_true", help="ignore the cached extract and elevation")
    p_osm.add_argument("--flat", action="store_true", help="skip elevation data (flat ground)")
    p_osm.add_argument("--out", default=str(DEFAULT_OUT))
    p_osm.set_defaults(func=cmd_osm)

    p_syn = sub.add_parser("synthetic", help="build a deterministic offline test zone")
    p_syn.add_argument("--zone-id", default="test_grid_001")
    p_syn.add_argument("--size", type=float, default=256.0)
    p_syn.add_argument("--version", type=int, default=2)
    p_syn.add_argument("--out", default=str(DEFAULT_OUT))
    p_syn.set_defaults(func=cmd_synthetic)

    args = parser.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
