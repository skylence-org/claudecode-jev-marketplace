#!/bin/sh
# ack_path.sh: stub proof for the runtime-ack channel (0.7.0). The receiver
# hook writes acks/<sha>.ack the moment a ring/doorbell prompt becomes a
# turn; the sender consumes it and needs ZERO composer reads on that path.
# Scenarios:
#   A ring path, ack present after send  -> delivered:acked, no pane reads
#                                           consumed (any read would crash
#                                           the stub: none are seeded)
#   B SENT drain file, late ack present  -> drain-delivered:acked, no reads
#   C no ack                             -> falls through to the composer
#                                           verify (idle->working matrix row)
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "ack_path.sh: jq required, skipping"; exit 0; }

STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waker-ack_stub.XXXXXX")
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

PEND="$HERDR_PLUGIN_CONFIG_DIR/pending"
RINGS="$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"

reset_state() {
  rm -rf "$ORG_WAKER_STUB_STATE"
  mkdir -p "$ORG_WAKER_STUB_STATE" "$HERDR_PLUGIN_CONFIG_DIR/log" \
    "$HERDR_PLUGIN_CONFIG_DIR/pending" "$HERDR_PLUGIN_CONFIG_DIR/registry" \
    "$HERDR_PLUGIN_CONFIG_DIR/state" "$HERDR_PLUGIN_CONFIG_DIR/spool" \
    "$HERDR_PLUGIN_CONFIG_DIR/acks"
  rm -f "$PEND"/* "$HERDR_PLUGIN_CONFIG_DIR/acks"/*
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

plant_ack() { : > "$HERDR_PLUGIN_CONFIG_DIR/acks/$(ack_sha "$1").ack"; }

failed=0
last_outcome() { tail -n 1 "$RINGS" 2>/dev/null | jq -r '.outcome // empty' 2>/dev/null || true; }

# --- A: ring path, ack arrives -> delivered:acked, zero composer forensics -
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"   # pre-send composer_clear only
write_seq agent_status idle                        # send_prompt gate read
plant_ack "$SENT"
ring_or_hold "stub-lane" "1" "orch" "$SENT"
if [ "$(last_outcome)" = "delivered:acked" ]; then
  echo "ok A: outcome delivered:acked"
else
  echo "FAIL A: outcome=$(last_outcome) want delivered:acked"
  failed=1
fi
if ls "$HERDR_PLUGIN_CONFIG_DIR/acks"/*.ack >/dev/null 2>&1; then
  echo "FAIL A: ack file not consumed"
  failed=1
else
  echo "ok A: ack consumed"
fi
if ls "$PEND"/*.msg >/dev/null 2>&1; then
  echo "FAIL A: wake was held despite ack"
  failed=1
else
  echo "ok A: nothing pending"
fi

# --- B: SENT drain file, late ack -> drain-delivered:acked, zero reads -----
reset_state
printf 'orch\n%s\n%s\n' "$SENT" "sent" > "$PEND/1000-stub-lane-g1.msg"
plant_ack "$SENT"
do_drain
if [ "$(last_outcome)" = "drain-delivered:acked" ]; then
  echo "ok B: outcome drain-delivered:acked"
else
  echo "FAIL B: outcome=$(last_outcome) want drain-delivered:acked"
  failed=1
fi
if ls "$PEND"/*.msg "$PEND"/*.claim >/dev/null 2>&1; then
  echo "FAIL B: pending survived acked delivery"
  failed=1
else
  echo "ok B: pending consumed"
fi

# --- C: no ack -> composer verify fallback (idle->working, delivered) ------
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq pane_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq agent_status idle idle working
ring_or_hold "stub-lane" "1" "orch" "$SENT"
if [ "$(last_outcome)" = "delivered" ]; then
  echo "ok C: no ack falls through to composer verify (delivered)"
else
  echo "FAIL C: outcome=$(last_outcome) want delivered"
  failed=1
fi

if [ "$failed" -eq 0 ]; then
  echo "ack_path.sh: OK"
  rm -rf "$STUB_ROOT"
  exit 0
else
  echo "ack_path.sh: FAILED (state under $STUB_ROOT)"
  exit 1
fi
