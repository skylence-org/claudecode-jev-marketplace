#!/bin/sh
# ghost-probe: classify a target agent's input line BEFORE any send (no-fusion
# hard law). Discriminates Claude Code suggestion GHOST text (the placeholder
# the operator accepts with Tab or the right arrow) from REAL operator typing.
# Field-validated recipe 2026-06-10; design doc:
# https://gist.github.com/jonasvanderhaegen/4f6251458e529d290db93ee7afada592
#
# This script never touches the target. The caller gathers tails and, in probe
# mode, sends ONE space between two tails, then a backspace afterwards so the
# net effect is zero either way.
#
# ON HERDR, START WITH live, THEN probe. `herdr pane read` strips ANSI by
# default and `--format ansi` keeps the styling, so BOTH sources still show a
# ghost's text: there is no styling-stripped source that renders a ghost as an
# empty prompt line. zero-touch therefore needs Solo's raw output (or an
# equivalent) and will call a ghost TYPED without it. That errs toward refusing
# to send, which is safe but useless, so on a pure Herdr box the working
# sequence is live (is the operator typing right now?) then probe.
#
# Subcommands:
#   zero-touch --rendered FILE --raw FILE
#       Step 1, no interaction, and only meaningful when the raw source strips a
#       ghost's styling to an empty prompt line (Solo does; Herdr does not).
#       Verdicts: EMPTY | GHOST | TYPED | AMBIGUOUS.
#   probe --before FILE --after FILE [--sent]
#       Deterministic ONLY when a probe space was actually delivered between
#       the two tails: a ghost VANISHES instantly, real typing is RETAINED
#       (trailing whitespace is trimmed, so retained reads as unchanged).
#       --sent is the caller's attestation that the space really went in via
#       a verb this build exposes (marketplace#88: some herdr builds have no
#       pane send-text/send-key; `herdr agent send-keys <target> space` where
#       supported, verified once per box on a scratch pane). WITHOUT --sent an
#       unchanged line is indistinguishable from "no probe ever happened" and
#       classifies UNCLASSIFIED, never TYPED. Probe ONCE, never in a loop.
#       Verdicts: GHOST | TYPED | AMBIGUOUS | UNCLASSIFIED.
#   live --t0 FILE --t1 FILE
#       Guard: two rendered tails moments apart. A prompt line that changed
#       between them is LIVE typing: do not probe, do not send.
#       Verdicts: LIVE | STABLE.
#
# Gathering tails on Herdr:
#   herdr agent read <name> --source visible --lines 40 > /tmp/tail.t0
#   herdr pane read  <pane> --source visible --lines 40 > /tmp/tail.t0
#
# Options: --prompt-char C (default the Claude Code prompt character).
# FILE may be - for stdin (at most one input per invocation).
#
# Exit codes: 0 = safe to send (EMPTY, GHOST, STABLE)
#             1 = DO NOT SEND (TYPED, LIVE), route to the durable channel
#             2 = AMBIGUOUS, UNCLASSIFIED, or usage error: gather better tails
#                 (or deliver a real probe and pass --sent), do not send
set -u

PROMPT="❯"
NP="$(printf '\001')NOPROMPT"

usage() {
  awk 'NR > 1 { if (!/^#/) exit; s = $0; sub(/^# ?/, "", s); print s }' "$0"
  exit 2
}

# Last prompt line's content, trimmed; sentinel when no prompt line exists.
prompt_text() {
  awk -v p="$PROMPT" -v np="$NP" '
    { i = index($0, p); if (i) { found = 1; line = substr($0, i + length(p)) } }
    END {
      if (!found) { print np; exit }
      gsub(/^[ \t]+/, "", line); gsub(/[ \t\r]+$/, "", line)
      print line
    }
  ' "$1"
}

[ "$#" -ge 1 ] || usage
cmd=$1; shift
A=""; B=""; SENT=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --rendered|--before|--t0) A=$2; shift 2 ;;
    --raw|--after|--t1)       B=$2; shift 2 ;;
    --prompt-char)            PROMPT=$2; shift 2 ;;
    --sent)                   SENT=1; shift ;;
    -h|--help)                usage ;;
    *) echo "ghost-probe: unknown argument $1" >&2; exit 2 ;;
  esac
done
[ -n "$A" ] && [ -n "$B" ] || usage
[ "$A" = "-" ] && A=/dev/stdin
[ "$B" = "-" ] && B=/dev/stdin

a=$(prompt_text "$A")
b=$(prompt_text "$B")

case "$cmd" in
  zero-touch)
    [ "$b" = "$NP" ] && { echo AMBIGUOUS; exit 2; }
    [ -n "$b" ] && { echo TYPED; exit 1; }
    [ "$a" = "$NP" ] && { echo AMBIGUOUS; exit 2; }
    if [ -n "$a" ]; then echo GHOST; exit 0; else echo EMPTY; exit 0; fi
    ;;
  probe)
    { [ "$a" = "$NP" ] || [ "$b" = "$NP" ]; } && { echo AMBIGUOUS; exit 2; }
    [ -z "$a" ] && { echo AMBIGUOUS; exit 2; }
    [ -z "$b" ] && { echo GHOST; exit 0; }
    case "$b" in
      "$a"*)
        if [ "$SENT" -eq 1 ]; then echo TYPED; exit 1; fi
        echo "ghost-probe: before/after prompt lines are identical and --sent was not given: with no delivered probe this is an artifact of two plain reads, not evidence of typing (marketplace#88)" >&2
        echo UNCLASSIFIED; exit 2
        ;;
    esac
    echo AMBIGUOUS; exit 2
    ;;
  live)
    { [ "$a" = "$NP" ] || [ "$b" = "$NP" ]; } && { echo AMBIGUOUS; exit 2; }
    if [ "$a" = "$b" ]; then echo STABLE; exit 0; else echo LIVE; exit 1; fi
    ;;
  *) usage ;;
esac
