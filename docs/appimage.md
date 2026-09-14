/**
 * @file
 * @brief AppImage release layout, installation lifecycle, and compatibility contract.
 */

# AppImage distribution

Prism's primary binary distribution is `prism-x86_64.AppImage`, accompanied by
`prism-x86_64.AppImage.sha256`. Build and publication are defined in
`.github/workflows/appimage.yml`. A manual workflow run produces reviewable CI
artifacts; a `v*` tag in `atgehrhardt/prism` publishes them after build and
compatibility checks. The installer requires these release assets to exist.

## Compatibility

The baseline is x86_64 Linux with glibc 2.39 or newer (Ubuntu 24.04), a systemd
user session, udev, Bash, Python 3, curl, and util-linux tools including flock.
The host supplies GPU drivers, graphics libraries, fonts, PipeWire client libraries,
desktop portals, a PulseAudio-compatible audio server (including PipeWire-Pulse),
and systemd. PipeWire client libraries stay with the host's matching modules;
the AppImage does not replace the desktop's audio or video service stack.
The mounted image requires working FUSE support. Container compatibility tests
extract the image to test its payload without requiring a privileged FUSE mount;
these tests do not validate GPU capture or a complete desktop session.

The image contains Prism, its web assets, the private labwc/wlroots compositor,
Wayland session tools, Xwayland, its keyboard compiler/data, the input bridge,
HDR calibration and KWin mode helpers, and supporting libraries. The compositor's
newer dependencies are compiled against the baseline instead of requiring a
newer host glibc. Libraries are located using executable-relative RPATHs rather
than exporting a global LD_LIBRARY_PATH into launched games.

Steam and bubblewrap remain host requirements for Steam Headless. KDE virtual
outputs and physical display switching need the host's Plasma 6, kscreen, and
krfb tools. Packaging does not add these features to other desktops. GPU support
for headless HDR still follows [the HDR requirements](headless-hdr.md).

The release build includes CUDA capture support for NVIDIA headless HDR and
Prism's native NVENC encoder. The CUDA compiler is needed only in the build
container. KWin, portal, Wayland, and private compositor capture are available.
Direct KMS capture requires privileges that cannot be set on a read-only mounted
AppImage binary; use a suitably configured native/source installation if you
require that capture backend. AppImage setup deliberately does not attempt
`setcap` on its mounted files.

## Installed layout and updates

- `${XDG_DATA_HOME:-$HOME/.local/share}/prism/prism.AppImage`: stable release image.
- `~/.local/bin/prism`: small launcher, including `--update` and `--remove`.
- `${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user/prism*.service`: service definitions.
- `${XDG_CONFIG_HOME:-$HOME/.config}/prism`: configuration and apps.
- `/etc/udev/rules.d/{60-prism.rules,61-prism-input.rules}` and
  `/etc/modules-load.d/60-prism.conf`: host integration requiring sudo.

Empty or relative XDG overrides use their standard home-directory defaults.
All service commands point at the stable image path. Each internal service
invokes an allowlisted `--internal` entry point, so a service never retains the
transient mount path from installation. The image dispatcher supplies the
bundled session directory and executable search paths for that invocation.

The installer serializes updates with flock, downloads to the destination
filesystem, verifies SHA-256 before executing the download, and probes the
payload before stopping the existing services. It saves the affected user files,
registers integration, replaces the image with a rename, and restarts Prism.
An immediate startup failure restores the old image and saved user integration.
The initial check is not a guarantee that a later GPU streaming session succeeds.
System input rules may remain installed after a failed first-time setup.
Checksums protect download integrity; their trust comes from the same HTTPS
release origin as the image, not an independent signing key.

Use `PRISM_VERSION=vX.Y.Z prism --update` for an explicit published version.
`prism --remove` retains configuration and game/application data. It does not
remove host packages, Steam, developer checkouts, or unrelated user services.

## Migrating from the source installer

Run the new installation command. Existing Prism user service definitions are
replaced with AppImage entry points, and the old `~/.local/bin/prism` executable
is replaced by the launcher. Existing apps and settings are retained. The old
checkout and other source-installed helper files are left in place; after
validating the new installation, they can be removed separately. No installer
moves or deletes `~/Dev/prism`, which may contain developer changes.

## Building and validating

From the repository root on an x86_64 Linux Docker host:

```bash
docker build -f packaging/linux/AppImage/Dockerfile -t prism-appimage-build .
docker run --rm -v "$PWD:/src" prism-appimage-build bash scripts/build-appimage.sh
```

Output is under `cmake-build-appimage/artifacts`. The existing Linux CI runs the
C++ suite. Add `-e PRISM_BUILD_TESTS=ON` to the Docker command to also run gtest
through `cmake-build-appimage/tests/test_prism` during packaging.
See [CI build performance](ci-performance.md) for compiler and container caching.
Packaging tools and upgraded compositor
sources are pinned to release hashes or immutable commits. Host distribution
packages receive the baseline distribution's updates.
For a developer-only build without NVIDIA headless HDR, pass
`-e PRISM_ENABLE_CUDA=OFF` to the container. Published releases use CUDA support.

To install a locally built or downloaded CI artifact on a target Linux desktop,
keep the image and its `.sha256` file together, then run:

```bash
PRISM_APPIMAGE="$PWD/cmake-build-appimage/artifacts/prism-x86_64.AppImage" bash install.sh
```

This follows the same verification and rollback path without requiring a
published GitHub release.

Run installer/integration tests without changing the host:

```bash
python3 tests/integration/test_appimage.py
python3 tests/integration/test_install_bootstrap.py install-source.sh
```

On actual Ubuntu and Fedora desktop hosts, validate first install, update,
uninstall, reboot/login startup, pairing, each available capture mode, audio,
virtual input, and NVIDIA/AMD HDR operation. These require hardware beyond the
container smoke checks.

## Developer source installation

The source installer remains available for development:

```bash
PRISM_SRC_DIR="$PWD" bash install-source.sh
```

Automatic build-dependency installation targets Fedora. Other distributions
must provide the dependencies and set `PRISM_SKIP_DEPENDENCIES=1`. Without
`PRISM_SRC_DIR`, sources default to `${XDG_CACHE_HOME:-$HOME/.cache}/prism/source`.
The source installer retains its existing native installation behavior.
`scripts/update-upstream.sh` is a maintainer-only Sunshine rebase tool; it is
never called by the AppImage updater.
