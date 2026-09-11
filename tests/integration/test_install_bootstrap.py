#!/usr/bin/env python3
"""@file
@brief Test installer startup without packages, network, or host changes.
"""

import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

INSTALLER = Path(sys.argv.pop(1)).resolve()


class InstallBootstrapTest(unittest.TestCase):
    """Verify file and pipe entry points build in the cloned source."""

    def test_bootstrap(self):
        """Cover fresh/existing sources, relative paths, and clone failures."""
        for piped in (False, True):
            for existing, clone_fails in (
                (False, False), (True, False), (False, True)
            ):
                with self.subTest(
                    piped=piped, existing=existing, clone_fails=clone_fails
                ):
                    with tempfile.TemporaryDirectory(
                        prefix="prism-bootstrap-"
                    ) as tmp:
                        root = Path(tmp)
                        caller = root / "unrelated directory"
                        caller.mkdir()
                        source = caller / "source checkout"
                        fixture = root / "fixture"
                        (fixture / "scripts").mkdir(parents=True)
                        session_dir = fixture / "contrib/virtual-session"
                        session_dir.mkdir(parents=True)
                        (fixture / "scripts/linux_cuda_config.sh").write_text(
                            'prism_configure_cuda() { '
                            'CUDA_FLAG=OFF; CUDA_FLAGS=(); }\n'
                        )
                        compositor = (
                            session_dir / 'build-headless-compositor.sh'
                        )
                        compositor.write_text('exit 0\n')
                        if existing:
                            import shutil
                            shutil.copytree(fixture, source)
                            (source / ".git").mkdir()
                        mock_bin = root / "bin"
                        mock_bin.mkdir()
                        stubs = {
                            # A child reading stdin must not eat the installer.
                            "sudo": 'cat >/dev/null\n',
                            "dnf": 'exit 0\n',
                            "git": '''if [ "$1" = clone ]; then
  [ "$CLONE_FAILS" = 0 ] || exit 23
  cp -R "$FIXTURE" "${@: -1}"
  mkdir "${@: -1}/.git"
fi
''',
                            # Stop before building or installing anything.
                            "cmake": '''\
[ "$PWD" = "$EXPECTED_SOURCE" ] || exit 24
[ "$1" = -S ] && [ "$2" = "$EXPECTED_SOURCE" ] || exit 25
printf 'reached build\\n'
exit 42
''',
                        }
                        for name, body in stubs.items():
                            path = mock_bin / name
                            path.write_text(
                                "#!/usr/bin/env bash\nset -eu\n" + body
                            )
                            path.chmod(0o755)
                        env = dict(os.environ)
                        env.update(
                            PATH=f"{mock_bin}:{env['PATH']}",
                            PRISM_SRC_DIR="source checkout",
                            PRISM_SKIP_DEPENDENCIES="0",
                            FIXTURE=str(fixture),
                            EXPECTED_SOURCE=str(source),
                            CLONE_FAILS=str(int(clone_fails)),
                        )
                        result = subprocess.run(
                            ["bash"] if piped else ["bash", str(INSTALLER)],
                            input=INSTALLER.read_text() if piped else "",
                            cwd=caller, env=env,
                            capture_output=True, text=True,
                            timeout=15,
                        )
                        self.assertEqual(
                            result.returncode, 23 if clone_fails else 42,
                            result.stdout + result.stderr,
                        )
                        self.assertEqual(
                            "reached build" in result.stdout, not clone_fails
                        )


if __name__ == "__main__":
    unittest.main()
