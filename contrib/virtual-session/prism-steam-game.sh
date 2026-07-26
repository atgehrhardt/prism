#!/usr/bin/env bash
# Prism: launch a Steam game inside the headless session and exit when the
# game exits, so the app — and therefore the stream — closes with the game.
# Sunshine runs this as the app command of synced Steam games; the session's
# own lightweight Steam client (plain `steam -silent`, no Deck UI) is brought
# up by prism-headless-start.sh when PRISM_STEAM_APP_ID is set.
#
# Usage: prism-steam-game.sh <appid>
set -u

ID="${1:?usage: prism-steam-game.sh <appid>}"
LOG="$HOME/.local/state/prism-headless.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== steam-game $(date -Is) appid=$ID ==="

# Games run under Steam's reaper as `reaper SteamLaunch AppId=<id> -- ...`.
# The ` -- ` is required: install-script evaluators run as
# `reaper SteamLaunch AppId=<id> Install=1 -- ...` and must NOT count as the
# game. The trailing space also prevents prefix collisions (44 vs 440).
GAME_PATTERN="SteamLaunch AppId=$ID -- "

# 1. Launch the game through the session Steam client, retrying while the
#    client is still booting. Steam queues URLs sent to a running instance,
#    so repeats are harmless until the game process shows up. The wait is
#    generous: install scripts and Vulkan shader processing can take minutes
#    before the game process appears.
launched=0
for _ in $(seq 1 150); do
  steam "steam://rungameid/$ID" >/dev/null 2>&1 || true
  sleep 2
  if pgrep -f "$GAME_PATTERN" >/dev/null; then
    launched=1
    break
  fi
done
if [ "$launched" != "1" ]; then
  echo "game $ID never appeared; giving up"
  exit 1
fi
echo "game $ID launched"

# 2. Wait for the game to exit.
while pgrep -f "$GAME_PATTERN" >/dev/null; do
  sleep 2
done
echo "game $ID exited; shutting down session steam"

# 3. Quit the session Steam client so the teardown in prism-headless-stop.sh
#    restores the desktop one. Exiting here ends the app, which closes the
#    stream and the session.
steam -shutdown 2>/dev/null || true
