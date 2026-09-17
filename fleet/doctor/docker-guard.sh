#!/usr/bin/env bash
# docker-guard.sh - ONE Supabase stack per box, enforced at the only chokepoint.
#
# Why: every swarms-platform lane used to `supabase start` its own 12-container
# stack (plus stray `docker run postgres`) to get the app to boot for a
# screenshot. Two full stacks + three orphan Postgres containers were found on
# 2026-09-17 during a swap-exhaustion incident. Briefs and PATH shims cannot
# stop `npx supabase start` (it resolves to the worktree's node_modules), and
# the Supabase CLI talks to dockerd directly, so the guard lives at the Docker
# event stream: every container `create` is inspected the moment it happens.
#
# Policy (docker-guard-allow.txt, one entry per line):
#   project:<id>   Supabase CLI project allowed to run. Anything else carrying
#                  com.supabase.cli.project is removed on creation.
#   <glob>         container-name glob whose bare Postgres-family image
#                  (postgres, pgvector, timescale, supabase/postgres) is
#                  tolerated. Other bare Postgres containers are NOT killed -
#                  other mates may own them - but each one is logged and
#                  alerted so nothing accumulates silently again.
#
# Every action: docker-guard.log here, a line in COMMS.md for the
# orchestrator, and notify-master.sh (the box's one alert path).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ALLOW=$HERE/docker-guard-allow.txt
LOG=$HERE/docker-guard.log
COMMS=$HERE/COMMS.md
SHARED_README="$HOME/oss-fleet/shared-supabase/README.md"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
comms() {
  printf '\n## [docker-guard -> orchestrator] %s %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$COMMS"
}
alert() { [ -x "$HERE/notify-master.sh" ] && "$HERE/notify-master.sh" "$1" "docker-guard" >/dev/null 2>&1; return 0; }

allowed_project() { grep -qxF -- "project:$1" "$ALLOW" 2>/dev/null; }
allowed_name() {
  local name=$1 pat
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in project:*|\#*) continue ;; esac
    # shellcheck disable=SC2254
    case "$name" in $pat) return 0 ;; esac
  done < "$ALLOW"
  return 1
}
is_pg_image() {
  printf '%s' "$1" | grep -qiE '(^|/)(postgres|postgresql|pgvector|timescale(db)?|supabase/postgres)([:@]|$)'
}

# Bare-postgres alerts are de-duplicated per container id for the life of this
# process; the startup sweep therefore alerts once per restart, not per event.
declare -A seen_alert=()

handle() {
  local id=$1 name=$2 image=$3 project=$4
  if [ -n "$project" ]; then
    if allowed_project "$project"; then
      return 0
    fi
    if docker rm -f "$id" >/dev/null 2>&1; then
      log "KILLED $name image=$image supabase-project=$project - only the shared stack may run (see $SHARED_README)"
      comms "KILLED a second Supabase stack: container $name (project $project). The fleet runs ONE shared stack at http://127.0.0.1:54321; lanes must not run supabase start. Brief rules: data/swarms-brief-rules.md."
      alert "docker-guard killed $name (supabase project $project) - a lane tried to start its own stack"
    else
      log "FAILED to remove $name ($id) project=$project"
    fi
    return 0
  fi
  if is_pg_image "$image"; then
    allowed_name "$name" && return 0
    if [ -z "${seen_alert[$id]:-}" ]; then
      seen_alert[$id]=1
      log "ALERT bare postgres container $name image=$image - not killed; allowlist it in $ALLOW or remove it"
      comms "ALERT: bare Postgres container $name ($image) exists outside the shared stack. Not killed (owner unknown). Remove it or add its name to doctor/docker-guard-allow.txt."
      alert "docker-guard: bare postgres container $name ($image) outside the shared stack"
    fi
  fi
  return 0
}

sweep() {
  docker ps -a --format '{{.ID}}|{{.Names}}|{{.Image}}|{{.Label "com.supabase.cli.project"}}' 2>/dev/null \
  | while IFS='|' read -r id name image project; do
      [ -n "$id" ] && handle "$id" "$name" "$image" "$project"
    done
}

[ -f "$ALLOW" ] || { log "allowlist $ALLOW missing - refusing to run without it"; exit 1; }
until docker info >/dev/null 2>&1; do sleep 5; done
log "start: sweep + event watch (allowlist: $(grep -cvE '^(#|$)' "$ALLOW") entries)"
sweep

# `docker events` blocks for the daemon's lifetime; systemd Restart=always
# brings us back (with a fresh sweep) if dockerd restarts.
docker events --filter type=container --filter event=create \
  --format '{{.Actor.ID}}|{{.Actor.Attributes.name}}|{{.Actor.Attributes.image}}|{{index .Actor.Attributes "com.supabase.cli.project"}}' \
| while IFS='|' read -r id name image project; do
    [ -n "$id" ] && handle "$id" "$name" "$image" "$project"
  done
log "docker events stream ended - exiting for restart"
exit 1
