-- Patchwork relay storage. Embedded SQLite: no Postgres, no Docker, one file.

CREATE TABLE IF NOT EXISTS workspace (
  id          TEXT PRIMARY KEY,
  name        TEXT NOT NULL,
  icon        TEXT NOT NULL DEFAULT '',
  icon_file_id TEXT,
  autonomy    TEXT NOT NULL DEFAULT '',
  created_at  INTEGER NOT NULL,
  task_prefix TEXT NOT NULL DEFAULT 'PW',
  task_seq    INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS workspace_skills (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  description  TEXT NOT NULL DEFAULT '',
  instructions TEXT NOT NULL,
  created_at   INTEGER NOT NULL,
  updated_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS members (
  id           TEXT PRIMARY KEY,
  kind         TEXT NOT NULL,               -- human | agent
  handle       TEXT NOT NULL UNIQUE,
  display_name TEXT NOT NULL,
  email        TEXT,
  avatar       TEXT,
  is_admin     INTEGER NOT NULL DEFAULT 0,
  agent_json   TEXT,                        -- AgentProfile for agents
  active       INTEGER NOT NULL DEFAULT 1,
  created_at   INTEGER NOT NULL
);

-- Device tokens for humans, and short-lived run tokens handed to agents.
CREATE TABLE IF NOT EXISTS tokens (
  token_hash TEXT PRIMARY KEY,
  member_id  TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  kind       TEXT NOT NULL,                 -- device | run
  run_id     TEXT,
  label      TEXT,
  created_at INTEGER NOT NULL,
  last_used  INTEGER,
  revoked    INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS tokens_member ON tokens(member_id);

-- One-use handoff from an existing human device to a new one. Only hashes
-- reach disk; a successful claim deletes the row in the same transaction that
-- creates the new device token.
CREATE TABLE IF NOT EXISTS pairings (
  secret_hash TEXT PRIMARY KEY,
  member_id   TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  created_at  INTEGER NOT NULL,
  expires_at  INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS pairings_expiry ON pairings(expires_at);

CREATE TABLE IF NOT EXISTS invites (
  code       TEXT PRIMARY KEY,
  created_by TEXT,
  created_at INTEGER NOT NULL,
  email      TEXT,
  is_admin   INTEGER NOT NULL DEFAULT 0,
  used_at    INTEGER,
  used_by    TEXT
);

CREATE TABLE IF NOT EXISTS sections (
  id       TEXT PRIMARY KEY,
  name     TEXT NOT NULL,
  position REAL NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS channels (
  id              TEXT PRIMARY KEY,
  kind            TEXT NOT NULL,            -- channel | dm | task
  section_id      TEXT REFERENCES sections(id) ON DELETE SET NULL,
  slug            TEXT NOT NULL DEFAULT '',
  name            TEXT NOT NULL,
  topic           TEXT NOT NULL DEFAULT '',
  position        REAL NOT NULL DEFAULT 0,
  task_id         TEXT,
  last_message_at INTEGER NOT NULL DEFAULT 0,
  archived        INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS channels_kind ON channels(kind);

CREATE TABLE IF NOT EXISTS channel_members (
  channel_id TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  member_id  TEXT NOT NULL REFERENCES members(id) ON DELETE CASCADE,
  PRIMARY KEY (channel_id, member_id)
);

CREATE TABLE IF NOT EXISTS messages (
  id            TEXT PRIMARY KEY,
  channel_id    TEXT NOT NULL REFERENCES channels(id) ON DELETE CASCADE,
  author_id     TEXT NOT NULL,
  kind          TEXT NOT NULL,
  body          TEXT NOT NULL DEFAULT '',
  card          TEXT,
  parent_id     TEXT,
  reply_to_id   TEXT,
  run_id        TEXT,
  task_id       TEXT,
  mentions      TEXT NOT NULL DEFAULT '[]',
  reply_count   INTEGER NOT NULL DEFAULT 0,
  last_reply_at INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  edited_at     INTEGER
);
CREATE INDEX IF NOT EXISTS messages_channel ON messages(channel_id, id);
CREATE INDEX IF NOT EXISTS messages_parent ON messages(parent_id, id);

CREATE VIRTUAL TABLE IF NOT EXISTS message_search USING fts5(
  message_id UNINDEXED, channel_id UNINDEXED, body, tokenize = 'porter unicode61'
);

CREATE TABLE IF NOT EXISTS reactions (
  message_id TEXT NOT NULL REFERENCES messages(id) ON DELETE CASCADE,
  member_id  TEXT NOT NULL,
  emoji      TEXT NOT NULL,
  PRIMARY KEY (message_id, member_id, emoji)
);

CREATE TABLE IF NOT EXISTS attachments (
  id         TEXT PRIMARY KEY,
  file_name  TEXT NOT NULL,
  mime       TEXT NOT NULL,
  size       INTEGER NOT NULL,
  caption    TEXT NOT NULL DEFAULT '',
  path       TEXT NOT NULL,
  message_id TEXT,
  task_id    TEXT,
  run_id     TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS attachments_message ON attachments(message_id);
CREATE INDEX IF NOT EXISTS attachments_task ON attachments(task_id);

CREATE TABLE IF NOT EXISTS tasks (
  id                    TEXT PRIMARY KEY,
  key                   TEXT NOT NULL UNIQUE,
  title                 TEXT NOT NULL,
  outcome               TEXT NOT NULL DEFAULT '',
  status                TEXT NOT NULL,
  owner_id              TEXT,
  source_channel_id     TEXT,
  source_message_id     TEXT,
  discussion_channel_id TEXT NOT NULL,
  project_id            TEXT,
  host_id               TEXT,
  worktree_id           TEXT,
  current_run_id        TEXT,
  active_continuation   TEXT,
  question_blocked_run_id TEXT,
  pr_url                TEXT,
  pr_state              TEXT,
  review_action         TEXT,
  created_by            TEXT NOT NULL,
  due_at                INTEGER,
  once_key              TEXT,
  position              REAL NOT NULL DEFAULT 0,
  created_at            INTEGER NOT NULL,
  updated_at            INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS tasks_status ON tasks(status);

CREATE TABLE IF NOT EXISTS projects (
  id             TEXT PRIMARY KEY,
  name           TEXT NOT NULL,
  description    TEXT NOT NULL DEFAULT '',
  repo_url       TEXT,
  default_branch TEXT NOT NULL DEFAULT 'main',
  paths          TEXT NOT NULL DEFAULT '{}',
  created_at     INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS hosts (
  id           TEXT PRIMARY KEY,
  name         TEXT NOT NULL,
  kind         TEXT NOT NULL,               -- relay | desktop
  platform     TEXT NOT NULL DEFAULT '',
  owner_id     TEXT,
  capabilities TEXT NOT NULL DEFAULT '{}',
  last_seen    INTEGER NOT NULL DEFAULT 0,
  created_at   INTEGER NOT NULL
);

CREATE TABLE IF NOT EXISTS worktrees (
  id              TEXT PRIMARY KEY,
  task_id         TEXT NOT NULL,
  project_id      TEXT NOT NULL,
  host_id         TEXT NOT NULL,
  path            TEXT NOT NULL,
  branch          TEXT NOT NULL DEFAULT '',
  base_branch     TEXT NOT NULL DEFAULT '',
  is_main_checkout INTEGER NOT NULL DEFAULT 0,
  created_at      INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS worktrees_task ON worktrees(task_id);

CREATE TABLE IF NOT EXISTS runs (
  id            TEXT PRIMARY KEY,
  agent_id      TEXT NOT NULL,
  status        TEXT NOT NULL,
  trigger       TEXT NOT NULL,
  channel_id    TEXT NOT NULL,
  task_id       TEXT,
  host_id       TEXT,
  project_id    TEXT,
  worktree_id   TEXT,
  cwd           TEXT,
  automation_id TEXT,
  session_id    TEXT,
  runtime       TEXT NOT NULL DEFAULT '',
  provider      TEXT,
  model         TEXT,
  thinking      TEXT,
  prompt        TEXT NOT NULL DEFAULT '',
  headline      TEXT NOT NULL DEFAULT '',
  error         TEXT,
  token_usage   TEXT,
  depth         INTEGER NOT NULL DEFAULT 0,
  created_at    INTEGER NOT NULL,
  started_at    INTEGER,
  ended_at      INTEGER
);
CREATE INDEX IF NOT EXISTS runs_task ON runs(task_id, id);
CREATE INDEX IF NOT EXISTS runs_status ON runs(status);

CREATE TABLE IF NOT EXISTS task_continuations (
  id            TEXT PRIMARY KEY,
  task_id       TEXT NOT NULL,
  run_id        TEXT NOT NULL,
  agent_id      TEXT NOT NULL,
  command       TEXT NOT NULL,
  every_seconds INTEGER NOT NULL,
  deadline_at   INTEGER NOT NULL,
  wake_prompt   TEXT NOT NULL,
  status        TEXT NOT NULL,
  summary       TEXT NOT NULL,
  next_check_at INTEGER NOT NULL,
  created_at    INTEGER NOT NULL,
  updated_at    INTEGER NOT NULL,
  ended_at      INTEGER
);
CREATE UNIQUE INDEX IF NOT EXISTS task_continuations_active
  ON task_continuations(task_id) WHERE ended_at IS NULL;
CREATE INDEX IF NOT EXISTS task_continuations_due
  ON task_continuations(status, next_check_at) WHERE ended_at IS NULL;

CREATE TABLE IF NOT EXISTS run_events (
  id         TEXT PRIMARY KEY,
  run_id     TEXT NOT NULL,
  seq        INTEGER NOT NULL,
  kind       TEXT NOT NULL,
  text       TEXT NOT NULL DEFAULT '',
  data       TEXT,
  created_at INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS run_events_run ON run_events(run_id, seq);

CREATE TABLE IF NOT EXISTS questions (
  id          TEXT PRIMARY KEY,
  run_id      TEXT NOT NULL,
  agent_id    TEXT NOT NULL,
  channel_id  TEXT NOT NULL,
  task_id     TEXT,
  message_id  TEXT,
  headline    TEXT NOT NULL DEFAULT '',
  items       TEXT NOT NULL,
  status      TEXT NOT NULL,
  answers     TEXT,
  answered_by TEXT,
  created_at  INTEGER NOT NULL,
  answered_at INTEGER
);
CREATE INDEX IF NOT EXISTS questions_run ON questions(run_id);
CREATE INDEX IF NOT EXISTS questions_status ON questions(status);

CREATE TABLE IF NOT EXISTS inbox (
  id            TEXT PRIMARY KEY,
  member_id     TEXT NOT NULL,
  kind          TEXT NOT NULL,
  title         TEXT NOT NULL,
  preview       TEXT NOT NULL DEFAULT '',
  actor_id      TEXT,
  channel_id    TEXT,
  message_id    TEXT,
  task_id       TEXT,
  run_id        TEXT,
  automation_id TEXT,
  created_at    INTEGER NOT NULL,
  read_at       INTEGER
);
CREATE INDEX IF NOT EXISTS inbox_member ON inbox(member_id, read_at, id);

CREATE TABLE IF NOT EXISTS automations (
  id                 TEXT PRIMARY KEY,
  name               TEXT NOT NULL,
  description        TEXT NOT NULL DEFAULT '',
  enabled            INTEGER NOT NULL DEFAULT 1,
  trigger            TEXT NOT NULL,
  agent_id           TEXT NOT NULL,
  action             TEXT NOT NULL,
  instructions       TEXT NOT NULL DEFAULT '',
  context_channel_id TEXT,
  report_channel_id  TEXT,
  project_id         TEXT,
  location           TEXT NOT NULL DEFAULT 'auto',
  host_id            TEXT,
  created_by         TEXT NOT NULL,
  created_at         INTEGER NOT NULL,
  last_run_at        INTEGER,
  next_run_at        INTEGER,
  failure_count      INTEGER NOT NULL DEFAULT 0
);

CREATE TABLE IF NOT EXISTS automation_runs (
  id              TEXT PRIMARY KEY,
  automation_id   TEXT NOT NULL,
  run_id          TEXT,
  trigger_summary TEXT NOT NULL DEFAULT '',
  trigger_payload TEXT,
  selection       TEXT,
  context_preview TEXT NOT NULL DEFAULT '',
  status          TEXT NOT NULL,
  error           TEXT,
  task_id         TEXT,
  once_key        TEXT,
  created_at      INTEGER NOT NULL,
  ended_at        INTEGER
);
CREATE INDEX IF NOT EXISTS automation_runs_automation ON automation_runs(automation_id, id);

CREATE TABLE IF NOT EXISTS previews (
  id         TEXT PRIMARY KEY,
  task_id    TEXT NOT NULL,
  host_id    TEXT NOT NULL,
  run_id     TEXT,
  label      TEXT NOT NULL DEFAULT '',
  port       INTEGER NOT NULL,
  url        TEXT NOT NULL DEFAULT '',
  status     TEXT NOT NULL,
  local_only INTEGER NOT NULL DEFAULT 0,
  created_at INTEGER NOT NULL,
  stopped_at INTEGER
);
CREATE INDEX IF NOT EXISTS previews_task ON previews(task_id);

-- The realtime stream, persisted so a reconnecting client can catch up
-- instead of refetching the world.
CREATE TABLE IF NOT EXISTS events (
  seq     INTEGER PRIMARY KEY AUTOINCREMENT,
  at      INTEGER NOT NULL,
  payload TEXT NOT NULL
);
