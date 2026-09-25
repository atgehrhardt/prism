#!/usr/bin/env python3
"""@file
@brief Regress Dependabot refresh, CI dispatch, and protected merging.
"""

import copy
import importlib.util
import json
import os
from pathlib import Path
import runpy
import subprocess
import unittest
from unittest.mock import call, patch

import yaml

ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts/dependabot-auto-merge.py"
SPEC = importlib.util.spec_from_file_location("automerge", SCRIPT)
MERGE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MERGE)
REPO = "atgehrhardt/prism"
ENDPOINT = f"repos/{REPO}/pulls/42"
PULL = {
    "number": 42,
    "user": {"login": "dependabot[bot]", "type": "Bot"},
    "state": "open", "draft": False,
    "auto_merge": {"merge_method": "squash"},
    "mergeable": True, "mergeable_state": "blocked",
    "base": {"ref": "master", "repo": {"full_name": REPO}},
    "head": {"sha": "a" * 40, "ref": "dependabot/npm/update",
             "repo": {"full_name": REPO}},
}


class SelectionTest(unittest.TestCase):
    """@brief Validate identity and API handling."""

    def test_eligibility(self):
        """@brief Reject humans, forks, drafts, closed PRs, and other bases."""
        self.assertTrue(MERGE.eligible(PULL, REPO))
        for path, value in [
            (("user", "login"), "contributor"),
            (("user", "type"), "User"),
            (("head", "repo", "full_name"), "contributor/prism"),
            (("head", "repo"), None),
            (("base", "repo", "full_name"), "another/prism"),
            (("base", "ref"), "other"),
            (("draft",), True), (("state",), "closed"),
        ]:
            with self.subTest(path=path, value=value):
                pull = copy.deepcopy(PULL)
                target = pull
                for key in path[:-1]:
                    target = target[key]
                target[path[-1]] = value
                self.assertFalse(MERGE.eligible(pull, REPO))

    def test_api_arguments_and_failures(self):
        """@brief Keep CLI arguments separate and reject invalid responses."""
        with patch.object(MERGE.subprocess, "check_output") as output:
            output.return_value = json.dumps(PULL)
            self.assertEqual(MERGE.api(ENDPOINT, "--method", "GET"), PULL)
            output.assert_called_once_with(
                ["gh", "api", ENDPOINT, "--method", "GET"], text=True,
            )
            output.return_value = "not json"
            with self.assertRaises(ValueError):
                MERGE.api(ENDPOINT)
            output.side_effect = subprocess.CalledProcessError(1, "gh")
            with self.assertRaises(subprocess.CalledProcessError):
                MERGE.api(ENDPOINT)


class ProcessTest(unittest.TestCase):
    """@brief Exercise updates and merge races with API fixtures."""

    def setUp(self):
        """@brief Isolate external calls and CI dispatch."""
        self.pull = copy.deepcopy(PULL)
        for name in ("api", "gh", "ensure_checks"):
            patcher = patch.object(MERGE, name)
            setattr(self, name, patcher.start())
            self.addCleanup(patcher.stop)
        patcher = patch.object(MERGE.time, "sleep")
        self.sleep = patcher.start()
        self.addCleanup(patcher.stop)
        self.api.return_value = self.pull

    def test_existing_auto_merge(self):
        """@brief Recover missing checks for an already enrolled PR."""
        MERGE.process(42, REPO)
        self.gh.assert_not_called()
        self.ensure_checks.assert_called_once_with(self.pull, REPO)

    def test_enable_auto_merge(self):
        """@brief Enroll with required checks and an exact head guard."""
        self.pull["auto_merge"] = None
        MERGE.process(42, REPO)
        self.gh.assert_called_once_with(
            "pr", "merge", "42", "--repo", REPO, "--auto", "--squash",
            "--match-head-commit", "a" * 40,
        )

    def test_skip_ineligible_or_conflicted_pr(self):
        """@brief Avoid mutations for ineligible or unmergeable PRs."""
        for key, value in [("draft", True), ("mergeable", False),
                           ("mergeable", None)]:
            self.api.return_value = dict(PULL, **{key: value})
            MERGE.process(42, REPO)
        self.gh.assert_not_called()
        self.ensure_checks.assert_not_called()

    def test_immediate_merge(self):
        """@brief Stop if enrollment immediately merges the PR."""
        self.api.side_effect = [
            dict(PULL, auto_merge=None), dict(PULL, state="closed"),
        ]
        MERGE.process(42, REPO)
        self.ensure_checks.assert_not_called()

    def test_refresh_behind_branch(self):
        """@brief Merge master with a SHA guard and test the new head."""
        self.pull["mergeable_state"] = "behind"
        updated = copy.deepcopy(self.pull)
        updated["head"]["sha"] = "b" * 40
        self.api.side_effect = [self.pull, {}, self.pull, updated]
        MERGE.process(42, REPO)
        self.assertEqual(self.api.call_args_list, [
            call(ENDPOINT),
            call(f"{ENDPOINT}/update-branch", "--method", "PUT",
                 "-f", f"expected_head_sha={'a' * 40}"),
            call(ENDPOINT), call(ENDPOINT),
        ])
        self.sleep.assert_called_once_with(5)
        self.ensure_checks.assert_called_once_with(updated, REPO)

    def test_refresh_timeout(self):
        """@brief Do not test the old commit if the update is still pending."""
        self.pull["mergeable_state"] = "behind"
        with self.assertRaisesRegex(RuntimeError, "update still pending"):
            MERGE.process(42, REPO)
        self.assertEqual(self.sleep.call_count, 12)
        self.ensure_checks.assert_not_called()

    def test_refresh_closed_or_rejected(self):
        """@brief Handle closed PRs and stale-head rejections safely."""
        self.pull["mergeable_state"] = "behind"
        self.api.side_effect = [self.pull, {}, dict(PULL, state="closed")]
        MERGE.process(42, REPO)
        self.api.side_effect = [
            self.pull, subprocess.CalledProcessError(1, "gh"),
        ]
        with self.assertRaises(subprocess.CalledProcessError):
            MERGE.process(42, REPO)
        self.ensure_checks.assert_not_called()


class ChecksTest(unittest.TestCase):
    """@brief Recover missing CI without restarting valid runs."""

    def test_dispatch_missing_or_approval_blocked_checks(self):
        """@brief Dispatch absent current-head runs and approval blocks."""
        for runs in [[], [{
            "head_sha": "a" * 40, "status": "waiting", "conclusion": None,
        }], [{
            "head_sha": "a" * 40, "status": "completed",
            "conclusion": "action_required",
        }], [{
            "head_sha": "b" * 40, "status": "completed",
            "conclusion": "success",
        }]]:
            with self.subTest(runs=runs), patch.object(
                MERGE, "api", return_value=[{"workflow_runs": runs}],
            ) as api, patch.object(MERGE, "gh") as gh:
                MERGE.ensure_checks(PULL, REPO)
                self.assertEqual(gh.call_args_list, [
                    call("workflow", "run", workflow, "--repo", REPO,
                         "--ref", PULL["head"]["ref"])
                    for workflow in MERGE.WORKFLOWS
                ])
                self.assertEqual(api.call_args_list, [
                    call(f"repos/{REPO}/actions/workflows/{workflow}"
                         f"/runs?head_sha={'a' * 40}&per_page=100",
                         "--paginate", "--slurp")
                    for workflow in MERGE.WORKFLOWS
                ])

    def test_do_not_restart_running_or_failed_checks(self):
        """@brief Preserve pending, passing, and failed runs across pages."""
        for status, conclusion in [
            ("queued", None), ("in_progress", None),
            ("completed", "success"), ("completed", "failure"),
            ("completed", "cancelled"),
        ]:
            with self.subTest(status=status, conclusion=conclusion):
                pages = [{"workflow_runs": []}, {"workflow_runs": [{
                    "head_sha": "a" * 40, "status": status,
                    "conclusion": conclusion,
                }]}]
                with patch.object(MERGE, "api", return_value=pages), \
                        patch.object(MERGE, "gh") as gh:
                    MERGE.ensure_checks(PULL, REPO)
                gh.assert_not_called()

    def test_recover_partial_dispatch(self):
        """@brief Dispatch only missing CI after a partial failure."""
        with patch.object(MERGE, "api", side_effect=[
            [{"workflow_runs": [{"head_sha": "a" * 40,
                                 "status": "queued", "conclusion": None}]}],
            [{"workflow_runs": []}],
        ]), patch.object(MERGE, "gh") as gh:
            MERGE.ensure_checks(PULL, REPO)
        gh.assert_called_once_with(
            "workflow", "run", "ci.yml", "--repo", REPO,
            "--ref", PULL["head"]["ref"],
        )


class MainTest(unittest.TestCase):
    """@brief Validate pagination, failure isolation, and workflow wiring."""

    def test_scan_continues_after_errors(self):
        """@brief Process later pages after API or timeout errors."""
        for error in [RuntimeError("pending"),
                      subprocess.CalledProcessError(1, "gh"), None]:
            with patch.dict(os.environ, GH_REPO=REPO), patch.object(
                MERGE, "api", return_value=[
                    [PULL, dict(PULL, draft=True)], [dict(PULL, number=43)],
                ],
            ), patch.object(MERGE, "process", side_effect=[error, None]) as fn:
                self.assertEqual(MERGE.main(), int(error is not None))
                self.assertEqual(fn.call_args_list, [
                    call(42, REPO), call(43, REPO),
                ])

    def test_cli_empty_scan(self):
        """@brief Run the real entry point against an empty API response."""
        with patch.dict(os.environ, GH_REPO=REPO), patch.object(
            subprocess, "check_output", return_value="[[]]",
        ), self.assertRaises(SystemExit) as result:
            runpy.run_path(str(SCRIPT), run_name="__main__")
        self.assertEqual(result.exception.code, 0)

    def test_trusted_workflow_and_ci_triggers(self):
        """@brief Execute trusted master code and keep CI dispatchable."""
        workflow = yaml.load(
            (ROOT / ".github/workflows/dependabot-auto-merge.yml").read_text(),
            Loader=yaml.BaseLoader,
        )
        job = workflow["jobs"]["auto-merge"]
        self.assertEqual(workflow["permissions"], {})
        self.assertEqual(job["permissions"], {
            "contents": "write", "pull-requests": "write", "actions": "write",
        })
        self.assertEqual(job["steps"][0]["with"], {
            "ref": "master", "persist-credentials": "false",
        })
        self.assertEqual(job["steps"][1]["run"],
                         "python3 scripts/dependabot-auto-merge.py")
        self.assertEqual(workflow["on"]["push"]["branches"], ["master"])
        self.assertIn("schedule", workflow["on"])
        self.assertEqual(workflow["on"]["workflow_run"], {
            "workflows": ["Linux", "Common Lint"], "types": ["completed"],
        })
        self.assertEqual(" ".join(job["if"].split()), (
            "github.repository == 'atgehrhardt/prism' && "
            "(github.event_name != 'pull_request_target' || "
            "github.event.pull_request.user.login == 'dependabot[bot]')"
        ))
        for name in MERGE.WORKFLOWS:
            ci = yaml.load(
                (ROOT / ".github/workflows" / name).read_text(),
                Loader=yaml.BaseLoader,
            )
            self.assertIn("workflow_dispatch", ci["on"])
        config = yaml.safe_load((ROOT / ".github/dependabot.yml").read_text())
        for update in config["updates"]:
            self.assertEqual(update.get("rebase-strategy", "auto"), "auto")


if __name__ == "__main__":
    unittest.main()
