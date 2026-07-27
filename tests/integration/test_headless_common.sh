#!/usr/bin/env bash
# Exercise backend-neutral headless helper behavior with synthetic proc data.
set -euo pipefail

SOURCE_DIR="${1:?source directory required}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export PRISM_PROC_ROOT="$TEST_ROOT/proc"
export PRISM_LABWC_RESET_FILE="$TEST_ROOT/prism-labwc-reset-required"
mkdir -p "$PRISM_PROC_ROOT/101" "$PRISM_PROC_ROOT/102" "$PRISM_PROC_ROOT/103"

# shellcheck source=/dev/null
. "$SOURCE_DIR/contrib/virtual-session/prism-headless-common.sh"

printf '%s\n' '0::/user.slice/user-1000.slice/user@1000.service/app.slice/prism-headless-session.service' \
  > "$PRISM_PROC_ROOT/101/cgroup"
printf '%s\n' '1:name=systemd:/user.slice/user-1000.slice/user@1000.service/app.slice/prism-headless-session.service/child' \
  > "$PRISM_PROC_ROOT/102/cgroup"
printf '%s\n' '0::/user.slice/user-1000.slice/user@1000.service/app.slice/unrelated.service' \
  > "$PRISM_PROC_ROOT/103/cgroup"

CONTROL_GROUP="/user.slice/user-1000.slice/user@1000.service/app.slice/prism-headless-session.service"
prism_pid_in_control_group 101 "$CONTROL_GROUP"
prism_pid_in_control_group 102 "$CONTROL_GROUP"
if prism_pid_in_control_group 103 "$CONTROL_GROUP"; then
  echo "unrelated cgroup was incorrectly accepted" >&2
  exit 1
fi

SOCKET_PATH="$TEST_ROOT/gamescope-7"
python3 - "$SOCKET_PATH" <<'PY' &
import socket
import sys
import time

server = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
server.bind(sys.argv[1])
server.listen(1)
connection, _ = server.accept()
connection.close()
time.sleep(0.1)
PY
SOCKET_SERVER_PID=$!
for _ in $(seq 1 50); do
  [ -S "$SOCKET_PATH" ] && break
  sleep 0.01
done
[ "$(prism_socket_peer_pid "$SOCKET_PATH")" = "$SOCKET_SERVER_PID" ]
wait "$SOCKET_SERVER_PID"

STATE="$TEST_ROOT/state"
prism_atomic_write "$STATE" <<EOF
version=2
session_id=42
backend=systemd
unit=prism-headless-session.service
app_unit=prism-headless-app-42.scope
steam=1
wayland_display=gamescope-7
x_display=:9
physical_sink=speakers
capture_sink_module=
session_sink_module=123
loop_module=456
EOF
[ "$(prism_state_get "$STATE" version)" = "2" ]
[ "$(prism_state_get "$STATE" session_id)" = "42" ]
prism_state_valid "$STATE"

prism_mark_labwc_reset_required
prism_labwc_reset_required
[ "$(cat "$PRISM_LABWC_RESET_FILE")" = "1" ]
prism_clear_labwc_reset_required
if prism_labwc_reset_required; then
  echo "labwc reset marker was not cleared" >&2
  exit 1
fi

printf '%s\n' 'session_id=43' >> "$STATE"
if prism_state_valid "$STATE"; then
  echo "duplicate state key was incorrectly accepted" >&2
  exit 1
fi

mkdir -p "$PRISM_PROC_ROOT/201" "$PRISM_PROC_ROOT/202" \
  "$PRISM_PROC_ROOT/203" "$PRISM_PROC_ROOT/204"
printf '%s\0' 'WAYLAND_DISPLAY=wayland-prism' > "$PRISM_PROC_ROOT/201/environ"
printf '%s\n' $'Name:\tgamescope' $'PPid:\t1' > "$PRISM_PROC_ROOT/201/status"
printf '%s\n' $'Name:\tsteam' $'PPid:\t201' > "$PRISM_PROC_ROOT/202/status"
printf '%s\n' $'Name:\tfossilize' $'PPid:\t202' > "$PRISM_PROC_ROOT/203/status"
printf '%s\n' $'Name:\tunrelated' $'PPid:\t1' > "$PRISM_PROC_ROOT/204/status"
# shellcheck disable=SC2317 # Called indirectly by the sourced legacy helper.
pgrep() {
  printf '%s\n' 201
}
LEGACY_PIDS=" $(prism_legacy_headless_pids | tr '\n' ' ')"
case "$LEGACY_PIDS" in *" 201 "*) ;; *) exit 1 ;; esac
case "$LEGACY_PIDS" in *" 202 "*) ;; *) exit 1 ;; esac
case "$LEGACY_PIDS" in *" 203 "*) ;; *) exit 1 ;; esac
case "$LEGACY_PIDS" in *" 204 "*) echo "unrelated legacy process was accepted" >&2; exit 1 ;; esac
unset -f pgrep

INPUT_ROOT="$TEST_ROOT/input"
mkdir -p \
  "$INPUT_ROOT/sys/devices/pci/controller-hid" \
  "$INPUT_ROOT/sys/devices/pci/controller-input" \
  "$INPUT_ROOT/sys/devices/virtual/input/prism-gamepad" \
  "$INPUT_ROOT/sys/class/hidraw/hidraw3" \
  "$INPUT_ROOT/sys/class/input/event4" \
  "$INPUT_ROOT/sys/class/input/event5" \
  "$INPUT_ROOT/dev/input"
printf '%s\n' 'HID_NAME=Host Steam Controller' \
  > "$INPUT_ROOT/sys/devices/pci/controller-hid/uevent"
printf '%s\n' 'Host Gamepad' \
  > "$INPUT_ROOT/sys/devices/pci/controller-input/name"
printf '%s\n' 'Xbox One S Controller' \
  > "$INPUT_ROOT/sys/devices/virtual/input/prism-gamepad/name"
ln -s "$INPUT_ROOT/sys/devices/pci/controller-hid" \
  "$INPUT_ROOT/sys/class/hidraw/hidraw3/device"
ln -s "$INPUT_ROOT/sys/devices/pci/controller-input" \
  "$INPUT_ROOT/sys/class/input/event4/device"
ln -s "$INPUT_ROOT/sys/devices/virtual/input/prism-gamepad" \
  "$INPUT_ROOT/sys/class/input/event5/device"
touch \
  "$INPUT_ROOT/dev/hidraw3" \
  "$INPUT_ROOT/dev/input/event4" \
  "$INPUT_ROOT/dev/input/event5"
mapfile -t CONTROLLER_NODES < <(
  PRISM_SYS_ROOT="$INPUT_ROOT/sys" \
  PRISM_DEV_ROOT="$INPUT_ROOT/dev" \
  PRISM_HEADLESS_LIST_CONTROLLERS=1 \
    "$SOURCE_DIR/contrib/virtual-session/prism-headless-steam.sh"
)
[ "${#CONTROLLER_NODES[@]}" -eq 2 ]
case " ${CONTROLLER_NODES[*]} " in *" $INPUT_ROOT/dev/hidraw3 "*) ;; *) exit 1 ;; esac
case " ${CONTROLLER_NODES[*]} " in *" $INPUT_ROOT/dev/input/event4 "*) ;; *) exit 1 ;; esac
case " ${CONTROLLER_NODES[*]} " in
  *" $INPUT_ROOT/dev/input/event5 "*)
    echo "Prism virtual controller was incorrectly classified as a host controller" >&2
    exit 1
    ;;
esac

for script in \
  prism-headless-common.sh \
  prism-headless-exec.sh \
  prism-headless-session.sh \
  prism-headless-steam.sh \
  prism-headless-start.sh \
  prism-headless-stop.sh \
  prism-headless-audio.sh \
  prism-steam-game.sh \
  prism-steam-restore.sh; do
  bash -n "$SOURCE_DIR/contrib/virtual-session/$script"
done
