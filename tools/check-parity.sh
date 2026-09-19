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

CORE=plugins/jev-core
ORG=plugins/herdr-agent-org-jev

cmp -s "$CORE/scripts/jev" "$ORG/scripts/jev" || err "jev helper twins diverged: $CORE/scripts/jev vs $ORG/scripts/jev (must be byte-identical)"

need() { f=$1; shift; for p in "$@"; do grep -qF -- "$p" "$f" || err "$f missing invariant: $p"; done; }

need "$CORE/hooks/hooks.json" "jev-intent-gate" "jev-research-nudge"
need "$CORE/scripts/jev-questions.json" '"research-nudge"' '"deps-pin"'
need "$CORE/hooks/jev-intent-gate.sh" "deps-pin" "FAIL-OPEN" "exit 2"
need "$CORE/hooks/jev-research-nudge.sh" "research-nudge" "claude-herdr-org-lanes"

need "$ORG/scripts/jev-questions.json" '"tier-gauge"' '"review-gate"' "downgrade_bar" "gate_lines"
need "$ORG/scripts/dispatch-worker" "tier-gauge" "--no-gauge" "TIER-GAUGE" "ADVISOR_UP"
need "$ORG/scripts/tier-gauge" "exit 3" "ungauged" "downgrade_bar"
need "$ORG/scripts/review-gate-check" "MANDATORY-REVIEW" "WAIVABLE-UNGAUGED" "gate_lines"
need "$ORG/skills/orchestrator/SKILL.md" "TIER-GAUGE" "review-gate-check" "TIER BY BRIEF" "ACCEPT SEQUENCE" "CONTRACT, NOT A MENU"
need "$ORG/tests/conduct/run-conduct.sh" "self-test"

for f in "$CORE/scripts/jev" "$ORG/scripts/jev" "$ORG/scripts/tier-gauge" "$ORG/scripts/review-gate-check" "$ORG/scripts/dispatch-worker"; do
  [ -x "$f" ] || err "$f is not executable"
done

if [ "$fail" = 0 ]; then echo "parity: OK"; else echo "parity: FAILED"; exit 1; fi
