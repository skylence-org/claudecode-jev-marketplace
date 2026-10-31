# org-relay — durable, task-backed MCP message bus for the herdr agent-org

Operator ruling 2026-08-03: the composer-paste channel (doorbell + waker ring)
is retired as the org's message path. Operator direction 2026-08-05: the
in-turn `relay_await` re-arm loop is retired with it — it occupied the
orchestrator's turn (operator prompts queued behind a listener that re-armed
every 50s) and still died with every turn end. The wake plane is TASK-DRIVEN
as of 1.0.

**Source of truth (1.5.0):** this directory, `herdr-plugins/org-relay` in
skylence-org/claudecode-jev-marketplace. The multi-llm-marketplace copy
stopped at 1.4.1 (commit 965ec72, 2026-09-19); this repo then changed the
crate (df40d17, `relay_send` live_await) under the same 1.4.1, so two
different builds carried one version. From 1.5.0 on, every change to `src/`
or `build.rs` bumps the crate version, and `tools/check-parity.sh` fails a
change that does not; it also keeps `Cargo.toml`, `Cargo.lock` and
`herdr-plugin.toml` on the same version.

**Install from this repo:** `cd herdr-plugins/org-relay && cargo build
--release && sh relay-ctl install-daemon`. install-daemon refuses a dirty
build, copies the binary to a versioned slot under
`~/.local/libexec/org-relay/`, repoints `current`, restarts launchd, and
verifies the served sha. Then `sh relay-ctl status`: its first line names
the build (`org-relay: build 1.5.0 sha <sha> built <ts> from <origin remote>
<source dir>`); the same `build` object is in `relay_status` and `GET
/status`. A daemon whose build has no `remote` predates 1.5.0.

**Design (settled):** data plane = SQLite queue — ONE box-wide db for every
org (`~/.config/herdr/org-relay/relay.db`, set as ORG_RELAY_DB by the launchd
plist; the `$HERDR_ORG_ROOT/relay.db` fallback only applies to ad-hoc runs
without that env), messages `{sender, to, lane, kind, body}`, explicit
consume. Wake plane = **task-backed `relay_await`**, armed once with a LONG
timeout as the LAST call of a turn — and ONLY while a message is expected; an
idle role arms nothing and is woken by a native ping or the nudge net:

- A client declaring the MCP tasks extension (`io.modelcontextprotocol/tasks`,
  SEP-2663) gets a **task handle back immediately** (`resultType: "task"`,
  rmcp `task_manager`) and polls `tasks/get`; the hold runs server-side.
- Claude Code >= 2.1.212 (no tasks extension yet) holds the call in-turn for
  ~2 minutes, then its harness **auto-backgrounds** it into a native
  background task: the turn ends, the operator's composer answers instantly,
  and the settled task starts the recipient's next turn.
- Either hold registers the recipient in the **awaiter registry**, which is
  what `relay_status.awaiting` reports and what suppresses the nudge.

Default `timeout_s` 1800 (max 3600); a timeout returns cleanly with
`retry: true` — one re-arm per wake while a message is still expected, never
a loop. In-process `Notify` wakes a live awaiter the instant `relay_send`
commits; a 2s poll covers writers that bypass the daemon. `relay_send` returns
`{id, queued_for, live_await}`: `live_await` is the awaiter registry's answer
at commit time; a sender that stays awake pings once only when it is false (or
absent: an older daemon), a sender whose turn ends with the send (a worker's
doorbell) pings once regardless.

**Guide gate (1.0):** `relay_send / relay_inbox / relay_consume / relay_await`
refuse until the session reads `relay://guide` (resources/read, or the
`relay_guide` tool — both unlock). The guide IS the wake-plane contract
(arm-as-last-call, inbox-first turn entry, consume-after-acting, nudge
semantics); the refusal names the step. The gate is strictly PER-SESSION and
in-memory, on purpose: the only durable key available (clientInfo
name/version) is shared by every session of the same client build, so a
persisted ack would let the first reader unlock the bus for sessions that
never saw the contract. Every session — and every transport reconnect —
reads the short guide once. `relay_status` and the observability tools are
never gated.

**Nudge watchdog (0.5.0, demoted to LAST RESORT by 1.0):** coverage can still
die — an operator Esc inside the pre-background window, a timed-out task
nobody re-armed, a crash. The daemon polls its own queue (~20s): a recipient
with unconsumed messages older than ~90s, no live await coverage (in-call and
task-backed holds both register), and no consume inside the grace window gets
a short, content-free composer ring via `nudge-deliver` (composer-guarded
classify / verify / empty-submit recover). Per-recipient cooldown ~5 min
(~20 min once a recipient has no live herdr agent). Outcomes land on the
`nudge` stream. Env: `ORG_RELAY_NUDGE=0` disables; `ORG_RELAY_NUDGE_HELPER`
overrides the helper path.

**Transport (1.0):** rmcp 3.1 streamable HTTP behind axum — the same stack
binary-skyline ships (`sky-binaries/binary-skyline/src/mcp_server.rs` is the
reference). Sessions are real (LocalSessionManager, one `RelayServer` per
session carrying the gate state). Plain mirrors for CLI/hook consumers that
should not need an MCP handshake: `GET /health` ("ok") and `GET /status`
(the relay_status payload; `relay-ctl status` uses it). Wire an agent with
`claude mcp add --transport http relay http://127.0.0.1:7431/mcp`.

Client-side env worth exporting in org pane shells (Board bootstrap):
`CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` high enough that a held await is never
idle-aborted before the harness backgrounds it.

Tools: `relay_guide / relay_send / relay_inbox / relay_consume / relay_await /
relay_status / relay_stats`, plus `relay_audit_tail / relay_observability_set /
relay_observability_status` over the audit / access / nudge JSONL streams.

**1.5.0 additions:**

- `relay-ctl send --to <agent> --kind <kind> --body <text> [--sender <name>]
  [--lane <slug>]`: the same enqueue as `relay_send`, over POST /send, so a
  long job ends with `...; relay-ctl send --to <orch> --kind job --body "job
  <id> rc=$?"` and wakes its orchestrator. Never a short-timeout await as a
  timer.
- `relay_await(after_id=N)`: wake only for ids above N, so queued messages
  you cannot act on yet stay unconsumed (consume-after-acting holds) without
  the await returning at once. Chosen over a `relay_defer(ids, reason)` tool:
  stateless, no deadlines to expire, nothing for the nudge net to reconcile.
- `relay_status` per queue: `oldest_ts`, `oldest_age_s`, `awaiting`,
  `agent_live`, `last_seen_s` (in-memory, resets on restart), plus the
  daemon's `build`. Orphans are removed by the operator only:
  `relay-ctl purge --recipient <name> --older-than <N>s|m|h|d` lists, and
  deletes only with `--delete` (exactly the listed ids; audited).
- `relay_stats(agent?, since?)`: counts by kind, delivered vs consumed,
  send-to-deliver / send-to-consume seconds (n, median, max). Delivery is a
  new nullable `delivered_at` column (added on open when missing; a 1.4
  daemon on the same db is unaffected), stamped when relay_inbox or a waking
  relay_await first hands a row over.

Layout: `src/queue.rs` (data plane + awaiter and last-seen registries + stats),
`src/server.rs` (rmcp handler + guide gate + SEP-2663 tasks), `src/guide.rs`
(guide text + pinned refusal), `src/nudge.rs` (watchdog), `src/main.rs`
(axum serve + /health + /status + /send), `relay-ctl` (daemon control,
`send`, `purge`), `test/` (concurrency smoke, nudge classify, relay-ctl
send and purge suites).

Status: 1.5.0 — gate: `cargo test` and the concurrency smoke in the
org-relay CI job, plus the relay-ctl send and purge suites. History,
1.0.0 — compiled, `cargo test` green (gate transitions, pinned
refusal text, nudge predicate incl. task-backed suppression, guide hash,
tool-def deserialization), wire-smoked end to end (gate refusal → unlock →
send → task handle → tasks/get result → gate re-arms for a fresh session →
in-call timeout with retry:true). Deploy: `cargo build --release`, then re-run
`sh relay-ctl install-daemon` so launchd runs the 1.0 binary.
