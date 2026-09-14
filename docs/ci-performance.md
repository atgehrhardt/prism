/**
 * @file
 * @brief CI build caching, invalidation, and performance validation.
 */

# CI build performance

The [Linux baseline run](https://github.com/atgehrhardt/prism/actions/runs/34787658646)
spent 899 seconds building, 153 seconds checking out sources, 107 seconds installing
dependencies, and 27 seconds running tests. Compilation is the main target for
optimization; the test suite and coverage instrumentation remain enabled.

Linux, Fedora smoke, and AppImage jobs cache compiler results with ccache and npm
downloads. Compiler caches are separate for each workflow and architecture, with
a 1 GB limit each. Keys include the commit, with a prefix fallback to reuse the
previous accessible cache. ccache checks compiler contents, source, headers, and
compiler options before reusing a result. The workflows do not enable ccache
sloppiness, cache CMake build trees, or restore test results or coverage counters.
Every run configures, builds, and executes its existing checks.

Build jobs use the runner's available CPU count instead of a fixed two workers.
Recursive submodule checkout remains shallow and fetches up to four repositories
concurrently. Compiler cache statistics appear in the build logs.

The AppImage builder uses Buildx's GitHub Actions layer cache, scoped to
`prism-appimage-builder`. Unchanged toolchains and pinned compositor dependencies
can be restored instead of rebuilt. Dockerfile and copied dependency script
changes invalidate the affected layers. The image is loaded into the job's Docker
daemon; no container registry publication is required. Artifact upload skips ZIP
compression because the AppImage already contains a compressed filesystem.

Caches are optional accelerators. A cache miss, eviction, or new branch without an
accessible cache triggers a normal build. The first run populates the caches and
may spend additional time uploading them. GitHub's cache visibility rules apply;
PR caches are scoped to their merge ref. The AppImage workflow can be manually run
on master after merging to seed a cache accessible to later PRs.

To assess the improvement, compare the build, cache restore/save, and Docker image
steps between a cold run and a subsequent source change. Inspect ccache hit rates
alongside total elapsed time. Do not infer a speedup from a skipped build or test.

To force a clean compiler cache, delete the relevant Actions cache or increment
the workflow's `build-v1` cache prefix. Delete the AppImage Buildx cache when a
fresh baseline package installation is required without a Dockerfile change.
