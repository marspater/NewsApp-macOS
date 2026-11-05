"""Regressions for the Phase 0 validation and reproducibility boundary."""
from __future__ import annotations

import argparse
import sqlite3
import tempfile
import unittest
from pathlib import Path

from script.evaluation import editorial_fixtures, editorial_matrix


class MatrixValidationTests(unittest.TestCase):
    """Exercise the actual seeded schema, not copies of validation rules."""

    @classmethod
    def setUpClass(cls) -> None:
        """Keep a pristine deterministic seed for independent mutation controls."""
        cls.seed = sqlite3.connect(":memory:")
        cls.meta, _ = editorial_matrix.seed_phase_zero(
            cls.seed, editorial_fixtures.DeterministicFixtureRNG(20261105)
        )

    @classmethod
    def tearDownClass(cls) -> None:
        """Close the private seed."""
        cls.seed.close()

    def setUp(self) -> None:
        """Copy the seed so each failure injection is isolated."""
        self.db = sqlite3.connect(":memory:")
        self.seed.backup(self.db)
        self.addCleanup(self.db.close)

    def test_complete_fixture(self) -> None:
        """The default corpus satisfies structural checks."""
        result = editorial_matrix.validate_fixture(self.db, self.meta)
        self.assertEqual(result["article_count"], 5000)
        self.assertGreater(result["impression_count"], 50000)

    def test_each_ranking_set_is_checked(self) -> None:
        """Keeping the total unchanged cannot conceal an incomplete query."""
        self.db.execute(
            "UPDATE ranking_judgements SET query_id='extra' WHERE rowid IN "
            "(SELECT rowid FROM ranking_judgements LIMIT 1)"
        )
        with self.assertRaisesRegex(RuntimeError, "ten ranking"):
            editorial_matrix.validate_fixture(self.db, self.meta)

    def test_impression_before_availability_fails(self) -> None:
        """Impossible exposure times fail before metrics are published."""
        self.db.execute("UPDATE impressions SET rendered_at=0 WHERE id=1")
        with self.assertRaisesRegex(RuntimeError, "precedes availability"):
            editorial_matrix.validate_fixture(self.db, self.meta)

    def test_non_neutral_default_fails(self) -> None:
        """The agreed baseline never silently assigns publisher scores."""
        self.db.execute("UPDATE articles SET source_elo=999 WHERE rowid=1")
        with self.assertRaisesRegex(RuntimeError, "neutral"):
            editorial_matrix.validate_fixture(self.db, self.meta)

    def test_logical_hash_excludes_storage_layout(self) -> None:
        """Identical logical data has identical fixture and label hashes."""
        original = editorial_matrix.provenance(self.db)
        self.db.execute("VACUUM")
        repeated = editorial_matrix.provenance(self.db)
        self.assertEqual(original, repeated)
        self.db.execute("UPDATE passage_sentences SET expected_new_fact=1-expected_new_fact WHERE rowid=1")
        changed = editorial_matrix.provenance(self.db)
        self.assertNotEqual(original["labels_sha256"], changed["labels_sha256"])


class OutputProtectionTests(unittest.TestCase):
    """No invocation replaces a previous report or SQLite sidecar."""

    def test_existing_database_sidecar_is_preserved(self) -> None:
        """Refuse even when only an old WAL exists."""
        with tempfile.TemporaryDirectory() as directory:
            database = Path(directory) / "fixture.sqlite3"
            wal = Path(str(database) + "-wal")
            wal.write_text("preserve")
            args = argparse.Namespace(database=database, output=Path(directory) / "report.json")
            with self.assertRaises(SystemExit):
                editorial_matrix.prepare_paths(args)
            self.assertEqual(wal.read_text(), "preserve")

    def test_report_cannot_alias_database(self) -> None:
        """The database and report must have distinct paths."""
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture"
            args = argparse.Namespace(database=path, output=path)
            with self.assertRaises(SystemExit):
                editorial_matrix.prepare_paths(args)


class GitRevisionTests(unittest.TestCase):
    """Provenance resolves normal, detached and linked-worktree Git metadata."""

    def test_detached_and_loose_reference(self) -> None:
        """Read both forms without spawning a subprocess."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            git_dir = root / ".git"
            (git_dir / "refs/heads").mkdir(parents=True)
            revision = "a" * 40
            (git_dir / "HEAD").write_text(revision + "\n")
            self.assertEqual(editorial_matrix.git_revision(root), revision)
            (git_dir / "HEAD").write_text("ref: refs/heads/main\n")
            (git_dir / "refs/heads/main").write_text(revision + "\n")
            self.assertEqual(editorial_matrix.git_revision(root), revision)

    def test_linked_worktree_packed_reference(self) -> None:
        """A linked worktree resolves references in its common Git directory."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "checkout").mkdir()
            common = root / "common"
            administrative = common / "worktrees/check"
            administrative.mkdir(parents=True)
            (root / "checkout/.git").write_text("gitdir: ../common/worktrees/check\n")
            (administrative / "commondir").write_text("../..\n")
            (administrative / "HEAD").write_text("ref: refs/heads/topic\n")
            revision = "b" * 40
            (common / "packed-refs").write_text("# pack-refs\n" + revision + " refs/heads/topic\n")
            self.assertEqual(editorial_matrix.git_revision(root / "checkout"), revision)

    def test_invalid_reference_is_rejected(self) -> None:
        """A malformed reference cannot escape the Git metadata directory."""
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / ".git").mkdir()
            (root / ".git/HEAD").write_text("ref: refs/../../secret\n")
            with self.assertRaisesRegex(RuntimeError, "Invalid Git HEAD"):
                editorial_matrix.git_revision(root)


if __name__ == "__main__":
    unittest.main()
