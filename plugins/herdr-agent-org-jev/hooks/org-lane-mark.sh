#!/bin/sh
# PreToolUse hook on the shell-class tools: record WHAT this Claude session
# actually did to the Herdr org, so org-stop-gate.sh can state a premise it can
# prove. Read by org-stop-gate.sh.
#
# Herdr has no MCP tool surface (dispatch, steer, and wait are shell commands),
# so this hook cannot arm on a tool NAME the way the Solo sibling does. It fires
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
cmd=$(printf '%s' "$input" | jq -r '[(.tool_input? // {}) | .. | strings] | join(" ")' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

case "$cmd" in
  *dispatch-worker*|*"agent start"*) event=dispatch ;;
  *"agent wait"*)                    event=wait ;;
  *)                                 exit 0 ;;
esac

printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$event" >> "/tmp/claude-herdr-org-lanes-$sid"
exit 0
