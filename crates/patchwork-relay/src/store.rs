//! SQLite storage.
//!
//! Queries are small and indexed, so they run directly on the async worker
//! rather than through a blocking pool; the one scan-shaped operation
//! (full-text search) is bounded by SQLite's FTS index.

use std::collections::BTreeMap;
use std::path::Path;

use anyhow::{anyhow, Context, Result};
use patchwork_core::events::{Envelope, Event};
use patchwork_core::models::*;
use patchwork_core::{now_ms, Id};
use r2d2_sqlite::SqliteConnectionManager;
use rusqlite::{params, OptionalExtension, Row};
use serde_json::Value as Json;

pub type Pool = r2d2::Pool<SqliteConnectionManager>;
pub type Conn = r2d2::PooledConnection<SqliteConnectionManager>;

#[derive(Clone)]
pub struct Store {
    pool: Pool,
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

        let conn = pool.get()?;
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
            "ALTER TABLE tasks ADD COLUMN once_key TEXT",
            "ALTER TABLE automation_runs ADD COLUMN once_key TEXT",
            // After the column, never in schema.sql: an index on a column an
            // older database has not been given yet would fail the batch.
            "CREATE INDEX IF NOT EXISTS automation_runs_once ON automation_runs(automation_id, once_key)",
        ] {
            let _ = conn.execute(statement, []);
        }

        Ok(Self { pool })
    }

    pub fn conn(&self) -> Result<Conn> {
        self.pool.get().context("database connection unavailable")
    }

    // -- workspace ---------------------------------------------------------

    pub fn workspace(&self) -> Result<Workspace> {
        let conn = self.conn()?;
        conn.query_row(
            "SELECT id, name, created_at, task_prefix, task_seq FROM workspace LIMIT 1",
            [],
            |r| {
                Ok(Workspace {
                    id: r.get(0)?,
                    name: r.get(1)?,
                    created_at: r.get(2)?,
                    task_prefix: r.get(3)?,
                    task_seq: r.get(4)?,
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
            created_at: now_ms(),
            task_seq: 0,
        };
        self.conn()?.execute(
            "INSERT INTO workspace (id, name, created_at, task_seq) VALUES (?1, ?2, ?3, 0)",
            params![ws.id, ws.name, ws.created_at],
        )?;
        Ok(ws)
    }

    pub fn update_workspace(&self, name: Option<&str>, task_prefix: Option<&str>) -> Result<Workspace> {
        let conn = self.conn()?;
        if let Some(name) = name {
            conn.execute("UPDATE workspace SET name = ?1", params![name])?;
        }
        if let Some(prefix) = task_prefix {
            conn.execute("UPDATE workspace SET task_prefix = ?1", params![prefix])?;
        }
        self.workspace()
    }

    /// Keys already handed out keep the prefix they were made with: renaming
    /// the series is not rewriting history.
    pub fn next_task_key(&self) -> Result<String> {
        let conn = self.conn()?;
        conn.execute("UPDATE workspace SET task_seq = task_seq + 1", [])?;
        let (prefix, seq): (String, i64) = conn.query_row(
            "SELECT task_prefix, task_seq FROM workspace LIMIT 1",
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
        self.conn()?
            .execute("UPDATE members SET active = 0 WHERE id = ?1", params![id])?;
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

    /// Returns `(member_id, kind, run_id)`.
    pub fn lookup_token(&self, token_hash: &str) -> Result<Option<(Id, String, Option<Id>)>> {
        let conn = self.conn()?;
        let found = conn
            .query_row(
                "SELECT member_id, kind, run_id FROM tokens WHERE token_hash = ?1 AND revoked = 0",
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
                created_by: r.get::<_, Option<String>>("created_by")?.unwrap_or_default(),
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
                        created_by: r.get::<_, Option<String>>("created_by")?.unwrap_or_default(),
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
        let mut stmt = conn.prepare("SELECT member_id FROM channel_members WHERE channel_id = ?1")?;
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
        self.conn()?
            .execute("UPDATE channels SET archived = 1 WHERE id = ?1", params![id])?;
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
            parent_id: row.get("parent_id")?,
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
        let conn = self.conn()?;
        conn.execute(
            "INSERT INTO messages (id, channel_id, author_id, kind, body, card, parent_id, run_id, task_id, mentions, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11)",
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
                message.parent_id,
                message.run_id,
                message.task_id,
                to_json(&message.mentions),
                message.created_at,
            ],
        )?;
        conn.execute(
            "INSERT INTO message_search (message_id, channel_id, body) VALUES (?1, ?2, ?3)",
            params![message.id, message.channel_id, message.body],
        )?;
        conn.execute(
            "UPDATE channels SET last_message_at = ?2 WHERE id = ?1",
            params![message.channel_id, message.created_at],
        )?;
        if let Some(parent) = &message.parent_id {
            conn.execute(
                "UPDATE messages SET reply_count = reply_count + 1, last_reply_at = ?2 WHERE id = ?1",
                params![parent, message.created_at],
            )?;
        }
        for id in &message.attachments.iter().map(|a| a.id.clone()).collect::<Vec<_>>() {
            conn.execute(
                "UPDATE attachments SET message_id = ?2 WHERE id = ?1",
                params![id, message.id],
            )?;
        }
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
        let mut stmt = conn.prepare(
            "SELECT * FROM messages WHERE channel_id = ?1 ORDER BY id DESC LIMIT ?2",
        )?;
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
        let mut reactions = conn
            .prepare("SELECT member_id, emoji FROM reactions WHERE message_id = ?1")?;
        let mut attachments = conn.prepare("SELECT * FROM attachments WHERE message_id = ?1")?;
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
            message_id: row.get("message_id")?,
            task_id: row.get("task_id")?,
            run_id: row.get("run_id")?,
            created_at: row.get("created_at")?,
        })
    }

    pub fn insert_attachment(
        &self,
        attachment: &Attachment,
        path: &str,
    ) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO attachments (id, file_name, mime, size, path, message_id, task_id, run_id, created_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9)",
            params![
                attachment.id,
                attachment.file_name,
                attachment.mime,
                attachment.size,
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
            .query_row("SELECT * FROM attachments WHERE id = ?1", params![id], |r| {
                Ok((Self::attachment_from_row(r)?, r.get::<_, String>("path")?))
            })
            .optional()?)
    }

    pub fn task_attachments(&self, task_id: &str) -> Result<Vec<Attachment>> {
        let conn = self.conn()?;
        let mut stmt =
            conn.prepare("SELECT * FROM attachments WHERE task_id = ?1 ORDER BY id DESC")?;
        let rows = stmt.query_map(params![task_id], |r| Self::attachment_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
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
            discussion_channel_id: row.get("discussion_channel_id")?,
            project_id: row.get("project_id")?,
            host_id: row.get("host_id")?,
            worktree_id: row.get("worktree_id")?,
            current_run_id: row.get("current_run_id")?,
            pr_url: row.get("pr_url")?,
            pr_state: json_col(row, "pr_state"),
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
                                pr_state, created_by, due_at, once_key, position, created_at, updated_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)",
            params![
                task.id, task.key, task.title, task.outcome, task.status.as_str(), task.owner_id,
                task.source_channel_id, task.source_message_id, task.discussion_channel_id,
                task.project_id, task.host_id, task.worktree_id, task.current_run_id, task.pr_url,
                task.pr_state.as_ref().map(to_json), task.created_by, task.due_at, task.once_key,
                task.position, task.created_at, task.updated_at
            ],
        )?;
        Ok(())
    }

    pub fn update_task(&self, task: &Task) -> Result<()> {
        self.conn()?.execute(
            "UPDATE tasks SET title=?2, outcome=?3, status=?4, owner_id=?5, project_id=?6, host_id=?7,
                              worktree_id=?8, current_run_id=?9, pr_url=?10, pr_state=?11, due_at=?12,
                              position=?13, updated_at=?14 WHERE id=?1",
            params![
                task.id, task.title, task.outcome, task.status.as_str(), task.owner_id,
                task.project_id, task.host_id, task.worktree_id, task.current_run_id, task.pr_url,
                task.pr_state.as_ref().map(to_json), task.due_at, task.position, now_ms()
            ],
        )?;
        Ok(())
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

    /// The open task an agent already made about this, if it made one. Done is
    /// not open: the same thing going wrong again is a new task, not a ghost.
    pub fn task_by_once_key(&self, key: &str) -> Result<Option<Task>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row(
                "SELECT * FROM tasks WHERE once_key = ?1 AND status != 'done'
                 ORDER BY created_at DESC LIMIT 1",
                params![key],
                |r| Self::task_from_row(r),
            )
            .optional()?)
    }

    pub fn delete_task(&self, id: &str) -> Result<()> {
        self.conn()?
            .execute("DELETE FROM tasks WHERE id = ?1", params![id])?;
        Ok(())
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
            trigger: json_col(row, "trigger").unwrap_or(RunTrigger::Manual {
                by: String::new(),
            }),
            channel_id: row.get("channel_id")?,
            task_id: row.get("task_id")?,
            host_id: row.get("host_id")?,
            project_id: row.get("project_id")?,
            worktree_id: row.get("worktree_id")?,
            cwd: row.get("cwd")?,
            automation_id: row.get("automation_id")?,
            session_id: row.get("session_id")?,
            runtime: row.get("runtime")?,
            prompt: row.get("prompt")?,
            headline: row.get("headline")?,
            error: row.get("error")?,
            token_usage: json_col(row, "token_usage"),
            created_at: row.get("created_at")?,
            started_at: row.get("started_at")?,
            ended_at: row.get("ended_at")?,
        })
    }

    pub fn insert_run(&self, run: &Run, depth: i32) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO runs (id, agent_id, status, trigger, channel_id, task_id, host_id, project_id,
                               worktree_id, cwd, automation_id, session_id, runtime, prompt, headline,
                               error, token_usage, depth, created_at, started_at, ended_at)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18,?19,?20,?21)",
            params![
                run.id, run.agent_id, run.status.as_str(), to_json(&run.trigger), run.channel_id,
                run.task_id, run.host_id, run.project_id, run.worktree_id, run.cwd, run.automation_id,
                run.session_id, run.runtime, run.prompt, run.headline, run.error,
                run.token_usage.as_ref().map(to_json), depth, run.created_at, run.started_at, run.ended_at
            ],
        )?;
        Ok(())
    }

    pub fn update_run(&self, run: &Run) -> Result<()> {
        self.conn()?.execute(
            "UPDATE runs SET status=?2, host_id=?3, worktree_id=?4, cwd=?5, session_id=?6, runtime=?7,
                             headline=?8, error=?9, token_usage=?10, started_at=?11, ended_at=?12,
                             project_id=?13 WHERE id=?1",
            params![
                run.id, run.status.as_str(), run.host_id, run.worktree_id, run.cwd, run.session_id,
                run.runtime, run.headline, run.error, run.token_usage.as_ref().map(to_json),
                run.started_at, run.ended_at, run.project_id
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
    pub fn project_active_run(&self, project_id: &str, task_id: Option<&str>) -> Result<Option<Run>> {
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
                kind: serde_json::from_value(Json::String(kind))
                    .unwrap_or(RunEventKind::Lifecycle),
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

    pub fn set_question_message(&self, id: &str, message_id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE questions SET message_id = ?2 WHERE id = ?1",
            params![id, message_id],
        )?;
        Ok(())
    }

    pub fn answer_question(
        &self,
        id: &str,
        answers: &[QuestionAnswer],
        by: &str,
    ) -> Result<Question> {
        self.conn()?.execute(
            "UPDATE questions SET status='answered', answers=?2, answered_by=?3, answered_at=?4
             WHERE id=?1 AND status='open'",
            params![id, to_json(&answers), by, now_ms()],
        )?;
        self.question(id)?
            .ok_or_else(|| anyhow!("question not found"))
    }

    pub fn cancel_questions_for_run(&self, run_id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE questions SET status='cancelled' WHERE run_id=?1 AND status='open'",
            params![run_id],
        )?;
        Ok(())
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

    pub fn mark_inbox_read(&self, id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE inbox SET read_at = ?2 WHERE id = ?1 AND read_at IS NULL",
            params![id, now_ms()],
        )?;
        Ok(())
    }

    pub fn mark_all_inbox_read(&self, member_id: &str) -> Result<()> {
        self.conn()?.execute(
            "UPDATE inbox SET read_at = ?2 WHERE member_id = ?1 AND read_at IS NULL",
            params![member_id, now_ms()],
        )?;
        Ok(())
    }

    /// Resolving an item that points at a task or run, once it is handled.
    pub fn resolve_inbox_for(&self, task_id: Option<&str>, run_id: Option<&str>) -> Result<()> {
        let conn = self.conn()?;
        if let Some(task_id) = task_id {
            conn.execute(
                "UPDATE inbox SET read_at = ?2 WHERE task_id = ?1 AND read_at IS NULL",
                params![task_id, now_ms()],
            )?;
        }
        if let Some(run_id) = run_id {
            conn.execute(
                "UPDATE inbox SET read_at = ?2 WHERE run_id = ?1 AND read_at IS NULL",
                params![run_id, now_ms()],
            )?;
        }
        Ok(())
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
            failure_count: row.get("failure_count")?,
        })
    }

    pub fn upsert_automation(&self, automation: &Automation) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO automations (id, name, description, enabled, trigger, agent_id, action, instructions,
                                      context_channel_id, report_channel_id, project_id, location, host_id,
                                      created_by, created_at, last_run_at, next_run_at, failure_count)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13,?14,?15,?16,?17,?18)
             ON CONFLICT(id) DO UPDATE SET name=?2, description=?3, enabled=?4, trigger=?5, agent_id=?6,
                                           action=?7, instructions=?8, context_channel_id=?9,
                                           report_channel_id=?10, project_id=?11, location=?12, host_id=?13,
                                           last_run_at=?16, next_run_at=?17, failure_count=?18",
            params![
                automation.id, automation.name, automation.description, automation.enabled as i64,
                to_json(&automation.trigger), automation.agent_id,
                serde_json::to_string(&automation.action).unwrap_or_default().trim_matches('"'),
                automation.instructions, automation.context_channel_id, automation.report_channel_id,
                automation.project_id,
                serde_json::to_string(&automation.location).unwrap_or_default().trim_matches('"'),
                automation.host_id, automation.created_by, automation.created_at,
                automation.last_run_at, automation.next_run_at, automation.failure_count
            ],
        )?;
        Ok(())
    }

    pub fn automations(&self) -> Result<Vec<Automation>> {
        let conn = self.conn()?;
        let mut stmt = conn.prepare("SELECT * FROM automations ORDER BY name COLLATE NOCASE")?;
        let rows = stmt.query_map([], |r| Self::automation_from_row(r))?;
        Ok(rows.filter_map(|r| r.ok()).collect())
    }

    pub fn automation(&self, id: &str) -> Result<Option<Automation>> {
        let conn = self.conn()?;
        Ok(conn
            .query_row("SELECT * FROM automations WHERE id = ?1", params![id], |r| {
                Self::automation_from_row(r)
            })
            .optional()?)
    }

    pub fn automation_by_webhook(&self, token: &str) -> Result<Option<Automation>> {
        Ok(self.automations()?.into_iter().find(|a| {
            matches!(&a.trigger, AutomationTrigger::Webhook { token: t } if t == token)
        }))
    }

    pub fn delete_automation(&self, id: &str) -> Result<()> {
        self.conn()?
            .execute("DELETE FROM automations WHERE id = ?1", params![id])?;
        Ok(())
    }

    fn automation_run_from_row(row: &Row) -> rusqlite::Result<AutomationRun> {
        let status: String = row.get("status")?;
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
            created_at: row.get("created_at")?,
            ended_at: row.get("ended_at")?,
        })
    }

    pub fn upsert_automation_run(&self, run: &AutomationRun) -> Result<()> {
        self.conn()?.execute(
            "INSERT INTO automation_runs (id, automation_id, run_id, trigger_summary, trigger_payload,
                                          selection, context_preview, status, error, task_id, created_at, ended_at,
                                          once_key)
             VALUES (?1,?2,?3,?4,?5,?6,?7,?8,?9,?10,?11,?12,?13)
             ON CONFLICT(id) DO UPDATE SET run_id=?3, selection=?6, context_preview=?7, status=?8,
                                           error=?9, task_id=?10, ended_at=?12",
            params![
                run.id, run.automation_id, run.run_id, run.trigger_summary,
                run.trigger_payload.as_ref().map(to_json), run.selection.as_ref().map(to_json),
                run.context_preview, run.status.as_str(), run.error, run.task_id,
                run.created_at, run.ended_at, run.once_key
            ],
        )?;
        Ok(())
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
        let mut stmt =
            conn.prepare("SELECT seq, at, payload FROM events WHERE seq > ?1 ORDER BY seq LIMIT ?2")?;
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

    /// Members who can see a channel: everyone for open channels, the listed
    /// participants for DMs, and for a task discussion its owner and creator.
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
            Some("dm") | Some("task") => {
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
