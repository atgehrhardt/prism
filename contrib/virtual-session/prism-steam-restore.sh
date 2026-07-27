#!/usr/bin/env bash
# Restore desktop Steam after a cancelable headless-session grace period.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless.state"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"

sleep 5
if [ -e "$OVERRIDE_FILE" ] || [ -e "$STATE" ] || prism_unit_live "$PRISM_HEADLESS_UNIT"; then
  exit 0
fi
if pgrep -x steam >/dev/null 2>&1; then
  exit 0
fi

steam -silent &
launcher_pid=$!
# Keep the service main process alive while the Steam launcher or any Steam
# process in this unit is alive. This avoids requiring systemd ExitType=cgroup.
while kill -0 "$launcher_pid" >/dev/null 2>&1 ||
  prism_unit_has_comm "$PRISM_STEAM_RESTORE_UNIT" steam; do
  sleep 2
done
wait "$launcher_pid" 2>/dev/null || true
