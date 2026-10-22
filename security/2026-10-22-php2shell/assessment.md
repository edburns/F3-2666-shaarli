# PHP2Shell exposure assessment for Shaarli

Assessment date: 2026-10-22  
Target: `REDACTED_HOST.azurecontainerapps.io`  
Azure resource group: `REDACTED_RESOURCE_GROUP`  
Azure Container App: `REDACTED_APP`

## Executive conclusion

The deployed Shaarli instance was mitigated on 2026-10-22. Its active revision
is pinned to Shaarli v0.16.10 and runs PHP 8.4.27. Easy Auth remains enabled,
the persistent Azure Files mount is unchanged, Shaarli responds internally, and
a point-in-time data snapshot matches the live share byte for byte.

The repository deploys the mutable image
`ghcr.io/shaarli/shaarli:release`. The instance was created before the
2026-10-21 PHP security release, so its original replica could contain a PHP
version affected by CVE-2026-109618 and CVE-2026-109619. Both vulnerabilities
are critical, network-reachable remote-code-execution flaws fixed in PHP 8.4.27.
CVE-2026-109619 has a confirmed PHP-FPM exploitation path, which matches the
official Shaarli container architecture.

There are two important qualifications:

1. Microsoft Entra Easy Auth is configured in front of Shaarli, and an
   unauthenticated probe on 2026-10-22 returned HTTP 401. Azure documents that
   application code receives a request only after the authentication sidecar.
   This substantially reduces exposure to arbitrary Internet attackers.
2. Shaarli v0.16.10 and the rebuilt upstream `release` image contain PHP
   8.4.27. Azure Container Apps uses an `always` image-pull policy, so a replica
   started after the upstream rebuild may already be patched. This is not proof
   that the active revision is patched, because the repository records only a
   mutable tag and no deployed digest or runtime PHP version.

The live evidence is recorded in
`security/2026-10-22-php2shell/live-post-change-attestation.md`.

## Vulnerability

| Identifier | PHP description | Severity | Relevant fixed PHP |
|------------|-----------------|----------|--------------------|
| CVE-2026-109618 | RCE through out-of-memory corruption during request handling | Critical, CVSS 9.2 | 8.4.27 |
| CVE-2026-109619 | RCE through stale request-owned global state used by a later request | Critical, CVSS 9.2 | 8.4.27 |

PHP states that all installations serving web requests, including PHP-FPM, are
at risk. Updating is the only complete mitigation. CVE-2026-109619's session
lifecycle path was validated against PHP-FPM; requests must reach the same
persistent worker, but multiple workers and worker recycling only reduce
reliability.

## Repository and deployment evidence

| Evidence | Implication |
|----------|-------------|
| `scripts/lib-shaarli.sh:7` defines `ghcr.io/shaarli/shaarli:release`. | New instances use a mutable tag rather than a reviewed digest. |
| `scripts/lib-shaarli.sh:283-300` places that image in a PHP-backed Shaarli container and mounts persistent data at `/var/www/shaarli/data`. | Successful container RCE would run with the web worker's privileges and could reach persistent Shaarli configuration, credentials, links, and plugins. |
| `scripts/lib-shaarli.sh:351-381` enables Entra authentication and limits access to one principal before ingress is published. | Unauthenticated Internet traffic should be rejected by the platform before reaching PHP. |
| `scripts/lib-shaarli.sh:399-410` enables HTTPS-only external ingress after the allow-list check. | The application is Internet-addressable but fronted by Easy Auth. |
| `scripts/lib-shaarli.sh:293-295` configures `minReplicas: 0` and `maxReplicas: 1`. | A post-rebuild cold start should pull the new `release` image, but there is no durable evidence of which digest a prior running replica used. One worker also makes same-worker exploit sequencing more plausible after authentication. |
| The live endpoint returned HTTP 401 with an Entra `WWW-Authenticate` challenge on 2026-10-22. | Easy Auth is currently rejecting this unauthenticated probe. |
| Shaarli upstream issue `shaarli/Shaarli#2297` records that v0.16.10, `v0.16`, and `release` were rebuilt with PHP 8.4.27 on 2026-10-21. | A patched upstream image is available now. |

## Current uncertainty

The Azure CLI session used for this assessment is signed into tenant
`REDACTED_ID`, while the Shaarli resource and its
Easy Auth registration are in tenant `REDACTED_ID`
and subscription `REDACTED_ID` (`REDACTED_SUBSCRIPTION_NAME`). The current session therefore cannot inspect the active revision.

Do not interpret the endpoint's HTTP 401 as proof that PHP is patched. It proves
only that unauthenticated traffic is presently blocked at the platform auth
layer.

## Immediate remediation runbook

The currently verified multi-platform v0.16.10 image index is:

```text
ghcr.io/shaarli/shaarli:v0.16.10@sha256:48a1a8962c58c74c5c36d4927a7c2dcb5bf191a93b83dc480d9827f383ada903
```

Authenticate to the correct Azure tenant and select the known subscription:

```bash
az login --tenant REDACTED_ID
az account set --subscription REDACTED_ID
az account show --query '{name:name,id:id,tenantId:tenantId}' -o json
```

Capture the pre-change state:

```bash
RG=REDACTED_RESOURCE_GROUP
APP=REDACTED_APP

az containerapp show \
  --resource-group "$RG" \
  --name "$APP" \
  --query '{image:properties.template.containers[0].image,latestRevision:properties.latestRevisionName,latestReadyRevision:properties.latestReadyRevisionName,minReplicas:properties.template.scale.minReplicas,maxReplicas:properties.template.scale.maxReplicas}' \
  -o json

az containerapp auth show \
  --resource-group "$RG" \
  --name "$APP" \
  --query '{enabled:platform.enabled,unauthenticatedAction:globalValidation.unauthenticatedClientAction,allowedPrincipals:identityProviders.azureActiveDirectory.validation.defaultAuthorizationPolicy.allowedPrincipals.identities}' \
  -o json
```

Roll out the immutable patched image:

```bash
PATCHED_IMAGE='ghcr.io/shaarli/shaarli:v0.16.10@sha256:48a1a8962c58c74c5c36d4927a7c2dcb5bf191a93b83dc480d9827f383ada903'

az containerapp update \
  --resource-group "$RG" \
  --name "$APP" \
  --image "$PATCHED_IMAGE" \
  --output none
```

Verify the new revision and security boundary:

```bash
az containerapp show \
  --resource-group "$RG" \
  --name "$APP" \
  --query '{image:properties.template.containers[0].image,latestRevision:properties.latestRevisionName,latestReadyRevision:properties.latestReadyRevisionName,runningStatus:properties.runningStatus}' \
  -o json

az containerapp revision list \
  --resource-group "$RG" \
  --name "$APP" \
  --query '[].{name:name,active:properties.active,healthy:properties.healthState,running:properties.runningState,created:properties.createdTime,image:properties.template.containers[0].image}' \
  -o table

curl -sS -D - -o /dev/null --max-time 30 \
  'https://REDACTED_HOST.azurecontainerapps.io/' |
  sed -n '1,20p'
```

After signing in through a browser to wake the patched replica, attest the
runtime:

```bash
az containerapp exec \
  --resource-group "$RG" \
  --name "$APP" \
  --command 'php84 --version'
```

The first line must report PHP 8.4.27 or newer. Also verify in the browser that
Shaarli login, link listing, adding a private note, and persistent data all work.

If the patched image cannot be deployed immediately, disable external ingress
or deactivate the active revision from the correct subscription. PHP's
configuration workarounds are incomplete and must not be treated as a final
fix.

## Required durable repository changes

1. Replace the default mutable `release` tag with a reviewed version and digest.
2. Add an in-place upgrade script that captures state, deploys a supplied
   digest, waits for a healthy revision, verifies Easy Auth, and prints runtime
   attestation commands.
3. Add a status/attestation command that records the configured image,
   revision, authentication policy, and runtime PHP version.
4. Update the README with the upgrade and emergency-disable procedures.
5. Establish a repeatable process for monitoring Shaarli/PHP advisories and
   updating the pinned digest.

## Primary references

- PHP security notice: <https://www.php.net/?=PHPE9568F35-D428-11d2-A769-00AA001ACF42>
- CVE-2026-109618 advisory: <https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w>
- CVE-2026-109619 advisory: <https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp>
- Shaarli remediation issue: <https://github.com/shaarli/Shaarli/issues/2297>
- Shaarli v0.16.10: <https://github.com/shaarli/Shaarli/releases/tag/v0.16.10>
- Azure Container Apps authentication: <https://learn.microsoft.com/azure/container-apps/authentication>
- Azure Container Apps revision management: <https://learn.microsoft.com/azure/container-apps/revisions-manage>
- Azure Container Apps image pull behavior: <https://learn.microsoft.com/azure/container-apps/managed-identity-image-pull>
