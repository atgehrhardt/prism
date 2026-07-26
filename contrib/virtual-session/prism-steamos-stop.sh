#!/usr/bin/env bash
# Backwards-compatible wrapper for the old steamos stop path.
exec "$(dirname "$0")/prism-headless-stop.sh" "$@"
