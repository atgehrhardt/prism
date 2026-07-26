#!/usr/bin/env bash
# Prism: bring up the headless gamescope session for an app with capture mode
# "headless" (or "steamos"). Generic: works for any app. Steam-specific
# behavior (quit desktop Steam, launch Big Picture, restore on exit) only
# happens when PRISM_STEAM=1 is set in the environment.
#
# Env in:  PRISM_STEAM=0|1 (default 0)
#          SUNSHINE_CLIENT_WIDTH / HEIGHT / FPS / ENABLE_HDR (set by Sunshine)
# State out: $XDG_RUNTIME_DIR/prism-headless.state  (KEY=VALUE lines:
#          steam, wayland_display, x_display)
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
OVERRIDE_FILE="$RUNTIME/prism-capture-override"
STATE="$RUNTIME/prism-headless.state"
SOCKET="wayland-prism"
LOG="$HOME/.local/state/prism-headless.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== headless-start $(date -Is) steam=${PRISM_STEAM:-0} client=${SUNSHINE_CLIENT_WIDTH:-?}x${SUNSHINE_CLIENT_HEIGHT:-?}@${SUNSHINE_CLIENT_FPS:-?} ==="

export DBUS_SESSION_BUS_ADDRESS="unix:path=$RUNTIME/bus"

# Serialize with prism-headless-stop.sh.
exec 9>"$RUNTIME/prism-headless.lock"
flock -x 9

# 0. Recover from a previous session that was never torn down (e.g. sunshine
# crashed): a leftover gamescope would fight the new one for the session.
if [ -f "$STATE" ]; then
  echo "found stale state file; tearing down previous headless session"
  pkill -x gamescope 2>/dev/null || true
  pkill -x gamescopereaper 2>/dev/null || true
  for _ in $(seq 1 20); do
    pgrep -x gamescope >/dev/null || break
    sleep 0.5
  done
  pkill -9 -x gamescope 2>/dev/null || true
  pkill -9 -x gamescopereaper 2>/dev/null || true
  rm -f "$STATE"
fi

# 1. Steam handling (only when requested): quit desktop Steam if running.
if [ "${PRISM_STEAM:-0}" = "1" ]; then
  if pgrep -x steam >/dev/null; then
    steam -shutdown 2>/dev/null || true
    for _ in $(seq 1 30); do
      pgrep -x steam >/dev/null || break
      sleep 0.5
    done
  else
    echo "desktop steam not running, skipping shutdown"
  fi
  # steamwebhelper regularly outlives `steam -shutdown`. A stale helper keeps
  # the Steam single-instance lock and the fossilize shader-cache state, which
  # both prevents the desktop Steam from relaunching later and hangs every
  # game after the first at "Processing Vulkan shaders" in the new session.
  if pgrep -x steamwebhelper >/dev/null; then
    echo "killing stale steamwebhelper left behind by desktop steam"
    pkill -x steamwebhelper 2>/dev/null || true
    for _ in $(seq 1 20); do
      pgrep -x steamwebhelper >/dev/null || break
      sleep 0.5
    done
    pkill -9 -x steamwebhelper 2>/dev/null || true
  fi
  # The session Steam must not start until the desktop instance is COMPLETELY
  # gone (main process and helpers): starting earlier makes it forward to the
  # dying desktop instance instead of becoming the session instance, and
  # launch URLs then open games on the desktop.
  for _ in $(seq 1 40); do
    pgrep -x steam >/dev/null && sleep 0.5 && continue
    pgrep -x steamwebhelper >/dev/null && sleep 0.5 && continue
    break
  done
  pgrep -x steam >/dev/null && echo "WARNING: desktop steam still running; session launch may misroute"
fi

# 2. Arm the capture override so this stream captures the headless session.
echo "$SOCKET" > "$OVERRIDE_FILE"

# 2b. Make sure the headless compositor service is actually running (it can be
# stopped manually or after a crash; the stream fails without it).
if [ ! -S "$RUNTIME/$SOCKET" ]; then
  echo "socket $SOCKET missing; starting prism-labwc.service"
  systemctl --user start prism-labwc.service 2>/dev/null || true
fi

# 3. Size the headless output to the client's requested mode.
W="${SUNSHINE_CLIENT_WIDTH:-1920}"
H="${SUNSHINE_CLIENT_HEIGHT:-1080}"
FPS="${SUNSHINE_CLIENT_FPS:-60}"
export WAYLAND_DISPLAY="$SOCKET"
for _ in $(seq 1 40); do
  [ -S "$RUNTIME/$SOCKET" ] && break
  sleep 0.25
done
if command -v wlr-randr >/dev/null; then
  wlr-randr --output HEADLESS-1 --custom-mode "${W}x${H}@${FPS}" 2>/dev/null || true
fi

# 3b. Dedicated audio sink for the headless session. Session apps get
# PULSE_SINK=prism-headless so only their audio is captured; the background
# guard loops this sink into Sunshine's capture sink and keeps the desktop's
# default sink on the physical output (Sunshine switches it at stream start).
PHYSICAL_SINK="$(pactl get-default-sink 2>/dev/null || true)"
pactl load-module module-null-sink sink_name=prism-headless \
  sink_properties=device.description="Prism Headless Session" >/dev/null 2>&1 || true
setsid "$(dirname "$0")/prism-headless-audio.sh" "$PHYSICAL_SINK" >>"$LOG" 2>&1 9>&- &

# 4. Launch gamescope inside the headless compositor.
# --adaptive-sync lets gamescope present frames as they arrive instead of
# holding them for a fixed vblank (VRR); on a headless output this removes
# the artificial fixed-refresh cap on frame pacing for the stream.
# --rt asks for realtime scheduling, which reduces frame-pacing jitter on the
# compositor thread; gamescope degrades gracefully when rtkit/CAP_SYS_NICE is
# unavailable, so this is safe everywhere.
GAMESCOPE_FLAGS=(--adaptive-sync --rt)
if [ "${SUNSHINE_CLIENT_ENABLE_HDR:-false}" = "true" ]; then
  GAMESCOPE_FLAGS+=(--hdr-enabled)
fi
if [ "${PRISM_STEAM:-0}" = "1" ]; then
  if [ -n "${PRISM_STEAM_APP_ID:-}" ]; then
    # Direct game launch (PRISM_STEAM_APP_ID, set by Sunshine for synced Steam
    # game apps): lightweight session — a plain Steam client (visible, per user
    # preference; no Deck UI flags), no mangoapp. The app command
    # (prism-steam-game.sh) launches the game and exits with it.
    # Two Xwaylands like the Deck session: gamescope treats the second as the
    # game display, which is what makes late-launched game windows composite.
    SESSION_CMD=(steam)
    GAMESCOPE_FLAGS+=(--xwayland-count 2)
  else
    # Deck UI flags (as used by gamescope-session-plus/Bazzite): -steamos3 /
    # -steampal / -steamdeck enable the full Deck interface including the QAM
    # performance tab; plain -steamos does not.
    SESSION_CMD=(steam -gamepadui -steamos3 -steampal -steamdeck)
    # Two Xwaylands are required for gamescope to export
    # STEAM_MULTIPLE_XWAYLANDS=1, which the Deck UI expects.
    GAMESCOPE_FLAGS+=(--xwayland-count 2)
    # Steam's performance overlay setting drives mangoapp through gamescope's
    # control interface; without --mangoapp the toggle has no effect.
    if command -v mangoapp >/dev/null; then
      GAMESCOPE_FLAGS+=(--mangoapp)
      # Pre-create the config file shared between Steam (writes presets) and
      # mangoapp (reads them). gamescope's own fallback writes a stray NUL
      # byte into its auto-created file.
      export MANGOHUD_CONFIGFILE="$RUNTIME/prism-mangoapp.conf"
      echo "no_display" > "$MANGOHUD_CONFIGFILE"
      # Steam perf level 4 writes "preset=4", which enables MangoHud's "debug"
      # element (gamescope frametime plots). That element renders invalid ImGui
      # widgets from the gamescope message data and aborts mangoapp outright on
      # builds with ImGui assertions enabled (e.g. Fedora's), leaving the
      # overlay crash-looping and never composited. MANGOHUD_CONFIG is parsed
      # after the config file, so this wins over anything Steam writes.
      export MANGOHUD_CONFIG="${MANGOHUD_CONFIG:+$MANGOHUD_CONFIG,}debug=0"
    else
      echo "mangoapp not found; Steam performance overlay will be unavailable"
    fi
  fi
else
  # Generic keepalive; the app's own command joins the session via the
  # gamescope wayland/X sockets (see state file).
  SESSION_CMD=(sleep infinity)
fi
# Snapshot existing sockets so step 5 can tell the new session's sockets apart
# from stale ones left by crashed sessions.
GS_BEFORE="$(find "$RUNTIME" -maxdepth 1 -name 'gamescope-*' -printf '%f ' 2>/dev/null)"
X_BEFORE="$(find /tmp/.X11-unix -maxdepth 1 -name 'X*' -printf '%f ' 2>/dev/null | tr -d 'X')"
setsid env WAYLAND_DISPLAY="$SOCKET" XDG_SESSION_TYPE=wayland PULSE_SINK=prism-headless \
  gamescope -W "$W" -H "$H" -r "$FPS" -e -f "${GAMESCOPE_FLAGS[@]}" \
  -- "${SESSION_CMD[@]}" >>"$LOG" 2>&1 9>&- &

# 5. Discover the gamescope session sockets and record state for the app
# command environment and for teardown. Stale sockets from crashed sessions
# linger in $XDG_RUNTIME_DIR and /tmp/.X11-unix, so discover by diffing against
# a pre-launch snapshot instead of taking the first match.
GSOCKET=""
XDISP=""
for _ in $(seq 1 40); do
  for s in "$RUNTIME"/gamescope-*; do
    case "$s" in
      *.lock | *-ei | *limiter*) continue ;;
    esac
    b="$(basename "$s")"
    [ -S "$s" ] || continue
    case " $GS_BEFORE " in *" $b "*) continue ;; esac
    GSOCKET="$b" && break
  done
  for x in /tmp/.X11-unix/X*; do
    [ -S "$x" ] || continue
    owner="$(stat -c %U "$x" 2>/dev/null)"
    [ "$owner" = "$(id -un)" ] || continue
    n="${x##*/X}"
    [ "$n" = "0" ] && continue
    case " $X_BEFORE " in *" $n "*) continue ;; esac
    # must belong to a live Xwayland, not a stale socket
    pgrep -f "Xwayland :$n " >/dev/null || pgrep -f "Xwayland :$n$" >/dev/null || continue
    XDISP=":$n" && break
  done
  [ -n "$GSOCKET" ] && [ -n "$XDISP" ] && break
  sleep 0.25
done
{
  echo "steam=${PRISM_STEAM:-0}"
  echo "wayland_display=$GSOCKET"
  echo "x_display=$XDISP"
} > "$STATE"
echo "launched gamescope ${W}x${H}@${FPS} flags=${GAMESCOPE_FLAGS[*]:-none} session=${SESSION_CMD[*]} socket=$GSOCKET x=$XDISP"
