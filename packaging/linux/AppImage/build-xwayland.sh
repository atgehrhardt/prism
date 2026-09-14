#!/usr/bin/env bash
## @file
## @brief Build Xwayland with relocatable keyboard compiler and data paths.
set -euo pipefail
ROOT=/tmp/cmake-build-appimage-xwayland
git init "$ROOT/protocols"
git -C "$ROOT/protocols" fetch --depth 1 https://gitlab.freedesktop.org/xorg/proto/xorgproto.git \
  c18d2bc22813793bba7f0e4e603c0104d7724802
git -C "$ROOT/protocols" checkout --detach FETCH_HEAD
meson setup "$ROOT/cmake-build-protocols" "$ROOT/protocols" \
  --prefix=/opt/prism-deps --libdir=lib
meson install -C "$ROOT/cmake-build-protocols"
mkdir -p /opt/prism-deps/share/licenses/xorgproto
cp "$ROOT/protocols"/COPYING* /opt/prism-deps/share/licenses/xorgproto/
git init "$ROOT/source"
git -C "$ROOT/source" fetch --depth 1 https://gitlab.freedesktop.org/xorg/xserver.git \
  c5a47fda896aeefbf1d06a73e392a294344f9e1a
git -C "$ROOT/source" checkout --detach FETCH_HEAD
# The installed wrapper sets cwd to the AppDir before starting this binary.
# Stock distro Xwayland hardcodes /usr/bin/xkbcomp and cannot use the bundle.
meson setup "$ROOT/cmake-build-xwayland" "$ROOT/source" \
  --prefix=/opt/prism-deps --libdir=lib --buildtype=release \
  -Dxvfb=false -Dxwayland_ei=false -Ddocs=false -Ddevel-docs=false \
  -Dsecure-rpc=false -Dxdmcp=false -Dxdm-auth-1=false \
  -Dxkb_bin_dir=usr/bin -Dxkb_dir=usr/share/xkb -Dxkb_output_dir=/tmp
meson compile -C "$ROOT/cmake-build-xwayland"
meson install -C "$ROOT/cmake-build-xwayland"
mkdir -p /opt/prism-deps/share/licenses/xwayland
cp "$ROOT/source/COPYING" /opt/prism-deps/share/licenses/xwayland/
rm -rf "$ROOT"
