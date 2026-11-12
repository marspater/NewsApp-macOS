import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import summarize_launches

PREFIX = "2026-11-12 10:00:00.000000+0100 0x1 Default 0x0 100 0 News: [com.marspater.news:Launch] "
# A build before #1243: no restore line and no restored= field.
BASELINE = PREFIX + "Launch milestone list_page_fetched ms_since_process_start=800.000\n" \
    + PREFIX + "First card visible ms_since_process_start=900.500\n"
COLD = PREFIX + "Launch milestone list_page_fetched ms_since_process_start=850.000\n" \
    + PREFIX + "Launch event today_edition_restored outcome=none ms_since_process_start=860.000\n" \
    + PREFIX + "Launch milestone today_edition_requested ms_since_process_start=861.000\n" \
    + PREFIX + "Today edition stage=context ms=40.500 count=200\n" \
    + PREFIX + "Today edition stage=assignment ms=60.250 count=150\n" \
    + PREFIX + "Launch milestone today_edition_installed ms_since_process_start=1000.000\n" \
    + PREFIX + "First card visible ms_since_process_start={card} restored=false\n"
WARM = PREFIX + "Launch event today_edition_restored outcome=shown ms_since_process_start=870.000\n" \
    + PREFIX + "First card visible ms_since_process_start={card} restored=true\n" \
    + PREFIX + "Launch event today_fresh_edition_ready outcome={outcome} scrolled=false focused=false " \
    "reading=false lane_moved=false voiceover=false new_day=false ms_since_process_start=1040.000\n"
FOOTPRINT = """News [1]: 64-bit    Footprint: 419 MB (16384 bytes per page)

  Dirty      Clean  Reclaimable    Regions    Category
    ---        ---          ---        ---    ---
 190 MB        0 B        60 MB        143    Malloc Small
  21 MB        0 B          0 B        165    CG Raster Data
{layers}        0 B        16 KB         57    CoreAnimation
3200 KB        0 B          0 B        136    IOSurface
  16 KB        0 B          0 B          1    IOAccelerator (graphics)
 419 MB     155 MB        72 MB       9701    TOTAL

Auxiliary data:
    phys_footprint: 419 MB
    phys_footprint_peak: 1.2 GB
"""


class ParseTests(unittest.TestCase):
    def test_baseline_line_without_restored_field(self):
        launch = summarize_launches.parse_launch(BASELINE)
        self.assertEqual(launch["first_card_ms"], 900.5)
        self.assertIsNone(launch["restored"])
        self.assertIsNone(launch["restore_outcome"])

    def test_cold_and_warm_launches(self):
        cold = summarize_launches.parse_launch(COLD.format(card="1100.000"))
        self.assertEqual(
            (cold["restored"], cold["restore_outcome"], cold["today_edition_installed_ms"], cold["assignment_ms"]),
            (False, "none", 1000.0, 60.25))
        warm = summarize_launches.parse_launch(WARM.format(card="940.000", outcome="swapped"))
        self.assertEqual(
            (warm["restored"], warm["restore_outcome"], warm["fresh_outcome"], warm["fresh_ready_ms"]),
            (True, "shown", "swapped", 1040.0))
        self.assertIsNone(warm["today_edition_installed_ms"])

    def test_footprint_regions_and_units(self):
        memory = summarize_launches.parse_footprint(FOOTPRINT.format(layers="  62 MB"))
        self.assertEqual(memory["footprint_mb"], 419)
        self.assertEqual(memory["peak_mb"], 1228.8)
        self.assertEqual(memory["CoreAnimation"], 62)
        self.assertEqual(memory["CG Raster Data"], 21)
        self.assertEqual(memory["IOSurface"], 3.125)
        self.assertIsNone(memory["Malloc Large"])

    def test_p95_is_nearest_rank(self):
        self.assertEqual(summarize_launches.p95(list(range(1, 21))), 19)
        self.assertEqual(summarize_launches.p95([5]), 5)


class SummaryTests(unittest.TestCase):
    def write(self, directory, name, text):
        with open(os.path.join(directory, name), "w") as handle:
            handle.write(text)

    def test_arms_are_gated_and_the_first_round_is_discarded(self):
        with tempfile.TemporaryDirectory() as directory:
            for round_number, card in enumerate(("5000.000", "1100.000", "1200.000"), start=1):
                self.write(directory, f"r{round_number}-baseline.log", BASELINE)
                self.write(directory, f"r{round_number}-cold.log", COLD.format(card=card))
                self.write(directory, f"r{round_number}-cold.load", "3.5\n")
                self.write(directory, f"r{round_number}-cold.settled.footprint", FOOTPRINT.format(layers="  62 MB"))
            # A warm launch that fell back to the wait, and a swap launch whose fresh edition only confirmed.
            self.write(directory, "r2-warm.log", COLD.format(card="1150.000"))
            self.write(directory, "r3-warm.log", WARM.format(card="940.000", outcome="confirmed"))
            self.write(directory, "r2-swap.log", WARM.format(card="950.000", outcome="confirmed"))
            self.write(directory, "r3-swap.log", WARM.format(card="960.000", outcome="swapped"))
            self.write(directory, "r3-swap.settled.footprint", FOOTPRINT.format(layers="  80 MB"))
            self.write(directory, "r3-swap.scrolled.footprint", FOOTPRINT.format(layers=" 350 MB"))
            summarize_launches.main(["x", directory, "--meta", "revision=abc"])
            with open(os.path.join(directory, "summary.json")) as handle:
                result = json.load(handle)
            with open(os.path.join(directory, "summary.md")) as handle:
                report = handle.read()
        arms = result["arms"]
        self.assertEqual(result["meta"], {"revision": "abc"})
        self.assertEqual(arms["baseline"]["first_card_ms"]["median"], 900.5)
        self.assertEqual(arms["cold"]["launches"], 2)
        self.assertEqual(arms["cold"]["first_card_ms"], {"n": 2, "median": 1150.0, "p95": 1200.0, "min": 1100.0,
                                                         "max": 1200.0})
        self.assertEqual(arms["cold"]["memory"]["settled"]["CoreAnimation"]["median"], 62)
        self.assertEqual(arms["cold"]["load1"]["max"], 3.5)
        self.assertEqual((arms["cold"]["context_ms"]["median"], arms["cold"]["assignment_ms"]["median"]), (40.5, 60.25))
        self.assertIn("| cold | 2 | 0 | 1150 | 1200 | 1100 to 1200 | – | 40 | 60 | 3.5 to 3.5 |", report)
        self.assertEqual(arms["warm"]["launches"], 1)
        self.assertEqual(arms["warm"]["excluded"], [{"round": 2, "reason": "restored=False, restore_outcome=none"}])
        self.assertEqual(arms["warm"]["fresh_ready_ms"]["median"], 1040.0)
        self.assertEqual(arms["swap"]["excluded"], [{"round": 2, "reason": "fresh_outcome=confirmed"}])
        self.assertEqual(arms["swap"]["memory"]["scrolled"]["CoreAnimation"]["median"], 350)
        self.assertIn("| swap | scrolled | 419 | 1229 (1229) | 350 |", report)
        self.assertIn("- excluded: swap round 2: fresh_outcome=confirmed", report)


if __name__ == "__main__":
    unittest.main()
