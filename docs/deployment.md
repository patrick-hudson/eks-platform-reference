# Deployment

[Repository overview](../README.md) · [GitHub Actions](github-actions.md) · [Cleanup](cleanup.md)

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
and in both environment entries in `environments/observability/terraform.tfvars`.
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
billable AWS resources. Read the [cost breakdown](costs.md) before leaving a
cluster running.

### Bootstrap state and CI roles

Authenticate your AWS profile first using your configured login method
(`aws login` or `aws sso login`), then select it for this shell:

```bash
export AWS_PROFILE=YOUR_PROFILE
aws sts get-caller-identity
cp bootstrap/terraform.tfvars.example bootstrap/terraform.tfvars
```

Read the repository value GitHub actually uses in its OIDC subject:

```bash
gh api repos/OWNER/REPOSITORY/actions/oidc/customization/sub \
  --jq '.sub_claim_prefix | sub("^repo:"; "")'
```

Set `github_repository` in the local tfvars file to that exact result. New
repositories use `OWNER@OWNER-ID/REPOSITORY@REPOSITORY-ID`; older repositories
may use `OWNER/REPOSITORY`. Do not infer the value from the repository URL.
The module adds `repo:` and the exact environment to build the trust condition.
An incorrect value causes `Not authorized to perform sts:AssumeRoleWithWebIdentity`.
After correcting it, plan and apply bootstrap again to update the role trusts,
then retry the workflow. This does not require reapplying the EKS platform.
See [GitHub's subject formats](https://docs.github.com/en/actions/reference/security/oidc#immutable-subject-claims).

Choose a globally unique state bucket and confirm the cluster and role names
match the environment inputs. Confirm that `hosted_zone_id` identifies the zone whose
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
