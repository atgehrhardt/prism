#!/usr/bin/env bash
# Build and install prism-virtual-output: creates a KWin virtual output via
# zkde_screencast_unstable_v1 and keeps it alive until killed.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

XML="$REPO_ROOT/third-party/plasma-wayland-protocols/src/protocols/zkde-screencast-unstable-v1.xml"
[ -f "$XML" ] || { echo "missing protocol XML: $XML" >&2; exit 1; }

wayland-scanner client-header "$XML" "$BUILD_DIR/zkde-screencast-unstable-v1-client-protocol.h"
wayland-scanner private-code  "$XML" "$BUILD_DIR/zkde-screencast-unstable-v1-protocol.c"

mkdir -p "$HOME/.local/bin"
read -r -a WAYLAND_FLAGS <<< "$(pkg-config --cflags --libs wayland-client)"
cc -O2 -Wall -Wextra -I"$BUILD_DIR" \
  -o "$HOME/.local/bin/prism-virtual-output" \
  "$SCRIPT_DIR/prism-virtual-output.c" \
  "$BUILD_DIR/zkde-screencast-unstable-v1-protocol.c" \
  "${WAYLAND_FLAGS[@]}"

echo "prism-virtual-output installed to $HOME/.local/bin/prism-virtual-output"
