#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
# Synthetic fixtures and overridden AWS data sources make all plans credential-free.
(
  cd bootstrap
  terraform test -var-file=tests/fixtures.tfvars
)
for target in dev prod; do
  (
    cd environments
    TF_WORKSPACE="$target" terraform test -var="test_workspace=$target"
    cd observability
    TF_WORKSPACE="$target" terraform test -var="test_workspace=$target"
  )
done
python3 -m unittest discover -s tests -v
