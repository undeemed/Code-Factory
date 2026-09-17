# shared-supabase - the ONE Supabase stack on this box

Every swarms-platform lane boots the app against this stack. Nobody starts
their own. The database is a **read-only test fixture**: no migrations, no
`db reset`, no schema edits, no hand-seeding - ever (captain, 2026-09-17).

| | |
|---|---|
| Project id | `swarms-shared` (label `com.supabase.cli.project=swarms-shared`) |
| API | `http://127.0.0.1:54321` |
| Studio | `http://127.0.0.1:54323` (browse only - writes are rejected) |
| Mailpit | `http://127.0.0.1:54324` (magic links / confirmation mail land here) |
| DB | `127.0.0.1:54322` - `postgres` role is read-only by default; DDL rejected |
| Env for the app | `swarms-platform.env.local` (seeded into every worktree automatically) |
| Test account | see `swarms-platform.env.local` header |

## Why this exists

The swarms briefs require before/after screenshots of the live app. The app
refuses to boot without a Supabase URL and key, worktrees carry only
`.env.example`, so every lane built its own 12-container stack (two full
stacks and three stray Postgres containers were found on 2026-09-17 while the
box was 52 GB into swap). One stack, pre-wired env, and hard guards close that.

## Moving parts

- `check.sh` - keeps the stack up (idempotent `supabase start` on the existing
  volumes) and re-applies `guard.sql`. Run at login by
  `flotilla-shared-supabase.service`, every 5 min by
  `flotilla-shared-supabase-check.timer`. Log: `check.log`.
- `guard.sql` - event triggers reject DDL/DROP from every role except the
  Supabase service roles; `postgres`/`dashboard_user` default to read-only
  transactions. App traffic (anon/authenticated/service_role) is unaffected.
- `~/oss-fleet/doctor/docker-guard.sh` (`flotilla-docker-guard.service`) -
  watches `docker events`; any Supabase CLI project other than `swarms-shared`
  is removed the instant it is created; bare Postgres containers are alerted.
  Allowlist: `doctor/docker-guard-allow.txt`.
- `~/oss-fleet/doctor/worktree-env-seed.sh` (`flotilla-worktree-env-seed.*`) -
  installs `swarms-platform.env.local` as `.env.local` in every swarms
  worktree, on pool changes, every 2 min, and at login. Files lacking the
  `# fleet-shared-supabase` marker are replaced (backup kept alongside).
- `~/.local/bin/supabase` - shim; refuses lifecycle subcommands with a pointer
  here. (`npx supabase` bypasses it; the docker guard does not.)
- `/etc/docker/daemon.json` - `init: true` so containers reap their children
  (the 489-zombie pile came from Supabase studio/pg_meta without an init) and
  `live-restore: true` so dockerd restarts do not take containers down.
- Brief rules: `firstmate/data/swarms-brief-rules.md` "Backend" section.

## Operating

```
systemctl --user status flotilla-shared-supabase flotilla-docker-guard
cd ~/oss-fleet/shared-supabase && ./node_modules/.bin/supabase status
tail ~/oss-fleet/doctor/docker-guard.log ~/oss-fleet/shared-supabase/check.log
```

Stopping on purpose: `systemctl --user stop flotilla-shared-supabase-check.timer`
then `./node_modules/.bin/supabase stop` (volumes are kept). Do NOT `--no-backup`
unless you mean to lose the fixture.

The fixture volume is `supabase_db_swarms-shared` (cloned 2026-09-17 from lane
14's seeded DB: 5 test users, marketplace content). Snapshot before any
deliberate change:
`docker run --rm -v supabase_db_swarms-shared:/v:ro -v $PWD:/b alpine tar czf /b/db-$(date +%F).tgz -C /v .`
