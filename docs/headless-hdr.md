# Headless HDR and lifecycle assessment

Headless HDR uses a private labwc compositor with Vulkan rendering. Its output is
BT.2020 with the ST 2084 PQ transfer function. Prism captures the output as a
10-bit RGB DMA-BUF, converts it on the GPU, and sends HDR10 metadata through the
existing Moonlight protocol. Iris already negotiates 10-bit video and applies
the host's HDR metadata, so this feature does not require an Iris protocol change.

## Installation and use

On the Fedora Prism host, run `PRISM_SRC_DIR="$PWD" bash install.sh` from the updated Prism checkout. The
installer builds `~/.local/bin/prism-labwc` in addition to Prism and installs the
updated session helpers. It preserves a checkout with local changes.

For an existing development installation with the build dependencies available:

```sh
bash contrib/virtual-session/build-headless-compositor.sh
```

Also rebuild/install Prism and the session helpers; the compositor alone does not
add HDR capture support to an older Prism binary. Other packaging flows must
install `prism-labwc` on the session service's PATH. The helper supports
`PRISM_INSTALL_PREFIX` for installations outside `~/.local`.

The compositor/runtime code has no Fedora or KDE dependency. The source installer
automatically installs packages only on Fedora; other distributions can supply
dependencies and use `PRISM_SKIP_DEPENDENCIES=1 PRISM_SRC_DIR="$PWD" bash install.sh`.
The existing `scripts/linux_build.sh` has Prism dependency lists for Fedora,
Debian/Ubuntu, and Arch. The extra compositor dependencies are checked by:

```sh
bash contrib/virtual-session/build-headless-compositor.sh --check
```

This command only checks tools and pkg-config requirements; it does not fetch,
build, install, or test the GPU. The pinned compositor needs Meson 1.3+, Wayland
1.24+, wayland-protocols 1.47+, libdrm 2.4.129+, xkbcommon 1.8+, pixman 0.43+,
GBM 21.1+, Vulkan headers/loader 1.2.182+, Xwayland development files, and the
remaining libraries listed by the check. Older stable distributions may need a
separate dependency prefix supplied via `PKG_CONFIG_PATH`. Skipping package
installation does not waive those requirements. Distro packaging and hardware
tests on Debian/Ubuntu, Arch, and openSUSE remain outstanding.

For NVIDIA, install a CUDA toolkit with `nvcc >= 12` before building Prism. The
installer accepts `PRISM_ENABLE_CUDA=AUTO|ON|OFF` (default `AUTO`) and `CUDACXX`
for an explicit compiler path. It fails when NVIDIA is detected or CUDA is
requested but the compiler is missing. AMD uses VAAPI and does not need CUDA.
The installer verifies CUDA compilation before configuring Prism. It tries the
system GCC, then installed versioned GCC executables (newest first), and selects
one that passes. Set `CUDAHOSTCXX` to choose a host compiler explicitly; an
explicit selection is never replaced automatically. For example, when the CUDA
toolkit rejects GCC 16 but GCC 15 is installed:

```bash
CUDAHOSTCXX=/usr/bin/gcc-15 bash install.sh
```

If none passes, install a host compiler supported by the toolkit and rerun.
Bypassing the toolkit's version check requires the explicit
`PRISM_CUDA_ALLOW_UNSUPPORTED_COMPILER=1` option and still must pass the compile
probe. Unsupported compilers may fail to build or produce incorrect runtime
behavior. `PRISM_ENABLE_CUDA=OFF` intentionally disables NVIDIA headless HDR.

Enable HDR in Iris and launch an app whose streaming mode is **Headless**. The
client must have an HDR10 display and an HEVC Main10 or AV1 10-bit decoder. The
host needs a Vulkan renderer that supports wlroots color transforms, GPU DMA-BUF
sharing, and an encoder capable of 10-bit HEVC or AV1. Hardware capture/encoding
is required for this path; the software capture path reduces RGB to eight bits.

Native Wayland games must submit HDR surfaces through `color-management-v1`.
For Proton games, select a Wine Wayland/HDR-capable compatibility build, such as
a compatible GE-Proton release. Prism sets `PROTON_ENABLE_WAYLAND=1`,
`PROTON_ENABLE_HDR=1`, and `DXVK_HDR=1` inside HDR app/Steam sessions. Game-specific
HDR settings still apply. X11-only games remain SDR inside the HDR output.
See [GE-Proton's HDR instructions](https://github.com/GloriousEggroll/proton-ge-custom/blob/master/README.md).

SDR sessions use the system labwc. An HDR request without `prism-labwc` fails
before stopping the existing session. Capture fails if the selected private
output lacks verified BT.2020/PQ colorimetry or produces an eight-bit buffer.

## Why a private compositor build is required

The pinned labwc 0.20.1 supports HDR rendering, but wlroots 0.20.1's headless
backend does not advertise HDR primaries/transfer functions or accept an output
image description. The small patch in
`contrib/virtual-session/patches/wlroots-headless-hdr.patch` adds those capabilities
to the virtual output. Labwc still checks Vulkan color transforms and whether
the GPU accepts a 10-bit output buffer before enabling HDR.

`build-headless-compositor.sh` pins both upstream commits and statically links
the patched wlroots into `prism-labwc`. It does not replace the host's labwc or
shared wlroots library. Build files live in `cmake-build-headless-compositor`.
Upstream references: [labwc output configuration](https://github.com/labwc/labwc/blob/529fc382da8f9b6bc4dcea720fd3561e605abd91/src/output.c),
[wlroots headless output](https://gitlab.freedesktop.org/wlroots/wlroots/-/blob/a7f20066270c042799ae70b71dfa4d561ba85121/backend/headless/output.c).

## Bugs found and addressed

| Area | Finding | Change |
| --- | --- | --- |
| HDR request | Session environment unconditionally forced SDR; capture never supplied HDR metadata. | Preserve the request, use the HDR compositor, read actual output colorimetry, verify captured precision, and supply metadata. |
| Xwayland | Startup waited for an X socket while the default lazy Xwayland policy could wait for its first application. | Enable Xwayland persistence before starting the compositor. |
| Output geometry | Inherited output count/scale/transform could conflict with the one-output capture contract. | Create one output and explicitly set its scale, transform, position, and mode. |
| Mode readiness | A matching mode on another output could satisfy the text search; advertised noncurrent modes overwrote the active capture size. | Match only the selected output and consume only current `wl_output` modes. |
| GPU selection | Compositor allocation could choose a different GPU from capture/encoding. | Pass Prism's selected render node to the compositor. |
| Audio startup | Default settings waited for a stream-created sink before stream startup could finish. | Route to the already-created `prism-stream` sink; retain explicit configured sinks. |
| Delayed frames | A timeout could launch a second screencopy request sharing the first request's buffer state. | Retain one request across timeouts and release pending protocol objects on teardown. |
| Buffer import | Only the first DMA-BUF plane was exported, breaking modifiers with auxiliary planes. | Export each plane with its own descriptor, stride, and offset. |
| Buffer allocation | Failure of explicit modifier allocation fell back to an unrestricted layout the compositor might reject. | Use only negotiated implicit/linear fallbacks and preserve their import modifier. |
| Frame orientation | Capture ignored the compositor's vertical-inversion flag. | Carry orientation with each frame and reverse rows during conversion without reducing HDR precision. |
| Build selection | A missing toolkit silently disabled NVIDIA GPU capture; distro library failures appeared deep in the compositor build. | Check CUDA selection and report missing/outdated compositor dependencies before building Prism. |
| SDK headers | FFmpeg's bundled NVENC headers could shadow Prism's pinned SDK and fail its compatibility guard. | Keep the pinned headers first in the include search path. |
| Descriptor lifetime | GBM's borrowed render-node descriptor was never closed. | Close it after destroying the GBM device and mark it close-on-exec. |
| Compositor failure | Unbounded roundtrips and ignored dispatch errors could stall initialization. | Bound sync waits and check display errors. |
| Capture isolation | A missing named output could fall through to numeric selection; an empty override file permitted desktop fallback. | Require the exact private output and reject empty overrides. |
| Desktop environment | An inherited labwc activation override could change the desktop's D-Bus/systemd environment. | Explicitly disable activation-environment updates in the private compositor. |

## Validation and remaining limits

Prism, its web UI, and the isolated compositor were built on Fedora 44 ARM64 in a
local Docker container on the Mac. The full Prism build enabled VAAPI, Vulkan,
Wayland, KWin, portal, and X11 support; CUDA and the tray were disabled in that
container build. Installation into a test prefix and the installed binary's
`--version` smoke check also succeeded.

Twelve regression tests exercise the Wayland client and allocation rules,
using a small test compositor for protocol cases,
including metadata values, rejection of SDR/failed descriptions, bit-depth checks,
delayed frames, frame orientation, current-mode selection, negotiated buffer layouts, and a stalled compositor. Shell tests cover
SDR/HDR launcher configuration, geometry selection, audio readiness, and existing
ownership/cleanup policies, CUDA build selection, and dependency preflight. The updated Wayland capture sources were compiled
with VAAPI and CUDA paths enabled, as were the GL, CUDA, and VAAPI converter sources.
Two offscreen OpenGL tests pass using Mesa software rendering, checking exact 10-bit
pixel values with and without row inversion. Iris's non-root debug APK and its 26
existing unit tests also pass.

The Mac development environment has no Linux DRM GPU or connected HDR client.
An end-to-end HDR game stream, GPU modifier compatibility, Steam/Proton behavior,
and visual HDR calibration still need validation on the actual host. The CUDA
C++ converter was separately checked against the full build's actual FFmpeg and
pinned NVENC headers. NVCC compilation and NVIDIA driver interoperability were
not exercised here. The complete Prism unit-test suite was not run; validation
used the targeted Wayland/GL tests and six shell integration suites.

The headless path still requires a systemd user manager, Xwayland for Steam/X11,
and functioning GPU DMA-BUF capture. It does not implement a shared-memory capture
fallback, native touch/pen forwarding, or physical-monitor VRR. The lifecycle
keeps its existing ownership checks and rollback behavior. Failed sessions report
details in `~/.local/state/prism-headless.log` and the Prism service journal.

The existing GL/CUDA converter still selects NVIDIA device zero. On systems with
several GPUs, use the matching `adapter_name` render node in Prism's settings;
automatic selection of another NVIDIA encoder is not implemented.

On the Fedora/KDE/NVIDIA test host, validate an SDR session first, then enable HDR
in Iris and stream a native Wayland HDR app or a compatible Proton game using
10-bit HEVC/AV1. Check that HDR content is distinguishable from the SDR desktop,
keyboard/mouse and audio remain in the private session, and stopping/reconnecting
at a different resolution leaves no compositor, input bridge, or audio loopback
behind. Repeat the same sequence on an AMD host using VAAPI. The physical
desktop's display mode and HDR setting should remain unchanged throughout.
