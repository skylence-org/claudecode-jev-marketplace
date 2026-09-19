#!/bin/bash
# dispatch.test.sh: dispatch-worker's decision paths against a stubbed herdr
# and a real filesystem board. No live herdr, no key, no tokens.
#
# The stub answers the five herdr calls dispatch-worker makes with canned
# JSON and records every invocation, so the suite can assert both the exit
# code and that no composer send (`agent prompt`, `pane run`) ever happens.
#
# Run: bash plugins/herdr-agent-org/tests/jev/dispatch.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
DW="$PLUGIN/scripts/dispatch-worker"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export TMPDIR="$TMP"
unset TYPESAFE_API_KEY JEV_DISABLE 2>/dev/null || true
export JEV_AUDIT_FILE="$TMP/audit.jsonl"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
stub() { printf '%s' "$1" >"$TMP/stub.json"; printf '%s' "$TMP/stub.json"; }

# herdr stub: logs argv, answers what dispatch-worker parses.
STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
cat >"$STUBBIN/herdr" <<'EOF'
#!/bin/sh
echo "$*" >>"$HERDR_STUB_LOG"
case "$1 $2" in
  "pane list")   echo '{"result":{"panes":[]}}' ;;
  "pane split")  echo '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
  "agent start") echo '{"result":{"ok":true}}' ;;
  "agent wait")  exit 0 ;;
  "agent get")   echo '{"result":{"agent":{"agent_status":"working"}}}' ;;
  "pane rename") exit 0 ;;
  *)             exit 0 ;;
esac
EOF
chmod +x "$STUBBIN/herdr"
export HERDR_BIN_PATH="$STUBBIN/herdr" HERDR_STUB_LOG="$TMP/herdr.log" HERDR_ENV=1 HERDR_PANE_ID=w1:p1
export HERDR_ORG_ROOT="$TMP/org"
export PATH="$PLUGIN/scripts:$PATH"
sh "$PLUGIN/scripts/board" init "$HERDR_ORG_ROOT" >/dev/null 2>&1
printf 'Implement the thing. Use good judgment about the schema.\n' >"$TMP/brief.md"
sh "$PLUGIN/scripts/board" create lane-a --title "lane a" --body-file "$TMP/brief.md" >/dev/null 2>&1

ANS_ORD='{"tier-gauge":{"tier":{"choice":"ordinary","confidence":0.81},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'
ANS_MECH='{"tier-gauge":{"tier":{"choice":"mechanical","confidence":0.95},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'

dw() { : >"$HERDR_STUB_LOG"; OUT=$(sh "$DW" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

echo "--- dispatch-worker (stubbed herdr) ---------------------------------"

dw --name lane-a --kind grok --todo lane-a -- --permission-mode bypassPermissions
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'L11' && [ ! -s "$HERDR_STUB_LOG" ]; then ok "non-claude kind: refused before any herdr call (L11)"; else bad "kind" "rc=$RC err=$ERR log=$(cat "$HERDR_STUB_LOG")"; fi

JEV_STUB_ANSWERS="$(stub "$ANS_ORD")" dw --name lane-a --todo lane-a -- --model haiku --permission-mode bypassPermissions
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'refused by tier-gauge' && [ ! -s "$HERDR_STUB_LOG" ]; then ok "haiku on an ordinary brief: refused by the gauge before the split"; else bad "gauge refuse" "rc=$RC err=$ERR"; fi

JEV_STUB_ANSWERS="$(stub "$ANS_ORD")" dw --name lane-a --todo lane-a -- --permission-mode bypassPermissions
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.model == "sonnet" and .submit == "launch-arg" and (.gauge | test("tier=ordinary"))' >/dev/null; then ok "sonnet default: dispatched, gauge verdict in the JSON summary"; else bad "dispatch" "rc=$RC out=$OUT err=$ERR"; fi
grep -q 'agent start lane-a --kind claude --pane w1:p9' "$HERDR_STUB_LOG" && grep -q 'you own todo lane-a' "$HERDR_STUB_LOG" && ok "pointer rode the launch arguments" || bad "launch arg" "$(cat "$HERDR_STUB_LOG")"
if ! grep -qE 'agent prompt|pane run|send-keys' "$HERDR_STUB_LOG"; then ok "no composer send of any kind (L11)"; else bad "composer" "$(cat "$HERDR_STUB_LOG")"; fi
sh "$PLUGIN/scripts/board" get lane-a | grep -q 'TIER-GAUGE: jev-1.13.0 tier=ordinary' && ok "gauge verdict filed on the todo" || bad "filing" "$(sh "$PLUGIN/scripts/board" get lane-a | tail -5)"
sh "$PLUGIN/scripts/board" get lane-a --json | jq -e '.status == "in_progress" and .owner == "lane-a"' >/dev/null && ok "todo owned and in_progress" || bad "board state" "$(sh "$PLUGIN/scripts/board" get lane-a --json)"

dw --name lane-a --todo lane-a -- --model opus --permission-mode bypassPermissions
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'upgrade-reason' && ok "opus without --upgrade-reason: refused (L17)" || bad "upgrade" "rc=$RC err=$ERR"

JEV_STUB_ANSWERS="$(stub "$ANS_MECH")" dw --name lane-a --todo lane-a -- --model haiku --permission-mode bypassPermissions
[ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.gauge | test("tier=mechanical")' >/dev/null && ok "haiku on a mechanical brief: dispatched" || bad "haiku mech" "rc=$RC out=$OUT err=$ERR"

dw --name lane-a --todo lane-a -- --permission-mode bypassPermissions
[ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.gauge | test("ungauged")' >/dev/null && ok "no key: dispatched ungauged" || bad "ungauged" "rc=$RC out=$OUT"

JEV_STUB_ANSWERS="$(stub "$ANS_ORD")" dw --name lane-a --todo lane-a --no-gauge -- --model haiku --permission-mode bypassPermissions
[ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.gauge == ""' >/dev/null && ok "--no-gauge skips the gauge" || bad "no-gauge" "rc=$RC out=$OUT"

dw --name 'Bad Name' --todo lane-a
[ $RC -eq 2 ] && ok "invalid agent name: usage error" || bad "name" "rc=$RC"

echo
echo "dispatch-worker: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
