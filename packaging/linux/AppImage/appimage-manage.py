#!/usr/bin/env python3
"""@file
@brief Register AppImage services and input permissions without a source
checkout.
"""

import json
import fcntl
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import sys

HERE = Path(__file__).resolve().parents[2]
MARKER = "# Managed by Prism AppImage\n"
COMPONENTS = {
    "prism": None,
    "prism-headless-session": "headless-session",
    "prism-input-bridge": "input-bridge",
    "prism-headless-steam": "headless-steam-session",
    "prism-steam-restore": "steam-restore",
}


def xdg(name, default):
    """@brief Resolve an absolute XDG directory, ignoring relative overrides.
    @param name Environment variable name.
    @param default Home-relative fallback directory.
    @return Absolute directory path.
    """
    value = Path(os.environ.get(name) or Path.home() / default)
    return value if value.is_absolute() else Path.home() / default


def run(*args):
    """@brief Run a host integration command and propagate failures.
    @param args Command and arguments, without shell expansion.
    """
    subprocess.run(args, check=True)


def unit_quote(value):
    """@brief Escape an executable path for systemd Exec directives.
    @param value Absolute executable path.
    @return Quoted path with specifier and variable expansion disabled.
    """
    if any(ord(c) < 32 for c in value):
        raise ValueError(
            "Installation paths cannot contain control characters"
        )
    return (
        '"'
        + value.replace("\\", "\\\\")
        .replace('"', '\\"')
        .replace("%", "%%")
        .replace("$", "$$")
        + '"'
    )


def write(path, content, mode=0o644):
    """@brief Atomically replace a managed file in its destination directory.
    @param path Destination path.
    @param content UTF-8 contents.
    @param mode Installed file permissions.
    """
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_name(path.name + ".prism-new")
    temporary.write_text(content)
    temporary.chmod(mode)
    temporary.replace(path)


def install(image):
    """@brief Register services and input rules for a stable image path.
    @param image Absolute destination of the verified AppImage.
    """
    if not image.is_absolute():
        raise ValueError("AppImage installation path must be absolute")
    executable = unit_quote(str(image))
    config = xdg("XDG_CONFIG_HOME", ".config")
    # Reject malformed existing config before making system changes.
    apps = config / "prism/apps.json"
    if apps.exists():
        data = json.loads(apps.read_text())
        if not isinstance(data, dict) or not isinstance(
            data.get("apps", []), list
        ):
            raise ValueError("Invalid apps.json; repair it before installing")
    else:
        data = json.loads((HERE / "share/prism/apps.json").read_text())
    for command in ("systemctl", "udevadm", "modprobe", "sudo"):
        if not shutil.which(command):
            raise ValueError(f"Required host command is missing: {command}")
    share = HERE / "share/prism"
    for rule in ("60-prism.rules", "61-prism-input.rules"):
        run(
            "sudo",
            "install",
            "-Dm644",
            str(share / "udev/rules.d" / rule),
            "/etc/udev/rules.d/" + rule,
        )
    run(
        "sudo",
        "install",
        "-Dm644",
        str(share / "modules-load.d/60-prism.conf"),
        "/etc/modules-load.d/60-prism.conf",
    )
    run("sudo", "modprobe", "uinput")
    run("sudo", "modprobe", "uhid")
    run("sudo", "udevadm", "control", "--reload-rules")
    for device in ("/dev/uinput", "/dev/uhid"):
        run("sudo", "udevadm", "trigger", "--property-match=DEVNAME=" + device)
    units = config / "systemd/user"
    for name, component in COMPONENTS.items():
        template = (
            share / "appimage-services" / (name + ".service")
        ).read_text()
        lines = []
        for line in template.splitlines():
            if line.startswith("ExecStart="):
                line = "ExecStart=" + executable
                if component:
                    line += " --internal " + component
            elif line.startswith("ExecStopPost="):
                line = (
                    "ExecStopPost="
                    + executable
                    + " --internal session-cleanup"
                )
            lines.append(line)
        write(units / (name + ".service"), MARKER + "\n".join(lines) + "\n")
    # Preserve all existing apps and settings. Defaults apply only to fresh
    # installs.
    if not apps.exists():
        write(apps, json.dumps(data, indent=2) + "\n", 0o600)
    conf = config / "prism/prism.conf"
    if not conf.exists():
        write(conf, "audio_sink = prism-stream\n", 0o600)
    launcher = Path.home() / ".local/bin/prism"
    write(
        launcher,
        "#!/bin/sh\n" + MARKER + "exec " + shlex.quote(str(image)) + ' "$@"\n',
        0o755,
    )
    run("systemctl", "--user", "daemon-reload")


def remove():
    """@brief Serialize removal with updates and retain all user data."""
    image = xdg("XDG_DATA_HOME", ".local/share") / "prism/prism.AppImage"
    if not image.parent.is_dir():
        raise ValueError("No managed Prism AppImage installation found")
    with (image.parent / ".install.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        remove_integration(image)


def remove_integration(image):
    """
    @brief Remove managed integration and the installed image, retaining user
    data.
    @param image Installed image path, protected by the caller's update lock.
    """
    units = xdg("XDG_CONFIG_HOME", ".config") / "systemd/user"
    owned = [units / (name + ".service") for name in COMPONENTS]
    owned = [
        path
        for path in owned
        if path.exists() and path.read_text().startswith(MARKER)
    ]
    if not owned:
        raise ValueError("No managed Prism AppImage services found")
    for path in owned:
        run("systemctl", "--user", "stop", path.name)
    if units / "prism.service" in owned:
        run("systemctl", "--user", "disable", "prism.service")
    for path in owned:
        path.unlink()
    launcher = Path.home() / ".local/bin/prism"
    if launcher.exists() and MARKER.encode() in launcher.read_bytes():
        launcher.unlink()
    run("systemctl", "--user", "daemon-reload")
    run(
        "sudo",
        "rm",
        "-f",
        "/etc/udev/rules.d/60-prism.rules",
        "/etc/udev/rules.d/61-prism-input.rules",
        "/etc/modules-load.d/60-prism.conf",
    )
    run("sudo", "udevadm", "control", "--reload-rules")
    image.unlink(missing_ok=True)
    print(
        "Prism removed. Configuration, credentials, and application data were"
        " retained."
    )


def main():
    """
    @brief Validate command-line arguments and perform the requested
    integration.
    """
    if os.getuid() == 0:
        raise ValueError("Run as your desktop user, without sudo")
    if len(sys.argv) == 3 and sys.argv[1] == "install":
        install(Path(sys.argv[2]))
    elif sys.argv[1:] == ["remove"]:
        remove()
    else:
        raise ValueError("Usage: appimage-manage.py install IMAGE | remove")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
