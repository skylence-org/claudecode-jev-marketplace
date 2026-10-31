#!/bin/bash
# dispatch.test.sh: dispatch-worker's decision paths against a stubbed herdr
# and a real filesystem board. No live herdr, no key, no tokens.
#
# The stub answers the herdr calls dispatch-worker makes with canned JSON and
# records every invocation, so the suite can assert both the exit code and
# that no composer send (`agent prompt`, `pane run`) ever happens. With
# HERDR_STUB_TRUST=1 the fresh session sits on Claude Code's folder-trust
# dialog ("No, exit" selected) until an `enter` follows a `down`.
#
# Run: bash plugins/herdr-agent-org/tests/jev/dispatch.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
DW="$PLUGIN/scripts/dispatch-worker"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d)
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export TMPDIR="$TMP"
unset TYPESAFE_API_KEY JEV_DISABLE CLAUDE_CODE_SESSION_ID HERDR_ORG_WAKER_TARGET 2>/dev/null || true
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
  "pane list")   if [ -n "${HERDR_STUB_PANES:-}" ]; then echo "$HERDR_STUB_PANES"; else echo '{"result":{"panes":[]}}'; fi ;;
  "pane split")  [ -n "${HERDR_STUB_SPLIT_FAIL:-}" ] && { echo 'split refused' >&2; exit 1; }; echo '{"result":{"pane":{"pane_id":"w1:p9"}}}' ;;
  "agent start") echo '{"result":{"ok":true}}' ;;
  "agent wait")  [ -n "${HERDR_STUB_TRUST:-}" ] && ! grep -q 'send-keys .* enter$' "$HERDR_STUB_LOG" && exit 1; exit 0 ;;
  "agent read")
    echo 'Quick safety check: Is this a project you created or one you trust?'
    if [ "${HERDR_STUB_TRUST:-}" != stuck ] && grep -q 'send-keys .* down$' "$HERDR_STUB_LOG"; then printf '❯ Yes, I trust this folder\n  No, exit\n'; else printf '  Yes, I trust this folder\n❯ No, exit\n'; fi ;;
  "agent get")
    # Gone between a `pane close` and the next `agent start` (the relaunch).
    awk '/^pane close/ { c = NR } /^agent start/ { s = NR } END { exit !(c > s) }' "$HERDR_STUB_LOG" && exit 1
    printf '{"result":{"agent":{"agent_status":"working","pane_id":"w1:p5","cwd":"%s"}}}\n' "${HERDR_STUB_CWD:-/nonexistent}" ;;
  "pane rename") exit 0 ;;
  *)             exit 0 ;;
esac
EOF
chmod +x "$STUBBIN/herdr"
# A pane id no live pane carries: dispatch-worker resolves its session from the
# pane map /tmp/claude-herdr-org-pane-<id>, and a real-shaped id could arm a
# live session's stop gate.
export HERDR_BIN_PATH="$STUBBIN/herdr" HERDR_STUB_LOG="$TMP/herdr.log" HERDR_ENV=1 HERDR_PANE_ID="dwtest-$$:p1"
trap 'rm -rf "$TMP" "/tmp/claude-herdr-org-pane-dwtest-$$_p1"' EXIT
export HERDR_ORG_ROOT="$TMP/org"
export PATH="$PLUGIN/scripts:$PATH"
sh "$PLUGIN/scripts/board" init "$HERDR_ORG_ROOT" >/dev/null 2>&1
printf 'Implement the thing. Use good judgment about the schema.\n' >"$TMP/brief.md"
sh "$PLUGIN/scripts/board" create lane-a --title "lane a" --body-file "$TMP/brief.md" >/dev/null 2>&1

ANS_ORD='{"tier-gauge":{"tier":{"choice":"ordinary","confidence":0.81},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'
ANS_MECH='{"tier-gauge":{"tier":{"choice":"mechanical","confidence":0.95},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'
ANS_HARD='{"tier-gauge":{"tier":{"choice":"hard","confidence":0.8},"risky":{"noul":0.05},"names_lane_tree":{"noul":0.9},"orders_milestones":{"noul":0.9},"inlines_board_snippets":{"noul":0.9}}}'

dw() { : >"$HERDR_STUB_LOG"; OUT=$(sh "$DW" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

echo "--- dispatch-worker (stubbed herdr) ---------------------------------"

dw --name lane-a --kind grok --todo lane-a -- --permission-mode bypassPermissions
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'L11' && [ ! -s "$HERDR_STUB_LOG" ]; then ok "non-claude kind: refused before any herdr call (L11)"; else bad "kind" "rc=$RC err=$ERR log=$(cat "$HERDR_STUB_LOG")"; fi

JEV_STUB_ANSWERS="$(stub "$ANS_ORD")" dw --name lane-a --todo lane-a -- --model haiku --permission-mode bypassPermissions
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'refused by tier-gauge' && [ ! -s "$HERDR_STUB_LOG" ]; then ok "haiku on an ordinary brief: refused by the gauge before the split"; else bad "gauge refuse" "rc=$RC err=$ERR"; fi

JEV_STUB_ANSWERS="$(stub "$ANS_ORD")" dw --name lane-a --todo lane-a -- --permission-mode bypassPermissions
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.model == "sonnet" and .submit == "launch-arg" and (.gauge | test("tier=ordinary"))' >/dev/null; then ok "sonnet default: dispatched, gauge verdict in the JSON summary"; else bad "dispatch" "rc=$RC out=$OUT err=$ERR"; fi
grep -q 'agent start lane-a --kind claude --pane w1:p9' "$HERDR_STUB_LOG" && grep -q 'you own todo lane-a' "$HERDR_STUB_LOG" && ok "pointer rode the launch arguments" || bad "launch arg" "$(cat "$HERDR_STUB_LOG")"
grep -qF "env HERDR_ORG_ROOT=$HERDR_ORG_ROOT $PLUGIN/scripts/board get lane-a" "$HERDR_STUB_LOG" && ok "pointer carries the exact board command (absolute script, HERDR_ORG_ROOT)" || bad "board command" "$(grep 'agent start' "$HERDR_STUB_LOG")"
printf '%s' "$OUT" | jq -e '.trust == "none"' >/dev/null && ok "no trust dialog: trust=none" || bad "trust none" "out=$OUT"
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

HERDR_STUB_TRUST=1 dw --name lane-a --todo lane-a --no-gauge -- --permission-mode bypassPermissions
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.state == "trust-prompt" and .trust == "prompt" and .submit == "launch-arg-unconfirmed"' >/dev/null && printf '%s' "$ERR" | grep -q -- '--accept-trust' && ! grep -q 'send-keys' "$HERDR_STUB_LOG"; then ok "trust dialog without --accept-trust: state=trust-prompt, hint, no key sent"; else bad "trust prompt" "rc=$RC out=$OUT err=$ERR log=$(cat "$HERDR_STUB_LOG")"; fi

HERDR_STUB_TRUST=1 dw --name lane-a --todo lane-a --no-gauge --accept-trust -- --permission-mode bypassPermissions
keys=$(grep 'send-keys' "$HERDR_STUB_LOG" | awk '{print $NF}' | tr '\n' ' ')
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.trust == "accepted" and .submit == "launch-arg" and .state == "working"' >/dev/null && [ "$keys" = "down enter " ]; then ok "--accept-trust: down, verified ❯ Yes, enter; trust=accepted, submit confirmed"; else bad "accept trust" "rc=$RC out=$OUT keys=$keys"; fi
if ! grep -qE 'agent prompt|pane run' "$HERDR_STUB_LOG" && ! grep 'send-keys' "$HERDR_STUB_LOG" | grep -qvE ' (down|enter)$'; then ok "trust path sends content-free keys only (L11 exception)"; else bad "trust keys" "$(cat "$HERDR_STUB_LOG")"; fi

HERDR_STUB_TRUST=stuck dw --name lane-a --todo lane-a --no-gauge --accept-trust -- --permission-mode bypassPermissions
keys=$(grep 'send-keys' "$HERDR_STUB_LOG" | awk '{print $NF}' | tr '\n' ' ')
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.trust == "unconfirmed" and .state == "trust-prompt"' >/dev/null && [ "$keys" = "down " ]; then ok "--accept-trust, Yes never selected: enter NOT sent, trust=unconfirmed"; else bad "trust stuck" "rc=$RC out=$OUT keys=$keys"; fi

echo "--- board root, no silent default (item 11) --------------------------"
mkdir -p "$TMP/nowhere"
OUT=$(cd "$TMP/nowhere" && env -u HERDR_ORG_ROOT sh "$PLUGIN/scripts/board" get lane-a 2>"$TMP/err"); RC=$?
if [ $RC -ne 0 ] && [ "$(wc -l <"$TMP/err" | tr -d ' ')" = 1 ] && grep -q 'export HERDR_ORG_ROOT=' "$TMP/err" && [ ! -e "$HOME/.herdr-org/default" ]; then ok "no HERDR_ORG_ROOT, no ./.herdr-org: one-line error naming the fix, non-zero, nothing created"; else bad "board no root" "rc=$RC out=$OUT err=$(cat "$TMP/err")"; fi
OUT=$(cd "$TMP/nowhere" && env -u HERDR_ORG_ROOT sh "$PLUGIN/scripts/board" path 2>/dev/null); RC=$?
[ $RC -ne 0 ] && [ -z "$OUT" ] && ok "board path with no root: fails, prints no guessed path" || bad "board path" "rc=$RC out=$OUT"
sh "$PLUGIN/scripts/board" init "$TMP/here/.herdr-org" >/dev/null 2>&1
OUT=$(cd "$TMP/here" && env -u HERDR_ORG_ROOT sh "$PLUGIN/scripts/board" list 2>&1); RC=$?
[ $RC -eq 0 ] && ok "explicit ./.herdr-org still resolves without HERDR_ORG_ROOT" || bad "board pwd root" "rc=$RC out=$OUT"

echo "--- hard brief below the top tier (item 9) ----------------------------"
JEV_STUB_ANSWERS="$(stub "$ANS_HARD")" dw --name lane-a --todo lane-a -- --permission-mode bypassPermissions
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q -- '--keep-tier' && [ "$(printf '%s\n' "$ERR" | grep -c 'dispatch-worker:')" = 1 ] && ! grep -q 'pane split' "$HERDR_STUB_LOG"; then ok "hard brief, no choice: one-line refusal before any pane"; else bad "hard no choice" "rc=$RC err=$ERR log=$(cat "$HERDR_STUB_LOG")"; fi
JEV_STUB_ANSWERS="$(stub "$ANS_HARD")" dw --name lane-a --todo lane-a --keep-tier "long, not hard" -- --permission-mode bypassPermissions
if [ $RC -eq 0 ] && sh "$PLUGIN/scripts/board" get lane-a | grep -q 'TIER-KEPT: model=sonnet brief_tier=hard, long, not hard'; then ok "--keep-tier: dispatched, [TIER-KEPT: model=<m> brief_tier=hard, <why>] filed"; else bad "keep-tier" "rc=$RC err=$ERR"; fi
JEV_STUB_ANSWERS="$(stub "$ANS_HARD")" dw --name lane-a --todo lane-a --upgrade-reason "design work" -- --model opus --permission-mode bypassPermissions
if [ $RC -eq 0 ] && ! printf '%s' "$OUT" | jq -e '.gauge | test("upgrade=advised")' >/dev/null; then ok "--model opus --upgrade-reason: top tier, no stop"; else bad "hard opus" "rc=$RC out=$OUT err=$ERR"; fi

echo "--- --relaunch (item 10) ---------------------------------------------"
mkdir -p "$TMP/lane"
export HERDR_STUB_CWD="$TMP/lane" HERDR_STUB_PANES='{"result":{"panes":[{"pane_id":"w1:p5","label":"lane-a: lane-a"}]}}'
dw --relaunch lane-a --model opus --upgrade-reason "needs design" --no-gauge
order=$(grep -nE '^(pane close w1:p5|agent start lane-a)' "$HERDR_STUB_LOG" | cut -d' ' -f1-2 | tr '\n' ';')
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.relaunched_from == "w1:p5" and .model == "opus" and .todo == "lane-a"' >/dev/null && printf '%s' "$order" | grep -qE '^[0-9]+:pane close;[0-9]+:agent start;$'; then ok "--relaunch: old pane closed, then the same name started"; else bad "relaunch" "rc=$RC out=$OUT err=$ERR order=$order"; fi
grep 'agent start lane-a' "$HERDR_STUB_LOG" | grep -q -- '--model opus' && grep 'agent start lane-a' "$HERDR_STUB_LOG" | grep -q -- '--permission-mode bypassPermissions' && grep 'agent start lane-a' "$HERDR_STUB_LOG" | grep -q 'you own todo lane-a' && grep -q "pane split .*--cwd $TMP/lane" "$HERDR_STUB_LOG" && ok "--relaunch: same lane tree, same todo pointer, new model" || bad "relaunch args" "$(cat "$HERDR_STUB_LOG")"
sh "$PLUGIN/scripts/board" get lane-a | grep -q 'MODEL: opus, needs design' && sh "$PLUGIN/scripts/board" get lane-a | grep -q 'RELAUNCH: w1:p5 -> w1:p9, needs design' && ok "--relaunch: [MODEL] and [RELAUNCH] filed" || bad "relaunch filing" "$(sh "$PLUGIN/scripts/board" get lane-a | tail -4)"
dw --relaunch lane-a --model sonnet --no-gauge
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q -- '--keep-tier' && ! grep -q 'pane close' "$HERDR_STUB_LOG" && ok "--relaunch downgrade without --keep-tier: refused, nothing closed" || bad "relaunch no reason" "rc=$RC err=$ERR"
dw --relaunch lane-a --model sonnet --keep-tier "opus not needed" --no-gauge
[ $RC -eq 0 ] && sh "$PLUGIN/scripts/board" get lane-a | grep -q 'TIER-KEPT: model=sonnet brief_tier=ungauged, opus not needed' && ok "--relaunch downgrade with --keep-tier: [TIER-KEPT: model=sonnet brief_tier=ungauged, <why>] filed" || bad "relaunch keep" "rc=$RC err=$ERR"
HERDR_STUB_CWD=/nonexistent dw --relaunch lane-a --model opus --upgrade-reason x --no-gauge
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'lane tree' && ! grep -q 'pane close' "$HERDR_STUB_LOG" && ok "--relaunch with the lane tree missing: refused" || bad "relaunch no tree" "rc=$RC err=$ERR"
# Target guard (review I2): never close a pane that is not this lane's.
HERDR_STUB_PANES='{"result":{"panes":[{"pane_id":"w1:p5","label":"other-x: other-todo"}]}}' dw --relaunch lane-a --todo lane-a --model opus --upgrade-reason x --no-gauge
[ $RC -eq 2 ] && ! grep -q 'pane close' "$HERDR_STUB_LOG" && ok "--relaunch R1: pane labelled for another lane is refused, nothing closed" || bad "relaunch R1" "rc=$RC err=$ERR log=$(cat "$HERDR_STUB_LOG")"
HERDR_PANE_ID=w1:p5 dw --relaunch lane-a --model opus --upgrade-reason x --no-gauge
[ $RC -eq 2 ] && ! grep -q 'pane close' "$HERDR_STUB_LOG" && ok "--relaunch R2: the caller's own pane is refused, nothing closed" || bad "relaunch R2" "rc=$RC err=$ERR"
# Reap before split (review I3): a failed split leaves a board record and the exact re-dispatch.
HERDR_STUB_SPLIT_FAIL=1 dw --relaunch lane-a --model opus --upgrade-reason "split probe" --no-gauge
trail=$(sh "$PLUGIN/scripts/board" get lane-a)
if [ $RC -ne 0 ] && printf '%s' "$trail" | grep -q 'RELAUNCH: w1:p5 reaped, split probe' && printf '%s' "$trail" | grep -q 'RELAUNCH-FAILED' && printf '%s' "$ERR" | grep -q 'dispatch-worker --name lane-a --todo lane-a'; then ok "--relaunch R3: failed split after the reap files the reap and the failure, names the re-dispatch"; else bad "relaunch R3" "rc=$RC err=$ERR trail=$(printf '%s' "$trail" | tail -4)"; fi
sh "$PLUGIN/scripts/board" set-status lane-a verified >/dev/null 2>&1
dw --relaunch lane-a --model opus --upgrade-reason x --no-gauge
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'is verified' && ! grep -q 'pane close' "$HERDR_STUB_LOG" && ok "--relaunch on a verified todo: refused, nothing closed" || bad "relaunch verified" "rc=$RC err=$ERR"
unset HERDR_STUB_CWD HERDR_STUB_PANES

echo "--- --replacer [--bounce N] (marketplace#11) ---------------------------"
bd() { sh "$PLUGIN/scripts/board" "$@" >/dev/null 2>&1; }
RLANE="$TMP/rlane"; git init -q -b main "$RLANE"
git -C "$RLANE" -c user.email=t@t -c user.name=t commit -q --allow-empty -m "wip: predecessor's work"
RTIP=$(git -C "$RLANE" rev-parse --short HEAD)
BCMD="env HERDR_ORG_ROOT=$HERDR_ORG_ROOT $PLUGIN/scripts/board"
bd create lane-r --title "lane r" --body-file "$TMP/brief.md"
printf '**[BOUNCE 1/3]**\nDIGEST\n- tip: aaa1111\n\nRULING: fix F1.\n' | bd comment lane-r --stdin
printf '**[BOUNCE 2/3]**\nDIGEST\n- tip: bbb2222\n\nRULING: fix F2 "as listed".\n' | bd comment lane-r --stdin
bd comment lane-r "**[BOUNCE 2/3 FIXES]** F2 fixed, 9 passed"
bd create lane-q --title "lane q" --body-file "$TMP/brief.md"
startline() { grep '^agent start' "$HERDR_STUB_LOG"; }
dw --name lane-r --todo lane-r --cwd "$RLANE" --replacer --no-gauge -- --permission-mode bypassPermissions
S=$(startline)
if [ $RC -eq 0 ] && printf '%s' "$S" | grep -q 'herdr-replacer' && printf '%s' "$S" | grep -qF "REPLACER for todo lane-r, bounce 2/3" && printf '%s' "$S" | grep -qF "$BCMD get lane-r" && printf '%s' "$S" | grep -qF "tip $RTIP" && printf '%s' "$S" | grep -q 'ONLY its FIXES' && ! printf '%s' "$S" | grep -q 'you own todo'; then ok "--replacer: pointer names herdr-replacer, the exact board command, the tip SHA and the round"; else bad "replacer pointer" "rc=$RC err=$ERR start=$S"; fi
printf '%s' "$OUT" | jq -e --arg t "$RTIP" '.replacer == true and .tip == $t and .bounce == 2' >/dev/null && ok "--replacer: JSON reports replacer, tip, bounce (auto-detected 2 from [BOUNCE 2/3], the FIXES milestone ignored)" || bad "replacer json" "out=$OUT"
dw --name lane-r --todo lane-r --cwd "$RLANE" --replacer --bounce 3 --no-gauge -- --permission-mode bypassPermissions
S=$(startline)
[ $RC -eq 0 ] && printf '%s' "$S" | grep -qF 'bounce 3/3' && printf '%s' "$OUT" | jq -e '.bounce == 3' >/dev/null && ok "--bounce N overrides the detected round" || bad "replacer --bounce" "rc=$RC out=$OUT start=$S"
dw --name lane-q --todo lane-q --cwd "$RLANE" --replacer --no-gauge -- --permission-mode bypassPermissions
S=$(startline)
if [ $RC -eq 0 ] && printf '%s' "$S" | grep -q 'REPLACER for todo lane-q:' && ! printf '%s' "$S" | grep -qi 'bounce' && printf '%s' "$OUT" | jq -e '.replacer == true and .bounce == null' >/dev/null; then ok "--replacer, no [BOUNCE r/3] on the todo: the bounce clause is omitted, bounce=null"; else bad "replacer no bounce" "rc=$RC out=$OUT start=$S"; fi
dw --name lane-r --todo lane-r --cwd "$RLANE" --replacer --prompt "do it" --no-gauge
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q -- '--prompt' && [ ! -s "$HERDR_STUB_LOG" ] && ok "--replacer with --prompt: refused (exit 2) before any herdr call" || bad "replacer+prompt" "rc=$RC err=$ERR"
dw --name lane-r --cwd "$RLANE" --replacer --no-gauge
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q -- '--todo' && [ ! -s "$HERDR_STUB_LOG" ] && ok "--replacer without --todo: refused (exit 2) before any herdr call" || bad "replacer no todo" "rc=$RC err=$ERR"
dw --name lane-r --todo lane-r --replacer --no-gauge
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q -- '--cwd' && [ ! -s "$HERDR_STUB_LOG" ] && ok "--replacer without --cwd: refused (exit 2)" || bad "replacer no cwd" "rc=$RC err=$ERR"
dw --name lane-r --todo lane-r --cwd "$TMP/nowhere" --replacer --no-gauge
[ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'git' && [ ! -s "$HERDR_STUB_LOG" ] && ok "--replacer on a --cwd that is no git tree: refused (exit 2), no tip to name" || bad "replacer no git" "rc=$RC err=$ERR"
JEV_STUB_ANSWERS="$(stub "$ANS_HARD")" dw --name lane-r --todo lane-r --cwd "$RLANE" --replacer --keep-tier "precise fix list" -- --permission-mode bypassPermissions
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.replacer == true and (.gauge | test("source=bounce"))' >/dev/null && sh "$PLUGIN/scripts/board" get lane-r | grep -q 'TIER-KEPT: model=sonnet brief_tier=hard, precise fix list'; then ok "--replacer + gauge + --keep-tier: gauged on the bounce, [TIER-KEPT] filed"; else bad "replacer keep-tier" "rc=$RC out=$OUT err=$ERR"; fi
HERDR_STUB_TRUST=1 dw --name lane-r --todo lane-r --cwd "$RLANE" --replacer --no-gauge --accept-trust --model opus --upgrade-reason "approach was wrong twice" -- --permission-mode bypassPermissions
S=$(startline)
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.replacer == true and .model == "opus" and .trust == "accepted"' >/dev/null && printf '%s' "$S" | grep -q -- '--model opus' && printf '%s' "$S" | grep -q 'herdr-replacer' && sh "$PLUGIN/scripts/board" get lane-r | grep -q 'MODEL: opus, approach was wrong twice'; then ok "--replacer + --model + --upgrade-reason + --accept-trust: all still apply"; else bad "replacer flags" "rc=$RC out=$OUT err=$ERR"; fi
dw --name lane-a --todo lane-q --no-gauge -- --permission-mode bypassPermissions
printf '%s' "$OUT" | jq -e '.replacer == false and .tip == "" and .bounce == null' >/dev/null && ok "fresh dispatch: replacer=false, tip empty, bounce=null" || bad "fresh json" "out=$OUT"
echo
echo "dispatch-worker: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
