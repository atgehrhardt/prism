#!/usr/bin/env bash
# Prism: prep "undo" for the "Desktop (Virtual)" app. Re-enables the physical
# output, disarms the capture override, and destroys the virtual output.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOG="$HOME/.local/state/prism-virtual.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-virtual-common.sh
. "$SCRIPT_DIR/prism-virtual-common.sh"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== virtual-desktop stop $(date -Is) ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

# Shared cross-mode capture lock (see prism-headless-start.sh).
exec 9>"$RUNTIME/prism-capture.lock"
flock -x -w 90 9 || echo "virtual-stop: lock timeout, proceeding anyway"

if ! prism_virtual_cleanup; then
  echo "ERROR: virtual desktop teardown is incomplete"
  exit 1
fi
echo "virtual desktop torn down"
