#!/bin/sh
# SessionStart hook, two events, one contract (soloterm #38, backported).
#
# startup/resume: prime the role-skill contract before the first beat. A
# dispatch pointer names the role skill, but a pointer is prose a model can
# read past, and a role that never invoked its skill is not running under it.
#
# compact: compaction keeps facts and drops conduct. The role skill's text is
# the first thing a summary evicts, the decay is self-invisible to the
# degraded agent, and a half-remembered skill is exactly where clauses go
# optional.
#
# Herdr has no per-worker env marker the way Solo has SOLO_PROCESS_ID: every
# pane carries HERDR_ENV=1, orchestrator and worker alike, so this arms for
# any Herdr-managed Claude session (or any session that dispatched).
# Over-arming costs one paragraph that no-ops in a session with no org role.
command -v jq >/dev/null 2>&1 || exit 0
input=$(cat)
sid=$(printf '%s' "$input" | jq -r '.session_id // empty')
src=$(printf '%s' "$input" | jq -r '.source // empty')
if [ "${HERDR_ENV:-}" != "1" ] && { [ -z "$sid" ] || [ ! -f "/tmp/claude-herdr-org-lanes-$sid" ]; }; then
  exit 0
fi

if [ "$src" = "compact" ]; then
  cat <<'EOF'
ORG CONDUCT REFRESH (compaction just ran; Herdr substrate). If you hold no
agent-org role in this session, ignore this. Otherwise: the summary you now
run on keeps facts, not conduct, and the skill did not become advisory
because you compacted; it is still the contract you are under, in full (L0).
Before the next org action: (1) re-invoke your role skill (orchestrator;
herdr-worker or replacer if you were dispatched; the herdr skill for the
control surface); (2) re-ANCHOR from durable state, meaning board list plus
herdr agent list plus herdr pane list plus waker-ctl list. The board is truth
and the summary is hearsay, so re-verify any claim it carries before acting
on it; (3) satisfy L6 for every still-working worker you own: a
waker-registered lane rings you, anything else needs its fallback
`herdr agent wait` re-armed, because a missed re-arm right after compaction
is the signature of conduct that did not survive; (4) confirm HERDR_ENV=1
still holds.
EOF
else
  cat <<'EOF'
ORG CONDUCT PRIME (this session runs inside a Herdr-managed pane): if your
first message is a dispatch brief or pointer, invoke the role skill it names
(herdr-worker; replacer; orchestrator if you are the conductor) BEFORE your
first org action. A pointer is prose a model can read past, and a role that
never invoked its skill is not running under it. That skill is a CONTRACT,
not a menu (L0): it binds in full, every clause, until this session ends,
and the clauses that read like overhead are the ones other roles are
counting on. Skipping, deferring, or substituting a step is a deviation,
declared where the org can see it ([LAW-FRICTION] as the orchestrator,
[CONDUCT] as a worker), never dropped silently. Holding no org role in this
session? Ignore this.
EOF
fi
exit 0
