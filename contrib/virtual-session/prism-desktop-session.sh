#!/usr/bin/env bash
# Prism: prep commands for the "Desktop" app. Adapts the primary physical
# output to the connecting client and restores the previous state on
# disconnect.
#
#   prism-desktop-session.sh set      (prep "do")
#   prism-desktop-session.sh restore  (prep "undo")
#
# Uses Sunshine's per-client env: SUNSHINE_CLIENT_WIDTH, SUNSHINE_CLIENT_HEIGHT,
# SUNSHINE_CLIENT_FPS, SUNSHINE_CLIENT_HDR.
#
# Note: KWin cannot add arbitrary modes, so if the client resolution is not a
# native mode of the panel, the native resolution is kept (Sunshine scales the
# capture to the client) and only the refresh rate is snapped to the closest
# native match of the client FPS.
set -u

RUNTIME="${XDG_RUNTIME_DIR:-/run/user/$(id -u)}"
STATE="$RUNTIME/prism-desktop-session.state"
LOG="$HOME/.local/state/prism-desktop.log"
mkdir -p "$(dirname "$LOG")"
exec >>"$LOG" 2>&1
echo "=== desktop-session ${1:-?} $(date -Is) client=${SUNSHINE_CLIENT_WIDTH:-?}x${SUNSHINE_CLIENT_HEIGHT:-?}@${SUNSHINE_CLIENT_FPS:-?} hdr=${SUNSHINE_CLIENT_HDR:-?} ==="

command -v kscreen-doctor >/dev/null || exit 0

strip() { sed 's/\x1b\[[0-9;]*m//g'; }

# Primary output name (block containing "priority 1").
OUTPUT="$(kscreen-doctor -o 2>/dev/null | strip | awk '/^Output:/{name=$3} /priority 1$/{print name; exit}')"
[ -n "$OUTPUT" ] || { echo "no primary output found"; exit 0; }

# State dump for the primary output: "hdr wcg current_mode_id"
output_state() {
  kscreen-doctor -o 2>/dev/null | strip | awk -v out="$OUTPUT" '
    $0 ~ "^Output:.* "out" " {f=1; hdr="disabled"; wcg="disabled"; cur=""; next}
    f && /^Output:/ {exit}
    f && /HDR:/ {hdr=$2}
    f && /Wide Color Gamut:/ {wcg=$4}
    f && /Modes:/ {
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+\*$/) { split($i, b, ":"); cur=b[1] }
      }
    }
    END {print hdr, wcg, cur}'
}

# Best mode id: prefer exact client resolution, else native panel resolution;
# within the candidate set pick the refresh closest to the client FPS.
best_mode() {
  local want_w="${SUNSHINE_CLIENT_WIDTH:-0}" want_h="${SUNSHINE_CLIENT_HEIGHT:-0}" fps="${SUNSHINE_CLIENT_FPS:-60}"
  kscreen-doctor -o 2>/dev/null | strip | awk -v out="$OUTPUT" -v ww="$want_w" -v wh="$want_h" -v fps="$fps" '
    $0 ~ "^Output:.* "out" " {f=1; next}
    f && /^Output:/ {exit}
    f && /Modes:/ {
      exact=-1; exactd=1e9; any=-1; anyd=1e9
      # find the preferred (!) mode resolution, i.e. the panel native resolution
      for (i=1; i<=NF; i++) {
        if ($i ~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+!$/) {
          m=$i; gsub(/[!*]/, "", m)
          split(m, b, ":"); split(b[2], c, "@"); split(c[1], r, "x")
          nw=r[1]+0; nh=r[2]+0
        }
      }
      for (i=1; i<=NF; i++) {
        if ($i !~ /^[0-9]+:[0-9]+x[0-9]+@[0-9.]+/) continue
        m=$i; gsub(/[!*]/, "", m)
        split(m, b, ":"); id=b[1]
        split(b[2], c, "@"); split(c[1], r, "x"); w=r[1]+0; h=r[2]+0; rate=c[2]+0
        d=(rate-fps); if (d<0) d=-d
        # fallback candidates: only the panel native resolution (KWin cannot
        # add custom modes; Sunshine scales the capture for other resolutions)
        if (w==nw && h==nh && d<anyd) {anyd=d; any=id}
        if (w==ww && h==wh && d<exactd) {exactd=d; exact=id}
      }
      print (exact >= 0 ? exact : any); exit
    }'
}

# Apply HDR/WCG state, retrying until it sticks (KWin can reject the toggle
# right after a mode change).
apply_color() {
  local out="$1" hdr="$2" wcg="$3"
  for _ in 1 2 3 4; do
    kscreen-doctor "output.$out.hdr.$hdr" "output.$out.wcg.$wcg" 2>/dev/null || true
    sleep 1
    local cur_hdr
    cur_hdr="$(output_state | awk '{print $1}')"
    [ "$cur_hdr" = "${hdr}d" ] && return 0
  done
  echo "WARNING: could not apply hdr=$hdr on $out"
}

case "${1:-}" in
  set)
    read -r HDR WCG CUR <<< "$(output_state)"
    [ -n "$CUR" ] && printf '%s %s %s %s\n' "$OUTPUT" "$CUR" "$HDR" "$WCG" > "$STATE"
    MODE="$(best_mode)"
    if [ -n "$MODE" ]; then
      echo "setting $OUTPUT mode $MODE"
      kscreen-doctor "output.$OUTPUT.mode.$MODE" 2>/dev/null || true
      sleep 1  # let the mode change settle before toggling color state
    fi
    if [ "${SUNSHINE_CLIENT_HDR:-false}" = "true" ]; then
      echo "enabling HDR+WCG on $OUTPUT"
      apply_color "$OUTPUT" enable enable
    else
      echo "disabling HDR on $OUTPUT"
      apply_color "$OUTPUT" disable disable
    fi
    ;;
  restore)
    [ -f "$STATE" ] || exit 0
    read -r OUT MODE HDR WCG < "$STATE"
    # state stores kscreen's reported words (enabled/disabled); the setter
    # wants enable/disable
    HDR="${HDR%d}"
    WCG="${WCG%d}"
    echo "restoring $OUT mode $MODE hdr=$HDR wcg=$WCG"
    [ -n "$MODE" ] && kscreen-doctor "output.$OUT.mode.$MODE" 2>/dev/null || true
    sleep 1  # let the mode change settle before toggling color state
    apply_color "$OUT" "$HDR" "$WCG"
    rm -f "$STATE"
    ;;
esac
