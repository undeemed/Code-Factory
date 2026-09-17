#!/usr/bin/env bash
# check.sh - keep the ONE shared Supabase stack up and guarded. Idempotent.
#
# Runs at login (flotilla-shared-supabase.service) and every 5 minutes
# (flotilla-shared-supabase-check.timer). `supabase start` on a running stack
# is a no-op; on a stopped one it recreates the missing containers from the
# existing volumes (no migrations, no seed - the DB volume is the fixture).
# After the stack is healthy the DDL guard is (re)applied, so a `db reset`
# that somehow got through would still end with the guard back in place.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LOG=$HERE/check.log
SB=$HERE/node_modules/.bin/supabase
# Container names follow the project_id in supabase/config.toml.
PROJECT=$(sed -nE 's/^project_id = "(.*)"/\1/p' "$HERE/supabase/config.toml")
DB=supabase_db_${PROJECT:-swarms-shared}
# One keeper at a time: the login unit, the 5-minute timer and a human can
# overlap, and two guard.sql runs racing produce "tuple concurrently updated"
# or, worse, one run's DROP EVENT TRIGGER landing after the other's CREATE.
exec 9>"$HERE/.check.lock"
flock -w 600 9 || exit 1
log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
# The box's one alert path when present (oss-fleet/doctor/notify-master.sh);
# a fresh host without it still gets the log line.
notify() { [ -x "$HOME/oss-fleet/doctor/notify-master.sh" ] && "$HOME/oss-fleet/doctor/notify-master.sh" "$1" "$2" >/dev/null 2>&1; return 0; }

cd "$HERE" || exit 1
if ! docker info >/dev/null 2>&1; then
  log "docker not reachable - retry next tick"
  exit 0
fi

need_start=0
if ! docker inspect --format '{{.State.Running}}' "$DB" 2>/dev/null | grep -qx true; then
  need_start=1
else
  # A partially-down stack (someone `docker rm -f`'d one service) still needs start.
  for svc in kong auth rest studio storage pg_meta realtime; do
    docker inspect --format '{{.State.Running}}' "supabase_${svc}_${PROJECT:-swarms-shared}" 2>/dev/null | grep -qx true || { need_start=1; break; }
  done
fi

if [ "$need_start" -eq 1 ]; then
  log "stack not (fully) running - supabase start"
  if ! timeout 600 "$SB" start >> "$LOG" 2>&1; then
    log "supabase start FAILED (see above)"
    notify "shared-supabase: supabase start failed; lanes cannot boot swarms-platform" "shared-supabase down"
    exit 1
  fi
  log "stack started"
fi

# Wait for postgres, then (re)apply the guard. Both statements are idempotent.
for _ in $(seq 1 30); do
  docker exec "$DB" pg_isready -U postgres -q 2>/dev/null && break
  sleep 2
done
# supabase_admin has no trust entry on the unix socket; TCP with the local
# password (the CLI's fixed `postgres`) is the documented way in.
if docker exec -i -e PGPASSWORD=postgres "$DB" psql -v ON_ERROR_STOP=1 -h 127.0.0.1 -U supabase_admin -d postgres -q < "$HERE/guard.sql" >> "$LOG" 2>&1; then
  :
else
  log "guard.sql apply FAILED"
  notify "shared-supabase: DDL guard failed to apply" "shared-supabase guard"
  exit 1
fi

# The app env every swarms worktree receives (installed by worktree-env-seed.sh).
# Generated from the running stack, so a rebuilt host needs no hand step and the
# keys always match the stack that is actually answering on :54321. Never
# regenerated once present: operators may append project secrets to it.
ENV_OUT=$HERE/swarms-platform.env.local
if [ ! -s "$ENV_OUT" ]; then
  status=$("$SB" status -o env 2>/dev/null) || status=
  anon=$(printf '%s\n' "$status" | sed -nE 's/^ANON_KEY="(.*)"/\1/p')
  srk=$(printf '%s\n' "$status" | sed -nE 's/^SERVICE_ROLE_KEY="(.*)"/\1/p')
  api=$(printf '%s\n' "$status" | sed -nE 's/^API_URL="(.*)"/\1/p')
  if [ -n "$anon" ] && [ -n "$srk" ] && [ -n "$api" ]; then
    umask 077
    cat > "$ENV_OUT.tmp" <<ENV
# fleet-shared-supabase  (marker: do not remove; the fleet re-seeds files without it)
# ONE shared Supabase stack for every swarms-platform lane. READ-ONLY TEST FIXTURE.
# Never: supabase start/stop/db reset/migrations, docker postgres, psql writes. See $HERE/README.md
# Test account for logged-in screenshots: fleet-tester@example.test / fleet-tester-2026  (or sign up via UI; mail lands at Mailpit :54324)
NEXT_PUBLIC_SITE_URL=http://localhost:3000
NEXT_PUBLIC_SUPABASE_URL=$api
NEXT_PUBLIC_SUPABASE_ANON_KEY=$anon
SUPABASE_SERVICE_ROLE_KEY=$srk
STRIPE_SECRET_KEY="sk_test_placeholder"
NEXT_PUBLIC_STRIPE_PUBLISHABLE_KEY="pk_test_placeholder"
STRIPE_WEBHOOK_SECRET="whsec_placeholder"
RESEND_API_KEY="re_placeholder"
JWT_SECRET="local-dev-only-jwt-secret-not-for-production"
ENV
    mv "$ENV_OUT.tmp" "$ENV_OUT" && log "generated $ENV_OUT from the running stack"
  else
    log "could not read stack keys for $ENV_OUT (supabase status empty) - retry next tick"
  fi
fi
exit 0
