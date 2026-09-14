#!/usr/bin/env bash
## @file
## @brief Stage the cached compositor only when it matches the checkout's build inputs.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
APPDIR="${1:?usage: stage-compositor.sh APPDIR|--check}"
cd "$ROOT"
if ! sha256sum --check --status /opt/prism-deps/share/licenses/private-compositor/inputs.sha256; then
  echo 'Compositor inputs changed; rebuild the AppImage builder container.' >&2
  exit 1
fi
[ "$APPDIR" != --check ] || exit 0
install -Dm755 /opt/prism-deps/bin/prism-labwc "$APPDIR/usr/bin/prism-labwc"
