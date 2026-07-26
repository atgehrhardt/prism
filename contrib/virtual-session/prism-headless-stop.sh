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
# shellcheck source=/dev/null
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

# 2b. Kill any Steam still attached to the headless session. steamwebhelper
# is a separate process name and survives killing `steam` alone; left behind
# it holds the single-instance lock and the fossilize shader-cache state.
for name in steam steamwebhelper; do
  for p in $(pgrep -x "$name"); do
    env_disp="$(tr '\0' '\n' < "/proc/$p/environ" 2>/dev/null | grep -E '^(WAYLAND_DISPLAY|DISPLAY)=' || true)"
    case "$env_disp" in
      *wayland-prism* | *gamescope* | DISPLAY=:1 | DISPLAY=:2 | DISPLAY=:3)
        kill "$p" 2>/dev/null || true ;;
    esac
  done
done

# Shader-compile workers from the torn-down session must not outlive it; they
# keep cache locks that hang the next session's shader processing.
if [ "$STEAM" = "1" ]; then
  pkill -x fossilize_replay 2>/dev/null || true
fi

# 2c. Tear down headless audio separation: stop the guard if it is still
# waiting, remove the loopback into the capture sink, and destroy the
# session's dedicated sink.
pkill -f prism-headless-audio.sh 2>/dev/null || true
ASTATE="$RUNTIME/prism-headless-audio.state"
if [ -f "$ASTATE" ]; then
  # shellcheck source=/dev/null
  . "$ASTATE" 2>/dev/null || true
  if [ -n "${loop_module:-}" ]; then
    pactl unload-module "$loop_module" 2>/dev/null || true
  fi
  rm -f "$ASTATE"
fi
pactl list short modules 2>/dev/null | grep 'sink_name=prism-headless' | cut -f1 \
  | while read -r m; do pactl unload-module "$m" 2>/dev/null || true; done

rm -f "$STATE"

# 3. Return Steam to the desktop if this was a Steam session.
if [ "$STEAM" = "1" ]; then
  unset WAYLAND_DISPLAY
  # Wait for the headless instance to fully exit so Steam's single-instance
  # lock is released before relaunching on the desktop. steamwebhelper must
  # also be gone: relaunching while it lingers makes the new client treat the
  # launch as "open Steam" and show its window.
  for _ in $(seq 1 40); do
    pgrep -x steam >/dev/null || break
    sleep 0.5
  done
  pkill -9 -x steamwebhelper 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x steamwebhelper >/dev/null || break
    sleep 0.5
  done
  # Relaunch with verification: a failed or ignored start is retried, since
  # Steam silently no-ops if its lock has not been released yet.
  for attempt in 1 2 3; do
    pgrep -x steam >/dev/null && break
    echo "relaunching desktop steam (attempt $attempt)"
    setsid steam -silent >/dev/null 2>&1 9>&- &
    for _ in $(seq 1 20); do
      pgrep -x steam >/dev/null && break
      sleep 0.5
    done
  done
  if pgrep -x steam >/dev/null; then
    echo "desktop steam running"
  else
    echo "WARNING: failed to relaunch desktop steam after 3 attempts"
  fi
fi
