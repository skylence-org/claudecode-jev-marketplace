#!/bin/sh
# org-stop-gate.sh + org-lane-mark.sh: the NO AWAIT COVERAGE line fires only
# while a dispatched lane is in flight (no [DONE] doorbell from its todo slug or
# its agent name since the dispatch); a done lane, a covered session and an idle
# session are asked for nothing, and the backlog line never asks an idle session
# to keep an await armed (marketplace#2, review rounds 1 and 2). A keyless
# dispatch line is in flight only while another agent is alive (0.1.6), and a
# dispatch-worker run from inside a script records its own line. Stubs: a fake
# `herdr` (agent list from $tmp/agents.json, pane p1 = orch-test; the calls
# dispatch-worker makes), a fake daemon /status served by python3 http.server,
# a temp relay DB in the daemon's own schema under a temp HOME. No live model,
# no live daemon, no real DB.
set -u
here=$(cd "$(dirname "$0")" && pwd)
gate="$here/../../hooks/org-stop-gate.sh"
markhook="$here/../../hooks/org-lane-mark.sh"
for dep in jq sqlite3 python3 curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "org-stop-gate: SKIP ($dep missing)"; [ -n "${CI:-}" ] && exit 1; exit 0; }
done
sid="gate-test-$$"
unset CLAUDE_CODE_SESSION_ID HERDR_WORKSPACE_ID HERDR_ORG_WAKER_TARGET
tmp=$(mktemp -d)
srv=""
db="$tmp/home/.config/herdr/org-relay/relay.db"
cleanup() {
  [ -n "$srv" ] && { kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; }
  chmod 644 "$db" 2>/dev/null
  rm -rf "$tmp" "/tmp/claude-herdr-org-lanes-$sid" "/tmp/claude-herdr-org-sweep-$sid" /tmp/claude-herdr-org-pane-p1
}
trap cleanup EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.config/herdr/org-relay" "$tmp/bin" "$tmp/www"
sqlite3 "$db" "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, sender TEXT NOT NULL, recipient TEXT NOT NULL, lane TEXT, kind TEXT NOT NULL, body TEXT NOT NULL, consumed_at TEXT);"
one_agent='{"result":{"agents":[{"pane_id":"p1","name":"orch-test"}]}}'
two_agents='{"result":{"agents":[{"pane_id":"p1","name":"orch-test"},{"pane_id":"p2","name":"w-x"}]}}'
cat > "$tmp/bin/herdr" <<EOF
#!/bin/sh
case "\$1 \$2" in
  "agent list")  cat "$tmp/agents.json" ;;
  "pane split")  echo '{"result":{"pane":{"pane_id":"p9"}}}' ;;
  "agent get")   echo '{"result":{"agent":{"agent_status":"working"}}}' ;;
  *)             exit 0 ;;
esac
EOF
chmod +x "$tmp/bin/herdr"
export HERDR_BIN_PATH="$tmp/bin/herdr" HERDR_PANE_ID=p1
printf '{"awaiting":[]}' > "$tmp/www/status"
# Never the real daemon's port (7431): a collision would let the readiness probe
# be answered by the live daemon and the suite read a real /status.
port=$((7400 + $$ % 100))
[ "$port" = 7431 ] && port=7531
(cd "$tmp/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
srv=$!
export ORG_RELAY_PORT="$port"
i=0
until curl -s -m 1 "http://127.0.0.1:$port/status" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 50 ] && { echo "org-stop-gate: FAIL (stub daemon never came up on $port)"; exit 1; }
  sleep 0.1
done
kill -0 "$srv" 2>/dev/null || { echo "org-stop-gate: FAIL (port $port answered but the stub is not running: taken by another service)"; exit 1; }
marker="/tmp/claude-herdr-org-lanes-$sid"
run_gate() { printf '{"session_id":"%s","stop_hook_active":false}' "$sid" | sh "$gate"; }
reset() { rm -f "$marker" "/tmp/claude-herdr-org-sweep-$sid"; chmod 644 "$db"; sqlite3 "$db" "DELETE FROM messages;"; printf '{"awaiting":[]}' > "$tmp/www/status"; printf '%s' "$one_agent" > "$tmp/agents.json"; }
msg() { sqlite3 "$db" "INSERT INTO messages(ts,sender,recipient,lane,kind,body) VALUES('$1','$2','orch-test','$2','$3','x');"; }
mark() { printf '{"session_id":"%s","tool_name":"%s","tool_input":%s}' "$sid" "$1" "$2" | sh "$markhook"; }
pass=0
fail=0
expect() { # expect <1 = NO AWAIT COVERAGE present | 0 = absent> <case name> <gate output>
  if printf '%s' "$3" | grep -q 'NO AWAIT COVERAGE'; then got=1; else got=0; fi
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); echo "ok   $2"; else fail=$((fail + 1)); echo "FAIL $2 (NO AWAIT COVERAGE present=$got, expected $1)"; fi
}
expect_marker() { # expect_marker <case name> <expected events, ;-joined, stamps dropped>
  got=$(awk '{ $1 = ""; sub(/^ /, ""); print }' "$marker" 2>/dev/null | tr '\n' ';')
  if [ "$got" = "$2" ]; then pass=$((pass + 1)); echo "ok   $1"; else fail=$((fail + 1)); echo "FAIL $1 (marker: $got, expected: $2)"; fi
}
# --- the gate: in flight vs done
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"
expect 1 "dispatched lane, no doorbell yet: coverage asked for" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect 0 "lane done ([DONE] doorbell from the todo slug): nothing asked for" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-t lane-n" > "$marker"; msg 2026-10-26T10:05:00Z lane-n doorbell
expect 0 "lane done ([DONE] doorbell from the agent name, name differs from todo): nothing asked for" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect 0 "an older three-field marker line still reads done" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a blocker
expect 1 "a blocker does not end the flight" "$(run_gate)"
reset; printf '%s\n' "2026-10-26T10:00:00Z dispatch lane-a w-a" "2026-10-26T11:00:00Z dispatch lane-a w-a2" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect 1 "re-dispatch after an old doorbell is in flight again" "$(run_gate)"
reset; printf '%s\n' "2026-10-26T10:00:00Z dispatch lane-a w-a" "2026-10-26T10:00:00Z dispatch lane-b w-b" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect 1 "two lanes, one done: still in flight" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"; printf '%s' "$two_agents" > "$tmp/agents.json"
expect 1 "a keyless dispatch line counts as in flight while another agent is alive" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"
expect 0 "a keyless dispatch line with no other agent alive is not in flight forever" "$(run_gate)"
reset; printf '%s\n' "2026-10-26T10:00:00Z dispatch - -" "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"
expect 1 "a keyless line never masks a keyed lane still in flight" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z wait" > "$marker"
expect 0 "a lifecycle wait alone asks for no coverage" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; printf '{"awaiting":["orch-test"]}' > "$tmp/www/status"
expect 0 "a lane in flight under live await coverage asks for nothing" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell; chmod 000 "$db"
expect 1 "an unreadable relay DB counts the lane as in flight (fail-safe)" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
out=$(run_gate)
if printf '%s' "$out" | grep -q 'RELAY BACKLOG' && ! printf '%s' "$out" | grep -q 'leave coverage armed'; then
  pass=$((pass + 1)); echo "ok   the backlog line asks to act and consume, never to keep an idle await armed"
else
  fail=$((fail + 1)); echo "FAIL backlog line: $out"
fi
# --- the marker writer (org-lane-mark.sh)
reset
mark Bash '{"command":"dispatch-worker --name w1 --kind worker --todo lane-x --prompt \"see --todo note\""}'
expect_marker "Bash dispatch: --todo and --name recorded, a --todo inside the quoted prompt ignored" "dispatch lane-x w1;"
reset
mark Bash '{"command":"dispatch-worker --name a --todo lane-a --cwd /x; dispatch-worker --name b --todo lane-b --cwd /y"}'
expect_marker "two dispatches in one command: two marker lines" "dispatch lane-a a;dispatch lane-b b;"
reset
mark skyline_run '{"argv":["dispatch-worker","--todo","lane-y","--name","w2","--prompt","see --todo note"]}'
expect_marker "argv form: one line, prompt words ignored" "dispatch lane-y w2;"
reset
mark skyline_run_batch '{"argv_list":[["dispatch-worker","--todo=lane-p","--name=wp"],["dispatch-worker","--todo","lane-q"]]}'
expect_marker "argv_list form, --todo= and --name= forms: one line per array, - for a missing name" "dispatch lane-p wp;dispatch lane-q -;"
reset
mark skyline_run '{"argv":["sh","-c","dispatch-worker --todo lane-z --name w9 \"p x\""]}'
expect_marker "argv sh -c form: the inner command is classified" "dispatch lane-z w9;"
reset
mark Bash '{"command":"herdr agent start w3 && herdr agent wait w3"}'
expect_marker "herdr agent start records the agent name as the key; herdr agent wait records wait" "dispatch - w3;wait;"
reset
mark Bash '{"command":"grep dispatch-worker notes.md"}'
expect_marker "a command that merely mentions dispatch-worker leaves no mark" ""
reset
mark Bash '{"command":"dispatch-worker --help"}'
expect_marker "dispatch-worker --help leaves no mark" ""
reset
mark skyline_run '{"argv":["dispatch-worker","-h"]}'
expect_marker "dispatch-worker -h (argv form) leaves no mark" ""
reset
mark Bash '{"command":"herdr agent start --help"}'
expect_marker "herdr agent start --help leaves no mark" ""
reset
mark Bash '{"command":"sh /x/run-dispatch.sh"}'
expect_marker "a script-run dispatch is invisible to the hook" ""
# --- dispatch-worker records its own line (the script-run case)
dwscript="$tmp/run-dispatch.sh"
printf '#!/bin/sh\nsh "%s" --name w-s --todo lane-s --no-gauge --prompt go\n' "$here/../../scripts/dispatch-worker" > "$dwscript"
run_dw() { HERDR_ENV=1 HERDR_ORG_ROOT="$tmp/org" sh "$dwscript" >/dev/null 2>&1; }
reset
# Subshell: an assignment prefixed to a function call persists in POSIX sh.
(export CLAUDE_CODE_SESSION_ID="$sid"; run_dw)
expect_marker "script-run dispatch-worker appends its own line via CLAUDE_CODE_SESSION_ID" "dispatch lane-s w-s;"
reset
mark Bash '{"command":"true"}'
rm -f "$marker"
run_dw
expect_marker "no session env: dispatch-worker finds the session through the pane map the hook wrote" "dispatch lane-s w-s;"
reset
rm -f /tmp/claude-herdr-org-pane-p1
run_dw
expect_marker "no session env and no pane map: nothing recorded, nothing guessed" ""
echo "org-stop-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
