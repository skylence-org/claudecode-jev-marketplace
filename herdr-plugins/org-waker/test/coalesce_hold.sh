#!/bin/sh
# coalesce_hold.sh: stub proof for per-lane pending coalescing.
# Field evidence (rings.jsonl 2026-07-30, lane dockerize-tests): five settle
# rings for ONE lane all held:composer, five pending files piled up, and the
# backlog later delivered as a stale barrage the orchestrator had to dismiss
# one by one. The ring only says "go read the board", so a lane's newer
# UNSENT hold supersedes its older ones. Scenarios:
#   A two unsent holds, same lane      -> 1 pending file (the newer text),
#                                         dropped:coalesced ring for the old
#   B sent file for the lane           -> survives coalescing untouched
#   C other lane / rev-<lane> files    -> never touched (suffix parse exact)
# Uses HERDR_BIN_PATH fake herdr; hold_wake needs it only for the toast.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "coalesce_hold.sh: jq required, skipping"; exit 0; }

STUB_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/waker-coalesce_stub.XXXXXX")
export HERDR_PLUGIN_CONFIG_DIR="$STUB_ROOT/cfg"
FAKE="$STUB_ROOT/fake_herdr"
mkdir -p "$HERDR_PLUGIN_CONFIG_DIR"
cat > "$FAKE" <<'FAKE'
#!/bin/sh
case "${1:-}" in
  notification) exit 0 ;;
  plugin) echo "${HERDR_PLUGIN_CONFIG_DIR:-/tmp/missing}" ;;
  *) echo "fake_herdr: unhandled: $*" >&2; exit 1 ;;
esac
FAKE
chmod +x "$FAKE"
export HERDR_BIN_PATH="$FAKE"

. "$WAKER" list >/dev/null 2>&1

PEND="$HERDR_PLUGIN_CONFIG_DIR/pending"
RINGS="$HERDR_PLUGIN_CONFIG_DIR/log/rings.jsonl"
: > "$RINGS"

failed=0
count_msgs() { ls "$PEND"/*.msg 2>/dev/null | wc -l | tr -d ' '; }

# --- A: two unsent holds for one lane coalesce to the newest ---------------
hold_wake "lane-a" "1" "orch" "[RING g1] lane lane-a -> done. board get lane-a" "composer" "unsent"
sleep 1   # distinct epoch-ms filename prefix
hold_wake "lane-a" "1" "orch" "[RING g1] lane lane-a -> idle. board get lane-a" "composer" "unsent"
if [ "$(count_msgs)" = "1" ]; then
  echo "ok A: one pending file after two holds"
else
  echo "FAIL A: pending=$(count_msgs) want 1"
  failed=1
fi
survivor=$(ls "$PEND"/*.msg | head -1)
if [ "$(sed -n '2p' "$survivor")" = "[RING g1] lane lane-a -> idle. board get lane-a" ]; then
  echo "ok A: survivor is the NEWER wake"
else
  echo "FAIL A: survivor text: $(sed -n '2p' "$survivor")"
  failed=1
fi
if grep -q '"outcome":"dropped:coalesced-g1"' "$RINGS"; then
  echo "ok A: coalesce logged one audit ring"
else
  echo "FAIL A: no dropped:coalesced ring in rings.jsonl"
  failed=1
fi

# --- B: a SENT file for the same lane survives -----------------------------
printf '%s\n%s\n%s\n' orch "[RING g1] lane lane-a sent copy" sent > "$PEND/1000-lane-a-g1.msg"
hold_wake "lane-a" "1" "orch" "[RING g1] lane lane-a -> done again" "composer" "unsent"
if [ -f "$PEND/1000-lane-a-g1.msg" ]; then
  echo "ok B: sent file survived coalescing"
else
  echo "FAIL B: coalescing removed a SENT file (duplicate-guard memory lost)"
  failed=1
fi

# --- C: other lanes and rev-<lane> never touched ---------------------------
printf '%s\n%s\n' orch "[RING g1] lane rev-lane-a -> done" > "$PEND/1001-rev-lane-a-g1.msg"
printf '%s\n%s\n' orch "[RING g1] lane other -> done" > "$PEND/1002-other-g1.msg"
hold_wake "lane-a" "1" "orch" "[RING g1] lane lane-a -> done final" "composer" "unsent"
ok=1
[ -f "$PEND/1001-rev-lane-a-g1.msg" ] || ok=0
[ -f "$PEND/1002-other-g1.msg" ] || ok=0
if [ "$ok" = "1" ]; then
  echo "ok C: rev-lane-a and other lanes untouched"
else
  echo "FAIL C: coalescing crossed lane boundaries"
  failed=1
fi

if [ "$failed" -eq 0 ]; then
  echo "coalesce_hold.sh: OK"
  exit 0
else
  echo "coalesce_hold.sh: FAILED (state under $STUB_ROOT)"
  exit 1
fi
