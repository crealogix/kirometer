#!/usr/bin/env bash
# Run a command with a short-lived Managed Grafana service account token in
# GRAFANA_AUTH, e.g. `tofu plan` for the grafana stack.
#
#   scripts/with-grafana-token.sh <platform-stack-dir> -- <command> [args...]
#
# The token lives for at most one hour, is deleted when the command exits,
# and is never written to disk or to OpenTofu state.
set -euo pipefail

if [[ $# -lt 3 || $2 != "--" ]]; then
  echo "usage: $0 <platform-stack-dir> -- <command> [args...]" >&2
  exit 2
fi
platform_dir=$1
shift 2

workspace_id=$(tofu -chdir="$platform_dir" output -raw grafana_workspace_id)
service_account_id=$(tofu -chdir="$platform_dir" output -raw grafana_service_account_id)

response=$(aws grafana create-workspace-service-account-token \
  --workspace-id "$workspace_id" \
  --service-account-id "$service_account_id" \
  --name "opentofu-$(date -u +%Y%m%dT%H%M%SZ)-$$" \
  --seconds-to-live 3600 \
  --output json)

token_id=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["serviceAccountToken"]["id"])' <<<"$response")

cleanup() {
  aws grafana delete-workspace-service-account-token \
    --workspace-id "$workspace_id" \
    --service-account-id "$service_account_id" \
    --token-id "$token_id" >/dev/null \
    || echo "warning: could not delete Grafana token $token_id; it expires within an hour" >&2
}
trap cleanup EXIT

GRAFANA_AUTH=$(python3 -c 'import json,sys; print(json.load(sys.stdin)["serviceAccountToken"]["key"])' <<<"$response")
unset response
export GRAFANA_AUTH

"$@"
