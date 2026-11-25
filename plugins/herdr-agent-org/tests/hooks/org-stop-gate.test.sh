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
# The lanes the keyed cases dispatch, alive and working (0.1.7: a keyed line
# whose agent is no longer listed is done).
lanes_alive='{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1","agent_status":"working"},{"pane_id":"p2","name":"w-a","workspace_id":"w1","agent_status":"working"},{"pane_id":"p3","name":"w-a2","workspace_id":"w1","agent_status":"working"},{"pane_id":"p4","name":"w-b","workspace_id":"w1","agent_status":"working"},{"pane_id":"p5","name":"lane-n","workspace_id":"w1","agent_status":"working"}]}}'
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
reset() { rm -f "$marker" "/tmp/claude-herdr-org-sweep-$sid"; chmod 644 "$db"; sqlite3 "$db" "DELETE FROM messages;"; printf '{"awaiting":[]}' > "$tmp/www/status"; printf '%s' "$lanes_alive" > "$tmp/agents.json"; }
agents() { printf '%s' "$1" > "$tmp/agents.json"; }
run_gate_ws() { (export HERDR_WORKSPACE_ID="$1"; run_gate); }
msg() { sqlite3 "$db" "INSERT INTO messages(ts,sender,recipient,lane,kind,body) VALUES('$1','$2','orch-test','$2','$3','x');"; }
msgc() { msg "$@"; sqlite3 "$db" "UPDATE messages SET consumed_at='2026-10-26T23:00:00Z';"; }
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
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"; agents "$one_agent"
expect 0 "a keyless dispatch line with no other agent alive is not in flight forever" "$(run_gate)"
reset; printf '%s\n' "2026-10-26T10:00:00Z dispatch - -" "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"
expect 1 "a keyless line never masks a keyed lane still in flight" "$(run_gate)"
# --- keyless liveness counts only named, unfinished lanes in this workspace (0.1.7, review M3)
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1"},{"pane_id":"p7","workspace_id":"w1","agent_status":"idle"}]}}'
expect 0 "shape B: an unnamed idle operator pane does not hold a keyless line in flight" "$(run_gate_ws w1)"
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1"},{"pane_id":"p2","name":"w-d","workspace_id":"w1","agent_status":"done"},{"pane_id":"p3","name":"w-i","workspace_id":"w1","agent_status":"idle"}]}}'
msg 2026-10-26T10:05:00Z w-i doorbell; msg 2026-10-26T10:06:00Z w-d doorbell
expect 0 "shape C: a done and an idle worker, each past its own [DONE], do not hold a keyless line" "$(run_gate_ws w1)"
# herdr `done` = idle plus unseen output: a mid-lane worker whose turn ended (review I2)
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1"},{"pane_id":"p2","name":"w-d","workspace_id":"w1","agent_status":"done"}]}}'
expect 1 "a done-status worker with no [DONE] doorbell still holds a keyless line" "$(run_gate_ws w1)"
# a previous round's [DONE] does not finish a re-dispatched worker (review M1, FN5)
reset; printf '%s\n' "2026-10-26T10:00:00Z dispatch - -" "2026-10-26T11:00:00Z dispatch - -" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1"},{"pane_id":"p3","name":"w-i","workspace_id":"w1","agent_status":"idle"}]}}'
msg 2026-10-26T10:30:00Z w-i doorbell
expect 1 "FN5: a [DONE] older than the newest dispatch line does not finish the worker" "$(run_gate_ws w1)"
# HERDR_WORKSPACE_ID unset: scope to this pane's own workspace, never all (review M3)
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1"},{"pane_id":"p9","name":"w-o","workspace_id":"w2","agent_status":"working"}]}}'
expect 0 "orig-B: no HERDR_WORKSPACE_ID, a working lane in another workspace does not hold the line" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1"},{"pane_id":"p9","name":"w-o","workspace_id":"w2","agent_status":"working"}]}}'
expect 0 "shape D: a working lane in another workspace does not hold a keyless line" "$(run_gate_ws w1)"
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test","workspace_id":"w1"},{"pane_id":"p3","name":"w-i","workspace_id":"w1","agent_status":"idle"}]}}'
expect 1 "control: an idle named worker with no [DONE] yet still holds a keyless line" "$(run_gate_ws w1)"
# --- a keyed line ends when its agent is gone (0.1.7, review M4)
reset; echo "2026-10-26T10:00:00Z dispatch - helper" > "$marker"; agents "$one_agent"
expect 0 "shape F: herdr agent start of a non-lane agent, agent no longer listed: done" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch - helper" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p1","name":"orch-test"},{"pane_id":"p5","name":"helper","agent_status":"working"}]}}'
expect 1 "control: the same keyed line while the agent is still listed: in flight" "$(run_gate)"
# A partial list (herdr rehydrating, this pane's own agent missing) never ends keyed lanes (review M2, FN3b)
expect_dbg() { # expect_dbg <in_flight 0|1> <case name>
  got=$(printf '{"session_id":"%s","stop_hook_active":false}' "$sid" | ORG_STOP_GATE_DEBUG=1 sh "$gate" 2>&1 >/dev/null | sed -n 's/.*in_flight=\([01]\).*/\1/p')
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); echo "ok   $2"; else fail=$((fail + 1)); echo "FAIL $2 (in_flight=$got, expected $1)"; fi
}
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"
agents '{"result":{"agents":[{"pane_id":"p7","name":"someone","workspace_id":"w1","agent_status":"working"}]}}'
expect_dbg 1 "FN3b: a list without this pane's agent does not end a keyed lane"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; printf 'not json' > "$tmp/agents.json"
expect_dbg 1 "herdr unreadable: a keyed line without a doorbell stays in flight"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; agents "$one_agent"
expect_dbg 0 "control: a full list without w-a ends the keyed lane"
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
# --- leading shell keywords (0.1.7, review M6)
reset
mark Bash '{"command":"for n in a b; do herdr agent start \"$n\" --pane x; done"}'
expect_marker "for ... do herdr agent start \"\$n\": classified, a \$-name is no key" "dispatch - -;"
reset
mark Bash '{"command":"if true; then herdr agent start w7; else herdr agent start w8; fi"}'
expect_marker "then/else stages are classified" "dispatch - w7;dispatch - w8;"
reset
mark Bash '{"command":"{ dispatch-worker --name w9 --todo lane-9; }"}'
expect_marker "a { group } stage is classified" "dispatch lane-9 w9;"
# --- prefix commands and subshells (PR #9 review M6)
reset
mark Bash '{"command":"time dispatch-worker --name w1 --todo l1"}'
expect_marker "time dispatch-worker: classified" "dispatch l1 w1;"
reset
mark Bash '{"command":"(herdr agent start w2)"}'
expect_marker "(subshell): classified, no ) glued to the name" "dispatch - w2;"
reset
mark Bash '{"command":"nohup herdr agent start w3 > /tmp/x.log 2>&1 &"}'
expect_marker "nohup ... &: classified" "dispatch - w3;"
reset
mark Bash '{"command":"env FOO=1 BAR=2 dispatch-worker --name w4 --todo l4"}'
expect_marker "env VAR=... dispatch-worker: classified" "dispatch l4 w4;"
reset
mark Bash '{"command":"exec herdr agent start w5"}'
expect_marker "exec herdr agent start: classified" "dispatch - w5;"
reset
mark Bash '{"command":"out=$(dispatch-worker --name w6 --todo l6)"}'
expect_marker "a \$( ) capture: classified" "dispatch l6 w6;"
reset
mark Bash '{"command":"sh /x/run-dispatch.sh"}'
expect_marker "a script-run dispatch is invisible to the hook" ""
reset
mark Bash '{"command":"dispatch-worker --relaunch w5 --model opus --upgrade-reason x"}'
expect_marker "dispatch-worker --relaunch records the relaunched agent name" "dispatch - w5;"
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
# --- quiet gate (0.1.10): output contract first; a DRAINED fingerprint (nothing
# in flight, backlog a known number) keys on the dispatch lines at backlog 0 and
# on the whole marker above 0, so the in-flight-to-done edge blocks once and
# only repeat drained stops (and wait lines at backlog 0) are quiet.
# Multi-stop cases: each starts from reset and runs every stop through the gate
# (audit-herdr-pr20 C1: a quiet stop must still write its fingerprint).
expect_out() { # expect_out <1 = output non-empty | 0 = empty> <case name> <gate output>
  if [ -n "$3" ]; then got=1; else got=0; fi
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); echo "ok   $2"; else fail=$((fail + 1)); echo "FAIL $2 (blocked=$got, expected $1)"; fi
}
expect_has() { # expect_has <fixed string> <case name> <gate output>
  if printf '%s' "$3" | jq -r '.reason // empty' | grep -Fq -- "$1"; then pass=$((pass + 1)); echo "ok   $2"; else fail=$((fail + 1)); echo "FAIL $2 (reason lacks: $1)"; fi
}
cover() { printf '{"awaiting":[%s]}' "$1" > "$tmp/www/status"; }
consume_all() { sqlite3 "$db" "UPDATE messages SET consumed_at='2026-10-26T23:00:00Z' WHERE consumed_at IS NULL;"; }
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; out=$(run_gate)
expect_out 1 "in flight: still blocks" "$out"
[ "$(printf '%s' "$out" | jq -r '.reason' | grep -o 'OUTPUT CONTRACT' | head -1)" = "OUTPUT CONTRACT" ] && [ "$(printf '%s' "$out" | jq -r '.reason' | cut -c1-16)" = "OUTPUT CONTRACT:" ] && { pass=$((pass + 1)); echo "ok   reason starts with the one-line output contract"; } || { fail=$((fail + 1)); echo "FAIL reason does not start with the output contract"; }
expect_has "reply in chat with one status line" "contract asks for one status line" "$out"
expect_has "<fixes, ;-joined>" "contract lets the status line carry every fix" "$out"
expect_has "plus the **Questions** block or the question tool when check (4) applies" "contract keeps the Questions block for check (4)" "$out"
expect_has "plus any incident line the skill requires" "contract keeps required incident lines" "$out"
expect_has "settle lane tree + branch per merge state (L5)" "check (2) keeps per merge state (L5)" "$out"
expect_has "register, arm, or write it (L6)" "check (3) keeps or write it" "$out"
expect_has "WAKE, ACCEPT SEQUENCE and L4-L6" "detail pointer names WAKE, ACCEPT SEQUENCE, L4-L6" "$out"
expect_has "(5) anything you are about to assert" "checklist kept after the contract" "$out"
expect_has "NO AWAIT COVERAGE" "no-coverage block unchanged" "$out"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msgc 2026-10-26T10:05:00Z lane-a doorbell
expect_out 1 "lane done, backlog 0, first evaluation: blocks (the drain edge is never skipped)" "$(run_gate)"
expect_out 0 "lane done, backlog 0, repeat stop: quiet" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell; msg 2026-10-26T10:06:00Z lane-a blocker
out=$(run_gate)
expect_out 1 "lane done but backlog queued: blocks" "$out"
expect_has "RELAY BACKLOG" "backlog block unchanged" "$out"
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"; agents "$one_agent"
expect_out 1 "keyless dispatch, no other agent alive, first evaluation: blocks" "$(run_gate)"
expect_out 0 "keyless dispatch, no other agent alive, repeat stop: quiet" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; cover '"orch-test"'; run_gate >/dev/null
expect_out 0 "in flight and covered: settled fingerprint re-stop does not block" "$(run_gate)"
# (a) the last lane rang [DONE] and was consumed in-turn; its agent is still alive (unreaped)
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; cover '"orch-test"'; run_gate >/dev/null
cover ""; msgc 2026-10-26T10:05:00Z lane-a doorbell; out=$(run_gate)
expect_out 1 "(a) last lane DONE and consumed, agent alive: the drain stop blocks once" "$out"
expect_has "(2) live agent whose lane todo is verified or complete?" "(a) the drain sweep carries the reap check" "$out"
expect_out 0 "(a) repeat drained stop, nothing new: quiet" "$(run_gate)"
# (b) every lane done and reaped; lane tree/branch still open (L5)
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; cover '"orch-test"'; run_gate >/dev/null
cover ""; msgc 2026-10-26T10:05:00Z lane-a doorbell; agents "$one_agent"
expect_out 1 "(b) all lanes done and reaped, tree/branch open: the drain stop blocks once" "$(run_gate)"
expect_out 0 "(b) repeat drained stop, nothing new: quiet" "$(run_gate)"
# (m3) crashed lane: in flight and covered, then the agent is gone with no doorbell
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; cover '"orch-test"'; run_gate >/dev/null
agents "$one_agent"
expect_out 1 "(m3) crashed lane (agent gone, no doorbell): blocks" "$(run_gate)"
expect_out 0 "(m3) repeat drained stop, nothing new: quiet" "$(run_gate)"
# (m1) nothing in flight; backlog 1 -> 0 -> 1 (a later job wake, peer message or late blocker)
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect_out 1 "(m1) drained with the [DONE] queued: blocks" "$(run_gate)"
consume_all
expect_out 1 "(m1) backlog consumed (1 -> 0): blocks, as 0.1.9 did" "$(run_gate)"
msg 2026-10-26T12:00:00Z gate-job job; out=$(run_gate)
expect_out 1 "(m1) a later job wake (backlog 0 -> 1): blocks again" "$out"
expect_has "RELAY BACKLOG" "(m1) the re-block carries RELAY BACKLOG" "$out"
# (m2) keyless line in flight -> not -> in flight again, uncovered
reset; echo "2026-10-26T10:00:00Z dispatch - -" > "$marker"; agents "$two_agents"; run_gate >/dev/null
agents "$one_agent"
expect_out 1 "(m2) keyless lane finished: the drain stop blocks" "$(run_gate)"
agents "$two_agents"
expect 1 "(m2) keyless lane back in flight, uncovered: NO AWAIT COVERAGE again" "$(run_gate)"
# (c1) / (c4) backlog unknown (herdr unreadable / HERDR_PANE_ID unset): the 0.1.9 fingerprint, so any marker change blocks
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; printf 'not json' > "$tmp/agents.json"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect_out 1 "(c1) herdr unreadable, lane DONE unconsumed: blocks" "$(run_gate)"
echo "2026-10-26T11:00:00Z wait" >> "$marker"
expect_out 1 "(c1) backlog unknown: a wait line still moves the fingerprint (0.1.9 behaviour)" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect_out 1 "(c4) HERDR_PANE_ID unset, lane DONE unconsumed: blocks" "$(export HERDR_PANE_ID=""; run_gate)"
echo "2026-10-26T11:00:00Z wait" >> "$marker"
expect_out 1 "(c4) backlog unknown: a wait line still moves the fingerprint (0.1.9 behaviour)" "$(export HERDR_PANE_ID=""; run_gate)"
# (d1) / (m4) lifecycle wait lines while drained with a known backlog: the 0.1.10 saving
reset; echo "2026-10-26T10:00:00Z wait" > "$marker"
expect_out 1 "(d1) lifecycle waits only, first evaluation: blocks (as 0.1.9)" "$(run_gate)"
echo "2026-10-26T11:00:00Z wait" >> "$marker"
expect_out 0 "(d1) another wait line while drained: quiet (0.1.10 change)" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msgc 2026-10-26T10:05:00Z lane-a doorbell; run_gate >/dev/null
echo "2026-10-26T11:00:00Z wait" >> "$marker"
expect_out 0 "(m4) a wait line appended after the drain sweep: quiet (0.1.10 change)" "$(run_gate)"
echo "2026-10-26T11:30:00Z dispatch lane-b w-gone" >> "$marker"
expect_out 1 "a new dispatch line while drained (its agent already gone): blocks" "$(run_gate)"
# (X3) / (X7) drained with a NON-ZERO backlog: wait lines still move the fingerprint (quiet only at backlog 0; round-2 review F1)
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell; run_gate >/dev/null
echo "2026-10-26T11:00:00Z wait" >> "$marker"
expect_has "RELAY BACKLOG" "(X3) drained, backlog 1, a wait line appended: re-blocks with RELAY BACKLOG" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell; run_gate >/dev/null
consume_all; echo "2026-10-26T11:00:00Z wait" >> "$marker"; msg 2026-10-26T11:05:00Z lane-a blocker
expect_has "RELAY BACKLOG" "(X7) backlog consumed in the continuation, wait line, then a new message: RELAY BACKLOG" "$(run_gate)"
# (E1) /status dead throughout: the drain edge still blocks once (0.1.9 was silent here; the d- prefix carries it)
run_gate_dead() { (export ORG_RELAY_PORT=1; run_gate); }
reset; echo "2026-10-26T10:00:00Z dispatch lane-a w-a" > "$marker"
expect_out 1 "(E1) /status dead, lane in flight: blocks" "$(run_gate_dead)"
msgc 2026-10-26T10:05:00Z lane-a doorbell
expect_out 1 "(E1) /status dead, last lane DONE and consumed: the drain stop blocks" "$(run_gate_dead)"
expect_out 0 "(E1) /status dead, repeat drained stop: quiet" "$(run_gate_dead)"
echo "org-stop-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
