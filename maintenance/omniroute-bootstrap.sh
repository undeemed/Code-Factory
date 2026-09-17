#!/usr/bin/env bash
# Provision (or re-provision) OmniRoute on this host: the AI gateway every OMP
# model role routes through.
#
# Idempotent. With no container present it creates one; with a container present
# and --recreate it replaces it, carrying the existing env forward. Either way it
# ends with the reviewed admission/heap configuration, the two writable-layer
# patches applied, and omp's model list regenerated from the running router.
#
# Secrets never live in this repository. On a fresh host the three OmniRoute
# secrets are generated and appended to the account's own super.env; an existing
# super.env or a live container is reused as-is so a re-run never rotates a
# working deployment's keys.
#
# Usage:
#   omniroute-bootstrap.sh                 # create if absent, else verify + patch
#   omniroute-bootstrap.sh --recreate      # replace the container (env changes)
#   omniroute-bootstrap.sh --check         # report configuration drift, change nothing
#
# Why each knob is where it is: docs/omniroute-resilience.md.
set -euo pipefail

IMAGE=${OMNIROUTE_IMAGE:-diegosouzapw/omniroute:main}
NAME=${OMNIROUTE_NAME:-omniroute}
PORT=${OMNIROUTE_PORT:-20128}
VOLUME=${OMNIROUTE_VOLUME:-omniroute-data}
ENV_FILE=${OMNIROUTE_ENV_FILE:-$HOME/super.env}
MAINT=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
REPO=$(cd "$MAINT/.." && pwd)

# Chat-admission and heap settings. The shipped defaults serialize a coding fleet
# onto a single heavyweight lease (heavy = >=32k estimated tokens, 1 in flight),
# which surfaces as `503 chat_admission_busy` on every large-context turn.
HEAVY_TOKENS=${HEAVY_TOKENS:-45000}
HEAVY_IN_FLIGHT=${HEAVY_IN_FLIGHT:-6}
QUEUE_MS=${QUEUE_MS:-20000}
QUEUED_BYTES=${QUEUED_BYTES:-$((32 * 1024 * 1024))}
HEAP_MB=${HEAP_MB:-3072}

mode=${1:-ensure}
docker="docker"
if ! docker info >/dev/null 2>&1; then docker="sudo docker"; fi

log() { printf '== %s\n' "$*"; }

container_exists() { $docker inspect "$NAME" >/dev/null 2>&1; }

wait_healthy() {
	for _ in $(seq 1 60); do
		if curl -fsS -o /dev/null --max-time 5 "http://localhost:$PORT/api/health"; then
			log "healthy on :$PORT"
			return 0
		fi
		sleep 2
	done
	echo "omniroute did not become healthy on :$PORT" >&2
	return 1
}

read_env_value() {
	# Existing value from super.env, empty when absent.
	[ -f "$ENV_FILE" ] || return 0
	sed -n "s/^$1=//p" "$ENV_FILE" | tail -1
}

ensure_secret() {
	# Reuse the recorded secret; mint one only when the host has none, so a re-run
	# never invalidates existing API keys or the dashboard password.
	local key=$1 bytes=$2 value
	value=$(read_env_value "$key")
	if [ -z "$value" ]; then
		value=$(openssl rand -hex "$bytes")
		printf '%s=%s\n' "$key" "$value" >>"$ENV_FILE"
		log "minted $key into $ENV_FILE"
	fi
	printf '%s' "$value"
}

if [ "$mode" = "--check" ]; then
	if ! container_exists; then
		echo "omniroute: no container named $NAME" >&2
		exit 1
	fi
	log "container env"
	$docker inspect "$NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' |
		grep -E 'OMNIROUTE_CHAT_|OMNIROUTE_MEMORY_MB' | sort
	log "writable-layer patches"
	bash "$MAINT/omniroute-system-role-patch.sh" "$NAME" --check
	bash "$MAINT/omniroute-claude-client-version.sh" "$NAME" --check
	exit 0
fi

if container_exists && [ "$mode" != "--recreate" ]; then
	log "container exists; verifying patches only (use --recreate to change env)"
	wait_healthy
	bash "$MAINT/omniroute-system-role-patch.sh" "$NAME" >/dev/null || true
	bash "$MAINT/omniroute-claude-client-version.sh" "$NAME" >/dev/null || true
else
	args=(run -d --name "$NAME" --restart unless-stopped -p "$PORT:$PORT" -v "$VOLUME:/app/data")

	if container_exists; then
		log "carrying existing env forward (minus the knobs this script owns)"
		mapfile -t CARRY < <(
			$docker inspect "$NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' |
				grep -vE '^(PATH|NODE_VERSION|HOSTNAME)=' |
				grep -vE '^(OMNIROUTE_MEMORY_MB|NODE_OPTIONS|OMNIROUTE_CHAT_)' |
				grep -vE '^$' | sort -u
		)
		for kv in "${CARRY[@]}"; do args+=(--env "$kv"); done
		log "stopping and removing $NAME (data stays in the $VOLUME volume)"
		$docker stop "$NAME" >/dev/null
		$docker rm "$NAME" >/dev/null
	else
		log "fresh install: resolving secrets from $ENV_FILE"
		touch "$ENV_FILE"
		chmod 600 "$ENV_FILE"
		jwt=$(ensure_secret OMNIROUTE_JWT_SECRET 32)
		api_secret=$(ensure_secret OMNIROUTE_API_KEY_SECRET 32)
		initial_password=$(ensure_secret OMNIROUTE_PASSWORD 16)
		base_url=$(read_env_value OMNIROUTE_DASHBOARD)
		: "${base_url:=http://127.0.0.1:$PORT}"
		args+=(
			--env "JWT_SECRET=$jwt"
			--env "API_KEY_SECRET=$api_secret"
			--env "INITIAL_PASSWORD=$initial_password"
			--env "DATA_DIR=/app/data"
			--env "PORT=$PORT"
			--env "NODE_ENV=production"
			--env "APP_BIND_HOST=0.0.0.0"
			--env "ENABLE_REQUEST_LOGS=false"
			--env "REQUIRE_API_KEY=false"
			--env "AUTH_COOKIE_SECURE=false"
			--env "BASE_URL=$base_url"
			--env "NEXT_PUBLIC_BASE_URL=$base_url"
			--env "OMNIROUTE_MIGRATIONS_DIR=/app/migrations"
		)
	fi

	args+=(
		--env "OMNIROUTE_MEMORY_MB=$HEAP_MB"
		--env "NODE_OPTIONS=--max-old-space-size=$HEAP_MB"
		--env "OMNIROUTE_CHAT_MAX_HEAVY_IN_FLIGHT=$HEAVY_IN_FLIGHT"
		--env "OMNIROUTE_CHAT_HEAVY_ESTIMATED_TOKENS=$HEAVY_TOKENS"
		--env "OMNIROUTE_CHAT_ADMISSION_QUEUE_MS=$QUEUE_MS"
		--env "OMNIROUTE_CHAT_ADMISSION_MAX_QUEUED_BYTES=$QUEUED_BYTES"
		"$IMAGE"
	)

	log "starting $NAME from $IMAGE"
	$docker "${args[@]}" >/dev/null
	wait_healthy

	log "applying writable-layer patches (discarded by docker rm / image pull)"
	bash "$MAINT/omniroute-system-role-patch.sh" "$NAME"
	bash "$MAINT/omniroute-claude-client-version.sh" "$NAME"
fi

log "regenerating omp's model list from the running router"
if [ -n "$(read_env_value OMNIROUTE_API_KEY)" ]; then
	python3 "$REPO/scripts/sync_omniroute_models.py" --no-probe \
		--base-url "http://127.0.0.1:$PORT/v1" || true
else
	echo "   no OMNIROUTE_API_KEY in $ENV_FILE yet — mint an endpoint key in the" >&2
	echo "   dashboard, record it there, then run scripts/sync_omniroute_models.py" >&2
fi

log "configuration"
$docker inspect "$NAME" --format '{{range .Config.Env}}{{println .}}{{end}}' |
	grep -E 'OMNIROUTE_CHAT_|OMNIROUTE_MEMORY_MB' | sort
bash "$MAINT/omniroute-system-role-patch.sh" "$NAME" --check
bash "$MAINT/omniroute-claude-client-version.sh" "$NAME" --check
