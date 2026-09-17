# Fleet guards

`factory.profiles.fleet_guards` reproduces the controls added to the source host
on 2026-09-17 after a swap-exhaustion incident: 24 GB of RAM and 52 GB of swap
were full, load sat near 300, and ssh took minutes. Two full local Supabase
stacks (24 containers) and three stray Postgres containers were running, each
built by a swarms-platform lane that only needed a screenshot; 489 zombie
processes had accumulated under containers whose PID 1 was a bare `node`; ten
live lanes at 5-8 GB each had been spawned with nothing bounding concurrency.

Every control below removes a cause, not a symptom.

## The chain the controls break

1. Briefs require before/after screenshots of the live app.
2. swarms-platform refuses to boot without a Supabase URL and key
   (`Your project's URL and Key are required to create a Supabase client!`).
3. Worktrees carry only `.env.example`; there was no shared backend.
4. So each lane ran `npx supabase start` - twelve containers - plus `next dev`,
   `tsc` and a browser, and nothing tore any of it down.

## What is provisioned

| Path (under the account home) | Purpose |
| --- | --- |
| `oss-fleet/shared-supabase/` | The ONE stack: pinned CLI (`npm ci` from `fleet/shared-supabase/package-lock.json`), `supabase/config.toml` with `factory.fleet.supabase_project_id`, `check.sh` keeper, `guard.sql`, `README.md`. `check.sh` also generates `swarms-platform.env.local` from the running stack. |
| `oss-fleet/doctor/docker-guard.sh` | `docker events` watcher. A container carrying `com.supabase.cli.project` other than an allowlisted project is removed on creation; bare Postgres-family images are logged and alerted, not killed (other projects may own them). `docker-guard-allow.txt` is written once and then operator-owned. |
| `oss-fleet/doctor/worktree-env-seed.sh` | Installs the env file as `.env.local` in every `~/.treehouse/swarms-platform-*/*/swarms-platform` worktree and Firstmate's `projects/swarms-platform`. Files without the `# fleet-shared-supabase` marker are replaced with a backup left beside them. |
| `.local/bin/supabase` | Shim: `status`/`--version` pass through; every lifecycle or schema subcommand is refused with the reason. `npx supabase` bypasses it, which is why the Docker guard exists. |
| `.config/systemd/user/flotilla-*.{service,timer,path}` | Login start + 5-minute keeper for the stack; the guard as a restart-always service; the seeder on pool changes, every 2 minutes and at login. |
| `/etc/docker/daemon.json` | `init: true` and `live-restore: true` merged in (tasks/docker.yml, any profile with docker). |
| Firstmate `config/spawn-memory-floor-mb` | `6000`: `bin/fm-spawn.sh` refuses a fresh spawn while host `MemAvailable` is below it. Free swap is not counted - "there is swap left" is the thrash state. |

Inside the database, `guard.sql` installs event triggers that reject every DDL
command and every DROP from any role other than the Supabase service roles,
and sets `postgres`/`dashboard_user` to read-only transactions by default.
Application traffic (anon/authenticated/service_role through PostgREST, GoTrue,
Storage) is unaffected. There is never a migration on this database.

The pinned Firstmate revision (`factory.firstmate.revision`) carries the last
layer: `extensions/fm-swarms-platform-guard.ts`, a tool-call seatbelt loaded by
every omp and pi crewmate that blocks `supabase start|stop|db reset|migration`,
`docker run ... postgres`, `psql` against the stack and edits to the shared
containers, with the reason attached - so the agent learns why before the
Docker guard has to act.

## The fixture

The shared database is a read-only test fixture. Its content cannot be
rebuilt from the application's migrations (they do not apply cleanly to an
empty database), so provisioning restores the Docker volume
`supabase_db_<project>` from `factory.fleet.fixture_archive`, a tarball taken
with:

```
docker run --rm -v supabase_db_swarms-shared:/v:ro -v "$PWD":/b alpine \
  tar czf /b/db-$(date +%F).tgz -C /v .
```

Copy that archive to the new host, set the path in `.local/host.yml`, and
apply. With neither an existing volume nor an archive the play stops with that
instruction rather than starting an empty, useless stack. Snapshots contain
test users and marketplace content only; keep them out of this repository.

## Operating

```
systemctl --user status flotilla-shared-supabase flotilla-docker-guard flotilla-worktree-env-seed.path
~/oss-fleet/shared-supabase/node_modules/.bin/supabase status --workdir ~/oss-fleet/shared-supabase
tail ~/oss-fleet/doctor/docker-guard.log ~/oss-fleet/shared-supabase/check.log ~/oss-fleet/doctor/worktree-env-seed.log
```

Tolerating a bare Postgres container someone else owns: add its name (glob)
to `docker-guard-allow.txt`; the guard re-reads the file on every event.
