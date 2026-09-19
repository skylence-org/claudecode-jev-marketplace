# core

The opinionated Claude Code baseline, with [TypeSafe's Jev](https://docs.typesafe.ai) deciding
the judgments the baseline used to spend a `claude -p` subprocess on.

Forked from [multi-llm-marketplace](https://github.com/skylence-org/multi-llm-marketplace)'s
`core-claude` 0.9.8. `/core:setup` installs the whole baseline in one no-prompt run;
`/core:doctor` audits it read-only. **Replaces `core-claude`; never install both** — the
hooks would fire twice.

## What `/core:setup` installs

| Component | Where | What it does |
|-----------|-------|--------------|
| `judge-hook.sh` | plugin `hooks/`, `PreToolUse` | Rules engine over tool inputs: `deny`, `allow`, `gated` (fact probe), `escalate`. Skyline-aware. Unchanged from core-claude. |
| `judge-rules.json` | plugin `hooks/` | The complete ruleset, plugin-owned. Two rules fewer than core-claude's: `deps.pinned-install` and `deps.manifest-edit` are decided by `jev-intent-gate` instead. |
| `~/.claude/judge-rules.json` | your machine | Overlay, empty by default: `rules`, `only`, `disable`, `override`. Unchanged from core-claude. |
| **`jev-intent-gate.sh`** | plugin `hooks/`, `PreToolUse` | The dependency version-pin rules, decided by Jev: regex pre-match, then ONE request asking whether the pinned version is backed by a registry lookup or the lockfile (`lookup_seen`) and whether the edit raises a version (`raises_version`). Blocks with a templated reason naming the numbers. |
| `writing-guard.sh` | plugin `hooks/`, `PostToolUse` | Flags AI writing tells in newly written content. Unchanged. |
| **`jev-research-nudge.sh`** | plugin `hooks/`, `Stop` | A hedged, checkable factual claim in the last turn gets one nudge to verify it. Regex hedge gate, then ONE Jev Noul. Silent in agent-org sessions. Replaces core-claude's haiku subprocess. |
| **`scripts/jev`** | plugin `scripts/` | The one door to the API: `jev ask <set>`, `jev threshold`, `jev sets`, `jev doctor`, `jev cache-clear`. Fail-open, response cache, audit log (`~/.claude/jev-audit.jsonl`), `JEV_STUB_ANSWERS` for tests. POSIX sh + curl + jq. |
| **`scripts/jev-questions.json`** | plugin `scripts/` | Every Jev question and threshold, in one file. |
| **`~/.claude/jev-questions.json`** | your machine | Overlay, empty by default; same shape, recursively merged, for tuning thresholds per box. |
| `core-hud.sh` | `~/.claude/`, `statusLine` | Four-line HUD: model + effort chip + project ⎇ branch stats; gradient context bar; 5h/7d quota lines with a burn-rate engine. The one file still copied, because `statusLine` takes a plain command path. Unchanged. |
| Guidelines | `~/.claude/CLAUDE.md` | Advisor, Decisive Thinking, Coding, Review Mindset, Writing — between `core:guidelines` markers. Unchanged, and the marker names are kept so a `core-claude` install's block is replaced in place, not duplicated. |
| `/core:doctor` | skill | Read-only audit: proves the judge gate by running it, flags double-fire wiring, reports the overlays, statusline drift, guidelines sync, version stamp — plus `jev doctor` (key, question sets, one live `/v1/models` call) and the audit-log tail. |
| `/core:session-handoff`, `/core:uninstall-claude`, `/core:purge-claude-user-scope` | skills | Unchanged from core-claude. The Solo-substrate skills (`solo-setup`, `solo-session-handoff`) are not carried: no Solo plugin lives in this marketplace. |

## Install

```
/plugin marketplace add skylence-org/claudecode-jev-marketplace
/plugin install core@claudecode-jev-marketplace
/core:setup
```

Then, once per box, in your own shell (never paste the key into a chat):

```powershell
[Environment]::SetEnvironmentVariable('TYPESAFE_API_KEY', '<key from https://console.typesafe.ai/keys>', 'User')
```

```bash
export TYPESAFE_API_KEY=...   # macOS / Linux: in your shell profile
```

Restart Claude Code so the hooks and statusline take effect. Without a key every Jev hook is
inert and says so once on stderr; the judge-hook, writing-guard, HUD, and guidelines work
exactly as in core-claude.

## Migrating from core-claude

Uninstall `core-claude` first (`/plugin uninstall core-claude@multi-llm-marketplace`), then
install this and run `/core:setup`. Everything on disk is compatible: the same
`~/.claude/judge-rules.json` overlay, the same `core-hud.sh` path, the same fence markers in
`CLAUDE.md` and the shell profile. The version stamp moves from `~/.claude/.core-claude-version`
to `~/.claude/.core-version`; the old file is harmless and can be deleted.

## Permission posture

`/core:setup` sets `permissions.defaultMode` to `bypassPermissions`, exactly as
core-claude does. Per-call permission prompts go away; the judge-hook plus its rules become
the safety gate, and PreToolUse hooks still run under bypass mode. Jev is not part of that gate:
both Jev hooks fail open, so they can only ever add a block, never remove one.

## Request budget

Both Jev hooks are gated by a regex before Jev is asked, so a normal session makes a handful
of calls: the intent gate only on a pinned install or a manifest edit, the nudge only on a
stop whose last turn contains a hedge word. Each call is a few hundred input tokens at $0.042
per million; output is free. Measured round trips from Western Europe: 1.1–1.5 s. Hook timeout
is 5 s (`JEV_TIMEOUT`).

## Why the other judge-hook rules are not on Jev

Deny, allow, and gated rules are regexes and fact probes: code answers them exactly.
`git.remote-branch-delete` asks whether the branch name appears *verbatim* in a recent user
message — an exact-string question Jev reads literally and grep answers better (the vendor's
own [jaggedness page](https://docs.typesafe.ai/model-jaggedness/jev-1.13) says so). It stays
`escalate`, inert by choice on OAuth boxes, as upstream documents.

## Reading the audit log

```bash
tail -n 20 ~/.claude/jev-audit.jsonl | jq -c '{ts, set, ms, answers}'
```

A week of that is what the thresholds should be tuned against. Jev's calibration is a
population property: a 0.7 means "right about 70% of the time across many such answers", so
pick each bar from the cost of that kind of mistake, then set it in `~/.claude/jev-questions.json`.

## Tests

```bash
bash plugins/core/tests/jev.test.sh          # jev helper + both Jev hooks; stub-driven, no key, no tokens
bash plugins/core/hooks/judge-hook.test.sh   # the judge-hook suite, unchanged from upstream; stubs the claude CLI
```
