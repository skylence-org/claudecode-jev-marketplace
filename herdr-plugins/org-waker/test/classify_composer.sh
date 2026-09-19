#!/bin/sh
# classify_composer.sh: fixture test for org-waker's post-send composer
# classifier (skylore mark 90 / wake-submit-verify F1). Sources the real
# waker script so the test exercises the real prompt_text/classify_composer
# functions rather than a re-implementation, then feeds them fake tails --
# no herdr binary, no live pane required.
set -eu

DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
WAKER="$DIR/waker"

command -v jq >/dev/null 2>&1 || { echo "classify_composer.sh: jq required, skipping"; exit 0; }

HERDR_PLUGIN_CONFIG_DIR=$(mktemp -d "${TMPDIR:-/tmp}/org-waker-test.XXXXXX")
export HERDR_PLUGIN_CONFIG_DIR
trap 'rm -rf "$HERDR_PLUGIN_CONFIG_DIR"' EXIT

# `list` is a side-effect-free subcommand (no herdr calls) so sourcing the
# script with that argument exercises only setup, never a live send.
. "$WAKER" list >/dev/null 2>&1

failed=0
check() {
  # check LABEL TAIL SENT_LINE WANT
  got=$(classify_composer "$2" "$3")
  if [ "$got" != "$4" ]; then
    echo "FAIL $1: got '$got' want '$4'"
    failed=1
  else
    echo "ok $1"
  fi
}

SENT="[RING g1] lane foo -> idle. board get foo"

# exact-match: our own wake text still sits on the composer line, unsubmitted.
check exact-match "$(printf 'some scrollback\n%s %s' "$PROMPT_CHAR" "$SENT")" "$SENT" parked

# mismatch: someone else's text is on the line -- never empty-submit it.
check mismatch "$(printf 'some scrollback\n%s unrelated operator text' "$PROMPT_CHAR")" "$SENT" foreign

# empty: composer is clear.
check empty "$(printf 'some scrollback\n%s ' "$PROMPT_CHAR")" "$SENT" clear

# no prompt line in the visible frame at all: reads as clear too (queued or scrolled off).
check no-prompt-line "$(printf 'some scrollback\nno prompt char here')" "$SENT" clear

# Grok 4.5 boxed composer (measured 2026-07-28): border glyphs U+256D/U+2500/U+256E
# top, U+2502 on the composer line, U+2570/U+2500/U+256F bottom. Empty middle line
# must classify clear (not a lone border glyph).
check grok-empty-box "$(printf '╭─────────────────────────────╮\n│ %s                           │\n╰──── Grok 4.5 (medium) ── ───╯\nShift+Tab:mode  |  Ctrl+x:shortcuts' "$PROMPT_CHAR")" "$SENT" clear

# Grok boxed with EXACTLY the sent text after the prompt char → parked.
check grok-parked-box "$(printf '╭─────────────────────────────╮\n│ %s %s                     │\n╰──── Grok 4.5 (medium) ── ───╯\nShift+Tab:mode  |  Ctrl+x:shortcuts' "$PROMPT_CHAR" "$SENT")" "$SENT" parked

# Grok boxed with other text → foreign (never empty-submit).
check grok-foreign-box "$(printf '╭─────────────────────────────╮\n│ %s unrelated operator text   │\n╰──── Grok 4.5 (medium) ── ───╯\nShift+Tab:mode  |  Ctrl+x:shortcuts' "$PROMPT_CHAR")" "$SENT" foreign

# Claude mid-turn queue: composer line is the exact QUEUED_HINT → delivered-equivalent.
# One read is enough in verify_submitted; classifier returns the new `queued` verdict.
check queued-hint "$(printf 'some scrollback\n%s %s' "$PROMPT_CHAR" "$QUEUED_HINT")" "$SENT" queued

if [ "$failed" -eq 0 ]; then
  echo "classify_composer.sh: OK"
else
  echo "classify_composer.sh: FAILED"
  exit 1
fi
