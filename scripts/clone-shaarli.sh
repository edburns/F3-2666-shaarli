#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

usage() {
  cat <<'EOF'
Usage: clone-shaarli.sh SOURCE TARGET [--location LOCATION] [--principal-id OBJECT_ID]

Create an isolated Shaarli instance whose persistent data starts as a
point-in-time copy of SOURCE. The source remains online.

Options:
  --location       Azure region (default: the source instance's region)
  --principal-id   Only this Entra user object ID may access the clone
                   (default: the signed-in Azure CLI user)
EOF
}

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  usage
  exit 0
fi

[[ $# -ge 2 ]] || {
  usage >&2
  exit 2
}

source_instance="$1"
target_instance="$2"
shift 2
location=""
principal_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)
      [[ $# -ge 2 ]] || die "--location requires a value"
      location="$2"
      shift 2
      ;;
    --principal-id)
      [[ $# -ge 2 ]] || die "--principal-id requires a value"
      principal_id="$2"
      shift 2
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
ensure_resource_providers
load_instance "$source_instance"

source_resource_group="$RESOURCE_GROUP"
source_app_name="$APP_NAME"
source_storage_account="$STORAGE_ACCOUNT"
source_storage_key="$(az storage account keys list \
  --account-name "$source_storage_account" \
  --resource-group "$source_resource_group" \
  --query '[0].value' \
  -o tsv)"
source_image="$(az containerapp show \
  --name "$source_app_name" \
  --resource-group "$source_resource_group" \
  --query 'properties.template.containers[0].image' \
  -o tsv)"
[[ -n "$location" ]] || location="$(az group show \
  --name "$source_resource_group" \
  --query location \
  -o tsv)"
[[ -n "$principal_id" ]] || principal_id="$(current_principal_id)"

provision_instance_base "$target_instance" "$location" "$source_image" "$principal_id"
target_resource_group="$RESOURCE_GROUP"
target_storage_account="$STORAGE_ACCOUNT"
target_storage_key="$(az storage account keys list \
  --account-name "$target_storage_account" \
  --resource-group "$target_resource_group" \
  --query '[0].value' \
  -o tsv)"

transfer_dir="$(mktemp -d "${TMPDIR:-/tmp}/shaarli-clone.XXXXXX")"
snapshot=""
cleanup() {
  local status=$?
  if [[ -n "$snapshot" ]]; then
    az storage share delete \
      --name "$SHAARLI_DATA_SHARE" \
      --snapshot "$snapshot" \
      --account-name "$source_storage_account" \
      --account-key "$source_storage_key" \
      --output none || true
  fi
  [[ -z "$transfer_dir" || ! -d "$transfer_dir" ]] || rm -rf -- "$transfer_dir"
  if [[ "$status" -ne 0 ]]; then
    printf "Clone failed; remove the incomplete target with: scripts/delete-shaarli.sh %q --yes\n" \
      "$target_instance" >&2
  fi
  return "$status"
}
trap cleanup EXIT

log "Snapshotting $source_instance for a consistent clone"
snapshot="$(az storage share snapshot \
  --name "$SHAARLI_DATA_SHARE" \
  --account-name "$source_storage_account" \
  --account-key "$source_storage_key" \
  --query snapshot \
  -o tsv)"

log "Copying the source data snapshot through $transfer_dir"
az storage file download-batch \
  --source "$SHAARLI_DATA_SHARE" \
  --snapshot "$snapshot" \
  --destination "$transfer_dir" \
  --account-name "$source_storage_account" \
  --account-key "$source_storage_key" \
  --output none
az storage file upload-batch \
  --source "$transfer_dir" \
  --destination "$SHAARLI_DATA_SHARE" \
  --account-name "$target_storage_account" \
  --account-key "$target_storage_key" \
  --output none

publish_instance "$target_instance"
