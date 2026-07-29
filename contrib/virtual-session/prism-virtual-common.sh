#!/usr/bin/env bash
# Shared ownership and cleanup helpers for Prism virtual-display sessions.
#
# This file is sourced by the virtual-display lifecycle scripts. Cleanup is
# deliberately lock-free: callers acquire the cross-mode capture lock before
# invoking it, including startup rollback while the lock is already held.

PRISM_VIRTUAL_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-audio-common.sh
. "$PRISM_VIRTUAL_COMMON_DIR/prism-audio-common.sh"

PRISM_VIRTUAL_RUNTIME="${PRISM_VIRTUAL_RUNTIME:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}"
PRISM_VIRTUAL_NAME="${PRISM_VIRTUAL_NAME:-Prism-Virtual}"
PRISM_VIRTUAL_OUTPUT="${PRISM_VIRTUAL_OUTPUT:-Virtual-$PRISM_VIRTUAL_NAME}"
PRISM_VIRTUAL_OVERRIDE_FILE="${PRISM_VIRTUAL_OVERRIDE_FILE:-$PRISM_VIRTUAL_RUNTIME/prism-capture-override}"
PRISM_VIRTUAL_STATE="${PRISM_VIRTUAL_STATE:-$PRISM_VIRTUAL_RUNTIME/prism-virtual-desktop.state}"
PRISM_VIRTUAL_AUDIO_STATE="${PRISM_VIRTUAL_AUDIO_STATE:-$PRISM_VIRTUAL_RUNTIME/prism-virtual-audio.state}"

## @brief Run kscreen-doctor with a bounded execution time.
##
## @param timeout_seconds Maximum number of seconds to wait.
## @param ... Arguments passed to kscreen-doctor.
## @return The kscreen-doctor exit status, or timeout's failure status.
prism_virtual_kscreen() {
  local timeout_seconds="${1:?timeout required}"
  shift
  timeout "$timeout_seconds" kscreen-doctor "$@"
}

## @brief Capture a normalized KScreen output snapshot.
##
## @param timeout_seconds Maximum number of seconds to wait.
## @return Zero when KScreen returned a complete snapshot.
prism_virtual_output_snapshot() {
  local timeout_seconds="${1:-10}"

  (
    set -o pipefail
    prism_virtual_kscreen "$timeout_seconds" -o 2>/dev/null |
      sed 's/\x1b\[[0-9;]*m//g'
  )
}

## @brief Test whether a named KScreen output is enabled.
##
## @param output Name of the output to inspect.
## @return Zero when the output exists and is enabled.
prism_virtual_output_is_enabled() {
  local output="${1:?output required}"

  prism_virtual_output_snapshot 10 | awk -v target="$output" '
    /^Output:/ {name=$3}
    /^\tenabled$/ && name == target {found=1}
    END {exit found ? 0 : 1}
  '
}

## @brief Test whether a named KScreen output exists.
##
## @param output Name of the output to inspect.
## @param timeout_seconds Maximum number of seconds to wait for KScreen.
## @return Zero when the output exists.
prism_virtual_output_exists() {
  local output="${1:?output required}"
  local timeout_seconds="${2:-10}"

  prism_virtual_output_snapshot "$timeout_seconds" | awk -v target="$output" '
    /^Output:/ && $3 == target {found=1}
    END {exit found ? 0 : 1}
  '
}

## @brief Test whether Prism's named Krfb virtual monitor is active.
##
## @return Zero when an exact Prism virtual-monitor process is present.
prism_virtual_monitor_present() {
  pgrep -f "krfb-virtualmonitor --name ${PRISM_VIRTUAL_NAME}([[:space:]]|$)" \
    >/dev/null 2>&1
}

## @brief Test whether Prism's virtual-audio guard is active.
##
## @return Zero when the exact virtual-audio guard process is present.
prism_virtual_audio_guard_present() {
  pgrep -f 'prism-virtual-audio.sh([[:space:]]|$)' >/dev/null 2>&1
}

## @brief Restore outputs recorded as enabled before virtual capture.
##
## Disconnected outputs are removed from recovery state. Outputs that cannot
## be verified as enabled remain in the state file for a later retry.
##
## @return Zero when every connected recorded output was restored.
prism_virtual_restore_outputs() {
  local outputs verify_outputs out restore_state
  local result=0
  local -a connected_outputs=()
  local -a enable_arguments=()

  [ -f "$PRISM_VIRTUAL_STATE" ] || return 0
  restore_state="${PRISM_VIRTUAL_STATE}.restore.$$"
  : > "$restore_state"
  if ! outputs="$(prism_virtual_output_snapshot 2)"; then
    echo "ERROR: KWin output state is unavailable; retaining recovery state"
    cp "$PRISM_VIRTUAL_STATE" "$restore_state"
    result=1
  else
    while read -r out; do
      [ -z "$out" ] && continue
      if ! printf '%s\n' "$outputs" | awk -v target="$out" '
        /^Output:/ && $3 == target {found=1}
        END {exit found ? 0 : 1}
      '; then
        echo "recorded output $out is disconnected; no restoration is needed"
        continue
      fi
      echo "re-enabling physical output $out"
      connected_outputs+=("$out")
      enable_arguments+=("output.$out.enable")
    done < "$PRISM_VIRTUAL_STATE"

    if [ "${#enable_arguments[@]}" -gt 0 ]; then
      prism_virtual_kscreen 2 "${enable_arguments[@]}" >/dev/null 2>&1 || true
    fi
    verify_outputs="$(prism_virtual_output_snapshot 2 2>/dev/null || true)"
    for out in "${connected_outputs[@]}"; do
      if ! printf '%s\n' "$verify_outputs" | awk -v target="$out" '
        /^Output:/ {name=$3}
        /^\tenabled$/ && name == target {found=1}
        END {exit found ? 0 : 1}
      '; then
        echo "ERROR: physical output $out could not be verified as enabled"
        printf '%s\n' "$out" >> "$restore_state"
        result=1
      fi
    done
  fi
  if [ -s "$restore_state" ]; then
    mv -f "$restore_state" "$PRISM_VIRTUAL_STATE"
  else
    rm -f "$restore_state" "$PRISM_VIRTUAL_STATE"
  fi
  return "$result"
}

## @brief Remove Prism-owned virtual-display audio resources.
##
## @return Zero when every confirmed audio resource was removed.
prism_virtual_cleanup_audio() {
  local loop_module="" sink_module=""
  local result=0

  pkill -f 'prism-virtual-audio.sh([[:space:]]|$)' 2>/dev/null || true
  for _ in $(seq 1 8); do
    prism_virtual_audio_guard_present || break
    sleep 0.25
  done
  if prism_virtual_audio_guard_present; then
    pkill -KILL -f 'prism-virtual-audio.sh([[:space:]]|$)' 2>/dev/null || true
    sleep 0.25
    if prism_virtual_audio_guard_present; then
      echo "ERROR: Prism virtual-audio guard remains active"
      result=1
    fi
  fi
  if command -v pactl >/dev/null 2>&1; then
    loop_module="$(prism_audio_state_get "$PRISM_VIRTUAL_AUDIO_STATE" loop_module 2>/dev/null || true)"
    sink_module="$(prism_audio_state_get "$PRISM_VIRTUAL_AUDIO_STATE" sink_module 2>/dev/null || true)"
    prism_unload_module "$loop_module" || result=1
    prism_unload_loopback_modules prism-virtual.monitor prism-stream || result=1
    prism_unload_module "$sink_module" || result=1
    prism_unload_named_sink_modules prism-virtual || result=1
  elif [ -e "$PRISM_VIRTUAL_AUDIO_STATE" ]; then
    echo "ERROR: virtual audio ownership state exists but pactl is unavailable"
    result=1
  fi
  [ "$result" -ne 0 ] || rm -f "$PRISM_VIRTUAL_AUDIO_STATE"
  return "$result"
}

## @brief Stop Prism's exact virtual-monitor process and verify its output left.
##
## @return Zero when neither the process nor its KScreen output remains.
prism_virtual_stop_monitor() {
  local result=0

  pkill -f "krfb-virtualmonitor --name ${PRISM_VIRTUAL_NAME}([[:space:]]|$)" \
    2>/dev/null || true
  for _ in $(seq 1 4); do
    prism_virtual_monitor_present || break
    sleep 0.25
  done
  if prism_virtual_monitor_present; then
    pkill -KILL -f "krfb-virtualmonitor --name ${PRISM_VIRTUAL_NAME}([[:space:]]|$)" \
      2>/dev/null || true
    sleep 0.25
    if prism_virtual_monitor_present; then
      echo "ERROR: Prism virtual-monitor process remains active"
      result=1
    fi
  fi
  if prism_virtual_output_exists "$PRISM_VIRTUAL_OUTPUT" 1; then
    echo "ERROR: Prism virtual output $PRISM_VIRTUAL_OUTPUT remains active"
    result=1
  elif [ -f "$PRISM_VIRTUAL_STATE" ] &&
    ! prism_virtual_output_snapshot 1 >/dev/null; then
    echo "ERROR: KWin is unavailable while virtual-display recovery is incomplete"
    result=1
  fi
  return "$result"
}

## @brief Restore the preferred desktop sink after virtual capture.
##
## @param fallback_sink Previously recorded physical sink, if available.
## @return Always zero; an unavailable preferred sink is a warning.
prism_virtual_restore_default_sink() {
  local fallback_sink="${1:-}"
  local preferred restore

  command -v pactl >/dev/null 2>&1 || return 0
  preferred="$(sed -n 's/^prism_default_sink *= *//p' \
    "$HOME/.config/prism/prism.conf" 2>/dev/null | tail -1)"
  restore="$(prism_audio_choose_restore_sink \
    "$preferred" "$fallback_sink" 2>/dev/null || true)"
  [ -n "$restore" ] || return 0

  prism_restore_default_sink "$restore" ||
    echo "WARN: recorded default sink $restore is unavailable; keeping the current available sink"
  echo "default sink now: $(pactl get-default-sink 2>/dev/null || true)"
}

## @brief Roll back or tear down a Prism virtual-display transaction.
##
## The caller must hold the cross-mode capture lock. The routine is idempotent
## and retains ownership evidence only for resources that could not be removed.
##
## @return Zero when all confirmed Prism-owned resources were removed.
prism_virtual_cleanup() {
  local physical_sink=""
  local result=0

  physical_sink="$(prism_audio_state_get \
    "$PRISM_VIRTUAL_AUDIO_STATE" physical_sink 2>/dev/null || true)"
  rm -f "$PRISM_VIRTUAL_OVERRIDE_FILE"
  prism_virtual_cleanup_audio || result=1
  prism_virtual_restore_outputs || result=1
  prism_virtual_stop_monitor || result=1
  prism_virtual_restore_default_sink "$physical_sink" || true
  return "$result"
}
