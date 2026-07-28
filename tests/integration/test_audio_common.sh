#!/usr/bin/env bash
# Exercise exact, idempotent Prism audio cleanup with a mocked pactl backend.
set -euo pipefail

SOURCE_DIR="${1:?source directory required}"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export PATH="$TEST_ROOT/bin:$PATH"
export PRISM_TEST_MODULES="$TEST_ROOT/modules"
export PRISM_TEST_UNLOADS="$TEST_ROOT/unloads"
mkdir -p "$TEST_ROOT/bin"

cat > "$TEST_ROOT/bin/pactl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-} ${2:-} ${3:-}" in
  "list short modules")
    cat "$PRISM_TEST_MODULES"
    ;;
  "unload-module "*)
    module="${2:?module required}"
    if [ "${PRISM_TEST_FAIL_UNLOAD:-}" = "$module" ]; then
      exit 1
    fi
    printf '%s\n' "$module" >> "$PRISM_TEST_UNLOADS"
    awk -v unwanted="$module" '$1 != unwanted' "$PRISM_TEST_MODULES" \
      > "$PRISM_TEST_MODULES.tmp"
    mv "$PRISM_TEST_MODULES.tmp" "$PRISM_TEST_MODULES"
    ;;
  *)
    exit 2
    ;;
esac
EOF
chmod +x "$TEST_ROOT/bin/pactl"

cat > "$PRISM_TEST_MODULES" <<'EOF'
10	module-loopback	source=prism-headless.monitor sink=prism-stream latency_msec=20
11	module-loopback	latency_msec=20 sink=prism-stream source=prism-headless.monitor
12	module-loopback	source=prism-virtual.monitor sink=prism-stream
13	module-loopback	source=alsa_output.pci.monitor sink=prism-stream
14	module-loopback	source=prism-headless.monitor sink=user-capture
15	module-loopback	source=user.monitor sink=user-capture
16	module-null-sink	sink_name=prism-headless sink_properties=device.description=Prism
17	module-null-sink	sink_name=user-sink
18	module-loopback	source=prism-headless.monitor-extra sink=prism-stream
19	module-loopback	source=prism-headless.monitor sink=prism-stream-extra
20	module-always-sink	sink_name=prism-headless
21	module-loopback	source=prism-virtual.monitor sink=prism-stream
EOF
: > "$PRISM_TEST_UNLOADS"

# shellcheck source=/dev/null
. "$SOURCE_DIR/contrib/virtual-session/prism-audio-common.sh"

prism_unload_loopback_modules prism-headless.monitor prism-stream
[ "$(tr '\n' ' ' < "$PRISM_TEST_UNLOADS")" = "10 11 " ]
if awk '$1 == 10 || $1 == 11 {found=1} END {exit found ? 0 : 1}' "$PRISM_TEST_MODULES"; then
  echo "duplicate headless routes were not removed" >&2
  exit 1
fi

prism_unload_loopback_modules prism-virtual.monitor prism-stream
grep -qx '12' "$PRISM_TEST_UNLOADS"
grep -qx '21' "$PRISM_TEST_UNLOADS"
prism_unload_named_sink_modules prism-headless
grep -qx '16' "$PRISM_TEST_UNLOADS"

prism_unload_prism_capture_loopbacks
for removed in 13 18; do
  grep -qx "$removed" "$PRISM_TEST_UNLOADS"
done
for preserved in 14 15 17 19 20; do
  awk -v wanted="$preserved" '$1 == wanted {found=1} END {exit found ? 0 : 1}' \
    "$PRISM_TEST_MODULES"
done

unload_count="$(wc -l < "$PRISM_TEST_UNLOADS")"
prism_unload_prism_capture_loopbacks
prism_unload_named_sink_modules prism-headless
[ "$(wc -l < "$PRISM_TEST_UNLOADS")" -eq "$unload_count" ]

prism_unload_module ""
prism_unload_module invalid
prism_unload_module 999
[ "$(wc -l < "$PRISM_TEST_UNLOADS")" -eq "$unload_count" ]

printf '%s\n' \
  $'22\tmodule-loopback\tsource=prism-virtual.monitor sink=prism-stream' \
  >> "$PRISM_TEST_MODULES"
export PRISM_TEST_FAIL_UNLOAD=22
if prism_unload_loopback_modules prism-virtual.monitor prism-stream; then
  echo "failed module unload was incorrectly reported as successful" >&2
  exit 1
fi
awk '$1 == 22 {found=1} END {exit found ? 0 : 1}' "$PRISM_TEST_MODULES"
unset PRISM_TEST_FAIL_UNLOAD
prism_unload_loopback_modules prism-virtual.monitor prism-stream

STATE="$TEST_ROOT/audio.state"
prism_audio_atomic_write "$STATE" <<EOF
loop_module=44
physical_sink=speakers
EOF
[ "$(prism_audio_state_get "$STATE" loop_module)" = "44" ]
printf '%s\n' 'loop_module=45' >> "$STATE"
if prism_audio_state_get "$STATE" loop_module >/dev/null; then
  echo "duplicate audio state key was accepted" >&2
  exit 1
fi
printf '%s\n' 'loop_module=44' 'malformed-state-line' > "$STATE"
if prism_audio_state_get "$STATE" loop_module >/dev/null; then
  echo "malformed audio state was accepted" >&2
  exit 1
fi
if prism_audio_state_get "$TEST_ROOT/missing" loop_module >/dev/null; then
  echo "missing audio state was accepted" >&2
  exit 1
fi
