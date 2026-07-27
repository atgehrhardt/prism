#!/usr/bin/env bash
# Repository-owned implementation of the GitHub "Common Lint" workflow.
# Run by CI and the pre-push hook in .githooks/; it can also be run manually:
#   scripts/lint.sh
#
# Version-pinned tooling is bootstrapped into .lint-venv/ (gitignored).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$REPO_ROOT"

VENV="$REPO_ROOT/.lint-venv"
CLANG_FORMAT_VERSION=20.1.8
YAMLLINT_VERSION=1.38.0
CMAKELANG_VERSION=0.6.13
FLAKE8_VERSION=7.3.0
SHELLCHECK_VERSION=0.10.0
SHELLCHECK_SHA256=6c881ab0698e4e6ea235245f22832860544f17ba386442fe7e9d629f8cbedf87
ACTIONLINT_VERSION=1.7.12
ACTIONLINT_SHA256=8aca8db96f1b94770f1b0d72b6dddcb1ebb8123cb3712530b08cc387b349a3d8
HADOLINT_VERSION=2.14.0
HADOLINT_SHA256=6bf226944684f56c84dd014e8b979d27425c0148f61b3bd99bcc6f39e9dc5a47
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
TOOL_VERSIONS="$CLANG_FORMAT_VERSION:$YAMLLINT_VERSION:$CMAKELANG_VERSION:$FLAKE8_VERSION"
if [ ! -x "$VENV/bin/clang-format" ] ||
  [ ! -f "$VENV/.tool-versions" ] ||
  [ "$(cat "$VENV/.tool-versions")" != "$TOOL_VERSIONS" ]; then
  echo "Bootstrapping lint tools into .lint-venv ..."
  python3 -m venv "$VENV"
  "$VENV/bin/pip" -q install --upgrade pip
  "$VENV/bin/pip" -q install \
    "clang-format==${CLANG_FORMAT_VERSION}" \
    "yamllint==${YAMLLINT_VERSION}" \
    "cmakelang==${CMAKELANG_VERSION}" \
    "flake8==${FLAKE8_VERSION}"
  printf '%s\n' "$TOOL_VERSIONS" > "$VENV/.tool-versions"
fi
PATH="$VENV/bin:$PATH"

download() { # download <url> <output> <sha256>
  local url="$1"
  local output="$2"
  local sha256="$3"
  curl -fsSL --retry 3 "$url" -o "$output"
  printf '%s  %s\n' "$sha256" "$output" | sha256sum --check
}

if [ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ]; then
  if [ ! -x "$VENV/bin/shellcheck" ] ||
    ! "$VENV/bin/shellcheck" --version | grep -q "version: ${SHELLCHECK_VERSION}"; then
    echo "Downloading shellcheck ${SHELLCHECK_VERSION} ..."
    shellcheck_archive="$VENV/shellcheck.tar.xz"
    download \
      "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" \
      "$shellcheck_archive" \
      "$SHELLCHECK_SHA256"
    tar -xJf "$shellcheck_archive" -C "$VENV/bin" \
      --strip-components=1 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck"
  fi

  if [ ! -x "$VENV/bin/actionlint" ] ||
    [ "$("$VENV/bin/actionlint" -version | head -n 1)" != "$ACTIONLINT_VERSION" ]; then
    echo "Downloading actionlint ${ACTIONLINT_VERSION} ..."
    actionlint_archive="$VENV/actionlint.tar.gz"
    download \
      "https://github.com/rhysd/actionlint/releases/download/v${ACTIONLINT_VERSION}/actionlint_${ACTIONLINT_VERSION}_linux_amd64.tar.gz" \
      "$actionlint_archive" \
      "$ACTIONLINT_SHA256"
    tar -xzf "$actionlint_archive" -C "$VENV/bin" actionlint
  fi

  if [ ! -x "$VENV/bin/hadolint" ] ||
    ! "$VENV/bin/hadolint" --version | grep -q " ${HADOLINT_VERSION}$"; then
    echo "Downloading hadolint ${HADOLINT_VERSION} ..."
    download \
      "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64" \
      "$VENV/bin/hadolint" \
      "$HADOLINT_SHA256"
    chmod +x "$VENV/bin/hadolint"
  fi
else
  for tool in shellcheck actionlint hadolint; do
    if ! command -v "$tool" >/dev/null 2>&1; then
      echo "WARNING: ${tool} not found; skipping its checks" >&2
    fi
  done
fi

# Paths not present in CI checkouts (submodules, build output, deps)
SUBMODULES=$(git config --file .gitmodules --get-regexp path 2>/dev/null | awk '{print $2}' || true)
PRUNE=( -path ./node_modules -o -path './cmake-build-*' -o -path ./.lint-venv -o -path './.git' )
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

# --- GitHub Actions -----------------------------------------------------------
if command -v actionlint >/dev/null 2>&1; then
  run actionlint actionlint -color
fi

# --- shellcheck ---------------------------------------------------------------
if command -v shellcheck >/dev/null 2>&1; then
  mapfile -t SH_FILES < <(find_tree '*.sh' '*.bash')
  if [ ${#SH_FILES[@]} -gt 0 ]; then
    run shellcheck shellcheck --format gcc "${SH_FILES[@]}"
  fi
fi

# --- yamllint -----------------------------------------------------------------
mapfile -t YML_FILES < <(find_tree '*.yml' '*.yaml')
run yamllint yamllint --config-file .yamllint.yml --format=standard --strict "${YML_FILES[@]}" .clang-format

# --- cmake-lint ---------------------------------------------------------------
mapfile -t CMAKE_FILES < <(find_tree 'CMakeLists.txt' '*.cmake')
if [ ${#CMAKE_FILES[@]} -gt 0 ]; then
  run cmake-lint cmake-lint --line-width 120 --tab-size 4 "${CMAKE_FILES[@]}"
fi

# --- Python -------------------------------------------------------------------
mapfile -t PYTHON_FILES < <(find_tree '*.py')
if [ ${#PYTHON_FILES[@]} -gt 0 ]; then
  run flake8 flake8 "${PYTHON_FILES[@]}"
fi

# --- Docker -------------------------------------------------------------------
if command -v hadolint >/dev/null 2>&1; then
  mapfile -t DOCKER_FILES < <(find_tree 'Dockerfile' '*.dockerfile')
  if [ ${#DOCKER_FILES[@]} -gt 0 ]; then
    run hadolint hadolint \
      --failure-threshold style \
      --no-color \
      --ignore DL3008 \
      --ignore DL3013 \
      --ignore DL3016 \
      --ignore DL3018 \
      --ignore DL3028 \
      --ignore DL3059 \
      "${DOCKER_FILES[@]}"
  fi
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
