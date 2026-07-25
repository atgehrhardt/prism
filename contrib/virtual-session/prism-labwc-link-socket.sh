#!/usr/bin/env bash
# Prism: ExecStartPost helper for prism-labwc.service.
# labwc names its socket automatically (wayland-N); find the socket owned by
# labwc ($1 = labwc PID) and link it to the stable name "wayland-prism".
set -u

PID="${1:?usage: prism-labwc-link-socket.sh <labwc-pid>}"
RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"

for _ in $(seq 1 40); do
  for s in "$RUNTIME"/wayland-*; do
    [ -S "$s" ] || continue
    case "$s" in *.lock | *wayland-prism) continue ;; esac
    if fuser "$s" 2>/dev/null | tr ' ' '\n' | grep -qx "$PID"; then
      ln -sfn "$s" "$RUNTIME/wayland-prism"
      exit 0
    fi
  done
  sleep 0.25
done
echo "labwc-link-socket: could not find labwc socket" >&2
exit 1
