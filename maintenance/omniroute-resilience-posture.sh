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
#   rateLimitProtection = off for every OAuth seat EXCEPT the capped ones
#     It is a local admission gate meant for metered API keys. On an OAuth seat
#     with no cap it queues the request locally instead of failing over, which
#     surfaces as `504 local rate-limit execution expiration` while a healthy
#     seat idles. Claude is the exception: Anthropic's real ceiling on a Max
#     seat is CONCURRENCY (measured ~3-4 heavy agent turns), and exceeding it
#     earns `403 Request not allowed`, which this router reads as a permanent
#     ban. So Claude seats keep the gate ON with a per-seat cap of
#     CLAUDE_SEAT_CONCURRENCY, which converts a ban into a short local queue.
#     Verified 2026-09-17: 8 concurrent 400-token requests held at exactly 3
#     executing, all 200, neither seat rate-limited or banned.
#
#     Caveat: per-connection overrides load ONCE per process
#     (`initializeRateLimits` is guarded by an `initialized` flag) and
#     `refreshConnectionRateLimits()` has no caller upstream, so a changed cap
#     needs a container restart to take effect. This script reports when that
#     applies.
#
# Usage:
#   omniroute-resilience-posture.sh            # assert (idempotent)
#   omniroute-resilience-posture.sh --check    # report drift, change nothing
set -euo pipefail

PORT=${OMNIROUTE_PORT:-20128}
ENV_FILE=${OMNIROUTE_ENV_FILE:-$HOME/super.env}
BASE=${OMNIROUTE_BASE:-http://127.0.0.1:$PORT}
mode=${1:-assert}

# Providers whose OAuth seats keep the local gate ON behind a per-seat cap,
# because their real ceiling is concurrency and overrunning it earns a ban.
CAPPED_PROVIDERS=${OMNIROUTE_CAPPED_PROVIDERS:-claude}
SEAT_CONCURRENCY=${OMNIROUTE_SEAT_CONCURRENCY:-3}
SEAT_QUEUE_MS=${OMNIROUTE_SEAT_QUEUE_MS:-12000}
# Quiet period a seat must observe before its stale local flag is cleared.
SEAT_REVIVE_GRACE_SEC=${OMNIROUTE_SEAT_REVIVE_GRACE_SEC:-300}

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
    "oauth":  { "baseCooldownMs": 5000, "useUpstreamRetryHints": true, "maxBackoffSteps": 4 },
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

is_capped() {
	case " $CAPPED_PROVIDERS " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

stale_flag_seats() {
	# "cid provider name" for OAuth seats parked on a local flag that has
	# outlived its cause: `banned`/`unavailable`, no cooldown left, and quiet
	# for SEAT_REVIVE_GRACE_SEC.
	#
	# `banned` is OmniRoute's OWN flag, not an Anthropic account state: one code
	# path sets it (any FORBIDDEN classification in chatCore) and nothing in the
	# tree ever clears it. A burst-induced 403 therefore costs a healthy seat
	# until a human notices. This is that human.
	api "$BASE/api/resilience/connections" | GRACE="$SEAT_REVIVE_GRACE_SEC" python3 -c '
import json, os, sys
from datetime import datetime, timezone

grace = float(os.environ["GRACE"])
now = datetime.now(timezone.utc)
for c in json.load(sys.stdin)["connections"]:
    if c.get("authType") != "oauth":
        continue
    if c.get("testStatus") not in ("banned", "unavailable"):
        continue
    # Respect a live cooldown: the upstream window is not ours to shorten.
    if c.get("isCoolingDown") or (c.get("cooldownRemainingMs") or 0) > 0:
        continue
    stamp = c.get("lastErrorAt")
    if stamp:
        try:
            when = datetime.fromisoformat(str(stamp).replace("Z", "+00:00"))
        except ValueError:
            when = None
        if when is not None and (now - when).total_seconds() < grace:
            continue
    print(c["id"], c.get("provider") or "?", c.get("name") or c["id"])
'
}

oauth_seats() {
	# "cid provider gate name" for every OAuth connection.
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
    if cid in oauth:
        print(cid, row.get("provider") or "?", 1 if row.get("rateLimitProtection") else 0, oauth[cid])
'
}

seat_cap() {
	# Persisted per-seat override for one connection: "maxConcurrent maxWaitMs".
	api "$BASE/api/providers" | CID="$1" python3 -c '
import json, os, sys
raw = json.load(sys.stdin)
rows = raw if isinstance(raw, list) else (raw.get("providers") or raw.get("connections") or raw.get("data") or [])
for row in rows:
    if row.get("id") == os.environ["CID"]:
        ov = row.get("rateLimitOverrides") or {}
        print(ov.get("maxConcurrent", "-"), ov.get("maxWaitMs", "-"))
        break
else:
    print("- -")
'
}

report_seats() {
	local found=0 cid provider gate name cap qwait
	while read -r cid provider gate name; do
		[ -n "$cid" ] || continue
		found=1
		if is_capped "$provider"; then
			read -r cap qwait <<<"$(seat_cap "$cid")"
			if [ "$gate" = 1 ] && [ "$cap" = "$SEAT_CONCURRENCY" ] && [ "$qwait" = "$SEAT_QUEUE_MS" ]; then
				printf '   %s (%s) capped at %s concurrent, %sms queue\n' "$name" "$provider" "$cap" "$qwait"
			else
				printf '   %s (%s) off posture: gate=%s cap=%s queue=%s -> want gate=1 cap=%s queue=%s\n' \
					"$name" "$provider" "$gate" "$cap" "$qwait" "$SEAT_CONCURRENCY" "$SEAT_QUEUE_MS"
			fi
		elif [ "$gate" = 1 ]; then
			printf '   %s (%s) off posture: local gate on with no cap -> want gate off\n' "$name" "$provider"
		else
			printf '   %s (%s) gate off\n' "$name" "$provider"
		fi
	done < <(oauth_seats)
	[ "$found" = 1 ] || echo "   no OAuth seats"
}

if [ "$mode" = "--check" ]; then
	log "resilience posture"
	report_drift
	log "OAuth seats"
	report_seats
	log "OAuth seats parked on a stale local flag"
	if [ -z "$(stale_flag_seats)" ]; then
		echo "   none"
	else
		stale_flag_seats | sed 's/^/   /'
	fi
	exit 0
fi

log "asserting resilience settings"
api -X PATCH -H 'Content-Type: application/json' -d "$desired" "$BASE/api/resilience" >/dev/null
report_drift

log "reviving OAuth seats parked on a stale local flag"
revived=0
while read -r cid provider name; do
	[ -n "$cid" ] || continue
	api -X PATCH -H 'Content-Type: application/json' \
		-d '{"isActive":true,"testStatus":"active","errorCode":null,"lastError":null}' \
		"$BASE/api/providers/$cid" >/dev/null
	printf '   revived %s (%s)\n' "$name" "$provider"
	revived=$((revived + 1))
done < <(stale_flag_seats)
[ "$revived" -gt 0 ] || echo "   none parked"

log "asserting per-seat posture on OAuth seats"
restart_needed=0
changed=0
while read -r cid provider gate name; do
	[ -n "$cid" ] || continue
	if is_capped "$provider"; then
		read -r cap qwait <<<"$(seat_cap "$cid")"
		if [ "$cap" != "$SEAT_CONCURRENCY" ] || [ "$qwait" != "$SEAT_QUEUE_MS" ]; then
			api -X PATCH -H 'Content-Type: application/json' \
				-d "{\"maxConcurrent\":$SEAT_CONCURRENCY,\"rateLimitOverrides\":{\"maxConcurrent\":$SEAT_CONCURRENCY,\"maxWaitMs\":$SEAT_QUEUE_MS}}" \
				"$BASE/api/providers/$cid" >/dev/null
			printf '   capped %s (%s) at %s concurrent, %sms queue\n' "$name" "$provider" "$SEAT_CONCURRENCY" "$SEAT_QUEUE_MS"
			restart_needed=1
			changed=1
		fi
		if [ "$gate" != 1 ]; then
			api -X POST -H 'Content-Type: application/json' \
				-d "{\"connectionId\":\"$cid\",\"enabled\":true}" "$BASE/api/rate-limits" >/dev/null
			printf '   gate on for %s (%s)\n' "$name" "$provider"
			changed=1
		fi
	elif [ "$gate" = 1 ]; then
		api -X POST -H 'Content-Type: application/json' \
			-d "{\"connectionId\":\"$cid\",\"enabled\":false}" "$BASE/api/rate-limits" >/dev/null
		printf '   cleared %s (%s)\n' "$name" "$provider"
		changed=1
	fi
done < <(oauth_seats)
[ "$changed" -gt 0 ] || echo "   already on posture"

if [ "$restart_needed" = 1 ]; then
	log "a per-seat cap changed - restart to load it"
	echo "   sudo docker restart omniroute   # overrides load once per process"
fi
