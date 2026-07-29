#!/usr/bin/env bash
# Exercise the wlroots input bridge against an isolated headless labwc.
set -euo pipefail

: "${1:?source directory required}"
BUILD_DIR="${2:?build directory required}"
BRIDGE="$BUILD_DIR/prism-input-bridge"

if [ ! -x "$BRIDGE" ]; then
  echo "ERROR: built prism-input-bridge helper is missing: $BRIDGE" >&2
  exit 1
fi
for required in labwc wayland-info; do
  if ! command -v "$required" >/dev/null 2>&1; then
    echo "SKIP: $required is unavailable"
    exit 0
  fi
done

TEST_ROOT="$(mktemp -d)"
RUNTIME="$TEST_ROOT/runtime"
CONFIG_HOME="$TEST_ROOT/config"
READY_FILE="$RUNTIME/prism-headless-input.ready"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
LABWC_LOG="$TEST_ROOT/labwc.log"
BRIDGE_LOG="$TEST_ROOT/bridge.log"
LABWC_PID=""
BRIDGE_PID=""
mkdir -m 700 "$RUNTIME"
mkdir -p "$CONFIG_HOME/labwc"

cleanup() {
  [ -z "$BRIDGE_PID" ] || kill -TERM "$BRIDGE_PID" >/dev/null 2>&1 || true
  [ -z "$LABWC_PID" ] || kill -TERM "$LABWC_PID" >/dev/null 2>&1 || true
  [ -z "$BRIDGE_PID" ] || wait "$BRIDGE_PID" 2>/dev/null || true
  [ -z "$LABWC_PID" ] || wait "$LABWC_PID" 2>/dev/null || true
  rm -rf "$TEST_ROOT"
}
trap cleanup EXIT

start_labwc() {
  env \
    XDG_RUNTIME_DIR="$RUNTIME" \
    XDG_CONFIG_HOME="$CONFIG_HOME" \
    WLR_BACKENDS=headless \
    labwc --config-dir "$CONFIG_HOME/labwc" >>"$LABWC_LOG" 2>&1 &
  LABWC_PID=$!
  for _ in $(seq 1 100); do
    [ -S "$RUNTIME/wayland-0" ] && return 0
    kill -0 "$LABWC_PID" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

wait_for_marker() {
  for _ in $(seq 1 100); do
    [ -r "$READY_FILE" ] && [ "$(cat "$READY_FILE")" = "bridge-test" ] &&
      return 0
    kill -0 "$BRIDGE_PID" 2>/dev/null || return 1
    sleep 0.05
  done
  return 1
}

start_labwc
PROTOCOLS="$(env XDG_RUNTIME_DIR="$RUNTIME" WAYLAND_DISPLAY=wayland-0 wayland-info 2>/dev/null)"
for protocol in \
  zwlr_virtual_pointer_manager_v1 \
  zwp_virtual_keyboard_manager_v1; do
  printf '%s\n' "$PROTOCOLS" | grep -q "$protocol"
done

env \
  XDG_RUNTIME_DIR="$RUNTIME" \
  PRISM_SESSION_ID=bridge-test \
  PRISM_WAYLAND_SOCKET=wayland-0 \
  PRISM_HEADLESS_INPUT_READY_FILE="$READY_FILE" \
  PRISM_CAPTURE_OVERRIDE_FILE="$OVERRIDE_FILE" \
  "$BRIDGE" >>"$BRIDGE_LOG" 2>&1 &
BRIDGE_PID=$!
wait_for_marker
[ "$(stat -c '%a' "$READY_FILE")" = "600" ]

printf '%s\n' 'wlroots:stale-session' >"$OVERRIDE_FILE"
sleep 0.15
if grep -q 'activated evdev forwarding' "$BRIDGE_LOG"; then
  echo "stale capture override activated input forwarding" >&2
  exit 1
fi
printf '%s\n' 'wlroots:bridge-test' >"$OVERRIDE_FILE"
for _ in $(seq 1 50); do
  grep -q 'activated evdev forwarding' "$BRIDGE_LOG" && break
  sleep 0.05
done
grep -q 'activated evdev forwarding' "$BRIDGE_LOG"
rm -f "$OVERRIDE_FILE"
for _ in $(seq 1 50); do
  grep -q 'deactivated evdev forwarding' "$BRIDGE_LOG" && break
  sleep 0.05
done
grep -q 'deactivated evdev forwarding' "$BRIDGE_LOG"

# A compositor disconnect retracts readiness. Recreating the exact same owned
# socket permits reconnection within this unit lifetime.
kill -TERM "$LABWC_PID"
wait "$LABWC_PID" || true
LABWC_PID=""
for _ in $(seq 1 100); do
  [ ! -e "$READY_FILE" ] && break
  sleep 0.05
done
[ ! -e "$READY_FILE" ]
start_labwc
wait_for_marker

kill -TERM "$BRIDGE_PID"
wait "$BRIDGE_PID"
BRIDGE_PID=""
[ ! -e "$READY_FILE" ]

if env \
  XDG_RUNTIME_DIR="$RUNTIME" \
  PRISM_SESSION_ID='bad/session' \
  PRISM_WAYLAND_SOCKET=wayland-0 \
  PRISM_HEADLESS_INPUT_READY_FILE="$READY_FILE" \
  PRISM_CAPTURE_OVERRIDE_FILE="$OVERRIDE_FILE" \
  "$BRIDGE" >/dev/null 2>&1; then
  echo "invalid session identifier was accepted" >&2
  exit 1
fi
if env \
  XDG_RUNTIME_DIR="$RUNTIME" \
  PRISM_SESSION_ID=bridge-test \
  PRISM_WAYLAND_SOCKET=desktop-0 \
  PRISM_HEADLESS_INPUT_READY_FILE="$READY_FILE" \
  PRISM_CAPTURE_OVERRIDE_FILE="$OVERRIDE_FILE" \
  "$BRIDGE" >/dev/null 2>&1; then
  echo "non-owned Wayland socket name was accepted" >&2
  exit 1
fi
