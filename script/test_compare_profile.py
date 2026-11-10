import contextlib
import io
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import compare_profile


def metrics(clock):
    return [{"testIdentifier": "NewsPerformanceTests/testLaunchToMainWindow()", "testRuns": [{"metrics": [
        {"displayName": "Clock Monotonic Time", "unitOfMeasurement": "s", "measurements": clock}]}]}]


def summary(revision, intervals, **meta):
    return {"meta": {"revision": revision, **meta}, "intervals": [
        {"category": "Feeds", "name": name, "count": 1, "median_ms": ms, "p90_ms": ms} for name, ms in intervals]}


def write(directory, name, value):
    with open(os.path.join(directory, name), "w") as handle:
        json.dump(value, handle)


class CompareTests(unittest.TestCase):
    def run_main(self, current, previous):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            compare_profile.main(["x", current] + ([previous] if previous else []))
        return out.getvalue(), err.getvalue()

    def test_warns_past_tolerance_and_ignores_short_intervals(self):
        with tempfile.TemporaryDirectory() as now, tempfile.TemporaryDirectory() as before:
            write(now, "metrics.json", metrics([1.0, 1.4, 1.5]))
            write(before, "metrics.json", metrics([1.0, 1.1, 1.2]))
            write(now, "summary.json", summary("b", [("Refresh", 120.0), ("Tick", 0.9)]))
            write(before, "summary.json", summary("a", [("Refresh", 100.0), ("Tick", 0.3)]))
            table, warnings = self.run_main(now, before)
        self.assertIn("previous revision: a", table)
        self.assertIn("| testLaunchToMainWindow() · Clock Monotonic Time | s | 1.400 | 1.100 | +27.3% |", table)
        self.assertIn("| Feeds · Refresh | ms | 120.000 | 100.000 | +20.0% |", table)
        self.assertEqual(warnings.count("::warning::"), 1)
        self.assertIn("Clock Monotonic Time median grew +27.3%", warnings)

    def test_first_run_has_no_previous_values(self):
        with tempfile.TemporaryDirectory() as now:
            write(now, "summary.json", summary("b", [("Refresh", 120.0)]))
            table, warnings = self.run_main(now, None)
        self.assertIn("previous revision: none found", table)
        self.assertIn("| Feeds · Refresh | ms | 120.000 | – | – |", table)
        self.assertIn("XCTest metrics\n\nNo values in this run.", table)
        self.assertEqual(warnings, "")

    def test_no_ratio_against_a_negative_baseline(self):
        rows, regressions = compare_profile.compare({("t", "m", "kB"): 10.0}, {("t", "m", "kB"): -32.0}, 0.25)
        self.assertEqual(rows, [(("t", "m", "kB"), 10.0, -32.0, None)])
        self.assertEqual(regressions, [])

    def test_skips_a_previous_run_of_another_configuration(self):
        with tempfile.TemporaryDirectory() as now, tempfile.TemporaryDirectory() as before:
            write(now, "metrics.json", metrics([2.0]))
            write(before, "metrics.json", metrics([1.0]))
            write(now, "summary.json", summary("b", [("Refresh", 120.0)], configuration="Profile"))
            write(before, "summary.json", summary("a", [("Refresh", 10.0)]))
            table, warnings = self.run_main(now, before)
        self.assertIn("previous run measured the Debug build, this one Profile: not compared", table)
        self.assertIn("| testLaunchToMainWindow() · Clock Monotonic Time | s | 2.000 | – | – |", table)
        self.assertEqual(warnings, "")


if __name__ == "__main__":
    unittest.main()
