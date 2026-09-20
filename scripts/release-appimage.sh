#!/usr/bin/env bash
## @file
## @brief Validate or publish a manual AppImage release at its tested commit.
## @param $1 Operation: validate before building, or publish after compatibility checks.
## @details Requires RELEASE_TAG and GH_REPO; publication also needs RELEASE_COMMIT and GH_TOKEN.
set -euo pipefail
[[ "${1:-}" = validate || "${1:-}" = publish ]] || { echo 'Expected validate or publish.' >&2; exit 1; }
[[ "${GH_REPO:-}" = atgehrhardt/prism ]] || { echo 'Release publication is restricted to atgehrhardt/prism.' >&2; exit 1; }
[[ "${RELEASE_TAG:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9]+([.-][A-Za-z0-9]+)*)?$ ]] || {
  echo 'Expected a version such as v1.0.0 or v1.0.0-rc.1.' >&2; exit 1;
}
# Distinguish an absent tag from authentication or network errors.
if git ls-remote --exit-code --tags origin "refs/tags/$RELEASE_TAG"; then
  echo "Tag $RELEASE_TAG already exists; choose a new version." >&2
  exit 1
else
  status=$?
  [[ "$status" = 2 ]] || exit "$status"
fi
[[ "$1" = publish ]] || exit 0
[[ "${RELEASE_COMMIT:-}" =~ ^[0-9a-f]{40}$ ]] || { echo 'Expected the full build commit SHA.' >&2; exit 1; }
(cd artifact && sha256sum --check prism-x86_64.AppImage.sha256)
# Creating the ref explicitly pins the release to the built commit and fails if
# another run has claimed the version. GITHUB_TOKEN does not trigger another tag build.
gh api --method POST "repos/$GH_REPO/git/refs" \
  -f "ref=refs/tags/$RELEASE_TAG" -f "sha=$RELEASE_COMMIT"
flags=(--verify-tag --generate-notes)
if [[ "$RELEASE_TAG" == *-* ]]; then flags+=(--prerelease); fi
gh release create "$RELEASE_TAG" \
  artifact/prism-x86_64.AppImage artifact/prism-x86_64.AppImage.sha256 \
  "${flags[@]}"
