#!/usr/bin/env bash
# Prism: one-shot audio separator for headless sessions. Started in the
# background by prism-headless-start.sh.
#
# Sunshine switches the system DEFAULT sink to its capture sink when a stream
# starts, which would pull every desktop app's audio into the headless stream.
# This guard waits for that switch (or for the forced audio_sink to appear),
# loops the headless session's dedicated sink into the capture sink, and then
# returns the default sink to the physical output so desktop audio stays off
# the stream while the session's apps are still captured.
#
# Args: $1 = physical sink name to restore as default.
# State out: $XDG_RUNTIME_DIR/prism-headless-audio.state (loop_module, physical_sink)
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$RUNTIME/prism-headless-audio.state"
LOG="$HOME/.local/state/prism-headless.log"
SESSION_SINK="prism-headless"
exec >>"$LOG" 2>&1
echo "=== headless-audio $(date -Is) physical=${1:-?} ==="

PHYSICAL="${1:-}"

# The sink Sunshine captures from: a forced audio_sink in the config wins,
# otherwise it is the sink-sunshine-* sink Sunshine switches the default to at
# stream start.
CAPTURE_SINK=""
CONFIG="$HOME/.config/sunshine/sunshine.conf"
if [ -f "$CONFIG" ]; then
  CAPTURE_SINK="$(sed -n 's/^audio_sink *= *//p' "$CONFIG" | tail -1)"
fi

for _ in $(seq 1 240); do
  if [ -n "$CAPTURE_SINK" ]; then
    pactl list short sinks 2>/dev/null | grep -q "$CAPTURE_SINK" && break
  else
    cur="$(pactl get-default-sink 2>/dev/null || true)"
    case "$cur" in
      sink-sunshine-*) CAPTURE_SINK="$cur"; break ;;
    esac
  fi
  sleep 0.5
done
if [ -z "$CAPTURE_SINK" ]; then
  echo "timed out waiting for the sunshine capture sink; audio not separated"
  exit 1
fi
echo "capture sink: $CAPTURE_SINK"

# Loop the headless session sink into the capture sink so session apps (which
# use PULSE_SINK=prism-headless) are heard on the stream.
LOOP_ID="$(pactl load-module module-loopback source="$SESSION_SINK.monitor" sink="$CAPTURE_SINK" latency_msec=20 2>/dev/null || true)"
echo "loopback module: ${LOOP_ID:-failed}"

# Put the default sink back on the physical output so desktop apps started
# during the session are NOT captured.
if [ -n "$PHYSICAL" ]; then
  pactl set-default-sink "$PHYSICAL" 2>/dev/null || true
fi

{
  echo "loop_module=${LOOP_ID:-}"
  echo "physical_sink=$PHYSICAL"
} > "$STATE"
