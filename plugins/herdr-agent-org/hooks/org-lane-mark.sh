#!/bin/sh
# PreToolUse hook on the shell-class tools: record WHAT this Claude session
# actually did to the Herdr org, so org-stop-gate.sh can state a premise it can
# prove. Read by org-stop-gate.sh.
#
# Herdr has no MCP tool surface (dispatch, steer, and wait are shell commands),
# so this hook cannot arm on a tool NAME. It fires
# on every Bash/skyline_run call and classifies the command text itself:
#   dispatch  worker started (dispatch-worker, herdr agent start)
#   wait      lifecycle wait armed (herdr agent wait)
# Anything else leaves no mark, so the gate stays inert in ordinary sessions.
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0

# Flatten every string under tool_input: .command for Bash, .argv / .argv_list
# for skyline_run, without caring which shape the caller used.
cmd=$(printf '%s' "$input" | jq -r '[(.tool_input? // {}) | .. | strings] | join("\n")' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# Classify by the PROGRAM each pipeline stage runs, not by substring: a sed,
# grep, or cat that merely mentions dispatch-worker is not a dispatch. Stages
# split on | ; & and newlines; leading VAR=value assignments are skipped;
# `${HERDR_BIN_PATH:-herdr}` counts as herdr.
event=$(printf '%s\n' "$cmd" | tr '|;&' '\n\n\n' | awk '
  BEGIN { ev = "" }
  {
    n = split($0, t, /[ \t]+/); i = 1
    while (i <= n && (t[i] == "" || t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/)) i++
    if (i > n) next
    p = t[i]; sub(/.*\//, "", p)
    if (p == "dispatch-worker") { ev = "dispatch"; exit }
    if (p ~ /^(\$\{HERDR_BIN_PATH:-herdr\}|"\$\{HERDR_BIN_PATH:-herdr\}"|\$HERDR|"\$HERDR"|herdr)$/ && t[i+1] == "agent") {
      if (t[i+2] == "start") { ev = "dispatch"; exit }
      if (t[i+2] == "wait" && ev == "") ev = "wait"
    }
  }
  END { print ev }')
[ -n "$event" ] || exit 0

printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" >> "/tmp/claude-herdr-org-lanes-$sid"
exit 0
