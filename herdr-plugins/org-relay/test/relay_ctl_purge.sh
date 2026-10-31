#!/bin/sh
# relay-ctl purge: operator-only cleanup of orphaned queues. Lists by default,
# deletes only with --delete and only the listed ids, never touches consumed
# rows, newer rows or other recipients, and records the purge in audit.jsonl.
# Runs against a temp db in the daemon's own schema: no daemon, no build.
set -u
DIR=$(cd "$(dirname "$0")/.." && pwd)
CTL="$DIR/relay-ctl"
for dep in sqlite3 jq; do
  command -v "$dep" >/dev/null 2>&1 || { echo "relay-ctl purge: SKIP ($dep missing)"; [ -n "${CI:-}" ] && exit 1; exit 0; }
done
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export ORG_RELAY_DB="$T/relay.db"
sqlite3 "$ORG_RELAY_DB" "CREATE TABLE messages (id INTEGER PRIMARY KEY AUTOINCREMENT, ts TEXT NOT NULL, sender TEXT NOT NULL, recipient TEXT NOT NULL, lane TEXT, kind TEXT NOT NULL, body TEXT NOT NULL, consumed_at TEXT);"
ago() { echo "strftime('%Y-%m-%dT%H:%M:%SZ', 'now', '-$1 seconds')"; }
sqlite3 "$ORG_RELAY_DB" "INSERT INTO messages (ts, sender, recipient, kind, body, consumed_at) VALUES
  ($(ago 172800), 'peer', 'i531-silent-persist', 'doorbell', 'old, orphaned', NULL),
  ($(ago 60), 'peer', 'i531-silent-persist', 'doorbell', 'fresh', NULL),
  ($(ago 172800), 'peer', 'i531-silent-persist', 'doorbell', 'old but consumed', $(ago 100)),
  ($(ago 172800), 'peer', 'orch-other', 'doorbell', 'old, another recipient', NULL);"
pass=0; fail=0
ok() { pass=$((pass + 1)); echo "ok   $1"; }
bad() { fail=$((fail + 1)); echo "FAIL $1: $2"; }
rows() { sqlite3 "$ORG_RELAY_DB" "SELECT group_concat(id) FROM (SELECT id FROM messages ORDER BY id);"; }
p() { OUT=$(sh "$CTL" purge "$@" 2>"$T/err"); RC=$?; ERR=$(cat "$T/err"); }

p --recipient i531-silent-persist --older-than 1d
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'old, orphaned' && ! printf '%s' "$OUT" | grep -q 'fresh' && printf '%s' "$OUT" | grep -q '1 unconsumed message(s).*nothing deleted' && [ "$(rows)" = "1,2,3,4" ]; then ok "default lists exactly the old unconsumed row and deletes nothing"; else bad "list" "rc=$RC out=$OUT rows=$(rows)"; fi

p --recipient i531-silent-persist --older-than 1d --dry-run
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'nothing deleted' && [ "$(rows)" = "1,2,3,4" ]; then ok "--dry-run is the same listing"; else bad "dry-run" "rc=$RC rows=$(rows)"; fi

p --recipient i531-silent-persist --older-than 1d --delete
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'deleted 1 ' && [ "$(rows)" = "2,3,4" ]; then ok "--delete removes only the listed id (not the fresh, consumed or other-recipient rows)"; else bad "delete" "rc=$RC out=$OUT rows=$(rows)"; fi
if jq -e 'select(.event == "purge") | .recipient == "i531-silent-persist" and .deleted == 1 and .ids == [1]' "$T/audit.jsonl" >/dev/null 2>&1; then ok "the purge is recorded in audit.jsonl beside the db"; else bad "audit" "$(cat "$T/audit.jsonl" 2>/dev/null)"; fi

p --recipient i531-silent-persist --older-than 1d --delete
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'no unconsumed message' && [ "$(rows)" = "2,3,4" ]; then ok "nothing left to purge: says so, exit 0"; else bad "empty" "rc=$RC out=$OUT"; fi

p --older-than 1d
if [ $RC -eq 2 ] && printf '%s' "$ERR" | grep -q -- '--recipient is required'; then ok "missing --recipient: usage error"; else bad "no recipient" "rc=$RC err=$ERR"; fi
for bad_age in 1w 10 d -5d; do
  p --recipient x --older-than "$bad_age"
  [ $RC -eq 2 ] || bad "bad age $bad_age" "rc=$RC"
done
ok "bad --older-than values (1w, 10, d, -5d): usage errors"

p --recipient "o'brien" --older-than 1d
if [ $RC -eq 0 ] && printf '%s' "$OUT" | grep -q 'no unconsumed message'; then ok "a quote in the recipient is escaped, not executed"; else bad "quote" "rc=$RC err=$ERR"; fi

echo "relay-ctl purge: $pass passed, $fail failed"
[ "$fail" = 0 ]
