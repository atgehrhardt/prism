#!/usr/bin/env bash
# Build and install prism-input-bridge: forwards Prism's uinput evdev
# events into the headless labwc session via wlroots virtual-input protocols.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_DIR="$(mktemp -d)"
trap 'rm -rf "$BUILD_DIR"' EXIT

WLR_VP_XML="$REPO_ROOT/third-party/wlr-protocols/unstable/wlr-virtual-pointer-unstable-v1.xml"
# The repo's bundled wayland-protocols copy predates virtual-keyboard, so the
# XML is vendored under contrib/virtual-session/protocols/. Fall back to the
# system wayland-protocols if a distro ships it there.
VK_XML="$SCRIPT_DIR/protocols/virtual-keyboard-unstable-v1.xml"
if [ ! -f "$VK_XML" ]; then
  VK_XML="$(pkg-config --variable=pkgdatadir wayland-protocols)/unstable/virtual-keyboard/virtual-keyboard-unstable-v1.xml"
fi
for f in "$WLR_VP_XML" "$VK_XML"; do
  [ -f "$f" ] || { echo "missing protocol XML: $f" >&2; exit 1; }
done

gen() { # gen <xml> <basename>
  wayland-scanner client-header "$1" "$BUILD_DIR/$2-client-protocol.h"
  wayland-scanner private-code  "$1" "$BUILD_DIR/$2-protocol.c"
}
gen "$WLR_VP_XML" wlr-virtual-pointer-unstable-v1
gen "$VK_XML" virtual-keyboard-unstable-v1

mkdir -p "$HOME/.local/bin"
read -r -a BRIDGE_FLAGS <<< "$(pkg-config --cflags --libs wayland-client xkbcommon)"
cc -O2 -Wall -Wextra -I"$BUILD_DIR" \
  -o "$HOME/.local/bin/prism-input-bridge" \
  "$SCRIPT_DIR/prism-input-bridge.c" \
  "$BUILD_DIR/wlr-virtual-pointer-unstable-v1-protocol.c" \
  "$BUILD_DIR/virtual-keyboard-unstable-v1-protocol.c" \
  "${BRIDGE_FLAGS[@]}"

install -Dm644 "$SCRIPT_DIR/prism-input-bridge.service" \
  "$HOME/.config/systemd/user/prism-input-bridge.service"
systemctl --user daemon-reload

echo "prism-input-bridge installed to $HOME/.local/bin/prism-input-bridge"
