# Security and export boundary

This repository is an allowlisted reconstruction recipe, not a copy of a home directory. Keeping the repository private does not make credentials safe to commit.

## Never export

- SSH private keys, GitHub tokens, Tailscale node identity or auth keys.
- OMP, Pi, Claude, Codex, or other provider authentication stores.
- Browser profiles, cookies, password stores, desktop login sessions, or VNC passwords.
- Agent transcripts, fleet task history, private project working trees, database files, or Docker volumes.
- `.env` files, Terraform state, runtime sockets, PID files, and caches.

The source host contains at least one service unit with an inline API credential. That unit must not be copied verbatim. Recreated services must load credentials from a private runtime environment file, never from tracked unit contents.

## On a new host

Authenticate each CLI interactively under the account that will run it. Do not copy an old host's credential database to make a tool appear configured. GitHub repository access, model subscriptions, organization permissions, and tailnet membership are separate prerequisites; installing a binary does not grant them.

Keep local credential files outside the checkout, in owner-only directories with mode `0700`; files should have mode `0600`. Services should use `EnvironmentFile=` or Docker secrets. Do not put tokens into shell command arguments or public URLs.

The persistent desktop browser uses exactly one profile, `~/.vnc-chrome-profile`. Never clone, trim, archive into Git, or replace it. Log in on the destination device. The browser pruner excludes persistent profiles, attached browsers, and headed browsers.

## Remote access

Keep application and desktop listeners on loopback unless a reviewed deployment explicitly needs another binding. Reach them through SSH port forwarding or a configured private network. Do not publish a Docker socket or mount the host socket into an agent container; it grants host-level control.

Loopback is shared by local accounts. The optional desktop therefore requires an operator-created private VNC credential in addition to SSH transport. It never offers unauthenticated RFB access. Its service will not kill another desktop to claim an occupied display.

Tailscale installation, authentication, and SSH authorization are separate steps. Join the tailnet interactively, then use `tailscale set --ssh=true` only if Tailscale SSH is wanted. The tailnet must also authorize the connection in its SSH policy. Do not use `tailscale up --reset` to change one setting on an existing machine.

This export does not rewrite the current host's firewall, SSH policy, account membership, or credentials. Review those changes separately before applying a new-host profile.

## Updates

Tool versions and artifact checksums belong in reviewed lock files. Package-manager integrity checks verify the downloaded package matches the lock; they do not establish that a publisher is trustworthy. Review added dependencies and installer behavior before updating locks. Ubuntu security updates remain an operating-system responsibility rather than freezing an entire vulnerable package index forever.

Back up project repositories and application data separately, using encrypted storage and an application-aware restore procedure. A successful environment bootstrap is not evidence that a database backup is recoverable.
