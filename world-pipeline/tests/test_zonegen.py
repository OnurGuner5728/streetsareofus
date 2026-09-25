"""Unit tests for the world pipeline: python -m unittest discover -s world-pipeline/tests"""
import math
import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from zonegen import geo  # noqa: E402
from zonegen.osm import parse  # noqa: E402
from zonegen.spawn import compute_spawn_points  # noqa: E402
from zonegen.synthetic import build_synthetic_zone  # noqa: E402
from zonegen.zone import ZoneBuilder, building_height, parse_length  # noqa: E402

ORIGIN = (40.9895, 29.02965)


class GeoTests(unittest.TestCase):
    def test_projection_round_trip(self):
        proj = geo.LocalProjection(*ORIGIN)
        e, n = proj.to_local(40.9900, 29.0300)
        lat, lon = proj.to_geo(e, n)
        self.assertAlmostEqual(lat, 40.9900, places=9)
        self.assertAlmostEqual(lon, 29.0300, places=9)

    def test_projection_scale(self):
        proj = geo.LocalProjection(*ORIGIN)
        _, n = proj.to_local(ORIGIN[0] + 0.001, ORIGIN[1])
        self.assertAlmostEqual(n, 111.1, delta=0.2)  # 0.001 deg of latitude

    def test_bbox_is_square(self):
        proj = geo.LocalProjection(*ORIGIN)
        s, w, n, e = proj.bbox(512)
        sw = proj.to_local(s, w)
        ne = proj.to_local(n, e)
        self.assertAlmostEqual(ne[0] - sw[0], 512, delta=0.01)
        self.assertAlmostEqual(ne[1] - sw[1], 512, delta=0.01)

    def test_orientation_and_centroid(self):
        square_cw = [(0, 0), (0, 10), (10, 10), (10, 0)]
        self.assertLess(geo.signed_area(square_cw), 0)
        ccw = geo.ensure_ccw(square_cw)
        self.assertGreater(geo.signed_area(ccw), 0)
        cx, cy = geo.centroid(ccw)
        self.assertAlmostEqual(cx, 5)
        self.assertAlmostEqual(cy, 5)

    def test_point_in_polygon(self):
        l_shape = [(0, 0), (10, 0), (10, 4), (4, 4), (4, 10), (0, 10)]
        self.assertTrue(geo.point_in_polygon((2, 8), l_shape))
        self.assertFalse(geo.point_in_polygon((8, 8), l_shape))

    def test_clean_ring_drops_duplicates_and_collinear(self):
        ring = [(0, 0), (5, 0), (10, 0), (10, 10), (10, 10.1), (0, 10), (0, 0)]
        cleaned = geo.clean_ring(ring)
        self.assertEqual(len(cleaned), 4)

    def test_clip_polyline(self):
        pieces = geo.clip_polyline([(-20, 0), (20, 0), (20, 30), (0, 30)], -10, -10, 10, 10)
        self.assertEqual(len(pieces), 1)
        self.assertEqual(pieces[0], [(-10.0, 0.0), (10.0, 0.0)])
        self.assertEqual(geo.clip_polyline([(20, 20), (30, 30)], -10, -10, 10, 10), [])

    def test_clip_polygon(self):
        clipped = geo.clip_polygon_rect([(-5, -5), (5, -5), (5, 5), (-5, 5)], 0, 0, 10, 10)
        self.assertAlmostEqual(abs(geo.signed_area(clipped)), 25)

    def test_sample_polyline(self):
        pts = geo.sample_polyline([(0, 0), (100, 0)], 20)
        self.assertEqual(pts, [(10.0, 0.0), (30.0, 0.0), (50.0, 0.0), (70.0, 0.0), (90.0, 0.0)])

    def test_stable_unit_is_deterministic(self):
        self.assertEqual(geo.stable_unit("w123"), geo.stable_unit("w123"))
        self.assertTrue(0 <= geo.stable_unit("x") < 1)


class HeightTests(unittest.TestCase):
    def test_parse_length(self):
        self.assertEqual(parse_length("12"), 12.0)
        self.assertEqual(parse_length("12.5 m"), 12.5)
        self.assertEqual(parse_length("12,5"), 12.5)
        self.assertAlmostEqual(parse_length("10'"), 3.048)
        self.assertIsNone(parse_length("tall"))

    def test_height_sources(self):
        self.assertEqual(building_height({"building": "yes", "height": "20"}, "w1")[2], "osm:height")
        h, _, src = building_height({"building": "apartments", "building:levels": "5"}, "w2")
        self.assertEqual(src, "osm:levels")
        self.assertAlmostEqual(h, 15.5)
        h, _, src = building_height({"building": "yes"}, "w3")
        self.assertEqual(src, "estimated")
        self.assertTrue(9.0 <= h <= 19.0)

    def test_roof_is_walkable_under(self):
        h, min_h, _ = building_height({"building": "roof"}, "w4")
        self.assertGreater(min_h, 2.2)
        self.assertGreater(h, min_h)


def _overpass_fixture():
    """A tiny Overpass response: one building, one street, one POI, one park."""
    def way(way_id, tags, coords):
        return {"type": "way", "id": way_id, "tags": tags,
                "geometry": [{"lat": lat, "lon": lon} for lat, lon in coords]}
    lat0, lon0 = ORIGIN
    d = 0.0001  # ~11 m north/south, ~8.4 m east/west
    return {
        "osm3s": {"timestamp_osm_base": "2026-09-24T00:00:00Z"},
        "elements": [
            way(1, {"building": "apartments", "building:levels": "4"},
                [(lat0, lon0), (lat0, lon0 + d), (lat0 + d, lon0 + d), (lat0 + d, lon0), (lat0, lon0)]),
            way(2, {"highway": "pedestrian", "name": "Test Sokağı"},
                [(lat0 - 3 * d, lon0 - 30 * d), (lat0 - 3 * d, lon0 + 30 * d)]),
            way(3, {"highway": "footway", "tunnel": "yes"}, [(lat0, lon0), (lat0, lon0 + d)]),
            way(4, {"leisure": "park"},
                [(lat0 + 5 * d, lon0), (lat0 + 5 * d, lon0 + 5 * d), (lat0 + 10 * d, lon0 + 5 * d),
                 (lat0 + 10 * d, lon0), (lat0 + 5 * d, lon0)]),
            {"type": "node", "id": 9, "lat": lat0 - 2 * d, "lon": lon0, "tags": {"amenity": "cafe", "name": "Kafe"}},
            {"type": "node", "id": 10, "lat": lat0 + 1, "lon": lon0, "tags": {"amenity": "bench"}},
        ],
    }


class ZoneBuildTests(unittest.TestCase):
    def setUp(self):
        self.zone = ZoneBuilder("test", *ORIGIN, 512, 1, "Test").build(parse(_overpass_fixture()))

    def test_contents(self):
        self.assertEqual(len(self.zone["buildings"]), 1)
        self.assertEqual(self.zone["buildings"][0]["height_source"], "osm:levels")
        self.assertEqual([r["name"] for r in self.zone["roads"]], ["Test Sokağı"])  # tunnel skipped
        self.assertEqual([a["kind"] for a in self.zone["areas"]], ["park"])
        self.assertEqual([p["name"] for p in self.zone["pois"]], ["Kafe"])  # far node dropped

    def test_building_is_ccw_and_local(self):
        fp = self.zone["buildings"][0]["footprint"]
        self.assertGreater(geo.signed_area([tuple(p) for p in fp]), 0)
        self.assertTrue(all(abs(c) < 20 for p in fp for c in p))

    def test_spawn_points_avoid_buildings(self):
        spawns = compute_spawn_points(self.zone)
        self.assertGreater(len(spawns), 0)
        footprint = [tuple(p) for p in self.zone["buildings"][0]["footprint"]]
        for s in spawns:
            self.assertFalse(geo.point_in_polygon((s["e"], s["n"]), footprint))
            self.assertEqual(s["street"], "Test Sokağı")
            self.assertLessEqual(s["static_score"], 1.0)


class SyntheticZoneTests(unittest.TestCase):
    def test_synthetic_zone_is_consistent(self):
        zone = build_synthetic_zone("grid", 256)
        spawns = compute_spawn_points(zone)
        self.assertEqual(len(zone["buildings"]), 96)
        self.assertGreater(len(spawns), 20)
        half = zone["size_m"] / 2
        for s in spawns:
            self.assertTrue(abs(s["e"]) < half and abs(s["n"]) < half)
            for b in zone["buildings"]:
                self.assertFalse(geo.point_in_polygon((s["e"], s["n"]), [tuple(p) for p in b["footprint"]]))
        for i, a in enumerate(spawns):
            for b in spawns[i + 1:]:
                self.assertGreaterEqual(math.hypot(a["e"] - b["e"], a["n"] - b["n"]), 12.0 - 1e-6)


if __name__ == "__main__":
    unittest.main()


from zonegen import transit  # noqa: E402
from zonegen.osm import OsmData, OsmMember, OsmRelation, OsmWay  # noqa: E402


class TransitTests(unittest.TestCase):
    def test_short_line_name(self):
        self.assertEqual(transit.short_line_name("T3: Kadıköy ↔ Moda Nostaljik Tramvay Hattı"), "Kadıköy – Moda")

    def test_chain_orients_ways(self):
        a = [(0.0, 0.0), (0.0, 1.0)]
        b = [(0.0, 2.0), (0.0, 1.0)]  # stored backwards
        self.assertEqual(transit._chain([a, b]), [(0.0, 0.0), (0.0, 1.0), (0.0, 2.0)])

    def test_osm_loop_line(self):
        proj = geo.LocalProjection(*ORIGIN)
        lat0, lon0 = ORIGIN
        d = 0.001
        half1 = [(lat0, lon0), (lat0 + d, lon0), (lat0 + d, lon0 + d)]
        half2 = [(lat0 + d, lon0 + d), (lat0, lon0 + d), (lat0, lon0)]
        members = [OsmMember("node", 1, "stop", [(lat0 + d / 2, lon0)]),
                   OsmMember("node", 2, "stop", [(lat0 + d, lon0 + d / 2)]),
                   OsmMember("node", 3, "stop", [(lat0, lon0 + d / 2)]),
                   OsmMember("way", 10, "", half1), OsmMember("way", 11, "", half2)]
        rel = OsmRelation(99, {"route": "tram", "ref": "T9", "roundtrip": "yes", "name": "T9: A ↔ B"}, members)
        tracks = [OsmWay(10, {"railway": "tram"}, half1), OsmWay(11, {"railway": "tram"}, half2)]
        osm = OsmData(ways=tracks, routes=[rel], extra_node_tags={1: {"name": "Bir"}, 2: {"name": "İki"}})
        lines = transit.osm_lines(osm, proj, 512)
        self.assertEqual(len(lines), 1)
        line = lines[0]
        self.assertEqual(line["kind"], "loop")
        # 0.001 deg square: two sides of ~111 m (latitude) and two of ~84 m.
        self.assertAlmostEqual(line["length"], 2 * (111.1 + 84.0), delta=8)
        self.assertEqual([s["name"] for s in line["stops"]], ["Bir", "İki", "Durak 3"])
        arcs = [s["s"] for s in line["stops"]]
        self.assertEqual(arcs, sorted(arcs))

    def test_unbuilt_routes_are_ignored(self):
        proj = geo.LocalProjection(*ORIGIN)
        way = [(ORIGIN[0], ORIGIN[1]), (ORIGIN[0] + 0.001, ORIGIN[1])]
        rel = OsmRelation(5, {"route": "tram"}, [OsmMember("way", 7, "", way),
                                                 OsmMember("node", 1, "stop", [way[0]]),
                                                 OsmMember("node", 2, "stop", [way[1]])])
        self.assertEqual(transit.osm_lines(OsmData(routes=[rel]), proj, 512), [])

    def test_generated_network_on_grid(self):
        zone = build_synthetic_zone("grid", 256)
        lines = transit.build_transit(None, None, zone)["lines"]
        self.assertGreaterEqual(len(lines), 1)
        half = zone["size_m"] / 2
        for line in lines:
            self.assertEqual(line["source"], "generated")
            stops = line["stops"]
            self.assertGreaterEqual(len(stops), 2)
            arcs = [s["s"] for s in stops]
            self.assertEqual(arcs, sorted(arcs))
            for st in stops:
                # No terminus inside the boundary wall.
                self.assertLess(max(abs(st["e"]), abs(st["n"])), half - 5)
                plat = st["platform"]
                self.assertGreaterEqual(plat["r"], line["track_offset"] + 1.0)
                self.assertLessEqual(plat["r"], plat["r_room"] + 1.0)
