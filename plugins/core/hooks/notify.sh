#!/usr/bin/env bash
# notify.sh — desktop notifications for Claude Code lifecycle events.
# Upstream core-claude wires this from /solo-setup; core carries no Solo skills, so nothing wires it here (kept for a manual hook entry). Handles only events
# Claude Code actually emits: PreCompact, Notification (idle), Stop.
payload=$(cat)
event=$(echo "$payload" | jq -r '.hook_event_name // "Unknown"')

case "$event" in
  PreCompact)
    trigger=$(echo "$payload" | jq -r '.matcher // "auto"')
    title="Claude Code"
    message="Compaction starting ($trigger). Conduct does not survive the summary — agents should re-read their role skill after."
    ;;
  Stop)
    title="Claude Code"
    message="Turn complete."
    ;;
  Notification)
    type=$(echo "$payload" | jq -r '.notification_type // ""')
    title="Claude Code"
    message="Idle: Claude is waiting for input."
    [[ "$type" != "idle_prompt" ]] && exit 0
    ;;
  *)
    exit 0
    ;;
esac

if command -v osascript &>/dev/null; then
  osascript -e "display notification \"$message\" with title \"$title\""
elif command -v powershell.exe &>/dev/null; then
  powershell.exe -NonInteractive -Command "
    Add-Type -AssemblyName System.Windows.Forms
    \$n = New-Object System.Windows.Forms.NotifyIcon
    \$n.Icon = [System.Drawing.SystemIcons]::Information
    \$n.BalloonTipTitle = '$title'
    \$n.BalloonTipText = '$message'
    \$n.Visible = \$true
    \$n.ShowBalloonTip(8000)
    Start-Sleep -Milliseconds 8500
    \$n.Dispose()
  " &
elif command -v notify-send &>/dev/null; then
  notify-send "$title" "$message"
fi
