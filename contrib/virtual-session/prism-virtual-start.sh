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

# kscreen-doctor can hang indefinitely when KWin is in a degenerate state
# (e.g. all outputs disabled by a previous session that was never torn down);
# never let a single call block the launch forever.
KSD="timeout 10 kscreen-doctor"

exec 9>"$RUNTIME/prism-virtual.lock"
flock -x -w 90 9 || exit 1

# Recover from a previous session that was never torn down (e.g. sunshine was
# killed mid-stream): re-enable any physical outputs it disabled, otherwise
# KWin sits in a zero-output state where kscreen-doctor hangs.
if [ -f "$STATE" ]; then
  echo "found stale state file; re-enabling outputs from previous session"
  while read -r OUT; do
    [ -z "$OUT" ] && continue
    $KSD "output.$OUT.enable" 2>/dev/null || true
  done < "$STATE"
  rm -f "$STATE"
fi

W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"

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
  if $KSD -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | grep -q "Output:.* $VOUT "; then
    OUT_FOUND=1
    break
  fi
  sleep 0.25
done
if [ -z "$OUT_FOUND" ]; then
  echo "ERROR: virtual output $VOUT did not appear"
  exit 1
fi

# Switch the virtual output to the client's refresh rate. Virtual outputs only
# advertise 60Hz, so add a custom mode first (kscreen-doctor takes mHz). The
# resulting mode may be slightly off (e.g. 119.85) but mode.WxH@FPS resolves it.
if [ "$FPS" != "60" ]; then
  echo "setting $VOUT mode to ${W}x${H}@${FPS}"
  $KSD "output.$VOUT.addCustomMode.$W.$H.$((FPS * 1000)).full" 2>/dev/null || true
  $KSD "output.$VOUT.mode.${W}x${H}@${FPS}" 2>/dev/null \
    || echo "WARN: could not switch $VOUT to ${W}x${H}@${FPS}, staying at 60Hz"
fi

# Enable VRR on the virtual output so KWin paces frames by content instead of
# a fixed vblank; the streamer captures frames as they are produced.
$KSD "output.$VOUT.vrrpolicy.always" 2>/dev/null \
  || echo "WARN: could not set vrrpolicy on $VOUT (needs Plasma 6)"

# HDR: mark the virtual output as HDR/WCG capable when the client asked for an
# HDR stream, so KWin accepts and passes through HDR content.
if [ "${SUNSHINE_CLIENT_ENABLE_HDR:-false}" = "true" ]; then
  echo "enabling hdr/wcg on $VOUT"
  for _ in 1 2 3; do
    $KSD "output.$VOUT.hdr.enable" "output.$VOUT.wcg.enable" 2>/dev/null && break
    sleep 1
  done || echo "WARN: could not enable hdr on $VOUT"
fi

# Point this stream's portal capture at the virtual output.
echo "portal:$VOUT" > "$OVERRIDE_FILE"

# Audio: Sunshine is pointed at a dedicated "prism-stream" capture sink
# (audio_sink in sunshine.conf). Create it up front so it exists before
# Sunshine's audio init, then start the audio guard: it routes all session
# audio through a "prism-virtual" sink into the capture sink and restores the
# physical default on teardown.
if ! pactl list short sinks 2>/dev/null | grep -q '^[0-9]*[[:space:]]prism-stream[[:space:]]'; then
  pactl load-module module-null-sink sink_name=prism-stream \
    sink_properties=device.description="Prism Stream Capture" >/dev/null 2>&1 || true
fi
PHYSICAL_SINK="$(pactl get-default-sink 2>/dev/null || true)"
setsid "$(dirname "$0")/prism-virtual-audio.sh" "$PHYSICAL_SINK" >>"$LOG" 2>&1 9>&- &

# Disable every enabled output except the virtual one (KWin reshuffles
# priorities when the virtual output appears, so don't rely on "priority 1").
# Remember which ones we disabled so undo can re-enable exactly those.
: > "$STATE"
$KSD -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '
  /^Output:/ {name=$3}
  /^\tenabled$/ {if (name != "") print name}
' | while read -r OUT; do
  [ "$OUT" = "$VOUT" ] && continue
  echo "$OUT" >> "$STATE"
  echo "disabling physical output $OUT"
  $KSD "output.$OUT.disable" 2>/dev/null || true
done
echo "virtual desktop ready: $VOUT ${W}x${H}"
