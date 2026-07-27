#!/usr/bin/env bash
# Route only processes owned by Prism's headless service into the stream sink.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless-audio.state"
LOG="$HOME/.local/state/prism-headless.log"
SESSION_SINK="prism-headless"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"

exec >>"$LOG" 2>&1
PHYSICAL="${1:-}"
echo "=== headless-audio $(date -Is) physical=${PHYSICAL:-?} unit=$PRISM_HEADLESS_UNIT ==="

CAPTURE_SINK=""
CONFIG="$HOME/.config/prism/prism.conf"
if [ -f "$CONFIG" ]; then
  CAPTURE_SINK="$(sed -n 's/^audio_sink *= *//p' "$CONFIG" | tail -1)"
fi
for _ in $(seq 1 240); do
  if [ -n "$CAPTURE_SINK" ] && pactl list short sinks 2>/dev/null |
    awk -v wanted="$CAPTURE_SINK" '$2 == wanted {found=1} END {exit !found}'; then
    break
  fi
  if [ -z "$CAPTURE_SINK" ]; then
    current="$(pactl get-default-sink 2>/dev/null || true)"
    case "$current" in sink-prism-*) CAPTURE_SINK="$current"; break ;; esac
  fi
  sleep 0.5
done
if [ -z "$CAPTURE_SINK" ]; then
  echo "ERROR: timed out waiting for Prism's capture sink"
  exit 1
fi

LOOP_ID="$(pactl load-module module-loopback source="$SESSION_SINK.monitor" \
  sink="$CAPTURE_SINK" latency_msec=20 2>/dev/null || true)"
case "$LOOP_ID" in
  '' | *[!0-9]*) echo "ERROR: could not create headless audio loopback"; exit 1 ;;
esac
pactl suspend-sink "$SESSION_SINK" 0 >/dev/null 2>&1 || true
pactl suspend-source "$SESSION_SINK.monitor" 0 >/dev/null 2>&1 || true
if [ -n "$PHYSICAL" ]; then
  pactl set-default-sink "$PHYSICAL" >/dev/null 2>&1 || true
fi

if ! prism_atomic_write "$STATE" <<EOF
loop_module=$LOOP_ID
physical_sink=$PHYSICAL
EOF
then
  echo "ERROR: could not publish headless audio state"
  exit 1
fi

# Startup publishes the override only after socket readiness. Remain alive in
# the owned cgroup while waiting for that final commit.
for _ in $(seq 1 300); do
  [ -f "$OVERRIDE_FILE" ] && break
  prism_unit_live "$PRISM_HEADLESS_UNIT" || exit 0
  sleep 0.1
done
[ -f "$OVERRIDE_FILE" ] || exit 0

while [ -f "$OVERRIDE_FILE" ] && prism_unit_live "$PRISM_HEADLESS_UNIT"; do
  CONTROL_GROUP="$(prism_unit_control_group "$PRISM_HEADLESS_UNIT")"
  APP_CONTROL_GROUP="$(prism_unit_control_group "${PRISM_HEADLESS_APP_UNIT:-missing.scope}")"
  [ -n "$CONTROL_GROUP" ] || break

  if [ -n "$PHYSICAL" ]; then
    current="$(pactl get-default-sink 2>/dev/null || true)"
    case "$current" in
      "$CAPTURE_SINK" | sink-prism-*)
        pactl set-default-sink "$PHYSICAL" >/dev/null 2>&1 || true ;;
    esac
  fi

  capture_source="$(pactl list short sources 2>/dev/null |
    awk -v wanted="$CAPTURE_SINK.monitor" '$2 == wanted {print $1; exit}')"
  if [ -n "$capture_source" ]; then
    pactl list source-outputs 2>/dev/null | awk '
      /^Source Output #/ { idx = substr($3, 2) }
      /^[[:space:]]*Source: / { src = $2 }
      /application.name = "prism"/ { print idx, src }
    ' | while read -r output_id source_id; do
      if [ -n "$output_id" ] && [ "$source_id" != "$capture_source" ]; then
        pactl move-source-output "$output_id" "$capture_source" >/dev/null 2>&1 || true
      fi
    done
  fi

  pactl list sink-inputs 2>/dev/null | awk '
    function emit() {
      if (idx != "") print idx, pid, sink, session
    }
    /^Sink Input #/ {
      emit()
      idx = substr($3, 2)
      pid = ""
      sink = ""
      session = ""
    }
    /^[[:space:]]*Sink: / { sink = $2 }
    /application.process.id = / { gsub(/"/, "", $3); pid = $3 }
    /prism.session.id = / { gsub(/"/, "", $3); session = $3 }
    END { emit() }
  ' | while read -r input_id pid current_sink stream_session; do
    [ -d "/proc/$pid" ] || continue
    if prism_pid_in_control_group "$pid" "$CONTROL_GROUP" ||
      { [ -n "$APP_CONTROL_GROUP" ] &&
        prism_pid_in_control_group "$pid" "$APP_CONTROL_GROUP"; } ||
      [ "$stream_session" = "${PRISM_SESSION_ID:-}" ]; then
      if [ "$current_sink" != "$SESSION_SINK" ]; then
        pactl move-sink-input "$input_id" "$SESSION_SINK" >/dev/null 2>&1 || true
      fi
    elif [ -n "$PHYSICAL" ] && [ "$current_sink" = "$CAPTURE_SINK" ]; then
      pactl move-sink-input "$input_id" "$PHYSICAL" >/dev/null 2>&1 || true
    fi
  done
  sleep 2
done
