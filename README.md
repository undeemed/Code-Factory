# ⚡ Code Factory

> Reproducible AI-agent development environment on a fresh Ubuntu machine. One command to go from bare metal to a fully wired Herdr + Firstmate + OMP coding fleet.

Native Ansible provisioning. Pinned toolchain. Strict configuration schemas. Reviewed version locks. No Nix, no chezmoi, no cloud dependencies.

## Why

AI coding agents work best when their environment is deterministic and their sessions survive reboots. Code Factory provisions an Ubuntu host with:

- **Herdr** terminal workspace — pane management, presentation spaces, agent-aware desktops
- **Firstmate** fleet orchestrator — task dispatch, spawn memory floor, brief-rule enforcement
- **OMP/Pi** agent harness — model roles, mnemopi memory, chrome-devtools-axi browser integration. Every OMP model role resolves to an OmniRoute option generated from the running router by `scripts/sync_omniroute_models.py`; see [model selection](docs/omniroute-models.md) and, when a model "never works", [resilience gates](docs/omniroute-resilience.md)
- **Fleet guards** — one shared Supabase stack, Docker event guard, browser tier ladder, dev-server reaper, session cookie sync
- **Pinned toolchain** — Node 24, Bun 1.4, uv, Rust 1.97, GitHub CLI, no-mistakes, treehouse — every binary sha256-locked in `toolchain.lock.json`

Not copied: credentials, browser profiles, account sessions, agent history, live pane/task state, private project working trees, database volumes. See [security boundaries](docs/security.md).

## Quick start

Ubuntu 24.04 or 26.04, x86_64 or aarch64. Non-root account with sudo.

```bash
# 1. Authenticate GitHub (needed for private repos and gh-axi)
gh auth login

# 2. Clone
git clone https://github.com/undeemed/Code-Factory.git
cd Code-Factory

# 3. Bootstrap pinned tooling (uv, Node, Bun, Rust, etc.)
./bootstrap.sh

# 4. Review and edit the host config
./factory init              # creates .local/host.yml (gitignored)
vim .local/host.yml         # adjust profiles, user, paths

# 5. Preview (check mode, no changes)
./factory plan

# 6. Apply
./factory apply
```

`plan` is Ansible check mode — it reports what would change but makes no mutations. `apply` is the explicit state-changing step and may request sudo.

## What gets reproduced

- Herdr 0.9.0 with captured UI preferences and one canonical, versioned user-service executable.
- Pinned Node 24, Bun 1.4, uv, Rust 1.97, GitHub CLI, no-mistakes, treehouse.
- OMP 18.x and Pi 0.84.x, Codex, AXI tools, and pnpm.
- Safe OMP/Pi presentation and model-role settings.
- Pinned Firstmate source, dispatch settings, and Herdr backend selection.
- Docker engine defaults: `init` (reap orphaned children) and `live-restore`.
- **Fleet guards** — optional but recommended for multi-lane agent work:
  - One shared local Supabase stack (read-only test fixture, event-trigger DDL guard)
  - Docker event guard (kills rogue stacks on creation)
  - Browser tier ladder: Obscura (default, Rust CDP engine) → Chrome (pixel-critical fallback) → VNC (human eyes)
  - Cookie session sync across all three browser tiers
  - Dev-server reaper (kills idle `next dev` / `tsc` trees)
  - Spawn memory floor (refuses new lanes when host RAM is low)
- Optional Tailscale, loopback-only XFCE/VNC desktop, Chrome apt package.

## Configuration

`.local/host.yml` is the single source of truth. `./factory init` creates it; `./factory validate` checks it against the JSON schema.

```yaml
factory:
  user: coder
  home: /home/coder
  workspace: /home/coder/Dev
  start_services: true
  enable_linger: true
  profiles:
    agents: true          # Chrome autoprune, AXI tools, browser defaults
    development: true     # Rust, build tools
    firstmate: true       # Firstmate clone + dispatch settings
    docker: true          # Docker engine (group membership opt-in separately)
    fleet_guards: false   # Shared Supabase, browser ladder, session sync
    tailscale: false      # Daemon only; authenticate separately
    desktop: false        # XFCE + TigerVNC + noVNC
  browsers:
    obscura_version: '0.2.2'
    obscura_sha256: c1b4548e36549a0228c39c1cc842df425bc7253af2b0a56bd2a538d8ff7e3406
  fleet:
    supabase_project_id: swarms-shared
    fixture_archive: ""   # Path to DB volume tarball for fresh hosts
  firstmate:
    url: https://github.com/undeemed/firstmate.git
    revision: 341e691d...
```

All profiles default to `false` except `agents` and `development`. The recipe refuses conflicting unmanaged commands and independently advanced Firstmate checkouts instead of overwriting them. See [docs/](docs/) for architecture, security boundaries, and recovery procedures.

## Profiles

| Profile | What it installs |
|---------|-----------------|
| `agents` | Chrome autoprune, AXI tools, browser env defaults, agent harness config |
| `development` | Rust toolchain, build essentials, development-mode npm packages |
| `firstmate` | Pinned Firstmate clone, dispatch/harness config, spawn memory floor |
| `docker` | Docker engine + Compose v2. Group membership is opt-in (`docker_group_users`). |
| `fleet_guards` | Shared Supabase stack, Docker event guard, browser tier ladder, session sync, dev-server reaper, env seeder |
| `tailscale` | Tailscale daemon. Auth is manual. |
| `desktop` | XFCE + TigerVNC + noVNC. Requires an operator-created VNC password. |

## Fleet guards

The `fleet_guards` profile provisions everything a multi-lane AI agent fleet needs to run without thrashing the host:

- **Browser ladder** (Obscura → Chrome → VNC) with one shared cookie jar synced every 2 minutes
- **Shared Supabase** — read-only test fixture, DDL-guarded, one stack per host enforced at the Docker event layer
- **Dev-server reaper** — kills idle `next dev` / `tsc` trees every 2 minutes
- **Spawn memory floor** — refuses fresh agent lanes when host RAM is below threshold

See [docs/fleet-guards.md](docs/fleet-guards.md) for the incident that motivated it and the full design.

## OmniRoute gateway

Every OMP model role routes through OmniRoute, so the gateway is part of the
recipe rather than a hand-built side service. Enable it with
`factory_omniroute_bootstrap: true` (needs the `docker` profile):

```bash
maintenance/omniroute-bootstrap.sh            # create if absent, else verify + patch
maintenance/omniroute-bootstrap.sh --recreate # replace the container (env changes)
maintenance/omniroute-bootstrap.sh --check    # report configuration drift
```

It is idempotent: an existing container is verified and patched, never rotated,
so a re-run cannot invalidate live API keys or the dashboard password. Secrets
are minted into the account's own `super.env`; none live in this repository.

The bootstrap owns three things the shipped image gets wrong for a coding fleet:

- **Chat-admission headroom.** By default one "heavy" request (≥32k estimated
  tokens) may be in flight router-wide, so every large-context agent turn
  serializes and the losers get `503 chat_admission_busy`. The heavy bar moves to
  45k and the lease count to 6, with the node heap raised to match — the gate
  exists to protect that heap, so the two move together.
- **Two writable-layer patches**, re-applied automatically because `docker rm`
  and image pulls discard them: keeping `system` as `system` in the
  chat→Responses translation, and keeping the pinned `claude-cli` identity in
  step with the installed CLI.
- **The model list**, regenerated from the running router by
  `scripts/sync_omniroute_models.py` instead of hand-maintained.

[docs/omniroute-resilience.md](docs/omniroute-resilience.md) maps each error
string to the gate that produced it — three of them impersonate an upstream rate
limit — and [docs/omniroute-models.md](docs/omniroute-models.md) covers model
selection.

## Docker worker

An isolated devcontainer-style Docker image can be built from the same recipe (`factory.start_services: false`). The image carries the pinned toolchain, agent configs, and fleet guards without starting any systemd services, linger, or Docker-in-Docker. See [docs/architecture.md](docs/architecture.md).

## CI

GitHub Actions runs on every push and PR:

- `uv sync` + `pytest` + `ruff`
- `./factory validate` against the JSON schema
- Full Docker worker image build + behavior smoke test
- All actions pinned to immutable commit SHAs (no `@v4` tags)

## Troubleshooting

```bash
./factory doctor    # actionable diagnostics
./factory plan      # preview what apply would change
```

Common issues:
- **`factory_guards` requires `docker` + `firstmate`** — enable both profiles
- **Empty fixture archive** — the shared DB is a read-only fixture; copy the volume snapshot from the source host
- **Spawn memory floor** — wait for a lane to finish or raise the threshold in `config/spawn-memory-floor-mb`

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## License

[MIT](LICENSE)
