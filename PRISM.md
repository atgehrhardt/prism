# Prism

Prism is a small fork of [Sunshine](https://github.com/LizardByte/Sunshine) that adds
**per-app capture override** on Linux/Wayland: an app's prep command can redirect that
app's stream to a different Wayland compositor — for example a fully headless
[labwc](https://github.com/labwc/labwc) + [gamescope](https://github.com/ValveSoftware/gamescope)
session running Steam Big Picture (SteamOS mode) — while the normal "Desktop" app keeps
streaming your real desktop. One paired Sunshine instance, one Moonlight entry.

Everything Prism-specific lives in exactly two places, so tracking upstream is trivial:

- `src/platform/linux/misc.cpp` — a ~40-line block at the top of `platf::display()`
  (branch `virtual-capture`, rebased onto upstream release tags)
- `contrib/virtual-session/` — scripts, systemd user units, docs (no upstream conflicts)

## What you get

| Moonlight app | Behavior |
|---|---|
| **Desktop** | Streams your desktop. Resolution, FPS, bitrate and codec follow the Moonlight client settings automatically (native Sunshine behavior). |
| **SteamOS (Headless)** | Quits Steam on your desktop, starts a headless labwc compositor + gamescope at the client's requested resolution/FPS, launches Steam Big Picture in SteamOS mode, and streams that. Your physical screen is untouched. When the stream ends (or the client crashes), Steam reopens on your desktop. |

## Install (Fedora)

```bash
curl -fsSL https://raw.githubusercontent.com/atgehrhardt/prism/virtual-capture/install.sh | bash
```

This installs build/runtime dependencies, clones and builds Prism, installs it to
`~/.local`, sets up `sunshine.service` + `sunshine-labwc.service` (systemd user units),
installs the session scripts, and merges the two apps into
`~/.config/sunshine/apps.json` (backing up the existing file).

Then open `https://<host>:47990`, set/enter your credentials, and pair Moonlight as usual.

## Updating

```bash
~/Dev/prism/update.sh
```

Fetches the latest upstream Sunshine release tag, rebases the `virtual-capture` patch
branch onto it, rebuilds, and reinstalls. If upstream ever changes the display-init
code and the rebase conflicts, resolve the single conflicted hunk in
`src/platform/linux/misc.cpp` and `git rebase --continue`.

## How the capture override works

Sunshine already ships a wlroots capture backend (wlr-screencopy), used on
Sway/Hyprland. When a stream's display is initialized, Prism checks
`$XDG_RUNTIME_DIR/prism-capture-override`:

- file exists and names a Wayland socket (e.g. `wayland-sunshine`) → this stream
  captures that compositor via the wlroots backend
- file absent → unchanged upstream behavior (portal/KMS/whatever your session uses)

The `SteamOS (Headless)` app's prep `do` script writes the file and starts
gamescope inside labwc; its `undo` script removes the file and restores desktop Steam.
Input (keyboard/mouse/gamepad) works through Sunshine's normal uinput devices, which
the headless labwc session picks up like any compositor would.

## Notes & caveats

- GPU-agnostic: the patch touches capture routing only; encoding stays on Sunshine's
  normal `auto` path (nvenc / vaapi / software).
- HDR: attempted via `gamescope --hdr-enabled` when the client requests it; depends on
  labwc color-management support and falls back to SDR. Desktop HDR capture depends on
  your portal/compositor and is not guaranteed.
- The optional `desktop-refresh.sh` prep script can snap your monitor's refresh rate to
  the client FPS via `kscreen-doctor` (KDE only); it is not enabled by default.
