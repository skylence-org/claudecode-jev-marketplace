#!/bin/bash
# shipped-criteria.test.sh: pins the shipped scripts/jev-questions.json to the
# criteria promoted from the two-session calibration (marketplace#14): the
# tier descriptions, the risky wording, _calibration, every threshold, and
# every shipped-only set and question. A future edit to the criteria changes
# this file in the same PR, on purpose.
#
# Run: bash plugins/herdr-agent-org/tests/jev/shipped-criteria.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
Q="$PLUGIN/scripts/jev-questions.json"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

# The intended values, verbatim (tier criteria and risky wording as promoted
# from the calibrated overlay; calibration text as the lane brief fixed it).
EXPECTED=$(cat <<'JSON'
{
  "tier": {
    "mechanical": {
      "what": "Transcription-grade: complete code blocks, exact file paths and line ranges, each step one action with its command and expected output, acceptance checks as exact commands with expected counts. The worker types; it invents nothing. A fix brief that hands over the exact replacement lines also fits here.",
      "not_for": "A brief that says what to build without showing how, and any REVIEW lane: reviewing always needs judgment."
    },
    "ordinary": {
      "what": "Ordinary engineering: the goal and acceptance criteria are clear and the interfaces are named, but the worker chooses the implementation, writes tests from a description, or fills in details the brief leaves open. Includes: a fix round whose findings already carry file:line evidence and an explicit ruling per finding; diagnosing a reproducible failure along a stated hypothesis with a repro loop; reviewing a diff that stays inside one subsystem or is test-only or config-only.",
      "not_for": "A brief with every code block already written, one whose acceptance is ambiguous, or one listed under hard."
    },
    "hard": {
      "what": "Hard or high-stakes: the change spans three or more subsystems, or two or more code paths or consumers must stay consistent with each other (two surfaces computing the same verdict, a writer and a reader of a new format); security-sensitive code (secrets, encryption keys, credential storage, authentication) or concurrency and timeouts around persistent state; the brief's premise about the existing code is unverified or contested; ambiguous acceptance criteria; cross-repo blast radius; a prior round failed because the APPROACH was wrong; or reviewing a diff with any of these properties.",
      "not_for": "A large but fully specified task, a fix round with an explicit ruling per finding, or a diagnosis with a clear repro loop."
    }
  },
  "risky": "Does `brief` have the worker touch release or CI configuration, authentication or authorization, secrets, encryption keys or credential storage, data integrity (migrations, schemas, money, persistence formats), parser or resolution logic, or state that cannot be undone?",
  "calibration": "2026-10-31 two labelled sessions (skyway). Session 1: 18 briefs (4 worker, 6 bounce, 8 reviewer); labels = what the work turned out to need; tier match 11/18 uncalibrated, 13/18 with these criteria; worker briefs 1/4 to 4/4. Session 2 (these criteria active): bounce briefs risky 0.54 / 0.71 / 0.93 / 0.15 tracked the surface; tier read ordinary on all four bounce briefs, including two whose surface (a runner terminal-row invariant, encryption-key storage) the orchestrator ran on Opus; on bounces tier measures design burden, use risky for surface risk. Small samples, session 1 tuned on its own set: re-read jev-audit.jsonl after the next session."
}
JSON
)

echo "--- shipped jev-questions.json (marketplace#14) ---------------------------"
jq -e . "$Q" >/dev/null 2>&1 && ok "parses as JSON" || { bad "parse" "jq -e . $Q failed"; echo "shipped-criteria: $PASS passed, $FAIL failed"; exit 1; }

TG='.sets["tier-gauge"]'
for c in mechanical ordinary hard; do
  for f in what not_for; do
    got=$(jq -r "$TG.questions.tier.criteria.$c.$f" "$Q")
    want=$(printf '%s' "$EXPECTED" | jq -r ".tier.$c.$f")
    [ "$got" = "$want" ] && ok "tier.$c.$f is the calibrated wording" || bad "tier.$c.$f" "got: $got"
  done
done
[ "$(jq -r "$TG.questions.tier.criteria | keys | join(\",\")" "$Q")" = "hard,mechanical,ordinary" ] && ok "tier choices are exactly mechanical, ordinary, hard" || bad "tier choices" "$(jq -c "$TG.questions.tier.criteria | keys" "$Q")"
got=$(jq -r "$TG.questions.risky.instructions" "$Q"); want=$(printf '%s' "$EXPECTED" | jq -r .risky)
[ "$got" = "$want" ] && ok "risky question names secrets, encryption keys and credential storage" || bad "risky" "got: $got"
got=$(jq -r ._calibration "$Q"); want=$(printf '%s' "$EXPECTED" | jq -r .calibration)
[ "$got" = "$want" ] && ok "_calibration is the two-session record" || bad "_calibration" "got: $got"
jq -r ._comment "$Q" | grep -q '^Every Jev question and threshold the herdr org uses' && ok "_comment is the shipped file's own text, not the overlay's" || bad "_comment" "$(jq -r ._comment "$Q")"

# Shipped-only content the overlay never carried: still present, unchanged.
jq -e "$TG.questions.tier.type == \"choice\" and ($TG.questions.tier.instructions.question | test(\"Which description fits\")) and ($TG.questions.tier.instructions.focus | test(\"DESIGN or DECIDE\"))" "$Q" >/dev/null && ok "tier keeps its type and instructions" || bad "tier shape" "$(jq -c "$TG.questions.tier | del(.criteria)" "$Q")"
jq -e "$TG.questions.risky.type == \"noul\" and ($TG.questions.risky.criteria | has(\"true\") and has(\"false\"))" "$Q" >/dev/null && ok "risky keeps its type and criteria" || bad "risky shape" "$(jq -c "$TG.questions.risky" "$Q")"
jq -e "$TG.questions | has(\"names_lane_tree\") and has(\"orders_milestones\") and has(\"inlines_board_snippets\")" "$Q" >/dev/null && ok "the three template-lint questions are present" || bad "lint questions" "$(jq -c "$TG.questions | keys" "$Q")"
jq -e "$TG.thresholds == {\"downgrade_bar\":0.6,\"upgrade_bar\":0.3,\"risky\":0.7,\"lint\":0.5}" "$Q" >/dev/null && ok "tier-gauge thresholds unchanged (0.6 / 0.3 / 0.7 / 0.5)" || bad "tg thresholds" "$(jq -c "$TG.thresholds" "$Q")"
jq -e '.sets["review-gate"].thresholds == {"gate_lines":150,"surface":0.7,"max_diff_chars":80000}' "$Q" >/dev/null && ok "review-gate set present, thresholds unchanged (150 / 0.7 / 80000)" || bad "review-gate thresholds" "$(jq -c '.sets["review-gate"].thresholds' "$Q")"
[ "$(jq -r '.sets["review-gate"].questions | keys | join(",")' "$Q")" = "touches_auth,touches_data_integrity,touches_parser_resolution,touches_release_ci" ] && ok "review-gate keeps its four surface questions" || bad "review-gate questions" "$(jq -c '.sets["review-gate"].questions | keys' "$Q")"
jq -e '(.sets["tier-gauge"]._used_by | length > 0) and (.sets["review-gate"]._used_by | length > 0) and (._model_note | test("jev-1.13.0"))' "$Q" >/dev/null && ok "_used_by on both sets and _model_note kept" || bad "notes" "$(jq -c '{a: .sets["tier-gauge"]._used_by, b: .sets["review-gate"]._used_by}' "$Q")"
[ "$(jq -r 'keys_unsorted | join(",")' "$Q")" = "_comment,_model_note,_calibration,sets" ] && ok "top-level keys in house order (_comment, _model_note, _calibration, sets)" || bad "key order" "$(jq -c keys_unsorted "$Q")"

echo
echo "shipped-criteria: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
