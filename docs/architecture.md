# Infrastructure choice

## Decision

Use Ansible core for the native Ubuntu host and Docker Compose for isolated workloads. Keep Herdr, SSH, the user service manager, and browser lifecycle management on the host.

The source machine already uses Ubuntu packages, user-level systemd services, home-directory tools, and SSH. Ansible manages those objects directly without moving the machine to a new package store or OS. The playbook consumes a validated host document; native tools have versioned URLs and SHA-256 values, npm has a dependency lock, and the provisioning Python environment has `uv.lock`.

| Candidate | Fit here | Decision |
| --- | --- | --- |
| Ansible | Existing Ubuntu machines, apt, users, files, SSH, systemd | Primary configuration management |
| Docker / Compose | Bounded project processes, reproducible tool image, named data volumes | Optional worker and backing-service layer |
| Nix + Home Manager | Strong declarative package closure; works on Ubuntu too | Not selected: adds a daemon/store/profile migration and packaging work for locally distributed tools |
| chezmoi | Dotfile templates and per-machine configuration | Not selected: does not replace host package, user-manager, and service provisioning; a second template owner is unnecessary |
| OpenTofu | Cloud instances, networks, DNS, resource lifecycle | Add when a provider/resource contract is chosen; no pretend provider configuration is shipped |
| cloud-init | Initial VM prerequisites before configuration management | Small vendor-neutral bootstrap input only |

This is repeatable configuration, not a bit-identical OS image. Ubuntu packages receive distribution security updates. Exact agent/native-tool versions are deliberately locked. Rebuilding an environment does not recreate authenticated accounts, databases, or running processes.

## Host and container boundary

Herdr documents a persistent headless `herdr server` and SSH remote clients. The host's user manager owns that server and survives logout through lingering. Its unit names a versioned executable directly, so an old `/usr/local/bin/herdr` cannot silently win over a newer interactive CLI.

An ordinary container has a different process and filesystem lifecycle. Docker's tiny init can reap processes; it does not reproduce the host's user D-Bus, login manager, SSH identity, or desktop session. The worker image therefore disables host-service operations and does not mount host PID state, the Docker socket, credentials, browser profiles, or Herdr session state.

Use a Linux host for the native recipe. macOS and other client devices can reach that host over SSH; this repository does not claim to reproduce Linux systemd services as native macOS services. Headless Mac setup must not depend on a GUI/TCC dialog being dismissed remotely.

## Findings from the source VPS

- Ubuntu 26.04 LTS, x86_64. The recipe also targets Ubuntu 24.04 for the container/rebuild baseline.
- Interactive Herdr was 0.9.0, while the user unit pointed at a separate 0.8.2 binary. Export selects one 0.9.0 executable and path.
- OMP reported 18.1.13, but the Bun global manifest still declared 17.4.2. Pi reported 0.84.2 while an old cache held 0.82.1. Locks use the active CLI versions, not old cache contents.
- Installed quota-axi was 0.1.28, below the pinned Firstmate checkout's 0.1.29 floor. Export deliberately selects 0.1.29. Other captured agent preferences, including Pi/Opus crews and OMP/Fable 5.1 secondmates, are preserved.
- Desktop helpers contained profile-copying behavior and two incompatible runtime registries. Neither is reproduced. Optional desktop setup has one persistent `~/.vnc-chrome-profile`, no seed copying, and no migration of login state.
- Some current services and Compose files bind broadly or contain machine-specific network addresses. New templates use loopback and explicit opt-in roles instead of copying those bindings.
- Host browser pruning, fleet emergency memory handling, and build-cache cleanup have different owners. The exported browser pruner handles only eligible idle AXI bridge processes. It does not delete Docker volumes, caches, worktrees, or active builds.
- Project-specific Seer, Dorm, Foodie, and development preview deployments are not baseline services. Rebuild those projects from their own source and migrations after authenticating. Their databases and credentials are not environment configuration.

## Reproducibility policy

1. Update native versions and both architecture hashes together in `toolchain.lock.json`; never resolve a mutable `latest` installer during deployment.
2. Update exact npm dependencies and regenerate `tools/npm/package-lock.json` together. Do not copy a live global package directory.
3. Change Python dependencies with `uv lock` and commit the lock.
4. Keep machine differences in ignored `.local/host.yml`; schema validation precedes provisioning.
5. Do not force, stash, reset, or overwrite a modified Firstmate checkout or an unmanaged command. Resolve that conflict explicitly.
6. Keep authentication and mutable application state outside the recipe. Provider model access must be checked on the destination account.

## Primary sources

- [Herdr installation](https://herdr.dev/docs/install/), [headless/SSH persistence](https://herdr.dev/docs/persistence-remote/), [session-state limits](https://herdr.dev/docs/session-state/), [config reference](https://herdr.dev/docs/config-reference/).
- [Herdr v0.9.0 release](https://github.com/herdrdev/herdr/releases/tag/v0.9.0). Asset digests are recorded in the lock; no claim is made that the release supplies an independent SBOM or signature bundle.
- [Ansible introduction](https://docs.ansible.com/projects/ansible/latest/getting_started/index.html), [checksummed downloads](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/get_url_module.html), [user systemd/D-Bus requirements](https://docs.ansible.com/projects/ansible/latest/collections/ansible/builtin/systemd_service_module.html).
- [systemd lingering](https://www.freedesktop.org/software/systemd/man/latest/loginctl.html).
- [Docker process boundaries](https://docs.docker.com/engine/containers/multi-service_container/), [Docker and host firewall behavior](https://docs.docker.com/engine/network/firewall-iptables/).
- [Nix multi-user installation](https://nix.dev/manual/nix/stable/installation/multi-user.html), [standalone Home Manager](https://nix-community.github.io/home-manager/installation/standalone.html).
- [chezmoi setup](https://www.chezmoi.io/user-guide/setup/), [OpenTofu scope](https://opentofu.org/docs/intro/).
