#!/usr/bin/env bash
# Exercise crash-recovery reconciliation with synthetic system and audio state.
set -euo pipefail

SOURCE_DIR="${1:?source directory required}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export PATH="$TEST_ROOT/bin:$PATH"
export HOME="$TEST_ROOT/home"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
export PRISM_SESSION_DIR="$SOURCE_DIR/contrib/virtual-session"
export PRISM_SYS_ROOT="$TEST_ROOT/sys"
export PRISM_PROC_ROOT="$TEST_ROOT/proc"
export PRISM_RECOVERY_LOG="$TEST_ROOT/recovery.log"
export PRISM_INPUT_WAIT_ATTEMPTS=1
export PRISM_TEST_MODULES="$TEST_ROOT/modules"
export PRISM_TEST_SINKS="$TEST_ROOT/sinks"
export PRISM_TEST_OUTPUTS="$TEST_ROOT/outputs"
export PRISM_TEST_VIRTUAL_MONITOR="$TEST_ROOT/virtual-monitor"
export PRISM_TEST_VIRTUAL_AUDIO_GUARD="$TEST_ROOT/virtual-audio-guard"
export PRISM_TEST_MIRROR_WATCHDOG="$TEST_ROOT/mirror-watchdog"
mkdir -p "$TEST_ROOT/bin" "$HOME/.config/prism" "$XDG_RUNTIME_DIR" \
  "$PRISM_SYS_ROOT/class/input" "$PRISM_PROC_ROOT"
: > "$PRISM_TEST_MODULES"
printf '%s\n' $'1\tphysical-speakers' > "$PRISM_TEST_SINKS"
printf '%s\n' 'DP-1 enabled' 'HDMI-A-1 disabled' > "$PRISM_TEST_OUTPUTS"

cat > "$TEST_ROOT/bin/pactl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  "list short modules")
    cat "$PRISM_TEST_MODULES"
    ;;
  "list short sinks")
    cat "$PRISM_TEST_SINKS"
    ;;
  "get-default-sink  ")
    printf '%s\n' "physical-speakers"
    ;;
  "set-default-sink "*)
    exit 0
    ;;
  "unload-module "*)
    module="${2:?module required}"
    if [ "${PRISM_TEST_FAIL_UNLOAD:-}" = "$module" ]; then
      exit 1
    fi
    module_line="$(awk -v wanted="$module" '$1 == wanted {print; exit}' "$PRISM_TEST_MODULES")"
    awk -v unwanted="$module" '$1 != unwanted' "$PRISM_TEST_MODULES" \
      > "$PRISM_TEST_MODULES.tmp"
    mv "$PRISM_TEST_MODULES.tmp" "$PRISM_TEST_MODULES"
    case "$module_line" in
      *"sink_name=prism-headless"*)
        awk '$2 != "prism-headless"' "$PRISM_TEST_SINKS" > "$PRISM_TEST_SINKS.tmp"
        mv "$PRISM_TEST_SINKS.tmp" "$PRISM_TEST_SINKS"
        ;;
      *"sink_name=prism-virtual"*)
        awk '$2 != "prism-virtual"' "$PRISM_TEST_SINKS" > "$PRISM_TEST_SINKS.tmp"
        mv "$PRISM_TEST_SINKS.tmp" "$PRISM_TEST_SINKS"
        ;;
    esac
    ;;
  *)
    exit 2
    ;;
esac
EOF

cat > "$TEST_ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "--user show-environment")
    exit 0
    ;;
  *"--property=ActiveState --value")
    printf '%s\n' inactive
    ;;
  *"--property=ControlGroup --value")
    printf '\n'
    ;;
  "--user list-units"*)
    exit 0
    ;;
  *)
    exit 0
    ;;
esac
EOF

cat > "$TEST_ROOT/bin/kscreen-doctor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-o" ]; then
  index=1
  while read -r name status; do
    printf 'Output: %s %s synthetic\n\t%s\n' "$index" "$name" "$status"
    index=$((index + 1))
  done < "$PRISM_TEST_OUTPUTS"
  if [ -e "$PRISM_TEST_VIRTUAL_MONITOR" ]; then
    printf 'Output: %s Virtual-Prism-Virtual synthetic\n\tenabled\n' "$index"
  fi
  exit 0
fi
case "${1:-}" in
  output.*.enable)
    output="${1#output.}"
    output="${output%.enable}"
    if [ "${PRISM_TEST_FAIL_OUTPUT:-}" = "$output" ]; then
      exit 1
    fi
    awk -v wanted="$output" '{$2 = ($1 == wanted ? "enabled" : $2); print}' \
      "$PRISM_TEST_OUTPUTS" > "$PRISM_TEST_OUTPUTS.tmp"
    mv "$PRISM_TEST_OUTPUTS.tmp" "$PRISM_TEST_OUTPUTS"
    ;;
esac
EOF

cat > "$TEST_ROOT/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"krfb-virtualmonitor"*)
    [ -e "$PRISM_TEST_VIRTUAL_MONITOR" ] && printf '%s\n' 4242
    ;;
  *"prism-virtual-audio.sh"*)
    [ -e "$PRISM_TEST_VIRTUAL_AUDIO_GUARD" ] && printf '%s\n' 4243
    ;;
  *"prism-mirror-audio.sh"*"prism-mirror-watchdog"*)
    [ -e "$PRISM_TEST_MIRROR_WATCHDOG" ] && printf '%s\n' 4244
    ;;
  *)
    exit 1
    ;;
esac
EOF

cat > "$TEST_ROOT/bin/pkill" <<'EOF'
#!/usr/bin/env bash
case "$*" in
  *"krfb-virtualmonitor"*) rm -f "$PRISM_TEST_VIRTUAL_MONITOR" ;;
  *"prism-virtual-audio.sh"*) rm -f "$PRISM_TEST_VIRTUAL_AUDIO_GUARD" ;;
  *"prism-mirror-audio.sh"*"prism-mirror-watchdog"*)
    rm -f "$PRISM_TEST_MIRROR_WATCHDOG"
    ;;
esac
exit 0
EOF

cat > "$TEST_ROOT/bin/udevadm" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$TEST_ROOT/bin/"*

CLEANUP="$SOURCE_DIR/contrib/virtual-session/prism-session-cleanup.sh"

# A clean startup is a no-op, and repeated cleanup remains successful.
"$CLEANUP"
"$CLEANUP"

# Detached audio processes are reconciled even if their state writes never
# completed.
touch "$PRISM_TEST_VIRTUAL_AUDIO_GUARD" "$PRISM_TEST_MIRROR_WATCHDOG"
"$CLEANUP"
[ ! -e "$PRISM_TEST_VIRTUAL_AUDIO_GUARD" ]
[ ! -e "$PRISM_TEST_MIRROR_WATCHDOG" ]

# Recover committed headless state, duplicate routes, and both session sinks.
cat > "$XDG_RUNTIME_DIR/prism-headless.state" <<EOF
version=2
session_id=42
backend=systemd
unit=prism-headless-session.service
app_unit=prism-headless-app-42.scope
steam=0
wayland_display=gamescope-7
x_display=:9
physical_sink=physical-speakers
capture_sink_module=
session_sink_module=30
loop_module=31
EOF
cat > "$XDG_RUNTIME_DIR/prism-headless-audio.state" <<EOF
loop_module=31
physical_sink=physical-speakers
EOF
cat > "$PRISM_TEST_MODULES" <<EOF
30	module-null-sink	sink_name=prism-headless
31	module-loopback	source=prism-headless.monitor sink=prism-stream
32	module-loopback	source=prism-headless.monitor sink=prism-stream
33	module-null-sink	sink_name=prism-virtual
34	module-loopback	source=prism-virtual.monitor sink=prism-stream
35	module-null-sink	sink_name=user-sink
36	module-loopback	source=user.monitor sink=user-sink
EOF
printf '%s\n' \
  $'1\tphysical-speakers' \
  $'2\tprism-headless' \
  $'3\tprism-virtual' > "$PRISM_TEST_SINKS"
"$CLEANUP"
[ ! -e "$XDG_RUNTIME_DIR/prism-headless.state" ]
[ ! -e "$XDG_RUNTIME_DIR/prism-headless-audio.state" ]
awk '$1 == 35 || $1 == 36 {preserved++} END {exit preserved == 2 ? 0 : 1}' \
  "$PRISM_TEST_MODULES"

# Failed module removal keeps ownership evidence and blocks startup until a
# later retry completes.
cat > "$XDG_RUNTIME_DIR/prism-headless-audio.state" <<EOF
loop_module=40
physical_sink=physical-speakers
EOF
printf '%s\n' \
  $'40\tmodule-loopback\tsource=prism-headless.monitor sink=prism-stream' \
  > "$PRISM_TEST_MODULES"
export PRISM_TEST_FAIL_UNLOAD=40
if "$CLEANUP"; then
  echo "cleanup accepted a failed audio module unload" >&2
  exit 1
fi
[ -e "$XDG_RUNTIME_DIR/prism-headless-audio.state" ]
unset PRISM_TEST_FAIL_UNLOAD
"$CLEANUP"
[ ! -e "$XDG_RUNTIME_DIR/prism-headless-audio.state" ]

# A failed output restoration retains only the failed entry for retry. An
# intentionally disabled, unrecorded HDMI output must stay disabled.
printf '%s\n' \
  'DP-1 disabled' \
  'eDP-1 disabled' \
  'HDMI-A-1 disabled' > "$PRISM_TEST_OUTPUTS"
printf '%s\n' 'DP-1' 'eDP-1' > "$XDG_RUNTIME_DIR/prism-virtual-desktop.state"
touch "$PRISM_TEST_VIRTUAL_MONITOR"
export PRISM_TEST_FAIL_OUTPUT=DP-1
if "$CLEANUP"; then
  echo "cleanup accepted an un-restored physical output" >&2
  exit 1
fi
[ "$(cat "$XDG_RUNTIME_DIR/prism-virtual-desktop.state")" = "DP-1" ]
grep -qx 'eDP-1 enabled' "$PRISM_TEST_OUTPUTS"
grep -qx 'HDMI-A-1 disabled' "$PRISM_TEST_OUTPUTS"
unset PRISM_TEST_FAIL_OUTPUT

# Retry restores the retained output and removes the virtual monitor/output.
"$CLEANUP"
grep -qx 'DP-1 enabled' "$PRISM_TEST_OUTPUTS"
grep -qx 'HDMI-A-1 disabled' "$PRISM_TEST_OUTPUTS"
[ ! -e "$XDG_RUNTIME_DIR/prism-virtual-desktop.state" ]
[ ! -e "$PRISM_TEST_VIRTUAL_MONITOR" ]

# A kernel input device with a Prism-supported exact name blocks startup.
mkdir -p "$PRISM_SYS_ROOT/class/input/event9/device"
printf '%s\n' 'Prism PS5 (virtual) pad' \
  > "$PRISM_SYS_ROOT/class/input/event9/device/name"
if "$CLEANUP"; then
  echo "cleanup accepted a remaining Prism virtual input device" >&2
  exit 1
fi
rm -rf "$PRISM_SYS_ROOT/class/input/event9"
mkdir -p "$PRISM_SYS_ROOT/class/input/event10/device"
printf '%s\n' 'Prism PS5 (virtual) padding' \
  > "$PRISM_SYS_ROOT/class/input/event10/device/name"
"$CLEANUP"
printf '%s\n' 'Prism PS5 (virtual) pad (seat1)' \
  > "$PRISM_SYS_ROOT/class/input/event10/device/name"
if "$CLEANUP"; then
  echo "cleanup accepted a seat-scoped Prism virtual input device" >&2
  exit 1
fi
