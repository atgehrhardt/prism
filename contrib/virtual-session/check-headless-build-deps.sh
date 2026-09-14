#!/usr/bin/env bash
## @file
## @brief Check private-compositor build requirements without installing packages.
set -euo pipefail

missing=0
for program in git meson ninja pkg-config patch cc wayland-scanner; do
  if ! command -v "$program" >/dev/null 2>&1; then
    echo "Missing build command: $program" >&2
    missing=1
  fi
done
if ! command -v glslang >/dev/null 2>&1 && ! command -v glslangValidator >/dev/null 2>&1; then
  echo 'Missing build command: glslang or glslangValidator' >&2
  missing=1
fi
if command -v meson >/dev/null 2>&1; then
  meson_version="$(meson --version)"
  if ! awk -v version="$meson_version" 'BEGIN { split(version, v, "."); exit !(v[1] > 1 || (v[1] == 1 && v[2] >= 3)) }'; then
    echo "Meson >= 1.3 required; found $meson_version" >&2
    missing=1
  fi
fi

# These match the pinned labwc/wlroots Meson requirements, including the
# selected Vulkan, GBM, color-management and Xwayland features. Use pkg-config
# names so packagers can supply dependencies on any distribution.
requirements=(
  'wayland-server >= 1.24.0' 'wayland-client >= 1.24.0'
  'wayland-scanner >= 1.24.0' 'wayland-protocols >= 1.47' 'libdrm >= 2.4.129'
  'xkbcommon >= 1.8.0' 'pixman-1 >= 0.46.0' 'gbm >= 21.1'
  'vulkan >= 1.2.182' 'xwayland >= 21.1.9'
  egl glesv2 lcms2 libxml-2.0 glib-2.0 cairo pangocairo libpng libinput
  xcb xcb-ewmh xcb-icccm xcb-composite xcb-render xcb-res 'xcb-xfixes >= 1.15'
)
if command -v pkg-config >/dev/null 2>&1; then
  for requirement in "${requirements[@]}"; do
    if ! pkg-config --exists "$requirement"; then
      echo "Missing or outdated build dependency: $requirement" >&2
      missing=1
    fi
  done
fi
if [ "$missing" -ne 0 ]; then
  echo 'Install the development packages above, or provide a compatible prefix through PKG_CONFIG_PATH.' >&2
  exit 1
fi
echo 'Headless compositor build dependencies are available (GPU runtime support is not tested).'
