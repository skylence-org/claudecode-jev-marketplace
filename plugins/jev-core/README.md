# jev-core

[TypeSafe's Jev](https://docs.typesafe.ai) as a decision primitive for Claude Code hooks.

Jev is a System One model: send a state and typed questions, get typed answers and
probabilities back — no generated text, no parsing. That makes it the right tool for the
places a hook needs a *judgment* rather than a regex, and the wrong tool for anything that
needs a sentence written. This plugin puts it in exactly the two places core-claude already
spends a model judgment, and nowhere on the per-tool-call hot path.

## What ships

- **`scripts/jev`** — the one door to the API. `jev ask <set> < state.json` runs a named
  question set from `scripts/jev-questions.json` and prints the answers; `jev threshold`,
  `jev sets`, `jev doctor`, `jev cache-clear`. Fail-open on every infrastructure error,
  response cache by request checksum, one audit line per call in `~/.claude/jev-audit.jsonl`
  (answers and a state checksum, never the state), and `JEV_STUB_ANSWERS` for tests.
  POSIX sh + curl + jq only, so the same file ships in every plugin here byte-identical.
- **`scripts/jev-questions.json`** — every question and threshold in one reviewable file.
  Tune per box in `~/.claude/jev-questions.json` (same shape, merged over the shipped file).
- **`hooks/jev-intent-gate.sh`** (PreToolUse) — the two dependency rules core-claude's
  judge-hook ships as `class: escalate`, answered by Jev: is this pinned version backed by a
  registry lookup or the lockfile? Regex pre-match first; every unrelated call exits before
  any network.
- **`hooks/jev-research-nudge.sh`** (Stop) — a hedged factual claim in the last turn gets one
  nudge to verify it. Regex hedge gate first; silent in agent-org sessions.

## Install

```
/plugin marketplace add skylence-org/claudecode-jev-marketplace
/plugin install jev-core@claudecode-jev-marketplace
```

Then, once per box, in your own shell (never paste the key into a chat):

```powershell
[Environment]::SetEnvironmentVariable('TYPESAFE_API_KEY', '<key from https://console.typesafe.ai/keys>', 'User')
```

```bash
export TYPESAFE_API_KEY=...   # macOS / Linux: in your shell profile
```

Restart Claude Code, then `sh "<plugin-root>/scripts/jev" doctor` prints the key state,
the question sets, and one live `/v1/models` call.

Without a key every hook is inert and says so once on stderr; nothing blocks.

## Request budget

Both hooks are gated by a regex before Jev is asked, so a normal session makes a handful of
calls: the intent gate only on a pinned install or a manifest edit, the nudge only on a stop
whose last turn contains a hedge word. Each call is a few hundred input tokens at
$0.042 per million; output is free. Measured round trip from Western Europe: ~1.1 s cold,
sub-second warm. Hook timeout is 5 s (`JEV_TIMEOUT`); measured round trips were 1.1-1.5 s.

## Running beside core-claude

If `core-claude` is installed too, its judge-hook and research-nudge still run. Disable the
overlapping pieces so a judgment is not made twice:

```json
// ~/.claude/judge-rules.json
{ "disable": ["deps.pinned-install", "deps.manifest-edit"] }
```

research-nudge has no per-rule switch: with both plugins installed, a hedged turn draws two
nudges (core-claude's `claude -p` one and this one). Keep whichever you prefer by removing
the other plugin's Stop hook entry from your settings. The deny/allow/gated rules in
judge-hook are code and stay exactly where they are — Jev is not a replacement for a regex.

## Why not the other judge-hook rules

`git.remote-branch-delete` asks whether the branch name appears *verbatim* in a recent user
message. That is an exact-string question; Jev reads literally and is worse than grep at it
(its own [jaggedness page](https://docs.typesafe.ai/model-jaggedness/jev-1.13) says so). It
belongs in judge-hook's `gated` class with a transcript probe, not here.

## Reading the audit log

```bash
tail -n 20 ~/.claude/jev-audit.jsonl | jq -c '{ts, set, ms, answers}'
```

A week of that is what the thresholds should be tuned against. Jev is calibrated as a
population property, not per answer: a 0.7 means "right about 70% of the time across many
such answers", so pick the bar from the cost of each kind of mistake, not from one case.

## Tests

`bash plugins/jev-core/tests/jev.test.sh` — stub-driven, no key, no network, no tokens.
