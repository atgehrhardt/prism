#!/usr/bin/env bash
## @file
## @brief Build a complete x86_64 Prism AppImage inside the baseline build container.
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BUILD="$ROOT/cmake-build-appimage"
APPDIR="$BUILD/AppDir"
TOOLS="$BUILD/tools"
[ "$(uname -m)" = x86_64 ] || { echo 'AppImage packaging currently requires x86_64.' >&2; exit 1; }
mkdir -p "$BUILD" "$TOOLS"

## @brief Download and verify an immutable packaging tool release.
## @param $1 HTTPS release asset URL.
## @param $2 Expected SHA-256 digest.
## @param $3 Local tool filename.
fetch_tool() {
  curl -fL --retry 3 "$1" -o "$TOOLS/$3"
  printf '%s  %s\n' "$2" "$TOOLS/$3" | sha256sum --check --status
  chmod 755 "$TOOLS/$3"
}
fetch_tool https://github.com/linuxdeploy/linuxdeploy/releases/download/1-alpha-20251107-1/linuxdeploy-x86_64.AppImage \
  c20cd71e3a4e3b80c3483cef793cda3f4e990aca14014d23c544ca3ce1270b4d linuxdeploy.AppImage
fetch_tool https://github.com/linuxdeploy/linuxdeploy-plugin-qt/releases/download/1-alpha-20250213-1/linuxdeploy-plugin-qt-x86_64.AppImage \
  15106be885c1c48a021198e7e1e9a48ce9d02a86dd0a1848f00bdbf3c1c92724 linuxdeploy-plugin-qt.AppImage
fetch_tool https://github.com/AppImage/appimagetool/releases/download/1.9.1/appimagetool-x86_64.AppImage \
  ed4ce84f0d9caff66f50bcca6ff6f35aae54ce8135408b3fa33abfc3cb384eb0 appimagetool.AppImage
fetch_tool https://github.com/AppImage/type2-runtime/releases/download/20251108/runtime-x86_64 \
  2fca8b443c92510f1483a883f60061ad09b46b978b2631c807cd873a47ec260d runtime

cmake -S "$ROOT" -B "$BUILD" -G Ninja \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_INSTALL_PREFIX=/usr -DCMAKE_INSTALL_LIBDIR=lib \
  -DPRISM_ASSETS_DIR=share/prism -DPRISM_SESSION_DIR=/usr/libexec/prism \
  -DPRISM_EXECUTABLE_PATH=/usr/bin/prism -DPRISM_BUILD_APPIMAGE=ON -DPRISM_ENABLE_TRAY=ON \
  -DPRISM_ENABLE_CUDA="${PRISM_ENABLE_CUDA:-ON}" -DCUDA_FAIL_ON_MISSING=ON \
  -DCMAKE_CUDA_HOST_COMPILER=/usr/bin/g++-13 -DCUDA_INHERIT_COMPILE_OPTIONS=OFF \
  -DBUILD_DOCS=OFF -DBUILD_TESTS="${PRISM_BUILD_TESTS:-OFF}"
cmake --build "$BUILD" --parallel "${PRISM_BUILD_JOBS:-2}"
if [ "${PRISM_BUILD_TESTS:-OFF}" = ON ]; then
  xvfb-run -a "$BUILD/tests/test_prism" --gtest_output="xml:$BUILD/test-results.xml"
fi
rm -rf "$APPDIR"
DESTDIR="$APPDIR" cmake --install "$BUILD"
PRISM_INSTALL_PREFIX="$APPDIR/usr" bash "$ROOT/contrib/virtual-session/build-headless-compositor.sh"
PRISM_INSTALL_PREFIX="$APPDIR/usr" bash "$ROOT/contrib/virtual-session/build-kwin-mode.sh"
ln -s prism-labwc "$APPDIR/usr/bin/labwc"
for program in wayland-info wlr-randr pactl; do
  install -Dm755 "$(command -v "$program")" "$APPDIR/usr/bin/$program"
done
# This Xwayland build resolves xkbcomp relative to the AppDir set by its wrapper.
install -Dm755 /opt/prism-deps/bin/Xwayland "$APPDIR/usr/bin/prism-Xwayland"
install -Dm755 "$ROOT/packaging/linux/AppImage/Xwayland" "$APPDIR/usr/bin/Xwayland"
install -Dm755 "$(command -v xkbcomp)" "$APPDIR/usr/bin/xkbcomp"
cp -a /usr/share/X11/xkb "$APPDIR/usr/share/"

# Extract without executing static runtimes, including on emulated build hosts.
for tool in linuxdeploy linuxdeploy-plugin-qt appimagetool; do
  mkdir -p "$TOOLS/$tool"
  rm -rf "$TOOLS/$tool/squashfs-root"
  python3 "$ROOT/packaging/linux/AppImage/extract.py" \
    "$TOOLS/$tool.AppImage" "$TOOLS/$tool/squashfs-root" >/dev/null
done
export PATH="$TOOLS/linuxdeploy-plugin-qt/squashfs-root/usr/bin:$PATH"
export QMAKE=/usr/bin/qmake6
export EXTRA_PLATFORM_PLUGINS='libqwayland-egl.so;libqwayland-generic.so'
export EXTRA_QT_MODULES=waylandcompositor
# These portable libraries are not guaranteed on a minimal Wayland/KDE desktop.
# Keep PipeWire and GPU-driver integration libraries on the host.
PORTABLE_LIBRARIES=()
for dependency in opengl:libOpenGL.so.0 fontconfig:libfontconfig.so.1 \
  freetype2:libfreetype.so.6 harfbuzz:libharfbuzz.so.0 fribidi:libfribidi.so.0 \
  wayland-client:libwayland-client.so.0 wayland-server:libwayland-server.so.0 \
  wayland-cursor:libwayland-cursor.so.0 wayland-egl:libwayland-egl.so.1; do
  package="${dependency%%:*}"
  library="${dependency#*:}"
  PORTABLE_LIBRARIES+=(--library "$(pkg-config --variable=libdir "$package")/$library")
done
"$TOOLS/linuxdeploy/squashfs-root/AppRun" --appdir "$APPDIR" \
  --desktop-file "$BUILD/dev.lizardbyte.app.Prism.desktop" --icon-file "$ROOT/prism.svg" \
  "${PORTABLE_LIBRARIES[@]}" --plugin qt
# Use our dispatcher instead of the generated Qt environment wrapper.
install -m755 "$ROOT/packaging/linux/AppImage/AppRun" "$APPDIR/AppRun"
# Qt finds its own bundled plugins without exporting Qt paths into launched games.
printf '[Paths]\nPrefix=..\nPlugins=plugins\n' > "$APPDIR/usr/bin/qt.conf"
bash "$ROOT/scripts/package-appimage-licenses.sh" "$APPDIR"
"$APPDIR/AppRun" --check
mkdir -p "$BUILD/artifacts"
ARCH=x86_64 "$TOOLS/appimagetool/squashfs-root/AppRun" \
  --runtime-file "$TOOLS/runtime" "$APPDIR" "$BUILD/artifacts/prism-x86_64.AppImage"
(cd "$BUILD/artifacts" && sha256sum prism-x86_64.AppImage > prism-x86_64.AppImage.sha256)
