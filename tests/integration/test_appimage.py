#!/usr/bin/env python3
"""@file
@brief Exercise AppImage dispatch, host integration, and verified release
replacement.
"""

import hashlib
import importlib.util
import json
import os
from pathlib import Path
import shutil
import subprocess
import struct
import runpy
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "manage", ROOT / "packaging/linux/AppImage/appimage-manage.py"
)
MANAGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MANAGE)
EXTRACT_SPEC = importlib.util.spec_from_file_location(
    "extract", ROOT / "packaging/linux/AppImage/extract.py"
)
EXTRACT = importlib.util.module_from_spec(EXTRACT_SPEC)
EXTRACT_SPEC.loader.exec_module(EXTRACT)


class AppImageTest(unittest.TestCase):
    """
    @brief Test packaging contracts without modifying the host or accessing the
    network.
    """

    def setUp(self):
        """@brief Create an isolated home and minimal AppDir payload."""
        self.tmp = tempfile.TemporaryDirectory(prefix="prism-appimage-")
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        self.appdir = self.home / "App Dir"
        self.helpers = self.appdir / "usr/libexec/prism"
        self.helpers.mkdir(parents=True)
        self.share = self.appdir / "usr/share/prism"
        (self.share / "web").mkdir(parents=True)
        (self.appdir / "usr/share/xkb").mkdir()
        services = self.share / "appimage-services"
        services.mkdir()
        for name in MANAGE.COMPONENTS:
            shutil.copy(
                ROOT / "contrib/virtual-session" / (name + ".service"),
                services,
            )
        (self.share / "apps.json").write_text(
            '{"apps": [{"name": "Desktop Headless"}]}'
        )
        self.env = dict(
            os.environ,
            HOME=str(self.home),
            XDG_CONFIG_HOME="",
            XDG_DATA_HOME="",
        )
        self.env_patch = patch.dict(os.environ, self.env)
        self.env_patch.start()
        self.addCleanup(self.env_patch.stop)

    def test_install_preserves_config_and_quotes_service_paths(self):
        """
        @brief Keep custom apps and escape paths without embedding transient
        mounts.
        """
        image = self.home / 'data space/100%/$prism".AppImage'
        config = self.home / ".config/prism"
        config.mkdir(parents=True)
        (config / "apps.json").write_text('{"apps": [{"name": "Custom"}]}')
        (config / "prism.conf").write_text("audio_sink = custom\n")
        with (
            patch.object(MANAGE, "HERE", self.appdir / "usr"),
            patch.object(MANAGE, "run") as run,
            patch("shutil.which", return_value="/bin/tool"),
        ):
            MANAGE.install(image)
            MANAGE.install(image)
        self.assertEqual(
            json.loads((config / "apps.json").read_text())["apps"],
            [{"name": "Custom"}],
        )
        self.assertEqual(
            (config / "prism.conf").read_text(), "audio_sink = custom\n"
        )
        for name, component in MANAGE.COMPONENTS.items():
            text = (
                self.home / ".config/systemd/user" / (name + ".service")
            ).read_text()
            self.assertIn(MANAGE.unit_quote(str(image)), text)
            self.assertNotIn(str(self.appdir), text)
            if component:
                self.assertIn(" --internal " + component, text)
        self.assertFalse(
            any("setcap" in str(call) for call in run.call_args_list)
        )

    def test_fresh_install_and_remove(self):
        """
        @brief Install defaults and remove only managed integration while
        keeping data.
        """
        image = self.home / ".local/share/prism/prism.AppImage"
        image.parent.mkdir(parents=True)
        image.touch()
        with (
            patch.object(MANAGE, "HERE", self.appdir / "usr"),
            patch.object(MANAGE, "run"),
            patch("shutil.which", return_value="/bin/tool"),
        ):
            MANAGE.install(image)
            foreign = self.home / ".config/systemd/user/unrelated.service"
            foreign.write_text("custom")
            MANAGE.remove()
        self.assertFalse(image.exists())
        self.assertFalse((self.home / ".local/bin/prism").exists())
        self.assertTrue(foreign.exists())
        self.assertTrue((self.home / ".config/prism/apps.json").exists())
        self.assertTrue((self.home / ".config/prism/prism.conf").exists())

    def test_invalid_config_fails_before_host_changes(self):
        """
        @brief Reject malformed user config before modifying permissions or
        services.
        """
        config = self.home / ".config/prism"
        config.mkdir(parents=True)
        (config / "apps.json").write_text("invalid")
        with patch.object(MANAGE, "run") as run, self.assertRaises(ValueError):
            MANAGE.install(self.home / "prism.AppImage")
        run.assert_not_called()

    def test_xdg_and_path_validation(self):
        """
        @brief Honor absolute XDG overrides and reject unsafe installation
        paths.
        """
        with patch.dict(os.environ, XDG_DATA_HOME="relative"):
            self.assertEqual(
                MANAGE.xdg("XDG_DATA_HOME", ".local/share"),
                self.home / ".local/share",
            )
        with patch.dict(os.environ, XDG_DATA_HOME=str(self.home / "custom")):
            self.assertEqual(
                MANAGE.xdg("XDG_DATA_HOME", ".local/share"),
                self.home / "custom",
            )
        with self.assertRaises(ValueError):
            MANAGE.install(Path("relative"))
        with self.assertRaises(ValueError):
            MANAGE.unit_quote("/path\nExecStart=evil")

    def test_dispatch(self):
        """
        @brief Forward only allowlisted internal components, arguments, and
        exit codes.
        """
        launcher = self.appdir / "AppRun"
        shutil.copy(ROOT / "packaging/linux/AppImage/AppRun", launcher)
        launcher.chmod(0o755)
        binary = self.appdir / "usr/bin/prism"
        binary.parent.mkdir()
        binary.write_text(
            '#!/bin/sh\nprintf "%s\\n" "$PRISM_SESSION_DIR" "$@"\nexit 27\n'
        )
        binary.chmod(0o755)
        for component in (
            "session-cleanup",
            "headless-session",
            "headless-steam-session",
            "steam-restore",
        ):
            target = self.helpers / ("prism-" + component + ".sh")
            shutil.copy(binary, target)
            result = subprocess.run(
                [str(launcher), "--internal", component],
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 27, result.stderr)
            self.assertIn(str(self.helpers), result.stdout)
        shutil.copy(binary, binary.parent / "prism-input-bridge")
        for args, code in (
            (["--internal", "input-bridge"], 27),
            (["--internal", "../prism"], 64),
            (["--internal", "session-cleanup", "extra"], 64),
            (["--internal"], 64),
            (["--install"], 64),
            (["--check", "extra"], 64),
            (["--remove", "extra"], 64),
            (["--update", "extra"], 64),
            (["argument with spaces"], 27),
        ):
            result = subprocess.run(
                [str(launcher), *args], capture_output=True, text=True
            )
            self.assertEqual(result.returncode, code, result.stderr)

    def test_release_installer(self):
        """
        @brief Verify file/pipe installation, checksum rejection, and startup
        rollback.
        """
        for piped, failure in (
            (False, ""),
            (True, ""),
            (False, "checksum"),
            (False, "download"),
            (False, "check"),
            (False, "install"),
            (False, "restart"),
            (False, "inactive"),
            (False, "fresh-restart"),
            (False, "malformed"),
            (False, "local"),
            (False, "default-data"),
            (False, "relative-data"),
            (False, "platform"),
            (False, "architecture"),
            (False, "root"),
            (False, "lock"),
            (False, "manager"),
            (False, "version"),
        ):
            with self.subTest(piped=piped, failure=failure):
                case = self.home / (str(piped) + (failure or "success"))
                case.mkdir()
                mocks = case / "bin"
                mocks.mkdir()
                payload = case / "payload"
                payload.write_text(
                    '#!/bin/sh\necho "$1" >> "$EVENTS"\nif [ "$1" = --install'
                    " ]; then\n  echo replaced >"
                    ' "$HOME/.config/systemd/user/prism.service"\nfi\ncase'
                    ' "$1:$FAILURE" in --check:check|--install:install) exit'
                    " 1;; esac\n"
                )
                digest = hashlib.sha256(payload.read_bytes()).hexdigest()
                payload.with_suffix(".sha256").write_text(
                    digest + "  payload\n"
                )
                data_dir = case / (
                    ".local/share" if failure.endswith("-data") else "data"
                )
                destination = data_dir / "prism/prism.AppImage"
                destination.parent.mkdir(parents=True)
                fresh = failure.startswith("fresh-")
                if not fresh:
                    destination.write_text("previous release")
                unit = case / ".config/systemd/user/prism.service"
                unit.parent.mkdir(parents=True)
                unit.write_text("previous unit")
                commands = {
                    "uname": (
                        """if [ "$1" = -s ]; then
  [ "$FAILURE" = platform ] && echo Darwin || echo Linux
else
  [ "$FAILURE" = architecture ] && echo aarch64 || echo x86_64
fi"""
                    ),
                    "id": '[ "$FAILURE" = root ] && echo 0 || echo 1000',
                    "flock": '[ "$FAILURE" != lock ]',
                    "sleep": "exit 0",
                    "curl": (
                        """[ "$FAILURE" != download ] || exit 22
case "$*" in *sha256*)
  [ "$FAILURE" != checksum ] || DIGEST=$(printf '%064d' 0)
  [ "$FAILURE" != malformed ] || DIGEST=invalid
  printf '%s  ignored\\n' "$DIGEST" > "${@: -1}";;
*) cp "$PAYLOAD" "${@: -1}";; esac"""
                    ),
                    "sha256sum": (
                        """python3 -c 'import hashlib,sys
d,p=sys.stdin.read().strip().split(None,1)
sys.exit(hashlib.sha256(open(p,"rb").read()).hexdigest()!=d)' """
                    ),
                    "systemctl": (
                        """echo "$*" >> "$EVENTS"
if [ "$2" = restart ] && [ "$FAILURE" = restart ]; then exit 1; fi
if [ "$2" = show-environment ] && [ "$FAILURE" = manager ]; then exit 1; fi
if [ "$2" = is-active ] && [ "$FAILURE" = inactive ]; then exit 1; fi"""
                    ),
                }
                for name, body in commands.items():
                    path = mocks / name
                    path.write_text("#!/bin/bash\nset -eu\n" + body + "\n")
                    path.chmod(0o755)
                events = case / "events"
                env = dict(
                    self.env,
                    HOME=str(case),
                    PATH=f"{mocks}:{self.env['PATH']}",
                    FAILURE=failure.removeprefix("fresh-"),
                    PRISM_APPIMAGE=str(payload) if failure == "local" else "",
                    PAYLOAD=str(payload),
                    DIGEST=digest,
                    EVENTS=str(events),
                    XDG_DATA_HOME=str(case / "data"),
                    PRISM_VERSION=(
                        "invalid/tag" if failure == "version" else "latest"
                    ),
                )
                if failure.endswith("-data"):
                    env["XDG_DATA_HOME"] = (
                        "relative" if failure == "relative-data" else ""
                    )
                result = subprocess.run(
                    ["bash"] if piped else ["bash", str(ROOT / "install.sh")],
                    input=(ROOT / "install.sh").read_text() if piped else "",
                    env=env,
                    capture_output=True,
                    text=True,
                    timeout=15,
                )
                if failure and failure not in (
                    "local",
                    "default-data",
                    "relative-data",
                ):
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    if fresh:
                        self.assertFalse(destination.exists())
                    else:
                        self.assertEqual(
                            destination.read_text(),
                            "previous release",
                            result.stderr,
                        )
                    self.assertEqual(unit.read_text(), "previous unit")
                    if failure in ("download", "checksum", "malformed"):
                        self.assertNotIn("--check", events.read_text())
                else:
                    self.assertEqual(
                        result.returncode, 0, result.stdout + result.stderr
                    )
                    self.assertEqual(
                        destination.read_bytes(), payload.read_bytes()
                    )
                    self.assertEqual(unit.read_text(), "replaced\n")
                self.assertFalse(
                    [
                        path
                        for path in destination.parent.glob(".install.*")
                        if path.is_dir()
                    ]
                )

    def test_kwin_packaging_prefix(self):
        """@brief Build the output helper into custom and default prefixes."""
        mocks = self.home / "compiler-bin"
        mocks.mkdir()
        for name, body in {
            "wayland-scanner": 'touch "$3"',
            "pkg-config": "echo -lwayland-client",
            "cc": 'while [ "$1" != -o ]; do shift; done; touch "$2"',
        }.items():
            path = mocks / name
            path.write_text("#!/bin/sh\nset -eu\n" + body + "\n")
            path.chmod(0o755)
        for prefix in (None, self.home / "AppDir/usr"):
            env = dict(self.env, PATH=f"{mocks}:{self.env['PATH']}")
            env.pop("PRISM_INSTALL_PREFIX", None)
            if prefix:
                env["PRISM_INSTALL_PREFIX"] = str(prefix)
            result = subprocess.run(
                [
                    "bash",
                    str(ROOT / "contrib/virtual-session/build-kwin-mode.sh"),
                ],
                env=env,
                capture_output=True,
                text=True,
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            expected = prefix or self.home / ".local"
            self.assertTrue((expected / "bin/prism-kwin-mode").exists())

    def test_extract_format_validation(self):
        """@brief Find SquashFS after the ELF runtime."""
        identity = b"\x7fELF\x02\x01\x01\x00AI\x02" + b"\x00" * 5
        header = struct.pack(
            "<16sHHIQQQIHHHHHH",
            identity,
            3,
            62,
            1,
            0,
            0,
            64,
            0,
            64,
            0,
            0,
            64,
            1,
            0,
        )
        section = struct.pack("<IIQQQQIIQQ", 0, 1, 0, 0, 128, 4, 0, 0, 0, 0)
        image = header + section + b"hsqs" + b"hsqs"
        self.assertEqual(EXTRACT.squashfs_offset(image), 132)
        # BSS length is not a file offset.
        bss = struct.pack("<IIQQQQIIQQ", 0, 8, 0, 0, 128, 4096, 0, 0, 0, 0)
        self.assertEqual(EXTRACT.squashfs_offset(header + bss + b"hsqs"), 128)
        for offset, value in (
            (0, 0),
            (8, 0),
            (18, 0),
            (58, 0),
            (60, 0),
            (40, 0),
            (40, 255),
        ):
            invalid = bytearray(image)
            invalid[offset] = value
            with self.subTest(offset=offset, value=value):
                with self.assertRaises(ValueError):
                    EXTRACT.squashfs_offset(invalid)
        for invalid in (b"", image[:-4], header[:63]):
            with self.assertRaises(ValueError):
                EXTRACT.squashfs_offset(invalid)
        image_path = self.home / "fixture.AppImage"
        image_path.write_bytes(image)
        destination = self.home / "extracted"
        with (
            patch.object(
                EXTRACT.sys,
                "argv",
                ["extract", str(image_path), str(destination)],
            ),
            patch.object(EXTRACT.subprocess, "run") as run,
        ):
            EXTRACT.main()
            self.assertIn("132", run.call_args.args[0])
            destination.mkdir()
            with self.assertRaises(ValueError):
                EXTRACT.main()
        with patch.object(EXTRACT.sys, "argv", ["extract"]):
            with self.assertRaises(ValueError):
                EXTRACT.main()

    def test_manager_command_validation(self):
        """@brief Reject root setup and invalid commands before mutation."""
        with patch.object(MANAGE.os, "getuid", return_value=0):
            with self.assertRaises(ValueError):
                MANAGE.main()
        with patch.object(MANAGE.os, "getuid", return_value=1000):
            with patch.object(MANAGE.sys, "argv", ["manage", "invalid"]):
                with self.assertRaises(ValueError):
                    MANAGE.main()
            with (
                patch.object(MANAGE.sys, "argv", ["manage", "remove"]),
                patch.object(MANAGE, "remove") as remove,
            ):
                MANAGE.main()
                remove.assert_called_once()
            with (
                patch.object(
                    MANAGE.sys, "argv", ["manage", "install", "/image"]
                ),
                patch.object(MANAGE, "install") as install,
            ):
                MANAGE.main()
                install.assert_called_once_with(Path("/image"))

    def test_manager_failure_paths(self):
        """@brief Propagate host failures and reject unmanaged removal."""
        with patch.object(MANAGE.subprocess, "run") as run:
            MANAGE.run("systemctl", "--user", "daemon-reload")
            run.assert_called_once_with(
                ("systemctl", "--user", "daemon-reload"), check=True
            )
            run.side_effect = subprocess.CalledProcessError(1, "systemctl")
            with self.assertRaises(subprocess.CalledProcessError):
                MANAGE.run("systemctl")
        with self.assertRaises(ValueError):
            MANAGE.remove()
        config = self.home / ".config/prism"
        config.mkdir(parents=True)
        for contents in ("[]", '{"apps": 1}'):
            (config / "apps.json").write_text(contents)
            with self.assertRaises(ValueError):
                MANAGE.install(self.home / "image")
        (config / "apps.json").write_text('{"apps": []}')
        with patch("shutil.which", return_value=None):
            with self.assertRaises(ValueError):
                MANAGE.install(self.home / "image")
        image = self.home / ".local/share/prism/prism.AppImage"
        image.parent.mkdir(parents=True)
        with self.assertRaises(ValueError):
            MANAGE.remove()
        # Both command-line entry points translate invalid usage into failure.
        for name in ("appimage-manage.py", "extract.py"):
            with patch.object(sys, "argv", [name, "invalid"]):
                with self.assertRaises(SystemExit):
                    runpy.run_path(
                        str(ROOT / "packaging/linux/AppImage" / name),
                        run_name="__main__",
                    )

    def test_remove_preserves_unmanaged_files_and_respects_lock(self):
        """@brief Preserve user files and reject concurrent removal."""
        image = self.home / ".local/share/prism/prism.AppImage"
        image.parent.mkdir(parents=True)
        image.touch()
        units = self.home / ".config/systemd/user"
        units.mkdir(parents=True)
        (units / "prism.service").write_text("user service")
        (units / "prism-headless-session.service").write_text(MANAGE.MARKER)
        launcher = self.home / ".local/bin/prism"
        launcher.parent.mkdir(parents=True)
        launcher.write_bytes(b"\x7fELF\xff")
        with patch.object(MANAGE, "run") as run:
            with (image.parent / ".install.lock").open("a") as lock:
                MANAGE.fcntl.flock(lock, MANAGE.fcntl.LOCK_EX)
                with self.assertRaises(BlockingIOError):
                    MANAGE.remove()
                run.assert_not_called()
            MANAGE.remove()
        self.assertTrue((units / "prism.service").exists())
        self.assertEqual(launcher.read_bytes(), b"\x7fELF\xff")

    def test_launcher_setup_and_payload_checks(self):
        """@brief Exercise setup dispatch and missing-payload checks."""
        launcher = self.appdir / "AppRun"
        shutil.copy(ROOT / "packaging/linux/AppImage/AppRun", launcher)
        launcher.chmod(0o755)
        binary_dir = self.appdir / "usr/bin"
        binary_dir.mkdir()
        for program in (
            "prism",
            "prism-input-bridge",
            "prism-hdr-calibration",
            "prism-labwc",
            "prism-kwin-mode",
            "Xwayland",
            "prism-Xwayland",
            "xkbcomp",
            "wayland-info",
            "wlr-randr",
            "pactl",
        ):
            path = binary_dir / program
            path.write_text("#!/bin/sh\nexit 0\n")
            path.chmod(0o755)
        for helper in (
            "appimage-manage.py",
            "install-appimage.sh",
            "prism-headless-session.sh",
            "prism-headless-steam-session.sh",
            "prism-steam-restore.sh",
            "prism-session-cleanup.sh",
            "prism-audio-common.sh",
            "prism-headless-common.sh",
            "prism-headless-exec.sh",
        ):
            (self.helpers / helper).touch()
            (self.helpers / helper).chmod(0o755)
        for args in (
            ["--check"],
            ["--install", "/stable/image"],
            ["--remove"],
            ["--update"],
        ):
            result = subprocess.run(
                [str(launcher), *args], capture_output=True, text=True
            )
            self.assertEqual(result.returncode, 0, result.stderr)
        (self.helpers / "appimage-manage.py").unlink()
        result = subprocess.run(
            [str(launcher), "--check"], capture_output=True
        )
        self.assertEqual(result.returncode, 1)
        (binary_dir / "prism-labwc").unlink()
        result = subprocess.run(
            [str(launcher), "--check"], capture_output=True
        )
        self.assertEqual(result.returncode, 1)

    def test_library_audit(self):
        """@brief Fail target-distro checks for unresolved helper libraries."""
        library_dir = self.appdir / "usr/lib"
        library_dir.mkdir()
        (library_dir / "fixture.so").touch()
        mocks = self.home / "audit-tools"
        mocks.mkdir()
        for name, body in {
            "file": "echo ELF",
            "ldd": (
                'case "$AUDIT_FAIL" in status) exit 1;; '
                'missing) echo "libmissing.so => not found";; '
                'symbol) echo "undefined symbol: missing_api";; esac'
            ),
        }.items():
            path = mocks / name
            path.write_text("#!/bin/sh\n" + body + "\n")
            path.chmod(0o755)
        launcher = self.appdir / "AppRun"
        launcher.write_text("#!/bin/sh\nexit 0\n")
        launcher.chmod(0o755)
        for failure in ("", "status", "missing", "symbol"):
            result = subprocess.run(
                [
                    "bash",
                    str(ROOT / "scripts/check-appimage.sh"),
                    str(self.appdir),
                ],
                env=dict(
                    self.env,
                    PATH=f"{mocks}:{self.env['PATH']}",
                    AUDIT_FAIL=failure,
                ),
                capture_output=True,
                text=True,
            )
            self.assertEqual(
                result.returncode, 1 if failure else 0, result.stderr
            )

    def test_relocatable_xwayland(self):
        """@brief Find bundled keyboard tools from any working directory."""
        directory = self.appdir / "usr/bin"
        directory.mkdir()
        wrapper = directory / "Xwayland"
        shutil.copy(ROOT / "packaging/linux/AppImage/Xwayland", wrapper)
        wrapper.chmod(0o755)
        binary = directory / "prism-Xwayland"
        binary.write_text('#!/bin/sh\nprintf "%s\\n" "$PWD" "$@"\nexit 27\n')
        binary.chmod(0o755)
        result = subprocess.run(
            [str(wrapper), "-rootless", "argument with spaces"],
            cwd=self.home,
            capture_output=True,
            text=True,
        )
        self.assertEqual(result.returncode, 27)
        self.assertEqual(
            result.stdout.splitlines(),
            [
                str(self.appdir),
                "-xkbdir",
                str(self.appdir / "usr/share/xkb"),
                "-rootless",
                "argument with spaces",
            ],
        )


if __name__ == "__main__":
    unittest.main()
