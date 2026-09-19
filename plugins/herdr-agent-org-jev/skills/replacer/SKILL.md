---
name: herdr-replacer
description: Successor pickup on the Herdr substrate. Inherit a predecessor worker's lane from durable state (board todo trail, committed WIP) after context exhaustion, a kill, or a stall. Invoke when a dispatch brief names you as REPLACER.
---

# Replacer (successor pickup)

Your context is fresh; the predecessor's knowledge survives only in artifacts. Trust artifacts, never prose. On Herdr this bites harder than on Solo: your predecessor's pane was reaped and its scrollback went with it, so the board todo and git are all there is.

## This skill is a contract, not a menu

All seven steps below run, in order, before you continue the lane. You are here precisely because a predecessor's state stopped being legible; a step you skip recreates that hole for your own successor, and you will not be the one paying for it. The breach arrives as a reasonable local story ("the handover comment reads complete, the git baseline is a formality"), never as a decision to disobey. Trust artifacts, never prose, and that includes the prose you tell yourself.

1. CONTRACT: read the lane todo body and the issues it references (`board get <slug>`). That is your acceptance criteria. `board` is a bare script on PATH, NEVER a `herdr` subcommand — `command -v board` before ever concluding it is unreachable (verified live 2026-08-01: a replacer guessed `herdr board`, got a real "no such subcommand" error, and wrongly generalized to "no board mechanism exists" — every board write for an otherwise fully-completed task was silently skipped, PICKUP comment included).
2. HANDOVER: read the todo comments newest-first. The last [HANDOVER] or checkpoint comment is your starting state; earlier milestones are history.
3. TREE: verify it yourself with `git status`, `git log --oneline -5`, and `git diff --stat` in the inherited **lane tree** (absolute path from the brief or todo, usually a skyline/skyrift workspace under `<repo>-workspaces/`). If it is a workspace: confirm `.skyrift-workspace` is present and still untracked, and `skyline_workspace_list` with the source's absolute `from_path` should show it. Uncommitted changes described in prose but absent on disk are LOST; say so in your pickup comment instead of guessing.
4. BASELINE: do NOT run cargo or build-slot. Replacers never compile either. Baseline the inherited state from git plus the todo trail; whether it compiles is the orchestrator's gate build, not yours.
5. EXTERNAL TARGETS in inherited next-steps (push remote, PR repo, deploy path, port) are PROPOSED until a one-command proof verifies them (`git ls-remote`, `gh repo view`, a port probe). Nonexistent remotes have been inherited unverified across two generations.
6. PICKUP comment: verified SHA, baseline counts, anything lost against the handover, and your continuation plan. Confirm the predecessor's plan or revise it WITH the stated reason. Deviating from the inherited plan needs a [DESIGN REVISION] comment BEFORE you implement.
7. Continue under herdr-worker rules. The predecessor's reported failures bind you; do not re-try them without saying why.

Note: `skyline_run`'s UNCHANGED dedup is daemon-global, so a verification re-run can return "unchanged since last call" because the PREDECESSOR ran the identical command. The raw tee path in that message is fresh; read it.

## Skylore

On pickup: one `skyline_lore_recall` with the lane keywords plus `repo=` (and unscoped as well if the failure mode smelled machine-wide). Prefer the todo trail for your contract; use lore only so you do not re-burn a gotcha the predecessor or a peer already paid for. Mark only if you discover a new durable fact the next successor will need.
