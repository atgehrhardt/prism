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

for payload in prism-audio-common.sh prism-session-cleanup.sh; do
  grep -Fq "$payload" "$INSTALLER"
  grep -Fq "$payload" "$LINUX_CMAKE"
done
grep -Fq 'prism-labwc-link-socket.sh' "$INSTALLER"
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
