#!/bin/bash
# jev-intent-gate.sh — PreToolUse hook. The two dependency rules that
# core-claude's judge-hook ships as class=escalate (deps.pinned-install,
# deps.manifest-edit), decided by ONE Jev request instead of a `claude -p`
# subprocess.
#
# Why these two and not the rest of judge-rules.json: deny/allow rules are
# regex and belong in code; the gated rule is a fact probe and belongs in code;
# git.remote-branch-delete asks whether a branch name appears VERBATIM in
# recent user messages, which is grep's job (Jev reads literally and is worse
# than grep at exact matching). Only "does recent context show a registry
# lookup for this version?" is a semantic judgment — and on a box that logs in
# with OAuth, judge-hook's escalate path cannot run isolated (`--bare` needs
# ANTHROPIC_API_KEY) and is inert. Jev is an HTTP call with no hook or
# CLAUDE.md inheritance, so the judgment actually happens.
#
# Flow: regex pre-match (every unrelated tool call exits here, before any
# network) -> state {tool, tool_input, recent_user_messages} -> Jev set
# `deps-pin` -> two Nouls -> verdict by thresholds in jev-questions.json.
# The user messages are DATA in the state, structurally separated from the
# questions; the escalate prompt had to beg for that in prose.
#
# Verdict: exit 2 with a TEMPLATED reason on stderr (Jev returns no prose);
# the numbers behind the block are in the reason and in the audit log.
# FAIL-OPEN: no key, timeout, unparseable reply -> allow + one stderr line.
set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
HOOK_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" 2>/dev/null && pwd) || exit 0
JEV="${JEV_BIN:-$HOOK_DIR/../scripts/jev}"
[ -x "$JEV" ] || JEV="sh $JEV"

INPUT=$(cat)
PARSED=$(printf '%s' "$INPUT" | jq -r \
  '[(.tool_name // ""), ((.tool_input // {}) | tojson | @base64), (.transcript_path // "")] | @tsv' 2>/dev/null) || exit 0
RAW_TOOL=$(printf '%s' "$PARSED" | cut -f1)
TOOL_INPUT_JSON=$(printf '%s' "$PARSED" | cut -f2 | { base64 -d 2>/dev/null || base64 -D 2>/dev/null; })
TRANSCRIPT=$(printf '%s' "$PARSED" | cut -f3)
[ -n "$RAW_TOOL" ] || exit 0

# Skyline-aware normalisation, same as judge-hook: a skyline_run carries argv
# rather than a command string, skyline_create/edit carry path/patch.
CLASS="$RAW_TOOL"
MATCH_TEXT="$TOOL_INPUT_JSON"
case "$RAW_TOOL" in
  *skyline_run)
    CLASS=Bash
    CMDS=$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '((.argv // []) | join(" ")), ((.argv_list // [])[] | join(" "))' 2>/dev/null) || CMDS=""
    [ -n "$CMDS" ] && MATCH_TEXT="$TOOL_INPUT_JSON
$(printf '%s\n' "$CMDS" | sed 's/^/cmd: /')"
    ;;
  *skyline_create)
    CLASS=Write
    FP=$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.path // empty' 2>/dev/null) || FP=""
    [ -n "$FP" ] && MATCH_TEXT="$TOOL_INPUT_JSON
\"file_path\":\"$FP\""
    ;;
  *skyline_edit)
    CLASS=Edit
    FPS=$(printf '%s' "$TOOL_INPUT_JSON" | jq -r '.patch // empty' 2>/dev/null | sed -n 's/^¶\([^#]*\)#.*/\1/p') || FPS=""
    [ -n "$FPS" ] && MATCH_TEXT="$TOOL_INPUT_JSON
$(printf '%s\n' "$FPS" | sed 's/^/"file_path":"/; s/$/"/')"
    ;;
esac

# Stage 1: regex pre-match, verbatim from judge-rules.json deps.* patterns.
PIN_RE='((npm|pnpm)[[:space:]]+(i|install|add)[[:space:]]+[^[:space:]]+@[0-9]|yarn[[:space:]]+add[[:space:]]+[^[:space:]]+@[0-9]|composer[[:space:]]+require[[:space:]]+[^[:space:]]+:)'
MANIFEST_RE='"file_path"[[:space:]]*:[[:space:]]*"[^"]*(package|composer)\.json"'
RULE=""
case "$CLASS" in
  Bash)       printf '%s' "$MATCH_TEXT" | grep -qE -- "$PIN_RE"      && RULE=deps.pinned-install ;;
  Edit|Write) printf '%s' "$MATCH_TEXT" | grep -qE -- "$MANIFEST_RE" && RULE=deps.manifest-edit ;;
esac
[ -n "$RULE" ] || exit 0

# Recent operator intent, the last three user messages, as an array.
CTX='[]'
if [ -n "$TRANSCRIPT" ] && [ -f "$TRANSCRIPT" ]; then
  CTX=$(tail -n 400 "$TRANSCRIPT" 2>/dev/null | jq -cs '
    [ .[] | select(.type == "user") | .message.content
      | if type == "string" then .
        else ((map(select(.type == "text") | .text) // []) | join("\n")) end
      | select(length > 0) ] | .[-3:] | map(.[-1500:])' 2>/dev/null) || CTX='[]'
  [ -n "$CTX" ] || CTX='[]'
fi

STATE=$(jq -nc --arg tool "$RAW_TOOL" --argjson ti "$TOOL_INPUT_JSON" --argjson ctx "$CTX" \
  '{tool: $tool, tool_input: $ti, recent_user_messages: $ctx}') || exit 0
ANSWERS=$(printf '%s' "$STATE" | $JEV ask deps-pin 2>/dev/null) || ANSWERS=""
if [ -z "$ANSWERS" ]; then
  echo "jev-intent-gate: rule $RULE matched but Jev gave no answer (no key, timeout, or error); allowing without evaluation" >&2
  exit 0
fi

LOOKUP=$(printf '%s' "$ANSWERS" | jq -r '.lookup_seen.noul // empty')
RAISES=$(printf '%s' "$ANSWERS" | jq -r '.raises_version.noul // empty')
T_LOOKUP=$($JEV threshold deps-pin lookup_seen 2>/dev/null)
T_RAISES=$($JEV threshold deps-pin raises_version 2>/dev/null)
{ [ -n "$LOOKUP" ] && [ -n "$T_LOOKUP" ]; } || { echo "jev-intent-gate: reply lacked lookup_seen; allowing" >&2; exit 0; }

ge() { awk -v a="$1" -v b="$2" 'BEGIN { exit !(a >= b) }'; }

BLOCK=0
case "$RULE" in
  deps.pinned-install)
    ge "$LOOKUP" "$T_LOOKUP" || BLOCK=1 ;;
  deps.manifest-edit)
    # Allowed when the edit does not raise a version, or when a lookup is visible.
    if [ -n "$RAISES" ] && [ -n "$T_RAISES" ] && ge "$RAISES" "$T_RAISES" && ! ge "$LOOKUP" "$T_LOOKUP"; then BLOCK=1; fi ;;
esac
[ "$BLOCK" -eq 1 ] || exit 0

echo "jev-intent-gate: blocked rule=$RULE lookup_seen=$LOOKUP${RAISES:+ raises_version=$RAISES} (thresholds lookup>=$T_LOOKUP${T_RAISES:+, raises>=$T_RAISES}; ${JEV_MODEL:-jev-1.13.0}). The version looks pinned from memory. Verify the current stable version first with \`npm view <pkg> version\` or \`composer show <pkg> --all\` (or read it from the lockfile), then pin that; do not use a version recalled from training." >&2
exit 2
