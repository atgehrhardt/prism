#!/usr/bin/env bash
# Prism: prep "undo" for the "Desktop (Virtual)" app. Re-enables the physical
# output, disarms the capture override, and destroys the virtual output.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-virtual-desktop.state"
VNAME="Prism-Virtual"
LOG="$HOME/.local/state/prism-virtual.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== virtual-desktop stop $(date -Is) ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

exec 9>"$RUNTIME/prism-virtual.lock"
flock -x -w 90 9 || echo "virtual-stop: lock timeout, proceeding anyway"

# Disarm capture override first so any new stream uses the desktop.
rm -f "$OVERRIDE_FILE"

# Tear down audio routing: stop the guard, unload the loopback and the
# session sink, and restore the physical default sink.
pkill -f prism-virtual-audio.sh 2>/dev/null || true
ASTATE="$RUNTIME/prism-virtual-audio.state"
if [ -f "$ASTATE" ]; then
  # shellcheck source=/dev/null
  . "$ASTATE" 2>/dev/null || true
  [ -n "${loop_module:-}" ] && pactl unload-module "$loop_module" 2>/dev/null || true
  [ -n "${sink_module:-}" ] && pactl unload-module "$sink_module" 2>/dev/null || true
  if [ -n "${physical_sink:-}" ]; then
    pactl set-default-sink "$physical_sink" 2>/dev/null || true
  fi
  rm -f "$ASTATE"
fi

# Re-enable the physical outputs we disabled.
if [ -f "$STATE" ]; then
  while read -r OUT; do
    [ -z "$OUT" ] && continue
    echo "re-enabling physical output $OUT"
    kscreen-doctor "output.$OUT.enable" 2>/dev/null || true
  done < "$STATE"
  rm -f "$STATE"
fi

# Destroy the virtual output (it disappears when krfb-virtualmonitor exits).
pkill -f "krfb-virtualmonitor --name $VNAME" 2>/dev/null || true
echo "virtual desktop torn down"
