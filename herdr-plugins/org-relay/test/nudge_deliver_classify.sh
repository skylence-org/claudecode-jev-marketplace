#!/bin/sh
# Classifier unit test for nudge-deliver --classify: fake rendered tails, no
# herdr needed. Run: sh herdr-plugins/org-relay/test/nudge_deliver_classify.sh
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
ND="$DIR/nudge-deliver"
TEXT='[RELAY-NUDGE] unconsumed relay messages are queued for you. Run relay_inbox(agent="orch-x"), act on them, then relay_consume the handled ids.'
fail=0
check() {
  want=$1
  tail_in=$2
  got=$(printf '%s\n' "$tail_in" | sh "$ND" --classify "$TEXT")
  if [ "$got" != "$want" ]; then
    echo "FAIL: want $want, got $got, for tail ending: $(printf '%s' "$tail_in" | tail -1)"
    fail=1
  fi
}
check clear "some transcript line
❯ "
check none "a pane too small to render a composer"
check ours "transcript
❯ $TEXT"
check queued "transcript
❯ Press up to edit queued messages"
check pasted "transcript
❯ [Pasted text #1]"
check pasted "transcript
❯ [Pasted text #2] [Pasted text #3]"
check foreign "transcript
❯ fix the login bug please"
check clear "transcript
❯ │"
# Wrapped composer: the TUI soft-wraps at pane width, so only the FIRST visual
# fragment reaches prompt_text — the [RELAY-NUDGE] tag prefix must classify it
# ours (measured live 2026-08-04: exact-match called it foreign, held forever).
check ours "transcript
❯ [RELAY-NUDGE] unconsumed relay messages are queued for you. Run"
if [ "$fail" = 0 ]; then
  echo "nudge-deliver classify: OK"
else
  echo "nudge-deliver classify: FAILED"
  exit 1
fi
