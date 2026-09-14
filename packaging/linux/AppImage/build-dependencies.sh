#!/usr/bin/env bash
## @file
## @brief Build pinned compositor dependencies against the AppImage glibc baseline.
set -euo pipefail
root=/tmp/cmake-build-appimage-dependencies
mkdir -p "$root"

## @brief Build and install an exact Meson dependency revision.
## @param $1 Repository URL.
## @param $2 Immutable commit SHA.
## @param $3 Source directory name.
## @param ... Additional Meson configuration options.
build() {
  local url="$1" revision="$2" name="$3"
  shift 3
  git init "$root/$name"
  git -C "$root/$name" fetch --depth 1 "$url" "$revision"
  git -C "$root/$name" checkout --detach FETCH_HEAD
  meson setup "$root/cmake-build-$name" "$root/$name" \
    --prefix=/opt/prism-deps --libdir=lib --buildtype=release "$@"
  meson compile -C "$root/cmake-build-$name"
  meson install -C "$root/cmake-build-$name"
  mkdir -p "/opt/prism-deps/share/licenses/$name"
  for license in "$root/$name"/COPYING* "$root/$name"/LICENSE*; do
    [ ! -f "$license" ] || cp "$license" "/opt/prism-deps/share/licenses/$name/"
  done
}
build https://gitlab.freedesktop.org/wayland/wayland.git \
  736d12ac67c20c60dc406dc49bb06be878501f86 wayland -Ddocumentation=false -Dtests=false
build https://gitlab.freedesktop.org/wayland/wayland-protocols.git \
  88223018d1b578d0d8869866da66d9608e05f928 protocols -Dtests=false
build https://gitlab.freedesktop.org/mesa/drm.git \
  a8e5e10a873f67f557dc70e5407af4553f35edd9 drm -Dtests=false -Dintel=disabled -Dradeon=disabled -Damdgpu=disabled -Dnouveau=disabled
build https://gitlab.freedesktop.org/pixman/pixman.git \
  9cc163c9da0fb4da430641715313d95a6ec466d9 pixman -Dtests=disabled -Ddemos=disabled
build https://github.com/xkbcommon/libxkbcommon.git \
  b3465081878e80ca6c11fe35c81787ec374ec15a xkbcommon \
  -Denable-docs=false -Denable-tools=false -Denable-x11=false -Denable-wayland=false
# Build-time tools and tests must also find the upgraded libraries.
printf '%s\n' /opt/prism-deps/lib > /etc/ld.so.conf.d/prism-build.conf
ldconfig
rm -rf "$root"
