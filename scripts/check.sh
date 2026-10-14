#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
terraform fmt -check -recursive
for root in bootstrap environments environments/observability; do
  (
    cd "$root"
    terraform init -backend=false -input=false -lockfile=readonly
    terraform validate
  )
done
