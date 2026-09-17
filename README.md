# Code Factory

Rebuild the coding environment around Herdr, Firstmate, OMP, Pi, and their supporting tools on a fresh Ubuntu machine. Native Ansible provisioning, an isolated Docker worker, strict configuration schemas, and reviewed version locks live together here.

**IaC choice: Ansible for the host; Docker Compose for workloads.** [Research and tradeoffs](docs/architecture.md) explain why Nix, chezmoi, and OpenTofu are not additional requirements.

## What gets reproduced

- Herdr 0.9.0 with captured UI preferences and one canonical, versioned user-service executable.
- Node 24.19.0, Bun 1.4.0, uv 0.12.5, Rust 1.97.1, GitHub CLI 2.97.0, no-mistakes 1.48.0, and treehouse 2.1.1.
- Locked OMP 18.1.13, Pi 0.84.2, Codex, AXI tools, and pnpm.
- Safe OMP/Pi presentation and model-role settings. Firstmate crews use Pi/Opus 5; secondmates use OMP/Fable 5.1, both with xhigh effort.
- Pinned Firstmate source, its gitignored dispatch settings, and Herdr backend selection. No autonomous fleet restore or outward GitHub actions run during setup.
- Guarded native browser pruning: five-minute checks, two hours of observed inactivity, active-request and persistent-profile protection.
- Optional Docker, Tailscale installation, and a loopback-only single-profile XFCE/VNC desktop.
- Docker/devcontainer worker plus optional PostgreSQL/Redis development services, with bounded resources and no host credential or Docker-socket mounts.
- Docker engine defaults merged into `/etc/docker/daemon.json`: `init` (docker-init reaps orphaned children) and `live-restore`.
- Optional fleet guards: ONE shared local Supabase stack for every swarms-platform lane, a Docker event guard that removes any second stack on creation, automatic `.env.local` seeding into every worktree, a CLI shim, and Firstmate's spawn memory floor. See [fleet guards](docs/fleet-guards.md).

Not copied: credentials, browser profiles, account sessions, agent history, live pane/task state, private project working trees, database volumes, or application-specific deployments. Unsafe agent auto-approval/trust allowlists are not transferred. See [security boundaries](docs/security.md) and [migration/recovery](docs/recovery.md).

## Fresh Ubuntu host

Native targets: Ubuntu 24.04 or 26.04, Linux x86_64 or aarch64. Use a non-root operator account with sudo. The x86_64 container test is the automated reference; ARM assets are separately pinned, not a claim of ARM hardware testing.

Install initial access tooling through the OS, authenticate GitHub, and clone this private repository:

```bash
sudo apt-get update
sudo apt-get install -y git gh python3 python3-venv ca-certificates sudo

gh auth login
gh repo clone undeemed/Code-Factory
cd Code-Factory
./bootstrap.sh
./factory init
```

Review `.local/host.yml` before applying. `init` selects the current account and its home. It will not overwrite an existing local configuration. All machine-local files under `.local/` are ignored by Git.

```bash
$EDITOR .local/host.yml
./factory validate
./factory plan
./factory apply
./factory doctor
```

`plan` is Ansible check mode, not a promise that authentication or external network access works. `apply` is the explicit state-changing step and may request sudo. No provisioning runs merely by cloning, bootstrapping tooling, or opening the repository.

The recipe refuses conflicting unmanaged commands and modified/independently advanced Firstmate checkouts instead of overwriting them. Use a clean operator account for a fresh-device rebuild. Existing agent configuration files are preserved rather than replaced wholesale.

## Authentication and first launch

Installing software does not grant provider/model access. Log in as the configured operator, then authenticate OMP, Pi, Codex, and GitHub interactively. Recheck model availability under those destination accounts; model-role preferences do not create subscriptions.

```bash
systemctl --user status herdr.service chrome-autoprune.timer
herdr
cd ~/Dev/firstmate
omp
```

Adjust the workspace path if the host configuration changed it. Firstmate initializes its own private operational state on first use; this export does not carry the old backlog, charters, or worktrees.

From another device with Herdr and working SSH access:

```bash
herdr --remote operator@host
```

Use the real target identity. On headless Macs, do not substitute GUI launches or assume TCC permissions exist. This repository's native host playbook is Linux-only; a Mac can be a remote client or run the isolated worker through its own approved container runtime.

## Optional host profiles

Set these booleans in `.local/host.yml`, validate, then explicitly apply:

- `factory.profiles.docker`: installs the Ubuntu Docker package family. Docker group membership is not granted automatically; use sudo or configure your preferred access policy separately.
- `factory.profiles.tailscale`: installs the daemon only. Authenticate a fresh node yourself; Tailscale SSH additionally needs tailnet SSH policy. No existing SSH/firewall policy is rewritten.
- `factory.profiles.desktop`: installs XFCE/TigerVNC/noVNC, then requires an operator-created VNC password before enabling listeners. Run `tigervncpasswd ~/.vnc/passwd` as the operator after package installation, protect it with mode `0600`, and rerun apply. Use an SSH tunnel as well. The browser launcher uses only `~/.vnc-chrome-profile`; sign in afresh, never copy a seed profile.
- `factory.profiles.firstmate`: clones the pinned public source and writes dispatch preferences. Keep the agents profile enabled with it.
- `factory.profiles.fleet_guards`: one shared Supabase stack plus the guards that keep it the only one (requires the docker and firstmate profiles). A fresh host needs `factory.fleet.fixture_archive` pointing at a snapshot of the fixture database volume; the play refuses to start an empty stack. Details and the incident that produced this in [docs/fleet-guards.md](docs/fleet-guards.md).

`factory.start_services: false` suppresses user/system service and linger actions for container builds. It does not make a container a full replacement for a native host.

## Docker worker

Install Docker/Compose on the device running these commands. If its Docker socket requires sudo, prefix the Docker commands accordingly.

```bash
docker compose --profile worker build worker
docker compose --profile worker run --rm worker bash
```

The worker is non-root. Its workspace is a named volume, not your entire home directory. Authenticate tools inside the intended environment; do not mount host auth databases or browser profiles. The devcontainer also opens an initially empty named-volume workspace at `/home/coder/Dev`; clone projects there after login. It does not bind or mirror the host checkout. The filtered Code Factory source is available at `/opt/code-factory`.

Optional data services start with empty named volumes. PostgreSQL needs an explicit private password file before startup:

```bash
export CODE_FACTORY_SECRET_DIR="$HOME/.local/state/code-factory/secrets"
install -d -m 700 "$CODE_FACTORY_SECRET_DIR"
(umask 077; set -o noclobber; openssl rand -hex 32 > "$CODE_FACTORY_SECRET_DIR/postgres_password")
docker compose --profile data up -d
```

Ports bind to loopback. These are development examples, not copies of existing application databases. `docker compose down` preserves named volumes; do not add `--volumes` unless discarding their data is intentional.

Create that password once; the command refuses to overwrite it. When using sudo, pass the chosen directory explicitly: `sudo env CODE_FACTORY_SECRET_DIR="$CODE_FACTORY_SECRET_DIR" docker compose --profile data up -d`.

## Configuration and locks

| File | Contract |
| --- | --- |
| `config/default.yml` | Full default host document |
| `.local/host.yml` | Ignored operator-specific host document |
| `schemas/factory.schema.json` | Allowed host fields/types; unknown fields rejected |
| `toolchain.lock.json` | Native versions, per-architecture URLs and SHA-256 values |
| `schemas/toolchain.schema.json` | Artifact lock contract |
| `tools/npm/package-lock.json` | Exact agent dependency graph and package integrity |
| `uv.lock` | Provisioning/validation Python dependency graph |
| `maintenance/requirements.txt` | Hashed private pruner-runtime dependency |

Update locks deliberately. The native installer stages and checks downloads before exposing commands, rejects archive traversal, and does not replace an unmanaged executable. Operating-system packages follow the selected Ubuntu release and security updates rather than a frozen package index.

## Checks and operations

```bash
./factory validate --config config/default.yml
uv run ruff check .
uv run pytest
docker build --target smoke -t code-factory-smoke .
docker run --rm --init --memory=4g --cpus=2 code-factory-smoke
```

The image smoke exercises installed commands, a headless Herdr server, and a second provisioning pass. It does not log in to providers or create browser profiles. CI runs the repository's configured checks.

Browser pruning is native and independent of the checkout after installation:

```bash
~/.local/share/code-factory/pruner-venv/bin/python ~/.local/bin/chrome-autoprune.py  # dry-run
journalctl --user -u chrome-autoprune.service
systemctl --user disable --now chrome-autoprune.timer
```

Newly discovered sessions get a full observation window; snapshot age alone never triggers a kill. No forced SIGKILL or profile deletion is performed. Pruning idle browsers does not replace build concurrency limits or application-aware storage management.
