# Shaarli on Azure Container Apps

These scripts manage isolated, single-user [Shaarli](https://github.com/shaarli/Shaarli)
instances in the current Azure CLI subscription. Each instance includes:

- an Azure Container App using the official `ghcr.io/shaarli/shaarli:release`
  image, 0.25 vCPU, 0.5 GiB memory, one replica maximum, and scale-to-zero;
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

## Create an instance

```bash
./scripts/create-shaarli.sh personal
```

The command prints the instance URL after unauthenticated access has been
verified to redirect to Microsoft sign-in. Sign in, then complete Shaarli's
one-time setup. The setup page is never exposed without Entra authentication.

Use another Azure region or pin a specific Shaarli release when needed:

```bash
./scripts/create-shaarli.sh personal \
  --location westus2 \
  --image ghcr.io/shaarli/shaarli:v0.15.0
```

## Clone an instance

```bash
./scripts/clone-shaarli.sh personal personal-copy
```

Cloning creates fully independent infrastructure and copies a point-in-time
Azure Files snapshot. The source stays online. Its Shaarli login, links,
configuration, and plugins are copied; the clone gets a new opaque URL and a
new Entra app registration. By default it uses the source image and region.

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

## Naming, cost, and maintenance

An instance named `personal` is managed as resource group
`REDACTED_RESOURCE_GROUP`; the public app hostname contains a random 88-bit suffix.
Instance names must be 1-30 lowercase letters, numbers, or hyphens.

The Consumption plan's scale-to-zero behavior and smallest supported resource
allocation keep this suitable for light personal use. Azure Files and other
Azure charges still apply, and these scripts do not create or enforce a budget.
Review actual subscription costs independently.

The generated Entra client secret expires after two years. Before then, replace
the app registration credential and update the Container App's Microsoft
identity provider secret. Running create or clone again is intentionally not
an in-place upgrade operation.

Work item: <REDACTED_PRIVATE_WORK_ITEM>
