# Prism

<p align="center"><img src="prism.svg" width="128" alt="Prism logo"></p>

**Prism** is a fork of [Sunshine](https://github.com/LizardByte/Sunshine) (the self-hosted
game stream host for Moonlight) that makes **capture modes a first-class, per-app setting**
on Linux/Wayland.

Stock Sunshine can only capture the session it runs in. Prism lets each app decide *what*
gets streamed — your real desktop, a client-sized virtual display, or a fully headless
labwc session running next to (and never touching) your desktop — all under a
**single paired Moonlight entry**. No dummy plugs, no second GPU, no second Sunshine
instance.

## Capture modes

Every app gets a **Capture Mode** (dropdown in the web UI app editor, stored as
`prism-capture` in `apps.json`):

| Mode | What it does |
|---|---|
| **Default (mirror)** | Streams your desktop as-is. Resolution, FPS, bitrate and codec follow the client's settings automatically (Sunshine scales the capture); host display settings are untouched. |
| **Virtual display** | Creates a KWin virtual output at the client's *exact* resolution and refresh rate, streams it, and turns the physical monitor(s) off for the session. SDR only (KWin limitation). |
| **Headless (labwc)** | Runs a private [labwc](https://labwc.github.io/) compositor with a headless wlroots output at the client's exact resolution/FPS. Prism captures that output directly through wlroots screencopy. Works with **any** app — its command runs inside the owned Wayland/Xwayland session. Your physical monitors are untouched. If the app name contains "steam", Prism additionally hands Steam from the desktop into the session, launches Big Picture, and returns Steam to the desktop when the stream ends. |
| **Portal output** | Captures a specific named output through the XDG portal. |

### Name-based defaults

Don't want to pick a mode? The app name decides:

- contains **"virtual"** → Virtual display
- contains **"headless"** or **"steam"** → Headless (Steam behavior only when "steam")
- anything else (e.g. **Desktop**) → mirror

Apps with no command launch nothing — mirror and virtual modes simply stream the
(virtual) desktop.

### Default apps

Fresh installs include four ready-made apps:

- **Desktop (Mirror)** — your desktop as-is
- **Desktop (Virtual)** — client-exact resolution on a virtual output
- **Desktop Headless** — empty private labwc session
- **Steam Headless** — headless SteamOS (Big Picture) session

### Steam game sync

Steam is an **optional dependency**. It is required only for Steam game discovery and
synchronization, the **Steam Headless** entry, and launching synchronized Steam games.
When Steam is installed, its games are synced into the app list automatically (`src/steam_games.*`
parses `libraryfolders.vdf` + `appmanifest_*.acf`; Proton/runtimes are filtered out).
The list is re-synced on every client applist request, so installs and uninstalls show
up without a restart, and box art is pulled from Steam's library cache (converted to PNG
via ffmpeg into `~/.cache/prism/covers`).
Launching one brings up a lightweight headless Steam session (a silent background
Steam client — not the heavy SteamOS/Deck UI session) and includes the game URL on
Steam's initial command line inside the isolated headless session. The appid is handed
to the session via `PRISM_STEAM_APP_ID`; `prism-steam-game.sh` monitors the resulting
game and exits with it, so closing the game closes the stream. Ending the stream either
way tears the session down. Synced apps are marked `prism-steam` in the Applications
tab; editing one imports it as a regular override app, and an app you define yourself
always wins on name collision.

With `gamepad = auto`, Prism honors the controller type and capabilities reported by
the Moonlight client. A PlayStation controller or a motion-capable client can therefore
appear as a virtual DualSense in Steam's Controller Settings. Steam Input may still
translate that DualSense to Xbox/XInput for individual games; this is expected and
preserves compatibility with games that do not support native DualSense input.
Clients that advertise one or more rear controls are automatically exposed as a
DualSense Edge instead. Their four Moonlight extra-button slots appear on Linux as the
Edge's Fn1, Fn2, left paddle, and right paddle buttons, so each can be assigned in
Steam Input. Set `gamepad = ds5-edge` to force that device type.

## Status

⚠️ **Currently validated on Fedora 44 (KDE Plasma 6, Wayland, NVIDIA) only.** The design is
GPU-agnostic (capture routing only; encoding stays on Sunshine's normal nvenc/vaapi/software
paths) — **testers wanted!** If you try Prism on another distro, GPU, or desktop environment,
please report back in [Issues](https://github.com/atgehrhardt/prism/issues).

## Compatibility

Nothing is Fedora- or NVIDIA-locked, but features vary by desktop environment:

| Feature | Requirement | Notes |
|---|---|---|
| **Mirror (default) capture** | Any Sunshine-supported setup | Stock Sunshine capture paths (PipeWire/portal, KMS, X11, kwingrab) — works on GNOME, KDE, wlroots, X11, any GPU. |
| **Headless (labwc) mode** | labwc with its headless wlroots backend, wlr-randr, Xwayland, bubblewrap, and a systemd user manager | DE-independent: labwc is the session's only compositor. Prism captures its exact `HEADLESS-1` output with DMA-BUF-capable wlroots screencopy and sends keyboard/mouse input through labwc's virtual-input protocols. Bubblewrap gives headless Steam a private device view so host controllers cannot displace the streamed controller. Non-systemd hosts retain other supported capture modes, but headless startup fails safely. |
| **Steam game sync / headless Steam** | Same as headless | Any distro with Steam installed. |
| **Audio separation** (`prism-stream`/`prism-virtual`/`prism-headless` sinks, `prism_default_sink`) | PipeWire (via `pactl`) | Distro- and DE-agnostic, but **not** PulseAudio- or ALSA-only systems. |
| **Virtual display mode** | KDE Plasma 6 (Wayland) | Relies on KWin virtual outputs (`krfb-virtualmonitor`). No equivalent on other DEs yet. |
| **Physical-display mode/HDR switching** (`prism-desktop-session.sh`, `prism-kwin-mode`) | KDE Plasma 6 | Built on `kscreen-doctor` / kde-output-management-v2; silently no-ops elsewhere. |

In short: on non-KDE desktops you keep mirror capture, headless sessions, Steam sync, and
audio separation; you lose virtual-display mode and physical-display switching. On any
PipeWire distro with KDE Plasma 6, everything should work.

## Install (Fedora 44)

```bash
curl -fsSL https://raw.githubusercontent.com/atgehrhardt/prism/master/install.sh | bash
```

The Fedora source installer uses only Fedora's enabled repositories. It does not install
Steam or enable third-party repositories; in particular, RPM Fusion is no longer required
solely to satisfy Steam. Install Steam separately if you want Steam discovery, synchronized
game launching, or Steam Headless. The default Steam Headless entry remains visible and
reports a clear runtime error if selected without Steam installed.

Installs dependencies, builds Prism, and sets up:

- `prism.service` — the stream host (`~/.local/bin/prism`)
- `prism-headless-session.service` — owns the private labwc compositor and Xwayland
- `prism-steam-restore.service` — cancelable five-second handoff back to desktop Steam
- `prism-input-bridge.service` — transiently routes Prism's virtual keyboard/mouse
  devices into labwc, exclusively while one headless session is active
- `prism-headless-steam.service` — owns Steam and its session-launched process tree
- the four default apps in `~/.config/prism/apps.json` (existing file is backed up;
  other custom apps are preserved)

Then open `https://<host>:47990`, set credentials, and pair Moonlight as usual.

## Update

```bash
~/Dev/prism/update.sh
```

Fetches the latest upstream Sunshine release tag, rebases the `master` branch onto
it, rebuilds, and reinstalls. Prism is a **hard fork** (the rebrand lives in source), so a
rebase can occasionally conflict in rebranded files — the script stops and tells you how to
resolve. The functional Prism layer stays small.

## Uninstall

```bash
systemctl --user stop prism.service prism-input-bridge.service prism-headless-session.service
systemctl --user disable prism.service
rm -f ~/.local/bin/prism \
      ~/.local/bin/prism-*.sh \
      ~/.local/bin/prism-input-bridge \
      ~/.local/bin/prism-kwin-mode \
      ~/.config/systemd/user/prism.service \
      ~/.config/systemd/user/prism-headless-session.service \
      ~/.config/systemd/user/prism-input-bridge.service \
      ~/.config/systemd/user/prism-headless-steam.service
systemctl --user daemon-reload
```

To also remove the input-bridge udev rule and wipe configuration, credentials, and app
data (full clean slate):

```bash
sudo rm -f /etc/udev/rules.d/61-prism-input.rules && sudo udevadm control --reload
rm -rf ~/.config/prism ~/.cache/prism
```

## How it works

- **Capture override patch** (`src/platform/linux/misc.cpp`): when a stream's display is
  initialized, Prism checks `$XDG_RUNTIME_DIR/prism-capture-override`.
  `portal:<output>` captures a named portal output. A strict
  `wlroots:<session>` contract is resolved through version-four ownership state to one
  exact labwc Wayland socket, `HEADLESS-1`, and client mode. Invalid, stale, unavailable,
  or mismatched overrides fail capture instead of selecting another compositor, desktop,
  or capture backend.
- **Per-app modes** (`src/process.cpp`): the `prism-capture` field (with name-based
  defaults) drives session bring-up/teardown before/after each stream — no prep commands
  to write yourself. A global `prism_capture_default` (Settings → General → Default
  Streaming Mode) covers apps with no explicit mode, and the Applications tab supports
  multiselect bulk changes (backed by `POST /api/apps/capture`, matched by name).
- **Headless session** (`contrib/virtual-session/prism-headless-*.sh`): launches labwc
  directly on `WLR_BACKENDS=headless`, with no inherited desktop display. `wlr-randr`
  applies the client's exact mode to `HEADLESS-1`. One ten-second deadline covers the
  owned Wayland/Xwayland sockets, exact output mode, required screencopy/DMA-BUF/input
  protocols, and virtual-input readiness. Steam readiness has a separate ten-second
  process check. State and the strict capture override are published atomically only
  after compositor and input readiness; failures roll back without automatic retry or
  capture-mode fallback. Xwayland remains necessary for Steam, Proton, and X11 apps;
  native Wayland apps use the private labwc socket directly. Steam uses a separate
  session-owned service and a bubblewrap mount namespace that hides host controllers
  while leaving Prism's dynamically created virtual controllers visible.
- **Virtual display** (`contrib/virtual-session/prism-virtual-*.sh`): creates/removes the
  KWin virtual output via `krfb-virtualmonitor` (KWin gates virtual outputs behind its
  security-context system; krfb is associated explicitly with its trusted
  `org.kde.krfb.virtualmonitor` desktop entry) and disables physical outputs meanwhile.
  Output discovery has one ten-second deadline. A failed or interrupted launch rolls back
  its exact monitor, audio, capture override, and recorded physical-output changes; it
  never falls back to capturing another display.
- **Input bridge** (`contrib/virtual-session/prism-input-bridge.c`): a transient Wayland
  client connects only to the owned labwc socket and creates wlroots virtual pointer and
  keyboard devices before publishing readiness. It grabs only Prism-owned
  `* passthrough` evdev devices and only while the exact matching capture override exists.
  Removing or changing the override immediately releases the grabs. Controllers remain
  direct uinput devices and are visible to Steam through normal Linux hotplug. Client
  touch emulated as an absolute mouse remains supported; native multi-touch and pen
  injection are outside this headless path.
- **Audio separation** (`contrib/virtual-session/prism-*-audio.sh`): Sunshine captures a
  dedicated `prism-stream` null sink (`audio_sink` in `prism.conf`, set by `install.sh`),
  and each capture mode routes the right audio into it. Exactly one active loopback may
  feed `prism-stream` for the current capture mode; startup and teardown remove tracked
  modules and exact duplicate routes before creating a replacement. **Mirror/portal** streams loop the
  physical sink's monitor in (stock behavior: audio on stream and host speakers).
  **Virtual display** selects a `prism-virtual` sink as the system default for the session
  (physical outputs are off, so everything belongs on the stream) and loops it in.
  **Headless** session apps output to a dedicated `prism-headless` sink (`PULSE_SINK` plus a
  cgroup-aware routing watchdog), which is looped in, while the desktop's default sink stays
  on the physical output — desktop audio is never captured, and desktop apps keep playing
  locally — mirroring how inputs are separated. Set `prism_default_sink = <sink-name>` in
  `prism.conf` to force a specific default sink whenever any stream ends
  (e.g. your speakers, if the physical output varies); without it the sink
  recorded at stream start is restored.
- **Crash recovery** (`contrib/virtual-session/prism-session-cleanup.sh`): Prism reconciles
  stale headless units/scopes, virtual displays, session sinks, loopbacks, overrides, and
  supported virtual gamepads synchronously before initializing display, input, encoders,
  discovery, or network listeners. Both native and AppImage user services also run the
  reconciler as `ExecStopPost` after graceful exits and crashes. Confirmed resources that
  cannot be removed block startup and are retried by systemd; failed physical-output
  restoration remains recorded so intentionally disabled, unrecorded outputs are never
  changed.
- **`prism-kwin-mode`** (`contrib/virtual-session/prism-kwin-mode.c`): native
  kde-output-management-v2 client for output modes/HDR/custom modes (used by the optional
  `prism-desktop-session.sh` for physical-display switching; not wired up by default).

## Caveats

- **HDR**: private labwc headless sessions are SDR. Desktop HDR capture depends on your
  portal/compositor. KWin virtual outputs are marked HDR/WCG-capable for HDR clients
  (needs Plasma 6).
- **VRR**: private headless outputs have no physical VRR target. KWin virtual outputs
  still get `vrrpolicy.always`.
- **Virtual outputs match the client's refresh rate** (a custom mode is added via
  `kscreen-doctor` when the client requests more than the 60Hz default).
- **Physical-display resolution switching is limited by your driver**: e.g. NVIDIA + DSC
  panels reject compositor-generated modelines. Mirror mode handles this with GPU scaling
  instead — visually lossless at the client.
- The udev rule `contrib/virtual-session/61-prism-input.rules` (installed by `install.sh`,
  needs sudo) grants the session user read access to Sunshine's evdev nodes.

## Latency notes

What is already latency-optimal, verified before changing anything:

- **Encoder**: nvenc runs with `NV_ENC_TUNING_INFO_ULTRA_LOW_LATENCY` and defaults to the
  fastest preset (P1) — nothing to gain here.
- **Audio**: the headless audio separation loopback runs at 20 ms.
- **Refresh pacing**: virtual outputs and headless sessions run at the client's exact FPS.

Applied:

- **Direct wlroots screencopy** captures the private labwc output without a portal or
  nested compositor boundary and preserves DMA-BUF GPU paths.

Explored and deliberately **not** applied (unsafe or not measurable):

- Encoder two-pass / B-frame tuning — already handled by the ultra-low-latency tune.

## Credits

All the heavy lifting is upstream [Sunshine](https://github.com/LizardByte/Sunshine) by
LizardByte and its contributors. Prism builds on it; see `NOTICE`/`LICENSE`.
