#!/usr/bin/env bash
# Prism: brand the built web UI assets (Sunshine -> Prism in display text).
# Runs after `cmake --install` so upstream source stays untouched and rebases
# never conflict. Safe to run repeatedly.
set -euo pipefail

WEB="${1:-$HOME/.local/assets/web}"
[ -d "$WEB" ] || { echo "brand-web-ui: $WEB not found, skipping"; exit 0; }

PROTECT="__PRISM_PROTECT_LIZARDBYTE_URL__"

find "$WEB" -maxdepth 3 \( -name '*.html' -o -name '*.js' -o -name '*.json' \) -print0 |
  xargs -0 sed -i \
    -e "s|https://github.com/LizardByte/Sunshine|$PROTECT|g" \
    -e 's/Sunshine/Prism/g' \
    -e "s|$PROTECT|https://github.com/LizardByte/Sunshine|g"

echo "brand-web-ui: branded $WEB"
