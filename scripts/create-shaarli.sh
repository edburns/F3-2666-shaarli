#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

usage() {
  cat <<'EOF'
Usage: create-shaarli.sh INSTANCE [--location LOCATION] [--image IMAGE] [--principal-id OBJECT_ID]

Create a new private Shaarli instance on Azure Container Apps.

Options:
  --location       Azure region (default: eastus)
  --image          Immutable Shaarli IMAGE@sha256:DIGEST reference
                   (default: pinned Shaarli v0.16.10 with PHP 8.4.27)
  --principal-id   Only this Entra user object ID may access the app
                   (default: the signed-in Azure CLI user)
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
location="$SHAARLI_DEFAULT_LOCATION"
image="$SHAARLI_DEFAULT_IMAGE"
principal_id=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --location)
      [[ $# -ge 2 ]] || die "--location requires a value"
      location="$2"
      shift 2
      ;;
    --image)
      [[ $# -ge 2 ]] || die "--image requires a value"
      image="$2"
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
[[ -n "$principal_id" ]] || principal_id="$(current_principal_id)"

provision_instance_base "$instance_name" "$location" "$image" "$principal_id"
publish_instance "$instance_name"
