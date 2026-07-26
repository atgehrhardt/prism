#!/usr/bin/env bash
# Backwards-compatible wrapper: SteamOS session = headless + steam behavior.
exec env PRISM_STEAM=1 "$(dirname "$0")/prism-headless-start.sh" "$@"
