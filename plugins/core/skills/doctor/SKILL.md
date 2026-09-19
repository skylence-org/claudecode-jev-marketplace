---
name: doctor-skill
description: Read-only health check of the core install. Proves the judge gate is live by running it, checks the plugin is enabled, flags legacy copy-based hook wiring that would double-fire, reports the judge-rules overlay, checks statusline drift and CLAUDE.md guidelines sync, and compares the version stamp. Run /core:doctor when hooks look inert, after a plugin update, or on a machine you don't trust. Writes nothing.
---

# /core:doctor

One read-only pass; report the output verbatim and make NO writes. The single most important line is the GATE probe: with `bypassPermissions` on and the judge not denying, nothing stands between the model and the machine.

Since 2026-07-24 the judge-hook, writing-guard and research-nudge run FROM the plugin (`hooks/hooks.json`, paths under `${CLAUDE_PLUGIN_ROOT}`), so they update with it and there is nothing to copy or keep in sync. A hook wired in `settings.json` by absolute path is now a LEGACY finding, not a healthy state: both copies fire, so every tool call is judged twice and an escalate rule spawns two `claude -p` processes.

```bash
P="$CLAUDE_PLUGIN_ROOT"
S=~/.claude/settings.json

echo '== gate (the one that matters) =='
# The payload comes from a FILE on purpose: a command line that spells out a
# privilege word is denied by the very rule it is probing, so an inline JSON
# payload would make this check unrunnable exactly when the gate is healthy.
probe=$(mktemp -d)
cat "$P/hooks/probe-payload.json" \
  | TMPDIR="$probe" bash "$P/hooks/judge-hook.sh" >/dev/null 2>&1
rc=$?
rm -rf "$probe"
case "$rc" in
  2) echo 'judge-hook: LIVE (denied a gated command end to end: script, shipped rules, overlay)' ;;
  0) echo 'judge-hook: NOT DENYING. If bypassPermissions is on, NOTHING gates tool calls. Check jq is installed, that hooks/judge-rules.json exists in the plugin, and that your overlay does not disable privilege.sudo' ;;
  *) echo "judge-hook: probe exited $rc (unexpected); treat the gate as unproven" ;;
esac
jq -e '.enabledPlugins | to_entries | any(.key | startswith("core@"))' "$S" >/dev/null 2>&1 \
  && echo 'core plugin: enabled (its hooks.json registers judge-hook, jev-intent-gate, writing-guard, jev-research-nudge)' \
  || echo 'core plugin: NOT ENABLED. The probe above ran the script directly, but Claude Code is not running any of these hooks'
jq -e '.enabledPlugins | to_entries | any(.key | startswith("core-claude@"))' "$S" >/dev/null 2>&1 \
  && echo 'core-claude plugin: ALSO ENABLED. Every tool call is judged twice and written content guarded twice; uninstall one of the two'

echo '== legacy copies (should all be absent) =='
legacy=0
for f in judge-hook.sh writing-guard.sh research-nudge.sh; do
  if [ -f ~/.claude/"$f" ]; then
    legacy=1
    echo "~/.claude/$f: PRESENT. Pre-2026-07-24 copy; retire it (setup Step 1 does this) or it may run beside the plugin's"
  fi
done
if [ -f "$S" ]; then
  for pat in judge-hook writing-guard research-nudge; do
    jq -e --arg p "$pat" '[.hooks[]?[]?.hooks[]?.command] | any(test($p))' "$S" >/dev/null 2>&1 \
      && { legacy=1; echo "settings.json: $pat still wired by path. It DOUBLE-FIRES beside the plugin hook; re-run /core:setup to strip it"; }
  done
fi
[ "$legacy" -eq 0 ] && echo 'none: hooks run only from the plugin'

echo '== judge rules =='
echo "shipped ruleset: $(jq '.rules | length' "$P/hooks/judge-rules.json" 2>/dev/null || echo 'UNREADABLE, the gate has no rules') rules (plugin-owned, updates with the plugin)"
R=~/.claude/judge-rules.json
if [ ! -f "$R" ]; then
  echo 'overlay: absent (fine: the full shipped ruleset is active)'
elif ! jq -e 'type == "object"' "$R" >/dev/null 2>&1; then
  echo 'overlay: UNPARSEABLE. It is being IGNORED, so the shipped rules are active but your local customization is not'
else
  echo "overlay: $(jq '.rules | length' "$R" 2>/dev/null || echo 0) local rule(s), only=$(jq -c '.only // []' "$R"), disable=$(jq -c '.disable // []' "$R"), override=$(jq -c '(.override // {}) | keys' "$R")"
  dupes=$(jq --slurpfile s "$P/hooks/judge-rules.json" '[.rules[]? | . as $r | select(($s[0].rules | map(.reason) | index($r.reason)) != null)] | length' "$R" 2>/dev/null || echo 0)
  [ "${dupes:-0}" -gt 0 ] && echo "overlay: contains $dupes COPY of a shipped rule. Overlay rules are evaluated first, so these silently pin the old version of any rule the plugin has since changed; re-run /core:setup Step 2 to retire them"
  bad=$(jq -r --slurpfile s "$P/hooks/judge-rules.json" '($s[0].rules | map(.id) + map(._category) | unique) as $known | [((.disable // []) + (.only // []))[] | select(. as $k | ($known | index($k)) == null)] | join(", ")' "$R" 2>/dev/null)
  [ -n "$bad" ] && echo "overlay: only/disable name unknown id or _category values that match nothing: $bad"
  badov=$(jq -r --slurpfile s "$P/hooks/judge-rules.json" '($s[0].rules | map(.id)) as $ids | [((.override // {}) | keys)[] | select(. as $k | ($ids | index($k)) == null)] | join(", ")' "$R" 2>/dev/null)
  [ -n "$badov" ] && echo "overlay: override names ids that do not ship, so those patches do nothing: $badov (override keys on rule id only, never _category)"
  both=$(jq -r '. as $o | [(($o.override // {}) | keys)[] | select(. as $k | (($o.disable // []) | index($k)) != null)] | join(", ")' "$R" 2>/dev/null)
  [ -n "$both" ] && echo "overlay: disabled AND overridden, where disable wins so the patch is dead: $both"
fi

echo '== statusline (the one file still copied) =='
if [ ! -f ~/.claude/core-hud.sh ]; then echo 'core-hud.sh: MISSING, run /core:setup'
elif diff -q "$P/statusline/core-hud.sh" ~/.claude/core-hud.sh >/dev/null 2>&1; then echo 'core-hud.sh: in sync'
else echo 'core-hud.sh: DRIFT vs the plugin. Diff before re-running setup (statuslines are often customized deliberately)'
fi
jq -e '.statusLine.command // "" | test("core-hud")' "$S" >/dev/null 2>&1 \
  && echo 'core-hud (statusLine): wired' || echo 'core-hud (statusLine): NOT WIRED'
jq -e '.permissions.defaultMode == "bypassPermissions"' "$S" >/dev/null 2>&1 \
  && echo 'bypassPermissions: on (the gate probe above is what makes this survivable)' \
  || echo 'bypassPermissions: off (posture not applied)'

# Memory is off via env vars only, in two places, and a shell export beats the
# settings block. Report both, and report whether anything was already written,
# because disabling the feature does not remove what it wrote.
for v in CLAUDE_CODE_DISABLE_AUTO_MEMORY CLAUDE_CODE_DISABLE_ORG_MEMORY; do
  ins=$(jq -r --arg v "$v" '.env[$v] // "unset"' "$S" 2>/dev/null)
  where=$(grep -l "export $v=1" ~/.zshrc ~/.bashrc 2>/dev/null | xargs -r -n1 basename | tr '\n' ',' | sed 's/,$//')
  printf '%s: settings.env=%s shell=%s\n' "$v" "$ins" "${where:+pinned in $where}${where:-unpinned}"
done
mem=$(find ~/.claude/projects -type d -name memory 2>/dev/null | head -5)
if [ -n "$mem" ]; then
  n=$(printf '%s\n' "$mem" | while read -r d; do find "$d" -type f 2>/dev/null; done | wc -l | tr -d ' ')
  echo "memory on disk: $n file(s) under $(printf '%s\n' "$mem" | wc -l | tr -d ' ') project memory dir(s); disabling does not delete these"
else
  echo 'memory on disk: none'
fi

echo '== CLAUDE.md guidelines =='
awk '/<!-- BEGIN core:guidelines -->/{f=1} f{print} /<!-- END core:guidelines -->/{f=0}' ~/.claude/CLAUDE.md 2>/dev/null \
  | diff -q - "$P/templates/claude-md.md" >/dev/null 2>&1 \
  && echo 'fenced block: in sync with the plugin template' \
  || echo 'fenced block: DRIFT or missing. Re-run /core:setup Step 4 to refresh (content outside the fences is preserved)'

echo '== jev == (key, question sets, one live /v1/models call)'
sh "$P/scripts/jev" doctor 2>&1 | sed 's/^/  /' || true
A=~/.claude/jev-audit.jsonl
if [ -f "$A" ]; then
  echo "  audit: $(wc -l < "$A" | tr -d ' ') call(s) logged; last: $(tail -n 1 "$A" | jq -c '{ts, set, ms, answers}' 2>/dev/null)"
else
  echo '  audit: no calls logged yet (~/.claude/jev-audit.jsonl absent)'
fi
Q=~/.claude/jev-questions.json
if [ ! -f "$Q" ]; then echo '  overlay: absent (fine: the shipped thresholds are active)'
elif jq -e 'type == "object"' "$Q" >/dev/null 2>&1; then echo "  overlay: thresholds $(jq -c '[(.sets // {}) | to_entries[] | {(.key): (.value.thresholds // {})}] | add // {}' "$Q")"
else echo '  overlay: UNPARSEABLE. It is being IGNORED; the shipped thresholds are active but your tuning is not'; fi

echo '== version =='
inst=$(cat ~/.claude/.core-version 2>/dev/null || echo none)
plug=$(jq -r .version "$P/.claude-plugin/plugin.json" 2>/dev/null || echo unknown)
echo "installed: $inst | plugin: $plug"
[ "$inst" = "$plug" ] || echo 'install stamp is stale relative to the plugin. Hooks and rules still update with the plugin; the stamp only tracks the settings/CLAUDE.md side, so re-run /core:setup when convenient'
```

Interpretation guide for the report you give the user:

- The GATE probe is the headline. `NOT DENYING` together with `bypassPermissions: on` is the one red-alert combination, and it is now measured by running the hook rather than inferred from a settings.json line.
- LEGACY findings are about cost and confusion, not safety: the gate still works, it just runs twice. Setup strips them.
- An overlay carrying copies of shipped rules is the quiet one to catch. Nothing looks broken, and the machine keeps enforcing a rule version the plugin replaced.
- A stale version stamp no longer implies stale hooks or rules, because those live in the plugin. Say so, rather than pushing a re-run as urgent.
- The jev section is about coverage, not safety: with no key the two Jev hooks are inert and fail open, so nothing is less guarded than under core-claude, only less measured. `key: NOT SET` means "set TYPESAFE_API_KEY in the shell environment and restart", never "re-run setup". A live probe that fails with the key set is a network or vendor issue; the hooks keep failing open until it clears.
