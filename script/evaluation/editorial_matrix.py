#!/usr/bin/env python3
"""Phase 0 editorial evaluation matrix command-line runner."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import os
import sqlite3
import tempfile
from pathlib import Path

from editorial_fixtures import (
    BASE,
    UTC,
    DeterministicFixtureRNG,
    schema,
    seed_articles,
    seed_personalization,
    seed_ranking,
)
from editorial_metrics import (
    eval_momentum,
    eval_novelty,
    eval_personalization,
    eval_ranking,
)

def create_empty_file_exclusive(path: Path) -> None:
    """Create a new private file atomically without replacing an existing path."""
    try:
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_RDWR, 0o600)
    except FileExistsError as error:
        raise SystemExit(f"Refusing to overwrite an existing file: {path}") from error
    os.close(descriptor)

def parse_args() -> argparse.Namespace:
    """Parse output, retained-database, and deterministic seed arguments."""
    parser = argparse.ArgumentParser(description="Build and evaluate the Phase 0 editorial evaluation matrix.")
    parser.add_argument(
        "--output",
        type=Path,
        default=Path("docs/benchmarks") / f"{dt.datetime.now(UTC):%Y-%m-%d}-editorial-matrix.json",
    )
    parser.add_argument(
        "--database",
        type=Path,
        help="Optional retained SQLite database path; temporary by default.",
    )
    parser.add_argument("--seed", type=int, default=20261105)
    return parser.parse_args()

def prepare_paths(
    args: argparse.Namespace,
) -> tuple[Path, Path, tempfile.TemporaryDirectory | None]:
    """Resolve output paths and refuse existing database, sidecar, or report files."""
    temporary = None
    sidecars = []
    if args.database is not None:
        db_path = args.database.expanduser().resolve()
        db_path.parent.mkdir(parents=True, exist_ok=True)
        sidecars = [Path(str(db_path) + suffix) for suffix in ("-wal", "-shm", "-journal")]
        if db_path.exists() or any(path.exists() for path in sidecars):
            raise SystemExit(f"Refusing to overwrite an existing SQLite database or sidecar: {db_path}")
    else:
        temporary = tempfile.TemporaryDirectory(prefix="news-editorial-phase0-")
        db_path = Path(temporary.name) / "editorial-phase0.sqlite3"

    output_path = args.output.expanduser().resolve()
    if output_path.exists():
        raise SystemExit(f"Refusing to overwrite an existing evaluation report: {output_path}")
    if args.database is not None and output_path in {db_path, *sidecars}:
        raise SystemExit("The report path must be different from the SQLite database and its sidecars")
    return db_path, output_path, temporary

def seed_phase_zero(
    db: sqlite3.Connection,
    rng: DeterministicFixtureRNG,
) -> tuple[dict[str, dict[str, str]], dict[str, float]]:
    """Create the schema and seed all controlled Phase 0 datasets."""
    schema(db)
    event_meta, timings = seed_articles(db, rng)
    timings["ranking_judgement_insert_ms"] = seed_ranking(db, rng)
    insert_ms, update_ms = seed_personalization(db, rng)
    timings["impression_insert_ms"] = insert_ms
    timings["impression_scroll_update_ms"] = update_ms
    return event_meta, timings

def validate_fixture(
    db: sqlite3.Connection,
    event_meta: dict[str, dict[str, str]],
) -> dict[str, object]:
    """Fail explicitly when the required corpus, event, ranking, or impression counts drift."""
    article_count = db.execute("SELECT count(*) FROM articles").fetchone()[0]
    scenario_counts = dict(db.execute("SELECT scenario,count(*) FROM articles GROUP BY scenario"))
    expected_scenarios = {"breaking": 2000, "slow_weekend": 1500, "syndication": 1500}
    passage_count = db.execute("SELECT count(*) FROM passages").fetchone()[0]
    ranking_count = db.execute("SELECT count(*) FROM ranking_judgements").fetchone()[0]
    impression_count = db.execute("SELECT count(*) FROM impressions").fetchone()[0]
    if article_count < 5000 or scenario_counts != expected_scenarios:
        raise RuntimeError(f"Unexpected article fixture: count={article_count}, scenarios={scenario_counts}")
    if len(event_meta) != 50 or passage_count != 5000:
        raise RuntimeError("The labelled event/passage fixture is incomplete")
    if ranking_count != 5000 or impression_count != 50000:
        raise RuntimeError("The ranking/impression fixture is incomplete")
    return {
        "article_count": article_count,
        "scenario_counts": scenario_counts,
        "event_count": len(event_meta),
        "passage_count": passage_count,
        "ranking_count": ranking_count,
        "impression_count": impression_count,
    }

def database_summary(
    db: sqlite3.Connection,
    args: argparse.Namespace,
    db_path: Path,
    timings: dict[str, float],
    fixture: dict[str, object],
) -> dict:
    """Build database counts, timings, and storage measurements for the report."""
    return {
        "retained_path": str(db_path) if args.database is not None else None,
        "article_count": fixture["article_count"],
        "scenario_counts": fixture["scenario_counts"],
        "event_count": fixture["event_count"],
        "independent_story_count": db.execute(
            "SELECT count(DISTINCT wire_group_id) FROM articles"
        ).fetchone()[0],
        "passage_count": fixture["passage_count"],
        "sentence_count": db.execute("SELECT count(*) FROM passage_sentences").fetchone()[0],
        "entity_anchored_sentence_count": db.execute(
            "SELECT count(*) FROM passage_sentences WHERE has_core_entity=1"
        ).fetchone()[0],
        "ranking_judgement_count": fixture["ranking_count"],
        "impression_count": fixture["impression_count"],
        "timings_ms": timings,
        "sqlite_file_bytes": db_path.stat().st_size,
    }

def build_matrix(
    db: sqlite3.Connection,
    args: argparse.Namespace,
    db_path: Path,
    event_meta: dict[str, dict[str, str]],
    timings: dict[str, float],
    fixture: dict[str, object],
) -> dict:
    """Assemble the reproducible quality and performance matrix for Phase 0."""
    return {
        "schema_version": 1,
        "generated_at": dt.datetime.now(UTC).isoformat(timespec="seconds"),
        "seed": args.seed,
        "phase": 0,
        "phase_zero_gate": "PASS",
        "database": database_summary(db, args, db_path, timings, fixture),
        "novelty_extraction": eval_novelty(db, event_meta),
        "momentum": eval_momentum(db),
        "ranking": eval_ranking(db),
        "personalization": eval_personalization(db),
        "hardware": {
            "ane_spin_up_ms": None,
            "ane_cpu_power_draw": None,
            "vector_cache_hit_rate": None,
            "reason": "Intentionally not invoked in Phase 0; this matrix gates Phase 1 Core ML/vDSP work.",
        },
        "phase_zero_constraints": {
            "coreml_invocations": 0,
            "vDSP_invocations": 0,
            "third_party_dependencies": 0,
            "production_database_migrations": 0,
            "production_consumers_changed": 0,
        },
        "limitations": [
            "Synthetic controls test fixture routing and metric calculations; they are not manually adjudicated language-quality labels.",
            "Net-new fact precision, full MACD accuracy, MMR semantic diversity and EWMA vector update cost remain pending later phases and real holdouts.",
            "The volume-floor sweep counts distinct wire groups; it is not a MACD result or a selected production threshold.",
            "The ranking baseline sorts source-Elo metadata; it is not MMR and does not use vectors.",
            "Recommendation relevance and discovery use synthetic topic labels and an 85/15 exposure fixture; they do not represent a trained reader profile.",
            "ANE spin-up and ANE/CPU power telemetry require a separate Apple-silicon hardware run after Phase 0 is accepted.",
        ],
    }

def write_report(
    output_path: Path,
    matrix: dict,
    db_path: Path,
    args: argparse.Namespace,
    fixture: dict[str, object],
) -> None:
    """Write the JSON report exclusively and print the run's key dimensions."""
    output_path.parent.mkdir(parents=True, exist_ok=True)
    with output_path.open("x", encoding="utf-8") as report_file:
        json.dump(matrix, report_file, indent=2, sort_keys=True)
        report_file.write("\n")
    print(
        f"Phase 0 matrix: {fixture['article_count']} articles, "
        f"{fixture['event_count']} events, {fixture['passage_count']} passages"
    )
    print(f"Scenario counts: {fixture['scenario_counts']}")
    print(f"Report: {output_path}")
    if args.database is not None:
        print(f"SQLite: {db_path}")
    print("Core ML invocations: 0; vDSP invocations: 0")

def run_phase_zero(args: argparse.Namespace, db_path: Path, output_path: Path) -> None:
    """Run the SQLite seed, integrity gates, evaluations, and JSON export."""
    rng = DeterministicFixtureRNG(args.seed)
    create_empty_file_exclusive(db_path)
    db = sqlite3.connect(db_path)
    try:
        db.execute("PRAGMA busy_timeout=5000")
        event_meta, timings = seed_phase_zero(db, rng)
        fixture = validate_fixture(db, event_meta)
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        matrix = build_matrix(db, args, db_path, event_meta, timings, fixture)
        write_report(output_path, matrix, db_path, args, fixture)
    finally:
        db.close()

def main() -> int:
    """Build the Phase 0 corpus, run its evaluation matrix, and write JSON output."""
    args = parse_args()
    db_path, output_path, temporary = prepare_paths(args)
    try:
        run_phase_zero(args, db_path, output_path)
    finally:
        if temporary is not None:
            temporary.cleanup()
    return 0

if __name__ == "__main__":
    raise SystemExit(main())
