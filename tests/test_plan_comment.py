import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).parents[1]
GH = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
record = {'args': args}
if '--input' in args:
    record['payload'] = json.loads(Path(args[args.index('--input') + 1]).read_text())
with open(os.environ['COMMENT_TEST_LOG'], 'a') as log:
    log.write(json.dumps(record) + '\\n')
if '--method' not in args:
    print(os.environ['COMMENT_TEST_COMMENTS'])
'''


class PlanCommentTests(unittest.TestCase):
    def comment(self, comments=None, report="| Platform | Planned | 1 | 0 | 0 | 0 |", status="success"):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            executable = directory / "gh"
            executable.write_text(GH)
            executable.chmod(0o755)
            report_path = directory / "plan.md"
            if report is not None:
                report_path.write_text(report)
            log = directory / "commands.jsonl"
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"],
                               COMMENT_TEST_LOG=str(log), COMMENT_TEST_COMMENTS=json.dumps(comments or [[]]),
                               TARGET="dev", GITHUB_REPOSITORY="owner/repo", PR_NUMBER="1", HEAD_SHA="abc123",
                               GITHUB_SERVER_URL="https://github.com", GITHUB_RUN_ID="42", GH_TOKEN="test-token",
                               PLAN_REPORT=str(report_path), PLAN_JOB_STATUS=status, GITHUB_STEP_SUMMARY=str(directory / "summary.md"))
            result = subprocess.run(["bash", str(REPO / "scripts/comment-plan.sh")], env=environment, capture_output=True, text=True)
            calls = [json.loads(line) for line in log.read_text().splitlines()]
            self.assertEqual(result.returncode, 0, result.stderr)
            return calls

    def test_creates_comment_with_counts_commit_and_run_link(self):
        calls = self.comment()
        self.assertIn("--paginate", calls[0]["args"])
        self.assertIn("POST", calls[1]["args"])
        self.assertIn("repos/owner/repo/issues/1/comments", calls[1]["args"])
        body = calls[1]["payload"]["body"]
        self.assertTrue(body.startswith("<!-- terraform-plan:dev -->"))
        self.assertIn("abc123", body)
        self.assertIn("https://github.com/owner/repo/actions/runs/42", body)
        self.assertIn("| Platform | Planned | 1 | 0 | 0 | 0 |", body)

    def test_updates_only_matching_bot_comment_across_pages(self):
        comments = [[{"id": 3, "user": {"login": "github-actions[bot]"}, "body": "<!-- terraform-plan:dev --> old"}],
                    [{"id": 4, "user": {"login": "human"}, "body": "<!-- terraform-plan:dev -->"},
                     {"id": 5, "user": {"login": "github-actions[bot]"}, "body": "<!-- terraform-plan:prod -->"}]]
        calls = self.comment(comments)
        self.assertIn("PATCH", calls[1]["args"])
        self.assertIn("repos/owner/repo/issues/comments/3", calls[1]["args"])

    def test_failure_before_plan_produces_clear_comment(self):
        calls = self.comment(report=None, status="failure")
        body = calls[1]["payload"]["body"]
        self.assertIn("**failure**", body)
        self.assertIn("No plan results were produced", body)


if __name__ == "__main__":
    unittest.main()
