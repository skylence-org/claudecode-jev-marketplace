---
name: setup-skill
description: One-shot, no-prompt installer for the core Claude Code baseline (core-claude with TypeSafe Jev deciding the judgments). The judge-hook and jev-intent-gate (PreToolUse), writing-guard (PostToolUse) and jev-research-nudge (Stop) run FROM the plugin via its own hooks.json, so this skill installs only the core-hud statusline, writes empty ~/.claude/judge-rules.json and ~/.claude/jev-questions.json overlays, probes the Jev key with `jev doctor`, removes any legacy copy-based hook wiring, and sets the full-bypass permission posture with dynamic workflows disabled plus the core guidelines (Advisor, Decisive Thinking, Coding, Review Mindset, Writing) in the user-scope CLAUDE.md. Invoke as /core:setup on a new machine; never beside core-claude.
---

# /core:setup

Run once on a new machine. Installs the core baseline with no prompts. Every step that overwrites makes a timestamped backup first. Execute the steps in order, then report the Step 6 checklist.

All source files live under `$CLAUDE_PLUGIN_ROOT` (the root of this plugin). Run each block exactly as written.

> Posture note: this skill sets `permissions.defaultMode` to `bypassPermissions`. Per-call permission prompts go away; the judge-hook (PreToolUse) plus its rules become the safety gate. PreToolUse hooks still run under bypass mode, so the gate stays live.

## Step 1: statusline, and retire any legacy hook copies (backup first)

The three hooks are registered by the plugin itself (`hooks/hooks.json`, paths under `${CLAUDE_PLUGIN_ROOT}`), so they update whenever the plugin does and are NOT copied here. Only the statusline is still a copy, because `settings.json.statusLine` takes a plain command path.

Older installs have copies at `~/.claude/{judge-hook,writing-guard,research-nudge}.sh` wired by absolute path in settings.json. Leaving them in place would run every hook TWICE (two judges, and two `claude -p` spawns on an escalate rule), so they are backed up and removed here while Step 3 removes their wiring.

```bash
mkdir -p ~/.claude
ts=$(date +%Y%m%d%H%M%S)
cp "$CLAUDE_PLUGIN_ROOT/statusline/core-hud.sh" ~/.claude/core-hud.sh.new
[ -f ~/.claude/core-hud.sh ] && cp ~/.claude/core-hud.sh ~/.claude/core-hud.sh.bak.$ts
mv ~/.claude/core-hud.sh.new ~/.claude/core-hud.sh
chmod +x ~/.claude/core-hud.sh

for f in judge-hook.sh writing-guard.sh research-nudge.sh; do
  if [ -f ~/.claude/$f ]; then
    mv ~/.claude/$f ~/.claude/$f.retired.$ts
    echo "retired legacy copy ~/.claude/$f -> $f.retired.$ts (the plugin now owns this hook)"
  fi
done
```

## Step 2: write the judge-rules OVERLAY (only if absent)

The complete ruleset ships in `$CLAUDE_PLUGIN_ROOT/hooks/judge-rules.json` and arrives with every plugin update. `~/.claude/judge-rules.json` is now an OVERLAY and starts EMPTY. Add rules with `rules`, narrow to a subset with `only`, drop shipped ones with `disable`, or change one in place with `override` (a rule id mapped to a partial rule, shallow-merged over the shipped one). `only`, `disable` and the `override` keys are all named by a shipped rule's stable `id`, and `only`/`disable` also accept a `_category`.

An existing file is left alone if it is already an overlay. A pre-overlay install instead has a full COPY of the shipped ruleset there, which still works and is also a trap: overlay rules are evaluated FIRST, so a stale copy silently reinstates the old version of any rule the plugin has since changed. Those copies are detected by matching each local rule's `reason` against the shipped set (a pre-overlay copy predates the `id` field, so ids cannot be the test), retired to a backup, and anything genuinely local is kept.

```bash
RULES=~/.claude/judge-rules.json
SHIPPED="$CLAUDE_PLUGIN_ROOT/hooks/judge-rules.json"
OVERLAY_DOC="Local overlay for the core judge. The complete ruleset ships with the plugin; this file only customizes it. Keys: rules (local additions, evaluated first), only (keep just these shipped ids or _category values), disable (drop these, applied after only), override (rule id -> partial rule, shallow-merged over the shipped rule in place so it keeps its position). Empty means the shipped ruleset is fully active."
if [ ! -f "$RULES" ]; then
  jq -n --arg c "$OVERLAY_DOC" '{_comment: $c, rules: [], only: [], disable: [], override: {}}' > "$RULES"
  echo "wrote empty overlay $RULES"
else
  # `. as $r` first: inside index(...) the input is the mapped array, so a bare
  # .reason there reads the array, not the rule, and jq errors out.
  dupes=$(jq --slurpfile s "$SHIPPED" '[.rules[]? | . as $r | select(($s[0].rules | map(.reason) | index($r.reason)) != null)] | length' "$RULES" 2>/dev/null || echo 0)
  if [ "${dupes:-0}" -gt 0 ]; then
    cp "$RULES" "$RULES.fullcopy.bak.$(date +%Y%m%d%H%M%S)"
    jq --slurpfile s "$SHIPPED" --arg c "$OVERLAY_DOC" \
      '{_comment: $c,
        rules: [.rules[]? | . as $r | select(($s[0].rules | map(.reason) | index($r.reason)) == null)],
        only: (.only // []), disable: (.disable // []), override: (.override // {})}' \
      "$RULES" > "$RULES.tmp" && mv "$RULES.tmp" "$RULES"
    echo "retired $dupes copied shipped rule(s) from $RULES (backup: .fullcopy.bak.*); the plugin supplies those now, $(jq '.rules | length' "$RULES") local rule(s) kept"
  else
    echo "$RULES already an overlay, left as-is"
  fi
fi
jq -e 'type == "object"' "$RULES" >/dev/null && echo "overlay parses: OK" || echo "overlay is NOT valid JSON. Fix it; until then the hook ignores the overlay and runs the shipped rules alone"
```

## Step 2b: Jev, write the question overlay (only if absent) and probe the key

Every Jev question and threshold ships in `$CLAUDE_PLUGIN_ROOT/scripts/jev-questions.json` and arrives with every plugin update. `~/.claude/jev-questions.json` is an OVERLAY of the same shape, recursively merged over the shipped file; it starts EMPTY and is where thresholds get tuned per box after reading `~/.claude/jev-audit.jsonl`. The key is never written by this skill and never pasted into a chat. `jev` looks for it in three places, first hit wins: the `TYPESAFE_API_KEY` environment variable; the key file `~/.config/typesafe/api_key` (one line, `chmod 600`; `TYPESAFE_API_KEY_FILE` overrides the path); on macOS a Keychain generic password with service `TYPESAFE_API_KEY`. The key file is the recommended place on every OS because every process of the operator's user reads it, including herdr split panes and daemon-routed shell calls, which do not inherit a shell's environment. Without a key both Jev hooks are fail-open and inert; everything else in this baseline works exactly as core-claude does.

```bash
Q=~/.claude/jev-questions.json
if [ ! -f "$Q" ]; then
  jq -n '{_comment: "Local overlay for the core question sets. Same shape as the plugin'\''s scripts/jev-questions.json ({sets: {<set>: {thresholds: {...}, questions: {...}}}}), recursively merged over it. Empty means the shipped questions and thresholds are fully active. Tune thresholds here after reading ~/.claude/jev-audit.jsonl; never edit the plugin file.", sets: {}}' > "$Q"
  echo "wrote empty overlay $Q"
elif jq -e 'type == "object"' "$Q" >/dev/null 2>&1; then
  echo "$Q already present, left as-is"
else
  echo "$Q is NOT valid JSON: it is ignored until fixed (the shipped thresholds stay active)"
fi
sh "$CLAUDE_PLUGIN_ROOT/scripts/jev" doctor \
  || echo 'jev: key missing or the API unreachable. The two Jev hooks stay inert (fail-open) until a key is in place (recommended: one line in ~/.config/typesafe/api_key, chmod 600) and Claude Code is restarted; judge-hook, writing-guard, HUD and guidelines are unaffected.'
```

## Step 3: wire settings.json (backup first; idempotent)

Sets the statusline, the full-bypass posture, `disableWorkflows: true`, `awaySummaryEnabled: false` (disables the session recap), and `promptSuggestionEnabled: false` (no inline ghost text in the input box; it also reads as typed text to any agent classifying a pane's input line, so org send-safety checks get cleaner without it). The settings key is not respected in some builds (anthropics/claude-code#15709), so the undocumented env var `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false` is also pinned in `env` and the shell profile alongside it. Adaptive thinking and Claude's auto-memory have no settings key, so they go in `env` AND are pinned in the shell profile (next block). It also STRIPS the legacy copy-based hook entries: the plugin registers those three hooks itself now, and leaving a settings.json entry beside it runs each hook twice. Existing unrelated hooks and the deny list are preserved.

```bash
SETTINGS=~/.claude/settings.json
[ -f "$SETTINGS" ] || echo '{}' > "$SETTINGS"
cp "$SETTINGS" "$SETTINGS.bak.$(date +%Y%m%d%H%M%S)"

tmp=$(mktemp)
jq '
  .statusLine = {type: "command", command: "bash ~/.claude/core-hud.sh"}
  | .disableWorkflows = true
  | .awaySummaryEnabled = false
  | .promptSuggestionEnabled = false
  | .env = (.env // {})
  | .env.CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING = "1"
  | .env.CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION = "false"
  | .env.CLAUDE_CODE_DISABLE_AUTO_MEMORY = "1"
  | .env.CLAUDE_CODE_DISABLE_ORG_MEMORY = "1"
  | .permissions = (.permissions // {})
  | .permissions.defaultMode = "bypassPermissions"
  | .hooks = (.hooks // {})
  | .hooks.PreToolUse = ((.hooks.PreToolUse // []) | map(select(((.hooks // []) | map(.command) | join(" ")) | test("judge-hook.sh") | not)))
  | .hooks.PostToolUse = ((.hooks.PostToolUse // []) | map(select(((.hooks // []) | map(.command) | join(" ")) | test("writing-guard.sh") | not)))
  | .hooks.Stop = ((.hooks.Stop // []) | map(select(((.hooks // []) | map(.command) | join(" ")) | test("research-nudge.sh") | not)))
  | .hooks |= with_entries(select(.value | length > 0))
' "$SETTINGS" > "$tmp" && mv "$tmp" "$SETTINGS"

# Adaptive thinking and auto-memory have no settings.json *key*, only env vars.
# Memory takes TWO: CLAUDE_CODE_DISABLE_AUTO_MEMORY covers the per-project
# auto-memory that writes under ~/.claude/projects/<project>/memory/, and
# CLAUDE_CODE_DISABLE_ORG_MEMORY covers the org-level bank. Both are needed for
# "off", and neither is discoverable from `claude --help`: they were found in
# the shipped binary's strings, alongside the --bare description which lists
# auto-memory among the things that mode skips.
# The settings `env` block is read at
# startup but has had reliability bugs (anthropics/claude-code #5202, #8500,
# #20112), and a shell export wins over it regardless, so also pin it in the
# shell profile. Idempotent: a fenced block, replaced on re-run.
PROFILE="$HOME/.zshrc"
case "${SHELL:-}" in *bash) PROFILE="$HOME/.bashrc" ;; esac
touch "$PROFILE"
cp "$PROFILE" "$PROFILE.bak.$(date +%Y%m%d%H%M%S)"
ptmp=$(mktemp)
awk '/# >>> core:env >>>/{s=1} !s{print} /# <<< core:env <<</{s=0; next}' "$PROFILE" > "$ptmp"
{ cat "$ptmp"; printf '\n# >>> core:env >>>\nexport CLAUDE_CODE_DISABLE_ADAPTIVE_THINKING=1\nexport CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false\nexport CLAUDE_CODE_DISABLE_AUTO_MEMORY=1\nexport CLAUDE_CODE_DISABLE_ORG_MEMORY=1\n# <<< core:env <<<\n'; } > "$PROFILE"
rm -f "$ptmp"
echo "settings.json wired: core-hud, bypassPermissions, disableWorkflows, recap off, prompt suggestions off (settings key + CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false), adaptive-thinking off, memory off; legacy copy-based hook entries stripped (the plugin registers them)"
echo "shell profile pinned: adaptive-thinking + prompt-suggestion + auto-memory + org-memory disabled ($PROFILE)"

echo '--- verify ---'
jq -e '.permissions.defaultMode == "bypassPermissions"' "$SETTINGS" >/dev/null && echo 'defaultMode: OK' || echo 'defaultMode: FAILED'
# The gate is what makes bypassPermissions survivable, so verify it by RUNNING
# Verify the gate by RUNNING it, not by looking for a settings.json line that no
# longer exists. This is the whole chain in one call: plugin hook script, plugin
# ruleset, and the overlay on top of it.
# The payload comes from a FILE on purpose. A command line that spells out a
# privilege word is denied by the very rule it is probing, so writing the JSON
# inline here would make this step unrunnable once the gate is live.
cat "$CLAUDE_PLUGIN_ROOT/hooks/probe-payload.json" \
  | bash "$CLAUDE_PLUGIN_ROOT/hooks/judge-hook.sh" >/dev/null 2>&1
[ $? -eq 2 ] \
  && echo 'judge-hook: LIVE (denied a gated command end to end)' \
  || echo 'judge-hook: NOT DENYING. Do not run under bypassPermissions until this is fixed. Check that core is enabled in settings.json enabledPlugins, that jq is installed, and that your overlay does not disable privilege.sudo.'
jq -e '.enabledPlugins | to_entries | any(.key | startswith("core@"))' ~/.claude/settings.json >/dev/null \
  && echo 'core plugin: enabled (its hooks.json registers judge-hook, jev-intent-gate, writing-guard, jev-research-nudge)' \
  || echo 'core plugin: NOT enabled. None of the four hooks will run'
jq -e '.enabledPlugins | to_entries | any(.key | startswith("core-claude@"))' ~/.claude/settings.json >/dev/null 2>&1 \
  && echo 'core-claude plugin: ALSO ENABLED. Its judge-hook and writing-guard fire beside this plugin'"'"'s on every call; uninstall it (/plugin uninstall core-claude@multi-llm-marketplace)' \
  || true
```

## Step 4: write the CLAUDE.md guidelines (backup first; idempotent; cross-checked)

The canonical guidelines (Advisor, Decisive Thinking, Coding, Review Mindset, Writing) live in `$CLAUDE_PLUGIN_ROOT/templates/claude-md.md`, fenced by `<!-- BEGIN core:guidelines -->` and `<!-- END core:guidelines -->`. This replaces a prior fenced block if present, otherwise appends one. Content outside the fences is left alone.

```bash
CLAUDE_MD=~/.claude/CLAUDE.md
TEMPLATE="$CLAUDE_PLUGIN_ROOT/templates/claude-md.md"
touch "$CLAUDE_MD"
cp "$CLAUDE_MD" "$CLAUDE_MD.bak.$(date +%Y%m%d%H%M%S)"

tmp=$(mktemp)
awk '
  /<!-- BEGIN core:guidelines -->/ {skip=1}
  !skip {print}
  /<!-- END core:guidelines -->/ {skip=0; next}
' "$CLAUDE_MD" > "$tmp"

# Collapse trailing blank lines to exactly one separator, then append the template.
awk '{ if (NF==0) { blanks++ } else { while (blanks>0) { print ""; blanks-- }; print } }' "$tmp" > "$CLAUDE_MD"
printf '\n' >> "$CLAUDE_MD"
cat "$TEMPLATE" >> "$CLAUDE_MD"
rm -f "$tmp"
echo "CLAUDE.md guidelines section refreshed"

# Cross-check: the installed fenced block must match the shipped example verbatim.
installed=$(awk '/<!-- BEGIN core:guidelines -->/{f=1} f{print} /<!-- END core:guidelines -->/{f=0}' "$CLAUDE_MD")
if [ "$installed" = "$(cat "$TEMPLATE")" ]; then
  echo "CLAUDE.md guidelines: in sync with the shipped example"
else
  echo "CLAUDE.md guidelines: DRIFT vs the shipped example — re-run /core:setup to refresh"
fi
```

## Step 5: stamp the installed version

```bash
jq -r .version "$CLAUDE_PLUGIN_ROOT/.claude-plugin/plugin.json" > ~/.claude/.core-version
echo "stamped ~/.claude/.core-version: $(cat ~/.claude/.core-version)"
```

## Step 6: summary

Print this checklist, substituting the seeded/existing state for judge-rules and the actual verify results from Step 3:

```
core:setup
----------
plugin hooks                   judge-hook, jev-intent-gate, writing-guard, jev-research-nudge run from ${CLAUDE_PLUGIN_ROOT} (update with the plugin; nothing copied)
~/.claude/jev-questions.json   empty overlay written | existing overlay kept
Jev key                        set via env | file | keychain, jev doctor live | NOT SET (both Jev hooks inert, fail-open; put it in ~/.config/typesafe/api_key, chmod 600, and restart)
~/.claude/core-hud.sh          installed (statusline; the one file still copied)
~/.claude/judge-rules.json     empty overlay written | existing overlay kept | full copy retired to .fullcopy.bak
~/.claude/*.sh.retired.*       legacy hook copies retired, if any were present
~/.claude/settings.json        wired + VERIFIED (bypassPermissions, disableWorkflows, recap off, prompt suggestions off via settings key and CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false, adaptive-thinking off, auto-memory + org-memory off, legacy hook entries stripped, judge-hook proven live by a real deny)
~/.zshrc | ~/.bashrc           pinned CLAUDE_CODE_DISABLE_{ADAPTIVE_THINKING,AUTO_MEMORY,ORG_MEMORY}=1 and CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false (shell beats the settings env block)
~/.claude/CLAUDE.md            guidelines written + cross-checked against the shipped example
~/.claude/.core-version stamped
```

Then tell the user: restart Claude Code for the plugin hooks and statusline to take effect, and that `/core:doctor` re-checks all of this read-only at any time. If Step 1 retired any legacy copies, mention that the judge now updates with the plugin and no longer needs a re-run of this skill to pick up rule changes.
