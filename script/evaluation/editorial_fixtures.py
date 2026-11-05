"""Deterministic Phase 0 corpus builders for the editorial evaluation matrix."""
from __future__ import annotations

import datetime as dt
import hashlib
import sqlite3
import time
import typing

UTC = dt.timezone.utc
BASE = dt.datetime(2026, 11, 1, tzinfo=UTC)
TOPICS = [
    "energy", "semiconductors", "monetary-policy", "rail", "shipping",
    "public-health", "space", "cybersecurity", "agriculture", "climate",
]
SCENARIOS = [("breaking", 20), ("slow_weekend", 15), ("syndication", 15)]
PUBLISHERS = [f"Publisher {i:02d}" for i in range(20)]

T = typing.TypeVar("T")

class DeterministicFixtureRNG:
    """Generate reproducible pseudo-random values for synthetic evaluation fixtures."""

    def __init__(self, seed: int) -> None:
        """Initialize the fixture stream from a caller-selected integer seed."""
        self._seed = str(seed).encode("utf-8")
        self._counter = 0

    def _next_u64(self) -> int:
        """Return the next 64 bits from the deterministic SHA-256 counter stream."""
        digest = hashlib.sha256(self._seed + self._counter.to_bytes(8, "big")).digest()
        self._counter += 1
        return int.from_bytes(digest[:8], "big")

    def randint(self, start: int, stop: int) -> int:
        """Return a reproducible integer in the inclusive range [start, stop]."""
        if start > stop:
            raise ValueError("start must not exceed stop")
        span = stop - start + 1
        ceiling = 1 << 64
        limit = ceiling - ceiling % span
        while True:
            value = self._next_u64()
            if value < limit:
                return start + value % span

    def random(self) -> float:
        """Return a deterministic floating-point value in the half-open range [0, 1)."""
        return self._next_u64() / float(1 << 64)

    def shuffle(self, values: list[T]) -> None:
        """Shuffle a list in place using the seeded fixture stream."""
        for index in range(len(values) - 1, 0, -1):
            other = self.randint(0, index)
            values[index], values[other] = values[other], values[index]

def ts(value: dt.datetime) -> float:
    """Convert a timezone-aware datetime to a Unix timestamp."""
    return value.timestamp()

def schema(db: sqlite3.Connection) -> None:
    """Create the isolated Phase 0 SQLite and FTS5 evaluation schema."""
    db.executescript(
        """
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
          text TEXT NOT NULL,expected_class TEXT NOT NULL,has_core_entity INTEGER NOT NULL,expected_new_fact INTEGER NOT NULL,
          replay_at REAL NOT NULL,expected_lexical_match INTEGER NOT NULL
        );
        CREATE VIRTUAL TABLE passage_fts USING fts5(passage_id UNINDEXED,event_id UNINDEXED,text,tokenize='porter unicode61');

        CREATE TABLE passage_sentences(
          id TEXT PRIMARY KEY,passage_id TEXT NOT NULL REFERENCES passages(id),sentence TEXT NOT NULL,
          has_core_entity INTEGER NOT NULL,expected_new_fact INTEGER NOT NULL,entity_id TEXT
        );
        CREATE TABLE semantic_fallback_queue(
          passage_id TEXT PRIMARY KEY REFERENCES passages(id),event_id TEXT NOT NULL,priority TEXT NOT NULL CHECK(priority='low')
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
          rendered_at REAL NOT NULL,scrolled_past_at REAL,action TEXT NOT NULL,reward REAL NOT NULL,topic_id TEXT NOT NULL,
          clicked_at REAL,saved_at REAL
        );
        CREATE INDEX impressions_user_time ON impressions(user_id,rendered_at);
        CREATE TABLE topic_adjacency(
          topic_id TEXT NOT NULL,adjacent_topic_id TEXT NOT NULL,
          PRIMARY KEY(topic_id,adjacent_topic_id)
        );
        CREATE TABLE reader_topic_exposure(
          user_id TEXT NOT NULL,topic_id TEXT NOT NULL,prior_impressions INTEGER NOT NULL,
          PRIMARY KEY(user_id,topic_id)
        );
        CREATE TABLE recommendation_judgements(
          user_id TEXT NOT NULL,article_id TEXT NOT NULL REFERENCES articles(id),slot INTEGER NOT NULL,
          slot_type TEXT NOT NULL,expected_relevant INTEGER NOT NULL,action TEXT NOT NULL,topic_id TEXT NOT NULL,
          PRIMARY KEY(user_id,article_id)
        );
        """
    )


def article_timing(
    scenario: str,
    index: int,
    anchor: dt.datetime,
    rng: DeterministicFixtureRNG,
) -> tuple[dt.datetime, dt.datetime, int]:
    """Generate publication/fetch times and a relevance grade for one scenario."""
    if scenario == "breaking":
        published = (
            anchor + dt.timedelta(seconds=index * 20)
            if index < 80
            else anchor - dt.timedelta(hours=23) + dt.timedelta(minutes=(index - 80) * 60)
        )
        fetched = published + dt.timedelta(minutes=rng.randint(0, 15))
        grade = 3 if index % 5 == 0 else 2
    elif scenario == "slow_weekend":
        published = anchor + dt.timedelta(minutes=index * 43)
        fetched = published + dt.timedelta(minutes=rng.randint(0, 90))
        grade = 2 if index % 4 == 0 else 1
    else:
        wire_index = index // 20
        published = anchor + dt.timedelta(hours=wire_index * 3)
        fetched = published + dt.timedelta(hours=(index % 20) * 2 + rng.randint(0, 20))
        grade = 1
    return published, fetched, grade

def passage_fixture(
    scenario: str,
    bucket: int,
    query: str,
    topic: str,
    article_id: str,
    wire_id: str,
    index: int,
) -> tuple[str, str, int, int, str]:
    """Build the labelled passage and candidate anchor sentence for one article."""
    if scenario == "syndication":
        kind = "repetition"
        passage = f"{query}. Authorities confirmed syndicated status and timeline."
        new_fact, anchored = 0, 1
    elif bucket < 4:
        kind = "repetition"
        passage = f"{query}. Authorities confirmed previously reported status and timeline."
        new_fact = 0
        anchored = 0 if index % 5 == 0 else 1
    elif bucket < 8:
        kind = "potentially_new"
        passage = f"{query}. Agency identified a newly affected facility and revised the casualty figure."
        new_fact = 1
        anchored = 0 if index % 5 == 0 else 1
    else:
        kind = "semantic_fallback"
        passage = f"Dispatch{article_id.split('-')[-1]}."
        new_fact, anchored = 0, 0 if index % 5 == 0 else 1

    if scenario == "syndication":
        sentence = f"The {topic} authority confirmed syndicated story {wire_id} status and timeline."
    elif kind == "potentially_new":
        sentence = f"The {topic} authority identified newly affected facility {article_id} and revised the count."
    elif kind == "semantic_fallback":
        sentence = f"Officials described the {topic} situation for {article_id} and issued an updated statement."
    else:
        sentence = f"The {topic} authority confirmed previously reported status for {article_id} and timeline."
    return kind, passage, new_fact, anchored, sentence

def build_article_fixture(
    scenario: str,
    event_id: str,
    event_number: int,
    topic: str,
    query: str,
    anchor: dt.datetime,
    index: int,
    rng: DeterministicFixtureRNG,
) -> tuple[tuple, tuple, tuple, list[tuple]]:
    """Build one article, its event passage, FTS row, and two candidate sentences."""
    article_id = f"article-{(event_number - 1) * 100 + index + 1:05d}"
    wire_id = f"{event_id}-wire-{index // 20:02d}" if scenario == "syndication" else article_id
    published, fetched, grade = article_timing(scenario, index, anchor, rng)
    publisher = PUBLISHERS[index % len(PUBLISHERS)]
    independent = f"Wire Service {wire_id.split('-')[-1]}" if scenario == "syndication" else publisher
    title = f"{topic.replace('-', ' ').title()} event {event_number} report {index:03d}"
    body = f"{query}. {scenario.replace('_', ' ')} coverage for {event_id}. Wire {wire_id}."
    elo = 1000.0
    article_row = (
        article_id, event_id, scenario, topic, publisher, independent, wire_id,
        title, body, ts(published), ts(fetched), elo, grade
    )
    kind, passage, new_fact, anchored, sentence = passage_fixture(
        scenario, index % 10, query, topic, article_id, wire_id, index
    )
    passage_id = f"passage-{article_id}"
    passage_row = (passage_id, article_id, event_id, passage, kind, anchored, new_fact, ts(fetched), 0)
    fts_row = (passage_id, event_id, passage)
    sentence_rows = [
        (
            f"sentence-{article_id}-0", passage_id, sentence, anchored, new_fact,
            f"entity:{topic}" if anchored else None,
        ),
        (
            f"sentence-{article_id}-1", passage_id,
            "The company declined to comment.", 0, 0, None,
        ),
    ]
    return article_row, passage_row, fts_row, sentence_rows

def build_event_fixture(
    scenario: str,
    event_number: int,
    rng: DeterministicFixtureRNG,
) -> tuple[str, dict[str, str], list[tuple], list[tuple], list[tuple], list[tuple], tuple]:
    """Build the 100-article controlled fixture and time window for one event."""
    event_id = f"event-{event_number:03d}"
    topic = TOPICS[(event_number - 1) % len(TOPICS)]
    anchor = BASE + dt.timedelta(hours=(event_number % 12) * 2)
    query = f"incident{event_number:03d} authority operation"
    article_rows, passage_rows, fts_rows, sentence_rows = [], [], [], []
    for index in range(100):
        article, passage, fts, sentences = build_article_fixture(
            scenario, event_id, event_number, topic, query, anchor, index, rng
        )
        article_rows.append(article)
        passage_rows.append(passage)
        fts_rows.append(fts)
        sentence_rows.extend(sentences)
    availability = {article[0]: article[10] for article in article_rows}
    passage_rows = [
        (*row[:-1], int(any(
            other[1] != row[1]
            and other[3].split(".", 1)[0] == row[3].split(".", 1)[0]
            and (availability[other[1]], other[1]) < (availability[row[1]], row[1])
            for other in passage_rows
        )))
        for row in passage_rows
    ]
    window = (
        event_id, scenario, ts(anchor - dt.timedelta(hours=3)),
        ts(anchor + dt.timedelta(hours=3)), int(scenario == "breaking"),
    )
    return event_id, {"scenario": scenario, "topic": topic, "query": query}, article_rows, passage_rows, fts_rows, sentence_rows, window

def insert_seeded_rows(
    db: sqlite3.Connection,
    article_rows: list[tuple],
    passage_rows: list[tuple],
    fts_rows: list[tuple],
    sentence_rows: list[tuple],
    event_windows: list[tuple],
) -> dict[str, float]:
    """Persist seeded article and passage rows and return insertion timings."""
    started = time.perf_counter()
    db.executemany("INSERT INTO articles VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)", article_rows)
    db.commit()
    article_insert_ms = (time.perf_counter() - started) * 1000
    started = time.perf_counter()
    db.executemany("INSERT INTO passages VALUES(?,?,?,?,?,?,?,?,?)", passage_rows)
    db.executemany("INSERT INTO passage_fts(passage_id,event_id,text) VALUES(?,?,?)", fts_rows)
    db.executemany("INSERT INTO passage_sentences VALUES(?,?,?,?,?,?)", sentence_rows)
    db.executemany("INSERT INTO event_windows VALUES(?,?,?,?,?)", event_windows)
    db.commit()
    return {
        "article_insert_ms": article_insert_ms,
        "passage_and_fts_insert_ms": (time.perf_counter() - started) * 1000,
    }

def seed_articles(
    db: sqlite3.Connection,
    rng: DeterministicFixtureRNG,
) -> tuple[dict[str, dict[str, str]], dict[str, float]]:
    """Seed the breaking, slow-weekend, and syndicated article corpus."""
    event_meta = {}
    article_rows, passage_rows, fts_rows, sentence_rows, event_windows = [], [], [], [], []
    event_number = 0
    for scenario, event_count in SCENARIOS:
        for _ in range(event_count):
            event_number += 1
            event_id, metadata, articles, passages, fts, sentences, window = build_event_fixture(
                scenario, event_number, rng
            )
            event_meta[event_id] = metadata
            article_rows.extend(articles)
            passage_rows.extend(passages)
            fts_rows.extend(fts)
            sentence_rows.extend(sentences)
            event_windows.append(window)
    timings = insert_seeded_rows(db, article_rows, passage_rows, fts_rows, sentence_rows, event_windows)
    return event_meta, timings

def ranking_relevance_grade(article_topic: str, query_topic_index: int) -> int:
    """Return the synthetic relevance label for an exact or adjacent topic."""
    if article_topic == TOPICS[query_topic_index]:
        return 3
    article_topic_index = TOPICS.index(article_topic)
    adjacent_indexes = (
        (query_topic_index + 1) % len(TOPICS),
        (query_topic_index - 1) % len(TOPICS),
    )
    if article_topic_index in adjacent_indexes:
        return 1
    return 0

def seed_ranking(db: sqlite3.Connection, rng: DeterministicFixtureRNG) -> float:
    """Create reproducible 500-candidate ranking judgement sets."""
    articles = db.execute("SELECT id,topic_id,source_elo FROM articles ORDER BY id").fetchall()
    rows = []
    for index, topic in enumerate(TOPICS):
        candidates = []
        for article_id, article_topic, elo in articles:
            grade = ranking_relevance_grade(article_topic, index)
            candidates.append((f"query-{index:02d}", article_id, grade, article_topic, elo))
        rng.shuffle(candidates)
        rows.extend(candidates[:500])
    started = time.perf_counter()
    db.executemany("INSERT INTO ranking_judgements VALUES(?,?,?,?,?)", rows)
    db.commit()
    return (time.perf_counter() - started) * 1000

def build_impression_rows(
    articles: list[tuple[str, str, float]],
    rendered: float,
    rng: DeterministicFixtureRNG,
) -> list[tuple]:
    """Create rendered impressions with deterministic skip and engagement rewards."""
    impressions = []
    for user_index in range(10):
        user = f"user-{user_index:02d}"
        for article_index, (article_id, topic, fetched_at) in enumerate(articles):
            choice = rng.random()
            action, reward = "none", 0.0
            if choice < 0.58:
                action, reward = "scrolled_past", -1.0
            elif choice < 0.68:
                action, reward = "click", 1.0
            elif choice < 0.73:
                action, reward = "save", 2.0
            rendered_at = max(rendered, fetched_at) + article_index + user_index * 0.01
            impressions.append((
                None, user, article_id, rendered_at, None, action, reward, topic,
                rendered_at + 5 if action == "click" else None,
                rendered_at + 10 if action == "save" else None,
            ))
            if article_index < 10:
                impressions.append((
                    None, user, article_id, rendered_at + 3600, None, "none", 0.0, topic,
                    None, None,
                ))
    return impressions

def recommendation_action(slot: int) -> str:
    """Choose the deterministic engagement label for one recommendation slot."""
    if slot % 9 == 0:
        return "click"
    if slot % 17 == 0:
        return "save"
    return "none"

def recommendations_for_topic(
    index: int,
    preferred: str,
    by_topic: dict[str, list[str]],
) -> list[tuple]:
    """Build one user's 85 core and 15 adjacent-topic discovery slots."""
    adjacent_topic = TOPICS[(index + 1) % len(TOPICS)]
    candidates = by_topic[preferred][:85] + by_topic[adjacent_topic][:15]
    rows = []
    for slot, article_id in enumerate(candidates):
        discovery = slot >= 85
        topic = adjacent_topic if discovery else preferred
        rows.append((
            f"user-{index:02d}", article_id, slot,
            "discovery" if discovery else "core",
            0 if discovery else 1,
            recommendation_action(slot),
            topic,
        ))
    return rows

def build_recommendation_rows(articles: list[tuple[str, str]]) -> list[tuple]:
    """Create the fixed 85/15 core and adjacent-topic discovery fixture."""
    by_topic: dict[str, list[str]] = {}
    for article_id, topic in articles:
        by_topic.setdefault(topic, []).append(article_id)
    recommendations = []
    for index, preferred in enumerate(TOPICS):
        recommendations.extend(recommendations_for_topic(index, preferred, by_topic))
    return recommendations

def seed_personalization(
    db: sqlite3.Connection,
    rng: DeterministicFixtureRNG,
) -> tuple[float, float]:
    """Seed synthetic impression rewards and the fixed core/discovery fixture."""
    articles = db.execute("SELECT id,topic_id,fetched_at FROM articles ORDER BY id").fetchall()
    rendered = ts(BASE + dt.timedelta(days=3))
    impressions = build_impression_rows(articles, rendered, rng)
    start = time.perf_counter()
    db.executemany("INSERT INTO impressions VALUES(?,?,?,?,?,?,?,?,?,?)", impressions)
    db.commit()
    insert_ms = (time.perf_counter() - start) * 1000

    start = time.perf_counter()
    db.execute(
        "UPDATE impressions SET scrolled_past_at=rendered_at+30 "
        "WHERE action='scrolled_past' AND scrolled_past_at IS NULL"
    )
    db.commit()
    update_ms = (time.perf_counter() - start) * 1000

    db.executemany(
        "INSERT INTO topic_adjacency VALUES(?,?)",
        [(topic, TOPICS[(index + offset) % len(TOPICS)])
         for index, topic in enumerate(TOPICS) for offset in (-1, 1)],
    )
    db.executemany(
        "INSERT INTO reader_topic_exposure VALUES(?,?,?)",
        [(f"user-{index:02d}", topic, 100 if topic == preferred else 0)
         for index, preferred in enumerate(TOPICS) for topic in TOPICS],
    )
    recommendations = build_recommendation_rows([(article_id, topic) for article_id, topic, _ in articles])
    db.executemany("INSERT INTO recommendation_judgements VALUES(?,?,?,?,?,?,?)", recommendations)
    db.commit()
    return insert_ms, update_ms
