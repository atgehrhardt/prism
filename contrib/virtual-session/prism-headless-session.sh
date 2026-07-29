#!/usr/bin/env bash
# Run Prism's private, session-owned labwc compositor.
set -euo pipefail

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOG="$HOME/.local/state/prism-headless.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ID="${PRISM_SESSION_ID:?missing PRISM_SESSION_ID}"
W="${PRISM_CLIENT_WIDTH:?missing PRISM_CLIENT_WIDTH}"
H="${PRISM_CLIENT_HEIGHT:?missing PRISM_CLIENT_HEIGHT}"
FPS="${PRISM_CLIENT_FPS:?missing PRISM_CLIENT_FPS}"
PHYSICAL_SINK="${PRISM_PHYSICAL_SINK:?missing PRISM_PHYSICAL_SINK}"
LABWC_CONFIG_HOME="$RUNTIME/prism-labwc-config"

mkdir -p "$(dirname "$LOG")" "$LABWC_CONFIG_HOME/labwc"
exec >>"$LOG" 2>&1

echo "=== headless-labwc $(date -Is) id=$SESSION_ID ${W}x${H}@${FPS} ==="
"$SCRIPT_DIR/prism-headless-audio.sh" "$PHYSICAL_SINK" &

# The compositor is a true headless root, never a child of the user's desktop
# compositor. An isolated config home prevents user autostart entries from
# leaking desktop applications into the stream session.
unset DISPLAY WAYLAND_DISPLAY GAMESCOPE_WAYLAND_DISPLAY
export WLR_BACKENDS=headless
export XDG_CONFIG_HOME="$LABWC_CONFIG_HOME"
export XDG_SESSION_TYPE=wayland
export PULSE_SINK=prism-headless
export PULSE_PROP="prism.session.id=$SESSION_ID"

echo "starting private labwc compositor"
exec labwc --config-dir "$LABWC_CONFIG_HOME/labwc"
