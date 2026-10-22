# Shaarli on Azure Container Apps

These scripts manage isolated, single-user [Shaarli](https://github.com/shaarli/Shaarli)
instances in the current Azure CLI subscription. Each instance includes:

- an Azure Container App using a reviewed Shaarli version pinned by immutable
  OCI digest, 0.25 vCPU, 0.5 GiB memory, one replica maximum, and scale-to-zero;
- an opaque `azurecontainerapps.io` HTTPS hostname, so custom DNS and a separate
  gateway are unnecessary;
- Container Apps built-in Microsoft Entra authentication, restricted to one
  user object ID before public ingress is enabled;
- a 5 GiB locally redundant Azure Files share mounted at
  `/var/www/shaarli/data`; and
- a dedicated resource group and Entra app registration for clean deletion.

The Shaarli cache remains ephemeral by design. Persistent configuration,
credentials, links, and plugins live in the data share.

## Prerequisites

- Bash, `curl`, and Azure CLI with the `containerapp` command available.
- An enabled Azure subscription selected by `az account set`.
- Permission to create resource groups, Container Apps, storage accounts, and
  app registrations in the subscription's Microsoft Entra tenant.

The scripts use the signed-in Azure CLI user's Entra object ID by default. Pass
`--principal-id OBJECT_ID` to grant a different user access.

### Private environment for the Instapaper importer

The Azure management scripts discover their configuration through Azure CLI;
they do not need hardcoded personal account values or an environment file.
For `scripts/instapaper_import.py`, create your own ignored configuration file:

```bash
cp .env.example .env.local
chmod 600 .env.local
# Edit .env.local with your own Instapaper username and consumer credentials.
source .env.local
python3 scripts/instapaper_import.py /path/to/private-bookmarks.html
```

The file must be authored and explicitly sourced before running the importer;
it is not loaded automatically. Empty or redacted values fail before a network
request. Existing command-line credential options override the environment.
The password is prompted securely and is not stored in this file.

Keep bookmark exports and operational transcripts private. Even with HTTP
credential/body logging suppressed, import progress includes bookmark URLs and
tags. Never commit raw logs, exported bookmarks, or `.env.local`. Redacting Git
history does not revoke previously exposed credentials: rotate the Instapaper
password and consumer credentials, and revoke exposed OAuth access tokens
before publishing. Remote caches and other clones require separate cleanup.

The raw files under `prompts/` have been replaced with redaction notices
throughout Git history. Deployment identifiers in the incident records are
also redacted. This changes historical commit IDs: use the rewritten history,
and do not merge old clones or branches back into it.

## Create an instance

```bash
./scripts/create-shaarli.sh personal
```

The command prints the instance URL after unauthenticated access has been
verified to redirect to Microsoft sign-in. Sign in, then complete Shaarli's
one-time setup. The setup page is never exposed without Entra authentication.

Use another Azure region or a different reviewed immutable image when needed:

```bash
./scripts/create-shaarli.sh personal \
  --location westus2 \
  --image ghcr.io/shaarli/shaarli:v0.16.10@sha256:48a1a8962c58c74c5c36d4927a7c2dcb5bf191a93b83dc480d9827f383ada903
```

Mutable tags such as `release`, `latest`, and bare version tags are rejected.
Update the reviewed version and digest together when promoting a new image.

## Clone an instance

```bash
./scripts/clone-shaarli.sh personal personal-copy
```

Cloning creates fully independent infrastructure and copies a point-in-time
Azure Files snapshot. The source stays online. Its Shaarli login, links,
configuration, and plugins are copied; the clone gets a new opaque URL and a
new Entra app registration. By default it uses the source image and region. A
source created with an older mutable image tag must be upgraded before cloning.

The transfer passes through a temporary local directory, so the machine running
the script needs enough free disk space for the source data.

## Delete an instance

```bash
./scripts/delete-shaarli.sh personal
```

Deletion requires typing the instance name. For automation:

```bash
./scripts/delete-shaarli.sh personal --yes
```

This permanently removes the resource group, storage data and snapshots, and
the Entra app registration.

## Upgrade and security attestation

Roll an existing instance to the repository's reviewed image:

```bash
./scripts/update-shaarli-image.sh personal
```

The update script requires an immutable digest, verifies that Easy Auth is
enabled with one allowed principal, takes a point-in-time snapshot of the
persistent Azure Files share, changes only the container image, waits for the
new revision, and confirms anonymous traffic is still rejected.

After the rollout, sign in through the browser once so a scaled-to-zero
application replica is running, then attest the live PHP runtime:

```bash
./scripts/attest-shaarli-security.sh personal --runtime
```

The command succeeds only when the configured image is pinned, Easy Auth blocks
anonymous traffic, exactly one principal is allowed, and the running PHP version
contains the fixes for CVE-2026-109618 and CVE-2026-109619.

For the 2026-10-21 PHP2Shell incident, see
`security/2026-10-22-php2shell/assessment.md`.

If a critical runtime fix is unavailable, contain the instance rather than
depending on incomplete PHP configuration workarounds:

```bash
INSTANCE=example # Set this to your instance name.
RG="rg-shaarli-$INSTANCE"
APP=$(az group show --name "$RG" --query tags.shaarliAppName -o tsv)
az containerapp ingress disable \
  --name "$APP" \
  --resource-group "$RG"
```

## Naming, cost, and maintenance

An instance named `example` is managed as resource group
`rg-shaarli-example`; the public app hostname contains a random 88-bit suffix.
Instance names must be 1-30 lowercase letters, numbers, or hyphens.

The Consumption plan's scale-to-zero behavior and smallest supported resource
allocation keep this suitable for light personal use. Azure Files and other
Azure charges still apply, and these scripts do not create or enforce a budget.
Review actual subscription costs independently.

The generated Entra client secret expires after two years. Before then, replace
the app registration credential and update the Container App's Microsoft
identity provider secret. Running create or clone again is intentionally not
an in-place upgrade operation.

Work item: REDACTED (private tracking reference).
