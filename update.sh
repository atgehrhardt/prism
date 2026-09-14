#!/usr/bin/env bash
## @file
## @brief Update to a published Prism AppImage release without rebasing source.
set -euo pipefail
exec bash "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install.sh" "$@"
