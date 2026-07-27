#!/usr/bin/env bash
# Prism: audio router for virtual-display sessions. Started in the background
# by prism-virtual-start.sh and runs until the session's capture override is
# removed.
#
# The physical outputs are disabled for the duration of a virtual-display
# stream, so everything the user does belongs on the stream. This guard waits
# for Prism's capture sink, creates a dedicated "prism-virtual" null sink,
# selects it as the system default (moving existing streams onto it), and loops
# it into the capture sink so all session audio is heard on the stream. On
# teardown the default sink is returned to the physical output recorded at
# start.
#
# Args: $1 = physical sink name to restore as default afterwards.
# State out: $XDG_RUNTIME_DIR/prism-virtual-audio.state
#   (loop_module, sink_module, physical_sink)
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-virtual-audio.state"
LOG="$HOME/.local/state/prism-virtual.log"
SESSION_SINK="prism-virtual"
exec >>"$LOG" 2>&1
echo "=== virtual-audio $(date -Is) physical=${1:-?} ==="

PHYSICAL="${1:-}"

# The sink Prism captures from: a forced audio_sink in the config wins,
# otherwise it is the sink-prism-* sink Prism switches the default to at
# stream start.
CAPTURE_SINK=""
CONFIG="$HOME/.config/prism/prism.conf"
if [ -f "$CONFIG" ]; then
  CAPTURE_SINK="$(sed -n 's/^audio_sink *= *//p' "$CONFIG" | tail -1)"
fi

for _ in $(seq 1 240); do
  if [ -n "$CAPTURE_SINK" ]; then
    pactl list short sinks 2>/dev/null | grep -q "$CAPTURE_SINK" && break
  else
    cur="$(pactl get-default-sink 2>/dev/null || true)"
    case "$cur" in
      sink-prism-*) CAPTURE_SINK="$cur"; break ;;
    esac
  fi
  sleep 0.5
done
if [ -z "$CAPTURE_SINK" ]; then
  echo "timed out waiting for the prism capture sink; audio not routed"
  exit 1
fi
echo "capture sink: $CAPTURE_SINK"

# Dedicated sink for the virtual session. Selecting it as the default routes
# every app (existing and new) onto the stream; the physical outputs are off
# anyway, so nothing is lost on the host.
SINK_MODULE="$(pactl load-module module-null-sink sink_name="$SESSION_SINK" \
  sink_properties=device.description="Prism Virtual Display" 2>/dev/null || true)"
echo "session sink module: ${SINK_MODULE:-failed}"

pactl set-default-sink "$SESSION_SINK" 2>/dev/null || true
pactl list short sink-inputs 2>/dev/null | cut -f1 | while read -r input_id; do
  if pactl move-sink-input "$input_id" "$SESSION_SINK" 2>/dev/null; then
    echo "moved sink-input $input_id to $SESSION_SINK"
  fi
done

# Loop the session sink into the capture sink so apps are heard on the stream.
LOOP_ID="$(pactl load-module module-loopback source="$SESSION_SINK.monitor" sink="$CAPTURE_SINK" latency_msec=20 2>/dev/null || true)"
echo "loopback module: ${LOOP_ID:-failed}"

# Keep the session sink and its monitor unsuspended; null sinks with no active
# input otherwise suspend and the loopback goes silent.
pactl suspend-sink "$SESSION_SINK" 0 2>/dev/null || true
pactl suspend-source "$SESSION_SINK.monitor" 0 2>/dev/null || true

{
  echo "loop_module=${LOOP_ID:-}"
  echo "sink_module=${SINK_MODULE:-}"
  echo "physical_sink=$PHYSICAL"
} > "$STATE"

# Watchdog: Prism may switch the default sink to its capture sink at stream
# start (after the moves above); keep putting the default back on the session
# sink and moving stray streams onto it. Runs until teardown removes the
# capture override, then exits.
while [ -f "$OVERRIDE_FILE" ]; do
  cur="$(pactl get-default-sink 2>/dev/null || true)"
  if [ "$cur" != "$SESSION_SINK" ]; then
    pactl set-default-sink "$SESSION_SINK" 2>/dev/null || true
  fi
  pactl list sink-inputs 2>/dev/null | awk '
    /^Sink Input #/ { idx = substr($3, 2) }
    /^[[:space:]]*Sink: / { sink = $2 }
    /application.process.id = / { print idx, sink }
  ' | while read -r input_id cur_sink; do
    [ "$cur_sink" = "$SESSION_SINK" ] && continue
    if pactl move-sink-input "$input_id" "$SESSION_SINK" 2>/dev/null; then
      echo "routed sink-input $input_id to $SESSION_SINK"
    fi
  done
  sleep 2
done
echo "capture override gone; virtual audio guard exiting"
