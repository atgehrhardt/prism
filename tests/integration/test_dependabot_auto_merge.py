#!/usr/bin/env python3
"""@file
@brief Exercise the auto-merge workflow without contacting or modifying GitHub.
"""

import copy
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[2]
REPOSITORY = "atgehrhardt/prism"
WORKFLOW = yaml.load(
    (ROOT / ".github/workflows/dependabot-auto-merge.yml").read_text(),
    Loader=yaml.BaseLoader,
)
JOB = WORKFLOW["jobs"]["auto-merge"]
PULL = {
    "number": 42,
    "user": {"login": "dependabot[bot]", "type": "Bot"},
    "state": "open",
    "draft": False,
    "base": {"ref": "master", "repo": {"full_name": REPOSITORY}},
    "head": {"sha": "a" * 40, "repo": {"full_name": REPOSITORY}},
}


class DependabotAutoMergeTest(unittest.TestCase):
    """@brief Run the workflow shell and jq filter with a fake GitHub CLI."""

    def run_workflow(self, pages, api_exit=0, merge_exit=0):
        """@brief Record GitHub requests made by the workflow's actual script.
        @param pages API response pages, emitted as consecutive JSON arrays.
        @param api_exit Exit status of the fake pull request listing.
        @param merge_exit Exit status of each fake merge request.
        @return Process result and recorded GitHub CLI arguments.
        """
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            fixture = directory / "pulls.json"
            fixture.write_text("\n".join(json.dumps(page) for page in pages))
            log = directory / "commands.jsonl"
            gh = directory / "gh"
            gh.write_text(
                f"#!{sys.executable}\n"
                "import json, os, pathlib, sys\n"
                "with open(os.environ['TEST_GH_LOG'], 'a') as log:\n"
                "    log.write(json.dumps(sys.argv[1:]) + '\\n')\n"
                "if sys.argv[1] == 'api':\n"
                "    path = pathlib.Path(os.environ['TEST_PULLS'])\n"
                "    print(path.read_text())\n"
                "    sys.exit(int(os.environ['TEST_API_EXIT']))\n"
                "if sys.argv[1:3] == ['pr', 'merge']:\n"
                "    sys.exit(int(os.environ['TEST_MERGE_EXIT']))\n"
                "sys.exit(99)\n"
            )
            gh.chmod(0o755)
            result = subprocess.run(
                ["bash", "-c", JOB["steps"][0]["run"]],
                env=dict(
                    os.environ,
                    PATH=f"{directory}:{os.environ['PATH']}",
                    GH_REPO=REPOSITORY,
                    GH_TOKEN="unused-test-token",
                    TEST_GH_LOG=str(log),
                    TEST_PULLS=str(fixture),
                    TEST_API_EXIT=str(api_exit),
                    TEST_MERGE_EXIT=str(merge_exit),
                ),
                capture_output=True,
                text=True,
            )
            calls = [
                json.loads(line) for line in log.read_text().splitlines()
            ]
            self.assertEqual(calls[0], [
                "api", "--paginate",
                f"repos/{REPOSITORY}/pulls"
                "?state=open&base=master&per_page=100",
            ])
            return result, calls[1:]

    def test_enrolls_updates_across_pages(self):
        """@brief Enroll updates with GitHub's checks and SHA guard."""
        second = copy.deepcopy(PULL)
        second.update(number=43, title="Major dependency update")
        second["head"]["sha"] = "b" * 40
        result, calls = self.run_workflow([[PULL], [second]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [
            ["pr", "merge", str(pull["number"]), "--repo", REPOSITORY,
             "--auto", "--squash", "--match-head-commit", pull["head"]["sha"]]
            for pull in [PULL, second]
        ])

    def test_rejects_ineligible_pull_requests(self):
        """@brief Reject ineligible PRs from automatic enrollment."""
        for path, value in [
            (("user", "login"), "contributor"),
            (("user", "type"), "User"),
            (("head", "repo", "full_name"), "contributor/prism"),
            (("head", "repo"), None),
            (("base", "repo", "full_name"), "another/prism"),
            (("base", "ref"), "other-branch"),
            (("draft",), True),
            (("state",), "closed"),
        ]:
            with self.subTest(path=path, value=value):
                pull = copy.deepcopy(PULL)
                target = pull
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                result, calls = self.run_workflow([[pull]])
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual(calls, [])

    def test_no_open_updates(self):
        """@brief Succeed without requesting a merge when the list is empty."""
        result, calls = self.run_workflow([[]])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(calls, [])

    def test_api_failure_does_not_merge_partial_results(self):
        """@brief Do not merge partial results from a failed API request."""
        result, calls = self.run_workflow([[PULL]], api_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_malformed_response_does_not_merge(self):
        """@brief Fail closed if GitHub returns an unexpected response."""
        result, calls = self.run_workflow([{"message": "error"}])
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(calls, [])

    def test_merge_rejection_stops_the_run(self):
        """@brief Surface rejected merges without retrying with a bypass."""
        result, calls = self.run_workflow([[PULL, PULL]], merge_exit=1)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(len(calls), 1)
        self.assertNotIn("--admin", calls[0])

    def test_privileged_workflow_does_not_execute_pr_code(self):
        """@brief Limit privileges to metadata-only automation in this fork."""
        self.assertEqual(WORKFLOW["permissions"], {})
        self.assertEqual(JOB["permissions"], {
            "contents": "write", "pull-requests": "write",
        })
        self.assertEqual(WORKFLOW["on"]["pull_request_target"], {
            "branches": ["master"],
            "types": ["opened", "reopened", "synchronize", "ready_for_review"],
        })
        self.assertIn("workflow_dispatch", WORKFLOW["on"])
        self.assertEqual(" ".join(JOB["if"].split()), (
            "github.repository == 'atgehrhardt/prism' && "
            "(github.event_name == 'workflow_dispatch' || "
            "github.event.pull_request.user.login == 'dependabot[bot]')"
        ))
        self.assertEqual(len(JOB["steps"]), 1)
        step = JOB["steps"][0]
        self.assertNotIn("uses", step)
        self.assertNotIn("${{", step["run"])
        self.assertEqual(step["shell"], "bash")
        self.assertEqual(step["env"], {
            "GH_TOKEN": "${{ github.token }}",
            "GH_REPO": "${{ github.repository }}",
        })

    def test_dependabot_keeps_branches_current(self):
        """@brief Allow every ecosystem to rebase after each merge."""
        config = yaml.safe_load((ROOT / ".github/dependabot.yml").read_text())
        for update in config["updates"]:
            with self.subTest(ecosystem=update["package-ecosystem"]):
                self.assertEqual(update.get("rebase-strategy", "auto"), "auto")


if __name__ == "__main__":
    unittest.main()
