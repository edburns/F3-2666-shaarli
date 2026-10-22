# Live post-change attestation

Attestation date: 2026-10-22  
Instance: `REDACTED`  
Resource group: `REDACTED_RESOURCE_GROUP`  
Container App: `REDACTED_APP`

## Mitigation state

- Active and latest-ready revision:
  `REDACTED_APP`
- Revision health: `Healthy`
- Image:
  `ghcr.io/shaarli/shaarli:v0.16.10@sha256:48a1a8962c58c74c5c36d4927a7c2dcb5bf191a93b83dc480d9827f383ada903`
- Runtime: PHP 8.4.27, built 2026-10-21
- Unauthenticated public request: HTTP 401
- Easy Auth: enabled
- Unauthenticated action: `RedirectToLoginPage`
- Allowed-principal count: 1
- Internal Shaarli web probe: successful

## Persistent data protection

- Storage account: `REDACTED_STORAGE_ACCOUNT`
- Azure Files share: `shaarli-data`
- Mount path before mitigation: `/var/www/shaarli/data`
- Mount path after mitigation: `/var/www/shaarli/data`
- Storage mapping before and after:
  `shaarli-data` Azure File volume backed by the `shaarli-data` environment
  storage
- Point-in-time safety snapshot:
  `2026-10-22T18:34:01.0000000Z`
- Live file count after mitigation: 7
- Snapshot file count: 7
- Live byte count after mitigation: 1,677,883
- Snapshot byte count: 1,677,883
- Byte-for-byte SHA-256 inventory comparison: identical
- Persistent files modified at or after rollout: only
  `lastupdatecheck.txt` (7 bytes), Shaarli's update-check timestamp
- User data files modified at or after rollout: 0

The image-only revision changed neither the volume definition nor the mount
path. The active share and the safety snapshot were downloaded independently
and every file matched by relative path, size, and SHA-256 digest, including
after the read-only render test. Azure Files metadata shows that the rollout
did not modify any user data file. The patched container also served Shaarli
successfully through its internal HTTP port.

No write/delete functional test was performed against user data. Validation was
intentionally read-only to avoid creating or modifying Shaarli records.

## Recovery point

If a later validation uncovers an application-level problem, preserve the
current share and restore from the snapshot above into a separate recovery
share or clone. Do not overwrite the live share before comparing both copies.
