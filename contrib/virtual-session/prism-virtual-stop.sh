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

# Restore the desktop default sink, retrying until it sticks: PipeWire and
# WirePlumber can move the default while session sinks are being torn down,
# so a single set-default-sink easily loses the race.
restore_default_sink() {
  local target="$1"
  [ -z "$target" ] && return 0
  echo "restoring default sink: $target"
  for _ in $(seq 1 10); do
    pactl set-default-sink "$target" 2>/dev/null || true
    [ "$(pactl get-default-sink 2>/dev/null || true)" = "$target" ] && break
    sleep 0.5
  done
  echo "default sink now: $(pactl get-default-sink 2>/dev/null || true)"
}

# Tear down audio routing: stop the guard, unload the loopback and the
# session sink, and restore the default sink.
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
# A user-configured prism_default_sink wins over the recorded physical sink.
RESTORE="$(sed -n 's/^prism_default_sink *= *//p' "$HOME/.config/sunshine/sunshine.conf" 2>/dev/null | tail -1)"
RESTORE="${RESTORE:-${physical_sink:-}}"
restore_default_sink "$RESTORE"

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
echo "virtual desktop torn down"
