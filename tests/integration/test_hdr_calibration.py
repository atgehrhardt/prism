#!/usr/bin/env python3
"""@brief Exercise the real HDR wizard, Wayland input, preview, save and cancellation on a private GPU compositor."""
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


def run_test(build, compositor):
    """@brief Run GPU integration checks without using the desktop or an active streaming session."""
    with tempfile.TemporaryDirectory(prefix="prism-hdr-wizard-") as temporary:
        root = Path(temporary)
        config = root / "labwc"
        config.mkdir()
        (config / "rc.xml").write_text(
            "<labwc_config><core><hdr>yes</hdr><adaptiveSync>yes</adaptiveSync></core></labwc_config>"
        )
        environment = dict(os.environ)
        for name in ("DISPLAY", "WAYLAND_DISPLAY", "GAMESCOPE_WAYLAND_DISPLAY"):
            environment.pop(name, None)
        environment.update(
            XDG_RUNTIME_DIR=str(root), XDG_CONFIG_HOME=str(root),
            WLR_BACKENDS="headless", WLR_HEADLESS_OUTPUTS="1", WLR_RENDERER="vulkan",
            LABWC_UPDATE_ACTIVATION_ENV="no",
            PRISM_HDR_SETTINGS_FILE=str(root / "prism-headless-hdr"),
            PRISM_HDR_PROFILE=str(root / "client-a.conf"),
        )
        live = root / "prism-headless-hdr"
        profile = root / "client-a.conf"
        other = root / "client-b.conf"
        live.write_text("1 203 1000\n")
        other.write_text("1 250 750\n")
        processes = []
        with (root / "log").open("w") as log:
            try:
                server = subprocess.Popen(
                    [str(compositor), "--config-dir", str(config)], env=environment,
                    stdout=log, stderr=log, start_new_session=True,
                )
                processes.append(server)
                for _ in range(80):
                    sockets = [entry for entry in root.glob("wayland-*") if entry.is_socket()]
                    if sockets:
                        break
                    assert server.poll() is None, "compositor exited before readiness"
                    time.sleep(0.1)
                assert sockets, "compositor socket timeout"
                environment["WAYLAND_DISPLAY"] = sockets[0].name

                def launch():
                    """@brief Start the actual installed wizard and wait for its first committed frame."""
                    child = subprocess.Popen(
                        [str(build / "prism-hdr-calibration")], env=environment,
                        stdout=log, stderr=log, start_new_session=True,
                    )
                    processes.append(child)
                    time.sleep(1)
                    assert child.poll() is None, "wizard failed to start"
                    return child

                def keys(*codes):
                    """@brief Deliver controller-equivalent key presses over the actual Wayland protocol."""
                    subprocess.run([str(build / "hdr-test-keyboard"), *map(str, codes)],
                                   env=environment, check=True, timeout=5)
                    time.sleep(0.3)

                def white_pixel():
                    """@brief Sample the absolute-PQ test patch through compositor screencopy."""
                    image = subprocess.check_output(
                        ["grim", "-o", "HEADLESS-1", "-t", "ppm", "-"],
                        env=environment, timeout=5,
                    )
                    header = re.match(rb"P6\s+(\d+)\s+(\d+)\s+(\d+)\s", image)
                    assert header and int(header[3]) == 255
                    width, height = int(header[1]), int(header[2])
                    # Sample the white square away from the highlight cross.
                    index = header.end() + (int(height * 300 / 720) * width + int(width * 520 / 1280)) * 3
                    return image[index]

                app = launch()
                assert abs(white_pixel() - 148) <= 1, "203-nit white was not preserved through HDR composition"
                keys(106)  # Right: raise SDR white to 213 nits.
                assert live.read_text() == "1 213 1000\n"
                assert not profile.exists(), "preview modified the persistent profile"
                actual = white_pixel()
                assert actual >= 149, f"preview white code was {actual}"
                keys(28, 106)  # Enter, Right: highlight peak to 1025 nits.
                assert live.read_text() == "1 213 1025\n"
                assert abs(white_pixel() - 192) <= 2
                keys(28, 28)  # Review, Save and close.
                assert app.wait(timeout=5) == 0
                assert profile.read_text() == "1 213 1025\n"
                assert other.read_text() == "1 250 750\n", "another client profile changed"

                app = launch()
                keys(106, 1)  # Adjust, then cancel from first page.
                assert app.wait(timeout=5) == 0
                assert profile.read_text() == "1 213 1025\n"
                assert live.read_text() == "1 213 1025\n", "cancel did not restore preview"

                # A failed save stays in the wizard instead of claiming success.
                profile.unlink()
                profile.mkdir()
                (profile / "keep").write_text("keep")
                app = launch()
                keys(28, 28, 28)
                assert app.poll() is None, "failed save closed the wizard"
                assert not Path(str(profile) + ".tmp").exists()
                keys(1, 1, 1)
                assert app.wait(timeout=5) == 0
                print("PASS: HDR pixel values, live preview, controller navigation, per-device save, cancel and failed save")
            except Exception:
                log.flush()
                print((root / "log").read_text(), file=sys.stderr)
                raise
            finally:
                for child in reversed(processes):
                    if child.poll() is None:
                        os.killpg(child.pid, signal.SIGTERM)
                        try:
                            child.wait(timeout=3)
                        except subprocess.TimeoutExpired:
                            os.killpg(child.pid, signal.SIGKILL)
                            child.wait()


if __name__ == "__main__":
    run_test(Path(sys.argv[1]).resolve(), Path(sys.argv[2]).resolve())
