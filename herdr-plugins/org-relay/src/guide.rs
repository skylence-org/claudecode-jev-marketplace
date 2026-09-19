//! The relay://guide resource, server instructions, and the guide gate's
//! pinned refusal text. Pattern follows binary-skyline's guide gate (#214):
//! messaging tools refuse in-band until the session has read the guide; the
//! refusal mutates no state, so an identical retry after the read succeeds.
//! The guide is the wake-plane CONTRACT — a session that skips it re-creates
//! the deaf-org stall the 2026-08-04 forensics measured (5 messages
//! unconsumed for 3h23m), so the gate is load-bearing, not ceremony.

pub const GUIDE_URI: &str = "relay://guide";

/// Sent in `initialize` as the server's instructions field.
pub const SERVER_INSTRUCTIONS: &str = "Read relay://guide (resources/read, or the relay_guide tool) BEFORE using the messaging tools — relay_send / relay_inbox / relay_consume / relay_await refuse until this session has read it (enforced on sessionful transports; a stateless SEP-2567 client is trusted to read it first); relay_status and the observability tools are never gated. The guide is the org's wake-plane contract: task-backed awaiting (arm ONE long relay_await as the LAST call of a turn; never a 50s re-arm loop), inbox-first turn entry, consume ONLY after acting, and what a [RELAY-NUDGE] means. The gate is per-session by design — every session reads the contract once; it is short on purpose.";

pub const GUIDE_RESOURCE: &str = r#"# org-relay guide — the org's message bus and wake plane

One durable SQLite queue for every org on this box. Messages are
{sender, to, lane, kind, body}; delivery state is a single explicit
`consumed_at`. Recipients are BARE AGENT NAMES box-wide, so org-distinct
names (orch-<feature>, not `orchestrator`) are what keep peer orgs' mail
apart.

## The wake model (task-backed awaiting)

`relay_await(agent=<you>, timeout_s=1800)` is armed as the LAST tool call of
a turn, once, with a LONG timeout. What happens next depends on your client:

- Client with the MCP tasks extension (`io.modelcontextprotocol/tasks`,
  SEP-2663): the call returns a TASK HANDLE immediately (`resultType:
  "task"`). Your turn is free the moment you call it; poll `tasks/get` or let
  your harness surface the completion.
- Claude Code >= 2.1.212 (no tasks extension yet): the call holds in-turn for
  about 2 minutes, then the harness AUTO-BACKGROUNDS it into a native
  background task — your turn ends, the operator's composer is free, and the
  result arrives later as a task notification that starts your next turn.

Either way: ONE await covers you for the whole idle period. The pre-1.0
doctrine of 50-second re-arm loops is RETIRED — it existed for a transport
whose silent holds clients aborted at ~60s. Do not re-create it. A timeout
returns cleanly with `retry: true`: re-arm ONE new long await, as the last
call of that turn.

Rules that keep the org deaf-proof:

1. ARM AS LAST CALL. An await armed mid-turn blocks the rest of your beat
   for up to 2 minutes. Do your work first; arm coverage as the final call
   before the turn would otherwise end.
2. INBOX FIRST ON TURN ENTRY. Whatever started this turn — an await result,
   a [RELAY-NUDGE], an operator message — while any lane is in flight your
   first bus action is relay_inbox(agent=<you>): interrupts kill turns,
   never queues, and this check re-finds what a killed turn was about to
   handle.
3. CONSUME ONLY AFTER ACTING. relay_consume marks ids handled. A crash
   between reading and acting must lose nothing; consumed-but-unacted is the
   one state the queue cannot protect you from.
4. ENQUEUE IS NOT DELIVERY. relay_send returning {"id":N} means durably
   queued, not read. The recipient's await (or the nudge net) is what turns
   it into a mind reading it.

## The nudge net (last resort, not the primary)

The daemon polls its own queue (~20s). A recipient with unconsumed messages
older than ~90s, NO live await covering it (in-call or task-backed — both
register), and no recent consume gets a short composer ring:

  [RELAY-NUDGE] unconsumed relay messages are queued for you. ...

A nudge is content-free and idempotent: run relay_inbox, act, consume. It is
the net for sessions whose await died (crash, operator interrupt during the
pre-background window, expired timeout never re-armed) — with a live await
armed you will never see one.

## Native pings (a WAKE accelerator, not the record)

Claude sessions on this box can also reach each other with the client's own
SendMessage / ListAgents tools (Claude Code >= 2.1.224): a message starts a
turn in an idle peer with zero keystrokes. The org uses this ON TOP of the
queue, never instead of it:

- The QUEUE stays the record. relay_send is what is durable, audited, and
  consumable; a ping carries only a pointer ("doorbell queued: board get
  <slug>") and the recipient acts from relay_inbox, never from ping text.
- A ping is the coverage-gap wake. With a live relay_await armed you are
  already covered and need no ping; it helps a peer whose await lapsed, doing
  the nudge net's job without the composer.
- Pings are Claude-only and undurable: names auto-derive from a session's cwd
  (resolve from a fresh ListAgents row), first contact needs the row's
  "[ref]", and a non-Claude producer cannot deliver one. Everything the queue
  guarantees, a ping does not.

## Tools

- relay_send(sender, to, kind, body, lane?) — durable enqueue + in-process
  wake of any live awaiter. kind: doorbell | ring | blocker | incident |
  peer | operator | other.
- relay_inbox(agent, include_consumed?) — list queued messages.
- relay_consume(agent, ids) — mark handled AFTER acting.
- relay_await(agent, timeout_s?) — task-backed coverage; see the wake model.
- relay_status() — queues per recipient + `awaiting` (live coverage) +
  nudge state. Non-empty queues with empty awaiting = deaf org, right now.
- relay_guide() — this text; reading it (or the relay://guide resource)
  unlocks the messaging tools for this session.
- relay_audit_tail(stream?, limit?) — audit = message lifecycle with wake
  latency; access = per-call records; nudge = watchdog outcomes.
- relay_observability_set/status — stream toggles (audit ON, access OFF,
  nudge ON by default).

## Environment

ORG_RELAY_DB (db path; the launchd plist pins the box-wide default),
ORG_RELAY_PORT (7431), ORG_RELAY_NUDGE=0 (disable watchdog),
ORG_RELAY_NUDGE_HELPER (nudge-deliver override), ORG_RELAY_AUDIT/ACCESS/NUDGE
(stream overrides). Client side: raise CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT in
org pane shells so a held await is never idle-aborted before the harness
backgrounds it.
"#;

/// Refusal returned for any messaging-tool call before this session has read
/// relay://guide. Pinned verbatim by tests — change the text here and in the
/// test together, deliberately.
pub const GUIDE_GATE_REFUSAL: &str = "guide-gate: this session has not read relay://guide. Call relay_guide (or resources/read uri relay://guide; server name is usually `relay`), then retry this exact call. Why: the wake plane is task-backed now (ONE long relay_await armed as the LAST call of a turn — never a 50s re-arm loop), turn entry is inbox-first, and consume comes only after acting; using the bus without this contract re-creates the 3h23m deaf-org stall. (the gate is per-session and in-memory by design — every session, and every reconnect, reads the short guide once)";

/// Stable content hash of the guide (FNV-1a 64), surfaced for cache-busting
/// and drift checks. The gate itself is per-session and in-memory — there is
/// no persisted ack ledger (that was removed pre-1.0), so a guide change just
/// means the next read serves new text, not a box-wide re-arm.
pub fn guide_hash() -> String {
    let mut h: u64 = 0xcbf2_9ce4_8422_2325;
    for b in GUIDE_RESOURCE.as_bytes() {
        h ^= *b as u64;
        h = h.wrapping_mul(0x0000_0100_0000_01b3);
    }
    format!("{h:016x}")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn guide_hash_is_stable_and_content_bound() {
        assert_eq!(guide_hash(), guide_hash());
        assert_eq!(guide_hash().len(), 16);
    }

    #[test]
    fn guide_names_the_load_bearing_clauses() {
        for phrase in [
            "LAST tool call",
            "task-backed",
            "AUTO-BACKGROUNDS",
            "retry: true",
            "INBOX FIRST",
            "CONSUME ONLY AFTER ACTING",
            "[RELAY-NUDGE]",
            "WAKE accelerator",
            "SendMessage",
            "io.modelcontextprotocol/tasks",
        ] {
            assert!(GUIDE_RESOURCE.contains(phrase), "guide must contain {phrase:?}");
        }
    }
}
