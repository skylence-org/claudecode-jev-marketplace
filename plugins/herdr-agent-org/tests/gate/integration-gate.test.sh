#!/bin/bash
# integration-gate.test.sh: scripts/integration-gate over throwaway git repos
# (a bare "origin" plus a clone per case). No herdr, no relay daemon, no key:
# relay-ctl is a stub that records its argv, and PATH is built explicitly so
# the box's real relay-ctl can never be reached.
#
# Run: bash plugins/herdr-agent-org/tests/gate/integration-gate.test.sh
# IG_SH=dash (or bash) runs the gate under that shell instead of sh; the
# hangup case always runs under dash when it is installed (dash runs no EXIT
# trap on SIGHUP, so it is the shell that proves the HUP trap).
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
IG_SH=${IG_SH:-sh}
ig() { OUT=$(PATH="$STUBBIN:$BASEPATH" $IG_SH "$IG" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
ig_norelay() { OUT=$(PATH="$BASEPATH" $IG_SH "$IG" "$@" 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err"); }
# ig_bg SHELL SIG ARGS...: run the gate in the background, wait until its first
# command is running (its log exists), send SIG once, collect the exit.
ig_bg() {
  local shell=$1 sig=$2 log1="/tmp/gate_${SLUG}_1.log" pid i=0
  shift 2
  [ -e "$log1" ] && ls -la "$log1" >/dev/null && rm -f "$log1"
  PATH="$STUBBIN:$BASEPATH" "$shell" "$IG" "$@" >"$TMP/bg.out" 2>"$TMP/bg.err" &
  pid=$!
  while [ ! -e "$log1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
  sleep 0.3
  kill -"$sig" "$pid"
  wait "$pid"; RC=$?
  OUT=$(cat "$TMP/bg.out"); ERR=$(cat "$TMP/bg.err")
}
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

echo "--- signals (review I1) -------------------------------------------------"
mkrepos r6
move_main r6 m.txt "from main"
before=$(snap "$TMP/r6")
: >"$TMP/relay.log"
ig_bg "$IG_SH" TERM --slug "$SLUG" --cwd "$TMP/r6" --cmd 'sleep 3' --notify orch-x
if [ "$(snap "$TMP/r6")" = "$before" ] && printf '%s\n' "$OUT" | tail -1 | grep -q "^GATE-DONE $SLUG " && grep -q -- '--to orch-x' "$TMP/relay.log" && grep -q 'rc=143' "$TMP/relay.log" && [ $RC -eq 143 ]; then ok "TERM mid-command on a merged run: tree restored, GATE-DONE printed, relay notified, exit 143"; else bad "term finish" "rc=$RC snap=$(snap "$TMP/r6") before=$before out=$OUT relay=$(cat "$TMP/relay.log")"; fi
if command -v dash >/dev/null 2>&1; then
  : >"$TMP/relay.log"
  ig_bg dash HUP --slug "$SLUG" --cwd "$TMP/r6" --cmd 'sleep 3' --notify orch-x
  if [ "$(snap "$TMP/r6")" = "$before" ] && printf '%s\n' "$OUT" | tail -1 | grep -q "^GATE-DONE $SLUG " && grep -q 'rc=129' "$TMP/relay.log" && [ $RC -eq 129 ]; then ok "HUP under dash mid-command: tree restored, GATE-DONE printed, relay notified, exit 129"; else bad "hup dash" "rc=$RC snap=$(snap "$TMP/r6") before=$before out=$OUT relay=$(cat "$TMP/relay.log")"; fi
else
  echo "skip HUP under dash: dash not installed"
fi

echo "--- in place, restored too (review I2) ----------------------------------"
mkrepos r7
before=$(snap "$TMP/r7"); FEAT=$(git -C "$TMP/r7" rev-parse feat)
ig --slug "$SLUG" --cwd "$TMP/r7" --cmd 'git checkout -q main'
[ $RC -eq 0 ] && [ "$(snap "$TMP/r7")" = "$before" ] && printf '%s' "$OUT" | grep -q '^RESTORED:' && ok "in place: a command that checks out main is undone, RESTORED: names it" || bad "in-place checkout" "rc=$RC snap=$(snap "$TMP/r7") before=$before out=$OUT"
ig --slug "$SLUG" --cwd "$TMP/r7" --cmd 'echo x >> a.txt'
[ $RC -eq 0 ] && [ "$(snap "$TMP/r7")" = "$before" ] && printf '%s' "$OUT" | grep -q '^RESTORED:.*a.txt' && ok "in place: a command that edits a tracked file is undone, RESTORED: names the file" || bad "in-place dirty" "rc=$RC snap=$(snap "$TMP/r7") before=$before out=$OUT"
ig --slug "$SLUG" --cwd "$TMP/r7" --cmd 'git commit -q --allow-empty -m gate-made'
[ $RC -eq 0 ] && [ "$(snap "$TMP/r7")" = "$before" ] && [ "$(git -C "$TMP/r7" rev-parse feat)" = "$FEAT" ] && ok "in place: a command that commits never moves the lane branch" || bad "in-place commit" "rc=$RC feat=$(git -C "$TMP/r7" rev-parse feat) want=$FEAT out=$OUT"
ig --slug "$SLUG" --cwd "$TMP/r7" --cmd true
! printf '%s' "$OUT" | grep -q '^RESTORED:' && ok "in place, nothing changed: no RESTORED: line" || bad "restored noise" "out=$OUT"

echo "--- known-fail never hides a crash (review I3) --------------------------"
ig --slug "$SLUG" --cwd "$TMP/r7" --cmd 'echo "--- FAIL: TestFlaky (1.0s)"; echo "Segmentation fault"; exit 139' --known-fail 'TestFlaky \('
[ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q 'known-only rc=139' && printf '%s' "$OUT" | grep -q 'failed=1 known=1$' && ok "known failure line plus exit 139: counted failed, known-only rc=139 printed" || bad "known crash" "rc=$RC out=$OUT"
ig --slug "$SLUG" --cwd "$TMP/r7" --cmd 'echo "--- FAIL: TestFlakyButRealRegression (1.0s)"; exit 1' --known-fail 'TestFlaky \('
[ $RC -eq 1 ] && printf '%s' "$OUT" | grep -q '^  --- FAIL: TestFlakyButRealRegression' && ok "the documented anchored form 'TestFlaky \\(' does not hide TestFlakyButRealRegression" || bad "anchored known" "rc=$RC out=$OUT"
grep -q "TestFlaky \\\\(" "$IG" && ok "usage text shows the anchored --known-fail form" || bad "usage anchor" "$(grep -n 'known-fail' "$IG" | head -5)"

echo "--- test merge: hooks, non-conflict failure, gate-file trust (m1 m2 m3) --"
mkrepos r9
move_main r9 m.txt "from main"
for h in post-merge prepare-commit-msg; do printf '#!/bin/sh\ntouch "%s/hook-%s"\n' "$TMP" "$h" >"$TMP/r9/.git/hooks/$h"; chmod +x "$TMP/r9/.git/hooks/$h"; done
ig --slug "$SLUG" --cwd "$TMP/r9" --cmd true
[ $RC -eq 0 ] && [ ! -e "$TMP/hook-post-merge" ] && [ ! -e "$TMP/hook-prepare-commit-msg" ] && ok "the test merge runs no repo hook (post-merge, prepare-commit-msg)" || bad "hooks ran" "rc=$RC $(echo "$TMP"/hook-*)"
mkrepos r10
move_main r10 main-only.txt "from main"
printf 'lane copy\n' >"$TMP/r10/main-only.txt"
before=$(snap "$TMP/r10")
ig --slug "$SLUG" --cwd "$TMP/r10" --cmd true
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q 'MERGE-FAILED' && ! printf '%s' "$OUT" | grep -q 'MERGE-CONFLICT' && printf '%s%s' "$OUT" "$ERR" | grep -q 'main-only.txt' && [ "$(snap "$TMP/r10")" = "$before" ] && ! printf '%s' "$OUT" | grep -q '^true rc='; then ok "a merge that fails without a conflict: MERGE-FAILED plus git's reason, exit 2, tree as before"; else bad "merge failed" "rc=$RC out=$OUT err=$ERR snap=$(snap "$TMP/r10") before=$before"; fi
ig --slug "$SLUG" --cwd "$TMP/r2"
[ $RC -eq 0 ] && printf '%s' "$ERR" | grep -q '\.herdr-gate.*has none' && ok ".herdr-gate the base lacks: warned (the gated tree chose its own commands)" || bad "gate file trust none" "rc=$RC err=$ERR"
mkrepos r8
move_main r8 .herdr-gate 'true'
git -C "$TMP/r8" fetch -q && git -C "$TMP/r8" merge -q --no-edit origin/main
ig --slug "$SLUG" --cwd "$TMP/r8"
[ $RC -eq 0 ] && ! printf '%s' "$ERR" | grep -q 'herdr-gate' && ok ".herdr-gate equal to the base's: no warning" || bad "gate file same" "rc=$RC err=$ERR"
commit_in "$TMP/r8" .herdr-gate 'true\necho lane-added\n'
ig --slug "$SLUG" --cwd "$TMP/r8"
[ $RC -eq 0 ] && printf '%s' "$ERR" | grep -q '\.herdr-gate.*differs' && ok ".herdr-gate that differs from the base's: warned" || bad "gate file differs" "rc=$RC err=$ERR"
grep -qi 'trust' "$IG" && grep -q 'sh -c' "$IG" && grep -qi 'privileges' "$IG" && ok "the script header states the gate-file trust boundary" || bad "header trust" "no trust boundary text"

echo "--- round 2: crash markers under make (I-A) -------------------------------"
REALGIT=$(command -v git)
# gitwrap DIR CASE-PATTERN ACTION: a git first on PATH that runs ACTION
# (a sleep, or exit 1) when its argv matches CASE-PATTERN, else the real git.
gitwrap() { mkdir -p "$1"; printf '#!/bin/sh\ncase "$*" in %s) %s ;; esac\nexec "%s" "$@"\n' "$2" "$3" "$REALGIT" >"$1/git"; chmod +x "$1/git"; }
# ig_pre_bg PREFIX DELAY SIG ARGS...: the gate with PREFIX first on PATH, in
# the background; SIG is sent once after DELAY seconds.
ig_pre_bg() {
  local pre=$1 d=$2 sig=$3 pid
  shift 3
  PATH="$pre:$STUBBIN:$BASEPATH" $IG_SH "$IG" "$@" >"$TMP/bg.out" 2>"$TMP/bg.err" &
  pid=$!
  sleep "$d"; kill -"$sig" "$pid"
  wait "$pid"; RC=$?
  OUT=$(cat "$TMP/bg.out"); ERR=$(cat "$TMP/bg.err")
}
mkrepos r11
commit_in "$TMP/r11" Makefile 'check:\n\ttrue\ntest:\n\tsh -c '"'"'echo "--- FAIL: TestFlaky (1.0s)"; kill -SEGV $$$$'"'"'\n'
ig --slug "$SLUG" --cwd "$TMP/r11" --known-fail 'TestFlaky \('
if [ $RC -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^  crash: make' && printf '%s\n' "$OUT" | grep -q '^  known: --- FAIL: TestFlaky' && printf '%s\n' "$OUT" | grep -q 'failed=1 known=1$'; then ok "make test crashes after a known flaky line: crash: line printed, counted failed, exit 1 ($IG_SH)"; else bad "make crash" "rc=$RC out=$OUT err=$ERR"; fi
mkrepos r12
commit_in "$TMP/r12" Makefile 'check:\n\ttrue\ntest:\n\t@echo "--- FAIL: TestFlaky (1.0s)"; echo "installing SIGSEGV handler"; exit 1\n'
ig --slug "$SLUG" --cwd "$TMP/r12" --known-fail 'TestFlaky \('
if [ $RC -eq 0 ] && printf '%s\n' "$OUT" | grep -q 'failed=0 known=1$' && ! printf '%s\n' "$OUT" | grep -q '^  crash:'; then ok "make test with only a known failure (and a log line that merely names SIGSEGV): still downgraded, exit 0"; else bad "make known" "rc=$RC out=$OUT err=$ERR"; fi

echo "--- round 3: every signal report is a crash, a test name is not (I-1) ---"
# Each case pairs a crash with a KNOWN flaky line, so only the crash rule can
# keep the gate red.
for s in TRAP FPE TERM; do
  mkrepos "r20$s"
  commit_in "$TMP/r20$s" Makefile 'check:\n\ttrue\ntest:\n\tsh -c '"'"'echo "--- FAIL: TestFlaky (1.0s)"; kill -'"$s"' $$$$'"'"'\n'
  ig --slug "$SLUG" --cwd "$TMP/r20$s" --known-fail 'TestFlaky \('
  if [ $RC -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^  crash: make' && printf '%s\n' "$OUT" | grep -q 'failed=1 known=1$'; then ok "make recipe killed by SIG$s after a known flaky line: crash: make line, counted failed, exit 1 ($IG_SH)"; else bad "make $s crash" "rc=$RC out=$OUT err=$ERR"; fi
done
mkrepos r21
printf '#!/bin/sh\nkill -SEGV $$\n' >"$TMP/r21/crasher"; chmod +x "$TMP/r21/crasher"
git -C "$TMP/r21" add crasher; git -C "$TMP/r21" commit -q -m crasher
commit_in "$TMP/r21" Makefile 'check:\n\ttrue\ntest:\n\t@./crasher; echo "--- FAIL: TestFlaky (1.0s)"; exit 1\n'
ig --slug "$SLUG" --cwd "$TMP/r21" --known-fail 'TestFlaky \('
if [ $RC -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^  crash: .*[0-9] Segmentation fault' && printf '%s\n' "$OUT" | grep -q 'failed=1 known=1$'; then ok "make runner whose child segfaults, then prints the known flaky and exits 1: the shell's job report is a crash: line, exit 1 ($IG_SH)"; else bad "make child crash" "rc=$RC out=$OUT err=$ERR"; fi
for inner in sh bash dash; do
  command -v "$inner" >/dev/null 2>&1 || { echo "skip child crash under $inner: not installed"; continue; }
  ig --slug "$SLUG" --cwd "$TMP/r21" --cmd "$inner -c './crasher; echo \"--- FAIL: TestFlaky (1.0s)\"'; exit 1" --known-fail 'TestFlaky \('
  if [ $RC -eq 1 ] && printf '%s\n' "$OUT" | grep -q '^  crash: .*Segmentation fault' && printf '%s\n' "$OUT" | grep -q 'failed=1 known=1$'; then ok "a runner under $inner whose child segfaults (rc 1, known flaky): crash: line, exit 1 ($IG_SH)"; else bad "child crash $inner" "rc=$RC out=$OUT err=$ERR log=$(cat "/tmp/gate_${SLUG}_1.log")"; fi
done
ig --slug "$SLUG" --cwd "$TMP/r21" --cmd 'echo "--- FAIL: TestFlaky (1.0s)"; echo "ok 4 - prints Abort trap"; echo "not ok 3 - recovers from Segmentation fault"; echo "--- FAIL: TestBus (0.0s) expected Bus error"; echo "t.go:12: child said: Killed"; exit 1' \
  --known-fail 'TestFlaky \(' --known-fail 'recovers from Segmentation' --known-fail 'TestBus \('
if [ $RC -eq 0 ] && ! printf '%s\n' "$OUT" | grep -q '^  crash:' && printf '%s\n' "$OUT" | grep -q 'failed=0 known=3$'; then ok "test names that mention a signal (TAP ok/not ok, a FAIL reason, a quoted child line) are not crash: lines; all known, exit 0"; else bad "signal in a test name" "rc=$RC out=$OUT err=$ERR"; fi
# The regex itself over fixed lines: GNU make 4 and Linux spellings cannot be
# produced on every box (make 3.81 on macOS), so they are tested as strings.
CRE=$(sed -n "s/^CRASH_RE='\(.*\)'\$/\1/p" "$IG")
miss=""
while IFS='|' read -r want line; do
  [ -n "$line" ] || continue
  got=no; printf '%s\n' "$line" | grep -qE -- "$CRE" && got=yes
  [ "$got" = "$want" ] || miss="$miss [$want] $line;"
done <<'EOF'
yes|make: *** [Makefile:3: test] Segmentation fault (core dumped)
yes|make[1]: *** [Makefile:3: test] Error 139
yes|make: *** [Makefile:2: test] Terminated
yes|make: *** [Makefile:2: test] Floating point exception
yes|gmake: *** [Makefile:2: test] Segmentation fault: 11
yes|/usr/bin/make: *** [t] Trace/BPT trap: 5
yes|make: *** [t] Hangup: 1
yes|make: *** [t] User defined signal 1: 30
yes|make: *** [t] Error 130
yes|/bin/sh: line 1: 35112 Segmentation fault: 11  ./crasher
yes|bash: line 1: 4242 Aborted                 (core dumped) ./crasher
yes|run.sh: line 7: 4242 Trace/breakpoint trap   ./crasher
yes|sh: 1: 4242 Killed
yes|Floating point exception: 8
yes|Terminated
yes|[signal SIGSEGV: segmentation violation code=0x1 addr=0x0 pc=0x10a4b2c]
yes|process didn't exit successfully: `x` (signal: 11, SIGSEGV: invalid memory reference)
no|make: *** [test] Error 2
no|make: *** [Makefile:3: test] Error 1
no|make: *** [t] Error 125
no|make: [u] Error 3 (ignored)
no|make: *** [t] Error 139 (ignored)
no|make: *** No rule to make target 'x'.  Stop.
no|ok 4 - prints Abort trap
no|not ok 3 - recovers from Segmentation fault
no|--- FAIL: TestHandlesBusError (0.00s) expected Bus error
no|t.go:12: child said: Killed
no|installing SIGSEGV handler
EOF
[ -n "$CRE" ] && [ -z "$miss" ] && ok "CRASH_RE over fixed lines: GNU make 4 and Linux report forms are crashes, make's ordinary Error N<126, (ignored) and test names are not" || bad "crash regex table" "CRE=${CRE:-<not found>} miss:$miss"

echo "--- round 2: restore puts back the SHA and keeps what it found (I-B I-C) --"
for shape in inplace merged; do
  mkrepos "r13$shape"; R="$TMP/r13$shape"
  [ "$shape" = merged ] && move_main "r13$shape" m.txt "from main"
  before=$(snap "$R"); FEAT=$(git -C "$R" rev-parse feat)
  ig --slug "$SLUG" --cwd "$R" --cmd 'git checkout -q feat && git commit -q --allow-empty -m gate-made-on-feat'
  MV=$(git -C "$R" rev-parse -q --verify "refs/integration-gate/$SLUG/moved")
  if [ $RC -eq 0 ] && [ "$(snap "$R")" = "$before" ] && [ "$(git -C "$R" rev-parse feat)" = "$FEAT" ] && [ -n "$MV" ] && [ "$(git -C "$R" log -1 --format=%s "$MV")" = gate-made-on-feat ] \
     && printf '%s\n' "$OUT" | grep -q "^RESTORED: .*feat moved to $MV.*put back to feat at $FEAT.*kept: .*refs/integration-gate/$SLUG/moved" && ! printf '%s' "$OUT" | grep -q 'featrefs'; then
    ok "$shape: a command that commits on the lane branch: feat put back to its SHA, the commit kept under refs/integration-gate/<slug>/moved, RESTORED: says so"
  else bad "lane branch moved ($shape)" "rc=$RC feat=$(git -C "$R" rev-parse feat) want=$FEAT MV=$MV snap=$(snap "$R") before=$before out=$OUT err=$ERR"; fi
done
mkrepos r15; before=$(snap "$TMP/r15"); FEAT=$(git -C "$TMP/r15" rev-parse feat)
log1="/tmp/gate_${SLUG}_1.log"; [ -e "$log1" ] && ls -la "$log1" >/dev/null && rm -f "$log1"
PATH="$STUBBIN:$BASEPATH" $IG_SH "$IG" --slug "$SLUG" --cwd "$TMP/r15" --cmd 'sleep 2' >"$TMP/bg.out" 2>"$TMP/bg.err" &
gp=$!; i=0
while [ ! -e "$log1" ] && [ $i -lt 100 ]; do sleep 0.1; i=$((i + 1)); done
sleep 0.2
printf 'worker edit\n' >>"$TMP/r15/a.txt"; git -C "$TMP/r15" commit -q -am 'worker commit during gate'; WC=$(git -C "$TMP/r15" rev-parse HEAD)
printf 'uncommitted worker edit\n' >>"$TMP/r15/b.txt"
wait $gp; RC=$?; OUT=$(cat "$TMP/bg.out"); ERR=$(cat "$TMP/bg.err")
if [ $RC -eq 0 ] && [ "$(snap "$TMP/r15")" = "$before" ] && [ "$(git -C "$TMP/r15" rev-parse feat)" = "$FEAT" ] \
   && git -C "$TMP/r15" merge-base --is-ancestor "$WC" "refs/integration-gate/$SLUG/head" \
   && git -C "$TMP/r15" show 'stash@{0}:b.txt' 2>/dev/null | grep -q 'uncommitted worker edit' \
   && git -C "$TMP/r15" stash list | grep -q "integration-gate $SLUG: found at restore" \
   && printf '%s\n' "$OUT" | grep -q "^RESTORED: .*kept: .*refs/integration-gate/$SLUG/head" && printf '%s\n' "$OUT" | grep -q '^RESTORED: .*kept: .*stash'; then
  ok "a writer commits and edits during an in-place run: nothing lost (commit under refs/integration-gate/<slug>/head, edit in a stash), both named"
else bad "preserve before discard" "rc=$RC WC=$WC head=$(git -C "$TMP/r15" rev-parse -q --verify "refs/integration-gate/$SLUG/head") stash=$(git -C "$TMP/r15" stash list) snap=$(snap "$TMP/r15") before=$before out=$OUT err=$ERR"; fi

echo "--- round 2: ignored lane files survive the test merge (I-D) -------------"
mkrepos r16
commit_in "$TMP/r16" .gitignore 'local.cfg\n'
printf 'MY LOCAL SECRET CONFIG\n' >"$TMP/r16/local.cfg"
move_main r16 local.cfg "main default"
ig --slug "$SLUG" --cwd "$TMP/r16" --cmd true
if [ $RC -eq 2 ] && printf '%s' "$OUT" | grep -q 'MERGE-FAILED' && [ "$(cat "$TMP/r16/local.cfg" 2>&1)" = 'MY LOCAL SECRET CONFIG' ] && ! printf '%s' "$OUT" | grep -q '^true rc='; then ok "main starts tracking an ignored lane file: MERGE-FAILED, exit 2, the lane's file intact"; else bad "ignored file" "rc=$RC out=$OUT err=$ERR local.cfg=$(cat "$TMP/r16/local.cfg" 2>&1)"; fi

echo "--- round 2: signal races and the verifier (m-c, ruling A) ----------------"
mkrepos r17; move_main r17 m.txt "from main"; before=$(snap "$TMP/r17")
gitwrap "$TMP/slow-detach" '"checkout -q --detach"' 'sleep 1.5'
ig_pre_bg "$TMP/slow-detach" 0.7 TERM --slug "$SLUG" --cwd "$TMP/r17" --cmd true
[ $RC -eq 143 ] && [ "$(snap "$TMP/r17")" = "$before" ] && printf '%s\n' "$OUT" | tail -1 | grep -q "^GATE-DONE $SLUG " && ok "TERM during the detach: tree restored, GATE-DONE printed, exit 143" || bad "term detach" "rc=$RC snap=$(snap "$TMP/r17") before=$before out=$OUT err=$ERR"
mkrepos r18
commit_in "$TMP/r18" m.txt 'lane\n'
move_main r18 m.txt "main"
before=$(snap "$TMP/r18")
gitwrap "$TMP/slow-abort" '"merge --abort"' 'sleep 1.5'
ig_pre_bg "$TMP/slow-abort" 0.8 TERM --slug "$SLUG" --cwd "$TMP/r18" --cmd true
[ $RC -eq 3 ] && [ "$(snap "$TMP/r18")" = "$before" ] && [ ! -e "$TMP/r18/.git/MERGE_HEAD" ] && printf '%s' "$OUT" | grep -q '^MERGE-CONFLICT' && printf '%s\n' "$OUT" | tail -1 | grep -q 'merged=conflict' && ok "TERM during the conflict path's merge --abort: tree restored, MERGE-CONFLICT printed, merged=conflict, exit 3 (a signal during finish is ignored)" || bad "term abort" "rc=$RC snap=$(snap "$TMP/r18") before=$before out=$OUT err=$ERR"
mkrepos r19
gitwrap "$TMP/fail-co" '"checkout -q -f feat"*' 'exit 1'
OUT=$(PATH="$TMP/fail-co:$STUBBIN:$BASEPATH" $IG_SH "$IG" --slug "$SLUG" --cwd "$TMP/r19" --cmd true 2>"$TMP/err"); RC=$?; ERR=$(cat "$TMP/err")
[ $RC -eq 1 ] && [ "$(printf '%s\n' "$OUT" | grep -c '^RESTORE MISMATCH:')" = 1 ] && printf '%s\n' "$OUT" | grep -q '^RESTORE MISMATCH: .*detached' && ! printf '%s' "$OUT" | grep -q '^RESTORED:' && printf '%s\n' "$OUT" | tail -1 | grep -q "^GATE-DONE $SLUG " && ok "a restore the verifier cannot confirm: one RESTORE MISMATCH: line naming what differs, exit 1, never a RESTORED: line" || bad "restore mismatch" "rc=$RC out=$OUT err=$ERR"

echo
echo "integration-gate: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
