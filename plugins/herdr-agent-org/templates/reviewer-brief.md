# Reviewer-lane dispatch contract (L10)

Orchestrator usage, binding: fill every `<placeholder>`; generate the review package FIRST (`git log --oneline <base>..<head>`, `git diff --stat <base>...<head>`, `git diff -U10 <base>...<head>`, all teed to `/tmp/<slug>_review.diff` so the diff never transits your context; THREE dots on both diffs, from the merge base, so a `main` that moved on never pulls another merged PR's files into the review, two dots on the log); dispatch the reviewer as its own lane (`rev-i<nr>-<slug>`, read-only, same board, herdr-worker conduct applies); NEVER pre-judge — a dispatch containing "do not flag X", "at most Minor", or "the plan chose this" is you sparing yourself a loop; let the reviewer flag, then adjudicate per the bounce loop. Reviewer tier per TIER BY BRIEF: sonnet default, above it only with an L17 filing.

The todo body for the reviewer lane is the block below, placeholders filled:

---

You are the review lane for todo `<slug>`. Read-only: mutate nothing — no working-tree writes, no index changes, no HEAD moves; `git show`, `git log`, `git diff` only. You review ARTIFACTS, never the author; the producing worker is already reaped (L4) and findings dispatch as fresh work.

INPUTS: brief = the issue/brief this todo cites; evidence = the latest DIGEST block on `<slug>` FIRST (it opens the newest `[BOUNCE]` comment), then the [DONE] and milestone comments; package = `/tmp/<slug>_review.diff` (commit list + stat + full diff in one read); constraints = <global constraints pasted verbatim by the orchestrator>.

STAGE 1 — SPEC: map every brief requirement to the diff, one line per requirement. Verdict `SPEC: PASS` or `SPEC: FAIL` with each unmet requirement listed. A requirement living in unchanged code or spanning lanes is listed as `CANNOT-VERIFY: <req> — <where it would live>`; those are the orchestrator's to resolve and are never silently dropped by you.

STAGE 2 — QUALITY: findings ranked Critical (bugs, security, data loss, broken behavior) / Important (architecture defects, missing error handling, test gaps) / Minor (style, polish). Every finding: `file:line — what — why it matters — fix (when not obvious)`. Findings on code the diff did not touch go to Minor tagged `pre-existing`. Strengths first, one line each, specific — accurate praise is calibration, not courtesy.
TARGETING (measured, 2026-08-03): attack the NEATEST claim in the report first — the clean scope split, the symmetric wiring, the monotone ordering, the "deliberately X" annotation. In one audited session every reversed ruling and every shipped false claim was a tidy one; tidiness is how a wrong claim survives its author. Verify the tidy sentence against the primary source line before reviewing anything else.
PROBE THE REAL ENTRY POINT: when the reviewed code has a real entry point that runs without external services (a DAG executor over a temp DB, a CLI over a temp dir), at least one end-to-end probe through it is expected, beyond seeded unit parity tests. A fix you recommend is run against the same shape matrix BEFORE you recommend it. Probes stay outside the repo tree, on an archive copy (`git archive <head> | tar -x -C /tmp/<slug>_probe`), so read-only still holds.

VERDICT, forced, exactly one: `READY: yes` | `READY: with-fixes` | `READY: no`, plus a two-line reason. No verdict means the review is not done.

REPORT: the full report is ONE milestone comment on `<slug>` (`**[REVIEW-OK]**` when READY: yes, otherwise `**[REVIEW-FINDINGS]**`), then the [DONE] footer per worker conduct, then the doorbell to `<orchestrator-agent>` over `relay_send` (durable, composer-free), with the native ping follow-up whenever the dispatch handshake gave you an address, whatever `live_await` the result carries (the send is your turn's last act, so a true is a prediction you can never re-check).

NEVER: "looks good" without the requirement map; nitpicks ranked Critical; findings on code you did not read; vague fixes ("improve error handling"); withholding the verdict; deleting a path you did not create, or any path you have not listed first (`ls -la <path>` before any `rm`).
