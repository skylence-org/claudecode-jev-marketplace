---
name: herdr-setup
description: 'One-shot playbook to bootstrap a fresh macOS box from "herdr installed" to "org-ready": preflight, org-relay message-bus wiring (daemon + claude MCP connection), native session-ping wiring (SendMessage/ListAgents, S2c), legacy org-waker wiring, optional ActivityWatch context (aw-context install + category sync), board bootstrap, ecosystem plugin picks, and an end-to-end verification checklist. Invoke when the operator says "set up herdr for the org".'
---

# Herdr org bootstrap (one-shot)

Run S1 through S5 in order, once per box. It takes a machine from "herdr is installed" to "an orchestrator can dispatch workers and get woken on their settle." Every command below is copy-paste-exact.

## S1 Preflight

```bash
herdr --version
```
This skill was authored and measured against **0.7.5**. Anything older is unverified for the `agent start` / `wait` / `prompt` semantics the org depends on; treat a lower version as a stop-and-upgrade, not a "probably fine."

```bash
herdr agent start --help
```
Read the `--kind` possible-values list. It must include both `claude` and `grok`, the two runtimes this org dispatches (`herdr-agent-org-claude` / `herdr-agent-org-grok`). Missing either means that plugin variant has nothing to start against on this box; reinstall or upgrade herdr.

```bash
command -v jq && jq --version
command -v gh && gh --version
```
`jq` is required by `dispatch-worker` (parses Herdr JSON for pane splits, agent status, and the summary payload) and by the org-waker plugin script itself (`herdr-plugins/org-waker/waker`, plus its test suites). `board` and `waker-ctl` do not call jq. `gh` opens and inspects PRs (workers open, never merge; L14). Either missing: install it (`brew install jq gh` on macOS) before continuing; nothing downstream degrades gracefully without them.

## S2 Org-relay wiring (the message bus — do this FIRST of the two)

The org-relay is the org's message path (relay doctrine, 2026-08-03): a durable
SQLite queue + long-poll MCP server on `127.0.0.1:7431`, supervised by launchd.
The waker in S2b remains only as legacy/crash tooling for pre-relay lanes.

Pick ONE, matching the box:

**Dev box** (repo checked out): confirm the checkout still exists BEFORE linking. A prior `plugin link` can point at a path a later reorg deleted or renamed; when that happens `herdr plugin list` keeps showing the plugin "enabled" with a silent `manifest unavailable` warning, and its launchd daemon keeps running against the dead path with NO error surfaced — `launchctl print` shows `spawn scheduled`, not a crash (measured 2026-08-16: the checkout was gone, the daemon looked supervised, nothing complained until `relay-ctl status` was run by hand). Check first:
```bash
herdr plugin list | grep -A1 org-relay      # "manifest unavailable" = checkout is gone
ls -d <abs-path-to-repo>/herdr-plugins/org-relay
```
If the checkout is gone, re-clone it to the same path before linking. Then: `herdr plugin link <abs-path-to-repo>/herdr-plugins/org-relay`

**Consumer box:** `herdr plugin install skylence-be/multi-llm-marketplace/herdr-plugins/org-relay --yes`

Then daemonize and wire the client, from the installed plugin dir (`herdr plugin list` prints it; `relay-ctl` needs `cargo` on PATH for the first build):

```bash
sh <plugin-dir>/relay-ctl install-daemon
```
What that does as of 1.3: builds if needed, REFUSES a binary from a dirty
git tree (a consumer-box plugin snapshot has no .git and installs with an
"unknown provenance" warning instead), copies the binary to a versioned slot
under `~/.local/libexec/org-relay/`, repoints the `current` symlink that
launchd execs (repo churn can never touch the running daemon), restarts the
daemon, and verifies the SERVED sha equals the installed one — reverting the
symlink if not. `relay-ctl rollback` repoints to the previous slot. ALWAYS
re-run install-daemon after upgrading the plugin — the plist bakes PATH,
HERDR_BIN_PATH, and the nudge-helper path, which launchd cannot resolve
itself.

The CLIENT connection needs no manual step on a box running the
herdr-agent-org-claude Claude plugin: the plugin ships `.mcp.json`
(`relay -> http://127.0.0.1:7431/mcp`, same one-file pattern as
skyline-claude), so every session surfaces the tools as
`plugin:herdr-agent-org-claude:relay` automatically after a plugin
reload. Manual wiring is ONLY for a box using the relay without that
plugin: `claude mcp add --scope user --transport http relay
http://127.0.0.1:7431/mcp` — and if a box has both, remove the
user-scope duplicate (`claude mcp remove relay`) so the tool list
carries one copy. Grok workers wire it through their own runtime's MCP
config (no `.mcp.json` convention on the grok twins).

Verify all four, in order — each proves a different layer:

```bash
launchctl print gui/$(id -u)/com.skylence.org-relay | head -3   # supervised, not an orphan
curl -s http://127.0.0.1:7431/health | jq .                     # status ok + build attestation
curl -s http://127.0.0.1:7431/health | jq -r .build.sha         # the daemon says WHAT it is
claude mcp list | grep relay                                    # client handshake: ✔ Connected
sh <plugin-dir>/relay-ctl status                                # relay_status + build, box-wide db path
```

KeepAlive proof (once per box, worth the 10 seconds): `kill -9 $(lsof -ti tcp:7431)`,
wait ~4s, re-run the health curl. A daemon comes back; an orphan does not.
The db is box-wide (`~/.config/herdr/org-relay/relay.db`) BY DESIGN — one
server serves every org on the box, which is what makes peer-orchestrator
relay messages deliverable; do not point it at a per-org path.

## S2b Org-waker wiring (legacy: crash-net for pre-relay lanes only)

Pick ONE, matching the box:

**Dev box** (this repo is checked out locally and you want plugin fixes to ship without reinstalling):
```bash
herdr plugin link <abs-path-to-repo>/herdr-plugins/org-waker
```
LINKED means the plugin runs the WORKING TREE, not a frozen snapshot. Keep that checkout on `main` and current. A stale link quietly serves stale waker behavior with no error.

**Consumer box** (no local checkout, just want the wake mechanism installed):
```bash
herdr plugin install skylence-be/multi-llm-marketplace/herdr-plugins/org-waker
```

Verify either path landed:
```bash
waker-ctl present
herdr plugin action invoke doctor --plugin skylence.org-waker
```
`waker-ctl present` exits 0 with no output when the plugin's config dir resolves, and exit 1 with no output when it does not (verified 2026-07-29: `HERDR_BIN_PATH` pointed at a failing stub). Other `waker-ctl` subcommands print a stderr message when the plugin is missing; `present` is silent by design. The `doctor` action runs async: it returns a `log_id` immediately with `status: running`. Read the completed result with:
```bash
herdr plugin log list --plugin skylence.org-waker
```
and find that `log_id`'s entry; its `stdout` reports herdr/jq versions, registered lanes, pending wakes, and the last few `rings.jsonl` lines.

Then the correctness gate, ALL suites, from the repo root (dev box with a checkout):
```bash
for t in herdr-plugins/org-waker/test/*.sh; do sh "$t"; done
```
Each suite prints its own `<name>.sh: OK` line at the end when every case passes. Don't hardcode a suite count or name list here — the set grows (8 suites measured 2026-08-16: ack_path, classify_composer, coalesce_hold, drain_sent_preserve, parked_retry, pasted_placeholder, sent_no_resend, verify_clear_gate, up from 6 at waker 0.3.0). Instead grep the run's combined output for `\.sh: (OK|FAIL)` and confirm every matched line says `OK`. Anything else means stop before dispatching: the wake mechanism's classification, dedup, or retry logic is broken, and lanes will hang silently or ring stale bursts instead of waking the orchestrator cleanly.

**Consumer box (no repo checkout):** you cannot run those suites from a path that does not exist. Either clone `skylence-be/multi-llm-marketplace` long enough to run them from its root, or treat the doctor action above plus the S5 live probe as your gate. Do not invent a substitute shell check.

## S2c Native session-ping wiring (Claude <-> Claude, the composer-free wake)

Claude Code >= 2.1.224 (changelog 2026-08-07) ships `SendMessage` / `ListAgents`:
local Claude sessions message each other by name over a per-session Unix socket,
and a message STARTS A TURN in an idle session — the third-party turn-starter
role the composer nudge used to hold. The org runs it as the PING plane on top
of the relay (orchestrator L6: a ping is a wake, board + relay are the record).
macOS/Linux only; 2.1.225 adds cross-machine initiation via Remote Control,
which the org does not require.

```bash
claude --version   # >= 2.1.224, or skip this section: the org still runs whole on relay + nudge net
```

Wiring, measured on the reference box (2026-08-12, CC 2.1.228, macOS): NONE
needed for the local plane — a probe ping to an idle `--permission-mode
bypassPermissions` session DELIVERED and started its turn with zero
keystrokes, no settings key anywhere, full round trip (ping -> probe turn ->
attributed reply back) ~10s. The docs additionally describe a
`crossSessionInbound` accept/hold/refuse rule
(code.claude.com/docs/en/cross-session-messaging; precedence project > user >
default, defaults documented as mode-dependent), so if the probe below shows
a ping PARKING instead of delivering, set the rule explicitly in USER scope
(`~/.claude/settings.json`) and re-probe:

```json
{ "crossSessionInbound": "accept" }
```

Footguns: the feature rides feature-flag evaluation, so a pane exporting
`CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC`, `DISABLE_TELEMETRY`,
`DO_NOT_TRACK`, or `DISABLE_GROWTHBOOK` silently loses it (research-grade;
suspect it when a pane lists no peers). Native names AUTO-DERIVE from the
session cwd (`scratchpad-72 [659f9a]`-style, measured), so the role skills
resolve every address from a live `ListAgents` row and never from a herdr
agent name. The FIRST send to a peer must carry the row's `name [ref]` — a
bare name is refused with a confirm error (measured). An inbound message
arrives wrapped `<cross-session-message from="uds:/tmp/cc-socks/<pid>.sock"
from-name="..." from-mode="...">` and the reply address is that `from`
attribute copied verbatim.

Verify with two scratch sessions — prove the turn-start, not just the tool
(this exact probe ran green on the reference box 2026-08-12):

1. Open two Claude panes; in pane A run `ListAgents`. Pane B's row must appear.
2. Let pane B settle idle, then from A: `SendMessage(to="<B's name [ref]>",
   message="PING_OK — reply to this message's from address with PONG, then idle")`.
3. Pane B must start a turn on its own, zero keystrokes, and the PONG must
   arrive back in A as a `<cross-session-message>`. B idle-and-silent means
   the ping parked HELD: wire `crossSessionInbound` accept as above (or find
   the kill-switch env var in that pane), restart B, re-probe. Only a green
   probe lets the role skills lean on pings.

## S2.5 ActivityWatch context (aw-context) — optional

Gives every agent on the box read access to the operator's real desktop
activity (current window, presence, afk-filtered per-app time) plus
category-tree/settings management, via the `skylence.aw-context` herdr plugin.
Skip cleanly when ActivityWatch is not part of this box's workflow; nothing
later depends on it.

Preflight — an aw-server must already answer or everything below is a no-op:
```bash
curl -sf --max-time 3 http://127.0.0.1:5600/api/0/info
```
No answer: install and start ActivityWatch (aw-server + aw-watcher-window +
aw-watcher-afk) first, or skip this section.

Same dev/consumer split as S2, same stale-link warning for the dev form:
```bash
herdr plugin link <abs-path-to-repo>/herdr-plugins/aw-context                    # dev box
herdr plugin install skylence-be/multi-llm-marketplace/herdr-plugins/aw-context  # consumer box
```

Verify (doctor is async like org-waker's: the invoke returns a `log_id` with
`status: running`; read the completed stdout in the log list):
```bash
herdr plugin action invoke doctor --plugin skylence.aw-context
herdr plugin log list --plugin skylence.aw-context
```
doctor must report aw-server reachable and BOTH watcher buckets fresh. A
WARN/stale bucket line means the watchers are not actually reporting, and
every "current activity" answer agents get will be quietly stale — fix the
watchers before wiring agents to the data.

Category consistency, so per-app summaries mean the same thing on every box.
Idempotent: an in-sync tree prints `already in sync` and writes nothing, so
run it unconditionally on every setup pass. Any real write snapshots the
prior tree to the plugin config dir `backups/` first.
```bash
sh <plugin-path>/awctx category sync <plugin-path>/presets/agent-org.json
```
`<plugin-path>` is `<abs-path-to-repo>/herdr-plugins/aw-context` on a dev box;
on a consumer box it is the installed plugin root (the directory holding the
`manifest_path` shown by `herdr plugin list`).

Fresh device that should carry the FULL reference config (whole category tree
plus portable settings: startOfDay, startOfWeek, durationDefault, theme,
views), not just the agent categories layered on: apply the committed
baseline instead — also idempotent, also backed up before any real write:
```bash
sh <plugin-path>/awctx bootstrap apply <plugin-path>/presets/aw-baseline.json
```
The baseline is exported from the reference machine with
`awctx bootstrap export`; re-export and commit it whenever the desired
ActivityWatch config changes, and every other box picks it up on its next
setup pass.

Agent wiring, per the plugin README: put `awctx` on PATH once and add one
instruction line to agent briefs (agents then self-serve via
`awctx agent-help`, and check `awctx doctor` before trusting numbers):
```bash
ln -s <plugin-path>/awctx ~/.local/bin/awctx
```

## S3 Board bootstrap

Exports made INSIDE a Claude session die with that shell call: each tool call starts a fresh shell from the profile. `HERDR_ORG_ROOT` and the scripts `PATH` must therefore reach the **claude process** itself, set before it starts, so it forwards them to workers.

**Use `conduct`.** It does all of it and `exec`s claude:

```bash
# inside Herdr, in the pane shell:
conduct <org-name>                 # doctrinal launch built in: injects --model opusplan --advisor opus (explicit flags win; empty CONDUCT_MODEL/CONDUCT_ADVISOR suppresses)
conduct <org-name> --model sonnet  # further args pass through to claude and override the injected defaults
```

`conduct` also exports `CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT` (default 1800000ms)
into the claude process so a held relay_await is never idle-aborted before
the harness backgrounds it (L6/TASK-BACKED AWAIT); an existing export wins.
Hand-rolled bootstraps must export it themselves (the block below does).

Install it once by putting the plugin's `scripts/` dir on `PATH` from your shell rc. Resolve it by newest mtime so a plugin version bump needs no edit:

```zsh
# >>> herdr-org >>>
typeset -a _horg=( "$HOME"/.claude/plugins/cache/*/herdr-agent-org-claude/*/scripts(N/om) )
(( ${#_horg} )) && path=( "${_horg[1]}" $path )
unset _horg
# <<< herdr-org <<<
```

That also puts `board`, `dispatch-worker`, `waker-ctl` and `build-slot` on `PATH` in the pane shell, so you can inspect a board without going through claude.

**Verify it immediately, don't trust the paste.** A block that looks intact (markers present, no syntax error) can still be silently incomplete — e.g. missing the `typeset -a _horg=(...)` line that actually populates the glob, leaving the `(( ${#_horg} ))` conditional permanently false with no error at all (measured 2026-08-16: the block ran clean, PATH just never gained the entry). Confirm in a FRESH interactive shell, not the current one — rc files only apply to new shells:
```bash
zsh -ic 'which conduct board dispatch-worker waker-ctl'
```
All four must resolve. Any `not found` means re-diff the block against the snippet above line-by-line — don't assume the markers being present proves the body between them is complete.

**Do NOT reimplement `conduct` as a shell function that warns on a missing board and starts claude anyway.** That was the original form and it cost ~25 minutes on 2026-07-30: the warning went to stderr microseconds before a full-screen TUI took the terminal, so the operator rarely saw it and the agent never did. From inside, the org simply had no board and every call fell back to `~/.herdr-org/default`. A typo'd org name was indistinguishable from a new one. Create the board or refuse to start; do not warn and continue.

The equivalent by hand:

```bash
export HERDR_ORG_ROOT="$HOME/.herdr-org/<org-name>"
export PATH="<plugin-root>/scripts:$PATH"   # board, dispatch-worker, waker-ctl
export CLAUDE_CODE_MCP_TOOL_IDLE_TIMEOUT=1800000   # ms; held relay_await must outlive the pre-background window (L6)
board init "$HERDR_ORG_ROOT"
claude
```

**ABSOLUTE-PATH GOTCHA:** `board init <name>` with a bare name ALWAYS resolves to `~/.herdr-org/<name>`. It ignores `HERDR_ORG_ROOT` entirely, even when the export above already ran. Only an absolute or `./`/`../`-relative argument to `board init` itself honors a non-default location:
```bash
board init /abs/path/to/org   # only this form can put the org somewhere else
```
Every OTHER board subcommand (`get`, `list`, `comment`, `set-status`, ...) reads `HERDR_ORG_ROOT` correctly; only `init`'s own root resolution is special. `conduct` passes the absolute path for exactly this reason.

**ORIENT guard**, the first thing any orchestrator or worker session should check:
```bash
test -n "$HERDR_ORG_ROOT"
```
Unset means stop and redo the bootstrap above; never improvise with ad-hoc exports inside the Claude session, since they die with the current shell call. Left unset, the board CLI silently falls back to `~/.herdr-org/default`, quietly sending this org's milestones to the wrong board.

**Read that guard with the harness Bash tool, not `skyline_run`.** `skyline_run` children inherit the skyline daemon's environment (a LaunchAgent, cwd `/`), where `HERDR_*` is stale or unset regardless of what your pane has — so a `skyline_run` read of `HERDR_ORG_ROOT` is not evidence about your own process. Measured 2026-07-30: it reported `HERDR_ORG_ROOT` unset and `HERDR_PANE_ID=w5:p1` while the real pane was `wG:p1` in a different workspace. Filesystem checks (`ls ~/.herdr-org/<org>`) are daemon-independent and settle it either way.

Also remember a split worker pane does NOT inherit the requesting pane's environment (measured herdr 0.7.5, 2026-07-28): `dispatch-worker` forwards `HERDR_ORG_ROOT` and `PATH` via `--env` from your own process env.

## S4 Recommended ecosystem plugins (surveyed 2026-07-28)

These are the OPERATOR's call: this skill instructs, it does not auto-install anything below.

**Starter set**, the four with the clearest day-one payoff:
- `dot/herdr-terminal-notifier`: macOS notifications on agent state changes, so a parked worker rings instantly instead of waiting for a sweep. `herdr plugin install dot/herdr-terminal-notifier`
- `persiyanov/herdr-reviewr`: review sidebar for the L10 flow, comment on a worker's diff and see the PR plus its checks in one pane. `herdr plugin install persiyanov/herdr-reviewr`
- `senna-lang/herdr-agent-usage`: per-agent context meters and rate limits in the sidebar; succession triggers read these. `herdr plugin install senna-lang/herdr-agent-usage`
- `ntindle/herdr-resurrect`: snapshot and restore workspaces plus agents after a server crash or reboot. `herdr plugin install ntindle/herdr-resurrect`

**Optional**, pick what the workflow needs, do not install all of them:
- ONE remote-operation pick, to answer prompts from a phone: `dcolinmorgan/herdr-remote`, `AltanS/collie`, or `alexei-led/ccgram`.
- Many-pane navigation: `thanhdat77/herdr-navigator` or `JanTvrdik/herdr-command-palette`.
- `smarzban/herdr-file-viewer`: read-only diff and markdown pane.
- `ogulcancelik/herdr-browser`: a Chromium pane for web lanes.
- `natori-hrj/herdr-lazy`: declarative plugin manager; adopt once several of the above have landed, not before.

Living index of the wider ecosystem: `yigitkonur/awesome-herdr`.

Install syntax for any of the above: `herdr plugin install <owner>/<repo>` (`--ref <tag>` pins a version, `-y` skips the confirmation prompt).

## S5 Verification checklist (end-to-end)

Prove the RELAY path first — it is the org's message bus (1.0 speaks rmcp
streamable HTTP with per-session handshakes, so a bare stateless curl to /mcp
no longer works; use the plain mirrors and an in-session tool call):
```bash
curl -s http://127.0.0.1:7431/health    # "ok" = daemon up
curl -s http://127.0.0.1:7431/status    # queues + awaiting + nudge state, no handshake needed
# from any claude session with the relay wired: relay_guide() once to open the
# guide gate, then relay_send(sender=probe, to=orchestrator, kind=other,
# body=SETUP_PROBE); relay_inbox(agent=orchestrator) must list SETUP_PROBE;
# relay_consume it. Send -> inbox -> consume round-trip = bus OK.
```

Then the ping plane (S2c), on any box at CC >= 2.1.224: run the two-pane
PING_OK probe from S2c once per box and note the observed zero-keystroke
turn-start. A box that fails the probe still runs — relay + nudge net cover —
it just keeps composer-era recovery for stalled Claude lanes, which is exactly
what the ping plane retires.

Then, ONLY if this box still runs pre-relay lanes, prove the legacy wake path. Dispatch a throwaway probe with `--wake-target` and an explicit `--prompt` (do not pass `--todo` for a nonexistent slug: the default pointer asks for `board get <slug>`, board side-effects fail, and the probe dead-ends):
```bash
dispatch-worker --name probe --wake-target orchestrator \
  --prompt $'Reply with the single word PROBE_OK, then idle. Do not edit files.' \
  --cwd /abs/scratch-tree -- --permission-mode bypassPermissions
```

Run this FROM a pane that is itself the registered `orchestrator` — a `conduct`-launched session carrying that identity — not standalone. `--wake-target orchestrator` addresses a specific registered name; if nothing is registered under it the ring can only land `held:composer:status=unknown` or `dropped:coalesced-*`, never `delivered`, which reads like a broken waker but is actually a probe fired at no target (measured 2026-08-16). If you're driving this probe through an MCP/daemon tool rather than a real pane shell (e.g. skyline's `run`), pass `HERDR_ENV`, `HERDR_PANE_ID`, `HERDR_WORKSPACE_ID`, and `HERDR_ORG_ROOT` explicitly via that tool's env parameter — such daemons run with their own stale/unset env regardless of the pane's actual state (same footgun as the ORIENT guard above). Also expect an agent-driven run of this step to trip Claude Code's own auto-mode permission classifier, since it dispatches a live worker; that's a normal approval prompt; approve it or don't automate past it silently.
1. Confirm the settle ring arrives WITHOUT an operator pressing Enter; the orchestrator pane should receive the wake prompt on its own.
2. Confirm the ring is logged with a truthful outcome:
   ```bash
   herdr plugin action invoke doctor --plugin skylence.org-waker
   herdr plugin log list --plugin skylence.org-waker   # find that log_id, read "last rings"
   ```
   The recorded outcome (`delivered`, `held:undelivered`, `drain-delivered`, ...) must match what was actually observed on screen.
3. Unregister and reap the probe:
   ```bash
   waker-ctl unregister --lane probe
   ```
   then close or reap the probe's pane and agent as usual.
4. If a pending wake existed for the probe at unregister time, expect a new `dropped:unregistered` line in `rings.jsonl`. Confirm it is there, not silently swallowed.

5. Conductor model probe (once per box, after S3): launch `conduct probe-org --model opusplan --advisor opus` in a scratch pane, have it enter plan mode, produce a two-line plan for a trivial task, and exit plan mode. Known answer (measured 2026-08-16, CC 2.1.233, herdr 0.7.5 — reconfirm once per box, this can drift with CC updates): (a) it does NOT proceed past plan exit unattended — the pane parks `blocked` on the "Would you like to proceed?" dialog even under `conduct`'s injected opusplan/advisor flags, because those don't include `--permission-mode bypassPermissions`; an org that needs unattended planning must launch with bypassPermissions explicitly (`conduct <org> --permission-mode bypassPermissions`) and re-verify there, since that combination is itself unconfirmed. (b) confirmed: statusline model is Opus during the plan phase, Sonnet after exit — if a pane capture can't show the statusline clearly, just ask the agent directly ("what model are you running as right now?") and read its answer. (c) advisor consultation did not fire for a trivial two-line plan on the reference box — inconclusive whether it ever surfaces in the transcript at all; treat as still open, not confirmed-silent. Then clean up: remove `~/.herdr-org/probe-org` and close the scratch pane.
