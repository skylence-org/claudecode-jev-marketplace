# herdr-agent-org

Claude Code port of the Skylence agent-org, running on **[Herdr](https://herdr.dev)**, forked from [multi-llm-marketplace](https://github.com/skylence-org/multi-llm-marketplace)'s `herdr-agent-org-claude` 2.4.1, with [TypeSafe Jev](https://docs.typesafe.ai) measuring two laws the orchestrator used to judge from memory. Install this **instead of** `herdr-agent-org-claude`, never beside it: both carry the same role skills and hooks.

## What Jev adds (and where it deliberately is not)

One Jev request per lane per **event**, never per tool call, and nothing changes when there is no key:

- **`scripts/tier-gauge`**, called by `dispatch-worker` before any pane exists (L17 TIER BY BRIEF, measured). One request over the brief: the work tier as a Choice over *descriptions of the work* (mechanical / ordinary / hard — never model names), a `risky` Noul over the L10 surfaces, and three brief-template lint Nouls (lane-tree path, milestone comments, inlined board calls). A cheap tier (`--model haiku`) on a brief the gauge reads as not mechanical is **refused** (exit 2 from `dispatch-worker`, the same hard stop as a missing `--upgrade-reason`); a hard brief below the top tier only warns; it never auto-upgrades. The verdict is filed on the todo as `[TIER-GAUGE: jev-1.13.0 tier=… conf=… risky=… verdict=…]`. `--no-gauge` skips it; file the L13 reason.
- **`scripts/review-gate-check <slug> --cwd <lane-tree> --base <base> --head <tip>`** at ACCEPT SEQUENCE step 1 (L10 REVIEW GATE, measured). Changed lines are counted in code (≥ 150 is MANDATORY before Jev is asked at all); below that, one request answers four surface Nouls over the changed paths, commit subjects and `--stat` summary. The diff itself leaves the box only with `--send-diff` or `JEV_SEND_DIFF=1` (set per repo in `.claude/settings.json` `env` for repos that may share source with the vendor); `JEV_DISABLE=1` the same way turns Jev off for a repo entirely. Both refs must resolve, or the script exits 2: a diff that cannot be computed is never a pass. Prints exactly one line to paste on the todo: `MANDATORY-REVIEW: …` (exit 3), `WAIVABLE: …` (exit 0; the `[REVIEW-WAIVED]` filing is still yours), or `WAIVABLE-UNGAUGED` (no Jev; judge the surfaces yourself).
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
5. Recommended: the **org-waker** herdr plugin (`herdr plugin install skylence-org/claudecode-jev-marketplace/herdr-plugins/org-waker`). It is the event-driven wake mechanism L6 builds on; without it the org runs on fallback waits alone.

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
    - 0.1.6: a hard brief below the top tier stops the dispatch until `--upgrade-reason` or `--keep-tier "<why>"` (`[TIER-KEPT: ...]`); `--relaunch <name> --model <m>` reaps and relaunches a just-started lane at another model (`[RELAUNCH: ...]`); `--accept-trust` answers Claude Code's startup folder-trust dialog with content-free keys (`state=trust-prompt` without it); the default pointer carries the exact board command (`env HERDR_ORG_ROOT=<root> <abs>/board`); the lane is appended to the session's stop-gate marker even when dispatch-worker runs from a script
    - 0.1.7: `tier-gauge` gauges what the next worker receives: a todo with a `[BOUNCE n]` comment is gauged on its latest DIGEST + ruling (`source=bounce`, no template lint), anything else on its body (`source=body`); a review lane always on its brief; `--show-brief` prints the gauged text without a Jev call. The stop gate counts only unfinished named lanes in this workspace for a keyless line, ends a keyed line whose agent is gone, and marks `herdr agent start` / `dispatch-worker` stages inside `for … do`, `if … then`, `else` and `{ … }`
    - 0.1.8: `--replacer [--bounce N]` builds the replacer/bounce pointer itself (the `herdr-replacer` skill, the exact board command, the lane tree's tip SHA, and the round). The round comes from `tier-gauge --todo <slug> --round-only`, the same parser the gauge uses: the LAST comment whose first line starts with `**[BOUNCE r/n]` or `[BOUNCE 4 / ESCALATION]`, so a bounce quoted in the body or named in prose is no bounce; round 4 points at the ESCALATION comment; none found omits the bounce clause. `--bounce` takes 1, 2 or 3. It needs `--todo` and a git `--cwd`, refuses `--prompt`, works with every other flag, and the JSON summary adds `replacer`, `tip`, `bounce`
  - `build-slot` is the machine-wide compile serializer
  - `tier-gauge` measures a brief's worker tier, risk, and template completeness (L17; one Jev request, called by `dispatch-worker`)
  - `review-gate-check` measures the L10 review gate at accept (lines in code, surfaces by one Jev request)
  - `integration-gate` (0.1.8) is the L7 merged-state gate outside build-slot's Rust path: `--slug S --cwd TREE [--base origin/main] [--cmd "CMD" ...] [--known-fail REGEX ...] [--notify AGENT] [--comment]`. It fetches, detaches HEAD at the tip, and makes a local merge of `--base` there when the tip lacks it (repo hooks off; a conflict aborts, prints `MERGE-CONFLICT`, exits 3; a merge that fails without a conflict, or would overwrite an ignored lane file, prints `MERGE-FAILED` with the reason, exits 2), runs each command (default: `.herdr-gate` lines, else `make check` then `make test`) with a log at `/tmp/gate_<slug>_<n>.log`, names the distinct `--- FAIL` / `FAIL` / `panic:` / `not ok` lines, and downgrades `--known-fail` matches, never for an rc of 126 or more (`known-only rc=N`) and never past a crash marker in the log (make's `*** [...] Segmentation fault` / `Killed` / `Error 126-255`, `(core dumped)`, a runtime's signal tag; printed as `crash:` lines, the patterns live in `CRASH_RE` in the script), because make exits 2 for a crashed recipe. Anchor the regex (`--known-fail 'TestFlaky \('`): a bare `TestFlaky` also hides `TestFlakyButRealRegression`. The gate owns the tree for its run: never gate a tree a live worker writes to. Gate commands run on a detached HEAD, so in them `git rev-parse --abbrev-ref HEAD` prints `HEAD`, `git symbolic-ref HEAD` fails, `git branch --show-current` prints nothing and `@{upstream}` does not resolve. On every exit, merged or in place, including HUP, INT and TERM, it puts HEAD, the branch, the index and tracked files back exactly as found; untracked files a command creates stay, and files it deletes do not come back. Restore keeps what it would discard first (tracked changes in a stash, a moved detached HEAD as `refs/integration-gate/<slug>/head`, a moved lane branch as `refs/integration-gate/<slug>/moved`, the branch then reset to its SHA), and a verifier compares the result with the snapshot taken before anything ran: `RESTORED:` names what was found and kept only when the verifier confirms the put-back, otherwise `RESTORE MISMATCH:` names what differs and the gate fails. It ends with `GATE-DONE <slug> tip=… merged=… failed=… known=…`; `--notify` wakes the orchestrator with `relay-ctl send --kind job`, on a signal too. Trust boundary: `.herdr-gate` and the Makefile come from the gated tree, the lane under review, and run through `sh -c` with your privileges, so a lane can choose its own gate; the gate warns when the tree's `.herdr-gate` differs from the base's (or the base has none), and `--cmd` gates with commands you chose. Exit 0 no unknown failure, 1 failures or `RESTORE MISMATCH`, 2 usage or `MERGE-FAILED`, 3 merge conflict, 128+signal on a signal
  - `review-package` (0.1.8) writes the L10 review package to one file: `--base B --head H` (whole PR: three dots on both diffs, two on the log) to `/tmp/<slug>_review.diff`, or `--from F --to T [--round N]` (delta after a bounce: two dots throughout) to `/tmp/<slug>_review<N>.diff` (N defaults to 2, so every round keeps its package); `--from` must be an ancestor of `--to` (after a rebase it is refused: use `git range-diff` or re-review the whole PR); an existing package is refused unless `--force`; `--out` overrides, and its directory must exist; refuses (exit 3) when the tree's HEAD is not the reviewed tip; prints the path and line count
  - `jev` is the shared door to the TypeSafe API; `jev-questions.json` holds every question and threshold
  - `waker-ctl` is the org-side client of the org-waker herdr plugin (register, unregister, list, drain, doctor)
- **Hooks** (`hooks/hooks.json`, wired on install):
  - `org-lane-mark.sh` (PreToolUse on Bash and skyline_run) records one line per org event, `dispatch` or `wait`
  - `org-stop-gate.sh` (Stop) blocks a marked session's FIRST stop with the anti-idle sweep
  - `org-conduct-refresh.sh` (SessionStart, matchers `startup|resume|compact`) primes the role-skill contract in fresh sessions and re-injects the re-read order after compaction
- **templates/claude-md.md**: worker guidance to paste into `~/.claude/CLAUDE.md` on a machine that runs lane workers.
- **templates/reviewer-brief.md**: the L10 reviewer-lane dispatch contract — two-stage verdict (spec compliance and artifact quality), severity-ranked findings, forced `READY:` verdict, review-package-as-file.
- **templates/reviewer-delta-brief.md** (0.1.8): the round-2 delta-review contract for a FRESH reviewer after a bounce: CONTEXT (round-1 findings, the ruling, CLOSED ids that stay closed without new evidence, `[MINOR-DEFERRED]`), the two-dot delta package, a FIX MAP stage, delta targeting (the new rule at every writer and consumer, consumers of the new state, mutation tests, docs against code), and the same conduct, verdict, report and NEVER lines as `reviewer-brief.md`. The placeholder list sits in a comment at the top.

## Calibration

The tier criteria `tier-gauge` asks Jev about ship in `scripts/jev-questions.json` and change only by PR. Recalibrate them locally first, in the overlay, and promote a change only once it holds on more than one session's briefs.

- **Where the overlay lives.** `JEV_QUESTIONS_OVERLAY`, default `~/.claude/jev-questions.json`: the same shape as the shipped file, deep-merged over it, and ignored (never fatal) when it does not parse. `scripts/jev doctor` prints whether it was merged. Keep a `_calibration` note in it saying what changed, when, and on which sample.
- **Label briefs from outcomes, not from reading them.** For each finished lane, write `<todo-slug> <tier>` to a labels file, the tier being the one the lane turned out to need: `mechanical` when a transcription-grade brief landed first pass on the cheap tier; `hard` when it took an upgrade, a replacer, or two or more bounces for approach (not typos); `ordinary` otherwise. `tier-gauge --todo <slug> --show-brief` prints the exact text that was gauged (the body, or the latest `[BOUNCE]` DIGEST), so you label what was measured.
- **Compare runs.** Gauge every labelled slug twice, shipped criteria versus overlay, and count agreements per tier. The request checksum covers the questions, so a changed criterion is never answered from cache:

  ```bash
  export HERDR_ORG_ROOT=~/.herdr-org/<org>   # board (and so --todo) refuses to guess an org
  # tier=null in the output means ungauged: no key, no root, or no such todo
  while read -r slug label; do
    shipped=$(JEV_QUESTIONS_OVERLAY=/nonexistent tier-gauge --todo "$slug" --json | jq -r .tier)
    overlay=$(tier-gauge --todo "$slug" --json | jq -r .tier)
    echo "$slug label=$label shipped=$shipped overlay=$overlay"
  done < labels.txt
  ```

  Every call lands in `JEV_AUDIT_FILE` (default `~/.claude/jev-audit.jsonl`, one JSON object per line: `ts`, `set`, `model`, `request_sum`, and `answers`, plus `ms`/`tokens` on live calls, `cache` or `stub` otherwise). The history of a run reads back with `jq -c 'select(.set == "tier-gauge" and (.stub | not)) | {ts, request_sum, tier: .answers.tier.choice, conf: .answers.tier.confidence}' ~/.claude/jev-audit.jsonl`.
- **Promote** to `scripts/jev-questions.json` only when the overlay wins on labelled briefs from at least two sessions. 0.1.8's promotion of the first calibration did NOT meet that bar: it was an operator decision taken after two sessions. Session 1 (18 labelled briefs: tier match 11/18 shipped vs 13/18 overlay, worker briefs 1/4 → 4/4) compared the two; session 2 ran with the overlay active and compared no shipped run (`risky` tracked the real surface on four bounce briefs, 0.54 / 0.71 / 0.93 / 0.15, while `tier` read ordinary on all four and so missed both hard bounce briefs; on bounces read `risky` for surface risk). Both samples are small and session 1 tuned on its own set: re-read the audit after the next session before promoting again. An overlay equal to the shipped criteria is now a no-op; keep yours only for what you are still testing.

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

A brief `tier-gauge` reads as HARD below the top tier (`upgrade=advised`) stops the dispatch before any pane exists: pass `-- --model opus --upgrade-reason "<why>"` or `--keep-tier "<why>"`, filed as `[TIER-KEPT: model=<m> brief_tier=<tier>, <why>]`. To change a just-started worker's model, `dispatch-worker --relaunch <name> --model <m>` (with `--upgrade-reason` or `--keep-tier`) closes its pane and starts the same name in the same lane tree with the same todo, filing `[RELAUNCH: <old pane> -> <new pane>, <why>]`.

## The Herdr substrate at a glance

| Concern | herdr-agent-org |
| --- | --- |
| Board and todos | Filesystem board (`scripts/board`) |
| Worker PTYs | `herdr pane split` plus `agent start` |
| Read and steer | `herdr agent read` / `SendMessage` ping and `relay_send`; never the composer (L11) |
| Wake with lanes in flight | org-relay `relay_await` (task-backed), armed as the turn's last call; fallback `herdr agent wait` |
| Idle wake | nothing armed: a native `SendMessage` ping (pointer plus relay id) or the nudge net starts the turn; `relay_send` returns `live_await`, ping only when it is false or absent (older daemon) (a sender whose turn ends with the send, a worker's doorbell, pings once regardless) |
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
