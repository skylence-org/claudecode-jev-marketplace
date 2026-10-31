#!/bin/sh
# check-parity: the `jev` helper ships as a byte-identical twin in every plugin
# that calls Jev (plugins install separately, so no cross-plugin import
# exists), and the load-bearing wiring phrases must be present where the
# doctrine says they are. The failure class this catches is one copy patched
# and its sibling forgotten.
set -u
cd "$(dirname "$0")/.." || exit 1
fail=0
err() { echo "parity: $*"; fail=1; }

CORE=plugins/core
ORG=plugins/herdr-agent-org

cmp -s "$CORE/scripts/jev" "$ORG/scripts/jev" || err "jev helper twins diverged: $CORE/scripts/jev vs $ORG/scripts/jev (must be byte-identical)"

need() { f=$1; shift; for p in "$@"; do grep -qF -- "$p" "$f" || err "$f missing invariant: $p"; done; }

need "$CORE/hooks/hooks.json" "judge-hook" "writing-guard" "jev-intent-gate" "jev-research-nudge"
need "$CORE/scripts/jev-questions.json" '"research-nudge"' '"deps-pin"'
need "$CORE/hooks/jev-intent-gate.sh" "deps-pin" "FAIL-OPEN" "exit 2"
need "$CORE/hooks/jev-research-nudge.sh" "research-nudge" "claude-herdr-org-lanes"
need "$CORE/skills/setup/SKILL.md" "/core:setup" "jev doctor" "jev-questions.json" "core:guidelines"
need "$CORE/skills/doctor/SKILL.md" "/core:doctor" "== jev =="
need "$CORE/templates/claude-md.md" "<!-- BEGIN core:guidelines -->"
# jev-intent-gate owns the dependency-pin judgments; a copy of either rule in
# judge-rules.json would judge every pinned install twice.
for id in deps.pinned-install deps.manifest-edit; do
  grep -qF "\"$id\"" "$CORE/hooks/judge-rules.json" && err "$CORE/hooks/judge-rules.json still ships $id (jev-intent-gate owns it)"
done
grep -qF 'research-nudge.sh' "$CORE/hooks/hooks.json" && ! grep -qF 'jev-research-nudge.sh' "$CORE/hooks/hooks.json" && err "hooks.json wires the haiku research-nudge instead of jev-research-nudge"

need "$ORG/scripts/jev-questions.json" '"tier-gauge"' '"review-gate"' "downgrade_bar" "gate_lines"
need "$ORG/scripts/dispatch-worker" "tier-gauge" "--no-gauge" "TIER-GAUGE" "ADVISOR_UP"
need "$ORG/scripts/tier-gauge" "exit 3" "ungauged" "downgrade_bar"
need "$ORG/scripts/review-gate-check" "MANDATORY-REVIEW" "WAIVABLE-UNGAUGED" "gate_lines"
need "$ORG/skills/orchestrator/SKILL.md" "TIER-GAUGE" "review-gate-check" "TIER BY BRIEF" "ACCEPT SEQUENCE" "CONTRACT, NOT A MENU"
need "$ORG/tests/conduct/run-conduct.sh" "self-test"

for f in "$CORE/scripts/jev" "$CORE/hooks/judge-hook.sh" "$CORE/hooks/writing-guard.sh" "$CORE/hooks/jev-intent-gate.sh" "$CORE/hooks/jev-research-nudge.sh" "$CORE/statusline/core-hud.sh" \
         "$ORG/scripts/jev" "$ORG/scripts/tier-gauge" "$ORG/scripts/review-gate-check" "$ORG/scripts/dispatch-worker"; do
  [ -x "$f" ] || err "$f is not executable"
done

# org-relay: one version per build. Two repos once shipped different builds
# as 1.4.1 (multi-llm-marketplace 965ec72 and this repo's df40d17), so the
# three version fields must agree, and a src/ or build.rs change against main
# without a Cargo.toml version bump fails. The base is $PARITY_BASE, else
# origin/main, else a depth-1 fetch of main (CI checks out shallow, with no
# origin/main); with no base at all the bump check is skipped, never failed.
RELAY=herdr-plugins/org-relay
cver() { sed -n 's/^version = "\(.*\)"/\1/p' | head -1; }
cv=$(cver < "$RELAY/Cargo.toml")
pv=$(cver < "$RELAY/herdr-plugin.toml")
lv=$(awk '/^name = "org-relay"$/ { getline; gsub(/version = |"/, ""); print; exit }' "$RELAY/Cargo.lock")
[ "$cv" = "$pv" ] || err "$RELAY: Cargo.toml says $cv but herdr-plugin.toml says $pv"
[ "$cv" = "$lv" ] || err "$RELAY: Cargo.toml says $cv but Cargo.lock says $lv"
base="${PARITY_BASE:-origin/main}"
if ! git rev-parse -q --verify "$base^{commit}" >/dev/null 2>&1; then
  if git fetch -q --depth=1 origin main 2>/dev/null; then base=FETCH_HEAD; else base=""; fi
fi
if [ -z "$base" ]; then
  echo "parity: org-relay version-bump check skipped (no base ref)"
elif ! git diff --quiet "$base" HEAD -- "$RELAY/src" "$RELAY/build.rs" 2>/dev/null; then
  bv=$(git show "$base:$RELAY/Cargo.toml" 2>/dev/null | cver)
  [ "$bv" != "$cv" ] || err "$RELAY/src changed against $base but Cargo.toml still says $cv: bump the crate version (one version per build)"
fi

if [ "$fail" = 0 ]; then echo "parity: OK"; else echo "parity: FAILED"; exit 1; fi
