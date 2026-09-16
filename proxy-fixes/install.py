#!/usr/bin/env python3
"""Apply reviewed proxy fixes only to exact known artifacts; install restart guards.

No secrets, authentication stores, requests, or service environments are read.
Services are NOT restarted by this script. Unknown upgraded artifacts fail closed.
"""

import argparse
import hashlib
import json
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def apply_patch(component, directory, spec, backup):
    states = []
    for relative, expected in spec["files"].items():
        path = directory / relative
        actual = sha(path)
        if actual == expected["after"]:
            states.append("after")
        elif actual == expected["before"]:
            states.append("before")
        else:
            raise ValueError(
                f"unrecognized {component} artifact: {relative}; review new version, do not patch blindly"
            )
    if set(states) == {"after"}:
        return
    if set(states) != {"before"}:
        raise ValueError(
            f"partial {component} patch detected; restore a known complete artifact first"
        )
    backup.mkdir(parents=True, exist_ok=True, mode=0o700)
    for relative, expected in spec["files"].items():
        saved = backup / f"{component}-{expected['before']}.original"
        if not saved.exists():
            with saved.open("xb") as stream:
                stream.write((directory / relative).read_bytes())
        if sha(saved) != expected["before"]:
            raise ValueError(f"backup mismatch: {saved}")
    subprocess.run(
        [
            "patch",
            "--batch",
            "--forward",
            "-p1",
            "--input",
            str(ROOT / component / "preserved-thinking.patch"),
        ],
        cwd=directory,
        check=True,
    )
    for relative, expected in spec["files"].items():
        if sha(directory / relative) != expected["after"]:
            raise ValueError(f"post-patch integrity failure: {component}/{relative}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--headroom-python", type=Path, required=True)
    parser.add_argument("--pxpipe-package", type=Path, required=True)
    parser.add_argument("--node", type=Path, default=Path(shutil.which("node") or "/usr/bin/node"))
    parser.add_argument(
        "--no-guards",
        action="store_true",
        help="apply and check only, for a container without systemd",
    )
    args = parser.parse_args()
    manifest = json.loads((ROOT / "manifest.json").read_text())
    inspect_code = "import json,importlib.metadata; from pathlib import Path; import headroom.proxy.body_forwarding as m; print(json.dumps({'version':importlib.metadata.version('headroom-ai'),'root':str(Path(m.__file__).parents[2])}))"
    headroom = json.loads(
        subprocess.check_output([args.headroom_python, "-c", inspect_code], text=True)
    )
    package = json.loads((args.pxpipe_package / "package.json").read_text())
    if (
        headroom["version"] != manifest["headroom"]["version"]
        or package["version"] != manifest["pxpipe"]["version"]
    ):
        raise ValueError("installed proxy versions differ from reviewed patch manifest")
    backup = Path.home() / ".local/state/code-factory/proxy-backups"
    apply_patch("headroom", Path(headroom["root"]), manifest["headroom"], backup)
    apply_patch("pxpipe", args.pxpipe_package.resolve(), manifest["pxpipe"], backup)
    permanent = Path.home() / ".local/share/code-factory/proxy-fixes"
    permanent.mkdir(parents=True, exist_ok=True)
    headroom_check = permanent / "headroom-check.py"
    pxpipe_check = permanent / "pxpipe-check.mjs"
    permanent_manifest = permanent / "manifest.json"
    shutil.copyfile(ROOT / "manifest.json", permanent_manifest)
    shutil.copyfile(ROOT / "headroom/test_preserved_thinking.py", headroom_check)
    shutil.copyfile(ROOT / "pxpipe/check.mjs", pxpipe_check)
    headroom_command = [
        args.headroom_python.absolute(),
        headroom_check,
        "--manifest",
        permanent_manifest,
    ]
    pxpipe_command = [
        args.node.resolve(),
        pxpipe_check,
        args.pxpipe_package.resolve(),
        permanent_manifest,
    ]
    subprocess.run(headroom_command, check=True)
    subprocess.run(pxpipe_command, check=True)
    if not args.no_guards:
        units = Path.home() / ".config/systemd/user"
        for name, argv in (
            ("headroom", headroom_command),
            ("pxpipe", pxpipe_command),
        ):
            directory = units / f"{name}.service.d"
            directory.mkdir(parents=True, exist_ok=True)
            # systemd accepts double-quoted argv, without invoking a shell.
            command = " ".join(json.dumps(str(item)) for item in argv)
            (directory / "code-factory-thinking-guard.conf").write_text(
                "[Service]\n# Refuse startup if a package update reintroduces prefix mutation.\nExecStartPre="
                + command
                + "\n"
            )
        subprocess.run(["systemctl", "--user", "daemon-reload"], check=True)
    print(
        "Proxy patches verified; restart pxpipe then headroom when their request connections are idle."
    )


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"proxy repair: {error}", file=sys.stderr)
        sys.exit(1)
