#!/usr/bin/env bash
# Prism: prep "do" for the "Desktop (Virtual)" app. Creates a KWin virtual
# output sized to the client, points this stream's portal capture at it, and
# disables the physical primary output for the duration of the stream.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-virtual-desktop.state"
VNAME="Prism-Virtual"
VOUT="Virtual-$VNAME"
VPORT=5999
LOG="$HOME/.local/state/prism-virtual.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== virtual-desktop start $(date -Is) client=${SUNSHINE_CLIENT_WIDTH:-?}x${SUNSHINE_CLIENT_HEIGHT:-?}@${SUNSHINE_CLIENT_FPS:-?} ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

exec 9>"$RUNTIME/prism-virtual.lock"
flock -x -w 90 9 || exit 1

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"

# Clean up any previous virtual output.
pkill -f "krfb-virtualmonitor --name $VNAME" 2>/dev/null || true
sleep 1

# Create the virtual output sized to the client. krfb's VNC server is unused
# but requires a password/port; use a random password.
PW="$(head -c 9 /dev/urandom | base64)"
setsid krfb-virtualmonitor --name "$VNAME" --resolution "${W}x${H}" \
  --password "$PW" --port "$VPORT" >>"$LOG" 2>&1 9>&- &

# Wait for the output to appear.
OUT_FOUND=""
for _ in $(seq 1 40); do
  if kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Output:.* $VOUT "; then
    OUT_FOUND=1
    break
  fi
  sleep 0.25
done
if [ -z "$OUT_FOUND" ]; then
  echo "ERROR: virtual output $VOUT did not appear"
  exit 1
fi

# Point this stream's portal capture at the virtual output.
echo "portal:$VOUT" > "$OVERRIDE_FILE"

# Disable every enabled output except the virtual one (KWin reshuffles
# priorities when the virtual output appears, so don't rely on "priority 1").
# Remember which ones we disabled so undo can re-enable exactly those.
: > "$STATE"
kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
  /^Output:/ {name=$3}
  /^\tenabled$/ {if (name != "") print name}
' | while read -r OUT; do
  [ "$OUT" = "$VOUT" ] && continue
  echo "$OUT" >> "$STATE"
  echo "disabling physical output $OUT"
  kscreen-doctor "output.$OUT.disable" 2>/dev/null || true
done
echo "virtual desktop ready: $VOUT ${W}x${H}"
