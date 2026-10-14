#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${TARGET:?}" "${EVENT:?}" "${OPERATION:?}" "${AWS_REGION:?}" "${STATE_BUCKET:?}"
case "$TARGET" in dev|prod) ;; *) echo "Invalid environment" >&2; exit 1 ;; esac
case "$EVENT:$OPERATION" in
  pull_request:plan|workflow_dispatch:plan|workflow_dispatch:apply) ;;
  *) echo "Invalid event and operation combination" >&2; exit 1 ;;
esac
export TF_WORKSPACE="$TARGET"
if [[ -n "${PLAN_REPORT:-}" ]]; then
  printf '| Root | Result | Add | Change | Destroy | Replace |\n| --- | --- | ---: | ---: | ---: | ---: |\n' > "$PLAN_REPORT"
fi
report_status() {
  if [[ -n "${PLAN_REPORT:-}" ]]; then
    printf '| %s | %s | — | — | — | — |\n' "$1" "$2" >> "$PLAN_REPORT"
  fi
}
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
  local root="$1"
  local -a options=(-input=false -no-color -out=deploy.tfplan)
  if [[ "$OPERATION" == plan ]]; then
    # The plan role cannot create locks or mutate infrastructure. Apply replans under a lock.
    options+=(-lock=false)
  else
    options+=(-lock-timeout=5m)
  fi
  if ! terraform plan "${options[@]}"; then
    report_status "$root" Failed
    return 1
  fi
  if ! plan_json=$(terraform show -json deploy.tfplan); then
    report_status "$root" Failed
    return 1
  fi
  if [[ -n "${PLAN_REPORT:-}" ]]; then
    jq -r --arg root "$root" '
      [.resource_changes[]?.change.actions] as $actions |
      [$root, "Planned",
       ([$actions[] | select(index("create"))] | length),
       ([$actions[] | select(index("update"))] | length),
       ([$actions[] | select(index("delete"))] | length),
       ([$actions[] | select(index("create") and index("delete"))] | length)] |
      "| " + (map(tostring) | join(" | ")) + " |"
    ' <<< "$plan_json" >> "$PLAN_REPORT"
  fi
}
init_root platform
plan_root Platform
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
    report_status Monitoring 'Deferred: cluster does not exist'
    printf 'Monitoring plan deferred: this cluster does not exist yet. Run a manual apply to create the platform first.\n'
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
plan_root Monitoring
if [[ "$OPERATION" == apply ]]; then
  terraform apply -input=false -lock-timeout=5m deploy.tfplan
fi
