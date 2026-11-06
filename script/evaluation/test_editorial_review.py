"""Regression controls for fixed novelty labels and retained WAL database size."""
import argparse
import json
import sqlite3
import tempfile
import unittest
from pathlib import Path

from script.evaluation import editorial_fixtures, editorial_matrix, editorial_metrics


class NoveltyGateTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.db = sqlite3.connect(":memory:")
        cls.meta, _ = editorial_matrix.seed_phase_zero(
            cls.db, editorial_fixtures.DeterministicFixtureRNG(20261105)
        )
        cls.novelty = editorial_metrics.eval_novelty(cls.db, cls.meta)

    @classmethod
    def tearDownClass(cls):
        cls.db.close()

    def test_relabelled_controls_fail_even_when_total_is_unchanged(self):
        for source, destination in (("semantic_fallback", "repetition"), ("potentially_new", "repetition"),
                                    ("repetition", "semantic_fallback")):
            with self.subTest(source=source):
                self.db.execute("SAVEPOINT relabel")
                self.db.execute(
                    "UPDATE passages SET expected_class=? WHERE rowid=(SELECT rowid FROM passages WHERE expected_class=? LIMIT 1)",
                    (destination, source),
                )
                with self.assertRaisesRegex(RuntimeError, "control classes"):
                    editorial_matrix.validate_novelty_gate(self.db, self.novelty)
                self.db.execute("ROLLBACK TO relabel")
                self.db.execute("RELEASE relabel")

    def test_seeded_classes_pass(self):
        self.assertEqual(editorial_matrix.validate_novelty_gate(self.db, self.novelty)["fallback_passages"], 700)


class RetainedDatabaseTests(unittest.TestCase):
    def test_report_size_includes_committed_fallback_queue(self):
        with tempfile.TemporaryDirectory() as directory:
            db_path = Path(directory) / "fixture.sqlite"
            output = Path(directory) / "report.json"
            args = argparse.Namespace(seed=20261105, database=db_path, output=output)
            editorial_matrix.run_phase_zero(args, db_path, output)
            report = json.loads(output.read_text())
            self.assertEqual(report["database"]["sqlite_file_bytes"], db_path.stat().st_size)
            with sqlite3.connect(db_path) as db:
                self.assertEqual(db.execute("SELECT count(*) FROM semantic_fallback_queue").fetchone()[0], 700)
                busy, log, checkpointed = db.execute("PRAGMA wal_checkpoint(PASSIVE)").fetchone()
                self.assertEqual((busy, log, checkpointed), (0, 0, 0))


if __name__ == "__main__":
    unittest.main()
