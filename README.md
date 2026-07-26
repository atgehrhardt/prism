# Prism

<p align="center"><img src="prism.svg" width="128" alt="Prism logo"></p>

**Prism** is a fork of [Sunshine](https://github.com/LizardByte/Sunshine) (the self-hosted
game stream host for Moonlight) that makes **capture modes a first-class, per-app setting**
on Linux/Wayland.

Stock Sunshine can only capture the session it runs in. Prism lets each app decide *what*
gets streamed — your real desktop, a client-sized virtual display, or a fully headless
gamescope session running next to (and never touching) your desktop — all under a
**single paired Moonlight entry**. No dummy plugs, no second GPU, no second Sunshine
instance.

## Capture modes

Every app gets a **Capture Mode** (dropdown in the web UI app editor, stored as
`prism-capture` in `apps.json`):

| Mode | What it does |
|---|---|
| **Default (mirror)** | Streams your desktop as-is. Resolution, FPS, bitrate and codec follow the client's settings automatically (Sunshine scales the capture); host display settings are untouched. |
| **Virtual display** | Creates a KWin virtual output at the client's *exact* resolution and refresh rate, streams it, and turns the physical monitor(s) off for the session. SDR only (KWin limitation). |
| **Headless (gamescope)** | Brings up a fully headless [labwc](https://github.com/labwc/labwc) + [gamescope](https://github.com/ValveSoftware/gamescope) session at the client's resolution/FPS and streams that. Works with **any** app — its command runs inside the session. Your physical monitors are untouched. If the app name contains "steam", it additionally quits Steam on the desktop, launches Steam Big Picture (SteamOS mode) in the session, and returns Steam to the desktop when the stream ends. |
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
- **Desktop Headless** — empty headless gamescope session
- **Steam Headless** — headless SteamOS (Big Picture) session

### Steam game sync

Installed Steam games are synced into the app list automatically (`src/steam_games.*`
parses `libraryfolders.vdf` + `appmanifest_*.acf`; Proton/runtimes are filtered out).
Launching one brings up the same headless SteamOS session as **Steam Headless** and starts
the game inside it (the appid is handed to the session's own Steam via `PRISM_STEAM_APP_ID`,
so there is no race with the Big Picture boot); ending the stream tears the session — and the
game — down. Synced apps are marked `prism-steam` in the Applications tab; editing one imports
it as a regular override app, and an app you define yourself always wins on name collision.

## Status

⚠️ **Currently validated on Fedora 44 (KDE Plasma 6, Wayland, NVIDIA) only.** The design is
GPU-agnostic (capture routing only; encoding stays on Sunshine's normal nvenc/vaapi/software
paths) and should work on other Wayland desktops and distros — **testers wanted!** If you
try Prism on another distro, GPU, or desktop environment, please report back in
[Issues](https://github.com/atgehrhardt/prism/issues).

## Install (Fedora 44)

```bash
curl -fsSL https://raw.githubusercontent.com/atgehrhardt/prism/master/install.sh | bash
```

Installs dependencies, builds Prism, and sets up:

- `prism.service` — the stream host (`~/.local/bin/prism`)
- `prism-labwc.service` — persistent headless compositor (socket `wayland-prism`)
- `prism-input-bridge.service` — routes Sunshine's virtual keyboard/mouse/touch into
  headless sessions (exclusively, only while one is active)
- the four default apps in `~/.config/sunshine/apps.json` (existing file is backed up;
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

## How it works

- **Capture override patch** (`src/platform/linux/misc.cpp`): when a stream's display is
  initialized, Prism checks `$XDG_RUNTIME_DIR/prism-capture-override` — `portal:<output>`
  captures a named output via the portal; otherwise the named Wayland socket is captured
  via Sunshine's wlroots backend.
- **Per-app modes** (`src/process.cpp`): the `prism-capture` field (with name-based
  defaults) drives session bring-up/teardown before/after each stream — no prep commands
  to write yourself. A global `prism_capture_default` (Settings → General → Default
  Streaming Mode) covers apps with no explicit mode, and the Applications tab supports
  multiselect bulk changes (backed by `POST /api/apps/capture`, matched by name).
- **Headless session** (`contrib/virtual-session/prism-headless-*.sh`): sizes the headless
  output to the client (`wlr-randr`), launches gamescope at the client's mode, records the
  session sockets for app commands, and tears everything down — serialized with a lock so
  a mid-setup disconnect can't leave orphans.
- **Virtual display** (`contrib/virtual-session/prism-virtual-*.sh`): creates/removes the
  KWin virtual output via `krfb-virtualmonitor` (KWin gates virtual outputs behind its
  security-context system; krfb is a trusted app) and disables physical outputs meanwhile.
- **Input bridge** (`contrib/virtual-session/prism-input-bridge.c`): labwc can't claim a
  libinput seat while a desktop owns it, but speaks `zwlr_virtual_pointer_v1` /
  `zwp_virtual_keyboard_v1`; the bridge re-injects Sunshine's uinput events there and holds
  an exclusive `EVIOCGRAB` only during headless streams.
- **Audio separation** (`contrib/virtual-session/prism-headless-audio.sh`): headless session
  apps output to a dedicated `prism-headless` null sink (`PULSE_SINK`), which is looped into
  Sunshine's capture sink; the guard keeps the desktop's default sink on the physical output
  so desktop audio is never captured into the stream — mirroring how inputs are separated.
- **`prism-kwin-mode`** (`contrib/virtual-session/prism-kwin-mode.c`): native
  kde-output-management-v2 client for output modes/HDR/custom modes (used by the optional
  `prism-desktop-session.sh` for physical-display switching; not wired up by default).

## Caveats

- **HDR**: attempted via `gamescope --hdr-enabled` for HDR clients in headless mode
  (depends on labwc color-management support); desktop HDR capture depends on your
  portal/compositor. KWin virtual outputs are marked HDR/WCG-capable for HDR clients
  (needs Plasma 6).
- **VRR**: headless sessions run gamescope with `--adaptive-sync`, and KWin virtual
  outputs get `vrrpolicy.always`, so frame pacing follows the content instead of a
  fixed vblank.
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

- **gamescope `--rt`** for headless sessions (realtime scheduling on the compositor
  thread; degrades gracefully without rtkit).

Explored and deliberately **not** applied (unsafe or not measurable):

- `gamescope --immediate-flips` — can capture partial/torn frames.
- Encoder two-pass / B-frame tuning — already handled by the ultra-low-latency tune.
- Removing the labwc↔gamescope compositor hop (gamescope headless backend as the capture
  target directly) would cut ~1 frame of queueing but restructures the whole session stack
  (input bridge, socket layout); left as future work.

## Credits

All the heavy lifting is upstream [Sunshine](https://github.com/LizardByte/Sunshine) by
LizardByte and its contributors. Prism builds on it; see `NOTICE`/`LICENSE`.
