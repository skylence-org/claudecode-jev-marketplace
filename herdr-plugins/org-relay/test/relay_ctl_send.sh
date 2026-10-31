#!/bin/sh
# relay-ctl send: argument validation, the JSON body it POSTs to /send, and
# how it reports each daemon answer (200, 400, 404, nothing listening). Runs
# against a stub `curl` on PATH that records the request and replays a canned
# answer, so no daemon, no build and no db are needed.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
CTL="$DIR/relay-ctl"
command -v jq >/dev/null 2>&1 || { echo "relay-ctl send: SKIP (jq missing)"; [ -n "${CI:-}" ] && exit 1; exit 0; }
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
mkdir -p "$T/bin"
cat > "$T/bin/curl" <<'EOF'
#!/bin/sh
out=""; data=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) out=$2; shift 2 ;;
    --data-binary) data=$2; shift 2 ;;
    *) printf '%s\n' "$1" >> "$CURL_ARGS"; shift ;;
  esac
done
printf '%s' "$data" > "$CURL_BODY"
[ -n "$out" ] && cp "$CURL_REPLY_FILE" "$out"
printf '%s' "$CURL_CODE"
exit "$CURL_RC"
EOF
chmod +x "$T/bin/curl"
export PATH="$T/bin:$PATH" CURL_ARGS="$T/args" CURL_BODY="$T/body" CURL_REPLY_FILE="$T/reply" ORG_RELAY_PORT=7466 TMPDIR="$T"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
run() { # run <code> <curl rc> <reply json> -- relay-ctl send args...
  code=$1; crc=$2; printf '%s' "$3" > "$T/reply"; shift 4
  : > "$T/args"; : > "$T/body"
  OUT=$(CURL_CODE=$code CURL_RC=$crc sh "$CTL" send "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err")
}

run 200 0 '{"id":42,"queued_for":"orch","live_await":true}' -- --to orch --kind job --body 'job gate-1 rc=0 (it took $x min)'
if [ $RC -eq 0 ] && printf '%s' "$OUT" | jq -e '.id == 42 and .live_await == true' >/dev/null \
  && jq -e '.sender == "relay-ctl" and .to == "orch" and .kind == "job" and .body == "job gate-1 rc=0 (it took $x min)" and (has("lane") | not)' "$T/body" >/dev/null \
  && grep -q '^http://127.0.0.1:7466/send$' "$T/args"; then ok "200: posts the exact body to /send on ORG_RELAY_PORT, prints {id, live_await}"; else bad "200" "rc=$RC out=$OUT body=$(cat "$T/body") args=$(tr '\n' ' ' < "$T/args")"; fi

run 200 0 '{"id":43,"queued_for":"orch","live_await":false}' -- --to orch --kind job --body done --sender gate-runner --lane lane-a
if [ $RC -eq 0 ] && jq -e '.sender == "gate-runner" and .lane == "lane-a"' "$T/body" >/dev/null; then ok "--sender and --lane ride the body"; else bad "sender/lane" "body=$(cat "$T/body")"; fi

run 200 0 '{}' -- --to orch --kind job
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q -- '--body is required' && [ ! -s "$T/args" ]; then ok "missing --body: usage error, nothing sent"; else bad "missing body" "rc=$RC err=$ERR"; fi

run 200 0 '{}' -- --to orch --kind job --body '   '
if [ $RC -eq 2 ] && [ ! -s "$T/args" ]; then ok "whitespace-only --body: refused like relay_send does"; else bad "blank body" "rc=$RC"; fi

run 200 0 '{}' -- --to orch --kind job --body x --to
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q 'needs a value' && [ ! -s "$T/args" ]; then ok "a flag without a value: usage error"; else bad "dangling flag" "rc=$RC err=$ERR"; fi

run 400 0 '{"error":"missing required string argument: kind"}' -- --to orch --kind job --body x
if [ $RC -eq 1 ] && printf '%s' "$ERR" | grep -q 'HTTP 400' && printf '%s' "$ERR" | grep -q 'missing required'; then ok "400: the daemon's validation error is reported, exit 1"; else bad "400" "rc=$RC err=$ERR"; fi

run 404 0 'Not Found' -- --to orch --kind job --body x
if [ $RC -eq 1 ] && printf '%s' "$ERR" | grep -q 'has no POST /send'; then ok "404: names the old daemon and the fix"; else bad "404" "rc=$RC err=$ERR"; fi

run 000 7 '' -- --to orch --kind job --body x
if [ $RC -eq 1 ] && printf '%s' "$ERR" | grep -q 'no org-relay answering on :7466'; then ok "nothing listening: says so, exit 1"; else bad "down" "rc=$RC err=$ERR"; fi

echo "relay-ctl send: $pass passed, $fail failed"
[ "$fail" = 0 ]
