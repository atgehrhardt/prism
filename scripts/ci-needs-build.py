#!/usr/bin/env python3
"""@file
@brief Skip native CI work only when a verified diff contains documentation.
"""

import json
import os
from pathlib import Path
import re
import subprocess


def needs_build(paths):
    """@brief Classify changed paths conservatively.
    @param paths Changed repository-relative paths, including deleted files.
    @return Whether any path can affect a native build.
    """
    return any(
        not (
            path.startswith("docs/")
            or ("/" not in path and path.endswith(".md"))
        )
        for path in paths
    )


def classify(event_name, event):
    """@brief Inspect a complete PR or push diff; uncertainty requires a build.
    @param event_name GitHub event type.
    @param event Parsed GitHub event payload.
    @return Whether native checks should run.
    """
    if event_name == "pull_request":
        base = event["pull_request"]["base"]["sha"]
    elif event_name == "push" and not event.get("ref", "").startswith(
        "refs/tags/"
    ):
        base = event["before"]
    else:
        return True
    if not re.fullmatch(r"[0-9a-f]{40}", base) or base == "0" * 40:
        return True
    try:
        if subprocess.run(
            ["git", "cat-file", "-e", base], capture_output=True
        ).returncode:
            subprocess.run(
                ["git", "fetch", "--no-tags", "--depth=1", "origin", base],
                check=True,
                capture_output=True,
            )
        diff = subprocess.check_output(
            [
                "git",
                "diff",
                "--no-renames",
                "--name-only",
                "-z",
                base,
                "HEAD",
                "--",
            ]
        )
    except subprocess.CalledProcessError:
        return True
    return needs_build(os.fsdecode(path) for path in diff.split(b"\0") if path)


def main():
    """@brief Publish the build decision to the GitHub step output."""
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        build = classify(os.environ.get("GITHUB_EVENT_NAME", ""), event)
    except (OSError, KeyError, TypeError, ValueError):
        build = True
    result = f"build={str(build).lower()}\n"
    print(result, end="")
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(result)


if __name__ == "__main__":
    main()
