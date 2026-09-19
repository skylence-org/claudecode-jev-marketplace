---
name: herdr-control
description: "Control Herdr, a terminal multiplexer for coding agents, from Claude Code. Use when HERDR_ENV=1 and you need to inspect or control panes, tabs, workspaces, commands, or another agent. Requires Herdr >= 0.7."
---

# Herdr control surface

Herdr organizes terminals into workspaces, tabs, and panes, recognizes coding agents running inside panes, and exposes the session through the `herdr` CLI (and a JSON socket API). This skill is the low-level surface; `scripts/dispatch-worker` and `scripts/board` sit on top of it.

## Guardrail

```bash
test "${HERDR_ENV:-}" = 1
```

If this fails, say you are not inside a Herdr-managed pane and stop. Prefer `${HERDR_BIN_PATH:-herdr}` for portability.

Never run bare `herdr` for discovery: it attaches the TUI. Use `herdr --help` and group help (`herdr agent`, `herdr pane`, and so on).

## Primitives

| Primitive | Responsibility |
| --- | --- |
| workspace / tab / pane topology | Create and organize terminal locations |
| pane | Raw terminal: run commands, send input, read or wait on output |
| agent | Recognized coding agent: prompt, wait on lifecycle, read |

A pane exists whether or not it contains an agent. `agent start` requires an **available shell pane** (interactive prompt, no foreground agent) and never creates layout, so split first.

Agent states: `working`, `blocked`, `done` (idle plus unseen output), `idle` (seen), `unknown`.

## Discover

```bash
herdr workspace list
herdr tab list --workspace "$HERDR_WORKSPACE_ID"
herdr pane current --current
herdr pane list --workspace "$HERDR_WORKSPACE_ID"
herdr agent list
herdr session list            # agent list is per-session; a peer may live next door
```

Public IDs: workspace `w1`, tab `w1:t1`, pane `w1:p1`. Parse IDs from JSON responses; never infer them from sidebar order.

## Claude Code specifics

Two facts change how you use this surface when the agent on either end is Claude Code.

- **Reads are a frame plus whatever scrolled.** `--source visible` and `--source detection` show the CURRENT frame. `recent` and `recent-unwrapped` reach back through the pane's host scrollback, and on the Claude Code build measured here (herdr 0.7.5, 2026-07-23) that scrollback carries committed transcript, so a larger `--lines` does recover past turns. Herdr's docs say the opposite for full-screen agents and name Claude Code among them, so measure before relying on either: `herdr pane read <pane> --source recent --lines 300`. Two limits hold regardless: an agent mid-turn has scrolled nothing yet, so `recent` equals `visible` until it commits output, and scrollback dies with the pane. Anything that must outlive the pane goes on the board, or into a file the worker names.
- **State detection is screen-based.** `herdr integration install claude` installs a session-identity hook only (it enables pane restore after a server restart); it does NOT make Claude Code authoritative for lifecycle state. State still comes from Herdr's screen-manifest detection, and `blocked` is only reported when a known approval or permission UI is on screen. Treat `agent wait` as a good-enough settle signal and the board as the source of truth. `herdr agent explain <target>` diagnoses a state that looks wrong.

## Start a sibling agent

```bash
# preserve focus and cwd
herdr pane split --current --direction right --cwd "$PWD" --no-focus
# read .result.pane.pane_id from the JSON
herdr agent start reviewer --kind claude --pane <pane_id> -- --model sonnet --permission-mode bypassPermissions
herdr agent prompt reviewer "Review the diff on PR #123." --wait --timeout 120000
herdr agent read reviewer --source visible --lines 120
```

Args after `--` pass to the agent binary. A Claude worker started with no args stops at the first permission prompt and parks in `blocked`, so pass the full-auto args deliberately or expect to answer prompts by hand.

Supported kinds include `claude`, `codex`, `grok`, `opencode`, `hermes`, `cursor`, and more; run `herdr agent` for the installed list. Names must match `[a-z][a-z0-9_-]{0,31}` and be unique among live agents.

## Coordinate

```bash
herdr agent wait reviewer --until done --timeout 300000
herdr agent wait reviewer --until blocked --timeout 120000
herdr agent send-keys reviewer esc
herdr agent get reviewer
```

`agent prompt --wait` waits for a settled `idle`, `done`, or `blocked` by default. A prompt from a non-working state that never advances the lifecycle returns `agent_prompt_stalled` within about 5s: that is your verify-after-send signal, not a transient.

Messaging a live CLAUDE session: prefer the native ping (`SendMessage`, target resolved from a `ListAgents` row; CC >= 2.1.224) — it touches no composer, arrives attributed, and starts a turn in an idle session. `agent prompt` remains the path for non-Claude kinds, launch-time delivery, and lifecycle-coupled sends (`--wait` semantics); when each applies is orchestrator doctrine (L6/L11).

Ordinary commands (tests, servers) go through the pane, not the agent:

```bash
herdr pane run <pane_id> "just test"
herdr pane wait-output <pane_id> --regex "passed|failed" --timeout 120000
herdr pane read <pane_id> --source recent-unwrapped --lines 120
```

Pane input addresses the terminal whatever occupies it; agent input resolves the live agent and fails if that agent no longer owns the pane. Prefer agent commands for peers and pane commands for shells.

## Identity in the sidebar

The sidebar is how a human tells one agent from another, so name things rather than leaving the runtime's own label:

```bash
herdr agent rename "$HERDR_PANE_ID" orchestrator   # name yourself; target may be a pane ID
herdr agent rename w1:p2 reviewer                  # or an existing unique agent name
herdr agent rename reviewer --clear
herdr pane rename w1:p2 "impl-a: lane-a"           # outlives the agent
herdr pane rename w1:p2 --clear
```

Agent names match `[a-z][a-z0-9_-]{0,31}` and must be unique among live agents; a closed lane frees its name. `agent rename` needs the target to be a recognized agent, so on a pane detection has not classified yet, `pane rename` is the fallback that still labels the sidebar. Tab and workspace labels (`herdr tab rename`, `herdr workspace rename`) group a whole wave when one workspace holds several lanes.

## Safety

- Classify the target's input line before ANY send (no-fusion law). `scripts/ghost-probe.sh` is the classifier; on Herdr use `live` then `probe`. Native `SendMessage` pings bypass the composer entirely and need no classification.
- Use `--no-focus` for background work unless the operator asked to switch context.
- Address `--current`, an explicit pane ID, or a unique agent name; never another client's focused pane.
- Do not close workspaces, tabs, or panes you did not create unless asked.
- Never `herdr server stop` unless the operator explicitly intends to kill the session.
