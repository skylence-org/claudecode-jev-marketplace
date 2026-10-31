#!/bin/sh
# relay-ctl link-cli (run by install-daemon): links relay-ctl into a bin dir
# so a job can end with a bare `relay-ctl send ...`, says when that dir is not
# on PATH, and the linked script still resolves its own crate directory
# (status prints the absolute cli path roles fall back to). Stub curl; no
# daemon, no launchd, no build.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
CTL="$DIR/relay-ctl"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/stub"
cat > "$T/stub/curl" <<'EOF'
#!/bin/sh
for a in "$@"; do last=$a; done
case "$last" in
  */health) printf '{"status":"ok"}' ;;
  */status) printf '{"build":{"version":"1.5.0","sha":"abc","dirty":false,"built_at":"t","remote":"r","source_dir":"s"}}' ;;
esac
EOF
chmod +x "$T/stub/curl"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }

OUT=$(RELAY_CTL_BIN_DIR="$T/bin" PATH="/usr/bin:/bin" sh "$CTL" link-cli 2>&1); RC=$?
if [ $RC -eq 0 ] && [ -L "$T/bin/relay-ctl" ] && [ "$(readlink "$T/bin/relay-ctl")" = "$CTL" ]; then ok "link-cli creates the missing bin dir and links relay-ctl to the crate's script"; else bad "link" "rc=$RC out=$OUT"; fi
if printf '%s' "$OUT" | grep -q "$T/bin is not on PATH"; then ok "a bin dir not on PATH is named, with the absolute-path fallback"; else bad "path hint" "$OUT"; fi
OUT=$(RELAY_CTL_BIN_DIR="$T/bin" PATH="$T/bin:/usr/bin:/bin" sh "$CTL" link-cli 2>&1)
if ! printf '%s' "$OUT" | grep -q 'not on PATH'; then ok "on PATH: no hint"; else bad "on path" "$OUT"; fi
OUT=$(RELAY_CTL_BIN_DIR="$T/bin" PATH="$T/bin:/usr/bin:/bin" sh "$CTL" link-cli 2>&1); RC=$?
[ $RC -eq 0 ] && [ "$(readlink "$T/bin/relay-ctl")" = "$CTL" ] && ok "re-linking is idempotent" || bad "relink" "rc=$RC"

OUT=$(PATH="$T/stub:$T/bin:/usr/bin:/bin" ORG_RELAY_PORT=7468 sh "$T/bin/relay-ctl" status 2>&1); RC=$?
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -qF "org-relay: cli $CTL (on PATH as relay-ctl)"; then ok "run through the link, status resolves the real crate dir and prints the absolute cli path"; else bad "status via link" "rc=$RC out=$OUT"; fi
OUT=$(PATH="$T/stub:/usr/bin:/bin" ORG_RELAY_PORT=7468 sh "$CTL" status 2>&1)
if printf '%s' "$OUT" | grep -qF "org-relay: cli $CTL (not on PATH"; then ok "not on PATH: status says to call it by its absolute path"; else bad "status off path" "$OUT"; fi

echo "relay-ctl link: $pass passed, $fail failed"
[ "$fail" = 0 ]
