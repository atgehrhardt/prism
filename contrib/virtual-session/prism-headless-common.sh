#!/usr/bin/env bash
# Prism headless-session ownership helpers.
#
# This file is sourced by the headless lifecycle scripts. Keep systemd and
# cgroup details here so a future ownership backend can implement the same
# operations without changing capture, Steam, or audio routing.

PRISM_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-audio-common.sh
. "$PRISM_COMMON_DIR/prism-audio-common.sh"

PRISM_HEADLESS_UNIT="${PRISM_HEADLESS_UNIT:-prism-headless-session.service}"
PRISM_INPUT_UNIT="${PRISM_INPUT_UNIT:-prism-input-bridge.service}"
PRISM_STEAM_UNIT="${PRISM_STEAM_UNIT:-prism-headless-steam.service}"
PRISM_STEAM_RESTORE_UNIT="${PRISM_STEAM_RESTORE_UNIT:-prism-steam-restore.service}"
PRISM_PROC_ROOT="${PRISM_PROC_ROOT:-/proc}"
PRISM_CGROUP_ROOT="${PRISM_CGROUP_ROOT:-/sys/fs/cgroup}"
PRISM_RUNTIME_DIR="${PRISM_RUNTIME_DIR:-${XDG_RUNTIME_DIR:-/run/user/$(id -u)}}"

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

## @brief Test whether a PipeWire or PulseAudio stream belongs to the session.
##
## The exact session property is authoritative even when a sandbox reports a
## process ID from its private PID namespace. Streams without that property
## must have a valid host PID in an owned session or application cgroup.
##
## @param session_id Current Prism headless session identifier.
## @param stream_session Session property advertised by the audio stream.
## @param pid Host process identifier advertised by the audio stream.
## @param control_group Headless compositor control group.
## @param app_control_group Optional post-start application control group.
## @param steam_control_group Optional owned Steam control group.
## @return Zero when the stream is owned by the current headless session.
prism_audio_stream_owned() {
  local session_id="${1:?session ID required}"
  local stream_session="${2:-}"
  local pid="${3:-}"
  local control_group="${4:?control group required}"
  local app_control_group="${5:-}"
  local steam_control_group="${6:-}"

  if [ -n "$session_id" ] && [ "$stream_session" = "$session_id" ]; then
    return 0
  fi

  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  prism_pid_in_control_group "$pid" "$control_group" ||
    { [ -n "$app_control_group" ] &&
      prism_pid_in_control_group "$pid" "$app_control_group"; } ||
    { [ -n "$steam_control_group" ] &&
      prism_pid_in_control_group "$pid" "$steam_control_group"; }
}

## @brief Find the kernel inode for a listening Unix-domain socket.
##
## This reads procfs instead of connecting to the socket, because compositor
## sockets must not receive synthetic clients while their backends initialize.
##
## @param socket_path Filesystem path to the listening socket.
## @return The numeric socket inode, or no output when no listener exists.
prism_listening_socket_inode() {
  local socket_path="${1:?socket path required}"
  local resolved_path

  resolved_path="$(readlink -f -- "$socket_path" 2>/dev/null || true)"
  [ -n "$resolved_path" ] || return 1
  [ -r "$PRISM_PROC_ROOT/net/unix" ] || return 1
  awk -v target="$resolved_path" \
    '$4 == "00010000" && $6 == "01" && $8 == target {
      print $7
      found = 1
      exit
    }
    END { exit !found }' \
    "$PRISM_PROC_ROOT/net/unix"
}

## @brief Test whether any process in a systemd unit owns a socket inode.
##
## @param socket_inode Numeric inode from procfs.
## @param unit Owned systemd unit.
## @return Zero when a process in the unit has the socket open.
prism_unit_owns_socket_inode() {
  local socket_inode="${1:?socket inode required}"
  local unit="${2:?unit required}"

  case "$socket_inode" in *[!0-9]* | '') return 1 ;; esac
  prism_unit_socket_inodes "$unit" | grep -Fxq "$socket_inode"
}

## @brief List socket inodes held by processes in a systemd unit.
##
## @param unit Owned systemd unit.
## @return Numeric socket inodes, one per line.
prism_unit_socket_inodes() {
  local unit="${1:?unit required}"
  local pid fd fd_target

  while read -r pid; do
    for fd in "$PRISM_PROC_ROOT/$pid"/fd/*; do
      [ -L "$fd" ] || continue
      fd_target="$(readlink "$fd" 2>/dev/null || true)"
      case "$fd_target" in
        'socket:['*']')
          fd_target="${fd_target#'socket:['}"
          printf '%s\n' "${fd_target%']'}"
          ;;
      esac
    done
  done < <(prism_unit_pids "$unit")
}

## @brief Test whether a socket belongs to a precomputed inode set.
##
## @param socket_path Filesystem path to the listening socket.
## @param socket_inodes Newline-delimited socket inodes held by an owned unit.
## @return Zero only when the listener inode is present in the set.
prism_socket_owned_by_inode_set() {
  local socket_path="${1:?socket path required}"
  local socket_inodes="${2:-}"
  local socket_inode candidate

  socket_inode="$(prism_listening_socket_inode "$socket_path")" || return 1
  while IFS= read -r candidate; do
    [ "$candidate" = "$socket_inode" ] && return 0
  done <<< "$socket_inodes"
  return 1
}

## @brief Read peer credentials from a listening Unix-domain socket.
##
## The caller must first establish that the path is a current listener. The
## connection timeout bounds behavior if the listener disappears concurrently.
##
## @param socket_path Filesystem path to the listening socket.
## @return Numeric peer process ID on success.
prism_socket_peer_pid() {
  local socket_path="${1:?socket path required}"

  python3 - "$socket_path" <<'PY'
import socket
import struct
import sys

try:
    client = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    client.settimeout(0.1)
    client.connect(sys.argv[1])
    credentials = client.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
except OSError:
    sys.exit(1)
print(struct.unpack("3i", credentials)[0])
PY
}

## @brief Verify a socket peer belongs to a systemd unit.
##
## Use this only when a compositor hides its descriptors from procfs and an
## independently owned listener proves that socket startup was reached.
##
## @param socket_path Filesystem path to the listening socket.
## @param unit Owned systemd unit.
## @return Zero only when the socket peer process is in the unit cgroup.
prism_socket_peer_owned_by_unit() {
  local socket_path="${1:?socket path required}"
  local unit="${2:?unit required}"
  local peer_pid

  prism_listening_socket_inode "$socket_path" >/dev/null || return 1
  peer_pid="$(prism_socket_peer_pid "$socket_path" 2>/dev/null)" || return 1
  case "$peer_pid" in *[!0-9]* | '') return 1 ;; esac
  prism_pid_in_unit "$peer_pid" "$unit"
}

## @brief Test whether a listening socket is owned by a systemd unit.
##
## @param socket_path Filesystem path to the listening socket.
## @param unit Owned systemd unit.
## @return Zero only when the unit owns the listener.
prism_socket_owned_by_unit() {
  local socket_path="${1:?socket path required}"
  local unit="${2:?unit required}"
  local socket_inode

  socket_inode="$(prism_listening_socket_inode "$socket_path")" || return 1
  prism_unit_owns_socket_inode "$socket_inode" "$unit"
}

prism_unit_pids() {
  local unit="${1:?unit required}"
  local control_group cgroup_dir procs_file pid_path pid

  control_group="$(prism_unit_control_group "$unit")"
  [ -n "$control_group" ] || return 0
  cgroup_dir="$PRISM_CGROUP_ROOT$control_group"
  if [ -r "$cgroup_dir/cgroup.procs" ]; then
    while IFS= read -r procs_file; do
      [ -r "$procs_file" ] && cat "$procs_file"
    done < <(find "$cgroup_dir" -name cgroup.procs -type f 2>/dev/null)
    return 0
  fi

  # procfs remains the compatibility path for cgroup v1 and test fixtures.
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

## @brief Test whether a readiness marker belongs to the current session.
##
## @param marker_file Path to the runtime-owned readiness marker.
## @param session_id Expected Prism session identifier.
## @return Zero only when the marker contains the exact session identifier.
prism_headless_ready_marker_matches() {
  local marker_file="${1:?marker file required}"
  local session_id="${2:?session id required}"
  local marker=""

  [ -r "$marker_file" ] || return 1
  IFS= read -r marker < "$marker_file" || return 1
  [ "$marker" = "$session_id" ] &&
    cmp -s "$marker_file" <(printf '%s\n' "$session_id")
}

## @brief Wait for a named process inside an owned systemd unit.
##
## @param unit Owned systemd unit.
## @param process_name Exact process comm value to find.
## @return Zero when found, one on timeout, or two if the unit exits.
prism_wait_unit_comm() {
  local unit="${1:?unit required}"
  local process_name="${2:?process name required}"
  local attempts="${PRISM_TEST_HEADLESS_READY_ATTEMPTS:-100}"

  for _ in $(seq 1 "$attempts"); do
    if ! prism_unit_active "$unit"; then
      return 2
    fi
    prism_unit_has_comm "$unit" "$process_name" && return 0
    sleep 0.1
  done
  return 1
}

prism_start_unit() {
  local unit="${1:?unit required}"
  timeout 2 systemctl --user start "$unit" >/dev/null 2>&1
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
    timeout 1 systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
    return 0
  fi
  timeout 1 systemctl --user stop "$unit" >/dev/null 2>&1 || true
  for _ in $(seq 1 5); do
    if ! prism_unit_live "$unit" && ! prism_unit_has_pids "$unit"; then
      break
    fi
    sleep 0.1
  done
  if prism_unit_live "$unit" || prism_unit_has_pids "$unit"; then
    echo "WARN: $unit did not stop gracefully; killing its control group" >&2
    timeout 1 systemctl --user kill --kill-whom=all --signal=KILL "$unit" >/dev/null 2>&1 || true
    for _ in $(seq 1 5); do
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
  timeout 1 systemctl --user reset-failed "$unit" >/dev/null 2>&1 || true
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
  local version session_id backend unit input_unit steam_unit app_unit steam
  local wayland_display output_name x_display width height framerate
  local physical_sink session_sink_module loop_module capture_sink_module

  [ -r "$file" ] || return 1
  awk '
    BEGIN {
      split("version session_id backend unit input_unit steam_unit app_unit steam wayland_display output_name x_display width height framerate physical_sink capture_sink_module session_sink_module loop_module", keys)
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
  input_unit="$(prism_state_get "$file" input_unit 2>/dev/null || true)"
  steam_unit="$(prism_state_get "$file" steam_unit 2>/dev/null || true)"
  app_unit="$(prism_state_get "$file" app_unit 2>/dev/null || true)"
  steam="$(prism_state_get "$file" steam 2>/dev/null || true)"
  wayland_display="$(prism_state_get "$file" wayland_display 2>/dev/null || true)"
  output_name="$(prism_state_get "$file" output_name 2>/dev/null || true)"
  x_display="$(prism_state_get "$file" x_display 2>/dev/null || true)"
  width="$(prism_state_get "$file" width 2>/dev/null || true)"
  height="$(prism_state_get "$file" height 2>/dev/null || true)"
  framerate="$(prism_state_get "$file" framerate 2>/dev/null || true)"
  physical_sink="$(prism_state_get "$file" physical_sink 2>/dev/null || true)"
  capture_sink_module="$(prism_state_get "$file" capture_sink_module 2>/dev/null || true)"
  session_sink_module="$(prism_state_get "$file" session_sink_module 2>/dev/null || true)"
  loop_module="$(prism_state_get "$file" loop_module 2>/dev/null || true)"

  [ "$version" = "4" ] || return 1
  case "$session_id" in '' | *[!A-Za-z0-9_.-]*) return 1 ;; esac
  [ "${#session_id}" -le 128 ] || return 1
  [ "$backend" = "systemd" ] || return 1
  [ "$unit" = "$PRISM_HEADLESS_UNIT" ] || return 1
  [ "$input_unit" = "$PRISM_INPUT_UNIT" ] || return 1
  [ "$steam_unit" = "$PRISM_STEAM_UNIT" ] || return 1
  [ "$app_unit" = "prism-headless-app-${session_id}.scope" ] || return 1
  case "$steam" in 0 | 1) ;; *) return 1 ;; esac
  case "$wayland_display" in
    wayland-*) case "${wayland_display#wayland-}" in '' | *[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case "${wayland_display#wayland-}" in
    0 | [1-9] | [1-9][0-9]*) ;;
    *) return 1 ;;
  esac
  [ "${wayland_display#wayland-}" -le 127 ] || return 1
  [ "$output_name" = "HEADLESS-1" ] || return 1
  case "$x_display" in
    :*) case "${x_display#:}" in '' | *[!0-9]*) return 1 ;; esac ;;
    *) return 1 ;;
  esac
  case "${x_display#:}" in
    0 | [1-9] | [1-9][0-9]*) ;;
    *) return 1 ;;
  esac
  [ "${x_display#:}" -le 127 ] || return 1
  for dimension in "$width" "$height"; do
    case "$dimension" in '' | *[!0-9]*) return 1 ;; esac
    [ "$dimension" -gt 0 ] && [ "$dimension" -le 16384 ] || return 1
  done
  case "$framerate" in '' | *[!0-9]*) return 1 ;; esac
  [ "$framerate" -gt 0 ] && [ "$framerate" -le 1000 ] || return 1
  case "$physical_sink" in '' | *[!A-Za-z0-9_.-]*) return 1 ;; esac
  [ "${#physical_sink}" -le 255 ] || return 1
  case "$capture_sink_module" in '' | *[!0-9]*) [ -z "$capture_sink_module" ] || return 1 ;; esac
  case "$session_sink_module" in '' | *[!0-9]*) return 1 ;; esac
  case "$loop_module" in '' | *[!0-9]*) return 1 ;; esac
  for module_id in "$capture_sink_module" "$session_sink_module" "$loop_module"; do
    [ -z "$module_id" ] || [ "$module_id" -le 4294967295 ] || return 1
  done
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
  local version pid remaining=0
  local -a legacy_pids=()

  version="$(prism_state_get "$state" version 2>/dev/null || true)"
  [ "$version" = "4" ] && return 0
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
  for _ in $(seq 1 20); do
    remaining=0
    for pid in "${legacy_pids[@]}"; do
      kill -0 "$pid" >/dev/null 2>&1 && remaining=1
    done
    [ "$remaining" = "0" ] && break
    sleep 0.1
  done
  if [ "$remaining" != "0" ]; then
    echo "ERROR: a Prism-owned legacy process remains active" >&2
    return 1
  fi
}
