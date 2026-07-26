#!/usr/bin/env bash
# Prism: tear down the headless gamescope session (capture mode "headless" /
# "steamos"). Idempotent; also runs when the client disconnects/crashes.
# Steam is returned to the desktop only if the session had PRISM_STEAM=1.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless.state"
LOG="$HOME/.local/state/prism-headless.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== headless-stop $(date -Is) ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

exec 9>"$RUNTIME/prism-headless.lock"
flock -x -w 90 9 || echo "headless-stop: lock timeout, proceeding anyway"

STEAM=0
[ -f "$STATE" ] && . "$STATE" 2>/dev/null && STEAM="${steam:-0}"

# 1. Disarm the capture override first so any new stream uses the desktop.
rm -f "$OVERRIDE_FILE"

# 2. Tear down gamescope (session children exit via gamescopereaper).
pkill -x gamescope 2>/dev/null || true
pkill -x gamescopereaper 2>/dev/null || true
for _ in $(seq 1 20); do
  pgrep -x gamescope >/dev/null || break
  sleep 0.5
done
pkill -9 -x gamescope 2>/dev/null || true
pkill -9 -x gamescopereaper 2>/dev/null || true

# 2b. Kill any Steam still attached to the headless session.
for p in $(pgrep -x steam); do
  env_disp="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^(WAYLAND_DISPLAY|DISPLAY)=' || true)"
  case "$env_disp" in
    *wayland-prism* | *gamescope* | DISPLAY=:1 | DISPLAY=:2 | DISPLAY=:3)
      kill "$p" 2>/dev/null || true ;;
  esac
done

rm -f "$STATE"

# 3. Return Steam to the desktop if this was a Steam session.
if [ "$STEAM" = "1" ]; then
  unset WAYLAND_DISPLAY
  if ! pgrep -x steam >/dev/null; then
    setsid steam -silent >/dev/null 2>&1 &
    echo "relaunched desktop steam"
  fi
fi
