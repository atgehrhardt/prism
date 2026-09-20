#!/usr/bin/env python3
"""@file
@brief Test manual release validation and publication without network writes.
"""

import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release-appimage.sh"


class ReleaseTest(unittest.TestCase):
    """@brief Verify release guards, commit pinning, and asset publication."""

    def run_release(self, operation="publish", **overrides):
        """@brief Run the release script with fake Git/GitHub commands.

        @param operation Script operation to exercise.
        @param overrides Environment values for responses and release inputs.
        @return Completed process and recorded GitHub CLI arguments.
        """
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "artifact").mkdir()
            data = b"test AppImage"
            (root / "artifact/prism-x86_64.AppImage").write_bytes(data)
            (root / "artifact/prism-x86_64.AppImage.sha256").write_text(
                f"{hashlib.sha256(data).hexdigest()}  prism-x86_64.AppImage\n"
            )
            for name, source in {
                "git": '#!/bin/sh\nexit "${GIT_STATUS:-2}"\n',
                "gh": '#!/bin/sh\nprintf "%s\\n" "$*" >> "$CALLS"\n'
                'exit "${GH_STATUS:-0}"\n',
                "sha256sum": '#!/bin/sh\nexit "${CHECKSUM_STATUS:-0}"\n',
            }.items():
                path = root / name
                path.write_text(source)
                path.chmod(0o755)
            env = {
                **os.environ,
                "PATH": f"{root}:{os.environ['PATH']}",
                "CALLS": str(root / "calls"),
                "GH_REPO": "atgehrhardt/prism",
                "RELEASE_TAG": "v1.2.3",
                "RELEASE_COMMIT": "a" * 40,
                **overrides,
            }
            result = subprocess.run(
                ["bash", str(SCRIPT), operation],
                cwd=root,
                env=env,
                text=True,
                capture_output=True,
                check=False,
            )
            calls = root / "calls"
            return result, calls.read_text() if calls.exists() else ""

    def test_validation(self):
        """@brief Accept new versions without publishing anything."""
        for version in ("v1.2.3", "v1.2.3-rc.1"):
            result, calls = self.run_release("validate", RELEASE_TAG=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(calls, "")

    def test_reject_invalid_inputs(self):
        """@brief Reject invalid versions, repository, operations and SHAs."""
        for overrides in (
            {"RELEASE_TAG": ""},
            {"RELEASE_TAG": "1.2.3"},
            {"RELEASE_TAG": "v1.2.3;echo bad"},
            {"RELEASE_TAG": "v1.2.3\nbad"},
            {"GH_REPO": "LizardByte/Sunshine"},
            {"RELEASE_COMMIT": "master"},
        ):
            result, calls = self.run_release(**overrides)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, "")
        result, calls = self.run_release("invalid")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_existing_tag_and_network_failure(self):
        """@brief Reject existing tags and failed remote queries."""
        for status in ("0", "128"):
            result, calls = self.run_release(GIT_STATUS=status)
            self.assertNotEqual(result.returncode, 0)
            self.assertEqual(calls, "")

    def test_publish(self):
        """@brief Pin the SHA and handle stable/prerelease assets."""
        for version in ("v1.2.3", "v1.2.3-rc.1"):
            result, calls = self.run_release(RELEASE_TAG=version)
            self.assertEqual(result.returncode, 0, result.stderr)
            lines = calls.splitlines()
            self.assertEqual(len(lines), 2)
            self.assertIn(f"ref=refs/tags/{version}", lines[0])
            self.assertIn("sha=" + "a" * 40, lines[0])
            self.assertIn(f"release create {version}", lines[1])
            self.assertIn("artifact/prism-x86_64.AppImage.sha256", lines[1])
            self.assertIn("--verify-tag --generate-notes", lines[1])
            self.assertEqual("--prerelease" in lines[1], "-" in version)

    def test_failed_checksum(self):
        """@brief Reject invalid assets before creating a tag."""
        result, calls = self.run_release(CHECKSUM_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, "")

    def test_tag_creation_race(self):
        """@brief Reject publication when another run creates the tag."""
        result, calls = self.run_release(GH_STATUS="1")
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls.splitlines()), 1)
        self.assertNotIn("release create", calls)


if __name__ == "__main__":
    unittest.main()
