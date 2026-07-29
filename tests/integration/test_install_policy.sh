#!/usr/bin/env bash
# Verify optional-Steam policy and recovery payload/service wiring.
set -euo pipefail

SOURCE_DIR="${1:?source directory required}"
INSTALLER="$SOURCE_DIR/install.sh"
README="$SOURCE_DIR/README.md"
NATIVE_SERVICE="$SOURCE_DIR/contrib/virtual-session/prism.service"
SERVICE_TEMPLATE="$SOURCE_DIR/packaging/linux/app-dev.lizardbyte.app.Prism.service.in"
APP_RUN="$SOURCE_DIR/packaging/linux/AppImage/AppRun"
LINUX_CMAKE="$SOURCE_DIR/cmake/packaging/linux.cmake"
LINUX_BUILD="$SOURCE_DIR/scripts/linux_build.sh"
MAIN_CPP="$SOURCE_DIR/src/main.cpp"

DNF_TRANSACTION="$(
  sed -n '/^sudo dnf install -y /,/^$/p' "$INSTALLER"
)"
if printf '%s\n' "$DNF_TRANSACTION" | grep -Eq '(^|[[:space:]\\])steam([[:space:]\\]|$)'; then
  echo "Steam remains in the unconditional Fedora dependency transaction" >&2
  exit 1
fi
grep -Eqi 'Steam.*optional|optional.*Steam' "$README"
grep -Fq 'RPM Fusion' "$README"

grep -Fq 'ExecStopPost=%h/.local/bin/prism-session-cleanup.sh' "$NATIVE_SERVICE"
grep -Fq '@PRISM_SERVICE_CLEANUP_COMMAND@' "$SERVICE_TEMPLATE"
grep -Fq 'xsession-cleanup' "$APP_RUN"
grep -Fq 'exit 64' "$APP_RUN"

for payload in \
  prism-audio-common.sh \
  prism-headless-session.sh \
  prism-headless-steam-session.sh \
  prism-session-cleanup.sh \
  prism-virtual-common.sh; do
  grep -Fq "$payload" "$INSTALLER"
  grep -Fq "$payload" "$LINUX_CMAKE"
done
for labwc_component in \
  prism-input-bridge \
  prism-input-bridge.service \
  prism-headless-steam.service \
  labwc \
  wlr-randr \
  xorg-x11-server-Xwayland; do
  grep -Fq "$labwc_component" "$INSTALLER"
done
grep -Fq 'add_executable(prism-input-bridge' \
  "$SOURCE_DIR/cmake/compile_definitions/linux.cmake"
grep -Fq 'wlr-virtual-pointer-unstable-v1' \
  "$SOURCE_DIR/cmake/compile_definitions/linux.cmake"
grep -Fq 'virtual-keyboard-unstable-v1' \
  "$SOURCE_DIR/cmake/compile_definitions/linux.cmake"
grep -Fq 'PkgConfig::XKBCOMMON' \
  "$SOURCE_DIR/cmake/compile_definitions/linux.cmake"
ARCH_BUILD_DEPS="$(sed -n '/^function add_arch_deps()/,/^}/p' "$LINUX_BUILD")"
DEBIAN_BUILD_DEPS="$(sed -n '/^function add_debian_based_deps()/,/^}/p' "$LINUX_BUILD")"
FEDORA_BUILD_DEPS="$(sed -n '/^function add_fedora_deps()/,/^}/p' "$LINUX_BUILD")"
grep -Fq "'libxkbcommon'" <<< "$ARCH_BUILD_DEPS"
grep -Fq '"libxkbcommon-dev"' <<< "$DEBIAN_BUILD_DEPS"
grep -Fq '"libxkbcommon-devel"' <<< "$FEDORA_BUILD_DEPS"
grep -Fq 'systemctl --user restart prism.service' "$INSTALLER"
grep -Fq 'disable --now prism-input-bridge.service prism-labwc.service' "$INSTALLER"
if grep -Eq 'prism-labwc-link-socket.sh.*install -D|enable .*prism-(labwc|input-bridge)' "$INSTALLER"; then
  echo "Installer still installs or enables a persistent headless helper" >&2
  exit 1
fi
if grep -Fq 'prism-labwc-link-socket.sh' "$LINUX_CMAKE"; then
  echo "CMake packaging still includes the obsolete labwc helper" >&2
  exit 1
fi
if grep -Eiq 'gamescope-pipewire|prism-gamescope-query|libei-1[.]0' \
  "$SOURCE_DIR/cmake/compile_definitions/linux.cmake" "$LINUX_CMAKE"; then
  echo "Build or packaging still contains a direct-gamescope component" >&2
  exit 1
fi
if grep -Fq 'reset --hard' "$INSTALLER"; then
  echo "Installer still destructively resets an existing checkout" >&2
  exit 1
fi
grep -Fq 'status --porcelain --untracked-files=all' "$INSTALLER"

APPDIR_TEST="$(mktemp -d)"
trap 'rm -rf "$APPDIR_TEST"' EXIT
mkdir -p "$APPDIR_TEST/usr/libexec/prism"
cp "$APP_RUN" "$APPDIR_TEST/AppRun"
printf '%s\n' '#!/usr/bin/env bash' 'exit 27' \
  > "$APPDIR_TEST/usr/libexec/prism/prism-session-cleanup.sh"
chmod +x "$APPDIR_TEST/AppRun" \
  "$APPDIR_TEST/usr/libexec/prism/prism-session-cleanup.sh"
set +e
"$APPDIR_TEST/AppRun" --internal session-cleanup
valid_status=$?
"$APPDIR_TEST/AppRun" --internal anything-else
invalid_status=$?
"$APPDIR_TEST/AppRun" --internal session-cleanup extra
extra_status=$?
set -e
[ "$valid_status" -eq 27 ]
[ "$invalid_status" -eq 64 ]
[ "$extra_status" -eq 64 ]

command_line="$(grep -n 'if (!config::prism.cmd.name.empty())' "$MAIN_CPP" | cut -d: -f1)"
cleanup_line="$(grep -n 'proc::reconcile_stale_capture_state()' "$MAIN_CPP" | cut -d: -f1)"
display_line="$(grep -n 'display_device::init' "$MAIN_CPP" | head -1 | cut -d: -f1)"
platform_line="$(grep -n 'platf::init()' "$MAIN_CPP" | head -1 | cut -d: -f1)"
input_line="$(grep -n 'input::init()' "$MAIN_CPP" | head -1 | cut -d: -f1)"
http_line="$(grep -n 'http::init()' "$MAIN_CPP" | head -1 | cut -d: -f1)"
[ "$command_line" -lt "$cleanup_line" ]
for subsystem_line in "$display_line" "$platform_line" "$input_line" "$http_line"; do
  [ "$cleanup_line" -lt "$subsystem_line" ]
done
