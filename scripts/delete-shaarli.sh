#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

usage() {
  cat <<'EOF'
Usage: delete-shaarli.sh INSTANCE [--yes]

Permanently delete an entire Shaarli instance, including its data, snapshots,
Container App, storage account, environment, and Entra app registration.

Options:
  --yes   Do not prompt for confirmation
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
assume_yes=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --yes)
      assume_yes=true
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

if [[ "$assume_yes" != "true" ]]; then
  [[ -t 0 ]] || die "refusing non-interactive deletion without --yes"
  printf "Delete Shaarli instance '%s' and all of its data? Type the instance name to confirm: " \
    "$instance_name" >&2
  read -r confirmation
  [[ "$confirmation" == "$instance_name" ]] || die "confirmation did not match; nothing was deleted"
fi

log "Deleting $RESOURCE_GROUP and all Azure resources in the instance"
az group delete \
  --name "$RESOURCE_GROUP" \
  --yes \
  --output none

if [[ -n "$AUTH_APP_ID" ]] && az ad app show --id "$AUTH_APP_ID" >/dev/null 2>&1; then
  log "Deleting Microsoft Entra app registration $AUTH_APP_ID"
  az ad app delete --id "$AUTH_APP_ID"
fi

printf "Shaarli instance '%s' was deleted.\n" "$instance_name"
