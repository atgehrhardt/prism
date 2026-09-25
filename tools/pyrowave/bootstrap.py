#!/usr/bin/env python3
"""Fetch the exact PyroWave/Granite sources used by Prism and Iris builds."""
import argparse
import pathlib
import subprocess

PYROWAVE_REVISION = "186f0393b77f7755953b5ecde994bb1cec2e4155"
GRANITE_REVISION = "b6cffd5ce81f540f0855e6778428483e14763d9b"


def checkout(path, repository, revision):
    """Create a pinned checkout without overwriting a different revision."""
    if not (path / ".git").exists():
        path.mkdir(parents=True, exist_ok=True)
        subprocess.run(["git", "init", str(path)], check=True)
        subprocess.run(
            ["git", "-C", str(path), "remote", "add", "origin", repository],
            check=True)
        subprocess.run(
            ["git", "-C", str(path), "fetch", "--depth", "1",
             "origin", revision],
            check=True)
        subprocess.run(
            ["git", "-C", str(path), "checkout", "--detach", "FETCH_HEAD"],
            check=True)
    actual = subprocess.check_output(
        ["git", "-C", str(path), "rev-parse", "HEAD"], text=True).strip()
    if actual != revision:
        raise RuntimeError(
            f"{path}: expected {revision}, found {actual}; "
            "use a fresh build directory")


def main():
    """Populate dependency sources without changing application checkouts."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=pathlib.Path)
    args = parser.parse_args()
    checkout(args.source, "https://github.com/Themaister/pyrowave.git",
             PYROWAVE_REVISION)
    granite = args.source / "Granite"
    checkout(granite, "https://github.com/Themaister/Granite.git",
             GRANITE_REVISION)
    subprocess.run(
        ["git", "-C", str(granite), "submodule", "update", "--init",
         "--depth", "1",
         "third_party/volk", "third_party/khronos/vulkan-headers"], check=True)


if __name__ == "__main__":
    main()
