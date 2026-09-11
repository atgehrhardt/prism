#!/usr/bin/env bash
## @file
## @brief Build Prism's isolated HDR-capable labwc with a pinned static wlroots.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BUILD_ROOT="$REPO_ROOT/cmake-build-headless-compositor"
LABWC_REV=529fc382da8f9b6bc4dcea720fd3561e605abd91
WLROOTS_REV=a7f20066270c042799ae70b71dfa4d561ba85121
PREFIX="${PRISM_INSTALL_PREFIX:-$HOME/.local}"

bash "$SCRIPT_DIR/check-headless-build-deps.sh"
if [ "${1:-}" = --check ]; then
  exit 0
fi
if [ "$#" -ne 0 ]; then
  echo 'Usage: build-headless-compositor.sh [--check]' >&2
  exit 2
fi

## @brief Fetch an exact upstream commit into a dedicated build checkout.
## @param $1 Repository URL.
## @param $2 Expected commit SHA.
## @param $3 Checkout path.
fetch_source() {
  local url="$1" revision="$2" destination="$3"
  if [ ! -d "$destination/.git" ]; then
    git init "$destination"
    git -C "$destination" remote add origin "$url"
    git -C "$destination" fetch --depth 1 origin "$revision"
    git -C "$destination" checkout --detach FETCH_HEAD
  fi
  [ "$(git -C "$destination" rev-parse HEAD)" = "$revision" ] || {
    echo "ERROR: unexpected source revision in $destination" >&2
    return 1
  }
}

fetch_source https://github.com/labwc/labwc.git "$LABWC_REV" "$BUILD_ROOT/labwc"
fetch_source https://gitlab.freedesktop.org/wlroots/wlroots.git "$WLROOTS_REV" \
  "$BUILD_ROOT/labwc/subprojects/wlroots"
PATCH_FILE="$SCRIPT_DIR/patches/wlroots-headless-hdr.patch"
if git -C "$BUILD_ROOT/labwc/subprojects/wlroots" apply --check "$PATCH_FILE"; then
  git -C "$BUILD_ROOT/labwc/subprojects/wlroots" apply "$PATCH_FILE"
else
  git -C "$BUILD_ROOT/labwc/subprojects/wlroots" apply --reverse --check "$PATCH_FILE"
fi

# Static linking keeps this headless-only change out of the user's desktop.
meson setup --reconfigure "$BUILD_ROOT/build" "$BUILD_ROOT/labwc" \
  --buildtype=release --force-fallback-for=wlroots-0.20 \
  -Dprefix="$PREFIX" -Dicon=disabled -Dsvg=disabled -Dman-pages=disabled \
  -Dlabnag=disabled -Dnls=disabled -Dsystemd-session=disabled -Dxwayland=enabled \
  -Dwlroots:default_library=static -Dwlroots:examples=false \
  -Dwlroots:backends=[] -Dwlroots:renderers=vulkan,gles2 \
  -Dwlroots:allocators=gbm -Dwlroots:session=disabled \
  -Dwlroots:color-management=enabled
meson compile -C "$BUILD_ROOT/build"
install -Dm755 "$BUILD_ROOT/build/labwc" "$PREFIX/bin/prism-labwc"
echo "HDR headless compositor installed to $PREFIX/bin/prism-labwc"
