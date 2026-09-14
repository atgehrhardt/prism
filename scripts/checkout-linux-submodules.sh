#!/usr/bin/env bash
## @file
## @brief Fetch only submodules consumed by Linux builds with documentation disabled.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# Do not recurse into FFmpeg's source encoders or standalone dependency test/docs trees.
git -C "$ROOT" submodule update --init --depth 1 --jobs 4 -- \
  third-party/build-deps third-party/glad third-party/inputtino \
  third-party/libdisplaydevice third-party/lizardbyte-common \
  third-party/moonlight-common-c third-party/nv-codec-headers \
  third-party/plasma-wayland-protocols third-party/Simple-Web-Server \
  third-party/tray third-party/wayland-protocols third-party/wlr-protocols
git -C "$ROOT/third-party/build-deps" submodule update --init --depth 1 -- \
  third-party/FFmpeg/Vulkan-Headers
git -C "$ROOT/third-party/moonlight-common-c" submodule update --init --depth 1 --jobs 2 -- enet nanors
git -C "$ROOT/third-party/lizardbyte-common" submodule update --init --depth 1 -- third-party/googletest
