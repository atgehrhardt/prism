#!/usr/bin/env bash
# Local mirror of the GitHub "common lint" workflow (LizardByte/.github).
# Run by the pre-push hook in .githooks/; can also be run manually:
#   scripts/lint.sh
#
# Tooling is bootstrapped into .lint-venv/ (gitignored) on first run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VENV="$REPO_ROOT/.lint-venv"
CLANG_FORMAT_VERSION=20
FAILED=0

run() { # run <name> <cmd...>
  echo "=== $1 ==="
  shift
  if "$@"; then
    echo "--- $1: OK"
  else
    echo "--- $1: FAILED" >&2
    FAILED=1
  fi
}

# --- bootstrap tools ---------------------------------------------------------
if [ ! -x "$VENV/bin/clang-format" ]; then
  echo "Bootstrapping lint tools into .lint-venv ..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  "$VENV/bin/pip" -q install "clang-format==${CLANG_FORMAT_VERSION}.*" yamllint cmakelang flake8
fi
PATH="$VENV/bin:$PATH"

if ! command -v shellcheck >/dev/null 2>&1; then
  if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
    echo "Downloading shellcheck ..."
    curl -sSL https://github.com/koalaman/shellcheck/releases/download/v0.10.0/shellcheck-v0.10.0.linux.x86_64.tar.xz \
      | tar -xJ -C "$VENV/bin" --strip-components=1 shellcheck-v0.10.0/shellcheck
  else
    echo "WARNING: shellcheck not found; skipping shell lint" >&2
  fi
fi

# Paths not present in CI checkouts (submodules, build output, deps)
SUBMODULES=$(git config --file .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}' || true)
PRUNE=( -path ./node_modules -o -path ./cmake-build-prism -o -path ./.lint-venv -o -path './.git' )
for s in $SUBMODULES; do
  PRUNE+=( -o -path "./$s" )
done

# Directories containing a lint ignore file are excluded, mirroring CI.
IGNORE_DIRS=$(find . \( "${PRUNE[@]}" \) -prune -o -type f \( -name '.clang-format-ignore' -o -name '.cmake-lint-ignore' \) -print0 | xargs -0 -r -n1 dirname)
for d in $IGNORE_DIRS; do
  PRUNE+=( -o -path "$d" )
done
find_tree() { # find_tree <iname-glob> [more globs...]
  local args=()
  local first=1
  for g in "$@"; do
    if [ $first -eq 1 ]; then first=0; else args+=( -o ); fi
    args+=( -iname "$g" )
  done
  find . \( "${PRUNE[@]}" \) -prune -o -type f \( "${args[@]}" \) -print
}

# --- C++ clang-format ---------------------------------------------------------
mapfile -t CPP_FILES < <(find_tree '*.c' '*.cpp' '*.h' '*.hpp' '*.m' '*.mm')
if [ ${#CPP_FILES[@]} -gt 0 ]; then
  run clang-format clang-format --dry-run --style=file --Werror "${CPP_FILES[@]}"
fi

# --- shellcheck ---------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t SH_FILES < <(find_tree '*.sh' '*.bash')
  if [ ${#SH_FILES[@]} -gt 0 ]; then
    run shellcheck shellcheck --format gcc "${SH_FILES[@]}"
  fi
fi

# --- yamllint -----------------------------------------------------------------
YAMLLINT_CONFIG=.yamllint.yml
if [ ! -f "$YAMLLINT_CONFIG" ]; then
  YAMLLINT_CONFIG="$VENV/.yamllint.yml"
  [ -f "$YAMLLINT_CONFIG" ] || curl -sS https://raw.githubusercontent.com/LizardByte/.github/master/.yamllint.yml -o "$YAMLLINT_CONFIG"
fi
mapfile -t YML_FILES < <(find_tree '*.yml' '*.yaml')
run yamllint yamllint --config-file "$YAMLLINT_CONFIG" --format=standard --strict "${YML_FILES[@]}" .clang-format

# --- cmake-lint ---------------------------------------------------------------
mapfile -t CMAKE_FILES < <(find_tree 'CMakeLists.txt' '*.cmake')
if [ ${#CMAKE_FILES[@]} -gt 0 ]; then
  run cmake-lint cmake-lint --line-width 120 --tab-size 4 "${CMAKE_FILES[@]}"
fi

# --- trailing whitespace ------------------------------------------------------
# shellcheck disable=SC2016 # expressions expand in the inner bash, not here
run trailing-spaces bash -c '
  fail=0
  while IFS= read -r f; do
    case "$f" in third-party/*|packaging/linux/flatpak/deps/*) continue ;; esac
    [ -f "$f" ] || continue
    if grep -nIE " +$" "$f" >/dev/null 2>&1; then
      echo "trailing whitespace: $f" >&2
      fail=1
    fi
  done < <(git ls-files)
  exit $fail
'

if [ $FAILED -ne 0 ]; then
  echo "Lint failed; push aborted. Fix the issues above or push with --no-verify." >&2
  exit 1
fi
echo "All lint checks passed."
