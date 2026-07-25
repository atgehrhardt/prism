#!/usr/bin/env bash
# Prism: optional prep command for the "Desktop" app. Snaps the primary output's
# refresh rate to the closest native mode matching the client's requested FPS.
# Usage: prism-desktop-refresh.sh set   (prep "do")
#        prism-desktop-refresh.sh restore (prep "undo")
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$RUNTIME/prism-desktop-mode"
LOG="$HOME/.local/state/prism-desktop.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1

command -v kscreen-doctor >/dev/null || exit 0

OUTPUT="$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk '/^Output:.* priority 1$/{print $3; exit}')"
[ -n "$OUTPUT" ] || exit 0

case "${1:-}" in
  set)
    FPS="${SUNSHINE_CLIENT_FPS:-60}"
    # Save current mode id (marked with '*') to restore later.
    CUR="$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -v out="$OUTPUT" '
      $0 ~ "Output:.* "out" " {f=1} f && /Modes:/ {print; exit}' | grep -o '[0-9]*:[0-9x]*@[0-9.]*\*' | tr -d '*' | cut -d: -f1)"
    [ -n "$CUR" ] && echo "$OUTPUT $CUR" > "$STATE"
    # Pick the native mode id whose refresh is closest to the client FPS.
    BEST="$(kscreen-doctor -o 2>/dev/null | sed 's/\x1b\[[0-9;]*m//g' | awk -v out="$OUTPUT" -v fps="$FPS" '
      $0 ~ "Output:.* "out" " {f=1; next}
      f && /Modes:/ {
        n=split($0, a, /[0-9]+:[0-9]+x[0-9]+@[0-9.]+/)
        best=-1; bestd=1e9
        for (i=1; i<=n; i++) {
          m=a[i]; sub(/^[^0-9]*/, "", m)
          split(m, b, ":"); id=b[1]
          split(b[2], c, "@"); r=c[2]+0
          d=(r-fps); if (d<0) d=-d
          if (d<bestd) {bestd=d; best=id}
        }
        print best; exit
      }')"
    [ -n "$BEST" ] && kscreen-doctor "output.$OUTPUT.mode.$BEST" 2>/dev/null || true
    ;;
  restore)
    [ -f "$STATE" ] || exit 0
    read -r OUT MODE < "$STATE"
    kscreen-doctor "output.$OUT.mode.$MODE" 2>/dev/null || true
    rm -f "$STATE"
    ;;
esac
