import tempfile
import unittest
from pathlib import Path

from beaconwatch import LocationStore, Position, distance_km, parse_beacon_position


class PacketParsingTests(unittest.TestCase):
    def test_parses_beacon_uncompressed_position(self):
        position = parse_beacon_position(
            "K6BAT-7>APB730,TCPIP*,qAC,T2TEST:!3341.23N/11749.80W>123/045Beacon 73"
        )
        self.assertIsNotNone(position)
        self.assertEqual(position.callsign, "K6BAT-7")
        self.assertAlmostEqual(position.latitude, 33.6871667, places=5)
        self.assertAlmostEqual(position.longitude, -117.83, places=5)

    def test_rejects_another_tocall(self):
        self.assertIsNone(
            parse_beacon_position("K6BAT-7>APRS,TCPIP*:!3341.23N/11749.80W>Beacon 73")
        )

    def test_rejects_non_position_packet(self):
        self.assertIsNone(parse_beacon_position("K6BAT-7>APB730,TCPIP*:>status"))

    def test_parses_timestamped_southern_eastern_position(self):
        position = parse_beacon_position(
            "VK1ABC>APB730,TCPIP*:@191230z3351.00S/15112.00E>Beacon 73"
        )
        self.assertEqual(position, Position("VK1ABC", -33.85, 151.2))


class LocationStoreTests(unittest.TestCase):
    def setUp(self):
        self.temporary_directory = tempfile.TemporaryDirectory()
        self.store = LocationStore(Path(self.temporary_directory.name) / "locations.db")

    def tearDown(self):
        self.temporary_directory.cleanup()

    def test_retains_first_point_within_250_km(self):
        first = Position("K6BAT-7", 33.68, -117.83)
        nearby = Position("K6BAT-7", 34.05, -118.24)
        self.assertEqual(self.store.record(first), "inserted")
        self.assertEqual(self.store.record(nearby), "unchanged")
        self.assertEqual(
            self.store.all(),
            [{"callsign": "K6BAT-7", "latitude": 33.68, "longitude": -117.83}],
        )

    def test_replaces_point_after_more_than_250_km(self):
        first = Position("K6BAT-7", 33.68, -117.83)
        moved = Position("K6BAT-7", 37.77, -122.42)
        self.assertGreater(distance_km(first, moved), 250)
        self.store.record(first)
        self.assertEqual(self.store.record(moved), "moved")
        self.assertEqual(self.store.all()[0]["latitude"], 37.77)

    def test_keeps_callsigns_separate(self):
        self.store.record(Position("K6BAT", 33.68, -117.83))
        self.store.record(Position("N6IPD-15", 40.0, -75.0))
        self.assertEqual([row["callsign"] for row in self.store.all()], ["K6BAT", "N6IPD-15"])


if __name__ == "__main__":
    unittest.main()
