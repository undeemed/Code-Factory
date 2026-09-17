#!/usr/bin/env bash
# Keep OmniRoute's pinned Claude Code client version in step with the real CLI.
#
# The native `claude` provider presents a captured claude-cli identity
# (src/shared/constants/claudeCodeClient.ts: user agent, billing header,
# x-app version). Anthropic rejects a stale identity with
#
#   403 Request not allowed
#
# and OmniRoute treats a 403 as a permanent ban: it marks the connection
# `test_status=banned` and drops it from rotation, which reads as "my account
# keeps turning itself off". On 2026-09-17 the image pinned 2.1.220 while the
# installed CLI was 2.1.274; both Claude Max accounts were banned within the
# hour, and bumping the pin restored them immediately.
#
# The edit lives in the container's writable layer: it survives
# `docker restart` but NOT `docker rm` / an image update. Re-run after
# `docker pull`, and any time Claude Code updates on the host.
#
# Usage: maintenance/omniroute-claude-client-version.sh [container] [version|--check]
set -euo pipefail

container="${1:-omniroute}"
want="${2:-}"
docker="docker"
if ! docker info >/dev/null 2>&1; then docker="sudo docker"; fi

constants=/app/src/shared/constants/claudeCodeClient.ts

pinned() {
	$docker exec "$container" sh -lc \
		"grep -o 'CLAUDE_CODE_CLIENT_VERSION = \"[0-9.]*\"' $constants | grep -o '[0-9][0-9.]*'"
}

installed() {
	claude --version 2>/dev/null | grep -o '^[0-9][0-9.]*' || true
}

current="$(pinned)"

if [ "$want" = "--check" ]; then
	local_version="$(installed)"
	echo "omniroute pins claude-cli/$current; host CLI reports ${local_version:-unknown}"
	if [ -n "$local_version" ] && [ "$local_version" != "$current" ]; then
		echo "pin is stale — re-run this script to bump it" >&2
		exit 1
	fi
	exit 0
fi

if [ -z "$want" ]; then
	want="$(installed)"
fi
if [ -z "$want" ]; then
	echo "no version given and no claude CLI on PATH to read one from" >&2
	exit 2
fi
if [ "$want" = "$current" ]; then
	echo "already pinned to claude-cli/$current"
	exit 0
fi

echo "bumping pinned claude-cli $current -> $want"
$docker exec "$container" sh -lc "
set -e
patched=0
for f in /app/.build/next/server/chunks/*.js; do
	if grep -q '$current' \"\$f\"; then
		cp -n \"\$f\" \"\$f.origver\" 2>/dev/null || true
		sed -i 's/$current/$want/g' \"\$f\"
		patched=\$((patched + 1))
	fi
done
sed -i 's/$current/$want/' $constants
echo \"patched \$patched chunk(s)\"
"

$docker restart "$container" >/dev/null
for _ in $(seq 1 30); do
	if curl -fsS -o /dev/null --max-time 5 http://localhost:20128/api/health; then
		echo "omniroute healthy on claude-cli/$want"
		echo "clear any banned claude connections:"
		echo "  PATCH /api/providers/<id> {\"isActive\":true,\"testStatus\":\"active\",\"errorCode\":null,\"lastError\":null}"
		exit 0
	fi
	sleep 2
done
echo "omniroute did not report healthy in time" >&2
exit 1
