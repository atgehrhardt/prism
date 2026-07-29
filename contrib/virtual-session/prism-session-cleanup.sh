#!/usr/bin/env bash
# Reconcile stale resources owned by a completed or crashed Prism stream.
#
# This operation is intentionally idempotent and fail-closed. It removes only
# resources identified by Prism's reserved names, fixed systemd unit prefixes,
# or strictly parsed ownership state. If a confirmed resource remains, the
# script returns nonzero so the Prism service can retry before listening.
set -u

PRISM_SESSION_DIR="${PRISM_SESSION_DIR:-$(cd "$(dirname "$0")" && pwd)}"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$PRISM_SESSION_DIR/prism-headless-common.sh"

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
PRISM_SYS_ROOT="${PRISM_SYS_ROOT:-/sys}"
RECOVERY_LOG="${PRISM_RECOVERY_LOG:-$HOME/.local/state/prism-recovery.log}"
HEADLESS_STATE="$RUNTIME/prism-headless.state"
HEADLESS_AUDIO_STATE="$RUNTIME/prism-headless-audio.state"
HEADLESS_READY_FILE="$RUNTIME/prism-headless-session.ready"
HEADLESS_INPUT_READY_FILE="$RUNTIME/prism-headless-input.ready"
VIRTUAL_STATE="$RUNTIME/prism-virtual-desktop.state"
VIRTUAL_AUDIO_STATE="$RUNTIME/prism-virtual-audio.state"
MIRROR_AUDIO_STATE="$RUNTIME/prism-mirror-audio.state"

prism_cleanup_log_init() {
  mkdir -p "$(dirname "$RECOVERY_LOG")"
  exec > >(tee -a "$RECOVERY_LOG") 2>&1
  echo "=== session cleanup $(date -Is) ==="
}

prism_capture_loopbacks_present() {
  pactl list short modules 2>/dev/null |
    awk '
      $2 == "module-loopback" {
        for (i = 3; i <= NF; ++i) {
          if ($i == "sink=prism-stream") found=1
        }
      }
      END {exit found ? 0 : 1}
    '
}

prism_named_sink_present() {
  local sink="${1:?sink required}"

  pactl list short sinks 2>/dev/null |
    awk -v wanted="$sink" '$2 == wanted {found=1} END {exit found ? 0 : 1}'
}

prism_virtual_monitor_present() {
  pgrep -f 'krfb-virtualmonitor --name Prism-Virtual([[:space:]]|$)' >/dev/null 2>&1
}

prism_virtual_audio_guard_present() {
  pgrep -f 'prism-virtual-audio.sh([[:space:]]|$)' >/dev/null 2>&1
}

prism_mirror_watchdog_present() {
  pgrep -f 'prism-mirror-audio.sh.*prism-mirror-watchdog([[:space:]]|$)' \
    >/dev/null 2>&1
}

prism_virtual_output_present() {
  timeout 10 kscreen-doctor -o 2>/dev/null |
    sed 's/\x1b\[[0-9;]*m//g' |
    awk '$1 == "Output:" && $3 == "Virtual-Prism-Virtual" {found=1} END {exit found ? 0 : 1}'
}

prism_headless_units_present() {
  prism_unit_live "$PRISM_HEADLESS_UNIT" || prism_unit_has_pids "$PRISM_HEADLESS_UNIT" ||
    prism_unit_live "$PRISM_INPUT_UNIT" || prism_unit_has_pids "$PRISM_INPUT_UNIT" ||
    prism_unit_live "$PRISM_STEAM_UNIT" || prism_unit_has_pids "$PRISM_STEAM_UNIT" ||
    systemctl --user list-units --all --plain --no-legend \
      'prism-headless-app-*.scope' 2>/dev/null | awk 'NF {found=1} END {exit found ? 0 : 1}'
}

prism_headless_markers_present() {
  [ -e "$HEADLESS_STATE" ] || [ -e "$HEADLESS_AUDIO_STATE" ] ||
    [ -e "$RUNTIME/prism-headless-session.env" ] ||
    [ -e "$RUNTIME/prism-headless-input.env" ] ||
    [ -e "$HEADLESS_READY_FILE" ] ||
    [ -e "$HEADLESS_INPUT_READY_FILE" ] ||
    prism_headless_units_present || prism_legacy_headless_present
}

prism_select_restore_sink() {
  local configured candidate candidate_sink newest="" newest_sink=""

  configured="$(sed -n 's/^prism_default_sink *= *//p' \
    "$HOME/.config/prism/prism.conf" 2>/dev/null | tail -1)"
  if prism_audio_sink_available "$configured"; then
    printf '%s\n' "$configured"
    return 0
  fi

  for candidate in "$HEADLESS_STATE" "$HEADLESS_AUDIO_STATE" \
    "$VIRTUAL_AUDIO_STATE" "$MIRROR_AUDIO_STATE"; do
    [ -f "$candidate" ] || continue
    if [ "$candidate" = "$HEADLESS_STATE" ] && ! prism_state_valid "$candidate"; then
      continue
    fi
    candidate_sink="$(prism_audio_state_get "$candidate" physical_sink 2>/dev/null || true)"
    prism_audio_sink_available "$candidate_sink" || continue
    if [ -z "$newest" ] || [ "$candidate" -nt "$newest" ]; then
      newest="$candidate"
      newest_sink="$candidate_sink"
    fi
  done
  if [ -n "$newest_sink" ]; then
    printf '%s\n' "$newest_sink"
    return 0
  fi
  prism_audio_choose_restore_sink "" "" 2>/dev/null || true
}

prism_cleanup_headless() {
  local result=0

  if ! prism_headless_markers_present; then
    return 0
  fi
  echo "reconciling headless session resources"
  if prism_headless_backend_available; then
    "$PRISM_SESSION_DIR/prism-headless-stop.sh" || result=1
  else
    if prism_legacy_headless_present; then
      prism_cleanup_legacy_headless || result=1
    fi
    if [ -e "$HEADLESS_STATE" ]; then
      echo "ERROR: headless ownership state exists but the systemd user manager is unavailable"
      result=1
    fi
  fi
  return "$result"
}

prism_cleanup_virtual() {
  local result=0

  if [ -e "$VIRTUAL_STATE" ] || [ -e "$VIRTUAL_AUDIO_STATE" ] ||
    prism_virtual_audio_guard_present || prism_virtual_monitor_present ||
    prism_virtual_output_present; then
    echo "reconciling virtual desktop resources"
    "$PRISM_SESSION_DIR/prism-virtual-stop.sh" || result=1
  fi
  return "$result"
}

prism_cleanup_mirror() {
  local result=0

  if ! command -v pactl >/dev/null 2>&1; then
    if [ -e "$MIRROR_AUDIO_STATE" ]; then
      echo "ERROR: mirror audio state exists but pactl is unavailable"
      return 1
    fi
    return 0
  fi
  PRISM_AUDIO_ACTION=stop "$PRISM_SESSION_DIR/prism-mirror-audio.sh" || result=1
  return "$result"
}

prism_virtual_input_present() {
  local name_path name prefix suffix
  local -a prefixes=(
    "Prism X-Box One (virtual) pad"
    "Prism Nintendo (virtual) pad"
    "Prism DualSense Edge (virtual) pad"
    "Prism PS5 (virtual) pad"
  )

  for name_path in "$PRISM_SYS_ROOT"/class/input/event*/device/name; do
    [ -r "$name_path" ] || continue
    IFS= read -r name < "$name_path" || continue
    for prefix in "${prefixes[@]}"; do
      if [ "$name" = "$prefix" ]; then
        echo "$name"
        return 0
      fi
      suffix="${name#"$prefix"}"
      [ "$suffix" = "$name" ] && continue
      case "$suffix" in
        \ \(*\))
          echo "$name"
          return 0
          ;;
      esac
    done
  done
  return 1
}

prism_wait_for_virtual_inputs() {
  local remaining="" attempts="${PRISM_INPUT_WAIT_ATTEMPTS:-20}"

  if command -v udevadm >/dev/null 2>&1; then
    udevadm settle --timeout=3 >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 "$attempts"); do
    remaining="$(prism_virtual_input_present || true)"
    [ -z "$remaining" ] && return 0
    sleep 0.1
  done
  echo "ERROR: Prism virtual input device remains: $remaining"
  return 1
}

prism_verify_cleanup() {
  local result=0

  if prism_headless_backend_available && prism_headless_units_present; then
    echo "ERROR: a Prism headless unit or app scope remains active"
    result=1
  fi
  if prism_legacy_headless_present; then
    echo "ERROR: an obsolete Prism-owned headless process tree remains active"
    result=1
  fi
  if prism_virtual_monitor_present; then
    echo "ERROR: krfb-virtualmonitor --name Prism-Virtual remains active"
    result=1
  fi
  if prism_virtual_audio_guard_present; then
    echo "ERROR: a detached Prism virtual-audio guard remains active"
    result=1
  fi
  if prism_mirror_watchdog_present; then
    echo "ERROR: a detached Prism mirror-audio watchdog remains active"
    result=1
  fi
  if prism_virtual_output_present; then
    echo "ERROR: KWin output Virtual-Prism-Virtual remains active"
    result=1
  fi
  if [ -e "$VIRTUAL_STATE" ]; then
    echo "ERROR: physical-output recovery remains incomplete: $VIRTUAL_STATE"
    result=1
  fi
  if prism_named_sink_present prism-headless || prism_named_sink_present prism-virtual; then
    echo "ERROR: a Prism session audio sink remains active"
    result=1
  fi
  if prism_capture_loopbacks_present; then
    echo "ERROR: a Prism capture loopback remains active"
    result=1
  fi
  prism_wait_for_virtual_inputs || result=1
  return "$result"
}

prism_session_cleanup_main() {
  local result=0 audio_result=0 restore_sink loop_module sink_module

  prism_cleanup_log_init
  restore_sink="$(prism_select_restore_sink)"
  rm -f "$RUNTIME/prism-capture-override"

  prism_cleanup_headless || result=1
  prism_cleanup_virtual || result=1
  prism_cleanup_mirror || result=1

  pkill -f 'prism-virtual-audio.sh' 2>/dev/null || true
  pkill -f 'prism-mirror-audio.sh.*prism-mirror-watchdog' 2>/dev/null || true

  if command -v pactl >/dev/null 2>&1; then
    for state in "$HEADLESS_AUDIO_STATE" "$VIRTUAL_AUDIO_STATE" "$MIRROR_AUDIO_STATE"; do
      loop_module="$(prism_audio_state_get "$state" loop_module 2>/dev/null || true)"
      sink_module="$(prism_audio_state_get "$state" sink_module 2>/dev/null || true)"
      prism_unload_module "$loop_module" || audio_result=1
      prism_unload_module "$sink_module" || audio_result=1
    done
    prism_unload_prism_capture_loopbacks || audio_result=1
    prism_unload_named_sink_modules prism-headless || audio_result=1
    prism_unload_named_sink_modules prism-virtual || audio_result=1
  elif [ -e "$HEADLESS_AUDIO_STATE" ] || [ -e "$VIRTUAL_AUDIO_STATE" ] ||
    [ -e "$MIRROR_AUDIO_STATE" ]; then
    echo "ERROR: Prism audio ownership state exists but pactl is unavailable"
    audio_result=1
  fi
  [ "$audio_result" -eq 0 ] || result=1

  if ! prism_headless_units_present 2>/dev/null && ! prism_legacy_headless_present; then
    rm -f "$RUNTIME/prism-headless-session.env" "$RUNTIME/prism-headless-input.env" \
      "$HEADLESS_READY_FILE" "$HEADLESS_INPUT_READY_FILE" \
      "$RUNTIME/prism-labwc-reset-required"
    if [ "$audio_result" -eq 0 ]; then
      rm -f "$HEADLESS_STATE"
    fi
  fi
  if [ "$audio_result" -eq 0 ]; then
    rm -f "$HEADLESS_AUDIO_STATE" "$VIRTUAL_AUDIO_STATE" "$MIRROR_AUDIO_STATE"
  fi

  if [ -e "$RUNTIME/prism-desktop-session.state" ]; then
    "$PRISM_SESSION_DIR/prism-desktop-session.sh" restore || result=1
  fi

  prism_restore_default_sink "$restore_sink" || true
  prism_verify_cleanup || result=1
  if [ "$result" -ne 0 ]; then
    echo "ERROR: Prism session cleanup is incomplete; startup remains blocked"
    return 1
  fi
  echo "Prism session cleanup complete"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  prism_session_cleanup_main "$@"
fi
