#!/bin/sh
# PreToolUse hook on the shell-class tools: record WHAT this Claude session
# actually did to the Herdr org, so org-stop-gate.sh can state a premise it can
# prove. Read by org-stop-gate.sh.
#
# Herdr has no MCP tool surface (dispatch, steer, and wait are shell commands),
# so this hook cannot arm on a tool NAME. It fires
# on every Bash/skyline_run call and classifies the command text itself, ONE
# marker line per command stage:
#   dispatch <todo> <name>  worker started: a dispatch-worker stage records its
#             --todo slug and --name (`-` when absent); `herdr agent start <n>`
#             records `- <n>`. org-stop-gate.sh matches relay doorbells whose
#             sender is either key to tell an in-flight lane from a done one.
#   wait      lifecycle wait armed (herdr agent wait)
# Anything else leaves no mark, so the gate stays inert in ordinary sessions.
# A --help/-h stage starts nothing and leaves no mark. A dispatch the hook
# cannot see (dispatch-worker run from inside a script) is recorded by
# dispatch-worker itself, which finds this session through
# $CLAUDE_CODE_SESSION_ID or, in a shell that dropped it, through the pane
# map written below (/tmp/claude-herdr-org-pane-<pane id>).
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
[ -n "$sid" ] || exit 0
if [ -n "${HERDR_PANE_ID:-}" ]; then
  pane_map="/tmp/claude-herdr-org-pane-$(printf '%s' "$HERDR_PANE_ID" | tr -c 'A-Za-z0-9_-' '_')"
  [ "$(cat "$pane_map" 2>/dev/null)" = "$sid" ] || printf '%s\n' "$sid" > "$pane_map" 2>/dev/null || true
fi

# One line per command: Bash's .command as typed; each skyline_run .argv array
# and each run_batch .argv_list array as ONE shell-quoted line (@sh), so a
# prompt argument keeps its spaces inside one quoted token.
cmd=$(printf '%s' "$input" | jq -r '(.tool_input? // {}) | [(.command? // empty), (.argv? // empty | @sh), ((.argv_list? // [])[] | @sh), ((.argv?, (.argv_list? // [])[]) | select(type=="array" and ((.[0]|tostring)|test("(^|/)(ba|z)?sh$")) and ((.[1]|tostring)|test("^-[a-z]*c$"))) | .[2] // empty)] | join("\n")' 2>/dev/null || true)
[ -n "$cmd" ] || exit 0

# Classify by the PROGRAM each pipeline stage runs, not by substring: a sed,
# grep, or cat that merely mentions dispatch-worker is not a dispatch. Stages
# split on | ; & and newlines; quoted strings with whitespace (prompt text) are
# blanked first so their words are never read as flags; leading VAR=value
# assignments, shell keywords (do then else elif if while until { !) and the
# prefix commands time / exec / nohup / env (with its VAR=value pairs) are
# skipped, and ( ) are separators, so a stage inside a loop, a branch, a
# subshell or a $( ) is classified (0.1.7, PR #9 review M6). Known limit: a
# dispatch typed inside a heredoc BODY is not seen; dispatch-worker's own
# marker line covers it. `${HERDR_BIN_PATH:-herdr}` counts as herdr. A name or
# todo that is a shell expansion (`"$n"` in a loop) is no key: recorded as `-`.
events=$(printf '%s\n' "$cmd" | tr '|;&' '\n\n\n' | awk -v q="'" '
  function bare(s) { gsub("[\"" q "]", "", s); return s }
  {
    gsub(/(^|[ \t])"[^"]*[ \t][^"]*"/, " \"\"")
    gsub("(^|[ \t])" q "[^" q "]*[ \t][^" q "]*" q, " " q q)
    gsub(/[()]/, " ")
    n = split($0, t, /[ \t]+/); i = 1
    while (i <= n && (t[i] == "" || t[i] ~ /^[A-Za-z_][A-Za-z0-9_]*=/ || t[i] ~ /^(do|then|else|elif|if|while|until|\{|!|time|exec|nohup|env)$/)) i++
    if (i > n) next
    p = bare(t[i]); sub(/.*\//, "", p)
    if (p == "dispatch-worker") {
      todo = "-"; name = "-"
      for (j = i + 1; j <= n; j++) {
        v = bare(t[j])
        if (v == "--help" || v == "-h") next
        if (v == "--todo" && j < n) todo = bare(t[j + 1])
        else if (v ~ /^--todo=/) todo = substr(v, 8)
        else if (v == "--name" && j < n) name = bare(t[j + 1])
        else if (v ~ /^--name=/) name = substr(v, 8)
        else if (v == "--relaunch" && j < n) name = bare(t[j + 1])
      }
      if (todo == "" || todo ~ /\$/) todo = "-"
      if (name == "" || name ~ /\$/) name = "-"
      print "dispatch " todo " " name; next
    }
    if (p ~ /^(\$\{HERDR_BIN_PATH:-herdr\}|\$HERDR|herdr)$/ && bare(t[i + 1]) == "agent") {
      if (bare(t[i + 2]) == "start") {
        for (j = i + 3; j <= n; j++) { v = bare(t[j]); if (v == "--help" || v == "-h") next }
        name = bare(t[i + 3]); if (name == "" || name ~ /\$/) name = "-"
        print "dispatch - " name; next
      }
      if (bare(t[i + 2]) == "wait") { print "wait"; next }
    }
  }')
[ -n "$events" ] || exit 0

ts=$(date -u +%Y-%m-%dT%H:%M:%SZ)
printf '%s\n' "$events" | while IFS= read -r ev; do
  printf '%s %s\n' "$ts" "$ev"
done >> "/tmp/claude-herdr-org-lanes-$sid"
exit 0
