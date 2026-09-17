#!/usr/bin/env bash
# Assert OmniRoute's rate-limit posture: park an exhausted seat for exactly as
# long as the upstream says, and never sit waiting for one.
#
# These live in OmniRoute's database, not its container env, and the server
# re-seeds parts of that table on startup - `rateLimitProtection` has come back
# on for the OAuth seats after every recreate so far. So this runs as an
# assertion, not a one-time click, and is safe to re-run.
#
# What it asserts and why (full reasoning in docs/omniroute-resilience.md):
#
#   connectionCooldown.oauth.useUpstreamRetryHints = true
#     Shipped default is false, which throws away Anthropic's `retry-after` and
#     substitutes a local ladder (5s, 10s, 20s ... ). A Claude Max seat that
#     states a 54-minute reset was therefore retried 5 SECONDS later, measured
#     live as `rateLimitedUntil` 2s out against a 54m wall. Retrying a seat
#     through its own stated window is what escalates a 429 into
#     `403 Request not allowed` - an account-level block, not a timer. With
#     hints honoured the seat sits out its real window untouched and the
#     request moves to the other seat immediately.
#
#   waitForCooldown / comboCooldownWait
#     Shipped defaults block a request for up to 30s, and a combo request for up
#     to 90s per attempt on a 5-minute budget, waiting for a cooling connection.
#     With two Claude seats plus the routing pool behind a fallback chain,
#     waiting is never the best move: fail over instead. Trimmed to seconds.
#
#   rateLimitProtection = off for every OAuth connection
#     It is a local admission gate meant for metered API keys. On an OAuth seat
#     it queues the request locally instead of failing over, which surfaces as
#     `504 local rate-limit execution expiration` while a healthy seat idles.
#
# Usage:
#   omniroute-resilience-posture.sh            # assert (idempotent)
#   omniroute-resilience-posture.sh --check    # report drift, change nothing
set -euo pipefail

PORT=${OMNIROUTE_PORT:-20128}
ENV_FILE=${OMNIROUTE_ENV_FILE:-$HOME/super.env}
BASE=${OMNIROUTE_BASE:-http://127.0.0.1:$PORT}
mode=${1:-assert}

log() { printf '== %s\n' "$*"; }

password=$(sed -n 's/^OMNIROUTE_PASSWORD=//p' "$ENV_FILE" 2>/dev/null | tail -1)
if [ -z "$password" ]; then
	echo "no OMNIROUTE_PASSWORD in $ENV_FILE; cannot reach the management API" >&2
	exit 1
fi

cookie=$(mktemp)
trap 'rm -f "$cookie"' EXIT

if ! curl -fsS -m 10 -c "$cookie" -X POST -H 'Content-Type: application/json' \
	-d "{\"password\":\"$password\"}" "$BASE/api/auth/login" >/dev/null; then
	echo "management login failed against $BASE" >&2
	exit 1
fi

api() { curl -fsS -m 20 -b "$cookie" "$@"; }

# The reviewed posture, as the PATCH body /api/resilience validates.
read -r -d '' desired <<'JSON' || true
{
  "connectionCooldown": {
    "oauth":  { "baseCooldownMs": 5000, "useUpstreamRetryHints": true, "maxBackoffSteps": 8 },
    "apikey": { "baseCooldownMs": 3000, "useUpstreamRetryHints": true, "maxBackoffSteps": 5 }
  },
  "waitForCooldown":   { "enabled": true, "maxRetries": 2, "maxRetryWaitSec": 8 },
  "comboCooldownWait": { "enabled": true, "maxWaitMs": 12000, "maxAttempts": 3, "budgetMs": 40000 }
}
JSON

report_drift() {
	# Compare only the keys this script owns; anything else is the operator's.
	api "$BASE/api/resilience" | DESIRED="$desired" python3 -c '
import json, os, sys
live = json.load(sys.stdin)
want = json.loads(os.environ["DESIRED"])
drift = 0
for section, fields in want.items():
    have = live.get(section) or {}
    for key, value in fields.items():
        if isinstance(value, dict):
            for k2, v2 in value.items():
                got = (have.get(key) or {}).get(k2)
                if got != v2:
                    drift += 1
                    print(f"   drift {section}.{key}.{k2}: {got!r} -> {v2!r}")
        elif have.get(key) != value:
            drift += 1
            print(f"   drift {section}.{key}: {have.get(key)!r} -> {value!r}")
print("   resilience settings match" if not drift else f"   {drift} setting(s) off posture")
sys.exit(0)
'
}

oauth_connections_with_protection() {
	# Connection ids whose auth is OAuth and whose local gate is still on.
	# authType comes from the resilience view; the gate state from rate-limits.
	local conns limits
	conns=$(api "$BASE/api/resilience/connections")
	limits=$(api "$BASE/api/rate-limits")
	CONNS="$conns" LIMITS="$limits" python3 -c '
import json, os
oauth = {
    c["id"]: c.get("name") or c["id"]
    for c in json.loads(os.environ["CONNS"])["connections"]
    if c.get("authType") == "oauth"
}
for row in json.loads(os.environ["LIMITS"])["connections"]:
    cid = row["connectionId"]
    if cid in oauth and row.get("rateLimitProtection"):
        print(cid, row.get("provider"), oauth[cid])
'
}

if [ "$mode" = "--check" ]; then
	log "resilience posture"
	report_drift
	log "OAuth seats with the local rate-limit gate still on"
	if [ -z "$(oauth_connections_with_protection)" ]; then
		echo "   none"
	else
		oauth_connections_with_protection | sed 's/^/   /'
	fi
	exit 0
fi

log "asserting resilience settings"
api -X PATCH -H 'Content-Type: application/json' -d "$desired" "$BASE/api/resilience" >/dev/null
report_drift

log "clearing the local rate-limit gate on OAuth seats"
cleared=0
while read -r cid provider name; do
	[ -n "$cid" ] || continue
	api -X POST -H 'Content-Type: application/json' \
		-d "{\"connectionId\":\"$cid\",\"enabled\":false}" "$BASE/api/rate-limits" >/dev/null
	printf '   cleared %s (%s)\n' "$name" "$provider"
	cleared=$((cleared + 1))
done < <(oauth_connections_with_protection)
[ "$cleared" -gt 0 ] || echo "   already clear"
