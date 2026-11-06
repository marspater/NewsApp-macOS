"""Phase 0 quality and performance measurements over the seeded SQLite corpus."""
from __future__ import annotations

import math
import re
import sqlite3
import statistics
import time


def rank_candidates(rows: list[tuple[float, str, int]]) -> list[tuple[float, str, int]]:
    """Order candidates using scores and stable IDs, never relevance labels."""
    return sorted(rows, key=lambda row: (-row[0], row[1]))


def ndcg10(rows: list[tuple[float, str, int]]) -> float:
    """Calculate NDCG@10 with a relevance-independent article-ID tie-breaker."""
    def dcg(grades: list[int]) -> float:
        """Calculate discounted cumulative gain for ordered relevance grades."""
        return sum((2 ** grade - 1) / math.log2(i + 2) for i, grade in enumerate(grades))

    denominator = dcg(sorted((grade for _, _, grade in rows), reverse=True)[:10])
    return dcg([grade for _, _, grade in rank_candidates(rows)[:10]]) / denominator if denominator else 0.0


def passage_query(text: str) -> str:
    """Quote bounded tokens from the leading sentence without interpreting FTS syntax."""
    sentence = re.split(r"[.!?]", text, maxsplit=1)[0]
    tokens = list(dict.fromkeys(re.findall(r"[^\W_]+", sentence.lower(), flags=re.UNICODE)))[:12]
    return " AND ".join('"' + token + '"' for token in tokens)


def fetch_fts_candidates(
    db: sqlite3.Connection,
    query: str,
    event_id: str,
    article_id: str,
    replay_at: float,
) -> tuple[list[tuple], float]:
    """Retrieve earlier available same-event passages at the incoming report's replay time."""
    started = time.perf_counter()
    if not query:
        return [], (time.perf_counter() - started) * 1000
    candidates = db.execute(
        "SELECT p.id FROM passage_fts JOIN passages p ON p.id=passage_fts.passage_id "
        "JOIN articles a ON a.id=p.article_id "
        "WHERE passage_fts MATCH ? AND p.event_id=? AND a.event_id=? AND p.article_id!=? "
        "AND a.published_at<=? AND (a.fetched_at<? OR (a.fetched_at=? AND a.id<?)) "
        "ORDER BY bm25(passage_fts),p.id LIMIT 32",
        (query, event_id, event_id, article_id, replay_at, replay_at, replay_at, article_id),
    ).fetchall()
    return candidates, (time.perf_counter() - started) * 1000


def eval_novelty(db: sqlite3.Connection, event_meta: dict) -> dict:
    """Measure content-derived FTS retrieval; read gold routing labels only after retrieval."""
    del event_meta  # Metadata and labels must not influence retrieval or routing.
    rows = db.execute(
        "SELECT p.id,p.article_id,p.event_id,p.text,p.replay_at,p.expected_lexical_match "
        "FROM passages p ORDER BY p.replay_at,p.article_id,p.id"
    ).fetchall()
    db.execute("DELETE FROM semantic_fallback_queue")
    lexical_expected = lexical_found = fallback_expected = fallback_correct = queued = 0
    mismatches = []
    elapsed = []
    for passage_id, article_id, event_id, text, replay_at, expected_match in rows:
        candidates, latency = fetch_fts_candidates(db, passage_query(text), event_id, article_id, replay_at)
        elapsed.append(latency)
        actual_match = bool(candidates)
        if not actual_match:
            db.execute(
                "INSERT INTO semantic_fallback_queue(passage_id,event_id,priority) VALUES(?,?,'low')",
                (passage_id, event_id),
            )
            queued += 1
        # Expected labels are used only for evaluation of the completed route.
        if expected_match:
            lexical_expected += 1
            lexical_found += actual_match
        else:
            fallback_expected += 1
            fallback_correct += not actual_match
        if actual_match != bool(expected_match):
            mismatches.append(passage_id)
    db.commit()
    return {
        "labelled_passages": len(rows),
        "fts5_same_event_query_median_ms": statistics.median(elapsed) if elapsed else None,
        "lexical_candidate_expected_count": lexical_expected,
        "lexical_candidate_recall_on_controlled_corpus": lexical_found / lexical_expected if lexical_expected else None,
        "semantic_fallback_expected_count": fallback_expected,
        "semantic_fallback_queue_count": queued,
        "persisted_low_priority_queue_rows": db.execute(
            "SELECT count(*) FROM semantic_fallback_queue WHERE priority='low'"
        ).fetchone()[0],
        "semantic_fallback_queue_priority": "low",
        "semantic_fallback_route_rate_on_controlled_corpus": fallback_correct / fallback_expected if fallback_expected else None,
        "routing_mismatch_count": len(mismatches),
        "routing_mismatch_sample": mismatches[:10],
        "query_policy": "leading sentence tokens; same event; earlier fetched_at/ID; publication not after replay",
        "entity_anchoring": entity_anchor_metrics(db),
        "net_new_fact_precision": None,
        "net_new_fact_precision_status": "not_measured_phase_0_no_embedding_or_extraction_invocations",
        "note": "Synthetic lexical routing includes first-report misses; it does not establish semantic novelty precision.",
    }


def entity_anchor_metrics(db: sqlite3.Connection) -> dict:
    """Keep all authored new-fact labels in the denominator, including unanchored sentences."""
    anchored, distinct_texts = db.execute(
        "SELECT count(*),count(DISTINCT lower(trim(sentence))) "
        "FROM passage_sentences WHERE has_core_entity=1"
    ).fetchone()
    gold_new, anchored_new = db.execute(
        "SELECT coalesce(sum(expected_new_fact),0),"
        "coalesce(sum(CASE WHEN has_core_entity=1 THEN expected_new_fact ELSE 0 END),0) "
        "FROM passage_sentences"
    ).fetchone()
    return {
        "anchored_sentence_count": anchored,
        "distinct_anchored_sentence_texts": distinct_texts,
        "identical_text_vector_cache_reuse_upper_bound": (anchored - distinct_texts) / anchored if anchored else 0,
        "gold_net_new_fact_sentences": gold_new,
        "entity_anchored_gold_net_new_fact_sentences": anchored_new,
        "unanchored_gold_net_new_fact_sentences": gold_new - anchored_new,
    }


def floor_confusion_counts(rows: list[tuple], report_floor: int, publisher_floor: int) -> tuple[int, int, int, int]:
    """Count true/false positives and negatives for one volume-floor pair."""
    counts = [[0, 0], [0, 0]]
    for _, _, expected, _, independent, publishers in rows:
        predicted = int(independent >= report_floor and publishers >= publisher_floor)
        counts[int(bool(expected))][predicted] += 1
    return counts[1][1], counts[0][1], counts[0][0], counts[1][0]


def safe_ratio(numerator: float, denominator: float, default: float | None) -> float | None:
    """Divide while returning a caller-selected fallback for an empty denominator."""
    return numerator / denominator if denominator else default


def volume_floor_sweep(rows: list[tuple]) -> list[dict]:
    """Evaluate volume floors without representing them as MACD measurements."""
    sweep = []
    for floor in (2, 3, 5, 10, 20):
        for publisher_floor in (1, 2, 3):
            tp, fp, tn, fn = floor_confusion_counts(rows, floor, publisher_floor)
            sweep.append({
                "independent_report_floor": floor, "independent_publisher_floor": publisher_floor,
                "true_positive": tp, "false_positive": fp, "true_negative": tn, "false_negative": fn,
                "accuracy": safe_ratio(tp + tn, len(rows), None),
                "false_positive_rate": safe_ratio(fp, fp + tn, 0.0),
                "recall": safe_ratio(tp, tp + fn, 0.0), "status": "volume_floor_only_not_MACD",
            })
    return sweep


def independent_report_timeline(rows: list[tuple]) -> list[tuple]:
    """Replay one publication-time entry per event/wire, irrespective of fetch order or duplicate ingestion."""
    reports = {}
    for _, event_id, wire_id, origin, published_at, _ in rows:
        key = (event_id, wire_id)
        if key in reports and reports[key][1] != origin:
            raise RuntimeError("A wire group has inconsistent originating publishers")
        if key not in reports or published_at < reports[key][0]:
            reports[key] = (published_at, origin)
    return sorted((published, event, wire, origin) for (event, wire), (published, origin) in reports.items())


def eval_momentum(db: sqlite3.Connection) -> dict:
    """Evaluate publication-time volume controls without computing MACD."""
    rows = db.execute(
        "SELECT w.event_id,w.scenario,w.expected_burst,count(a.id),count(DISTINCT a.wire_group_id),"
        "count(DISTINCT a.independent_publisher) FROM event_windows w LEFT JOIN articles a "
        "ON a.event_id=w.event_id AND a.published_at BETWEEN w.window_start AND w.window_end "
        "GROUP BY w.event_id ORDER BY w.event_id"
    ).fetchall()
    reports = db.execute(
        "SELECT id,event_id,wire_group_id,independent_publisher,published_at,fetched_at FROM articles ORDER BY id"
    ).fetchall()
    timeline = independent_report_timeline(reports)
    sample_wire = db.execute(
        "SELECT event_id,wire_group_id FROM articles WHERE scenario='syndication' ORDER BY event_id,wire_group_id LIMIT 1"
    ).fetchone()
    if sample_wire is None:
        raise RuntimeError("The syndication control row is missing")
    sample_counts = db.execute(
        "SELECT count(*),count(DISTINCT publisher),count(DISTINCT independent_publisher) "
        "FROM articles WHERE event_id=? AND wire_group_id=?", sample_wire
    ).fetchone()
    return {
        "labelled_event_windows": len(rows),
        "windows_by_scenario": {kind: sum(row[1] == kind for row in rows) for kind in ("breaking", "slow_weekend", "syndication")},
        "raw_article_count_in_windows": sum(row[3] for row in rows),
        "independent_report_count_in_windows": sum(row[4] for row in rows),
        "independent_publisher_count_in_windows": sum(row[5] for row in rows),
        "single_syndicated_wire_control": {
            "outlet_rows": sample_counts[0], "local_publishers": sample_counts[1],
            "independent_publishers": sample_counts[2],
            "independent_reports": sum(1 for _, event, wire, _ in timeline if (event, wire) == sample_wire),
        },
        "publication_replay_independent_reports": len(timeline),
        "publication_replay_invariant_to_fetch_order": timeline == independent_report_timeline(list(reversed(reports))),
        "publication_replay_invariant_to_duplicate_ingestion": timeline == independent_report_timeline(reports + reports),
        "syndication_copy_inflation_ratio": sum(row[3] for row in rows) / max(1, sum(row[4] for row in rows)),
        "delayed_fetch_over_six_hours_count": sum(row[5] - row[4] > 21600 for row in reports),
        "volume_floor_sweep": volume_floor_sweep(rows),
        "MACD_burst_accuracy": None, "MACD_false_positive_rate": None,
        "MACD_status": "not_measured_phase_0_MACD_not_implemented",
        "timestamp_policy": "publication timestamp; fetched_at retained separately for delayed-poll controls",
    }


def eval_ranking(db: sqlite3.Connection) -> dict:
    """Measure the equal-source-score baseline and candidate-sort latency."""
    ndcgs, latencies, counts = [], [], {}
    for (query,) in db.execute("SELECT DISTINCT query_id FROM ranking_judgements ORDER BY query_id"):
        rows = db.execute(
            "SELECT source_elo,article_id,relevance_grade FROM ranking_judgements WHERE query_id=? ORDER BY article_id", (query,)
        ).fetchall()
        start = time.perf_counter()
        rank_candidates(rows)[:10]
        latencies.append((time.perf_counter() - start) * 1000)
        ndcgs.append(ndcg10(rows))
        counts[query] = len(rows)
    return {
        "ranking_queries": len(ndcgs), "candidate_count_per_query": counts,
        "baseline_neutral_source_NDCG_at_10": statistics.mean(ndcgs) if ndcgs else None,
        "baseline_candidate_sort_median_ms": statistics.median(latencies) if latencies else None,
        "source_score_policy": "equal source weights; article_id ascending tie-break; labels evaluation only",
        "mmr_NDCG_at_10": None, "intra_list_semantic_diversity": None,
        "ranking_latency_500_candidate_vectors_ms": None,
        "vector_metrics_status": "not_measured_phase_0_no_vDSP_or_embedding_invocations",
    }


def eval_personalization(db: sqlite3.Connection, topic_catalog: list[str]) -> dict:
    """Measure the full rendered denominator and synthetic discovery exposure."""
    total, skipped, positive, neutral = db.execute(
        "SELECT count(*),sum(action='scrolled_past'),sum(action IN ('click','save')),sum(action='none') FROM impressions"
    ).fetchone()
    discovery, engaged, topics = db.execute(
        "SELECT count(*),sum(action IN ('click','save')),count(DISTINCT topic_id) "
        "FROM recommendation_judgements WHERE slot_type='discovery'"
    ).fetchone()
    core, relevant = db.execute(
        "SELECT count(*),sum(expected_relevant) FROM recommendation_judgements WHERE slot_type='core'"
    ).fetchone()
    try:
        storage = db.execute(
            "SELECT coalesce(sum(pgsize),0) FROM dbstat WHERE name IN ('impressions','impressions_user_time')"
        ).fetchone()[0]
        storage_basis = "SQLite dbstat table plus index pages"
    except sqlite3.DatabaseError:
        storage = db.execute(
            "SELECT coalesce(sum(length(user_id)+length(article_id)+length(topic_id)+64),0) FROM impressions"
        ).fetchone()[0]
        storage_basis = "estimated stored field bytes plus 64-byte row overhead; dbstat unavailable"
    return {
        "impression_rows": total, "rendered_impression_count": total,
        "skipped_impression_count": skipped, "positive_click_or_save_count": positive,
        "neutral_impression_count": neutral,
        "impression_log_table_and_index_bytes": storage, "impression_storage_measurement": storage_basis,
        "discovery_slot_share": discovery / max(1, discovery + core),
        "core_recommendation_relevance": relevant / max(1, core),
        "recommendation_metric_basis": "synthetic topic-label control, not a user-preference model",
        "discovery_engagement_rate": engaged / max(1, discovery),
        "distinct_discovery_topics_reached": topics, "topic_discovery_rate": topics / max(1, len(topic_catalog)),
        "ewma_vector_update_cost_ms": None, "ewma_status": "not_measured_phase_0_no_embedding_vectors",
        "production_policy": {"opt_in": True, "raw_retention_days": 30, "implemented_in_phase_0": False},
    }


def validate_retrieval(db: sqlite3.Connection, evaluations: dict) -> str:
    """Check historical retrieval routes and the persisted fallback queue."""
    novelty = evaluations["novelty_extraction"]
    if novelty["routing_mismatch_count"] or novelty["lexical_candidate_expected_count"] == 0:
        raise RuntimeError("Content-derived FTS routing failed authored historical controls")
    expected = {row[0] for row in db.execute("SELECT id FROM passages WHERE expected_lexical_match=0")}
    queued = {row[0] for row in db.execute("SELECT passage_id FROM semantic_fallback_queue WHERE priority='low'")}
    if not expected or expected != queued:
        raise RuntimeError("Persisted low-priority fallback queue differs from expected routes")
    return "content_derived_historical_fts_routes_and_exact_fallback_queue"


def validate_momentum(evaluations: dict) -> str:
    """Check publication replay invariance and wire independence."""
    momentum = evaluations["momentum"]
    if not momentum["publication_replay_invariant_to_fetch_order"] or not momentum["publication_replay_invariant_to_duplicate_ingestion"]:
        raise RuntimeError("Publication-time replay changed with polling order or repeated ingestion")
    wire = momentum["single_syndicated_wire_control"]
    if wire != {"outlet_rows": 20, "local_publishers": 20, "independent_publishers": 1, "independent_reports": 1}:
        raise RuntimeError("Syndication control must count twenty copies as one originating report")
    return "publication_time_wire_deduplication_and_replay_invariance"


def validate_ranking(evaluations: dict) -> str:
    """Check every ranking candidate-set size."""
    if len(evaluations["ranking"]["candidate_count_per_query"]) != 10 or any(
        count != 500 for count in evaluations["ranking"]["candidate_count_per_query"].values()
    ):
        raise RuntimeError("Each of ten ranking queries must have 500 candidates")
    return "ten_individual_500_candidate_ranking_sets"


def validate_impressions(db: sqlite3.Connection, evaluations: dict) -> str:
    """Check rendered-impression chronology and action reward controls."""
    invalid_rewards = db.execute(
        "SELECT count(*) FROM impressions WHERE "
        "(action='none' AND (reward!=0 OR scrolled_past_at IS NOT NULL OR clicked_at IS NOT NULL OR saved_at IS NOT NULL)) OR "
        "(action='scrolled_past' AND (reward>=0 OR scrolled_past_at IS NULL OR clicked_at IS NOT NULL OR saved_at IS NOT NULL)) OR "
        "(action='click' AND (reward<=0 OR clicked_at IS NULL OR saved_at IS NOT NULL)) OR "
        "(action='save' AND (reward<=0 OR saved_at IS NULL)) OR "
        "action NOT IN ('none','scrolled_past','click','save')"
    ).fetchone()[0]
    invalid_times = db.execute(
        "SELECT count(*) FROM impressions i JOIN articles a ON a.id=i.article_id WHERE "
        "i.rendered_at<a.fetched_at OR i.rendered_at<a.published_at OR "
        "i.scrolled_past_at<i.rendered_at OR i.clicked_at<i.rendered_at OR i.saved_at<i.rendered_at"
    ).fetchone()[0]
    personal = evaluations["personalization"]
    if invalid_rewards or invalid_times or not personal["neutral_impression_count"] or personal["impression_rows"] != (
        personal["skipped_impression_count"] + personal["positive_click_or_save_count"] + personal["neutral_impression_count"]
    ):
        raise RuntimeError("Impression chronology, reward signs or rendered denominator are invalid")
    if not db.execute(
        "SELECT 1 FROM impressions GROUP BY user_id,article_id HAVING count(*)>1 LIMIT 1"
    ).fetchone():
        raise RuntimeError("Repeated qualifying impressions are missing")
    return "render_scroll_action_chronology_rewards_neutral_and_repeated_impressions"


def validate_discovery(db: sqlite3.Connection) -> str:
    """Check each reader's adjacent, underexposed discovery share."""
    per_user = db.execute(
        "SELECT user_id,count(*),sum(slot_type='discovery') FROM recommendation_judgements GROUP BY user_id"
    ).fetchall()
    if not per_user or any(20 * count_discovery != 3 * count_all for _, count_all, count_discovery in per_user):
        raise RuntimeError("Discovery must account for fifteen percent of every reader's exposure")
    invalid_discovery = db.execute(
        "SELECT count(*) FROM recommendation_judgements r WHERE r.slot_type='discovery' AND NOT EXISTS ("
        "SELECT 1 FROM reader_topic_exposure prior JOIN topic_adjacency adjacent ON adjacent.topic_id=prior.topic_id "
        "JOIN reader_topic_exposure target ON target.user_id=prior.user_id AND target.topic_id=adjacent.adjacent_topic_id "
        "WHERE prior.user_id=r.user_id AND target.topic_id=r.topic_id AND target.prior_impressions<prior.prior_impressions)"
    ).fetchone()[0]
    if invalid_discovery:
        raise RuntimeError("Discovery includes topics without adjacent, underexposed evidence")
    return "per_reader_fifteen_percent_adjacent_underexposed_discovery"


def validate_evaluation(db: sqlite3.Connection, evaluations: dict) -> list[str]:
    """Fail on incorrect deterministic controls; acceptance of real editorial quality is separate."""
    return [
        validate_retrieval(db, evaluations),
        validate_momentum(evaluations),
        validate_ranking(evaluations),
        validate_impressions(db, evaluations),
        validate_discovery(db),
    ]
