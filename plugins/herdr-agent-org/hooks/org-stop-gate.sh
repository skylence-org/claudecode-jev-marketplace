#!/bin/sh
# Stop hook: anti-idle gate. A session that put Herdr org state in flight may
# not end its turn without confirming follow-up. Blocks the FIRST stop only
# (stop_hook_active passes the second), so it costs one extra turn, not a loop.
#
# Two rules, both field-driven (2026-07-21):
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
#   AWAIT COVERAGE (org-relay 1.0; LANES IN FLIGHT ONLY since marketplace#2):
#     with a lane in flight — a marker line `dispatch <todo> <name>` the relay
#     holds no `doorbell` ([DONE]) for since, from either key — a stop while
#     this agent holds no live relay_await (GET /status .awaiting, no MCP
#     handshake needed) re-blocks once with the arm-coverage instruction, the
#     mechanical form of L6. With every dispatched lane done, coverage is
#     neither asked for nor part of the fingerprint: an idle orchestrator arms
#     nothing (marketplace#1).
#   KEYLESS LINES (0.1.6, narrowed 0.1.7): a dispatch line with no key can
#     never be matched to a doorbell, so it counts as in flight only while
#     `herdr agent list` shows an unfinished LANE in this workspace: a named
#     agent on another pane whose status is not done and that is not idle
#     after its own [DONE] doorbell. Unnamed operator panes and finished
#     workers never hold it (12/12 complete, no worker alive, gate still
#     demanding an await: skyway #550 session; review M3 of PR #8).
#   GONE AGENTS (0.1.7, review M4): a keyed line whose agent name is no
#     longer listed is done; a lane that died without a doorbell is the
#     waker's to report, and a `herdr agent start` of a non-lane agent never
#     sends one.
#     Fail-open: an unreachable daemon never blocks a stop; an unreadable
#     relay DB counts every dispatch as in flight.
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
active=$(printf '%s' "$input" | jq -r '.stop_hook_active // false')
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ "$active" = "true" ] && exit 0
marker="/tmp/claude-herdr-org-lanes-$sid"
{ [ -n "$sid" ] && [ -f "$marker" ]; } || exit 0

backlog=""; me=""; covered=""; agents_json=""
relay_db="$HOME/.config/herdr/org-relay/relay.db"
[ -n "${HERDR_PANE_ID:-}" ] && agents_json=$("${HERDR_BIN_PATH:-herdr}" agent list 2>/dev/null)
if [ -n "${HERDR_PANE_ID:-}" ] && [ -f "$relay_db" ] && command -v sqlite3 >/dev/null 2>&1; then
  me=$(printf '%s' "$agents_json" | jq -r --arg p "$HERDR_PANE_ID" '.result.agents[]? | select(.pane_id==$p) | .name // empty' 2>/dev/null | head -1)
  if [ -n "$me" ]; then
    me_sql=$(printf '%s' "$me" | sed "s/'/''/g")
    backlog=$(sqlite3 -readonly "$relay_db" "SELECT COUNT(*) FROM messages WHERE recipient='$me_sql' AND consumed_at IS NULL;" 2>/dev/null)
    status_json=$(curl -s -m 2 "http://127.0.0.1:${ORG_RELAY_PORT:-7431}/status" 2>/dev/null)
    if [ -n "$status_json" ]; then
      covered=$(printf '%s' "$status_json" | jq -r --arg a "$me" '.awaiting // [] | if index($a) then 1 else 0 end' 2>/dev/null)
    fi
  fi
fi
# Unfinished lanes on other panes of this workspace (workers split into the
# orchestrator's own): named, not done, not idle past their own [DONE].
# Empty when herdr was not readable. Names of every listed agent, for the
# gone-agent rule.
others=""; listed=""; agents_ok=0
first_ts=$(awk 'NR == 1 { print $1 }' "$marker")
if [ -n "$agents_json" ] && printf '%s' "$agents_json" | jq -e '.result.agents' >/dev/null 2>&1; then
  agents_ok=1
  listed=$(printf '%s' "$agents_json" | jq -r '.result.agents[]? | .name // empty' 2>/dev/null)
  others=0
  cand=$(printf '%s' "$agents_json" | jq -r --arg p "${HERDR_PANE_ID:-}" --arg w "${HERDR_WORKSPACE_ID:-}" '.result.agents[]? | select(.pane_id != $p and ($w == "" or .workspace_id == $w)) | select((.name // "") != "" and (.agent_status // "") != "done") | "\(.agent_status // "-") \(.name)"' 2>/dev/null)
  while read -r st nm; do
    [ -n "$nm" ] || continue
    if [ "$st" = idle ] && [ -f "$relay_db" ] && command -v sqlite3 >/dev/null 2>&1; then
      nm_sql=$(printf '%s' "$nm" | sed "s/'/''/g")
      rang=$(sqlite3 -readonly "$relay_db" "SELECT COUNT(*) FROM messages WHERE sender='$nm_sql' AND kind='doorbell' AND ts >= '$first_ts';" 2>/dev/null </dev/null)
      [ "${rang:-0}" -gt 0 ] 2>/dev/null && continue
    fi
    others=$((others + 1))
  done <<EOF
$cand
EOF
fi
# Each marker line `<ts> dispatch <todo> <name>` is in flight until the relay
# holds a `doorbell` whose sender is that lane's todo slug or its agent name
# (`-` = unknown; older lines carry one field or none) stamped at or after the
# line's own stamp (both ISO-8601 UTC, so string order is time order; a blocker
# does not end the flight; a re-dispatch is a new line). A failed query or no
# readable relay DB: in flight. A line with no key: in flight while another
# unfinished lane is alive (or herdr is unreadable), done once none is. A
# line whose agent name herdr no longer lists: done.
in_flight=0
if grep -Eq ' dispatch( |$)' "$marker" 2>/dev/null; then
  if ! { [ -f "$relay_db" ] && command -v sqlite3 >/dev/null 2>&1; }; then
    in_flight=1
  else
    while read -r since ev todo name; do
      [ "$ev" = "dispatch" ] || continue
      keys=""
      for k in "$todo" "$name"; do
        case "$k" in
          ""|-) ;;
          *) keys="${keys:+$keys,}'$(printf '%s' "$k" | sed "s/'/''/g")'" ;;
        esac
      done
      if [ -z "$keys" ]; then
        [ "${others:-1}" = "0" ] || { in_flight=1; break; }
        continue
      fi
      if [ "$agents_ok" = 1 ] && [ "$name" != "-" ] && [ -n "$name" ] && ! printf '%s\n' "$listed" | grep -Fxq -- "$name"; then
        continue
      fi
      done_n=$(sqlite3 -readonly "$relay_db" "SELECT COUNT(*) FROM messages WHERE sender IN ($keys) AND kind='doorbell' AND ts >= '$since';" 2>/dev/null </dev/null)
      [ "${done_n:-0}" -gt 0 ] 2>/dev/null || { in_flight=1; break; }
    done < "$marker"
  fi
fi
cov_fp=""
[ "$in_flight" = "1" ] && cov_fp="${covered:+-c$covered}"
fp="$(cksum < "$marker" | awk '{print $1 "-" $2}')${backlog:+-b$backlog}$cov_fp"
seen="/tmp/claude-herdr-org-sweep-$sid"
[ -f "$seen" ] && [ "$(cat "$seen" 2>/dev/null)" = "$fp" ] && exit 0
printf '%s' "$fp" > "$seen"

if grep -Eq ' dispatch( |$)' "$marker" 2>/dev/null; then
  premise="this session dispatched Herdr workers"
else
  premise="this session armed Herdr org state (lifecycle waits; no worker dispatch recorded)"
fi

relay_line=""
if [ -n "$backlog" ] && [ "$backlog" -gt 0 ] 2>/dev/null; then
  relay_line="RELAY BACKLOG: $backlog unconsumed relay message(s) queued for '$me' — relay_inbox(agent: $me), act, consume, and end the turn; arm coverage only if a lane is still in flight (the next line says when). "
fi
if [ "$covered" = "0" ] && [ "$in_flight" = "1" ]; then
  relay_line="${relay_line}NO AWAIT COVERAGE: a dispatched lane has sent no [DONE] doorbell yet and '$me' holds no live relay_await — arm ONE long relay_await(agent: $me, timeout_s: 1800) as the LAST call before idling (L6); with every lane done this line does not appear and an idle session arms nothing. "
fi

reason="ANTI-IDLE FINGERPRINT SWEEP ($premise; post-compaction: re-invoke your role skill FIRST). Run it against live reads, not memory, meaning board list + herdr agent list: (1) an idle/done/blocked worker with no verdict? read it (herdr agent read --source visible for the current frame, --source recent --lines N to reach back through scrollback; either way its board comments are what outlive the pane) and post the verdict on its lane todo NOW; (2) a live agent whose lane todo is verified or complete? unregister then reap it NOW (waker-ctl unregister --lane <lane>, L6, then L4) and settle lane tree + branch per merge state (L5); (3) a working agent with neither a waker registration (waker-ctl list) nor an armed herdr agent wait nor a written re-check plan? register or arm or write it (L6); (4) a blocking operator question still unposted? inbox pad plus one line under Questions; (5) anything you are about to assert that a board list / herdr agent list read would contradict? correct it (L15). Then stop."
# jq builds the payload so the reason is JSON-escaped rather than hand-quoted.
jq -n --arg r "${relay_line}${reason}" '{decision:"block", reason:$r}'
exit 0
