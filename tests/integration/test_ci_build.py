#!/usr/bin/env python3
"""@file
@brief Regress CI change classification and incremental web build behavior.
"""

import importlib.util
import json
import os
from pathlib import Path
import runpy
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "changes", ROOT / "scripts/ci-needs-build.py"
)
CHANGES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CHANGES)


class ChangesTest(unittest.TestCase):
    """@brief Skip native checks only for documentation diffs."""

    def test_paths(self):
        """@brief Handle mixed changes and unusual filenames."""
        for paths, expected in [
            ([], False),
            (["README.md", "docs/configuration.md"], False),
            (["docs/a file\nwith newline.png"], False),
            (["LICENSE"], True),
            (["src/example.md"], True),
            (["docs/a.md", "src/a.cpp"], True),
            ([".gitmodules"], True),
            (["third-party/glad"], True),
        ]:
            with self.subTest(paths=paths):
                self.assertEqual(CHANGES.needs_build(paths), expected)

    def test_events_and_missing_history(self):
        """@brief Build releases, manual runs, and unknown diffs."""
        sha = "a" * 40
        for name, event in [
            ("workflow_dispatch", {}),
            ("push", {"ref": "refs/tags/v1"}),
            ("push", {"before": "0" * 40}),
            ("push", {"before": "invalid"}),
        ]:
            self.assertTrue(CHANGES.classify(name, event))
        for event_name, event in [
            ("push", {"before": sha}),
            ("pull_request", {"pull_request": {"base": {"sha": sha}}}),
        ]:
            with (
                patch.object(CHANGES.subprocess, "run") as run,
                patch.object(
                    CHANGES.subprocess,
                    "check_output",
                    return_value=b"docs/a.md\0",
                ),
            ):
                run.return_value.returncode = 0
                self.assertFalse(CHANGES.classify(event_name, event))
                self.assertEqual(run.call_count, 1)
                run.return_value.returncode = 1
                self.assertFalse(CHANGES.classify(event_name, event))
                self.assertIn("fetch", run.call_args.args[0])
            with patch.object(
                CHANGES.subprocess,
                "run",
                side_effect=subprocess.CalledProcessError(1, "git"),
            ):
                self.assertTrue(CHANGES.classify(event_name, event))

    def test_cli_and_renames(self):
        """@brief Compare Git history, including source-to-doc renames."""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            env = dict(
                os.environ,
                GIT_CONFIG_GLOBAL=os.devnull,
                GIT_CONFIG_NOSYSTEM="1",
            )
            subprocess.run(
                ["git", "init", "-q", temporary], check=True, env=env
            )
            for key, value in [
                ("user.name", "Test"),
                ("user.email", "test@example.com"),
            ]:
                subprocess.run(
                    ["git", "-C", temporary, "config", key, value],
                    check=True,
                    env=env,
                )
            source = directory / "source.cpp"
            source.write_text("source\n")
            subprocess.run(
                ["git", "-C", temporary, "add", "."], check=True, env=env
            )
            subprocess.run(
                ["git", "-C", temporary, "commit", "-qm", "base"],
                check=True,
                env=env,
            )
            sha = subprocess.check_output(
                ["git", "-C", temporary, "rev-parse", "HEAD"],
                text=True,
                env=env,
            ).strip()
            event = directory / "event.json"
            output = directory / "output"
            env.update(
                GITHUB_EVENT_PATH=str(event),
                GITHUB_EVENT_NAME="push",
                GITHUB_OUTPUT=str(output),
            )
            event.write_text(json.dumps({"before": sha}))
            for moved, expected in [(False, "false"), (True, "true")]:
                if moved:
                    source.rename(directory / "README.md")
                else:
                    (directory / "README.md").write_text("docs\n")
                subprocess.run(
                    ["git", "-C", temporary, "add", "README.md", "source.cpp"],
                    check=True,
                    env=env,
                )
                subprocess.run(
                    ["git", "-C", temporary, "commit", "-qm", "change"],
                    check=True,
                    env=env,
                )
                subprocess.run(
                    [sys.executable, str(ROOT / "scripts/ci-needs-build.py")],
                    cwd=directory,
                    env=env,
                    check=True,
                    capture_output=True,
                )
                self.assertEqual(
                    output.read_text().splitlines()[-1], f"build={expected}"
                )
            event.write_text("not json")
            with patch.dict(os.environ, env):
                CHANGES.main()
            self.assertEqual(output.read_text().splitlines()[-1], "build=true")
            event.write_text(json.dumps({"before": sha}))
            with (
                patch.dict(os.environ, env),
                patch.object(CHANGES.subprocess, "run") as run,
                patch.object(
                    CHANGES.subprocess,
                    "check_output",
                    return_value=b"README.md\0",
                ),
            ):
                run.return_value.returncode = 0
                runpy.run_path(
                    str(ROOT / "scripts/ci-needs-build.py"),
                    run_name="__main__",
                )
            self.assertEqual(
                output.read_text().splitlines()[-1], "build=false"
            )

    def test_selective_checkout(self):
        """@brief Keep checkout bounded to explicit Linux dependencies."""
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            git = directory / "git"
            git.write_text(
                f"#!{sys.executable}\nimport json, os, sys\n"
                "with open(os.environ['CHECKOUT_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
            )
            git.chmod(0o755)
            log = directory / "commands"
            subprocess.run(
                ["bash", str(ROOT / "scripts/checkout-linux-submodules.sh")],
                check=True,
                env=dict(
                    os.environ,
                    PATH=f"{directory}:{os.environ['PATH']}",
                    CHECKOUT_LOG=str(log),
                ),
            )
            commands = [
                json.loads(line) for line in log.read_text().splitlines()
            ]
            self.assertEqual(len(commands), 4)
            for command in commands:
                self.assertNotIn("--recursive", command)
                self.assertIn("--depth", command)
                self.assertNotIn("third-party/FFmpeg/FFmpeg", command)
            self.assertIn("third-party/FFmpeg/Vulkan-Headers", commands[1])
            self.assertEqual(commands[2][-2:], ["enet", "nanors"])
            self.assertEqual(commands[3][-1], "third-party/googletest")


class WebBuildTest(unittest.TestCase):
    """@brief Exercise the real CMake graph with a fake npm command."""

    def setUp(self):
        """@brief Create a web target and observable fake npm command."""
        self.temporary = tempfile.TemporaryDirectory(prefix="prism web ")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.build = self.root / "cmake-build-web"
        self.assets = self.root / "src_assets/common/assets/web"
        self.assets.mkdir(parents=True)
        for name in ["index.html", "public/old.txt"]:
            path = self.assets / name
            path.parent.mkdir(exist_ok=True)
            path.write_text("original")
        for name in ["package.json", "package-lock.json", "vite.config.js"]:
            (self.root / name).write_text("{}")
        npm = self.root / "npm"
        npm.write_text(
            f"#!{sys.executable}\n" + """import os, pathlib, shutil, sys
root = pathlib.Path.cwd()
with (root / 'calls').open('a') as log:
    log.write(' '.join(sys.argv[1:]) + '\\n')
if (root / 'fail').exists():
    sys.exit(1)
if sys.argv[1] == 'ci':
    (root / 'node_modules').mkdir(exist_ok=True)
else:
    out = pathlib.Path(os.environ['PRISM_ASSETS_DIR']) / 'assets/web'
    shutil.rmtree(out, ignore_errors=True)
    out.mkdir(parents=True)
    for name in ('apps', 'config', 'index', 'logout', 'password', 'pin',
                 'troubleshooting', 'welcome'):
        (out / (name + '.html')).write_text('built')
    public = root / 'src_assets/common/assets/web/public'
    for path in public.iterdir():
        shutil.copy(path, out / path.name)
"""
        )
        npm.chmod(0o755)
        (self.root / "CMakeLists.txt").write_text(
            "cmake_minimum_required(VERSION 3.20)\nproject(web NONE)\n"
            'set(PRISM_SOURCE_ASSETS_DIR "${CMAKE_SOURCE_DIR}/src_assets")\n'
            f'include("{ROOT}/cmake/targets/web.cmake")\n'
        )
        self.configure(npm)

    def configure(self, npm, offline=False):
        """@brief Configure the real CMake rules with an isolated npm command.
        @param npm Fake npm executable.
        @param offline Whether npm is restricted to cached downloads.
        """
        subprocess.run(
            [
                "cmake",
                "-S",
                str(self.root),
                "-B",
                str(self.build),
                "-G",
                "Ninja",
                f"-DNPM={npm}",
                f"-DNODE={sys.executable}",
                f"-DNPM_OFFLINE={'ON' if offline else 'OFF'}",
            ],
            check=True,
            capture_output=True,
        )

    def run_build(self, success=True):
        """@brief Build and assert the expected outcome.
        @param success Expected build success.
        @return Recorded npm command lines.
        """
        result = subprocess.run(
            ["cmake", "--build", str(self.build)],
            capture_output=True,
            text=True,
        )
        self.assertEqual(
            result.returncode == 0, success, result.stdout + result.stderr
        )
        return (self.root / "calls").read_text().splitlines()

    def test_incremental_inputs_and_cleanup(self):
        """@brief Track web inputs and remove obsolete output."""
        self.assertEqual(len(self.run_build()), 2)
        self.assertEqual(len(self.run_build()), 2)
        for name in ["index.html", "public/added.txt"]:
            (self.assets / name).write_text("changed")
            self.assertEqual(self.run_build()[-1], "run build-clean")
        before = len(self.run_build())
        (self.assets / "public/old.txt").unlink()
        self.assertEqual(len(self.run_build()), before + 1)
        self.assertFalse((self.build / "assets/web/old.txt").exists())
        self.assertEqual(
            sum(call.startswith("ci ") for call in self.run_build()), 1
        )
        (self.root / "vite.config.js").write_text("changed")
        self.assertEqual(len(self.run_build()), before + 2)
        shutil.rmtree(self.build / "assets/web")
        self.assertEqual(len(self.run_build()), before + 3)

    def test_dependency_changes_and_failures(self):
        """@brief Reinstall dependencies and retry failures."""
        (self.root / "fail").touch()
        self.run_build(False)
        self.assertFalse(
            (self.root / "node_modules/.prism-dependencies").exists()
        )
        (self.root / "fail").unlink()
        self.run_build()
        for name in ["package.json", "package-lock.json"]:
            (self.root / name).write_text("changed")
            self.assertEqual(
                self.run_build()[-2:],
                ["ci --ignore-scripts", "run build-clean"],
            )
        shutil.rmtree(self.root / "node_modules")
        self.assertEqual(
            self.run_build()[-2:], ["ci --ignore-scripts", "run build-clean"]
        )
        self.configure(self.root / "npm", offline=True)
        self.assertEqual(self.run_build()[-2], "ci --ignore-scripts --offline")
        (self.root / "fail").touch()
        (self.assets / "index.html").write_text("failed input")
        self.run_build(False)
        (self.root / "fail").unlink()
        before = len((self.root / "calls").read_text().splitlines())
        self.assertEqual(len(self.run_build()), before + 1)


if __name__ == "__main__":
    unittest.main()
