#!/bin/sh
# sent_no_resend.sh: stub proof for the sent-marker duplicate fix.
# Field evidence (rings.jsonl 2026-07-30, lane i331-runtime-facts): ONE done
# event and ONE held:undelivered entry produced 3+ actual deliveries, because
# Claude Code queues every mid-turn `agent prompt` paste while the composer
# verification stays inconclusive, and every drain retry re-pasted the prompt.
# The fix: a pending wake whose paste already reached the target carries a
# `sent` marker (line 3), and drain never calls the prompt path for it again.
# Scenarios:
#   A ring path, send accepted, verify foreign  -> held:unverified, marker=sent, 1 prompt
#   B drain while composer still foreign        -> file kept, STILL 1 prompt (old code: 2)
#   C drain once composer is clear              -> drain-delivered:inferred, file gone, STILL 1 prompt
# Uses HERDR_BIN_PATH fake herdr with canned tails; no live pane.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "sent_no_resend.sh: jq required, skipping"; exit 0; }

STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waker-sent-no-resend_stub.XXXXXX")
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
        jq -cn --arg p "$pane" --arg s "$status" \
          '{result:{agent:{pane_id:$p, agent_status:$s}}}'
        ;;
      read)
        next agent_read
        ;;
      prompt)
        printf '%s\n' "$*" >> "$STATE/prompts"
        exit 0
        ;;
      *)
        echo "fake_herdr: unhandled agent subcommand: $*" >&2
        exit 1
        ;;
    esac
    ;;
  pane)
    case "${2:-}" in
      read)
        next pane_read
        ;;
      run)
        printf '%s\n' "$*" >> "$STATE/pane_runs"
        exit 0
        ;;
      *)
        echo "fake_herdr: unhandled pane subcommand: $*" >&2
        exit 1
        ;;
    esac
    ;;
  notification)
    exit 0
    ;;
  plugin)
    echo "${HERDR_PLUGIN_CONFIG_DIR:-/tmp/missing}"
    ;;
  *)
    echo "fake_herdr: unhandled: $*" >&2
    exit 1
    ;;
esac
FAKE
chmod +x "$FAKE"
export HERDR_BIN_PATH="$FAKE"

. "$WAKER" list >/dev/null 2>&1

SENT="[RING g1] lane stub-lane -> done. board get stub-lane"
FOREIGN="[RING g1] lane some-other-lane -> done. board get some-other-lane"
PC="$PROMPT_CHAR"
CLEAR_TAIL=$(printf 'scroll\n%s \n' "$PC")
FOREIGN_TAIL=$(printf 'scroll\n%s %s\n' "$PC" "$FOREIGN")

mkdir -p "$HERDR_PLUGIN_CONFIG_DIR/log" "$HERDR_PLUGIN_CONFIG_DIR/pending" \
  "$HERDR_PLUGIN_CONFIG_DIR/registry" "$HERDR_PLUGIN_CONFIG_DIR/state" \
  "$HERDR_PLUGIN_CONFIG_DIR/spool"
: > "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"
echo stub-pane > "$ORG_WAKER_STUB_STATE/pane_id"
echo working > "$ORG_WAKER_STUB_STATE/agent_status"
: > "$ORG_WAKER_STUB_STATE/prompts"
: > "$ORG_WAKER_STUB_STATE/pane_runs"

seed_reads() {
  # seed_reads KIND tail0 tail1 ...  (also resets the index)
  kind=$1
  shift
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
  tail -n 1 "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl" 2>/dev/null \
    | jq -r '.outcome // empty' 2>/dev/null || true
}

# --- A: ring path, prompt accepted, verify sees foreign -> held sent -------
seed_reads agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"     # composer_clear pre-send
seed_reads pane_read "$FOREIGN_TAIL"                   # verify: foreign, 1 read
ring_or_hold "stub-lane" "1" "orch" "$SENT"
if [ "$(last_outcome)" = "held:unverified:status=unknown" ]; then
  echo "ok A: outcome held:unverified:status=unknown"
else
  echo "FAIL A: outcome=$(last_outcome) want held:unverified:status=unknown"
  failed=1
fi
if [ "$(prompts_count)" = "1" ]; then
  echo "ok A: exactly 1 agent prompt"
else
  echo "FAIL A: prompts=$(prompts_count) want 1"
  failed=1
fi
msg=$(ls "$HERDR_PLUGIN_CONFIG_DIR/pending"/*.msg 2>/dev/null | head -n 1)
if [ -n "$msg" ] && [ "$(sed -n '3p' "$msg")" = "sent" ]; then
  echo "ok A: pending file carries sent marker"
else
  echo "FAIL A: pending file missing or marker wrong ($msg)"
  failed=1
fi

# --- B: drain while composer still foreign -> kept, no second prompt -------
# Old code called deliver() here and pasted a second copy; prompts must stay 1.
seed_reads agent_read "$FOREIGN_TAIL" "$FOREIGN_TAIL"  # composer_clear in drain: busy
seed_reads pane_read "$FOREIGN_TAIL" "$FOREIGN_TAIL"   # recover_own_text + queued check
do_drain
if [ "$(prompts_count)" = "1" ]; then
  echo "ok B: STILL exactly 1 agent prompt after drain retry (no duplicate)"
else
  echo "FAIL B: prompts=$(prompts_count) want 1 (drain re-pasted a sent wake)"
  failed=1
fi
if ls "$HERDR_PLUGIN_CONFIG_DIR/pending"/*.msg >/dev/null 2>&1; then
  echo "ok B: pending file kept while target busy"
else
  echo "FAIL B: pending file vanished without delivery evidence"
  failed=1
fi

# --- C: drain once composer is clear -> inferred delivered, file gone ------
seed_reads agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"      # composer_clear in drain: clear
seed_reads pane_read                                    # no pane reads needed
do_drain
if [ "$(last_outcome)" = "drain-delivered:inferred" ]; then
  echo "ok C: outcome drain-delivered:inferred"
else
  echo "FAIL C: outcome=$(last_outcome) want drain-delivered:inferred"
  failed=1
fi
if ls "$HERDR_PLUGIN_CONFIG_DIR/pending"/*.msg >/dev/null 2>&1 || \
   ls "$HERDR_PLUGIN_CONFIG_DIR/pending"/*.claim >/dev/null 2>&1; then
  echo "FAIL C: pending file survived inferred delivery"
  failed=1
else
  echo "ok C: pending consumed"
fi
if [ "$(prompts_count)" = "1" ]; then
  echo "ok C: total agent prompts across all scenarios: 1"
else
  echo "FAIL C: prompts=$(prompts_count) want 1"
  failed=1
fi

echo "--- rings.jsonl:"
cat "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl" 2>/dev/null || true

if [ "$failed" -eq 0 ]; then
  echo "sent_no_resend.sh: OK"
  exit 0
else
  echo "sent_no_resend.sh: FAILED (state under $STUB_ROOT)"
  exit 1
fi
