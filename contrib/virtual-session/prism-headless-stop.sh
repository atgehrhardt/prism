#!/usr/bin/env bash
# Tear down Prism's owned headless session. Safe after partial startup or when
# called repeatedly.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless.state"
ASTATE="$RUNTIME/prism-headless-audio.state"
ENV_FILE="$RUNTIME/prism-headless-session.env"
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
flock -x -w 90 9 || {
  echo "ERROR: timed out waiting for capture lifecycle lock" >&2
  exit 1
}

VERSION="$(prism_state_get "$STATE" version 2>/dev/null || true)"
VALID_STATE=0
HAD_SESSION=0
CLEANUP_FAILED=0
OWNERSHIP_CLEAN=1
if prism_state_valid "$STATE"; then
  VALID_STATE=1
elif [ -f "$STATE" ] && [ "$VERSION" = "2" ]; then
  echo "WARN: ignoring malformed versioned state; stopping fixed Prism-owned units only" >&2
fi
STEAM="$(prism_state_get "$STATE" steam 2>/dev/null || true)"
PHYSICAL_SINK="$(prism_state_get "$STATE" physical_sink 2>/dev/null || true)"
SESSION_SINK_MODULE="$(prism_state_get "$STATE" session_sink_module 2>/dev/null || true)"
LOOP_MODULE="$(prism_state_get "$STATE" loop_module 2>/dev/null || true)"
APP_UNIT="$(prism_state_get "$STATE" app_unit 2>/dev/null || true)"
if [ "$VALID_STATE" != "1" ]; then
  STEAM=0
  SESSION_SINK_MODULE=""
  LOOP_MODULE=""
  APP_UNIT=""
fi
if [ -f "$STATE" ] || prism_unit_live "$PRISM_HEADLESS_UNIT" ||
  prism_unit_has_pids "$PRISM_HEADLESS_UNIT"; then
  HAD_SESSION=1
fi
if [ -z "$LOOP_MODULE" ]; then
  LOOP_MODULE="$(prism_state_get "$ASTATE" loop_module 2>/dev/null || true)"
fi
if [ -z "$PHYSICAL_SINK" ]; then
  PHYSICAL_SINK="$(prism_state_get "$ASTATE" physical_sink 2>/dev/null || true)"
fi

rm -f "$OVERRIDE_FILE"

if [ -f "$STATE" ] && [ "$VERSION" != "2" ]; then
  if ! prism_cleanup_legacy_headless || prism_legacy_headless_present; then
    echo "ERROR: Prism-owned legacy gamescope processes remain active" >&2
    CLEANUP_FAILED=1
    OWNERSHIP_CLEAN=0
  fi
else
  if [ -n "$APP_UNIT" ] && ! prism_stop_unit "$APP_UNIT"; then
    echo "ERROR: preserving state because the owned app scope could not be stopped" >&2
    CLEANUP_FAILED=1
    OWNERSHIP_CLEAN=0
  fi
  if ! prism_stop_headless_app_units; then
    echo "ERROR: one or more owned app scopes could not be stopped" >&2
    CLEANUP_FAILED=1
    OWNERSHIP_CLEAN=0
  fi
  if ! prism_stop_unit "$PRISM_HEADLESS_UNIT"; then
    echo "ERROR: preserving state because the owned session could not be stopped" >&2
    CLEANUP_FAILED=1
    OWNERSHIP_CLEAN=0
  fi
fi
if [ "$HAD_SESSION" = "1" ]; then
  if ! prism_mark_labwc_reset_required; then
    echo "ERROR: could not record required labwc reset" >&2
    CLEANUP_FAILED=1
  fi
fi

prism_unload_module "$LOOP_MODULE" || CLEANUP_FAILED=1
prism_unload_loopback_modules prism-headless.monitor prism-stream || CLEANUP_FAILED=1
prism_unload_module "$SESSION_SINK_MODULE" || CLEANUP_FAILED=1
prism_unload_named_sink_modules prism-headless || CLEANUP_FAILED=1

RESTORE="$(sed -n 's/^prism_default_sink *= *//p' \
  "$HOME/.config/prism/prism.conf" 2>/dev/null | tail -1)"
RESTORE="${RESTORE:-$PHYSICAL_SINK}"
prism_restore_default_sink "$RESTORE" || true

if [ "$OWNERSHIP_CLEAN" = "1" ] && [ "$CLEANUP_FAILED" = "0" ]; then
  rm -f "$STATE" "$ASTATE" "$ENV_FILE"
  if [ "$STEAM" = "1" ]; then
    prism_schedule_steam_restore
  fi
fi
if [ "$CLEANUP_FAILED" -ne 0 ]; then
  echo "ERROR: headless session teardown is incomplete" >&2
  exit 1
fi
echo "headless session torn down"
