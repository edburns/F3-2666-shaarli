#!/usr/bin/env bash

set -Eeuo pipefail

# These constants are consumed by scripts that source this library.
# shellcheck disable=SC2034
readonly SHAARLI_DEFAULT_IMAGE="ghcr.io/shaarli/shaarli:release"
# shellcheck disable=SC2034
readonly SHAARLI_DEFAULT_LOCATION="eastus"
readonly SHAARLI_DATA_SHARE="shaarli-data"
readonly SHAARLI_ENV_STORAGE="shaarli-data"
readonly SHAARLI_SCHEMA_VERSION="1"

log() {
  printf '==> %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

validate_instance_name() {
  local instance_name="$1"

  [[ "$instance_name" =~ ^[a-z0-9][a-z0-9-]{0,29}$ ]] ||
    die "instance names must be 1-30 lowercase letters, numbers, or hyphens and start with a letter or number"
}

validate_location() {
  [[ "$1" =~ ^[a-z0-9]+$ ]] || die "invalid Azure location: $1"
}

validate_image() {
  [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._:/@-]+$ ]] ||
    die "invalid container image reference: $1"
}

resource_group_for() {
  printf 'rg-shaarli-%s\n' "$1"
}

random_hex() {
  local byte_count="${1:-8}"
  od -An -N "$byte_count" -tx1 /dev/urandom | tr -d '[:space:]'
}

ensure_azure_ready() {
  require_command az
  require_command curl

  local account_state
  account_state="$(az account show --query state -o tsv 2>/dev/null)" ||
    die "Azure CLI is not signed in; run 'az login'"
  [[ "$account_state" == "Enabled" ]] ||
    die "the selected Azure subscription is not enabled"

  az containerapp --help >/dev/null 2>&1 ||
    die "Azure CLI Container Apps support is unavailable; run 'az extension add --name containerapp --upgrade'"
}

ensure_resource_providers() {
  local provider
  for provider in Microsoft.App Microsoft.Storage; do
    if [[ "$(az provider show --namespace "$provider" --query registrationState -o tsv)" != "Registered" ]]; then
      log "Registering Azure resource provider $provider"
      az provider register --namespace "$provider" --wait
    fi
  done
}

current_principal_id() {
  az ad signed-in-user show --query id -o tsv
}

tag_value() {
  local resource_group="$1"
  local tag_name="$2"
  az group show \
    --name "$resource_group" \
    --query "tags.\"$tag_name\"" \
    -o tsv
}

load_instance() {
  local instance_name="$1"
  validate_instance_name "$instance_name"

  RESOURCE_GROUP="$(resource_group_for "$instance_name")"
  [[ "$(az group exists --name "$RESOURCE_GROUP")" == "true" ]] ||
    die "Shaarli instance '$instance_name' does not exist ($RESOURCE_GROUP was not found)"

  APP_NAME="$(tag_value "$RESOURCE_GROUP" "shaarliAppName")"
  STORAGE_ACCOUNT="$(tag_value "$RESOURCE_GROUP" "shaarliStorageAccount")"
  AUTH_APP_ID="$(tag_value "$RESOURCE_GROUP" "shaarliAuthAppId")"
  [[ -n "$APP_NAME" && -n "$STORAGE_ACCOUNT" ]] ||
    die "$RESOURCE_GROUP is missing Shaarli lifecycle metadata"
}

provision_instance_base() {
  local instance_name="$1"
  local location="$2"
  local image="$3"
  local principal_id="$4"
  local suffix storage_key tenant_id client_secret environment_id

  validate_instance_name "$instance_name"
  validate_location "$location"
  validate_image "$image"
  RESOURCE_GROUP="$(resource_group_for "$instance_name")"
  [[ "$(az group exists --name "$RESOURCE_GROUP")" == "false" ]] ||
    die "Shaarli instance '$instance_name' already exists ($RESOURCE_GROUP already exists)"

  # Container App names must be shorter than 32 characters.
  suffix="$(random_hex 11)"
  APP_NAME="shaarli-$suffix"
  ENVIRONMENT_NAME="cae-$suffix"
  STORAGE_ACCOUNT="stsh$(random_hex 10)"

  log "Creating resource group $RESOURCE_GROUP in $location"
  az group create \
    --name "$RESOURCE_GROUP" \
    --location "$location" \
    --tags \
      "managedBy=shaarli-lifestyle" \
      "shaarliInstance=$instance_name" \
      "shaarliSchema=$SHAARLI_SCHEMA_VERSION" \
      "shaarliAppName=$APP_NAME" \
      "shaarliStorageAccount=$STORAGE_ACCOUNT" \
    --output none

  log "Creating durable Azure Files storage"
  az storage account create \
    --name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$location" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --min-tls-version TLS1_2 \
    --https-only true \
    --allow-blob-public-access false \
    --output none
  storage_key="$(az storage account keys list \
    --account-name "$STORAGE_ACCOUNT" \
    --resource-group "$RESOURCE_GROUP" \
    --query '[0].value' \
    -o tsv)"
  az storage share create \
    --name "$SHAARLI_DATA_SHARE" \
    --account-name "$STORAGE_ACCOUNT" \
    --account-key "$storage_key" \
    --quota 5 \
    --output none

  log "Creating a scale-to-zero Container Apps environment"
  az containerapp env create \
    --name "$ENVIRONMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --location "$location" \
    --logs-destination none \
    --output none
  az containerapp env storage set \
    --name "$ENVIRONMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --storage-name "$SHAARLI_ENV_STORAGE" \
    --azure-file-account-name "$STORAGE_ACCOUNT" \
    --azure-file-account-key "$storage_key" \
    --azure-file-share-name "$SHAARLI_DATA_SHARE" \
    --access-mode ReadWrite \
    --output none
  environment_id="$(az containerapp env show \
    --name "$ENVIRONMENT_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query id \
    -o tsv)"

  local app_yaml
  app_yaml="$(mktemp "${TMPDIR:-/tmp}/shaarli-app.XXXXXX")"
  cat >"$app_yaml" <<EOF
properties:
  managedEnvironmentId: $environment_id
  configuration:
    activeRevisionsMode: Single
    ingress:
      external: false
      allowInsecure: false
      targetPort: 80
      transport: Auto
  template:
    containers:
      - name: shaarli
        image: $image
        resources:
          cpu: 0.25
          memory: 0.5Gi
        volumeMounts:
          - volumeName: shaarli-data
            mountPath: /var/www/shaarli/data
    scale:
      minReplicas: 0
      maxReplicas: 1
    volumes:
      - name: shaarli-data
        storageType: AzureFile
        storageName: $SHAARLI_ENV_STORAGE
EOF

  log "Creating the private Container App"
  if ! az containerapp create \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --environment "$ENVIRONMENT_NAME" \
    --yaml "$app_yaml" \
    --output none; then
    rm -f "$app_yaml"
    die "Container App creation failed; inspect $RESOURCE_GROUP, then run scripts/delete-shaarli.sh $instance_name --yes"
  fi
  rm -f "$app_yaml"

  log "Creating the Microsoft Entra authentication registration"
  AUTH_APP_ID="$(az ad app create \
    --display-name "Shaarli $instance_name ($APP_NAME)" \
    --sign-in-audience AzureADMyOrg \
    --enable-id-token-issuance true \
    --query appId \
    -o tsv)"
  az ad sp create --id "$AUTH_APP_ID" --output none
  az group update \
    --name "$RESOURCE_GROUP" \
    --set "tags.shaarliAuthAppId=$AUTH_APP_ID" \
    --output none

  client_secret="$(az ad app credential reset \
    --id "$AUTH_APP_ID" \
    --append \
    --display-name "Container Apps Easy Auth" \
    --years 2 \
    --query password \
    -o tsv)"
  tenant_id="$(az account show --query tenantId -o tsv)"

  log "Restricting the app to Microsoft Entra principal $principal_id"
  az containerapp auth microsoft update \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --client-id "$AUTH_APP_ID" \
    --client-secret "$client_secret" \
    --issuer "https://login.microsoftonline.com/$tenant_id/v2.0" \
    --yes \
    --output none
  unset client_secret

  az containerapp auth update \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --enabled true \
    --unauthenticated-client-action RedirectToLoginPage \
    --redirect-provider azureactivedirectory \
    --require-https true \
    --set \
      "identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities=[$principal_id]" \
    --yes \
    --output none

  local configured_principal_id
  configured_principal_id="$(az containerapp auth show \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query 'identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities[0]' \
    -o tsv)"
  [[ "$configured_principal_id" == "$principal_id" ]] ||
    die "Microsoft Entra principal allow-list verification failed; public ingress was not enabled"

  local active_revision
  active_revision="$(az containerapp revision list \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query '[?properties.active].name | [0]' \
    -o tsv)"
  [[ -n "$active_revision" ]] ||
    die "could not find the active Container App revision to apply authentication settings"
  log "Restarting the private revision to apply its authentication secret"
  az containerapp revision restart \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --revision "$active_revision" \
    --output none
}

publish_instance() {
  local instance_name="$1"

  log "Enabling public HTTPS ingress behind Microsoft Entra authentication"
  az containerapp ingress enable \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --type external \
    --target-port 80 \
    --transport auto \
    --allow-insecure false \
    --output none

  APP_URL="https://$(az containerapp show \
    --name "$APP_NAME" \
    --resource-group "$RESOURCE_GROUP" \
    --query properties.configuration.ingress.fqdn \
    -o tsv)"

  log "Registering the public authentication callback"
  az ad app update \
    --id "$AUTH_APP_ID" \
    --web-redirect-uris "$APP_URL/.auth/login/aad/callback" \
    --output none

  local status_code=""
  local _
  for _ in {1..30}; do
    status_code="$(curl --silent --show-error --output /dev/null \
      --write-out '%{http_code}' \
      --max-time 15 \
      "$APP_URL" || true)"
    if [[ "$status_code" == "302" || "$status_code" == "401" ]]; then
      break
    fi
    sleep 5
  done
  [[ "$status_code" == "302" || "$status_code" == "401" ]] ||
    die "instance was created but its authentication endpoint did not become ready (last HTTP status: ${status_code:-none})"

  printf '\nShaarli instance %q is ready:\n%s\n' "$instance_name" "$APP_URL"
  printf 'Sign in with the allowed Microsoft Entra account, then complete Shaarli setup.\n'
}
