#!/usr/bin/env bash
## @file
## @brief Verify container Git trust for the runner-owned checkout and source manifest.
set -euo pipefail
ROOT="${1:?usage: test_appimage_build_ownership.sh CHECKOUT}"
TEMPORARY="$(mktemp -d)"
trap 'rm -rf "$TEMPORARY"' EXIT

# Exercise Git's ownership guard even when Docker maps the checkout to root locally.
GIT_TEST_ASSUME_DIFFERENT_OWNER=true git -C "$ROOT" rev-parse --verify HEAD > "$TEMPORARY/revision"
GIT_TEST_ASSUME_DIFFERENT_OWNER=true git -C "$ROOT" submodule status --recursive > "$TEMPORARY/submodules"
test -s "$TEMPORARY/revision"
test -s "$TEMPORARY/submodules"

# Trust must remain limited to the mounted checkout, not arbitrary repositories.
git init -q "$TEMPORARY/unrelated"
if GIT_TEST_ASSUME_DIFFERENT_OWNER=true git -C "$TEMPORARY/unrelated" status > "$TEMPORARY/output" 2>&1; then
  echo 'An unrelated repository incorrectly bypassed the ownership guard.' >&2
  exit 1
fi
grep -q 'dubious ownership' "$TEMPORARY/output"
echo 'Container checkout ownership and recursive source metadata checks passed.'
