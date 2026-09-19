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
echo "herdr-agent-org: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
