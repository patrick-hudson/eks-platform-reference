#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
terraform fmt -check -recursive
for root in bootstrap environments environments/observability; do
  (
    cd "$root"
    terraform init -backend=false -input=false -lockfile=readonly
    if [[ "$root" == bootstrap ]]; then
      terraform validate
    else
      for workspace in dev prod; do
        TF_WORKSPACE="$workspace" terraform validate
      done
    fi
  )
done
