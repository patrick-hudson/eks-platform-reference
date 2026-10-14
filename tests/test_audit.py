import importlib.util
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("audit", Path(__file__).parents[1] / "scripts/audit.py")
audit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(audit)


class AuditTests(unittest.TestCase):
    def test_missing_cluster_is_absent_but_denial_is_incomplete(self):
        with patch.object(audit.subprocess, "run", return_value=SimpleNamespace(returncode=255, stderr="An error occurred (ResourceNotFoundException)", stdout="")):
            self.assertEqual(audit.aws("test-region", "eks", "describe-cluster", missing_ok=True, name="test"), {})
        with patch.object(audit.subprocess, "run", return_value=SimpleNamespace(returncode=255, stderr="An error occurred (AccessDeniedException)", stdout="")):
            with self.assertRaises(RuntimeError):
                audit.aws("test-region", "eks", "describe-cluster", missing_ok=True, name="test")

    def test_unexpected_missing_error_is_not_a_pass(self):
        with patch.object(audit.subprocess, "run", return_value=SimpleNamespace(returncode=255, stderr="An error occurred (ResourceNotFoundException)", stdout="")):
            with self.assertRaises(RuntimeError):
                audit.aws("test-region", "ec2", "describe-vpcs", missing_ok=True)

    def test_terminal_instances_and_nat_are_not_leftovers(self):
        with patch.object(audit, "aws", return_value={"Reservations": [{"Instances": [{"State": {"Name": "terminated"}}]}]}):
            self.assertFalse(audit.exists("test-region", "instance", "i-test"))
        with patch.object(audit, "aws", return_value={"NatGateways": [{"State": "deleted"}]}):
            self.assertFalse(audit.exists("test-region", "nat-gateway", "nat-test"))
        with patch.object(audit, "aws", return_value={"NatGateways": [{"State": "deleting"}]}):
            self.assertTrue(audit.exists("test-region", "nat-gateway", "nat-test"))

    def run_audit(self, directory, remaining, captured_exists, account="test-account"):
        snapshot = Path(directory) / "before.json"
        snapshot.write_text(json.dumps({"account_id": "test-account", "region": "test-region", "environment": "dev", "cluster_name": "test-cluster", "resources": [{"type": "ebs-volume", "id": "vol-test"}]}))
        argv = ["audit.py", "audit", "--environment", "dev", "--region", "test-region", "--cluster-name", "test-cluster", "--snapshot", str(snapshot)]
        with patch.object(audit.sys, "argv", argv), patch.object(audit, "aws", return_value={"Account": account}), patch.object(audit, "collect", return_value=remaining) as collect, patch.object(audit, "exists", return_value=captured_exists), patch("builtins.print"):
            result = audit.main()
        return result, collect

    def test_untagged_captured_volume_still_fails_audit(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_audit(directory, set(), True)
            self.assertEqual(result, 1)

    def test_no_resources_passes(self):
        with tempfile.TemporaryDirectory() as directory:
            result, _ = self.run_audit(directory, set(), False)
            self.assertEqual(result, 0)

    def test_wrong_account_is_rejected_before_resource_inventory(self):
        with tempfile.TemporaryDirectory() as directory:
            snapshot = Path(directory) / "before.json"
            snapshot.write_text(json.dumps({"account_id": "right-account", "region": "test-region", "environment": "dev", "cluster_name": "test-cluster", "resources": []}))
            argv = ["audit.py", "audit", "--environment", "dev", "--region", "test-region", "--cluster-name", "test-cluster", "--snapshot", str(snapshot)]
            with patch.object(audit.sys, "argv", argv), patch.object(audit, "aws", return_value={"Account": "wrong-account"}), patch.object(audit, "collect") as collect:
                with self.assertRaises(RuntimeError):
                    audit.main()
                collect.assert_not_called()


if __name__ == "__main__":
    unittest.main()
