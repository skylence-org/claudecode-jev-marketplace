#!/bin/sh
# Smoke test for awctx. Offline assertions always run; live assertions run
# only when a local aw-server answers (skipped otherwise, not failed).
set -eu

here=$(cd "$(dirname "$0")/.." && pwd)
AWCTX="$here/awctx"
fail=0

sh -n "$AWCTX" && echo 'ok: sh -n' || { echo 'FAIL: syntax'; fail=1; }

sh "$AWCTX" agent-help | grep -q 'awctx now' \
  && echo 'ok: agent-help' || { echo 'FAIL: agent-help'; fail=1; }

# Unknown command → clean nonzero + hint on stderr.
if out=$(sh "$AWCTX" bogus 2>&1); then
  echo 'FAIL: bogus command should exit nonzero'; fail=1
else
  printf '%s' "$out" | grep -q 'agent-help' \
    && echo 'ok: unknown-command hint' || { echo 'FAIL: unknown-command hint'; fail=1; }
fi

# Unreachable server → doctor fails cleanly, no stack of curl/jq noise.
if AWCTX_SERVER=http://127.0.0.1:1 sh "$AWCTX" doctor >/dev/null 2>&1; then
  echo 'FAIL: doctor should exit nonzero when server unreachable'; fail=1
else
  echo 'ok: doctor fails offline'
fi

if curl -sf --max-time 2 "${AWCTX_SERVER:-http://127.0.0.1:5600}/api/0/info" >/dev/null 2>&1; then
  for c in 'doctor' 'buckets' 'now' 'recent 10' 'afk 1' 'summary 1'; do
    if sh "$AWCTX" $c >/dev/null 2>&1; then
      echo "ok: awctx $c (live)"
    else
      echo "FAIL: awctx $c (live)"; fail=1
    fi
  done
  # Write side: add a throwaway category, see it, remove it, see it gone.
  if sh "$AWCTX" category add 'Test/awctx-smoke' 'awctx-smoke-nomatch-9f3a' >/dev/null 2>&1 \
     && sh "$AWCTX" categories | grep -q 'Test/awctx-smoke' \
     && sh "$AWCTX" category rm 'Test/awctx-smoke' >/dev/null 2>&1 \
     && ! sh "$AWCTX" categories | grep -q 'Test/awctx-smoke'; then
    echo 'ok: category add/rm roundtrip (live)'
  else
    echo 'FAIL: category add/rm roundtrip (live)'; fail=1
  fi
  # Sync: temp preset upserts, second run is a no-op, then clean up.
  pre=$(mktemp)
  printf '%s' '[{"name":["Test","awctx-smoke"],"rule":{"type":"regex","regex":"awctx-smoke-nomatch-9f3a"}}]' > "$pre"
  if sh "$AWCTX" category sync "$pre" >/dev/null 2>&1 \
     && sh "$AWCTX" categories | grep -q 'Test/awctx-smoke' \
     && sh "$AWCTX" category sync "$pre" 2>/dev/null | grep -q 'already in sync' \
     && sh "$AWCTX" category rm 'Test/awctx-smoke' >/dev/null 2>&1; then
    echo 'ok: category sync idempotent (live)'
  else
    echo 'FAIL: category sync (live)'; fail=1
  fi
  rm -f "$pre"
  # Bootstrap: export current state, re-apply it, expect zero writes.
  bl=$(mktemp)
  if sh "$AWCTX" bootstrap export "$bl" >/dev/null 2>&1 \
     && [ "$(sh "$AWCTX" bootstrap apply "$bl" 2>/dev/null | grep -cv 'already in sync')" = 0 ]; then
    echo 'ok: bootstrap export/apply idempotent (live)'
  else
    echo 'FAIL: bootstrap export/apply (live)'; fail=1
  fi
  rm -f "$bl"
else
  echo 'skip: no live aw-server; live assertions not run'
fi

[ "$fail" -eq 0 ] && echo PASS || echo FAILED
exit "$fail"
