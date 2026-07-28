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

LABWC_POLLS="$TEST_ROOT/labwc-polls"
# shellcheck disable=SC2317 # Called indirectly by the sourced readiness helper.
wlr-randr() {
  printf '.\n' >> "$LABWC_POLLS"
  if [ "$(wc -l < "$LABWC_POLLS")" -le 2 ]; then
    return 1
  fi
  printf '%s\n' 'HEADLESS-1 "Headless output 1"'
}
# shellcheck disable=SC2317 # Called indirectly by the sourced readiness helper.
sleep() {
  :
}
prism_wait_labwc_settled HEADLESS-1
[ "$(wc -l < "$LABWC_POLLS")" -eq 14 ]
unset -f wlr-randr sleep

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

# The session command builder is safe to source and does not launch gamescope.
# shellcheck source=/dev/null
. "$SOURCE_DIR/contrib/virtual-session/prism-headless-session.sh"

DIRECT_FLAGS=()
DIRECT_CMD=()
DIRECT_MANGO=0
prism_build_headless_session_command \
  1 2379780 /opt/prism true 1 DIRECT_FLAGS DIRECT_CMD DIRECT_MANGO
[ "${DIRECT_CMD[0]}" = "/opt/prism/prism-headless-steam.sh" ]
[ "${DIRECT_CMD[1]}" = "steam" ]
[ "${DIRECT_CMD[2]}" = "steam://rungameid/2379780" ]
[ "${#DIRECT_CMD[@]}" -eq 3 ]
[ "$DIRECT_MANGO" = "0" ]
case " ${DIRECT_FLAGS[*]} " in
  *" --hdr-enabled "*) ;;
  *) echo "Direct Steam command omitted HDR flag" >&2; exit 1 ;;
esac
case " ${DIRECT_FLAGS[*]} ${DIRECT_CMD[*]} " in
  *" --mangoapp "* | *" -gamepadui "*)
    echo "Direct Steam command incorrectly enabled the Deck UI" >&2
    exit 1
    ;;
esac

DECK_FLAGS=()
DECK_CMD=()
DECK_MANGO=0
prism_build_headless_session_command \
  1 "" /opt/prism false 1 DECK_FLAGS DECK_CMD DECK_MANGO
case " ${DECK_FLAGS[*]} " in *" --mangoapp "*) ;; *) exit 1 ;; esac
case " ${DECK_CMD[*]} " in
  *" steam -gamepadui -steamos3 -steampal -steamdeck "*) ;;
  *) echo "Steam Headless command lost Deck UI flags" >&2; exit 1 ;;
esac
[ "$DECK_MANGO" = "1" ]

PLAIN_FLAGS=()
PLAIN_CMD=()
PLAIN_MANGO=0
prism_build_headless_session_command \
  0 "" /opt/prism false 1 PLAIN_FLAGS PLAIN_CMD PLAIN_MANGO
[ "${PLAIN_CMD[*]}" = "sleep infinity" ]
case " ${PLAIN_FLAGS[*]} " in
  *" --xwayland-count "* | *" --mangoapp "*) exit 1 ;;
esac
[ "$PLAIN_MANGO" = "0" ]
if prism_build_headless_session_command \
  1 "not-an-appid" /opt/prism false 0 PLAIN_FLAGS PLAIN_CMD PLAIN_MANGO; then
  echo "Invalid Steam app ID was accepted by the command builder" >&2
  exit 1
fi

# Source the monitor so its process matching and lifecycle can be exercised
# against synthetic process data without starting Steam.
# shellcheck source=/dev/null
. "$SOURCE_DIR/contrib/virtual-session/prism-steam-game.sh"

MONITOR_ROOT="$TEST_ROOT/steam-monitor"
export PRISM_PROC_ROOT="$MONITOR_ROOT/proc"
mkdir -p "$PRISM_PROC_ROOT/701" "$PRISM_PROC_ROOT/702"
printf '%s\0' 'reaper SteamLaunch AppId=44 Install=1 -- installer' \
  > "$PRISM_PROC_ROOT/701/cmdline"
printf '%s\0' 'reaper SteamLaunch AppId=44 -- game' \
  > "$PRISM_PROC_ROOT/702/cmdline"
prism_unit_pids() {
  local path pid
  for path in "$PRISM_PROC_ROOT"/[0-9]*/cmdline; do
    [ -r "$path" ] || continue
    pid="${path#"$PRISM_PROC_ROOT"/}"
    printf '%s\n' "${pid%/cmdline}"
  done
}
mapfile -t MATCHED_GAME_PIDS < <(
  prism_session_game_pids prism-headless-session.service \
    "SteamLaunch AppId=44 -- "
)
[ "${MATCHED_GAME_PIDS[*]}" = "702" ]
rm -f "$PRISM_PROC_ROOT/701/cmdline" "$PRISM_PROC_ROOT/702/cmdline"

mkdir -p "$MONITOR_ROOT/runtime" "$MONITOR_ROOT/home"
STEAM_CALLS="$MONITOR_ROOT/steam-calls"
MONITOR_SCENARIO=restart
MONITOR_STEP=0
touch "$MONITOR_ROOT/steam-present"
prism_state_get() {
  case "${2:?key required}" in
    session_id) printf '%s\n' "test-session" ;;
    unit) printf '%s\n' "prism-headless-session.service" ;;
    *) return 1 ;;
  esac
}
prism_unit_live() {
  [ ! -f "$MONITOR_ROOT/unit-dead" ]
}
prism_unit_has_comm() {
  [ -f "$MONITOR_ROOT/steam-present" ]
}
steam() {
  printf '%s\n' "$*" >> "$STEAM_CALLS"
}
sleep() {
  MONITOR_STEP=$((MONITOR_STEP + 1))
  if [ "$MONITOR_SCENARIO" = "death" ]; then
    touch "$MONITOR_ROOT/unit-dead"
    return 0
  fi
  case "$MONITOR_STEP" in
    1)
      rm -f "$MONITOR_ROOT/steam-present"
      ;;
    2)
      touch "$MONITOR_ROOT/steam-present"
      mkdir -p "$PRISM_PROC_ROOT/801"
      printf '%s\0' 'reaper SteamLaunch AppId=44 Install=1 -- installer' \
        > "$PRISM_PROC_ROOT/801/cmdline"
      ;;
    3)
      mkdir -p "$PRISM_PROC_ROOT/802"
      printf '%s\0' 'reaper SteamLaunch AppId=44 -- game' \
        > "$PRISM_PROC_ROOT/802/cmdline"
      ;;
    4)
      rm -f "$PRISM_PROC_ROOT/802/cmdline"
      ;;
  esac
}

# The subshell contains prism_steam_game_main's persistent log redirection.
# shellcheck disable=SC2030  # These test environment changes are intentionally local.
(
  export HOME="$MONITOR_ROOT/home"
  export XDG_RUNTIME_DIR="$MONITOR_ROOT/runtime"
  export PRISM_SESSION_ID=test-session
  prism_steam_game_main 44
)
[ "$(cat "$STEAM_CALLS")" = "-shutdown" ]
if grep -q "rungameid" "$STEAM_CALLS"; then
  echo "Steam game monitor sent a duplicate rungameid request" >&2
  exit 1
fi

rm -f "$MONITOR_ROOT/unit-dead" "$STEAM_CALLS"
rm -f "$PRISM_PROC_ROOT"/8*/cmdline
touch "$MONITOR_ROOT/steam-present"
MONITOR_SCENARIO=death
MONITOR_STEP=0
# shellcheck disable=SC2031  # Recreate the intentionally subshell-local test environment.
if (
  export HOME="$MONITOR_ROOT/home"
  export XDG_RUNTIME_DIR="$MONITOR_ROOT/runtime"
  export PRISM_SESSION_ID=test-session
  prism_steam_game_main 44
); then
  echo "Steam game monitor accepted loss of the owned session" >&2
  exit 1
fi
[ ! -e "$STEAM_CALLS" ]

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
