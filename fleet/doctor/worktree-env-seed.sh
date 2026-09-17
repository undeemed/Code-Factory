#!/usr/bin/env bash
# worktree-env-seed.sh - every swarms-platform checkout gets the shared-backend
# .env.local, automatically, forever.
#
# Root cause this closes: treehouse hands lanes a worktree with only
# .env.example; the app refuses to boot without a Supabase URL/key
# (CONTRIBUTING.md: "Your project's URL and Key are required"), so each agent
# built its own backend. Treehouse has no post-create hook, so this runs from
# systemd: on every change to the pool directory (new worktree), on a 2-minute
# timer (new pools, deleted files), and at login.
#
# Source of truth: ~/oss-fleet/shared-supabase/swarms-platform.env.local, which
# carries the marker line below. A worktree file without the marker is an
# agent-written placeholder file and is replaced (backup kept beside it).
set -u
SRC="$HOME/oss-fleet/shared-supabase/swarms-platform.env.local"
MARK='# fleet-shared-supabase'
LOG="$HOME/oss-fleet/doctor/worktree-env-seed.log"
log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }

[ -f "$SRC" ] || { log "source $SRC missing"; exit 1; }
grep -qF "$MARK" "$SRC" || { log "source lacks marker '$MARK' - refusing"; exit 1; }

seed_one() {
  local wt=$1 f=$1/.env.local
  if [ -f "$f" ] && grep -qF "$MARK" "$f" && cmp -s "$SRC" "$f"; then
    return 0
  fi
  if [ -f "$f" ]; then
    cp -p "$f" "$f.pre-shared-$(date -u +%Y%m%dT%H%M%SZ)"
  fi
  install -m 600 "$SRC" "$f" && log "seeded $f"
}

# Worktree pools: ~/.treehouse/<repo>-<hash>/<n>/swarms-platform. A pool slot
# directory can exist for a moment before `git worktree add` fills it; give the
# checkout up to 2 minutes to appear so a brand-new lane is covered before its
# first `pnpm dev`, not on the next timer tick.
shopt -s nullglob
for slot in "$HOME"/.treehouse/swarms-platform-*/*/; do
  wt="${slot%/}/swarms-platform"
  if [ ! -d "$wt" ]; then
    for _ in $(seq 1 60); do sleep 2; [ -d "$wt" ] && break; done
    [ -d "$wt" ] || continue
  fi
  [ -e "$wt/package.json" ] || continue
  seed_one "$wt"
done
# Firstmate's primary checkout of the project.
for wt in "$HOME"/.treehouse/firstmate-*/*/firstmate/projects/swarms-platform; do
  [ -e "$wt/package.json" ] && seed_one "$wt"
done
exit 0
