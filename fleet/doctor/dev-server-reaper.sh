#!/usr/bin/env bash
# dev-server-reaper.sh - kill dev servers and type-checkers that outlived their lane.
#
# Why: a `next dev` is 3-4 GB per worktree (Next compiles the whole app per
# process; nothing is shared across branches), and nobody killed them when a
# lane stopped working - the agent forgot, firstmate's teardown only runs when
# a task is retired, treehouse only cleans at worktree return. On 2026-09-17
# finished lanes held 6 GB of idle dev servers while the host swapped. A dev
# server is throwaway (10 s to restart), so reaping it is always safe.
#
# Targets: node processes whose cwd is a treehouse pool worktree
# (~/.treehouse/<pool>/<n>/<repo>) or a no-mistakes pipeline worktree
# (~/.no-mistakes/worktrees/<repo>/<run>) and whose command is a Next.js
# server (`next dev`, `next-server`) or a type-check (`tsc --noEmit`).
#
# A target is reaped when ANY of these hold for its worktree:
#   * no agent process (omp/pi/claude/codex/grok/kimi/cursor) has that cwd;
#   * the firstmate lane owning that worktree last reported
#     done: / paused: / blocked: / failed:;
#   * the agent's newest transcript has not been written for >= IDLE_MIN
#     minutes (default 30).
# Otherwise (a lane actively working) the server is left alone.
#
# Runs every 2 minutes from flotilla-dev-server-reaper.timer and at login.
# Every kill: dev-server-reaper.log here, one line in COMMS.md for the
# orchestrator, notify-master.sh when present.
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
LOG=$HERE/dev-server-reaper.log
COMMS=$HERE/COMMS.md
IDLE_MIN=${REAPER_IDLE_MIN:-30}
DRY=${REAPER_DRY_RUN:-0}
# treehouse pool worktrees (~/.treehouse/<pool>/<n>/<repo>) and no-mistakes
# pipeline worktrees (~/.no-mistakes/worktrees/<repo-hash>/<run-id>), whose
# review agents also run `next dev` and do not always take it down.
POOL_RE="^$HOME/(\.treehouse/[^/]+/[0-9]+/[^/]+|\.no-mistakes/worktrees/[^/]+/[^/]+)$"

log() { printf '[%s] %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG"; }
comms() { printf '\n## [dev-server-reaper -> orchestrator] %s %s\n' "$(date '+%Y-%m-%d %H:%M')" "$*" >> "$COMMS"; }
notify() { [ -x "$HERE/notify-master.sh" ] && "$HERE/notify-master.sh" "$1" "dev-server-reaper" >/dev/null 2>&1; return 0; }

cmdline() { tr '\0' ' ' < "/proc/$1/cmdline" 2>/dev/null; }
comm_of() { cat "/proc/$1/comm" 2>/dev/null; }
cwd_of() { readlink "/proc/$1/cwd" 2>/dev/null; }
# comm may contain spaces ("next-server (v15.5.9)"), so split after the last ')'.
ppid_of() { sed -E 's/^.*\) //' "/proc/$1/stat" 2>/dev/null | awk '{print $2}'; }

is_target() {  # <pid> -> 0 when this is a dev server / type-check process
  local c cmd
  c=$(comm_of "$1")
  case "$c" in next-server*) return 0 ;; esac
  case "$c" in node|bun|MainThread) ;; *) return 1 ;; esac
  cmd=$(cmdline "$1")
  case "$cmd" in
    *"/next dev"*|*"next dev "*|*"next-server"*|*"/tsc --noEmit"*|*" tsc --noEmit"*) return 0 ;;
  esac
  return 1
}

# Lane state for a worktree: prints "<state>" from the owning firstmate task's
# status file, or "" when no lane record names this worktree.
lane_state() {  # <worktree>
  local meta status
  meta=$(grep -lsx -- "worktree=$1" "$HOME"/.treehouse/firstmate-*/*/firstmate/state/*.meta 2>/dev/null | head -1)
  [ -n "$meta" ] || return 0
  status=${meta%.meta}.status
  [ -f "$status" ] || return 0
  tail -1 "$status" | sed -E 's/^([a-z-]+)( \[[^]]*\])?:.*/\1/'
}

# Minutes since the newest agent transcript for a worktree was written; "" when
# no transcript is found (then idleness cannot be judged).
agent_idle_min() {  # <worktree>
  local rel crel newest=0 f m
  rel=${1#"$HOME"/}; rel=${rel//\//-}
  # Claude Code names its project dir from the full path with every non-alnum
  # character turned into '-': /home/u/.no-mistakes/x -> -home-u--no-mistakes-x
  crel=$(printf '%s' "$1" | sed -E 's/[^A-Za-z0-9]/-/g')
  for f in "$HOME"/.omp/agent/sessions/*"$rel"/*.jsonl "$HOME"/.pi/agent/sessions/*"$rel"*/*.jsonl "$HOME"/.claude/projects/"$crel"/*.jsonl; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null) || continue
    [ "$m" -gt "$newest" ] && newest=$m
  done
  [ "$newest" -gt 0 ] || return 0
  echo $(( ($(date +%s) - newest) / 60 ))
}

agent_alive() {  # <worktree> -> 0 when an agent process has this cwd
  local p
  for p in $(pgrep -x 'omp|pi|claude|codex|grok|kimi|cursor' 2>/dev/null); do
    [ "$(cwd_of "$p")" = "$1" ] && return 0
  done
  return 1
}

# Walk up from a target through the wrapper chain (pnpm -> sh -> node) that
# shares its cwd, stopping before any interactive shell or agent, so the whole
# `pnpm dev` tree dies and does not respawn a child. Never crosses out of the
# worktree.
tree_root() {  # <pid> <worktree>
  local pid=$1 wt=$2 pp c
  while :; do
    pp=$(ppid_of "$pid"); [ -n "$pp" ] && [ "$pp" -gt 1 ] || break
    [ "$(cwd_of "$pp")" = "$wt" ] || break
    c=$(comm_of "$pp")
    case "$c" in node|bun|sh|pnpm|npm|npx|MainThread|next-server*) pid=$pp ;; *) break ;; esac
  done
  echo "$pid"
}

tree_kb=0
kill_tree() {  # <root-pid>  (accumulates RSS+swap of the whole tree in tree_kb)
  local kids k
  kids=$(pgrep -P "$1" 2>/dev/null)
  for k in $kids; do kill_tree "$k"; done
  tree_kb=$(( tree_kb + $(awk '/VmRSS|VmSwap/{s+=$2} END{print s+0}' "/proc/$1/status" 2>/dev/null || echo 0) ))
  [ "$DRY" = 1 ] || kill -TERM "$1" 2>/dev/null
}

declare -A decided=()   # worktree -> reason ("" = keep)
declare -A reaped_wt=()
declare -A done_root=()  # roots already handled this pass
reaped=0; kept=0; freed_kb=0

for pid in $(pgrep -x 'node|bun|MainThread|next-server' 2>/dev/null) $(pgrep -f 'next-server' 2>/dev/null); do
  [ -d "/proc/$pid" ] || continue
  is_target "$pid" || continue
  wt=$(cwd_of "$pid"); [ -n "$wt" ] || continue
  [[ "$wt" =~ $POOL_RE ]] || continue
  if [ -z "${decided[$wt]+x}" ]; then
    reason=
    state=$(lane_state "$wt")
    idle=$(agent_idle_min "$wt")
    if ! agent_alive "$wt"; then
      reason="no agent process in worktree"
    else
      case "$state" in
        done|paused|blocked|failed) reason="lane reported ${state}:" ;;
      esac
      if [ -z "$reason" ] && [ -n "$idle" ] && [ "$idle" -ge "$IDLE_MIN" ]; then
        reason="agent idle ${idle}m (>= ${IDLE_MIN}m)"
      fi
    fi
    decided[$wt]=$reason
  fi
  reason=${decided[$wt]}
  if [ -z "$reason" ]; then kept=$((kept+1)); continue; fi
  root=$(tree_root "$pid" "$wt")
  [ -n "${done_root[$root]+x}" ] && continue
  done_root[$root]=1
  [ -d "/proc/$root" ] || continue
  desc=$(cmdline "$root" | cut -c1-80)
  tree_kb=0; kill_tree "$root"; kb=$tree_kb
  reaped=$((reaped+1)); freed_kb=$((freed_kb + kb))
  reaped_wt[$wt]=1
  log "${DRY:+DRY }REAPED pid=$root ($((kb/1024)) MB) [$desc] in ${wt#"$HOME"/} - $reason"
done

# Stragglers that ignored TERM.
if [ "$DRY" != 1 ] && [ "$reaped" -gt 0 ]; then
  sleep 3
  for pid in $(pgrep -x 'node|bun|MainThread|next-server' 2>/dev/null) $(pgrep -f 'next-server' 2>/dev/null); do
    [ -d "/proc/$pid" ] || continue
    is_target "$pid" || continue
    wt=$(cwd_of "$pid")
    [ -n "${reaped_wt[$wt]+x}" ] || continue
    kill -KILL "$pid" 2>/dev/null && log "KILLED (SIGKILL) straggler pid=$pid in ${wt#"$HOME"/}"
  done
fi

if [ "$reaped" -gt 0 ]; then
  summary="reaped $reaped dev-server/type-check process tree(s), ~$((freed_kb/1024)) MB, in: $(printf '%s ' "${!reaped_wt[@]}" | sed "s|$HOME/.treehouse/||g")"
  log "$summary"
  [ "$DRY" = 1 ] || { comms "$summary. Lanes were done/paused/blocked or idle >= ${IDLE_MIN}m; a dev server restarts in 10 s when a lane needs one. Evidence protocol: start, screenshot, kill."; notify "dev-server-reaper: $summary"; }
fi
exit 0
