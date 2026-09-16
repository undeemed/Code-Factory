#!/usr/bin/env python3
"""Refuse to provision an image with a configuration that describes another machine.

Run inside the Dockerfile `worker` stage, as the image account, after
`./factory validate` has accepted the document against schemas/factory.schema.json:

    uv run --project . --locked python containers/assert-image-config.py CONFIG

`./factory validate` proves the document is well formed. This guard proves it is
the *right* document for this image: the account it provisions is the account the
build runs as, and every capability an ordinary container cannot host is off.
Without it a stale or copied document would silently converge a different home,
or ask ansible to touch systemd, Docker, Tailscale or a desktop that is absent
here by design.
"""

import os
import pwd
import sys
from pathlib import Path

import yaml

# Capabilities that need a real host: a user manager and D-Bus, the host network
# stack and a node identity, or an X server. containers/factory.container.yml
# documents why each one is false.
HOST_ONLY_PROFILES = ("docker", "tailscale", "desktop")
# The workspace is a named volume (compose) or a bind (devcontainer) at runtime,
# so anything baked into it - a Firstmate clone above all - is shadowed.
VOLUME_SHADOWED_PROFILES = ("firstmate",)
DISABLED_FLAGS = ("start_services", "enable_linger")


def check(path: Path) -> list[str]:
    config = yaml.safe_load(path.read_text())["factory"]
    account = pwd.getpwuid(os.getuid())
    problems: list[str] = []

    if config["user"] != account.pw_name:
        problems.append(
            f"factory.user={config['user']!r} but the build runs as {account.pw_name!r}"
        )
    if config["home"] != account.pw_dir:
        problems.append(
            f"factory.home={config['home']!r} but {account.pw_name!r} has home {account.pw_dir!r}"
        )

    workspace = Path(config["workspace"])
    if not workspace.is_relative_to(Path(config["home"])):
        problems.append(f"factory.workspace={workspace} is outside factory.home")
    if not os.access(workspace, os.W_OK):
        problems.append(f"{workspace} is missing or not writable by {account.pw_name}")

    for flag in DISABLED_FLAGS:
        if config[flag] is not False:
            problems.append(f"factory.{flag} must be false in an image: there is no systemd here")
    for profile in HOST_ONLY_PROFILES:
        if config["profiles"][profile] is not False:
            problems.append(
                f"factory.profiles.{profile} must be false: it needs host capabilities the worker denies"
            )
    for profile in VOLUME_SHADOWED_PROFILES:
        if config["profiles"][profile] is not False:
            problems.append(
                f"factory.profiles.{profile} must be false: the workspace is a volume, so a baked checkout is shadowed"
            )

    if config["browser_prune"]["enabled"] is not False:
        problems.append(
            "factory.browser_prune.enabled must be false: the pruner needs host browser process groups"
        )

    return problems


def main(argv: list[str]) -> int:
    if len(argv) != 2:
        print(f"usage: {Path(argv[0]).name} CONFIG", file=sys.stderr)
        return 2
    path = Path(argv[1])
    problems = check(path)
    if problems:
        print(f"{path} does not describe this image:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    account = pwd.getpwuid(os.getuid())
    print(f"{path} matches this image: user={account.pw_name} home={account.pw_dir}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
