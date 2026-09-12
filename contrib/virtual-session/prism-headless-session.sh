#!/usr/bin/env bash
# Run Prism's private, session-owned labwc compositor.
set -euo pipefail

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
LOG="$HOME/.local/state/prism-headless.log"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# User services do not necessarily inherit the login shell's ~/.local/bin.
export PATH="$SCRIPT_DIR:$HOME/.local/bin:$PATH"
SESSION_ID="${PRISM_SESSION_ID:?missing PRISM_SESSION_ID}"
W="${PRISM_CLIENT_WIDTH:?missing PRISM_CLIENT_WIDTH}"
H="${PRISM_CLIENT_HEIGHT:?missing PRISM_CLIENT_HEIGHT}"
FPS="${PRISM_CLIENT_FPS:?missing PRISM_CLIENT_FPS}"
HDR="${PRISM_CLIENT_HDR:-false}"
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
export WLR_HEADLESS_OUTPUTS=1
export LABWC_UPDATE_ACTIVATION_ENV=no
## @brief Share the session's live SDR-white calibration with the private compositor.
export PRISM_HDR_SETTINGS_FILE="$RUNTIME/prism-headless-hdr"
export XDG_CONFIG_HOME="$LABWC_CONFIG_HOME"
export XDG_SESSION_TYPE=wayland
export PULSE_SINK=prism-headless
export PULSE_PROP="prism.session.id=$SESSION_ID"

# Xwayland must be alive before startup waits for its owned socket. The
# default lazy policy can otherwise leave startup waiting for its first app.
## @brief Request Adaptive Sync for all session content; labwc tests backend support and falls back when unavailable.
cat > "$LABWC_CONFIG_HOME/labwc/rc.xml" <<EOF
<?xml version="1.0"?>
<labwc_config>
  <core><xwaylandPersistence>yes</xwaylandPersistence><hdr>$HDR</hdr><adaptiveSync>yes</adaptiveSync></core>
</labwc_config>
EOF

COMPOSITOR=labwc
if [ "$HDR" = true ]; then
  COMPOSITOR=prism-labwc
  export WLR_RENDERER=vulkan
fi

echo "starting private labwc compositor"
exec "$COMPOSITOR" --config-dir "$LABWC_CONFIG_HOME/labwc"
