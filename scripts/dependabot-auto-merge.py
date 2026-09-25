#!/usr/bin/env python3
"""@file
@brief Refresh Dependabot branches and enroll them in protected auto-merge.
"""

import json
import os
import subprocess
import time

WORKFLOWS = ("_common-lint.yml", "ci.yml")


def gh(*arguments):
    """@brief Run GitHub CLI without interpreting metadata as shell code.
    @param arguments CLI arguments.
    @return Standard output; failures raise CalledProcessError.
    """
    return subprocess.check_output(["gh", *arguments], text=True)


def api(endpoint, *arguments):
    """@brief Read a JSON GitHub API response.
    @param endpoint Repository API path.
    @param arguments Additional API flags.
    @return Decoded response.
    """
    return json.loads(gh("api", endpoint, *arguments))


def eligible(pull, repository):
    """@brief Accept only open Dependabot updates within the target repository.
    @param pull Pull request REST response.
    @param repository Repository owner/name.
    @return Whether this pull request may be automated.
    """
    return (
        pull["user"]["login"] == "dependabot[bot]"
        and pull["user"]["type"] == "Bot"
        and pull["state"] == "open"
        and pull["draft"] is False
        and pull["base"]["ref"] == "master"
        and pull["base"]["repo"]["full_name"] == repository
        and (pull["head"]["repo"] or {}).get("full_name") == repository
    )


def ensure_checks(pull, repository):
    """@brief Dispatch missing CI without retrying failed checks.
    @param pull Eligible pull request with the current head commit.
    @param repository Repository owner/name.
    """
    sha = pull["head"]["sha"]
    for workflow in WORKFLOWS:
        pages = api(
            f"repos/{repository}/actions/workflows/{workflow}/runs"
            f"?head_sha={sha}&per_page=100",
            "--paginate", "--slurp",
        )
        # GITHUB_TOKEN branch updates can leave PR runs awaiting approval.
        # Explicit dispatch starts CI without that manual step. Existing real
        # runs, including failures, must not be repeatedly restarted.
        if any(
            run["head_sha"] == sha
            and run["status"] in ("queued", "in_progress", "completed")
            and run["conclusion"] != "action_required"
            for page in pages for run in page["workflow_runs"]
        ):
            continue
        print(f"PR #{pull['number']}: dispatching {workflow} at {sha}")
        gh("workflow", "run", workflow, "--repo", repository,
           "--ref", pull["head"]["ref"])


def process(number, repository):
    """@brief Enroll a PR, refresh its branch, and start missing CI.
    @param number Pull request number.
    @param repository Repository owner/name.
    """
    endpoint = f"repos/{repository}/pulls/{number}"
    pull = api(endpoint)
    if not eligible(pull, repository):
        return
    if pull["mergeable"] is not True:
        print(f"PR #{number}: conflicts or mergeability pending; skipping")
        return
    if not pull.get("auto_merge"):
        gh("pr", "merge", str(number), "--repo", repository,
           "--auto", "--squash", "--match-head-commit", pull["head"]["sha"])
        # Enabling auto-merge can immediately merge a ready PR.
        pull = api(endpoint)
        if not eligible(pull, repository):
            return
    if pull["mergeable_state"] == "behind":
        sha = pull["head"]["sha"]
        print(f"PR #{number}: updating branch from master")
        api(f"{endpoint}/update-branch", "--method", "PUT",
            "-f", f"expected_head_sha={sha}")
        for attempt in range(12):
            pull = api(endpoint)
            if not eligible(pull, repository):
                return
            if pull["head"]["sha"] != sha:
                break
            time.sleep(5)
        else:
            raise RuntimeError(f"PR #{number}: branch update still pending")
    ensure_checks(pull, repository)


def main():
    """@brief Reconcile eligible PRs without letting one failure block others.
    @return Zero on success, or one if a PR could not be processed.
    """
    repository = os.environ["GH_REPO"]
    pages = api(
        f"repos/{repository}/pulls?state=open&base=master&per_page=100",
        "--paginate", "--slurp",
    )
    failed = False
    for page in pages:
        for pull in page:
            if not eligible(pull, repository):
                continue
            try:
                process(pull["number"], repository)
            except (subprocess.CalledProcessError, RuntimeError) as error:
                print(f"PR #{pull['number']}: {error}")
                failed = True
    return int(failed)


if __name__ == "__main__":
    raise SystemExit(main())
