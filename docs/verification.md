# Verification

Verification uses Terraform 1.16.5 with AWS 6.67.0, Helm 3.3.0, and Kubernetes
2.38.0 providers. Root lockfiles include the official checksums. The configured
Kubernetes version is 1.35; monitoring chart 92.7.0 and ALB controller chart
1.14.1 are pinned.

Run these checks from the repository root:

```bash
bash scripts/check.sh
bash scripts/test.sh
bash -n scripts/check.sh scripts/test.sh scripts/deploy.sh
```

The Terraform tests run plans with synthetic credentials and replace the AWS
identity, partition, cluster and other API lookups. AWS provider schemas and
IAM policy document generation still run. Kubernetes and Helm operations are
mocked. Tests cover both environment inputs, NAT topology, service account role
separation, exact GitHub environment subjects, state-bucket protection, public
Grafana outputs, automatic settings selection by workspace, and refusal of
workspaces without configured settings. Python tests check that
audit denials fail, only recognized not-found responses count as deletion,
terminal compute resources are ignored, captured untagged disks still fail,
and a snapshot from another account cannot pass.

A live AWS apply has not been run as part of building this repo. No claim is
made that account permissions, regional quotas, DNS delegation, controllers, or
an actual second no-change plan have been verified. For the first deployment:

1. Apply dev platform, then dev monitoring, using the README commands.
2. Check every node is Ready, both PVCs are Bound, and controller pods are healthy.
3. Check HTTPS Grafana redirects HTTP, requires login, and displays node metrics.
4. Run both plans again in the same workspace; expect no changes.
5. Follow [cleanup](cleanup.md), save the before inventory, and require the AWS
   audit and DNS checks to pass after destruction.

The local check results are: formatting passed, three roots validated, eleven
offline plan runs passed (including missing-workspace-settings and wrong-zone
rejection runs), and seventeen Python audit and deployment-script tests passed.
Both environment roots load their settings from `terraform.tfvars`; the dev
and prod tests pass without a var-file. A separate offline test confirmed that
the default workspace fails variable validation. The script tests cover
read-only PR behavior, deployment order, working directories, workspace
selection, manual operation selection, missing-cluster deferral and errors
that must stop an apply. Cluster deletion and replacement stop before apply;
initial creation and in-place updates are allowed. Failures at each plan/apply
stage stop later deployment stages.
Deployment scripts are tested from a directory outside the repository too. Bash syntax checks passed. Both
pinned Helm charts rendered using the exact Terraform-generated dev values: 104 monitoring
objects, generated Grafana credentials, the expected gp3 PVCs, disabled anonymous
access, bounded Prometheus retention, and the controller's IRSA service account.
These are local checks, not an AWS deployment receipt.

Chart template rendering is checked separately from mocked Terraform plans.
The exact values from the offline monitoring plan are rendered through the two
published charts; the resulting Kubernetes manifests are inspected for PVC
settings, Grafana authentication, retention and controller identity. Upgrade
checks should repeat that rendering and read upstream chart upgrade notes.

The staged source also received local correctness, security, and cleanup review.
The security pass corrected the README's claim about bootstrap protection:
privileged role creation and policy attachment do not provide a permissions
boundary. A local synthetic S3 endpoint verified that workspace initialization
and selection use the permitted prefix and environment state key.

The complete source received correctness, security, test, maintainability,
reliability and adversarial review before the first PR. Its two findings were
fixed: deployment refuses destructive cluster plans until monitoring cleanup,
and offline tests inspect the actual IAM assume-role policies for both plan
and apply roles. A scratch-copy mutation check confirmed that broadening the
OIDC subject to a wildcard fails the policy assertion. Workflow syntax passed
actionlint 1.7.12. These checks do not verify live AWS permissions or controllers.

Hosted-zone selection was checked against the account through a read-only
Terraform plan. The previous name lookup reproduced the multiple-zone error.
The explicit zone ID lookup succeeded, and its four name servers matched the
domain's public delegation. No DNS records or other AWS resources were changed
by that check. Bootstrap and monitoring use the same selector; the monitoring
test also rejects a selected zone belonging to another domain.
