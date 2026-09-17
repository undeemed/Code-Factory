#!/usr/bin/env bash
# Recreate the omniroute container with chat-admission headroom.
#
# WHY: the default structural gate is OMNIROUTE_CHAT_MAX_HEAVY_IN_FLIGHT=1 — ONE
# "heavy" chat request router-wide, where heavy means >=256KB body, >=200
# messages, >=64 tools, or >=32k estimated tokens. Every real agent turn on a
# repo clears 32k tokens, so a fleet of lanes serializes onto a single lease and
# the losers get `503 chat_admission_busy` after a 2s wait. That reads as "Fable
# and Opus never work", because only the big-context models ever trip it while
# the small smol/tiny prompts sail through.
#
# The gate protects a 1GB node heap while parked waiters hold fully buffered
# bodies, so raising concurrency alone would just move the failure to OOM. Heap
# and the queued-bytes budget go up with it.
#
# Env changes need a new container, which DISCARDS the writable-layer patches
# (claude-cli version pin, system-role fix). This re-applies and verifies both.
set -euo pipefail

MAINT="$HOME/Code-Factory/maintenance"
HEAVY_IN_FLIGHT=${HEAVY_IN_FLIGHT:-6}
# Raise what counts as "heavy" so ordinary agent turns never take a lease at all.
# The 32k default classifies every real repo turn as heavy; 128k reserves the gate
# for genuinely huge bodies, which is what it was built for.
HEAVY_TOKENS=${HEAVY_TOKENS:-128000}
QUEUE_MS=${QUEUE_MS:-20000}
QUEUED_BYTES=${QUEUED_BYTES:-$((32 * 1024 * 1024))}
HEAP_MB=${HEAP_MB:-3072}
docker="docker"
if ! docker info >/dev/null 2>&1; then docker="sudo docker"; fi

echo "== carrying over existing env (minus the knobs we are changing)"
mapfile -t CARRY < <(
	$docker inspect omniroute --format '{{range .Config.Env}}{{println .}}{{end}}' |
		grep -vE '^(PATH|NODE_VERSION|HOSTNAME)=' |
		grep -vE '^(OMNIROUTE_MEMORY_MB|NODE_OPTIONS|OMNIROUTE_CHAT_)' |
		grep -vE '^$' | sort -u
)
printf '   carried %d env vars\n' "${#CARRY[@]}"

args=(run -d --name omniroute --restart unless-stopped -p 20128:20128 -v omniroute-data:/app/data)
for kv in "${CARRY[@]}"; do args+=(--env "$kv"); done
args+=(
	--env "OMNIROUTE_MEMORY_MB=$HEAP_MB"
	--env "NODE_OPTIONS=--max-old-space-size=$HEAP_MB"
	--env "OMNIROUTE_CHAT_MAX_HEAVY_IN_FLIGHT=$HEAVY_IN_FLIGHT"
	--env "OMNIROUTE_CHAT_HEAVY_ESTIMATED_TOKENS=$HEAVY_TOKENS"
	--env "OMNIROUTE_CHAT_ADMISSION_QUEUE_MS=$QUEUE_MS"
	--env "OMNIROUTE_CHAT_ADMISSION_MAX_QUEUED_BYTES=$QUEUED_BYTES"
	diegosouzapw/omniroute:main
)

echo "== replacing container (data persists in the omniroute-data volume)"
$docker stop omniroute >/dev/null
$docker rm omniroute >/dev/null
$docker "${args[@]}" >/dev/null

echo "== waiting for health"
for _ in $(seq 1 60); do
	if curl -fsS -o /dev/null --max-time 5 http://localhost:20128/api/health; then
		echo "   healthy"
		break
	fi
	sleep 2
done

echo "== re-applying writable-layer patches"
bash "$MAINT/omniroute-system-role-patch.sh" omniroute
bash "$MAINT/omniroute-claude-client-version.sh" omniroute

echo "== verification"
bash "$MAINT/omniroute-system-role-patch.sh" omniroute --check
bash "$MAINT/omniroute-claude-client-version.sh" omniroute --check
$docker inspect omniroute --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -E 'CHAT_|MEMORY_MB'
