#!/bin/sh
# doorbell_suppress.sh: 0.7.2 settle-ring suppression. A consumed doorbell
# ack leaves state/doorbell--<lane>; the next idle|done settle for that lane
# must log suppressed:doorbell-acked, consume the marker, and ring nothing.
# Without the marker the same transition must reach the ring machinery (the
# herdr stub refuses reads, so it lands as a held wake). register clears any
# stale marker so a new generation starts clean. Crash/blocked paths never
# consult the marker (not asserted here; they share no code with the branch).
set -eu

DIR=$(cd "$(dirname "$0")/.." && pwd)
WAKER="$DIR/waker"

CFG=$(mktemp -d "${TMPDIR:-/tmp}/org-waker-test.XXXXXX")
STUB=$(mktemp -d "${TMPDIR:-/tmp}/org-waker-stub.XXXXXX")
trap 'rm -rf "$CFG" "$STUB"' EXIT
export HERDR_PLUGIN_CONFIG_DIR="$CFG"
unset HERDR_ENV HERDR_SOCKET_PATH 2>/dev/null || true

# herdr stub: log calls, refuse reads (forces the hold path when a ring is
# attempted), accept everything else.
cat > "$STUB/herdr" <<'EOF'
#!/bin/sh
echo "$*" >> "${STUB_LOG:?}"
case "$1 $2" in
  "agent read"*) exit 1 ;;
esac
exit 0
EOF
chmod +x "$STUB/herdr"
export HERDR_BIN_PATH="$STUB/herdr"
export STUB_LOG="$STUB/calls.log"
: > "$STUB_LOG"

failed=0
ok()   { echo "ok $1"; }
bad()  { echo "FAIL $1"; failed=1; }

fire() {
  # fire STATUS
  HERDR_PLUGIN_EVENT="pane_agent_status_changed" \
  HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"pane_id\":\"w1:p9\",\"agent_status\":\"$1\",\"agent\":\"claude\"}}" \
  sh "$WAKER" on-event >/dev/null 2>&1 || true
}

# 1. register clears a stale marker (new generation starts clean)
mkdir -p "$CFG/state"
touch "$CFG/state/doorbell--t-lane"
sh "$WAKER" register --pane w1:p9 --lane t-lane --todo t-lane --target orch >/dev/null
if [ ! -e "$CFG/state/doorbell--t-lane" ]; then ok register-clears-marker; else bad register-clears-marker; fi

# 2. marker present: settle is suppressed, marker consumed, no herdr call,
#    nothing held
fire working
touch "$CFG/state/doorbell--t-lane"
: > "$STUB_LOG"
fire done
if grep -q 'suppressed:doorbell-acked' "$CFG/log/rings.jsonl" 2>/dev/null; then ok suppressed-logged; else bad suppressed-logged; fi
if [ ! -e "$CFG/state/doorbell--t-lane" ]; then ok marker-consumed; else bad marker-consumed; fi
if [ ! -s "$STUB_LOG" ]; then ok no-herdr-call; else bad no-herdr-call; fi
if [ -z "$(ls "$CFG/pending" 2>/dev/null)" ]; then ok nothing-held; else bad nothing-held; fi

# 3. no marker: the same transition reaches the ring machinery (held wake,
#    since the stub refuses composer reads)
fire working
: > "$STUB_LOG"
fire idle
if grep -q 'held:' "$CFG/log/rings.jsonl" 2>/dev/null; then ok unmarked-still-rings; else bad unmarked-still-rings; fi
if [ -n "$(ls "$CFG/pending" 2>/dev/null)" ]; then ok held-wake-present; else bad held-wake-present; fi

# 4. stale marker (>1h) is discarded and the settle still rings
sh "$WAKER" register --pane w1:p9 --lane t-lane --todo t-lane --target orch >/dev/null
fire working
touch "$CFG/state/doorbell--t-lane"
touch -t 202601010000 "$CFG/state/doorbell--t-lane" 2>/dev/null || true
count_before=$(grep -c 'held:' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
fire done
count_after=$(grep -c 'held:' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
if [ "$count_after" -gt "$count_before" ]; then ok stale-marker-rings; else bad stale-marker-rings; fi
if [ ! -e "$CFG/state/doorbell--t-lane" ]; then ok stale-marker-discarded; else bad stale-marker-discarded; fi


# 5. unconsumed canonical-text ack (worker hand-rolled the prompt because the
#    doorbell script was unreachable): suppressed, ack consumed (0.7.3 leg)
sh "$WAKER" register --pane w1:p9 --lane t-lane --todo t-lane --target orch >/dev/null
fire working
if command -v shasum >/dev/null 2>&1; then
  SHA=$(printf '%s' "[DOORBELL] lane t-lane [DONE], verdict needed. board get t-lane" | shasum -a 256 | cut -c1-32)
else
  SHA=$(printf '%s' "[DOORBELL] lane t-lane [DONE], verdict needed. board get t-lane" | sha256sum | cut -c1-32)
fi
mkdir -p "$CFG/acks"
touch "$CFG/acks/$SHA.ack"
sup_before=$(grep -c 'suppressed:doorbell-acked' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
fire done
sup_after=$(grep -c 'suppressed:doorbell-acked' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
if [ "$sup_after" -gt "$sup_before" ]; then ok ack-file-suppresses; else bad ack-file-suppresses; fi
if [ ! -e "$CFG/acks/$SHA.ack" ]; then ok ack-consumed; else bad ack-consumed; fi


# 6. 0.7.4 name/slug variants: agent name differs from todo slug; marker was
#    written under the TODO slug (doorbell script arg) while registration
#    carries the agent name. Both must suppress.
sh "$WAKER" register --pane w2:p3 --lane short-name --todo short-name-full-slug --target orch >/dev/null
fire2() {
  HERDR_PLUGIN_EVENT="pane_agent_status_changed" \
  HERDR_PLUGIN_EVENT_JSON="{\"data\":{\"pane_id\":\"w2:p3\",\"agent_status\":\"$1\",\"agent\":\"claude\"}}" \
  sh "$WAKER" on-event >/dev/null 2>&1 || true
}
fire2 working
touch "$CFG/state/doorbell--short-name-full-slug"
sup_b=$(grep -c 'suppressed:doorbell-acked' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
fire2 done
sup_a=$(grep -c 'suppressed:doorbell-acked' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
if [ "$sup_a" -gt "$sup_b" ]; then ok todo-slug-marker-suppresses; else bad todo-slug-marker-suppresses; fi
# ack text carrying the TODO slug in the lane position must also match
fire2 working
if command -v shasum >/dev/null 2>&1; then
  SHA2=$(printf '%s' "[DOORBELL] lane short-name-full-slug [DONE], verdict needed. board get short-name-full-slug" | shasum -a 256 | cut -c1-32)
else
  SHA2=$(printf '%s' "[DOORBELL] lane short-name-full-slug [DONE], verdict needed. board get short-name-full-slug" | sha256sum | cut -c1-32)
fi
touch "$CFG/acks/$SHA2.ack"
sup_b=$(grep -c 'suppressed:doorbell-acked' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
fire2 idle
sup_a=$(grep -c 'suppressed:doorbell-acked' "$CFG/log/rings.jsonl" 2>/dev/null || echo 0)
if [ "$sup_a" -gt "$sup_b" ]; then ok todo-slug-ack-suppresses; else bad todo-slug-ack-suppresses; fi

[ "$failed" -eq 0 ] && echo "doorbell_suppress: PASS" || { echo "doorbell_suppress: FAIL"; exit 1; }
