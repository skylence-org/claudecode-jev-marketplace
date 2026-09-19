# org-waker (herdr plugin)

Event-driven wake-up for the [herdr](https://herdr.dev) agent-org plugins in this repo. It closes the gap issue #37 recorded: Solo's `timer_fire_when_idle_*` had no Herdr equivalent, so a lane that settled after the orchestrator's turn ended changed board state nobody was watching. This plugin subscribes to Herdr's pane events and turns a registered lane's settle, block, or death into ONE `herdr agent prompt` at the registered orchestrator agent. A prompt STARTS an orchestrator turn, which is the thing an armed `herdr agent wait` structurally cannot do after your turn has ended (see `#36`'s "what this does not fix").

Not a Claude Code plugin: this is a **herdr** plugin, installed with herdr's own plugin manager. It is runtime-agnostic; the claude and grok org plugins both drive it through the same files.

## Install

```bash
herdr plugin install skylence-org/multi-llm-marketplace/herdr-plugins/org-waker
# or, for local development against this checkout:
herdr plugin link /abs/path/to/multi-llm-marketplace/herdr-plugins/org-waker
```

Requires herdr >= 0.7.4 and `jq` on PATH. Verify with:

```bash
herdr plugin action invoke doctor --plugin skylence.org-waker
```

## How it works

- The manifest subscribes `pane.agent_status_changed`, `pane.exited`, and `pane.closed` (dot-form in the manifest; the JSON payload uses underscore-form event names and flat `.data.pane_id` / `.data.agent_status` fields).
- An event for a pane that is not in the registry exits with **zero herdr calls**, so the operator's unrelated panes never cost anything.
- Ring predicate: `blocked` rings on a blocked-edge; `idle`/`done` ring only on a working→terminal edge. Repeated re-emissions stay silent, so there is no stale-fire class for the orchestrator to dismiss (the Solo defect issue #20 records).
- Death coverage: `pane.exited`/`pane.closed` on a *registered* lane ring as crash-class, and so does a status event whose `agent` label went empty while registered (the agent process died before settling). Unregister a lane BEFORE reaping it at close-out and the expected death stays silent; a still-registered death is by definition a crash.
- Send safety (org law L11): before any prompt, two visible-frame tails of the target are compared ghost-probe-style. A changing or non-empty input line HOLDS the wake as a pending file and raises a toast instead of stomping operator text. On pure Herdr a suggestion ghost is indistinguishable from typed text, so a ghost false-positives into a hold; the drain path recovers it.
- Delivery: target `working` → plain `agent prompt`; target `idle`/`done` → `agent prompt --wait --timeout 8000` (Claude Code queues a mid-turn prompt cleanly, so `--wait` on a still-running turn would misread it as failure). Target `blocked`/`unknown` → hold. Neither branch proves the Enter actually submitted (herdr's send is timing-flaky), so `deliver` ALWAYS follows up with a post-send check: resolve the target's pane, settle (~1s) so paste can render, then classify the composer line — a first-read clear is trusted only after a second read (~1s later) also classifies clear. Clear (or a queued indicator — the exact Claude Code hint `Press up to edit queued messages`) is what earns the `delivered` outcome; our own wake text still parked gets empty-submit recovery (`pane run <pane> ""`): re-confirm the composer is still parked immediately before each Enter (abort without Enter on foreign; clear|queued already counts as success); settle (~1s) before each re-check; success only if the post-settle classify is clear or queued (foreign fails and holds — never a silent delivered); one retry of the empty submit if the first Enter left the line parked; still parked after both attempts logs undelivered. Pre-send L11: if the composer already holds EXACTLY this wake's text (a previously parked copy), empty-submit recovery counts as delivery instead of holding forever or re-prompting a duplicate; foreign text still holds. Any other post-send text on the line is left untouched and the ring reports undelivered (never empty-submit text we did not send — a fusion hazard). Only a verified delivery is logged `delivered` in `log/rings.jsonl`; a verification failure falls back to the existing hold path exactly like an `agent prompt` exit-code failure.
- Held wakes drain through a claim-by-rename queue (stale claims sweep back after 300s; delivery stops at the first failure so nothing lands out of order). Each pending file carries its own target, so a dead lane's wake never needs a registry row to route. Drain runs as a manifest action, opportunistically after handled events (2s debounce marker), on every `pane.focused` event as a heartbeat (so a held wake retries as soon as the operator moves focus), and at `[[startup]]`, which also RECONCILES the registry: a registered lane whose pane no longer exists gets its crash ring synthesized, covering death events lost while the server was down. Panes that still exist are left to the live event stream (agent detection may still be settling right after restore). Every permanent removal of a pending `.msg`/`.claim` writes exactly one `log/rings.jsonl` line — audit outcome vocabulary: `delivered` (live ring), `held:<why>` (composer/undelivered), `drain-delivered` (drain success or own-text recovery), `dropped:superseded-g<N>` (re-dispatch gen bump), `dropped:malformed` (bad pending body), `dropped:unregistered` (close-out purge of that lane's held wakes; never silent).
- `waker stats` prints a delivery-audit summary: ring counts by outcome and by lane from `log/rings.jsonl`, the pending wake count with the oldest wake's age in minutes, and the in-flight `.claim` count.

## Wake line format

```
[RING g<gen>] lane <lane> -> <status>. board get <todo>
[RING g<gen>] lane <lane> -> <status>. board get <todo>. NOTE: <beat-note>
[RING g<gen>] lane <lane> PANE exited (exit 1) while registered. Crash-class: board get <todo>, consider a replacer.
[RING g<gen>] lane <lane>: agent process GONE (last status working). Crash-class: board get <todo>, consider a replacer.
```

The payload is a pointer, not content: the board comment trail remains the contract; the ring only makes it timely. `g<gen>` is the registration generation; a re-dispatched lane bumps it, and pending wakes from an older generation are dropped at drain instead of costing a turn. When the lane was registered with `--beat-note <text>`, every ring (settle, block, and crash-class) appends `. NOTE: <text>` so the orchestrator receives the beat script on the same line as the pointer — held wakes keep working unchanged because the note is baked into the ring line at composition time and pending files already store the full line.

## The registry contract

Everything lives under the plugin config dir, the one root both the handler environment (`HERDR_PLUGIN_CONFIG_DIR`) and a plain shell (`herdr plugin config-dir skylence.org-waker`) resolve identically:

```
registry/<lane>.row   one TSV row per lane: pane_id  lane  todo  target  gen  org_root  registered_at  [beat_note]
state/                per-pane last status, dead markers, drain debounce
pending/              held wakes (line 1 target, line 2 wake text), <epoch-ms>-<lane>-g<gen>.msg
spool/<lane>.jsonl    append-only event records (orchestrator catch-up surface)
log/rings.jsonl       delivery audit
```

The `registry/` row files are the interface: the org plugins' `dispatch-worker`/`waker-ctl` write them through the same upsert semantics as `waker register` (re-registering a lane bumps `gen` and clears its per-pane state; one file per lane, so concurrent registrars cannot clobber each other, and a pre-0.2.0 `registry.tsv` migrates on first touch). Registration and steering:

```bash
waker register --pane <pane_id> --lane <name> --target <orchestrator-agent> [--todo <slug>] [--org-root <path>] [--beat-note <text>]
waker unregister --lane <name>     # BEFORE reaping the agent at close-out
waker list
waker drain                        # also exposed as the drain action
```

## Prior art

Built on patterns from [joelhooks/herdr-pings](https://github.com/joelhooks/herdr-pings) (MIT: the spool contract, the agent-label early-crash watchdog, pane-death lifecycle bridging) and [caioniehues/herdmates](https://github.com/caioniehues/herdmates) (MIT: the edge-filter ring predicate, unknown-pane silence, claim-by-rename delivery with stale-claim sweep, marker-file debounce). What neither ships, and this plugin adds, is a subscriber that rings an **agent** instead of a human.

## Limitations

- A held wake needs a later event, the startup sweep, or a manual drain to retry; an org with zero further events keeps it parked (the toast tells the operator). The orchestrator doctrine keeps a fallback `herdr agent wait` for exactly this window.
- The orchestrator must still exist and be reachable as an agent; a dead orchestrator needs the operator (same boundary as #36's doorbell).
- One herdr session: events reach the server that owns the pane, and the registry does not model peer sessions.
