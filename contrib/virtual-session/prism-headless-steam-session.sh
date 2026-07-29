#!/usr/bin/env bash
# Launch Steam directly inside Prism's private labwc compositor.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_ID="${PRISM_SESSION_ID:?missing PRISM_SESSION_ID}"
WAYLAND_SOCKET="${WAYLAND_DISPLAY:?missing WAYLAND_DISPLAY}"
X_DISPLAY="${DISPLAY:?missing DISPLAY}"
APP_ID="${PRISM_STEAM_APP_ID:-}"

case "$APP_ID" in
  '' | *[!0-9]*)
    [ -z "$APP_ID" ] || {
      echo "ERROR: invalid Steam app ID '$APP_ID'" >&2
      exit 2
    }
    ;;
esac

export XDG_SESSION_TYPE=wayland
export PULSE_SINK=prism-headless
export PULSE_PROP="prism.session.id=$SESSION_ID"
unset GAMESCOPE_WAYLAND_DISPLAY

echo "starting Steam directly in labwc socket=$WAYLAND_SOCKET display=$X_DISPLAY session=$SESSION_ID"
if [ -n "$APP_ID" ]; then
  exec "$SCRIPT_DIR/prism-headless-steam.sh" \
    steam -silent "steam://rungameid/$APP_ID"
fi
exec "$SCRIPT_DIR/prism-headless-steam.sh" \
  steam -gamepadui -steamos3 -steampal -steamdeck
