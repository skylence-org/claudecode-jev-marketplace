#!/bin/sh
# org-stop-gate.sh: the NO AWAIT COVERAGE line fires only while a dispatched
# lane is in flight (no [DONE] doorbell from it since its dispatch); a done
# lane, and an idle session, are asked for nothing (marketplace#2, review I-2).
# Stubs: a fake `herdr agent list` (pane p1 = orch-test), a fake daemon
# /status served by python3 http.server (nobody awaiting), a temp relay DB in
# the daemon's own schema under a temp HOME. No live model, no live daemon.
set -u
here=$(cd "$(dirname "$0")" && pwd)
gate="$here/../../hooks/org-stop-gate.sh"
for dep in jq sqlite3 python3 curl; do
  command -v "$dep" >/dev/null 2>&1 || { echo "org-stop-gate: skip ($dep missing)"; exit 0; }
done
sid="gate-test-$$"
tmp=$(mktemp -d)
srv=""
cleanup() {
  [ -n "$srv" ] && { kill "$srv" 2>/dev/null; wait "$srv" 2>/dev/null; }
  rm -rf "$tmp" "/tmp/claude-herdr-org-lanes-$sid" "/tmp/claude-herdr-org-sweep-$sid"
}
trap cleanup EXIT
export HOME="$tmp/home"
mkdir -p "$HOME/.config/herdr/org-relay" "$tmp/bin" "$tmp/www"
db="$HOME/.config/herdr/org-relay/relay.db"
sqlite3 "$db" "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, sender TEXT NOT NULL, recipient TEXT NOT NULL, lane TEXT, kind TEXT NOT NULL, body TEXT NOT NULL, consumed_at TEXT);"
printf '#!/bin/sh\necho %s\n' "'{\"result\":{\"agents\":[{\"pane_id\":\"p1\",\"name\":\"orch-test\"}]}}'" > "$tmp/bin/herdr"
chmod +x "$tmp/bin/herdr"
export HERDR_BIN_PATH="$tmp/bin/herdr" HERDR_PANE_ID=p1
printf '{"awaiting":[]}' > "$tmp/www/status"
port=$((7400 + $$ % 100))
(cd "$tmp/www" && exec python3 -m http.server "$port" --bind 127.0.0.1 >/dev/null 2>&1) &
srv=$!
export ORG_RELAY_PORT="$port"
i=0
until curl -s -m 1 "http://127.0.0.1:$port/status" >/dev/null 2>&1; do
  i=$((i + 1))
  [ "$i" -gt 50 ] && { echo "org-stop-gate: FAIL (stub daemon never came up on $port)"; exit 1; }
  sleep 0.1
done
marker="/tmp/claude-herdr-org-lanes-$sid"
run_gate() { printf '{"session_id":"%s","stop_hook_active":false}' "$sid" | sh "$gate"; }
reset() { rm -f "$marker" "/tmp/claude-herdr-org-sweep-$sid"; sqlite3 "$db" "DELETE FROM messages;"; }
msg() { sqlite3 "$db" "INSERT INTO messages(ts,sender,recipient,lane,kind,body) VALUES('$1','$2','orch-test','$2','$3','x');"; }
pass=0
fail=0
expect() { # expect <1 = line present | 0 = absent> <case name> <gate output>
  if printf '%s' "$3" | grep -q 'NO AWAIT COVERAGE'; then got=1; else got=0; fi
  if [ "$got" = "$1" ]; then pass=$((pass + 1)); echo "ok   $2"; else fail=$((fail + 1)); echo "FAIL $2 (NO AWAIT COVERAGE present=$got, expected $1)"; fi
}
reset; echo "2026-10-26T10:00:00Z dispatch lane-a" > "$marker"
expect 1 "dispatched lane, no doorbell yet: coverage asked for" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect 0 "lane done ([DONE] doorbell after the dispatch): nothing asked for" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch lane-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a blocker
expect 1 "a blocker does not end the flight" "$(run_gate)"
reset; printf '%s\n' "2026-10-26T10:00:00Z dispatch lane-a" "2026-10-26T11:00:00Z dispatch lane-a" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect 1 "re-dispatch after an old doorbell is in flight again" "$(run_gate)"
reset; printf '%s\n' "2026-10-26T10:00:00Z dispatch lane-a" "2026-10-26T10:00:00Z dispatch lane-b" > "$marker"; msg 2026-10-26T10:05:00Z lane-a doorbell
expect 1 "two lanes, one done: still in flight" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z dispatch" > "$marker"
expect 1 "a dispatch recorded without a slug counts as in flight" "$(run_gate)"
reset; echo "2026-10-26T10:00:00Z wait" > "$marker"
expect 0 "a lifecycle wait alone asks for no coverage" "$(run_gate)"
# org-lane-mark.sh writes the slug the gate matches on: dispatch-worker's --todo
# value, from a Bash command line or a skyline_run argv array; `herdr agent
# start` records a bare dispatch.
mark="$here/../../hooks/org-lane-mark.sh"
reset
printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"dispatch-worker --name w1 --kind worker --todo lane-x --prompt you-own-todo-lane-x"}}' "$sid" | sh "$mark"
printf '{"session_id":"%s","tool_name":"skyline_run","tool_input":{"argv":["dispatch-worker","--todo","lane-y","--name","w2"]}}' "$sid" | sh "$mark"
printf '{"session_id":"%s","tool_name":"Bash","tool_input":{"command":"herdr agent start w3"}}' "$sid" | sh "$mark"
lines=$(awk '{ $1 = ""; sub(/^ /, ""); print }' "$marker" | tr '\n' ';')
if [ "$lines" = "dispatch lane-x;dispatch lane-y;dispatch;" ]; then
  pass=$((pass + 1)); echo "ok   lane-mark records the --todo slug (Bash and argv forms), none for herdr agent start"
else
  fail=$((fail + 1)); echo "FAIL lane-mark marker lines: $lines"
fi
echo "org-stop-gate: $pass passed, $fail failed"
[ "$fail" = 0 ]
