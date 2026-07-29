#!/usr/bin/env bash
# Exercise fail-fast virtual-display startup and transactional cleanup.
set -euo pipefail

SOURCE_DIR="${1:?source directory required}"
TEST_ROOT="$(mktemp -d)"
ORIGINAL_PATH="$PATH"
cleanup_test_root() {
  local rc=$?

  if [ "$rc" -ne 0 ]; then
    echo "virtual session test failed with status $rc" >&2
    if [ -f "$TEST_ROOT/home/.local/state/prism-virtual.log" ]; then
      echo "virtual session test log:" >&2
      sed -n '1,320p' "$TEST_ROOT/home/.local/state/prism-virtual.log" >&2
    fi
  fi
  rm -rf "$TEST_ROOT"
  exit "$rc"
}
trap cleanup_test_root EXIT
export PATH="$TEST_ROOT/bin:$ORIGINAL_PATH"
export HOME="$TEST_ROOT/home"
export XDG_RUNTIME_DIR="$TEST_ROOT/runtime"
export PRISM_TEST_OUTPUTS="$TEST_ROOT/outputs"
export PRISM_TEST_MODULES="$TEST_ROOT/modules"
export PRISM_TEST_SINKS="$TEST_ROOT/sinks"
export PRISM_TEST_DEFAULT_SINK="$TEST_ROOT/default-sink"
export PRISM_TEST_MONITOR="$TEST_ROOT/virtual-monitor"
export PRISM_TEST_MONITOR_PID="$TEST_ROOT/virtual-monitor.pid"
export PRISM_TEST_AUDIO_PID="$TEST_ROOT/virtual-audio.pid"
export PRISM_TEST_KRFB_ARGS="$TEST_ROOT/krfb-args"
mkdir -p "$TEST_ROOT/bin" "$HOME/.config/prism" "$XDG_RUNTIME_DIR"
printf '%s\n' 'audio_sink = prism-stream' > "$HOME/.config/prism/prism.conf"

cat > "$TEST_ROOT/bin/kscreen-doctor" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = "-o" ]; then
  if [ "${PRISM_TEST_KSCREEN_FAIL:-0}" = "1" ]; then
    exit 1
  fi
  index=1
  while read -r name status; do
    printf 'Output: %s %s synthetic\n\t%s\n' "$index" "$name" "$status"
    index=$((index + 1))
  done < "$PRISM_TEST_OUTPUTS"
  if [ -e "$PRISM_TEST_MONITOR" ]; then
    printf 'Output: %s Virtual-Prism-Virtual synthetic\n\tenabled\n' "$index"
  fi
  exit 0
fi
case "${1:-}" in
  output.*.disable)
    output="${1#output.}"
    output="${output%.disable}"
    if [ "${PRISM_TEST_FAIL_DISABLE_AFTER_CHANGE:-}" = "$output" ]; then
      awk -v wanted="$output" '{$2 = ($1 == wanted ? "disabled" : $2); print}' \
        "$PRISM_TEST_OUTPUTS" > "$PRISM_TEST_OUTPUTS.tmp"
      mv "$PRISM_TEST_OUTPUTS.tmp" "$PRISM_TEST_OUTPUTS"
      exit 1
    fi
    [ "${PRISM_TEST_FAIL_DISABLE:-}" != "$output" ] || exit 1
    awk -v wanted="$output" '{$2 = ($1 == wanted ? "disabled" : $2); print}' \
      "$PRISM_TEST_OUTPUTS" > "$PRISM_TEST_OUTPUTS.tmp"
    mv "$PRISM_TEST_OUTPUTS.tmp" "$PRISM_TEST_OUTPUTS"
    ;;
  output.*.enable)
    output="${1#output.}"
    output="${output%.enable}"
    [ "${PRISM_TEST_FAIL_ENABLE:-}" != "$output" ] || exit 1
    awk -v wanted="$output" '{$2 = ($1 == wanted ? "enabled" : $2); print}' \
      "$PRISM_TEST_OUTPUTS" > "$PRISM_TEST_OUTPUTS.tmp"
    mv "$PRISM_TEST_OUTPUTS.tmp" "$PRISM_TEST_OUTPUTS"
    ;;
esac
EOF

cat > "$TEST_ROOT/bin/krfb-virtualmonitor" <<'EOF'
#!/usr/bin/env bash
set -u
printf '%s\n' "$*" > "$PRISM_TEST_KRFB_ARGS"
printf '%s\n' "$$" > "$PRISM_TEST_MONITOR_PID"
cleanup() {
  rm -f "$PRISM_TEST_MONITOR" "$PRISM_TEST_MONITOR_PID"
}
trap cleanup EXIT INT TERM
case "${PRISM_TEST_KRFB_SCENARIO:-success}" in
  exit) exit 7 ;;
  no-output) ;;
  success) touch "$PRISM_TEST_MONITOR" ;;
  *) exit 8 ;;
esac
while :; do
  sleep 1
done
EOF

cat > "$TEST_ROOT/bin/setsid" <<'EOF'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  *prism-virtual-audio.sh)
    "$@" &
    child_pid=$!
    printf '%s %s\n' "$$" "$child_pid" > "$PRISM_TEST_AUDIO_PID"
    cleanup_audio() {
      kill -TERM "$child_pid" 2>/dev/null || true
      wait "$child_pid" 2>/dev/null || true
      rm -f "$PRISM_TEST_AUDIO_PID"
    }
    trap 'cleanup_audio; exit 143' TERM INT
    wait "$child_pid"
    status=$?
    rm -f "$PRISM_TEST_AUDIO_PID"
    exit "$status"
    ;;
esac
exec "$@"
EOF

cat > "$TEST_ROOT/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
  *krfb-virtualmonitor*)
    pid_file="$PRISM_TEST_MONITOR_PID"
    ;;
  *prism-virtual-audio.sh*)
    pid_file="$PRISM_TEST_AUDIO_PID"
    ;;
  *)
    exit 1
    ;;
esac
[ -r "$pid_file" ] || exit 1
read -r pid _ < "$pid_file"
kill -0 "$pid" 2>/dev/null || exit 1
printf '%s\n' "$pid"
EOF

cat > "$TEST_ROOT/bin/pkill" <<'EOF'
#!/usr/bin/env bash
set -u
case "$*" in
  *krfb-virtualmonitor*) pid_file="$PRISM_TEST_MONITOR_PID" ;;
  *prism-virtual-audio.sh*) pid_file="$PRISM_TEST_AUDIO_PID" ;;
  *) exit 0 ;;
esac
if [ -r "$pid_file" ]; then
  read -r pid child_pid < "$pid_file"
  signal=TERM
  case " $* " in *" -KILL "* | *" -9 "*) signal=KILL ;; esac
  kill "-$signal" "$pid" 2>/dev/null || true
  [ -z "${child_pid:-}" ] || kill "-$signal" "$child_pid" 2>/dev/null || true
fi
exit 0
EOF

cat > "$TEST_ROOT/bin/pactl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-}" in
  "list short")
    case "${3:-}" in
      modules) cat "$PRISM_TEST_MODULES" ;;
      sinks) cat "$PRISM_TEST_SINKS" ;;
      sink-inputs) : ;;
      *) exit 2 ;;
    esac
    ;;
  "list sink-inputs")
    :
    ;;
  "get-default-sink ")
    cat "$PRISM_TEST_DEFAULT_SINK"
    ;;
  "set-default-sink "*)
    printf '%s\n' "${2:?sink required}" > "$PRISM_TEST_DEFAULT_SINK"
    ;;
  "load-module module-null-sink")
    if printf '%s\n' "$*" | grep -q 'sink_name=prism-stream'; then
      module=10
      sink=prism-stream
    else
      module=20
      sink=prism-virtual
    fi
    if ! awk -v wanted="$module" '$1 == wanted {found=1} END {exit found ? 0 : 1}' \
      "$PRISM_TEST_MODULES"; then
      printf '%s\tmodule-null-sink\tsink_name=%s\n' "$module" "$sink" \
        >> "$PRISM_TEST_MODULES"
    fi
    if ! awk -v wanted="$sink" '$2 == wanted {found=1} END {exit found ? 0 : 1}' \
      "$PRISM_TEST_SINKS"; then
      printf '2\t%s\n' "$sink" >> "$PRISM_TEST_SINKS"
    fi
    printf '%s\n' "$module"
    ;;
  "load-module module-loopback")
    printf '%s\tmodule-loopback\t%s\n' 21 "${*:3}" >> "$PRISM_TEST_MODULES"
    printf '%s\n' 21
    ;;
  "unload-module "*)
    module="${2:?module required}"
    module_line="$(awk -v wanted="$module" '$1 == wanted {print; exit}' "$PRISM_TEST_MODULES")"
    awk -v unwanted="$module" '$1 != unwanted' "$PRISM_TEST_MODULES" \
      > "$PRISM_TEST_MODULES.tmp"
    mv "$PRISM_TEST_MODULES.tmp" "$PRISM_TEST_MODULES"
    case "$module_line" in
      *sink_name=prism-virtual*)
        awk '$2 != "prism-virtual"' "$PRISM_TEST_SINKS" > "$PRISM_TEST_SINKS.tmp"
        mv "$PRISM_TEST_SINKS.tmp" "$PRISM_TEST_SINKS"
        ;;
    esac
    ;;
  "suspend-sink "* | "suspend-source "* | "move-sink-input "*)
    :
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/"*

START="$SOURCE_DIR/contrib/virtual-session/prism-virtual-start.sh"
STOP="$SOURCE_DIR/contrib/virtual-session/prism-virtual-stop.sh"

reset_fixture() {
  if [ -r "$PRISM_TEST_MONITOR_PID" ]; then
    monitor_pid="$(cat "$PRISM_TEST_MONITOR_PID")"
    kill -TERM "$monitor_pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      kill -0 "$monitor_pid" 2>/dev/null || break
      sleep 0.01
    done
    kill -KILL "$monitor_pid" 2>/dev/null || true
  fi
  if [ -r "$PRISM_TEST_AUDIO_PID" ]; then
    read -r audio_pid audio_child_pid < "$PRISM_TEST_AUDIO_PID"
    kill -TERM "$audio_pid" "$audio_child_pid" 2>/dev/null || true
    for _ in $(seq 1 100); do
      if ! kill -0 "$audio_pid" 2>/dev/null &&
        ! kill -0 "$audio_child_pid" 2>/dev/null; then
        break
      fi
      sleep 0.01
    done
    kill -KILL "$audio_pid" "$audio_child_pid" 2>/dev/null || true
  fi
  rm -f "$XDG_RUNTIME_DIR"/prism-* "$PRISM_TEST_MONITOR" \
    "$PRISM_TEST_MONITOR_PID" "$PRISM_TEST_AUDIO_PID" "$PRISM_TEST_KRFB_ARGS"
  printf '%s\n' 'DP-1 enabled' 'HDMI-A-1 disabled' > "$PRISM_TEST_OUTPUTS"
  : > "$PRISM_TEST_MODULES"
  printf '%s\n' $'1\tphysical-speakers' $'2\tprism-stream' > "$PRISM_TEST_SINKS"
  printf '%s\n' physical-speakers > "$PRISM_TEST_DEFAULT_SINK"
  unset PRISM_TEST_FAIL_DISABLE PRISM_TEST_FAIL_DISABLE_AFTER_CHANGE \
    PRISM_TEST_FAIL_ENABLE PRISM_TEST_KSCREEN_FAIL
}

# A complete session uses the trusted desktop entry and restores only outputs
# that were enabled before capture.
reset_fixture
export PRISM_TEST_KRFB_SCENARIO=success
PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS=2 "$START"
grep -Fq -- '--name Prism-Virtual --desktopfile org.kde.krfb.virtualmonitor' \
  "$PRISM_TEST_KRFB_ARGS"
grep -qx 'DP-1' "$XDG_RUNTIME_DIR/prism-virtual-desktop.state"
grep -qx 'DP-1 disabled' "$PRISM_TEST_OUTPUTS"
grep -qx 'HDMI-A-1 disabled' "$PRISM_TEST_OUTPUTS"
[ "$(cat "$XDG_RUNTIME_DIR/prism-capture-override")" = "portal:Virtual-Prism-Virtual" ]
"$STOP"
grep -qx 'DP-1 enabled' "$PRISM_TEST_OUTPUTS"
grep -qx 'HDMI-A-1 disabled' "$PRISM_TEST_OUTPUTS"
[ ! -e "$XDG_RUNTIME_DIR/prism-virtual-desktop.state" ]
[ ! -e "$PRISM_TEST_MONITOR" ]

# A monitor that remains alive without publishing an output fails under one
# wall-clock deadline and creates no audio, override, or display state.
reset_fixture
export PRISM_TEST_KRFB_SCENARIO=no-output
start_millis="$(date +%s%3N)"
if PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS=2 "$START"; then
  echo "virtual startup accepted a missing KScreen output" >&2
  exit 1
fi
elapsed_millis=$(( $(date +%s%3N) - start_millis ))
[ "$elapsed_millis" -lt 5000 ]
[ ! -e "$XDG_RUNTIME_DIR/prism-capture-override" ]
[ ! -e "$XDG_RUNTIME_DIR/prism-virtual-desktop.state" ]
[ ! -e "$PRISM_TEST_AUDIO_PID" ]
[ ! -e "$PRISM_TEST_MONITOR" ]

# Repeated invalid KScreen snapshots produce the distinct bounded diagnostic
# and still remove the owned monitor.
reset_fixture
export PRISM_TEST_KRFB_SCENARIO=no-output
export PRISM_TEST_KSCREEN_FAIL=1
start_millis="$(date +%s%3N)"
if PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS=2 "$START"; then
  echo "virtual startup accepted repeated KScreen failures" >&2
  exit 1
fi
elapsed_millis=$(( $(date +%s%3N) - start_millis ))
[ "$elapsed_millis" -lt 5000 ]
grep -Fq 'ERROR: KScreen failed' "$HOME/.local/state/prism-virtual.log"
[ ! -e "$PRISM_TEST_MONITOR" ]
[ ! -e "$XDG_RUNTIME_DIR/prism-capture-override" ]

# A Krfb process that exits during startup is rejected immediately.
reset_fixture
export PRISM_TEST_KRFB_SCENARIO=exit
start_millis="$(date +%s%3N)"
if PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS=2 "$START"; then
  echo "virtual startup accepted an exited Krfb process" >&2
  exit 1
fi
elapsed_millis=$(( $(date +%s%3N) - start_millis ))
[ "$elapsed_millis" -lt 3000 ]

# Failure after state capture rolls back audio, monitor, override, and exactly
# the recorded physical output.
reset_fixture
export PRISM_TEST_KRFB_SCENARIO=success
export PRISM_TEST_FAIL_DISABLE_AFTER_CHANGE=DP-1
if PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS=2 "$START"; then
  echo "virtual startup accepted a failed physical-output transition" >&2
  exit 1
fi
grep -qx 'DP-1 enabled' "$PRISM_TEST_OUTPUTS"
grep -qx 'HDMI-A-1 disabled' "$PRISM_TEST_OUTPUTS"
[ ! -e "$XDG_RUNTIME_DIR/prism-virtual-desktop.state" ]
[ ! -e "$XDG_RUNTIME_DIR/prism-capture-override" ]
[ ! -e "$PRISM_TEST_MONITOR" ]

# An unverified output restoration preserves only its recovery entry.
reset_fixture
export PRISM_TEST_KRFB_SCENARIO=success
export PRISM_TEST_FAIL_DISABLE_AFTER_CHANGE=DP-1
export PRISM_TEST_FAIL_ENABLE=DP-1
if PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS=2 "$START"; then
  echo "virtual startup accepted an incomplete rollback" >&2
  exit 1
fi
[ "$(cat "$XDG_RUNTIME_DIR/prism-virtual-desktop.state")" = "DP-1" ]
unset PRISM_TEST_FAIL_ENABLE PRISM_TEST_FAIL_DISABLE_AFTER_CHANGE
"$STOP"
[ ! -e "$XDG_RUNTIME_DIR/prism-virtual-desktop.state" ]

# TERM during readiness waiting returns promptly and executes rollback.
reset_fixture
export PRISM_TEST_KRFB_SCENARIO=no-output
PRISM_TEST_VIRTUAL_READY_TIMEOUT_SECONDS=10 "$START" &
START_PID=$!
for _ in $(seq 1 100); do
  [ -e "$PRISM_TEST_MONITOR_PID" ] && break
  sleep 0.01
done
[ -e "$PRISM_TEST_MONITOR_PID" ]
kill -TERM "$START_PID"
set +e
wait "$START_PID"
TERM_STATUS=$?
set -e
[ "$TERM_STATUS" -ne 0 ]
[ ! -e "$PRISM_TEST_MONITOR" ]
[ ! -e "$XDG_RUNTIME_DIR/prism-capture-override" ]

for script in \
  prism-virtual-common.sh \
  prism-virtual-start.sh \
  prism-virtual-stop.sh; do
  bash -n "$SOURCE_DIR/contrib/virtual-session/$script"
done
