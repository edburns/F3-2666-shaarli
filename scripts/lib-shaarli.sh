#!/usr/bin/env bash

set -Eeuo pipefail

# These constants are consumed by scripts that source this library.
# shellcheck disable=SC2034
readonly SHAARLI_DEFAULT_IMAGE="ghcr.io/shaarli/shaarli:release"
# shellcheck disable=SC2034
readonly SHAARLI_DEFAULT_LOCATION="eastus"
readonly SHAARLI_DATA_SHARE="shaarli-data"
readonly SHAARLI_ENV_STORAGE="shaarli-data"
readonly SHAARLI_SCHEMA_VERSION="2"

# Container Apps bills allocated resources by the second while a replica is
# running. With minReplicas 0 an idle instance costs nothing regardless of these
# values, so allocating more only costs during the seconds a request is actually
# being served -- and more CPU shortens the cold start that dominates those
# seconds. Must be one of the CPU/memory pairs Container Apps accepts:
# 0.25/0.5Gi, 0.5/1.0Gi, 0.75/1.5Gi, 1.0/2.0Gi, and so on.
readonly SHAARLI_DEFAULT_CPU="0.5"
readonly SHAARLI_DEFAULT_MEMORY="1.0Gi"

# Thumbnail generation fetches and resizes a remote image per bookmark, lazily
# on first display. On a small container with a large collection that is the
# most expensive thing Shaarli can be asked to do, and the resulting cache lives
# in the container's ephemeral filesystem, so it is discarded on every
# scale-to-zero cycle. Seed it off; "common" (known media sites only) or "all"
# can be set later from Tools -> Configure.
readonly SHAARLI_THUMBNAIL_MODE="none"

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

# Compute the public HTTPS URL an app will have once external ingress is
# enabled. The Container Apps environment's default domain is stable and known
# as soon as the environment exists, so this can be resolved before the app is
# created -- and, critically, before ingress is flipped from internal to
# external. Deriving it from properties.configuration.ingress.fqdn at create
# time would yield the *.internal.* hostname instead.
shaarli_root_url_for() {
  local app_name="$1"
  local environment_name="$2"
  local resource_group="$3"
  local default_domain

  default_domain="$(az containerapp env show \
    --name "$environment_name" \
    --resource-group "$resource_group" \
    --query properties.defaultDomain \
    -o tsv)"
  [[ -n "$default_domain" ]] ||
    die "could not determine the Container Apps environment default domain"

  printf 'https://%s.%s/\n' "$app_name" "$default_domain"
}

# Shaarli derives its own base URL from $_SERVER at request time. Behind the
# Container Apps ingress and Easy Auth sidecar that discovery fails, producing
# an empty host and breaking every generated absolute URL (bookmarklets, feed
# links, permalinks, QR codes). general.root_url overrides the discovery.
#
# The data share mounts at /var/www/shaarli/data, so writing config.json.php to
# the share root pre-seeds the config before the container's first boot. The
# install wizard still runs -- it triggers on a missing credentials.login, not a
# missing file -- and merges its output into whatever is already there.
#
# Any other setting that should differ from Shaarli's defaults on a fresh
# instance belongs here too, so a new instance boots correct rather than needing
# a manual visit to the settings page.
seed_shaarli_config() {
  local storage_account="$1"
  local storage_key="$2"
  local root_url="$3"
  local thumbnail_mode="$4"
  local seed_file

  seed_file="$(mktemp "${TMPDIR:-/tmp}/shaarli-config.XXXXXX")"
  cat >"$seed_file" <<EOF
<?php /*
{
    "general": {
        "root_url": "$root_url"
    },
    "thumbnails": {
        "mode": "$thumbnail_mode"
    }
}
*/ ?>
EOF

  az storage file upload \
    --account-name "$storage_account" \
    --account-key "$storage_key" \
    --share-name "$SHAARLI_DATA_SHARE" \
    --source "$seed_file" \
    --path config.json.php \
    --output none
  rm -f "$seed_file"
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

  SHAARLI_ROOT_URL="$(shaarli_root_url_for \
    "$APP_NAME" "$ENVIRONMENT_NAME" "$RESOURCE_GROUP")"
  log "Seeding Shaarli configuration with root_url $SHAARLI_ROOT_URL"
  seed_shaarli_config \
    "$STORAGE_ACCOUNT" "$storage_key" "$SHAARLI_ROOT_URL" "$SHAARLI_THUMBNAIL_MODE"

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
          cpu: $SHAARLI_DEFAULT_CPU
          memory: $SHAARLI_DEFAULT_MEMORY
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

  # Easy Auth stops working when this secret expires, with a failure that does
  # not obviously point at a credential. Record the date so it is queryable
  # across instances and rotate-auth-secret.sh has a baseline to report against.
  local secret_expiry
  secret_expiry="$(az ad app credential list \
    --id "$AUTH_APP_ID" \
    --query 'max_by(@, &endDateTime).endDateTime' \
    -o tsv 2>/dev/null | cut -c1-10 || true)"
  if [[ -n "$secret_expiry" ]]; then
    az group update \
      --name "$RESOURCE_GROUP" \
      --set "tags.shaarliAuthSecretExpiry=$secret_expiry" \
      --output none
  fi

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

  # The seeded root_url was predicted from the environment's default domain.
  # If the assigned FQDN differs, every absolute URL Shaarli generates will be
  # wrong, so fail loudly rather than shipping a subtly broken instance.
  if [[ -n "${SHAARLI_ROOT_URL:-}" && "$SHAARLI_ROOT_URL" != "$APP_URL/" ]]; then
    die "seeded root_url ($SHAARLI_ROOT_URL) does not match the assigned ingress FQDN ($APP_URL/); run scripts/set-root-url.sh $instance_name to repair"
  fi

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
