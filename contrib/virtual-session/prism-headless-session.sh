#!/usr/bin/env bash
# Prism foreground supervisor for prism-headless-session.service.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
SOCKET="wayland-prism"
LOG="$HOME/.local/state/prism-headless.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

W="${PRISM_CLIENT_WIDTH:?missing PRISM_CLIENT_WIDTH}"
H="${PRISM_CLIENT_HEIGHT:?missing PRISM_CLIENT_HEIGHT}"
FPS="${PRISM_CLIENT_FPS:?missing PRISM_CLIENT_FPS}"
STEAM_MODE="${PRISM_STEAM:-0}"
PHYSICAL_SINK="${PRISM_PHYSICAL_SINK:-}"

echo "=== headless-session $(date -Is) id=${PRISM_SESSION_ID:-?} ${W}x${H}@${FPS} steam=$STEAM_MODE ==="

"$SCRIPT_DIR/prism-headless-audio.sh" "$PHYSICAL_SINK" &

GAMESCOPE_FLAGS=(--adaptive-sync --rt)
if [ "${PRISM_CLIENT_HDR:-false}" = "true" ]; then
  GAMESCOPE_FLAGS+=(--hdr-enabled)
fi

if [ "$STEAM_MODE" = "1" ]; then
  GAMESCOPE_FLAGS+=(--xwayland-count 2)
  if [ -n "${PRISM_STEAM_APP_ID:-}" ]; then
    SESSION_CMD=("$SCRIPT_DIR/prism-headless-steam.sh" steam)
  else
    SESSION_CMD=("$SCRIPT_DIR/prism-headless-steam.sh" steam -gamepadui -steamos3 -steampal -steamdeck)
    if command -v mangoapp >/dev/null 2>&1; then
      GAMESCOPE_FLAGS+=(--mangoapp)
      export MANGOHUD_CONFIGFILE="$RUNTIME/prism-mangoapp.conf"
      printf '%s\n' "no_display" > "$MANGOHUD_CONFIGFILE"
      export MANGOHUD_CONFIG="${MANGOHUD_CONFIG:+$MANGOHUD_CONFIG,}debug=0"
    else
      echo "mangoapp not found; Steam performance overlay will be unavailable"
    fi
  fi
else
  SESSION_CMD=(sleep infinity)
fi

export WAYLAND_DISPLAY="$SOCKET"
export XDG_SESSION_TYPE=wayland
export PULSE_SINK=prism-headless
echo "starting gamescope flags=${GAMESCOPE_FLAGS[*]} session=${SESSION_CMD[*]}"
exec gamescope -w "$W" -h "$H" -W "$W" -H "$H" -r "$FPS" -e -f \
  "${GAMESCOPE_FLAGS[@]}" -- "${SESSION_CMD[@]}"
