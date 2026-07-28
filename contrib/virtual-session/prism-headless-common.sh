#!/usr/bin/env bash
# Prism headless-session ownership helpers.
#
# This file is sourced by the headless lifecycle scripts. Keep systemd and
# cgroup details here so a future ownership backend can implement the same
# operations without changing capture, Steam, or audio routing.

PRISM_HEADLESS_UNIT="${PRISM_HEADLESS_UNIT:-prism-headless-session.service}"
PRISM_STEAM_RESTORE_UNIT="${PRISM_STEAM_RESTORE_UNIT:-prism-steam-restore.service}"
PRISM_PROC_ROOT="${PRISM_PROC_ROOT:-/proc}"
PRISM_RUNTIME_DIR="${PRISM_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}"
PRISM_LABWC_RESET_FILE="${PRISM_LABWC_RESET_FILE:-$PRISM_RUNTIME_DIR/prism-labwc-reset-required}"

prism_headless_backend_available() {
  command -v systemctl >/dev/null 2>&1 &&
    systemctl --user show-environment >/dev/null 2>&1
}

prism_headless_require_backend() {
  if ! prism_headless_backend_available; then
    echo "ERROR: headless mode requires an accessible systemd user manager" >&2
    return 1
  fi
}

prism_unit_active() {
  local unit="${1:?unit required}"
  systemctl --user is-active --quiet "$unit" 2>/dev/null
}

prism_unit_live() {
  local unit="${1:?unit required}"
  local state

  state="$(systemctl --user show "$unit" --property=ActiveState --value 2>/dev/null || true)"
  case "$state" in
    active | activating | reloading | deactivating) return 0 ;;
  esac
  return 1
}

prism_unit_control_group() {
  local unit="${1:?unit required}"
  systemctl --user show "$unit" --property=ControlGroup --value 2>/dev/null
}

prism_pid_in_control_group() {
  local pid="${1:?pid required}"
  local control_group="${2:?control group required}"
  local _hierarchy _controllers path

  [ -r "$PRISM_PROC_ROOT/$pid/cgroup" ] || return 1
  while IFS=: read -r _hierarchy _controllers path; do
    case "$path" in
      "$control_group" | "$control_group"/*) return 0 ;;
    esac
  done < "$PRISM_PROC_ROOT/$pid/cgroup"
  return 1
}

prism_pid_in_unit() {
  local pid="${1:?pid required}"
  local unit="${2:?unit required}"
  local control_group

  control_group="$(prism_unit_control_group "$unit")"
  [ -n "$control_group" ] || return 1
  prism_pid_in_control_group "$pid" "$control_group"
}

prism_socket_peer_pid() {
  local socket_path="${1:?socket path required}"

  python3 - "$socket_path" <<'PY'
import socket
import struct
import sys

client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
client.settimeout(0.5)
client.connect(sys.argv[1])
credentials = client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
print(struct.unpack("3i", credentials)[0])
PY
}

prism_socket_owned_by_unit() {
  local socket_path="${1:?socket path required}"
  local unit="${2:?unit required}"
  local pid

  pid="$(prism_socket_peer_pid "$socket_path" 2>/dev/null || true)"
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  prism_pid_in_unit "$pid" "$unit"
}

prism_unit_pids() {
  local unit="${1:?unit required}"
  local control_group pid_path pid

  control_group="$(prism_unit_control_group "$unit")"
  [ -n "$control_group" ] || return 0
  for pid_path in "$PRISM_PROC_ROOT"/[0-9]*/cgroup; do
    [ -r "$pid_path" ] || continue
    pid="${pid_path#"$PRISM_PROC_ROOT"/}"
    pid="${pid%/cgroup}"
    prism_pid_in_control_group "$pid" "$control_group" && printf '%s\n' "$pid"
  done
}

prism_unit_has_comm() {
  local unit="${1:?unit required}"
  local wanted="${2:?process name required}"
  local pid comm

  while read -r pid; do
    [ -r "$PRISM_PROC_ROOT/$pid/comm" ] || continue
    IFS= read -r comm < "$PRISM_PROC_ROOT/$pid/comm" || continue
    [ "$comm" = "$wanted" ] && return 0
  done < <(prism_unit_pids "$unit")
  return 1
}

prism_unit_has_pids() {
  local unit="${1:?unit required}"

  [ -n "$(prism_unit_pids "$unit" | head -1)" ]
}

prism_start_unit() {
  local unit="${1:?unit required}"
  timeout 20 systemctl --user start "$unit" >/dev/null 2>&1
}

prism_mark_labwc_reset_required() {
  printf '%s\n' "1" | prism_atomic_write "$PRISM_LABWC_RESET_FILE"
}

prism_labwc_reset_required() {
  [ -f "$PRISM_LABWC_RESET_FILE" ]
}

prism_clear_labwc_reset_required() {
  rm -f "$PRISM_LABWC_RESET_FILE"
}

# Wait for labwc's headless output to remain observable long enough for nested
# compositors to attach reliably after a service restart.
prism_wait_labwc_settled() {
  local output_name="${1:-HEADLESS-1}"
  local consecutive=0

  for _ in $(seq 1 60); do
    if wlr-randr 2>/dev/null | grep -q "^${output_name}"; then
      consecutive=$((consecutive + 1))
      if [ "$consecutive" -ge 12 ]; then
        return 0
      fi
    else
      consecutive=0
    fi
    sleep 0.25
  done

  return 1
}

prism_run_owned_app() {
  local unit="${1:?app unit required}"
  local command_line="${2:?app command required}"

  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
  systemd-run --user --scope --quiet --same-dir --unit="$unit" \
    --property=KillMode=control-group /bin/sh -c "$command_line"
}

prism_stop_unit() {
  local unit="${1:?unit required}"

  if ! prism_unit_live "$unit" && ! prism_unit_has_pids "$unit"; then
    systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
    return 0
  fi
  timeout 25 systemctl --user stop "$unit" >/dev/null 2>&1 || true
  for _ in $(seq 1 50); do
    if ! prism_unit_live "$unit" && ! prism_unit_has_pids "$unit"; then
      break
    fi
    sleep 0.1
  done
  if prism_unit_live "$unit" || prism_unit_has_pids "$unit"; then
    echo "WARN: $unit did not stop gracefully; killing its control group" >&2
    systemctl --user kill --kill-whom=all --signal=KILL "$unit" >/dev/null 2>&1 || true
    for _ in $(seq 1 50); do
      if ! prism_unit_live "$unit" && ! prism_unit_has_pids "$unit"; then
        break
      fi
      sleep 0.1
    done
  fi
  if prism_unit_live "$unit" || prism_unit_has_pids "$unit"; then
    echo "ERROR: $unit still owns processes after forced teardown" >&2
    return 1
  fi
  systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
}

prism_stop_headless_app_units() {
  local unit result=0

  while read -r unit; do
    [ -z "$unit" ] && continue
    prism_stop_unit "$unit" || result=1
  done < <(
    systemctl --user list-units --all --plain --no-legend \
      'prism-headless-app-*.scope' 2>/dev/null | awk '{print $1}'
  )
  return "$result"
}

prism_state_get() {
  local file="${1:?state file required}"
  local key="${2:?state key required}"

  [ -r "$file" ] || return 1
  awk -F= -v wanted="$key" '$1 == wanted { sub(/^[^=]*=/, ""); print; exit }' "$file"
}

prism_state_valid() {
  local file="${1:?state file required}"
  local version session_id backend unit app_unit steam wayland_display x_display
  local session_sink_module loop_module capture_sink_module

  [ -r "$file" ] || return 1
  awk '
    BEGIN {
      split("version session_id backend unit app_unit steam wayland_display x_display physical_sink capture_sink_module session_sink_module loop_module", keys)
      for (key_index in keys) required[keys[key_index]] = 1
    }
    {
      separator = index($0, "=")
      if (separator < 2) exit 1
      key = substr($0, 1, separator - 1)
      if (!(key in required) || ++seen[key] != 1) exit 1
    }
    END {
      for (key in required) {
        if (seen[key] != 1) exit 1
      }
    }
  ' "$file" || return 1

  version="$(prism_state_get "$file" version 2>/dev/null || true)"
  session_id="$(prism_state_get "$file" session_id 2>/dev/null || true)"
  backend="$(prism_state_get "$file" backend 2>/dev/null || true)"
  unit="$(prism_state_get "$file" unit 2>/dev/null || true)"
  app_unit="$(prism_state_get "$file" app_unit 2>/dev/null || true)"
  steam="$(prism_state_get "$file" steam 2>/dev/null || true)"
  wayland_display="$(prism_state_get "$file" wayland_display 2>/dev/null || true)"
  x_display="$(prism_state_get "$file" x_display 2>/dev/null || true)"
  capture_sink_module="$(prism_state_get "$file" capture_sink_module 2>/dev/null || true)"
  session_sink_module="$(prism_state_get "$file" session_sink_module 2>/dev/null || true)"
  loop_module="$(prism_state_get "$file" loop_module 2>/dev/null || true)"

  [ "$version" = "2" ] || return 1
  case "$session_id" in '' | *[!A-Za-z0-9_.-]*) return 1 ;; esac
  [ "$backend" = "systemd" ] || return 1
  [ "$unit" = "$PRISM_HEADLESS_UNIT" ] || return 1
  [ "$app_unit" = "prism-headless-app-${session_id}.scope" ] || return 1
  case "$steam" in 0 | 1) ;; *) return 1 ;; esac
  case "$wayland_display" in
    gamescope-*) case "${wayland_display#gamescope-}" in '' | *[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case "$x_display" in
    :*) case "${x_display#:}" in '' | *[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case "$capture_sink_module" in '' | *[!0-9]*) [ -z "$capture_sink_module" ] || return 1 ;; esac
  case "$session_sink_module" in '' | *[!0-9]*) return 1 ;; esac
  case "$loop_module" in '' | *[!0-9]*) return 1 ;; esac
}

prism_atomic_write() {
  local target="${1:?target required}"
  local temporary="${target}.tmp.$$"

  umask 077
  if ! cat > "$temporary"; then
    rm -f "$temporary"
    return 1
  fi
  mv -f "$temporary" "$target"
}

prism_unload_module() {
  local module="${1:-}"
  case "$module" in
    '' | *[!0-9]*) return 0 ;;
  esac
  pactl unload-module "$module" >/dev/null 2>&1 || true
}

prism_unload_named_sink_modules() {
  local sink="${1:?sink required}"
  local module

  pactl list short modules 2>/dev/null |
    awk -v name="sink_name=$sink" 'index($0, name) {print $1}' |
    while read -r module; do
      prism_unload_module "$module"
    done
}

prism_restore_default_sink() {
  local sink="${1:-}"

  [ -n "$sink" ] || return 0
  echo "restoring default sink: $sink"
  for _ in $(seq 1 20); do
    if pactl list short sinks 2>/dev/null |
      awk -v wanted="$sink" '$2 == wanted {found=1} END {exit !found}'; then
      pactl set-default-sink "$sink" >/dev/null 2>&1 || true
      [ "$(pactl get-default-sink 2>/dev/null || true)" = "$sink" ] && return 0
    fi
    sleep 0.5
  done
  echo "WARN: could not restore default sink $sink" >&2
  return 1
}

prism_schedule_steam_restore() {
  systemctl --user start "$PRISM_STEAM_RESTORE_UNIT" >/dev/null 2>&1 ||
    echo "WARN: could not schedule desktop Steam restoration" >&2
}

prism_legacy_headless_present() {
  local pid

  while read -r pid; do
    [ -r "$PRISM_PROC_ROOT/$pid/environ" ] || continue
    if tr '\0' '\n' < "$PRISM_PROC_ROOT/$pid/environ" 2>/dev/null |
      grep -q '^WAYLAND_DISPLAY=wayland-prism$'; then
      return 0
    fi
  done < <(pgrep -x gamescope 2>/dev/null || true)
  return 1
}

prism_legacy_headless_pids() {
  local owned="" changed=1 pid pid_path parent

  while read -r pid; do
    [ -r "$PRISM_PROC_ROOT/$pid/environ" ] || continue
    if tr '\0' '\n' < "$PRISM_PROC_ROOT/$pid/environ" 2>/dev/null |
      grep -q '^WAYLAND_DISPLAY=wayland-prism$'; then
      owned="$owned $pid"
    fi
  done < <(pgrep -x gamescope 2>/dev/null || true)
  [ -n "$owned" ] || return 0

  while [ "$changed" = "1" ]; do
    changed=0
    for pid_path in "$PRISM_PROC_ROOT"/[0-9]*/status; do
      [ -r "$pid_path" ] || continue
      pid="${pid_path#"$PRISM_PROC_ROOT"/}"
      pid="${pid%/status}"
      case " $owned " in *" $pid "*) continue ;; esac
      parent="$(awk '/^PPid:/ {print $2; exit}' "$pid_path" 2>/dev/null)"
      case " $owned " in
        *" $parent "*)
          owned="$owned $pid"
          changed=1
          ;;
      esac
    done
  done
  for pid in $owned; do
    printf '%s\n' "$pid"
  done
}

prism_cleanup_legacy_headless() {
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local state="$runtime/prism-headless.state"
  local version pid
  local -a legacy_pids=()

  version="$(prism_state_get "$state" version 2>/dev/null || true)"
  [ "$version" = "2" ] && return 0
  if [ ! -f "$state" ] && ! prism_legacy_headless_present; then
    return 0
  fi

  echo "recovering legacy headless session"
  # Migration targets only the gamescope process tree attached to Prism's
  # private compositor. Unrelated gamescope and Steam trees are untouched.
  mapfile -t legacy_pids < <(prism_legacy_headless_pids)
  if [ "${#legacy_pids[@]}" -gt 0 ]; then
    kill -TERM "${legacy_pids[@]}" >/dev/null 2>&1 || true
  fi
  for _ in $(seq 1 20); do
    local_alive=0
    for pid in "${legacy_pids[@]}"; do
      kill -0 "$pid" >/dev/null 2>&1 && local_alive=1
    done
    [ "$local_alive" = "0" ] && break
    sleep 0.25
  done
  for pid in "${legacy_pids[@]}"; do
    kill -KILL "$pid" >/dev/null 2>&1 || true
  done
  rm -f "$state" "$runtime/prism-headless-audio.state"
}
