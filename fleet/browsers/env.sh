# fleet browser default tier - sourced by every shell an agent inherits.
# Ladder: obscura (default) -> chrome (pixel-critical fallback) -> vnc (human).
# Escalate for one task with:  eval "$(fleet-browser env chrome)"
# Docs: ~/oss-fleet/browsers/README.md
export CHROME_DEVTOOLS_AXI_BROWSER_URL="${CHROME_DEVTOOLS_AXI_BROWSER_URL:-http://127.0.0.1:9222}"
export FLEET_BROWSER_TIER="${FLEET_BROWSER_TIER:-obscura}"
case ":$PATH:" in *":$HOME/oss-fleet/browsers:"*) ;; *) export PATH="$HOME/oss-fleet/browsers:$PATH" ;; esac
