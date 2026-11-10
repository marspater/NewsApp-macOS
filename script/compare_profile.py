"""Compares a profile run with the previous successful one (#577).

Reads each run's directory: summary.json (summarize_signposts.py) and metrics.json
(`xcresulttool get test-results metrics`). Prints a Markdown table of the medians beside the previous run's and a
GitHub `::warning::` for every value that grew past the tolerance. Never fails on a regression: CI runners differ
from run to run, so a slower number is a prompt to look at the trace, not a verdict.
Usage: compare_profile.py CURRENT_DIR [PREVIOUS_DIR] [--tolerance 0.25]
"""

# Standard library only: both inputs are JSON written by this workflow's own tools.
import json
import os
import statistics
import sys

# Signpost intervals this short are scheduling noise; their relative change says nothing.
SIGNPOST_FLOOR_MS = 1.0


def load(directory, name):
    path = os.path.join(directory, name) if directory else ""
    if not path or not os.path.isfile(path):
        return None
    with open(path) as handle:
        return json.load(handle)


def metric_medians(metrics):
    """{(test, metric name, unit): median} from xcresulttool's metrics JSON."""
    values = {}
    for test in metrics or []:
        name = test["testIdentifier"].rsplit("/", 1)[-1]
        for run in test.get("testRuns", []):
            for metric in run.get("metrics", []):
                if metric.get("measurements"):
                    key = (name, metric["displayName"], metric.get("unitOfMeasurement", ""))
                    values[key] = statistics.median(metric["measurements"])
    return values


def signpost_medians(summary):
    """{(category, interval, "ms"): median_ms} from summarize_signposts.py's JSON."""
    return {(i["category"], i["name"], "ms"): i["median_ms"] for i in (summary or {}).get("intervals", [])}


def compare(current, previous, tolerance, floor=0.0):
    """Rows (key, current, previous, change) and the keys whose value grew past the tolerance."""
    rows, regressions = [], []
    for key in sorted(current):
        now, before = current[key], previous.get(key)
        change = (now - before) / before if before else None
        rows.append((key, now, before, change))
        if change is not None and before >= floor and change > tolerance:
            regressions.append((key, change))
    return rows, regressions


def table(title, header, rows):
    lines = [f"### {title}", "", f"| {header} | Unit | Median | Previous | Change |", "|---|---|---:|---:|---:|"]
    for (first, second, unit), now, before, change in rows:
        previous = "–" if before is None else f"{before:.3f}"
        delta = "–" if change is None else f"{change:+.1%}"
        lines.append(f"| {first} · {second} | {unit} | {now:.3f} | {previous} | {delta} |")
    return lines


def main(argv):
    args = argv[1:]
    tolerance = 0.25
    if "--tolerance" in args:
        index = args.index("--tolerance")
        tolerance = float(args[index + 1])
        del args[index:index + 2]
    current_dir, previous_dir = args[0], (args[1] if len(args) > 1 else None)
    summary = load(current_dir, "summary.json")
    meta = (summary or {}).get("meta", {})
    lines = ["## Profile comparison", ""] + [f"- {key}: {value}" for key, value in meta.items()]
    previous_meta = (load(previous_dir, "summary.json") or {}).get("meta", {})
    # Runs before the Profile configuration recorded no configuration: they measured the Debug build.
    configuration = meta.get("configuration", "Debug")
    previous_configuration = previous_meta.get("configuration", "Debug")
    if previous_meta and previous_configuration != configuration:
        lines.append(
            f"- previous run measured the {previous_configuration} build, this one {configuration}: not compared")
        previous_dir, previous_meta = None, {}
    lines.append(f"- previous revision: {previous_meta.get('revision', 'none found')}")
    differing = [
        key for key in ("hardware", "os", "xcode") if previous_meta and previous_meta.get(key) != meta.get(key)]
    if differing:
        lines.append(f"- previous run differs in {', '.join(differing)}: changes may come from the runner")
    lines += [f"- tolerance: warn when a median grows more than {tolerance:.0%}", ""]
    warnings = []
    sections = [
        ("XCTest metrics", "Test · metric", metric_medians(load(current_dir, "metrics.json")),
         metric_medians(load(previous_dir, "metrics.json")), 0.0),
        ("Signpost intervals", "Category · interval", signpost_medians(summary),
         signpost_medians(load(previous_dir, "summary.json")), SIGNPOST_FLOOR_MS),
    ]
    for title, header, current, previous, floor in sections:
        if not current:
            lines += [f"### {title}", "", "No values in this run.", ""]
            continue
        rows, regressions = compare(current, previous, tolerance, floor)
        lines += table(title, header, rows) + [""]
        warnings += [f"{title}: {a} · {b} median grew {change:+.1%} over the previous run" for (a, b, _), change in
                     regressions]
    print("\n".join(lines))
    for warning in warnings:
        print(f"::warning::{warning}", file=sys.stderr)


if __name__ == "__main__":
    main(sys.argv)
