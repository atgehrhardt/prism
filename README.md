# Prism

<p align="center"><img src="prism.svg" width="128" alt="Prism logo"></p>

**Prism** is a fork of [Sunshine](https://github.com/LizardByte/Sunshine) (the self-hosted
game stream host for Moonlight) that adds **per-app capture override** on Linux/Wayland.

With stock Sunshine, one instance can only capture the session it runs in. Prism lets an
app's stream be redirected to a *different* Wayland compositor — which enables a fully
headless, fully virtual gaming session alongside your normal desktop stream, under a
**single paired Moonlight entry**:

| Moonlight app | What it does |
|---|---|
| **Desktop** | Pure mirror of your desktop as-is. Resolution, FPS, bitrate and codec follow the client's settings automatically (Sunshine scales the capture); host display settings are untouched. |
| **SteamOS (Headless)** | Quits Steam on your desktop, starts a headless [labwc](https://github.com/labwc/labwc) compositor + [gamescope](https://github.com/ValveSoftware/gamescope) at your client's exact resolution/FPS, launches Steam Big Picture in SteamOS mode, and streams that. Your physical monitors are untouched. When the stream ends (or the client disconnects), everything is torn down and Steam reopens on your desktop. |

| **Desktop (Virtual)** | Creates a KWin virtual output at the client's exact resolution, streams it, and turns the physical monitor off for the session (60Hz/SDR — KWin limitation). |

No dummy plugs, no second GPU, no second paired device.

## Status

⚠️ **Currently validated on Fedora 44 (KDE Plasma 6, Wayland, NVIDIA) only.** The design is
GPU-agnostic (capture routing only; encoding stays on Sunshine's normal nvenc/vaapi/software
paths) and should work on other Wayland desktops and distros — **testers wanted!** If you try
Prism on another distro, GPU, or desktop environment, please report back in
[Issues](https://github.com/atgehrhardt/prism/issues).

## Install (Fedora 44)

```bash
curl -fsSL https://raw.githubusercontent.com/atgehrhardt/prism/virtual-capture/install.sh | bash
```

This installs dependencies, builds Prism, and sets up:

- `prism.service` — the stream host (binary: `~/.local/bin/prism`)
- `prism-labwc.service` — persistent headless labwc compositor (socket `wayland-prism`)
- `prism-input-bridge.service` — forwards Sunshine's virtual keyboard/mouse/touch into the
  headless session (exclusively, only while a headless stream is active)
- the `Desktop` and `SteamOS (Headless)` apps in `~/.config/sunshine/apps.json`
  (existing file is backed up)

Then open `https://<host>:47990`, set credentials, and pair Moonlight as usual.

## Update

```bash
~/Dev/prism/update.sh
```

Fetches the latest upstream Sunshine release tag, rebases the `virtual-capture` branch onto
it, rebuilds, and reinstalls. Prism is a **hard fork**: the rebrand lives in source
(CMake project, web UI, tray), so a rebase can occasionally conflict in those files —
the script stops and tells you how to resolve (`git rebase --continue` when done).
The functional Prism layer (capture patch + `contrib/virtual-session/`) almost never
conflicts.

## How it works

- **Capture override patch** (`src/platform/linux/misc.cpp`, ~50 lines): when a stream's
  display is initialized, Prism checks `$XDG_RUNTIME_DIR/prism-capture-override`. If it names
  a Wayland socket, that stream is captured from that compositor via Sunshine's existing
  wlroots (wlr-screencopy) backend; otherwise behavior is stock.
- **Session scripts** (`contrib/virtual-session/prism-steamos-start.sh` / `-stop.sh`): run as
  the app's prep `do`/`undo` commands. They move Steam between the desktop and the headless
  session, size the headless output to the client's mode with `wlr-randr`, and clean up —
  serialized with a lock so a mid-setup disconnect can't leave orphans.
- **Input bridge** (`contrib/virtual-session/prism-input-bridge.c`): labwc can't claim a
  libinput seat while a desktop owns it, but it speaks `zwlr_virtual_pointer_v1` /
  `zwp_virtual_keyboard_v1`. The bridge reads Sunshine's uinput evdev nodes
  (`* passthrough`) and re-injects via those protocols, holding an exclusive `EVIOCGRAB`
  only while a headless stream runs (desktop streams keep desktop input).
- A udev rule (`contrib/virtual-session/61-prism-input.rules`) grants the session user read
  access to those evdev nodes.

## Caveats

- HDR via gamescope is attempted when the client requests it; whether it works depends on
  labwc color-management support. Desktop HDR depends on your portal/compositor.
- The optional `prism-desktop-refresh.sh` prep script can snap a KDE monitor's refresh rate
  to the client FPS via `kscreen-doctor`; not enabled by default.

## Credits

All the heavy lifting is upstream [Sunshine](https://github.com/LizardByte/Sunshine) by
LizardByte and its contributors. Prism is a thin layer on top; see `NOTICE`/`LICENSE`.
