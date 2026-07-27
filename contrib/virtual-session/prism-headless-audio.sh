#!/usr/bin/env bash
# Prism: audio separator for headless sessions. Started in the background by
# prism-headless-start.sh and runs until the session's capture override is
# removed.
#
# Prism switches the system DEFAULT sink to its capture sink when a stream
# starts, which would pull every desktop app's audio into the headless stream.
# This guard waits for that switch (or for the forced audio_sink to appear),
# loops the headless session's dedicated sink into the capture sink, returns
# the default sink to the physical output, and then keeps moving session audio
# streams into the session sink (PULSE_SINK alone is not honored by every
# audio path).
#
# Args: $1 = physical sink name to restore as default.
# State out: $XDG_RUNTIME_DIR/prism-headless-audio.state (loop_module, physical_sink)
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless-audio.state"
LOG="$HOME/.local/state/prism-headless.log"
SESSION_SINK="prism-headless"
exec >>"$LOG" 2>&1
echo "=== headless-audio $(date -Is) physical=${1:-?} ==="

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
  echo "timed out waiting for the prism capture sink; audio not separated"
  exit 1
fi
echo "capture sink: $CAPTURE_SINK"

# Loop the headless session sink into the capture sink so session apps are
# heard on the stream.
LOOP_ID="$(pactl load-module module-loopback source="$SESSION_SINK.monitor" sink="$CAPTURE_SINK" latency_msec=20 2>/dev/null || true)"
echo "loopback module: ${LOOP_ID:-failed}"

# Keep the session sink and its monitor unsuspended; null sinks with no active
# input otherwise suspend and the loopback goes silent.
pactl suspend-sink "$SESSION_SINK" 0 2>/dev/null || true
pactl suspend-source "$SESSION_SINK.monitor" 0 2>/dev/null || true

# Put the default sink back on the physical output so desktop apps started
# during the session are NOT captured.
if [ -n "$PHYSICAL" ]; then
  pactl set-default-sink "$PHYSICAL" 2>/dev/null || true
fi

{
  echo "loop_module=${LOOP_ID:-}"
  echo "physical_sink=$PHYSICAL"
} > "$STATE"

# Routing watchdog: PULSE_SINK is not honored by every audio path (Proton,
# some native engines), so actively move any stream whose process belongs to
# the headless session (gamescope env) into the session sink. The reverse
# direction matters just as much: Prism switches the default sink to its
# capture sink at stream start, which strands desktop apps on it — move any
# non-session stream sitting on the capture sink back to the physical output
# so desktop audio never leaks into the headless stream. Runs until the
# session's capture override is removed (teardown), then exits.
while [ -f "$OVERRIDE_FILE" ]; do
  # Prism switches the default sink to its capture sink at stream start (and on
  # every stream restart), which can happen AFTER the one-time restore above.
  # Keep forcing it back to the physical output or desktop audio goes silent.
  if [ -n "$PHYSICAL" ]; then
    cur_def="$(pactl get-default-sink 2>/dev/null || true)"
    case "$cur_def" in
      "$CAPTURE_SINK" | sink-prism-*)
        if pactl set-default-sink "$PHYSICAL" 2>/dev/null; then
          echo "default sink was $cur_def; restored $PHYSICAL"
        fi ;;
    esac
  fi
  # pipewire's stream-restore remembers where Prism's capture stream recorded
  # from in earlier sessions and re-routes it there on every new stream (e.g.
  # the physical monitor from before audio_sink was configured). Pin Prism's
  # record stream to the capture sink's monitor.
  cap_idx="$(pactl list short sources 2>/dev/null | awk -v n="$CAPTURE_SINK.monitor" '$2==n {print $1; exit}')"
  if [ -n "$cap_idx" ]; then
    pactl list source-outputs 2>/dev/null | awk '
      /^Source Output #/ { idx = substr($3, 2) }
      /^[[:space:]]*Source: / { src = $2 }
      /application.name = "prism"/ { print idx, src }
    ' | while read -r so_id so_src; do
      if [ -n "$so_id" ] && [ "$so_src" != "$cap_idx" ] && \
         pactl move-source-output "$so_id" "$cap_idx" 2>/dev/null; then
        echo "moved prism capture source-output $so_id from source $so_src to $CAPTURE_SINK.monitor"
      fi
    done
  fi
  pactl list sink-inputs 2>/dev/null | awk '
    /^Sink Input #/ { idx = substr($3, 2) }
    /^[[:space:]]*Sink: / { sink = $2 }
    /application.process.id = / { gsub(/"/, "", $3); print idx, $3, sink }
  ' | while read -r input_id pid cur_sink; do
    [ -d "/proc/$pid" ] || continue
    env_disp="$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | grep -E '^(WAYLAND_DISPLAY|DISPLAY)=' || true)"
    case "$env_disp" in
      *gamescope* | *wayland-prism* | DISPLAY=:1 | DISPLAY=:2 | DISPLAY=:3)
        if [ "$cur_sink" != "$SESSION_SINK" ] && pactl move-sink-input "$input_id" "$SESSION_SINK" 2>/dev/null; then
          echo "routed sink-input $input_id (pid $pid) to $SESSION_SINK"
        fi ;;
      *)
        if [ -n "$PHYSICAL" ] && [ "$cur_sink" = "$CAPTURE_SINK" ] && \
           pactl move-sink-input "$input_id" "$PHYSICAL" 2>/dev/null; then
          echo "moved desktop sink-input $input_id (pid $pid) off the capture sink to $PHYSICAL"
        fi ;;
    esac
  done
  sleep 2
done
echo "capture override gone; audio guard exiting"
