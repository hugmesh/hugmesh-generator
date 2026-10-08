# Cloud backups — generator (GitOps) leg

This page covers the **generator** half of per-domain and total-cloud backups. It
installs Velero, sets up the backup destination (`BackupStorageLocation`), the
ESO/Vault credentials and least-privilege RBAC, and runs the status sweep. The
catalog, role gates, versioning, restore step-up and per-service menu live in the
**admin-bff** (`cloudbackup` package). The UI lives in `hugmesh-admin-ui`.

The feature **ships dark**. Installing Velero must NOT start real backups. Two
independent gates keep it idle until a superadmin opts in.

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
Velero CR `spec.storageLocation` to the `destination_ref` of the backup_set row. If
that is blank it falls back to the literal string `default`:

```java
return (ref == null || ref.isBlank()) ? "default" : ref.trim();
```

The effector never hardcodes a BSL name. So:

- The **`default` BSL is required**. It is the TOTAL/superadmin destination, and
  the fallback for any DOMAIN backup with a blank `destination_ref`.
- A brand that sets `backup_destination.destination_ref = "<name>"` **must** have a
  BSL named exactly `<name>` (use the per-brand template in
  `backupstoragelocation.yaml`). Without it, that brand's Velero Backup CR fails
  to reconcile (`backup storage location not found`) and the sweep marks the row
  `failed`. The fix is to provision the BSL, never to change code.

Keep brands on `default` unless a dedicated per-brand bucket is wanted. Provision
the per-brand BSL in the same change that sets `destination_ref`.

## Per-brand destinations (dedicated bucket/credential)

A brand with its own destination needs, **in one change**:

1. `backup_destination.destination_ref = "<name>"` in the catalog (admin-bff).
2. A BSL named exactly `<name>` — the commented per-brand template in
   [`backupstoragelocation.yaml`](../specs/cluster/manifests/velero/backupstoragelocation.yaml).
3. Credentials, one of:
   * **Shared** — the BSL's `spec.credential` keeps `velero-cloud-credentials`.
     Nothing else to provision.
   * **Dedicated** — provision the commented per-brand ExternalSecret template in
     [`velero-externalsecrets.yaml`](../specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml)
     (target `velero-cloud-credentials-<name>`). Seed
     `access_key_id` + `secret_access_key` at
     `secret/hugmesh/velero-<name>` (`vault kv put`; per-brand paths like
     `secret/<brand>/velero` go nowhere ESO reads). Then point the BSL's
     `spec.credential.name` at the new Secret.

The kopia **repo password stays global** either way. Velero 1.18 keys every
repository from the single `velero-repo-credentials` Secret. There is no per-BSL
repo password.

## Credentials never touch git

`velero-cloud-credentials` (key `cloud`, an AWS/S3 INI file) is **templated by ESO
from Vault** at the **fixed path** `secret/hugmesh/velero`
(`access_key_id` + `secret_access_key`). The
[`ExternalSecret`](../specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml)
hardcodes that one path for the **shared** credential. The Velero server
(`credentials.existingSecret`) and every BSL on the shared credential
(`spec.credential`) name the resulting Secret. No object-store key or secret appears
in the git tree. The bucket and endpoint in the BSL are not secret and are
generator-templated.

A brand whose BSL uses a **dedicated** bucket or credential provisions the
commented **per-brand ExternalSecret template** at the bottom of the same file
(target `velero-cloud-credentials-<destination-ref>`, Vault path
`secret/hugmesh/velero-<destination-ref>`). See
[Per-brand destinations](#per-brand-destinations-dedicated-bucketcredential).
Brands on the shared credential need nothing extra.

## Kopia repository encryption (the repo password)

Kopia encrypts each backup repository (AES256-GCM-HMAC-SHA256) under a
**repository password**. Velero reads it from the Secret `velero-repo-credentials`
(key `repository-password`) in the `velero` namespace. **Upstream's default is a
well-known static password** (`static-passw0rd`, published in Velero's source). If
the Secret does not exist when the first repository is initialized, Velero creates
it with that default. The "encrypted" backups then open for anyone who holds the
bucket.

The second ExternalSecret in
[`velero-externalsecrets.yaml`](../specs/cluster/manifests/external-secrets/velero-externalsecrets.yaml)
templates this Secret from the **same** Vault path (`secret/hugmesh/velero`,
property `repo_password`). `scripts/gen-cluster-secrets.sh` seeds the property in the
same write as the object-store credentials. It mints one, or you pin it with
`MANAGED_VELERO_REPO_PASSWORD` or the keys-file entry
`managed.velero.repo_password`.

Velero 1.18 needs the password in place **before the first backup that uses the
repository**. That holds here: the ExternalSecret materializes as soon as the Vault
path is seeded (step 1 of go-live), and no backup can run until the effector flag
flips (step 4).

> **Rotation caveat (verified upstream):** changing the repo password does
> **not** re-encrypt existing kopia repositories. Velero can no longer connect to
> repositories made under the old password ("Velero will not be able to connect
> with the older backups"). To rotate, start a **new** repository (fresh
> bucket/prefix). Old backups restore only if you restore the old password. Pin the
> password across re-provisions. A re-run of `gen-cluster-secrets.sh` with managed
> velero credentials enabled and no pin mints a fresh password, and that IS a
> rotation.

## RBAC scope (not cluster-admin)

- `backups-effector` (SA in `hugmesh-backend`, the admin-bff's identity):
  `create/get/list/patch` on `velero.io` `backups` + `restores` in the **`velero`
  namespace only**. No pods, secrets, exec or cluster scope.
- `backups-effector` also holds a second Role, `backups-effector-menu-read`, in
  `hugmesh-backend`: `get` on core `configmaps`, no more. The admin-bff reads the
  per-brand `hugmesh-installed-services-<domainSlug>` ConfigMap with it to trim a
  scoped admin's backup menu. Without it the read gets 403 and the menu falls back
  to the full catalog.
- `backups-sweep` (SA in `velero`): `get/list/watch/patch` on the same CRs, to
  mirror `.status.phase`. It cannot create or delete CRs.

Velero's own server SA (chart-created `velero`) is separate and unchanged.

## Status sweep — split design (read here, write in admin-bff)

The admin-bff writes the catalog status (`backup_set.status`) with
`BackupSetRepository.markStatus(id, …)`, keyed on the **raw** set id, through the
least-privilege `adminbff_app` Postgres role. A generator CronJob cannot write it
correctly. It would (a) duplicate the BFF's sole-writer authority and need its own
DB credential, and (b) hit a mismatch: the CR label `hugmesh.net/backup-set-id` is a
*lossy* slug of the raw id. So the sweep is **split**:

- **Generator CronJob (`sweep-cronjob.yaml`)** — the CR-read half. It finds Velero
  CRs labelled `app.kubernetes.io/managed-by=hugmesh-admin-bff` that reached a
  terminal `.status.phase`. It mirrors that phase onto the CR as the annotation
  `hugmesh.net/catalog-status=complete|failed` (the key the admin-bff reader's
  `CATALOG_STATUS_ANNOTATION` constant names).
- **Admin-bff reconciler (SHIPPED on admin-bff main)** — the catalog-write half.
  The `cloudbackup` package's `BackupStatusReconciler` (scheduled, leader-gated,
  reading CRs through `Fabric8VeleroStatusReader`) lists the managed-by CRs and reads
  `.status.phase` **directly**. The CronJob's annotation is only a *fallback* phase
  source, so the reconciler works with or without the sweep deployed. It maps each
  terminal CR back to the **raw** `backup_set` id (the `hugmesh.net/backup-set-id`
  annotation, else the same-named slug label) and flips the row with
  `markStatus(id, complete|failed)`. A SUPERADMIN-only on-demand trigger exists at
  `POST /bff/superadmin/cloud-backups/sweep` (`BackupSweepController`).

Both halves ship. Sets reach `running` (the effector). The CR reaches a terminal
phase (and gets the mirrored annotation once the sweep is un-suspended). The
admin-bff reconciler flips the catalog row. The split is deliberate: the BFF stays
the sole writer of `backup_set`, and both the least-privilege rule and the lossy-slug
id mapping live on its side.

## Turning backups ON (superadmin opt-in)

Installing Velero does not enable backups. To go live:

1. **Provision the object store** (bucket `hugmesh-backups`, an S3/MinIO
   endpoint). Write `access_key_id`, `secret_access_key` **and `repo_password`** to
   Vault at the fixed path `secret/hugmesh/velero`. `repo_password` is the kopia
   repo encryption password. Omit it and every repo is keyed by upstream's
   well-known default (see
   [Kopia repository encryption](#kopia-repository-encryption-the-repo-password)).
   Use `scripts/gen-cluster-secrets.sh` (`MANAGED_VELERO_*`), or one manual
   `vault kv put` that carries **all three** properties (`kv put` replaces the whole
   document). Dedicated per-brand credentials use their own path; see
   [Per-brand destinations](#per-brand-destinations-dedicated-bucketcredential).
2. **Sync `apps/55-velero.yaml`** (manual) — Velero server + node-agent + CRDs.
3. **Sync `apps/56-velero-config.yaml`** (manual) — the `default` BSL (and any
   per-brand BSLs), RBAC, and the sweep CronJob.
4. **Flip the effector flag** on the admin-bff: set
   `BACKUPS_EFFECTOR_ENABLED=true` (env, `app.backups.effector.enabled`) and roll
   the deployment. The real `VeleroBackupEffector` replaces the `NoopBackupEffector`.
5. **Un-suspend the sweep**: `kubectl -n velero patch cronjob
   backups-status-sweep -p '{"spec":{"suspend":false}}'` (or the equivalent ArgoCD
   value).

To go dark again, reverse steps 4 and 5. The BSL and RBAC do nothing without the
effector.

## Recurring schedules (dark template)

The effector emits **one-shot** Backup/Restore CRs only. The catalog has no cadence
model. Recurring backups come from an operator-level **dark template**,
[`manifests/velero/schedule-template.yaml`](../specs/cluster/manifests/velero/schedule-template.yaml):
a nightly total-cloud Velero `Schedule` (1.18 schema) behind two gates, like the rest
of the feature:

1. its `kustomization.yaml` resource line ships **commented**, so a default sync never
   applies it;
2. the CR carries `spec.paused: true`, so even when applied nothing fires until it is
   unpaused (`skipImmediately: true` also stops a catch-up run on unpause).

To enable it, **after** go-live steps 1 to 3 (`velero-repo-credentials` must have
materialized, or the first scheduled backup keys the repo with upstream's default
password):

1. Uncomment `- schedule-template.yaml` in
   `specs/cluster/manifests/velero/kustomization.yaml`, adjust
   cron/TTL/namespaces, and sync `apps/56-velero-config.yaml`.
2. Unpause: `kubectl -n velero patch schedule total-cloud-nightly --type=merge
   -p '{"spec":{"paused":false}}'`.

**Limitation (an admin-bff follow-up is owed):** backups a Schedule produces have
**no `backup_set` row**. They never appear in the catalog UI, and the status sweep
and `BackupStatusReconciler` ignore them on purpose (the template labels them
`managed-by=hugmesh-generator`, not `hugmesh-admin-bff`). They restore like any
Velero backup, through the `velero` CLI or CRs, not the catalog. First-class
recurring backups need a cadence field on `backup_set` and an effector that emits
`Schedule` CRs with the catalog labels. That is admin-bff work, not part of this
generator leg.
