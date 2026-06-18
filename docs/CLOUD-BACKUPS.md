# Cloud backups — generator (GitOps) leg

This document covers the **generator** half of the per-domain + total-cloud cloud
backups feature: installing Velero, provisioning the backup destination
(`BackupStorageLocation`) + ESO/Vault credentials + least-privilege RBAC, and the
status-sweep. The catalog, role gates, versioning, restore step-up, and the
per-service menu live in the **admin-bff** (`cloudbackup` package: foundation
PR #74 + the Velero effector PR #76); the UI lives in `snapdragon-admin-ui`.

The whole feature **ships dark** — installing Velero must NOT silently start real
backups. Two independent gates keep it inert until a superadmin opts in.

## What this leg adds

| File | Role |
|---|---|
| `specs/cluster/apps/55-velero.yaml` | Velero server + node-agent + CRDs (Helm chart `12.0.3` / Velero `1.18.1` / `velero-plugin-for-aws v1.14.1`). **Manual sync.** |
| `specs/cluster/apps/56-velero-config.yaml` | Applies `manifests/velero` (BSL + RBAC + sweep). **Manual sync, wave 2** (after the CRDs). |
| `specs/cluster/manifests/velero/backupstoragelocation.yaml` | The `default` BSL + VolumeSnapshotLocation + a per-brand BSL template. |
| `specs/cluster/manifests/velero/rbac.yaml` | Least-privilege Role/RoleBinding for the effector SA + the sweep SA. |
| `specs/cluster/manifests/velero/sweep-cronjob.yaml` | The CR-read half of the status sweep (`suspend: true`). |
| `specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml` | The object-store credentials, materialized by ESO from Vault — never inline. |
| `specs/cluster/manifests/admin-bff-api/backups-effector-sa.yaml` | The `backups-effector` SA the admin-bff pod runs as. |
| `specs/cluster/manifests/admin-bff-api/deployment.yaml` | Wires `serviceAccountName: backups-effector` + the `BACKUPS_*` env (flag **off** by default). |

## How the BSL name matches the effector

The effector (`cloudbackup/VeleroResourceFactory.storageLocationRef`) sets the
Velero CR `spec.storageLocation` to the backup_set row's `destination_ref`, with a
**fallback to the literal string `default`** when it is blank:

```java
return (ref == null || ref.isBlank()) ? "default" : ref.trim();
```

So the effector never hardcodes a BSL name — it uses the catalog row, falling back
to `default`. Therefore:

- The **`default` BSL is required** — it is both the TOTAL/superadmin destination
  and the fallback any DOMAIN backup with a blank `destination_ref` resolves to.
- A brand that sets `backup_destination.destination_ref = "<name>"` **must** have a
  BSL named exactly `<name>` (the per-brand template in
  `backupstoragelocation.yaml`). If no such BSL exists, that brand's Velero Backup
  CR fails to reconcile (`backup storage location not found`) and the sweep marks
  the row `failed`. The fix is provisioning the BSL — never a code change.

Keep brands on `default` unless a dedicated per-brand bucket is wanted, and
provision the per-brand BSL in the same change that sets `destination_ref`.

## Credentials never touch git

`velero-cloud-credentials` (key `cloud`, an AWS/S3 INI file) is **templated by ESO
from Vault** `secret/<brand>/velero` (`access_key_id` + `secret_access_key`). The
Velero server (`credentials.existingSecret`) and every BSL (`spec.credential`)
reference it by name. No object-store key/secret bytes appear anywhere in the git
tree. The bucket/endpoint coordinates in the BSL are non-secret and
generator-templated.

## RBAC scope (not cluster-admin)

- `backups-effector` (SA in `snapdragon-backend`, the admin-bff's identity):
  `create/get/list/patch` on `velero.io` `backups` + `restores` in the **`velero`
  namespace only**. No pods, secrets, exec, or cluster scope.
- `backups-sweep` (SA in `velero`): `get/list/watch/patch` on the same CRs, to
  mirror `.status.phase`. Cannot create or delete CRs.

Velero's own server SA (chart-created `velero`) is separate and unchanged.

## Status sweep — split design (read here, write in admin-bff)

The catalog status (`backup_set.status`) is written by the admin-bff
`BackupSetRepository.markStatus(id, …)` keyed on the **raw** set id, via the
least-privilege `adminbff_app` Postgres role. A generator CronJob cannot correctly
write it: it would (a) duplicate the BFF's sole-writer authority and need its own
DB credential, and (b) the CR label `snapdragon.systems/backup-set-id` is a *lossy*
slug of the raw id. So the sweep is **split**:

- **Generator CronJob (`sweep-cronjob.yaml`)** — the CR-read half: finds Velero
  CRs labelled `app.kubernetes.io/managed-by=snapdragon-admin-bff` that reached a
  terminal `.status.phase` and mirrors it onto the CR as the annotation
  `snapdragon.systems/catalog-status=complete|failed`.
- **Admin-bff reconciler (FOLLOW-ON, not built here)** — the catalog-write half: a
  scheduled reactive reconciler (or a `/bff/superadmin/backups/sweep` endpoint the
  CronJob POSTs to) that lists CRs carrying that annotation, maps the
  `snapdragon.systems/backup-set-key` + version label back to the raw `backup_set`
  id, and calls `markStatus(id, complete|failed)`.

This is the faithful realization of the effector's "a future watch/sweep flips it
terminal" note without shipping a half-version that bypasses the BFF's DB model.

> **Follow-on owed to admin-bff:** the catalog-write reconciler above. Until it
> ships, sets correctly reach `running` (the effector) and the CR reaches a
> terminal phase + carries the mirrored annotation (this sweep), but the catalog
> row stays `running` until an operator reconciles it. The backup/restore itself
> completes regardless — only the catalog *display* lags.

## Turning backups ON (superadmin opt-in)

Installing Velero does not enable backups. To go live:

1. **Provision the object store** (bucket `snapdragon-backups`, an S3/MinIO
   endpoint) and write `access_key_id` + `secret_access_key` to Vault
   `secret/<brand>/velero`.
2. **Sync `apps/55-velero.yaml`** (manual) — Velero server + node-agent + CRDs.
3. **Sync `apps/56-velero-config.yaml`** (manual) — the `default` BSL (+ any
   per-brand BSLs), RBAC, and the sweep CronJob.
4. **Flip the effector flag** on the admin-bff: set
   `BACKUPS_EFFECTOR_ENABLED=true` (env, `app.backups.effector.enabled`) and roll
   the deployment. The real `VeleroBackupEffector` replaces the `NoopBackupEffector`.
5. **Un-suspend the sweep**: `kubectl -n velero patch cronjob
   backups-status-sweep -p '{"spec":{"suspend":false}}'` (or the equivalent ArgoCD
   value).

To go dark again, reverse steps 4–5 (the BSL/RBAC are inert without the effector).
