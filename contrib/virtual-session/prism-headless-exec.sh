#!/usr/bin/env bash
# Run Prism's post-start application command in an owned systemd scope while
# preserving its environment, working directory, exit status, and wait model.
set -u

COMMAND="${PRISM_HEADLESS_APP_COMMAND:?missing PRISM_HEADLESS_APP_COMMAND}"
APP_UNIT="${PRISM_HEADLESS_APP_UNIT:?missing PRISM_HEADLESS_APP_UNIT}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# shellcheck source=contrib/virtual-session/prism-headless-common.sh
. "$SCRIPT_DIR/prism-headless-common.sh"

prism_run_owned_app "$APP_UNIT" "$COMMAND"
