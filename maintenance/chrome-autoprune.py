#!/usr/bin/python3
"""Prune idle chrome-devtools-axi automation bridges, never browser profiles.

Default: report only. --apply records activity and sends graceful SIGTERM after
2 hours of continuously observed inactivity. Run every 5 minutes. First sight,
PID replacement, reboot, missing observations (>15 minutes), bridge I/O, or an
open HTTP request resets the clock. Snapshot age alone never authorizes a kill.

Only this user's installed AXI bridge, owning its process group and recorded
loopback listener, is eligible. Headed/attached/persistent-profile browsers are
excluded. No SIGKILL, profile deletion, package patching, or dev-server cleanup.
The bridge drains HTTP requests and closes its own MCP/Chrome children on exit.

Requires Linux pidfds and the pinned private psutil runtime. Timer: chrome-autoprune.timer.
Inspect with ~/.local/share/code-factory/pruner-venv/bin/python ~/.local/bin/chrome-autoprune.py
Logs: journalctl --user -u chrome-autoprune.service
Disable: systemctl --user disable --now chrome-autoprune.timer
"""

import argparse
import fcntl
import json
import math
import os
import re
import select
import signal
import stat
import tempfile
import time
from pathlib import Path

import psutil

HOME = Path.home()
REGISTRY = HOME / ".chrome-devtools-axi"
BRIDGE = (
    HOME
    / ".local/share/code-factory/npm/node_modules/chrome-devtools-axi/dist/bin/chrome-devtools-axi-bridge.js"
)
DEFAULT_STATE = HOME / ".local/state/chrome-autoprune/state.json"
UID = os.getuid()


class Protected(Exception):
    pass


def owned_json(path):
    # Ubuntu's private-group umask creates 0775/0664 registry entries. The
    # registry locates candidates; live process identity/I/O authorizes stopping.
    for parent in (path.parent, path.parent.parent):
        info = parent.lstat()
        if not stat.S_ISDIR(info.st_mode) or info.st_uid != UID or info.st_mode & 0o002:
            raise Protected("unsafe registry/state directory")
    fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    with os.fdopen(fd) as stream:
        info = os.fstat(stream.fileno())
        if not stat.S_ISREG(info.st_mode) or info.st_uid != UID or info.st_mode & 0o002:
            raise Protected("unsafe registry/state file")
        value = json.load(stream)
    if not isinstance(value, dict):
        raise Protected("invalid JSON record")
    return value


def observe(name, path):
    record = owned_json(path)
    pid, port = record.get("pid"), record.get("port")
    if type(pid) is not int or pid <= 1 or type(port) is not int or not 1 <= port <= 65535:
        raise Protected("invalid pid/port")
    proc = psutil.Process(pid)
    if proc.uids().real != UID or proc.uids().effective != UID:
        raise Protected("different process owner")
    args = proc.cmdline()
    if (
        len(args) != 2
        or Path(args[1]).resolve() != BRIDGE.resolve()
        or Path(proc.exe()).name != "node"
    ):
        raise Protected("not the installed AXI bridge")
    if os.getpgid(pid) != pid:
        raise Protected("bridge does not own its process group")
    environment = proc.environ()
    if environment.get("CHROME_DEVTOOLS_AXI_SESSION", "default") != name:
        raise Protected("session identity mismatch")
    if any(
        environment.get(key)
        for key in (
            "CHROME_DEVTOOLS_AXI_BROWSER_URL",
            "CHROME_DEVTOOLS_AXI_USER_DATA_DIR",
            "CHROME_DEVTOOLS_AXI_CHROME_ARGS",
        )
    ) or any(
        environment.get(key) == "1"
        for key in (
            "CHROME_DEVTOOLS_AXI_HEADED",
            "CHROME_DEVTOOLS_AXI_AUTO_CONNECT",
        )
    ):
        raise Protected("attached, headed, persistent, or custom browser")
    # Also inspect actual browser roots: env alone must not hide a desktop browser.
    for child in proc.children(recursive=True):
        try:
            child_args = child.cmdline()
            if not child_args or Path(child_args[0]).name not in (
                "chrome",
                "chromium",
                "headless_shell",
                "chrome-headless-shell",
            ):
                continue
            if any(arg.startswith("--type=") for arg in child_args):
                continue
            if not any(arg in ("--headless", "--headless=new") for arg in child_args) or not any(
                arg.startswith("--user-data-dir=/tmp/puppeteer_dev_chrome_profile-")
                for arg in child_args
            ):
                raise Protected("non-disposable browser profile")
        except psutil.NoSuchProcess:
            continue
    connections = proc.net_connections(kind="tcp")
    if not any(
        c.status == psutil.CONN_LISTEN and c.laddr.ip == "127.0.0.1" and c.laddr.port == port
        for c in connections
    ):
        raise Protected("recorded listener not owned by bridge")
    busy = any(
        c.laddr.port == port
        and c.status not in (psutil.CONN_LISTEN, psutil.CONN_TIME_WAIT, psutil.CONN_CLOSE)
        for c in connections
    )
    io = proc.io_counters()
    return {
        "pid": pid,
        "started": proc.create_time(),
        "port": port,
        "io": [io.read_chars, io.write_chars],
        "busy": busy,
    }


def advance(previous, current, now, max_gap):
    same = previous is not None and all(
        previous.get(k) == current[k] for k in ("pid", "started", "port")
    )
    try:
        observed = float(previous["observed"]) if same else -1
        since = float(previous["idle_since"]) if same else now
        continuous = 0 <= now - observed <= max_gap and 0 <= since <= observed
    except (KeyError, TypeError, ValueError):
        continuous = False
    unchanged = same and previous.get("io") == current["io"]
    idle_since = since if continuous and unchanged and not current["busy"] else now
    return {
        **current,
        "observed": now,
        "idle_since": idle_since,
        "stopping": bool(same and previous.get("stopping")),
    }


def terminate_if_unchanged(name, path, expected):
    # A pidfd pins the process even if it exits and its numeric PID gets reused.
    fd = os.pidfd_open(expected["pid"])
    try:
        fresh = observe(name, path)
        if fresh["busy"] or any(fresh[k] != expected[k] for k in ("pid", "started", "port", "io")):
            return "changed-before-stop", fresh
        signal.pidfd_send_signal(fd, signal.SIGTERM)
        poll = select.poll()
        poll.register(fd, select.POLLIN)
        return ("stopped" if poll.poll(2000) else "shutdown-requested"), fresh
    finally:
        os.close(fd)


def save_state(path, value):
    fd, temporary = tempfile.mkstemp(prefix=".state-", dir=path.parent)
    try:
        with os.fdopen(fd, "w") as stream:
            json.dump(value, stream, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def positive_seconds(value):
    result = float(value)
    if not math.isfinite(result) or result <= 0:
        raise argparse.ArgumentTypeError("must be finite and positive")
    return result


def run(args):
    boot = Path("/proc/sys/kernel/random/boot_id").read_text().strip()
    previous = {}
    try:
        state = owned_json(args.state)
        if (
            state.get("version") == 1
            and state.get("boot") == boot
            and isinstance(state.get("sessions"), dict)
        ):
            previous = {
                key: value for key, value in state["sessions"].items() if isinstance(value, dict)
            }
    except FileNotFoundError:
        pass
    except (OSError, ValueError, Protected) as error:
        print(json.dumps({"state_reset": str(error)}))
    records = [("default", REGISTRY / "bridge.pid")]
    records += [(p.parent.name, p) for p in sorted((REGISTRY / "sessions").glob("*/bridge.pid"))]
    updated = dict(previous) if args.session else {}
    summary = {
        "mode": "apply" if args.apply else "dry-run",
        "stale": 0,
        "protected": 0,
        "sessions": [],
    }
    for name, path in records:
        if args.session and name != args.session:
            continue
        updated.pop(name, None)
        try:
            current = observe(name, path)
            now = time.monotonic()
            entry = advance(previous.get(name), current, now, args.max_gap_seconds)
            idle = now - entry["idle_since"]
            action = "busy" if current["busy"] else "observing"
            if entry["stopping"]:
                action = "shutdown-pending"
            elif idle >= args.idle_seconds:
                action = "would-stop"
                if args.apply:
                    action, fresh = terminate_if_unchanged(name, path, current)
                    if action == "changed-before-stop":
                        entry = advance(None, fresh, time.monotonic(), args.max_gap_seconds)
                    else:
                        entry["stopping"] = True
            if action != "stopped":
                updated[name] = entry
            summary["sessions"].append(
                {
                    "name": name,
                    "pid": current["pid"],
                    "idle_seconds": round(idle),
                    "action": action,
                }
            )
        except (FileNotFoundError, ProcessLookupError, psutil.NoSuchProcess):
            summary["stale"] += 1
        except (OSError, ValueError, Protected, psutil.AccessDenied) as error:
            summary["protected"] += 1
            summary["sessions"].append({"name": name, "action": "protected", "reason": str(error)})
    if args.apply:
        save_state(args.state, {"version": 1, "boot": boot, "sessions": updated})
    print(json.dumps(summary, sort_keys=True))


def main():
    parser = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter
    )
    parser.add_argument(
        "--apply",
        action="store_true",
        help="persist observations and stop eligible idle bridges (default: dry-run)",
    )
    parser.add_argument("--idle-seconds", type=positive_seconds, default=7200)
    parser.add_argument("--max-gap-seconds", type=positive_seconds, default=900)
    parser.add_argument("--state", type=Path, default=DEFAULT_STATE)
    parser.add_argument("--session", help="limit inspection to one named session")
    args = parser.parse_args()
    if args.session and not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", args.session):
        parser.error("unsafe session name")
    if not hasattr(os, "pidfd_open") or not hasattr(signal, "pidfd_send_signal"):
        parser.error("Linux pidfd support required; refusing unsafe PID-only signaling")
    if not args.apply:
        run(args)
        return
    os.umask(0o077)
    args.state.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    if (
        args.state.parent.is_symlink()
        or args.state.parent.stat().st_uid != UID
        or args.state.parent.stat().st_mode & 0o022
    ):
        parser.error("unsafe state directory")
    lock = os.open(args.state.with_suffix(".lock"), os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('{"action":"already-running"}')
            return
        run(args)
    finally:
        os.close(lock)


if __name__ == "__main__":
    main()
