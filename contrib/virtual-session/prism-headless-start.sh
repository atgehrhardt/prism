#!/usr/bin/env bash
# Bring up a verified, session-owned labwc headless environment.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless.state"
ASTATE="$RUNTIME/prism-headless-audio.state"
ENV_FILE="$RUNTIME/prism-headless-session.env"
INPUT_ENV_FILE="$RUNTIME/prism-headless-input.env"
READY_FILE="$RUNTIME/prism-headless-session.ready"
INPUT_READY_FILE="$RUNTIME/prism-headless-input.ready"
LOG="$HOME/.local/state/prism-headless.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="$SCRIPT_DIR:$PATH"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== headless-start $(date -Is) backend=labwc steam=${PRISM_STEAM:-0} id=${PRISM_SESSION_ID:-?} client=${PRISM_CLIENT_WIDTH:-?}x${PRISM_CLIENT_HEIGHT:-?}@${PRISM_CLIENT_FPS:-?} ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

for required in awk cmp date find flock labwc pactl prism-input-bridge \
  python3 readlink systemctl systemd-run timeout wayland-info wlr-randr; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "ERROR: headless mode requires '$required'" >&2
    exit 1
  fi
done
if ! labwc --version 2>&1 | grep -q '+xwayland'; then
  echo "ERROR: installed labwc was built without Xwayland support" >&2
  exit 1
fi
prism_headless_require_backend || exit 1

W="${PRISM_CLIENT_WIDTH:-1920}"
H="${PRISM_CLIENT_HEIGHT:-1080}"
FPS="${PRISM_CLIENT_FPS:-60}"
HDR="${PRISM_CLIENT_HDR:-false}"
STEAM="${PRISM_STEAM:-0}"
SESSION_ID="${PRISM_SESSION_ID:-manual-$$}"
APP_UNIT="prism-headless-app-${SESSION_ID}.scope"
OUTPUT_NAME="HEADLESS-1"
case "$W:$H:$FPS" in
  *[!0-9:]* | :* | *: | *::*)
    echo "ERROR: invalid client mode ${W}x${H}@${FPS}" >&2
    exit 1
    ;;
esac
if [ "$W" -eq 0 ] || [ "$W" -gt 16384 ] ||
  [ "$H" -eq 0 ] || [ "$H" -gt 16384 ] ||
  [ "$FPS" -eq 0 ] || [ "$FPS" -gt 1000 ]; then
  echo "ERROR: client mode is outside the supported range" >&2
  exit 1
fi
case "$HDR" in
  true | false) ;;
  *)
    echo "ERROR: invalid HDR value '$HDR'" >&2
    exit 1
    ;;
esac
case "$STEAM" in
  0 | 1) ;;
  *)
    echo "ERROR: invalid Steam mode '$STEAM'" >&2
    exit 1
    ;;
esac
if [ "$STEAM" = "1" ]; then
  for required in bwrap steam; do
    command -v "$required" >/dev/null 2>&1 || {
      echo "ERROR: Steam headless mode requires the '$required' command" >&2
      exit 1
    }
  done
fi
case "${PRISM_STEAM_APP_ID:-}" in
  '' | *[!0-9]*)
    [ -z "${PRISM_STEAM_APP_ID:-}" ] || {
      echo "ERROR: invalid Steam app ID '${PRISM_STEAM_APP_ID}'" >&2
      exit 1
    }
    ;;
esac
case "$SESSION_ID" in
  '' | *[!A-Za-z0-9_.-]*)
    echo "ERROR: invalid session id '$SESSION_ID'" >&2
    exit 1
    ;;
esac
[ "${#SESSION_ID}" -le 128 ] || {
  echo "ERROR: session id is too long" >&2
  exit 1
}

exec 9>"$RUNTIME/prism-capture.lock"
flock -x -w 10 9 || {
  echo "ERROR: timed out waiting for capture lifecycle lock" >&2
  exit 1
}

COMMITTED=0
STEAM_HANDOFF=0
CAPTURE_SINK_MODULE=""
SESSION_SINK_MODULE=""
PHYSICAL_SINK=""

rollback() {
  local rc=$?
  local provisional_loop="" cleanup_failed=0 audio_cleanup_failed=0

  trap - EXIT INT TERM
  [ "$COMMITTED" = "1" ] && return "$rc"
  echo "headless startup failed; rolling back"
  rm -f "$OVERRIDE_FILE"
  prism_stop_unit "$APP_UNIT" || cleanup_failed=1
  prism_stop_headless_app_units || cleanup_failed=1
  prism_stop_unit "$PRISM_STEAM_UNIT" || cleanup_failed=1
  prism_stop_unit "$PRISM_INPUT_UNIT" || cleanup_failed=1
  prism_stop_unit "$PRISM_HEADLESS_UNIT" || cleanup_failed=1
  provisional_loop="$(prism_audio_state_get "$ASTATE" loop_module 2>/dev/null || true)"
  prism_unload_module "$provisional_loop" || audio_cleanup_failed=1
  prism_unload_loopback_modules prism-headless.monitor prism-stream || audio_cleanup_failed=1
  prism_unload_module "$SESSION_SINK_MODULE" || audio_cleanup_failed=1
  prism_unload_named_sink_modules prism-headless || audio_cleanup_failed=1
  rm -f "$READY_FILE" "$INPUT_READY_FILE"
  if [ "$cleanup_failed" -eq 0 ]; then
    rm -f "$STATE" "$ENV_FILE" "$INPUT_ENV_FILE"
  else
    echo "ERROR: preserving headless ownership files because rollback left a live unit" >&2
  fi
  [ "$audio_cleanup_failed" -ne 0 ] || rm -f "$ASTATE"
  prism_restore_default_sink "$PHYSICAL_SINK" || true
  [ "$STEAM_HANDOFF" = "1" ] && prism_schedule_steam_restore
  if [ "$cleanup_failed" -ne 0 ] || [ "$audio_cleanup_failed" -ne 0 ]; then
    echo "ERROR: headless rollback is incomplete" >&2
  fi
  return "$rc"
}
trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

prism_stop_unit "$PRISM_STEAM_RESTORE_UNIT" || {
  echo "ERROR: could not cancel desktop Steam restoration" >&2
  exit 1
}

# Reconcile current units and obsolete nested/direct sessions before launch.
OLD_VERSION="$(prism_state_get "$STATE" version 2>/dev/null || true)"
OLD_SESSION_MODULE="$(prism_state_get "$STATE" session_sink_module 2>/dev/null || true)"
OLD_LOOP_MODULE="$(prism_state_get "$STATE" loop_module 2>/dev/null || true)"
OLD_AUDIO_LOOP_MODULE="$(prism_audio_state_get "$ASTATE" loop_module 2>/dev/null || true)"
OLD_APP_UNIT="$(prism_state_get "$STATE" app_unit 2>/dev/null || true)"
case "$OLD_APP_UNIT" in
  prism-headless-app-*.scope) prism_stop_unit "$OLD_APP_UNIT" || exit 1 ;;
esac
prism_stop_headless_app_units || exit 1
prism_stop_unit "$PRISM_STEAM_UNIT" || exit 1
prism_stop_unit "$PRISM_INPUT_UNIT" || exit 1
prism_stop_unit "$PRISM_HEADLESS_UNIT" || exit 1
prism_stop_unit prism-labwc.service || exit 1
prism_unload_module "$OLD_LOOP_MODULE" || exit 1
prism_unload_module "$OLD_AUDIO_LOOP_MODULE" || exit 1
prism_unload_loopback_modules prism-headless.monitor prism-stream || exit 1
prism_unload_module "$OLD_SESSION_MODULE" || exit 1
if { [ -f "$STATE" ] && [ "$OLD_VERSION" != "4" ]; } ||
  prism_legacy_headless_present; then
  prism_cleanup_legacy_headless || exit 1
fi
prism_unload_named_sink_modules prism-headless || exit 1
rm -f "$STATE" "$ASTATE" "$ENV_FILE" "$INPUT_ENV_FILE" \
  "$READY_FILE" "$INPUT_READY_FILE" "$OVERRIDE_FILE" \
  "$RUNTIME/prism-labwc-reset-required"

if [ "$STEAM" = "1" ]; then
  if pgrep -x steam >/dev/null 2>&1; then
    echo "shutting down desktop Steam"
    STEAM_HANDOFF=1
    steam -shutdown >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      pgrep -x steam >/dev/null 2>&1 || break
      sleep 0.25
    done
  fi
  if pgrep -x steam >/dev/null 2>&1 ||
    pgrep -x steamwebhelper >/dev/null 2>&1; then
    echo "desktop Steam survived graceful shutdown; forcing initial handoff"
    STEAM_HANDOFF=1
    pkill -x steam >/dev/null 2>&1 || true
    pkill -x steamwebhelper >/dev/null 2>&1 || true
    sleep 1
    pkill -9 -x steam >/dev/null 2>&1 || true
    pkill -9 -x steamwebhelper >/dev/null 2>&1 || true
  fi
  if pgrep -x steam >/dev/null 2>&1; then
    echo "ERROR: desktop Steam could not be stopped" >&2
    exit 1
  fi
fi

PHYSICAL_SINK="$(pactl get-default-sink 2>/dev/null || true)"
case "$PHYSICAL_SINK" in
  '' | *[!A-Za-z0-9_.-]*)
    echo "ERROR: could not identify the physical default audio sink" >&2
    exit 1
    ;;
esac
if ! pactl list short sinks 2>/dev/null |
  awk '$2 == "prism-stream" {found=1} END {exit !found}'; then
  CAPTURE_SINK_MODULE="$(pactl load-module module-null-sink sink_name=prism-stream \
    sink_properties=device.description="Prism Stream Capture" 2>/dev/null || true)"
fi
if ! pactl list short sinks 2>/dev/null |
  awk '$2 == "prism-stream" {found=1} END {exit !found}'; then
  echo "ERROR: could not create prism-stream audio sink" >&2
  exit 1
fi
SESSION_SINK_MODULE="$(pactl load-module module-null-sink sink_name=prism-headless \
  sink_properties=device.description="Prism Headless Session" 2>/dev/null || true)"
case "$SESSION_SINK_MODULE" in
  '' | *[!0-9]*)
    echo "ERROR: could not create prism-headless audio sink" >&2
    exit 1
    ;;
esac

write_session_environment() {
  local wayland_display="${1:-}"
  local x_display="${2:-}"

  prism_atomic_write "$ENV_FILE" <<EOF
PRISM_SESSION_ID=$SESSION_ID
PRISM_HEADLESS_BACKEND=systemd
PRISM_HEADLESS_UNIT=$PRISM_HEADLESS_UNIT
PRISM_HEADLESS_INPUT_UNIT=$PRISM_INPUT_UNIT
PRISM_HEADLESS_STEAM_UNIT=$PRISM_STEAM_UNIT
PRISM_HEADLESS_APP_UNIT=$APP_UNIT
PRISM_CLIENT_WIDTH=$W
PRISM_CLIENT_HEIGHT=$H
PRISM_CLIENT_FPS=$FPS
PRISM_CLIENT_HDR=false
PRISM_STEAM=$STEAM
PRISM_STEAM_APP_ID=${PRISM_STEAM_APP_ID:-}
PRISM_PHYSICAL_SINK=$PHYSICAL_SINK
WAYLAND_DISPLAY=$wayland_display
DISPLAY=$x_display
PULSE_SINK=prism-headless
PULSE_PROP=prism.session.id=$SESSION_ID
EOF
}

if ! write_session_environment; then
  echo "ERROR: could not publish headless session environment" >&2
  exit 1
fi

# One wall-clock budget covers labwc dispatch, owned sockets, output mode,
# capture protocol discovery, and virtual-input readiness.
START_MS="$(date +%s%3N)"
DEADLINE_MS=$((START_MS + 10000))
prism_start_unit "$PRISM_HEADLESS_UNIT" || {
  echo "ERROR: could not start $PRISM_HEADLESS_UNIT" >&2
  exit 1
}

WAYLAND_SOCKET=""
XDISP=""
INPUT_STARTED=0
SAW_WAYLAND=0
SAW_XWAYLAND=0
SAW_OUTPUT=0
MODE_CONFIGURED=0
SAW_MODE=0
SAW_PROTOCOLS=0
SAW_INPUT=0

while [ "$(date +%s%3N)" -lt "$DEADLINE_MS" ]; do
  if ! prism_unit_live "$PRISM_HEADLESS_UNIT"; then
    echo "ERROR: labwc exited before headless readiness" >&2
    exit 1
  fi
  OWNED_SOCKET_INODES="$(prism_unit_socket_inodes "$PRISM_HEADLESS_UNIT")"
  if [ -z "$WAYLAND_SOCKET" ]; then
    for socket_path in "$RUNTIME"/wayland-*; do
      [ -S "$socket_path" ] || continue
      socket_name="$(basename "$socket_path")"
      case "$socket_name" in *.lock) continue ;; esac
      if prism_socket_owned_by_inode_set "$socket_path" "$OWNED_SOCKET_INODES"; then
        WAYLAND_SOCKET="$socket_name"
        SAW_WAYLAND=1
        break
      fi
    done
  fi
  if [ -z "$XDISP" ]; then
    for socket_path in /tmp/.X11-unix/X*; do
      [ -S "$socket_path" ] || continue
      socket_name="$(basename "$socket_path")"
      if prism_socket_owned_by_inode_set "$socket_path" "$OWNED_SOCKET_INODES"; then
        XDISP=":${socket_name#X}"
        SAW_XWAYLAND=1
        break
      fi
    done
  fi
  if [ -n "$WAYLAND_SOCKET" ] && [ "$SAW_OUTPUT" = "0" ]; then
    RANDR_OUTPUT="$(timeout 1 env \
      XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$WAYLAND_SOCKET" \
      wlr-randr 2>/dev/null || true)"
    if printf '%s\n' "$RANDR_OUTPUT" | grep -q "^${OUTPUT_NAME} "; then
      SAW_OUTPUT=1
    fi
  fi
  if [ "$SAW_OUTPUT" = "1" ] && [ "$MODE_CONFIGURED" = "0" ]; then
    if timeout 1 env \
      XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$WAYLAND_SOCKET" \
      wlr-randr --output "$OUTPUT_NAME" \
      --custom-mode "${W}x${H}@${FPS}" >/dev/null 2>&1; then
      MODE_CONFIGURED=1
    fi
  fi
  if [ "$MODE_CONFIGURED" = "1" ] && [ "$SAW_MODE" = "0" ]; then
    RANDR_OUTPUT="$(timeout 1 env \
      XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$WAYLAND_SOCKET" \
      wlr-randr 2>/dev/null || true)"
    if printf '%s\n' "$RANDR_OUTPUT" |
      grep -Eq "^[[:space:]]+${W}x${H} px, ${FPS}([.]0+)? Hz \\(current\\)$"; then
      SAW_MODE=1
    fi
  fi
  if [ "$SAW_MODE" = "1" ] && [ "$SAW_PROTOCOLS" = "0" ]; then
    PROTOCOLS="$(timeout 1 env \
      XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY="$WAYLAND_SOCKET" \
      wayland-info 2>/dev/null || true)"
    if printf '%s\n' "$PROTOCOLS" | grep -q "zwlr_screencopy_manager_v1" &&
      printf '%s\n' "$PROTOCOLS" | grep -q "zwp_linux_dmabuf_v1" &&
      printf '%s\n' "$PROTOCOLS" | grep -q "zxdg_output_manager_v1" &&
      printf '%s\n' "$PROTOCOLS" | grep -q "zwlr_virtual_pointer_manager_v1" &&
      printf '%s\n' "$PROTOCOLS" | grep -q "zwp_virtual_keyboard_manager_v1"; then
      SAW_PROTOCOLS=1
    fi
  fi
  if [ "$SAW_PROTOCOLS" = "1" ] && [ "$SAW_XWAYLAND" = "1" ] &&
    [ "$INPUT_STARTED" = "0" ]; then
    write_session_environment "$WAYLAND_SOCKET" "$XDISP" || {
      echo "ERROR: could not update headless session environment" >&2
      exit 1
    }
    if ! prism_atomic_write "$INPUT_ENV_FILE" <<EOF
PRISM_SESSION_ID=$SESSION_ID
PRISM_WAYLAND_SOCKET=$WAYLAND_SOCKET
PRISM_HEADLESS_INPUT_READY_FILE=$INPUT_READY_FILE
PRISM_CAPTURE_OVERRIDE_FILE=$OVERRIDE_FILE
EOF
    then
      echo "ERROR: could not publish input bridge environment" >&2
      exit 1
    fi
    prism_start_unit "$PRISM_INPUT_UNIT" || {
      echo "ERROR: could not start $PRISM_INPUT_UNIT" >&2
      exit 1
    }
    INPUT_STARTED=1
  fi
  if [ "$INPUT_STARTED" = "1" ]; then
    if prism_headless_ready_marker_matches "$INPUT_READY_FILE" "$SESSION_ID"; then
      SAW_INPUT=1
    elif ! prism_unit_live "$PRISM_INPUT_UNIT"; then
      echo "ERROR: Prism input bridge exited before becoming ready" >&2
      exit 1
    fi
  fi
  if [ "$SAW_WAYLAND" = "1" ] && [ "$SAW_XWAYLAND" = "1" ] &&
    [ "$SAW_MODE" = "1" ] && [ "$SAW_PROTOCOLS" = "1" ] &&
    [ "$SAW_INPUT" = "1" ]; then
    break
  fi
  sleep 0.05
done

if [ "$SAW_WAYLAND" != "1" ]; then
  echo "ERROR: labwc did not publish an owned Wayland socket within 10s" >&2
  exit 1
elif [ "$SAW_XWAYLAND" != "1" ]; then
  echo "ERROR: labwc did not publish an owned Xwayland socket within 10s" >&2
  exit 1
elif [ "$SAW_OUTPUT" != "1" ]; then
  echo "ERROR: labwc did not expose HEADLESS-1 within 10s" >&2
  exit 1
elif [ "$SAW_MODE" != "1" ]; then
  echo "ERROR: labwc did not apply ${W}x${H}@${FPS} within 10s" >&2
  exit 1
elif [ "$SAW_PROTOCOLS" != "1" ]; then
  echo "ERROR: labwc is missing required output, DMA-BUF, screencopy, or virtual-input protocols" >&2
  exit 1
elif [ "$SAW_INPUT" != "1" ]; then
  echo "ERROR: Prism input bridge did not become ready within 10s" >&2
  exit 1
fi

printf '%s\n' "$SESSION_ID" | prism_atomic_write "$READY_FILE" || {
  echo "ERROR: could not publish labwc session readiness" >&2
  exit 1
}

for _ in $(seq 1 50); do
  [ -f "$ASTATE" ] && break
  sleep 0.1
done
LOOP_MODULE="$(prism_state_get "$ASTATE" loop_module 2>/dev/null || true)"
case "$LOOP_MODULE" in
  '' | *[!0-9]*)
    echo "ERROR: headless audio routing did not become ready" >&2
    exit 1
    ;;
esac

if ! prism_atomic_write "$STATE" <<EOF
version=4
session_id=$SESSION_ID
backend=systemd
unit=$PRISM_HEADLESS_UNIT
input_unit=$PRISM_INPUT_UNIT
steam_unit=$PRISM_STEAM_UNIT
app_unit=$APP_UNIT
steam=$STEAM
wayland_display=$WAYLAND_SOCKET
output_name=$OUTPUT_NAME
x_display=$XDISP
width=$W
height=$H
framerate=$FPS
physical_sink=$PHYSICAL_SINK
capture_sink_module=$CAPTURE_SINK_MODULE
session_sink_module=$SESSION_SINK_MODULE
loop_module=$LOOP_MODULE
EOF
then
  echo "ERROR: could not publish headless session state" >&2
  exit 1
fi

if ! printf '%s\n' "wlroots:$SESSION_ID" | prism_atomic_write "$OVERRIDE_FILE"; then
  echo "ERROR: could not publish private-labwc capture override" >&2
  exit 1
fi

if [ "$STEAM" = "1" ]; then
  prism_start_unit "$PRISM_STEAM_UNIT" || {
    echo "ERROR: could not start $PRISM_STEAM_UNIT" >&2
    exit 1
  }
  for _ in $(seq 1 100); do
    if ! prism_unit_live "$PRISM_HEADLESS_UNIT"; then
      echo "ERROR: labwc exited while Steam was starting" >&2
      exit 1
    fi
    prism_unit_has_comm "$PRISM_STEAM_UNIT" steam && break
    prism_unit_live "$PRISM_STEAM_UNIT" || break
    sleep 0.1
  done
  if ! prism_unit_has_comm "$PRISM_STEAM_UNIT" steam; then
    echo "ERROR: Steam did not start within 10s after labwc readiness" >&2
    exit 1
  fi
fi

COMMITTED=1
trap - EXIT INT TERM
echo "headless session ready backend=labwc id=$SESSION_ID socket=$WAYLAND_SOCKET output=$OUTPUT_NAME x=$XDISP"
