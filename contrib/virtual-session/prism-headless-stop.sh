#!/usr/bin/env bash
# Tear down Prism's owned labwc headless session.
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
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"

mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== headless-stop $(date -Is) ==="
export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

prism_headless_require_backend || exit 1
exec 9>"$RUNTIME/prism-capture.lock"
flock -x -w 10 9 || {
  echo "ERROR: timed out waiting for capture lifecycle lock" >&2
  exit 1
}

VERSION="$(prism_state_get "$STATE" version 2>/dev/null || true)"
VALID_STATE=0
CLEANUP_FAILED=0
OWNERSHIP_CLEAN=1
if prism_state_valid "$STATE"; then
  VALID_STATE=1
elif [ -f "$STATE" ] && [ "$VERSION" = "4" ]; then
  echo "WARN: malformed version-four state; stopping fixed Prism-owned units" >&2
fi

STEAM="$(prism_state_get "$STATE" steam 2>/dev/null || true)"
PHYSICAL_SINK="$(prism_state_get "$STATE" physical_sink 2>/dev/null || true)"
SESSION_SINK_MODULE="$(prism_state_get "$STATE" session_sink_module 2>/dev/null || true)"
LOOP_MODULE="$(prism_state_get "$STATE" loop_module 2>/dev/null || true)"
APP_UNIT="$(prism_state_get "$STATE" app_unit 2>/dev/null || true)"
case "$STEAM" in 0 | 1) ;; *) STEAM=0 ;; esac
if [ "$VALID_STATE" != "1" ]; then
  SESSION_SINK_MODULE=""
  LOOP_MODULE=""
  APP_UNIT=""
fi
if [ -z "$LOOP_MODULE" ]; then
  LOOP_MODULE="$(prism_state_get "$ASTATE" loop_module 2>/dev/null || true)"
fi
if [ -z "$PHYSICAL_SINK" ]; then
  PHYSICAL_SINK="$(prism_state_get "$ASTATE" physical_sink 2>/dev/null || true)"
fi

# Deactivate capture and evdev forwarding before terminating any process.
rm -f "$OVERRIDE_FILE" "$READY_FILE" "$INPUT_READY_FILE"

if [ -n "$APP_UNIT" ] && ! prism_stop_unit "$APP_UNIT"; then
  echo "ERROR: owned application scope could not be stopped" >&2
  CLEANUP_FAILED=1
  OWNERSHIP_CLEAN=0
fi
if ! prism_stop_headless_app_units; then
  echo "ERROR: one or more owned application scopes could not be stopped" >&2
  CLEANUP_FAILED=1
  OWNERSHIP_CLEAN=0
fi
if ! prism_stop_unit "$PRISM_STEAM_UNIT"; then
  echo "ERROR: owned Steam unit could not be stopped" >&2
  CLEANUP_FAILED=1
  OWNERSHIP_CLEAN=0
fi
if ! prism_stop_unit "$PRISM_INPUT_UNIT"; then
  echo "ERROR: owned input bridge could not be stopped" >&2
  CLEANUP_FAILED=1
  OWNERSHIP_CLEAN=0
fi
if ! prism_stop_unit "$PRISM_HEADLESS_UNIT"; then
  echo "ERROR: owned labwc compositor could not be stopped" >&2
  CLEANUP_FAILED=1
  OWNERSHIP_CLEAN=0
fi
if [ -f "$STATE" ] && [ "$VERSION" != "4" ]; then
  if ! prism_cleanup_legacy_headless || prism_legacy_headless_present; then
    echo "ERROR: an obsolete Prism headless process remains active" >&2
    CLEANUP_FAILED=1
    OWNERSHIP_CLEAN=0
  fi
fi

prism_unload_module "$LOOP_MODULE" || CLEANUP_FAILED=1
prism_unload_loopback_modules prism-headless.monitor prism-stream || CLEANUP_FAILED=1
prism_unload_module "$SESSION_SINK_MODULE" || CLEANUP_FAILED=1
prism_unload_named_sink_modules prism-headless || CLEANUP_FAILED=1

PREFERRED_RESTORE="$(sed -n 's/^prism_default_sink *= *//p' \
  "$HOME/.config/prism/prism.conf" 2>/dev/null | tail -1)"
RESTORE="$(prism_audio_choose_restore_sink \
  "$PREFERRED_RESTORE" "$PHYSICAL_SINK" 2>/dev/null || true)"
prism_restore_default_sink "$RESTORE" || true

if [ "$OWNERSHIP_CLEAN" = "1" ] && [ "$CLEANUP_FAILED" = "0" ]; then
  rm -f "$STATE" "$ASTATE" "$ENV_FILE" "$INPUT_ENV_FILE" \
    "$READY_FILE" "$INPUT_READY_FILE"
  if [ "$STEAM" = "1" ]; then
    prism_schedule_steam_restore
  fi
fi
if [ "$CLEANUP_FAILED" -ne 0 ]; then
  echo "ERROR: headless session teardown is incomplete" >&2
  exit 1
fi
echo "headless labwc session torn down"
