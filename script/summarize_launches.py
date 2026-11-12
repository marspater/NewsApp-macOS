"""Summarizes the launches recorded by script/paired_launch.sh (#937).

Reads <dir>/r<round>-<arm>.log (the app's Launch log lines of one launch), the `footprint` reports beside it
(r<round>-<arm>.<checkpoint>.footprint) and r<round>-<arm>.load, and writes <dir>/summary.json and summary.md: per arm
the first card's median, p95 and range, the fresh edition behind a restored one, and memory per checkpoint.

A launch counts for its arm only when its log shows the state the arm stands for (ARMS); the others are listed as
excluded with what they showed. The first round is discarded as warm-up.
Usage: summarize_launches.py DIR [--discard N] [--meta key=value ...]
"""

# Standard library only: the inputs are the app's own log lines and footprint's report from the same run.
import glob
import json
import math
import os
import re
import statistics
import sys

# What a launch's log must show to count for its arm: (first card restored, today_edition_restored outcome,
# today_fresh_edition_ready outcome); None accepts anything. A build before #1243 logs none of the three.
ARMS = {
    "baseline": (None, None, None),
    "cold": (False, "none", None),
    "warm": (True, "shown", None),
    "swap": (True, "shown", "swapped"),
}
# The regions the image budget is read from (dirty megabytes in footprint's table).
CATEGORIES = ("CoreAnimation", "CG Raster Data", "IOSurface", "Malloc Small", "Malloc Large")
MS = r"ms_since_process_start=([\d.]+)"
UNITS = {"B": 1 / 1048576, "KB": 1 / 1024, "MB": 1, "GB": 1024}


def completed_today_stages(text):
    """Only pair stage timings from one complete, unambiguous Today assignment.

    StageTimer has no task ID. Multiple attempts or interleaved tasks cannot be safely paired,
    so reject their stage timings rather than combining unrelated operations.
    """
    stages = re.findall(
        r"Today edition stage=(context|event_images|assignment|differing_accounts|layout) ms=([\d.]+)", text)
    if [stage for stage, _ in stages] != [
        "context", "event_images", "assignment", "differing_accounts", "layout"
    ]:
        return None, None
    return float(stages[0][1]), float(stages[2][1])


def parse_launch(text):
    """The launch's stages from its Launch log lines; a line the build does not write leaves its field None."""

    def first(pattern, convert=float):
        match = re.search(pattern, text)
        return convert(match[1]) if match else None

    fresh = re.search(r"today_fresh_edition_ready outcome=(\w+).*?" + MS, text)
    context_ms, assignment_ms = completed_today_stages(text)
    return {
        "first_card_ms": first(r"First card visible " + MS),
        "restored": first(r"First card visible .*?restored=(true|false)", lambda value: value == "true"),
        "restore_outcome": first(r"today_edition_restored outcome=(\w+)", str),
        "fresh_outcome": fresh[1] if fresh else None,
        "fresh_ready_ms": float(fresh[2]) if fresh else None,
        "list_page_fetched_ms": first(r"Launch milestone list_page_fetched " + MS),
        "today_edition_requested_ms": first(r"Launch milestone today_edition_requested " + MS),
        # Milestones stop at the first card, so a launch that shows a restored edition never logs this one.
        "today_edition_installed_ms": first(r"Launch milestone today_edition_installed " + MS),
        "context_ms": context_ms,
        "assignment_ms": assignment_ms,
    }


def megabytes(number, unit):
    return round(float(number) * UNITS[unit], 3)


def parse_footprint(text):
    """Physical footprint, its peak and the dirty size of each region of interest, in MB, from `footprint -p`."""
    result = {}
    for key, label in (("footprint_mb", "phys_footprint"), ("peak_mb", "phys_footprint_peak")):
        match = re.search(rf"^\s*{label}: ([\d.]+) (B|KB|MB|GB)\s*$", text, re.MULTILINE)
        result[key] = megabytes(match[1], match[2]) if match else None
    for category in CATEGORIES:
        match = re.search(
            rf"^\s*([\d.]+) (B|KB|MB|GB)\s+[\d.]+ \w+\s+[\d.]+ \w+\s+\d+\s+{re.escape(category)}\s*$", text, re.MULTILINE)
        result[category] = megabytes(match[1], match[2]) if match else None
    return result


def p95(values):
    """Nearest rank: the smallest value with at least 95 % of the launches at or below it."""
    ordered = sorted(values)
    return ordered[max(0, math.ceil(0.95 * len(ordered)) - 1)]


def spread(values):
    values = [value for value in values if value is not None]
    if not values:
        return None
    return {"n": len(values), "median": round(statistics.median(values), 3), "p95": p95(values),
            "min": min(values), "max": max(values)}


def read(path):
    with open(path) as handle:  # NOSONAR  the directory is the operator's own command-line choice
        return handle.read()


def load_launches(directory):
    launches = []
    for path in sorted(glob.glob(os.path.join(directory, "r*-*.log"))):
        match = re.fullmatch(r"r(\d+)-(\w+)\.log", os.path.basename(path))
        if not match:
            continue
        stem = path[:-len(".log")]
        launch = {"round": int(match[1]), "arm": match[2], **parse_launch(read(path)), "memory": {}}
        for report in sorted(glob.glob(stem + ".*.footprint")):
            launch["memory"][report[len(stem) + 1:-len(".footprint")]] = parse_footprint(read(report))
        if os.path.isfile(stem + ".load"):
            launch["load1"] = float(read(stem + ".load").split()[0])
        launches.append(launch)
    return sorted(launches, key=lambda launch: (launch["round"], launch["arm"]))


def mismatch(launch):
    """Why the launch does not count for its arm, or None when it does."""
    if launch["first_card_ms"] is None:
        return "no first card"
    # A labelled arm (cold_integration) is gated as its kind.
    expected = ARMS.get(launch["arm"].split("_")[0])
    if expected is None:
        return None
    seen = (launch["restored"], launch["restore_outcome"], launch["fresh_outcome"])
    names = ("restored", "restore_outcome", "fresh_outcome")
    if launch["arm"].split("_")[0] == "baseline" and any(value is not None for value in seen):
        return "Today state markers present in baseline"
    wrong = [f"{name}={got}" for name, want, got in zip(names, expected, seen) if want is not None and got != want]
    if wrong:
        return ", ".join(wrong)
    if (launch["arm"].split("_")[0] == "swap"
            and launch["memory"].get("settled", {}).get("footprint_mb") is None):
        return "no post-swap settled footprint"
    return None


def summarize(launches, discard=1):
    arms = {}
    for launch in launches:
        if launch["round"] <= discard:
            continue
        arm = arms.setdefault(launch["arm"], {"counted": [], "excluded": []})
        reason = mismatch(launch)
        if reason:
            arm["excluded"].append({"round": launch["round"], "reason": reason})
        else:
            arm["counted"].append(launch)
    summary = {}
    for name, arm in arms.items():
        counted = arm["counted"]
        outcomes = {}
        for launch in counted:
            outcome = launch["fresh_outcome"] or "none"
            outcomes[outcome] = outcomes.get(outcome, 0) + 1
        checkpoints = sorted({checkpoint for launch in counted for checkpoint in launch["memory"]})
        summary[name] = {
            "launches": len(counted),
            "excluded": arm["excluded"],
            "first_card_ms": spread([launch["first_card_ms"] for launch in counted]),
            "fresh_ready_ms": spread([launch["fresh_ready_ms"] for launch in counted]),
            "fresh_outcomes": outcomes,
            # The fresh edition's own stages: the context read and the lane assignment (Athena · attention).
            "context_ms": spread([launch["context_ms"] for launch in counted]),
            "assignment_ms": spread([launch["assignment_ms"] for launch in counted]),
            "load1": spread([launch.get("load1") for launch in counted]),
            "memory": {
                checkpoint: {
                    key: spread([launch["memory"].get(checkpoint, {}).get(key) for launch in counted])
                    for key in ("footprint_mb", "peak_mb") + CATEGORIES
                }
                for checkpoint in checkpoints
            },
        }
    return summary


def cell(value, key="median"):
    return "–" if value is None else f"{value[key]:.0f}"


def markdown(summary, meta):
    lines = [f"- {key}: {value}" for key, value in meta.items()]
    header = ("| Arm | Launches | Excluded | First card median ms | p95 | Range | Fresh edition median ms "
              "| Context median ms | Assignment median ms | Load |")
    lines += ["", header, "|---|---:|---:|---:|---:|---|---:|---:|---:|---|"]
    for name, arm in summary.items():
        card, load = arm["first_card_ms"], arm["load1"]
        span = "–" if card is None else f"{card['min']:.0f} to {card['max']:.0f}"
        busy = "–" if load is None else f"{load['min']:.1f} to {load['max']:.1f}"
        lines.append(
            f"| {name} | {arm['launches']} | {len(arm['excluded'])} | {cell(card)} | {cell(card, 'p95')} | {span} "
            f"| {cell(arm['fresh_ready_ms'])} | {cell(arm['context_ms'])} | {cell(arm['assignment_ms'])} | {busy} |")
    lines += ["", "| Arm | Checkpoint | Footprint median MB | Peak median (highest) MB | "
              + " | ".join(CATEGORIES) + " |", "|---|---|---:|---:|" + "---:|" * len(CATEGORIES)]
    for name, arm in summary.items():
        for checkpoint, memory in arm["memory"].items():
            peak = memory["peak_mb"]
            highest = "–" if peak is None else f"{peak['median']:.0f} ({peak['max']:.0f})"
            regions = " | ".join(cell(memory[category]) for category in CATEGORIES)
            lines.append(f"| {name} | {checkpoint} | {cell(memory['footprint_mb'])} | {highest} | {regions} |")
    lines.append("")
    for name, arm in summary.items():
        for excluded in arm["excluded"]:
            lines.append(f"- excluded: {name} round {excluded['round']}: {excluded['reason']}")
    return lines


def main(argv):
    args = argv[1:]
    meta = {}
    if "--meta" in args:
        index = args.index("--meta")
        meta = {key: value for key, value in (item.split("=", 1) for item in args[index + 1:])}
        del args[index:]
    discard = 1
    if "--discard" in args:
        index = args.index("--discard")
        discard = int(args[index + 1])
        del args[index:index + 2]
    directory = args[0]
    launches = load_launches(directory)
    if not launches:
        sys.exit(f"No r<round>-<arm>.log files in {directory}")
    summary = summarize(launches, discard)
    with open(os.path.join(directory, "summary.json"), "w") as handle:  # NOSONAR
        json.dump({"meta": meta, "discarded_rounds": discard, "arms": summary, "launches": launches}, handle, indent=2)
        handle.write("\n")
    lines = markdown(summary, meta)
    with open(os.path.join(directory, "summary.md"), "w") as handle:  # NOSONAR
        handle.write("\n".join(lines) + "\n")
    print("\n".join(lines))


if __name__ == "__main__":
    main(sys.argv)
