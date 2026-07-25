#!/usr/bin/env bash
# Prism — one-command install for Fedora.
#   curl -fsSL https://raw.githubusercontent.com/atgehrhardt/prism/virtual-capture/install.sh | bash
set -euo pipefail

REPO="https://github.com/atgehrhardt/prism.git"
BRANCH="virtual-capture"
SRC_DIR="${PRISM_SRC_DIR:-$HOME/Dev/prism}"
BUILD_JOBS="$(nproc)"

log() { printf '\033[1;32m==>\033[0m %s\n' "$*"; }

# --- 1. Dependencies -------------------------------------------------------
log "Installing build and runtime dependencies (sudo may ask for your password)"
sudo dnf install -y \
  git cmake gcc-c++ ninja-build nodejs-npm wget which desktop-file-utils \
  libcap-devel libcurl-devel libdrm-devel libevdev-devel libnotify-devel \
  libva-devel libX11-devel libxcb-devel libXcursor-devel libXfixes-devel \
  libXi-devel libXinerama-devel libXrandr-devel libXtst-devel \
  openssl-devel pipewire-devel glslc vulkan-loader-devel \
  libgudev mesa-libGL-devel mesa-libgbm-devel miniupnpc-devel \
  numactl-devel opus-devel pulseaudio-libs-devel qt6-qtbase-devel qt6-qtsvg-devel \
  wayland-devel libxkbcommon-devel python3-jinja2 \
  gamescope labwc wlr-randr steam kscreen

# --- 2. Source --------------------------------------------------------------
if [ -d "$SRC_DIR/.git" ]; then
  log "Updating existing checkout in $SRC_DIR"
  git -C "$SRC_DIR" fetch origin "$BRANCH"
  git -C "$SRC_DIR" checkout "$BRANCH"
  git -C "$SRC_DIR" reset --hard "origin/$BRANCH"
  git -C "$SRC_DIR" submodule update --init --recursive
else
  log "Cloning Prism into $SRC_DIR"
  git clone --branch "$BRANCH" --recurse-submodules "$REPO" "$SRC_DIR"
fi

# --- 3. Build ----------------------------------------------------------------
log "Building Prism (this takes a while)"
# Enable CUDA (NVIDIA DMA-BUF/nvenc path) only when a CUDA toolkit is present;
# on AMD/Intel systems Sunshine simply builds without it.
CUDA_FLAG="OFF"
CUDA_COMPILER_FLAG=""
if command -v nvcc >/dev/null; then
  CUDA_FLAG="ON"
elif [ -x /usr/local/cuda/bin/nvcc ]; then
  CUDA_FLAG="ON"
  CUDA_COMPILER_FLAG="-DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc"
fi
# Newer distros ship a GCC newer than nvcc supports; permit it (Sunshine's CUDA
# code is small and builds fine in practice).
if [ "$CUDA_FLAG" = "ON" ]; then
  CUDA_COMPILER_FLAG="$CUDA_COMPILER_FLAG -DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler"
fi
cmake -S "$SRC_DIR" -B "$SRC_DIR/cmake-build-prism" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local" \
  -DSUNSHINE_ENABLE_CUDA="$CUDA_FLAG" \
  $CUDA_COMPILER_FLAG \
  -DCUDA_FAIL_ON_MISSING=OFF \
  -DBUILD_DOCS=OFF -DBUILD_TESTS=OFF
cmake --build "$SRC_DIR/cmake-build-prism" --parallel "$BUILD_JOBS"

# --- 4. Install --------------------------------------------------------------
log "Installing to ~/.local"
DESTDIR= cmake --install "$SRC_DIR/cmake-build-prism" --prefix "$HOME/.local" 2>/dev/null || {
  # Fallback: install the binary and assets manually
  install -Dm755 "$SRC_DIR/cmake-build-prism/sunshine" "$HOME/.local/bin/sunshine"
  [ -d "$SRC_DIR/cmake-build-prism/assets" ] && rm -rf "$HOME/.local/share/sunshine" && \
    cp -r "$SRC_DIR/cmake-build-prism/assets" "$HOME/.local/share/sunshine" || true
}

# --- 5. Session stack ---------------------------------------------------------
log "Installing Prism scripts and systemd user units"
install -Dm755 "$SRC_DIR/contrib/virtual-session/steamos-start.sh"   "$HOME/.local/bin/steamos-start.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/steamos-stop.sh"    "$HOME/.local/bin/steamos-stop.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/desktop-refresh.sh" "$HOME/.local/bin/desktop-refresh.sh"
install -Dm644 "$SRC_DIR/contrib/virtual-session/sunshine-labwc.service" \
  "$HOME/.config/systemd/user/sunshine-labwc.service"
install -Dm644 "$SRC_DIR/contrib/virtual-session/sunshine.service" \
  "$HOME/.config/systemd/user/sunshine.service"

# Build and install the uinput -> labwc virtual-input bridge (also installs
# prism-input-bridge.service and runs systemctl --user daemon-reload).
"$SRC_DIR/contrib/virtual-session/build-input-bridge.sh"

# --- 6. apps.json (idempotent merge, with backup) ------------------------------
APPS="$HOME/.config/sunshine/apps.json"
mkdir -p "$HOME/.config/sunshine"
if [ -f "$APPS" ]; then
  cp "$APPS" "$APPS.bak.$(date +%s)"
fi
python3 - <<'EOF'
import json, os
apps_path = os.path.expanduser("~/.config/sunshine/apps.json")
try:
    with open(apps_path) as f: data = json.load(f)
except Exception:
    data = {"env": {"PATH": "$(PATH):$(HOME)/.local/bin"}, "apps": []}
data.setdefault("env", {"PATH": "$(PATH):$(HOME)/.local/bin"})
data.setdefault("apps", [])
data["apps"] = [a for a in data["apps"]
                if a.get("name") not in ("Desktop", "SteamOS (Headless)")]
data["apps"].insert(0, {"name": "Desktop", "image-path": "desktop.png"})
data["apps"].append({
    "name": "SteamOS (Headless)",
    "image-path": "steam.png",
    "prep-cmd": [
        {"do":   "$(HOME)/.local/bin/steamos-start.sh",
         "undo": "$(HOME)/.local/bin/steamos-stop.sh"}
    ]
})
with open(apps_path, "w") as f:
    json.dump(data, f, indent=2)
print("apps.json updated")
EOF

# --- 7. Enable services --------------------------------------------------------
log "Enabling services"
systemctl --user daemon-reload
systemctl --user enable --now sunshine-labwc.service
systemctl --user enable --now sunshine.service

log "Done. Open https://$(hostname -I | awk '{print $1}'):47990 to pair Moonlight."
log "Apps available: 'Desktop' (dynamic client settings) and 'SteamOS (Headless)'."
