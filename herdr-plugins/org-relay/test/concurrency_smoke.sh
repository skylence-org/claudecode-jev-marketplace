#!/bin/sh
# Concurrency smoke: the parallel-org shape. Starts its own daemon on a
# scratch port + db, then proves: (1) N simultaneous awaits register coverage
# (3 task-backed + 3 in-call held), (2) a parallel send fan-out wakes every
# one of them with the right message, (3) a 40-send burst to one recipient
# loses nothing, (4) two sessions racing to consume the same id: exactly one
# wins. Exit 0 = all held. Requires: cargo build artifact, curl, jq.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
PORT=7497
URL="http://127.0.0.1:$PORT/mcp"
DB=$(mktemp -d)/relay-conc.db
BIN="$DIR/target/debug/org-relay"
[ -x "$BIN" ] || BIN="$DIR/target/release/org-relay"
[ -x "$BIN" ] || { echo "concurrency: no binary; run cargo build first"; exit 1; }

ORG_RELAY_PORT=$PORT ORG_RELAY_DB="$DB" ORG_RELAY_NUDGE=0 "$BIN" >/dev/null 2>&1 &
SRV=$!
trap 'kill $SRV 2>/dev/null' EXIT
i=0; until curl -s -m 1 "http://127.0.0.1:$PORT/health" | grep -q ok; do
  i=$((i+1)); [ $i -gt 20 ] && { echo "concurrency: daemon never came up"; exit 1; }; sleep 0.5
done

WORK=$(mktemp -d)
AWAIT_PIDS=""; SEND_PIDS=""; BURST_PIDS=""; RACE_PIDS=""
fail=0
err() { echo "concurrency: FAIL $*"; fail=1; }

# One MCP session per simulated worker. cap=tasks declares the extension.
new_session() { # $1=tag $2=cap
  h="$WORK/$1.hdrs"
  if [ "$2" = "tasks" ]; then
    caps='{"extensions":{"io.modelcontextprotocol/tasks":{}}}'
  else
    caps='{}'
  fi
  curl -s -m 15 -D "$h" -o "$WORK/$1.init" -X POST "$URL" \
    -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\",\"capabilities\":$caps,\"clientInfo\":{\"name\":\"conc-$1\",\"version\":\"1\"}}}"
  sid=$(grep -i '^mcp-session-id:' "$h" | tr -d '\r' | awk '{print $2}')
  [ -n "$sid" ] || { echo "concurrency: FAIL no session id for $1 ($(head -c 120 "$WORK/$1.init"))" >&2; }
  call "$sid" '{"jsonrpc":"2.0","method":"notifications/initialized"}' >/dev/null
  call "$sid" '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"relay_guide","arguments":{}}}' >/dev/null
  echo "$sid"
}
call() { # $1=sid $2=body -> payload on stdout; 90s cap covers a 60s hold leg
  curl -s -m 90 -X POST "$URL" -H 'Content-Type: application/json' \
    -H 'Accept: application/json, text/event-stream' -H "Mcp-Session-Id: $1" -d "$2" \
    | sed -n 's/^data: //p' | tail -1
}

# (1) Six workers arm awaits concurrently: par1-3 task-backed, par4-6 in-call.
echo "concurrency: phase 1 (sessions + parallel awaits)"
for n in 1 2 3; do
  SID=$(new_session "t$n" tasks)
  echo "$SID" > "$WORK/sid-t$n"
  call "$SID" "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"relay_await\",\"arguments\":{\"agent\":\"par$n\",\"timeout_s\":60}}}" > "$WORK/task-$n" & AWAIT_PIDS="$AWAIT_PIDS $!"
done
for n in 4 5 6; do
  SID=$(new_session "h$n" plain)
  echo "$SID" > "$WORK/sid-h$n"
  call "$SID" "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"relay_await\",\"arguments\":{\"agent\":\"par$n\",\"timeout_s\":60}}}" > "$WORK/hold-$n" & AWAIT_PIDS="$AWAIT_PIDS $!"
done
sleep 3
awaiting=$(curl -s "http://127.0.0.1:$PORT/status" | jq -r '.awaiting | sort | join(",")')
[ "$awaiting" = "par1,par2,par3,par4,par5,par6" ] || err "coverage: awaiting=[$awaiting], want par1..par6"

# (2) Parallel fan-out: one sender session, six sends at once.
echo "concurrency: phase 2 (fan-out)"
S=$(new_session sender plain)
for n in 1 2 3 4 5 6; do
  call "$S" "{\"jsonrpc\":\"2.0\",\"id\":1$n,\"method\":\"tools/call\",\"params\":{\"name\":\"relay_send\",\"arguments\":{\"sender\":\"orch\",\"to\":\"par$n\",\"kind\":\"doorbell\",\"body\":\"go-$n\"}}}" >/dev/null & SEND_PIDS="$SEND_PIDS $!"
done
wait $AWAIT_PIDS $SEND_PIDS
# In-call holds return with the message; task holds resolve via tasks/get.
for n in 4 5 6; do
  grep -q "go-$n" "$WORK/hold-$n" || err "in-call par$n did not wake with go-$n: $(cat "$WORK/hold-$n" | head -c 200)"
done
for n in 1 2 3; do
  tid=$(jq -r '.result.taskId // empty' "$WORK/task-$n" 2>/dev/null)
  [ -n "$tid" ] || { err "par$n returned no task handle: $(head -c 200 "$WORK/task-$n")"; continue; }
  SID=$(cat "$WORK/sid-t$n")
  ok=""
  for _ in 1 2 3 4 5 6 7 8 9 10; do
    got=$(call "$SID" "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tasks/get\",\"params\":{\"taskId\":\"$tid\"}}")
    echo "$got" | grep -q '"status":"completed"' && { echo "$got" | grep -q "go-$n" && ok=1; break; }
    sleep 1
  done
  [ -n "$ok" ] || err "task par$n never completed with go-$n"
done

# (3) Burst: 40 parallel sends to one recipient; nothing may be lost.
echo "concurrency: phase 3 (burst)"
for n in $(seq 1 40); do
  call "$S" "{\"jsonrpc\":\"2.0\",\"id\":3$n,\"method\":\"tools/call\",\"params\":{\"name\":\"relay_send\",\"arguments\":{\"sender\":\"w$n\",\"to\":\"burst-target\",\"kind\":\"other\",\"body\":\"b-$n\"}}}" >/dev/null & BURST_PIDS="$BURST_PIDS $!"
done
wait $BURST_PIDS
count=$(call "$S" '{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"relay_inbox","arguments":{"agent":"burst-target"}}}' | jq -r '.result.structuredContent.count // 0')
[ "$count" = "40" ] || err "burst: inbox count=$count, want 40"

# (4) Consume race: two sessions consume the same id; exactly one wins.
echo "concurrency: phase 4 (consume race)"
mid=$(call "$S" '{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"relay_inbox","arguments":{"agent":"burst-target"}}}' | jq -r '.result.structuredContent.messages[0].id')
S2=$(new_session racer plain)
call "$S"  "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"relay_consume\",\"arguments\":{\"agent\":\"burst-target\",\"ids\":[$mid]}}}" > "$WORK/c1" & RACE_PIDS="$RACE_PIDS $!"
call "$S2" "{\"jsonrpc\":\"2.0\",\"id\":43,\"method\":\"tools/call\",\"params\":{\"name\":\"relay_consume\",\"arguments\":{\"agent\":\"burst-target\",\"ids\":[$mid]}}}" > "$WORK/c2" & RACE_PIDS="$RACE_PIDS $!"
wait $RACE_PIDS
won=$(cat "$WORK/c1" "$WORK/c2" | jq -r '.result.structuredContent.consumed' | awk '{s+=$1} END{print s}')
[ "$won" = "1" ] || err "consume race: total consumed=$won, want exactly 1"

if [ "$fail" = 0 ]; then echo "concurrency: OK (6 parallel awaits mixed task/hold, fan-out wake, 40-send burst, consume race)"; else echo "concurrency: FAILED"; exit 1; fi
