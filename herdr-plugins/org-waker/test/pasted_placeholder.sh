#!/bin/sh
# pasted_placeholder.sh: stub proof for the [Pasted text #N] placeholder class.
# Field evidence (2026-08-01, three orchestrator panes at once): Claude Code
# renders any paste past its length threshold as "[Pasted text #N]", so a
# long wake could NEVER match `parked` by exact text, classified foreign,
# held forever, and the operator pressed Enter by hand. Scenarios:
#   A ring path, verify sees placeholder    -> Enter-recovered, delivered,
#                                              1 prompt, 1 empty submit
#   B drain of a SENT file, placeholder     -> Enter-recovered, delivered,
#                                              NO new prompt
#   C pre-send hold path, placeholder       -> STILL held (could be the
#                                              operator's own draft), no
#                                              empty submit, no prompt
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "pasted_placeholder.sh: jq required, skipping"; exit 0; }

STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waker-pasted_stub.XXXXXX")
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
PC="$PROMPT_CHAR"
CLEAR_TAIL=$(printf 'scroll\n%s \n' "$PC")
PASTED_TAIL=$(printf 'scroll\n%s [Pasted text #1]\n' "$PC")

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
runs_count() { wc -l < "$ORG_WAKER_STUB_STATE/pane_runs" | tr -d ' '; }
last_outcome() {
  tail -n 1 "$RINGS" 2>/dev/null | jq -r '.outcome // empty' 2>/dev/null || true
}

# --- A: ring path, verify sees the placeholder -> Enter-recover, delivered -
seed_reads agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"                 # pre-send composer_clear
seed_reads pane_read "$PASTED_TAIL" "$PASTED_TAIL" "$CLEAR_TAIL"  # verify + recover gate + post-Enter
ring_or_hold "stub-lane" "1" "orch" "$WAKE"
if [ "$(last_outcome)" = "delivered" ]; then
  echo "ok A: outcome delivered"
else
  echo "FAIL A: outcome=$(last_outcome) want delivered"
  failed=1
fi
[ "$(prompts_count)" = "1" ] && echo "ok A: 1 prompt" || { echo "FAIL A: prompts=$(prompts_count) want 1"; failed=1; }
[ "$(runs_count)" = "1" ] && echo "ok A: 1 empty-submit recovery" || { echo "FAIL A: pane_runs=$(runs_count) want 1"; failed=1; }
if ls "$PEND"/*.msg >/dev/null 2>&1; then
  echo "FAIL A: wake was held despite placeholder recovery"
  failed=1
else
  echo "ok A: nothing pending"
fi

# --- B: drain of a SENT file, placeholder on the composer ------------------
printf '%s\n%s\n%s\n' "orch" "$WAKE" "sent" > "$PEND/1000-stub-lane-g1.msg"
seed_reads agent_read "$PASTED_TAIL" "$PASTED_TAIL"               # composer_clear: busy
seed_reads pane_read "$PASTED_TAIL" "$PASTED_TAIL" "$PASTED_TAIL" "$CLEAR_TAIL"
# reads: recover_own_text (strict parked: fails), cls check, recover gate, post-Enter
do_drain
if [ "$(last_outcome)" = "drain-delivered" ]; then
  echo "ok B: outcome drain-delivered"
else
  echo "FAIL B: outcome=$(last_outcome) want drain-delivered"
  failed=1
fi
[ "$(prompts_count)" = "1" ] && echo "ok B: still 1 prompt (no re-paste)" || { echo "FAIL B: prompts=$(prompts_count) want 1"; failed=1; }
[ "$(runs_count)" = "2" ] && echo "ok B: recovered via empty submit" || { echo "FAIL B: pane_runs=$(runs_count) want 2"; failed=1; }
if ls "$PEND"/*.msg >/dev/null 2>&1 || ls "$PEND"/*.claim >/dev/null 2>&1; then
  echo "FAIL B: pending survived recovery"
  failed=1
else
  echo "ok B: pending consumed"
fi

# --- C: pre-send hold path stays strict on placeholders --------------------
seed_reads agent_read "$PASTED_TAIL" "$PASTED_TAIL"   # composer_clear: busy
seed_reads pane_read "$PASTED_TAIL"                    # recover_own_text strict gate
ring_or_hold "stub-lane" "1" "orch" "$WAKE"
if [ "$(last_outcome)" = "held:composer:status=unknown" ]; then
  echo "ok C: pre-send placeholder still HELD (operator draft protected)"
else
  echo "FAIL C: outcome=$(last_outcome) want held:composer:status=unknown"
  failed=1
fi
[ "$(prompts_count)" = "1" ] && echo "ok C: no new prompt" || { echo "FAIL C: prompts=$(prompts_count) want 1"; failed=1; }
[ "$(runs_count)" = "2" ] && echo "ok C: no empty submit into a possible operator draft" || { echo "FAIL C: pane_runs=$(runs_count) want 2"; failed=1; }

if [ "$failed" -eq 0 ]; then
  echo "pasted_placeholder.sh: OK"
  exit 0
else
  echo "pasted_placeholder.sh: FAILED (state under $STUB_ROOT)"
  exit 1
fi
