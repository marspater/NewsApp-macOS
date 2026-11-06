"""Export event-disjoint synthetic momentum controls from the Phase 0 SQLite fixture."""
from __future__ import annotations

import argparse
import json
import os
import sqlite3
from pathlib import Path
from urllib.parse import quote


def export(database: Path, output: Path) -> None:
    """Read only the supplied fixture and create a new private, deterministic input file."""
    output = output.expanduser().resolve()
    if output.exists():
        raise SystemExit(f"Refusing to overwrite an existing momentum input file: {output}")
    connection = sqlite3.connect("file:" + quote(str(database.resolve())) + "?mode=ro", uri=True)
    try:
        cases = []
        windows = connection.execute(
            "SELECT event_id,scenario,window_start,window_end,expected_burst FROM event_windows ORDER BY event_id"
        ).fetchall()
        for event_id, scenario, start, end, expected in windows:
            rows = connection.execute(
                "SELECT id,wire_group_id,publisher,independent_publisher,published_at,fetched_at "
                "FROM articles WHERE event_id=? ORDER BY id", (event_id,)
            ).fetchall()
            cases.append({
                "eventID": event_id, "scenario": scenario,
                "split": "tune" if int(event_id.rsplit("-", 1)[1]) % 2 == 0 else "holdout",
                "windowStart": start, "through": end, "expectedBurst": bool(expected),
                "reports": [dict(zip(
                    ("articleID", "wireGroupID", "localPublisherID", "originPublisherID", "publishedAt", "fetchedAt"), row
                )) for row in rows],
            })
        if len(cases) != 50 or sum(len(case["reports"]) for case in cases) != 5000:
            raise RuntimeError("Expected the complete 50-event, 5000-article Phase 0 fixture")
        descriptor = os.open(output, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump({"basis": "synthetic_phase_zero_controls", "cases": cases}, stream, sort_keys=True)
            stream.write("\n")
    finally:
        connection.close()


def main() -> None:
    """Parse fixture and output paths."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--database", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    export(args.database, args.output)


if __name__ == "__main__":
    main()
