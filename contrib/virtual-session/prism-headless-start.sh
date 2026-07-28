#!/usr/bin/env bash
# Bring up a verified, session-owned gamescope environment for headless capture.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless.state"
ASTATE="$RUNTIME/prism-headless-audio.state"
ENV_FILE="$RUNTIME/prism-headless-session.env"
SOCKET="wayland-prism"
LOG="$HOME/.local/state/prism-headless.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== headless-start $(date -Is) steam=${PRISM_STEAM:-0} id=${PRISM_SESSION_ID:-?} client=${PRISM_CLIENT_WIDTH:-?}x${PRISM_CLIENT_HEIGHT:-?}@${PRISM_CLIENT_FPS:-?} ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

for required in flock gamescope pactl python3 systemctl systemd-run timeout wlr-randr; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "ERROR: headless mode requires '$required'" >&2
    exit 1
  fi
done
prism_headless_require_backend || exit 1

W="${PRISM_CLIENT_WIDTH:-1920}"
H="${PRISM_CLIENT_HEIGHT:-1080}"
FPS="${PRISM_CLIENT_FPS:-60}"
HDR="${PRISM_CLIENT_HDR:-false}"
STEAM="${PRISM_STEAM:-0}"
SESSION_ID="${PRISM_SESSION_ID:-manual-$$}"
APP_UNIT="prism-headless-app-${SESSION_ID}.scope"
case "$W:$H:$FPS" in
  *[!0-9:]* | :* | *: | *::*)
    echo "ERROR: invalid client mode ${W}x${H}@${FPS}" >&2
    exit 1 ;;
esac
if [ "$W" -eq 0 ] || [ "$H" -eq 0 ] || [ "$FPS" -eq 0 ]; then
  echo "ERROR: client width, height, and FPS must be greater than zero" >&2
  exit 1
fi
case "$HDR" in true | false) ;; *) echo "ERROR: invalid HDR value '$HDR'" >&2; exit 1 ;; esac
case "$STEAM" in 0 | 1) ;; *) echo "ERROR: invalid Steam mode '$STEAM'" >&2; exit 1 ;; esac
if [ "$STEAM" = "1" ]; then
  for required in bwrap steam; do
    if ! command -v "$required" >/dev/null 2>&1; then
      echo "ERROR: Steam headless mode requires the '$required' command" >&2
      exit 1
    fi
  done
fi
case "${PRISM_STEAM_APP_ID:-}" in
  '' | *[!0-9]*) [ -z "${PRISM_STEAM_APP_ID:-}" ] || {
    echo "ERROR: invalid Steam app ID '${PRISM_STEAM_APP_ID}'" >&2
    exit 1
  } ;;
esac
case "$SESSION_ID" in
  '' | *[!A-Za-z0-9_.-]*) echo "ERROR: invalid session id '$SESSION_ID'" >&2; exit 1 ;;
esac

exec 9>"$RUNTIME/prism-capture.lock"
flock -x -w 90 9 || {
  echo "ERROR: timed out waiting for capture lifecycle lock" >&2
  exit 1
}

READY=0
SESSION_STARTED=0
CAPTURE_SINK_MODULE=""
SESSION_SINK_MODULE=""
PHYSICAL_SINK=""

rollback() {
  local rc=$?
  trap - EXIT
  [ "$READY" = "1" ] && return "$rc"
  echo "headless startup failed; rolling back"
  rm -f "$OVERRIDE_FILE"
  prism_stop_unit "$APP_UNIT" || true
  prism_stop_unit "$PRISM_HEADLESS_UNIT" || true
  if [ "$SESSION_STARTED" = "1" ]; then
    prism_mark_labwc_reset_required || true
  fi
  prism_unload_module "$SESSION_SINK_MODULE"
  prism_unload_named_sink_modules prism-headless
  rm -f "$STATE" "$ASTATE" "$ENV_FILE"
  prism_restore_default_sink "$PHYSICAL_SINK" || true
  [ "$STEAM" = "1" ] && prism_schedule_steam_restore
  return "$rc"
}
trap rollback EXIT

# Cancel either a pending restore or a desktop Steam instance previously
# launched by Prism. This is what makes a rapid stop/start avoid Steam churn.
prism_stop_unit "$PRISM_STEAM_RESTORE_UNIT" || {
  echo "ERROR: could not cancel desktop Steam restoration" >&2
  exit 1
}

# Recover owned and legacy sessions before creating any new resources.
OLD_VERSION="$(prism_state_get "$STATE" version 2>/dev/null || true)"
OLD_SESSION_MODULE="$(prism_state_get "$STATE" session_sink_module 2>/dev/null || true)"
OLD_LOOP_MODULE="$(prism_state_get "$STATE" loop_module 2>/dev/null || true)"
OLD_APP_UNIT="$(prism_state_get "$STATE" app_unit 2>/dev/null || true)"
if [ -f "$STATE" ] || prism_unit_live "$PRISM_HEADLESS_UNIT" ||
  prism_unit_has_pids "$PRISM_HEADLESS_UNIT"; then
  prism_mark_labwc_reset_required || {
    echo "ERROR: could not record required labwc reset" >&2
    exit 1
  }
fi
case "$OLD_APP_UNIT" in
  prism-headless-app-*.scope)
    prism_stop_unit "$OLD_APP_UNIT" || exit 1
    ;;
esac
prism_stop_headless_app_units || exit 1
prism_stop_unit "$PRISM_HEADLESS_UNIT" || exit 1
prism_unload_module "$OLD_LOOP_MODULE"
prism_unload_module "$OLD_SESSION_MODULE"
if { [ -f "$STATE" ] && [ "$OLD_VERSION" != "2" ]; } || prism_legacy_headless_present; then
  prism_cleanup_legacy_headless
fi
prism_unload_named_sink_modules prism-headless
rm -f "$STATE" "$ASTATE" "$ENV_FILE" "$OVERRIDE_FILE"

if prism_labwc_reset_required; then
  echo "resetting private labwc compositor before the next headless session"
  if ! timeout 20 systemctl --user restart prism-labwc.service >/dev/null 2>&1; then
    echo "ERROR: could not reset prism-labwc.service" >&2
    exit 1
  fi
else
  if ! timeout 20 systemctl --user start prism-labwc.service >/dev/null 2>&1; then
    echo "ERROR: could not start prism-labwc.service" >&2
    exit 1
  fi
fi
for _ in $(seq 1 80); do
  [ -S "$RUNTIME/$SOCKET" ] && break
  sleep 0.1
done
if [ ! -S "$RUNTIME/$SOCKET" ]; then
  echo "ERROR: private labwc socket $SOCKET is unavailable" >&2
  exit 1
fi

export WAYLAND_DISPLAY="$SOCKET"
if ! wlr-randr 2>/dev/null | grep -q '^HEADLESS-1'; then
  echo "ERROR: labwc did not expose HEADLESS-1" >&2
  exit 1
fi
for _ in $(seq 1 80); do
  systemctl --user is-active --quiet prism-input-bridge.service 2>/dev/null && break
  sleep 0.1
done
if ! systemctl --user is-active --quiet prism-input-bridge.service 2>/dev/null; then
  echo "ERROR: Prism input bridge did not reconnect to the private compositor" >&2
  exit 1
fi
if ! wlr-randr --output HEADLESS-1 --custom-mode "${W}x${H}@${FPS}" >/dev/null 2>&1; then
  echo "ERROR: could not set HEADLESS-1 to ${W}x${H}@${FPS}" >&2
  exit 1
fi
if ! prism_wait_labwc_settled HEADLESS-1; then
  echo "ERROR: private labwc output did not settle after configuration" >&2
  exit 1
fi
prism_clear_labwc_reset_required

if [ "$STEAM" = "1" ]; then
  if pgrep -x steam >/dev/null 2>&1; then
    echo "shutting down desktop Steam"
    steam -shutdown >/dev/null 2>&1 || true
    for _ in $(seq 1 60); do
      pgrep -x steam >/dev/null 2>&1 || break
      sleep 0.25
    done
  fi
  # This fallback is needed only for a Steam instance started outside Prism.
  # Once Prism restores Steam through its service, future handoffs are scoped.
  if pgrep -x steam >/dev/null 2>&1 || pgrep -x steamwebhelper >/dev/null 2>&1; then
    echo "desktop Steam survived graceful shutdown; forcing initial handoff"
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
  '' | *[!0-9]*) echo "ERROR: could not create prism-headless audio sink" >&2; exit 1 ;;
esac

if ! prism_atomic_write "$ENV_FILE" <<EOF
PRISM_SESSION_ID=$SESSION_ID
PRISM_HEADLESS_BACKEND=systemd
PRISM_HEADLESS_UNIT=$PRISM_HEADLESS_UNIT
PRISM_HEADLESS_APP_UNIT=$APP_UNIT
PRISM_CLIENT_WIDTH=$W
PRISM_CLIENT_HEIGHT=$H
PRISM_CLIENT_FPS=$FPS
PRISM_CLIENT_HDR=$HDR
PRISM_STEAM=$STEAM
PRISM_STEAM_APP_ID=${PRISM_STEAM_APP_ID:-}
PRISM_PHYSICAL_SINK=$PHYSICAL_SINK
PULSE_PROP=prism.session.id=$SESSION_ID
EOF
then
  echo "ERROR: could not publish headless session environment" >&2
  exit 1
fi

SESSION_STARTED=1
prism_start_unit "$PRISM_HEADLESS_UNIT" || {
  echo "ERROR: could not start $PRISM_HEADLESS_UNIT" >&2
  exit 1
}

GSOCKET=""
XDISP=""
for _ in $(seq 1 150); do
  if ! prism_unit_active "$PRISM_HEADLESS_UNIT"; then
    echo "ERROR: headless session service exited before becoming ready" >&2
    exit 1
  fi
  for socket_path in "$RUNTIME"/gamescope-*; do
    [ -S "$socket_path" ] || continue
    socket_name="$(basename "$socket_path")"
    case "$socket_name" in *.lock | *-ei | *limiter*) continue ;; esac
    if prism_socket_owned_by_unit "$socket_path" "$PRISM_HEADLESS_UNIT"; then
      GSOCKET="$socket_name"
    fi
    [ -n "$GSOCKET" ] && break
  done
  for socket_path in /tmp/.X11-unix/X*; do
    [ -S "$socket_path" ] || continue
    socket_name="$(basename "$socket_path")"
    if prism_socket_owned_by_unit "$socket_path" "$PRISM_HEADLESS_UNIT"; then
      XDISP=":${socket_name#X}"
    fi
    [ -n "$XDISP" ] && break
  done
  [ -n "$GSOCKET" ] && [ -n "$XDISP" ] && break
  sleep 0.1
done
if [ -z "$GSOCKET" ] || [ -z "$XDISP" ]; then
  echo "ERROR: gamescope did not publish owned Wayland and Xwayland sockets" >&2
  exit 1
fi

if [ "$STEAM" = "1" ]; then
  for _ in $(seq 1 200); do
    if ! prism_unit_active "$PRISM_HEADLESS_UNIT"; then
      echo "ERROR: headless session service exited while Steam was starting" >&2
      exit 1
    fi
    prism_unit_has_comm "$PRISM_HEADLESS_UNIT" steam && break
    sleep 0.1
  done
  if ! prism_unit_has_comm "$PRISM_HEADLESS_UNIT" steam; then
    echo "ERROR: owned Steam process did not become ready" >&2
    exit 1
  fi
fi

for _ in $(seq 1 50); do
  [ -f "$ASTATE" ] && break
  sleep 0.1
done
LOOP_MODULE="$(prism_state_get "$ASTATE" loop_module 2>/dev/null || true)"
case "$LOOP_MODULE" in
  '' | *[!0-9]*) echo "ERROR: headless audio routing did not become ready" >&2; exit 1 ;;
esac

if ! prism_atomic_write "$STATE" <<EOF
version=2
session_id=$SESSION_ID
backend=systemd
unit=$PRISM_HEADLESS_UNIT
app_unit=$APP_UNIT
steam=$STEAM
wayland_display=$GSOCKET
x_display=$XDISP
physical_sink=$PHYSICAL_SINK
capture_sink_module=$CAPTURE_SINK_MODULE
session_sink_module=$SESSION_SINK_MODULE
loop_module=$LOOP_MODULE
EOF
then
  echo "ERROR: could not publish headless session state" >&2
  exit 1
fi

if ! printf '%s\n' "$SOCKET" > "$OVERRIDE_FILE"; then
  echo "ERROR: could not publish headless capture override" >&2
  exit 1
fi
READY=1
trap - EXIT
echo "headless session ready id=$SESSION_ID socket=$GSOCKET x=$XDISP"
