#!/bin/bash
# writing-guard.sh — PostToolUse hook (Write|Edit + skyline_create/skyline_edit)
# that flags AI writing tells in NEWLY WRITTEN content — never the whole file:
#   Write / skyline_create → the full new content
#   Edit                   → new_string only
#   skyline_edit           → the +body lines of the patch only
# so editing a legacy file never flags text the edit didn't add.
#
# Em-dash policy matches ~/.claude/CLAUDE.md ## Writing Guidelines: at most one
# per 500 words in prose (minimum allowance 1); zero in code, where an em dash
# is almost always a generated-comment tell. Vocab/phrase scans run only on
# prose files with 150+ new words. Set WRITING_GUARD_EXEMPT_RE (ERE, matched
# against the file path) to exempt paths. Fails open on infrastructure errors.

set -uo pipefail

command -v jq >/dev/null 2>&1 || exit 0
INPUT=$(cat)

FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // .tool_input.path // empty' 2>/dev/null) || exit 0
CONTENT=$(printf '%s' "$INPUT" | jq -r '.tool_input.content // .tool_input.new_string // empty' 2>/dev/null) || exit 0

# skyline_edit: added lines of the patch; target path from the first ¶ header.
if [ -z "$CONTENT" ]; then
  PATCH=$(printf '%s' "$INPUT" | jq -r '.tool_input.patch // empty' 2>/dev/null) || PATCH=""
  if [ -n "$PATCH" ]; then
    [ -z "$FILE_PATH" ] && FILE_PATH=$(printf '%s\n' "$PATCH" | sed -n 's/^¶\([^#]*\)#.*/\1/p' | head -1)
    CONTENT=$(printf '%s\n' "$PATCH" | sed -n 's/^+//p')
  fi
fi

[ -z "$FILE_PATH" ] && exit 0
[ -z "$CONTENT" ] && exit 0

if [ -n "${WRITING_GUARD_EXEMPT_RE:-}" ]; then
  printf '%s' "$FILE_PATH" | grep -qE -- "$WRITING_GUARD_EXEMPT_RE" 2>/dev/null && exit 0
fi

# Skip data, config, lock, and binary files where these checks are pure noise.
case "$FILE_PATH" in
  *.json|*.jsonc|*.yaml|*.yml|*.toml|*.xml|*.csv|*.tsv|*.lock|*.lockb|*.lockfile|*.sum|*.mod|*.svg|*.map|*.min.js|*.min.css) exit 0 ;;
  *.png|*.jpg|*.jpeg|*.gif|*.webp|*.ico|*.pdf|*.zip|*.gz|*.tar|*.docx|*.xlsx|*.pptx|*.doc|*.xls|*.ppt|*.key|*.numbers|*.pages) exit 0 ;;
esac

# Prose files get the full vocab/phrase scan + the ratio em-dash rule; other
# files (code, configs) get the strict zero em-dash check only.
case "$FILE_PATH" in
  *.md|*.mdx|*.markdown|*.html|*.htm|*.txt|*.rst|*.adoc|*.tex|*.rtf) IS_PROSE=1 ;;
  *) IS_PROSE=0 ;;
esac

# Strip code blocks and inline code so quoted code in prose doesn't trip the regex.
STRIPPED=$(printf '%s\n' "$CONTENT" | awk '
  /^```/ { in_code = !in_code; next }
  !in_code { print }
' | sed 's/`[^`]*`//g')

VIOLATIONS=""

WORD_COUNT=$(printf '%s\n' "$STRIPPED" | wc -w | tr -d ' ')
EM_COUNT=$(printf '%s\n' "$STRIPPED" | grep -o '—' | wc -l | tr -d ' ')
if [ "$IS_PROSE" -eq 1 ]; then
  EM_ALLOWED=$((WORD_COUNT / 500))
  [ "$EM_ALLOWED" -lt 1 ] && EM_ALLOWED=1
else
  EM_ALLOWED=0
fi
if [ "$EM_COUNT" -gt "$EM_ALLOWED" ]; then
  VIOLATIONS="${VIOLATIONS}- Em dashes: ${EM_COUNT} in ${WORD_COUNT} new words (allowed ${EM_ALLOWED}; policy: max 1 per 500 words in prose, 0 in code)\n"
fi

if [ "$IS_PROSE" -eq 1 ] && [ "$WORD_COUNT" -ge 150 ]; then
  BANNED='delve|tapestry|pivotal|testament|meticulous|nuanced|multifaceted|embark|spearhead|bolster|garner|interplay|nestled|bustling|vibrant|comprehensive|invaluable|reimagine|empower|groundbreaking|transformative|paramount|myriad|cornerstone|catalyst|seamless|seamlessly'
  FOUND=$(printf '%s\n' "$STRIPPED" | grep -oiE "\b(${BANNED})\b" 2>/dev/null | sort -fu | tr '\n' ',' | sed 's/,$//' || true)
  [ -n "$FOUND" ] && VIOLATIONS="${VIOLATIONS}- Banned AI vocabulary: ${FOUND}\n"

  PHRASES='great question!|certainly!|absolutely!|i hope this helps|let'\''s dive in|without further ado|it'\''s worth noting that|in conclusion,|in summary,'
  FOUND_PH=$(printf '%s\n' "$STRIPPED" | grep -oiE "(${PHRASES})" 2>/dev/null | sort -fu | tr '\n' ' / ' | sed 's, / $,,' || true)
  [ -n "$FOUND_PH" ] && VIOLATIONS="${VIOLATIONS}- AI phrases: ${FOUND_PH}\n"
fi

[ -z "$VIOLATIONS" ] && exit 0

REASON=$(printf "New content written to %s violates ## Writing Guidelines (~/.claude/CLAUDE.md):\n\n%b\nEdit the file to remove these tells from the text you just added. Do not acknowledge or apologize, just produce a corrected version." "$FILE_PATH" "$VIOLATIONS")

jq -n --arg reason "$REASON" '{decision: "block", reason: $reason}'
