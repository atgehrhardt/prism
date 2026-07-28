#!/usr/bin/env bash
# Prism: prep "undo" for the "Desktop (Virtual)" app. Re-enables the physical
# output, disarms the capture override, and destroys the virtual output.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-virtual-desktop.state"
VNAME="Prism-Virtual"
LOG="$HOME/.local/state/prism-virtual.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-audio-common.sh
. "$SCRIPT_DIR/prism-audio-common.sh"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== virtual-desktop stop $(date -Is) ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

# kscreen-doctor can hang when KWin is in a degenerate state; cap every call.
prism_kscreen() {
  timeout 10 kscreen-doctor "$@"
}

prism_output_snapshot() {
  set -o pipefail
  prism_kscreen -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g'
}

prism_output_is_enabled() {
  local output="$1"
  prism_output_snapshot | awk -v target="$output" '
    /^Output:/ {name=$3}
    /^\tenabled$/ && name == target {found=1}
    END {exit found ? 0 : 1}
  '
}

prism_output_exists() {
  local output="$1"
  prism_output_snapshot | awk -v target="$output" '
    /^Output:/ && $3 == target {found=1}
    END {exit found ? 0 : 1}
  '
}

cleanup_failed=0
audio_cleanup_failed=0

# Shared cross-mode capture lock (see prism-headless-start.sh).
exec 9>"$RUNTIME/prism-capture.lock"
flock -x -w 90 9 || echo "virtual-stop: lock timeout, proceeding anyway"

# Disarm capture override first so any new stream uses the desktop.
rm -f "$OVERRIDE_FILE"

# Tear down audio routing: stop the guard, unload the loopback and the
# session sink.
pkill -f prism-virtual-audio.sh 2>/dev/null || true
ASTATE="$RUNTIME/prism-virtual-audio.state"
if command -v pactl >/dev/null 2>&1; then
  if [ -f "$ASTATE" ]; then
    loop_module="$(prism_audio_state_get "$ASTATE" loop_module 2>/dev/null || true)"
    sink_module="$(prism_audio_state_get "$ASTATE" sink_module 2>/dev/null || true)"
    physical_sink="$(prism_audio_state_get "$ASTATE" physical_sink 2>/dev/null || true)"
    prism_unload_module "$loop_module" || {
      cleanup_failed=1
      audio_cleanup_failed=1
    }
    prism_unload_module "$sink_module" || {
      cleanup_failed=1
      audio_cleanup_failed=1
    }
  fi
  prism_unload_loopback_modules prism-virtual.monitor prism-stream || {
    cleanup_failed=1
    audio_cleanup_failed=1
  }
  prism_unload_named_sink_modules prism-virtual || {
    cleanup_failed=1
    audio_cleanup_failed=1
  }
elif [ -e "$ASTATE" ]; then
  echo "ERROR: virtual audio ownership state exists but pactl is unavailable"
  cleanup_failed=1
  audio_cleanup_failed=1
fi
[ "$audio_cleanup_failed" -ne 0 ] || rm -f "$ASTATE"

# Re-enable the physical outputs we disabled.
if [ -f "$STATE" ]; then
  RESTORE_STATE="${STATE}.restore.$$"
  : > "$RESTORE_STATE"
  if ! OUTPUTS="$(prism_output_snapshot)"; then
    echo "ERROR: KWin output state is unavailable; retaining recovery state"
    cp "$STATE" "$RESTORE_STATE"
    cleanup_failed=1
  else
    while read -r OUT; do
      [ -z "$OUT" ] && continue
      if ! printf '%s\n' "$OUTPUTS" | awk -v target="$OUT" '
        /^Output:/ && $3 == target {found=1}
        END {exit found ? 0 : 1}
      '; then
        echo "recorded output $OUT is disconnected; no restoration is needed"
        continue
      fi
      echo "re-enabling physical output $OUT"
      if ! prism_kscreen "output.$OUT.enable" >/dev/null 2>&1 || ! prism_output_is_enabled "$OUT"; then
        echo "ERROR: physical output $OUT could not be verified as enabled"
        printf '%s\n' "$OUT" >> "$RESTORE_STATE"
        cleanup_failed=1
      fi
    done < "$STATE"
  fi
  if [ -s "$RESTORE_STATE" ]; then
    mv -f "$RESTORE_STATE" "$STATE"
  else
    rm -f "$RESTORE_STATE" "$STATE"
  fi
fi

# Destroy the virtual output (it disappears when krfb-virtualmonitor exits).
pkill -f "krfb-virtualmonitor --name $VNAME" 2>/dev/null || true
for _ in $(seq 1 20); do
  if ! pgrep -f "krfb-virtualmonitor --name ${VNAME}([[:space:]]|$)" >/dev/null 2>&1; then
    break
  fi
  sleep 0.25
done
if pgrep -f "krfb-virtualmonitor --name ${VNAME}([[:space:]]|$)" >/dev/null 2>&1; then
  echo "ERROR: Prism virtual-monitor process remains active"
  cleanup_failed=1
fi

if prism_output_exists "Virtual-$VNAME"; then
  echo "ERROR: Prism virtual output Virtual-$VNAME remains active"
  cleanup_failed=1
elif [ -f "$STATE" ] && ! prism_output_snapshot >/dev/null; then
  echo "ERROR: KWin is unavailable while virtual-display recovery is incomplete"
  cleanup_failed=1
fi

# Restore the desktop default sink last: sinks for disabled outputs do not
# exist until the output is back, and PipeWire takes a moment to re-create
# them, so wait for the target to appear and retry until the switch sticks.
RESTORE="$(sed -n 's/^prism_default_sink *= *//p' "$HOME/.config/prism/prism.conf" 2>/dev/null | tail -1)"
RESTORE="${RESTORE:-${physical_sink:-}}"
if [ -n "$RESTORE" ]; then
  echo "restoring default sink: $RESTORE"
  restored=0
  for _ in $(seq 1 20); do
    if pactl list short sinks 2>/dev/null | awk -v target="$RESTORE" '$2 == target {found=1} END {exit found ? 0 : 1}'; then
      pactl set-default-sink "$RESTORE" 2>/dev/null || true
      if [ "$(pactl get-default-sink 2>/dev/null || true)" = "$RESTORE" ]; then
        restored=1
        break
      fi
    fi
    sleep 0.5
  done
  if [ "$restored" -eq 0 ]; then
    echo "WARN: recorded default sink $RESTORE is unavailable; keeping the current available sink"
  fi
  echo "default sink now: $(pactl get-default-sink 2>/dev/null || true)"
fi
if [ "$cleanup_failed" -ne 0 ]; then
  echo "ERROR: virtual desktop teardown is incomplete"
  exit 1
fi
echo "virtual desktop torn down"
