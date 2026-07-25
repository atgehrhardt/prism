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

# Wait for a possibly still-running steamos-start.sh, then tear down.
exec 9>"$RUNTIME/prism-steamos.lock"
flock -x -w 90 9 || echo "steamos-stop: lock timeout, proceeding anyway"

# 1. Disarm the capture override first so any new stream uses the desktop.
rm -f "$OVERRIDE_FILE"

# 2. Tear down gamescope (Steam inside it usually exits via gamescopereaper).
pkill -x gamescope 2>/dev/null || true
pkill -x gamescopereaper 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -x gamescope >/dev/null || break
  sleep 0.5
done
pkill -9 -x gamescope 2>/dev/null || true
pkill -9 -x gamescopereaper 2>/dev/null || true

# 2b. Kill any Steam still attached to the headless session (it sometimes
# outlives gamescope). Such processes have WAYLAND_DISPLAY=wayland-sunshine
# or a non-:0 DISPLAY (gamescope's Xwayland) in their environment.
for p in $(pgrep -x steam); do
  env_disp="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^(WAYLAND_DISPLAY|DISPLAY)=' || true)"
  case "$env_disp" in
    *wayland-sunshine* | DISPLAY=:1 | DISPLAY=:2 | DISPLAY=:3)
      kill "$p" 2>/dev/null || true ;;
  esac
done
sleep 1
for p in $(pgrep -x steam); do
  env_disp="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^(WAYLAND_DISPLAY|DISPLAY)=' || true)"
  case "$env_disp" in
    *wayland-sunshine* | DISPLAY=:1 | DISPLAY=:2 | DISPLAY=:3)
      kill -9 "$p" 2>/dev/null || true ;;
  esac
done

# 3. Relaunch Steam on the desktop session.
unset WAYLAND_DISPLAY
if ! pgrep -x steam >/dev/null; then
  setsid steam -silent >/dev/null 2>&1 &
  echo "relaunched desktop steam"
fi
