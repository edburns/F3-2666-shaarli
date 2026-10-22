# Implementation plan: Eliminate PHP2Shell exposure from Shaarli (2026-10-22 incident)

Human DRI: Ed Burns<br>
Assessment: `security/2026-10-22-php2shell/assessment.md`<br>
Target resource group: `REDACTED_RESOURCE_GROUP`<br>
Target Container App: `REDACTED_APP`<br>
Target subscription: `REDACTED_ID` (`REDACTED_SUBSCRIPTION_NAME`)<br>
Relevant code: `scripts/lib-shaarli.sh`, `scripts/create-shaarli.sh`, `scripts/clone-shaarli.sh`

---

## Goal

Replace any potentially vulnerable Shaarli replica with an attested PHP 8.4.27
or newer image, then change this repository so deployments and upgrades use
immutable reviewed image digests and produce durable security evidence.

Success requires all of the following:

1. The active Azure revision references the reviewed v0.16.10 digest.
2. The running container reports PHP 8.4.27 or newer.
3. Entra Easy Auth remains enabled and restricted to the intended principal.
4. Shaarli data and core workflows survive the rollout.
5. Repository scripts can safely repeat this upgrade for future advisories.

---

## Completed phases

### Phase 0 ✅ — Identify the advisory and patched runtime

- PHP published CVE-2026-109618 and CVE-2026-109619 on 2026-10-21.
- Both are critical RCE vulnerabilities with affected PHP 8.4 versions below
  8.4.27.
- CVE-2026-109619 has a confirmed PHP-FPM exploitation path.
- Updating is the only complete mitigation.

### Phase 1 ✅ — Identify a patched Shaarli image

- Shaarli v0.16.10 was released with PHP 8.4.27.
- Reviewed multi-platform image:
  `ghcr.io/shaarli/shaarli:v0.16.10@sha256:48a1a8962c58c74c5c36d4927a7c2dcb5bf191a93b83dc480d9827f383ada903`.
- The upstream `release` tag is also patched, but remains unsuitable as a
  durable default because it is mutable.

### Phase 2 ✅ — Verify the unauthenticated boundary

- The public endpoint returned HTTP 401 on 2026-10-22 with an Entra
  authentication challenge.
- Repository code enables Easy Auth, requires HTTPS, and verifies a one-user
  allow-list before enabling public ingress.
- This reduces immediate public exploitability but does not prove the PHP
  runtime is patched.

---

## Phase 3 — Ignorance reduction: live questions to answer before declaring remediation complete

### 3.1 — Active Azure context and resource ownership

**Question:** Can the operator authenticate Azure CLI to tenant
`REDACTED_ID`, select subscription
`REDACTED_ID`, and read
`REDACTED_RESOURCE_GROUP/REDACTED_APP`?

The assessment session was authenticated to a different Microsoft tenant. No
live revision, runtime, or authentication configuration can be trusted until
the command context identifies the expected personal subscription.

**Spike needed:** Run the three Azure login/account commands in
`assessment.md`, then query the Container App and authentication configuration.

**Recommendation:** Stop remediation if any expected resource identifier differs
and reconcile the actual target before changing it.

**Resolution:**

### 3.2 — Pre-change active revision and configured image

**Question:** Which revision is active, what image reference is configured, and
when was the active revision created?

| Observation | Interpretation |
|-------------|----------------|
| Mutable `release` tag and a pre-2026-10-21 running replica | Treat as vulnerable. |
| Mutable `release` tag and a post-rebuild replica | Probably patched, but still replace with an immutable digest. |
| v0.16.10 digest and PHP 8.4.27 attestation | Already patched; continue with repository hardening. |
| Any PHP below 8.4.27 | Vulnerable; patch immediately. |

Azure's `always` pull policy means a recent replica start can retrieve patched
content without changing the configured tag. That behavior prevents the tag
alone from proving either vulnerable or patched state.

**Spike needed:** Capture `az containerapp show`, `az containerapp revision
list`, and, if a replica is available, `az containerapp exec --command 'php84
--version'`.

**Recommendation:** Preserve this output as the pre-change incident record.

**Resolution:**

### 3.3 — Easy Auth policy integrity

**Question:** Does the live authentication configuration still require
authentication and restrict access to exactly the intended Entra principal?

The HTTP 401 probe establishes that this request was rejected, but a complete
check must inspect `platform.enabled`,
`globalValidation.unauthenticatedClientAction`, and the allowed-principal list.

**Spike needed:** Compare `az containerapp auth show` with the principal stored
in the resource group's deployment metadata and with the intended operator.

**Recommendation:** Do not proceed with public application validation if Easy
Auth is disabled, anonymous access is allowed, or the allow-list is broader than
intended. Disable ingress until the policy is repaired.

**Resolution:**

### 3.4 — Immutable digest accepted by Azure Container Apps

**Question:** Will Azure Container Apps accept and successfully start
`ghcr.io/shaarli/shaarli:v0.16.10@sha256:48a1a8962c58c74c5c36d4927a7c2dcb5bf191a93b83dc480d9827f383ada903`
from GHCR in this environment?

The reference is a multi-platform OCI index digest. It is preferable to an
architecture-specific manifest because it remains portable, but the actual
deployment must prove registry access and platform resolution.

**Spike needed:** Apply the digest with `az containerapp update`, wait for the
latest ready revision to equal the latest revision, and inspect system logs if
the revision fails.

**Recommendation:** Use the multi-platform digest. If Azure rejects it, pin the
verified linux/amd64 manifest digest
`sha256:c85599ef5839fa59da63f8f3acc6f3041e57f107c718c91e1cb652a0f31ffe90`
and record why.

**Resolution:**

### 3.5 — Runtime attestation method

**Question:** What evidence will prove that the active web-serving replica, not
merely an upstream image tag, runs PHP 8.4.27 or newer?

| Option | Evidence quality | Trade-off |
|--------|------------------|-----------|
| `az containerapp exec ... php84 --version` | Direct runtime evidence | Requires a running replica and exec access. |
| Inspect the configured immutable digest | Strong supply-chain evidence | Does not directly observe the running process. |
| Application response headers | Weak | Shaarli/nginx need not disclose PHP version. |

**Spike needed:** Wake the new revision through an authenticated browser session
and run the exec command. Capture the first PHP version line and active revision
name together.

**Recommendation:** Require both the immutable configured digest and direct
runtime output.

**Resolution:**

### 3.6 — Functional and persistence regression check

**Question:** Does the patched revision preserve the mounted Azure Files data
and the single-user Shaarli workflows?

The image update must not overwrite or detach `/var/www/shaarli/data`.
Authentication success alone does not exercise link reads or writes.

**Spike needed:** Verify login, existing link count or a known private link,
creation and deletion of a temporary private note, and a cold start after
scaling back to zero.

**Recommendation:** Use a temporary private note with a unique timestamp so the
write can be verified and cleanly removed.

**Resolution:**

### 3.7 — Emergency rollback boundary

**Question:** What is the safe response if the patched revision fails health or
functional checks?

Rolling back to the prior revision could restore a vulnerable runtime. Leaving
the failed patched revision public could also produce an availability incident.

**Recommendation:** Prefer temporary ingress disablement while diagnosing. Do
not route traffic back to a revision that has not been attested as PHP 8.4.27 or
newer. If rollback is unavoidable for data recovery, restrict access before
activation and keep it offline afterward.

**Resolution:**

### 3.8 — Default pinning and future update policy

**Question:** Should repository defaults pin only a Shaarli version, or both a
version and OCI digest?

| Option | Reproducibility | Security update behavior |
|--------|-----------------|--------------------------|
| `release` | Low | Silently changes on pull; no reviewed promotion. |
| `v0.16.10` | Medium | Tag can still be rebuilt or moved. |
| `v0.16.10@sha256:...` | High | Requires deliberate digest updates. |

The incident demonstrates that an old Container App revision and a newly rebuilt
tag can have the same configured image string while containing different PHP
packages.

**Recommendation:** Pin version plus digest and make updates explicit,
reviewable repository changes.

**Resolution:**

---

## Phase 4 — Implementation

### 4.1 — Capture the live pre-change incident record

**What:** Authenticate to the correct Azure subscription and save the configured
image, revisions, scale settings, auth policy, and runtime PHP version.

**Files to create:**
- `security/2026-10-22-php2shell/live-pre-change-attestation.txt`

**Tests:** Confirm the resource group, app name, tenant, subscription, and URL
all match this plan.

**Gating criteria:** The target is unambiguous and the current PHP state is
classified as vulnerable, patched, or unknown with evidence.

### 4.2 — Deploy the patched immutable image

**What:** Update the Container App to the reviewed v0.16.10 OCI digest without
changing ingress, storage, scale, CPU, memory, or authentication settings.

**Files to modify:** None during the live operation.

**Tests:** Wait for a healthy latest revision; confirm the configured image is
the expected digest.

**Gating criteria:** The latest revision is ready and active. No traffic is sent
to an unattested prior revision.

### 4.3 — Attest runtime and application behavior

**What:** Verify PHP, Easy Auth, persistent data, write behavior, and cold-start
behavior.

**Files to create:**
- `security/2026-10-22-php2shell/live-post-change-attestation.txt`

**Tests:**
- `php84 --version` reports 8.4.27 or newer.
- Unauthenticated request returns 401 or redirects to the configured provider.
- Authenticated Shaarli login succeeds.
- Existing persistent data is present.
- A temporary private note can be created and deleted.
- The app remains healthy after returning to `minReplicas: 0`.

**Gating criteria:** All tests pass and the attestation records the active
revision and immutable digest.

### 4.4 — Pin the repository default image

**What:** Replace `SHAARLI_DEFAULT_IMAGE` with the reviewed version-plus-digest
reference and document how to update it.

**Files to modify:**
- `scripts/lib-shaarli.sh`
- `README.md`

**Tests:**
- Shell syntax checks for all scripts.
- Existing image validation accepts version-plus-digest references.
- A dry review of create and clone paths confirms they preserve the digest.

**Gating criteria:** No default deployment path uses `release`, `latest`, or an
unpinned version tag.

### 4.5 — Add an in-place upgrade script

**What:** Create a script that loads an instance, requires an explicit image
digest, captures pre-change state, updates only the image, waits for a healthy
revision, verifies Easy Auth, and prints the runtime attestation command.

**Files to create:**
- `scripts/update-shaarli-image.sh`

**Files to modify:**
- `README.md`

**Tests:**
- Invalid instance and image inputs fail before Azure mutation.
- A tag without a digest is rejected unless an explicit emergency override is
  designed and approved.
- Azure update failures return nonzero and identify the failed revision.
- Successful rollout preserves the configured volume mount and scale settings.

**Gating criteria:** A future image-only security update is one documented,
repeatable command with explicit failure behavior.

### 4.6 — Add a security attestation command

**What:** Add read-only reporting for Azure account context, configured image,
revision health, Easy Auth policy, allowed principals, and runtime PHP version.

**Files to create:**
- `scripts/attest-shaarli-security.sh`

**Files to modify:**
- `README.md`

**Tests:** Exercise scaled-to-zero and running-replica cases. A missing replica
must report runtime attestation as unavailable, not as success.

**Gating criteria:** The command cannot produce a success result without both a
pinned digest and PHP 8.4.27-or-newer runtime evidence.

### 4.7 — Document emergency containment and advisory response

**What:** Document how to disable external ingress or deactivate a revision,
deploy a fixed digest, verify PHP, restore service, and update the repository
pin.

**Files to modify:**
- `README.md`
- `security/2026-10-22-php2shell/assessment.md`

**Tests:** Have an operator follow the commands from a clean shell after
selecting the correct subscription.

**Gating criteria:** The runbook contains no dependency on mutable tags and no
step suggests incomplete PHP configuration mitigations are sufficient.

---

## Phase 5 — Reference material

- `security/2026-10-22-php2shell/assessment.md`
- <https://www.php.net/?=PHPE9568F35-D428-11d2-A769-00AA001ACF42>
- <https://github.com/php/php-src/security/advisories/GHSA-w8hw-w9fx-j79w>
- <https://github.com/php/php-src/security/advisories/GHSA-6wmf-4rv5-p3rp>
- <https://github.com/shaarli/Shaarli/issues/2297>
- <https://github.com/shaarli/Shaarli/releases/tag/v0.16.10>
- <https://learn.microsoft.com/azure/container-apps/authentication>
- <https://learn.microsoft.com/azure/container-apps/revisions-manage>
- <https://learn.microsoft.com/azure/container-apps/managed-identity-image-pull>
