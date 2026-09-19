# claudecode-jev-marketplace

[TypeSafe's Jev](https://docs.typesafe.ai) wired into Claude Code.

Jev is a System One model: send a state and typed questions (Choice, Score, Noul), get typed
answers and calibrated probabilities back. No generated text, no parsing, ~100 ms, output
tokens free. That makes it a decision primitive a shell hook can call the way it calls `jq`,
and this marketplace is the place that gets built out. The sibling
[multi-llm-marketplace](https://github.com/skylence-org/multi-llm-marketplace) stays as it is.

Owner: Skylence (github.com/skylence-org).

## Principle

Jev goes only at **event boundaries the system already treats as rare** — a stop, a dispatch,
an accept, an escalation — never on the per-tool-call hot path, and never where a regex,
arithmetic, or a fact probe already answers the question. One request per event; the
questions inside it run in parallel and cost nothing extra. Every call fails open, is cached
by request checksum, and leaves one audit line in `~/.claude/jev-audit.jsonl`. Every question
and threshold lives in one `jev-questions.json` per plugin, overridable per box.

## Plugins

- **`jev-core`** — the `jev` shell helper and two hooks that replace `claude -p` subprocess
  judgments in core-claude: `jev-intent-gate` (PreToolUse: is this pinned dependency version
  backed by a registry lookup?) and `jev-research-nudge` (Stop: did the last turn hedge a
  checkable fact?). [README](plugins/jev-core/README.md).
- **`herdr-agent-org-jev`** — the Skylence herdr agent-org, forked from
  `herdr-agent-org-claude` 2.4.1, with Jev at two event boundaries: `tier-gauge` inside
  `dispatch-worker` (L17 TIER BY BRIEF, measured) and `review-gate-check` at accept (L10 review
  gate, measured). Everything else is the upstream org unchanged.
  [README](plugins/herdr-agent-org-jev/README.md).

## Install

```
/plugin marketplace add skylence-org/claudecode-jev-marketplace
/plugin install jev-core@claudecode-jev-marketplace
/plugin install herdr-agent-org-jev@claudecode-jev-marketplace   # instead of herdr-agent-org-claude
```

Set `TYPESAFE_API_KEY` in your shell environment (a key from
https://console.typesafe.ai/keys; never paste it into a chat) and restart Claude Code. Without
a key every Jev call is fail-open: hooks allow, dispatches go ungauged, and one stderr line
says so. `sh plugins/jev-core/scripts/jev doctor` checks the setup.

## What is deliberately NOT on Jev

- `ghost-probe` (the no-fusion classifier): a deterministic diff of two pane tails. Must stay
  deterministic; Jev reads literally and is text-only.
- `writing-guard`: every Write/Edit. Hot path.
- The org-relay nudge watchdog: timing, nothing semantic.
- `run-conduct.sh`: a live model under pressure *is* the subject under test.
- The reviewer lane: finding findings needs generation.
- The architect dry-read gate: the doctrine says the gauge must be the priced worker tier.
- `git.remote-branch-delete`: "does the branch name appear verbatim in a user message" is
  grep's job (judge-hook's `gated` class), not a judgment.

## Development

```bash
sh tools/check-parity.sh                                  # jev twins byte-identical, wiring phrases present
bash plugins/jev-core/tests/jev.test.sh                   # stub-driven, no key, no tokens
bash plugins/herdr-agent-org-jev/tests/jev/gauge.test.sh  # same
sh plugins/herdr-agent-org-jev/tests/conduct/run-conduct.sh --self-test
git config core.hooksPath .githooks                       # once per clone
```

Local marketplace for a checkout: `/plugin marketplace add /path/to/this/repo`.

## Thresholds are starting points

Every bar shipped here comes from the vendor's cookbooks and the doctrine's own measurements,
not from this box's data. Jev's calibration is a population property (a 0.7 is right about
70% of the time across many such answers), so the right bar depends on the cost of each kind
of mistake. Read a week of `~/.claude/jev-audit.jsonl`, then move numbers in
`~/.claude/jev-questions.json`. The model is pinned to `jev-1.13.0` for the same reason;
bump `JEV_MODEL` deliberately, after re-reading the audit log against the new version.
