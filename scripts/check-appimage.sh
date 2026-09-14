#!/usr/bin/env bash
## @file
## @brief Check an extracted AppImage's executables and libraries on a target distro.
set -euo pipefail
APPDIR="${1:?usage: check-appimage.sh EXTRACTED_APPDIR}"
"$APPDIR/AppRun" --check
while IFS= read -r -d '' payload; do
  if file --brief "$payload" | grep -q ELF; then
    if ! dependencies="$(ldd -r "$payload" 2>&1)" ||
      grep -Eq 'not found|undefined symbol:' <<< "$dependencies"; then
      printf 'Unresolved dependencies: %s\n%s\n' "$payload" "$dependencies" >&2
      exit 1
    fi
  fi
done < <(find "$APPDIR/usr" -type d -name share -prune -o -type f -print0)
