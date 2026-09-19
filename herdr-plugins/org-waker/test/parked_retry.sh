#!/bin/sh
# parked_retry.sh: stub proof for org-waker parked-recovery hardening.
# C1 settle-before-recheck, C2 one empty-submit retry, C3 own-text recovery
# at delivery; F1 foreign-after-settle holds; F2 pre-Enter parked reconfirm.
# Uses HERDR_BIN_PATH → fake herdr with canned tails; no live pane.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "parked_retry.sh: jq required, skipping"; exit 0; }

STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waker-parked-retry_stub.XXXXXX")
export HERDR_PLUGIN_CONFIG_DIR="$STUB_ROOT/cfg"
export ORG_WAKER_STUB_STATE="$STUB_ROOT/state"
FAKE="$STUB_ROOT/fake_herdr"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR" "$ORG_WAKER_STUB_STATE"

# Fake herdr: sequences agent/pane reads from numbered files in state dir.
# agent get returns a fixed pane + status. pane run appends to pane_runs.
# agent prompt appends to prompts (must stay empty on C3 own-text recovery).
cat > "$FAKE" <<'FAKE'
#!/bin/sh
STATE="${ORG_WAKER_STUB_STATE:?}"
next() {
  # next KIND — print next canned response for KIND (agent_read|pane_read)
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
        # JSON shape matches real `herdr agent get` (pane_id + agent_status).
        # Sequenced statuses (agent_status_0, _1, ...) let a scenario model a
        # lifecycle transition (idle -> working when a prompt starts a turn);
        # absent a sequence, the static agent_status file is the answer.
        if [ -f "$STATE/agent_status_0" ]; then
          status=$(next agent_status)
        else
          status=$(cat "$STATE/agent_status" 2>/dev/null || echo idle)
        fi
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
    # config-dir fallback if HERDR_PLUGIN_CONFIG_DIR unset
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

# Source real waker (list is side-effect-free once CFG is set).
. "$WAKER" list >/dev/null 2>&1

SENT="[RING g1] lane stub-lane -> idle. board get stub-lane"
FOREIGN="operator was typing something else"
PC="$PROMPT_CHAR"
PARKED_TAIL=$(printf 'scroll\n%s %s\n' "$PC" "$SENT")
CLEAR_TAIL=$(printf 'scroll\n%s \n' "$PC")
FOREIGN_TAIL=$(printf 'scroll\n%s %s\n' "$PC" "$FOREIGN")

reset_state() {
  rm -rf "$ORG_WAKER_STUB_STATE"
  mkdir -p "$ORG_WAKER_STUB_STATE" "$HERDR_PLUGIN_CONFIG_DIR/log" \
    "$HERDR_PLUGIN_CONFIG_DIR/pending" "$HERDR_PLUGIN_CONFIG_DIR/registry" \
    "$HERDR_PLUGIN_CONFIG_DIR/state" "$HERDR_PLUGIN_CONFIG_DIR/spool"
  # Keep rings.jsonl across scenarios so the final file is the full audit trail.
  # Pending files from prior holds would confuse later cases — clear them.
  rm -f "$HERDR_PLUGIN_CONFIG_DIR/pending"/*
  [ -f "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl" ] || : > "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"
  echo stub-pane > "$ORG_WAKER_STUB_STATE/pane_id"
  echo idle > "$ORG_WAKER_STUB_STATE/agent_status"
  : > "$ORG_WAKER_STUB_STATE/pane_runs"
  : > "$ORG_WAKER_STUB_STATE/prompts"
  echo 0 > "$ORG_WAKER_STUB_STATE/agent_read_i"
  echo 0 > "$ORG_WAKER_STUB_STATE/pane_read_i"
}

# Write sequential canned tails: write_seq KIND file0 file1 ...
write_seq() {
  kind=$1
  shift
  n=0
  for content in "$@"; do
    printf '%s\n' "$content" > "$ORG_WAKER_STUB_STATE/${kind}_$n"
    n=$((n + 1))
  done
}

failed=0
outcome_lines=""

record() {
  # record LABEL WANT_OUTCOME
  last=$(tail -n 1 "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl" 2>/dev/null || true)
  got=$(printf '%s' "$last" | jq -r '.outcome // empty' 2>/dev/null || true)
  line="$1 outcome=$got"
  outcome_lines="$outcome_lines$line
"
  if [ "$got" != "$2" ]; then
    echo "FAIL $1: rings outcome='$got' want '$2' last=$last"
    failed=1
  else
    echo "ok $1: $line"
  fi
}

# --- (1) parked then cleared after first empty submit → delivered ----------
reset_state
# composer_clear: two empty agent reads
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
# deliver → verify: settle + pane parked; recover: pre-Enter parked,
# empty submit + settle + pane clear
write_seq pane_read "$PARKED_TAIL" "$PARKED_TAIL" "$CLEAR_TAIL"
ring_or_hold "stub-lane" "1" "orch" "$SENT"
record "parked-then-clear" "delivered"
runs=$(wc -l < "$ORG_WAKER_STUB_STATE/pane_runs" | tr -d ' ')
if [ "$runs" -lt 1 ]; then
  echo "FAIL parked-then-clear: expected >=1 pane run, got $runs"
  failed=1
fi

# --- (2) parked through both empty submits → held:undelivered -------------
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
# verify parked; try0 pre+post parked; try1 pre+post parked (5 reads, 2 runs)
write_seq pane_read "$PARKED_TAIL" "$PARKED_TAIL" "$PARKED_TAIL" "$PARKED_TAIL" "$PARKED_TAIL"
ring_or_hold "stub-lane" "1" "orch" "$SENT"
record "parked-both-submits" "held:unverified:status=idle"
runs=$(wc -l < "$ORG_WAKER_STUB_STATE/pane_runs" | tr -d ' ')
if [ "$runs" -ne 2 ]; then
  echo "FAIL parked-both-submits: expected 2 pane runs, got $runs"
  failed=1
fi

# --- (3) own-text already on composer at delivery → delivered, no prompt --
reset_state
# composer_clear sees stable parked own-text (not clear)
write_seq agent_read "$PARKED_TAIL" "$PARKED_TAIL"
# recover_own_text: pane read parked; recover: pre-Enter parked, Enter, clear
write_seq pane_read "$PARKED_TAIL" "$PARKED_TAIL" "$CLEAR_TAIL"
ring_or_hold "stub-lane" "1" "orch" "$SENT"
record "own-text-recovery" "delivered"
if [ -s "$ORG_WAKER_STUB_STATE/prompts" ]; then
  echo "FAIL own-text-recovery: agent prompt was called (would duplicate):"
  cat "$ORG_WAKER_STUB_STATE/prompts"
  failed=1
else
  echo "ok own-text-recovery: no agent prompt (no duplicate)"
fi
runs=$(wc -l < "$ORG_WAKER_STUB_STATE/pane_runs" | tr -d ' ')
if [ "$runs" -lt 1 ]; then
  echo "FAIL own-text-recovery: expected empty submit pane run"
  failed=1
fi

# --- (4) foreign-after-settle → held, never delivered (F1) -----------------
reset_state
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL"
# verify parked; pre-Enter parked; Enter; post-settle foreign → fail hold
write_seq pane_read "$PARKED_TAIL" "$PARKED_TAIL" "$FOREIGN_TAIL"
ring_or_hold "stub-lane" "1" "orch" "$SENT"
record "foreign-after-settle" "held:unverified:status=idle"
runs=$(wc -l < "$ORG_WAKER_STUB_STATE/pane_runs" | tr -d ' ')
if [ "$runs" -ne 1 ]; then
  echo "FAIL foreign-after-settle: expected exactly 1 pane run, got $runs"
  failed=1
fi

# --- (5) content-mutated-before-Enter → no Enter (F2) ---------------------
reset_state
# composer_clear sees stable parked own-text
write_seq agent_read "$PARKED_TAIL" "$PARKED_TAIL"
# recover_own_text parked; recover pre-Enter foreign → abort without Enter
write_seq pane_read "$PARKED_TAIL" "$FOREIGN_TAIL"
ring_or_hold "stub-lane" "1" "orch" "$SENT"
record "content-mutated-before-Enter" "held:composer:status=idle"
runs=$(wc -l < "$ORG_WAKER_STUB_STATE/pane_runs" | tr -d ' ')
if [ "$runs" -ne 0 ]; then
  echo "FAIL content-mutated-before-Enter: expected 0 pane runs, got $runs"
  failed=1
else
  echo "ok content-mutated-before-Enter: no empty submit on mutated line"
fi
if [ -s "$ORG_WAKER_STUB_STATE/prompts" ]; then
  echo "FAIL content-mutated-before-Enter: agent prompt should not run"
  cat "$ORG_WAKER_STUB_STATE/prompts"
  failed=1
fi
# --- helpers for count-based audit assertions -----------------------------
count_outcome() {
  # count_outcome OUTCOME — lines in rings.jsonl with that outcome
  jq -s --arg o "$1" '[.[] | select(.outcome == $o)] | length' \
    "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl" 2>/dev/null || echo 0
}

assert_count() {
  # assert_count LABEL OUTCOME WANT
  got=$(count_outcome "$2")
  if [ "$got" != "$3" ]; then
    echo "FAIL $1: outcome=$2 count=$got want $3"
    failed=1
  else
    echo "ok $1: outcome=$2 count=$got"
  fi
}

# --- (6) unregister purges pending → exactly one dropped:unregistered ----
# Evidence path for the silent-rm gap: held wake file exists, lane close-out
# removes it; audit must record dropped:unregistered (not vanish silently).
reset_state
: > "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"
printf 'orch\n%s\n' "$SENT" > "$HERDR_PLUGIN_CONFIG_DIR/pending/1000-stub-lane-g1.msg"
# Sibling lane must not be purged (rev-<lane> reviewer naming / suffix safety).
printf 'orch\nother wake\n' > "$HERDR_PLUGIN_CONFIG_DIR/pending/1001-rev-stub-lane-g1.msg"
cmd_unregister --lane stub-lane >/dev/null
assert_count "unregister-drop" "dropped:unregistered" "1"
if [ -e "$HERDR_PLUGIN_CONFIG_DIR/pending/1000-stub-lane-g1.msg" ]; then
  echo "FAIL unregister-drop: pending .msg still present"
  failed=1
else
  echo "ok unregister-drop: pending .msg removed"
fi
if [ ! -e "$HERDR_PLUGIN_CONFIG_DIR/pending/1001-rev-stub-lane-g1.msg" ]; then
  echo "FAIL unregister-drop: sibling rev-<lane> was purged"
  failed=1
else
  echo "ok unregister-drop: sibling rev-<lane> untouched"
  rm -f "$HERDR_PLUGIN_CONFIG_DIR/pending/1001-rev-stub-lane-g1.msg"
fi

# --- (7) drain success path → exactly one drain-delivered ----------------
reset_state
: > "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"
printf 'orch\n%s\n' "$SENT" > "$HERDR_PLUGIN_CONFIG_DIR/pending/2000-stub-lane-g1.msg"
# do_drain → composer_clear (2 agent reads) → deliver → verify clear (2 pane
# reads) → lifecycle corroboration: the pure-clear branch now requires the
# idle target to have STARTED a turn (post-verify status working) before
# clear counts as delivered. Sequenced statuses model exactly that:
# get#0 send_prompt pre-read = idle, get#1 verify pane resolve, get#2
# post-verify corroboration = working.
write_seq agent_read "$CLEAR_TAIL" "$CLEAR_TAIL" "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq pane_read "$CLEAR_TAIL" "$CLEAR_TAIL"
write_seq agent_status idle idle working working
do_drain
assert_count "drain-success" "drain-delivered" "1"
if [ -e "$HERDR_PLUGIN_CONFIG_DIR/pending/2000-stub-lane-g1.msg" ] || \
   [ -e "$HERDR_PLUGIN_CONFIG_DIR/pending/2000-stub-lane-g1.msg.claim" ]; then
  echo "FAIL drain-success: claim/msg still present after drain-delivered"
  failed=1
else
  echo "ok drain-success: pending claim consumed"
fi
# Exactly one rings line total for this scenario (no double-log).
total=$(wc -l < "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl" | tr -d ' ')
if [ "$total" -ne 1 ]; then
  echo "FAIL drain-success: expected 1 rings line, got $total"
  cat "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"
  failed=1
else
  echo "ok drain-success: exactly 1 rings line"
fi

echo "--- stub path: $FAKE"
echo "--- outcome lines:"
printf '%s' "$outcome_lines"
echo "--- rings.jsonl:"
cat "$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl" 2>/dev/null || true

if [ "$failed" -eq 0 ]; then
  echo "parked_retry.sh: OK"
  # keep stub dir for evidence paste; also copy path marker
  echo "$FAKE" > /tmp/waker-parked-retry_stub_path
  exit 0
else
  echo "parked_retry.sh: FAILED (state under $STUB_ROOT)"
  exit 1
fi
