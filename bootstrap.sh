#!/usr/bin/env bash
# Bootstrap repository tooling only; no host provisioning without explicit apply.
set -euo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
command -v python3 >/dev/null 2>&1 || { echo 'Install Python 3.12+ (Ubuntu 24.04/26.04) first.' >&2; exit 1; }
python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 12) else "Python 3.12+ required")'
export PATH="$HOME/.local/bin:$PATH"
WANTED_UV="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["tools"]["uv"]["version"])' "$ROOT/toolchain.lock.json")"
if ! command -v uv >/dev/null 2>&1 || [[ "$(uv --version)" != "uv $WANTED_UV"* ]]; then
  python3 "$ROOT/scripts/install_tools.py" --lock "$ROOT/toolchain.lock.json" --home "$HOME" --tools uv
fi
uv sync --project "$ROOT" --locked
if (($#)); then
  exec "$ROOT/factory" "$@"
fi
printf '%s\n' 'Repository tooling installed. Next: ./factory init; review .local/host.yml; ./factory plan; ./factory apply.'
