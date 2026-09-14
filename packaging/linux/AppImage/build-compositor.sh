#!/usr/bin/env bash
## @file
## @brief Cache the pinned private compositor and its license notices in the builder.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ROOT"
PRISM_INSTALL_PREFIX=/opt/prism-deps bash contrib/virtual-session/build-headless-compositor.sh
LICENSES=/opt/prism-deps/share/licenses/private-compositor
mkdir -p "$LICENSES"
(
  cd cmake-build-headless-compositor/labwc
  find . -type d \( -name .git -o -name CMakeFiles \) -prune -o \
    -type f \( -iname 'LICENSE*' -o -iname 'COPYING*' \) \
    -exec cp --parents -t "$LICENSES" {} +
)
sha256sum contrib/virtual-session/build-headless-compositor.sh \
  contrib/virtual-session/check-headless-build-deps.sh \
  contrib/virtual-session/patches/*.patch packaging/linux/AppImage/build-compositor.sh \
  > "$LICENSES/inputs.sha256"
rm -rf cmake-build-headless-compositor
