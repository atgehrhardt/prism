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

# kscreen-doctor can hang when KWin is in a degenerate state; cap every call.
KSD="timeout 10 kscreen-doctor"

exec 9>"$RUNTIME/prism-virtual.lock"
flock -x -w 90 9 || echo "virtual-stop: lock timeout, proceeding anyway"

# Disarm capture override first so any new stream uses the desktop.
rm -f "$OVERRIDE_FILE"

# Tear down audio routing: stop the guard, unload the loopback and the
# session sink.
pkill -f prism-virtual-audio.sh 2>/dev/null || true
ASTATE="$RUNTIME/prism-virtual-audio.state"
if [ -f "$ASTATE" ]; then
  # shellcheck source=/dev/null
  . "$ASTATE" 2>/dev/null || true
  if [ -n "${loop_module:-}" ]; then
    pactl unload-module "$loop_module" 2>/dev/null || true
  fi
  if [ -n "${sink_module:-}" ]; then
    pactl unload-module "$sink_module" 2>/dev/null || true
  fi
  rm -f "$ASTATE"
fi

# Re-enable the physical outputs we disabled.
if [ -f "$STATE" ]; then
  while read -r OUT; do
    [ -z "$OUT" ] && continue
    echo "re-enabling physical output $OUT"
    $KSD "output.$OUT.enable" 2>/dev/null || true
  done < "$STATE"
  rm -f "$STATE"
fi

# Destroy the virtual output (it disappears when krfb-virtualmonitor exits).
pkill -f "krfb-virtualmonitor --name $VNAME" 2>/dev/null || true

# Restore the desktop default sink last: sinks for disabled outputs do not
# exist until the output is back, and PipeWire takes a moment to re-create
# them, so wait for the target to appear and retry until the switch sticks.
RESTORE="$(sed -n 's/^prism_default_sink *= *//p' "$HOME/.config/sunshine/sunshine.conf" 2>/dev/null | tail -1)"
RESTORE="${RESTORE:-${physical_sink:-}}"
if [ -n "$RESTORE" ]; then
  echo "restoring default sink: $RESTORE"
  for _ in $(seq 1 20); do
    if pactl list short sinks 2>/dev/null | grep -q "[[:space:]]${RESTORE}[[:space:]]"; then
      pactl set-default-sink "$RESTORE" 2>/dev/null || true
      [ "$(pactl get-default-sink 2>/dev/null || true)" = "$RESTORE" ] && break
    fi
    sleep 0.5
  done
  echo "default sink now: $(pactl get-default-sink 2>/dev/null || true)"
fi
echo "virtual desktop torn down"
