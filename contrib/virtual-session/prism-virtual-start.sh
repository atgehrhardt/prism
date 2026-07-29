#!/usr/bin/env bash
# Prism: prep "do" for the "Desktop (Virtual)" app. Creates a KWin virtual
# output sized to the client, points this stream's portal capture at it, and
# disables the physical primary output for the duration of the stream.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
VPORT=5999
LOG="$HOME/.local/state/prism-virtual.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-virtual-common.sh
. "$SCRIPT_DIR/prism-virtual-common.sh"
OVERRIDE_FILE="$PRISM_VIRTUAL_OVERRIDE_FILE"
STATE="$PRISM_VIRTUAL_STATE"
ASTATE="$PRISM_VIRTUAL_AUDIO_STATE"
VNAME="$PRISM_VIRTUAL_NAME"
VOUT="$PRISM_VIRTUAL_OUTPUT"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== virtual-desktop start $(date -Is) client=${PRISM_CLIENT_WIDTH:-?}x${PRISM_CLIENT_HEIGHT:-?}@${PRISM_CLIENT_FPS:-?} ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

VIRTUAL_READY_TIMEOUT="${PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS:-10}"
case "$VIRTUAL_READY_TIMEOUT" in
  '' | *[!0-9]* | 0)
    echo "ERROR: invalid virtual-output readiness timeout '$VIRTUAL_READY_TIMEOUT'"
    exit 1
    ;;
esac

# Shared cross-mode capture lock (see prism-headless-start.sh).
exec 9>"$RUNTIME/prism-capture.lock"
flock -x -w 10 9 || {
  echo "ERROR: timed out waiting for capture lifecycle lock"
  exit 1
}

READY=0

## @brief Roll back a partially completed virtual-display transaction.
##
## @return The startup status that triggered the rollback.
rollback() {
  local rc=$?

  trap - EXIT INT TERM
  [ "$READY" = "1" ] && return "$rc"
  echo "virtual desktop startup failed; rolling back"
  if ! prism_virtual_cleanup; then
    echo "ERROR: virtual desktop rollback is incomplete"
  fi
  return "$rc"
}

trap rollback EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# Recover from an interrupted or overlapping virtual session before creating
# new resources. The shared cleanup retains only unresolved ownership state.
if [ -e "$STATE" ] || [ -e "$ASTATE" ] ||
  prism_virtual_monitor_present ||
  prism_virtual_audio_guard_present; then
  echo "found stale virtual desktop resources; reconciling them"
  prism_virtual_cleanup || exit 1
fi

W="${PRISM_CLIENT_WIDTH:-1920}"
H="${PRISM_CLIENT_HEIGHT:-1080}"
FPS="${PRISM_CLIENT_FPS:-60}"

# Create the virtual output sized to the client. krfb's VNC server is unused
# but requires a password/port; use a random password.
PW="$(head -c 9 /dev/urandom | base64)"
setsid krfb-virtualmonitor --name "$VNAME" \
  --desktopfile org.kde.krfb.virtualmonitor --resolution "${W}x${H}" \
  --password "$PW" --port "$VPORT" >>"$LOG" 2>&1 9>&- &
VIRTUAL_PID=$!

# Wait for the output under a single wall-clock deadline. Each KScreen probe
# gets at most one second, so a wedged KWin cannot multiply the total timeout.
OUT_FOUND=""
KSCREEN_FAILURES=0
READY_DEADLINE=$((SECONDS + VIRTUAL_READY_TIMEOUT))
while [ "$SECONDS" -lt "$READY_DEADLINE" ]; do
  if OUTPUTS="$(prism_virtual_output_snapshot 1)"; then
    if printf '%s\n' "$OUTPUTS" |
      awk -v target="$VOUT" '$1 == "Output:" && $3 == target {found=1} END {exit found ? 0 : 1}'; then
      OUT_FOUND=1
      break
    fi
  else
    KSCREEN_FAILURES=$((KSCREEN_FAILURES + 1))
  fi
  if ! kill -0 "$VIRTUAL_PID" >/dev/null 2>&1; then
    echo "ERROR: krfb-virtualmonitor exited before publishing $VOUT"
    exit 1
  fi
  sleep 0.25
done
if [ -z "$OUT_FOUND" ]; then
  if ! kill -0 "$VIRTUAL_PID" >/dev/null 2>&1; then
    echo "ERROR: krfb-virtualmonitor exited before publishing $VOUT"
  elif [ "$KSCREEN_FAILURES" -gt 0 ]; then
    echo "ERROR: KScreen failed $KSCREEN_FAILURES time(s); $VOUT was not observable within ${VIRTUAL_READY_TIMEOUT}s"
  else
    echo "ERROR: krfb-virtualmonitor remained active but $VOUT did not appear within ${VIRTUAL_READY_TIMEOUT}s"
  fi
  exit 1
fi

# Confirm the monitor did not exit immediately after publishing its output.
if ! kill -0 "$VIRTUAL_PID" >/dev/null 2>&1; then
  echo "ERROR: krfb-virtualmonitor exited after publishing $VOUT"
  exit 1
fi

# Switch the virtual output to the client's refresh rate. Virtual outputs only
# advertise 60Hz, so add a custom mode first (kscreen-doctor takes mHz). The
# resulting mode may be slightly off (e.g. 119.85) but mode.WxH@FPS resolves it.
if [ "$FPS" != "60" ]; then
  echo "setting $VOUT mode to ${W}x${H}@${FPS}"
  prism_virtual_kscreen 10 "output.$VOUT.addCustomMode.$W.$H.$((FPS * 1000)).full" 2>/dev/null || true
  prism_virtual_kscreen 10 "output.$VOUT.mode.${W}x${H}@${FPS}" 2>/dev/null \
    || echo "WARN: could not switch $VOUT to ${W}x${H}@${FPS}, staying at 60Hz"
fi

# Enable VRR on the virtual output so KWin paces frames by content instead of
# a fixed vblank; the streamer captures frames as they are produced.
prism_virtual_kscreen 10 "output.$VOUT.vrrpolicy.always" 2>/dev/null \
  || echo "WARN: could not set vrrpolicy on $VOUT (needs Plasma 6)"

# HDR: mark the virtual output as HDR/WCG capable when the client asked for an
# HDR stream, so KWin accepts and passes through HDR content.
if [ "${PRISM_CLIENT_HDR:-false}" = "true" ]; then
  echo "enabling hdr/wcg on $VOUT"
  for _ in 1 2 3; do
    prism_virtual_kscreen 10 "output.$VOUT.hdr.enable" "output.$VOUT.wcg.enable" 2>/dev/null && break
    sleep 1
  done || echo "WARN: could not enable hdr on $VOUT"
fi

# Point this stream's portal capture at the virtual output.
echo "portal:$VOUT" > "$OVERRIDE_FILE"

# Audio: Prism is pointed at a dedicated "prism-stream" capture sink
# (audio_sink in prism.conf). Create it up front so it exists before
# Prism's audio init, then start the audio guard: it routes all session
# audio through a "prism-virtual" sink into the capture sink and restores the
# physical default on teardown.
if ! pactl list short sinks 2>/dev/null | grep -q '^[0-9]*[[:space:]]prism-stream[[:space:]]'; then
  pactl load-module module-null-sink sink_name=prism-stream \
    sink_properties=device.description="Prism Stream Capture" >/dev/null 2>&1 || true
fi
PHYSICAL_SINK="$(pactl get-default-sink 2>/dev/null || true)"
setsid "$SCRIPT_DIR/prism-virtual-audio.sh" "$PHYSICAL_SINK" >>"$LOG" 2>&1 9>&- &

# Disable every enabled output except the virtual one (KWin reshuffles
# priorities when the virtual output appears, so don't rely on "priority 1").
# Remember which ones we disabled so undo can re-enable exactly those.
STATE_TMP="${STATE}.tmp.$$"
if ! OUTPUTS="$(prism_virtual_output_snapshot 10)"; then
  echo "ERROR: could not inspect enabled physical outputs"
  rm -f "$STATE_TMP"
  exit 1
fi
if ! printf '%s\n' "$OUTPUTS" | awk '
  /^Output:/ {name=$3}
  /^\tenabled$/ {if (name != "") print name}
' | awk -v virtual="$VOUT" '$0 != virtual' > "$STATE_TMP"; then
  echo "ERROR: could not record enabled physical outputs"
  rm -f "$STATE_TMP"
  exit 1
fi
mv -f "$STATE_TMP" "$STATE"
while read -r OUT; do
  [ "$OUT" = "$VOUT" ] && continue
  echo "disabling physical output $OUT"
  if ! prism_virtual_kscreen 10 "output.$OUT.disable" >/dev/null 2>&1; then
    echo "ERROR: could not disable physical output $OUT; recovery state retained"
    exit 1
  fi
done < "$STATE"
if ! OUTPUTS="$(prism_virtual_output_snapshot 10)"; then
  echo "ERROR: could not verify physical-output isolation; recovery state retained"
  exit 1
fi
while read -r OUT; do
  [ -z "$OUT" ] && continue
  if printf '%s\n' "$OUTPUTS" | awk -v target="$OUT" '
    /^Output:/ {name=$3}
    /^\tenabled$/ && name == target {found=1}
    END {exit found ? 0 : 1}
  '; then
    echo "ERROR: physical output $OUT remains enabled; recovery state retained"
    exit 1
  fi
done < "$STATE"
READY=1
trap - EXIT INT TERM
echo "virtual desktop ready: $VOUT ${W}x${H}"
