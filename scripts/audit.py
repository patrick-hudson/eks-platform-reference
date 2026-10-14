#!/usr/bin/env python3
"""Capture and audit this reference's AWS resources. All AWS calls are read-only."""
import argparse
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

PROJECT = "eks-platform-reference"


def aws(region, service, operation, missing_ok=False, **options):
    command = ["aws", service, operation, "--region", region, "--output", "json", "--no-cli-pager"]
    for key, value in options.items():
        command += ["--" + key.replace("_", "-"), json.dumps(value) if isinstance(value, (list, dict)) else str(value)]
    result = subprocess.run(command, capture_output=True, text=True)
    if result.returncode:
        # Missing resources are expected during audit; denied or failed calls are not proof of deletion.
        missing_errors = {
            ("eks", "describe-cluster"): "ResourceNotFoundException",
            ("iam", "get-role"): "NoSuchEntity",
            ("acm", "describe-certificate"): "ResourceNotFoundException",
            ("elbv2", "describe-load-balancers"): "LoadBalancerNotFound",
            ("elbv2", "describe-target-groups"): "TargetGroupNotFound",
        }
        missing_error = missing_errors.get((service, operation))
        if missing_ok and missing_error and f"({missing_error})" in result.stderr:
            return {}
        raise RuntimeError(f"{service} {operation}: {result.stderr.strip()}")
    return json.loads(result.stdout)


def owned(tags, environment):
    values = {tag["Key"]: tag["Value"] for tag in tags or []}
    return values.get("project") == PROJECT and values.get("environment") == environment


def collect(region, environment, cluster_name):
    resources = set()

    def add(kind, identifier):
        resources.add((kind, identifier))

    filters = [{"Name": "tag:project", "Values": [PROJECT]}, {"Name": "tag:environment", "Values": [environment]}]
    cluster = aws(region, "eks", "describe-cluster", missing_ok=True, name=cluster_name).get("cluster")
    if cluster:
        add("eks-cluster", cluster["name"])
        for name in aws(region, "eks", "list-nodegroups", cluster_name=cluster_name)["nodegroups"]:
            add("eks-nodegroup", name)
        for name in aws(region, "eks", "list-addons", cluster_name=cluster_name)["addons"]:
            add("eks-addon", name)

    vpcs = aws(region, "ec2", "describe-vpcs", filters=filters)["Vpcs"]
    vpc_ids = {vpc["VpcId"] for vpc in vpcs}
    if cluster:
        vpc_ids.add(cluster["resourcesVpcConfig"]["vpcId"])
    subnet_ids = set()
    for vpc_id in vpc_ids:
        add("vpc", vpc_id)
        scoped = [{"Name": "vpc-id", "Values": [vpc_id]}]
        for operation, response_key, id_key, kind in [
            ("describe-subnets", "Subnets", "SubnetId", "subnet"),
            ("describe-route-tables", "RouteTables", "RouteTableId", "route-table"),
            ("describe-security-groups", "SecurityGroups", "GroupId", "security-group"),
            ("describe-network-interfaces", "NetworkInterfaces", "NetworkInterfaceId", "network-interface"),
            ("describe-vpc-endpoints", "VpcEndpoints", "VpcEndpointId", "vpc-endpoint"),
        ]:
            for item in aws(region, "ec2", operation, filters=scoped)[response_key]:
                add(kind, item[id_key])
                if kind == "subnet":
                    subnet_ids.add(item[id_key])
        for gateway in aws(region, "ec2", "describe-nat-gateways", filter=scoped)["NatGateways"]:
            if gateway["State"] != "deleted":
                add("nat-gateway", gateway["NatGatewayId"])
                for address in gateway["NatGatewayAddresses"]:
                    if address.get("AllocationId"):
                        add("elastic-ip", address["AllocationId"])
        for gateway in aws(region, "ec2", "describe-internet-gateways", filters=[{"Name": "attachment.vpc-id", "Values": [vpc_id]}])["InternetGateways"]:
            add("internet-gateway", gateway["InternetGatewayId"])
        for reservation in aws(region, "ec2", "describe-instances", filters=scoped)["Reservations"]:
            for instance in reservation["Instances"]:
                if instance["State"]["Name"] != "terminated":
                    add("instance", instance["InstanceId"])
                    for mapping in instance.get("BlockDeviceMappings", []):
                        if mapping.get("Ebs"):
                            add("ebs-volume", mapping["Ebs"]["VolumeId"])

    for group in aws(region, "autoscaling", "describe-auto-scaling-groups")["AutoScalingGroups"]:
        group_subnets = set(group.get("VPCZoneIdentifier", "").split(","))
        if group_subnets & subnet_ids or owned(group.get("Tags"), environment):
            add("auto-scaling-group", group["AutoScalingGroupName"])

    # These objects can outlive their VPC or cluster. Scan tags independently.
    for operation, response_key, id_key, kind in [
        ("describe-addresses", "Addresses", "AllocationId", "elastic-ip"),
        ("describe-volumes", "Volumes", "VolumeId", "ebs-volume"),
        ("describe-launch-templates", "LaunchTemplates", "LaunchTemplateId", "launch-template"),
    ]:
        for item in aws(region, "ec2", operation, filters=filters)[response_key]:
            add(kind, item[id_key])
    for snapshot in aws(region, "ec2", "describe-snapshots", owner_ids=["self"], filters=filters)["Snapshots"]:
        add("ebs-snapshot", snapshot["SnapshotId"])
    for operation, response_key, id_key, kind in [
        ("describe-load-balancers", "LoadBalancers", "LoadBalancerArn", "load-balancer"),
        ("describe-target-groups", "TargetGroups", "TargetGroupArn", "target-group"),
    ]:
        items = aws(region, "elbv2", operation)[response_key]
        arns = [item[id_key] for item in items]
        tags_by_arn = {}
        for start in range(0, len(arns), 20):
            response = aws(region, "elbv2", "describe-tags", resource_arns=arns[start:start + 20])
            tags_by_arn.update({entry["ResourceArn"]: entry["Tags"] for entry in response["TagDescriptions"]})
        for item in items:
            identifier = item[id_key]
            if item.get("VpcId") in vpc_ids or owned(tags_by_arn[identifier], environment):
                add(kind, identifier)
    for group in aws(region, "logs", "describe-log-groups", log_group_name_prefix=f"/aws/eks/{cluster_name}/")["logGroups"]:
        add("log-group", group["logGroupName"])
    for role in aws(region, "iam", "list-roles")["Roles"]:
        if role["RoleName"].startswith(cluster_name + "-"):
            add("iam-role", role["RoleName"])
    for provider in aws(region, "iam", "list-open-id-connect-providers")["OpenIDConnectProviderList"]:
        info = aws(region, "iam", "get-open-id-connect-provider", open_id_connect_provider_arn=provider["Arn"])
        if info["Url"].startswith(f"oidc.eks.{region}.") and owned(info.get("Tags"), environment):
            add("irsa-provider", provider["Arn"])
    for certificate in aws(region, "acm", "list-certificates")["CertificateSummaryList"]:
        arn = certificate["CertificateArn"]
        tags = aws(region, "acm", "list-tags-for-certificate", certificate_arn=arn)["Tags"]
        if owned(tags, environment):
            add("acm-certificate", arn)
    return resources


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mode", choices=["snapshot", "audit"])
    parser.add_argument("--region", required=True)
    parser.add_argument("--environment", required=True, choices=["dev", "prod"])
    parser.add_argument("--cluster-name", required=True)
    parser.add_argument("--snapshot", required=True, type=Path)
    parser.add_argument("--report", type=Path)
    args = parser.parse_args()
    account = aws(args.region, "sts", "get-caller-identity")["Account"]
    metadata = {"account_id": account, "region": args.region, "environment": args.environment, "cluster_name": args.cluster_name}
    if args.mode == "snapshot":
        current = collect(args.region, args.environment, args.cluster_name)
        payload = dict(metadata, captured_at=datetime.now(timezone.utc).isoformat(), resources=[{"type": kind, "id": identifier} for kind, identifier in sorted(current)])
        args.snapshot.parent.mkdir(parents=True, exist_ok=True)
        args.snapshot.write_text(json.dumps(payload, indent=2) + "\n")
        print(f"Captured {len(current)} resources in {args.snapshot}")
        return 0
    previous = json.loads(args.snapshot.read_text())
    if any(previous[key] != value for key, value in metadata.items()):
        raise RuntimeError("Snapshot account, region, environment or cluster does not match this audit")
    current = collect(args.region, args.environment, args.cluster_name)
    captured = {(item["type"], item["id"]) for item in previous["resources"]}
    # Check exact captured objects with their describe APIs even after all ownership tags are removed.
    remaining = set(current)
    for kind, identifier in captured - current:
        if exists(args.region, kind, identifier):
            remaining.add((kind, identifier))
    report = dict(metadata, audited_at=datetime.now(timezone.utc).isoformat(), remaining=[{"type": kind, "id": identifier} for kind, identifier in sorted(remaining)])
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
    for kind, identifier in sorted(remaining):
        print(f"REMAINS {kind}: {identifier}")
    if remaining:
        print(f"Audit failed: {len(remaining)} resources remain.")
        return 1
    print("Environment resource audit passed. Check DNS, Terraform state, and shared resources using docs/cleanup.md.")
    return 0


def exists(region, kind, identifier):
    # Filter-based EC2 describes return an empty collection for absent objects.
    ec2 = {
        "vpc": ("describe-vpcs", "Vpcs", "vpc-id"),
        "subnet": ("describe-subnets", "Subnets", "subnet-id"),
        "route-table": ("describe-route-tables", "RouteTables", "route-table-id"),
        "security-group": ("describe-security-groups", "SecurityGroups", "group-id"),
        "network-interface": ("describe-network-interfaces", "NetworkInterfaces", "network-interface-id"),
        "vpc-endpoint": ("describe-vpc-endpoints", "VpcEndpoints", "vpc-endpoint-id"),
        "internet-gateway": ("describe-internet-gateways", "InternetGateways", "internet-gateway-id"),
        "elastic-ip": ("describe-addresses", "Addresses", "allocation-id"),
        "ebs-volume": ("describe-volumes", "Volumes", "volume-id"),
        "ebs-snapshot": ("describe-snapshots", "Snapshots", "snapshot-id"),
    }
    if kind in ec2:
        operation, key, filter_name = ec2[kind]
        return bool(aws(region, "ec2", operation, filters=[{"Name": filter_name, "Values": [identifier]}])[key])
    if kind == "auto-scaling-group":
        return bool(aws(region, "autoscaling", "describe-auto-scaling-groups", auto_scaling_group_names=[identifier])["AutoScalingGroups"])
    if kind == "launch-template":
        return any(template["LaunchTemplateId"] == identifier for template in aws(region, "ec2", "describe-launch-templates")["LaunchTemplates"])
    if kind == "instance":
        response = aws(region, "ec2", "describe-instances", filters=[{"Name": "instance-id", "Values": [identifier]}])
        return any(instance["State"]["Name"] != "terminated" for reservation in response["Reservations"] for instance in reservation["Instances"])
    if kind == "nat-gateway":
        return any(gateway["State"] != "deleted" for gateway in aws(region, "ec2", "describe-nat-gateways", filter=[{"Name": "nat-gateway-id", "Values": [identifier]}])["NatGateways"])
    if kind in {"eks-nodegroup", "eks-addon"}:
        # Absence of the cluster already proves its managed nodegroups and add-ons are gone.
        # Instances, volumes and ENIs are checked independently.
        return False
    if kind == "eks-cluster":
        return bool(aws(region, "eks", "describe-cluster", missing_ok=True, name=identifier))
    if kind == "log-group":
        return any(group["logGroupName"] == identifier for group in aws(region, "logs", "describe-log-groups", log_group_name_prefix=identifier)["logGroups"])
    if kind == "iam-role":
        return bool(aws(region, "iam", "get-role", missing_ok=True, role_name=identifier))
    if kind == "irsa-provider":
        return any(provider["Arn"] == identifier for provider in aws(region, "iam", "list-open-id-connect-providers")["OpenIDConnectProviderList"])
    if kind == "acm-certificate":
        return bool(aws(region, "acm", "describe-certificate", missing_ok=True, certificate_arn=identifier))
    if kind in {"load-balancer", "target-group"}:
        if kind == "load-balancer":
            return bool(aws(region, "elbv2", "describe-load-balancers", missing_ok=True, load_balancer_arns=[identifier]).get("LoadBalancers"))
        return bool(aws(region, "elbv2", "describe-target-groups", missing_ok=True, target_group_arns=[identifier]).get("TargetGroups"))
    raise RuntimeError(f"No deletion check for resource type {kind}")


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, KeyError, ValueError) as error:
        print(f"Audit incomplete: {error}", file=sys.stderr)
        sys.exit(2)
