#!/usr/bin/env bash
## @file
## @brief Restore desktop Steam once a usable desktop output returns after streaming.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"

## @brief Check that Steam's desktop X server has an output with an active mode.
## @return Zero when an output is usable, nonzero for no outputs or a failed probe.
prism_steam_desktop_ready() {
  [ -n "${DISPLAY:-}" ] || return 1
  LC_ALL=C timeout 2 xrandr --query 2>/dev/null | awk '
    $2 == "connected" {
      for (i = 3; i <= NF; i++) {
        if ($i ~ /^[0-9]+x[0-9]+[+-][0-9]+[+-][0-9]+$/) ready = 1
      }
    }
    END { exit !ready }
  '
}

## @brief Wait for the desktop, then launch and supervise the restored Steam client.
## @return Zero on cancellation or client exit; nonzero if restoration cannot be checked.
prism_steam_restore_main() {
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local launcher_pid waiting=0

  sleep 5
  # Serialize the final cancellation check and launch with headless startup.
  # The launcher must not inherit the lock, or it would block the next stream.
  exec 9>"$runtime/prism-capture.lock"
  while true; do
    flock -x 9 || return 1
    if [ -e "$runtime/prism-capture-override" ] ||
      [ -e "$runtime/prism-headless.state" ] || prism_unit_live "$PRISM_HEADLESS_UNIT"; then
      exec 9>&-
      return 0
    fi
    if pgrep -u "$(id -u)" -x steam >/dev/null 2>&1; then
      exec 9>&-
      return 0
    fi
    if ! command -v xrandr >/dev/null 2>&1; then
      echo "ERROR: desktop Steam restoration requires xrandr" >&2
      exec 9>&-
      return 1
    fi
    if prism_steam_desktop_ready; then
      echo "Desktop output ready; restoring Steam"
      steam -silent 9>&- &
      launcher_pid=$!
      exec 9>&-
      break
    fi
    flock -u 9
    if [ "$waiting" -eq 0 ]; then
      echo "Waiting for a desktop output before restoring Steam"
      waiting=1
    fi
    sleep 2
  done

  # Steam cannot initialize its UI with zero outputs and may otherwise remain
  # alive indefinitely, causing later desktop launches to target a stuck client.
  # Keep this service alive through launcher handoffs without ExitType=cgroup.
  while kill -0 "$launcher_pid" >/dev/null 2>&1 ||
    prism_unit_has_comm "$PRISM_STEAM_RESTORE_UNIT" steam; do
    sleep 2
  done
  wait "$launcher_pid" 2>/dev/null || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  prism_steam_restore_main "$@"
fi
