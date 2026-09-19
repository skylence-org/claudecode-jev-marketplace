#!/bin/bash
# jev-research-nudge.sh — Stop hook. When the assistant's final turn hedges a
# FACTUAL claim ("might", "probably", "I think", ...) without verifying it,
# block the first stop once and ask it to confirm the claim before concluding.
#
# Same two-stage shape as core-claude's research-nudge: (1) a cheap grep for
# hedge markers, where most turns exit; (2) only then ONE Jev request asking a
# single Noul, "is there a hedged, checkable factual claim here?". Stage 2 used
# to be a `claude -p` subprocess (seconds, a second model process, skipped
# under memory pressure); Jev answers over HTTP in well under a second and
# costs a few thousandths of a cent, so the pressure check is gone.
#
# Jev returns no prose, so the nudge cannot name the claim; it points at the
# last message, and the audit line (~/.claude/jev-audit.jsonl) carries the
# probability that drove it. Fails OPEN on every infrastructure error.
#
# Silent in herdr agent-org sessions (the org-lane-mark marker is present):
# org roles stop constantly, their milestone prose is hedge-shaped, and they
# answer to the org's own stop discipline. That reasoning survives the cost
# change.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 0
JEV="${JEV_BIN:-$HOOK_DIR/../scripts/jev}"
[ -x "$JEV" ] || JEV="sh $JEV"

INPUT=$(cat)
ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active // false')
[ "$ACTIVE" = "true" ] && exit 0

SID=$(printf '%s' "$INPUT" | jq -r '.session_id // empty')
[ -n "$SID" ] && [ -f "/tmp/claude-herdr-org-lanes-$SID" ] && exit 0

TRANSCRIPT=$(printf '%s' "$INPUT" | jq -r '.transcript_path // empty')
{ [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; } || exit 0

LAST=$(tail -n 400 "$TRANSCRIPT" | jq -rs '
  [ .[] | select(.type == "assistant") ] | last
  | (.message.content // [])
  | map(select(.type == "text") | .text) | join("\n")
' 2>/dev/null || true)
[ -n "$LAST" ] || exit 0

# Stage 1: the cheap gate. Most turns stop here and Jev is never called.
HEDGE="might|may( |,|\.|\$)|probably|possibly|i think|i believe|i'm not sure|not entirely sure|not totally sure|as far as i know|if i recall|presumably|i assume|i guess|afaik|i'd guess|likely"
printf '%s' "$LAST" | grep -qiE "$HEDGE" || exit 0

# Stage 2: one Jev request. The state is the text alone; the question set
# carries the definition of a factual claim and of a hedge.
STATE=$(jq -nc --arg t "$(printf '%s' "$LAST" | tail -c 12000)" '{assistant_text: $t}')
ANSWERS=$(printf '%s' "$STATE" | $JEV ask research-nudge 2>/dev/null) || ANSWERS=""
[ -n "$ANSWERS" ] || exit 0   # fail-open: no answer, no nudge

P=$(printf '%s' "$ANSWERS" | jq -r '.hedged_fact.noul // empty')
T=$($JEV threshold research-nudge nudge 2>/dev/null)
{ [ -n "$P" ] && [ -n "$T" ]; } || exit 0
awk -v p="$P" -v t="$T" 'BEGIN { exit !(p >= t) }' || exit 0

REASON=$(printf 'You hedged a factual claim in your last message instead of verifying it (jev hedged_fact=%s, threshold %s, %s). Before concluding, confirm it with a web search (WebSearch / WebFetch) or a direct test and state the confirmed fact with its source — or say plainly that you could not verify it. If the statement is genuinely subjective, or you already verified it this session, you may stop again.' \
  "$P" "$T" "${JEV_MODEL:-jev-1.13.0}")
jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
