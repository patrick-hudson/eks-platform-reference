Terraform for an AWS EKS platform with private worker nodes, Prometheus, public HTTPS Grafana, and GitHub OIDC deployments.

## What gets built

```text
GitHub Actions -- OIDC --> plan / apply IAM roles
                              |
                         S3 state + lock files
                              |
                         Terraform platform root
                              |
                  VPC across availability zones
                  |                         |
            public subnets            private subnets
            NAT gateways              EKS managed nodes
            Grafana ALB -- HTTP ----> Grafana + Prometheus
                  ^                         |
                  |                       gp3 EBS
       HTTPS / ACM certificate
                  |
     Route 53: grafana.<environment>.hudson.tf

Terraform monitoring root --> Helm / Kubernetes API
EKS control-plane logs    --> CloudWatch
CNI / EBS / ALB controller --> individual IRSA roles
```

Dev uses two zones, two small nodes, and one NAT gateway. Prod uses three
zones, three larger nodes, and a NAT gateway in each zone. Neither cluster
places worker nodes on the public internet. The public ALB forwards only
Grafana traffic; Prometheus stays inside the cluster.

## Repository layout

```text
bootstrap/                         state bucket and GitHub OIDC identities
modules/network/                   VPC, subnets, routing and NAT
modules/cluster/                   EKS, managed nodes, add-ons and IRSA
modules/observability/             monitoring, ALB controller, TLS and DNS
modules/pipeline/                  scoped state access and GitHub IAM roles
environments/                      shared platform root
  terraform.tfvars                 platform settings keyed by dev/prod workspace
  observability/                   shared monitoring root
    terraform.tfvars               monitoring settings keyed by dev/prod workspace
.github/workflows/terraform.yml     validation, PR plans and manual applies
scripts/                           local checks and workflow deployment
```

Both roots use Terraform CLI workspaces named `dev` and `prod`. All environment
differences live in each root's `terraform.tfvars`, which Terraform loads
automatically. Each file contains an `environments` map; the root selects
`environments[terraform.workspace]`. Changing workspace selects both state and
settings, so plan and destroy need no `-var-file`. Variable validation rejects
`default` and any workspace without configured settings.

The states are separate because Helm needs an existing Kubernetes API, valid
credentials, and ready nodes. A fresh deployment applies the platform before
monitoring. Destruction runs in the opposite order. No targeted apply is needed.

## Before you run it

You need Terraform 1.16.5, AWS CLI v2, kubectl compatible with the configured
Kubernetes version, and an AWS account with room for the nodes, NAT gateways,
and load balancers. Bash, jq, and Python 3 are used by the scripts; the Python code uses only the
standard library. Helm is only
needed if you want to inspect charts yourself; Terraform installs the releases.

Use an AWS profile or SSO session with permission to bootstrap IAM and S3 and
to provision the platform. Configure a persistent IAM administrator role in
`administrator_arns` before applying; use its IAM ARN, not an STS session ARN.
The cluster does not grant implicit administrator access to its creator.

The public `hudson.tf` hosted zone must already exist in the same account, with
its nameservers delegated correctly. Set its exact `hosted_zone_id` in bootstrap
and both monitoring tfvars files.
Terraform selects that ID and checks the zone name and public-zone setting
before adding Grafana alias records and ACM validation records. It does not create or replace
the zone or register the domain. Use unused Grafana hostnames; existing records
need to be imported or moved deliberately before this configuration owns them.

Review both sets of tfvars. The shipped values use one AWS region; if you change
it, update the AZs, backend region, bootstrap inputs, and GitHub variables as
well. Verify that the configured Kubernetes version is available and in
[standard EKS support](https://docs.aws.amazon.com/eks/latest/userguide/kubernetes-versions.html).
The control plane uses the STANDARD upgrade policy, so AWS can upgrade it at
the end of standard support; schedule explicit upgrades before that happens.

## Run dev first

Start each shell block below at the repository root. The commands enter the
relevant Terraform folder and return to the root when finished. They provision
billable AWS resources. Read the [cost breakdown](#cost) before leaving a
cluster running.

### Bootstrap state and CI roles

Authenticate your AWS profile first using your configured login method
(`aws login` or `aws sso login`), then select it for this shell:

```bash
export AWS_PROFILE=YOUR_PROFILE
aws sts get-caller-identity
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
```

Edit that local tfvars file: choose a globally unique state bucket, set your
GitHub `owner/repository`, and confirm the cluster and role names match the
environment inputs. Confirm that `hosted_zone_id` identifies the zone whose
name servers are delegated for your domain; duplicate hosted-zone names are
allowed in AWS. If this account already has GitHub's OIDC provider, set
`github_oidc_provider_arn` to its ARN. There is only one provider per issuer per
account; this configuration can reuse it.

```bash
cd bootstrap
terraform init
terraform plan -out=bootstrap.tfplan
terraform apply bootstrap.tfplan
terraform output
cd ..
```

Bootstrap starts with local state because the bucket does not exist yet.
Move that state into the bucket once it has been created:

```bash
cp bootstrap/backend.tf.example bootstrap/backend.tf
cp bootstrap/backend.hcl.example bootstrap/backend.hcl
# Edit bootstrap/backend.hcl with the bucket output and region.
cd bootstrap
terraform init -migrate-state -backend-config=backend.hcl
cd ..
```

Confirm the migration prompt. Secure any local backup state left by the
migration. Bootstrap state lives at `bootstrap/terraform.tfstate`; environment
roles cannot read or modify it. Bucket deletion is blocked with `prevent_destroy`.
S3 versioning, encryption, TLS-only access, and public-access blocking are enabled.

### Initialize the two roots

```bash
cp environments/backend.hcl.example environments/backend.hcl
cp environments/observability/backend.hcl.example environments/observability/backend.hcl
# Set the same bucket and region in both files. Keep their distinct keys.
cd environments
terraform init -backend-config=backend.hcl
terraform workspace select -or-create dev
terraform workspace select -or-create prod
terraform workspace select dev
cd observability
terraform init -backend-config=backend.hcl
terraform workspace select -or-create dev
terraform workspace select -or-create prod
terraform workspace select dev
cd ../..
```

Create both workspaces using your bootstrap credentials before enabling PR
plans. A read-only plan role cannot initialize an empty workspace state. The
backend uses native S3 locking with `use_lockfile = true`, without DynamoDB.
The [S3 backend documentation](https://developer.hashicorp.com/terraform/language/backend/s3)
explains lock permissions and workspace paths.

| Workspace | Platform state | Monitoring state |
| --- | --- | --- |
| dev | `environments/dev/platform.tfstate` | `environments/dev/observability.tfstate` |
| prod | `environments/prod/platform.tfstate` | `environments/prod/observability.tfstate` |

### Plan and apply dev

In `environments/terraform.tfvars`, set `administrator_arns` inside the
`environments.dev` object to your human administrator's persistent IAM ARN:

```hcl
administrator_arns = {
  operator = "REPLACE_WITH_YOUR_PERSISTENT_IAM_ROLE_ARN"
}
```

Then apply using that role's AWS session:

```bash
cd environments
terraform workspace select dev
terraform plan -out=dev.tfplan
terraform apply dev.tfplan
cd observability
terraform workspace select dev
terraform plan -out=dev.tfplan
terraform apply dev.tfplan
cd ../..
```

The second apply waits for Helm, certificate validation, and ALB reconciliation.
An access-denied error is a reason to check your IAM principal and its EKS access
entry. Do not rerun monitoring with an unrelated administrator identity.

### Open Grafana and check the cluster

```bash
cd environments
cluster_region=$(terraform output -raw region)
cluster_name=$(terraform output -raw cluster_name)
aws eks update-kubeconfig --region "$cluster_region" --name "$cluster_name"
kubectl get nodes
kubectl -n monitoring get pods,pvc,ingress
cd observability
terraform output -raw grafana_url
kubectl -n monitoring get secret monitoring-grafana \
  -o jsonpath='{.data.admin-password}' | base64 --decode
cd ../..
```

Log in as `admin` with that generated password. The dev URL is
`https://grafana.dev.hudson.tf`; prod uses `https://grafana.prod.hudson.tf`.
HTTP redirects to HTTPS. Anonymous access and account sign-up are disabled.
Keep the password private and change it after first login. Prometheus provides
node, pod, and Kubernetes object metrics; Grafana ships the chart's dashboards.

The API endpoint is public with IAM authentication, and private access is also
enabled. The sample API CIDRs allow GitHub-hosted runners with changing egress
addresses. For a fixed-egress runner, restrict `public_access_cidrs` in platform
tfvars. `ingress_cidrs` separately controls who can reach Grafana's ALB.
For a long-lived shared Grafana deployment, add SSO before giving more people access.

### Run prod

Select `prod` in both roots and configure `environments.prod.administrator_arns`
in the platform tfvars. Use the same plan and apply commands; the selected
workspace supplies the prod settings. Name the saved plans `prod.tfplan`.
Do not copy Terraform code or change modules to deploy prod.

## GitHub Actions

Create GitHub environments `dev-plan`, `prod-plan`, `dev`, and `prod`. Each needs
these environment variables; they are configuration, not stored AWS secrets:

| Variable | Value |
| --- | --- |
| `AWS_ROLE_ARN` | Corresponding role from bootstrap's `github_role_arns` output |
| `AWS_ACCOUNT_ID` | Account allowed by the AWS credentials action |
| `AWS_REGION` | Region matching tfvars and the state bucket |
| `TF_STATE_BUCKET` | Bootstrap state bucket output |

Restrict deployment branches on `dev` and `prod` to `main`. Require reviewers
for `prod`. Restrict who can approve same-repository PRs against `dev-plan` and
`prod-plan`: plan roles can read state and Kubernetes Secrets to refresh Helm
releases. The plan environments must allow PR refs, not just `main`. Protect
`main`, require the validate job, and require review for changes to workflows,
Terraform, and IAM policies. Environment branch restrictions are essential:
the OIDC environment subject does not itself prove which branch requested it.

Every PR runs formatting, validation, and offline plan tests. Same-repository
PRs also plan both environments using the read-only roles. Fork PRs run the
credential-free checks only. No `pull_request_target` execution is used.

For an environment without a cluster yet, the platform plan runs and the live
monitoring plan is explicitly deferred. Static validation and offline monitoring
plans still run. Once a cluster exists, both live plans run. PR plans are unlocked
because their roles cannot write lock files; they can be stale. Manual applies
create new saved plans under S3 locks and apply those exact files in the same job.
PR plan artifacts are never reused for deployment or published as artifacts.

Each PR plan updates one bot comment per environment with platform and monitoring
resource counts: add, change, destroy and replace. The comment includes the
commit, job result and workflow link. Failed plans and deferred monitoring are
marked explicitly. Comments contain counts only; raw plan values and JSON are
not posted. Retries update the existing comment for that environment.

A merge or push to `main` runs validation only. It does not request AWS
credentials or run a live plan or apply. This lets the demo be merged and
maintained without starting billable infrastructure.
Manual runs select one environment and either `plan` or `apply`; they default
to a dev plan. Manual applies require `main`. Deployment jobs serialize per environment and
are never canceled mid-apply. The prod environment approval sits before AWS
credentials are requested. This is not a sequential dev-to-prod promotion gate.

After the workflow is merged into `main`, use Actions > Terraform > Run workflow
to select the environment and operation, or run:

```bash
gh workflow run terraform.yml --ref main -f environment=dev -f operation=plan
gh workflow run terraform.yml --ref main -f environment=prod -f operation=apply
```

Manual plans use the corresponding `dev-plan` or `prod-plan` environment and
read-only role. Manual applies use `dev` or `prod`, including its approval rules.
To retry a failed PR job before merging, use GitHub's Re-run failed jobs button
or `gh run rerun RUN_ID --failed`. To retry just one environment job, find its
`databaseId` with `gh run view RUN_ID --json jobs --jq '.jobs[] | {name, databaseId}'`,
then run `gh run rerun RUN_ID --job JOB_ID` using that ID.
Plans do not take a state lock, so an active local apply does not block them;
wait until the apply finishes for a reliable result. Applies wait up to five
minutes for the S3 lock. Retry after the other apply finishes if that wait expires.

CI refuses plans that delete or replace the EKS cluster. Those changes need
monitoring-first cleanup and an AWS audit while its controllers still run;
follow [the cleanup procedure](docs/cleanup.md) before changing the cluster's
identity or other settings that require replacement. Initial creation and
in-place updates run normally.

The apply roles can manage EC2 and EKS resources in the configured region,
cluster-prefixed IAM roles, and records in the chosen hosted zone. Direct IAM grants target cluster-prefixed roles, and state-object deletion is
not granted; lock files can be deleted. This is not a permissions boundary:
creating roles and attaching policies can allow privilege escalation beyond
those direct grants, including access to bootstrap identities. Treat apply
workflows and their approvers as fully trusted within this AWS account. These
are privileged infrastructure roles, not least-privilege application roles. Workspaces separate state, not accounts or failure domains. At larger
scale, use separate accounts and backends and narrow IAM permissions further.

## Design decisions

**Managed node groups.** EKS manages node registration, replacement, and rolling
updates. That removes work that would otherwise live in custom launch scripts
and ASG lifecycle hooks. On-demand capacity keeps interruption handling out of
this baseline. Dev uses burstable nodes; sustained CPU loads need different
instance types or incur CPU credit charges. Node counts are explicit: increasing
`max` does not install an autoscaler or automatically grow the cluster.

**OIDC rather than stored AWS keys.** GitHub gets a short-lived session tied to
this repository and an exact GitHub environment. There is no IAM user access key
to rotate or leak in repository secrets. Plan and apply roles are separate, and
IRSA gives the CNI, EBS CSI driver, and ALB controller separate AWS identities.
IMDSv2 is required, with a hop limit that keeps normal pods from relying on node
credentials. The ALB controller receives its region and VPC explicitly.

**Public and private subnets.** Nodes need outbound access for images and AWS
APIs but do not need public IPs. NAT provides that path. Dev shares one NAT to
save money, accepting an availability dependency and cross-zone traffic charges.
Prod routes each private subnet to its local NAT. Public subnets also host the
Grafana ALB. The controller is the standard AWS controller, not a custom operator.

**S3 locking and workspaces.** S3 now supports Terraform lock files directly.
This avoids a separate lock database. Workspaces give the same code distinct
states; auto-loaded tfvars maps supply settings for the selected workspace.
Platform and monitoring are
separate roots because their provider dependencies and teardown order differ.
They look up the existing cluster through AWS, rather than granting monitoring
access to the entire platform state.

**Monitoring storage and ingress.** Prometheus and Grafana use encrypted gp3
volumes with delayed binding to a node's zone. Retention is bounded by time and
size. Neither deployment is replicated; a node failure can interrupt monitoring
while a replacement attaches the zonal volume. Grafana has a public TLS endpoint
because this reference includes internet access. The ALB terminates TLS and
forwards HTTP inside the VPC. Prometheus is not exposed, and alert routing is
not configured. Managed control-plane targets that EKS does not expose are
disabled in the chart instead of leaving permanently failing scrape targets.

**What changes at larger scale.** Separate AWS accounts for prod, private API
access from a VPC runner, SSO for Grafana, a permissions boundary on deployment
roles, and stronger DNS ownership controls come first. Add autoscaling when the
workload requires it. Move metrics to durable remote storage when retention or
availability requirements exceed a single Prometheus volume. Add alert receivers,
backup and restore tests, application ingress policies, and budget alerts with
an actual owner. Measure traffic before adding paid VPC endpoints; an S3 gateway
endpoint is a useful first step to reduce NAT traffic.

Provider versions and Helm charts are pinned. EKS add-ons use AWS's compatible
default for the configured minor version. That default can change; inspect its
version in every plan. Chart upgrades need their upstream upgrade notes,
particularly Prometheus CRD changes. The checked-in controller IAM policy is
from [AWS Load Balancer Controller v2.14.1](https://github.com/kubernetes-sigs/aws-load-balancer-controller/blob/v2.14.1/docs/install/iam_policy.json)
and must be reviewed alongside the controller chart pin.

## Cost

Estimate checked on October 14, 2026, for Linux on-demand instances in the sample
region, 730 hours per month, and the desired node counts. No free-tier credits,
Savings Plans, taxes, or support plan are included. Monitoring runs on the listed
nodes; there are no extra EC2 monitoring servers.

| Component | Dev / month | Prod / month | Basis |
| --- | ---: | ---: | --- |
| EKS control plane | $73.00 | $73.00 | One cluster at $0.10/hour |
| Worker nodes | $60.74 | $210.24 | Two at $0.0416/hour; three at $0.096/hour |
| Node root disks | $4.80 | $7.20 | 30 GiB gp3 per node at $0.08/GiB-month |
| Monitoring disks | $1.20 | $2.80 | 15 / 35 GiB total gp3 |
| NAT gateways | $32.85 | $98.55 | One / three at $0.045/hour |
| NAT public IPv4 | $3.65 | $10.95 | One / three at $0.005/IP-hour |
| Grafana ALB | $16.43 | $16.43 | One at $0.0225/hour |
| ALB public IPv4 | $7.30 | $10.95 | At least one address per enabled zone: two / three |
| ALB capacity allowance | $5.84 | $5.84 | Budget assumption: average one LCU at $0.008/LCU-hour |
| ACM certificate | $0 | $0 | Non-exportable public certificate used by ALB |
| Route 53 alias record | $0 additional | $0 additional | Existing zone; alias queries to ELB are free |
| **Estimated subtotal** | **$205.80** | **$435.96** | Before usage costs below |

The existing `hudson.tf` hosted zone costs $0.50/month once, not per environment;
it is already being paid for. Domain registration and renewal are separate.
State storage and S3 requests are usually well under $1/month for this project.
CloudWatch control-plane log ingestion and storage depend on traffic; allow a
few dollars initially and measure it. A reasonable light-use budget is roughly
**$210–225/month for dev** and **$440–465/month for prod**, or **$650–690/month
for both**. These are budget estimates, not limits or a bill guarantee.

For a short verification run, use these subtotal estimates:

| Runtime | Dev | Prod | Both |
| --- | ---: | ---: | ---: |
| 3 hours | $0.85 | $1.79 | $2.64 |
| 6 hours | $1.69 | $3.58 | $5.27 |
| 24 hours | $6.77 | $14.33 | $21.10 |

Allow **$2–3 for a short dev test** or **$8–10 for a day of dev**, including some
startup downloads and logs. Those allowances assume light traffic and successful
cleanup; they are not caps. Timing starts when AWS resources are provisioned,
including time spent waiting for a deployment or teardown.

Public Grafana adds about **$29.57/month in dev** or **$33.22/month in prod**,
including the one-LCU allowance and minimum public IPs. Capacity and IP counts
can grow under load. Without the LCU allowance, the fixed ingress floor is about
$23.73 / $27.38 per month. A 24-hour dev run is about **$6.77** at the subtotal
rate; prod is about **$14.33**, before variable charges. There is no separate
one-time EKS provisioning fee. Deployment, idle time, and teardown all count.

Add $0.045 for each GB processed by NAT, plus applicable internet and cross-zone
data transfer. Image pulls during first startup use NAT too. Dev's shared NAT
makes cross-zone charges more likely. Burstable CPU credit use can add EC2
charges. Extra nodes cost their instance rate and root disk storage. Retained
PVCs, snapshots, or ALBs left after a failed teardown continue to cost money.
If a cluster enters extended Kubernetes support, EKS's price rises to
$0.60/hour, adding $365/month; this configuration opts into STANDARD support.

Sources: [EKS](https://aws.amazon.com/eks/pricing/),
[EC2 Linux regional rate data](https://b0.p.awsstatic.com/pricing/2.0/meteredUnitMaps/ec2/USD/current/ec2-ondemand-without-sec-sel/US%20East%20(N.%20Virginia)/Linux/index.json),
[EBS](https://aws.amazon.com/ebs/pricing/),
[NAT and public IPv4](https://aws.amazon.com/vpc/pricing/),
[ALB](https://aws.amazon.com/elasticloadbalancing/pricing/),
[ACM](https://aws.amazon.com/certificate-manager/pricing/), and
[Route 53](https://aws.amazon.com/route53/pricing/).

## Checks

```bash
bash scripts/check.sh
bash scripts/test.sh
```

Checks install the locked providers, format-check the repo, validate every root,
and run offline Terraform plans with AWS lookups replaced by fixtures. They do
not contact AWS or create resources. Helm chart rendering is a separate local
check described in [verification](docs/verification.md). Live permissions,
quotas, DNS delegation, cluster readiness, and a second no-change AWS plan must
be checked during the first real deployment. Static validation cannot prove those.

## Tear it down

Use the [full cleanup and API audit runbook](docs/cleanup.md) to capture an
inventory before teardown and verify that billable resources are gone afterward.
The brief commands below are only the normal destruction sequence.

Select the same workspace in both roots. Save anything you want to keep from
Grafana and Prometheus, then destroy monitoring before the platform:

```bash
cd environments/observability
terraform workspace select dev
terraform destroy
cd ..
terraform workspace select dev
terraform destroy
cd ..
```

The ingress is deleted before its controller. Namespace deletion removes any
Prometheus PVCs retained by Helm; the storage class uses a Delete reclaim policy.
Before removing the cluster, confirm that the ALB and monitoring EBS volumes
are gone. A failed controller cleanup can leave AWS resources behind. If that
happens, fix it while the cluster and controller still exist. Do not delete the
cluster first and assume the finalizers will finish later.

The state bucket, bootstrap roles, and existing hosted zone remain. Keep state
versions until you no longer need recovery. Removing bootstrap protection is an
explicit cleanup task, not part of destroying dev or prod.

## What this is not

This is a small platform reference, not a production service or a claim that
workspaces isolate tenants. It has no application deployment, service mesh,
GitOps controller, custom operators, autoscaler, remote metrics storage,
monitoring high availability, disaster recovery, or staffed alert response.
The prod inputs improve node and NAT capacity; they do not create those missing
operating practices. Grafana's password login is a starting point, not a complete
identity system for a team.
