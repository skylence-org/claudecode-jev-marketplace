#!/bin/sh
# drain_sent_preserve.sh: stub proof that drain's UNSENT path cannot re-arm
# the duplicate machine. Old code called deliver() (send + verify fused): a
# send that verified inconclusive restored the file WITHOUT the sent marker,
# and the next pane-focus drain pasted a second copy — N identical wakes
# queueing mid-turn and firing back-to-back (the class the operator reported
# as "idle wake repeating nonstop", rings 2026-07-28 lane get-json: two
# drain-delivered for one lane+gen minutes apart). Scenarios:
#   A drain unsent, composer clear, verify foreign -> file REWRITTEN as sent,
#                                                     held:unverified, 1 prompt
#   B drain again, composer clear                  -> drain-delivered:inferred,
#                                                     file gone, STILL 1 prompt
#                                                     (old code: 2 prompts)
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "drain_sent_preserve.sh: jq required, skipping"; exit 0; }

STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waker-drain-preserve_stub.XXXXXX")
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
        status=$(cat "$STATE/agent_status" 2>/dev/null || echo idle)
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

WAKE="[RING g1] lane stub-lane -> done. board get stub-lane"
FOREIGN="some other text entirely"
PC="$PROMPT_CHAR"
CLEAR_TAIL=$(printf 'scroll\n%s \n' "$PC")
FOREIGN_TAIL=$(printf 'scroll\n%s %s\n' "$PC" "$FOREIGN")

PEND="$HERDR_PLUGIN_CONFIG_DIR/pending"
RINGS="$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"
mkdir -p "$PEND" "$HERDR_PLUGIN_CONFIG_DIR/log" "$HERDR_PLUGIN_CONFIG_DIR/registry" \
  "$HERDR_PLUGIN_CONFIG_DIR/state" "$HERDR_PLUGIN_CONFIG_DIR/spool"
: > "$RINGS"
echo stub-pane > "$ORG_WAKER_STUB_STATE/pane_id"
echo idle > "$ORG_WAKER_STUB_STATE/agent_status"
: > "$ORG_WAKER_STUB_STATE/prompts"
: > "$ORG_WAKER_STUB_STATE/pane_runs"

seed_reads() {
  kind=$1; shift
  echo 0 > "$ORG_WAKER_STUB_STATE/${kind}_i"
  n=0
  for content in "$@"; do
    printf '%s\n' "$content" > "$ORG_WAKER_STUB_STATE/${kind}_$n"
    n=$((n + 1))
  done
}

failed=0
prompts_count() { wc -l < "$ORG_WAKER_STUB_STATE/prompts" | tr -d ' '; }
last_outcome() {
  tail -n 1 "$RINGS" 2>/dev/null | jq -r '.outcome // empty' 2>/dev/null || true
}

# Unsent pending file (2 lines: pre-marker format).
printf '%s\n%s\n' "orch" "$WAKE" > "$PEND/1000-stub-lane-g1.msg"

# --- A: drain, composer clear, send ok, verify foreign ---------------------
seed_reads agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"   # composer_clear pre-send
seed_reads pane_read "$FOREIGN_TAIL"                 # verify: foreign
do_drain
if [ "$(prompts_count)" = "1" ]; then
  echo "ok A: exactly 1 prompt"
else
  echo "FAIL A: prompts=$(prompts_count) want 1"
  failed=1
fi
msg=$(ls "$PEND"/*.msg 2>/dev/null | head -n 1)
if [ -n "$msg" ] && [ "$(sed -n '3p' "$msg")" = "sent" ]; then
  echo "ok A: pending file rewritten with sent marker"
else
  echo "FAIL A: file missing or marker wrong ($msg) — drain restored UNSENT"
  failed=1
fi
if [ "$(last_outcome)" = "held:unverified:status=unknown" ]; then
  echo "ok A: outcome held:unverified:status=unknown"
else
  echo "FAIL A: outcome=$(last_outcome) want held:unverified:status=unknown"
  failed=1
fi

# --- B: drain again with clear composer -> inferred, no second paste -------
seed_reads agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
seed_reads pane_read
do_drain
if [ "$(prompts_count)" = "1" ]; then
  echo "ok B: STILL exactly 1 prompt (old code pasted a duplicate here)"
else
  echo "FAIL B: prompts=$(prompts_count) want 1 (duplicate machine re-armed)"
  failed=1
fi
if [ "$(last_outcome)" = "drain-delivered:inferred" ]; then
  echo "ok B: outcome drain-delivered:inferred"
else
  echo "FAIL B: outcome=$(last_outcome) want drain-delivered:inferred"
  failed=1
fi
if ls "$PEND"/*.msg >/dev/null 2>&1 || ls "$PEND"/*.claim >/dev/null 2>&1; then
  echo "FAIL B: pending survived inferred delivery"
  failed=1
else
  echo "ok B: pending consumed"
fi

if [ "$failed" -eq 0 ]; then
  echo "drain_sent_preserve.sh: OK"
  exit 0
else
  echo "drain_sent_preserve.sh: FAILED (state under $STUB_ROOT)"
  exit 1
fi
