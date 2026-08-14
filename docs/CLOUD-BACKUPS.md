# Cloud backups — generator (GitOps) leg

This document covers the **generator** half of the per-domain + total-cloud cloud
backups feature: installing Velero, provisioning the backup destination
(`BackupStorageLocation`) + ESO/Vault credentials + least-privilege RBAC, and the
status-sweep. The catalog, role gates, versioning, restore step-up, and the
per-service menu live in the **admin-bff** (`cloudbackup` package: foundation
PR #74 + the Velero effector PR #76); the UI lives in `hugmesh-admin-ui`.

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
| `specs/cluster/manifests/velero/schedule-template.yaml` | **Dark** recurring-schedule template (kustomize line commented, `paused: true`). |
| `specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml` | The object-store credentials **and the kopia repo encryption password**, materialized by ESO from Vault — never inline. |
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

## Per-brand destinations (dedicated bucket/credential)

A brand that opts into its own destination needs, **in one change**:

1. `backup_destination.destination_ref = "<name>"` in the catalog (admin-bff).
2. A BSL named exactly `<name>` — the commented per-brand template in
   [`backupstoragelocation.yaml`](../specs/cluster/manifests/velero/backupstoragelocation.yaml).
3. Credentials, one of:
   * **Shared** — the BSL's `spec.credential` keeps `velero-cloud-credentials`;
     nothing else to provision.
   * **Dedicated** — provision the commented per-brand ExternalSecret template in
     [`velero-externalsecrets.yaml`](../specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml)
     (target `velero-cloud-credentials-<name>`), seed
     `access_key_id` + `secret_access_key` at
     `secret/hugmesh/velero-<name>` (`vault kv put` — per-brand paths like
     `secret/<brand>/velero` go nowhere ESO reads), and point the BSL's
     `spec.credential.name` at the new Secret.

The kopia **repo password stays global** either way: Velero 1.18 keys every
repository from the single `velero-repo-credentials` Secret — there is no
per-BSL repo password.

## Credentials never touch git

`velero-cloud-credentials` (key `cloud`, an AWS/S3 INI file) is **templated by ESO
from Vault** at the **fixed path** `secret/hugmesh/velero`
(`access_key_id` + `secret_access_key`) — the
[`ExternalSecret`](../specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml)
hardcodes this single Vault path for the **shared** credential. The Velero server
(`credentials.existingSecret`) and every BSL on the shared credential
(`spec.credential`) reference the resulting Secret by name. No object-store
key/secret bytes appear anywhere in the git tree. The bucket/endpoint
coordinates in the BSL are non-secret and generator-templated.

A brand whose per-brand BSL uses a **dedicated** bucket/credential provisions the
commented **per-brand ExternalSecret template** at the bottom of the same file
(target `velero-cloud-credentials-<destination-ref>`, Vault path
`secret/hugmesh/velero-<destination-ref>`) — see
[Per-brand destinations](#per-brand-destinations-dedicated-bucketcredential).
Brands on the shared credential need nothing extra.

## Kopia repository encryption (the repo password)

Kopia encrypts each backup repository (AES256-GCM-HMAC-SHA256) under a
**repository password** Velero reads from the Secret `velero-repo-credentials`
(key `repository-password`) in the `velero` namespace. **Upstream's default is a
well-known static password** (`static-passw0rd`, published in Velero's source):
if the Secret does not exist when the first repository is initialized, Velero
creates it with that default — "encrypted" backups anyone holding the bucket can
open. The second ExternalSecret in
[`velero-externalsecrets.yaml`](../specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml)
templates this Secret from the **same** Vault path (`secret/hugmesh/velero`,
property `repo_password`), and `scripts/gen-cluster-secrets.sh` seeds the
property in the same write as the object-store creds (minted, or pinned via
`MANAGED_VELERO_REPO_PASSWORD` / keys-file `managed.velero.repo_password`).

Upstream (Velero 1.18) requires the password to be in place **before the first
backup targeting the repository** — guaranteed here because the ExternalSecret
materializes as soon as the Vault path is seeded (step 1 of go-live), while no
backup can run until the effector flag flips (step 4).

> **Rotation caveat (verified upstream):** changing the repo password does
> **not** re-encrypt existing kopia repositories. Velero simply can no longer
> connect to repositories created under the old password ("Velero will not be
> able to connect with the older backups"). Rotating therefore means starting a
> **new** repository (fresh bucket/prefix, old backups restorable only by
> restoring the old password). Pin the password across re-provisions — a
> re-run of `gen-cluster-secrets.sh` with managed velero creds enabled and no
> pin mints a fresh one, which IS a rotation.

## RBAC scope (not cluster-admin)

- `backups-effector` (SA in `hugmesh-backend`, the admin-bff's identity):
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
DB credential, and (b) the CR label `hugmesh.net/backup-set-id` is a *lossy*
slug of the raw id. So the sweep is **split**:

- **Generator CronJob (`sweep-cronjob.yaml`)** — the CR-read half: finds Velero
  CRs labelled `app.kubernetes.io/managed-by=hugmesh-admin-bff` that reached a
  terminal `.status.phase` and mirrors it onto the CR as the annotation
  `hugmesh.net/catalog-status=complete|failed` (the exact key the admin-bff
  reader's `CATALOG_STATUS_ANNOTATION` constant names).
- **Admin-bff reconciler (SHIPPED on admin-bff main)** — the catalog-write half:
  the `cloudbackup` package's `BackupStatusReconciler` (scheduled, leader-gated,
  reading CRs via `Fabric8VeleroStatusReader`) lists the managed-by CRs and reads
  `.status.phase` **directly**; the CronJob's mirror annotation is only its
  *fallback* phase source, so the reconciler works with or without the sweep
  deployed. Each terminal CR maps back to the **raw** `backup_set` id (the
  `hugmesh.net/backup-set-id` annotation, else the same-named slug label) and
  `markStatus(id, complete|failed)` flips the row. A SUPERADMIN-only on-demand
  trigger exists at `POST /bff/superadmin/cloud-backups/sweep`
  (`BackupSweepController`).

Both halves ship: sets reach `running` (the effector), the CR reaches a terminal
phase (+ the mirrored annotation once this sweep is un-suspended), and the
admin-bff reconciler flips the catalog row terminal. The split stays deliberate —
the BFF remains the sole writer of `backup_set` (least privilege + the lossy-slug
id mapping both live on its side).

## Turning backups ON (superadmin opt-in)

Installing Velero does not enable backups. To go live:

1. **Provision the object store** (bucket `hugmesh-backups`, an S3/MinIO
   endpoint) and write `access_key_id` + `secret_access_key` **+
   `repo_password`** (the kopia repo encryption password — omit it and every
   repo is keyed by upstream's well-known default, see
   [Kopia repository encryption](#kopia-repository-encryption-the-repo-password))
   to Vault at the fixed path `secret/hugmesh/velero`, either via
   `scripts/gen-cluster-secrets.sh` (`MANAGED_VELERO_*`) or one manual
   `vault kv put` carrying **all three** properties (`kv put` replaces the whole
   document). Dedicated per-brand credentials use their own path — see
   [Per-brand destinations](#per-brand-destinations-dedicated-bucketcredential).
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

## Recurring schedules (dark template)

The effector emits **one-shot** Backup/Restore CRs only — the catalog has no
cadence model. Recurring backups ship as an operator-level **dark template**,
[`manifests/velero/schedule-template.yaml`](../specs/cluster/manifests/velero/schedule-template.yaml):
a nightly total-cloud Velero `Schedule` (1.18 schema) behind two gates, exactly
like the rest of this feature:

1. its `kustomization.yaml` resource line ships **commented** — a default sync
   never applies it;
2. the CR itself carries `spec.paused: true` — even applied, nothing fires until
   unpaused (`skipImmediately: true` also suppresses the unpause catch-up run).

To enable, **after** go-live steps 1–3 (in particular: `velero-repo-credentials`
must have materialized, or the first scheduled backup keys the repo with
upstream's default password):

1. Uncomment `- schedule-template.yaml` in
   `specs/cluster/manifests/velero/kustomization.yaml`, adjust
   cron/TTL/namespaces to taste, and sync `apps/56-velero-config.yaml`.
2. Unpause: `kubectl -n velero patch schedule total-cloud-nightly --type=merge
   -p '{"spec":{"paused":false}}'`.

**Honest limitation (cross-repo follow-up owed to admin-bff):** backups a
Schedule produces have **no `backup_set` row** — they never appear in the
catalog UI, and the status sweep + `BackupStatusReconciler` deliberately ignore
them (the template labels them `managed-by=hugmesh-generator`, not
`hugmesh-admin-bff`). They restore like any Velero backup, via `velero` CLI/CRs
rather than the catalog. First-class recurring backups — a cadence field on
`backup_set` + the effector emitting `Schedule` CRs with the catalog labels —
are an admin-bff follow-up, not part of this generator leg.
