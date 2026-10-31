#!/bin/bash
# gauge.test.sh: tier-gauge and review-gate-check, driven by JEV_STUB_ANSWERS.
# No key, no network, no tokens. dispatch-worker itself needs a live herdr and
# is not exercised here; its gauge call is one guarded line that consumes
# tier-gauge's exit code, which this suite pins.
#
# Run: bash plugins/herdr-agent-org/tests/jev/gauge.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
TG="$PLUGIN/scripts/tier-gauge"
RG="$PLUGIN/scripts/review-gate-check"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export TMPDIR="$TMP"
unset TYPESAFE_API_KEY JEV_DISABLE JEV_QUESTIONS_OVERLAY 2>/dev/null || true
export JEV_AUDIT_FILE="$TMP/audit.jsonl"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
stub() { printf '%s' "$1" >"$TMP/stub.json"; printf '%s' "$TMP/stub.json"; }

printf 'Implement the thing. Use good judgment about the schema.\n' >"$TMP/brief.md"
tg() { # <model> <stub json> -> OUT, ERR, RC
  local s; s=$(stub "$2")
  OUT=$(JEV_STUB_ANSWERS="$s" sh "$TG" --brief-file "$TMP/brief.md" ${1:+--model "$1"} 2>"$TMP/err"); RC=$?
  ERR=$(cat "$TMP/err")
}
ANS_ORD='{"tier-gauge":{"tier":{"choice":"ordinary","confidence":0.81,"probabilities":{"mechanical":0.1,"ordinary":0.8,"hard":0.1}},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'
ANS_MECH='{"tier-gauge":{"tier":{"choice":"mechanical","confidence":0.9},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'
ANS_HARD='{"tier-gauge":{"tier":{"choice":"hard","confidence":0.55},"risky":{"noul":0.85},"names_lane_tree":{"noul":0.2},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'
ANS_LOWCONF='{"tier-gauge":{"tier":{"choice":"ordinary","confidence":0.3},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'

echo "--- tier-gauge --------------------------------------------------------"

tg haiku "$ANS_ORD"
if [ $RC -eq 3 ] && printf '%s' "$OUT" | grep -q 'verdict=refuse' && printf '%s' "$ERR" | grep -q 'REFUSED'; then ok "haiku on an ordinary brief at 0.81: refuse (exit 3)"; else bad "refuse" "rc=$RC out=$OUT err=$ERR"; fi

tg haiku "$ANS_MECH"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'tier=mechanical.*verdict=ok'; then ok "haiku on a mechanical brief: ok"; else bad "haiku mech" "rc=$RC out=$OUT"; fi

tg haiku "$ANS_LOWCONF"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'verdict=ok'; then ok "haiku on ordinary at conf 0.3 (< downgrade bar): not refused"; else bad "lowconf" "rc=$RC out=$OUT"; fi

tg sonnet "$ANS_ORD"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'verdict=ok'; then ok "sonnet (default) on ordinary: ok"; else bad "sonnet ord" "rc=$RC out=$OUT"; fi

tg sonnet "$ANS_HARD"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'verdict=warn' && printf '%s' "$ERR" | grep -q 'reads as HARD' && printf '%s' "$ERR" | grep -q 'MANDATORY-REVIEW' && printf '%s' "$OUT" | grep -q 'lint=lane-tree-path'; then ok "sonnet on hard+risky+missing tree path: warn (never auto-upgrade), all three warnings"; else bad "hard warn" "rc=$RC out=$OUT err=$ERR"; fi

tg opus "$ANS_HARD"
if [ $RC -eq 0 ] && ! printf '%s' "$ERR" | grep -q 'reads as HARD'; then ok "opus on hard: no tier warning"; else bad "opus hard" "rc=$RC err=$ERR"; fi

tg sonnet "$ANS_HARD"
if printf '%s' "$OUT" | grep -q 'upgrade=advised'; then ok "hard brief below the top tier: verdict line carries upgrade=advised"; else bad "advised" "out=$OUT"; fi
tg opus "$ANS_HARD"
if ! printf '%s' "$OUT" | grep -q 'upgrade=advised'; then ok "hard brief on the top tier: no upgrade=advised"; else bad "advised top" "out=$OUT"; fi
tg sonnet "$ANS_ORD"
if ! printf '%s' "$OUT" | grep -q 'upgrade=advised'; then ok "ordinary brief: no upgrade=advised"; else bad "advised ord" "out=$OUT"; fi

ANS_NOMILE='{"tier-gauge":{"tier":{"choice":"ordinary","confidence":0.81},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.1},"inlines_board_snippets":{"noul":0.9}}}'
tg sonnet "$ANS_NOMILE"
if printf '%s' "$OUT" | grep -q 'lint=milestone-comments'; then ok "worker brief without milestone orders: milestone-comments linted"; else bad "mile control" "out=$OUT"; fi
printf 'You are the review lane for todo `lane-x`. Read-only: mutate nothing.\n' >"$TMP/review.md"
OUT=$(JEV_STUB_ANSWERS="$(stub "$ANS_NOMILE")" sh "$TG" --brief-file "$TMP/review.md" --model sonnet 2>"$TMP/err"); RC=$?
if [ $RC -eq 0 ] && ! printf '%s' "$OUT" | grep -q 'milestone-comments' && ! grep -q 'brief template items' "$TMP/err"; then ok "review-lane brief (template header): milestone-comments lint skipped"; else bad "review header" "rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi
mkdir -p "$TMP/org"
HERDR_ORG_ROOT="$TMP/org" sh "$PLUGIN/scripts/board" init "$TMP/org" >/dev/null 2>&1
HERDR_ORG_ROOT="$TMP/org" sh "$PLUGIN/scripts/board" create rev2-i9-lane --title "review" --body-file "$TMP/brief.md" >/dev/null 2>&1
OUT=$(PATH="$PLUGIN/scripts:$PATH" HERDR_ORG_ROOT="$TMP/org" JEV_STUB_ANSWERS="$(stub "$ANS_NOMILE")" sh "$TG" --todo rev2-i9-lane --model sonnet 2>/dev/null); RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'tier=ordinary' && ! printf '%s' "$OUT" | grep -q 'milestone-comments'; then ok "review-lane todo name (rev2-): milestone-comments lint skipped"; else bad "review name" "rc=$RC out=$OUT"; fi

echo "--- tier-gauge gauges what the next worker receives (0.1.7) ---------"
bd() { PATH="$PLUGIN/scripts:$PATH" HERDR_ORG_ROOT="$TMP/org" sh "$PLUGIN/scripts/board" "$@" >/dev/null 2>&1; }
tgt() { OUT=$(PATH="$PLUGIN/scripts:$PATH" HERDR_ORG_ROOT="$TMP/org" JEV_STUB_ANSWERS="$(stub "$ANS_NOMILE")" sh "$TG" --todo "$@" 2>"$TMP/err"); RC=$?; }
printf 'Implement the whole replay engine from scratch; design the schema yourself.\n' >"$TMP/orig.md"
bd create lane-r --title "replay" --body-file "$TMP/orig.md"
bd comment lane-r "**[PHASE 1 DONE]** 12 passed"
printf '**[BOUNCE 2/3]**\nDIGEST\n- rulings: R1 keep the public API\n- CLOSED: F1\n- DEFERRED: F4\n- tip: abc1234\n\nRULING: fix F2 and F3 exactly as listed.\n' | PATH="$PLUGIN/scripts:$PATH" HERDR_ORG_ROOT="$TMP/org" sh "$PLUGIN/scripts/board" comment lane-r --stdin >/dev/null 2>&1
bd comment lane-r "**[TIER-GAUGE: later filing]** at dispatch"
: >"$JEV_AUDIT_FILE"
tgt lane-r --show-brief
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'RULING: fix F2' && printf '%s' "$OUT" | grep -q 'DIGEST' && ! printf '%s' "$OUT" | grep -q 'from scratch' && ! printf '%s' "$OUT" | grep -q 'later filing' && [ ! -s "$JEV_AUDIT_FILE" ]; then ok "--show-brief on a bounced todo: the latest [BOUNCE] DIGEST + ruling, not the body, not a later filing, no Jev call"; else bad "show bounce" "rc=$RC out=$OUT"; fi
tgt lane-r --model sonnet
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'source=bounce' && ! printf '%s' "$OUT" | grep -q 'lint='; then ok "bounced todo: verdict says source=bounce, template lint skipped"; else bad "bounce verdict" "rc=$RC out=$OUT"; fi
printf '**[BOUNCE 3/3]**\nDIGEST\n- tip: def5678\n\nRULING: only F5 remains.\n' | PATH="$PLUGIN/scripts:$PATH" HERDR_ORG_ROOT="$TMP/org" sh "$PLUGIN/scripts/board" comment lane-r --stdin >/dev/null 2>&1
tgt lane-r --show-brief
if printf '%s' "$OUT" | grep -q 'only F5' && ! printf '%s' "$OUT" | grep -q 'F2 and F3'; then ok "two bounces: the LATEST one is gauged"; else bad "latest bounce" "out=$OUT"; fi
bd create lane-p --title "plain" --body-file "$TMP/orig.md"
bd comment lane-p "**[PHASE 1 DONE]** milestone only"
tgt lane-p --model sonnet
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'source=body' && printf '%s' "$OUT" | grep -q 'lint=milestone-comments'; then ok "no [BOUNCE] comment: the body is gauged and linted (source=body)"; else bad "body source" "rc=$RC out=$OUT"; fi
bd comment rev2-i9-lane "**[BOUNCE 1/3]** DIGEST: a trail the review lane inherited"
tgt rev2-i9-lane --show-brief
if printf '%s' "$OUT" | grep -q 'Implement the thing' && ! printf '%s' "$OUT" | grep -q 'inherited'; then ok "review lane with a [BOUNCE] comment: its brief is gauged, never the inherited trail"; else bad "review source" "out=$OUT"; fi
# PR #9 review: only an orchestrator-formatted [BOUNCE r/n] comment counts.
bdin() { slug=$1; shift; printf "$@" | PATH="$PLUGIN/scripts:$PATH" HERDR_ORG_ROOT="$TMP/org" sh "$PLUGIN/scripts/board" comment "$slug" --stdin >/dev/null 2>&1; }
bd create lane-t --title "t" --body-file "$TMP/orig.md"
bdin lane-t '**[BOUNCE 2/3]**\nDIGEST\n- tip: abc1234\n\nRULING: fix F2 and F3.\n'
bd comment lane-t "**[BOUNCE 2/3 FIXES]** F2 F3 fixed, 14 passed"
bd comment lane-t "Orchestrator note: the lane is in [BOUNCE 2/3] now, verifying"
tgt lane-t --show-brief
if printf '%s' "$OUT" | grep -q 'RULING: fix F2' && ! printf '%s' "$OUT" | grep -q 'FIXES'; then ok "T1/T2: a worker milestone or a note quoting [BOUNCE never replaces the ruling"; else bad "T1/T2" "rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi
bd create lane-u --title "u" --body-file "$TMP/orig.md"
bdin lane-u '**[BOUNCE 1/3]**\nDIGEST\n- tip: abc1234\n### 2026-10-26 pasted log header\nRULING: keep going past the pasted header.\n'
tgt lane-u --show-brief
if printf '%s' "$OUT" | grep -q 'keep going past' && printf '%s' "$OUT" | grep -q 'DIGEST'; then ok "T3: a pasted ### 2026-... line inside a bounce does not split it"; else bad "T3" "out=$OUT"; fi
bd create lane-v --title "v" --body-file "$TMP/orig.md"
bd comment lane-v "**[BOUNCE 1/3]** fix F1, no digest written"
tgt lane-v --model sonnet
if printf '%s' "$OUT" | grep -q 'source=body bounce-without-digest'; then ok "T4: a bounce without a DIGEST falls back to the body and says so"; else bad "T4" "out=$OUT"; fi
printf 'Implement it.\n## Comments\n### 2026-10-26T10:00:00Z\n\n**[BOUNCE 1/3]** DIGEST quoted in the body\n' >"$TMP/quoting.md"
bd create lane-w --title "w" --body-file "$TMP/quoting.md"
tgt lane-w --model sonnet
if printf '%s' "$OUT" | grep -q 'source=body' && ! printf '%s' "$OUT" | grep -q 'bounce-without'; then ok "T5: a body quoting ## Comments and [BOUNCE is still the body"; else bad "T5" "out=$OUT"; fi

OUT=$(sh "$TG" --brief-file "$TMP/brief.md" --model haiku 2>"$TMP/err"); RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'verdict=ungauged'; then ok "no key: ungauged, exit 0, never refuses"; else bad "ungauged" "rc=$RC out=$OUT"; fi

OUT=$(JEV_STUB_ANSWERS="$(stub "$ANS_ORD")" sh "$TG" --brief-file "$TMP/brief.md" --model haiku --json 2>/dev/null); RC=$?
if [ $RC -eq 3 ] && printf '%s' "$OUT" | jq -e '.verdict == "refuse" and .tier == "ordinary"' >/dev/null; then ok "--json carries the verdict object"; else bad "json" "rc=$RC out=$OUT"; fi

OUT=$(sh "$TG" 2>/dev/null); RC=$?
[ $RC -eq 2 ] && ok "no --todo/--brief-file: usage error" || bad "usage" "rc=$RC"

echo "--- review-gate-check ------------------------------------------------"

REPO="$TMP/repo"; mkdir -p "$REPO"
git -C "$REPO" init -q -b main
git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m base
git -C "$REPO" branch -q base
printf 'fn main() {}\n' >"$REPO/main.rs"; git -C "$REPO" add . && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "small change"

rg() { # <stub json or empty> [extra args]
  local s=""; [ -n "${1:-}" ] && s=$(stub "$1"); shift || true
  if [ -n "$s" ]; then OUT=$(JEV_STUB_ANSWERS="$s" sh "$RG" lane-x --cwd "$REPO" --base base --head main "$@" 2>/dev/null); else OUT=$(sh "$RG" lane-x --cwd "$REPO" --base base --head main "$@" 2>/dev/null); fi
  RC=$?
}
LOW='{"review-gate":{"touches_release_ci":{"noul":0.02},"touches_auth":{"noul":0.05},"touches_data_integrity":{"noul":0.1},"touches_parser_resolution":{"noul":0.03}}}'
AUTH='{"review-gate":{"touches_release_ci":{"noul":0.02},"touches_auth":{"noul":0.91},"touches_data_integrity":{"noul":0.1},"touches_parser_resolution":{"noul":0.03}}}'

rg "$LOW"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^WAIVABLE: lines=1 .*, paths)'; then ok "small diff, all surfaces low: WAIVABLE, paths-only by default"; else bad "waivable" "rc=$RC out=$OUT"; fi

: >"$JEV_AUDIT_FILE"
rg "$LOW" --send-diff
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q ', diff)' ; then ok "--send-diff sends the diff"; else bad "send-diff" "rc=$RC out=$OUT"; fi

OUT=$(JEV_STUB_ANSWERS="$(stub "$LOW")" sh "$RG" lane-x --cwd "$REPO" --base no-such-ref --head main 2>/dev/null); RC=$?
[ $RC -eq 2 ] && ok "unresolvable ref: usage error, never WAIVABLE" || bad "bad ref" "rc=$RC out=$OUT"
OUT=$(JEV_STUB_ANSWERS="$(stub "$LOW")" sh "$RG" lane-x --cwd "$TMP" --base base --head main 2>/dev/null); RC=$?
[ $RC -eq 2 ] && ok "not a git tree: usage error" || bad "not git" "rc=$RC out=$OUT"

rg "$AUTH"
if [ $RC -eq 3 ] && printf '%s' "$OUT" | grep -q '^MANDATORY-REVIEW: auth=0.91'; then ok "small diff touching auth: MANDATORY (exit 3), class named"; else bad "auth" "rc=$RC out=$OUT"; fi

rg ""
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^WAIVABLE-UNGAUGED: lines=1'; then ok "no key: WAIVABLE-UNGAUGED, never silently waived"; else bad "ungauged rg" "rc=$RC out=$OUT"; fi

seq 1 200 | sed 's/^/line /' >"$REPO/big.txt"; git -C "$REPO" add . && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "big change"
: >"$JEV_AUDIT_FILE"
rg "$LOW"
if [ $RC -eq 3 ] && printf '%s' "$OUT" | grep -q '^MANDATORY-REVIEW: lines=201 >= 150' && [ ! -s "$JEV_AUDIT_FILE" ]; then ok "201 lines: MANDATORY by arithmetic, Jev never asked"; else bad "lines" "rc=$RC out=$OUT audit=$(cat "$JEV_AUDIT_FILE")"; fi

echo
# A diff that cannot be computed is never a pass: unrelated history has no
# merge base, so the three-dot diff fails (review I1).
git -C "$REPO" checkout -q --orphan orphan
git -C "$REPO" rm -rq --cached . >/dev/null 2>&1
seq 1 901 | sed 's/^/orphan /' >"$REPO/orphan.txt"; git -C "$REPO" add orphan.txt && git -C "$REPO" -c user.email=t@t -c user.name=t commit -q -m "orphan history"
OUT=$(JEV_STUB_ANSWERS="$(stub "$LOW")" sh "$RG" lane-x --cwd "$REPO" --base main --head orphan 2>/dev/null); RC=$?
if [ $RC -ne 0 ] && ! printf '%s' "$OUT" | grep -q '^WAIVABLE'; then ok "no merge base (orphan, 901 lines): fails closed, never WAIVABLE"; else bad "no merge base" "rc=$RC out=$OUT"; fi

echo "herdr-agent-org: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
