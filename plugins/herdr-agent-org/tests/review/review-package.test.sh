#!/bin/bash
# review-package.test.sh: scripts/review-package over a throwaway repo, and
# the placeholder contract of templates/reviewer-delta-brief.md. No herdr, no
# key, no network.
#
# Run: bash plugins/herdr-agent-org/tests/review/review-package.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
RP="$PLUGIN/scripts/review-package"
T="$PLUGIN/templates/reviewer-delta-brief.md"
T1="$PLUGIN/templates/reviewer-brief.md"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP=$(mktemp -d)
SLUG="rptest-$$"
cleanup() {
  rm -rf "$TMP"
  for f in "/tmp/${SLUG}_review.diff" "/tmp/${SLUG}_review2.diff"; do [ -e "$f" ] && ls -la "$f" >/dev/null && rm -f "$f"; done
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }
rp() { OUT=$(sh "$RP" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }

# main: base; feat branches off it (f1 b.txt, later f2 c.txt); main then moves
# on (m1 main-only.txt), so a two-dot PR diff would drag main-only.txt in.
R="$TMP/repo"; git init -q -b main "$R"
c() { printf '%s\n' "$2" >"$R/$1"; git -C "$R" add "$1"; git -C "$R" commit -q -m "$3"; }
c a.txt base "base commit"
git -C "$R" checkout -q -b feat
c b.txt one "feat f1 subject"
F1=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q main
c main-only.txt moved "main m1 subject"
M1=$(git -C "$R" rev-parse HEAD)
git -C "$R" checkout -q feat
c c.txt two "feat f2 subject"

echo "--- review-package -------------------------------------------------------"
rp --slug "$SLUG" --cwd "$R" --base main --head feat
P="/tmp/${SLUG}_review.diff"
if [ $RC -eq 0 ] && [ -s "$P" ] && printf '%s' "$OUT" | grep -qF "$P" && printf '%s' "$OUT" | grep -q "$(wc -l <"$P" | tr -d ' ') lines"; then ok "whole PR: /tmp/<slug>_review.diff written, path and line count printed"; else bad "pr package" "rc=$RC out=$OUT err=$ERR"; fi
if grep -qF 'git diff --stat main...feat' "$P" && grep -qF 'git diff -U10 main...feat' "$P" && grep -qF 'git log --oneline main..feat' "$P"; then ok "whole PR: THREE dots on both diffs, two dots on the log (named in the package)"; else bad "pr dots" "$(grep '^#' "$P")"; fi
if grep -q 'b.txt' "$P" && grep -q 'c.txt' "$P" && ! grep -q 'main-only.txt' "$P" && grep -q 'feat f2 subject' "$P" && ! grep -q 'main m1 subject' "$P"; then ok "whole PR: a main that moved on contributes no file and no commit"; else bad "pr content" "$(cat "$P")"; fi
grep -q '^@@' "$P" && [ "$(grep -c '^ ' "$P")" -ge 0 ] && ok "whole PR: full -U10 diff body present" || bad "pr body" "$(cat "$P")"

rp --slug "$SLUG" --cwd "$R" --from "$F1" --to feat
P2="/tmp/${SLUG}_review2.diff"
if [ $RC -eq 0 ] && [ -s "$P2" ] && printf '%s' "$OUT" | grep -qF "$P2" && grep -qF "git diff -U10 $F1..feat" "$P2" && grep -qF "git diff --stat $F1..feat" "$P2" && grep -qF "git log --oneline $F1..feat" "$P2"; then ok "delta: /tmp/<slug>_review2.diff, two dots on the log and both diffs"; else bad "delta package" "rc=$RC out=$OUT err=$ERR head=$(grep '^#' "$P2" 2>/dev/null)"; fi
if grep -q 'c.txt' "$P2" && ! grep -q '^diff --git a/b.txt' "$P2" && grep -q 'feat f2 subject' "$P2" && ! grep -q 'feat f1 subject' "$P2"; then ok "delta: only the commits and files after --from"; else bad "delta content" "$(cat "$P2")"; fi
rp --slug "$SLUG" --cwd "$R" --from "$M1" --to feat
grep -q 'main-only.txt' "$P2" && ok "delta is a straight two-dot range (a --from off the branch shows its files; three dots would hide them)" || bad "delta two-dot" "$(cat "$P2")"

rp --slug "$SLUG" --cwd "$R" --from "$F1" --to feat --out "$TMP/custom.diff"
[ $RC -eq 0 ] && [ -s "$TMP/custom.diff" ] && printf '%s' "$OUT" | grep -qF "$TMP/custom.diff" && ok "--out overrides the package path" || bad "out" "rc=$RC out=$OUT err=$ERR"

rm -f "$P"
git -C "$R" checkout -q main
rp --slug "$SLUG" --cwd "$R" --base main --head feat
[ $RC -ne 0 ] && [ $RC -ne 2 ] && printf '%s' "$ERR" | grep -q 'HEAD' && [ ! -e "$P" ] && ok "HEAD is not --head: refused, nothing written" || bad "head moved" "rc=$RC err=$ERR"
rp --slug "$SLUG" --cwd "$R" --from "$F1" --to feat
[ $RC -ne 0 ] && [ $RC -ne 2 ] && printf '%s' "$ERR" | grep -q 'HEAD' && ok "HEAD is not --to: refused" || bad "to moved" "rc=$RC err=$ERR"
git -C "$R" checkout -q feat

rp --slug "$SLUG" --cwd "$R" --base main --head feat --from "$F1" --to feat
[ $RC -eq 2 ] && ok "both ranges at once: usage error (exit 2)" || bad "both modes" "rc=$RC"
rp --slug "$SLUG" --cwd "$R"
[ $RC -eq 2 ] && ok "no range: usage error (exit 2)" || bad "no mode" "rc=$RC"
rp --slug "$SLUG" --cwd "$R" --base main --head no-such-ref
[ $RC -eq 2 ] && ok "unresolvable ref: usage error (exit 2)" || bad "bad ref" "rc=$RC"
rp --cwd "$R" --base main --head feat
[ $RC -eq 2 ] && ok "no --slug: usage error (exit 2)" || bad "no slug" "rc=$RC"

echo "--- templates/reviewer-delta-brief.md ------------------------------------"
if [ -f "$T" ]; then
  # The line after "PLACEHOLDERS" is the fill-in list; a "KEPT AS WRITTEN"
  # line names angle-bracket tokens that are quoted command syntax.
  LIST=$(sed -n '1,/-->/p' "$T" | sed -n '/^PLACEHOLDERS/{n;p;}' | grep -o '<[^<>]*>' | sort -u)
  KEPT=$(sed -n '1,/-->/p' "$T" | grep '^KEPT AS WRITTEN' | grep -o '<[^<>]*>' | sort -u)
  BODY=$(sed '1,/-->/d' "$T")
  for p in '<slug>' '<from>' '<to>' '<round-1 report pointer>' '<orchestrator-agent>'; do
    printf '%s\n' "$LIST" | grep -qxF "$p" || bad "placeholder list" "missing $p in the top comment"
  done
  printf '%s\n' "$LIST" | grep -qxF '<orchestrator-agent>' && ok "the top comment lists the issue's placeholders" || true
  stale=""
  while IFS= read -r p; do printf '%s' "$BODY" | grep -qF "$p" || stale="$stale $p"; done <<EOF
$LIST
EOF
  [ -z "$stale" ] && ok "every listed placeholder is used in the template" || bad "stale placeholders" "$stale"
  FILLED=$BODY
  while IFS= read -r p; do FILLED=${FILLED//"$p"/FILLED}; done <<EOF
$LIST
EOF
  while IFS= read -r p; do [ -n "$p" ] && FILLED=${FILLED//"$p"/}; done <<EOF
$KEPT
EOF
  left=$(printf '%s\n' "$FILLED" | grep -o '<[^<>]*>' | sort -u | tr '\n' ' ')
  [ "$KEPT" = '<path>' ] && ok "the only KEPT token is <path> (the NEVER line's ls -la syntax)" || bad "kept list" "$KEPT"
  [ -z "$left" ] && ok "sed of the documented placeholder list leaves no <...> placeholder" || bad "unfilled" "$left"
  same=0; total=0
  for prefix in 'You are the review lane for todo' 'VERDICT, forced' 'REPORT: the full report' 'NEVER: '; do
    total=$((total + 1))
    line=$(grep -m1 "^$prefix" "$T1")
    [ -n "$line" ] && grep -qxF -- "$line" "$T" && same=$((same + 1))
  done
  [ "$same" = "$total" ] && ok "conduct, verdict, report/close-out and NEVER lines are verbatim from reviewer-brief.md ($same/$total)" || bad "verbatim blocks" "$same/$total"
  grep -q 'review2.diff' "$T" && grep -q 'CLOSED' "$T" && grep -q 'MINOR-DEFERRED' "$T" && grep -q 'STAGE 1' "$T" && grep -q 'STAGE 2' "$T" && grep -q 'review-package' "$T" && ok "template names the delta package, CLOSED, MINOR-DEFERRED, both stages, review-package" || bad "sections" "$(grep -n '' "$T" | head -5)"
else
  bad "delta template" "$T missing"
fi

echo
echo "review-package: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
