#!/usr/bin/env bash
# Prism — rebase the virtual-capture patch onto the latest upstream Sunshine
# release, rebuild, and reinstall. Run from anywhere:
#   ~/Dev/prism/update.sh
set -euo pipefail

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BRANCH="virtual-capture"
UPSTREAM="https://github.com/LizardByte/Sunshine.git"

cd "$SRC_DIR"
git remote get-url upstream >/dev/null 2>&1 || git remote add upstream "$UPSTREAM"

echo "==> Fetching upstream"
git fetch upstream --tags

LATEST="$(git tag --sort=-v:refname | grep -E '^v?[0-9]+\.[0-9]+' | head -1)"
echo "==> Latest upstream release: $LATEST"
CURRENT_BASE="$(git describe --tags --abbrev=0 upstream/master 2>/dev/null || echo unknown)"
echo "==> Current base: $CURRENT_BASE"

if [ "$CURRENT_BASE" = "$LATEST" ]; then
  echo "==> Already on the latest release; nothing to do."
  exit 0
fi

echo "==> Rebasing $BRANCH onto $LATEST"
git checkout "$BRANCH"
if ! git rebase --onto "$LATEST" "$CURRENT_BASE" "$BRANCH"; then
  echo "!! Rebase conflict. Resolve it, then: git rebase --continue"
  echo "!! Abort with: git rebase --abort"
  exit 1
fi
git submodule update --init --recursive

echo "==> Rebuilding and reinstalling"
PRISM_SRC_DIR="$SRC_DIR" bash "$SRC_DIR/install.sh"

echo "==> Done. Push the rebased branch with: git push -f origin $BRANCH"
