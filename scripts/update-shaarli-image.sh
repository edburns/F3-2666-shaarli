#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

usage() {
  cat <<'EOF'
Usage: update-shaarli-image.sh INSTANCE [--image IMAGE@sha256:DIGEST] [--yes]

Roll out an immutable Shaarli image to an existing instance without changing
storage, ingress, authentication, scale, CPU, or memory settings.

The script refuses mutable tags, verifies Easy Auth before and after the update,
takes an Azure Files share snapshot before mutation, waits for the new revision
to become ready, and confirms the configured digest. Run
attest-shaarli-security.sh --runtime afterward to verify PHP and Shaarli inside
the running replica.

Options:
  --image   Immutable image reference
            (default: pinned Shaarli v0.16.10 with PHP 8.4.27)
  --yes     Do not prompt for confirmation
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
image="$SHAARLI_DEFAULT_IMAGE"
assume_yes="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --image)
      [[ $# -ge 2 ]] || die "--image requires a value"
      image="$2"
      shift 2
      ;;
    --yes)
      assume_yes="true"
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

validate_pinned_image "$image"
ensure_azure_ready
load_instance "$instance_name"

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

[[ "$auth_enabled" == "true" ]] ||
  die "Easy Auth is not enabled; refusing to roll out an Internet-accessible PHP container"
[[ "$unauthenticated_action" != "AllowAnonymous" && -n "$unauthenticated_action" ]] ||
  die "Easy Auth allows anonymous traffic; disable ingress or repair authentication before updating"
[[ "$allowed_principal_count" == "1" ]] ||
  die "expected exactly one allowed Entra principal, found ${allowed_principal_count:-none}"

current_image="$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'properties.template.containers[0].image' \
  -o tsv)"
current_revision="$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.latestReadyRevisionName \
  -o tsv)"

printf 'Instance:         %s\n' "$instance_name"
printf 'Container App:    %s\n' "$APP_NAME"
printf 'Current revision: %s\n' "${current_revision:-none}"
printf 'Current image:    %s\n' "${current_image:-none}"
printf 'Target image:     %s\n' "$image"

if [[ "$current_image" == "$image" ]]; then
  printf '\nThe configured image already matches the requested digest.\n'
  printf 'Run: %s/attest-shaarli-security.sh %s --runtime\n' "$SCRIPT_DIR" "$instance_name"
  exit 0
fi

if [[ "$assume_yes" != "true" ]]; then
  printf '\nCreate a new revision using the target image? [y/N] '
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || die "aborted"
fi

storage_key="$(az storage account keys list \
  --account-name "$STORAGE_ACCOUNT" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[0].value' \
  -o tsv)"
log "Taking a point-in-time snapshot of the persistent Shaarli data"
data_snapshot="$(az storage share snapshot \
  --name "$SHAARLI_DATA_SHARE" \
  --account-name "$STORAGE_ACCOUNT" \
  --account-key "$storage_key" \
  --metadata \
    "reason=shaarli-image-update" \
    "instance=$instance_name" \
  --query snapshot \
  -o tsv)"
unset storage_key
[[ -n "$data_snapshot" ]] ||
  die "Azure Files did not return a snapshot timestamp; refusing to update the image"
printf 'Data snapshot:    %s\n' "$data_snapshot"

log "Updating $APP_NAME to the immutable image digest"
az containerapp update \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --image "$image" \
  --output none

log "Waiting for the new revision to become ready"
latest_revision=""
ready_revision=""
for _ in {1..60}; do
  latest_revision="$(az containerapp show \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query properties.latestRevisionName \
    -o tsv)"
  ready_revision="$(az containerapp show \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query properties.latestReadyRevisionName \
    -o tsv)"
  if [[ -n "$latest_revision" && "$latest_revision" == "$ready_revision" ]]; then
    break
  fi
  sleep 5
done

[[ -n "$latest_revision" && "$latest_revision" == "$ready_revision" ]] ||
  die "new revision did not become ready; inspect 'az containerapp revision list --name $APP_NAME --resource-group $RESOURCE_GROUP -o table'"

configured_image="$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'properties.template.containers[0].image' \
  -o tsv)"
[[ "$configured_image" == "$image" ]] ||
  die "Azure reports unexpected image '$configured_image' after the update"

post_auth_enabled="$(az containerapp auth show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query platform.enabled \
  -o tsv)"
post_unauthenticated_action="$(az containerapp auth show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query globalValidation.unauthenticatedClientAction \
  -o tsv)"
[[ "$post_auth_enabled" == "true" && "$post_unauthenticated_action" == "$unauthenticated_action" ]] ||
  die "authentication settings changed during rollout; disable ingress and inspect the app"

app_url="https://$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn \
  -o tsv)"
status_code="$(curl --silent --show-error --output /dev/null \
  --write-out '%{http_code}' \
  --max-time 30 \
  "$app_url" || true)"
[[ "$status_code" == "302" || "$status_code" == "401" ]] ||
  die "Easy Auth did not reject the anonymous verification request (HTTP ${status_code:-none})"

printf '\nUpdated %s to revision %s.\n' "$instance_name" "$ready_revision"
printf 'Configured image: %s\n' "$configured_image"
printf 'Anonymous endpoint check: HTTP %s\n' "$status_code"
printf 'Pre-update data snapshot: %s\n' "$data_snapshot"
printf '\nSign in once through the browser to wake the application replica, then run:\n'
printf '  %s/attest-shaarli-security.sh %s --runtime\n' "$SCRIPT_DIR" "$instance_name"
