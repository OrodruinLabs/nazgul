CREATE TABLE IF NOT EXISTS events (
  id            TEXT PRIMARY KEY,
  source        TEXT NOT NULL,
  event_type    TEXT NOT NULL,
  priority      TEXT DEFAULT 'normal',
  status        TEXT DEFAULT 'pending',
  project_id    TEXT,
  payload       TEXT NOT NULL,
  metadata      TEXT,
  created_at    INTEGER NOT NULL,
  processed_at  INTEGER,
  completed_at  INTEGER,
  retry_count   INTEGER DEFAULT 0
);

CREATE INDEX IF NOT EXISTS idx_events_status ON events(status);
CREATE INDEX IF NOT EXISTS idx_events_source_type ON events(source, event_type);
CREATE INDEX IF NOT EXISTS idx_events_priority ON events(priority);

CREATE TABLE IF NOT EXISTS poll_state (
  resource_key  TEXT PRIMARY KEY,
  etag          TEXT,
  last_data     TEXT,
  last_polled   INTEGER NOT NULL,
  poll_count    INTEGER DEFAULT 0
);
