#!/bin/sh
# Stop hook: anti-idle gate. A session that put Herdr org state in flight may
# not end its turn without confirming follow-up. Blocks the FIRST stop only
# (stop_hook_active passes the second), so it costs one extra turn, not a loop.
#
# Carries both fixes the Solo sibling landed 2026-07-21, which the Grok/Herdr
# port predates:
#   PREMISE FOLLOWS EVIDENCE. org-lane-mark.sh records dispatch and wait
#     separately, so a session that only armed a lifecycle wait is never told it
#     dispatched workers.
#   SETTLE. An answered sweep does not re-fire until org state actually moves.
#     The marker's fingerprint IS the state: any new dispatch or wait appends a
#     line, moves the fingerprint, and re-arms the sweep.
#   RELAY BACKLOG (2026-08-04, paddle-GDPR stall): unconsumed relay messages
#     for this pane's agent fold into the fingerprint, so a stop onto a
#     non-empty queue re-fires the sweep once per backlog change — the 15:24Z
#     stall turn ended onto a settled fingerprint while [DONE]/[BLOCKER]
#     messages rotted for 3h23m.
#   AWAIT COVERAGE (org-relay 1.0): with dispatches recorded, a stop while
#     this agent holds no live relay_await (GET /status .awaiting, no MCP
#     handshake needed) re-blocks once with the arm-coverage instruction —
#     the mechanical form of L6's "turn ended with lanes in flight and no
#     await armed". Fail-open: an unreachable daemon never blocks a stop.
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ "$active" = "true" ] && exit 0
marker="/tmp/claude-herdr-org-lanes-$sid"
{ [ -n "$sid" ] && [ -f "$marker" ]; } || exit 0

backlog=""; me=""; covered=""
relay_db="$HOME/.config/herdr/org-relay/relay.db"
if [ -n "${HERDR_PANE_ID:-}" ] && [ -f "$relay_db" ] && command -v sqlite3 >/dev/null 2>&1; then
  me=$("${HERDR_BIN_PATH:-herdr}" agent list 2>/dev/null | jq -r --arg p "$HERDR_PANE_ID" '.result.agents[]? | select(.pane_id==$p) | .name // empty' 2>/dev/null | head -1)
  if [ -n "$me" ]; then
    me_sql=$(printf '%s' "$me" | sed "s/'/''/g")
    backlog=$(sqlite3 -readonly "$relay_db" "SELECT COUNT(*) FROM messages WHERE recipient='$me_sql' AND consumed_at IS NULL;" 2>/dev/null)
    status_json=$(curl -s -m 2 "http://127.0.0.1:${ORG_RELAY_PORT:-7431}/status" 2>/dev/null)
    if [ -n "$status_json" ]; then
      covered=$(printf '%s' "$status_json" | jq -r --arg a "$me" '.awaiting // [] | if index($a) then 1 else 0 end' 2>/dev/null)
    fi
  fi
fi
fp="$(cksum < "$marker" | awk '{print $1 "-" $2}')${backlog:+-b$backlog}${covered:+-c$covered}"
seen="/tmp/claude-herdr-org-sweep-$sid"
[ -f "$seen" ] && [ "$(cat "$seen" 2>/dev/null)" = "$fp" ] && exit 0
printf '%s' "$fp" > "$seen"

if grep -q ' dispatch$' "$marker" 2>/dev/null; then
  premise="this session dispatched Herdr workers"
else
  premise="this session armed Herdr org state (lifecycle waits; no worker dispatch recorded)"
fi

relay_line=""
if [ -n "$backlog" ] && [ "$backlog" -gt 0 ] 2>/dev/null; then
  relay_line="RELAY BACKLOG: $backlog unconsumed relay message(s) queued for '$me' — relay_inbox(agent: $me), act, consume, and leave coverage armed BEFORE idling. "
fi
if [ "$covered" = "0" ] && grep -q ' dispatch$' "$marker" 2>/dev/null; then
  relay_line="${relay_line}NO AWAIT COVERAGE: lanes are in flight and '$me' holds no live relay_await — arm ONE long relay_await(agent: $me, timeout_s: 1800) as the LAST call before idling (L6). "
fi

reason="ANTI-IDLE FINGERPRINT SWEEP ($premise; post-compaction: re-invoke your role skill FIRST). Run it against live reads, not memory, meaning board list + herdr agent list: (1) an idle/done/blocked worker with no verdict? read it (herdr agent read --source visible for the current frame, --source recent --lines N to reach back through scrollback; either way its board comments are what outlive the pane) and post the verdict on its lane todo NOW; (2) a live agent whose lane todo is verified or complete? unregister then reap it NOW (waker-ctl unregister --lane <lane>, L6, then L4) and settle lane tree + branch per merge state (L5); (3) a working agent with neither a waker registration (waker-ctl list) nor an armed herdr agent wait nor a written re-check plan? register or arm or write it (L6); (4) a blocking operator question still unposted? inbox pad plus one line under Questions; (5) anything you are about to assert that a board list / herdr agent list read would contradict? correct it (L15). Then stop."
# jq builds the payload so the reason is JSON-escaped rather than hand-quoted.
jq -n --arg r "${relay_line}${reason}" '{decision:"block", reason:$r}'
exit 0
