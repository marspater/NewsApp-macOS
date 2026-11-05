"""Regression controls for Phase 0 metric validity and failure behavior."""
from __future__ import annotations

import math
import sqlite3
import unittest

from script.evaluation import editorial_fixtures as fixtures
from script.evaluation import editorial_metrics as metrics


class RankingTests(unittest.TestCase):
    """Check ranking against hand calculations rather than an implementation mirror."""

    def test_hand_calculated_ndcg_and_short_list(self) -> None:
        """A high-score irrelevant result discounts the one relevant result to rank two."""
        self.assertAlmostEqual(metrics.ndcg10([(2, "a", 0), (1, "b", 3)]), 1 / math.log2(3))
        self.assertEqual(metrics.ndcg10([(1, "a", 3)]), 1)

    def test_zero_relevance_and_empty_set(self) -> None:
        """Undefined ideal gain produces a finite zero metric."""
        self.assertEqual(metrics.ndcg10([(1, "a", 0)]), 0)
        self.assertEqual(metrics.ndcg10([]), 0)

    def test_tied_scores_use_ids_never_gold(self) -> None:
        """Relabeling candidates changes evaluation but never their selected order."""
        original = [(1, "b", 3), (1, "a", 0)]
        relabeled = [(1, "b", 0), (1, "a", 3)]
        self.assertEqual([r[1] for r in metrics.rank_candidates(original)], ["a", "b"])
        self.assertEqual([r[1] for r in metrics.rank_candidates(relabeled)], ["a", "b"])
        self.assertLess(metrics.ndcg10(original), metrics.ndcg10(relabeled))


class RetrievalTests(unittest.TestCase):
    """Exercise temporal and event boundaries with independently authored tiny inputs."""

    def setUp(self) -> None:
        """Create a small fixture schema with self, history, cross-event and future rows."""
        self.db = sqlite3.connect(":memory:")
        fixtures.schema(self.db)
        self.add_report("a-old", "event", 1, 2, "Orion launch. Earlier report.")
        self.add_report("b-current", "event", 8, 10, "Orion launch. Current report.")
        self.add_report("c-future", "event", 11, 12, "Orion launch. Future report.")
        self.add_report("d-delayed", "event", 1, 15, "Orion launch. Delayed report.")
        self.add_report("e-other", "other", 1, 2, "Orion launch. Unrelated event.")
        self.add_report("a-same-time", "event", 8, 10, "Orion launch. Earlier ID.")
        self.add_report("z-same-time", "event", 8, 10, "Orion launch. Later ID.")

    def tearDown(self) -> None:
        """Close the isolated in-memory database."""
        self.db.close()

    def add_report(self, article_id: str, event: str, published: float, fetched: float, text: str) -> None:
        """Insert an authored report without deriving its expected outcome from the metric."""
        self.db.execute(
            "INSERT INTO articles VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)",
            (article_id, event, "breaking", "space", "publisher", "origin", article_id,
             "title", "body", published, fetched, 1000, 1),
        )
        self.db.execute(
            "INSERT INTO passages VALUES(?,?,?,?,?,?,?,?,?)",
            (article_id, article_id, event, text, "repetition", 1, 0, fetched, 1),
        )
        self.db.execute("INSERT INTO passage_fts VALUES(?,?,?)", (article_id, event, text))

    def test_history_excludes_self_future_delayed_and_other_events(self) -> None:
        """The replay can see only the two explicitly earlier available reports."""
        found, _ = metrics.fetch_fts_candidates(self.db, metrics.passage_query("Orion launch."), "event", "b-current", 10)
        self.assertEqual({row[0] for row in found}, {"a-old", "a-same-time"})

    def test_first_report_and_genuine_lexical_miss(self) -> None:
        """A first report and a unique input both route without a lexical candidate."""
        first, _ = metrics.fetch_fts_candidates(self.db, metrics.passage_query("Orion launch."), "event", "a-old", 2)
        miss, _ = metrics.fetch_fts_candidates(self.db, metrics.passage_query("Unprecedentedzebra."), "event", "b-current", 10)
        self.assertEqual(first, [])
        self.assertEqual(miss, [])

    def test_query_quotes_untrusted_fts_syntax(self) -> None:
        """Punctuation and FTS operator words cannot inject a different match expression."""
        self.assertEqual(metrics.passage_query('Orion OR "launch"*.'), '"orion" AND "or" AND "launch"')
        self.assertEqual(metrics.passage_query("!"), "")


class ReplayTests(unittest.TestCase):
    """Verify wire projection independently of table counts."""

    def test_wire_deduplication_and_backfill_order(self) -> None:
        """Twenty copies remain one report despite reversed fetch order and repeats."""
        rows = [(f"copy-{i}", "event", "wire", "origin", 5, 10 + i) for i in range(20)]
        self.assertEqual(metrics.independent_report_timeline(rows), [(5, "event", "wire", "origin")])
        shuffled = list(reversed(rows)) + [rows[0]]
        self.assertEqual(metrics.independent_report_timeline(rows), metrics.independent_report_timeline(shuffled))
        backfill = [("new", "event", "other", "second", 1, 100)]
        self.assertEqual(metrics.independent_report_timeline(rows + backfill)[0][0], 1)

    def test_conflicting_wire_origins_fail(self) -> None:
        """Ambiguous origin identity cannot silently count as known independence."""
        with self.assertRaisesRegex(RuntimeError, "inconsistent"):
            metrics.independent_report_timeline([
                ("a", "event", "wire", "one", 1, 2),
                ("b", "event", "wire", "two", 1, 3),
            ])


class GateTests(unittest.TestCase):
    """Mutation controls ensure broken results cannot pass the fixture gate."""

    @classmethod
    def setUpClass(cls) -> None:
        """Seed the complete deterministic fixture once for gate checks."""
        cls.db = sqlite3.connect(":memory:")
        fixtures.schema(cls.db)
        rng = fixtures.DeterministicFixtureRNG(20261105)
        cls.event_meta, _ = fixtures.seed_articles(cls.db, rng)
        fixtures.seed_ranking(cls.db, rng)
        fixtures.seed_personalization(cls.db, rng)
        cls.evaluations = {
            "novelty_extraction": metrics.eval_novelty(cls.db, cls.event_meta),
            "momentum": metrics.eval_momentum(cls.db),
            "ranking": metrics.eval_ranking(cls.db),
            "personalization": metrics.eval_personalization(cls.db, fixtures.TOPICS),
        }

    @classmethod
    def tearDownClass(cls) -> None:
        """Release the fixture after all mutation checks."""
        cls.db.close()

    def test_authored_fixture_passes(self) -> None:
        """The fixture must pass each named group of independent controls."""
        self.assertEqual(set(metrics.validate_evaluation(self.db, self.evaluations)), {
            "content_derived_historical_fts_routes_and_exact_fallback_queue",
            "publication_time_wire_deduplication_and_replay_invariance",
            "ten_individual_500_candidate_ranking_sets",
            "render_scroll_action_chronology_rewards_neutral_and_repeated_impressions",
            "per_reader_fifteen_percent_adjacent_underexposed_discovery",
        })

    def test_missing_index_rows_fail_despite_unchanged_corpus(self) -> None:
        """Deleting FTS rows must fail the gate even though source table counts are unchanged."""
        before = self.db.execute("SELECT count(*) FROM passage_fts").fetchone()[0]
        self.db.execute("DELETE FROM passage_fts")
        broken = dict(self.evaluations)
        broken["novelty_extraction"] = metrics.eval_novelty(self.db, self.event_meta)
        try:
            with self.assertRaisesRegex(RuntimeError, "FTS routing"):
                metrics.validate_evaluation(self.db, broken)
        finally:
            self.db.execute("INSERT INTO passage_fts SELECT id,event_id,text FROM passages")
            self.evaluations["novelty_extraction"] = metrics.eval_novelty(self.db, self.event_meta)
        self.assertEqual(self.db.execute("SELECT count(*) FROM passage_fts").fetchone()[0], before)

    def test_reward_and_timestamp_corruption_fail(self) -> None:
        """Correct counts cannot hide invalid reward signs or pre-render actions."""
        self.db.execute("SAVEPOINT corrupt")
        try:
            self.db.execute("UPDATE impressions SET reward=1 WHERE action='scrolled_past'")
            with self.assertRaisesRegex(RuntimeError, "Impression"):
                metrics.validate_evaluation(self.db, self.evaluations)
        finally:
            self.db.execute("ROLLBACK TO corrupt")
            self.db.execute("RELEASE corrupt")
        self.db.execute("SAVEPOINT corrupt")
        try:
            self.db.execute("UPDATE impressions SET clicked_at=rendered_at-1 WHERE action='click'")
            with self.assertRaisesRegex(RuntimeError, "Impression"):
                metrics.validate_evaluation(self.db, self.evaluations)
        finally:
            self.db.execute("ROLLBACK TO corrupt")
            self.db.execute("RELEASE corrupt")

    def test_discovery_share_and_underexposure_corruption_fail(self) -> None:
        """The gate checks per-reader allocation and independently stored exposure evidence."""
        self.db.execute("SAVEPOINT corrupt")
        try:
            self.db.execute("UPDATE recommendation_judgements SET slot_type='core' WHERE slot_type='discovery'")
            with self.assertRaisesRegex(RuntimeError, "fifteen percent"):
                metrics.validate_evaluation(self.db, self.evaluations)
        finally:
            self.db.execute("ROLLBACK TO corrupt")
            self.db.execute("RELEASE corrupt")
        self.db.execute("SAVEPOINT corrupt")
        try:
            self.db.execute("UPDATE reader_topic_exposure SET prior_impressions=100")
            with self.assertRaisesRegex(RuntimeError, "underexposed"):
                metrics.validate_evaluation(self.db, self.evaluations)
        finally:
            self.db.execute("ROLLBACK TO corrupt")
            self.db.execute("RELEASE corrupt")


if __name__ == "__main__":
    unittest.main()
