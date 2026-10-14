#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TARGET:?}" "${EVENT:?}" "${OPERATION:?}" "${AWS_REGION:?}" "${STATE_BUCKET:?}"
case "$TARGET" in dev|prod) ;; *) echo "Invalid environment" >&2; exit 1 ;; esac
case "$EVENT:$OPERATION" in
  pull_request:plan|push:apply|workflow_dispatch:plan|workflow_dispatch:apply) ;;
  *) echo "Invalid event and operation combination" >&2; exit 1 ;;
esac
export TF_WORKSPACE="$TARGET"
cd environments
# Read cluster details from the reviewed plan rather than a second naming convention.
init_root() {
  terraform init -input=false -lockfile=readonly \
    -backend-config="bucket=$STATE_BUCKET" \
    -backend-config="region=$AWS_REGION" \
    -backend-config="key=$1.tfstate" \
    -backend-config="workspace_key_prefix=environments" \
    -backend-config="encrypt=true" \
    -backend-config="use_lockfile=true"
  if [[ "$OPERATION" == plan ]]; then
    env -u TF_WORKSPACE terraform workspace select "$TARGET"
  else
    env -u TF_WORKSPACE terraform workspace select -or-create "$TARGET"
  fi
}
plan_root() {
  if [[ "$OPERATION" == plan ]]; then
    # The plan role cannot create locks or mutate infrastructure. Apply replans under a lock.
    terraform plan -input=false -lock=false -no-color -out=deploy.tfplan
  else
    terraform plan -input=false -lock-timeout=5m -out=deploy.tfplan
  fi
}
init_root platform
plan_root
plan_json=$(terraform show -json deploy.tfplan)
if [[ "$OPERATION" == apply ]] && jq -e \
  '.resource_changes // [] | any(.type == "aws_eks_cluster" and (.change.actions | index("delete") != null))' \
  <<< "$plan_json" >/dev/null; then
  echo "Cluster deletion or replacement requires monitoring-first cleanup and audit; see docs/cleanup.md before applying." >&2
  exit 1
fi
cluster_name=$(jq -r '.planned_values.outputs.cluster_name.value' <<< "$plan_json")
cluster_region=$(jq -r '.planned_values.outputs.region.value' <<< "$plan_json")
if [[ "$AWS_REGION" != "$cluster_region" ]]; then
  echo "GitHub AWS_REGION must match the Terraform region input" >&2
  exit 1
fi
if [[ "$OPERATION" == apply ]]; then
  terraform apply -input=false -lock-timeout=5m deploy.tfplan
fi
if ! status=$(aws eks describe-cluster --name "$cluster_name" --region "$cluster_region" --query cluster.status --output text 2>&1); then
  if [[ "$OPERATION" == plan && "$status" == *ResourceNotFoundException* ]]; then
    printf 'Monitoring plan deferred: this cluster does not exist yet. Merge applies platform first.\n'
    exit 0
  fi
  printf '%s\n' "$status" >&2
  exit 1
fi
if [[ "$status" != ACTIVE ]]; then
  printf 'Cluster is %s; monitoring requires an ACTIVE cluster.\n' "$status" >&2
  exit 1
fi
cd observability
init_root observability
plan_root
if [[ "$OPERATION" == apply ]]; then
  terraform apply -input=false -lock-timeout=5m deploy.tfplan
fi
