#!/usr/bin/env python3
"""Phase 0 editorial evaluation matrix. Standard-library only; no Core ML or Accelerate calls."""
from __future__ import annotations

import argparse
import datetime as dt
import json
import math
import random
import sqlite3
import statistics
import tempfile
import time
from pathlib import Path

UTC = dt.timezone.utc
BASE = dt.datetime(2026, 11, 1, tzinfo=UTC)
TOPICS = ["energy", "semiconductors", "monetary-policy", "rail", "shipping",
          "public-health", "space", "cybersecurity", "agriculture", "climate"]
SCENARIOS = [("breaking", 20), ("slow_weekend", 15), ("syndication", 15)]
PUBLISHERS = [f"Publisher {i:02d}" for i in range(20)]


def ts(value: dt.datetime) -> float:
    return value.timestamp()


def ndcg10(rows: list[tuple[float, int]]) -> float:
    ranked = sorted(rows, key=lambda row: (-row[0], -row[1]))[:10]
    ideal = sorted((grade for _, grade in rows), reverse=True)[:10]
    def dcg(grades: list[int]) -> float:
        return sum((2 ** grade - 1) / math.log2(i + 2) for i, grade in enumerate(grades))
    denominator = dcg(ideal)
    return dcg([grade for _, grade in ranked]) / denominator if denominator else 0.0


def schema(db: sqlite3.Connection) -> None:
    db.executescript("""
    PRAGMA journal_mode=WAL;
    PRAGMA synchronous=NORMAL;
    PRAGMA foreign_keys=ON;
    CREATE TABLE articles(
      id TEXT PRIMARY KEY,event_id TEXT NOT NULL,scenario TEXT NOT NULL,topic_id TEXT NOT NULL,
      publisher TEXT NOT NULL,independent_publisher TEXT NOT NULL,wire_group_id TEXT NOT NULL,title TEXT NOT NULL,body TEXT NOT NULL,
      published_at REAL NOT NULL,fetched_at REAL NOT NULL,source_elo REAL NOT NULL,relevance_grade INTEGER NOT NULL
    );
    CREATE INDEX articles_event_date ON articles(event_id,published_at);
    CREATE INDEX articles_wire_group ON articles(wire_group_id);
    CREATE TABLE passages(
      id TEXT PRIMARY KEY,article_id TEXT NOT NULL REFERENCES articles(id),event_id TEXT NOT NULL,
      text TEXT NOT NULL,expected_class TEXT NOT NULL,has_core_entity INTEGER NOT NULL,expected_new_fact INTEGER NOT NULL
    );
    CREATE VIRTUAL TABLE passage_fts USING fts5(passage_id UNINDEXED,event_id UNINDEXED,text,tokenize='porter unicode61');
    CREATE TABLE passage_sentences(
      id TEXT PRIMARY KEY,passage_id TEXT NOT NULL REFERENCES passages(id),sentence TEXT NOT NULL,
      has_core_entity INTEGER NOT NULL,expected_new_fact INTEGER NOT NULL,entity_id TEXT
    );
    CREATE TABLE event_windows(
      event_id TEXT PRIMARY KEY,scenario TEXT NOT NULL,window_start REAL NOT NULL,window_end REAL NOT NULL,
      expected_burst INTEGER NOT NULL
    );
    CREATE TABLE ranking_judgements(
      query_id TEXT NOT NULL,article_id TEXT NOT NULL REFERENCES articles(id),relevance_grade INTEGER NOT NULL,
      topic_id TEXT NOT NULL,source_elo REAL NOT NULL,PRIMARY KEY(query_id,article_id)
    );
    CREATE INDEX ranking_query_elo ON ranking_judgements(query_id,source_elo DESC);
    CREATE TABLE impressions(
      id INTEGER PRIMARY KEY,user_id TEXT NOT NULL,article_id TEXT NOT NULL REFERENCES articles(id),
      rendered_at REAL NOT NULL,scrolled_past_at REAL,action TEXT NOT NULL,reward REAL NOT NULL,topic_id TEXT NOT NULL
    );
    CREATE INDEX impressions_user_time ON impressions(user_id,rendered_at);
    CREATE TABLE recommendation_judgements(
      user_id TEXT NOT NULL,article_id TEXT NOT NULL REFERENCES articles(id),slot INTEGER NOT NULL,
      slot_type TEXT NOT NULL,expected_relevant INTEGER NOT NULL,action TEXT NOT NULL,topic_id TEXT NOT NULL,
      PRIMARY KEY(user_id,article_id)
    );
    """)


def seed_articles(db: sqlite3.Connection, rng: random.Random):
    event_meta = {}
    event_articles = {}
    article_rows = []
    passage_rows = []
    fts_rows = []
    sentence_rows = []
    event_windows = []
    article_number = 0
    event_number = 0

    for scenario, event_count in SCENARIOS:
        for _ in range(event_count):
            event_number += 1
            event_id = f"event-{event_number:03d}"
            topic = TOPICS[(event_number - 1) % len(TOPICS)]
            anchor = BASE + dt.timedelta(hours=(event_number % 12) * 2)
            query = f"incident{event_number:03d} authority operation"
            event_meta[event_id] = {"scenario": scenario, "topic": topic, "query": query}
            ids = []

            for index in range(100):
                article_number += 1
                article_id = f"article-{article_number:05d}"
                if scenario == "breaking":
                    published = (anchor + dt.timedelta(seconds=index * 20) if index < 80
                                 else anchor - dt.timedelta(hours=23) + dt.timedelta(minutes=(index - 80) * 60))
                    wire_id = article_id
                    fetched = published + dt.timedelta(minutes=rng.randint(0, 15))
                    grade = 3 if index % 5 == 0 else 2
                elif scenario == "slow_weekend":
                    published = anchor + dt.timedelta(minutes=index * 43)
                    wire_id = article_id
                    fetched = published + dt.timedelta(minutes=rng.randint(0, 90))
                    grade = 2 if index % 4 == 0 else 1
                else:
                    wire_index = index // 20
                    wire_id = f"{event_id}-wire-{wire_index:02d}"
                    published = anchor + dt.timedelta(hours=wire_index * 3)
                    fetched = published + dt.timedelta(hours=(index % 20) * 2 + rng.randint(0, 20))
                    grade = 1

                publisher = PUBLISHERS[index % len(PUBLISHERS)]
                independent_publisher = (f"Wire Service {int(wire_group.split('-')[-1]) % 2}" if scenario == "syndication" else publisher)
                title = f"{topic.replace('-', ' ').title()} event {event_number} report {index:03d}"
                body = f"{query}. {scenario.replace('_', ' ')} coverage for {event_id}. Wire {wire_id}."
                elo = 900.0 + ((index * 37 + event_number * 19) % 250)
                article_rows.append((article_id,event_id,scenario,topic,publisher,independent_publisher,wire_id,title,body,
                                     ts(published),ts(fetched),elo,grade))
                ids.append(article_id)

                bucket = index % 10
                if scenario == "syndication":
                    kind, passage, new_fact = "repetition", f"{query}. Authorities confirmed syndicated status and timeline.", 0
                    anchored = 1
                elif bucket < 4:
                    kind, passage, new_fact = "repetition", f"{query}. Authorities confirmed previously reported status and timeline.", 0
                    anchored = 0 if index % 5 == 0 else 1
                elif bucket < 8:
                    kind, passage, new_fact = "potentially_new", f"{query}. Agency identified a newly affected facility and revised the casualty figure.", 1
                    anchored = 0 if index % 5 == 0 else 1
                else:
                    kind = "semantic_fallback"
                    passage = f"Officials described the {topic} situation and issued fallbacktoken{article_number:05d} statement."
                    new_fact, anchored = 0, 0 if index % 5 == 0 else 1

                passage_id = f"passage-{article_id}"
                passage_rows.append((passage_id,article_id,event_id,passage,kind,anchored,new_fact))
                fts_rows.append((passage_id,event_id,passage))
                if scenario == "syndication":
                    sentence = f"The {topic} authority confirmed syndicated story {wire_id} status and timeline."
                elif kind == "potentially_new":
                    sentence = f"The {topic} authority identified newly affected facility {article_id} and revised the count."
                elif kind == "semantic_fallback":
                    sentence = f"Officials described the {topic} situation for {article_id} and issued an updated statement."
                else:
                    sentence = f"The {topic} authority confirmed previously reported status for {article_id} and timeline."
                sentence_rows.append((f"sentence-{article_id}-0",passage_id,sentence,anchored,new_fact,
                                      f"entity:{topic}" if anchored else None))
                sentence_rows.append((f"sentence-{article_id}-1",passage_id,
                                      "The company declined to comment.",0,0,None))

            event_articles[event_id] = ids
            event_windows.append((event_id,scenario,ts(anchor-dt.timedelta(hours=3)),
                                  ts(anchor+dt.timedelta(hours=3)),1 if scenario == "breaking" else 0))

    started = time.perf_counter()
    db.executemany("INSERT INTO articles VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", article_rows)
    db.commit()
    article_insert_ms = (time.perf_counter()-started)*1000

    started = time.perf_counter()
    db.executemany("INSERT INTO passages VALUES(?,?,?,?,?,?,?)", passage_rows)
    db.executemany("INSERT INTO passage_fts(passage_id,event_id,text) VALUES(?,?,?)", fts_rows)
    db.executemany("INSERT INTO passage_sentences VALUES(?,?,?,?,?,?)", sentence_rows)
    db.executemany("INSERT INTO event_windows VALUES(?,?,?,?,?)", event_windows)
    db.commit()
    passage_insert_ms = (time.perf_counter()-started)*1000
    return event_meta, event_articles, {
        "article_insert_ms": article_insert_ms,
        "passage_and_fts_insert_ms": passage_insert_ms,
    }


def eval_novelty(db: sqlite3.Connection, event_meta: dict) -> dict:
    rows = db.execute("SELECT id,article_id,event_id,expected_class FROM passages ORDER BY id").fetchall()
    lexical_expected = lexical_found = fallback_expected = fallback_queued = 0
    elapsed = []
    for passage_id, article_id, event_id, kind in rows:
        query = f"fallbacktoken{article_id.split('-')[-1]}" if kind == "semantic_fallback" else event_meta[event_id]["query"]
        start = time.perf_counter()
        candidates = db.execute(
            "SELECT f.passage_id FROM passage_fts f JOIN passages p ON p.id=f.passage_id "
            "WHERE passage_fts MATCH ? AND f.event_id=? AND p.article_id!=? "
            "ORDER BY bm25(passage_fts) LIMIT 32",
            (query,event_id,article_id),
        ).fetchall()
        elapsed.append((time.perf_counter()-start)*1000)
        if kind == "semantic_fallback":
            fallback_expected += 1
            fallback_queued += not bool(candidates)
        else:
            lexical_expected += 1
            lexical_found += bool(candidates)

    anchored, distinct_texts, gold_new = db.execute(
        "SELECT count(*),count(DISTINCT lower(trim(sentence))),sum(expected_new_fact) "
        "FROM passage_sentences WHERE has_core_entity=1"
    ).fetchone()
    anchored_new = db.execute(
        "SELECT sum(CASE WHEN expected_new_fact=1 AND has_core_entity=1 THEN 1 ELSE 0 END) "
        "FROM passage_sentences"
    ).fetchone()[0] or 0
    return {
        "labelled_passages": len(rows),
        "fts5_same_event_query_median_ms": statistics.median(elapsed) if elapsed else None,
        "lexical_candidate_recall_on_controlled_corpus": lexical_found/lexical_expected if lexical_expected else None,
        "semantic_fallback_expected_count": fallback_expected,
        "semantic_fallback_queue_count": fallback_queued,
        "semantic_fallback_queue_priority": "low",
        "semantic_fallback_route_rate_on_controlled_corpus": fallback_queued/fallback_expected if fallback_expected else None,
        "entity_anchoring": {
            "anchored_sentence_count": anchored,
            "distinct_anchored_sentence_texts": distinct_texts,
            "identical_text_vector_cache_reuse_upper_bound": (anchored-distinct_texts)/anchored if anchored else 0,
            "gold_net_new_fact_sentences": gold_new or 0,
            "entity_anchored_gold_net_new_fact_sentences": anchored_new,
        },
        "net_new_fact_precision": None,
        "net_new_fact_precision_status": "not_measured_phase_0_no_embedding_or_extraction_invocations",
        "note": "Lexical routing and entity anchors use synthetic controls; they are not semantic novelty precision.",
    }


def eval_momentum(db: sqlite3.Connection) -> dict:
    rows = db.execute("""
      SELECT w.event_id,w.scenario,w.expected_burst,count(a.id),count(DISTINCT a.wire_group_id),count(DISTINCT a.independent_publisher)
      FROM event_windows w LEFT JOIN articles a
        ON a.event_id=w.event_id AND a.published_at BETWEEN w.window_start AND w.window_end
      GROUP BY w.event_id ORDER BY w.event_id
    """).fetchall()
    sweep = []
    for floor in (2,3,5,10,20):
        for publisher_floor in (1,2,3):
            tp=fp=tn=fn=0
            for _,_,expected,_,_,independent,publishers in rows:
                predicted = independent >= floor and publishers >= publisher_floor
                if predicted and expected: tp += 1
                elif predicted: fp += 1
                elif expected: fn += 1
                else: tn += 1
            sweep.append({
                "independent_report_floor": floor,
                "independent_publisher_floor": publisher_floor,
                "true_positive": tp, "false_positive": fp, "true_negative": tn, "false_negative": fn,
                "accuracy": (tp+tn)/len(rows) if rows else None,
                "false_positive_rate": fp/(fp+tn) if fp+tn else 0.0,
                "recall": tp/(tp+fn) if tp+fn else 0.0,
                "status": "volume_floor_only_not_MACD",
            })
    raw = sum(row[4] for row in rows)
    independent = sum(row[5] for row in rows)
    independent_publishers = sum(row[6] for row in rows)
    sample_wire = db.execute("SELECT event_id,wire_group_id FROM articles WHERE scenario='syndication' ORDER BY event_id,wire_group_id LIMIT 1").fetchone()
    sample_counts = db.execute(
        "SELECT count(*),count(DISTINCT publisher),count(DISTINCT independent_publisher) FROM articles WHERE event_id=? AND wire_group_id=?",
        sample_wire).fetchone()
    return {
        "labelled_event_windows": len(rows),
        "windows_by_scenario": {kind: sum(row[1] == kind for row in rows)
                                for kind in ("breaking","slow_weekend","syndication")},
        "raw_article_count_in_windows": raw,
        "independent_report_count_in_windows": independent,
        "independent_publisher_count_in_windows": independent_publishers,
        "single_syndicated_wire_control": {
            "outlet_rows": sample_counts[0], "local_publishers": sample_counts[1],
            "independent_publishers": sample_counts[2], "independent_reports": 1,
        },
        "syndication_copy_inflation_ratio": raw/max(1,independent),
        "delayed_fetch_over_six_hours_count": db.execute(
            "SELECT count(*) FROM articles WHERE fetched_at-published_at>21600").fetchone()[0],
        "volume_floor_sweep": sweep,
        "MACD_burst_accuracy": None,
        "MACD_false_positive_rate": None,
        "MACD_status": "not_measured_phase_0_MACD_not_implemented",
        "timestamp_policy": "publication timestamp; fetched_at retained separately for delayed-poll controls",
    }


def seed_ranking(db: sqlite3.Connection, rng: random.Random) -> float:
    articles = db.execute("SELECT id,topic_id,source_elo FROM articles ORDER BY id").fetchall()
    rows=[]
    for index, topic in enumerate(TOPICS):
        candidates=[]
        for article_id, article_topic, elo in articles:
            grade = 3 if article_topic == topic else (
                1 if TOPICS.index(article_topic) in ((index+1)%10,(index-1)%10) else 0)
            candidates.append((f"query-{index:02d}",article_id,grade,article_topic,elo))
        rng.shuffle(candidates)
        rows.extend(candidates[:500])
    start=time.perf_counter()
    db.executemany("INSERT INTO ranking_judgements VALUES(?,?,?,?,?)",rows)
    db.commit()
    return (time.perf_counter()-start)*1000


def eval_ranking(db: sqlite3.Connection) -> dict:
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


def seed_personalization(db: sqlite3.Connection, rng: random.Random) -> tuple[float,float]:
    articles=db.execute("SELECT id,topic_id FROM articles ORDER BY id").fetchall()
    rendered=ts(BASE+dt.timedelta(days=3))
    impressions=[]
    for user_index in range(10):
        user=f"user-{user_index:02d}"
        for article_index,(article_id,topic) in enumerate(articles):
            choice=rng.random()
            action,reward=("none",0.0)
            if choice<0.58: action,reward=("scrolled_past",-1.0)
            elif choice<0.68: action,reward=("click",1.0)
            elif choice<0.73: action,reward=("save",2.0)
            impressions.append((None,user,article_id,rendered+article_index,None,action,reward,topic))
    start=time.perf_counter()
    db.executemany("INSERT INTO impressions VALUES(?,?,?,?,?,?,?,?)",impressions)
    db.commit()
    insert_ms=(time.perf_counter()-start)*1000
    start=time.perf_counter()
    db.execute("UPDATE impressions SET scrolled_past_at=rendered_at+30 WHERE action='scrolled_past' AND scrolled_past_at IS NULL")
    db.commit()
    update_ms=(time.perf_counter()-start)*1000

    by_topic={}
    for article_id,topic in articles: by_topic.setdefault(topic,[]).append(article_id)
    recommendations=[]
    for index,preferred in enumerate(TOPICS):
        user=f"user-{index:02d}"
        core=by_topic[preferred][:85]
        adjacent=by_topic[TOPICS[(index+1)%10]][:15]
        for slot,article_id in enumerate(core+adjacent):
            topic=preferred if slot<85 else TOPICS[(index+1)%10]
            action="click" if slot%9==0 else ("save" if slot%17==0 else "none")
            recommendations.append((user,article_id,slot,"core" if slot<85 else "discovery",
                                    1 if slot<85 else 0,action,topic))
    db.executemany("INSERT INTO recommendation_judgements VALUES(?,?,?,?,?,?,?)",recommendations)
    db.commit()
    return insert_ms,update_ms


def eval_personalization(db: sqlite3.Connection) -> dict:
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


def main() -> int:
    parser=argparse.ArgumentParser(description="Build and evaluate the Phase 0 editorial evaluation matrix.")
    parser.add_argument("--output",type=Path,default=Path("docs/benchmarks") /
                        f"{dt.datetime.now(UTC):%Y-%m-%d}-editorial-matrix.json")
    parser.add_argument("--database",type=Path,help="Optional retained SQLite database path; temporary by default.")
    parser.add_argument("--seed",type=int,default=20261105)
    args=parser.parse_args()
    rng=random.Random(args.seed)
    temporary=None
    if args.database:
        db_path=args.database.resolve()
        db_path.parent.mkdir(parents=True,exist_ok=True)
        if db_path.exists(): db_path.unlink()
        for suffix in ("-wal", "-shm"):
            sidecar = Path(str(db_path) + suffix)
            if sidecar.exists(): sidecar.unlink()
    else:
        temporary=tempfile.TemporaryDirectory(prefix="news-editorial-phase0-")
        db_path=Path(temporary.name)/"editorial-phase0.sqlite3"

    db=sqlite3.connect(db_path)
    db.execute("PRAGMA busy_timeout=5000")
    try:
        schema(db)
        event_meta,event_articles,timings=seed_articles(db,rng)
        timings["ranking_judgement_insert_ms"]=seed_ranking(db,rng)
        impression_insert,impression_update=seed_personalization(db,rng)
        timings["impression_insert_ms"]=impression_insert
        timings["impression_scroll_update_ms"]=impression_update
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        count=db.execute("SELECT count(*) FROM articles").fetchone()[0]
        assert count>=5000, f"Expected at least 5,000 articles; got {count}"
        scenarios=dict(db.execute("SELECT scenario,count(*) FROM articles GROUP BY scenario"))
        expected_scenarios={"breaking":2000,"slow_weekend":1500,"syndication":1500}
        assert scenarios == expected_scenarios, f"Unexpected scenario distribution: {scenarios}"
        event_count=len(event_meta)
        passage_count=db.execute("SELECT count(*) FROM passages").fetchone()[0]
        ranking_count=db.execute("SELECT count(*) FROM ranking_judgements").fetchone()[0]
        impression_count=db.execute("SELECT count(*) FROM impressions").fetchone()[0]
        assert event_count == 50 and passage_count == 5000, "The labelled event/passage fixture is incomplete"
        assert ranking_count == 5000 and impression_count == 50000, "The ranking/impression fixture is incomplete"
        matrix={
            "schema_version":1,
            "generated_at":dt.datetime.now(UTC).isoformat(timespec="seconds"),
            "seed":args.seed,
            "phase":0,
            "phase_zero_gate":"PASS",
            "database":{
                "retained_path":str(db_path) if args.database else None,
                "article_count":count,
                "scenario_counts":scenarios,
                "event_count":event_count,
                "independent_story_count":db.execute("SELECT count(DISTINCT wire_group_id) FROM articles").fetchone()[0],
                "passage_count":passage_count,
                "sentence_count":db.execute("SELECT count(*) FROM passage_sentences").fetchone()[0],
                "entity_anchored_sentence_count":db.execute("SELECT count(*) FROM passage_sentences WHERE has_core_entity=1").fetchone()[0],
                "ranking_judgement_count":ranking_count,
                "impression_count":impression_count,
                "timings_ms":timings,
                "sqlite_file_bytes":db_path.stat().st_size,
            },
            "novelty_extraction":eval_novelty(db,event_meta),
            "momentum":eval_momentum(db),
            "ranking":eval_ranking(db),
            "personalization":eval_personalization(db),
            "hardware":{
                "ane_spin_up_ms":None,
                "ane_cpu_power_draw":None,
                "vector_cache_hit_rate":None,
                "reason":"Intentionally not invoked in Phase 0; the seeded evaluation matrix is the prerequisite for Phase 1 Core ML/vDSP work.",
            },
            "phase_zero_constraints":{
                "coreml_invocations":0,
                "vDSP_invocations":0,
                "third_party_dependencies":0,
                "production_database_migrations":0,
                "production_consumers_changed":0,
            },
            "limitations":[
                "Synthetic controls test fixture routing and metric calculations; they are not manually adjudicated language-quality labels.",
                "Net-new fact precision, full MACD accuracy, MMR semantic diversity and EWMA vector update cost remain pending later phases and real holdouts.",
                "The volume-floor sweep counts distinct wire groups; it is not a MACD result or a selected production threshold.",
                "The ranking baseline sorts source-Elo metadata; it is not MMR and does not use vectors.",
                "Recommendation relevance and discovery use synthetic topic labels and an 85/15 exposure fixture; they do not represent a trained reader profile.",
                "ANE spin-up and ANE/CPU power telemetry require a separate Apple-silicon hardware run after Phase 0 is accepted.",
            ],
        }
        args.output.parent.mkdir(parents=True,exist_ok=True)
        args.output.write_text(json.dumps(matrix,indent=2,sort_keys=True)+"\n",encoding="utf-8")
        print(f"Phase 0 matrix: {count} articles, {len(event_meta)} events, {matrix['database']['passage_count']} passages")
        print(f"Scenario counts: {scenarios}")
        print(f"Report: {args.output.resolve()}")
        if args.database: print(f"SQLite: {db_path}")
        print("Core ML invocations: 0; vDSP invocations: 0")
    finally:
        db.close()
        if temporary: temporary.cleanup()
    return 0


if __name__=="__main__":
    raise SystemExit(main())
