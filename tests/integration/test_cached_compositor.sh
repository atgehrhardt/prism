#!/usr/bin/env bash
## @file
## @brief Check cached compositor staging and rejection of changed build inputs.
set -euo pipefail
ROOT="${1:?source directory required}"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT
cd "$ROOT"
while read -r _ input; do
  cp --parents "$input" "$TEMPORARY"
done < /opt/prism-deps/share/licenses/private-compositor/inputs.sha256
cp packaging/linux/AppImage/stage-compositor.sh "$TEMPORARY/packaging/linux/AppImage/"
STAGE="$TEMPORARY/packaging/linux/AppImage/stage-compositor.sh"
bash "$STAGE" --check
bash "$STAGE" "$TEMPORARY/App Dir"
cmp /opt/prism-deps/bin/prism-labwc "$TEMPORARY/App Dir/usr/bin/prism-labwc"
test -x "$TEMPORARY/App Dir/usr/bin/prism-labwc"
printf '\n# Changed build inputs\n' >> "$TEMPORARY/contrib/virtual-session/build-headless-compositor.sh"
if bash "$STAGE" "$TEMPORARY/stale" 2> "$TEMPORARY/error"; then
  echo 'A stale compositor was accepted.' >&2
  exit 1
fi
grep -q 'rebuild the AppImage builder' "$TEMPORARY/error"
test ! -e "$TEMPORARY/stale/usr/bin/prism-labwc"
echo 'Cached compositor staging and invalidation checks passed.'
