#!/usr/bin/env bash
# Build and install prism-kwin-mode: configures KWin outputs at runtime via
# kde-output-management-v2 / kde-output-device-v2 (incl. custom modes).
## @file
## @brief Build the KWin output helper into a user or packaging prefix.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
PREFIX="${PRISM_INSTALL_PREFIX:-$HOME/.local}"
BUILD_DIR="$(mktemp -d "${TMPDIR:-/tmp}/cmake-build-kwin-mode.XXXXXXXX")"
trap 'rm -rf "$BUILD_DIR"' EXIT

MGMT_XML="$REPO_ROOT/third-party/plasma-wayland-protocols/src/protocols/kde-output-management-v2.xml"
DEV_XML="$REPO_ROOT/third-party/plasma-wayland-protocols/src/protocols/kde-output-device-v2.xml"
for f in "$MGMT_XML" "$DEV_XML"; do
  [ -f "$f" ] || { echo "missing protocol XML: $f" >&2; exit 1; }
done

## @brief Generate client bindings for a Wayland protocol.
## @param $1 Protocol XML path.
## @param $2 Generated file basename.
gen() {
  wayland-scanner client-header "$1" "$BUILD_DIR/$2-client-protocol.h"
  wayland-scanner private-code  "$1" "$BUILD_DIR/$2-protocol.c"
}
gen "$MGMT_XML" kde-output-management-v2
gen "$DEV_XML" kde-output-device-v2

mkdir -p "$PREFIX/bin"
read -r -a WAYLAND_FLAGS <<< "$(pkg-config --cflags --libs wayland-client)"
cc -O2 -Wall -Wextra -I"$BUILD_DIR" \
  -o "$PREFIX/bin/prism-kwin-mode" \
  "$SCRIPT_DIR/prism-kwin-mode.c" \
  "$BUILD_DIR/kde-output-management-v2-protocol.c" \
  "$BUILD_DIR/kde-output-device-v2-protocol.c" \
  "${WAYLAND_FLAGS[@]}"

echo "prism-kwin-mode installed to $PREFIX/bin/prism-kwin-mode"
