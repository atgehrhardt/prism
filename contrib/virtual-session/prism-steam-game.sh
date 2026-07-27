#!/usr/bin/env bash
# Launch and monitor one Steam game strictly inside Prism's owned headless
# session. The stream remains alive for arbitrarily long shader compilation.
set -u

ID="${1:?usage: prism-steam-game.sh <appid>}"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$RUNTIME/prism-headless.state"
LOG="$HOME/.local/state/prism-headless.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

EXPECTED_SESSION="${PRISM_SESSION_ID:-}"
STATE_SESSION="$(prism_state_get "$STATE" session_id 2>/dev/null || true)"
STATE_UNIT="$(prism_state_get "$STATE" unit 2>/dev/null || true)"
if [ -z "$EXPECTED_SESSION" ] || [ "$STATE_SESSION" != "$EXPECTED_SESSION" ]; then
  echo "ERROR: headless session state does not match game launch"
  exit 1
fi
PRISM_HEADLESS_UNIT="${PRISM_HEADLESS_UNIT:-$STATE_UNIT}"
if [ -z "$PRISM_HEADLESS_UNIT" ] || ! prism_unit_live "$PRISM_HEADLESS_UNIT"; then
  echo "ERROR: owned headless session is not active"
  exit 1
fi

echo "=== steam-game $(date -Is) appid=$ID session=$EXPECTED_SESSION unit=$PRISM_HEADLESS_UNIT ==="
# Install-script evaluators include `Install=1` before `--`; requiring the
# exact delimiter below prevents them from being mistaken for the game.
GAME_PATTERN="SteamLaunch AppId=$ID -- "

session_game_pids() {
  local pid command_line
  while read -r pid; do
    [ -r "/proc/$pid/cmdline" ] || continue
    command_line="$(tr '\0' ' ' < "/proc/$pid/cmdline" 2>/dev/null || true)"
    case "$command_line" in
      *"$GAME_PATTERN"*) printf '%s\n' "$pid" ;;
    esac
  done < <(prism_unit_pids "$PRISM_HEADLESS_UNIT")
}

for _ in $(seq 1 60); do
  prism_unit_live "$PRISM_HEADLESS_UNIT" || break
  prism_unit_has_comm "$PRISM_HEADLESS_UNIT" steam && break
  sleep 1
done
if ! prism_unit_has_comm "$PRISM_HEADLESS_UNIT" steam; then
  echo "ERROR: session Steam did not start"
  exit 1
fi

launched=0
queued=0
while prism_unit_live "$PRISM_HEADLESS_UNIT" &&
  prism_unit_has_comm "$PRISM_HEADLESS_UNIT" steam; do
  if [ "$queued" = "0" ] &&
    steam "steam://rungameid/$ID" >/dev/null 2>&1; then
    queued=1
  fi
  if [ -n "$(session_game_pids | head -1)" ]; then
    launched=1
    break
  fi
  sleep 2
done
if [ "$launched" != "1" ]; then
  echo "ERROR: game $ID never appeared before session Steam exited"
  exit 1
fi

GAME_PID="$(session_game_pids | head -1)"
echo "game $ID launched (pid $GAME_PID)"
while prism_unit_live "$PRISM_HEADLESS_UNIT" &&
  prism_unit_has_comm "$PRISM_HEADLESS_UNIT" steam &&
  [ -n "$(session_game_pids | head -1)" ]; do
  sleep 2
done
if ! prism_unit_live "$PRISM_HEADLESS_UNIT"; then
  echo "ERROR: owned headless session died while game $ID was running"
  exit 1
fi
if ! prism_unit_has_comm "$PRISM_HEADLESS_UNIT" steam &&
  [ -n "$(session_game_pids | head -1)" ]; then
  echo "ERROR: session Steam died while game $ID was running"
  exit 1
fi
echo "game $ID exited; shutting down session Steam"
steam -shutdown >/dev/null 2>&1 || true
