#!/bin/bash
# jev.test.sh: regression tests for the jev helper and both core hooks.
#
# Every case runs the REAL scripts as Claude Code does — hook JSON on stdin,
# verdict from exit status / stdout — with JEV_STUB_ANSWERS supplying the
# model's answers, so the suite needs no key, makes no network call, and costs
# nothing. CI asserts the stub is in use (grep below) so that never changes
# silently.
#
# Run: bash plugins/core/tests/jev.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/.." && pwd)
JEV="$PLUGIN/scripts/jev"
GATE="$PLUGIN/hooks/jev-intent-gate.sh"
NUDGE="$PLUGIN/hooks/jev-research-nudge.sh"

command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not installed"; exit 0; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home"; mkdir -p "$HOME/.claude"
export TMPDIR="$TMP"
unset TYPESAFE_API_KEY JEV_DISABLE JEV_QUESTIONS_OVERLAY 2>/dev/null || true
export JEV_AUDIT_FILE="$TMP/audit.jsonl"

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

stub() { # <json> -> path
  printf '%s' "$1" >"$TMP/stub.json"; printf '%s' "$TMP/stub.json"
}

echo "--- jev helper -------------------------------------------------------"

out=$(sh "$JEV" sets 2>&1)
if printf '%s' "$out" | grep -q '^research-nudge$' && printf '%s' "$out" | grep -q '^deps-pin$'; then ok "sets lists both shipped sets"; else bad "sets" "$out"; fi

t=$(sh "$JEV" threshold research-nudge nudge)
[ "$t" = "0.7" ] && ok "threshold reads the shipped value" || bad "threshold" "got '$t'"

out=$(printf '{"assistant_text":"x"}' | sh "$JEV" ask research-nudge 2>"$TMP/err"); rc=$?
if [ $rc -eq 0 ] && [ -z "$out" ] && grep -q 'fail-open' "$TMP/err"; then ok "no key: fail-open (exit 0, empty stdout, one stderr line)"; else bad "no key fail-open" "rc=$rc out=$out err=$(cat "$TMP/err")"; fi

out=$(printf 'not json' | JEV_STUB_ANSWERS="$(stub '{}')" sh "$JEV" ask research-nudge 2>/dev/null); rc=$?
[ $rc -eq 2 ] && ok "non-JSON state is a caller bug (exit 2)" || bad "non-JSON state" "rc=$rc"

out=$(printf '{}' | JEV_STUB_ANSWERS="$(stub '{}')" sh "$JEV" ask no-such-set 2>/dev/null); rc=$?
[ $rc -eq 2 ] && ok "unknown set is a caller bug (exit 2)" || bad "unknown set" "rc=$rc"

S=$(stub '{"research-nudge":{"hedged_fact":{"type":"noul","noul":0.91}}}')
out=$(printf '{"assistant_text":"x"}' | JEV_STUB_ANSWERS="$S" sh "$JEV" ask research-nudge)
p=$(printf '%s' "$out" | jq -r '.hedged_fact.noul')
[ "$p" = "0.91" ] && ok "stub keyed by set id is served" || bad "stub by set" "$out"

S=$(stub '{"hedged_fact":{"type":"noul","noul":0.2}}')
out=$(printf '{"assistant_text":"x"}' | JEV_STUB_ANSWERS="$S" sh "$JEV" ask research-nudge)
p=$(printf '%s' "$out" | jq -r '.hedged_fact.noul')
[ "$p" = "0.2" ] && ok "bare answers stub is served" || bad "bare stub" "$out"

n=$(grep -c '"stub":true' "$JEV_AUDIT_FILE" 2>/dev/null || echo 0)
[ "$n" -ge 2 ] && ok "audit line written per stubbed call ($n)" || bad "audit" "lines=$n"
grep -q '"assistant_text"' "$JEV_AUDIT_FILE" && bad "audit never carries the state" "state text found in audit" || ok "audit carries answers and checksum, never the state"

printf '{"sets":{"research-nudge":{"thresholds":{"nudge":0.42}}}}' >"$TMP/overlay.json"
t=$(JEV_QUESTIONS_OVERLAY="$TMP/overlay.json" sh "$JEV" threshold research-nudge nudge)
[ "$t" = "0.42" ] && ok "overlay merges a threshold over the shipped file" || bad "overlay" "got '$t'"
printf 'not json' >"$TMP/broken.json"
t=$(JEV_QUESTIONS_OVERLAY="$TMP/broken.json" sh "$JEV" threshold research-nudge nudge)
[ "$t" = "0.7" ] && ok "broken overlay is ignored, shipped file stays live" || bad "broken overlay" "got '$t'"

out=$(printf '{"assistant_text":"x"}' | JEV_DISABLE=1 JEV_STUB_ANSWERS="$S" sh "$JEV" ask research-nudge 2>/dev/null); rc=$?
{ [ $rc -eq 0 ] && [ -z "$out" ]; } && ok "JEV_DISABLE=1 is fail-open" || bad "disable" "rc=$rc out=$out"

echo "--- jev-intent-gate ---------------------------------------------------"

run_gate() { # <tool> <tool_input json> [stub json]
  local payload; payload=$(jq -nc --arg t "$1" --argjson i "$2" '{tool_name:$t,tool_input:$i}')
  : >"$JEV_AUDIT_FILE"
  if [ -n "${3:-}" ]; then
    STDERR=$(printf '%s' "$payload" | JEV_STUB_ANSWERS="$(stub "$3")" bash "$GATE" 2>&1 >/dev/null); RC=$?
  else
    STDERR=$(printf '%s' "$payload" | bash "$GATE" 2>&1 >/dev/null); RC=$?
  fi
}
cmd() { jq -nc --arg c "$1" '{command:$c}'; }

run_gate Bash "$(cmd 'ls -la')" '{"lookup_seen":{"noul":0.0}}'
if [ $RC -eq 0 ] && [ ! -s "$JEV_AUDIT_FILE" ]; then ok "unrelated command: allow, Jev never asked"; else bad "unrelated" "rc=$RC audit=$(cat "$JEV_AUDIT_FILE")"; fi

run_gate Bash "$(cmd 'npm install left-pad@1.3.0')" '{"lookup_seen":{"noul":0.12}}'
if [ $RC -eq 2 ] && printf '%s' "$STDERR" | grep -q 'rule=deps.pinned-install lookup_seen=0.12'; then ok "pinned install, no lookup seen: block with templated numbers"; else bad "pinned block" "rc=$RC $STDERR"; fi

run_gate Bash "$(cmd 'npm install left-pad@1.3.0')" '{"lookup_seen":{"noul":0.93}}'
[ $RC -eq 0 ] && ok "pinned install, lookup seen: allow" || bad "pinned allow" "rc=$RC $STDERR"

run_gate Bash "$(cmd 'npm install left-pad@1.3.0')"
if [ $RC -eq 0 ] && printf '%s' "$STDERR" | grep -q 'allowing without evaluation'; then ok "pinned install, no key: fail-open and says so"; else bad "pinned fail-open" "rc=$RC $STDERR"; fi

run_gate Edit '{"file_path":"/repo/package.json","old_string":"x","new_string":"\"left-pad\": \"^1.3.0\""}' '{"lookup_seen":{"noul":0.1},"raises_version":{"noul":0.9}}'
[ $RC -eq 2 ] && ok "manifest edit raising a version without lookup: block" || bad "manifest block" "rc=$RC $STDERR"

run_gate Edit '{"file_path":"/repo/package.json","old_string":"x","new_string":"\"scripts\": {}"}' '{"lookup_seen":{"noul":0.1},"raises_version":{"noul":0.05}}'
[ $RC -eq 0 ] && ok "manifest edit that raises nothing: allow" || bad "manifest allow" "rc=$RC $STDERR"

run_gate mcp__skyline__skyline_run '{"argv":["pnpm","add","zod@3.22.4"]}' '{"lookup_seen":{"noul":0.05}}'
[ $RC -eq 2 ] && ok "skyline_run argv is normalised like Bash" || bad "skyline_run" "rc=$RC $STDERR"

echo "--- jev-research-nudge -------------------------------------------------"

run_nudge() { # <assistant text> [stub json] [session id]
  local tr="$TMP/transcript.jsonl"
  jq -nc --arg t "$1" '{type:"user",message:{content:"q"}}' >"$tr"
  jq -nc --arg t "$1" '{type:"assistant",message:{content:[{type:"text",text:$t}]}}' >>"$tr"
  local payload; payload=$(jq -nc --arg p "$tr" --arg s "${3:-sess1}" '{transcript_path:$p,session_id:$s,stop_hook_active:false}')
  : >"$JEV_AUDIT_FILE"
  if [ -n "${2:-}" ]; then OUT=$(printf '%s' "$payload" | JEV_STUB_ANSWERS="$(stub "$2")" bash "$NUDGE" 2>/dev/null); else OUT=$(printf '%s' "$payload" | bash "$NUDGE" 2>/dev/null); fi
}

run_nudge "Done. The tests pass." '{"hedged_fact":{"noul":0.99}}'
if [ -z "$OUT" ] && [ ! -s "$JEV_AUDIT_FILE" ]; then ok "no hedge word: silent, Jev never asked"; else bad "no hedge" "out=$OUT"; fi

run_nudge "The flag is probably --force-with-lease." '{"hedged_fact":{"noul":0.88}}'
if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1 && printf '%s' "$OUT" | grep -q 'hedged_fact=0.88'; then ok "hedged fact above bar: block with the number"; else bad "hedged block" "out=$OUT"; fi

run_nudge "You may want to rename this later." '{"hedged_fact":{"noul":0.15}}'
[ -z "$OUT" ] && ok "hedge about intent, below bar: silent" || bad "intent hedge" "out=$OUT"

run_nudge "The flag is probably --force-with-lease."
[ -z "$OUT" ] && ok "hedge but no key: fail-open, silent" || bad "nudge fail-open" "out=$OUT"

touch "/tmp/claude-herdr-org-lanes-orgsess"
run_nudge "The flag is probably --force-with-lease." '{"hedged_fact":{"noul":0.99}}' orgsess
rm -f "/tmp/claude-herdr-org-lanes-orgsess"
[ -z "$OUT" ] && ok "org session marker: silent" || bad "org session" "out=$OUT"

echo
echo "core: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
