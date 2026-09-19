//! Nudge watchdog (0.5.0 semantics, unchanged in 1.0): the daemon is the only
//! process that can see both sides of the deaf-org condition — unconsumed
//! backlog AND no live await covering its recipient — so it is the process
//! that breaks it. With the wake plane now task-backed the nudge is strictly
//! the NET: a covered recipient (in-call hold or task-backed hold; both
//! register in the awaiter registry) is never rung.

use std::collections::HashMap;
use std::time::{Duration, Instant};

use serde_json::json;

use crate::queue::{
    age_ms_since, awaiter_active, log_event, open_db, set_live_agents, NUDGE_COOLDOWN_S,
    NUDGE_GRACE_S, NUDGE_NOAGENT_COOLDOWN_S, NUDGE_POLL_S,
};

pub fn nudge_enabled() -> bool {
    match std::env::var("ORG_RELAY_NUDGE") {
        Ok(v) => !matches!(v.trim().to_ascii_lowercase().as_str(), "0" | "off" | "false" | "no"),
        Err(_) => true,
    }
}

/// The helper script that talks to herdr. Env override first; default is the
/// `nudge-deliver` sibling of this crate (the exe sits in target/<profile>/).
pub fn nudge_helper() -> Option<std::path::PathBuf> {
    if let Ok(p) = std::env::var("ORG_RELAY_NUDGE_HELPER") {
        let pb = std::path::PathBuf::from(p);
        return if pb.is_file() { Some(pb) } else { None };
    }
    let exe = std::env::current_exe().ok()?;
    let root = exe.parent()?.parent()?.parent()?;
    let pb = root.join("nudge-deliver");
    if pb.is_file() {
        Some(pb)
    } else {
        None
    }
}

/// Canonical nudge text. COUNT-FREE on purpose: deterministic per recipient,
/// so nudge-deliver can exact-match its own parked copy and recover it with an
/// empty submit; short enough that the '[Pasted text #N]' placeholder class

/// Live herdr agent names, one subprocess per watchdog tick. None when herdr
/// is missing or errors — the caller treats that as "cannot disprove
/// coverage" and leaves suppression intact.
fn live_agent_names() -> Option<std::collections::HashSet<String>> {
    let herdr = std::env::var("HERDR_BIN_PATH").unwrap_or_else(|_| "herdr".into());
    let out = std::process::Command::new(herdr).args(["agent", "list"]).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let v: serde_json::Value = serde_json::from_slice(&out.stdout).ok()?;
    Some(
        v["result"]["agents"]
            .as_array()?
            .iter()
            .filter_map(|a| a["name"].as_str().map(str::to_string))
            .collect(),
    )
}
/// from the waker era cannot appear.
pub fn nudge_text(agent: &str) -> String {
    format!("[RELAY-NUDGE] unconsumed relay messages are queued for you. Run relay_inbox(agent=\"{agent}\"), act on them, then relay_consume the handled ids.")
}

/// Pure nudge decision, unit-tested: backlog old enough, nobody awaiting, no
/// consume inside the grace window, per-recipient cooldown expired.
pub fn nudge_due(
    awaiting: bool,
    oldest_unconsumed_age_s: i64,
    last_consume_age_s: Option<i64>,
    since_last_nudge_s: Option<u64>,
    cooldown_s: u64,
) -> bool {
    if awaiting || oldest_unconsumed_age_s < NUDGE_GRACE_S {
        return false;
    }
    if last_consume_age_s.is_some_and(|a| a < NUDGE_GRACE_S) {
        return false;
    }
    !since_last_nudge_s.is_some_and(|s| s < cooldown_s)
}

fn deliver_nudge(helper: &std::path::Path, recipient: &str) -> String {
    match std::process::Command::new("/bin/sh")
        .arg(helper)
        .arg(recipient)
        .arg(nudge_text(recipient))
        .output()
    {
        Ok(out) => String::from_utf8_lossy(&out.stdout)
            .lines()
            .rev()
            .find(|l| !l.trim().is_empty())
            .map(|l| l.trim().to_string())
            .unwrap_or_else(|| format!("helper-exit-{}", out.status.code().unwrap_or(-1))),
        Err(e) => format!("helper-spawn-failed:{e}"),
    }
}

fn nudge_tick(helper: &std::path::Path, last: &mut HashMap<String, (Instant, String)>) -> Result<(), String> {
    let conn = open_db().map_err(|e| e.to_string())?;
    let mut stmt = conn
        .prepare(
            "SELECT recipient,
                    COUNT(*) FILTER (WHERE consumed_at IS NULL),
                    MIN(ts) FILTER (WHERE consumed_at IS NULL),
                    MAX(consumed_at)
             FROM messages GROUP BY recipient
             HAVING COUNT(*) FILTER (WHERE consumed_at IS NULL) > 0",
        )
        .map_err(|e| e.to_string())?;
    let rows: Vec<(String, i64, Option<String>, Option<String>)> = stmt
        .query_map([], |r| Ok((r.get(0)?, r.get(1)?, r.get(2)?, r.get(3)?)))
        .map_err(|e| e.to_string())?
        .filter_map(Result::ok)
        .collect();
    drop(stmt);
    drop(conn);
    // GHOST-BUSTER (measured 2026-08-05): a hold whose client died keeps its
    // name registered until timeout, and neither disconnects nor failed sends
    // are observable from inside the handler. Publish herdr's live-agent view
    // each tick; awaiter_active (and every other coverage view) then filters
    // holds whose agent is provably gone. Herdr unreachable ⇒ snapshot
    // cleared ⇒ coverage trusted as-is (fail-quiet, never nudge-spam).
    set_live_agents(live_agent_names());
    for (recipient, unconsumed, oldest_ts, last_consume) in rows {
        let oldest_age_s = oldest_ts.as_deref().and_then(age_ms_since).map(|ms| ms / 1000).unwrap_or(0);
        let consume_age_s = last_consume.as_deref().and_then(age_ms_since).map(|ms| ms / 1000);
        let cooldown = match last.get(&recipient) {
            Some((_, o)) if o == "no-agent" => NUDGE_NOAGENT_COOLDOWN_S,
            _ => NUDGE_COOLDOWN_S,
        };
        let since = last.get(&recipient).map(|(t, _)| t.elapsed().as_secs());
        if !nudge_due(awaiter_active(&recipient), oldest_age_s, consume_age_s, since, cooldown) {
            continue;
        }
        let outcome = deliver_nudge(helper, &recipient);
        log_event("nudge", json!({"event": "nudge", "recipient": recipient, "outcome": outcome,
            "unconsumed": unconsumed, "oldest_unconsumed_age_s": oldest_age_s}));
        last.insert(recipient, (Instant::now(), outcome));
    }
    Ok(())
}

pub fn spawn_nudge_watchdog(helper: std::path::PathBuf) {
    std::thread::spawn(move || {
        let mut last: HashMap<String, (Instant, String)> = HashMap::new();
        loop {
            std::thread::sleep(Duration::from_secs(NUDGE_POLL_S));
            if let Err(e) = nudge_tick(&helper, &mut last) {
                log_event("nudge", json!({"event": "tick-error", "error": e}));
            }
        }
    });
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::queue::AwaitGuard;

    #[test]
    fn nudge_waits_for_grace() {
        assert!(!nudge_due(false, NUDGE_GRACE_S - 1, None, None, NUDGE_COOLDOWN_S));
        assert!(nudge_due(false, NUDGE_GRACE_S, None, None, NUDGE_COOLDOWN_S));
    }

    #[test]
    fn active_awaiter_suppresses() {
        assert!(!nudge_due(true, 10_000, None, None, NUDGE_COOLDOWN_S));
    }

    #[test]
    fn task_backed_awaiter_suppresses_via_registry() {
        // A task-backed hold registers exactly like an in-call hold; the
        // watchdog cannot tell them apart, by design. Shares the snapshot lock
        // because awaiter_active reads the process-global live-agent snapshot.
        let _serial = crate::queue::snapshot_lock().lock().unwrap();
        set_live_agents(None);
        let _g = AwaitGuard::new("task-held");
        assert!(!nudge_due(awaiter_active("task-held"), 10_000, None, None, NUDGE_COOLDOWN_S));
    }

    #[test]
    fn recent_consume_suppresses() {
        assert!(!nudge_due(false, 10_000, Some(NUDGE_GRACE_S - 1), None, NUDGE_COOLDOWN_S));
        assert!(nudge_due(false, 10_000, Some(NUDGE_GRACE_S), None, NUDGE_COOLDOWN_S));
    }

    #[test]
    fn cooldown_suppresses() {
        assert!(!nudge_due(false, 10_000, None, Some(NUDGE_COOLDOWN_S - 1), NUDGE_COOLDOWN_S));
        assert!(nudge_due(false, 10_000, None, Some(NUDGE_COOLDOWN_S), NUDGE_COOLDOWN_S));
    }

    #[test]
    fn nudge_text_is_deterministic_and_short() {
        let t = nudge_text("orch-x");
        assert_eq!(t, nudge_text("orch-x"));
        assert!(t.len() < 200, "stay under the paste-placeholder threshold");
        assert!(t.starts_with("[RELAY-NUDGE] "));
    }
}
