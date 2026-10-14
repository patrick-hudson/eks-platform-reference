import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).parents[1]

TERRAFORM = '''#!/usr/bin/env python3
import json, os, sys
from pathlib import Path
args = sys.argv[1:]
with open(os.environ['DEPLOY_TEST_LOG'], 'a') as log:
    log.write(json.dumps({'args': args, 'workspace': os.environ.get('TF_WORKSPACE'), 'directory': str(Path.cwd().relative_to(os.environ['DEPLOY_TEST_REPO']))}) + '\\n')
operation = next(arg for arg in args if not arg.startswith('-'))
if operation == 'workspace' and os.environ.get('TF_WORKSPACE'):
    print('Workspace selection blocked by TF_WORKSPACE', file=sys.stderr)
    sys.exit(1)
stage = str(Path.cwd().relative_to(os.environ['DEPLOY_TEST_REPO'])) + ':' + operation
if stage == os.environ.get('DEPLOY_TEST_FAIL_STAGE'):
    print('Synthetic Terraform failure', file=sys.stderr)
    sys.exit(1)
if operation == 'show':
    print(json.dumps({'planned_values': {'outputs': {'cluster_name': {'value': 'test-cluster'}, 'region': {'value': 'test-region'}}}, 'resource_changes': [{'type': 'aws_eks_cluster', 'change': {'actions': json.loads(os.environ['DEPLOY_TEST_CLUSTER_ACTIONS'])}}]}))
'''
AWS = '''#!/usr/bin/env python3
import os, sys
result = os.environ.get('DEPLOY_TEST_AWS_RESULT', 'ACTIVE')
if result == 'ACTIVE':
    print('ACTIVE')
else:
    print('An error occurred (' + result + ')', file=sys.stderr)
    sys.exit(255)
'''


class DeployTests(unittest.TestCase):
    def deploy(self, event, aws_result="ACTIVE", region="test-region", operation=None, target="dev", cluster_actions=None, fail_stage=""):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            log = directory / "commands.jsonl"
            for name, content in [("terraform", TERRAFORM), ("aws", AWS)]:
                executable = directory / name
                executable.write_text(content)
                executable.chmod(0o755)
            if operation is None:
                operation = "plan" if event == "pull_request" else "apply"
            environment = dict(os.environ, PATH=str(directory) + os.pathsep + os.environ["PATH"], DEPLOY_TEST_LOG=str(log), DEPLOY_TEST_REPO=str(REPO), DEPLOY_TEST_AWS_RESULT=aws_result, DEPLOY_TEST_CLUSTER_ACTIONS=json.dumps(cluster_actions or ["create"]), DEPLOY_TEST_FAIL_STAGE=fail_stage, TARGET=target, EVENT=event, OPERATION=operation, AWS_REGION=region, STATE_BUCKET="test-state-bucket")
            result = subprocess.run(["bash", str(REPO / "scripts/deploy.sh")], cwd=directory, env=environment, capture_output=True, text=True)
            commands = [json.loads(line) for line in log.read_text().splitlines()] if log.exists() else []
            return result, commands

    def test_pr_plans_both_roots_without_apply_or_remote_locks(self):
        result, commands = self.deploy("pull_request")
        self.assertEqual(result.returncode, 0, result.stderr)
        plans = [command for command in commands if command["args"][0] == "plan"]
        self.assertEqual(len(plans), 2)
        self.assertTrue(all("-lock=false" in command["args"] for command in plans))
        self.assertFalse(any(arg.startswith("-var-file") for command in plans for arg in command["args"]))
        self.assertFalse(any(command["args"][0] == "apply" for command in commands))
        self.assertTrue(all(command["workspace"] is None for command in commands if command["args"][0] == "workspace"))

    def test_apply_plans_platform_before_monitoring(self):
        result, commands = self.deploy("push")
        self.assertEqual(result.returncode, 0, result.stderr)
        changes = [(command["directory"], command["args"][0]) for command in commands if command["args"][0] in {"plan", "apply"}]
        self.assertEqual(changes, [("environments", "plan"), ("environments", "apply"), ("environments/observability", "plan"), ("environments/observability", "apply")])
        self.assertTrue(all(command["workspace"] == "dev" for command in commands if command["args"][0] in {"plan", "apply"}))

    def test_only_missing_cluster_defers_monitoring(self):
        result, commands = self.deploy("pull_request", "ResourceNotFoundException")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Monitoring plan deferred", result.stdout)
        self.assertEqual(sum(command["args"][0] == "plan" for command in commands), 1)
        denied, _ = self.deploy("pull_request", "AccessDeniedException")
        self.assertNotEqual(denied.returncode, 0)
        self.assertNotIn("Monitoring plan deferred", denied.stdout)

    def test_region_mismatch_prevents_apply(self):
        result, commands = self.deploy("push", region="wrong-region")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command["args"][0] == "apply" for command in commands))

    def test_manual_prod_plan_is_read_only(self):
        result, commands = self.deploy("workflow_dispatch", operation="plan", target="prod", cluster_actions=["delete", "create"])
        self.assertEqual(result.returncode, 0, result.stderr)
        plans = [command for command in commands if command["args"][0] == "plan"]
        self.assertEqual(len(plans), 2)
        self.assertTrue(all("-lock=false" in command["args"] for command in plans))
        self.assertTrue(all(command["workspace"] == "prod" for command in plans))
        self.assertFalse(any(command["args"][0] == "apply" for command in commands))

    def test_manual_apply_retains_state_locking(self):
        result, commands = self.deploy("workflow_dispatch", operation="apply")
        self.assertEqual(result.returncode, 0, result.stderr)
        changes = [command for command in commands if command["args"][0] in {"plan", "apply"}]
        self.assertEqual([command["args"][0] for command in changes], ["plan", "apply", "plan", "apply"])
        self.assertTrue(all("-lock-timeout=5m" in command["args"] for command in changes))

    def test_manual_plan_defers_missing_cluster(self):
        result, commands = self.deploy("workflow_dispatch", "ResourceNotFoundException", operation="plan")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(command["args"][0] == "plan" for command in commands), 1)

    def test_pr_cannot_select_apply(self):
        result, commands = self.deploy("pull_request", operation="apply")
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(commands)

    def test_cluster_deletion_or_replacement_prevents_apply(self):
        for actions in (["delete"], ["delete", "create"], ["create", "delete"]):
            with self.subTest(actions=actions):
                result, commands = self.deploy("push", cluster_actions=actions)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("monitoring", result.stderr)
                self.assertFalse(any(command["args"][0] == "apply" for command in commands))

    def test_in_place_cluster_update_is_allowed(self):
        result, commands = self.deploy("push", cluster_actions=["update"])
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(sum(command["args"][0] == "apply" for command in commands), 2)

    def test_failed_terraform_stage_stops_later_stages(self):
        stages = [("environments", "plan"), ("environments", "apply"), ("environments/observability", "plan"), ("environments/observability", "apply")]
        for index, (directory, operation) in enumerate(stages):
            with self.subTest(directory=directory, operation=operation):
                result, commands = self.deploy("push", fail_stage=directory + ":" + operation)
                self.assertNotEqual(result.returncode, 0)
                observed = [(command["directory"], command["args"][0]) for command in commands if command["args"][0] in {"plan", "apply"}]
                self.assertEqual(observed, stages[:index + 1])


if __name__ == "__main__":
    unittest.main()
