#!/usr/bin/env python3
"""Code Factory configuration, provisioning, and non-mutating readiness checks."""

import argparse
import json
import os
import pwd
import shutil
import subprocess
import sys
from pathlib import Path

import jsonschema
import yaml

ROOT = Path(__file__).resolve().parent.parent


def validate_document(document, schema_name):
    schema = json.loads((ROOT / "schemas" / schema_name).read_text())
    jsonschema.Draft202012Validator.check_schema(schema)
    try:
        jsonschema.Draft202012Validator(schema).validate(document)
    except jsonschema.ValidationError as error:
        location = ".".join(str(part) for part in error.absolute_path) or "<root>"
        raise ValueError(f"{schema_name}: invalid {location} ({error.validator})") from None


def validate_config(document):
    validate_document(document, "factory.schema.json")
    config = document["factory"]
    home, workspace = Path(config["home"]), Path(config["workspace"])
    if (
        ".." in home.parts
        or ".." in workspace.parts
        or home == Path("/home")
        or not workspace.is_relative_to(home)
        or workspace == home
    ):
        raise ValueError(
            "workspace must be a proper descendant of an operator home; traversal is forbidden"
        )
    if config["user"] == "root":
        raise ValueError("use a non-root operator account")
    if config["profiles"]["firstmate"] and not config["profiles"]["agents"]:
        raise ValueError("Firstmate requires the agents profile")
    if config["profiles"].get("fleet_guards"):
        if not (config["profiles"]["docker"] and config["profiles"]["firstmate"]):
            raise ValueError("fleet guards require the docker and firstmate profiles")
        fixture = config.get("fleet", {}).get("fixture_archive", "")
        if fixture and ".." in Path(fixture).parts:
            raise ValueError("fleet.fixture_archive must not traverse; give a plain path")
    prune = config["browser_prune"]
    if prune["enabled"] and not config["profiles"]["agents"]:
        raise ValueError("browser pruning requires the agents profile")
    if (
        prune["max_gap_seconds"] < 2 * prune["poll_seconds"]
        or prune["idle_seconds"] < 2 * prune["poll_seconds"]
    ):
        raise ValueError("pruning idle/gap windows must allow at least two observation intervals")
    lock = json.loads((ROOT / "toolchain.lock.json").read_text())
    validate_document(lock, "toolchain.schema.json")
    if not set(lock["npm_required_tools"]).issubset(lock["tools"]):
        raise ValueError("npm support tool missing from artifact lock")
    return document


def load_config(path):
    try:
        document = yaml.safe_load(path.read_text())
    except yaml.YAMLError:
        raise ValueError("malformed host YAML; configuration contents omitted") from None
    return validate_config(document)


def initialize(args):
    config = yaml.safe_load((ROOT / "config/default.yml").read_text())
    current = pwd.getpwuid(os.getuid())
    user = args.user or (current.pw_name if current.pw_uid != 0 else "coder")
    home = args.home or (
        current.pw_dir if user == current.pw_name and current.pw_uid != 0 else f"/home/{user}"
    )
    config["factory"].update(user=user, home=home, workspace=str(Path(home) / "Dev"))
    if args.container:
        config["factory"].update(start_services=False, enable_linger=False)
        for profile in ("docker", "tailscale", "desktop", "firstmate"):
            config["factory"]["profiles"][profile] = False
        config["factory"]["browser_prune"]["enabled"] = False
    destination = ROOT / ".local/host.yml"
    destination.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    # Validate before writing; a bad argument must not strand an unusable config.
    validate_config(config)
    with destination.open("x") as stream:
        yaml.safe_dump(config, stream, sort_keys=False)
    destination.chmod(0o600)
    print(f"Created {destination}; review profiles before ./factory apply.")


def provision(document, check):
    environment = {**os.environ, "ANSIBLE_CONFIG": str(ROOT / "ansible/ansible.cfg")}
    argv = [
        "ansible-playbook",
        "-i",
        str(ROOT / "ansible/inventory.yml"),
        str(ROOT / "ansible/site.yml"),
        "--extra-vars",
        json.dumps(document),
    ]
    if check:
        argv.append("--check")
    if (
        os.geteuid() != 0
        and subprocess.run(
            ["sudo", "-n", "true"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        ).returncode
    ):
        if not sys.stdin.isatty():
            raise ValueError(
                "sudo access required; run interactively to supply the become password"
            )
        argv.append("--ask-become-pass")
    return subprocess.run(argv, cwd=ROOT, env=environment).returncode


def doctor(document):
    config = document["factory"]
    home = Path(config["home"])
    environment = {
        **os.environ,
        "HOME": str(home),
        "PATH": str(home / ".local/bin") + ":/usr/local/bin:/usr/bin:/bin",
    }
    tools = ["herdr", "node", "bun", "uv", "git"]
    if config["profiles"]["agents"]:
        tools += [
            "omp",
            "pi",
            "codex",
            "gh",
            "no-mistakes",
            "treehouse",
            "gh-axi",
            "chrome-devtools-axi",
            "tasks-axi",
            "quota-axi",
            "lavish-axi",
        ]
    if config["profiles"]["development"]:
        tools += ["rustc", "cargo"]
    failed = []
    for name in tools:
        path = shutil.which(name, path=environment["PATH"])
        if not path:
            failed.append(name)
            print(f"MISSING {name}")
            continue
        try:
            result = subprocess.run(
                [path, "--version"], env=environment, capture_output=True, text=True, timeout=20
            )
            if result.returncode:
                failed.append(name)
                print(f"FAILED {name}: exit {result.returncode}")
            else:
                text = (result.stdout or result.stderr).splitlines()
                print(f"OK {name}: {text[0] if text else path}")
        except subprocess.TimeoutExpired:
            failed.append(name)
            print(f"FAILED {name}: version command timed out")
    if config["profiles"]["agents"]:
        gh = shutil.which("gh", path=environment["PATH"])
        authenticated = (
            gh is not None
            and subprocess.run(
                [gh, "auth", "status"],
                env=environment,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                timeout=20,
            ).returncode
            == 0
        )
        print(
            "GitHub authentication: "
            + ("present" if authenticated else "manual gh auth login required")
        )
        print(
            "Provider access: authenticate OMP/Pi/Codex interactively; subscriptions/model availability are not inferred."
        )
    if config["start_services"]:
        print(
            "Native services: verify systemctl --user status herdr chrome-autoprune.timer as the operator."
        )
    print(
        "Software checks: "
        + (
            "FAILED " + ", ".join(failed)
            if failed
            else "passed; authentication/network prerequisites are separate"
        )
    )
    return 1 if failed else 0


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    init = commands.add_parser(
        "init", help="create ignored host config for this login; never overwrite"
    )
    init.add_argument("--user")
    init.add_argument("--home")
    init.add_argument("--container", action="store_true")
    for name in ("validate", "plan", "apply", "doctor"):
        command = commands.add_parser(name)
        command.add_argument("--config", type=Path, default=None)
    args = parser.parse_args()
    if args.command == "init":
        initialize(args)
        return 0
    path = args.config or (
        ROOT / ".local/host.yml"
        if (ROOT / ".local/host.yml").exists()
        else ROOT / "config/default.yml"
    )
    document = load_config(path.resolve())
    if args.command == "validate":
        print(f"Valid host configuration and artifact lock: {path}")
        return 0
    if args.command == "doctor":
        return doctor(document)
    if args.command == "apply" and args.config is None and not (ROOT / ".local/host.yml").exists():
        raise ValueError(
            "run ./factory init and review .local/host.yml before applying, or pass an explicit --config"
        )
    return provision(document, args.command == "plan")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (OSError, ValueError, jsonschema.ValidationError, subprocess.TimeoutExpired) as error:
        print(f"factory: {error}", file=sys.stderr)
        sys.exit(1)
