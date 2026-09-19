# herdr-agent-org

Claude Code port of the Skylence agent-org, running on **[Herdr](https://herdr.dev)**, forked from [multi-llm-marketplace](https://github.com/skylence-org/multi-llm-marketplace)'s `herdr-agent-org-claude` 2.4.1, with [TypeSafe Jev](https://docs.typesafe.ai) measuring two laws the orchestrator used to judge from memory. Install this **instead of** `herdr-agent-org-claude`, never beside it: both carry the same role skills and hooks.

## What Jev adds (and where it deliberately is not)

One Jev request per lane per **event**, never per tool call, and nothing changes when there is no key:

- **`scripts/tier-gauge`**, called by `dispatch-worker` before any pane exists (L17 TIER BY BRIEF, measured). One request over the brief: the work tier as a Choice over *descriptions of the work* (mechanical / ordinary / hard — never model names), a `risky` Noul over the L10 surfaces, and three brief-template lint Nouls (lane-tree path, milestone comments, inlined board calls). A cheap tier (`--model haiku`) on a brief the gauge reads as not mechanical is **refused** (exit 2 from `dispatch-worker`, the same hard stop as a missing `--upgrade-reason`); a hard brief below the top tier only warns; it never auto-upgrades. The verdict is filed on the todo as `[TIER-GAUGE: jev-1.13.0 tier=… conf=… risky=… verdict=…]`. `--no-gauge` skips it; file the L13 reason.
- **`scripts/review-gate-check <slug> --cwd <lane-tree> --base <base> --head <tip>`** at ACCEPT SEQUENCE step 1 (L10 REVIEW GATE, measured). Changed lines are counted in code (≥ 150 is MANDATORY before Jev is asked at all); below that, one request over the review package (`/tmp/<slug>_review.diff` when it fits, else paths + commit subjects) answers four surface Nouls. Prints exactly one line to paste on the todo: `MANDATORY-REVIEW: …` (exit 3), `WAIVABLE: …` (exit 0; the `[REVIEW-WAIVED]` filing is still yours), or `WAIVABLE-UNGAUGED` (no Jev; judge the surfaces yourself).
- **`scripts/jev`** and **`scripts/jev-questions.json`**: the shared door to the API and the one file holding every question and threshold. Byte-identical to `core`'s copy (`tools/check-parity.sh` enforces it). Fail-open, cached by request checksum, one audit line per call in `~/.claude/jev-audit.jsonl`, `JEV_STUB_ANSWERS` for tests. Tune thresholds in `~/.claude/jev-questions.json`.

Not on Jev, on purpose: the org-relay nudge watchdog (timing), the reviewer lane (needs generation), the architect dry-read gate (the gauge must be the priced worker tier), and `tests/conduct` (a live model under pressure is the subject under test).

Setup: put the key in `~/.config/typesafe/api_key` (one line, `chmod 600`). `jev` reads that file when `TYPESAFE_API_KEY` is not in the environment, and a file is what makes the org work: split panes inherit the herdr *server's* env, not yours, and a skyline-routed shell call runs inside a detached daemon — neither sees a shell export, both read a file owned by the same user. The env-variable route still works (pane shell before `claude` starts, or the tool call's `env` parameter per the SKYLINE-ROUTED SHELL GOTCHA), it just has to be repeated per process. `sh scripts/jev doctor` prints which source it found.

---

The rest of this README is the upstream `herdr-agent-org-claude` document, unchanged except the install commands.

Herdr is the agent multiplexer: real terminal panes, semantic agent state (`working` / `blocked` / `done` / `idle`), and CLI plus socket control so agents can orchestrate each other. This plugin maps the Skylence conductor-and-workers doctrine onto those primitives plus a **filesystem board**, so the board needs no MCP server.

## Prerequisites

1. **Herdr** installed and running (`brew install herdr`, or `curl -fsSL https://herdr.dev/install.sh | sh`). Target **>= 0.7** for `agent start` / `wait` / `prompt`.
2. Orchestrator and workers must run **inside Herdr panes** (`HERDR_ENV=1`).
3. `jq` on PATH (the hooks and `dispatch-worker` parse Herdr's JSON).
4. Optional: `herdr integration install claude`. See the caveat below before assuming it does more than it does.
5. Recommended: the **org-waker** herdr plugin (`herdr plugin install skylence-org/multi-llm-marketplace/herdr-plugins/org-waker`). It is the event-driven wake mechanism L6 builds on; without it the org runs on fallback waits alone.

## What it provides

- **Skills** (roles):
  - `orchestrator` conducts: dispatches via Herdr panes plus the board, verifies, merges, owns the single gate build
  - `herdr-worker` is worker conduct for dispatched agents
  - `replacer` is successor pickup after a stall, kill, or compaction
  - `org-audit` is an on-demand cold review, never scheduled
  - `herdr` is the low-level control surface (pane, agent, workspace CLI)
  - `herdr-setup` is the one-shot playbook to bootstrap a fresh box from "herdr installed" to "org-ready" (claude only)
  - `architect` is the operator-side planning contract: transcription-grade, blueprint-bound, SHA-pinned GitHub issues (haiku dry-read gated) that the orchestrator turns into lane briefs — never a dispatched org agent
- **Scripts**:
  - `board` is the filesystem board (todos, comments, pads, blockers); `set-status` best-effort publishes the lane's status into the herdr sidebar pane (`pane report-metadata`), `ready` lists unblocked pending todos, `create --tags`/`list --tags` tag and filter todos, `query <text>` case-insensitively searches todo files, `list`/`ready`/`get` support `--json`, and every mutating command snapshots a best-effort silent git commit when git is available
  - `dispatch-worker` splits a pane (auto layout: first worker below the orchestrator, later workers rightward in rows of at most 2, a fresh row per 2; explicit `--direction` overrides), starts a named agent, sends the pointer prompt, and reports the post-send state; optional `--beat-note TEXT` is forwarded to waker registration so settle/block/death rings carry the orchestrator's beat script
  - `build-slot` is the machine-wide compile serializer
  - `tier-gauge` measures a brief's worker tier, risk, and template completeness (L17; one Jev request, called by `dispatch-worker`)
  - `review-gate-check` measures the L10 review gate at accept (lines in code, surfaces by one Jev request)
  - `jev` is the shared door to the TypeSafe API; `jev-questions.json` holds every question and threshold
  - `waker-ctl` is the org-side client of the org-waker herdr plugin (register, unregister, list, drain, doctor)
- **Hooks** (`hooks/hooks.json`, wired on install):
  - `org-lane-mark.sh` (PreToolUse on Bash and skyline_run) records one line per org event, `dispatch` or `wait`
  - `org-stop-gate.sh` (Stop) blocks a marked session's FIRST stop with the anti-idle sweep
  - `org-conduct-refresh.sh` (SessionStart, matchers `startup|resume|compact`) primes the role-skill contract in fresh sessions and re-injects the re-read order after compaction
- **templates/claude-md.md**: worker guidance to paste into `~/.claude/CLAUDE.md` on a machine that runs lane workers.
- **templates/reviewer-brief.md**: the L10 reviewer-lane dispatch contract — two-stage verdict (spec compliance and artifact quality), severity-ranked findings, forced `READY:` verdict, review-package-as-file.

## Install

```
/plugin marketplace add skylence-org/claudecode-jev-marketplace
/plugin install herdr-agent-org@claudecode-jev-marketplace
```

Then start a session bound to one org. `conduct` is on the plugin's `scripts/`
dir; put that dir on your `PATH` once (see [Setup](skills/herdr-setup/SKILL.md) S3)
and the rest is one command:

```bash
# inside Herdr, in a pane:
conduct my-feature                 # creates the board if missing; injects the doctrinal defaults: --model opusplan --advisor opus
conduct my-feature --model sonnet  # explicit --model/--advisor win over the injected defaults
CONDUCT_ADVISOR= conduct my-feature   # empty CONDUCT_ADVISOR / CONDUCT_MODEL suppresses that injection
conduct my-feature --resume        # resume the last session instead of a new one
```

### conduct reference (formerly `orgclaude`; a deprecated shim with the old name forwards until the next minor)

```
conduct <org-name> [claude args ...]
```

| Parameter | Required | Rules |
|---|---|---|
| `<org-name>` | yes, first argument | Letters, digits, `.` `_` `-` only. Rejected before anything touches disk: empty, leading `-`, any `/`, `.`, `..`, whitespace or other characters. Resolves to `~/.herdr-org/<name>`; a missing board is created, an invalid name creates nothing. |
| everything after | no | Passed to `claude` unchanged, plus two injected defaults: `--model opusplan --advisor opus` are prepended UNLESS the args already carry that flag (explicit wins), with `CONDUCT_MODEL` / `CONDUCT_ADVISOR` overriding a default and an EMPTY value suppressing the injection. Any claude flag works: `--resume`, `--permission-mode bypassPermissions`, … |

Order matters: the first argument is always consumed as the org name, so
`conduct --resume my-feature` is rejected with exit 2 rather than creating a
board named `--resume` (which is exactly what the unvalidated 1.4.0 did).

Exit codes: `2` usage error or invalid name, `1` board creation failed, `127`
claude not on PATH. Otherwise conduct `exec`s claude, so the exit code you see
is claude's own. Run with no arguments to print usage plus the existing orgs.

`conduct` exports `HERDR_ORG_ROOT`, puts `scripts/` on `PATH`, creates the board
when it is missing, and then `exec`s claude. It is a script rather than a shell
function on purpose: those two variables only need to reach the CLAUDE PROCESS —
claude forwards them to workers itself, and `dispatch-worker` reads them from its
own env — so `exec` from a script is sufficient and nothing has to leak back into
your interactive shell.

The equivalent by hand, if you are not using `conduct`:

```bash
export HERDR_ORG_ROOT="$HOME/.herdr-org/my-feature"
export PATH="<plugin-root>/scripts:$PATH"   # board, dispatch-worker, waker-ctl
board init "$HERDR_ORG_ROOT"
claude
```

Split panes do NOT inherit the requester's environment: they get the herdr server's env (measured on herdr 0.7.5, 2026-07-28). `dispatch-worker` therefore passes `--env HERDR_ORG_ROOT=...` and `--env PATH=...` on the split itself; a hand-rolled `pane split` must do the same or the worker resolves neither the board nor the org scripts.

## Two Claude-specific facts that shape the doctrine

**Pane reads are frames; the board is what survives.** `--source visible` (or `--source detection`) shows the current frame. `recent` and `recent-unwrapped` reach back through the pane's host scrollback, and on the Claude Code build measured here that scrollback does carry committed transcript, so a bigger `--lines` really does recover past turns. Two limits still bind: a worker mid-turn has scrolled nothing yet, so `recent` equals `visible` until it commits output; and scrollback dies with the pane, so reaping an agent (L4) takes its history with it. Hence the board comment trail is the record, and every brief orders milestone comments at phase boundaries rather than one summary at the end. Note that Herdr's docs state alternate-screen rows never enter host scrollback and count Claude Code as a full-screen agent. That is not what this build did (measured 2026-07-23 on herdr 0.7.5, two independent panes), so re-check with `herdr pane read <pane> --source recent --lines 300` before trusting either statement.

**Claude Code is not authoritative for its own state.** `herdr integration install claude` installs a session-identity hook so Herdr can restore the pane after a server restart. It does not install lifecycle hooks, so state still comes from Herdr's screen-manifest detection, and `blocked` is reported only when a known approval or permission UI is on screen. `herdr agent wait` is a good-enough settle signal, not a contract; `herdr agent explain <target>` diagnoses a state that looks wrong.

A third practical point: a Claude worker started with no arguments stops at its first permission prompt and parks in `blocked`. Dispatch full-auto lane workers explicitly.

```bash
dispatch-worker --name impl-a --todo impl-a --cwd /abs/lane-tree \
  -- --permission-mode bypassPermissions
```

`dispatch-worker` fills in the doctrinal default itself (`--model sonnet` for a Claude worker, `--effort medium` for a grok one) when you pass none, so silence at dispatch cannot resolve to whatever the box is installed at. Going above that default requires `--upgrade-reason "<why>"`, which the script refuses to skip and files on the lane todo as `[MODEL: ...]` or `[EFFORT: ...]`. A bare `herdr agent start` has no such protection, so pass the setting yourself there. Both rules come from [issue #32](https://github.com/skylence-org/multi-llm-marketplace/issues/32).

## The Herdr substrate at a glance

| Concern | herdr-agent-org |
| --- | --- |
| Board and todos | Filesystem board (`scripts/board`) |
| Worker PTYs | `herdr pane split` plus `agent start` |
| Read and steer | `herdr agent read` / `SendMessage` ping and `relay_send`; never the composer (L11) |
| Idle wake | org-relay `relay_await` (task-backed); fallback `herdr agent wait` |
| Agent state | Herdr semantic states plus sidebar |
| MCP required | org-relay for messaging; the board itself is CLI only |
| Run location | **Must** be `HERDR_ENV=1` |
| Peer discovery | `herdr session list` plus per-session agent list |

## Typical flow

1. Operator: "you're the conductor", which invokes the `orchestrator` skill.
2. Orchestrator initializes or reads the board and plans the program itself (L3: no planner agent exists in this org).
3. Dispatch: `dispatch-worker --name <lane> --kind claude --todo <slug> --cwd <lane-tree> -- --permission-mode bypassPermissions`.
4. The worker invokes `herdr-worker` and reports milestones via `board comment`.
5. The orchestrator arms `herdr agent wait`, verifies claims by re-running them, gates the build once, and merges. Workers never compile.

## Notes

- Hook markers live at `/tmp/claude-herdr-org-lanes-<session_id>`, one file per session.
- The stop gate follows two rules, both field-driven (2026-07-21): the premise follows recorded evidence (a session that only armed waits is not told it dispatched workers), and an answered sweep settles until org state actually moves.
- Prefer `${HERDR_BIN_PATH:-herdr}`; Herdr injects that variable inside managed panes.
- Pair with `core-claude` for the baseline guidelines and judge-hook, and with `skyline-claude` for hash-guarded edits.
- `tests/conduct/` pressure-tests the role skills' conduct clauses on a live model (superpowers-style RED/GREEN doctrine testing): `sh tests/conduct/run-conduct.sh` is BILLED; `--self-test` (stubbed, free) runs in CI; `--without-skill` captures baseline rationalizations to close in the skills' tables.
