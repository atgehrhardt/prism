#!/usr/bin/env bash
# Launch headless Steam with host controller device nodes hidden.
#
# Prism's virtual Moonlight controllers are created under /sys/devices/virtual
# after the stream connects. Physical controllers that are already visible to
# desktop Steam can otherwise reserve XInput slot zero before Prism's virtual
# controller appears. A private mount namespace keeps those host devices out of
# headless Steam and every game it launches without changing host permissions.
set -euo pipefail

SYS_ROOT="${PRISM_SYS_ROOT:-/sys}"
DEV_ROOT="${PRISM_DEV_ROOT:-/dev}"

controller_name_matches() {
  local name="${1:-}"

  name="${name,,}"
  case "$name" in
    *controller* | *gamepad* | *"game pad"* | *joystick* | *dualshock* | \
      *dualsense* | *x-box* | *xbox*)
      return 0
      ;;
  esac
  return 1
}

sysfs_device_name() {
  local device_path="${1:?device path required}"
  local name=""

  if [ -r "$device_path/name" ]; then
    IFS= read -r name < "$device_path/name" || true
  elif [ -r "$device_path/uevent" ]; then
    name="$(sed -n 's/^HID_NAME=//p' "$device_path/uevent" | head -1)"
  fi
  printf '%s\n' "$name"
}

is_virtual_input_device() {
  local class_path="${1:?class path required}"
  local device_path

  device_path="$(readlink -f "$class_path/device" 2>/dev/null || true)"
  case "$device_path" in
    "$SYS_ROOT"/devices/virtual | "$SYS_ROOT"/devices/virtual/*) return 0 ;;
  esac
  return 1
}

udev_marks_controller() {
  local node="${1:?device node required}"

  [ "$DEV_ROOT" = "/dev" ] || return 1
  command -v udevadm >/dev/null 2>&1 || return 1
  udevadm info --query=property --name="$node" 2>/dev/null |
    grep -Eq '^ID_INPUT_(JOYSTICK|GAMEPAD)=1$'
}

headless_host_controller_nodes() {
  local class_path device_path name node

  for class_path in "$SYS_ROOT"/class/hidraw/hidraw*; do
    [ -e "$class_path" ] || continue
    is_virtual_input_device "$class_path" && continue
    device_path="$(readlink -f "$class_path/device" 2>/dev/null || true)"
    name="$(sysfs_device_name "$device_path")"
    controller_name_matches "$name" || continue
    node="$DEV_ROOT/${class_path##*/}"
    [ -e "$node" ] && printf '%s\n' "$node"
  done

  for class_path in "$SYS_ROOT"/class/input/event* "$SYS_ROOT"/class/input/js*; do
    [ -e "$class_path" ] || continue
    is_virtual_input_device "$class_path" && continue
    device_path="$(readlink -f "$class_path/device" 2>/dev/null || true)"
    name="$(sysfs_device_name "$device_path")"
    node="$DEV_ROOT/input/${class_path##*/}"
    [ -e "$node" ] || continue
    if controller_name_matches "$name" || udev_marks_controller "$node"; then
      printf '%s\n' "$node"
    fi
  done
}

if [ "${PRISM_HEADLESS_LIST_CONTROLLERS:-0}" = "1" ]; then
  headless_host_controller_nodes
  exit 0
fi

if [ "$#" -eq 0 ]; then
  echo "ERROR: no Steam command was supplied to the headless input wrapper" >&2
  exit 2
fi

mapfile -t CONTROLLER_NODES < <(headless_host_controller_nodes | sort -u)
if [ "${#CONTROLLER_NODES[@]}" -eq 0 ]; then
  exec "$@"
fi

if ! command -v bwrap >/dev/null 2>&1; then
  echo "ERROR: bubblewrap is required to isolate host controllers from headless Steam" >&2
  exit 1
fi

BWRAP_ARGS=(--die-with-parent --bind / / --dev-bind /dev /dev)
for node in "${CONTROLLER_NODES[@]}"; do
  BWRAP_ARGS+=(--bind /dev/null "$node")
done

printf 'isolating host controller nodes from headless Steam:'
printf ' %q' "${CONTROLLER_NODES[@]}"
printf '\n'
exec bwrap "${BWRAP_ARGS[@]}" -- "$@"
