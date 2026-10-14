# Cleanup and audit

[Repository overview](../README.md) · [Deployment](deployment.md) · [Costs](costs.md)

This procedure removes an environment and checks AWS for resources that still
exist. It also covers retiring the shared backend and CI identities when the
whole reference is finished. The existing `hudson.tf` hosted zone and domain
are outside this repo's ownership and must remain.

Each shell block starts at the repository root, enters the relevant Terraform
folder, and returns to the root when finished.

Use this sequence before deliberately replacing the cluster as well. Keep the
currently deployed cluster settings until monitoring is destroyed and audited;
changing the cluster name first makes Helm and Kubernetes look up a different
API. CI stops when a platform plan would delete or replace EKS.

A successful `terraform destroy` is one piece of evidence. It does not prove
that controller-created load balancers, retained disks, or manually detached
resources are gone. Use the AWS audit after destroy. It is read-only; it never
deletes anything or treats an access-denied response as proof of deletion.

## 1. Stop deployments and choose the scope

Disable the Terraform workflow in GitHub before cleanup. Wait for any running
apply to finish; do not cancel an apply and then launch a destroy against it.
Decide whether you are removing dev, prod, or both. If keeping an environment,
keep bootstrap and its state bucket. Work from a fresh AWS session that can
read the relevant AWS services and destroy the environment. The audit also
needs IAM reads and permission to describe snapshots and load balancer tags.

For dev, select the workspace in both roots and capture its identity:

```bash
export AUDIT_ENV=dev
cd environments
terraform workspace select "$AUDIT_ENV"
export AUDIT_REGION=$(terraform output -raw region)
export AUDIT_CLUSTER=$(terraform output -raw cluster_name)
terraform workspace show
cd observability
terraform workspace select "$AUDIT_ENV"
export AUDIT_ZONE=$(terraform output -raw hosted_zone_id)
terraform workspace show
cd ../..
aws sts get-caller-identity
```

Set `AUDIT_ENV=prod` when removing prod. Recheck
these values before each plan. The same region must be used for every regional
AWS audit call. IAM is account-wide.

## 2. Save the inventory before deleting anything

```bash
umask 077
python3 scripts/audit.py snapshot \
  --environment "$AUDIT_ENV" --region "$AUDIT_REGION" \
  --cluster-name "$AUDIT_CLUSTER" --snapshot "audit/$AUDIT_ENV-before.json"
cd environments
terraform state list > "../audit/$AUDIT_ENV-platform-state.txt"
cd observability
terraform state list > "../../audit/$AUDIT_ENV-monitoring-state.txt"
terraform show -json > "../../audit/$AUDIT_ENV-monitoring-before.json"
kubectl -n monitoring get ingress,pvc -o yaml > "../../audit/$AUDIT_ENV-kubernetes.yaml"
cd ../..
```

Refresh kubeconfig for this cluster first if needed. The snapshot records its
account, region, cluster name, VPC children, EC2 instances, NAT gateways, EIPs,
EBS volumes, launch templates, load balancers, target groups, control-plane log
groups, IAM roles, IRSA providers, and certificates. It includes tagged EBS
snapshots if any were made manually. These files contain infrastructure metadata
and should remain private; `audit/` is ignored by git.

The script uses AWS CLI pagination. It finds VPC children even without ownership
tags and independently scans resources tagged `project=eks-platform-reference`
and the selected `environment`. Captured resource IDs are checked after teardown
even if their tags were removed. A resource created later with no ownership
tags and outside the captured VPC is outside this audit's detection boundary.
Keep deployments disabled so the inventory stays useful.

## 3. Destroy monitoring while its controllers still run

Back up any dashboards or metrics you intend to keep. The monitoring disks
will be deleted. Inspect the destruction plan before executing it:

```bash
cd environments/observability
terraform workspace show
terraform plan -destroy -out=cleanup.tfplan
terraform apply cleanup.tfplan
terraform state list
cd ../..
```

The state list should be empty. Ingress deletion must complete before the ALB
controller is removed. The controller's finalizer deletes the ALB, listeners,
target groups, and its security group. Helm teardown removes Grafana's PVC;
namespace deletion removes Prometheus PVCs retained by the chart. The gp3
storage class has a Delete reclaim policy, so the EBS driver deletes their disks.
Terraform deletes the ACM certificate, its validation records, and the Grafana
alias record. It does not delete the public hosted zone.

If destroy hangs on an ingress or PVC, keep the platform running. Check:

```bash
kubectl -n monitoring get ingress,pvc
kubectl -n kube-system logs deployment/aws-load-balancer-controller --tail=100
kubectl -n kube-system logs deployment/ebs-csi-controller -c ebs-plugin --tail=100
kubectl get pv
```

Check the controller's IAM role and AWS API errors before retrying. Do not
remove finalizers simply to make Terraform finish: that can orphan billable
resources. Restore the controller if it was removed early, or deliberately
clean up the captured AWS objects and verify each deletion before clearing a
finalizer. Never delete another application's disks or shared security groups.

## 4. Destroy the platform

Only proceed when monitoring state is empty and its ALB and volumes are gone.
Use the inventory to inspect their exact IDs in AWS if needed.

```bash
cd environments
terraform workspace show
terraform plan -destroy -out=cleanup.tfplan
terraform apply cleanup.tfplan
terraform state list
cd ..
```

This removes EKS add-ons, the managed node group and its instances, the cluster,
IRSA providers and controller roles, the launch template, log group, NAT
resources, subnets, routing, internet gateway, and VPC. Network interfaces or
load balancers left by a controller can block VPC deletion. If the platform
destroy fails, inspect the blocking ID rather than forcing Terraform to forget it.

## 5. Audit AWS and DNS

```bash
python3 scripts/audit.py audit \
  --environment "$AUDIT_ENV" --region "$AUDIT_REGION" \
  --cluster-name "$AUDIT_CLUSTER" --snapshot "audit/$AUDIT_ENV-before.json" \
  --report "audit/$AUDIT_ENV-after.json"
```

Exit codes: `0` means no audited environment resources remain, `1` lists
remaining resources, and `2` means the audit was incomplete. An incomplete
audit is not a pass. Some APIs retain deleted NAT gateways and terminated EC2
instances temporarily; the script treats those terminal states as deleted.
Repeat after AWS finishes asynchronous cleanup if objects are still deleting.

To inspect individual captured objects directly:

```bash
aws eks describe-cluster --name "$AUDIT_CLUSTER" --region "$AUDIT_REGION"
# Expected: ResourceNotFoundException. Other errors do not prove deletion.
aws ec2 describe-vpcs --region "$AUDIT_REGION" \
  --filters "Name=tag:project,Values=eks-platform-reference" "Name=tag:environment,Values=$AUDIT_ENV"
aws ec2 describe-volumes --region "$AUDIT_REGION" \
  --filters "Name=tag:project,Values=eks-platform-reference" "Name=tag:environment,Values=$AUDIT_ENV"
aws ec2 describe-addresses --region "$AUDIT_REGION" \
  --filters "Name=tag:project,Values=eks-platform-reference" "Name=tag:environment,Values=$AUDIT_ENV"
aws ec2 describe-nat-gateways --region "$AUDIT_REGION" \
  --filter "Name=tag:project,Values=eks-platform-reference" "Name=tag:environment,Values=$AUDIT_ENV"
```

Expect empty VPC, volume, and address collections. NAT results may contain only
`deleted` gateways. The script checks load balancers, target groups, IAM roles,
and log groups too; do not use these four commands as the entire audit.

Check Route 53 separately. The snapshot does not capture DNS records because
they cannot carry ownership tags. The saved monitoring
state JSON contains its ACM validation record names. Keep that file private;
Terraform state can contain secrets. A state-address list alone does not contain
the DNS record values. Use the exact `AUDIT_ZONE` captured before destruction;
selecting the first zone returned by a name lookup can audit the wrong zone.

```bash
aws route53 list-resource-record-sets --hosted-zone-id "$AUDIT_ZONE" \
  --output json > "audit/$AUDIT_ENV-dns-after.json"
jq --arg host "grafana.$AUDIT_ENV.hudson.tf." \
  '[.ResourceRecordSets[] | select(.Name == $host or (.Name | endswith("." + $host)))]' \
  "audit/$AUDIT_ENV-dns-after.json"
```

Expect an empty array for the Grafana alias and its `_token.grafana...` ACM
validation CNAME. Keep unrelated records, including the zone's NS and SOA.
If hostnames were changed in tfvars, use the names from the before inventory
instead of the sample hostname above. Deleting DNS alone never deletes an ALB.

## 6. Verify state is empty, then remove the unused workspaces

Both `terraform state list` commands must return no managed resource addresses.
A no-resource state object may remain in S3 until the workspace is removed.
Select another workspace first:

```bash
cd environments
terraform workspace select default
terraform workspace delete "$AUDIT_ENV"
cd observability
terraform workspace select default
terraform workspace delete "$AUDIT_ENV"
cd ../..
```

Use your bootstrap credentials for workspace deletion: CI roles deliberately
cannot delete state objects. The default-workspace guard blocks plans and
applies, but workspace selection for maintenance is allowed. Never use
`workspace delete -force` to hide a non-empty state. S3 versioning retains old
state versions after deletion; that is intentional recovery data and still
uses storage. Do not use `force-unlock` unless you have verified there is no
Terraform process holding the lock.

Repeat steps 1–6 for the other environment if removing both. Keep the before
and after reports as cleanup evidence.

## 7. Retire bootstrap only when both environments are gone

Normal environment cleanup leaves the state bucket and the four GitHub roles.
This is expected. They are shared infrastructure, and the bucket contains the
bootstrap state. To retire the entire repo's AWS footprint:

1. Confirm both environment audits passed and neither workspace has resources.
   Disable the workflow and remove its `AWS_ROLE_ARN` variables in GitHub.
2. Save bootstrap outputs and inventory its exact bucket and role ARNs. Record
   whether the GitHub OIDC provider was created here or supplied as an existing
   provider. An existing shared provider must remain.
3. Move bootstrap state back to a secured local backend before deleting the
   bucket. Change the local `bootstrap/backend.tf` to `terraform { backend
   "local" {} }` on separate lines, then run
   `terraform init -migrate-state` from the `bootstrap` folder. Confirm the
   prompt and verify `terraform state list` still includes bootstrap
   resources. Keep an encrypted backup until the audit passes.
4. Remove the bucket's `prevent_destroy` only for this deliberate retirement.
   From that same folder, review `terraform plan -destroy`. Set
   `force_destroy = true` on that bucket for this cleanup so Terraform removes **all object versions
   and delete markers**, then save and apply the destroy plan. This erases state
   history permanently. Keep it off during normal operation.
5. If this repo created the GitHub OIDC provider but other repositories now use
   it, transfer its ownership and remove it from this destroy scope before
   applying. Check those dependencies explicitly; an account-wide issuer can
   be shared. Imported or externally supplied providers are not disposable.

Verify with read APIs, using the exact IDs saved before retirement:

```bash
aws s3api head-bucket --bucket "$AUDIT_BUCKET"
# Expected HTTP 404 / NoSuchBucket. A 403 is inconclusive.
aws iam get-role --role-name "$AUDIT_ROLE_NAME"
# Repeat for all four saved roles. Expected NoSuchEntity.
aws iam get-open-id-connect-provider --open-id-connect-provider-arn "$AUDIT_GITHUB_OIDC_ARN"
# Only for a provider owned and retired here. Expected NoSuchEntity.
cd bootstrap
terraform state list
# Expected no managed resources.
cd ..
```

Finally confirm the hosted zone and the domain still exist, remove temporary
local plan files and kubeconfig contexts for deleted clusters, and store or
remove the private audit files according to your own retention needs. IAM's
AWS-created service-linked roles may remain and are reused by other clusters;
they are not billable and are not owned by this repo. Do not delete them just
to make an account-wide IAM list empty.

## 8. Check the bill after AWS has caught up

Cost Explorer and billing data lag resource deletion. On the following day,
check EKS, EC2 compute, EC2 Other (NAT, EBS and IPv4), ELB, CloudWatch, and S3
for continued usage. Charges for the deployment day can arrive later even when
cleanup was successful; compare usage dates, not only the posting time.
Route 53's existing hosted zone and domain renewal charges should continue.

A resource audit proves the checked resources are gone at the audit time.
A billing review catches costs from resources outside the inventory or older
experiments. Neither should be presented as proof that every resource in a
shared AWS account has been deleted.
