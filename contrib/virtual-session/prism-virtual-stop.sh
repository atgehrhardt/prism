#!/usr/bin/env bash
# Prism: prep "undo" for the "Desktop (Virtual)" app. Re-enables the physical
# output, disarms the capture override, and destroys the virtual output.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-virtual-desktop.state"
VNAME="Prism-Virtual"
LOG="$HOME/.local/state/prism-virtual.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== virtual-desktop stop $(date -Is) ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

exec 9>"$RUNTIME/prism-virtual.lock"
flock -x -w 90 9 || echo "virtual-stop: lock timeout, proceeding anyway"

# Disarm capture override first so any new stream uses the desktop.
rm -f "$OVERRIDE_FILE"

# Re-enable the physical output.
if [ -f "$STATE" ]; then
  read -r PRIMARY < "$STATE"
  if [ -n "$PRIMARY" ]; then
    echo "re-enabling physical output $PRIMARY"
    kscreen-doctor "output.$PRIMARY.enable" 2>/dev/null || true
  fi
  rm -f "$STATE"
fi

# Destroy the virtual output (it disappears when krfb-virtualmonitor exits).
pkill -f "krfb-virtualmonitor --name $VNAME" 2>/dev/null || true
echo "virtual desktop torn down"
