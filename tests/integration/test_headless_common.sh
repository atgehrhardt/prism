#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2317
# Exact source patterns must remain literal; test stubs are called indirectly.
# Exercise private-labwc headless lifecycle helpers and policy.
set -euo pipefail

SOURCE_DIR="${1:?source directory required}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export PRISM_PROC_ROOT="$TEST_ROOT/proc"
export PRISM_CGROUP_ROOT="$TEST_ROOT/cgroup"
mkdir -p \
  "$PRISM_PROC_ROOT/101/fd" \
  "$PRISM_PROC_ROOT/102/fd" \
  "$PRISM_PROC_ROOT/103/fd" \
  "$PRISM_PROC_ROOT/104/fd" \
  "$PRISM_PROC_ROOT/net"

# shellcheck source=/dev/null
. "$SOURCE_DIR/contrib/virtual-session/prism-headless-common.sh"

CONTROL_GROUP="/user.slice/user-1000.slice/user@1000.service/app.slice/prism-headless-session.service"
printf '%s\n' "0::$CONTROL_GROUP" >"$PRISM_PROC_ROOT/101/cgroup"
printf '%s\n' "0::$CONTROL_GROUP/child" >"$PRISM_PROC_ROOT/102/cgroup"
printf '%s\n' "0::/user.slice/unrelated.service" >"$PRISM_PROC_ROOT/103/cgroup"
STEAM_CONTROL_GROUP="/user.slice/user-1000.slice/user@1000.service/app.slice/prism-headless-steam.service"
printf '%s\n' "0::$STEAM_CONTROL_GROUP/child" >"$PRISM_PROC_ROOT/104/cgroup"

prism_pid_in_control_group 101 "$CONTROL_GROUP"
prism_pid_in_control_group 102 "$CONTROL_GROUP"
if prism_pid_in_control_group 103 "$CONTROL_GROUP"; then
  echo "unrelated cgroup was accepted" >&2
  exit 1
fi
prism_audio_stream_owned session session 999999 "$CONTROL_GROUP" ""
prism_audio_stream_owned session stale 101 "$CONTROL_GROUP" ""
prism_audio_stream_owned session stale 104 "$CONTROL_GROUP" "" "$STEAM_CONTROL_GROUP"
if prism_audio_stream_owned session stale 103 "$CONTROL_GROUP" ""; then
  echo "unrelated audio stream was accepted" >&2
  exit 1
fi

SOCKET_PATH="$TEST_ROOT/wayland-7"
touch "$SOCKET_PATH"
printf '%s\n' \
  'Num RefCount Protocol Flags Type St Inode Path' \
  "0000000000000000: 00000002 00000000 00010000 0001 01 4242 $SOCKET_PATH" \
  >"$PRISM_PROC_ROOT/net/unix"
ln -s 'socket:[4242]' "$PRISM_PROC_ROOT/101/fd/7"
prism_unit_control_group() {
  [ "${1:?unit required}" = "prism-headless-session.service" ] || return 1
  printf '%s\n' "$CONTROL_GROUP"
}
[ "$(prism_listening_socket_inode "$SOCKET_PATH")" = "4242" ]
prism_socket_owned_by_unit "$SOCKET_PATH" prism-headless-session.service
prism_socket_owned_by_inode_set "$SOCKET_PATH" $'1111\n4242'
if prism_socket_owned_by_inode_set "$SOCKET_PATH" "1111"; then
  echo "unowned socket was accepted" >&2
  exit 1
fi
unset -f prism_unit_control_group
# shellcheck source=/dev/null
. "$SOURCE_DIR/contrib/virtual-session/prism-headless-common.sh"

STATE="$TEST_ROOT/prism-headless.state"
prism_atomic_write "$STATE" <<EOF
version=4
session_id=42
backend=systemd
unit=prism-headless-session.service
input_unit=prism-input-bridge.service
steam_unit=prism-headless-steam.service
app_unit=prism-headless-app-42.scope
steam=1
wayland_display=wayland-7
output_name=HEADLESS-1
x_display=:9
width=2560
height=1440
framerate=120
physical_sink=speakers
capture_sink_module=
session_sink_module=123
loop_module=456
EOF
prism_state_valid "$STATE"
[ "$(prism_state_get "$STATE" version)" = "4" ]
[ "$(prism_state_get "$STATE" output_name)" = "HEADLESS-1" ]

cp "$STATE" "$STATE.valid"
printf '%s\n' 'session_id=duplicate' >>"$STATE"
if prism_state_valid "$STATE"; then
  echo "duplicate state key was accepted" >&2
  exit 1
fi
cp "$STATE.valid" "$STATE"
sed -i 's/wayland_display=wayland-7/wayland_display=gamescope-7/' "$STATE"
if prism_state_valid "$STATE"; then
  echo "obsolete compositor socket was accepted" >&2
  exit 1
fi
cp "$STATE.valid" "$STATE"
sed -i 's/output_name=HEADLESS-1/output_name=HEADLESS-2/' "$STATE"
if prism_state_valid "$STATE"; then
  echo "unowned output was accepted" >&2
  exit 1
fi
cp "$STATE.valid" "$STATE"
sed -i 's/x_display=:9/x_display=:128/' "$STATE"
if prism_state_valid "$STATE"; then
  echo "out-of-range Xwayland display was accepted" >&2
  exit 1
fi

READY_MARKER="$TEST_ROOT/prism-headless-session.ready"
printf '%s\n' stale >"$READY_MARKER"
if prism_headless_ready_marker_matches "$READY_MARKER" 42; then
  echo "stale readiness marker was accepted" >&2
  exit 1
fi
printf '%s\n' 42 >"$READY_MARKER"
prism_headless_ready_marker_matches "$READY_MARKER" 42
printf '%s\n' 42 extra >"$READY_MARKER"
if prism_headless_ready_marker_matches "$READY_MARKER" 42; then
  echo "multi-line readiness marker was accepted" >&2
  exit 1
fi

# Upgrade reconciliation identifies only the obsolete Prism-owned nested tree.
mkdir -p "$PRISM_PROC_ROOT/201" "$PRISM_PROC_ROOT/202" "$PRISM_PROC_ROOT/203"
printf '%s\0' 'WAYLAND_DISPLAY=wayland-prism' >"$PRISM_PROC_ROOT/201/environ"
printf '%s\n' $'Name:\tgamescope' $'PPid:\t1' >"$PRISM_PROC_ROOT/201/status"
printf '%s\n' $'Name:\tsteam' $'PPid:\t201' >"$PRISM_PROC_ROOT/202/status"
printf '%s\n' $'Name:\tunrelated' $'PPid:\t1' >"$PRISM_PROC_ROOT/203/status"
pgrep() {
  printf '%s\n' 201
}
LEGACY_PIDS=" $(prism_legacy_headless_pids | tr '\n' ' ')"
case "$LEGACY_PIDS" in *" 201 "*) ;; *) exit 1 ;; esac
case "$LEGACY_PIDS" in *" 202 "*) ;; *) exit 1 ;; esac
case "$LEGACY_PIDS" in
  *" 203 "*)
    echo "unrelated legacy process was accepted" >&2
    exit 1
    ;;
esac
unset -f pgrep

# Host controllers are hidden from Steam, while Prism-created devices remain
# visible and can hotplug after the client establishes its input channel.
INPUT_ROOT="$TEST_ROOT/input"
mkdir -p \
  "$INPUT_ROOT/sys/devices/pci/host-controller" \
  "$INPUT_ROOT/sys/devices/virtual/input/prism-controller" \
  "$INPUT_ROOT/sys/class/input/event4" \
  "$INPUT_ROOT/sys/class/input/event5" \
  "$INPUT_ROOT/dev/input"
printf '%s\n' 'Host Gamepad' >"$INPUT_ROOT/sys/devices/pci/host-controller/name"
printf '%s\n' 'Prism PS5 (virtual) pad' \
  >"$INPUT_ROOT/sys/devices/virtual/input/prism-controller/name"
ln -s "$INPUT_ROOT/sys/devices/pci/host-controller" \
  "$INPUT_ROOT/sys/class/input/event4/device"
ln -s "$INPUT_ROOT/sys/devices/virtual/input/prism-controller" \
  "$INPUT_ROOT/sys/class/input/event5/device"
touch "$INPUT_ROOT/dev/input/event4" "$INPUT_ROOT/dev/input/event5"
mapfile -t CONTROLLER_NODES < <(
  PRISM_SYS_ROOT="$INPUT_ROOT/sys" \
  PRISM_DEV_ROOT="$INPUT_ROOT/dev" \
  PRISM_HEADLESS_LIST_CONTROLLERS=1 \
    "$SOURCE_DIR/contrib/virtual-session/prism-headless-steam.sh"
)
[ "${CONTROLLER_NODES[*]}" = "$INPUT_ROOT/dev/input/event4" ]

# Synchronized games launch a silent background Steam client, while the
# generic Steam entry retains its full Gamepad UI.
STEAM_TEST_BIN="$TEST_ROOT/steam-bin"
STEAM_TEST_ARGS="$TEST_ROOT/steam-args"
STEAM_TEST_ENV="$TEST_ROOT/steam-env"
mkdir -p "$STEAM_TEST_BIN" "$TEST_ROOT/empty-sys" "$TEST_ROOT/empty-dev"
cat >"$STEAM_TEST_BIN/steam" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"$PRISM_TEST_STEAM_ARGS"
printf 'PULSE_SINK=%s\nPULSE_PROP=%s\n' \
  "${PULSE_SINK:-}" "${PULSE_PROP:-}" \
  >"$PRISM_TEST_STEAM_ENV"
EOF
chmod +x "$STEAM_TEST_BIN/steam"

env \
  PATH="$STEAM_TEST_BIN:$PATH" \
  PRISM_SESSION_ID=steam-test \
  PRISM_STEAM_APP_ID=2784470 \
  PRISM_SYS_ROOT="$TEST_ROOT/empty-sys" \
  PRISM_DEV_ROOT="$TEST_ROOT/empty-dev" \
  PRISM_TEST_STEAM_ARGS="$STEAM_TEST_ARGS" \
  PRISM_TEST_STEAM_ENV="$STEAM_TEST_ENV" \
  WAYLAND_DISPLAY=wayland-7 \
  DISPLAY=:9 \
  "$SOURCE_DIR/contrib/virtual-session/prism-headless-steam-session.sh"
printf '%s\n' '-silent' 'steam://rungameid/2784470' |
  cmp -s - "$STEAM_TEST_ARGS"
grep -Fxq 'PULSE_SINK=prism-headless' "$STEAM_TEST_ENV"
grep -Fxq 'PULSE_PROP=prism.session.id=steam-test' "$STEAM_TEST_ENV"

env \
  PATH="$STEAM_TEST_BIN:$PATH" \
  PRISM_SESSION_ID=steam-test \
  PRISM_SYS_ROOT="$TEST_ROOT/empty-sys" \
  PRISM_DEV_ROOT="$TEST_ROOT/empty-dev" \
  PRISM_TEST_STEAM_ARGS="$STEAM_TEST_ARGS" \
  PRISM_TEST_STEAM_ENV="$STEAM_TEST_ENV" \
  WAYLAND_DISPLAY=wayland-7 \
  DISPLAY=:9 \
  "$SOURCE_DIR/contrib/virtual-session/prism-headless-steam-session.sh"
printf '%s\n' '-gamepadui' '-steamos3' '-steampal' '-steamdeck' |
  cmp -s - "$STEAM_TEST_ARGS"

HEADLESS_START="$SOURCE_DIR/contrib/virtual-session/prism-headless-start.sh"
HEADLESS_STOP="$SOURCE_DIR/contrib/virtual-session/prism-headless-stop.sh"
HEADLESS_SESSION="$SOURCE_DIR/contrib/virtual-session/prism-headless-session.sh"
STEAM_SESSION="$SOURCE_DIR/contrib/virtual-session/prism-headless-steam-session.sh"
HEADLESS_UNIT="$SOURCE_DIR/contrib/virtual-session/prism-headless-session.service"
INPUT_UNIT="$SOURCE_DIR/contrib/virtual-session/prism-input-bridge.service"
STEAM_UNIT="$SOURCE_DIR/contrib/virtual-session/prism-headless-steam.service"

# One deadline covers the owned socket, output mode, capture protocols, and
# bridge readiness. Steam has a separate post-compositor deadline.
[ "$(grep -c '^DEADLINE_MS=' "$HEADLESS_START")" -eq 1 ]
for diagnostic in \
  'labwc exited before headless readiness' \
  'labwc did not publish an owned Wayland socket within 10s' \
  'labwc did not publish an owned Xwayland socket within 10s' \
  'labwc did not expose HEADLESS-1 within 10s' \
  'labwc did not apply ${W}x${H}@${FPS} within 10s' \
  'labwc is missing required output, DMA-BUF, screencopy, or virtual-input protocols' \
  'Prism input bridge did not become ready within 10s' \
  'Steam did not start within 10s after labwc readiness'; do
  grep -Fq "$diagnostic" "$HEADLESS_START"
done
grep -Fq 'WLR_BACKENDS=headless' "$HEADLESS_SESSION"
grep -Fq 'exec labwc --config-dir' "$HEADLESS_SESSION"
grep -Fq 'unset DISPLAY WAYLAND_DISPLAY' "$HEADLESS_SESSION"
grep -Fq 'wlr-randr --output "$OUTPUT_NAME"' "$HEADLESS_START"
grep -Fq 'wayland-info' "$HEADLESS_START"
grep -Fq 'zwlr_screencopy_manager_v1' "$HEADLESS_START"
grep -Fq 'zwp_linux_dmabuf_v1' "$HEADLESS_START"
grep -Fq 'zxdg_output_manager_v1' "$HEADLESS_START"
grep -Fq 'exec "$SCRIPT_DIR/prism-headless-steam.sh"' "$STEAM_SESSION"
grep -Fq 'steam -silent "steam://rungameid/$APP_ID"' "$STEAM_SESSION"
if grep -Eiq 'exec[[:space:]]+gamescope|--backend[[:space:]]+headless|libei|PRISM_HEADLESS_EIS' \
  "$HEADLESS_START" "$HEADLESS_SESSION" "$STEAM_SESSION" "$INPUT_UNIT"; then
  echo "active headless runtime retained gamescope or EIS behavior" >&2
  exit 1
fi
if grep -Eq 'PRISM_GAMESCOPE_ATTEMPT|automatic retry' "$HEADLESS_START"; then
  echo "headless startup retained an automatic retry" >&2
  exit 1
fi

input_ready_line="$(grep -n 'prism_headless_ready_marker_matches "$INPUT_READY_FILE"' "$HEADLESS_START" |
  tail -1 | cut -d: -f1)"
state_commit_line="$(grep -n 'prism_atomic_write "$STATE"' "$HEADLESS_START" | cut -d: -f1)"
override_commit_line="$(grep -n 'prism_atomic_write "$OVERRIDE_FILE"' "$HEADLESS_START" | cut -d: -f1)"
steam_start_line="$(grep -n 'prism_start_unit "$PRISM_STEAM_UNIT"' "$HEADLESS_START" |
  tail -1 | cut -d: -f1)"
[ "$input_ready_line" -lt "$state_commit_line" ]
[ "$state_commit_line" -lt "$override_commit_line" ]
[ "$override_commit_line" -lt "$steam_start_line" ]

grep -Fq 'BindsTo=prism-headless-session.service' "$INPUT_UNIT"
grep -Fq 'PartOf=prism-headless-session.service' "$INPUT_UNIT"
grep -Fq 'BindsTo=prism-headless-session.service' "$STEAM_UNIT"
if grep -Eq 'WantedBy|prism-labwc.service' "$HEADLESS_UNIT" "$INPUT_UNIT" "$STEAM_UNIT"; then
  echo "transient labwc units retained persistent legacy relationships" >&2
  exit 1
fi

remove_override_line="$(grep -n 'rm -f "$OVERRIDE_FILE"' "$HEADLESS_STOP" | cut -d: -f1)"
stop_app_line="$(grep -n 'prism_stop_unit "$APP_UNIT"' "$HEADLESS_STOP" | cut -d: -f1)"
stop_steam_line="$(grep -n 'prism_stop_unit "$PRISM_STEAM_UNIT"' "$HEADLESS_STOP" | cut -d: -f1)"
stop_input_line="$(grep -n 'prism_stop_unit "$PRISM_INPUT_UNIT"' "$HEADLESS_STOP" | cut -d: -f1)"
stop_labwc_line="$(grep -n 'prism_stop_unit "$PRISM_HEADLESS_UNIT"' "$HEADLESS_STOP" | cut -d: -f1)"
[ "$remove_override_line" -lt "$stop_app_line" ]
[ "$stop_app_line" -lt "$stop_steam_line" ]
[ "$stop_steam_line" -lt "$stop_input_line" ]
[ "$stop_input_line" -lt "$stop_labwc_line" ]
grep -Fq 'timeout 1 systemctl --user stop' \
  "$SOURCE_DIR/contrib/virtual-session/prism-headless-common.sh"

for script in \
  prism-headless-common.sh \
  prism-headless-exec.sh \
  prism-headless-session.sh \
  prism-headless-steam.sh \
  prism-headless-steam-session.sh \
  prism-headless-start.sh \
  prism-headless-stop.sh \
  prism-headless-audio.sh \
  prism-session-cleanup.sh \
  prism-steam-game.sh \
  prism-steam-restore.sh \
  prism-virtual-common.sh; do
  bash -n "$SOURCE_DIR/contrib/virtual-session/$script"
done
