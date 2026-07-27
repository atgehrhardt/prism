#!/usr/bin/env bash
# Monitor one Steam game launched by Prism's owned headless Steam process.
# The stream remains alive for arbitrarily long downloads or shader compilation.

PRISM_STEAM_GAME_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$PRISM_STEAM_GAME_SCRIPT_DIR/prism-headless-common.sh"

# Print owned process IDs whose command line contains the exact game-launch
# pattern. Install-script evaluators do not contain that exact delimiter.
prism_session_game_pids() {
  local unit="${1:?unit required}"
  local game_pattern="${2:?game pattern required}"
  local pid command_line

  while read -r pid; do
    [ -r "$PRISM_PROC_ROOT/$pid/cmdline" ] || continue
    command_line="$(tr '\0' ' ' < "$PRISM_PROC_ROOT/$pid/cmdline" 2>/dev/null || true)"
    case "$command_line" in
      *"$game_pattern"*) printf '%s\n' "$pid" ;;
    esac
  done < <(prism_unit_pids "$unit")
}

# Validate session ownership, wait for the initially requested game, monitor
# its lifetime, and shut down the session Steam client after the game exits.
prism_steam_game_main() {
  local id="${1:?usage: prism-steam-game.sh <appid>}"
  local runtime="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
  local state="$runtime/prism-headless.state"
  local log="$HOME/.local/state/prism-headless.log"
  local expected_session="${PRISM_SESSION_ID:-}"
  local state_session state_unit unit
  local game_pattern game_pid
  local launched=0
  local steam_missing_seconds=0

  case "$id" in
    '' | *[!0-9]*)
      echo "ERROR: invalid Steam app ID '$id'" >&2
      return 2
      ;;
  esac

  mkdir -p "$(dirname "$log")"
  exec >>"$log" 2>&1

  state_session="$(prism_state_get "$state" session_id 2>/dev/null || true)"
  state_unit="$(prism_state_get "$state" unit 2>/dev/null || true)"
  if [ -z "$expected_session" ] || [ "$state_session" != "$expected_session" ]; then
    echo "ERROR: headless session state does not match game launch"
    return 1
  fi
  unit="${PRISM_HEADLESS_UNIT:-$state_unit}"
  if [ -z "$unit" ] || ! prism_unit_live "$unit"; then
    echo "ERROR: owned headless session is not active"
    return 1
  fi

  echo "=== steam-game $(date -Is) appid=$id session=$expected_session unit=$unit ==="
  echo "game $id launch requested by the owned Steam session; waiting for the game process"
  # Install-script evaluators include `Install=1` before `--`; requiring the
  # exact delimiter below prevents them from being mistaken for the game.
  game_pattern="SteamLaunch AppId=$id -- "

  for _ in $(seq 1 60); do
    prism_unit_live "$unit" || break
    prism_unit_has_comm "$unit" steam && break
    sleep 1
  done
  if ! prism_unit_has_comm "$unit" steam; then
    echo "ERROR: session Steam did not start"
    return 1
  fi

  while prism_unit_live "$unit"; do
    game_pid="$(prism_session_game_pids "$unit" "$game_pattern" | head -1)"
    if [ -n "$game_pid" ]; then
      launched=1
      break
    fi
    if prism_unit_has_comm "$unit" steam; then
      if [ "$steam_missing_seconds" -gt 0 ]; then
        echo "session Steam returned after a ${steam_missing_seconds}s restart window"
      fi
      steam_missing_seconds=0
    else
      steam_missing_seconds=$((steam_missing_seconds + 1))
      if [ "$steam_missing_seconds" -eq 1 ]; then
        echo "session Steam temporarily disappeared; allowing up to 60s for restart"
      elif [ "$steam_missing_seconds" -ge 60 ]; then
        echo "ERROR: session Steam did not return within 60s while launching game $id"
        return 1
      fi
    fi
    sleep 1
  done
  if [ "$launched" != "1" ]; then
    echo "ERROR: owned headless session ended before game $id appeared"
    return 1
  fi

  echo "game $id launched (pid $game_pid)"
  while [ -n "$(prism_session_game_pids "$unit" "$game_pattern" | head -1)" ]; do
    if ! prism_unit_live "$unit"; then
      echo "ERROR: owned headless session died while game $id was running"
      return 1
    fi
    sleep 2
  done

  echo "game $id exited; shutting down session Steam"
  steam -shutdown >/dev/null 2>&1 || true
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
  set -u
  prism_steam_game_main "$@"
fi
