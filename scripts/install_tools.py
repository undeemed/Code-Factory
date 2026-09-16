#!/usr/bin/env python3
"""Install only pinned public tools into a user-owned Code Factory prefix.

Stdlib-only: also bootstraps uv before repository dependencies exist. stdout is
one JSON result; installer progress goes to stderr. Existing unmanaged commands
are never replaced. Archives cannot write outside their staging directory.
"""

import argparse
import fcntl
import hashlib
import json
import os
import platform
import re
import shutil
import stat
import subprocess
import sys
import tarfile
import tempfile
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path, PurePosixPath


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def platform_key():
    machine = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}.get(
        platform.machine().lower()
    )
    if platform.system() != "Linux" or machine is None:
        raise ValueError(
            "native provisioning supports Linux x86_64/aarch64; other devices can use SSH Herdr clients"
        )
    return "linux-" + machine


def download(url, checksum, destination):
    parsed = urllib.parse.urlsplit(url)
    if (
        parsed.scheme != "https"
        or parsed.username
        or parsed.password
        or parsed.query
        or parsed.fragment
        or not re.fullmatch(r"[0-9a-f]{64}", checksum)
    ):
        raise ValueError("downloads require HTTPS and an explicit SHA-256")
    print(f"Downloading {url}", file=sys.stderr)
    with urllib.request.urlopen(url, timeout=120) as response, destination.open("wb") as stream:
        if urllib.parse.urlsplit(response.geturl()).scheme != "https":
            raise ValueError("refusing an insecure download redirect")
        shutil.copyfileobj(response, stream)
    if digest(destination) != checksum:
        raise ValueError(f"checksum mismatch for {url}")


def extract(archive, destination, kind, name):
    if kind == "file":
        shutil.copyfile(archive, destination / name)
    elif kind == "tar":
        with tarfile.open(archive) as source:
            source.extractall(destination, filter="data")
    elif kind == "zip":
        with zipfile.ZipFile(archive) as source:
            for item in source.infolist():
                path = PurePosixPath(item.filename)
                mode = item.external_attr >> 16
                if path.is_absolute() or ".." in path.parts or stat.S_ISLNK(mode):
                    raise ValueError("unsafe ZIP member")
            source.extractall(destination)
    else:
        raise ValueError(f"unsupported archive format: {kind}")


def binaries_in(root, patterns):
    result = {}
    for name, pattern in patterns.items():
        if name in (".", "..") or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ValueError("unsafe binary name")
        matches = [p for p in root.glob(pattern) if p.is_file()]
        if len(matches) != 1 or not matches[0].resolve().is_relative_to(root.resolve()):
            raise ValueError(f"expected one safe binary for {name}, found {len(matches)}")
        result[name] = matches[0]
    return result


def link_binary(home, name, target):
    link = home / ".local/bin" / name
    link.parent.mkdir(parents=True, exist_ok=True)
    if link.is_symlink() and link.resolve() == target.resolve():
        return False
    if os.path.lexists(link):
        old = link.resolve()
        if not link.is_symlink() or not (
            old.is_relative_to(home / ".local/share/code-factory")
            or old.is_relative_to(home / ".cargo")
        ):
            raise ValueError(
                f"unmanaged command exists: {link}; choose a clean account or relocate it explicitly"
            )
        link.unlink()
    link.symlink_to(target)
    return True


def install_asset(home, name, spec, key):
    version = spec["version"]
    if (
        name in (".", "..")
        or version in (".", "..")
        or not re.fullmatch(r"[A-Za-z0-9_.-]+", name)
        or not re.fullmatch(r"[A-Za-z0-9_.-]+", version)
    ):
        raise ValueError("unsafe tool name/version")
    asset = spec["assets"][key]
    final = home / ".local/share/code-factory/tools" / name / version / key
    stamp = final / ".asset.json"
    expected = hashlib.sha256(json.dumps(asset, sort_keys=True).encode()).hexdigest()
    valid = False
    if stamp.is_file():
        saved = json.loads(stamp.read_text())
        paths = binaries_in(final, asset["binaries"])
        valid = saved.get("spec") == expected and saved.get("files") == {
            n: digest(p) for n, p in paths.items()
        }
    changed = False
    if not valid:
        if final.exists():
            raise ValueError(
                f"installed artifact drifted or is incomplete: {final}; inspect it before replacing"
            )
        final.parent.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(prefix=".install-", dir=final.parent) as temporary:
            temporary = Path(temporary)
            archive = temporary / "download"
            unpacked = temporary / "contents"
            unpacked.mkdir()
            download(asset["url"], asset["sha256"], archive)
            extract(archive, unpacked, asset["format"], name)
            paths = binaries_in(unpacked, asset["binaries"])
            for path in paths.values():
                path.chmod(0o755)
            (unpacked / ".asset.json").write_text(
                json.dumps({"spec": expected, "files": {n: digest(p) for n, p in paths.items()}})
                + "\n"
            )
            unpacked.rename(final)
        changed = True
    for binary, path in binaries_in(final, asset["binaries"]).items():
        changed = link_binary(home, binary, path) or changed
    return changed


def command(argv, environment):
    subprocess.run([str(arg) for arg in argv], env=environment, check=True, stdout=sys.stderr)


def npm_install(repo, home, environment):
    source = repo / "tools/npm"
    manifest = json.loads((source / "package.json").read_text())
    lock_hash = digest(source / "package-lock.json")
    destination = home / ".local/share/code-factory/npm"
    stamp = destination / ".code-factory-lock"
    expected = lock_hash + ":" + digest(source / "package.json")
    installed = stamp.is_file() and stamp.read_text().strip() == expected
    for name, version in manifest["dependencies"].items():
        package = destination / "node_modules" / name / "package.json"
        if not package.is_file() or json.loads(package.read_text()).get("version") != version:
            installed = False
    changed = False
    if not installed:
        if (
            destination.exists()
            and any(destination.iterdir())
            and not stamp.exists()
            and not (destination / "package-lock.json").exists()
        ):
            raise ValueError(f"refusing unmanaged npm prefix: {destination}")
        destination.mkdir(parents=True, exist_ok=True)
        for name in ("package.json", "package-lock.json"):
            shutil.copyfile(source / name, destination / name)
        command(
            [home / ".local/bin/npm", "ci", "--prefix", destination, "--no-audit", "--no-fund"],
            environment,
        )
        stamp.write_text(expected + "\n")
        changed = True
    # Only expose explicitly requested packages, not incidental dependency bins.
    for package_name in manifest["dependencies"]:
        root = destination / "node_modules" / package_name
        package = json.loads((root / "package.json").read_text())
        bins = package.get("bin", {})
        if isinstance(bins, str):
            bins = {package_name.rsplit("/", 1)[-1]: bins}
        for name, relative in bins.items():
            target = root / relative
            if not target.is_file() or not target.resolve().is_relative_to(destination.resolve()):
                raise ValueError(f"invalid installed package command: {name}")
            changed = link_binary(home, name, target) or changed
    return changed


def rust_install(home, version, environment):
    rustup = home / ".cargo/bin/rustup"
    environment = {
        **environment,
        "CARGO_HOME": str(home / ".cargo"),
        "RUSTUP_HOME": str(home / ".rustup"),
    }
    changed = False
    if not rustup.exists():
        command(
            [
                home / ".local/bin/rustup-init",
                "-y",
                "--no-modify-path",
                "--profile",
                "minimal",
                "--default-toolchain",
                version,
                "--component",
                "rustfmt",
                "--component",
                "clippy",
            ],
            environment,
        )
        changed = True
    else:
        result = subprocess.run(
            [rustup, "run", version, "rustc", "--version"],
            env=environment,
            capture_output=True,
            text=True,
        )
        if result.returncode or not result.stdout.startswith(f"rustc {version} "):
            command(
                [
                    rustup,
                    "toolchain",
                    "install",
                    version,
                    "--profile",
                    "minimal",
                    "--component",
                    "rustfmt",
                    "--component",
                    "clippy",
                ],
                environment,
            )
            changed = True
        components = subprocess.run(
            [rustup, "component", "list", "--installed", "--toolchain", version],
            env=environment,
            capture_output=True,
            text=True,
            check=True,
        ).stdout
        missing = [
            name
            for name in ("rustfmt", "clippy")
            if not any(line.startswith(name + "-") for line in components.splitlines())
        ]
        if missing:
            command([rustup, "component", "add", "--toolchain", version, *missing], environment)
            changed = True
        current = subprocess.run(
            [rustup, "default"], env=environment, capture_output=True, text=True, check=True
        ).stdout
        if not current.startswith(version + "-"):
            command([rustup, "default", version], environment)
            changed = True
    for name in (
        "rustup",
        "cargo",
        "rustc",
        "rustfmt",
        "cargo-fmt",
        "cargo-clippy",
        "clippy-driver",
    ):
        changed = link_binary(home, name, home / ".cargo/bin" / name) or changed
    return changed


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lock", type=Path, required=True)
    parser.add_argument("--home", type=Path, required=True)
    parser.add_argument("--tools", default="herdr,node,bun,uv")
    parser.add_argument("--npm", action="store_true")
    parser.add_argument("--development", action="store_true")
    args = parser.parse_args()
    home = args.home.resolve(strict=True)
    if home.stat().st_uid != os.geteuid():
        parser.error("run as the user who owns --home")
    lock = json.loads(args.lock.read_text())
    if lock.get("schema_version") != 1:
        parser.error("unsupported toolchain lock schema")
    names = list(dict.fromkeys(args.tools.split(",")))
    if args.npm:
        names = list(dict.fromkeys([*names, *lock["npm_required_tools"]]))
    if args.development:
        names.append("rustup-init")
    key = platform_key()
    environment = {
        **os.environ,
        "HOME": str(home),
        "PATH": str(home / ".local/bin") + ":/usr/local/bin:/usr/bin:/bin",
    }
    prefix = home / ".local/share/code-factory"
    prefix.mkdir(parents=True, exist_ok=True)
    with (prefix / ".install.lock").open("a") as guard:
        fcntl.flock(guard, fcntl.LOCK_EX)
        changed = False
        for name in names:
            changed = install_asset(home, name, lock["tools"][name], key) or changed
        if args.npm:
            changed = npm_install(args.lock.resolve().parent, home, environment) or changed
        if args.development:
            changed = rust_install(home, lock["rust_toolchain"], environment) or changed
    print(
        json.dumps(
            {
                "changed": changed,
                "installed": names,
                "npm": args.npm,
                "development": args.development,
            }
        )
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        print(f"install_tools: {error}", file=sys.stderr)
        sys.exit(1)
