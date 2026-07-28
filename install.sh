#!/usr/bin/env bash
# Prism — one-command install for Fedora.
#   curl -fsSL https://raw.githubusercontent.com/atgehrhardt/prism/master/install.sh | bash
set -euo pipefail

REPO="https://github.com/atgehrhardt/prism.git"
BRANCH="master"
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
  wayland-devel libxkbcommon-devel python3-jinja2 bubblewrap \
  gamescope labwc wlr-randr kscreen krfb mangohud

# --- 2. Source --------------------------------------------------------------
if [ -d "$SRC_DIR/.git" ]; then
  if [ -n "$(git -C "$SRC_DIR" status --porcelain --untracked-files=all)" ]; then
    log "Using existing checkout in $SRC_DIR without updating because it has local changes"
  else
    log "Updating existing checkout in $SRC_DIR"
    git -C "$SRC_DIR" fetch origin "$BRANCH"
    git -C "$SRC_DIR" checkout "$BRANCH"
    git -C "$SRC_DIR" merge --ff-only "origin/$BRANCH"
  fi
  git -C "$SRC_DIR" submodule update --init --recursive
else
  log "Cloning Prism into $SRC_DIR"
  git clone --branch "$BRANCH" --recurse-submodules "$REPO" "$SRC_DIR"
fi

# --- 3. Build ----------------------------------------------------------------
log "Building Prism (this takes a while)"
# Enable CUDA (NVIDIA DMA-BUF/nvenc path) only when a CUDA toolkit is present;
# on AMD/Intel systems Prism simply builds without it.
CUDA_FLAG="OFF"
CUDA_COMPILER_FLAG=""
if command -v nvcc >/dev/null; then
  CUDA_FLAG="ON"
elif [ -x /usr/local/cuda/bin/nvcc ]; then
  CUDA_FLAG="ON"
  CUDA_COMPILER_FLAG="-DCMAKE_CUDA_COMPILER=/usr/local/cuda/bin/nvcc"
fi
# Newer distros ship a GCC newer than nvcc supports; permit it (Prism's CUDA
# code is small and builds fine in practice).
if [ "$CUDA_FLAG" = "ON" ]; then
  CUDA_COMPILER_FLAG="$CUDA_COMPILER_FLAG -DCMAKE_CUDA_FLAGS=-allow-unsupported-compiler"
fi
read -r -a CUDA_FLAGS <<< "$CUDA_COMPILER_FLAG"
cmake -S "$SRC_DIR" -B "$SRC_DIR/cmake-build-prism" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_INSTALL_PREFIX="$HOME/.local" \
  -DPRISM_ENABLE_CUDA="$CUDA_FLAG" \
  "${CUDA_FLAGS[@]}" \
  -DCUDA_FAIL_ON_MISSING=OFF \
  -DBUILD_DOCS=OFF -DBUILD_TESTS=OFF
cmake --build "$SRC_DIR/cmake-build-prism" --parallel "$BUILD_JOBS"

# --- 4. Install --------------------------------------------------------------
log "Installing to ~/.local"
# shellcheck disable=SC1007 # intentional empty DESTDIR env prefix
DESTDIR= cmake --install "$SRC_DIR/cmake-build-prism" --prefix "$HOME/.local" 2>/dev/null || {
  # Fallback: install the binary and assets manually
  install -Dm755 "$SRC_DIR/cmake-build-prism/prism" "$HOME/.local/bin/prism"
  if [ -d "$SRC_DIR/cmake-build-prism/assets" ]; then
    rm -rf "$HOME/.local/assets"
    cp -r "$SRC_DIR/cmake-build-prism/assets" "$HOME/.local/assets"
  fi
}

# --- 5. Session stack ---------------------------------------------------------
log "Installing Prism scripts and systemd user units"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-steamos-start.sh"   "$HOME/.local/bin/prism-steamos-start.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-steamos-stop.sh"    "$HOME/.local/bin/prism-steamos-stop.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-audio-common.sh"    "$HOME/.local/bin/prism-audio-common.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-headless-common.sh" "$HOME/.local/bin/prism-headless-common.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-headless-exec.sh"   "$HOME/.local/bin/prism-headless-exec.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-headless-start.sh"  "$HOME/.local/bin/prism-headless-start.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-headless-stop.sh"   "$HOME/.local/bin/prism-headless-stop.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-headless-session.sh" "$HOME/.local/bin/prism-headless-session.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-headless-steam.sh"  "$HOME/.local/bin/prism-headless-steam.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-headless-audio.sh"  "$HOME/.local/bin/prism-headless-audio.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-steam-game.sh"      "$HOME/.local/bin/prism-steam-game.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-steam-restore.sh"   "$HOME/.local/bin/prism-steam-restore.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-virtual-start.sh"   "$HOME/.local/bin/prism-virtual-start.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-virtual-stop.sh"    "$HOME/.local/bin/prism-virtual-stop.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-virtual-audio.sh"   "$HOME/.local/bin/prism-virtual-audio.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-mirror-audio.sh"    "$HOME/.local/bin/prism-mirror-audio.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-session-cleanup.sh" "$HOME/.local/bin/prism-session-cleanup.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-desktop-session.sh" "$HOME/.local/bin/prism-desktop-session.sh"
install -Dm755 "$SRC_DIR/contrib/virtual-session/prism-labwc-link-socket.sh" "$HOME/.local/bin/prism-labwc-link-socket.sh"
install -Dm644 "$SRC_DIR/contrib/virtual-session/prism-labwc.service" \
  "$HOME/.config/systemd/user/prism-labwc.service"
install -Dm644 "$SRC_DIR/contrib/virtual-session/prism-headless-session.service" \
  "$HOME/.config/systemd/user/prism-headless-session.service"
install -Dm644 "$SRC_DIR/contrib/virtual-session/prism-steam-restore.service" \
  "$HOME/.config/systemd/user/prism-steam-restore.service"
install -Dm644 "$SRC_DIR/contrib/virtual-session/prism.service" \
  "$HOME/.config/systemd/user/prism.service"

# Build and install the uinput -> labwc virtual-input bridge (also installs
# prism-input-bridge.service and runs systemctl --user daemon-reload).
"$SRC_DIR/contrib/virtual-session/build-input-bridge.sh"
"$SRC_DIR/contrib/virtual-session/build-kwin-mode.sh"

# --- 6. apps.json (idempotent merge, with backup) ------------------------------
APPS="$HOME/.config/prism/apps.json"
mkdir -p "$HOME/.config/prism"
if [ -f "$APPS" ]; then
  cp "$APPS" "$APPS.bak.$(date +%s)"
fi
python3 - <<'EOF'
import json, os
apps_path = os.path.expanduser("~/.config/prism/apps.json")
try:
    with open(apps_path) as f: data = json.load(f)
except Exception:
    data = {"env": {"PATH": "$(PATH):$(HOME)/.local/bin"}, "apps": []}
data.setdefault("env", {"PATH": "$(PATH):$(HOME)/.local/bin"})
data.setdefault("apps", [])
# Remove stock example apps and any previous Prism entries; keep other custom apps.
PRISM_APPS = ("Desktop", "Desktop (Mirror)", "Desktop (Virtual)", "Desktop Headless",
              "Steam Headless", "SteamOS (Headless)", "Low Res Desktop", "Steam Big Picture")
data["apps"] = [a for a in data["apps"] if a.get("name") not in PRISM_APPS]
defaults = [
    ("Desktop (Mirror)", "desktop.png", "default"),
    ("Desktop (Virtual)", "desktop.png", "virtual"),
    ("Desktop Headless", "desktop.png", "headless"),
    ("Steam Headless", "steam.png", "headless"),
]
for i, (name, image, mode) in enumerate(defaults):
    data["apps"].insert(i, {"name": name, "image-path": image, "prism-capture": mode})
with open(apps_path, "w") as f:
    json.dump(data, f, indent=2)
print("apps.json updated")
EOF

# --- 6b. prism.conf: dedicated capture sink --------------------------------
# Point Prism's audio capture at a dedicated "prism-stream" null sink so
# each capture mode can route exactly the right audio into the stream (mirror
# loops the desktop in; virtual/headless route only session audio). Respect an
# audio_sink the user set themselves.
CONF="$HOME/.config/prism/prism.conf"
touch "$CONF"
if ! grep -q '^audio_sink' "$CONF"; then
  log "Setting audio_sink=prism-stream in prism.conf"
  printf '\naudio_sink = prism-stream\n' >> "$CONF"
fi

# --- 7. Enable services --------------------------------------------------------
log "Enabling services"
systemctl --user daemon-reload
# udev rule: read access to Prism's evdev nodes for the input bridge
sudo install -Dm644 "$SRC_DIR/contrib/virtual-session/61-prism-input.rules" \
  /etc/udev/rules.d/61-prism-input.rules && sudo udevadm control --reload

systemctl --user enable prism-labwc.service prism-input-bridge.service prism.service
systemctl --user start prism-labwc.service
systemctl --user start prism-input-bridge.service
systemctl --user start prism.service

log "Done. Open https://$(hostname -I | awk '{print $1}'):47990 to pair Moonlight."
log "Apps available: Desktop (Mirror), Desktop (Virtual), Desktop Headless, Steam Headless."
