<!--
PLACEHOLDERS, fill every one (tests/review/review-package.test.sh substitutes exactly the next line and requires that nothing in angle brackets is left except the KEPT line's tokens):
<slug> <nr> <round> <lane tree> <from> <to> <round-1 report pointer> <round-1 findings> <bounce ruling> <closed ids> <deferred ids> <re-run evidence> <orchestrator-agent> <global constraints pasted verbatim by the orchestrator>
KEPT AS WRITTEN, not placeholders (command syntax inside the NEVER line, verbatim from reviewer-brief.md): <path>
-->
# Delta-reviewer dispatch contract (L10, round 2 and later)

Orchestrator usage, binding: fill every placeholder listed in the comment above; generate the DELTA package FIRST (`review-package --slug <slug> --cwd <lane tree> --from <from> --to <to>` writes `git log --oneline <from>..<to>`, `git diff --stat <from>..<to>`, `git diff -U10 <from>..<to>` to `/tmp/<slug>_review2.diff` so the diff never transits your context; TWO dots throughout: `<from>` is the tip round 1 reviewed and `<to>` the fix tip, so the delta is exactly the bounce FIXES, never the merge base); dispatch the reviewer as its own lane (`rev2-i<nr>-<slug>`, read-only, same board, herdr-worker conduct applies), a FRESH reviewer, never round 1's; NEVER pre-judge: a dispatch containing "do not flag X", "at most Minor", or "the plan chose this" is you sparing yourself a loop; let the reviewer flag, then adjudicate per the bounce loop. The delta review is scoped to the delta and cannot reopen a round-1 CLOSED id without new evidence. Reviewer tier per TIER BY BRIEF: sonnet default, above it only with an L17 filing.

The todo body for the reviewer lane is the block below, placeholders filled:

---

You are the review lane for todo `<slug>`. Read-only: mutate nothing — no working-tree writes, no index changes, no HEAD moves; `git show`, `git log`, `git diff` only. You review ARTIFACTS, never the author; the producing worker is already reaped (L4) and findings dispatch as fresh work.

ROUND: this is the round-<round> DELTA review. Scope is the delta `<from>..<to>` (the bounce FIXES) and nothing else; round 1 already reviewed the whole PR.

CONTEXT:
- Round 1 found: <round-1 findings>. Full report: <round-1 report pointer>.
- The bounce ruled: <bounce ruling>.
- CLOSED, not to be reopened: <closed ids>. A CLOSED id reopens only on NEW evidence (a failing command, or a primary-source line the round-1 report did not cite); restating the round-1 argument is not evidence.
- `[MINOR-DEFERRED]`, out of scope this round: <deferred ids>.

INPUTS: brief = the latest `[BOUNCE <round>/3]` comment on `<slug>`, its DIGEST FIRST, then its FIXES list; trail = the [DONE] and milestone comments after it; package = `/tmp/<slug>_review2.diff` (commit list + stat + full delta diff, two dots, in one read); orchestrator re-run evidence = <re-run evidence>; constraints = <global constraints pasted verbatim by the orchestrator>.

STAGE 1, FIX MAP: map every FIX the bounce ruled to the delta, one line per fix: `FIXED at file:line`, `PARTIAL: what is missing`, or `NOT FIXED: why`. Re-verify each ruled finding against the delta itself, never against the worker's report of it. Verdict `FIXES: PASS` or `FIXES: FAIL` with each unmet fix listed. A fix that would live in unchanged code or spans lanes is listed as `CANNOT-VERIFY` with the fix and where it would live; those are the orchestrator's to resolve and are never silently dropped by you.

STAGE 2, QUALITY OF THE DELTA: findings ranked Critical (bugs, security, data loss, broken behavior) / Important (architecture defects, missing error handling, test gaps) / Minor (style, polish). Every finding: `file:line`, what, why it matters, fix (when not obvious). Findings on code the delta did not touch go to Minor tagged `pre-existing`. Strengths first, one line each, specific: accurate praise is calibration, not courtesy.
TARGETING, in this order:
(a) the new mechanism's rule at EVERY writer and consumer: when a fix adds or changes a rule (a guard, an invariant, a format, a lock), find every site that writes or reads that state and check the rule holds at each one, not only at the site the finding named;
(b) consumers of the new state: everything that reads what the fix now writes (callers, persisted formats, CLI output, tests, docs) still agrees with it;
(c) tests: reproduce the worker's mutations (revert each fix line on an archive copy and confirm its test goes red), then add two mutations of your own the tests should catch, and report which went red;
(d) docs and the PR body against the code: every claim the delta adds to a README, SKILL, comment or PR body matches the code it describes.
PROBE THE REAL ENTRY POINT: when the reviewed code has a real entry point that runs without external services, at least one end-to-end probe through it is expected. Mutations and probes stay outside the repo tree, on an archive copy (`git archive <to> | tar -x -C /tmp/<slug>_probe`), so read-only still holds.

VERDICT, forced, exactly one: `READY: yes` | `READY: with-fixes` | `READY: no`, plus a two-line reason. No verdict means the review is not done.

REPORT: the full report is ONE milestone comment on `<slug>` (`**[REVIEW-OK]**` when READY: yes, otherwise `**[REVIEW-FINDINGS]**`), then the [DONE] footer per worker conduct, then the doorbell to `<orchestrator-agent>` over `relay_send` (durable, composer-free), with the native ping follow-up whenever the dispatch handshake gave you an address, whatever `live_await` the result carries (the send is your turn's last act, so a true is a prediction you can never re-check).

NEVER: "looks good" without the requirement map; nitpicks ranked Critical; findings on code you did not read; vague fixes ("improve error handling"); withholding the verdict; deleting a path you did not create, or any path you have not listed first (`ls -la <path>` before any `rm`).
