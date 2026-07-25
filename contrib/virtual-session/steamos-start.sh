#!/usr/bin/env bash
# Prism: launched by Sunshine's "SteamOS (Headless)" app as a prep "do" command.
# Moves Steam from the desktop into a headless labwc + gamescope session and arms
# the capture override so this stream captures that session instead of the desktop.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
SOCKET="wayland-sunshine"
LOG="$HOME/.local/state/prism-steamos.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== steamos-start $(date -Is) ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

# Serialize with steamos-stop.sh: if the client disconnects while this script
# is still setting up, undo must wait for us, then tear everything down.
exec 9>"$RUNTIME/prism-steamos.lock"
flock -x 9

# 1. Quit desktop Steam and wait for it to actually exit.
steam -shutdown 2>/dev/null || true
for _ in $(seq 1 30); do
  pgrep -x steam >/dev/null || break
  sleep 0.5
done

# 2. Arm the capture override (Prism patch reads this at display init for this stream).
echo "$SOCKET" > "$OVERRIDE_FILE"

# 3. Size the headless output to the client's requested mode.
W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"
export WAYLAND_DISPLAY="$SOCKET"
# Wait for labwc's socket to exist (service should already be running).
for _ in $(seq 1 40); do
  [ -S "$RUNTIME/$SOCKET" ] && break
  sleep 0.25
done
if command -v wlr-randr >/dev/null; then
  wlr-randr --output HEADLESS-1 --custom-mode "${W}x${H}@${FPS}" 2>/dev/null || true
fi

# 4. Launch gamescope + Steam (SteamOS UI) inside the headless compositor.
HDR_FLAGS=()
if [ "${SUNSHINE_CLIENT_ENABLE_HDR:-false}" = "true" ]; then
  HDR_FLAGS+=(--hdr-enabled)
fi
setsid env WAYLAND_DISPLAY="$SOCKET" XDG_SESSION_TYPE=wayland \
  gamescope -W "$W" -H "$H" -r "$FPS" -e -f "${HDR_FLAGS[@]}" \
  -- steam -gamepadui -steamos >>"$LOG" 2>&1 9>&- &
echo "launched gamescope ${W}x${H}@${FPS} hdr=${HDR_FLAGS[*]:-off} pid=$!"
