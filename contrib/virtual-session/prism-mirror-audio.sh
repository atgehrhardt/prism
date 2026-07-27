#!/usr/bin/env bash
# Prism: audio router for mirror (default) and portal-output streams.
#
# Prism is pointed at a dedicated "prism-stream" capture sink (audio_sink in
# prism.conf) so headless sessions can keep desktop audio out of the stream.
# For mirror streams the desktop IS the content, so this script loops the
# physical sink's monitor into the capture sink — preserving stock behavior
# (audio on both the stream and the host speakers) — and returns the default
# sink to the physical output after Prism's stream-start switch.
#
# Invoked by process.cpp via prism_run_session_script with PRISM_AUDIO_ACTION:
#   start — set up routing (self-backgrounds a watchdog) and record state
#   stop  — tear down routing and restore the default sink
# State: $XDG_RUNTIME_DIR/prism-mirror-audio.state (loop_module, physical_sink)
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$RUNTIME/prism-mirror-audio.state"
LOG="$HOME/.local/state/prism.log"
CAPTURE_SINK="prism-stream"
mkdir -p "$(dirname "$LOG")"

ACTION="${PRISM_AUDIO_ACTION:-start}"

if [ "$ACTION" = "stop" ]; then
  exec >>"$LOG" 2>&1
  echo "=== mirror-audio stop $(date -Is) ==="
  pkill -f 'prism-mirror-audio.sh.*prism-mirror-watchdog' 2>/dev/null || true
  PHYSICAL=""
  if [ -f "$STATE" ]; then
    # shellcheck source=/dev/null
    . "$STATE" 2>/dev/null || true
    if [ -n "${loop_module:-}" ]; then
      pactl unload-module "$loop_module" 2>/dev/null || true
    fi
    PHYSICAL="${physical_sink:-}"
    rm -f "$STATE"
  fi
  # A user-configured prism_default_sink wins over the recorded physical sink.
  RESTORE="$(sed -n 's/^prism_default_sink *= *//p' "$HOME/.config/prism/prism.conf" 2>/dev/null | tail -1)"
  RESTORE="${RESTORE:-$PHYSICAL}"
  if [ -n "$RESTORE" ]; then
    # PipeWire/WirePlumber can move the default while the loopback is being
    # torn down, so retry and verify instead of firing once.
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
  exit 0
fi

# --- start (watchdog portion runs as a detached child) -----------------------
if [ "${1:-}" = "prism-mirror-watchdog" ]; then
  exec >>"$LOG" 2>&1
  PHYSICAL="${2:-}"
  # Keep the desktop default on the physical output while the stream runs;
  # Prism switches it to the capture sink at stream start.
  for _ in $(seq 1 720); do
    [ -f "$STATE" ] || break
    cur="$(pactl get-default-sink 2>/dev/null || true)"
    if [ -n "$PHYSICAL" ] && [ "$cur" != "$PHYSICAL" ]; then
      pactl set-default-sink "$PHYSICAL" 2>/dev/null || true
    fi
    # pipewire's stream-restore can re-route Prism's capture stream to a monitor
    # it used in earlier sessions; keep it pinned to the capture sink's monitor.
    cap_idx="$(pactl list short sources 2>/dev/null | awk -v n="prism-stream.monitor" '$2==n {print $1; exit}')"
    if [ -n "$cap_idx" ]; then
      pactl list source-outputs 2>/dev/null | awk '
        /^Source Output #/ { idx = substr($3, 2) }
        /^[[:space:]]*Source: / { src = $2 }
        /application.name = "prism"/ { print idx, src }
      ' | while read -r so_id so_src; do
        if [ -n "$so_id" ] && [ "$so_src" != "$cap_idx" ]; then
          pactl move-source-output "$so_id" "$cap_idx" 2>/dev/null || true
        fi
      done
    fi
    sleep 5
  done
  exit 0
fi

exec >>"$LOG" 2>&1
echo "=== mirror-audio start $(date -Is) ==="

# Physical output the desktop was using before the stream.
PHYSICAL="$(pactl get-default-sink 2>/dev/null || true)"
echo "physical sink: ${PHYSICAL:-none}"

# Make sure the capture sink exists before Prism's audio init looks for it.
if ! pactl list short sinks 2>/dev/null | grep -q '^[0-9]*[[:space:]]prism-stream[[:space:]]'; then
  pactl load-module module-null-sink sink_name=prism-stream \
    sink_properties=device.description="Prism Stream Capture" >/dev/null 2>&1 || true
fi

# Loop the physical output into the capture sink so desktop audio is heard on
# the stream (and keeps playing on the host speakers).
LOOP_ID=""
if [ -n "$PHYSICAL" ]; then
  LOOP_ID="$(pactl load-module module-loopback source="$PHYSICAL.monitor" sink="$CAPTURE_SINK" latency_msec=20 2>/dev/null || true)"
  echo "loopback module: ${LOOP_ID:-failed}"
fi

{
  echo "loop_module=${LOOP_ID:-}"
  echo "physical_sink=$PHYSICAL"
} > "$STATE"

setsid "$0" prism-mirror-watchdog "$PHYSICAL" >/dev/null 2>&1 &
