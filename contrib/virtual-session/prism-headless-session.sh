#!/usr/bin/env bash
# Prism foreground supervisor for prism-headless-session.service.

# Build gamescope flags and its supervised session command without launching
# processes or writing files. Arguments 6-8 name the output array/variables.
prism_build_headless_session_command() {
  local steam_mode="${1:?steam mode required}"
  local steam_app_id="${2:-}"
  local script_dir="${3:?script directory required}"
  local hdr="${4:?HDR mode required}"
  local mango_available="${5:?mangoapp availability required}"
  local -n gamescope_flags_ref="${6:?gamescope flags output required}"
  local -n session_cmd_ref="${7:?session command output required}"
  local -n mango_enabled_ref="${8:?mangoapp output required}"

  case "$steam_mode" in 0 | 1) ;; *) return 2 ;; esac
  case "$hdr" in true | false) ;; *) return 2 ;; esac
  case "$mango_available" in 0 | 1) ;; *) return 2 ;; esac
  case "$steam_app_id" in
    '' | *[!0-9]*) [ -z "$steam_app_id" ] || return 2
      ;;
  esac

  gamescope_flags_ref=(--adaptive-sync --rt)
  session_cmd_ref=(sleep infinity)
  mango_enabled_ref=0

  if [ "$hdr" = "true" ]; then
    gamescope_flags_ref+=(--hdr-enabled)
  fi
  if [ "$steam_mode" = "1" ]; then
    gamescope_flags_ref+=(--xwayland-count 2)
    if [ -n "$steam_app_id" ]; then
      session_cmd_ref=(
        "$script_dir/prism-headless-steam.sh"
        steam
        "steam://rungameid/$steam_app_id"
      )
    else
      # shellcheck disable=SC2034  # Nameref output is consumed by the caller.
      session_cmd_ref=(
        "$script_dir/prism-headless-steam.sh"
        steam
        -gamepadui
        -steamos3
        -steampal
        -steamdeck
      )
      if [ "$mango_available" = "1" ]; then
        gamescope_flags_ref+=(--mangoapp)
        # shellcheck disable=SC2034  # Nameref output is consumed by the caller.
        mango_enabled_ref=1
      fi
    fi
  fi
}

# Configure logging and environment, start session audio, and replace this
# supervisor with gamescope and the command selected above.
prism_headless_session_main() {
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local socket="wayland-prism"
  local log="$HOME/.local/state/prism-headless.log"
  local script_dir
  local w="${PRISM_CLIENT_WIDTH:?missing PRISM_CLIENT_WIDTH}"
  local h="${PRISM_CLIENT_HEIGHT:?missing PRISM_CLIENT_HEIGHT}"
  local fps="${PRISM_CLIENT_FPS:?missing PRISM_CLIENT_FPS}"
  local steam_mode="${PRISM_STEAM:-0}"
  local physical_sink="${PRISM_PHYSICAL_SINK:-}"
  local mango_available=0
  local mango_enabled=0
  local -a gamescope_flags=()
  local -a session_cmd=()

  script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  mkdir -p "$(dirname "$log")"
  exec >>"$log" 2>&1

  echo "=== headless-session $(date -Is) id=${PRISM_SESSION_ID:-?} ${w}x${h}@${fps} steam=$steam_mode ==="

  "$script_dir/prism-headless-audio.sh" "$physical_sink" &

  if command -v mangoapp >/dev/null 2>&1; then
    mango_available=1
  fi
  if ! prism_build_headless_session_command \
    "$steam_mode" \
    "${PRISM_STEAM_APP_ID:-}" \
    "$script_dir" \
    "${PRISM_CLIENT_HDR:-false}" \
    "$mango_available" \
    gamescope_flags \
    session_cmd \
    mango_enabled; then
    echo "ERROR: invalid headless session command configuration" >&2
    return 2
  fi

  if [ "$mango_enabled" = "1" ]; then
    export MANGOHUD_CONFIGFILE="$runtime/prism-mangoapp.conf"
    printf '%s\n' "no_display" > "$MANGOHUD_CONFIGFILE"
    export MANGOHUD_CONFIG="${MANGOHUD_CONFIG:+$MANGOHUD_CONFIG,}debug=0"
  elif [ "$steam_mode" = "1" ] &&
    [ -z "${PRISM_STEAM_APP_ID:-}" ] &&
    [ "$mango_available" = "0" ]; then
    echo "mangoapp not found; Steam performance overlay will be unavailable"
  fi

  export WAYLAND_DISPLAY="$socket"
  export XDG_SESSION_TYPE=wayland
  export PULSE_SINK=prism-headless
  echo "starting gamescope flags=${gamescope_flags[*]} session=${session_cmd[*]}"
  exec gamescope -w "$w" -h "$h" -W "$w" -H "$h" -r "$fps" -e -f \
    "${gamescope_flags[@]}" -- "${session_cmd[@]}"
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  prism_headless_session_main "$@"
fi
