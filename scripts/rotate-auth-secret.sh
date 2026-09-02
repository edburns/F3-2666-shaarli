#!/usr/bin/env bash

set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib-shaarli.sh"

readonly SHAARLI_DEFAULT_SECRET_YEARS=2

usage() {
  cat <<'EOF'
Usage: rotate-auth-secret.sh INSTANCE [--years N] [--show] [--prune] [--yes]

Rotate the Microsoft Entra client secret that Container Apps Easy Auth uses to
protect a Shaarli instance.

The secret created at provisioning time expires. When it does, Easy Auth stops
being able to complete the OIDC exchange and the instance becomes unreachable,
with a failure that does not obviously point at an expired credential. Run this
before the expiry date to issue a replacement with no downtime.

A new secret is appended to the app registration, applied to the Container App,
and the active revision is restarted to pick it up. The previous secret is left
in place unless --prune is given, so a failed rotation can be rolled back.

Options:
  --years   Lifetime of the new secret in years (default: 2)
  --show    Report existing secrets and their expiry dates, then exit
  --prune   Delete superseded secrets after the new one is verified working
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
years="$SHAARLI_DEFAULT_SECRET_YEARS"
show_only="false"
prune="false"
assume_yes="false"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --years)
      [[ $# -ge 2 ]] || die "--years requires a value"
      [[ "$2" =~ ^[1-2]$ ]] || die "--years must be 1 or 2 (Entra caps client secrets at 2 years)"
      years="$2"
      shift 2
      ;;
    --show)
      show_only="true"
      shift
      ;;
    --prune)
      prune="true"
      shift
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

require_command python3

# Render the app registration's current secrets with days remaining, so both
# --show and the pre-rotation summary read the same way.
report_credentials() {
  local app_id="$1"
  az ad app credential list --id "$app_id" -o json |
    python3 -c '
import datetime
import json
import sys

credentials = json.load(sys.stdin)
if not credentials:
    print("  (none)")
    sys.exit(0)

now = datetime.datetime.now(datetime.timezone.utc)
for credential in sorted(credentials, key=lambda c: c.get("endDateTime") or ""):
    end_raw = credential.get("endDateTime")
    if end_raw:
        end = datetime.datetime.fromisoformat(end_raw.replace("Z", "+00:00"))
        days = (end - now).days
        state = "EXPIRED" if days < 0 else "%d days left" % days
        stamp = end.date().isoformat()
    else:
        state, stamp = "unknown", "unknown"
    print("  %s  expires %s  (%s)  %s" % (
        credential.get("keyId", "?"),
        stamp,
        state,
        credential.get("displayName") or "",
    ))
'
}

ensure_azure_ready
load_instance "$instance_name"

[[ -n "${AUTH_APP_ID:-}" ]] ||
  die "$RESOURCE_GROUP has no shaarliAuthAppId tag; this instance predates Entra authentication or its metadata was lost"

az ad app show --id "$AUTH_APP_ID" --query appId -o tsv >/dev/null 2>&1 ||
  die "Entra app registration $AUTH_APP_ID not found or not accessible with the signed-in account"

printf 'Instance:         %s\n' "$instance_name"
printf 'Container App:    %s\n' "$APP_NAME"
printf 'App registration: %s\n' "$AUTH_APP_ID"
printf 'Current secrets:\n'
report_credentials "$AUTH_APP_ID"

if [[ "$show_only" == "true" ]]; then
  exit 0
fi

if [[ "$assume_yes" != "true" ]]; then
  printf '\nIssue a new secret valid for %s year(s) and apply it? [y/N] ' "$years"
  read -r reply
  [[ "$reply" == "y" || "$reply" == "Y" ]] || die "aborted"
fi

# Preserve the issuer explicitly. Updating only the client id and secret should
# leave it alone, but re-sending it makes the rotation independent of whatever
# az's update semantics happen to be in the installed CLI version.
issuer="$(az containerapp auth show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query 'identityProviders.azureActiveDirectory.registration.openIdIssuer' \
  -o tsv 2>/dev/null || true)"
if [[ -z "$issuer" || "$issuer" == "null" ]]; then
  issuer="https://login.microsoftonline.com/$(az account show --query tenantId -o tsv)/v2.0"
fi

# Record which secrets existed beforehand so the new one can be identified and
# the old ones can be pruned by key id rather than by guessing at ordering.
previous_key_ids="$(az ad app credential list --id "$AUTH_APP_ID" --query '[].keyId' -o tsv)"

log "Appending a new client secret with a $years-year lifetime"
client_secret="$(az ad app credential reset \
  --id "$AUTH_APP_ID" \
  --append \
  --display-name "Container Apps Easy Auth (rotated $(date -u +%Y-%m-%d))" \
  --years "$years" \
  --query password \
  -o tsv)"
[[ -n "$client_secret" ]] || die "Entra did not return a client secret"

# Newly issued secrets are not always usable at the token endpoint the instant
# the Graph call returns. Give replication a moment before the app tries to use
# it, otherwise the first sign-in after the restart can fail spuriously.
log "Waiting for the credential to replicate"
sleep 20

log "Applying the new secret to $APP_NAME"
az containerapp auth microsoft update \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --client-id "$AUTH_APP_ID" \
  --client-secret "$client_secret" \
  --issuer "$issuer" \
  --yes \
  --output none
unset client_secret

active_revision="$(az containerapp revision list \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query '[?properties.active].name | [0]' \
  -o tsv)"
[[ -n "$active_revision" ]] ||
  die "could not find the active revision; the secret was updated but is not yet in effect"

log "Restarting revision $active_revision to load the new secret"
az containerapp revision restart \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --revision "$active_revision" \
  --output none

app_url="https://$(az containerapp show \
  --name "$APP_NAME" \
  --resource-group "$RESOURCE_GROUP" \
  --query properties.configuration.ingress.fqdn \
  -o tsv)"

# A working Easy Auth front end redirects anonymous callers to the login page
# (302) or rejects them (401). A 500 here means the sidecar could not use the
# secret, which is exactly the failure this script exists to avoid.
log "Verifying the authentication endpoint"
status_code=""
for _ in {1..30}; do
  status_code="$(curl --silent --show-error --output /dev/null \
    --write-out '%{http_code}' \
    --max-time 15 \
    "$app_url" || true)"
  if [[ "$status_code" == "302" || "$status_code" == "401" ]]; then
    break
  fi
  sleep 5
done

if [[ "$status_code" != "302" && "$status_code" != "401" ]]; then
  die "authentication endpoint did not come back healthy (last HTTP status: ${status_code:-none}); the previous secret is still present on the app registration, so re-running 'az containerapp auth microsoft update' with it will roll back"
fi

new_expiry="$(az ad app credential list --id "$AUTH_APP_ID" -o json |
  python3 -c '
import json
import sys

credentials = json.load(sys.stdin)
dated = [c for c in credentials if c.get("endDateTime")]
if not dated:
    sys.exit(0)
print(max(c["endDateTime"] for c in dated)[:10])
')"

if [[ -n "$new_expiry" ]]; then
  log "Recording the expiry date on $RESOURCE_GROUP"
  az group update \
    --name "$RESOURCE_GROUP" \
    --set "tags.shaarliAuthSecretExpiry=$new_expiry" \
    --output none
fi

if [[ "$prune" == "true" && -n "$previous_key_ids" ]]; then
  while IFS= read -r key_id; do
    [[ -n "$key_id" ]] || continue
    log "Deleting superseded secret $key_id"
    az ad app credential delete \
      --id "$AUTH_APP_ID" \
      --key-id "$key_id" \
      --output none
  done <<<"$previous_key_ids"
fi

printf '\nRotation complete for %q.\n' "$instance_name"
printf 'Endpoint: %s (HTTP %s)\n' "$app_url" "$status_code"
[[ -n "$new_expiry" ]] && printf 'New secret expires: %s\n' "$new_expiry"
printf 'Remaining secrets:\n'
report_credentials "$AUTH_APP_ID"
if [[ "$prune" != "true" ]]; then
  printf '\nThe previous secret was kept. Re-run with --prune once you are satisfied.\n'
fi
