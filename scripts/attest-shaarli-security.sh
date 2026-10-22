#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

usage() {
  cat <<'EOF'
Usage: attest-shaarli-security.sh INSTANCE [--runtime]

Report the configured image, active revision, Easy Auth boundary, and anonymous
endpoint behavior for a Shaarli instance.

With --runtime, execute php84 --version in a running replica and require a PHP
release that contains the PHP2Shell fixes, then issue a read-only internal HTTP
request to prove Shaarli renders. Sign in through the browser first if the
instance has scaled to zero. Azure CLI requires an interactive terminal for
container exec.
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -ge 1 ]] || {
  usage >&2
  exit 2
}

instance_name="$1"
shift
check_runtime="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --runtime)
      check_runtime="true"
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    *)
      die "unknown argument: $1"
      ;;
  esac
done

ensure_azure_ready
load_instance "$instance_name"

account_json="$(az account show --query '{name:name,id:id,tenantId:tenantId}' -o json)"
app_json="$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query '{image:properties.template.containers[0].image,latestRevision:properties.latestRevisionName,latestReadyRevision:properties.latestReadyRevisionName,runningStatus:properties.runningStatus,minReplicas:properties.template.scale.minReplicas,maxReplicas:properties.template.scale.maxReplicas}' \
  -o json)"
auth_json="$(az containerapp auth show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query '{enabled:platform.enabled,unauthenticatedAction:globalValidation.unauthenticatedClientAction,allowedPrincipals:identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities}' \
  -o json)"
configured_image="$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'properties.template.containers[0].image' \
  -o tsv)"
auth_enabled="$(az containerapp auth show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query platform.enabled \
  -o tsv)"
unauthenticated_action="$(az containerapp auth show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query globalValidation.unauthenticatedClientAction \
  -o tsv)"
allowed_principal_count="$(az containerapp auth show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'length(identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities)' \
  -o tsv)"
app_url="https://$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn \
  -o tsv)"
status_code="$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' \
  --max-time 30 \
  "$app_url" || true)"

printf '%s\n' "$account_json"
printf '%s\n' "$app_json"
printf '%s\n' "$auth_json"
printf '{"url":"%s","anonymousStatus":%s}\n' "$app_url" "${status_code:-0}"

result="PASS"
[[ "$configured_image" =~ @sha256:[0-9a-f]{64}$ ]] || result="FAIL"
[[ "$auth_enabled" == "true" ]] || result="FAIL"
[[ "$unauthenticated_action" != "AllowAnonymous" && -n "$unauthenticated_action" ]] || result="FAIL"
[[ "$allowed_principal_count" == "1" ]] || result="FAIL"
[[ "$status_code" == "302" || "$status_code" == "401" ]] || result="FAIL"

if [[ "$check_runtime" == "true" ]]; then
  require_command python3
  [[ -t 0 ]] ||
    die "runtime attestation requires an interactive terminal because 'az containerapp exec' allocates a TTY"
  log "Checking PHP in the running application replica"
  if ! runtime_output="$(az containerapp exec \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --command 'php84 --version' 2>&1)"; then
    printf '%s\n' "$runtime_output" >&2
    die "runtime attestation failed; sign in through the browser to wake the replica, then retry from an interactive terminal"
  fi
  printf '%s\n' "$runtime_output"
  php_version="$(printf '%s\n' "$runtime_output" |
    sed -nE 's/.*PHP ([0-9]+\.[0-9]+\.[0-9]+).*/\1/p' |
    head -n 1)"
  [[ -n "$php_version" ]] || die "could not parse PHP version from runtime output"

  if ! python3 - "$php_version" <<'PY'
import sys

version = tuple(int(part) for part in sys.argv[1].split("."))
fixed = {
    (8, 2): (8, 2, 35),
    (8, 3): (8, 3, 36),
    (8, 4): (8, 4, 27),
    (8, 5): (8, 5, 12),
}
minimum = fixed.get(version[:2])
if minimum is None:
    sys.exit(0 if version >= (8, 6, 0) else 1)
sys.exit(0 if version >= minimum else 1)
PY
  then
    result="FAIL"
  fi

  log "Checking that Shaarli renders through the container's internal web port"
  if ! app_output="$(az containerapp exec \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --command 'wget -qO /dev/null http://127.0.0.1/' 2>&1)"; then
    printf '%s\n' "$app_output" >&2
    result="FAIL"
  else
    printf 'Internal Shaarli render: PASS\n'
  fi
else
  [[ "$result" == "PASS" ]] && result="INCOMPLETE"
  printf 'Runtime PHP version: not checked (re-run with --runtime)\n'
fi

printf 'Security attestation: %s\n' "$result"
[[ "$result" == "PASS" ]]
