//! Data plane: the SQLite queue, observability streams, awaiter registry,
//! and the tool operations themselves. Ported intact from the 0.5.x
//! hand-rolled server; the transport moved to rmcp (server.rs) but every
//! queue semantic here is unchanged: explicit consume, second-precision ISO
//! stamps, WAL, one box-wide db resolved by `db_path()`.

use std::collections::HashMap;
use std::sync::{Arc, Mutex, OnceLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use rusqlite::Connection;
use serde_json::{json, Value};

pub const AWAIT_MAX_S: u64 = 3600;
/// Long by default: the await is armed as the LAST call of a turn. A client
/// with the tasks extension gets a task handle back immediately; a client
/// without it holds the call open (Claude Code >= 2.1.212 auto-backgrounds
/// the held call at ~2 minutes into a native background task, freeing the
/// turn — the result then arrives as a task notification). The old 50s
/// default existed only for the hand-rolled transport whose silent holds the
/// 2026-08-03 client aborted at ~60s; that ceiling is retired with it.
pub const AWAIT_DEFAULT_S: u64 = 1800;

// ── Nudge watchdog constants (semantics unchanged from 0.5.0) ───────────────
pub const NUDGE_POLL_S: u64 = 20;
pub const NUDGE_GRACE_S: i64 = 90;
pub const NUDGE_COOLDOWN_S: u64 = 300;
pub const NUDGE_NOAGENT_COOLDOWN_S: u64 = 1200;

// ── Observability ───────────────────────────────────────────────────────────
pub const AUDIT_DEFAULT_ON: bool = true;
pub const ACCESS_DEFAULT_ON: bool = false;
pub const MAX_LOG_BYTES: u64 = 10_000_000;
pub const MAX_BACKUPS: u32 = 1;

// ── Awaiter registry ────────────────────────────────────────────────────────
// Recipients with a live await in this process — in-call holds AND task-backed
// holds both register (the guard lives inside the spawned task future). Each
// hold records its start instant so status can expose hold AGE: a ghost hold
// (client died mid-hold; measured 2026-08-05, survives to full timeout) is
// indistinguishable from live coverage by name alone, but an old hold plus a
// quiet client is the shape to distrust. The nudge watchdog reads this; the
// in-call progress-tick liveness probe (server.rs) bounds ghost lifetime to
// ~90s for token-bearing clients.
fn awaiters() -> &'static Mutex<HashMap<String, Vec<Instant>>> {
    static A: OnceLock<Mutex<HashMap<String, Vec<Instant>>>> = OnceLock::new();
    A.get_or_init(|| Mutex::new(HashMap::new()))
}

/// RAII guard so an await that returns, times out, errors, is cancelled, or
/// panics always deregisters; a leaked entry would silently disable the nudge
/// for that name.
pub struct AwaitGuard {
    agent: String,
    at: Instant,
}
impl AwaitGuard {
    pub fn new(agent: &str) -> Self {
        let at = Instant::now();
        awaiters().lock().unwrap().entry(agent.to_string()).or_default().push(at);
        AwaitGuard { agent: agent.to_string(), at }
    }
}
impl Drop for AwaitGuard {
    fn drop(&mut self) {
        let mut m = awaiters().lock().unwrap();
        if let Some(v) = m.get_mut(&self.agent) {
            if let Some(i) = v.iter().position(|t| *t == self.at) {
                v.remove(i);
            } else {
                v.pop();
            }
            if v.is_empty() {
                m.remove(&self.agent);
            }
        }
    }
}

// ── Task-backed coverage (SEP-2663 holds) ───────────────────────────────────
// A task-backed hold runs SERVER-side: the client session that spawned it can
// die while the task keeps waiting, and a dead session must not suppress the
// nudge for its recipient. Coverage from a task therefore requires liveness:
// the task counts as a listener only while tasks/get polls keep arriving
// (within TASK_POLL_LIVENESS_S of the last one). In-call holds need no such
// check — a dead caller tears the HTTP request down and the guard drops.
pub const TASK_POLL_LIVENESS_S: u64 = 120;

struct TaskCover {
    agent: String,
    last_poll: Instant,
}

fn task_covers() -> &'static Mutex<HashMap<String, TaskCover>> {
    static T: OnceLock<Mutex<HashMap<String, TaskCover>>> = OnceLock::new();
    T.get_or_init(|| Mutex::new(HashMap::new()))
}

/// RAII cover for one task-backed hold; dropped when the task future settles
/// (result, timeout, cancellation, panic), removing the entry.
pub struct TaskCoverGuard(String);
impl TaskCoverGuard {
    pub fn new(task_id: &str, agent: &str) -> Self {
        task_covers().lock().unwrap().insert(
            task_id.to_string(),
            TaskCover { agent: agent.to_string(), last_poll: Instant::now() },
        );
        TaskCoverGuard(task_id.to_string())
    }
}
impl Drop for TaskCoverGuard {
    fn drop(&mut self) {
        task_covers().lock().unwrap().remove(&self.0);
    }
}

/// Called from the tasks/get handler: a poll proves the client behind the
/// task is still alive and listening.
pub fn touch_task_cover(task_id: &str) {
    if let Some(c) = task_covers().lock().unwrap().get_mut(task_id) {
        c.last_poll = Instant::now();
    }
}

fn task_cover_alive(c: &TaskCover) -> bool {
    c.last_poll.elapsed().as_secs() <= TASK_POLL_LIVENESS_S
}

// ── Live-agent snapshot (the ghost filter) ──────────────────────────────────
// Ghost holds cannot be detected from inside the handler: rmcp neither
// cancels a request future on client disconnect (session resumability) nor
// surfaces notification-send failures (fire-and-forget sink) — both measured
// 2026-08-05 (ghost smokes v1/v2). What the daemon CAN observe is herdr: the
// watchdog publishes the live agent set each tick, and every coverage view
// filters holds whose agent is provably gone. The orphan future itself runs
// to timeout invisibly. A stale or absent snapshot (herdr down, watchdog
// disabled) filters NOTHING — coverage is never dropped on missing evidence.
const LIVE_SNAPSHOT_FRESH_S: u64 = 90;

#[allow(clippy::type_complexity)]
fn live_agents() -> &'static Mutex<Option<(std::collections::HashSet<String>, Instant)>> {
    static L: OnceLock<Mutex<Option<(std::collections::HashSet<String>, Instant)>>> =
        OnceLock::new();
    L.get_or_init(|| Mutex::new(None))
}

/// Publish the watchdog's herdr view. `None` (herdr unreachable) clears the
/// snapshot so filtering stops rather than acting on stale data.
pub fn set_live_agents(names: Option<std::collections::HashSet<String>>) {
    *live_agents().lock().unwrap() = names.map(|s| (s, Instant::now()));
}

/// Some(true/false) when a fresh snapshot can answer; None means no evidence.
pub fn agent_is_live(name: &str) -> Option<bool> {
    live_agents()
        .lock()
        .unwrap()
        .as_ref()
        .filter(|(_, at)| at.elapsed().as_secs() <= LIVE_SNAPSHOT_FRESH_S)
        .map(|(s, _)| s.contains(name))
}

/// Coverage for the nudge and status: a hold or live task cover exists AND
/// the fresh snapshot does not prove the agent dead.
pub fn awaiter_active(agent: &str) -> bool {
    let held = awaiters().lock().unwrap().contains_key(agent)
        || task_covers()
            .lock()
            .unwrap()
            .values()
            .any(|c| c.agent == agent && task_cover_alive(c));
    held && agent_is_live(agent) != Some(false)
}

pub fn awaiting_names() -> Vec<String> {
    let mut v: Vec<String> = awaiters().lock().unwrap().keys().cloned().collect();
    v.extend(
        task_covers()
            .lock()
            .unwrap()
            .values()
            .filter(|c| task_cover_alive(c))
            .map(|c| c.agent.clone()),
    );
    v.retain(|n| agent_is_live(n) != Some(false));
    v.sort();
    v.dedup();
    v
}

/// Per-name hold detail for relay_status: hold count, oldest hold age, and
/// what the live-agent snapshot says (null = no fresh evidence). Ghosts show
/// here with `agent_live: false` for forensics even though the filtered
/// `awaiting` list excludes them.
pub fn awaiting_detail() -> Vec<Value> {
    let mut out: Vec<Value> = awaiters()
        .lock()
        .unwrap()
        .iter()
        .map(|(agent, holds)| {
            let oldest = holds.iter().map(|t| t.elapsed().as_secs()).max().unwrap_or(0);
            json!({"agent": agent, "holds": holds.len(), "kind": "hold",
                "oldest_age_s": oldest, "agent_live": agent_is_live(agent)})
        })
        .collect();
    for c in task_covers().lock().unwrap().values() {
        if task_cover_alive(c) {
            out.push(json!({"agent": c.agent, "holds": 1, "kind": "task",
                "oldest_age_s": c.last_poll.elapsed().as_secs(),
                "agent_live": agent_is_live(&c.agent)}));
        }
    }
    out.sort_by(|a, b| a["agent"].as_str().cmp(&b["agent"].as_str()));
    out
}

// ── In-process send notification ────────────────────────────────────────────
// relay_send pings the recipient's Notify so a live awaiter wakes in
// microseconds instead of on its next poll. The 2s poll fallback still covers
// writers that bypass this daemon (sqlite3 CLI, tests).
fn notifiers() -> &'static Mutex<HashMap<String, Arc<tokio::sync::Notify>>> {
    static N: OnceLock<Mutex<HashMap<String, Arc<tokio::sync::Notify>>>> = OnceLock::new();
    N.get_or_init(|| Mutex::new(HashMap::new()))
}

pub fn notifier_for(agent: &str) -> Arc<tokio::sync::Notify> {
    notifiers()
        .lock()
        .unwrap()
        .entry(agent.to_string())
        .or_insert_with(|| Arc::new(tokio::sync::Notify::new()))
        .clone()
}

pub fn notify_recipient(agent: &str) {
    if let Some(n) = notifiers().lock().unwrap().get(agent) {
        n.notify_waiters();
    }
}

pub fn now_iso() -> String {
    fmt_iso(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_secs())
}

/// Format an epoch-seconds instant as the second-precision ISO-8601 shape
/// every row in this db uses. Pure so the prune cutoff can reuse it.
pub fn fmt_iso(secs: u64) -> String {
    let days = secs / 86400;
    let (mut y, mut rem) = (1970i64, days as i64);
    loop {
        let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
        let len = if leap { 366 } else { 365 };
        if rem < len {
            break;
        }
        rem -= len;
        y += 1;
    }
    let leap = (y % 4 == 0 && y % 100 != 0) || y % 400 == 0;
    let ml = [31, if leap { 29 } else { 28 }, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31];
    let mut m = 0usize;
    while rem >= ml[m] {
        rem -= ml[m];
        m += 1;
    }
    let t = secs % 86400;
    format!(
        "{y:04}-{:02}-{:02}T{:02}:{:02}:{:02}Z",
        m + 1,
        rem + 1,
        t / 3600,
        (t % 3600) / 60,
        t % 60
    )
}

pub fn db_path() -> String {
    if let Ok(p) = std::env::var("ORG_RELAY_DB") {
        return p;
    }
    let root = std::env::var("HERDR_ORG_ROOT")
        .unwrap_or_else(|_| format!("{}/.herdr-org/default", std::env::var("HOME").unwrap_or_default()));
    format!("{root}/relay.db")
}

pub fn open_db() -> rusqlite::Result<Connection> {
    let conn = Connection::open(db_path())?;
    conn.busy_timeout(Duration::from_secs(5))?;
    // WAL: concurrent readers during a writer (async handlers + watchdog).
    let _ = conn.pragma_update(None, "journal_mode", "WAL");
    conn.execute_batch(
        "CREATE TABLE IF NOT EXISTS messages (
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            ts TEXT NOT NULL,
            sender TEXT NOT NULL,
            recipient TEXT NOT NULL,
            lane TEXT,
            kind TEXT NOT NULL,
            body TEXT NOT NULL,
            consumed_at TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_inbox ON messages(recipient, consumed_at);",
    )?;
    Ok(conn)
}

fn row_json(r: &rusqlite::Row) -> rusqlite::Result<Value> {
    Ok(json!({
        "id": r.get::<_, i64>(0)?,
        "ts": r.get::<_, String>(1)?,
        "sender": r.get::<_, String>(2)?,
        "recipient": r.get::<_, String>(3)?,
        "lane": r.get::<_, Option<String>>(4)?,
        "kind": r.get::<_, String>(5)?,
        "body": r.get::<_, String>(6)?,
        "consumed_at": r.get::<_, Option<String>>(7)?,
    }))
}

pub fn inbox(conn: &Connection, agent: &str, include_consumed: bool) -> rusqlite::Result<Vec<Value>> {
    let sql = if include_consumed {
        "SELECT id, ts, sender, recipient, lane, kind, body, consumed_at FROM messages
         WHERE recipient = ?1 ORDER BY id"
    } else {
        "SELECT id, ts, sender, recipient, lane, kind, body, consumed_at FROM messages
         WHERE recipient = ?1 AND consumed_at IS NULL ORDER BY id"
    };
    let mut stmt = conn.prepare(sql)?;
    let rows = stmt.query_map([agent], |r| row_json(r))?;
    rows.collect()
}

pub fn req_str(args: &Value, key: &str) -> Result<String, String> {
    args.get(key)
        .and_then(|v| v.as_str())
        .map(|s| s.trim().to_string())
        .filter(|s| !s.is_empty())
        .ok_or_else(|| format!("missing required string argument: {key}"))
}

// ── Retention ───────────────────────────────────────────────────────────────
// Consumed rows are history, not state: the audit stream already carries the
// lifecycle, so the queue only needs them long enough for forensics. ISO
// second-precision strings compare lexicographically in timestamp order, so
// the cutoff is a plain string comparison.
pub fn prune_consumed(retain_days: u64) -> Result<usize, String> {
    let now = SystemTime::now().duration_since(UNIX_EPOCH).map_err(|e| e.to_string())?.as_secs();
    let cutoff = fmt_iso(now.saturating_sub(retain_days.saturating_mul(86_400)));
    let conn = open_db().map_err(|e| e.to_string())?;
    conn.execute(
        "DELETE FROM messages WHERE consumed_at IS NOT NULL AND consumed_at < ?1",
        rusqlite::params![cutoff],
    )
    .map_err(|e| e.to_string())
}

// ── Observability streams ───────────────────────────────────────────────────

pub fn obs_dir() -> std::path::PathBuf {
    std::path::Path::new(&db_path())
        .parent()
        .map(|p| p.to_path_buf())
        .unwrap_or_else(|| std::path::PathBuf::from("."))
}

fn cfg_path() -> std::path::PathBuf {
    obs_dir().join("relay-observability.json")
}

pub fn cfg_path_string() -> String {
    cfg_path().to_string_lossy().into_owned()
}

/// Effective on/off for a stream. Precedence: env override, then the config
/// file a runtime toggle writes, then the compiled default.
pub fn stream_enabled(stream: &str) -> bool {
    let env_key = format!("ORG_RELAY_{}", stream.to_uppercase());
    if let Ok(v) = std::env::var(&env_key) {
        let v = v.trim().to_ascii_lowercase();
        return matches!(v.as_str(), "1" | "on" | "true" | "yes");
    }
    if let Ok(txt) = std::fs::read_to_string(cfg_path()) {
        if let Ok(cfg) = serde_json::from_str::<Value>(&txt) {
            if let Some(b) = cfg.get(stream).and_then(|v| v.as_bool()) {
                return b;
            }
        }
    }
    match stream {
        "audit" => AUDIT_DEFAULT_ON,
        "access" => ACCESS_DEFAULT_ON,
        // Cheap, bounded, and the only record of turn-starter activity: ON.
        "nudge" => true,
        _ => false,
    }
}

pub fn set_stream(stream: &str, enabled: bool) -> Result<(), String> {
    let p = cfg_path();
    let mut cfg: Value = std::fs::read_to_string(&p)
        .ok()
        .and_then(|t| serde_json::from_str(&t).ok())
        .unwrap_or_else(|| json!({}));
    cfg[stream] = json!(enabled);
    if let Some(d) = p.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    std::fs::write(&p, cfg.to_string()).map_err(|e| e.to_string())
}

/// Append one JSONL record, rotating at MAX_LOG_BYTES. Never fails a tool
/// call: observability that can break the bus is worse than no observability.
pub fn log_event(stream: &str, mut ev: Value) {
    if !stream_enabled(stream) {
        return;
    }
    let path = obs_dir().join(format!("{stream}.jsonl"));
    if let Ok(md) = std::fs::metadata(&path) {
        if md.len() >= MAX_LOG_BYTES {
            for i in (1..=MAX_BACKUPS).rev() {
                let _ = std::fs::rename(
                    obs_dir().join(format!("{stream}.jsonl.{i}")),
                    obs_dir().join(format!("{stream}.jsonl.{}", i + 1)),
                );
            }
            let _ = std::fs::rename(&path, obs_dir().join(format!("{stream}.jsonl.1")));
        }
    }
    if let Some(o) = ev.as_object_mut() {
        o.insert("ts".into(), json!(now_iso()));
    }
    if let Some(d) = path.parent() {
        let _ = std::fs::create_dir_all(d);
    }
    use std::io::Write;
    if let Ok(mut f) = std::fs::OpenOptions::new().create(true).append(true).open(&path) {
        let _ = writeln!(f, "{ev}");
    }
}

pub fn tail_stream(stream: &str, limit: usize) -> Vec<Value> {
    let path = obs_dir().join(format!("{stream}.jsonl"));
    let txt = std::fs::read_to_string(path).unwrap_or_default();
    let lines: Vec<&str> = txt.lines().filter(|l| !l.trim().is_empty()).collect();
    lines
        .iter()
        .rev()
        .take(limit)
        .rev()
        .filter_map(|l| serde_json::from_str::<Value>(l).ok())
        .collect()
}

/// Milliseconds since an ISO-8601 second-precision stamp this server wrote.
pub fn age_ms_since(ts: &str) -> Option<i64> {
    let p: Vec<&str> = ts.trim_end_matches('Z').split(['-', 'T', ':']).collect();
    if p.len() < 6 {
        return None;
    }
    let n = |i: usize| p[i].parse::<i64>().ok();
    let (y, mo, d, h, mi, s) = (n(0)?, n(1)?, n(2)?, n(3)?, n(4)?, n(5)?);
    // days-from-civil (Howard Hinnant's algorithm), valid for any Gregorian date.
    let yy = if mo <= 2 { y - 1 } else { y };
    let era = if yy >= 0 { yy } else { yy - 399 } / 400;
    let yoe = yy - era * 400;
    let mp = (mo + 9) % 12;
    let doy = (153 * mp + 2) / 5 + d - 1;
    let doe = yoe * 365 + yoe / 4 - yoe / 100 + doy;
    let days = era * 146_097 + doe - 719_468;
    let then = days * 86400 + h * 3600 + mi * 60 + s;
    let now = SystemTime::now().duration_since(UNIX_EPOCH).ok()?.as_secs() as i64;
    Some((now - then) * 1000)
}

// ── Synchronous tool operations (everything except the await) ───────────────
// Called from server.rs via spawn_blocking; Ok(payload) or Err(message).

pub fn op_sync(name: &str, args: &Value) -> Result<Value, String> {
    let conn = open_db().map_err(|e| format!("db open failed: {e}"))?;
    match name {
        "relay_send" => {
            let sender = req_str(args, "sender")?;
            let to = req_str(args, "to")?;
            let kind = req_str(args, "kind")?;
            let body = req_str(args, "body")?;
            let lane = args.get("lane").and_then(|v| v.as_str()).map(str::to_string);
            conn.execute(
                "INSERT INTO messages (ts, sender, recipient, lane, kind, body) VALUES (?1,?2,?3,?4,?5,?6)",
                rusqlite::params![now_iso(), sender, to, lane, kind, body],
            )
            .map_err(|e| e.to_string())?;
            let id = conn.last_insert_rowid();
            log_event("audit", json!({"event":"send","id":id,"sender":sender,"recipient":to,
                "lane":lane,"kind":kind,"body_bytes":body.len()}));
            notify_recipient(&to);
            Ok(json!({"id": id, "queued_for": to}))
        }
        "relay_inbox" => {
            let agent = req_str(args, "agent")?;
            let all = args.get("include_consumed").and_then(|v| v.as_bool()).unwrap_or(false);
            let msgs = inbox(&conn, &agent, all).map_err(|e| e.to_string())?;
            Ok(json!({"agent": agent, "count": msgs.len(), "messages": msgs}))
        }
        "relay_consume" => {
            let agent = req_str(args, "agent")?;
            let ids: Vec<i64> = args
                .get("ids")
                .and_then(|v| v.as_array())
                .map(|a| a.iter().filter_map(|v| v.as_i64()).collect())
                .unwrap_or_default();
            if ids.is_empty() {
                return Err("ids must be a non-empty array of message ids".into());
            }
            let mut n = 0usize;
            for id in &ids {
                n += conn
                    .execute(
                        "UPDATE messages SET consumed_at = ?1 WHERE id = ?2 AND recipient = ?3 AND consumed_at IS NULL",
                        rusqlite::params![now_iso(), id, agent],
                    )
                    .map_err(|e| e.to_string())?;
            }
            log_event("audit", json!({"event":"consume","agent":agent,"ids":ids,
                "consumed":n,"requested":ids.len()}));
            Ok(json!({"consumed": n, "of": ids.len()}))
        }
        "relay_status" => {
            let mut stmt = conn
                .prepare(
                    "SELECT recipient, COUNT(*) FROM messages WHERE consumed_at IS NULL GROUP BY recipient",
                )
                .map_err(|e| e.to_string())?;
            let rows: Vec<Value> = stmt
                .query_map([], |r| {
                    Ok(json!({"recipient": r.get::<_, String>(0)?, "unconsumed": r.get::<_, i64>(1)?}))
                })
                .map_err(|e| e.to_string())?
                .filter_map(Result::ok)
                .collect();
            Ok(json!({"db": db_path(), "queues": rows, "awaiting": awaiting_names(),
                      "awaiting_detail": awaiting_detail(),
                      "nudge": {"enabled": crate::nudge::nudge_enabled(),
                                "helper": crate::nudge::nudge_helper().map(|p| p.to_string_lossy().into_owned())}}))
        }
        "relay_audit_tail" => {
            let stream = args.get("stream").and_then(|v| v.as_str()).unwrap_or("audit").to_string();
            if stream != "audit" && stream != "access" && stream != "nudge" {
                return Err("stream must be \"audit\", \"access\", or \"nudge\"".into());
            }
            let limit = args.get("limit").and_then(|v| v.as_u64()).unwrap_or(50).clamp(1, 1000) as usize;
            let ev = tail_stream(&stream, limit);
            Ok(json!({"stream": stream, "enabled": stream_enabled(&stream),
                      "count": ev.len(), "events": ev}))
        }
        "relay_observability_set" => {
            let stream = req_str(args, "stream")?;
            if stream != "audit" && stream != "access" && stream != "nudge" {
                return Err("stream must be \"audit\", \"access\", or \"nudge\"".into());
            }
            let enabled = args.get("enabled").and_then(|v| v.as_bool())
                .ok_or("enabled must be a boolean")?;
            set_stream(&stream, enabled)?;
            Ok(json!({"stream": stream, "enabled": stream_enabled(&stream),
                      "config": cfg_path_string(),
                      "note": "an ORG_RELAY_<STREAM> env var, if set, overrides this file"}))
        }
        "relay_observability_status" => {
            let f = |s: &str| json!({"enabled": stream_enabled(s),
                "path": obs_dir().join(format!("{s}.jsonl")).to_string_lossy(),
                "bytes": std::fs::metadata(obs_dir().join(format!("{s}.jsonl"))).map(|m| m.len()).unwrap_or(0)});
            Ok(json!({"audit": f("audit"), "access": f("access"), "nudge": f("nudge"),
                      "config": cfg_path_string(),
                      "max_log_bytes": MAX_LOG_BYTES, "max_backups": MAX_BACKUPS}))
        }
        other => Err(format!("unknown tool: {other}")),
    }
}

/// The await: hold until a message lands for `agent`, a timeout passes, or the
/// caller goes away. Runs as an in-call hold (`direct_cover: true` — the
/// AwaitGuard held here registers coverage) or as the future backing a task
/// (`direct_cover: false` — the caller holds a TaskCoverGuard keyed by task
/// id, so coverage tracks tasks/get poll liveness instead of this future's
/// mere existence).
pub async fn op_await(args: &Value, direct_cover: bool) -> Result<Value, String> {
    let agent = req_str(args, "agent")?;
    let timeout_s = args
        .get("timeout_s")
        .and_then(|v| v.as_u64())
        .unwrap_or(AWAIT_DEFAULT_S)
        .clamp(1, AWAIT_MAX_S);
    let _guard = direct_cover.then(|| AwaitGuard::new(&agent));
    log_event("audit", json!({"event":"await_start","agent":agent,"timeout_s":timeout_s,
        "mode": if direct_cover { "hold" } else { "task" }}));
    let notify = notifier_for(&agent);
    let started = Instant::now();
    let deadline = started + Duration::from_secs(timeout_s);
    loop {
        // Arm the listener BEFORE the poll so a send landing between the poll
        // and the select cannot be missed (notified() buffers one permit).
        let notified = notify.notified();
        let a = agent.clone();
        let msgs = tokio::task::spawn_blocking(move || -> Result<Vec<Value>, String> {
            let c = open_db().map_err(|e| format!("db open failed: {e}"))?;
            inbox(&c, &a, false).map_err(|e| e.to_string())
        })
        .await
        .map_err(|e| format!("await poll task failed: {e}"))??;
        if !msgs.is_empty() {
            // Wake LATENCY: how long this agent was covered, and how old the
            // oldest delivered message was.
            let oldest_age = msgs.first()
                .and_then(|m| m.get("ts")).and_then(|v| v.as_str())
                .and_then(age_ms_since);
            log_event("audit", json!({"event":"await_wake","agent":agent,
                "waited_ms":started.elapsed().as_millis() as u64,
                "count":msgs.len(),
                "ids": msgs.iter().filter_map(|m| m.get("id").cloned()).collect::<Vec<_>>(),
                "oldest_msg_age_ms": oldest_age}));
            return Ok(json!({
                "agent": agent, "count": msgs.len(), "messages": msgs,
                "note": "messages are NOT auto-consumed; act, then relay_consume the ids"
            }));
        }
        let now = Instant::now();
        if now >= deadline {
            log_event("audit", json!({"event":"await_timeout","agent":agent,
                "waited_ms":started.elapsed().as_millis() as u64,"timeout_s":timeout_s}));
            return Ok(json!({"agent": agent, "count": 0, "messages": [],
                "timed_out": true, "retry": true,
                "note": "no messages within timeout_s; re-arm one long relay_await as the last call of this turn"}));
        }
        let poll_in = std::cmp::min(deadline - now, Duration::from_secs(2));
        tokio::select! {
            _ = notified => {}
            _ = tokio::time::sleep(poll_in) => {}
        }
    }
}

/// Shared serialization lock for tests that touch the process-global
/// live-agent snapshot. A fresh `Some(...)` snapshot makes every name outside
/// it read as dead (LIVE_SNAPSHOT_FRESH_S = 90s), so any test reading
/// `awaiter_active` must hold this while a snapshot-setting test runs, or it
/// flakes on the interleave. Crate-visible so nudge.rs tests share the one lock.
#[cfg(test)]
pub(crate) fn snapshot_lock() -> &'static Mutex<()> {
    static L: OnceLock<Mutex<()>> = OnceLock::new();
    L.get_or_init(|| Mutex::new(()))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn await_guard_registers_and_clears() {
        let _serial = snapshot_lock().lock().unwrap();
        set_live_agents(None);
        assert!(!awaiter_active("guard-test"));
        {
            let _g = AwaitGuard::new("guard-test");
            assert!(awaiter_active("guard-test"));
            {
                let _h = AwaitGuard::new("guard-test");
            }
            assert!(awaiter_active("guard-test"));
        }
        assert!(!awaiter_active("guard-test"));
    }

    #[test]
    fn task_cover_tracks_poll_liveness() {
        let _serial = snapshot_lock().lock().unwrap();
        set_live_agents(None);
        assert!(!awaiter_active("task-agent"));
        {
            let _c = TaskCoverGuard::new("task-1", "task-agent");
            assert!(awaiter_active("task-agent"), "fresh task cover counts");
            assert!(awaiting_names().contains(&"task-agent".to_string()));
            touch_task_cover("task-1");
            assert!(awaiter_active("task-agent"), "touched cover still counts");
        }
        assert!(!awaiter_active("task-agent"), "dropped cover deregisters");
    }

    // (snapshot_lock is defined at module scope above so nudge.rs tests,
    // which also read the live-agent snapshot, can share the same lock.)

    #[test]
    fn ghost_filter_drops_dead_names_and_never_filters_without_evidence() {
        let _serial = snapshot_lock().lock().unwrap();
        let _g = AwaitGuard::new("ghost-filter-probe");
        // No snapshot: no evidence, coverage stands.
        set_live_agents(None);
        assert!(awaiter_active("ghost-filter-probe"), "no snapshot must not filter");
        assert!(awaiting_names().contains(&"ghost-filter-probe".to_string()));
        // Fresh snapshot without the name: provably dead, filtered everywhere.
        let mut s = std::collections::HashSet::new();
        s.insert("someone-else".to_string());
        set_live_agents(Some(s));
        assert!(!awaiter_active("ghost-filter-probe"), "dead name must not count as coverage");
        assert!(!awaiting_names().contains(&"ghost-filter-probe".to_string()));
        let detail = awaiting_detail();
        let row = detail.iter().find(|r| r["agent"] == "ghost-filter-probe")
            .expect("detail keeps the ghost for forensics");
        assert_eq!(row["agent_live"], false);
        // Fresh snapshot WITH the name: coverage restored.
        let mut s = std::collections::HashSet::new();
        s.insert("ghost-filter-probe".to_string());
        set_live_agents(Some(s));
        assert!(awaiter_active("ghost-filter-probe"));
        // Clear so parallel tests never see a filtering snapshot.
        set_live_agents(None);
    }
}
