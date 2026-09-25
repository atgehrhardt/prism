# PyroWave streaming

Prism and Iris implement an experimental, explicitly selected PyroWave path for
Linux-to-Android streaming. Existing automatic codec selection is unchanged.
Iris refuses an unsupported PyroWave request instead of choosing H.264, changing
chroma resolution, or disabling HDR.

## Requirements and settings

Build Prism with `PRISM_ENABLE_PYROWAVE=ON` (the default) and Vulkan support.
CMake builds a pinned upstream C API in its build directory and installs the
shared library alongside Prism. The first build needs Python 3, Git, CMake,
Ninja or the selected CMake generator, and network access to the pinned sources.
Set `PRISM_ENABLE_PYROWAVE=OFF` to build without this dependency.

Use PipeWire DMA-BUF capture (`kwin` or `portal`), Vulkan KMS capture, or Wayland
DMA-BUF screencopy (including Prism's private headless labwc session). Memory-only
PipeWire buffers, X11, and other capture paths are not supported. The render device must resolve to a DRM render-node
path. Exporting capture synchronization fences requires Linux DMA-BUF sync-file
support. Unsupported pixel formats, layouts, or cross-GPU imports fail explicitly.
Separate KMS cursors are composited on the GPU; PipeWire and Wayland screencopy
supply an embedded cursor. Scaling preserves the display aspect ratio.

In Iris's video settings, select **PyroWave (experimental, strict)**. Enable
**PyroWave full chroma (4:4:4)** for full-resolution chroma; otherwise 4:2:0 is
used. The existing HDR setting requests HDR10. SDR uses full-range BT.709;
HDR uses full-range BT.2020/PQ with 16-bit intermediate components and a 10-bit
Android presentation surface. Chroma is centered with midpoint 0.5.

The Android library is packaged for arm64-v8a and x86_64 and loaded only on
Android 8 or newer. Runtime initialization additionally requires Vulkan 1.3,
PyroWave's subgroup features, and appropriate image-format support. HDR requires
an HDR10 display, a PQ swapchain format, and HDR metadata support. Device names
alone are not used as capability checks. Iris keeps its existing minimum Android
version and codecs for other devices.

Android presentation pre-rotates both the image and swapchain dimensions into
the panel's natural orientation. The viewport preserves the video aspect ratio
after rotation, including on portrait-native panels used in landscape. Renderer
initialization logs the negotiated video size, window size, buffer size, viewport,
and surface transform under `IrisPyroWave` to diagnose scaling independently of
compression quality.

PyroWave uses much higher bitrates than inter-frame codecs. Iris allows bitrate
entry up to 1,000 Mbps; this is an input range, not a promise that every
resolution/FPS/packet-size combination is transportable. Prism computes the
initial encoder budget from the effective stream FPS (including Warp multipliers)
after existing audio/FEC bandwidth adjustments. Subsequent frames earn byte
credits from elapsed capture time, so a 120 FPS capture does not lose half its
quality budget when Warp requests 240 FPS. Credits are capped at one transport-safe
frame; pauses cannot accumulate an oversized frame or a prolonged burst. Requests
whose initial budget exceeds four FEC blocks are rejected. The limit accounts
conservatively for envelope overhead. Actual
encoded frames are checked again before transmission; FEC is never silently
disabled for PyroWave.

## Protocol version 1

Both repositories pin upstream PyroWave to
`186f0393b77f7755953b5ecde994bb1cec2e4155`, using Granite
`b6cffd5ce81f540f0855e6778428483e14763d9b`. Protocol compatibility and the upstream
C API version are separate checks.

Discovery includes `PrismPyroWaveVersion=1` when the encoder initializes on the
configured GPU. Server codec bits `0x01000000`, `0x02000000`, `0x04000000`, and
`0x08000000` describe SDR420, HDR420, SDR444, and HDR444. Capture compatibility
is checked again when the session creates its display and imports its first
frame; discovery does not guarantee a particular display/capture layout.

RTSP DESCRIBE/ANNOUNCE use `x-prism-pyrowave.version:1`. ANNOUNCE sets
`x-nv-vqos[0].bitStreamFormat:3`; existing dynamic-range and chroma attributes
select the mode. Iris advertises exactly one of native format bits `0x10000`,
`0x20000`, `0x40000`, and `0x80000`. Missing/unknown versions or unsupported
modes terminate negotiation.

Each existing GameStream video frame carries one envelope. All integers are
little-endian; no C struct layout is transmitted:

| Bytes | Meaning |
| --- | --- |
| 0–3 | ASCII `PRW1` |
| 4 | Protocol version, 1 |
| 5 | Mode flags: bit 0 HDR, bit 1 full chroma |
| 6–7 | Reserved, zero |
| 8–11 | Packet count |
| Remaining | Repeated uint32 packet length followed by that upstream packet |

Envelopes are bounded to 4 MiB; each upstream packet is at most 65,536 bytes,
4-byte aligned, and at least 8 bytes long. The receiver validates the complete
envelope and upstream block framing before passing any packet to the codec.
Blocks must make forward progress and match the negotiated dimensions, chroma,
and frame sequence. These limits are additional
to the stricter per-session FEC capacity. Upstream packet boundaries are
preserved independently of UDP fragmentation. Existing encryption, FEC, frame
numbers, and timestamps remain in use. Every frame is independent; incomplete
network frames are discarded, and no partial-frame decoding is performed.

Iris applies its protocol patch to a generated build-directory copy of
moonlight-common-c. The upstream submodule remains unchanged. The protocol
header and dependency bootstrap script are intentionally mirrored between the
two repositories and must be updated together.

## Validation

Run `cmake-build-<name>/tests/test_prism --gtest_filter='PyroWave*'` for framing
and rate-control tests, including cadence changes, fractional byte credits,
transport ceilings, and pause recovery. Set `PRISM_TEST_GPU=1` to additionally round-trip generated
DMA-BUF images through encoding and decoding, covering all four modes and
separate cursor composition, aspect-fit black borders, full-range SDR component
values, adaptive budgets, and rejected input modes
without capturing the desktop. Set `PRISM_TEST_WAYLAND_DISPLAY` to a dedicated
test compositor socket to additionally capture and encode real Wayland DMA-BUF
frames in both chroma modes.

Iris's `testPyroWaveProtocol` verifies native patch application from Gradle's
working directory, including repeated builds and skipped-patch failures. It also
compiles native presentation tests covering all rotations and mirrors, full-screen
coverage, aspect-fit borders, and invalid dimensions. These tests need a host C++17
compiler and Vulkan headers (system headers or the bootstrapped PyroWave checkout).
`testNonRootDebugUnitTest` covers strict mode/version selection;
`assembleNonRootDebug` builds and packages both native 64-bit ABIs. Build scripts
require Python 3, Git, CMake, and Ninja on the build host. Checked-in SPIR-V headers
are generated from adjacent shader source using `glslc`; regenerate them when
changing a shader.

The performance overlay supports the existing compact mode and app traffic
counters. Decode timing uses completed GPU timestamp queries; unavailable
measurements are displayed as unavailable. Display submissions and busy-frame
drops are reported separately from network loss.

Physical Adreno and Mali testing is still required for Android presentation,
HDR accuracy, sustained 1080p60/120 operation, and latency. Also validate live
PipeWire/KMS capture, reconnects, surface changes, backgrounding, encrypted
streaming, packet loss, and existing codecs. An APK build or GPU codec round-trip
alone does not establish end-to-end streaming performance.
