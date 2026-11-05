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
  rendered_at REAL NOT NULL,scrolled_past_at REAL,action TEXT NOT NULL,reward REAL NOT NULL,topic_id TEXT NOT NULL
);
CREATE INDEX impressions_user_time ON impressions(user_id,rendered_at);
CREATE TABLE recommendation_judgements(
  user_id TEXT NOT NULL,article_id TEXT NOT NULL REFERENCES articles(id),slot INTEGER NOT NULL,
  slot_type TEXT NOT NULL,expected_relevant INTEGER NOT NULL,action TEXT NOT NULL,topic_id TEXT NOT NULL,
  PRIMARY KEY(user_id,article_id)
);
