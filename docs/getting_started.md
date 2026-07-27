# Getting Started

The recommended method for running Prism is to use the [binaries](#binaries) included in the
[latest release][latest-release], unless otherwise specified.

[Pre-releases](https://github.com/LizardByte/Sunshine/releases) are also available. These should be considered beta,
and release artifacts may be missing when merging changes on a faster cadence.

## Binaries

Binaries of Prism are created for each release. They are available for Linux only.
Binaries can be found in the [latest release][latest-release].

> [!NOTE]
> Some third party packages also exist.
> See [Third Party Packages](third_party_packages.md) for more information.
> No support will be provided for third party packages!

## Install

### Docker

> [!WARNING]
> The Docker images are not recommended for most users.

Docker images are available on [Dockerhub.io](https://hub.docker.com/repository/docker/lizardbyte/sunshine)
and [ghcr.io](https://github.com/orgs/LizardByte/packages?repo_name=sunshine).

See [Docker](../DOCKER_README.md) for more information.

### Linux

**CUDA Compatibility**

CUDA is used for NVFBC capture.

> [!NOTE]
> See [CUDA GPUS](https://developer.nvidia.com/cuda-gpus) to cross-reference Compute Capability to your GPU.
> The table below applies to packages provided by LizardByte. If you use an official LizardByte package, then you do not
> need to install CUDA.

<table>
    <caption>CUDA Compatibility</caption>
    <tr>
        <th>CUDA Version</th>
        <th>Min Driver</th>
        <th>CUDA Compute Capabilities</th>
        <th>Package</th>
    </tr>
    <tr>
        <td rowspan="8">13.1.1</td>
        <td rowspan="8">590.48.01</td>
        <td rowspan="8">50;52;60;61;62;70;72;75;80;86;87;89;90;100;101;103;120;121</td>
        <td>prism.AppImage</td>
    </tr>
    <tr>
        <td>prism-ubuntu-22.04-{arch}.deb</td>
    </tr>
    <tr>
        <td>prism-ubuntu-24.04-{arch}.deb</td>
    </tr>
    <tr>
        <td>prism-debian-trixie-{arch}.deb</td>
    </tr>
    <tr>
        <td>prism_{arch}.flatpak</td>
    </tr>
    <tr>
        <td>Prism (copr - Fedora)</td>
    </tr>
    <tr>
        <td>Prism (copr - OpenSUSE)</td>
    </tr>
    <tr>
        <td>prism.pkg.tar.zst</td>
    </tr>
</table>

#### AppImage

> [!CAUTION]
> Use distro-specific packages instead of the AppImage if they are available.
> AppImage does not support KMS capture.

> [!NOTE]
> The AppImage is built on Ubuntu 22.04, which requires `glibc 2.35` or newer and `libstdc++ 3.4.11` or newer.

##### Install
1. Download [prism.AppImage](https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine.AppImage)
   into your home directory.
   ```bash
   cd ~
   wget https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine.AppImage
   ```
2. Open terminal and run the following command.
   ```bash
   ./prism.AppImage --install
   ```

##### Run
```bash
./prism.AppImage --install && ./prism.AppImage
```

##### Uninstall
```bash
./prism.AppImage --remove
```

#### ArchLinux

> [!CAUTION]
> Use AUR packages at your own risk.

##### Install Prebuilt Packages
Follow the instructions at LizardByte's [pacman-repo](https://github.com/LizardByte/pacman-repo) to add
the repository. Then run the following command.
```bash
pacman -S prism
```

##### Install PKGBUILD Archive
Open terminal and run the following command.
```bash
wget https://github.com/LizardByte/Sunshine/releases/latest/download/sunshine.pkg.tar.gz
tar -xvf prism.pkg.tar.gz
cd prism

# install optional dependencies
pacman -S cuda  # Nvidia GPU encoding support
pacman -S libva-mesa-driver  # AMD GPU encoding support

makepkg -si
```

##### Uninstall
```bash
pacman -R prism
```

#### Debian/Ubuntu

##### Install
Download `prism-{distro}-{distro-version}-{arch}.deb` and run the following command.
```bash
sudo dpkg -i ./prism-{distro}-{distro-version}-{arch}.deb
```

> [!NOTE]
> The `{distro-version}` is the version of the distro we built the package on. The `{arch}` is the
> architecture of your operating system.

> [!TIP]
> You can double-click the deb file to see details about the package and begin installation.

##### Uninstall
```bash
sudo apt remove prism
```

#### Fedora/OpenSUSE

> [!TIP]
> The package name is case-sensitive.

##### Install (GitHub releases)
Download `Prism-{version}.{distro+version}.{arch}.rpm` and run the following command.
```bash
sudo dnf install ./Prism-{version}.{distro}.{arch}.rpm
```

> [!NOTE]
> The `{distro+version}` is the distro and distro version of the distro we built the package on. The `{arch}` is the
> architecture of your operating system.

> [!TIP]
> You can double-click the rpm file to see details about the package and begin installation.

##### Uninstall
```bash
sudo dnf remove prism
```

##### Install (Copr)

> [!IMPORTANT]
> Stable builds are only available if the Prism release was made after the Fedora version release.
> Because of this, it is often recommended to use the beta copr; however, you do not need to regularly update.
> This could lead to annoyances in rare cases where there may be a breaking change.

1. Enable copr repository.
   ```bash
   sudo dnf copr enable lizardbyte/stable
   ```

   or
   ```bash
   sudo dnf copr enable lizardbyte/beta
   ```

2. Install the package.
   ```bash
   sudo dnf install Prism
   ```

##### Uninstall
```bash
sudo dnf remove Prism
```

#### Flatpak

> [!CAUTION]
> Use distro-specific packages instead of the Flatpak if they are available.
> Flatpak does not support KMS capture.

Using this package requires that you have [Flatpak](https://flatpak.org/setup) installed.

##### Download (local option)
1. Download `prism_{arch}.flatpak` and run the following command.

   > [!NOTE]
   > Replace `{arch}` with your system architecture.

##### Install (system level)
**Flathub**
```bash
flatpak install --system flathub dev.lizardbyte.app.Sunshine
```

**Local**
```bash
flatpak install --system ./prism_{arch}.flatpak
```

##### Install (user level)
**Flathub**
```bash
flatpak install --user flathub dev.lizardbyte.app.Sunshine
```

**Local**
```bash
flatpak install --user ./prism_{arch}.flatpak
```

##### Additional installation (required)
```bash
flatpak run --command=additional-install.sh dev.lizardbyte.app.Sunshine
```

##### Run with NVFBC capture (X11 Only) or XDG Portal (Wayland Only)
```bash
flatpak run dev.lizardbyte.app.Sunshine
```

##### Uninstall
```bash
flatpak run --command=remove-additional-install.sh dev.lizardbyte.app.Sunshine
flatpak uninstall --delete-data dev.lizardbyte.app.Sunshine
```

#### Homebrew

> [!IMPORTANT]
> The Homebrew package is experimental on Linux.

This package requires that you have [Homebrew](https://docs.brew.sh/Installation) installed.

##### Install
```bash
brew update
brew upgrade
brew tap LizardByte/homebrew
brew install sunshine
```

##### Uninstall
```bash
brew uninstall sunshine
```

> [!TIP]
> For beta you can replace `sunshine` with `sunshine-beta` in the above commands.

## Initial Setup
After installation, some initial setup is required.

### Services

**Start once**
```bash
systemctl --user start app-dev.lizardbyte.app.Sunshine
```

**Start on boot**
```bash
systemctl --user --now enable app-dev.lizardbyte.app.Sunshine
```

> [!NOTE]
> The service has been renamed to "app-dev.lizardbyte.app.Sunshine" in order to increase compatibility with
> XDG Desktop Portal, but it is also aliased to "prism.service" for convenience.

## Usage

### Basic usage
If Prism is not installed/running as a service, then start Prism with the following command, unless a start
command is listed in the specified package [install](#install) instructions above.

> [!NOTE]
> A service is a process that runs in the background. Running multiple instances of Prism is not advised.

```bash
prism
```

### Specify config file
```bash
prism <directory of conf file>/prism.conf
```

> [!NOTE]
> This step is optional, you do not need to specify a config file.
> If no config file is entered, the default location will be used.
> The configuration file specified will be created if it doesn't exist.

### Start Prism over SSH (X11)
Assuming you are already logged into the host, you can use this command

```bash
ssh <user>@<ip_address> 'export DISPLAY=:0; prism'
```

If you are logged into the host with only a tty (teletypewriter), you can use `startx` to start the X server prior to
executing Prism. You nay need to add `sleep` between `startx` and `prism` to allow more time for the display to
be ready.

```bash
ssh <user>@<ip_address> 'startx &; export DISPLAY=:0; prism'
```

> [!TIP]
> You could also use the `~/.bash_profile` or `~/.bashrc` files to set up the `DISPLAY` variable.

@seealso{See [Remote SSH Headless Setup](https://app.lizardbyte.dev/2023-09-14-remote-ssh-headless-sunshine-setup)
on how to set up a headless streaming server without autologin and dummy plugs (X11 + NVidia GPUs)}

### Configuration

Prism is configured via the web ui, which is available on [https://localhost:47990](https://localhost:47990)
by default. You may replace *localhost* with your internal ip address.

> [!NOTE]
> Ignore any warning given by your browser about "insecure website". This is due to the SSL certificate
> being self-signed.

> [!CAUTION]
> If running for the first time, make sure to note the username and password that you created.

1. Change the web-ui to your desired theme, using the dropdown menu in the navbar.
   ![Theme Selection](images/split-themes.png)
2. Add games and applications.
   ![Applications](images/applications.png)
3. Adjust any configuration settings as needed. You can search for options in the search bar.
   ![Configuration](images/configuration-search.png)
4. In Moonlight, you may need to add the PC manually.
5. When Moonlight requests for you insert the pin:

   - Login to the web-ui
   - Go to "PIN" in the Navbar
   - Type in your PIN and press `Enter`, and enter a name of your choosing for the device.
     You should get a Success Message!
   - In Moonlight, select one of the Applications listed

7. If you run into issues, logs are available in the `Troubleshooting` tab.
   You can navigate through each warning/error message for clues to the issue.
   ![Logs](images/troubleshooting-logs.png)

### Arguments
To get a list of available arguments, run the following command.

@tabs{
   @tab{ General | ```bash
      prism --help
      ```}
   @tab{ AppImage | ```bash
      ./prism.AppImage --help
      ```}
   @tab{ Flatpak | ```bash
      flatpak run --command=prism dev.lizardbyte.app.Sunshine --help
      ```}
}

### Shortcuts
All shortcuts start with `Ctrl+Alt+Shift`, just like Moonlight.

* `Ctrl+Alt+Shift+N`: Hide/Unhide the cursor (This may be useful for Remote Desktop Mode for Moonlight)
* `Ctrl+Alt+Shift+F1/F12`: Switch to different monitor for Streaming

### Application List
* Applications should be configured via the web UI
* A basic understanding of working directories and commands is required
* You can use Environment variables in place of values
* `$(HOME)` will be replaced by the value of `$HOME`
* `$$` will be replaced by `$`, e.g. `$$(HOME)` will be become `$(HOME)`
* `env` - Adds or overwrites Environment variables for the commands/applications run by Prism.
  This can only be changed by modifying the `apps.json` file directly.

### Considerations
* When an application is started, if there is an application already running, it will be terminated.
* If any of the prep-commands fail, starting the application is aborted.
* When the application has been shutdown, the stream shuts down as well.

  * For example, if you attempt to run `steam` as a `cmd` instead of `detached` the stream will immediately fail.
    This is due to the method in which the steam process is executed. Other applications may behave similarly.
  * This does not apply to `detached` applications.

* The "Desktop" app works the same as any other application except it has no commands. It does not start an application,
  instead it simply starts a stream. If you removed it and would like to get it back, just add a new application with
  the name "Desktop" and "desktop.png" as the image path.
* For the flatpak you must prepend commands with `flatpak-spawn --host`.
* If inputs (mouse, keyboard, gamepads...) aren't working after connecting, add the user running prism to the
  `input` group.

### HDR Support
Streaming HDR content is experimentally supported on Linux hosts.

* General HDR support information and requirements:

  * HDR must be activated in the host OS, which may require an HDR-capable display or EDID emulator dongle
    connected to your host PC.
  * You must also enable the HDR option in your Moonlight client settings, otherwise the stream will be SDR
    (and probably overexposed if your host is HDR).
  * A good HDR experience relies on proper HDR display calibration both in the OS and in game. HDR calibration can
    differ significantly between client and host displays.
  * You may also need to tune the brightness slider or HDR calibration options in game to the different HDR brightness
    capabilities of your client's display.
  * Some GPUs video encoders can produce lower image quality or encoding performance when streaming in HDR compared
    to SDR.

Additional information:

- HDR streaming is supported for Intel and AMD GPUs that support encoding HEVC Main 10 or AV1 10-bit profiles using VAAPI.
- The KMS capture backend is required for HDR capture. Other capture methods, like NvFBC or X11, do not support HDR.
- You will need a desktop environment with a compositor that supports HDR rendering, such as Gamescope or KDE Plasma 6.

@seealso{[Arch wiki on HDR Support for Linux](https://wiki.archlinux.org/title/HDR_monitor_support) and
[Reddit Guide for HDR Support for AMD GPUs](https://www.reddit.com/r/linux_gaming/comments/10m2gyx/guide_alpha_test_hdr_on_linux)}

### Tutorials and Guides
Tutorial videos are available [here](https://www.youtube.com/playlist?list=PLMYr5_xSeuXAbhxYHz86hA1eCDugoxXY0).

Guides are available [here](guides.md).

@admonition{Community! |
Tutorials and Guides are community generated. Want to contribute? Reach out to us on our discord server.}

<div class="section_buttons">

| Previous                 |                      Next |
|:-------------------------|--------------------------:|
| [Overview](../README.md) | [Changelog](changelog.md) |

</div>

<details style="display: none;">
  <summary></summary>
  [TOC]
</details>

[latest-release]: https://github.com/LizardByte/Sunshine/releases/latest
