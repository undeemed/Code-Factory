#!/usr/bin/env bash
# Keep `system` as `system` in OmniRoute's chat -> Responses translation.
#
# OmniRoute rewrites mid-conversation system turns to `role: "developer"` input
# items (open-sse/translator/request/openai-responses/toResponses.ts). Zed's
# hosted endpoint (cloud.zed.dev/completions) accepts only
# user/assistant/system/tool, so every request carrying a system prompt — i.e.
# every agent request — fails with:
#
#   400 failed to parse OpenAI Responses API request: unknown variant `developer`
#
# The Responses API accepts `system` as well, so emitting `system` is strictly
# more compatible. Codex's own executor does its own system->developer handling
# for cache reasons and is not touched by this patch.
#
# The container ships a prebuilt Next server, so both the built chunks and the
# TypeScript source are patched. The edit lives in the container's writable
# layer: it survives `docker restart` but NOT `docker rm` / an image update.
# Re-run this script after pulling a new omniroute image.
#
# Usage: maintenance/omniroute-system-role-patch.sh [container] [--check]
set -euo pipefail

container="${1:-omniroute}"
mode="${2:-apply}"
docker="docker"
if ! docker info >/dev/null 2>&1; then docker="sudo docker"; fi

chunk_pattern='role:"developer",content:function'
chunk_replacement='role:"system",content:function'
source_file=/app/open-sse/translator/request/openai-responses/toResponses.ts

remaining() {
	$docker exec "$container" sh -lc \
		"grep -rl '$chunk_pattern' /app/.build/next/server/chunks/*.js 2>/dev/null | wc -l"
}

if [ "$mode" = "--check" ]; then
	count="$(remaining)"
	if [ "$count" -eq 0 ]; then
		echo "omniroute system-role patch: applied"
	else
		echo "omniroute system-role patch: MISSING in $count chunk(s) — re-run this script" >&2
		exit 1
	fi
	exit 0
fi

$docker exec "$container" sh -lc "
set -e
patched=0
for f in /app/.build/next/server/chunks/*.js; do
	if grep -q '$chunk_pattern' \"\$f\"; then
		cp -n \"\$f\" \"\$f.orig\" 2>/dev/null || true
		sed -i 's/$chunk_pattern/$chunk_replacement/g' \"\$f\"
		patched=\$((patched + 1))
	fi
done
if grep -q 'role: \"developer\",' $source_file 2>/dev/null; then
	cp -n $source_file $source_file.orig 2>/dev/null || true
	sed -i 's/        role: \"developer\",/        role: \"system\",/' $source_file
fi
echo \"patched \$patched chunk(s)\"
"

$docker restart "$container" >/dev/null
echo "restarted $container; waiting for health"
for _ in $(seq 1 30); do
	if curl -fsS -o /dev/null --max-time 5 http://localhost:20128/api/health; then
		echo "omniroute healthy; patch applied"
		exit 0
	fi
	sleep 2
done
echo "omniroute did not report healthy in time" >&2
exit 1
