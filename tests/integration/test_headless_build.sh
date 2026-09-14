#!/usr/bin/env bash
## @file
## @brief Check GPU build selection and portable compositor preflight diagnostics.
# shellcheck disable=SC2030,SC2031 # PATH isolation is intentional for each fixture.
set -euo pipefail
SOURCE_DIR="${1:?source directory required}"
SANDBOX="$(mktemp -d)"
trap 'rm -rf "$SANDBOX"' EXIT
mkdir -p "$SANDBOX/bin" "$SANDBOX/drm/renderD128/device" "$SANDBOX/toolkit with spaces"

# Isolate compiler discovery from the test machine's installed CUDA toolkit.
for program in bash awk dirname mktemp sort cat rm; do
  ln -s "$(command -v "$program")" "$SANDBOX/bin/$program"
done
export CUDA_PATH="$SANDBOX/missing-toolkit"
unset CUDACXX CUDAHOSTCXX PRISM_CUDA_ALLOW_UNSUPPORTED_COMPILER
# shellcheck source=scripts/linux_cuda_config.sh
. "$SOURCE_DIR/scripts/linux_cuda_config.sh"

(
  export PATH="$SANDBOX/bin"
  export PRISM_ENABLE_CUDA=AUTO
  printf '%s\n' 0x1002 > "$SANDBOX/drm/renderD128/device/vendor"
  prism_configure_cuda "$SANDBOX/drm"
  [ "$CUDA_FLAG" = OFF ]

  printf '%s\n' 0x10de > "$SANDBOX/drm/renderD128/device/vendor"
  if prism_configure_cuda "$SANDBOX/drm" 2>"$SANDBOX/nvidia-error"; then
    echo 'NVIDIA build silently disabled CUDA without a toolkit' >&2
    exit 1
  fi
  PRISM_ENABLE_CUDA=OFF prism_configure_cuda "$SANDBOX/drm"
  [ "$CUDA_FLAG" = OFF ]

  if PRISM_ENABLE_CUDA=ON prism_configure_cuda "$SANDBOX/empty"; then
    echo 'Explicit CUDA request succeeded without a toolkit' >&2
    exit 1
  fi
  if PRISM_ENABLE_CUDA=invalid prism_configure_cuda "$SANDBOX/empty"; then
    exit 1
  fi
  if CUDACXX=absent-nvcc prism_configure_cuda "$SANDBOX/empty"; then
    exit 1
  fi
)
grep -q 'CUDA toolkit' "$SANDBOX/nvidia-error"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$SANDBOX/toolkit with spaces/nvcc"
chmod +x "$SANDBOX/toolkit with spaces/nvcc"
printf '%s\n' '#!/usr/bin/env bash' 'exit 0' > "$SANDBOX/bin/gcc"
chmod +x "$SANDBOX/bin/gcc"
(
  export PATH="$SANDBOX/bin"
  export CUDACXX="$SANDBOX/toolkit with spaces/nvcc"
  prism_configure_cuda "$SANDBOX/drm"
  [ "$CUDA_FLAG" = ON ]
  [ "${#CUDA_FLAGS[@]}" -eq 3 ]
  [ "${CUDA_FLAGS[0]}" = "-DCMAKE_CUDA_COMPILER=$CUDACXX" ]
  PRISM_CUDA_ALLOW_UNSUPPORTED_COMPILER=1 prism_configure_cuda "$SANDBOX/drm"
  [ "${CUDA_FLAGS[2]}" = '-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler' ]
  unset CUDACXX
  export PATH="$SANDBOX/toolkit with spaces:$PATH"
  prism_configure_cuda "$SANDBOX/empty"
  [ "$CUDA_FLAG" = ON ]
)

# Reject the default host, then verify fallback and explicit override behavior.
cat > "$SANDBOX/toolkit with spaces/nvcc" <<'EOF'
#!/usr/bin/env bash
if [ "${1:-}" = -allow-unsupported-compiler ]; then exit 0; fi
[ "$1" = -ccbin ] || exit 98
case "$2" in
  */gcc-15 | */host\ with\ spaces) exit 0 ;;
  *) echo 'unsupported GNU version' >&2; exit 1 ;;
esac
EOF
(
  export PATH="$SANDBOX/bin" CUDACXX="$SANDBOX/toolkit with spaces/nvcc"
  if prism_configure_cuda "$SANDBOX/drm" 2>"$SANDBOX/host-error"; then exit 1; fi
  [ "$CUDA_FLAG" = OFF ]
  PRISM_CUDA_ALLOW_UNSUPPORTED_COMPILER=1 prism_configure_cuda "$SANDBOX/drm"
  [ "${CUDA_FLAGS[2]}" = '-DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler' ]
)
grep -q 'CUDAHOSTCXX' "$SANDBOX/host-error"
for program in gcc-16 gcc-15 'host with spaces'; do
  cp "$SANDBOX/bin/gcc" "$SANDBOX/bin/$program"
done
(
  export PATH="$SANDBOX/bin" CUDACXX="$SANDBOX/toolkit with spaces/nvcc"
  prism_configure_cuda "$SANDBOX/drm"
  [ "${CUDA_FLAGS[1]}" = "-DCMAKE_CUDA_HOST_COMPILER=$SANDBOX/bin/gcc-15" ]
  [ "${CUDA_FLAGS[2]}" = '-DCMAKE_CUDA_FLAGS=' ]
  CUDAHOSTCXX="$SANDBOX/bin/host with spaces" prism_configure_cuda "$SANDBOX/drm"
  [ "${CUDA_FLAGS[1]}" = "-DCMAKE_CUDA_HOST_COMPILER=$SANDBOX/bin/host with spaces" ]
  if CUDAHOSTCXX=gcc-16 prism_configure_cuda "$SANDBOX/drm"; then exit 1; fi
  if CUDAHOSTCXX=missing-host prism_configure_cuda "$SANDBOX/drm"; then exit 1; fi
)

# Verify runtime search precedence for both CUDA and non-CUDA configurations.
cmake -DSOURCE_DIR="$SOURCE_DIR" -P "$SOURCE_DIR/tests/integration/test_cuda_link.cmake"

# Exercise --check without fetching/building or depending on the host distro.
for program in git ninja patch cc wayland-scanner glslang; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$SANDBOX/bin/$program"
  chmod +x "$SANDBOX/bin/$program"
done
cat > "$SANDBOX/bin/meson" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --version ] || exit 99
echo "${PRISM_TEST_MESON_VERSION:-1.3.0}"
EOF
cat > "$SANDBOX/bin/pkg-config" <<'EOF'
#!/usr/bin/env bash
[ "$1" = --exists ] || exit 99
[ "$2" != "${PRISM_TEST_MISSING_REQUIREMENT:-}" ]
EOF
chmod +x "$SANDBOX/bin/meson" "$SANDBOX/bin/pkg-config"
PATH="$SANDBOX/bin" bash "$SOURCE_DIR/contrib/virtual-session/build-headless-compositor.sh" --check
if PATH="$SANDBOX/bin" PRISM_TEST_MISSING_REQUIREMENT='wayland-protocols >= 1.47' \
  bash "$SOURCE_DIR/contrib/virtual-session/build-headless-compositor.sh" --check >"$SANDBOX/deps-error" 2>&1; then
  echo 'Outdated Wayland protocols passed the preflight' >&2
  exit 1
fi
grep -q 'wayland-protocols >= 1.47' "$SANDBOX/deps-error"
if PATH="$SANDBOX/bin" PRISM_TEST_MISSING_REQUIREMENT='pixman-1 >= 0.46.0' \
  bash "$SOURCE_DIR/contrib/virtual-session/build-headless-compositor.sh" --check >"$SANDBOX/deps-error" 2>&1; then
  echo 'Outdated Pixman passed the preflight' >&2
  exit 1
fi
grep -q 'pixman-1 >= 0.46.0' "$SANDBOX/deps-error"
if PATH="$SANDBOX/bin" PRISM_TEST_MISSING_REQUIREMENT=libinput \
  bash "$SOURCE_DIR/contrib/virtual-session/build-headless-compositor.sh" --check >"$SANDBOX/deps-error" 2>&1; then
  echo 'Missing libinput headers passed the preflight' >&2
  exit 1
fi
grep -q libinput "$SANDBOX/deps-error"
if PATH="$SANDBOX/bin" PRISM_TEST_MESON_VERSION=1.2.9 \
  bash "$SOURCE_DIR/contrib/virtual-session/build-headless-compositor.sh" --check >"$SANDBOX/meson-error" 2>&1; then
  echo 'Outdated Meson passed the preflight' >&2
  exit 1
fi
grep -q 'Meson >= 1.3 required' "$SANDBOX/meson-error"

# Check the real startup preflight. An invalid session ID ends each successful
# preflight before any unit, audio, or display mutation can occur.
mkdir -p "$SANDBOX/home/.local/bin" "$SANDBOX/runtime"
for program in mkdir date grep; do
  ln -s "$(command -v "$program")" "$SANDBOX/bin/$program"
done
for program in cmp find flock pactl prism-input-bridge python3 readlink systemd-run timeout wayland-info wlr-randr; do
  printf '%s\n' '#!/usr/bin/env bash' 'exit 99' > "$SANDBOX/bin/$program"
  chmod +x "$SANDBOX/bin/$program"
done
cat > "$SANDBOX/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
[ "$*" = '--user show-environment' ]
EOF
chmod +x "$SANDBOX/bin/systemctl"
(
  export PATH="$SANDBOX/bin" HOME="$SANDBOX/home" XDG_RUNTIME_DIR="$SANDBOX/runtime"
  export PRISM_CLIENT_HDR=true PRISM_SESSION_ID='invalid/id' PRISM_STEAM=0
  unset PRISM_CLIENT_WIDTH PRISM_CLIENT_HEIGHT PRISM_CLIENT_FPS PRISM_RENDER_DEVICE PRISM_STEAM_APP_ID
  if bash "$SOURCE_DIR/contrib/virtual-session/prism-headless-start.sh"; then exit 1; fi
)
grep -q 'requires prism-labwc' "$SANDBOX/home/.local/state/prism-headless.log"
printf '%s\n' '#!/usr/bin/env bash' 'echo "labwc (+xwayland)"' \
  > "$SANDBOX/home/.local/bin/prism-labwc"
chmod +x "$SANDBOX/home/.local/bin/prism-labwc"
(
  export PATH="$SANDBOX/bin" HOME="$SANDBOX/home" XDG_RUNTIME_DIR="$SANDBOX/runtime"
  export PRISM_CLIENT_HDR=true PRISM_SESSION_ID='invalid/id' PRISM_STEAM=0
  unset PRISM_CLIENT_WIDTH PRISM_CLIENT_HEIGHT PRISM_CLIENT_FPS PRISM_RENDER_DEVICE PRISM_STEAM_APP_ID
  if bash "$SOURCE_DIR/contrib/virtual-session/prism-headless-start.sh"; then exit 1; fi
)
grep -q 'invalid session id' "$SANDBOX/home/.local/state/prism-headless.log"
# The packaged compositor must take precedence over stale user-installed helpers.
mkdir -p "$SANDBOX/packaged"
cp "$SANDBOX/home/.local/bin/prism-labwc" "$SANDBOX/packaged/prism-labwc"
printf '#!/bin/sh\nexit 29\n' > "$SANDBOX/home/.local/bin/prism-labwc"
: > "$SANDBOX/home/.local/state/prism-headless.log"
(
  export PATH="$SANDBOX/bin" HOME="$SANDBOX/home" XDG_RUNTIME_DIR="$SANDBOX/runtime"
  export PRISM_BIN_DIR="$SANDBOX/packaged" PRISM_CLIENT_HDR=true PRISM_SESSION_ID='invalid/id' PRISM_STEAM=0
  unset PRISM_CLIENT_WIDTH PRISM_CLIENT_HEIGHT PRISM_CLIENT_FPS PRISM_RENDER_DEVICE PRISM_STEAM_APP_ID
  if bash "$SOURCE_DIR/contrib/virtual-session/prism-headless-start.sh"; then exit 1; fi
)
grep -q 'invalid session id' "$SANDBOX/home/.local/state/prism-headless.log"
echo 'Headless build selection and dependency checks passed.'
