#!/bin/sh
# org-ack-submit: UserPromptSubmit hook — the receiver-side half of the
# acknowledged wake channel. Claude Code fires this hook at the exact moment
# a prompt BECOMES A TURN in this session, which is the ground truth every
# pane-read heuristic in the delivery chain has been approximating from
# pixels (measured 2026-08-01: both the org-waker's ring verify and the
# worker doorbell doctrine false-positived on "clear composer" reads that
# raced the paste render under load). When the submitted prompt is a ring or
# doorbell, drop an ack file keyed by the prompt's hash into the org-waker's
# config dir; the sender (waker `confirm_delivery`, worker `doorbell`
# script) waits on that file and only falls back to composer heuristics
# when no ack arrives.
#
# Never blocks, never modifies the prompt, exits 0 on every path.
set -u

[ "${HERDR_ENV:-}" = "1" ] || exit 0
command -v jq >/dev/null 2>&1 || exit 0

prompt=$(jq -r '.prompt // empty' 2>/dev/null) || exit 0
case $prompt in
  "[RING g"*|"[DOORBELL]"*) ;;
  *) exit 0 ;;
esac

cfg=$("${HERDR_BIN_PATH:-herdr}" plugin config-dir skylence.org-waker 2>/dev/null) || cfg=""
[ -n "$cfg" ] || cfg="$HOME/.config/herdr/plugins/config/skylence.org-waker"
mkdir -p "$cfg/acks" 2>/dev/null || exit 0

if command -v shasum >/dev/null 2>&1; then
  sha=$(printf '%s' "$prompt" | shasum -a 256 | cut -c1-32)
else
  sha=$(printf '%s' "$prompt" | sha256sum | cut -c1-32)
fi
[ -n "$sha" ] || exit 0

printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${CLAUDE_SESSION_ID:-unknown}" > "$cfg/acks/$sha.ack" 2>/dev/null || true
exit 0
