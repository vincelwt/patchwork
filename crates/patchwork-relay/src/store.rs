//! SQLite storage.
//!
//! Queries are small and indexed, so they run directly on the async worker
//! rather than through a blocking pool; the one scan-shaped operation
//! (full-text search) is bounded by SQLite's FTS index.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{anyhow, bail, Context, Result};
use patchwork_core::events::{Envelope, Event};
use patchwork_core::models::*;
use patchwork_core::wire::Device;
use patchwork_core::{new_id, now_ms, Id, Millis};
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::{params, OptionalExtension, Row, TransactionBehavior};
use serde_json::Value as Json;

pub type Pool = r2d2::Pool<SqliteConnectionManager>;
pub type Conn = r2d2::PooledConnection<SqliteConnectionManager>;

#[derive(Clone)]
pub struct Store {
    pool: Pool,
}

pub enum InsertTaskResult {
    Inserted,
    Existing(Task),
}

pub enum SaveWorkspaceSkillResult {
    Saved(WorkspaceSkill),
    Missing,
    TooLarge,
}

pub enum TaskRunHandoff {
    Peer(Task),
    Last,
    Moved,
}

pub enum QuestionCommit {
    Committed {
        blocked: Option<Task>,
        superseded: Vec<Question>,
    },
    RunEnded,
    AlreadyAsking(Question),
}

fn json_col<T: serde::de::DeserializeOwned>(row: &Row, idx: &str) -> Option<T> {
    row.get::<_, Option<String>>(idx)
        .ok()
        .flatten()
        .and_then(|s| serde_json::from_str(&s).ok())
}

fn json_col_or<T: serde::de::DeserializeOwned + Default>(row: &Row, idx: &str) -> T {
    json_col(row, idx).unwrap_or_default()
}

fn to_json(value: &impl serde::Serialize) -> String {
    serde_json::to_string(value).unwrap_or_else(|_| "null".into())
}

fn ensure_column(
    conn: &rusqlite::Connection,
    table: &str,
    column: &str,
    definition: &str,
) -> Result<()> {
    let exists = conn
        .prepare(&format!("PRAGMA table_info({table})"))?
        .query_map([], |row| row.get::<_, String>(1))?
        .any(|name| name.is_ok_and(|name| name == column));
    if !exists {
        conn.execute_batch(&format!(
            "ALTER TABLE {table} ADD COLUMN {column} {definition}"
        ))
        .with_context(|| format!("failed to add {table}.{column}"))?;
    }
    Ok(())
}

impl Store {
    pub fn open(path: &Path) -> Result<Self> {
        if let Some(parent) = path.parent() {
            std::fs::create_dir_all(parent).ok();
        }
        // Switch to WAL exactly once, on a connection of our own: the pool
        // opens several at a time and they would otherwise race on it.
        {
            let conn = rusqlite::Connection::open(path)?;
            conn.execute_batch("PRAGMA busy_timeout = 10000; PRAGMA journal_mode = WAL;")
                .context("failed to prepare the Patchwork database")?;
        }

        let manager = SqliteConnectionManager::file(path).with_init(|c| {
            c.execute_batch(
                "PRAGMA busy_timeout = 10000;
                 PRAGMA synchronous = NORMAL;
                 PRAGMA foreign_keys = ON;",
            )
        });
        let pool = r2d2::Pool::builder()
            .max_size(8)
            .min_idle(Some(1))
            .build(manager)
            .context("failed to open the Patchwork database")?;

        let mut conn = pool.get()?;
        conn.execute_batch(include_str!("schema.sql"))
            .context("failed to apply schema")?;

        // `CREATE TABLE IF NOT EXISTS` does nothing for a table that already
        // exists, so a column added to the schema after a database was made
        // has to be asked for by name. SQLite has no "add if missing": the
        // error for one that is already there is the success case.
        //
        // ponytail: a list, not a migration framework. It is only ever appended
        // to, and dropping a column is left to SQLite ignoring one nobody
        // writes to any more.
        for statement in [
            "ALTER TABLE tasks ADD COLUMN due_at INTEGER",
            "ALTER TABLE workspace ADD COLUMN task_prefix TEXT NOT NULL DEFAULT 'PW'",
            "ALTER TABLE workspace ADD COLUMN icon TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE workspace ADD COLUMN icon_file_id TEXT",
            "ALTER TABLE workspace ADD COLUMN autonomy TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE attachments ADD COLUMN caption TEXT NOT NULL DEFAULT ''",
            "ALTER TABLE messages ADD COLUMN reply_to_id TEXT",
            "ALTER TABLE messages ADD COLUMN suggestions TEXT NOT NULL DEFAULT '[]'",
            "ALTER TABLE tasks ADD COLUMN once_key TEXT",
            "ALTER TABLE tasks ADD COLUMN question_blocked_run_id TEXT",
            "ALTER TABLE tasks ADD COLUMN review_action TEXT",
            "ALTER TABLE tasks ADD COLUMN active_continuation TEXT",
            "ALTER TABLE tasks ADD COLUMN background INTEGER NOT NULL DEFAULT 0",
            "ALTER TABLE automation_runs ADD COLUMN once_key TEXT",
            "ALTER TABLE runs ADD COLUMN provider TEXT",
            "ALTER TABLE runs ADD COLUMN model TEXT",
            "ALTER TABLE runs ADD COLUMN thinking TEXT",
            "ALTER TABLE messages ADD COLUMN client_id TEXT",
            "ALTER TABLE automations ADD COLUMN last_success_at INTEGER",
            "ALTER TABLE automations ADD COLUMN last_error_at INTEGER",
            "ALTER TABLE automations ADD COLUMN last_error TEXT",
            "ALTER TABLE automations ADD COLUMN failure_notification_key TEXT",
            "ALTER TABLE automations ADD COLUMN execution_failure_notification_key TEXT",
            // After the columns, never in schema.sql: an index on a column an
            // older database has not been given yet would fail the batch.
            "CREATE INDEX IF NOT EXISTS automation_runs_once ON automation_runs(automation_id, once_key)",
            // One message per sender, channel and client id: a retried send
            // cannot be stored twice even if two attempts arrive at once.
            "CREATE UNIQUE INDEX IF NOT EXISTS messages_client ON messages(author_id, channel_id, client_id) WHERE client_id IS NOT NULL",
        ] {
            let _ = conn.execute(statement, []);
        }
        // These columns carry user intent and durable obligations, so unlike
        // the legacy best-effort list above, an unexpected migration failure
        // must stop startup rather than silently dropping work.
        for (table, column, definition) in [
            ("automations", "last_validated_at", "INTEGER"),
            ("automation_runs", "kind", "TEXT NOT NULL DEFAULT 'action'"),
            ("automation_runs", "due_at", "INTEGER"),
            (
                "automation_runs",
                "attempt_count",
                "INTEGER NOT NULL DEFAULT 0",
            ),
            ("automation_runs", "retry_at", "INTEGER"),
            ("automation_runs", "lease_until", "INTEGER"),
            ("automation_runs", "accepted_at", "INTEGER"),
        ] {
            ensure_column(&conn, table, column, definition)?;
        }

        let migration_version: i64 =
            conn.pragma_query_value(None, "user_version", |row| row.get(0))?;
        if migration_version < 1 {
            let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
            // v0.2.6 silently disabled unvalidated watches without emitting an
            // event. Restore the latest explicit state still in the durable
            // event log; if provenance has expired, preserve the current value.
            tx.execute(
                "UPDATE automations AS automation
                    SET enabled = (
                            SELECT json_extract(events.payload, '$.automation.enabled')
                              FROM events
                             WHERE json_extract(events.payload, '$.kind') = 'automation_updated'
                               AND json_extract(events.payload, '$.automation.id') = automation.id
                             ORDER BY events.seq DESC LIMIT 1
                        ),
                        next_run_at = CASE
                            WHEN enabled = 0 AND (
                                SELECT json_extract(events.payload, '$.automation.enabled')
                                  FROM events
                                 WHERE json_extract(events.payload, '$.kind') = 'automation_updated'
                                   AND json_extract(events.payload, '$.automation.id') = automation.id
                                 ORDER BY events.seq DESC LIMIT 1
                            ) = 1
                            THEN ?1 + COALESCE(json_extract(automation.trigger, '$.every_seconds'), 60) * 1000
                            ELSE next_run_at
                        END
                  WHERE json_extract(automation.trigger, '$.type') = 'watch'
                    AND automation.last_validated_at IS NULL
                    AND EXISTS (
                        SELECT 1 FROM events
                         WHERE json_extract(events.payload, '$.kind') = 'automation_updated'
                           AND json_extract(events.payload, '$.automation.id') = automation.id
                    )",
                params![now_ms()],
            )?;
            tx.pragma_update(None, "user_version", 1)?;
            tx.commit()?;
        }

        // Canonicalize legacy keys before enforcing one open task per key.
        // Keep the newest of any pre-existing duplicates; no task is deleted.
        conn.execute_batch(
            "UPDATE tasks
                SET once_key = NULLIF(lower(trim(once_key)), '')
              WHERE once_key IS NOT NULL;
             UPDATE tasks AS older
                SET once_key = NULL
              WHERE older.once_key IS NOT NULL
                AND older.status NOT IN ('done', 'canceled')
                AND EXISTS (
                    SELECT 1 FROM tasks AS newer
                     WHERE newer.once_key = older.once_key COLLATE NOCASE
                       AND newer.status NOT IN ('done', 'canceled')
                       AND (newer.created_at > older.created_at
                            OR (newer.created_at = older.created_at AND newer.id > older.id))
                );
             CREATE UNIQUE INDEX IF NOT EXISTS tasks_open_once
                ON tasks(once_key COLLATE NOCASE)
             WHERE once_key IS NOT NULL AND status NOT IN ('done', 'canceled');
             UPDATE automation_runs
                SET once_key = NULLIF(trim(once_key), '')
              WHERE once_key IS NOT NULL;
             UPDATE automation_runs AS newer
                SET once_key = NULL
              WHERE newer.once_key IS NOT NULL
                AND EXISTS (
                    SELECT 1 FROM automation_runs AS older
                     WHERE older.automation_id = newer.automation_id
                       AND older.once_key = newer.once_key
                       AND (older.created_at < newer.created_at
                            OR (older.created_at = newer.created_at AND older.id < newer.id))
                );
             CREATE UNIQUE INDEX IF NOT EXISTS automation_runs_once_unique
                ON automation_runs(automation_id, once_key)
             WHERE once_key IS NOT NULL;
             CREATE UNIQUE INDEX IF NOT EXISTS automation_runs_due_unique
                ON automation_runs(automation_id, kind, due_at)
             WHERE due_at IS NOT NULL;
             CREATE INDEX IF NOT EXISTS automation_runs_ready
                ON automation_runs(status, retry_at, lease_until, due_at);",
        )
        .context("failed to enforce task idempotency")?;

        Ok(Self { pool })
    }

    pub fn conn(&self) -> Result<Conn> {
        self.pool.get().context("database connection unavailable")
    }

    // -- workspace ---------------------------------------------------------

    pub fn workspace(&self) -> Result<Workspace> {
        let conn = self.conn()?;
        conn.query_row(
            "SELECT id, name, icon, icon_file_id, autonomy, created_at, task_prefix, task_seq FROM workspace LIMIT 1",
            [],
            |r| {
                let icon_file_id: Option<String> = r.get(3)?;
                Ok(Workspace {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    icon: r.get(2)?,
                    icon_image: icon_file_id
                        .map(|id| format!("/api/workspace/icon/{id}")),
                    autonomy: r.get(4)?,
                    created_at: r.get(5)?,
                    task_prefix: r.get(6)?,
                    task_seq: r.get(7)?,
                })
            },
        )
        .optional()?
        .ok_or_else(|| anyhow!("workspace is not initialised"))
    }

    /// The id is chosen by the caller: it names the workspace's directory on
    /// disk and its URL prefix, so the two can never drift apart.
    pub fn create_workspace(&self, id: &str, name: &str) -> Result<Workspace> {
        let ws = Workspace {
            id: id.to_string(),
            task_prefix: patchwork_core::models::default_task_prefix(),
            name: name.to_string(),
            icon: String::new(),
            icon_image: None,
            autonomy: String::new(),
            created_at: now_ms(),
            task_seq: 0,
        };
        self.conn()?.execute(
            "INSERT INTO workspace (id, name, created_at, task_seq) VALUES (?1, ?2, ?3, 0)",
            params![ws.id, ws.name, ws.created_at],
        )?;
        Ok(ws)
    }

    pub fn update_workspace(
        &self,
        name: Option<&str>,
        icon: Option<&str>,
        icon_file_id: Option<&str>,
        task_prefix: Option<&str>,
        autonomy: Option<&str>,
    ) -> Result<Workspace> {
        let conn = self.conn()?;
        if let Some(name) = name {
            conn.execute("UPDATE workspace SET name = ?1", params![name])?;
        }
        if let Some(icon) = icon {
            conn.execute(
                "UPDATE workspace SET icon = ?1, icon_file_id = NULL",
                params![icon],
            )?;
        }
        if let Some(id) = icon_file_id {
            conn.execute(
                "UPDATE workspace SET icon = '', icon_file_id = ?1",
                params![id],
            )?;
        }
        if let Some(prefix) = task_prefix {
            conn.execute("UPDATE workspace SET task_prefix = ?1", params![prefix])?;
        }
        if let Some(autonomy) = autonomy {
            conn.execute("UPDATE workspace SET autonomy = ?1", params![autonomy])?;
        }
        self.workspace()
    }

    pub fn save_workspace_skill(
        &self,
        mut skill: WorkspaceSkill,
        must_exist: bool,
        max_total_bytes: usize,
    ) -> Result<SaveWorkspaceSkillResult> {
        let mut conn = self.conn()?;
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let existing_created_at = transaction
            .query_row(
                "SELECT created_at FROM workspace_skills WHERE id = ?1",
                params![skill.id],
                |row| row.get(0),
            )
            .optional()?;
        if must_exist && existing_created_at.is_none() {
            return Ok(SaveWorkspaceSkillResult::Missing);
        }
        if let Some(created_at) = existing_created_at {
            skill.created_at = created_at;
        }
        let existing_bytes: i64 = transaction.query_row(
            "SELECT COALESCE(SUM(length(CAST(name AS BLOB)) + length(CAST(description AS BLOB)) + length(CAST(instructions AS BLOB))), 0)
             FROM workspace_skills WHERE id != ?1",
            params![skill.id],
            |row| row.get(0),
        )?;
        let new_bytes = skill.name.len() + skill.description.len() + skill.instructions.len();
        if existing_bytes as usize + new_bytes > max_total_bytes {
            return Ok(SaveWorkspaceSkillResult::TooLarge);
        }
        transaction.execute(
            "INSERT INTO workspace_skills (id, name, description, instructions, created_at, updated_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)
             ON CONFLICT(id) DO UPDATE SET name=?2, description=?3, instructions=?4, updated_at=?6",
            params![
                skill.id,
                skill.name,
                skill.description,
                skill.instructions,
                skill.created_at,
                skill.updated_at,
            ],
        )?;
        transaction.commit()?;
        Ok(SaveWorkspaceSkillResult::Saved(skill))
    }

    pub fn workspace_skills(&self) -> Result<Vec<WorkspaceSkill>> {
        let conn = self.conn()?;
        let mut statement = conn.prepare(
            "SELECT id, name, description, instructions, created_at, updated_at
             FROM workspace_skills ORDER BY name COLLATE NOCASE, id",
        )?;
        let rows = statement.query_map([], |row| {
            Ok(WorkspaceSkill {
                id: row.get(0)?,
                name: row.get(1)?,
                description: row.get(2)?,
                instructions: row.get(3)?,
                created_at: row.get(4)?,
                updated_at: row.get(5)?,
            })
        })?;
        Ok(rows.filter_map(Result::ok).collect())
    }

    pub fn delete_workspace_skill(&self, id: &str) -> Result<bool> {
        Ok(self
            .conn()?
            .execute("DELETE FROM workspace_skills WHERE id = ?1", params![id])?
            > 0)
    }

    /// Keys already handed out keep the prefix they were made with: renaming
    /// the series is not rewriting history.
    pub fn next_task_key(&self) -> Result<String> {
        let conn = self.conn()?;
        let (prefix, seq): (String, i64) = conn.query_row(
            "UPDATE workspace SET task_seq = task_seq + 1
             RETURNING task_prefix, task_seq",
            [],
            |r| Ok((r.get(0)?, r.get(1)?)),
        )?;
        Ok(format!("{prefix}-{seq}"))
    }

    // -- members -----------------------------------------------------------

    pub fn member_from_row(row: &Row) -> rusqlite::Result<Member> {
        let kind: String = row.get("kind")?;
        let kind = if kind == "agent" {
            MemberKind::Agent
        } else {
            MemberKind::Human
        };
        Ok(Member {
            id: row.get("id")?,
            kind,
            handle: row.get("handle")?,
            display_name: row.get("display_name")?,
            email: row.get("email")?,
            avatar: row.get("avatar")?,
            is_admin: row.get::<_, i64>("is_admin")? != 0,
            created_at: row.get("created_at")?,
            agent: if kind == MemberKind::Agent {
                Some(json_col_or::<AgentProfile>(row, "agent_json"))
            } else {
                None
            },
            presence: Presence::Offline,
        })
    }

    pub fn members(&self) -> Result<Vec<Member>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM members WHERE active = 1 ORDER BY kind DESC, display_name COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([], |r| Self::member_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn member(&self, id: &str) -> Result<Option<Member>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM members WHERE id = ?1", params![id], |r| {
                Self::member_from_row(r)
            })
            .optional()?)
    }

    pub fn member_by_handle(&self, handle: &str) -> Result<Option<Member>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM members WHERE handle = ?1 AND active = 1",
                params![handle],
                |r| Self::member_from_row(r),
            )
            .optional()?)
    }

    pub fn unique_handle(&self, base: &str) -> Result<String> {
        let base = patchwork_core::ids::slugify(base);
        let conn = self.conn()?;
        let mut candidate = base.clone();
        let mut n = 2;
        loop {
            let taken: bool = conn.query_row(
                "SELECT EXISTS(SELECT 1 FROM members WHERE handle = ?1)",
                params![candidate],
                |r| r.get(0),
            )?;
            if !taken {
                return Ok(candidate);
            }
            candidate = format!("{base}-{n}");
            n += 1;
        }
    }

    pub fn insert_member(&self, member: &Member) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO members (id, kind, handle, display_name, email, avatar, is_admin, agent_json, active, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, 1, ?9)",
            params![
                member.id,
                match member.kind { MemberKind::Agent => "agent", MemberKind::Human => "human" },
                member.handle,
                member.display_name,
                member.email,
                member.avatar,
                member.is_admin as i64,
                member.agent.as_ref().map(to_json),
                member.created_at,
            ],
        )?;
        Ok(())
    }

    pub fn update_member(&self, member: &Member) -> Result<()> {
        self.conn()?.execute(
            "UPDATE members SET handle = ?2, display_name = ?3, email = ?4, avatar = ?5,
                                is_admin = ?6, agent_json = ?7 WHERE id = ?1",
            params![
                member.id,
                member.handle,
                member.display_name,
                member.email,
                member.avatar,
                member.is_admin as i64,
                member.agent.as_ref().map(to_json),
            ],
        )?;
        Ok(())
    }

    pub fn deactivate_member(&self, id: &str) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        tx.execute("UPDATE members SET active = 0 WHERE id = ?1", params![id])?;
        tx.execute(
            "UPDATE tokens SET revoked = 1 WHERE member_id = ?1",
            params![id],
        )?;
        tx.execute("DELETE FROM pairings WHERE member_id = ?1", params![id])?;
        tx.commit()?;
        Ok(())
    }

    // -- tokens and invites -------------------------------------------------

    pub fn insert_token(
        &self,
        token_hash: &str,
        member_id: &str,
        kind: &str,
        run_id: Option<&str>,
        label: Option<&str>,
    ) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO tokens (token_hash, member_id, kind, run_id, label, created_at)
             VALUES (?1, ?2, ?3, ?4, ?5, ?6)",
            params![token_hash, member_id, kind, run_id, label, now_ms()],
        )?;
        Ok(())
    }

    /// Returns `(member_id, kind, run_id)` for an active member.
    pub fn lookup_token(&self, token_hash: &str) -> Result<Option<(Id, String, Option<Id>)>> {
        let conn = self.conn()?;
        let found = conn
            .query_row(
                "SELECT tokens.member_id, tokens.kind, tokens.run_id
                 FROM tokens JOIN members ON members.id = tokens.member_id
                 WHERE tokens.token_hash = ?1 AND tokens.revoked = 0 AND members.active = 1",
                params![token_hash],
                |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?)),
            )
            .optional()?;
        if found.is_some() {
            conn.execute(
                "UPDATE tokens SET last_used = ?2 WHERE token_hash = ?1",
                params![token_hash, now_ms()],
            )?;
        }
        Ok(found)
    }

    pub fn insert_pairing(
        &self,
        secret_hash: &str,
        member_id: &str,
        expires_at: i64,
    ) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "DELETE FROM pairings WHERE expires_at <= ?1",
            params![now_ms()],
        )?;
        conn.execute(
            "INSERT INTO pairings (secret_hash, member_id, created_at, expires_at)
             VALUES (?1, ?2, ?3, ?4)",
            params![secret_hash, member_id, now_ms(), expires_at],
        )?;
        Ok(())
    }

    /// Consume a valid pairing and mint its device token in one transaction.
    pub fn claim_pairing(
        &self,
        secret_hash: &str,
        token_hash: &str,
        label: Option<&str>,
        at: i64,
    ) -> Result<Option<Id>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let member_id: Option<Id> = tx
            .query_row(
                "DELETE FROM pairings
                 WHERE secret_hash = ?1 AND expires_at > ?2
                   AND EXISTS (SELECT 1 FROM members
                               WHERE id = pairings.member_id AND kind = 'human' AND active = 1)
                 RETURNING member_id",
                params![secret_hash, at],
                |row| row.get(0),
            )
            .optional()?;
        if let Some(member_id) = &member_id {
            tx.execute(
                "INSERT INTO tokens (token_hash, member_id, kind, label, created_at)
                 VALUES (?1, ?2, 'mobile', ?3, ?4)",
                params![token_hash, member_id, label, at],
            )?;
        }
        tx.commit()?;
        Ok(member_id)
    }

    pub fn devices(&self, member_id: &str, current_token_hash: &str) -> Result<Vec<Device>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT token_hash, COALESCE(NULLIF(label, ''), 'Device'), created_at, last_used
             FROM tokens
             WHERE member_id = ?1 AND kind IN ('device', 'mobile') AND revoked = 0
             ORDER BY created_at DESC",
        )?;
        let rows = stmt.query_map(params![member_id], |row| {
            let id: Id = row.get(0)?;
            Ok(Device {
                current: id == current_token_hash,
                id,
                label: row.get(1)?,
                created_at: row.get(2)?,
                last_used: row.get(3)?,
            })
        })?;
        Ok(rows.filter_map(|row| row.ok()).collect())
    }

    pub fn revoke_device(&self, member_id: &str, id: &str) -> Result<bool> {
        Ok(self.conn()?.execute(
            "UPDATE tokens SET revoked = 1
             WHERE token_hash = ?1 AND member_id = ?2 AND kind IN ('device', 'mobile') AND revoked = 0",
            params![id, member_id],
        )? == 1)
    }

    pub fn revoke_run_tokens(&self, run_id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE tokens SET revoked = 1 WHERE run_id = ?1",
            params![run_id],
        )?;
        Ok(())
    }

    pub fn insert_invite(&self, invite: &Invite) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO invites (code, created_by, created_at, email, is_admin) VALUES (?1,?2,?3,?4,?5)",
            params![invite.code, invite.created_by, invite.created_at, invite.email, invite.is_admin as i64],
        )?;
        Ok(())
    }

    pub fn invites(&self) -> Result<Vec<Invite>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM invites ORDER BY created_at DESC")?;
        let rows = stmt.query_map([], |r| {
            Ok(Invite {
                code: r.get("code")?,
                created_by: r
                    .get::<_, Option<String>>("created_by")?
                    .unwrap_or_default(),
                created_at: r.get("created_at")?,
                email: r.get("email")?,
                is_admin: r.get::<_, i64>("is_admin")? != 0,
                used_at: r.get("used_at")?,
                used_by: r.get("used_by")?,
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn claim_invite(&self, code: &str, member_id: &str) -> Result<Invite> {
        let conn = self.conn()?;
        let invite = conn
            .query_row(
                "SELECT * FROM invites WHERE code = ?1 AND used_at IS NULL",
                params![code],
                |r| {
                    Ok(Invite {
                        code: r.get("code")?,
                        created_by: r
                            .get::<_, Option<String>>("created_by")?
                            .unwrap_or_default(),
                        created_at: r.get("created_at")?,
                        email: r.get("email")?,
                        is_admin: r.get::<_, i64>("is_admin")? != 0,
                        used_at: None,
                        used_by: None,
                    })
                },
            )
            .optional()?
            .ok_or_else(|| anyhow!("that invite code is not valid"))?;
        conn.execute(
            "UPDATE invites SET used_at = ?2, used_by = ?3 WHERE code = ?1",
            params![code, now_ms(), member_id],
        )?;
        Ok(invite)
    }

    // -- sections and channels ---------------------------------------------

    pub fn sections(&self) -> Result<Vec<Section>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT id, name, position FROM sections ORDER BY position")?;
        let rows = stmt.query_map([], |r| {
            Ok(Section {
                id: r.get(0)?,
                name: r.get(1)?,
                position: r.get(2)?,
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn upsert_section(&self, section: &Section) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO sections (id, name, position) VALUES (?1,?2,?3)
             ON CONFLICT(id) DO UPDATE SET name = ?2, position = ?3",
            params![section.id, section.name, section.position],
        )?;
        Ok(())
    }

    pub fn section_by_name(&self, name: &str) -> Result<Option<Section>> {
        Ok(self
            .sections()?
            .into_iter()
            .find(|s| s.name.eq_ignore_ascii_case(name)))
    }

    pub fn rename_section(&self, id: &str, name: &str) -> Result<bool> {
        Ok(self.conn()?.execute(
            "UPDATE sections SET name = ?2 WHERE id = ?1",
            params![id, name],
        )? > 0)
    }

    pub fn delete_section(&self, id: &str) -> Result<bool> {
        Ok(self
            .conn()?
            .execute("DELETE FROM sections WHERE id = ?1", params![id])?
            > 0)
    }

    fn channel_from_row(row: &Row) -> rusqlite::Result<Channel> {
        let kind: String = row.get("kind")?;
        Ok(Channel {
            id: row.get("id")?,
            kind: match kind.as_str() {
                "dm" => ChannelKind::Dm,
                "task" => ChannelKind::Task,
                _ => ChannelKind::Channel,
            },
            section_id: row.get("section_id")?,
            slug: row.get("slug")?,
            name: row.get("name")?,
            topic: row.get("topic")?,
            position: row.get("position")?,
            created_at: row.get("created_at")?,
            member_ids: Vec::new(),
            task_id: row.get("task_id")?,
            last_message_at: row.get("last_message_at")?,
        })
    }

    fn hydrate_channel_members(&self, channels: &mut [Channel]) -> Result<()> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT member_id FROM channel_members WHERE channel_id = ?1")?;
        for ch in channels.iter_mut() {
            if ch.kind == ChannelKind::Channel {
                continue;
            }
            let rows = stmt.query_map(params![ch.id], |r| r.get::<_, String>(0))?;
            ch.member_ids = rows.filter_map(|r| r.ok()).collect();
        }
        Ok(())
    }

    pub fn channels(&self) -> Result<Vec<Channel>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM channels WHERE archived = 0 ORDER BY position, name COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([], |r| Self::channel_from_row(r))?;
        let mut channels: Vec<Channel> = rows.filter_map(|r| r.ok()).collect();
        drop(stmt);
        drop(conn);
        self.hydrate_channel_members(&mut channels)?;
        Ok(channels)
    }

    pub fn channel(&self, id: &str) -> Result<Option<Channel>> {
        let conn = self.conn()?;
        let found = conn
            .query_row("SELECT * FROM channels WHERE id = ?1", params![id], |r| {
                Self::channel_from_row(r)
            })
            .optional()?;
        drop(conn);
        match found {
            Some(mut ch) => {
                let mut one = std::slice::from_mut(&mut ch);
                self.hydrate_channel_members(&mut one)?;
                Ok(Some(ch))
            }
            None => Ok(None),
        }
    }

    pub fn channel_by_slug(&self, slug: &str) -> Result<Option<Channel>> {
        let slug = slug.trim_start_matches('#');
        let conn = self.conn()?;
        let found = conn
            .query_row(
                "SELECT * FROM channels WHERE slug = ?1 AND kind = 'channel'",
                params![slug],
                |r| Self::channel_from_row(r),
            )
            .optional()?;
        Ok(found)
    }

    pub fn insert_channel(&self, channel: &Channel) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO channels (id, kind, section_id, slug, name, topic, position, task_id, last_message_at, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
            params![
                channel.id,
                match channel.kind { ChannelKind::Dm => "dm", ChannelKind::Task => "task", ChannelKind::Channel => "channel" },
                channel.section_id,
                channel.slug,
                channel.name,
                channel.topic,
                channel.position,
                channel.task_id,
                channel.last_message_at,
                channel.created_at,
            ],
        )?;
        for member_id in &channel.member_ids {
            conn.execute(
                "INSERT OR IGNORE INTO channel_members (channel_id, member_id) VALUES (?1, ?2)",
                params![channel.id, member_id],
            )?;
        }
        Ok(())
    }

    pub fn update_channel(&self, channel: &Channel) -> Result<()> {
        self.conn()?.execute(
            "UPDATE channels SET section_id = ?2, slug = ?3, name = ?4, topic = ?5, position = ?6 WHERE id = ?1",
            params![channel.id, channel.section_id, channel.slug, channel.name, channel.topic, channel.position],
        )?;
        Ok(())
    }

    pub fn archive_channel(&self, id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE channels SET archived = 1 WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// The existing DM between exactly these two members, if any.
    pub fn find_dm(&self, a: &str, b: &str) -> Result<Option<Channel>> {
        let conn = self.conn()?;
        let id: Option<String> = conn
            .query_row(
                "SELECT c.id FROM channels c
                 JOIN channel_members m1 ON m1.channel_id = c.id AND m1.member_id = ?1
                 JOIN channel_members m2 ON m2.channel_id = c.id AND m2.member_id = ?2
                 WHERE c.kind = 'dm'
                   AND (SELECT COUNT(*) FROM channel_members cm WHERE cm.channel_id = c.id) = 2
                 LIMIT 1",
                params![a, b],
                |r| r.get(0),
            )
            .optional()?;
        drop(conn);
        match id {
            Some(id) => self.channel(&id),
            None => Ok(None),
        }
    }

    // -- messages -----------------------------------------------------------

    fn message_from_row(row: &Row) -> rusqlite::Result<Message> {
        let kind: String = row.get("kind")?;
        Ok(Message {
            id: row.get("id")?,
            channel_id: row.get("channel_id")?,
            author_id: row.get("author_id")?,
            kind: match kind.as_str() {
                "status" => MessageKind::Status,
                "system" => MessageKind::System,
                "card" => MessageKind::Card,
                _ => MessageKind::Text,
            },
            body: row.get("body")?,
            card: json_col(row, "card"),
            suggestions: json_col_or(row, "suggestions"),
            parent_id: row.get("parent_id")?,
            reply_to_id: row.get("reply_to_id")?,
            reply_to: None,
            reply_count: row.get::<_, i64>("reply_count")? as u32,
            last_reply_at: row.get("last_reply_at")?,
            run_id: row.get("run_id")?,
            task_id: row.get("task_id")?,
            mentions: json_col_or(row, "mentions"),
            attachments: Vec::new(),
            reactions: Vec::new(),
            created_at: row.get("created_at")?,
            edited_at: row.get("edited_at")?,
        })
    }

    pub fn insert_message(&self, message: &Message) -> Result<()> {
        self.insert_message_as(message, None)
    }

    /// `client_id` is the sender's own id for this message. It is not part of
    /// the message anyone reads; it only lets a retry be recognised as the same
    /// send through `message_by_client_id`.
    pub fn insert_message_as(&self, message: &Message, client_id: Option<&str>) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        tx.execute(
            "INSERT INTO messages (id, channel_id, author_id, kind, body, card, suggestions, parent_id, reply_to_id, run_id, task_id, mentions, created_at, client_id)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
            params![
                message.id,
                message.channel_id,
                message.author_id,
                match message.kind {
                    MessageKind::Status => "status",
                    MessageKind::System => "system",
                    MessageKind::Card => "card",
                    MessageKind::Text => "text",
                },
                message.body,
                message.card.as_ref().map(to_json),
                to_json(&message.suggestions),
                message.parent_id,
                message.reply_to_id,
                message.run_id,
                message.task_id,
                to_json(&message.mentions),
                message.created_at,
                client_id,
            ],
        )?;
        tx.execute(
            "INSERT INTO message_search (message_id, channel_id, body) VALUES (?1, ?2, ?3)",
            params![message.id, message.channel_id, message.body],
        )?;
        tx.execute(
            "UPDATE channels SET last_message_at = ?2 WHERE id = ?1",
            params![message.channel_id, message.created_at],
        )?;
        if let Some(parent) = &message.parent_id {
            tx.execute(
                "UPDATE messages SET reply_count = reply_count + 1, last_reply_at = ?2 WHERE id = ?1",
                params![parent, message.created_at],
            )?;
        }
        for attachment in &message.attachments {
            let claimed = tx.execute(
                "UPDATE attachments SET message_id = ?2, task_id = COALESCE(task_id, ?3)
                 WHERE id = ?1 AND message_id IS NULL",
                params![attachment.id, message.id, message.task_id],
            )?;
            if claimed != 1 {
                return Err(anyhow!("an attachment already belongs to another message"));
            }
        }
        tx.commit()?;
        Ok(())
    }

    pub fn message(&self, id: &str) -> Result<Option<Message>> {
        let conn = self.conn()?;
        let msg = conn
            .query_row("SELECT * FROM messages WHERE id = ?1", params![id], |r| {
                Self::message_from_row(r)
            })
            .optional()?;
        drop(conn);
        match msg {
            Some(mut m) => {
                self.hydrate_messages(std::slice::from_mut(&mut m))?;
                Ok(Some(m))
            }
            None => Ok(None),
        }
    }

    /// The message a sender already stored under this id in this channel, if any.
    pub fn message_by_client_id(
        &self,
        author_id: &str,
        channel_id: &str,
        client_id: &str,
    ) -> Result<Option<Message>> {
        let conn = self.conn()?;
        let id: Option<String> = conn
            .query_row(
                "SELECT id FROM messages WHERE author_id = ?1 AND channel_id = ?2 AND client_id = ?3",
                params![author_id, channel_id, client_id],
                |row| row.get(0),
            )
            .optional()?;
        drop(conn);
        match id {
            Some(id) => self.message(&id),
            None => Ok(None),
        }
    }

    /// The final response authored by an agent run, excluding progress notes.
    pub fn last_run_message(&self, run_id: &str, author_id: &str) -> Result<Option<Message>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM messages
                 WHERE run_id=?1 AND author_id=?2 AND kind='text' AND trim(body)!=''
                 ORDER BY id DESC LIMIT 1",
                params![run_id, author_id],
                Self::message_from_row,
            )
            .optional()?)
    }

    /// The one live status line an agent run owns in this conversation.
    pub fn run_status_message(
        &self,
        run_id: &str,
        channel_id: &str,
        author_id: &str,
    ) -> Result<Option<Message>> {
        let conn = self.conn()?;
        let id: Option<String> = conn
            .query_row(
                "SELECT id FROM messages WHERE run_id = ?1 AND channel_id = ?2
                 AND author_id = ?3 AND kind = 'status' AND parent_id IS NULL
                 ORDER BY id DESC LIMIT 1",
                params![run_id, channel_id, author_id],
                |row| row.get(0),
            )
            .optional()?;
        drop(conn);
        match id {
            Some(id) => self.message(&id),
            None => Ok(None),
        }
    }

    /// A streamed reply only knows who it mentions once it is finished.
    pub fn set_message_mentions(&self, id: &str, mentions: &[Id]) -> Result<()> {
        self.conn()?.execute(
            "UPDATE messages SET mentions = ?2 WHERE id = ?1",
            params![id, to_json(&mentions)],
        )?;
        Ok(())
    }

    /// Rewrite a reply that is still being written. Unlike an edit this leaves
    /// `edited_at` alone — the agent is composing, not revising.
    pub fn stream_message_body(&self, id: &str, body: &str) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "UPDATE messages SET body = ?2 WHERE id = ?1",
            params![id, body],
        )?;
        conn.execute(
            "UPDATE message_search SET body = ?2 WHERE message_id = ?1",
            params![id, body],
        )?;
        Ok(())
    }

    pub fn set_message_suggestions(&self, id: &str, suggestions: &[String]) -> Result<()> {
        self.conn()?.execute(
            "UPDATE messages SET suggestions = ?2 WHERE id = ?1",
            params![id, to_json(&suggestions)],
        )?;
        Ok(())
    }

    pub fn update_message_body(&self, id: &str, body: &str) -> Result<()> {
        let conn = self.conn()?;
        conn.execute(
            "UPDATE messages SET body = ?2, edited_at = ?3 WHERE id = ?1",
            params![id, body, now_ms()],
        )?;
        conn.execute(
            "UPDATE message_search SET body = ?2 WHERE message_id = ?1",
            params![id, body],
        )?;
        Ok(())
    }

    pub fn delete_message(&self, id: &str) -> Result<()> {
        let conn = self.conn()?;
        conn.execute("DELETE FROM messages WHERE id = ?1", params![id])?;
        conn.execute(
            "DELETE FROM message_search WHERE message_id = ?1",
            params![id],
        )?;
        Ok(())
    }

    /// Newest-first page of top-level messages, returned oldest-first.
    pub fn messages(
        &self,
        channel_id: &str,
        before: Option<&str>,
        limit: usize,
    ) -> Result<(Vec<Message>, bool)> {
        let conn = self.conn()?;
        let limit = limit.clamp(1, 500);
        let mut messages: Vec<Message> = match before {
            Some(before) => {
                let mut stmt = conn.prepare(
                    "SELECT * FROM messages WHERE channel_id = ?1 AND parent_id IS NULL AND id < ?2
                     ORDER BY id DESC LIMIT ?3",
                )?;
                let rows = stmt.query_map(params![channel_id, before, limit as i64 + 1], |r| {
                    Self::message_from_row(r)
                })?;
                rows.filter_map(|r| r.ok()).collect()
            }
            None => {
                let mut stmt = conn.prepare(
                    "SELECT * FROM messages WHERE channel_id = ?1 AND parent_id IS NULL
                     ORDER BY id DESC LIMIT ?2",
                )?;
                let rows = stmt.query_map(params![channel_id, limit as i64 + 1], |r| {
                    Self::message_from_row(r)
                })?;
                rows.filter_map(|r| r.ok()).collect()
            }
        };
        drop(conn);

        let has_more = messages.len() > limit;
        messages.truncate(limit);
        messages.reverse();
        self.hydrate_messages(&mut messages)?;
        Ok((messages, has_more))
    }

    pub fn thread(&self, parent_id: &str) -> Result<Vec<Message>> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT * FROM messages WHERE parent_id = ?1 ORDER BY id ASC")?;
        let rows = stmt.query_map(params![parent_id], |r| Self::message_from_row(r))?;
        let mut messages: Vec<Message> = rows.filter_map(|r| r.ok()).collect();
        drop(stmt);
        drop(conn);
        self.hydrate_messages(&mut messages)?;
        Ok(messages)
    }

    /// Most recent messages in a channel, oldest-first — what an agent gets as
    /// conversation context.
    pub fn recent_messages(&self, channel_id: &str, limit: usize) -> Result<Vec<Message>> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT * FROM messages WHERE channel_id = ?1 ORDER BY id DESC LIMIT ?2")?;
        let rows = stmt.query_map(params![channel_id, limit as i64], |r| {
            Self::message_from_row(r)
        })?;
        let mut messages: Vec<Message> = rows.filter_map(|r| r.ok()).collect();
        messages.reverse();
        Ok(messages)
    }

    fn hydrate_messages(&self, messages: &mut [Message]) -> Result<()> {
        if messages.is_empty() {
            return Ok(());
        }
        let conn = self.conn()?;
        let mut reactions =
            conn.prepare("SELECT member_id, emoji FROM reactions WHERE message_id = ?1")?;
        let mut attachments = conn.prepare("SELECT * FROM attachments WHERE message_id = ?1")?;
        let mut replies =
            conn.prepare("SELECT id, author_id, body, card FROM messages WHERE id = ?1")?;
        for m in messages.iter_mut() {
            let mut grouped: BTreeMap<String, Vec<String>> = BTreeMap::new();
            let rows = reactions.query_map(params![m.id], |r| {
                Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?))
            })?;
            for (member_id, emoji) in rows.flatten() {
                grouped.entry(emoji).or_default().push(member_id);
            }
            m.reactions = grouped
                .into_iter()
                .map(|(emoji, member_ids)| Reaction { emoji, member_ids })
                .collect();

            let rows = attachments.query_map(params![m.id], |r| Self::attachment_from_row(r))?;
            m.attachments = rows.filter_map(|r| r.ok()).collect();

            if let Some(reply_to_id) = &m.reply_to_id {
                m.reply_to = replies
                    .query_row(params![reply_to_id], |row| {
                        Ok(ReplyPreview {
                            id: row.get("id")?,
                            author_id: row.get("author_id")?,
                            body: row.get("body")?,
                            card: json_col(row, "card"),
                        })
                    })
                    .optional()?;
            }
        }
        Ok(())
    }

    pub fn toggle_reaction(&self, message_id: &str, member_id: &str, emoji: &str) -> Result<()> {
        let conn = self.conn()?;
        let existing: bool = conn.query_row(
            "SELECT EXISTS(SELECT 1 FROM reactions WHERE message_id=?1 AND member_id=?2 AND emoji=?3)",
            params![message_id, member_id, emoji],
            |r| r.get(0),
        )?;
        if existing {
            conn.execute(
                "DELETE FROM reactions WHERE message_id=?1 AND member_id=?2 AND emoji=?3",
                params![message_id, member_id, emoji],
            )?;
        } else {
            conn.execute(
                "INSERT INTO reactions (message_id, member_id, emoji) VALUES (?1,?2,?3)",
                params![message_id, member_id, emoji],
            )?;
        }
        Ok(())
    }

    pub fn search_messages(&self, query: &str, limit: usize) -> Result<Vec<Message>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT m.* FROM message_search s JOIN messages m ON m.id = s.message_id
             WHERE message_search MATCH ?1 ORDER BY m.id DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![query, limit as i64], |r| Self::message_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    // -- attachments --------------------------------------------------------

    fn attachment_from_row(row: &Row) -> rusqlite::Result<Attachment> {
        let id: String = row.get("id")?;
        Ok(Attachment {
            url: format!("/api/files/{id}"),
            id,
            file_name: row.get("file_name")?,
            mime: row.get("mime")?,
            size: row.get("size")?,
            caption: row.get("caption")?,
            message_id: row.get("message_id")?,
            task_id: row.get("task_id")?,
            run_id: row.get("run_id")?,
            created_at: row.get("created_at")?,
        })
    }

    pub fn insert_attachment(&self, attachment: &Attachment, path: &str) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO attachments (id, file_name, mime, size, caption, path, message_id, task_id, run_id, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
            params![
                attachment.id,
                attachment.file_name,
                attachment.mime,
                attachment.size,
                attachment.caption,
                path,
                attachment.message_id,
                attachment.task_id,
                attachment.run_id,
                attachment.created_at
            ],
        )?;
        Ok(())
    }

    /// Returns `(attachment, on-disk path)`.
    pub fn attachment(&self, id: &str) -> Result<Option<(Attachment, String)>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM attachments WHERE id = ?1",
                params![id],
                |r| Ok((Self::attachment_from_row(r)?, r.get::<_, String>("path")?)),
            )
            .optional()?)
    }

    pub fn task_attachments(&self, task_id: &str) -> Result<Vec<Attachment>> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT * FROM attachments WHERE task_id = ?1 ORDER BY id DESC")?;
        let rows = stmt.query_map(params![task_id], |r| Self::attachment_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Unpin evidence while preserving an attachment posted in chat.
    pub fn remove_task_attachment(&self, id: &str, task_id: &str) -> Result<bool> {
        Ok(self.conn()?.execute(
            "UPDATE attachments SET task_id = NULL WHERE id = ?1 AND task_id = ?2",
            params![id, task_id],
        )? == 1)
    }

    // -- tasks --------------------------------------------------------------

    fn task_from_row(row: &Row) -> rusqlite::Result<Task> {
        let status: String = row.get("status")?;
        Ok(Task {
            id: row.get("id")?,
            key: row.get("key")?,
            title: row.get("title")?,
            outcome: row.get("outcome")?,
            status: TaskStatus::parse(&status).unwrap_or(TaskStatus::Planned),
            owner_id: row.get("owner_id")?,
            source_channel_id: row.get("source_channel_id")?,
            source_message_id: row.get("source_message_id")?,
            background: row.get("background")?,
            discussion_channel_id: row.get("discussion_channel_id")?,
            project_id: row.get("project_id")?,
            host_id: row.get("host_id")?,
            worktree_id: row.get("worktree_id")?,
            current_run_id: row.get("current_run_id")?,
            active_continuation: json_col(row, "active_continuation"),
            pr_url: row.get("pr_url")?,
            pr_state: json_col(row, "pr_state"),
            review_action: row.get("review_action")?,
            created_by: row.get("created_by")?,
            due_at: row.get("due_at")?,
            once_key: row.get("once_key")?,
            created_at: row.get("created_at")?,
            updated_at: row.get("updated_at")?,
            position: row.get("position")?,
        })
    }

    pub fn insert_task(&self, task: &Task) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO tasks (id, key, title, outcome, status, owner_id, source_channel_id, source_message_id,
                                discussion_channel_id, project_id, host_id, worktree_id, current_run_id, pr_url,
                                pr_state, review_action, created_by, due_at, once_key, position, created_at, updated_at, background)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23)",
            params![
                task.id, task.key, task.title, task.outcome, task.status.as_str(), task.owner_id,
                task.source_channel_id, task.source_message_id, task.discussion_channel_id,
                task.project_id, task.host_id, task.worktree_id, task.current_run_id, task.pr_url,
                task.pr_state.as_ref().map(to_json), task.review_action, task.created_by,
                task.due_at, task.once_key, task.position, task.created_at, task.updated_at,
                task.background
            ],
        )?;
        Ok(())
    }

    /// Insert a task and its discussion under one SQLite write lock. The
    /// in-transaction lookup closes the read-before-write race for `once_key`.
    pub fn insert_task_with_channel(
        &self,
        task: &Task,
        channel: &Channel,
    ) -> Result<InsertTaskResult> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;

        if let Some(key) = task.once_key.as_deref() {
            let existing = tx
                .query_row(
                    "SELECT * FROM tasks
                     WHERE once_key = ?1 COLLATE NOCASE AND status NOT IN ('done', 'canceled')
                     ORDER BY created_at DESC LIMIT 1",
                    params![key],
                    Self::task_from_row,
                )
                .optional()?;
            if let Some(existing) = existing {
                tx.rollback()?;
                return Ok(InsertTaskResult::Existing(existing));
            }
        }

        tx.execute(
            "INSERT INTO channels (id, kind, section_id, slug, name, topic, position, task_id, last_message_at, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10)",
            params![
                channel.id,
                match channel.kind { ChannelKind::Dm => "dm", ChannelKind::Task => "task", ChannelKind::Channel => "channel" },
                channel.section_id,
                channel.slug,
                channel.name,
                channel.topic,
                channel.position,
                task.id,
                channel.last_message_at,
                channel.created_at,
            ],
        )?;
        for member_id in &channel.member_ids {
            tx.execute(
                "INSERT OR IGNORE INTO channel_members (channel_id, member_id) VALUES (?1, ?2)",
                params![channel.id, member_id],
            )?;
        }
        tx.execute(
            "INSERT INTO tasks (id, key, title, outcome, status, owner_id, source_channel_id, source_message_id,
                                discussion_channel_id, project_id, host_id, worktree_id, current_run_id, pr_url,
                                pr_state, created_by, due_at, once_key, position, created_at, updated_at, background)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)",
            params![
                task.id, task.key, task.title, task.outcome, task.status.as_str(), task.owner_id,
                task.source_channel_id, task.source_message_id, task.discussion_channel_id,
                task.project_id, task.host_id, task.worktree_id, task.current_run_id, task.pr_url,
                task.pr_state.as_ref().map(to_json), task.created_by, task.due_at, task.once_key,
                task.position, task.created_at, task.updated_at, task.background
            ],
        )?;
        tx.commit()?;
        Ok(InsertTaskResult::Inserted)
    }

    pub fn update_task(&self, task: &Task) -> Result<()> {
        self.update_task_inner(task, false)
    }

    /// Persist a task status chosen outside the question lifecycle. Even if
    /// the visible status stays `blocked`, a human or agent has taken control
    /// of it and answering an older question must not silently move it again.
    pub fn update_task_with_explicit_status(&self, task: &Task) -> Result<()> {
        self.update_task_inner(task, true)
    }

    fn update_task_inner(&self, task: &Task, explicit_status: bool) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if explicit_status && task.status == TaskStatus::Running {
            let has_work: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM runs WHERE task_id=?1
                                  AND status IN ('queued','dispatched','running','waiting'))
                     OR EXISTS(SELECT 1 FROM task_continuations WHERE task_id=?1
                                  AND ended_at IS NULL AND status IN ('waiting','ready'))",
                params![task.id],
                |row| row.get(0),
            )?;
            if !has_work {
                bail!("start a run or register a continuation before moving a task to running");
            }
        }
        if explicit_status && task.status != TaskStatus::Running {
            tx.execute(
                "UPDATE task_continuations SET ended_at=?2, updated_at=?2
                 WHERE task_id=?1 AND ended_at IS NULL",
                params![task.id, now_ms()],
            )?;
        }
        tx.execute(
            "UPDATE tasks SET title=?2, outcome=?3, status=?4, owner_id=?5, project_id=?6, host_id=?7,
                              worktree_id=?8, current_run_id=?9, pr_url=?10, pr_state=?11, due_at=?12,
                              position=?13, updated_at=MAX(?14, updated_at + 1),
                              question_blocked_run_id=CASE
                                WHEN ?15 OR ?4 != 'blocked' THEN NULL
                                ELSE question_blocked_run_id
                              END,
                              active_continuation=CASE
                                WHEN ?15 AND ?4 != 'running' THEN NULL
                                ELSE active_continuation
                              END,
                              review_action=?16
              WHERE id=?1",
            params![
                task.id, task.title, task.outcome, task.status.as_str(), task.owner_id,
                task.project_id, task.host_id, task.worktree_id, task.current_run_id, task.pr_url,
                task.pr_state.as_ref().map(to_json), task.due_at, task.position, now_ms(),
                explicit_status,
                task.review_action
            ],
        )?;
        tx.execute(
            "UPDATE channels SET name = ?2, topic = ?3 WHERE id = ?1",
            params![
                task.discussion_channel_id,
                format!("{}: {}", task.key, task.title),
                task.outcome,
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    /// Claim a review action exactly once before dispatching the follow-up run.
    /// The compare-and-set keeps a double click (or two open clients) from
    /// starting the approved action twice.
    pub fn claim_review_action(&self, task_id: &str, action: &str) -> Result<bool> {
        Ok(self.conn()?.execute(
            "UPDATE tasks SET status = 'running', review_action = NULL,
                              updated_at = MAX(?3, updated_at + 1)
             WHERE id = ?1 AND status = 'review' AND review_action = ?2
               AND current_run_id IS NULL",
            params![task_id, action, now_ms()],
        )? == 1)
    }

    /// Put an approval back when dispatch failed before a run took ownership.
    pub fn restore_review_action(&self, task_id: &str, action: &str) -> Result<bool> {
        Ok(self.conn()?.execute(
            "UPDATE tasks SET status = 'review', review_action = ?2,
                              updated_at = MAX(?3, updated_at + 1)
             WHERE id = ?1 AND status = 'running' AND review_action IS NULL
               AND current_run_id IS NULL",
            params![task_id, action, now_ms()],
        )? == 1)
    }

    pub fn update_task_if_unchanged(
        &self,
        task: &Task,
        expected_updated_at: Millis,
        explicit_status: bool,
    ) -> Result<bool> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if explicit_status && task.status == TaskStatus::Running {
            let has_work: bool = tx.query_row(
                "SELECT EXISTS(SELECT 1 FROM runs WHERE task_id=?1
                                  AND status IN ('queued','dispatched','running','waiting'))
                     OR EXISTS(SELECT 1 FROM task_continuations WHERE task_id=?1
                                  AND ended_at IS NULL AND status IN ('waiting','ready'))",
                params![task.id],
                |row| row.get(0),
            )?;
            if !has_work {
                bail!("start a run or register a continuation before moving a task to running");
            }
        }
        if explicit_status && task.status != TaskStatus::Running {
            tx.execute(
                "UPDATE task_continuations SET ended_at=?2, updated_at=?2
                 WHERE task_id=?1 AND ended_at IS NULL",
                params![task.id, now_ms()],
            )?;
        }
        let changed = tx.execute(
            "UPDATE tasks SET title=?2, outcome=?3, status=?4, owner_id=?5, project_id=?6, host_id=?7,
                              worktree_id=?8, current_run_id=?9, pr_url=?10, pr_state=?11, due_at=?12,
                              position=?13, updated_at=MAX(?14, updated_at + 1),
                              question_blocked_run_id=CASE
                                WHEN ?15 OR ?4 != 'blocked' THEN NULL
                                ELSE question_blocked_run_id
                              END,
                              active_continuation=CASE
                                WHEN ?15 AND ?4 != 'running' THEN NULL
                                ELSE active_continuation
                              END,
                              review_action=?16
             WHERE id=?1 AND updated_at=?17",
            params![
                task.id, task.title, task.outcome, task.status.as_str(), task.owner_id,
                task.project_id, task.host_id, task.worktree_id, task.current_run_id, task.pr_url,
                task.pr_state.as_ref().map(to_json), task.due_at, task.position, now_ms(),
                explicit_status, task.review_action, expected_updated_at
            ],
        )?;
        if changed == 0 {
            return Ok(false);
        }
        tx.execute(
            "UPDATE channels SET name = ?2, topic = ?3 WHERE id = ?1",
            params![
                task.discussion_channel_id,
                format!("{}: {}", task.key, task.title),
                task.outcome,
            ],
        )?;
        tx.commit()?;
        Ok(true)
    }

    /// Put the task in Running and point it at this run. Joining a task that
    /// is already running is allowed: `current_run_id` is the newest run to
    /// look at, not a lock, and the task is only released when the last of
    /// them stops.
    pub fn activate_task_run(
        &self,
        task_id: &str,
        run_id: &str,
        required_status: Option<TaskStatus>,
    ) -> Result<Option<TaskStatus>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = tx
            .query_row(
                "SELECT status, current_run_id, updated_at FROM tasks WHERE id = ?1",
                params![task_id],
                |row| {
                    Ok((
                        row.get::<_, String>(0)?,
                        row.get::<_, Option<String>>(1)?,
                        row.get::<_, Millis>(2)?,
                    ))
                },
            )
            .optional()?;
        let Some((status, _current_run_id, updated_at)) = current else {
            return Ok(None);
        };
        let status = TaskStatus::parse(&status).unwrap_or(TaskStatus::Planned);
        if status.is_terminal() || required_status.is_some_and(|required| required != status) {
            return Ok(None);
        }
        tx.execute(
            "UPDATE tasks SET status='running', current_run_id=?2, updated_at=?3 WHERE id=?1",
            params![task_id, run_id, now_ms().max(updated_at + 1)],
        )?;
        tx.commit()?;
        Ok(Some(status))
    }

    /// Only the pull request column. The watcher's task snapshot is seconds
    /// old by the time `gh` answers, so writing the whole row back would undo
    /// everything that happened meanwhile — including a `current_run_id` the
    /// finished run had just cleared, which parks the task for good.
    pub fn set_task_pr_state(&self, task_id: &str, pr: &PullRequestState) -> Result<Option<Task>> {
        self.conn()?.execute(
            "UPDATE tasks SET pr_state=?2, updated_at=MAX(?3, updated_at + 1) WHERE id=?1",
            params![task_id, to_json(pr), now_ms()],
        )?;
        self.task(task_id)
    }

    /// Free tasks still pointing at a run that has already ended. `finish_run`
    /// clears the pointer as work ends; a row that missed it accepts no new run
    /// and no approval, and nothing else ever comes back to fix it.
    pub fn clear_finished_task_runs(&self) -> Result<usize> {
        Ok(self.conn()?.execute(
            "UPDATE tasks SET current_run_id = NULL, updated_at = updated_at + 1
             WHERE current_run_id IS NOT NULL
               AND current_run_id IN
                   (SELECT id FROM runs WHERE status IN ('succeeded','failed','cancelled'))",
            [],
        )?)
    }

    pub fn hand_off_finished_task_run(
        &self,
        task_id: &str,
        finished_run_id: &str,
    ) -> Result<TaskRunHandoff> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current: Option<String> = tx
            .query_row(
                "SELECT current_run_id FROM tasks WHERE id=?1",
                params![task_id],
                |row| row.get(0),
            )
            .optional()?
            .flatten();
        if current.as_deref() != Some(finished_run_id) {
            return Ok(TaskRunHandoff::Moved);
        }
        let peer: Option<String> = tx
            .query_row(
                "SELECT id FROM runs WHERE task_id=?1 AND id!=?2
                   AND status IN ('queued','dispatched','running','waiting')
                 ORDER BY id DESC LIMIT 1",
                params![task_id, finished_run_id],
                |row| row.get(0),
            )
            .optional()?;
        let Some(peer) = peer else {
            return Ok(TaskRunHandoff::Last);
        };
        tx.execute(
            "UPDATE tasks SET current_run_id=?3, updated_at=MAX(?4, updated_at + 1)
             WHERE id=?1 AND current_run_id=?2",
            params![task_id, finished_run_id, peer, now_ms()],
        )?;
        let task = tx.query_row(
            "SELECT * FROM tasks WHERE id=?1",
            params![task_id],
            Self::task_from_row,
        )?;
        tx.commit()?;
        Ok(TaskRunHandoff::Peer(task))
    }

    pub fn finalize_task_run_start(
        &self,
        task_id: &str,
        run_id: &str,
        run_created_at: Millis,
    ) -> Result<bool> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let owns_task: bool = tx.query_row(
            "SELECT COALESCE(current_run_id=?2, 0) FROM tasks WHERE id=?1",
            params![task_id, run_id],
            |row| row.get(0),
        )?;
        if !owns_task {
            return Ok(false);
        }
        let now = now_ms();
        let ended_continuation = tx.execute(
            "UPDATE task_continuations SET ended_at=?4, updated_at=?4
             WHERE task_id=?1 AND ended_at IS NULL AND run_id!=?2
               AND (created_at<?3 OR (created_at=?3 AND id<?2))",
            params![task_id, run_id, run_created_at, now],
        )? > 0;
        let changed = tx.execute(
            "UPDATE tasks SET review_action=NULL, question_blocked_run_id=NULL,
                              active_continuation=CASE WHEN ?4 THEN NULL ELSE active_continuation END,
                              updated_at=MAX(?3, updated_at + 1)
             WHERE id=?1 AND current_run_id=?2",
            params![task_id, run_id, now, ended_continuation],
        )? > 0;
        tx.commit()?;
        Ok(changed)
    }

    /// A run that never reached its host gives the task back — unless someone
    /// else is still working on it, in which case the task stays running and
    /// only the pointer moves to whoever is left.
    pub fn restore_task_after_failed_start(
        &self,
        task_id: &str,
        run_id: &str,
        previous_status: TaskStatus,
    ) -> Result<bool> {
        Ok(self.conn()?.execute(
            "WITH remaining AS (
               SELECT id FROM runs WHERE task_id = ?1 AND id != ?2
                 AND status IN ('queued','dispatched','running','waiting')
               ORDER BY id DESC LIMIT 1
             )
             UPDATE tasks
             SET status = CASE
                   WHEN status='running' AND (SELECT id FROM remaining) IS NULL THEN ?3
                   ELSE status END,
                 current_run_id = (SELECT id FROM remaining),
                 updated_at = MAX(?4, updated_at + 1)
             WHERE id=?1 AND current_run_id=?2",
            params![task_id, run_id, previous_status.as_str(), now_ms()],
        )? > 0)
    }

    pub fn task(&self, id: &str) -> Result<Option<Task>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM tasks WHERE id = ?1", params![id], |r| {
                Self::task_from_row(r)
            })
            .optional()?)
    }

    /// Accepts an id or a human key like `PW-14`.
    pub fn set_task_source_message(&self, task_id: &str, message_id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE tasks SET source_message_id = ?2 WHERE id = ?1",
            params![task_id, message_id],
        )?;
        Ok(())
    }

    pub fn task_by_source_message(&self, message_id: &str) -> Result<Option<Task>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM tasks WHERE source_message_id = ?1 LIMIT 1",
                params![message_id],
                |row| Self::task_from_row(row),
            )
            .optional()?)
    }

    pub fn task_by_ref(&self, reference: &str) -> Result<Option<Task>> {
        if let Some(task) = self.task(reference)? {
            return Ok(Some(task));
        }
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM tasks WHERE key = ?1 COLLATE NOCASE",
                params![reference],
                |r| Self::task_from_row(r),
            )
            .optional()?)
    }

    pub fn tasks(&self) -> Result<Vec<Task>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM tasks ORDER BY position, created_at DESC")?;
        let rows = stmt.query_map([], |r| Self::task_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// The open task an agent already made about this, if it made one. Terminal
    /// tasks are not open: the same thing recurring is new work, not a ghost.
    pub fn task_by_once_key(&self, key: &str) -> Result<Option<Task>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM tasks WHERE once_key = ?1 COLLATE NOCASE
                   AND status NOT IN ('done', 'canceled')
                 ORDER BY created_at DESC LIMIT 1",
                params![key],
                |r| Self::task_from_row(r),
            )
            .optional()?)
    }

    pub fn delete_task(&self, id: &str) -> Result<Vec<String>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction()?;
        let files = {
            let mut statement = tx.prepare("SELECT path FROM attachments WHERE task_id = ?1")?;
            let files = statement
                .query_map(params![id], |row| row.get(0))?
                .filter_map(Result::ok)
                .collect();
            files
        };
        tx.execute("DELETE FROM attachments WHERE task_id = ?1", params![id])?;
        tx.execute("DELETE FROM previews WHERE task_id = ?1", params![id])?;
        tx.execute(
            "DELETE FROM task_continuations WHERE task_id = ?1",
            params![id],
        )?;
        tx.execute("DELETE FROM tasks WHERE id = ?1", params![id])?;
        tx.commit()?;
        Ok(files)
    }

    // -- durable task continuations ----------------------------------------

    fn task_continuation_from_row(row: &Row) -> rusqlite::Result<TaskContinuation> {
        let status: String = row.get("status")?;
        Ok(TaskContinuation {
            id: row.get("id")?,
            task_id: row.get("task_id")?,
            run_id: row.get("run_id")?,
            agent_id: row.get("agent_id")?,
            command: row.get("command")?,
            every_seconds: row.get("every_seconds")?,
            deadline_at: row.get("deadline_at")?,
            wake_prompt: row.get("wake_prompt")?,
            status: ContinuationStatus::parse(&status).unwrap_or(ContinuationStatus::Waiting),
            summary: row.get("summary")?,
            next_check_at: row.get("next_check_at")?,
            created_at: row.get("created_at")?,
            updated_at: row.get("updated_at")?,
            ended_at: row.get("ended_at")?,
        })
    }

    /// Transfer an external wait from a live task run to the relay. One task
    /// has one visible obligation, which keeps both the lifecycle and UI clear.
    pub fn register_task_continuation(
        &self,
        continuation: &TaskContinuation,
    ) -> Result<Option<Task>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let valid: bool = tx.query_row(
            "SELECT EXISTS(
                 SELECT 1 FROM runs r JOIN tasks t ON t.id=r.task_id
                  WHERE r.id=?1 AND r.task_id=?2 AND r.agent_id=?3
                    AND r.status IN ('queued','dispatched','running','waiting')
                    AND t.status='running'
               ) AND NOT EXISTS(
                 SELECT 1 FROM task_continuations
                  WHERE task_id=?2 AND ended_at IS NULL
               )",
            params![
                continuation.run_id,
                continuation.task_id,
                continuation.agent_id
            ],
            |row| row.get(0),
        )?;
        if !valid {
            return Ok(None);
        }
        tx.execute(
            "INSERT INTO task_continuations
             (id, task_id, run_id, agent_id, command, every_seconds, deadline_at, wake_prompt,
              status, summary, next_check_at, created_at, updated_at, ended_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14)",
            params![
                continuation.id,
                continuation.task_id,
                continuation.run_id,
                continuation.agent_id,
                continuation.command,
                continuation.every_seconds,
                continuation.deadline_at,
                continuation.wake_prompt,
                continuation.status.as_str(),
                continuation.summary,
                continuation.next_check_at,
                continuation.created_at,
                continuation.updated_at,
                continuation.ended_at,
            ],
        )?;
        tx.execute(
            "UPDATE tasks SET active_continuation=?2, updated_at=MAX(?3, updated_at + 1)
             WHERE id=?1",
            params![
                continuation.task_id,
                to_json(&continuation.public_summary()),
                now_ms()
            ],
        )?;
        let task = tx.query_row(
            "SELECT * FROM tasks WHERE id=?1",
            params![continuation.task_id],
            Self::task_from_row,
        )?;
        tx.commit()?;
        Ok(Some(task))
    }

    /// Advance due times before commands start so a slow or crashed checker
    /// cannot overlap itself or run on every scheduler tick.
    pub fn claim_due_task_continuations(&self, now: Millis) -> Result<Vec<TaskContinuation>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut continuations = {
            let mut stmt = tx.prepare(
                "SELECT * FROM task_continuations
                 WHERE ended_at IS NULL AND status='waiting'
                   AND next_check_at<=?1 AND deadline_at>?1
                 ORDER BY next_check_at LIMIT 50",
            )?;
            let rows = stmt.query_map(params![now], Self::task_continuation_from_row)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        for continuation in &mut continuations {
            continuation.next_check_at = now + continuation.every_seconds * 1000;
            continuation.updated_at = now;
            tx.execute(
                "UPDATE task_continuations SET next_check_at=?2, updated_at=?3
                 WHERE id=?1 AND ended_at IS NULL AND status='waiting'",
                params![continuation.id, continuation.next_check_at, now],
            )?;
        }
        tx.commit()?;
        Ok(continuations)
    }

    /// Apply a checker result once. A manual run, task move, or earlier result
    /// ends the row first, so late process output becomes a harmless no-op.
    pub fn apply_task_continuation_result(
        &self,
        id: &str,
        status: ContinuationStatus,
        summary: &str,
    ) -> Result<Option<Task>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let Some(mut continuation) = tx
            .query_row(
                "SELECT * FROM task_continuations
                 WHERE id=?1 AND ended_at IS NULL AND status='waiting'",
                params![id],
                Self::task_continuation_from_row,
            )
            .optional()?
        else {
            return Ok(None);
        };
        let now = now_ms();
        continuation.status = status;
        continuation.summary = summary.to_string();
        continuation.updated_at = now;
        tx.execute(
            "UPDATE task_continuations SET status=?2, summary=?3, updated_at=?4
             WHERE id=?1 AND ended_at IS NULL AND status='waiting'",
            params![id, status.as_str(), summary, now],
        )?;
        tx.execute(
            "UPDATE tasks
             SET status=CASE
                   WHEN ?3 IN ('action_required','failed') THEN 'blocked'
                   WHEN question_blocked_run_id IS NULL THEN 'running'
                   ELSE status END,
                 active_continuation=?2,
                 updated_at=MAX(?4, updated_at + 1)
             WHERE id=?1 AND status NOT IN ('done','canceled')",
            params![
                continuation.task_id,
                to_json(&continuation.public_summary()),
                status.as_str(),
                now
            ],
        )?;
        let task = tx
            .query_row(
                "SELECT * FROM tasks WHERE id=?1",
                params![continuation.task_id],
                Self::task_from_row,
            )
            .optional()?;
        tx.commit()?;
        Ok(task)
    }

    pub fn expire_task_continuations(&self, now: Millis) -> Result<Vec<Task>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let continuations = {
            let mut stmt = tx.prepare(
                "SELECT * FROM task_continuations
                 WHERE ended_at IS NULL AND status IN ('waiting','ready') AND deadline_at<=?1",
            )?;
            let rows = stmt.query_map(params![now], Self::task_continuation_from_row)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let mut tasks = Vec::new();
        for mut continuation in continuations {
            let summary = format!("Deadline reached: {}", continuation.summary);
            continuation.status = ContinuationStatus::ActionRequired;
            continuation.summary = summary.clone();
            continuation.updated_at = now;
            if tx.execute(
                "UPDATE task_continuations SET status='action_required', summary=?2, updated_at=?3
                 WHERE id=?1 AND ended_at IS NULL AND status IN ('waiting','ready')",
                params![continuation.id, summary, now],
            )? == 0
            {
                continue;
            }
            tx.execute(
                "UPDATE tasks SET status='blocked', active_continuation=?2,
                                  updated_at=MAX(?3, updated_at + 1)
                 WHERE id=?1 AND status NOT IN ('done','canceled')",
                params![
                    continuation.task_id,
                    to_json(&continuation.public_summary()),
                    now
                ],
            )?;
            if let Some(task) = tx
                .query_row(
                    "SELECT * FROM tasks WHERE id=?1",
                    params![continuation.task_id],
                    Self::task_from_row,
                )
                .optional()?
            {
                tasks.push(task);
            }
        }
        tx.commit()?;
        Ok(tasks)
    }

    pub fn ready_task_continuations(&self) -> Result<Vec<TaskContinuation>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM task_continuations
             WHERE ended_at IS NULL AND status='ready' ORDER BY updated_at",
        )?;
        let rows = stmt.query_map([], Self::task_continuation_from_row)?;
        Ok(rows.filter_map(Result::ok).collect())
    }

    /// Repair old or interrupted writes at startup. Normal transitions enforce
    /// the same rules transactionally; this catches states from older relays.
    pub fn reconcile_task_lifecycle(&self) -> Result<usize> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let before = tx.total_changes();
        let now = now_ms();
        tx.execute(
            "UPDATE task_continuations SET ended_at=?1, updated_at=?1
             WHERE ended_at IS NULL AND task_id IN
               (SELECT id FROM tasks WHERE status IN ('done','canceled'))",
            params![now],
        )?;
        tx.execute(
            "UPDATE tasks SET active_continuation=NULL, updated_at=updated_at+1
             WHERE status IN ('done','canceled') AND active_continuation IS NOT NULL",
            [],
        )?;
        tx.execute(
            "UPDATE tasks
             SET current_run_id=(
                   SELECT id FROM runs WHERE task_id=tasks.id
                     AND status IN ('queued','dispatched','running','waiting')
                   ORDER BY id DESC LIMIT 1
                 ),
                 updated_at=updated_at+1
             WHERE current_run_id IS NULL OR current_run_id IN
               (SELECT id FROM runs WHERE status IN ('succeeded','failed','cancelled'))",
            [],
        )?;
        tx.execute(
            "UPDATE tasks SET status='planned', updated_at=updated_at+1
             WHERE status='running'
               AND NOT EXISTS(SELECT 1 FROM runs WHERE task_id=tasks.id
                                AND status IN ('queued','dispatched','running','waiting'))
               AND NOT EXISTS(SELECT 1 FROM task_continuations WHERE task_id=tasks.id
                                AND ended_at IS NULL AND status IN ('waiting','ready'))",
            [],
        )?;
        let continuations = {
            let mut stmt = tx.prepare(
                "SELECT * FROM task_continuations WHERE ended_at IS NULL ORDER BY created_at",
            )?;
            let rows = stmt.query_map([], Self::task_continuation_from_row)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        for continuation in continuations {
            let status = match continuation.status {
                ContinuationStatus::Waiting | ContinuationStatus::Ready => "running",
                ContinuationStatus::ActionRequired | ContinuationStatus::Failed => "blocked",
            };
            tx.execute(
                "UPDATE tasks SET status=CASE
                                    WHEN question_blocked_run_id IS NOT NULL THEN status
                                    ELSE ?2 END,
                                  active_continuation=?3,
                                  updated_at=MAX(?4, updated_at + 1)
                 WHERE id=?1 AND status NOT IN ('done','canceled')",
                params![
                    continuation.task_id,
                    status,
                    to_json(&continuation.public_summary()),
                    now
                ],
            )?;
        }
        let changed = (tx.total_changes() - before) as usize;
        tx.commit()?;
        Ok(changed)
    }

    // -- projects, hosts, worktrees ----------------------------------------

    fn project_from_row(row: &Row) -> rusqlite::Result<Project> {
        Ok(Project {
            id: row.get("id")?,
            name: row.get("name")?,
            description: row.get("description")?,
            repo_url: row.get("repo_url")?,
            default_branch: row.get("default_branch")?,
            paths: json_col_or(row, "paths"),
            created_at: row.get("created_at")?,
        })
    }

    pub fn upsert_project(&self, project: &Project) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO projects (id, name, description, repo_url, default_branch, paths, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7)
             ON CONFLICT(id) DO UPDATE SET name=?2, description=?3, repo_url=?4,
                                           default_branch=?5, paths=?6",
            params![
                project.id, project.name, project.description,
                project.repo_url, project.default_branch, to_json(&project.paths),
                project.created_at
            ],
        )?;
        Ok(())
    }

    pub fn projects(&self) -> Result<Vec<Project>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM projects ORDER BY name COLLATE NOCASE")?;
        let rows = stmt.query_map([], |r| Self::project_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn project(&self, id: &str) -> Result<Option<Project>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM projects WHERE id = ?1", params![id], |r| {
                Self::project_from_row(r)
            })
            .optional()?)
    }

    pub fn delete_project(&self, id: &str) -> Result<()> {
        self.conn()?
            .execute("DELETE FROM projects WHERE id = ?1", params![id])?;
        Ok(())
    }

    fn host_from_row(row: &Row) -> rusqlite::Result<Host> {
        let kind: String = row.get("kind")?;
        Ok(Host {
            id: row.get("id")?,
            name: row.get("name")?,
            kind: if kind == "relay" {
                HostKind::Relay
            } else {
                HostKind::Desktop
            },
            platform: row.get("platform")?,
            owner_id: row.get("owner_id")?,
            online: false,
            last_seen: row.get("last_seen")?,
            capabilities: json_col_or(row, "capabilities"),
            created_at: row.get("created_at")?,
        })
    }

    pub fn upsert_host(&self, host: &Host) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO hosts (id, name, kind, platform, owner_id, capabilities, last_seen, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8)
             ON CONFLICT(id) DO UPDATE SET name=?2, kind=?3, platform=?4, owner_id=COALESCE(?5, owner_id),
                                           capabilities=?6, last_seen=?7",
            params![
                host.id, host.name,
                match host.kind { HostKind::Relay => "relay", HostKind::Desktop => "desktop" },
                host.platform, host.owner_id, to_json(&host.capabilities), host.last_seen, host.created_at
            ],
        )?;
        Ok(())
    }

    pub fn hosts(&self) -> Result<Vec<Host>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM hosts ORDER BY kind, name COLLATE NOCASE")?;
        let rows = stmt.query_map([], |r| Self::host_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn host(&self, id: &str) -> Result<Option<Host>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM hosts WHERE id = ?1", params![id], |r| {
                Self::host_from_row(r)
            })
            .optional()?)
    }

    pub fn touch_host(&self, id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE hosts SET last_seen = ?2 WHERE id = ?1",
            params![id, now_ms()],
        )?;
        Ok(())
    }

    fn worktree_from_row(row: &Row) -> rusqlite::Result<Worktree> {
        Ok(Worktree {
            id: row.get("id")?,
            task_id: row.get("task_id")?,
            project_id: row.get("project_id")?,
            host_id: row.get("host_id")?,
            path: row.get("path")?,
            branch: row.get("branch")?,
            base_branch: row.get("base_branch")?,
            is_main_checkout: row.get::<_, i64>("is_main_checkout")? != 0,
            created_at: row.get("created_at")?,
        })
    }

    pub fn upsert_worktree(&self, worktree: &Worktree) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO worktrees (id, task_id, project_id, host_id, path, branch, base_branch, is_main_checkout, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)
             ON CONFLICT(id) DO UPDATE SET path=?5, branch=?6, base_branch=?7, is_main_checkout=?8",
            params![
                worktree.id, worktree.task_id, worktree.project_id, worktree.host_id,
                worktree.path, worktree.branch, worktree.base_branch,
                worktree.is_main_checkout as i64, worktree.created_at
            ],
        )?;
        Ok(())
    }

    pub fn worktree(&self, id: &str) -> Result<Option<Worktree>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM worktrees WHERE id = ?1", params![id], |r| {
                Self::worktree_from_row(r)
            })
            .optional()?)
    }

    pub fn task_worktrees(&self, task_id: &str) -> Result<Vec<Worktree>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM worktrees WHERE task_id = ?1")?;
        let rows = stmt.query_map(params![task_id], |r| Self::worktree_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    // -- runs ---------------------------------------------------------------

    fn run_from_row(row: &Row) -> rusqlite::Result<Run> {
        let status: String = row.get("status")?;
        Ok(Run {
            id: row.get("id")?,
            agent_id: row.get("agent_id")?,
            status: RunStatus::parse(&status).unwrap_or(RunStatus::Queued),
            trigger: json_col(row, "trigger").unwrap_or(RunTrigger::Manual { by: String::new() }),
            channel_id: row.get("channel_id")?,
            task_id: row.get("task_id")?,
            host_id: row.get("host_id")?,
            project_id: row.get("project_id")?,
            worktree_id: row.get("worktree_id")?,
            cwd: row.get("cwd")?,
            automation_id: row.get("automation_id")?,
            session_id: row.get("session_id")?,
            runtime: row.get("runtime")?,
            provider: row.get("provider")?,
            model: row.get("model")?,
            thinking: row.get("thinking")?,
            prompt: row.get("prompt")?,
            headline: row.get("headline")?,
            error: row.get("error")?,
            token_usage: json_col(row, "token_usage"),
            created_at: row.get("created_at")?,
            started_at: row.get("started_at")?,
            ended_at: row.get("ended_at")?,
        })
    }

    /// A task takes as many runs at once as people start on it. They share one
    /// worktree, so each of them is told who else is in there; the relay does
    /// not arbitrate, it just keeps everyone's state visible.
    pub fn insert_run(&self, run: &Run, depth: i32) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT INTO runs (id, agent_id, status, trigger, channel_id, task_id, host_id, project_id,
                               worktree_id, cwd, automation_id, session_id, runtime, provider, model,
                               thinking, prompt, headline, error, token_usage, depth, created_at,
                               started_at, ended_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24)",
            params![
                run.id, run.agent_id, run.status.as_str(), to_json(&run.trigger), run.channel_id,
                run.task_id, run.host_id, run.project_id, run.worktree_id, run.cwd, run.automation_id,
                run.session_id, run.runtime, run.provider, run.model, run.thinking, run.prompt,
                run.headline, run.error, run.token_usage.as_ref().map(to_json), depth, run.created_at,
                run.started_at, run.ended_at
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn insert_run_for_automation(
        &self,
        run: &Run,
        depth: i32,
        automation_run_id: &str,
        automation_run_attempt: i64,
    ) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        tx.execute(
            "INSERT INTO runs (id, agent_id, status, trigger, channel_id, task_id, host_id, project_id,
                               worktree_id, cwd, automation_id, session_id, runtime, provider, model,
                               thinking, prompt, headline, error, token_usage, depth, created_at,
                               started_at, ended_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22,?23,?24)",
            params![
                run.id, run.agent_id, run.status.as_str(), to_json(&run.trigger), run.channel_id,
                run.task_id, run.host_id, run.project_id, run.worktree_id, run.cwd, run.automation_id,
                run.session_id, run.runtime, run.provider, run.model, run.thinking, run.prompt,
                run.headline, run.error, run.token_usage.as_ref().map(to_json), depth, run.created_at,
                run.started_at, run.ended_at
            ],
        )?;
        if tx.execute(
            "UPDATE automation_runs
                SET run_id = ?2, status = 'dispatched'
              WHERE id = ?1 AND attempt_count = ?3 AND accepted_at IS NULL
                AND run_id IS NULL AND lease_until IS NOT NULL",
            params![automation_run_id, run.id, automation_run_attempt],
        )? == 0
        {
            bail!("automation occurrence is no longer claimed");
        }
        tx.commit()?;
        Ok(())
    }

    /// Persist host acceptance and the linked occurrence together. Sending a
    /// StartRun frame is not acceptance: the host must acknowledge it.
    pub fn accept_run_dispatch(
        &self,
        run: &Run,
        at: Millis,
    ) -> Result<(bool, Option<AutomationRun>)> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let transitioned = tx.execute(
            "UPDATE runs SET status=?2, host_id=?3, worktree_id=?4, cwd=?5, session_id=?6, runtime=?7,
                             provider=?8, model=?9, thinking=?10, headline=?11, error=?12,
                             token_usage=?13, started_at=?14, ended_at=?15, project_id=?16
              WHERE id=?1 AND status IN ('queued','dispatched','running','waiting')",
            params![
                run.id, run.status.as_str(), run.host_id, run.worktree_id, run.cwd, run.session_id,
                run.runtime, run.provider, run.model, run.thinking, run.headline, run.error,
                run.token_usage.as_ref().map(to_json), run.started_at, run.ended_at, run.project_id
            ],
        )? > 0;
        if !transitioned {
            tx.rollback()?;
            return Ok((false, None));
        }
        tx.execute(
            "UPDATE automation_runs
                SET status = 'running', accepted_at = COALESCE(accepted_at, ?2),
                    error = NULL, retry_at = NULL, lease_until = NULL
              WHERE run_id = ?1 AND status IN ('queued','dispatched','running')",
            params![run.id, at],
        )?;
        let occurrence = tx
            .query_row(
                "SELECT * FROM automation_runs WHERE run_id = ?1",
                params![run.id],
                Self::automation_run_from_row,
            )
            .optional()?;
        if let Some(occurrence) = &occurrence {
            tx.execute(
                "UPDATE automations
                    SET last_run_at = ?2, execution_failure_notification_key = NULL
                  WHERE id = ?1",
                params![occurrence.automation_id, at],
            )?;
        }
        tx.commit()?;
        Ok((true, occurrence))
    }

    pub fn update_run(&self, run: &Run) -> Result<()> {
        self.conn()?.execute(
            "UPDATE runs SET status=?2, host_id=?3, worktree_id=?4, cwd=?5, session_id=?6, runtime=?7,
                             provider=?8, model=?9, thinking=?10, headline=?11, error=?12,
                             token_usage=?13, started_at=?14, ended_at=?15, project_id=?16 WHERE id=?1",
            params![
                run.id, run.status.as_str(), run.host_id, run.worktree_id, run.cwd, run.session_id,
                run.runtime, run.provider, run.model, run.thinking, run.headline, run.error,
                run.token_usage.as_ref().map(to_json), run.started_at, run.ended_at, run.project_id
            ],
        )?;
        Ok(())
    }

    pub fn run(&self, id: &str) -> Result<Option<Run>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM runs WHERE id = ?1", params![id], |r| {
                Self::run_from_row(r)
            })
            .optional()?)
    }

    pub fn run_depth(&self, id: &str) -> Result<i32> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT depth FROM runs WHERE id = ?1", params![id], |r| {
                r.get(0)
            })
            .optional()?
            .unwrap_or(0))
    }

    pub fn task_runs(&self, task_id: &str) -> Result<Vec<Run>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM runs WHERE task_id = ?1 ORDER BY id DESC")?;
        let rows = stmt.query_map(params![task_id], |r| Self::run_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Everyone still working on this task, newest first.
    pub fn active_task_runs(&self, task_id: &str) -> Result<Vec<Run>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM runs WHERE task_id = ?1
             AND status IN ('queued','dispatched','running','waiting') ORDER BY id DESC",
        )?;
        let rows = stmt.query_map(params![task_id], |r| Self::run_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn active_runs(&self) -> Result<Vec<Run>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM runs WHERE status IN ('queued','dispatched','running','waiting') ORDER BY id DESC",
        )?;
        let rows = stmt.query_map([], |r| Self::run_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn agent_active_run(&self, agent_id: &str, channel_id: &str) -> Result<Option<Run>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM runs WHERE agent_id = ?1 AND channel_id = ?2
                 AND status IN ('queued','dispatched','running','waiting') ORDER BY id DESC LIMIT 1",
                params![agent_id, channel_id],
                |r| Self::run_from_row(r),
            )
            .optional()?)
    }

    /// A run already working in this project, on a different task. Only
    /// interesting for projects with no repository, where every task shares
    /// the one folder.
    pub fn project_active_run(
        &self,
        project_id: &str,
        task_id: Option<&str>,
    ) -> Result<Option<Run>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM runs WHERE project_id = ?1
                 AND (?2 IS NULL OR task_id IS NULL OR task_id != ?2)
                 AND status IN ('queued','dispatched','running','waiting') ORDER BY id DESC LIMIT 1",
                params![project_id, task_id],
                |r| Self::run_from_row(r),
            )
            .optional()?)
    }

    /// The newest finished run for this agent on this task, so a retry can
    /// resume the same ACP session and the same worktree.
    pub fn last_run_for(&self, agent_id: &str, task_id: &str) -> Result<Option<Run>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM runs WHERE agent_id = ?1 AND task_id = ?2 ORDER BY id DESC LIMIT 1",
                params![agent_id, task_id],
                |r| Self::run_from_row(r),
            )
            .optional()?)
    }

    /// Reserve one explicit cross-session message and enforce its loop budget
    /// in the same write transaction, so concurrent sends cannot race it.
    pub fn reserve_direct_control(&self, event: &mut RunEvent, target_run_id: &str) -> Result<()> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let total: i64 = tx.query_row(
            "SELECT COUNT(*) FROM run_events WHERE run_id = ?1
             AND json_extract(data, '$.direction') = 'outbound'",
            params![event.run_id],
            |row| row.get(0),
        )?;
        let pair: i64 = tx.query_row(
            "SELECT COUNT(*) FROM run_events WHERE run_id = ?1
             AND json_extract(data, '$.direction') = 'outbound'
             AND json_extract(data, '$.target_run_id') = ?2",
            params![event.run_id, target_run_id],
            |row| row.get(0),
        )?;
        if total >= 16 || pair >= 4 {
            return Err(anyhow!(
                "this run has reached its cross-session message limit"
            ));
        }
        event.seq = tx.query_row(
            "SELECT COALESCE(MAX(seq), 0) + 1 FROM run_events WHERE run_id = ?1",
            params![event.run_id],
            |row| row.get(0),
        )?;
        tx.execute(
            "INSERT INTO run_events (id, run_id, seq, kind, text, data, created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)",
            params![
                event.id, event.run_id, event.seq,
                serde_json::to_string(&event.kind).unwrap_or_default().trim_matches('"'),
                event.text, event.data.as_ref().map(to_json), event.created_at
            ],
        )?;
        tx.commit()?;
        Ok(())
    }

    pub fn append_run_event(&self, event: &RunEvent) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO run_events (id, run_id, seq, kind, text, data, created_at) VALUES (?1,?2,?3,?4,?5,?6,?7)",
            params![
                event.id, event.run_id, event.seq,
                serde_json::to_string(&event.kind).unwrap_or_default().trim_matches('"'),
                event.text, event.data.as_ref().map(to_json), event.created_at
            ],
        )?;
        Ok(())
    }

    pub fn next_run_event_seq(&self, run_id: &str) -> Result<i64> {
        let conn = self.conn()?;
        let seq: i64 = conn.query_row(
            "SELECT COALESCE(MAX(seq), 0) + 1 FROM run_events WHERE run_id = ?1",
            params![run_id],
            |r| r.get(0),
        )?;
        Ok(seq)
    }

    pub fn run_events(&self, run_id: &str, after_seq: i64) -> Result<Vec<RunEvent>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM run_events WHERE run_id = ?1 AND seq > ?2 ORDER BY seq LIMIT 2000",
        )?;
        let rows = stmt.query_map(params![run_id, after_seq], |r| {
            let kind: String = r.get("kind")?;
            Ok(RunEvent {
                id: r.get("id")?,
                run_id: r.get("run_id")?,
                seq: r.get("seq")?,
                kind: serde_json::from_value(Json::String(kind)).unwrap_or(RunEventKind::Lifecycle),
                text: r.get("text")?,
                data: json_col(r, "data"),
                created_at: r.get("created_at")?,
            })
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    // -- questions ----------------------------------------------------------

    fn question_from_row(row: &Row) -> rusqlite::Result<Question> {
        let status: String = row.get("status")?;
        Ok(Question {
            id: row.get("id")?,
            run_id: row.get("run_id")?,
            agent_id: row.get("agent_id")?,
            channel_id: row.get("channel_id")?,
            task_id: row.get("task_id")?,
            message_id: row.get("message_id")?,
            headline: row.get("headline")?,
            items: json_col_or(row, "items"),
            status: match status.as_str() {
                "answered" => QuestionStatus::Answered,
                "cancelled" => QuestionStatus::Cancelled,
                _ => QuestionStatus::Open,
            },
            answers: json_col(row, "answers"),
            answered_by: row.get("answered_by")?,
            created_at: row.get("created_at")?,
            answered_at: row.get("answered_at")?,
        })
    }

    pub fn insert_question(&self, question: &Question) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO questions (id, run_id, agent_id, channel_id, task_id, message_id, headline, items, status, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'open',?9)",
            params![
                question.id, question.run_id, question.agent_id, question.channel_id,
                question.task_id, question.message_id, question.headline,
                to_json(&question.items), question.created_at
            ],
        )?;
        Ok(())
    }

    /// Make the question, waiting run, blocked task and Inbox rows visible as
    /// one state. A terminal run wins the race and commits none of them.
    ///
    /// One run asks one thing at a time: a second open question is nobody's to
    /// answer, and it holds the task in Blocked even after somebody answers
    /// the card they can see. `replace` cancels the earlier question instead of
    /// refusing, which is how a run whose `ask` died gets to ask again.
    pub fn commit_question_waiting(
        &self,
        question: &Question,
        run: &Run,
        inbox: &[InboxItem],
        replace: bool,
    ) -> Result<QuestionCommit> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "UPDATE runs SET status='waiting', headline=?2
             WHERE id=?1 AND status NOT IN ('succeeded','failed','cancelled')",
            params![run.id, run.headline],
        )?;
        if changed == 0 {
            return Ok(QuestionCommit::RunEnded);
        }
        let superseded = {
            let mut stmt = tx.prepare(
                "UPDATE questions SET status='cancelled'
                 WHERE run_id=?1 AND status='open' AND ?2 RETURNING *",
            )?;
            let rows = stmt.query_map(params![run.id, replace], Self::question_from_row)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        if !replace {
            if let Some(open) = tx
                .query_row(
                    "SELECT * FROM questions WHERE run_id=?1 AND status='open' ORDER BY created_at LIMIT 1",
                    params![run.id],
                    Self::question_from_row,
                )
                .optional()?
            {
                return Ok(QuestionCommit::AlreadyAsking(open));
            }
        }
        tx.execute(
            "INSERT INTO questions (id, run_id, agent_id, channel_id, task_id, message_id, headline, items, status, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,'open',?9)",
            params![
                question.id, question.run_id, question.agent_id, question.channel_id,
                question.task_id, question.message_id, question.headline,
                to_json(&question.items), question.created_at
            ],
        )?;
        for item in inbox {
            tx.execute(
                "INSERT INTO inbox (id, member_id, kind, title, preview, actor_id, channel_id, message_id,
                                    task_id, run_id, automation_id, created_at)
                 VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
                params![
                    item.id, item.member_id,
                    serde_json::to_string(&item.kind).unwrap_or_default().trim_matches('"'),
                    item.title, item.preview, item.actor_id, item.channel_id, item.message_id,
                    item.task_id, item.run_id, item.automation_id, item.created_at
                ],
            )?;
        }
        let blocked = if let Some(task_id) = &question.task_id {
            let changed = tx.execute(
                "UPDATE tasks
                 SET status='blocked', question_blocked_run_id=?2,
                     updated_at=MAX(?3, updated_at + 1)
                 WHERE id=?1 AND current_run_id=?2 AND status='running'",
                params![task_id, run.id, now_ms()],
            )?;
            if changed == 0 {
                None
            } else {
                tx.query_row(
                    "SELECT * FROM tasks WHERE id=?1",
                    params![task_id],
                    Self::task_from_row,
                )
                .optional()?
            }
        } else {
            None
        };
        tx.commit()?;
        Ok(QuestionCommit::Committed {
            blocked,
            superseded,
        })
    }

    pub fn answer_question(
        &self,
        id: &str,
        answers: &[QuestionAnswer],
        by: &str,
    ) -> Result<(Question, Option<Task>)> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "UPDATE questions SET status='answered', answers=?2, answered_by=?3, answered_at=?4
             WHERE id=?1 AND status='open'",
            params![id, to_json(&answers), by, now_ms()],
        )?;
        if changed == 0 {
            return Err(anyhow!("question is no longer open"));
        }
        let question = tx
            .query_row(
                "SELECT * FROM questions WHERE id=?1",
                params![id],
                Self::question_from_row,
            )
            .optional()?
            .ok_or_else(|| anyhow!("question not found"))?;
        let resumed = tx
            .query_row(
                "UPDATE tasks
                 SET status=CASE WHEN EXISTS(
                       SELECT 1 FROM task_continuations
                        WHERE task_id=tasks.id AND ended_at IS NULL
                          AND status IN ('action_required','failed')
                     ) THEN 'blocked' ELSE 'running' END,
                     question_blocked_run_id=NULL,
                     updated_at=MAX(?2, updated_at + 1)
                 WHERE current_run_id=?1
                   AND status='blocked'
                   AND question_blocked_run_id=?1
                   AND NOT EXISTS (
                     SELECT 1 FROM questions WHERE run_id=?1 AND status='open'
                   )
                 RETURNING *",
                params![question.run_id, now_ms()],
                Self::task_from_row,
            )
            .optional()?;
        tx.commit()?;
        Ok((question, resumed))
    }

    pub fn cancel_questions_for_run(&self, run_id: &str) -> Result<Vec<Question>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let mut questions = {
            let mut stmt = tx
                .prepare("SELECT * FROM questions WHERE run_id=?1 AND status='open' ORDER BY id")?;
            let rows = stmt.query_map(params![run_id], Self::question_from_row)?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        tx.execute(
            "UPDATE questions SET status='cancelled' WHERE run_id=?1 AND status='open'",
            params![run_id],
        )?;
        // Terminal run handling immediately computes the task's durable final
        // state. Restore its pre-question status in storage without emitting a
        // transient Running event between cancellation and that final update.
        tx.execute(
            "UPDATE tasks
             SET status=CASE WHEN EXISTS(
                   SELECT 1 FROM task_continuations
                    WHERE task_id=tasks.id AND ended_at IS NULL
                      AND status IN ('action_required','failed')
                 ) THEN 'blocked' ELSE 'running' END,
                 question_blocked_run_id=NULL,
                 updated_at=MAX(?2, updated_at + 1)
             WHERE current_run_id=?1
               AND status='blocked'
               AND question_blocked_run_id=?1",
            params![run_id, now_ms()],
        )?;
        tx.commit()?;
        for question in &mut questions {
            question.status = QuestionStatus::Cancelled;
        }
        Ok(questions)
    }

    pub fn question(&self, id: &str) -> Result<Option<Question>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM questions WHERE id = ?1", params![id], |r| {
                Self::question_from_row(r)
            })
            .optional()?)
    }

    pub fn open_questions(&self) -> Result<Vec<Question>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM questions WHERE status='open' ORDER BY id")?;
        let rows = stmt.query_map([], |r| Self::question_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn run_questions(&self, run_id: &str) -> Result<Vec<Question>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM questions WHERE run_id = ?1 ORDER BY id")?;
        let rows = stmt.query_map(params![run_id], |r| Self::question_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn task_questions(&self, task_id: &str) -> Result<Vec<Question>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM questions WHERE task_id = ?1 ORDER BY id")?;
        let rows = stmt.query_map(params![task_id], |r| Self::question_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    // -- inbox --------------------------------------------------------------

    fn inbox_from_row(row: &Row) -> rusqlite::Result<InboxItem> {
        let kind: String = row.get("kind")?;
        Ok(InboxItem {
            id: row.get("id")?,
            member_id: row.get("member_id")?,
            kind: serde_json::from_value(Json::String(kind)).unwrap_or(InboxKind::Mention),
            title: row.get("title")?,
            preview: row.get("preview")?,
            actor_id: row.get("actor_id")?,
            channel_id: row.get("channel_id")?,
            message_id: row.get("message_id")?,
            task_id: row.get("task_id")?,
            run_id: row.get("run_id")?,
            automation_id: row.get("automation_id")?,
            created_at: row.get("created_at")?,
            read_at: row.get("read_at")?,
        })
    }

    pub fn insert_inbox(&self, item: &InboxItem) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO inbox (id, member_id, kind, title, preview, actor_id, channel_id, message_id,
                                task_id, run_id, automation_id, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12)",
            params![
                item.id, item.member_id,
                serde_json::to_string(&item.kind).unwrap_or_default().trim_matches('"'),
                item.title, item.preview, item.actor_id, item.channel_id, item.message_id,
                item.task_id, item.run_id, item.automation_id, item.created_at
            ],
        )?;
        Ok(())
    }

    pub fn inbox(&self, member_id: &str, include_read: bool) -> Result<Vec<InboxItem>> {
        let conn = self.conn()?;
        let sql = if include_read {
            "SELECT * FROM inbox WHERE member_id = ?1 ORDER BY id DESC LIMIT 200"
        } else {
            "SELECT * FROM inbox WHERE member_id = ?1 AND read_at IS NULL ORDER BY id DESC LIMIT 200"
        };
        let mut stmt = conn.prepare(sql)?;
        let rows = stmt.query_map(params![member_id], |r| Self::inbox_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    /// Whether this task has already put something of this kind in an Inbox.
    /// Read or not: telling someone twice that the same task is due is worse
    /// than telling them once.
    pub fn inbox_has(&self, task_id: &str, kind: InboxKind) -> Result<bool> {
        let kind = serde_json::to_string(&kind).unwrap_or_default();
        let count: i64 = self.conn()?.query_row(
            "SELECT COUNT(*) FROM inbox WHERE task_id = ?1 AND kind = ?2",
            params![task_id, kind.trim_matches('"')],
            |r| r.get(0),
        )?;
        Ok(count > 0)
    }

    /// Forget that a task ever announced this, so moving its date can announce
    /// it again.
    pub fn clear_inbox(&self, task_id: &str, kind: InboxKind) -> Result<()> {
        let kind = serde_json::to_string(&kind).unwrap_or_default();
        self.conn()?.execute(
            "DELETE FROM inbox WHERE task_id = ?1 AND kind = ?2",
            params![task_id, kind.trim_matches('"')],
        )?;
        Ok(())
    }

    pub fn inbox_item(&self, id: &str) -> Result<Option<InboxItem>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM inbox WHERE id = ?1", params![id], |r| {
                Self::inbox_from_row(r)
            })
            .optional()?)
    }

    pub fn mark_inbox_read(&self, id: &str, member_id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE inbox SET read_at = ?3
             WHERE id = ?1 AND member_id = ?2 AND read_at IS NULL AND kind != 'question'",
            params![id, member_id, now_ms()],
        )?;
        Ok(())
    }

    pub fn mark_all_inbox_read(&self, member_id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE inbox SET read_at = ?2
             WHERE member_id = ?1 AND read_at IS NULL AND kind != 'question'",
            params![member_id, now_ms()],
        )?;
        Ok(())
    }

    /// Resolve ordinary task notices, every question cancelled with a run, or
    /// one answered question. The three scopes deliberately do not overlap.
    pub fn resolve_inbox_for(
        &self,
        task_id: Option<&str>,
        question_run_id: Option<&str>,
        question_message_id: Option<&str>,
    ) -> Result<Vec<InboxItem>> {
        let conn = self.conn()?;
        let mut items = {
            let mut stmt = conn.prepare(
                "SELECT * FROM inbox WHERE read_at IS NULL AND
                 ((?1 IS NOT NULL AND task_id = ?1 AND kind != 'question') OR
                  (?2 IS NOT NULL AND run_id = ?2 AND kind = 'question') OR
                  (?3 IS NOT NULL AND message_id = ?3 AND kind = 'question'))",
            )?;
            let rows = stmt.query_map(
                params![task_id, question_run_id, question_message_id],
                Self::inbox_from_row,
            )?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let at = now_ms();
        conn.execute(
            "UPDATE inbox SET read_at = ?4 WHERE read_at IS NULL AND
             ((?1 IS NOT NULL AND task_id = ?1 AND kind != 'question') OR
              (?2 IS NOT NULL AND run_id = ?2 AND kind = 'question') OR
              (?3 IS NOT NULL AND message_id = ?3 AND kind = 'question'))",
            params![task_id, question_run_id, question_message_id, at],
        )?;
        for item in &mut items {
            item.read_at = Some(at);
        }
        Ok(items)
    }

    // -- automations --------------------------------------------------------

    fn automation_from_row(row: &Row) -> rusqlite::Result<Automation> {
        let location: String = row.get("location")?;
        let action: String = row.get("action")?;
        Ok(Automation {
            id: row.get("id")?,
            name: row.get("name")?,
            description: row.get("description")?,
            enabled: row.get::<_, i64>("enabled")? != 0,
            trigger: json_col(row, "trigger").unwrap_or(AutomationTrigger::Manual),
            agent_id: row.get("agent_id")?,
            action: serde_json::from_value(Json::String(action))
                .unwrap_or(AutomationAction::PostInChat),
            instructions: row.get("instructions")?,
            context_channel_id: row.get("context_channel_id")?,
            report_channel_id: row.get("report_channel_id")?,
            project_id: row.get("project_id")?,
            location: serde_json::from_value(Json::String(location))
                .unwrap_or(ExecutionLocation::Auto),
            host_id: row.get("host_id")?,
            created_by: row.get("created_by")?,
            created_at: row.get("created_at")?,
            last_run_at: row.get("last_run_at")?,
            next_run_at: row.get("next_run_at")?,
            last_success_at: row.get("last_success_at")?,
            last_error_at: row.get("last_error_at")?,
            last_error: row.get("last_error")?,
            last_validated_at: row.get("last_validated_at")?,
            failure_count: row.get("failure_count")?,
            overdue_since: row.get("overdue_since").unwrap_or(None),
            blocked_reason: row.get("blocked_reason").unwrap_or(None),
            retry_at: row.get("retry_at").unwrap_or(None),
        })
    }

    pub fn upsert_automation(&self, automation: &Automation) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO automations (id, name, description, enabled, trigger, agent_id, action, instructions,
                                      context_channel_id, report_channel_id, project_id, location, host_id,
                                      created_by, created_at, last_run_at, next_run_at, last_success_at,
                                      last_error_at, last_error, last_validated_at, failure_count)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21,?22)
             ON CONFLICT(id) DO UPDATE SET name=?2, description=?3, enabled=?4, trigger=?5, agent_id=?6,
                                           action=?7, instructions=?8, context_channel_id=?9,
                                           report_channel_id=?10, project_id=?11, location=?12, host_id=?13,
                                           last_run_at=?16, next_run_at=?17, last_success_at=?18,
                                           last_error_at=?19, last_error=?20, last_validated_at=?21,
                                           failure_count=?22",
            params![
                automation.id, automation.name, automation.description, automation.enabled as i64,
                to_json(&automation.trigger), automation.agent_id,
                serde_json::to_string(&automation.action).unwrap_or_default().trim_matches('"'),
                automation.instructions, automation.context_channel_id, automation.report_channel_id,
                automation.project_id,
                serde_json::to_string(&automation.location).unwrap_or_default().trim_matches('"'),
                automation.host_id, automation.created_by, automation.created_at,
                automation.last_run_at, automation.next_run_at, automation.last_success_at,
                automation.last_error_at, automation.last_error, automation.last_validated_at,
                automation.failure_count
            ],
        )?;
        Ok(())
    }

    pub fn update_automation_config(
        &self,
        automation: &Automation,
        previous_trigger: &AutomationTrigger,
        previous_enabled: bool,
        reset_watch_health: bool,
    ) -> Result<Option<Automation>> {
        let changed = self.conn()?.execute(
            "UPDATE automations
                SET name = ?2, description = ?3, enabled = ?4, trigger = ?5,
                    agent_id = ?6, action = ?7, instructions = ?8,
                    context_channel_id = ?9, report_channel_id = ?10,
                    project_id = ?11, location = ?12, host_id = ?13,
                    next_run_at = ?14,
                    execution_failure_notification_key = NULL,
                    last_success_at = CASE WHEN ?15 THEN NULL ELSE last_success_at END,
                    last_error_at = CASE WHEN ?15 THEN NULL ELSE last_error_at END,
                    last_error = CASE WHEN ?15 THEN NULL ELSE last_error END,
                    last_validated_at = CASE WHEN ?15 THEN NULL ELSE last_validated_at END,
                    failure_notification_key = CASE WHEN ?15 THEN NULL ELSE failure_notification_key END,
                    failure_count = CASE WHEN ?15 THEN 0 ELSE failure_count END
              WHERE id = ?1 AND trigger = ?16 AND enabled = ?17",
            params![
                automation.id,
                automation.name,
                automation.description,
                automation.enabled as i64,
                to_json(&automation.trigger),
                automation.agent_id,
                serde_json::to_string(&automation.action)
                    .unwrap_or_default()
                    .trim_matches('"'),
                automation.instructions,
                automation.context_channel_id,
                automation.report_channel_id,
                automation.project_id,
                serde_json::to_string(&automation.location)
                    .unwrap_or_default()
                    .trim_matches('"'),
                automation.host_id,
                automation.next_run_at,
                reset_watch_health as i64,
                to_json(previous_trigger),
                previous_enabled as i64,
            ],
        )?;
        if changed == 0 {
            return Ok(None);
        }
        self.automation(&automation.id)
    }

    pub fn record_automation_execution_failure(
        &self,
        id: &str,
        diagnostic: &str,
    ) -> Result<Option<(Automation, bool)>> {
        let key: String = diagnostic.chars().take(500).collect();
        let mut conn = self.conn()?;
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let previous = transaction
            .query_row(
                "SELECT execution_failure_notification_key FROM automations WHERE id = ?1",
                params![id],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?;
        let Some(previous) = previous else {
            return Ok(None);
        };
        let notify = previous.as_deref() != Some(key.as_str());
        if notify {
            transaction.execute(
                "UPDATE automations SET execution_failure_notification_key = ?2 WHERE id = ?1",
                params![id, key],
            )?;
        }
        let automation = transaction.query_row(
            "SELECT * FROM automations WHERE id = ?1",
            params![id],
            Self::automation_from_row,
        )?;
        transaction.commit()?;
        Ok(Some((automation, notify)))
    }

    pub fn clear_automation_execution_failure(&self, id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE automations SET execution_failure_notification_key = NULL WHERE id = ?1",
            params![id],
        )?;
        Ok(())
    }

    pub fn retry_automation_execution_notification(
        &self,
        id: &str,
        diagnostic: &str,
    ) -> Result<()> {
        let key: String = diagnostic.chars().take(500).collect();
        self.conn()?.execute(
            "UPDATE automations SET execution_failure_notification_key = NULL
              WHERE id = ?1 AND execution_failure_notification_key = ?2",
            params![id, key],
        )?;
        Ok(())
    }

    pub fn retry_watch_failure_notification(&self, id: &str, diagnostic: &str) -> Result<()> {
        let key: String = diagnostic.chars().take(500).collect();
        self.conn()?.execute(
            "UPDATE automations SET failure_notification_key = NULL
              WHERE id = ?1 AND failure_notification_key = ?2",
            params![id, key],
        )?;
        Ok(())
    }

    pub fn record_watch_success(
        &self,
        id: &str,
        command: &str,
        at: Millis,
        validated: bool,
    ) -> Result<Option<Automation>> {
        let changed = self.conn()?.execute(
            "UPDATE automations
                SET last_success_at = ?3,
                    last_validated_at = CASE WHEN ?4 THEN ?3 ELSE last_validated_at END,
                    failure_notification_key = NULL,
                    failure_count = 0
              WHERE id = ?1 AND json_extract(trigger, '$.type') = 'watch'
                            AND json_extract(trigger, '$.command') = ?2",
            params![id, command, at, validated as i64],
        )?;
        if changed == 0 {
            return Ok(None);
        }
        self.automation(id)
    }

    pub fn record_watch_failure(
        &self,
        id: &str,
        command: &str,
        at: Millis,
        error: &str,
    ) -> Result<Option<(Automation, bool)>> {
        let error: String = error.chars().take(500).collect();
        let mut conn = self.conn()?;
        let transaction = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let previous = transaction
            .query_row(
                "SELECT failure_notification_key FROM automations
                  WHERE id = ?1 AND json_extract(trigger, '$.type') = 'watch'
                                AND json_extract(trigger, '$.command') = ?2",
                params![id, command],
                |row| row.get::<_, Option<String>>(0),
            )
            .optional()?;
        let Some(previous) = previous else {
            return Ok(None);
        };
        let notify = previous.as_deref() != Some(error.as_str());
        transaction.execute(
            "UPDATE automations
                SET last_error_at = ?3,
                    last_error = ?4,
                    failure_notification_key = CASE WHEN ?5 THEN ?4 ELSE failure_notification_key END,
                    failure_count = failure_count + 1
              WHERE id = ?1 AND json_extract(trigger, '$.type') = 'watch'
                            AND json_extract(trigger, '$.command') = ?2",
            params![id, command, at, error, notify as i64],
        )?;
        let automation = transaction.query_row(
            "SELECT * FROM automations WHERE id = ?1",
            params![id],
            Self::automation_from_row,
        )?;
        transaction.commit()?;
        Ok(Some((automation, notify)))
    }

    pub fn automations(&self) -> Result<Vec<Automation>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT automations.*,
                    (SELECT MIN(COALESCE(due_at, created_at)) FROM automation_runs
                      WHERE automation_id = automations.id AND accepted_at IS NULL
                        AND status IN ('queued','dispatched')
                        AND (lease_until IS NULL OR lease_until <= CAST(strftime('%s','now') AS INTEGER) * 1000)) AS overdue_since,
                    (SELECT error FROM automation_runs
                      WHERE automation_id = automations.id AND accepted_at IS NULL
                        AND status IN ('queued','dispatched') AND error IS NOT NULL
                      ORDER BY COALESCE(due_at, created_at), id LIMIT 1) AS blocked_reason,
                    (SELECT retry_at FROM automation_runs
                      WHERE automation_id = automations.id AND accepted_at IS NULL
                        AND status IN ('queued','dispatched')
                      ORDER BY COALESCE(due_at, created_at), id LIMIT 1) AS retry_at
               FROM automations ORDER BY name COLLATE NOCASE",
        )?;
        let rows = stmt.query_map([], Self::automation_from_row)?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn automation(&self, id: &str) -> Result<Option<Automation>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT automations.*,
                        (SELECT MIN(COALESCE(due_at, created_at)) FROM automation_runs
                          WHERE automation_id = automations.id AND accepted_at IS NULL
                            AND status IN ('queued','dispatched')
                            AND (lease_until IS NULL OR lease_until <= CAST(strftime('%s','now') AS INTEGER) * 1000)) AS overdue_since,
                        (SELECT error FROM automation_runs
                          WHERE automation_id = automations.id AND accepted_at IS NULL
                            AND status IN ('queued','dispatched') AND error IS NOT NULL
                          ORDER BY COALESCE(due_at, created_at), id LIMIT 1) AS blocked_reason,
                        (SELECT retry_at FROM automation_runs
                          WHERE automation_id = automations.id AND accepted_at IS NULL
                            AND status IN ('queued','dispatched')
                          ORDER BY COALESCE(due_at, created_at), id LIMIT 1) AS retry_at
                   FROM automations WHERE automations.id = ?1",
                params![id],
                Self::automation_from_row,
            )
            .optional()?)
    }

    pub fn automation_by_webhook(&self, token: &str) -> Result<Option<Automation>> {
        Ok(self
            .automations()?
            .into_iter()
            .find(|a| matches!(&a.trigger, AutomationTrigger::Webhook { token: t } if t == token)))
    }

    pub fn delete_automation(&self, id: &str) -> Result<()> {
        self.conn()?
            .execute("DELETE FROM automations WHERE id = ?1", params![id])?;
        Ok(())
    }

    fn automation_run_from_row(row: &Row) -> rusqlite::Result<AutomationRun> {
        let status: String = row.get("status")?;
        let kind: String = row.get("kind")?;
        Ok(AutomationRun {
            id: row.get("id")?,
            automation_id: row.get("automation_id")?,
            run_id: row.get("run_id")?,
            trigger_summary: row.get("trigger_summary")?,
            trigger_payload: json_col(row, "trigger_payload"),
            selection: json_col(row, "selection"),
            context_preview: row.get("context_preview")?,
            status: RunStatus::parse(&status).unwrap_or(RunStatus::Queued),
            error: row.get("error")?,
            task_id: row.get("task_id")?,
            once_key: row.get("once_key")?,
            kind: if kind == "watch_poll" {
                AutomationRunKind::WatchPoll
            } else {
                AutomationRunKind::Action
            },
            due_at: row.get("due_at")?,
            attempt_count: row.get("attempt_count")?,
            retry_at: row.get("retry_at")?,
            lease_until: row.get("lease_until")?,
            accepted_at: row.get("accepted_at")?,
            created_at: row.get("created_at")?,
            ended_at: row.get("ended_at")?,
        })
    }

    pub fn upsert_automation_run(&self, run: &AutomationRun) -> Result<bool> {
        let changed = self.conn()?.execute(
            "INSERT INTO automation_runs (id, automation_id, run_id, trigger_summary, trigger_payload,
                                          selection, context_preview, status, error, task_id, once_key,
                                          kind, due_at, attempt_count, retry_at, lease_until, accepted_at,
                                          created_at, ended_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)
             ON CONFLICT(id) DO UPDATE SET run_id=?3, selection=?6, context_preview=?7, status=?8,
                                           error=?9, task_id=?10, retry_at=?15,
                                           lease_until=?16, ended_at=?19
             WHERE automation_runs.attempt_count=?14 AND automation_runs.accepted_at IS ?17",
            params![
                run.id, run.automation_id, run.run_id, run.trigger_summary,
                run.trigger_payload.as_ref().map(to_json), run.selection.as_ref().map(to_json),
                run.context_preview, run.status.as_str(), run.error, run.task_id, run.once_key,
                match run.kind { AutomationRunKind::Action => "action", AutomationRunKind::WatchPoll => "watch_poll" },
                run.due_at, run.attempt_count, run.retry_at, run.lease_until, run.accepted_at,
                run.created_at, run.ended_at
            ],
        )?;
        Ok(changed > 0)
    }

    /// Reserve a keyed delivery before dispatch. `Some` means another caller
    /// already reserved it and owns the work.
    pub fn reserve_automation_run(&self, run: &AutomationRun) -> Result<Option<AutomationRun>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if let Some(key) = run.once_key.as_deref() {
            let existing = tx
                .query_row(
                    "SELECT * FROM automation_runs
                     WHERE automation_id = ?1 AND once_key = ?2
                     ORDER BY id LIMIT 1",
                    params![run.automation_id, key],
                    Self::automation_run_from_row,
                )
                .optional()?;
            if let Some(existing) = existing {
                tx.rollback()?;
                return Ok(Some(existing));
            }
        }
        tx.execute(
            "INSERT INTO automation_runs (id, automation_id, run_id, trigger_summary, trigger_payload,
                                          selection, context_preview, status, error, task_id, once_key,
                                          kind, due_at, attempt_count, retry_at, lease_until, accepted_at,
                                          created_at, ended_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19)",
            params![
                run.id, run.automation_id, run.run_id, run.trigger_summary,
                run.trigger_payload.as_ref().map(to_json), run.selection.as_ref().map(to_json),
                run.context_preview, run.status.as_str(), run.error, run.task_id, run.once_key,
                match run.kind { AutomationRunKind::Action => "action", AutomationRunKind::WatchPoll => "watch_poll" },
                run.due_at, run.attempt_count, run.retry_at, run.lease_until, run.accepted_at,
                run.created_at, run.ended_at
            ],
        )?;
        tx.commit()?;
        Ok(None)
    }

    /// Materialize a clock occurrence and advance its schedule in one commit.
    /// A duplicate tick returns the already durable occurrence.
    pub fn materialize_due_automation_run(
        &self,
        automation: &Automation,
        kind: AutomationRunKind,
        due_at: Millis,
        next_run_at: Option<Millis>,
        trigger_summary: &str,
        trigger_payload: Option<&Json>,
    ) -> Result<Option<AutomationRun>> {
        let kind = match kind {
            AutomationRunKind::Action => "action",
            AutomationRunKind::WatchPoll => "watch_poll",
        };
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let current = tx
            .query_row(
                "SELECT enabled, trigger, next_run_at FROM automations WHERE id = ?1",
                params![automation.id],
                |row| {
                    Ok((
                        row.get::<_, i64>(0)? != 0,
                        row.get::<_, String>(1)?,
                        row.get::<_, Option<Millis>>(2)?,
                    ))
                },
            )
            .optional()?;
        let expected_trigger = to_json(&automation.trigger);
        if !matches!(current, Some((true, ref trigger, next)) if trigger == &expected_trigger && next == automation.next_run_at)
        {
            let existing = tx
                .query_row(
                    "SELECT * FROM automation_runs
                     WHERE automation_id = ?1 AND kind = ?2 AND due_at = ?3",
                    params![automation.id, kind, due_at],
                    Self::automation_run_from_row,
                )
                .optional()?;
            tx.rollback()?;
            return Ok(existing);
        }

        let id = new_id();
        let created_at = now_ms();
        tx.execute(
            "INSERT OR IGNORE INTO automation_runs
                (id, automation_id, trigger_summary, trigger_payload, context_preview,
                 status, kind, due_at, created_at)
             VALUES (?1,?2,?3,?4,'','queued',?5,?6,?7)",
            params![
                id,
                automation.id,
                trigger_summary,
                trigger_payload.map(to_json),
                kind,
                due_at,
                created_at
            ],
        )?;
        tx.execute(
            "UPDATE automations SET next_run_at = ?2
             WHERE id = ?1 AND enabled = 1 AND trigger = ?3 AND next_run_at IS ?4",
            params![
                automation.id,
                next_run_at,
                expected_trigger,
                automation.next_run_at
            ],
        )?;
        let run = tx.query_row(
            "SELECT * FROM automation_runs
             WHERE automation_id = ?1 AND kind = ?2 AND due_at = ?3",
            params![automation.id, kind, due_at],
            Self::automation_run_from_row,
        )?;
        tx.commit()?;
        Ok(Some(run))
    }

    /// Work ready for an attempt, oldest occurrence first. Claiming remains a
    /// separate atomic step so concurrent scheduler ticks are harmless.
    pub fn ready_automation_runs(&self, now: Millis, limit: usize) -> Result<Vec<AutomationRun>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT candidate.* FROM automation_runs AS candidate
             JOIN automations ON automations.id = candidate.automation_id
             WHERE automations.enabled = 1
               AND candidate.accepted_at IS NULL
               AND candidate.run_id IS NULL
               AND candidate.status IN ('queued','dispatched')
               AND (candidate.retry_at IS NULL OR candidate.retry_at <= ?1)
               AND (candidate.lease_until IS NULL OR candidate.lease_until <= ?1)
               AND NOT EXISTS (
                   SELECT 1 FROM automation_runs AS older
                    WHERE older.automation_id = candidate.automation_id
                      AND older.kind = candidate.kind
                      AND older.accepted_at IS NULL
                      AND older.status IN ('queued','dispatched')
                      AND (COALESCE(older.due_at, older.created_at) < COALESCE(candidate.due_at, candidate.created_at)
                           OR (COALESCE(older.due_at, older.created_at) = COALESCE(candidate.due_at, candidate.created_at)
                               AND older.id < candidate.id))
               )
             ORDER BY COALESCE(candidate.due_at, candidate.created_at), candidate.id
             LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![now, limit as i64], Self::automation_run_from_row)?;
        Ok(rows.filter_map(Result::ok).collect())
    }

    pub fn claim_automation_run(
        &self,
        id: &str,
        now: Millis,
        lease_until: Millis,
    ) -> Result<Option<AutomationRun>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        let changed = tx.execute(
            "UPDATE automation_runs AS candidate
                SET status = 'dispatched', lease_until = ?3,
                    attempt_count = attempt_count + 1, error = NULL, retry_at = NULL
              WHERE candidate.id = ?1
                AND candidate.accepted_at IS NULL
                AND candidate.run_id IS NULL
                AND candidate.status IN ('queued','dispatched')
                AND (candidate.retry_at IS NULL OR candidate.retry_at <= ?2)
                AND (candidate.lease_until IS NULL OR candidate.lease_until <= ?2)
                AND EXISTS (SELECT 1 FROM automations
                             WHERE id = candidate.automation_id AND enabled = 1)
                AND NOT EXISTS (
                    SELECT 1 FROM automation_runs AS older
                     WHERE older.automation_id = candidate.automation_id
                       AND older.kind = candidate.kind
                       AND older.accepted_at IS NULL
                       AND older.status IN ('queued','dispatched')
                       AND (COALESCE(older.due_at, older.created_at) < COALESCE(candidate.due_at, candidate.created_at)
                            OR (COALESCE(older.due_at, older.created_at) = COALESCE(candidate.due_at, candidate.created_at)
                                AND older.id < candidate.id))
                )",
            params![id, now, lease_until],
        )?;
        let run = if changed == 0 {
            None
        } else {
            tx.query_row(
                "SELECT * FROM automation_runs WHERE id = ?1",
                params![id],
                Self::automation_run_from_row,
            )
            .optional()?
        };
        tx.commit()?;
        Ok(run)
    }

    pub fn retry_automation_run(
        &self,
        id: &str,
        attempt: i64,
        error: &str,
        now: Millis,
    ) -> Result<Option<AutomationRun>> {
        let exponent = attempt.saturating_sub(1).clamp(0, 8) as u32;
        let delay = 1_000_i64.saturating_mul(1_i64 << exponent).min(300_000);
        let retry_at = now.saturating_add(delay);
        let error: String = error.chars().take(500).collect();
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if tx.execute(
            "UPDATE automation_runs
                SET run_id = NULL, status = 'queued', error = ?3, retry_at = ?4,
                    lease_until = NULL, ended_at = NULL
              WHERE id = ?1 AND attempt_count = ?2 AND accepted_at IS NULL",
            params![id, attempt, error, retry_at],
        )? == 0
        {
            tx.rollback()?;
            return Ok(None);
        }
        let run = tx.query_row(
            "SELECT * FROM automation_runs WHERE id = ?1",
            params![id],
            Self::automation_run_from_row,
        )?;
        tx.commit()?;
        Ok(Some(run))
    }

    pub fn release_automation_run(&self, id: &str, attempt: i64) -> Result<Option<AutomationRun>> {
        let conn = self.conn()?;
        if conn.execute(
            "UPDATE automation_runs
                SET status = 'queued', error = NULL, retry_at = NULL, lease_until = NULL
              WHERE id = ?1 AND attempt_count = ?2 AND accepted_at IS NULL AND run_id IS NULL",
            params![id, attempt],
        )? == 0
        {
            return Ok(None);
        }
        Ok(conn
            .query_row(
                "SELECT * FROM automation_runs WHERE id = ?1",
                params![id],
                Self::automation_run_from_row,
            )
            .optional()?)
    }

    pub fn complete_automation_run(
        &self,
        id: &str,
        attempt: i64,
        at: Millis,
    ) -> Result<Option<AutomationRun>> {
        let mut conn = self.conn()?;
        let tx = conn.transaction_with_behavior(TransactionBehavior::Immediate)?;
        if tx.execute(
            "UPDATE automation_runs
                SET status = 'succeeded', error = NULL, retry_at = NULL, lease_until = NULL,
                    accepted_at = ?3, ended_at = ?3
              WHERE id = ?1 AND attempt_count = ?2 AND accepted_at IS NULL",
            params![id, attempt, at],
        )? == 0
        {
            tx.rollback()?;
            return Ok(None);
        }
        tx.execute(
            "UPDATE automations SET last_run_at = ?2,
                                    execution_failure_notification_key = NULL
              WHERE id = (SELECT automation_id FROM automation_runs WHERE id = ?1)",
            params![id, at],
        )?;
        let run = tx.query_row(
            "SELECT * FROM automation_runs WHERE id = ?1",
            params![id],
            Self::automation_run_from_row,
        )?;
        tx.commit()?;
        Ok(Some(run))
    }

    pub fn automation_run(&self, id: &str) -> Result<Option<AutomationRun>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM automation_runs WHERE id = ?1",
                params![id],
                Self::automation_run_from_row,
            )
            .optional()?)
    }

    /// Has this automation already acted on this key? The guard that makes a
    /// webhook safe to retry.
    pub fn automation_run_by_once_key(
        &self,
        automation_id: &str,
        once_key: &str,
    ) -> Result<Option<AutomationRun>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM automation_runs WHERE automation_id = ?1 AND once_key = ?2
                 ORDER BY id DESC LIMIT 1",
                params![automation_id, once_key],
                |r| Self::automation_run_from_row(r),
            )
            .optional()?)
    }

    pub fn automation_runs(&self, automation_id: &str, limit: usize) -> Result<Vec<AutomationRun>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare(
            "SELECT * FROM automation_runs WHERE automation_id = ?1 ORDER BY id DESC LIMIT ?2",
        )?;
        let rows = stmt.query_map(params![automation_id, limit as i64], |r| {
            Self::automation_run_from_row(r)
        })?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn automation_run_by_run(&self, run_id: &str) -> Result<Option<AutomationRun>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM automation_runs WHERE run_id = ?1",
                params![run_id],
                |r| Self::automation_run_from_row(r),
            )
            .optional()?)
    }

    // -- previews -----------------------------------------------------------

    fn preview_from_row(row: &Row) -> rusqlite::Result<Preview> {
        let status: String = row.get("status")?;
        Ok(Preview {
            id: row.get("id")?,
            task_id: row.get("task_id")?,
            host_id: row.get("host_id")?,
            run_id: row.get("run_id")?,
            label: row.get("label")?,
            port: row.get::<_, i64>("port")? as u16,
            url: row.get("url")?,
            status: match status.as_str() {
                "live" => PreviewStatus::Live,
                "stopped" => PreviewStatus::Stopped,
                "failed" => PreviewStatus::Failed,
                _ => PreviewStatus::Starting,
            },
            local_only: row.get::<_, i64>("local_only")? != 0,
            created_at: row.get("created_at")?,
            stopped_at: row.get("stopped_at")?,
        })
    }

    pub fn upsert_preview(&self, preview: &Preview) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO previews (id, task_id, host_id, run_id, label, port, url, status, local_only, created_at, stopped_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)
             ON CONFLICT(id) DO UPDATE SET url=?7, status=?8, stopped_at=?11",
            params![
                preview.id, preview.task_id, preview.host_id, preview.run_id, preview.label,
                preview.port as i64, preview.url,
                serde_json::to_string(&preview.status).unwrap_or_default().trim_matches('"'),
                preview.local_only as i64, preview.created_at, preview.stopped_at
            ],
        )?;
        Ok(())
    }

    pub fn preview(&self, id: &str) -> Result<Option<Preview>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM previews WHERE id = ?1", params![id], |r| {
                Self::preview_from_row(r)
            })
            .optional()?)
    }

    pub fn previews(&self, only_live: bool) -> Result<Vec<Preview>> {
        let conn = self.conn()?;
        let sql = if only_live {
            "SELECT * FROM previews WHERE status IN ('starting','live') ORDER BY id DESC"
        } else {
            "SELECT * FROM previews ORDER BY id DESC LIMIT 200"
        };
        let mut stmt = conn.prepare(sql)?;
        let rows = stmt.query_map([], |r| Self::preview_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn task_previews(&self, task_id: &str) -> Result<Vec<Preview>> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT * FROM previews WHERE task_id = ?1 ORDER BY id DESC")?;
        let rows = stmt.query_map(params![task_id], |r| Self::preview_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    // -- event log ----------------------------------------------------------

    pub fn append_event(&self, event: &Event) -> Result<Envelope> {
        let conn = self.conn()?;
        let at = now_ms();
        conn.execute(
            "INSERT INTO events (at, payload) VALUES (?1, ?2)",
            params![at, to_json(event)],
        )?;
        let seq = conn.last_insert_rowid();
        // Keep the catch-up log bounded; clients that fall far behind
        // re-bootstrap instead.
        if seq % 500 == 0 {
            conn.execute("DELETE FROM events WHERE seq < ?1", params![seq - 5000])?;
        }
        Ok(Envelope {
            seq,
            at,
            event: event.clone(),
        })
    }

    pub fn events_since(&self, seq: i64, limit: usize) -> Result<Vec<Envelope>> {
        let conn = self.conn()?;
        let mut stmt = conn
            .prepare("SELECT seq, at, payload FROM events WHERE seq > ?1 ORDER BY seq LIMIT ?2")?;
        let rows = stmt.query_map(params![seq, limit as i64], |r| {
            let payload: String = r.get(2)?;
            Ok((r.get::<_, i64>(0)?, r.get::<_, i64>(1)?, payload))
        })?;
        let mut out = Vec::new();
        for (seq, at, payload) in rows.flatten() {
            if let Ok(event) = serde_json::from_str::<Event>(&payload) {
                out.push(Envelope { seq, at, event });
            }
        }
        Ok(out)
    }

    pub fn latest_seq(&self) -> Result<i64> {
        let conn = self.conn()?;
        Ok(conn.query_row("SELECT COALESCE(MAX(seq), 0) FROM events", [], |r| r.get(0))?)
    }

    /// Used by the bootstrap endpoint to avoid N queries for member lookups.
    pub fn member_names(&self) -> Result<BTreeMap<Id, String>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT id, display_name FROM members")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        Ok(rows.flatten().collect())
    }

    pub fn channel_names(&self) -> Result<BTreeMap<Id, String>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT id, name FROM channels")?;
        let rows = stmt.query_map([], |r| Ok((r.get::<_, String>(0)?, r.get::<_, String>(1)?)))?;
        Ok(rows.flatten().collect())
    }

    /// Members who can see a channel: everyone for workspace-visible channels
    /// and task discussions, and only the listed participants for DMs.
    pub fn channel_audience(&self, channel_id: &str) -> Result<Vec<Id>> {
        let conn = self.conn()?;
        let kind: Option<String> = conn
            .query_row(
                "SELECT kind FROM channels WHERE id = ?1",
                params![channel_id],
                |r| r.get(0),
            )
            .optional()?;
        match kind.as_deref() {
            Some("dm") => {
                let mut stmt =
                    conn.prepare("SELECT member_id FROM channel_members WHERE channel_id = ?1")?;
                let rows = stmt.query_map(params![channel_id], |r| r.get::<_, String>(0))?;
                Ok(rows.flatten().collect())
            }
            _ => {
                let mut stmt = conn.prepare("SELECT id FROM members WHERE active = 1")?;
                let rows = stmt.query_map([], |r| r.get::<_, String>(0))?;
                Ok(rows.flatten().collect())
            }
        }
    }

    pub fn add_channel_member(&self, channel_id: &str, member_id: &str) -> Result<()> {
        self.conn()?.execute(
            "INSERT OR IGNORE INTO channel_members (channel_id, member_id) VALUES (?1, ?2)",
            params![channel_id, member_id],
        )?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use patchwork_core::new_id;

    fn store() -> (Store, std::path::PathBuf) {
        let path = std::env::temp_dir().join(format!("patchwork-store-{}.sqlite", new_id()));
        (Store::open(&path).unwrap(), path)
    }

    fn human(id: &str) -> Member {
        Member {
            id: id.into(),
            kind: MemberKind::Human,
            handle: id.into(),
            display_name: id.into(),
            email: None,
            avatar: None,
            is_admin: false,
            created_at: 1,
            agent: None,
            presence: Presence::Offline,
        }
    }

    fn watch_automation() -> Automation {
        Automation {
            id: "watch".into(),
            name: "Watch".into(),
            description: String::new(),
            enabled: false,
            trigger: AutomationTrigger::Watch {
                command: "true".into(),
                every_seconds: 60,
            },
            agent_id: "agent".into(),
            action: AutomationAction::CreateTask,
            instructions: String::new(),
            context_channel_id: None,
            report_channel_id: None,
            project_id: None,
            location: ExecutionLocation::Auto,
            host_id: None,
            created_by: "human".into(),
            created_at: 1,
            last_run_at: None,
            next_run_at: None,
            last_success_at: None,
            last_error_at: None,
            last_error: None,
            last_validated_at: None,
            failure_count: 0,
            overdue_since: None,
            blocked_reason: None,
            retry_at: None,
        }
    }

    fn run(id: &str, task_id: &str) -> Run {
        Run {
            id: id.into(),
            agent_id: "agent".into(),
            status: RunStatus::Running,
            trigger: RunTrigger::Manual { by: "human".into() },
            channel_id: "channel".into(),
            task_id: Some(task_id.into()),
            host_id: Some("host".into()),
            project_id: None,
            worktree_id: None,
            cwd: None,
            automation_id: None,
            session_id: None,
            runtime: "test".into(),
            provider: None,
            model: None,
            thinking: None,
            prompt: String::new(),
            headline: String::new(),
            error: None,
            token_usage: None,
            created_at: 1,
            started_at: Some(1),
            ended_at: None,
        }
    }

    fn question(id: &str, run_id: &str) -> Question {
        Question {
            id: id.into(),
            run_id: run_id.into(),
            agent_id: "agent".into(),
            channel_id: "channel".into(),
            task_id: Some("task".into()),
            message_id: None,
            headline: String::new(),
            items: Vec::new(),
            status: QuestionStatus::Open,
            answers: None,
            answered_by: None,
            created_at: 1,
            answered_at: None,
        }
    }

    fn idempotent_task(id: &str, key: &str) -> Task {
        Task {
            id: id.into(),
            key: key.into(),
            title: "Image proxy is returning 403".into(),
            outcome: "Restore image delivery".into(),
            status: TaskStatus::Planned,
            owner_id: None,
            source_channel_id: None,
            source_message_id: None,
            background: false,
            discussion_channel_id: format!("channel-{id}"),
            project_id: None,
            host_id: None,
            worktree_id: None,
            current_run_id: None,
            active_continuation: None,
            pr_url: None,
            pr_state: None,
            review_action: None,
            created_by: "human".into(),
            due_at: None,
            once_key: Some("posthog:image-proxy:403".into()),
            created_at: 1,
            updated_at: 1,
            position: 1.0,
        }
    }

    fn task_channel(task: &Task) -> Channel {
        Channel {
            id: task.discussion_channel_id.clone(),
            kind: ChannelKind::Task,
            section_id: None,
            slug: String::new(),
            name: task.title.clone(),
            topic: task.outcome.clone(),
            position: 0.0,
            created_at: 1,
            member_ids: vec!["human".into()],
            task_id: Some(task.id.clone()),
            last_message_at: 1,
        }
    }

    #[test]
    fn watch_health_records_failures_and_recovery() {
        let (store, path) = store();
        store.upsert_automation(&watch_automation()).unwrap();

        let diagnostic = format!("HTTP 404 {}", "x".repeat(600));
        let (failed, notify) = store
            .record_watch_failure("watch", "true", 10, &diagnostic)
            .unwrap()
            .unwrap();
        assert!(notify);
        assert_eq!(failed.failure_count, 1);
        assert_eq!(failed.last_error.as_ref().unwrap().chars().count(), 500);
        assert!(failed.last_error.as_ref().unwrap().starts_with("HTTP 404"));
        assert_eq!(failed.last_error_at, Some(10));
        assert_eq!(failed.last_validated_at, None);

        let (repeated, notify) = store
            .record_watch_failure("watch", "true", 11, &diagnostic)
            .unwrap()
            .unwrap();
        assert!(!notify);
        assert_eq!(repeated.failure_count, 2);
        store
            .retry_watch_failure_notification("watch", &diagnostic)
            .unwrap();
        let (_, notify) = store
            .record_watch_failure("watch", "true", 12, &diagnostic)
            .unwrap()
            .unwrap();
        assert!(notify, "a failed notification is retried");

        let (_, notify) = store
            .record_watch_failure("watch", "true", 13, "HTTP 500")
            .unwrap()
            .unwrap();
        assert!(notify, "a new diagnostic pings the creator again");

        let healthy = store
            .record_watch_success("watch", "true", 20, true)
            .unwrap()
            .unwrap();
        assert_eq!(healthy.failure_count, 0);
        assert_eq!(healthy.last_success_at, Some(20));
        assert_eq!(healthy.last_validated_at, Some(20));
        let (_, notify) = store
            .record_watch_failure("watch", "true", 21, "HTTP 500")
            .unwrap()
            .unwrap();
        assert!(notify, "recovery resets notification deduplication");

        let (_, notify) = store
            .record_automation_execution_failure("watch", "agent could not start")
            .unwrap()
            .unwrap();
        assert!(notify);
        let (_, notify) = store
            .record_automation_execution_failure("watch", "agent could not start")
            .unwrap()
            .unwrap();
        assert!(!notify, "identical execution failures do not spam");
        store
            .retry_automation_execution_notification("watch", "agent could not start")
            .unwrap();
        let (_, notify) = store
            .record_automation_execution_failure("watch", "agent could not start")
            .unwrap()
            .unwrap();
        assert!(notify, "a failed execution notification is retried");
        store.clear_automation_execution_failure("watch").unwrap();
        let (_, notify) = store
            .record_automation_execution_failure("watch", "agent could not start")
            .unwrap()
            .unwrap();
        assert!(notify, "execution recovery resets deduplication");
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn config_updates_preserve_concurrent_health_unless_the_command_changes() {
        let (store, path) = store();
        let mut stale = watch_automation();
        store.upsert_automation(&stale).unwrap();
        store
            .record_watch_success("watch", "true", 10, true)
            .unwrap();
        store
            .record_watch_failure("watch", "true", 20, "HTTP 404")
            .unwrap();
        store
            .record_automation_execution_failure("watch", "agent could not start")
            .unwrap();

        stale.name = "Renamed".into();
        let original_trigger = stale.trigger.clone();
        let preserved = store
            .update_automation_config(&stale, &original_trigger, false, false)
            .unwrap()
            .unwrap();
        assert_eq!(preserved.failure_count, 1);
        assert_eq!(preserved.last_validated_at, Some(10));
        assert_eq!(preserved.last_error.as_deref(), Some("HTTP 404"));
        let (_, notify) = store
            .record_automation_execution_failure("watch", "agent could not start")
            .unwrap()
            .unwrap();
        assert!(
            notify,
            "a config edit makes a repeated execution failure actionable again"
        );

        stale.trigger = AutomationTrigger::Watch {
            command: "changed".into(),
            every_seconds: 60,
        };
        let reset = store
            .update_automation_config(&stale, &original_trigger, false, true)
            .unwrap()
            .unwrap();
        assert_eq!(reset.failure_count, 0);
        assert_eq!(reset.last_success_at, None);
        assert_eq!(reset.last_validated_at, None);
        assert_eq!(reset.last_error, None);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_stale_config_update_cannot_overwrite_a_changed_schedule() {
        let (store, path) = store();
        let mut original = watch_automation();
        original.trigger = AutomationTrigger::Schedule {
            every_seconds: 60,
            start_at: None,
        };
        original.next_run_at = Some(61);
        store.upsert_automation(&original).unwrap();
        let mut changed = original.clone();
        changed.trigger = AutomationTrigger::Schedule {
            every_seconds: 300,
            start_at: None,
        };
        changed.next_run_at = Some(320);
        store
            .update_automation_config(&changed, &original.trigger, false, false)
            .unwrap();
        assert!(store
            .update_automation_config(&original, &original.trigger, false, false)
            .unwrap()
            .is_none());

        assert_eq!(
            store.automation("watch").unwrap().unwrap().next_run_at,
            Some(320)
        );
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_finished_poll_cannot_validate_a_replaced_watch_command() {
        let (store, path) = store();
        let original = watch_automation();
        store.upsert_automation(&original).unwrap();
        let mut changed = original.clone();
        changed.trigger = AutomationTrigger::Watch {
            command: "different".into(),
            every_seconds: 60,
        };
        store.upsert_automation(&changed).unwrap();

        assert!(store
            .record_watch_success("watch", "true", 20, true)
            .unwrap()
            .is_none());
        assert_eq!(
            store
                .automation("watch")
                .unwrap()
                .unwrap()
                .last_validated_at,
            None
        );
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_finished_poll_survives_an_interval_only_edit() {
        let (store, path) = store();
        let mut watch = watch_automation();
        watch.trigger = AutomationTrigger::Watch {
            command: "true".into(),
            every_seconds: 300,
        };
        store.upsert_automation(&watch).unwrap();

        let healthy = store
            .record_watch_success("watch", "true", 20, true)
            .unwrap()
            .unwrap();
        assert_eq!(healthy.last_success_at, Some(20));
        assert_eq!(healthy.last_validated_at, Some(20));
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn run_configuration_survives_insert_and_update() {
        let (store, path) = store();
        let mut configured = run("configured", "task");
        configured.provider = Some("openai".into());
        configured.model = Some("openai/gpt-5.6-sol".into());
        configured.thinking = Some("xhigh".into());
        store.insert_run(&configured, 0).unwrap();

        let loaded = store.run(&configured.id).unwrap().unwrap();
        assert_eq!(loaded.provider.as_deref(), Some("openai"));
        assert_eq!(loaded.model.as_deref(), Some("openai/gpt-5.6-sol"));
        assert_eq!(loaded.thinking.as_deref(), Some("xhigh"));

        configured.model = Some("anthropic/claude-opus-5".into());
        store.update_run(&configured).unwrap();
        assert_eq!(
            store.run(&configured.id).unwrap().unwrap().model.as_deref(),
            Some("anthropic/claude-opus-5")
        );
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn workspace_autonomy_defaults_empty_and_round_trips() {
        let (store, path) = store();
        let created = store.create_workspace("ws", "Test").unwrap();
        assert!(created.autonomy.is_empty());

        let updated = store
            .update_workspace(None, None, None, None, Some("Merge after checks pass."))
            .unwrap();
        assert_eq!(updated.autonomy, "Merge after checks pass.");
        assert_eq!(store.workspace().unwrap().autonomy, updated.autonomy);

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn workspace_skills_persist_in_name_order() {
        let (store, path) = store();
        for (id, name) in [("two", "Writing"), ("one", "Accessibility")] {
            assert!(matches!(
                store
                    .save_workspace_skill(
                        WorkspaceSkill {
                            id: id.into(),
                            name: name.into(),
                            description: format!("Use {name}"),
                            instructions: format!("Follow {name}"),
                            created_at: 1,
                            updated_at: 1,
                        },
                        false,
                        usize::MAX,
                    )
                    .unwrap(),
                SaveWorkspaceSkillResult::Saved(_)
            ));
        }
        let skills = store.workspace_skills().unwrap();
        assert_eq!(
            skills
                .iter()
                .map(|skill| skill.id.as_str())
                .collect::<Vec<_>>(),
            ["one", "two"]
        );
        assert!(store.delete_workspace_skill("one").unwrap());
        assert_eq!(store.workspace_skills().unwrap(), skills[1..]);
        assert!(matches!(
            store
                .save_workspace_skill(skills[0].clone(), true, usize::MAX)
                .unwrap(),
            SaveWorkspaceSkillResult::Missing
        ));
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn concurrent_workspace_skills_keep_the_prompt_limit() {
        let (store, path) = store();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let joins = ["one", "two"].map(|id| {
            let store = store.clone();
            let barrier = barrier.clone();
            std::thread::spawn(move || {
                barrier.wait();
                store
                    .save_workspace_skill(
                        WorkspaceSkill {
                            id: id.into(),
                            name: id.into(),
                            description: String::new(),
                            instructions: "x".repeat(40),
                            created_at: 1,
                            updated_at: 1,
                        },
                        false,
                        50,
                    )
                    .unwrap()
            })
        });
        let results = joins.map(|join| join.join().unwrap());
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, SaveWorkspaceSkillResult::Saved(_)))
                .count(),
            1
        );
        assert_eq!(store.workspace_skills().unwrap().len(), 1);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn concurrent_once_keys_create_one_task_and_one_discussion() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let mut joins = Vec::new();
        for (id, key) in [("one", "PW-1"), ("two", "PW-2")] {
            let store = store.clone();
            let barrier = barrier.clone();
            joins.push(std::thread::spawn(move || {
                let task = idempotent_task(id, key);
                let channel = task_channel(&task);
                barrier.wait();
                store.insert_task_with_channel(&task, &channel).unwrap()
            }));
        }
        let results: Vec<_> = joins.into_iter().map(|join| join.join().unwrap()).collect();
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, InsertTaskResult::Inserted))
                .count(),
            1
        );
        assert_eq!(
            results
                .iter()
                .filter(|result| matches!(result, InsertTaskResult::Existing(_)))
                .count(),
            1
        );
        assert_eq!(store.tasks().unwrap().len(), 1);
        assert_eq!(
            store
                .channels()
                .unwrap()
                .into_iter()
                .filter(|channel| channel.kind == ChannelKind::Task)
                .count(),
            1
        );
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn stale_agent_updates_cannot_overwrite_a_newer_task_state() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let task = idempotent_task("one", "PW-1");
        store
            .insert_task_with_channel(&task, &task_channel(&task))
            .unwrap();

        let mut completed = task.clone();
        completed.status = TaskStatus::Done;
        store.update_task(&completed).unwrap();

        let mut stale = task.clone();
        stale.title = "Stale agent edit".into();
        assert!(!store
            .update_task_if_unchanged(&stale, task.updated_at, false)
            .unwrap());
        let stored = store.task(&task.id).unwrap().unwrap();
        assert_eq!(stored.status, TaskStatus::Done);
        assert!(stored.updated_at > task.updated_at);
        assert_ne!(stored.title, stale.title);

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_finished_run_never_keeps_a_task_busy() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let task = idempotent_task("one", "PW-1");
        store
            .insert_task_with_channel(&task, &task_channel(&task))
            .unwrap();

        let mut done = run("run-done", &task.id);
        store.insert_run(&done, 0).unwrap();
        store
            .activate_task_run(&task.id, &done.id, None)
            .unwrap()
            .unwrap();
        done.status = RunStatus::Succeeded;
        done.ended_at = Some(2);
        store.update_run(&done).unwrap();

        // The run ended and released the task, which is now waiting on a human.
        let mut released = store.task(&task.id).unwrap().unwrap();
        released.current_run_id = None;
        released.status = TaskStatus::Review;
        store.update_task(&released).unwrap();

        // A pull request poll writes its own column and nothing else.
        let pr = PullRequestState {
            number: 89,
            title: "fix the icon".into(),
            state: "OPEN".into(),
            checks: String::new(),
            review: String::new(),
            last_feedback_at: String::new(),
            updated_at: 3,
        };
        let polled = store.set_task_pr_state(&task.id, &pr).unwrap().unwrap();
        assert!(polled.current_run_id.is_none());
        assert_eq!(polled.status, TaskStatus::Review);
        assert_eq!(polled.pr_state.as_ref().map(|p| p.number), Some(89));

        // And a pointer that survived anyway does not park the task forever:
        // the sweeper clears it, and an approval that needs a free task can
        // claim it again.
        let mut stuck = polled.clone();
        stuck.current_run_id = Some(done.id.clone());
        store.update_task(&stuck).unwrap();
        assert_eq!(store.clear_finished_task_runs().unwrap(), 1);
        assert!(store
            .task(&task.id)
            .unwrap()
            .unwrap()
            .current_run_id
            .is_none());
        assert!(store
            .activate_task_run(&task.id, "next-run", None)
            .unwrap()
            .is_some());

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_continuation_keeps_the_task_running_and_is_consumed_by_its_wake_run() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let task = idempotent_task("one", "PW-1");
        store
            .insert_task_with_channel(&task, &task_channel(&task))
            .unwrap();
        let mut source = run("source", &task.id);
        store.insert_run(&source, 0).unwrap();
        store
            .activate_task_run(&task.id, &source.id, None)
            .unwrap()
            .unwrap();

        let continuation = TaskContinuation {
            id: "continuation".into(),
            task_id: task.id.clone(),
            run_id: source.id.clone(),
            agent_id: source.agent_id.clone(),
            command: "check-build".into(),
            every_seconds: 20,
            deadline_at: 100_000,
            wake_prompt: "Finish the release".into(),
            status: ContinuationStatus::Waiting,
            summary: "Build is processing".into(),
            next_check_at: 2,
            created_at: 1,
            updated_at: 1,
            ended_at: None,
        };
        let registered = store
            .register_task_continuation(&continuation)
            .unwrap()
            .unwrap();
        assert_eq!(registered.status, TaskStatus::Running);
        assert_eq!(
            registered
                .active_continuation
                .as_ref()
                .map(|item| item.summary.as_str()),
            Some("Build is processing")
        );
        assert!(store
            .register_task_continuation(&continuation)
            .unwrap()
            .is_none());
        // A delayed finalization from the registering run must not consume the
        // obligation that run just handed to the relay.
        assert!(store
            .finalize_task_run_start(&task.id, &source.id, source.created_at)
            .unwrap());
        assert!(store
            .task(&task.id)
            .unwrap()
            .unwrap()
            .active_continuation
            .is_some());

        source.status = RunStatus::Cancelled;
        source.ended_at = Some(2);
        store.update_run(&source).unwrap();
        drop(store);

        // The run is gone and the relay process may restart; the obligation is
        // still enough to recover the task as running and resume its checker.
        let store = Store::open(&path).unwrap();
        store.reconcile_task_lifecycle().unwrap();
        let waiting = store.task(&task.id).unwrap().unwrap();
        assert_eq!(waiting.status, TaskStatus::Running);
        assert!(waiting.current_run_id.is_none());

        assert_eq!(store.claim_due_task_continuations(2).unwrap().len(), 1);
        store
            .apply_task_continuation_result(
                &continuation.id,
                ContinuationStatus::Waiting,
                "Still processing",
            )
            .unwrap()
            .unwrap();
        let ready = store
            .apply_task_continuation_result(
                &continuation.id,
                ContinuationStatus::Ready,
                "Build is available",
            )
            .unwrap()
            .unwrap();
        assert_eq!(
            ready.active_continuation.as_ref().map(|item| item.status),
            Some(ContinuationStatus::Ready)
        );

        let wake = run("wake", &task.id);
        store.insert_run(&wake, 0).unwrap();
        store
            .activate_task_run(&task.id, &wake.id, Some(TaskStatus::Running))
            .unwrap()
            .unwrap();
        assert!(store
            .finalize_task_run_start(&task.id, &wake.id, wake.created_at)
            .unwrap());
        assert!(store
            .task(&task.id)
            .unwrap()
            .unwrap()
            .active_continuation
            .is_none());
        assert!(store
            .apply_task_continuation_result(
                &continuation.id,
                ContinuationStatus::Failed,
                "late output",
            )
            .unwrap()
            .is_none());

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_continuation_deadline_becomes_a_named_blocker() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let task = idempotent_task("one", "PW-1");
        store
            .insert_task_with_channel(&task, &task_channel(&task))
            .unwrap();
        let source = run("source", &task.id);
        store.insert_run(&source, 0).unwrap();
        store
            .activate_task_run(&task.id, &source.id, None)
            .unwrap()
            .unwrap();
        store
            .register_task_continuation(&TaskContinuation {
                id: "continuation".into(),
                task_id: task.id.clone(),
                run_id: source.id.clone(),
                agent_id: source.agent_id.clone(),
                command: "check".into(),
                every_seconds: 20,
                deadline_at: 2,
                wake_prompt: "Continue".into(),
                status: ContinuationStatus::Waiting,
                summary: "Provider review is pending".into(),
                next_check_at: 2,
                created_at: 1,
                updated_at: 1,
                ended_at: None,
            })
            .unwrap()
            .unwrap();

        let expired = store.expire_task_continuations(2).unwrap();
        assert_eq!(expired.len(), 1);
        assert_eq!(expired[0].status, TaskStatus::Blocked);
        let blocker = expired[0].active_continuation.as_ref().unwrap();
        assert_eq!(blocker.status, ContinuationStatus::ActionRequired);
        assert_eq!(
            blocker.summary,
            "Deadline reached: Provider review is pending"
        );

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn reconciliation_repoints_then_releases_cancelled_runs() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let task = idempotent_task("one", "PW-1");
        store
            .insert_task_with_channel(&task, &task_channel(&task))
            .unwrap();
        let mut peer = run("peer", &task.id);
        let mut cancelled = run("cancelled", &task.id);
        store.insert_run(&peer, 0).unwrap();
        store.insert_run(&cancelled, 0).unwrap();
        store
            .activate_task_run(&task.id, &peer.id, None)
            .unwrap()
            .unwrap();
        store
            .activate_task_run(&task.id, &cancelled.id, None)
            .unwrap()
            .unwrap();
        cancelled.status = RunStatus::Cancelled;
        cancelled.ended_at = Some(2);
        store.update_run(&cancelled).unwrap();

        store.reconcile_task_lifecycle().unwrap();
        let working = store.task(&task.id).unwrap().unwrap();
        assert_eq!(working.status, TaskStatus::Running);
        assert_eq!(working.current_run_id.as_deref(), Some(peer.id.as_str()));

        peer.status = RunStatus::Cancelled;
        peer.ended_at = Some(3);
        store.update_run(&peer).unwrap();
        store.reconcile_task_lifecycle().unwrap();
        let released = store.task(&task.id).unwrap().unwrap();
        assert_eq!(released.status, TaskStatus::Planned);
        assert!(released.current_run_id.is_none());

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn task_run_activation_claims_the_expected_state_once() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let task = idempotent_task("one", "PW-1");
        store
            .insert_task_with_channel(&task, &task_channel(&task))
            .unwrap();

        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let mut joins = Vec::new();
        for run_id in ["run-one", "run-two"] {
            let store = store.clone();
            let barrier = barrier.clone();
            let task_id = task.id.clone();
            joins.push(std::thread::spawn(move || {
                barrier.wait();
                (
                    run_id,
                    store
                        .activate_task_run(&task_id, run_id, Some(TaskStatus::Planned))
                        .unwrap(),
                )
            }));
        }
        let results: Vec<_> = joins.into_iter().map(|join| join.join().unwrap()).collect();
        assert_eq!(
            results
                .iter()
                .filter(|(_, status)| status.is_some())
                .count(),
            1
        );
        let winner = results
            .iter()
            .find_map(|(run_id, status)| status.map(|_| *run_id))
            .unwrap();
        assert!(store
            .restore_task_after_failed_start(&task.id, winner, TaskStatus::Planned)
            .unwrap());

        assert_eq!(
            store
                .activate_task_run(&task.id, "run-three", Some(TaskStatus::Planned))
                .unwrap(),
            Some(TaskStatus::Planned)
        );
        let mut reviewed = store.task(&task.id).unwrap().unwrap();
        reviewed.status = TaskStatus::Review;
        store.update_task(&reviewed).unwrap();
        assert!(store
            .restore_task_after_failed_start(&task.id, "run-three", TaskStatus::Planned)
            .unwrap());
        let reviewed = store.task(&task.id).unwrap().unwrap();
        assert_eq!(reviewed.status, TaskStatus::Review);
        assert!(reviewed.current_run_id.is_none());

        let mut completed = reviewed;
        completed.status = TaskStatus::Done;
        store.update_task(&completed).unwrap();
        assert_eq!(
            store
                .activate_task_run(&task.id, "run-four", Some(TaskStatus::Planned))
                .unwrap(),
            None
        );

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn migration_preserves_an_enabled_legacy_watch_as_unvalidated() {
        let path = std::env::temp_dir().join(format!("patchwork-store-{}.sqlite", new_id()));
        let conn = rusqlite::Connection::open(&path).unwrap();
        conn.execute_batch(
            "CREATE TABLE automations (
                id TEXT PRIMARY KEY, name TEXT NOT NULL, description TEXT NOT NULL DEFAULT '',
                enabled INTEGER NOT NULL DEFAULT 1, trigger TEXT NOT NULL,
                agent_id TEXT NOT NULL, action TEXT NOT NULL, instructions TEXT NOT NULL DEFAULT '',
                context_channel_id TEXT, report_channel_id TEXT, project_id TEXT,
                location TEXT NOT NULL DEFAULT 'auto', host_id TEXT, created_by TEXT NOT NULL,
                created_at INTEGER NOT NULL, last_run_at INTEGER, next_run_at INTEGER,
                failure_count INTEGER NOT NULL DEFAULT 0
             );",
        )
        .unwrap();
        conn.execute(
            "INSERT INTO automations
                (id, name, enabled, trigger, agent_id, action, created_by, created_at)
             VALUES ('watch', 'Watch', 1, ?1, 'agent', 'create_task', 'human', 1)",
            params![to_json(&watch_automation().trigger)],
        )
        .unwrap();
        drop(conn);

        let store = Store::open(&path).unwrap();
        let watch = store.automation("watch").unwrap().unwrap();
        assert!(watch.enabled, "an upgrade must not change user intent");
        assert_eq!(watch.last_validated_at, None);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn v026_damage_is_repaired_from_the_last_explicit_enabled_state() {
        let (store, path) = store();
        let mut enabled = watch_automation();
        enabled.id = "enabled".into();
        enabled.enabled = true;
        store.upsert_automation(&enabled).unwrap();
        store
            .append_event(&Event::AutomationUpdated {
                automation: enabled.clone(),
            })
            .unwrap();

        let mut paused = enabled.clone();
        paused.id = "paused".into();
        paused.enabled = false;
        store.upsert_automation(&paused).unwrap();
        store
            .append_event(&Event::AutomationUpdated {
                automation: paused.clone(),
            })
            .unwrap();

        let conn = store.conn().unwrap();
        conn.execute(
            "UPDATE automations SET enabled=0, next_run_at=NULL WHERE id='enabled'",
            [],
        )
        .unwrap();
        conn.execute("ALTER TABLE automation_runs DROP COLUMN accepted_at", [])
            .unwrap();
        conn.pragma_update(None, "user_version", 0).unwrap();
        drop(conn);
        drop(store);

        let repaired = Store::open(&path).unwrap();
        assert!(repaired.automation("enabled").unwrap().unwrap().enabled);
        assert!(!repaired.automation("paused").unwrap().unwrap().enabled);
        drop(repaired);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn due_occurrence_survives_restart_and_duplicate_ticks() {
        let (store, path) = store();
        let mut automation = watch_automation();
        automation.enabled = true;
        automation.next_run_at = Some(10);
        store.upsert_automation(&automation).unwrap();

        let first = store
            .materialize_due_automation_run(
                &automation,
                AutomationRunKind::WatchPoll,
                10,
                Some(70),
                "Watch poll",
                None,
            )
            .unwrap()
            .unwrap();
        let duplicate = store
            .materialize_due_automation_run(
                &automation,
                AutomationRunKind::WatchPoll,
                10,
                Some(70),
                "Watch poll",
                None,
            )
            .unwrap()
            .unwrap();
        assert_eq!(duplicate.id, first.id);
        assert_eq!(store.automation_runs("watch", 10).unwrap().len(), 1);
        assert_eq!(
            store.automation("watch").unwrap().unwrap().next_run_at,
            Some(70)
        );
        drop(store);

        let reopened = Store::open(&path).unwrap();
        let ready = reopened.ready_automation_runs(10, 10).unwrap();
        assert_eq!(ready.len(), 1);
        assert_eq!(ready[0].id, first.id);
        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn transient_failure_retries_the_same_occurrence_and_pause_blocks_claims() {
        let (store, path) = store();
        let mut automation = watch_automation();
        automation.enabled = true;
        automation.next_run_at = Some(10);
        store.upsert_automation(&automation).unwrap();
        let occurrence = store
            .materialize_due_automation_run(
                &automation,
                AutomationRunKind::WatchPoll,
                10,
                Some(70),
                "Watch poll",
                None,
            )
            .unwrap()
            .unwrap();
        let claimed = store
            .claim_automation_run(&occurrence.id, 10, 100)
            .unwrap()
            .unwrap();
        assert_eq!(claimed.attempt_count, 1);
        let retry = store
            .retry_automation_run(&occurrence.id, 1, "host offline", 10)
            .unwrap()
            .unwrap();
        assert_eq!(retry.id, occurrence.id);
        assert_eq!(retry.retry_at, Some(1_010));
        assert_eq!(
            store
                .automation("watch")
                .unwrap()
                .unwrap()
                .blocked_reason
                .as_deref(),
            Some("host offline")
        );

        let mut paused = store.automation("watch").unwrap().unwrap();
        paused.enabled = false;
        let trigger = paused.trigger.clone();
        store
            .update_automation_config(&paused, &trigger, true, false)
            .unwrap()
            .unwrap();
        assert!(store
            .claim_automation_run(&occurrence.id, 1_010, 20_000)
            .unwrap()
            .is_none());
        assert_eq!(store.automation_runs("watch", 10).unwrap().len(), 1);
        let mut stale_edit = automation.clone();
        stale_edit.description = "stale editor".into();
        assert!(store
            .update_automation_config(&stale_edit, &trigger, true, false)
            .unwrap()
            .is_none());
        assert!(!store.automation("watch").unwrap().unwrap().enabled);

        paused.enabled = true;
        store
            .update_automation_config(&paused, &trigger, false, false)
            .unwrap()
            .unwrap();
        let retried = store
            .claim_automation_run(&occurrence.id, 1_010, 20_000)
            .unwrap()
            .unwrap();
        assert_eq!(retried.id, occurrence.id);
        assert_eq!(retried.attempt_count, 2);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn an_active_lease_is_not_reported_as_overdue() {
        let (store, path) = store();
        let now = now_ms();
        let mut automation = watch_automation();
        automation.enabled = true;
        automation.next_run_at = Some(now - 120_000);
        store.upsert_automation(&automation).unwrap();
        let occurrence = store
            .materialize_due_automation_run(
                &automation,
                AutomationRunKind::WatchPoll,
                now - 120_000,
                Some(now + 60_000),
                "Watch poll",
                None,
            )
            .unwrap()
            .unwrap();
        assert!(store
            .automation("watch")
            .unwrap()
            .unwrap()
            .overdue_since
            .is_some());
        let claimed = store
            .claim_automation_run(&occurrence.id, now, now + 300_000)
            .unwrap()
            .unwrap();
        assert_eq!(
            store.automation("watch").unwrap().unwrap().overdue_since,
            None
        );
        store
            .retry_automation_run(&occurrence.id, claimed.attempt_count, "host offline", now)
            .unwrap()
            .unwrap();
        assert!(store
            .automation("watch")
            .unwrap()
            .unwrap()
            .overdue_since
            .is_some());
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn expired_lease_attempts_are_fenced_from_newer_workers() {
        let (store, path) = store();
        let mut automation = watch_automation();
        automation.enabled = true;
        automation.next_run_at = Some(10);
        store.upsert_automation(&automation).unwrap();
        let occurrence = store
            .materialize_due_automation_run(
                &automation,
                AutomationRunKind::WatchPoll,
                10,
                Some(70),
                "Watch poll",
                None,
            )
            .unwrap()
            .unwrap();
        let first = store
            .claim_automation_run(&occurrence.id, 10, 20)
            .unwrap()
            .unwrap();
        let second = store
            .claim_automation_run(&occurrence.id, 21, 100)
            .unwrap()
            .unwrap();
        assert_eq!(first.attempt_count, 1);
        assert_eq!(second.attempt_count, 2);
        assert!(store
            .retry_automation_run(&occurrence.id, first.attempt_count, "late failure", 21)
            .unwrap()
            .is_none());
        assert!(store
            .complete_automation_run(&occurrence.id, first.attempt_count, 21)
            .unwrap()
            .is_none());
        let current = store.automation_run(&occurrence.id).unwrap().unwrap();
        assert_eq!(current.attempt_count, 2);
        assert_eq!(current.lease_until, Some(100));
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn run_dispatch_is_not_accepted_until_the_host_acknowledges_it() {
        let (store, path) = store();
        let mut automation = watch_automation();
        automation.enabled = true;
        automation.next_run_at = Some(10);
        store.upsert_automation(&automation).unwrap();
        let occurrence = store
            .materialize_due_automation_run(
                &automation,
                AutomationRunKind::Action,
                10,
                Some(70),
                "Scheduled",
                None,
            )
            .unwrap()
            .unwrap();
        store
            .claim_automation_run(&occurrence.id, 10, 100)
            .unwrap()
            .unwrap();
        let mut dispatched = run("run", "task");
        dispatched.task_id = None;
        dispatched.automation_id = Some(automation.id.clone());
        dispatched.status = RunStatus::Dispatched;
        store
            .insert_run_for_automation(&dispatched, 0, &occurrence.id, 1)
            .unwrap();
        let sent = store.automation_run(&occurrence.id).unwrap().unwrap();
        assert_eq!(sent.status, RunStatus::Dispatched);
        assert_eq!(sent.accepted_at, None);

        dispatched.status = RunStatus::Running;
        let (transitioned, accepted) = store.accept_run_dispatch(&dispatched, 20).unwrap();
        assert!(transitioned);
        let accepted = accepted.unwrap();
        assert_eq!(accepted.status, RunStatus::Running);
        assert_eq!(accepted.accepted_at, Some(20));

        let mut ended = dispatched.clone();
        ended.status = RunStatus::Failed;
        ended.ended_at = Some(30);
        store.update_run(&ended).unwrap();
        let (transitioned, _) = store.accept_run_dispatch(&dispatched, 40).unwrap();
        assert!(
            !transitioned,
            "a late acknowledgement cannot revive a terminal run"
        );
        assert_eq!(
            store.run(&dispatched.id).unwrap().unwrap().status,
            RunStatus::Failed
        );
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn migration_keeps_tasks_but_claims_a_legacy_key_once() {
        let (store, path) = store();
        store
            .conn()
            .unwrap()
            .execute("DROP INDEX tasks_open_once", [])
            .unwrap();
        let first = idempotent_task("one", "PW-1");
        let mut second = idempotent_task("two", "PW-2");
        second.once_key = Some("POSTHOG:IMAGE-PROXY:403".into());
        store.insert_task(&first).unwrap();
        store.insert_task(&second).unwrap();
        drop(store);

        let reopened = Store::open(&path).unwrap();
        let tasks = reopened.tasks().unwrap();
        assert_eq!(tasks.len(), 2, "migration never deletes a task");
        assert_eq!(
            tasks
                .iter()
                .filter(|task| task.once_key.as_deref() == Some("posthog:image-proxy:403"))
                .count(),
            1
        );
        drop(reopened);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn concurrent_webhook_keys_reserve_one_automation_run() {
        let (store, path) = store();
        let barrier = std::sync::Arc::new(std::sync::Barrier::new(2));
        let mut joins = Vec::new();
        for id in ["one", "two"] {
            let store = store.clone();
            let barrier = barrier.clone();
            joins.push(std::thread::spawn(move || {
                let run = AutomationRun {
                    id: id.into(),
                    automation_id: "automation".into(),
                    run_id: None,
                    trigger_summary: "Incoming webhook".into(),
                    trigger_payload: None,
                    selection: None,
                    context_preview: String::new(),
                    status: RunStatus::Queued,
                    error: None,
                    task_id: None,
                    once_key: Some("delivery-123".into()),
                    kind: AutomationRunKind::Action,
                    due_at: None,
                    attempt_count: 0,
                    retry_at: None,
                    lease_until: None,
                    accepted_at: None,
                    created_at: 1,
                    ended_at: None,
                };
                barrier.wait();
                store.reserve_automation_run(&run).unwrap()
            }));
        }
        let results: Vec<_> = joins.into_iter().map(|join| join.join().unwrap()).collect();
        assert_eq!(
            results.iter().filter(|existing| existing.is_none()).count(),
            1
        );
        assert_eq!(
            results.iter().filter(|existing| existing.is_some()).count(),
            1
        );
        assert_eq!(store.automation_runs("automation", 10).unwrap().len(), 1);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn pairing_issues_a_separate_device_for_the_same_member() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let secret = "raw-pairing-secret";
        let token = "new-device-token";
        store
            .insert_pairing(&crate::auth::hash_token(secret), "human", now_ms() + 1_000)
            .unwrap();
        assert_eq!(
            store
                .conn()
                .unwrap()
                .query_row(
                    "SELECT COUNT(*) FROM pairings WHERE secret_hash = ?1",
                    params![secret],
                    |row| row.get::<_, i64>(0),
                )
                .unwrap(),
            0
        );
        assert_eq!(
            store
                .claim_pairing(
                    &crate::auth::hash_token(secret),
                    &crate::auth::hash_token(token),
                    Some("Phone"),
                    now_ms(),
                )
                .unwrap()
                .as_deref(),
            Some("human")
        );
        let issued = store
            .lookup_token(&crate::auth::hash_token(token))
            .unwrap()
            .unwrap();
        assert_eq!(issued.0, "human");
        assert_eq!(issued.1, "mobile");
        assert_eq!(store.members().unwrap().len(), 1);
        let devices = store
            .devices("human", &crate::auth::hash_token(token))
            .unwrap();
        assert_eq!(devices.len(), 1);
        assert_eq!(devices[0].label, "Phone");
        assert!(devices[0].current);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn pairings_expire_and_are_single_use() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let at = now_ms();
        store.insert_pairing("expired", "human", at).unwrap();
        assert!(store
            .claim_pairing("expired", "expired-token", None, at)
            .unwrap()
            .is_none());

        store.insert_pairing("once", "human", at + 1_000).unwrap();
        assert!(store
            .claim_pairing("once", "first-token", None, at)
            .unwrap()
            .is_some());
        assert!(store
            .claim_pairing("once", "second-token", None, at)
            .unwrap()
            .is_none());
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_member_cannot_revoke_another_members_device() {
        let (store, path) = store();
        store.insert_member(&human("one")).unwrap();
        store.insert_member(&human("two")).unwrap();
        store
            .insert_token("one-token", "one", "device", None, None)
            .unwrap();
        store
            .insert_token("two-token", "two", "device", None, None)
            .unwrap();
        assert!(!store.revoke_device("one", "two-token").unwrap());
        assert!(store.lookup_token("two-token").unwrap().is_some());
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn deactivated_members_no_longer_authenticate() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let token = crate::auth::generate_token();
        store
            .insert_token(
                &crate::auth::hash_token(&token),
                "human",
                "device",
                None,
                None,
            )
            .unwrap();
        let state = std::sync::Arc::new(crate::state::AppState::new(
            store.clone(),
            path.with_extension("files"),
            "http://workspace".into(),
            "host".into(),
        ));
        assert!(crate::auth::authenticate(&state, &token).is_some());
        store.deactivate_member("human").unwrap();
        assert!(crate::auth::authenticate(&state, &token).is_none());
        drop(state);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn inbox_read_is_scoped_to_its_owner() {
        let (store, path) = store();
        store
            .insert_inbox(&InboxItem {
                id: "item".into(),
                member_id: "two".into(),
                kind: InboxKind::Mention,
                title: "Mention".into(),
                preview: String::new(),
                actor_id: None,
                channel_id: None,
                message_id: None,
                task_id: None,
                run_id: None,
                automation_id: None,
                created_at: 1,
                read_at: None,
            })
            .unwrap();
        store.mark_inbox_read("item", "one").unwrap();
        assert!(store.inbox_item("item").unwrap().unwrap().read_at.is_none());
        store.mark_inbox_read("item", "two").unwrap();
        assert!(store.inbox_item("item").unwrap().unwrap().read_at.is_some());
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn questions_resolve_independently_without_reading_other_run_items() {
        let (store, path) = store();
        let item = |id: &str, kind: InboxKind, message_id: Option<&str>| InboxItem {
            id: id.into(),
            member_id: "human".into(),
            kind,
            title: "Inbox item".into(),
            preview: String::new(),
            actor_id: None,
            channel_id: Some("channel".into()),
            message_id: message_id.map(str::to_string),
            task_id: Some("task".into()),
            run_id: Some("run".into()),
            automation_id: None,
            created_at: 1,
            read_at: None,
        };
        store
            .insert_inbox(&item(
                "question-one",
                InboxKind::Question,
                Some("message-one"),
            ))
            .unwrap();
        store
            .insert_inbox(&item(
                "question-two",
                InboxKind::Question,
                Some("message-two"),
            ))
            .unwrap();

        store.mark_inbox_read("question-one", "human").unwrap();
        store.mark_all_inbox_read("human").unwrap();
        assert!(store
            .resolve_inbox_for(Some("task"), None, None)
            .unwrap()
            .is_empty());

        let mut mention = item("mention", InboxKind::Mention, Some("other-message"));
        mention.task_id = None;
        store.insert_inbox(&mention).unwrap();
        let changed = store
            .resolve_inbox_for(None, None, Some("message-one"))
            .unwrap();
        assert_eq!(changed.len(), 1);
        assert_eq!(changed[0].id, "question-one");
        assert!(store
            .inbox_item("question-two")
            .unwrap()
            .unwrap()
            .read_at
            .is_none());

        let changed = store.resolve_inbox_for(None, Some("run"), None).unwrap();
        assert_eq!(changed.len(), 1);
        assert_eq!(changed[0].id, "question-two");
        assert!(store
            .inbox_item("mention")
            .unwrap()
            .unwrap()
            .read_at
            .is_none());
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn question_transitions_are_single_use() {
        let (store, path) = store();
        store
            .insert_question(&question("answered", "run-a"))
            .unwrap();
        assert_eq!(
            store
                .answer_question("answered", &[], "human")
                .unwrap()
                .0
                .status,
            QuestionStatus::Answered
        );
        assert!(store.answer_question("answered", &[], "human").is_err());

        store
            .insert_question(&question("cancelled", "run-b"))
            .unwrap();
        let cancelled = store.cancel_questions_for_run("run-b").unwrap();
        assert_eq!(cancelled.len(), 1);
        assert_eq!(cancelled[0].status, QuestionStatus::Cancelled);
        assert!(store.answer_question("cancelled", &[], "human").is_err());

        // Two asks racing past the API's pre-check still leave one question.
        let live = run("run-c", "task-c");
        store.insert_run(&live, 0).unwrap();
        store.insert_question(&question("asking", "run-c")).unwrap();
        assert!(matches!(
            store
                .commit_question_waiting(&question("second", "run-c"), &live, &[], false)
                .unwrap(),
            QuestionCommit::AlreadyAsking(open) if open.id == "asking"
        ));
        assert!(store.question("second").unwrap().is_none());
        let QuestionCommit::Committed { superseded, .. } = store
            .commit_question_waiting(&question("third", "run-c"), &live, &[], true)
            .unwrap()
        else {
            panic!("replacing a question commits");
        };
        assert_eq!(superseded.len(), 1);
        assert_eq!(superseded[0].id, "asking");
        assert_eq!(
            store.question("third").unwrap().unwrap().status,
            QuestionStatus::Open
        );

        let mut ended = run("ended-run", "ended-task");
        ended.status = RunStatus::Cancelled;
        store.insert_run(&ended, 0).unwrap();
        let pending = question("too-late", "ended-run");
        assert!(matches!(
            store
                .commit_question_waiting(&pending, &ended, &[], false)
                .unwrap(),
            QuestionCommit::RunEnded
        ));
        assert!(store.question(&pending.id).unwrap().is_none());
        assert_eq!(
            store.run(&ended.id).unwrap().unwrap().status,
            RunStatus::Cancelled
        );
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn task_questions_reach_every_human_who_can_see_the_task() {
        let (store, path) = store();
        store.insert_member(&human("one")).unwrap();
        store.insert_member(&human("two")).unwrap();
        for (id, kind) in [("task", ChannelKind::Task), ("dm", ChannelKind::Dm)] {
            store
                .insert_channel(&Channel {
                    id: id.into(),
                    kind,
                    section_id: None,
                    slug: String::new(),
                    name: id.into(),
                    topic: String::new(),
                    position: 0.0,
                    created_at: 1,
                    member_ids: vec!["one".into()],
                    task_id: None,
                    last_message_at: 0,
                })
                .unwrap();
        }

        let mut task_audience = store.channel_audience("task").unwrap();
        task_audience.sort();
        assert_eq!(task_audience, ["one", "two"]);
        assert_eq!(store.channel_audience("dm").unwrap(), ["one"]);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_task_runs_several_agents_at_once_and_lists_them() {
        let (store, path) = store();
        store.insert_member(&human("human")).unwrap();
        let task = idempotent_task("one", "PW-1");
        store
            .insert_task_with_channel(&task, &task_channel(&task))
            .unwrap();

        let mut first = run("r1", &task.id);
        store.insert_run(&first, 0).unwrap();
        assert_eq!(
            store
                .activate_task_run(&task.id, &first.id, None)
                .unwrap()
                .unwrap(),
            TaskStatus::Planned
        );

        // A second agent joins the same task and the same worktree.
        let second = run("r2", &task.id);
        store.insert_run(&second, 0).unwrap();
        assert_eq!(
            store
                .activate_task_run(&task.id, &second.id, None)
                .unwrap()
                .unwrap(),
            TaskStatus::Running
        );
        assert_eq!(
            store
                .active_task_runs(&task.id)
                .unwrap()
                .into_iter()
                .map(|r| r.id)
                .collect::<Vec<_>>(),
            ["r2", "r1"]
        );

        // One of them falling over leaves the other in charge of the task.
        assert!(store
            .restore_task_after_failed_start(&task.id, "r2", TaskStatus::Planned)
            .unwrap());
        let stored = store.task(&task.id).unwrap().unwrap();
        assert_eq!(stored.status, TaskStatus::Running);
        assert_eq!(stored.current_run_id.as_deref(), Some("r1"));

        // The last one out gives the task back.
        let mut second = second;
        second.status = RunStatus::Cancelled;
        store.update_run(&second).unwrap();
        first.status = RunStatus::Succeeded;
        store.update_run(&first).unwrap();
        assert!(store.active_task_runs(&task.id).unwrap().is_empty());
        assert!(store
            .restore_task_after_failed_start(&task.id, "r1", TaskStatus::Planned)
            .unwrap());
        let stored = store.task(&task.id).unwrap().unwrap();
        assert_eq!(stored.status, TaskStatus::Planned);
        assert_eq!(stored.current_run_id, None);
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn direct_messages_reserve_their_pair_budget_atomically() {
        let (store, path) = store();
        for index in 0..4 {
            let mut event = RunEvent {
                id: format!("event-{index}"),
                run_id: "source".into(),
                seq: 0,
                kind: RunEventKind::Message,
                text: "coordination".into(),
                data: Some(serde_json::json!({
                    "direction": "outbound",
                    "target_run_id": "target",
                })),
                created_at: index,
            };
            store.reserve_direct_control(&mut event, "target").unwrap();
            assert_eq!(event.seq, index + 1);
        }
        let mut extra = RunEvent {
            id: "extra".into(),
            run_id: "source".into(),
            seq: 0,
            kind: RunEventKind::Message,
            text: "too many".into(),
            data: Some(serde_json::json!({
                "direction": "outbound",
                "target_run_id": "target",
            })),
            created_at: 5,
        };
        assert!(store.reserve_direct_control(&mut extra, "target").is_err());
        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn inline_replies_stay_in_the_timeline_without_becoming_threads() {
        let (store, path) = store();
        store
            .insert_channel(&Channel {
                id: "channel".into(),
                kind: ChannelKind::Channel,
                section_id: None,
                slug: "general".into(),
                name: "General".into(),
                topic: String::new(),
                position: 0.0,
                created_at: 1,
                member_ids: Vec::new(),
                task_id: None,
                last_message_at: 0,
            })
            .unwrap();
        let source = Message {
            id: "m1".into(),
            channel_id: "channel".into(),
            author_id: "agent".into(),
            kind: MessageKind::Text,
            body: "First".into(),
            card: None,
            suggestions: vec!["Continue".into()],
            parent_id: None,
            reply_to_id: None,
            reply_to: None,
            reply_count: 0,
            last_reply_at: 0,
            run_id: None,
            task_id: None,
            mentions: Vec::new(),
            attachments: Vec::new(),
            reactions: Vec::new(),
            created_at: 1,
            edited_at: None,
        };
        let mut reply = source.clone();
        reply.id = "m2".into();
        reply.author_id = "human".into();
        reply.body = "Second".into();
        reply.reply_to_id = Some(source.id.clone());
        reply.created_at = 2;
        store.insert_message(&source).unwrap();
        store.insert_message(&reply).unwrap();

        let (timeline, _) = store.messages("channel", None, 10).unwrap();
        assert_eq!(
            timeline
                .iter()
                .map(|message| message.id.as_str())
                .collect::<Vec<_>>(),
            ["m1", "m2"]
        );
        assert_eq!(timeline[0].suggestions, ["Continue"]);
        assert_eq!(timeline[1].reply_to_id.as_deref(), Some("m1"));
        assert_eq!(timeline[1].reply_to.as_ref().unwrap().body, "First");
        assert!(store.thread("m1").unwrap().is_empty());
        assert_eq!(store.message("m1").unwrap().unwrap().reply_count, 0);

        drop(store);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn a_task_message_pins_its_attachment_to_both_records() {
        let (store, path) = store();
        store
            .insert_channel(&Channel {
                id: "channel".into(),
                kind: ChannelKind::Task,
                section_id: None,
                slug: String::new(),
                name: "Task".into(),
                topic: String::new(),
                position: 0.0,
                created_at: 1,
                member_ids: Vec::new(),
                task_id: Some("task".into()),
                last_message_at: 0,
            })
            .unwrap();
        let attachment = Attachment {
            id: "file".into(),
            file_name: "screen.png".into(),
            mime: "image/png".into(),
            size: 1,
            caption: String::new(),
            url: "/api/files/file".into(),
            message_id: None,
            task_id: None,
            run_id: None,
            created_at: 1,
        };
        store
            .insert_attachment(&attachment, "/tmp/screen.png")
            .unwrap();
        store
            .insert_message(&Message {
                id: "message".into(),
                channel_id: "channel".into(),
                author_id: "human".into(),
                kind: MessageKind::Text,
                body: String::new(),
                card: None,
                suggestions: Vec::new(),
                parent_id: None,
                reply_to_id: None,
                reply_to: None,
                reply_count: 0,
                last_reply_at: 0,
                run_id: None,
                task_id: Some("task".into()),
                mentions: Vec::new(),
                attachments: vec![attachment],
                reactions: Vec::new(),
                created_at: 1,
                edited_at: None,
            })
            .unwrap();
        let attached = store.attachment("file").unwrap().unwrap().0;
        assert_eq!(attached.message_id.as_deref(), Some("message"));
        assert_eq!(attached.task_id.as_deref(), Some("task"));
        assert!(store.remove_task_attachment("file", "task").unwrap());
        let unpinned = store.attachment("file").unwrap().unwrap().0;
        assert_eq!(unpinned.message_id.as_deref(), Some("message"));
        assert_eq!(unpinned.task_id, None);
        assert!(store.task_attachments("task").unwrap().is_empty());
        assert!(!store.remove_task_attachment("file", "task").unwrap());
        let mut duplicate = store.message("message").unwrap().unwrap();
        duplicate.id = "other-message".into();
        assert!(store.insert_message(&duplicate).is_err());
        assert_eq!(
            store
                .attachment("file")
                .unwrap()
                .unwrap()
                .0
                .message_id
                .as_deref(),
            Some("message")
        );
        drop(store);
        let _ = std::fs::remove_file(path);
    }
}
