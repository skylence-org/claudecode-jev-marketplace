#!/bin/bash
# integration-gate.test.sh: scripts/integration-gate over throwaway git repos
# (a bare "origin" plus a clone per case). No herdr, no relay daemon, no key:
# relay-ctl is a stub that records its argv, and PATH is built explicitly so
# the box's real relay-ctl can never be reached.
#
# Run: bash plugins/herdr-agent-org/tests/gate/integration-gate.test.sh
set -uo pipefail

HERE=$(cd "$(dirname "$0")" && pwd)
PLUGIN=$(cd "$HERE/../.." && pwd)
IG="$PLUGIN/scripts/integration-gate"

command -v git >/dev/null 2>&1 || { echo "SKIP: git not installed"; exit 0; }

TMP=$(mktemp -d)
SLUG="gatetest-$$"
cleanup() {
  rm -rf "$TMP"
  # Only this run's logs: list them, then remove exactly those.
  for f in /tmp/gate_"${SLUG}"_*.log; do [ -e "$f" ] && ls -la "$f" >/dev/null && rm -f "$f"; done
}
trap cleanup EXIT
export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export HERDR_ORG_ROOT="$TMP/org"
sh "$PLUGIN/scripts/board" init "$HERDR_ORG_ROOT" >/dev/null 2>&1
printf 'gate lane\n' >"$TMP/brief.md"
sh "$PLUGIN/scripts/board" create "$SLUG" --title "gate" --body-file "$TMP/brief.md" >/dev/null 2>&1

PASS=0; FAIL=0
ok()  { PASS=$((PASS + 1)); printf 'ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL %s\n     %s\n' "$1" "$2"; }

STUBBIN="$TMP/bin"; mkdir -p "$STUBBIN"
cat >"$STUBBIN/relay-ctl" <<EOF
#!/bin/sh
printf '%s\n' "\$*" >>"$TMP/relay.log"
echo '{"id":1,"live_await":true}'
EOF
chmod +x "$STUBBIN/relay-ctl"
BASEPATH="$(dirname "$(command -v git)"):/usr/bin:/bin"

# mkrepos NAME: bare origin with main (a.txt), a seed clone to move main with,
# and the lane clone on branch feat (b.txt added).
mkrepos() {
  O="$TMP/$1.git"; S="$TMP/$1-seed"; C="$TMP/$1"
  git init -q --bare -b main "$O"
  git clone -q "$O" "$S" 2>/dev/null
  git -C "$S" checkout -q -b main 2>/dev/null || true
  printf 'line one\n' >"$S/a.txt"; git -C "$S" add a.txt; git -C "$S" commit -q -m base; git -C "$S" push -q origin main 2>/dev/null
  git clone -q "$O" "$C" 2>/dev/null
  git -C "$C" checkout -q -b feat
  printf 'feature\n' >"$C/b.txt"; git -C "$C" add b.txt; git -C "$C" commit -q -m feature
}
# move_main NAME FILE CONTENT: commit on main in the seed clone and push.
move_main() { printf '%s\n' "$3" >"$TMP/$1-seed/$2"; git -C "$TMP/$1-seed" add "$2"; git -C "$TMP/$1-seed" commit -q -m "main moved: $2"; git -C "$TMP/$1-seed" push -q origin main 2>/dev/null; }
commit_in() { printf '%b' "$3" >"$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -q -m "add $2"; }
snap() { printf '%s %s %s' "$(git -C "$1" rev-parse HEAD)" "$(git -C "$1" symbolic-ref -q HEAD || echo detached)" "$(git -C "$1" status --porcelain | tr '\n' ';')"; }
ig() { OUT=$(PATH="$STUBBIN:$BASEPATH" sh "$IG" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
ig_norelay() { OUT=$(PATH="$BASEPATH" sh "$IG" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
merged_of() { printf '%s\n' "$OUT" | sed -n 's/^GATE-DONE .* merged=\([^ ]*\) .*/\1/p'; }

echo "--- integration-gate ---------------------------------------------------"

mkrepos r1
TIP=$(git -C "$TMP/r1" rev-parse HEAD); before=$(snap "$TMP/r1")
ig --slug "$SLUG" --cwd "$TMP/r1" --cmd true --cmd "test -f b.txt"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^true rc=0$' && printf '%s' "$OUT" | grep -q '^test -f b.txt rc=0$' && printf '%s' "$OUT" | grep -q "^GATE-DONE $SLUG tip=$TIP merged=none failed=0 known=0$" && [ "$(snap "$TMP/r1")" = "$before" ]; then ok "clean pass: rc lines, GATE-DONE merged=none, exit 0, tree untouched"; else bad "clean pass" "rc=$RC out=$OUT err=$ERR"; fi
[ -e "/tmp/gate_${SLUG}_1.log" ] && [ -e "/tmp/gate_${SLUG}_2.log" ] && ok "each command logged to /tmp/gate_<slug>_<n>.log" || bad "logs" "$(ls /tmp/gate_"${SLUG}"_* 2>&1)"

: >"$TMP/r1/.skyrift-workspace"
ig --slug "$SLUG" --cwd "$TMP/r1" --cmd true
[ $RC -eq 0 ] && ok "an untracked file (.skyrift-workspace) does not block the gate" || bad "untracked" "rc=$RC err=$ERR"
rm -f "$TMP/r1/.skyrift-workspace"

ig --slug "$SLUG" --cwd "$TMP/r1" --cmd 'printf "ok 1\nnot ok 2 - widget\n--- FAIL: TestX (0.00s)\n--- FAIL: TestX (0.00s)\npanic: boom\nnoise\n"; exit 1' --cmd true
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q ' rc=1$' && [ "$(printf '%s\n' "$OUT" | grep -c -- '^  --- FAIL: TestX')" = 1 ] && printf '%s' "$OUT" | grep -q '^  not ok 2 - widget' && printf '%s' "$OUT" | grep -q '^  panic: boom' && ! printf '%s' "$OUT" | grep -q '^  noise' && printf '%s' "$OUT" | grep -q 'failed=1 known=0$' && [ "$(snap "$TMP/r1")" = "$before" ]; then ok "failing command: exit 1, distinct FAIL/panic/not ok lines named, failed=1"; else bad "failing" "rc=$RC out=$OUT err=$ERR"; fi

ig --slug "$SLUG" --cwd "$TMP/r1" --cmd 'echo "--- FAIL: TestFlaky (1.00s)"; exit 1' --known-fail 'TestFlaky'
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'TestFlaky' && printf '%s' "$OUT" | grep -q 'failed=0 known=1$'; then ok "--known-fail: a named failure is reported, not counted (exit 0)"; else bad "known-fail" "rc=$RC out=$OUT err=$ERR"; fi
ig --slug "$SLUG" --cwd "$TMP/r1" --cmd 'echo "--- FAIL: TestFlaky (1.00s)"; echo "--- FAIL: TestReal (0.01s)"; exit 1' --known-fail 'TestFlaky'
if [ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'TestReal' && printf '%s' "$OUT" | grep -q 'failed=1 known=1$'; then ok "--known-fail: one unknown failure beside a known one still fails"; else bad "known+real" "rc=$RC out=$OUT"; fi
ig --slug "$SLUG" --cwd "$TMP/r1" --cmd 'echo "compile error"; exit 2' --known-fail 'TestFlaky'
[ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'failed=1' && ok "a failing command with no FAIL line is never known" || bad "no fail line" "rc=$RC out=$OUT"

echo "--- default commands ---------------------------------------------------"
mkrepos r2
commit_in "$TMP/r2" Makefile 'check:\n\techo checked\ntest:\n\techo tested\n'
ig --slug "$SLUG" --cwd "$TMP/r2"
if [ $RC -eq 0 ] && printf '%s\n' "$OUT" | grep -q '^make check rc=0$' && printf '%s\n' "$OUT" | sed -n '/^make check rc=/,$p' | grep -q '^make test rc=0$'; then ok "no .herdr-gate: make check then make test"; else bad "make default" "rc=$RC out=$OUT err=$ERR"; fi
commit_in "$TMP/r2" .herdr-gate '# gate commands\n\ntest -f b.txt\necho from-gate-file # trailing\n'
ig --slug "$SLUG" --cwd "$TMP/r2"
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q '^test -f b.txt rc=0$' && printf '%s' "$OUT" | grep -q '^echo from-gate-file # trailing rc=0$' && ! printf '%s' "$OUT" | grep -q 'make '; then ok ".herdr-gate: one command per line, # comment lines and blanks skipped"; else bad "gate file" "rc=$RC out=$OUT err=$ERR"; fi

echo "--- main moved -----------------------------------------------------------"
mkrepos r3
commit_in "$TMP/r3" .herdr-gate 'test -f main-only.txt\n'
move_main r3 main-only.txt "from main"
TIP=$(git -C "$TMP/r3" rev-parse HEAD); before=$(snap "$TMP/r3")
ig --slug "$SLUG" --cwd "$TMP/r3"
M=$(merged_of)
if [ $RC -eq 0 ] && [ -n "$M" ] && [ "$M" != none ] && printf '%s' "$OUT" | grep -q '^test -f main-only.txt rc=0$' && printf '%s' "$OUT" | grep -q "tip=$TIP "; then ok "main moved, clean merge: the gate ran on the merged tree (a main-only file was present)"; else bad "merge ran" "rc=$RC out=$OUT err=$ERR"; fi
if [ -n "$M" ] && [ "$M" != none ] && [ "$(snap "$TMP/r3")" = "$before" ] && [ ! -e "$TMP/r3/.git/MERGE_HEAD" ] && [ -z "$(git -C "$TMP/r3" branch -a --contains "$M" 2>/dev/null)" ] && [ ! -e "$TMP/r3/main-only.txt" ]; then ok "main moved: tip, branch and tree restored, the merge reachable from no branch"; else bad "merge restore" "M=$M snap=$(snap "$TMP/r3") before=$before contains=$(git -C "$TMP/r3" branch -a --contains "$M" 2>&1)"; fi
git -C "$TMP/r3" checkout -q --detach
before=$(snap "$TMP/r3")
ig --slug "$SLUG" --cwd "$TMP/r3"
[ $RC -eq 0 ] && [ "$(snap "$TMP/r3")" = "$before" ] && ok "detached original HEAD: restored detached at the same SHA" || bad "detached restore" "rc=$RC snap=$(snap "$TMP/r3") before=$before"
git -C "$TMP/r3" checkout -q feat
ig --slug "$SLUG" --cwd "$TMP/r3" --cmd 'test -f main-only.txt; exit 1'
[ $RC -eq 1 ] && [ "$(git -C "$TMP/r3" symbolic-ref -q HEAD)" = refs/heads/feat ] && [ ! -e "$TMP/r3/main-only.txt" ] && ok "a failing command on the merged tree: tip still restored" || bad "fail restore" "rc=$RC out=$OUT"

mkrepos r4
printf 'line from feat\n' >"$TMP/r4/a.txt"; git -C "$TMP/r4" commit -q -am "feat edits a"
move_main r4 a.txt "line from main"
before=$(snap "$TMP/r4")
ig --slug "$SLUG" --cwd "$TMP/r4" --cmd true
if [ $RC -eq 3 ] && printf '%s' "$OUT" | grep -q 'MERGE-CONFLICT' && [ "$(snap "$TMP/r4")" = "$before" ] && [ ! -e "$TMP/r4/.git/MERGE_HEAD" ] && ! printf '%s' "$OUT" | grep -q '^true rc='; then ok "main moved with a conflict: exit 3, MERGE-CONFLICT, HEAD and tree exactly as before, nothing run"; else bad "conflict" "rc=$RC out=$OUT err=$ERR snap=$(snap "$TMP/r4") before=$before"; fi

echo "--- notify / comment / usage --------------------------------------------"
: >"$TMP/relay.log"
ig --slug "$SLUG" --cwd "$TMP/r1" --cmd 'exit 1' --notify orch-x
R=$(cat "$TMP/relay.log")
if [ $RC -eq 1 ] && printf '%s' "$R" | grep -q '^send ' && printf '%s' "$R" | grep -q -- '--to orch-x' && printf '%s' "$R" | grep -q -- '--kind job' && printf '%s' "$R" | grep -q "$SLUG" && printf '%s' "$R" | grep -q 'rc=1'; then ok "--notify: relay-ctl send --to <agent> --kind job, body names slug and rc"; else bad "notify" "rc=$RC relay=$R err=$ERR"; fi
ig_norelay --slug "$SLUG" --cwd "$TMP/r1" --cmd true --notify orch-x
[ $RC -eq 0 ] && printf '%s' "$ERR" | grep -q 'relay-ctl' && printf '%s' "$OUT" | grep -q '^GATE-DONE' && ok "--notify with no relay-ctl on PATH: warns only, exit unchanged" || bad "no relay-ctl" "rc=$RC out=$OUT err=$ERR"
ig --slug "$SLUG" --cwd "$TMP/r1" --cmd true --comment
sh "$PLUGIN/scripts/board" get "$SLUG" | grep -q "\[GATE $SLUG rc=0\]" && ok "--comment: one-line [GATE <slug> rc=N] filed on the todo" || bad "comment" "$(sh "$PLUGIN/scripts/board" get "$SLUG" | tail -3)"

ig --cwd "$TMP/r1" --cmd true
[ $RC -eq 2 ] && ok "no --slug: usage error (exit 2)" || bad "no slug" "rc=$RC"
ig --slug "$SLUG" --cwd "$TMP" --cmd true
[ $RC -eq 2 ] && ok "--cwd not a git tree: usage error (exit 2)" || bad "not git" "rc=$RC"
ig --slug "$SLUG" --cwd "$TMP/r1" --base origin/no-such --cmd true
[ $RC -eq 2 ] && ok "unresolvable --base: usage error (exit 2)" || bad "bad base" "rc=$RC err=$ERR"
printf 'dirty\n' >>"$TMP/r1/b.txt"
ig --slug "$SLUG" --cwd "$TMP/r1" --cmd true
[ $RC -eq 2 ] && grep -q dirty "$TMP/r1/b.txt" && ok "tracked modifications: refused (exit 2), working tree untouched" || bad "dirty" "rc=$RC err=$ERR"

echo
echo "integration-gate: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
