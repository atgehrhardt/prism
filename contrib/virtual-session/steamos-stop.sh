#!/usr/bin/env bash
# Prism: launched by Sunshine's "SteamOS (Headless)" app as a prep "undo" command
# (also fires if the client disconnects/crashes). Tears down the headless session
# and returns Steam to the desktop. Idempotent.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
LOG="$HOME/.local/state/prism-steamos.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== steamos-stop $(date -Is) ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

# 1. Disarm the capture override first so any new stream uses the desktop.
rm -f "$OVERRIDE_FILE"

# 2. Tear down gamescope (Steam inside it exits with it).
pkill -x gamescope 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -x gamescope >/dev/null || break
  sleep 0.5
done
pkill -9 -x gamescope 2>/dev/null || true

# 3. Relaunch Steam on the desktop session.
unset WAYLAND_DISPLAY
if ! pgrep -x steam >/dev/null; then
  setsid steam -silent >/dev/null 2>&1 &
  echo "relaunched desktop steam"
fi
