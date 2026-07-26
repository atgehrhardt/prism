#!/usr/bin/env bash
# Prism: bring up the headless gamescope session for an app with capture mode
# "headless" (or "steamos"). Generic: works for any app. Steam-specific
# behavior (quit desktop Steam, launch Big Picture, restore on exit) only
# happens when PRISM_STEAM=1 is set in the environment.
#
# Env in:  PRISM_STEAM=0|1 (default 0)
#          SUNSHINE_CLIENT_WIDTH / HEIGHT / FPS / ENABLE_HDR (set by Sunshine)
# State out: $XDG_RUNTIME_DIR/prism-headless.state  (KEY=VALUE lines:
#          steam, wayland_display, x_display)
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless.state"
SOCKET="wayland-prism"
LOG="$HOME/.local/state/prism-headless.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== headless-start $(date -Is) steam=${PRISM_STEAM:-0} client=${SUNSHINE_CLIENT_WIDTH:-?}x${SUNSHINE_CLIENT_HEIGHT:-?}@${SUNSHINE_CLIENT_FPS:-?} ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

# Serialize with prism-headless-stop.sh.
exec 9>"$RUNTIME/prism-headless.lock"
flock -x 9

# 1. Steam handling (only when requested): quit desktop Steam if running.
if [ "${PRISM_STEAM:-0}" = "1" ]; then
  if pgrep -x steam >/dev/null; then
    steam -shutdown 2>/dev/null || true
    for _ in $(seq 1 30); do
      pgrep -x steam >/dev/null || break
      sleep 0.5
    done
  else
    echo "desktop steam not running, skipping shutdown"
  fi
fi

# 2. Arm the capture override so this stream captures the headless session.
echo "$SOCKET" > "$OVERRIDE_FILE"

# 3. Size the headless output to the client's requested mode.
W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"
export WAYLAND_DISPLAY="$SOCKET"
for _ in $(seq 1 40); do
  [ -S "$RUNTIME/$SOCKET" ] && break
  sleep 0.25
done
if command -v wlr-randr >/dev/null; then
  wlr-randr --output HEADLESS-1 --custom-mode "${W}x${H}@${FPS}" 2>/dev/null || true
fi

# 4. Launch gamescope inside the headless compositor.
HDR_FLAGS=()
if [ "${SUNSHINE_CLIENT_ENABLE_HDR:-false}" = "true" ]; then
  HDR_FLAGS+=(--hdr-enabled)
fi
if [ "${PRISM_STEAM:-0}" = "1" ]; then
  SESSION_CMD=(steam -gamepadui -steamos)
else
  # Generic keepalive; the app's own command joins the session via the
  # gamescope wayland/X sockets (see state file).
  SESSION_CMD=(sleep infinity)
fi
setsid env WAYLAND_DISPLAY="$SOCKET" XDG_SESSION_TYPE=wayland \
  gamescope -W "$W" -H "$H" -r "$FPS" -e -f "${HDR_FLAGS[@]}" \
  -- "${SESSION_CMD[@]}" >>"$LOG" 2>&1 9>&- &

# 5. Discover the gamescope session sockets and record state for the app
# command environment and for teardown.
GSOCKET=""
XDISP=""
for _ in $(seq 1 40); do
  for s in "$RUNTIME"/gamescope-*; do
    case "$s" in
      *.lock | *-ei | *-ei.lock | *limiter*) continue ;;
    esac
    [ -S "$s" ] && GSOCKET="$(basename "$s")" && break
  done
  for x in /tmp/.X11-unix/X*; do
    [ -S "$x" ] || continue
    owner="$(stat -c %U "$x" 2>/dev/null)"
    [ "$owner" = "$(id -un)" ] || continue
    # gamescope's Xwayland is the one that is NOT the desktop :0
    n="${x##*/X}"
    [ "$n" = "0" ] && continue
    XDISP=":$n" && break
  done
  [ -n "$GSOCKET" ] && [ -n "$XDISP" ] && break
  sleep 0.25
done
{
  echo "steam=${PRISM_STEAM:-0}"
  echo "wayland_display=$GSOCKET"
  echo "x_display=$XDISP"
} > "$STATE"
echo "launched gamescope ${W}x${H}@${FPS} hdr=${HDR_FLAGS[*]:-off} session=${SESSION_CMD[*]} socket=$GSOCKET x=$XDISP"
