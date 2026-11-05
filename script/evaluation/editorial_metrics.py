#!/usr/bin/env python3
"""Phase 0 quality and performance measurements over the seeded SQLite corpus."""
from __future__ import annotations

import math
import sqlite3
import statistics
import time

from editorial_fixtures import TOPICS

def ndcg10(rows: list[tuple[float, int]]) -> float:
    """Calculate normalized discounted cumulative gain at rank ten."""
    ranked = sorted(rows, key=lambda row: (-row[0], -row[1]))[:10]
    ideal = sorted((grade for _, grade in rows), reverse=True)[:10]
    def dcg(grades: list[int]) -> float:
        """Calculate discounted cumulative gain for ordered relevance grades."""
        return sum((2 ** grade - 1) / math.log2(i + 2) for i, grade in enumerate(grades))
    denominator = dcg(ideal)
    return dcg([grade for _, grade in ranked]) / denominator if denominator else 0.0

def eval_novelty(db: sqlite3.Connection, event_meta: dict) -> dict:
    """Measure FTS5 event-local retrieval and semantic-fallback queue routing."""
    rows = db.execute(
        "SELECT id,article_id,event_id,expected_class FROM passages ORDER BY id"
    ).fetchall()
    lexical, found, fallback, queued, elapsed = evaluate_fts_routes(db, rows, event_meta)
    db.commit()
    return {
        "labelled_passages": len(rows),
        "fts5_same_event_query_median_ms": statistics.median(elapsed) if elapsed else None,
        "lexical_candidate_recall_on_controlled_corpus": found / lexical if lexical else None,
        "semantic_fallback_expected_count": fallback,
        "semantic_fallback_queue_count": queued,
        "persisted_low_priority_queue_rows": db.execute(
            "SELECT count(*) FROM semantic_fallback_queue WHERE priority='low'"
        ).fetchone()[0],
        "semantic_fallback_queue_priority": "low",
        "semantic_fallback_route_rate_on_controlled_corpus": queued / fallback if fallback else None,
        "entity_anchoring": entity_anchor_metrics(db),
        "net_new_fact_precision": None,
        "net_new_fact_precision_status": "not_measured_phase_0_no_embedding_or_extraction_invocations",
        "note": "Lexical routing and entity anchors use synthetic controls; they are not semantic novelty precision.",
    }

def fetch_fts_candidates(
    db: sqlite3.Connection,
    query: str,
    event_id: str,
    article_id: str,
) -> tuple[list[tuple], float]:
    """Retrieve up to 32 same-event lexical matches and measure query latency."""
    started = time.perf_counter()
    candidates = db.execute(
        "SELECT passage_fts.passage_id FROM passage_fts JOIN passages p "
        "ON p.id=passage_fts.passage_id "
        "WHERE passage_fts MATCH ? AND passage_fts.event_id=? AND p.article_id!=? "
        "ORDER BY bm25(passage_fts) LIMIT 32",
        (query, event_id, article_id),
    ).fetchall()
    return candidates, (time.perf_counter() - started) * 1000

def evaluate_fts_routes(
    db: sqlite3.Connection,
    rows: list[tuple],
    event_meta: dict,
) -> tuple[int, int, int, int, list[float]]:
    """Measure lexical recall and persist semantic-miss fallback rows."""
    lexical_expected = lexical_found = fallback_expected = fallback_queued = 0
    elapsed = []
    for passage_id, article_id, event_id, kind in rows:
        query = (
            f"fallbacktoken{article_id.split('-')[-1]}"
            if kind == "semantic_fallback"
            else event_meta[event_id]["query"]
        )
        candidates, latency = fetch_fts_candidates(db, query, event_id, article_id)
        elapsed.append(latency)
        if kind == "semantic_fallback":
            fallback_expected += 1
            if not candidates:
                db.execute(
                    "INSERT OR IGNORE INTO semantic_fallback_queue(passage_id,event_id,priority) VALUES(?,?,?)",
                    (passage_id, event_id, "low"),
                )
                fallback_queued += 1
        else:
            lexical_expected += 1
            lexical_found += bool(candidates)
    return lexical_expected, lexical_found, fallback_expected, fallback_queued, elapsed

def entity_anchor_metrics(db: sqlite3.Connection) -> dict:
    """Summarize entity-anchored sentence counts and synthetic new-fact labels."""
    anchored, distinct_texts, gold_new = db.execute(
        "SELECT count(*),count(DISTINCT lower(trim(sentence))),sum(expected_new_fact) "
        "FROM passage_sentences WHERE has_core_entity=1"
    ).fetchone()
    anchored_new = db.execute(
        "SELECT sum(CASE WHEN expected_new_fact=1 AND has_core_entity=1 THEN 1 ELSE 0 END) "
        "FROM passage_sentences"
    ).fetchone()[0] or 0
    return {
        "anchored_sentence_count": anchored,
        "distinct_anchored_sentence_texts": distinct_texts,
        "identical_text_vector_cache_reuse_upper_bound": (anchored - distinct_texts) / anchored if anchored else 0,
        "gold_net_new_fact_sentences": gold_new or 0,
        "entity_anchored_gold_net_new_fact_sentences": anchored_new,
    }

def floor_confusion_counts(
    rows: list[tuple],
    report_floor: int,
    publisher_floor: int,
) -> tuple[int, int, int, int]:
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
    """Calculate classification metrics for each independent-report/publisher floor."""
    sweep = []
    total = len(rows)
    for floor in (2, 3, 5, 10, 20):
        for publisher_floor in (1, 2, 3):
            tp, fp, tn, fn = floor_confusion_counts(rows, floor, publisher_floor)
            sweep.append({
                "independent_report_floor": floor,
                "independent_publisher_floor": publisher_floor,
                "true_positive": tp, "false_positive": fp,
                "true_negative": tn, "false_negative": fn,
                "accuracy": safe_ratio(tp + tn, total, None),
                "false_positive_rate": safe_ratio(fp, fp + tn, 0.0),
                "recall": safe_ratio(tp, tp + fn, 0.0),
                "status": "volume_floor_only_not_MACD",
            })
    return sweep

def eval_momentum(db: sqlite3.Connection) -> dict:
    """Evaluate labelled event windows and independent-wire volume-floor controls."""
    rows = db.execute("""
      SELECT w.event_id,w.scenario,w.expected_burst,count(a.id),count(DISTINCT a.wire_group_id),count(DISTINCT a.independent_publisher)
      FROM event_windows w LEFT JOIN articles a
        ON a.event_id=w.event_id AND a.published_at BETWEEN w.window_start AND w.window_end
      GROUP BY w.event_id ORDER BY w.event_id
    """).fetchall()
    raw = sum(row[3] for row in rows)
    independent = sum(row[4] for row in rows)
    independent_publishers = sum(row[5] for row in rows)
    sample_wire = db.execute(
        "SELECT event_id,wire_group_id FROM articles WHERE scenario='syndication' "
        "ORDER BY event_id,wire_group_id LIMIT 1"
    ).fetchone()
    if sample_wire is None:
        raise RuntimeError("The syndication control row is missing")
    sample_counts = db.execute(
        "SELECT count(*),count(DISTINCT publisher),count(DISTINCT independent_publisher) "
        "FROM articles WHERE event_id=? AND wire_group_id=?",
        sample_wire
    ).fetchone()
    return {
        "labelled_event_windows": len(rows),
        "windows_by_scenario": {
            kind: sum(row[1] == kind for row in rows)
            for kind in ("breaking", "slow_weekend", "syndication")
        },
        "raw_article_count_in_windows": raw,
        "independent_report_count_in_windows": independent,
        "independent_publisher_count_in_windows": independent_publishers,
        "single_syndicated_wire_control": {
            "outlet_rows": sample_counts[0], "local_publishers": sample_counts[1],
            "independent_publishers": sample_counts[2], "independent_reports": 1,
        },
        "syndication_copy_inflation_ratio": raw / max(1, independent),
        "delayed_fetch_over_six_hours_count": db.execute(
            "SELECT count(*) FROM articles WHERE fetched_at-published_at>21600"
        ).fetchone()[0],
        "volume_floor_sweep": volume_floor_sweep(rows),
        "MACD_burst_accuracy": None,
        "MACD_false_positive_rate": None,
        "MACD_status": "not_measured_phase_0_MACD_not_implemented",
        "timestamp_policy": "publication timestamp; fetched_at retained separately for delayed-poll controls",
    }

def eval_ranking(db: sqlite3.Connection) -> dict:
    """Measure the source-Elo NDCG baseline and metadata-sort latency."""
    ndcgs=[]
    latencies=[]
    for (query,) in db.execute("SELECT DISTINCT query_id FROM ranking_judgements ORDER BY query_id"):
        rows=db.execute("SELECT source_elo,relevance_grade FROM ranking_judgements WHERE query_id=?",(query,)).fetchall()
        start=time.perf_counter()
        sorted(rows,key=lambda row:(-row[0],-row[1]))[:10]
        latencies.append((time.perf_counter()-start)*1000)
        ndcgs.append(ndcg10(rows))
    return {
        "ranking_queries": len(ndcgs),
        "candidate_count_per_query": 500,
        "baseline_source_elo_NDCG_at_10": statistics.mean(ndcgs) if ndcgs else None,
        "baseline_candidate_sort_median_ms": statistics.median(latencies) if latencies else None,
        "mmr_NDCG_at_10": None,
        "intra_list_semantic_diversity": None,
        "ranking_latency_500_candidate_vectors_ms": None,
        "vector_metrics_status": "not_measured_phase_0_no_vDSP_or_embedding_invocations",
    }

def eval_personalization(db: sqlite3.Connection) -> dict:
    """Measure impression storage, reward counts, and synthetic discovery exposure."""
    total,skipped,positive=db.execute(
        "SELECT count(*),sum(action='scrolled_past'),sum(action IN ('click','save')) FROM impressions").fetchone()
    discovery,engaged,topics=db.execute(
        "SELECT count(*),sum(action IN ('click','save')),count(DISTINCT topic_id) "
        "FROM recommendation_judgements WHERE slot_type='discovery'").fetchone()
    core,relevant=db.execute(
        "SELECT count(*),sum(expected_relevant) FROM recommendation_judgements WHERE slot_type='core'").fetchone()
    try:
        storage=db.execute(
            "SELECT coalesce(sum(pgsize),0) FROM dbstat WHERE name IN ('impressions','impressions_user_time')").fetchone()[0]
        storage_basis="SQLite dbstat table plus index pages"
    except sqlite3.DatabaseError:
        storage=db.execute(
            "SELECT coalesce(sum(length(user_id)+length(article_id)+length(topic_id)+48),0) FROM impressions").fetchone()[0]
        storage_basis="estimated stored field bytes plus 48-byte row overhead; dbstat unavailable"
    return {
        "impression_rows": total,
        "skipped_impression_count": skipped,
        "positive_click_or_save_count": positive,
        "impression_log_table_and_index_bytes": storage,
        "impression_storage_measurement": storage_basis,
        "discovery_slot_share": discovery/max(1,discovery+core),
        "core_recommendation_relevance": relevant/max(1,core),
        "recommendation_metric_basis": "synthetic topic-label control, not a user-preference model",
        "discovery_engagement_rate": engaged/max(1,discovery),
        "distinct_discovery_topics_reached": topics,
        "topic_discovery_rate": topics/max(1,len(TOPICS)),
        "ewma_vector_update_cost_ms": None,
        "ewma_status": "not_measured_phase_0_no_embedding_vectors",
    }
