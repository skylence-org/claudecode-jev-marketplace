#!/bin/sh
# verify_clear_gate.sh: stub proof for the lifecycle-corroborated clear branch.
# Field bug (2026-08-01, loadavg ~20, lane donchian-port): the paste rendered
# SLOWER than verify_submitted's two 1s-spaced reads; both saw an empty
# composer, the outcome logged "delivered", the pending file was deleted, and
# the ring sat parked on the composer with nothing left watching it. A false
# "delivered" is strictly worse than a hold: a hold keeps the SENT-file
# reconciliation alive, "delivered" ends the story. Matrix:
#   A pre=idle,   clear+clear, post=idle    -> held:unverified:status=idle
#                                              (nothing observably happened)
#   B pre=idle,   clear+clear, post=working -> delivered (the prompt STARTED
#                                              the turn; clear is corroborated)
#   C pre=working, clear+clear             -> held:unverified:status=working
#                                              (a busy target proves delivery
#                                              only via the queued hint)
#   D pre=working, queued hint             -> delivered (unchanged fast path)
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "verify_clear_gate.sh: jq required, skipping"; exit 0; }

STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waker-clear-gate_stub.XXXXXX")
export HERDR_PLUGIN_CONFIG_DIR="$STUB_ROOT/cfg"
export ORG_WAKER_STUB_STATE="$STUB_ROOT/state"
FAKE="$STUB_ROOT/fake_herdr"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR" "$ORG_WAKER_STUB_STATE"

cat > "$FAKE" <<'FAKE'
#!/bin/sh
STATE="${ORG_WAKER_STUB_STATE:?}"
next() {
  kind=$1
  i_file="$STATE/${kind}_i"
  [ -f "$i_file" ] || echo 0 > "$i_file"
  i=$(cat "$i_file")
  f="$STATE/${kind}_$i"
  if [ ! -f "$f" ]; then
    echo "fake_herdr: no more $kind responses (i=$i)" >&2
    exit 1
  fi
  cat "$f"
  echo $((i + 1)) > "$i_file"
}
case "${1:-}" in
  agent)
    case "${2:-}" in
      get)
        if [ -f "$STATE/agent_status_0" ]; then
          status=$(next agent_status)
        else
          status=$(cat "$STATE/agent_status" 2>/dev/null || echo idle)
        fi
        pane=$(cat "$STATE/pane_id" 2>/dev/null || echo stub-pane)
        jq -cn --arg p "$pane" --arg s "$status" '{result:{agent:{pane_id:$p, agent_status:$s}}}'
        ;;
      read) next agent_read ;;
      prompt) printf '%s\n' "$*" >> "$STATE/prompts"; exit 0 ;;
      *) echo "fake_herdr: unhandled agent subcommand: $*" >&2; exit 1 ;;
    esac
    ;;
  pane)
    case "${2:-}" in
      read) next pane_read ;;
      run) printf '%s\n' "$*" >> "$STATE/pane_runs"; exit 0 ;;
      *) echo "fake_herdr: unhandled pane subcommand: $*" >&2; exit 1 ;;
    esac
    ;;
  notification) exit 0 ;;
  plugin) echo "${HERDR_PLUGIN_CONFIG_DIR:-/tmp/missing}" ;;
  *) echo "fake_herdr: unhandled: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$FAKE"
export HERDR_BIN_PATH="$FAKE"

. "$WAKER" list >/dev/null 2>&1

SENT="[RING g1] lane stub-lane -> done. board get stub-lane"
PC="$PROMPT_CHAR"
CLEAR_TAIL=$(printf 'scroll\n%s \n' "$PC")
QUEUED_TAIL=$(printf 'scroll\n%s %s\n' "$PC" "$QUEUED_HINT")

PEND="$HERDR_PLUGIN_CONFIG_DIR/pending"
RINGS="$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"

reset_state() {
  rm -rf "$ORG_WAKER_STUB_STATE"
  mkdir -p "$ORG_WAKER_STUB_STATE" "$HERDR_PLUGIN_CONFIG_DIR/log" \
    "$HERDR_PLUGIN_CONFIG_DIR/pending" "$HERDR_PLUGIN_CONFIG_DIR/registry" \
    "$HERDR_PLUGIN_CONFIG_DIR/state" "$HERDR_PLUGIN_CONFIG_DIR/spool"
  rm -f "$PEND"/*
  : > "$RINGS"
  echo stub-pane > "$ORG_WAKER_STUB_STATE/pane_id"
  : > "$ORG_WAKER_STUB_STATE/prompts"
  : > "$ORG_WAKER_STUB_STATE/pane_runs"
}

write_seq() {
  kind=$1; shift
  n=0
  for content in "$@"; do
    printf '%s\n' "$content" > "$ORG_WAKER_STUB_STATE/${kind}_$n"
    n=$((n + 1))
  done
}

failed=0
last_outcome() { tail -n 1 "$RINGS" 2>/dev/null | jq -r '.outcome // empty' 2>/dev/null || true; }
prompts_count() { wc -l < "$ORG_WAKER_STUB_STATE/prompts" | tr -d ' '; }

check() {
  # check LABEL WANT_OUTCOME WANT_PENDING(yes|no)
  got=$(last_outcome)
  if [ "$got" = "$2" ]; then
    echo "ok $1: outcome=$got"
  else
    echo "FAIL $1: outcome=$got want $2"
    failed=1
  fi
  if [ "$(prompts_count)" = "1" ]; then
    echo "ok $1: exactly 1 prompt"
  else
    echo "FAIL $1: prompts=$(prompts_count) want 1"
    failed=1
  fi
  has=no; ls "$PEND"/*.msg >/dev/null 2>&1 && has=yes
  if [ "$has" = "$3" ]; then
    echo "ok $1: pending=$has"
  else
    echo "FAIL $1: pending=$has want $3"
    failed=1
  fi
}

# --- A: idle target, clear+clear, still idle -> nothing observably happened
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"          # pre-send composer_clear
write_seq pane_read "$CLEAR_TAIL" "$CLEAR_TAIL"           # verify: clear, clear
write_seq agent_status idle idle idle                     # pre-send, pane resolve, post-verify
ring_or_hold "stub-lane" "1" "orch" "$SENT"
check "A-idle-unmoved" "held:unverified:status=idle" "yes"
marker=$(sed -n '3p' "$PEND"/*.msg 2>/dev/null | head -1)
if [ "$marker" = "sent" ]; then
  echo "ok A-idle-unmoved: held file carries sent marker (drain may recover, never re-paste)"
else
  echo "FAIL A-idle-unmoved: marker='$marker' want sent"
  failed=1
fi

# --- B: idle target, clear+clear, now working -> the prompt started the turn
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq pane_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq agent_status idle idle working
ring_or_hold "stub-lane" "1" "orch" "$SENT"
check "B-idle-took-it" "delivered" "no"

# --- C: working target, clear+clear, no queued hint -> paste not seen, hold
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq pane_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq agent_status working working working
ring_or_hold "stub-lane" "1" "orch" "$SENT"
check "C-working-no-hint" "held:unverified:status=working" "yes"

# --- D: working target, queued hint -> delivered on one read (fast path)
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq pane_read "$QUEUED_TAIL"
write_seq agent_status working working
ring_or_hold "stub-lane" "1" "orch" "$SENT"
check "D-working-queued" "delivered" "no"

if [ "$failed" -eq 0 ]; then
  echo "verify_clear_gate.sh: OK"
  rm -rf "$STUB_ROOT"
  exit 0
else
  echo "verify_clear_gate.sh: FAILED (state under $STUB_ROOT)"
  exit 1
fi
