#!/usr/bin/env bash
## @file
## @brief Include license notices and source revision information in the AppImage.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APPDIR="${1:?usage: package-appimage-licenses.sh APPDIR}"
LICENSES="$APPDIR/usr/share/licenses/prism"
mkdir -p "$LICENSES/system" "$LICENSES/sources"
cp "$ROOT/LICENSE" "$LICENSES/LICENSE"
cp -a /opt/prism-deps/share/licenses "$LICENSES/compositor-dependencies"
find /usr/share/doc -mindepth 2 -maxdepth 2 -name copyright -type f \
  -exec cp --parents -t "$LICENSES/system" {} +
find "$ROOT/third-party" "$ROOT/cmake-build-appimage/_deps" \
  "$ROOT/cmake-build-headless-compositor/labwc" \
  -type d \( -name .git -o -name CMakeFiles -o -name node_modules \) -prune -o \
  -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) \
  -exec cp --parents -t "$LICENSES/sources" {} +
{
  printf 'Source: https://github.com/atgehrhardt/prism/tree/%s\n' "$(git -C "$ROOT" rev-parse HEAD)"
  printf 'Obtain matching sources with git clone and git submodule update --init --recursive.\n'
  printf 'The pinned compositor revisions and patches are in contrib/virtual-session.\n\n'
  git -C "$ROOT" submodule status --recursive
} > "$LICENSES/SOURCE.txt"
