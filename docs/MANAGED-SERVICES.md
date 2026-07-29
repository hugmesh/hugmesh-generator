# Managed backing services

Point an in-mesh **backing service** (a datastore/infra the mesh normally runs
itself) at a **hosted cloud equivalent** (AWS / Azure) on a generated node image,
INSTEAD OF running it in-cluster. Self-hosted stays the platform default; managed
mode is a strictly-additive, opt-in config axis.

Registry: [`specs/cluster/backing-services.yaml`](../specs/cluster/backing-services.yaml)
(`kind: BackingServiceRegistry`) is the single declared source of truth. The
builder's `gate_backing_services()` is its executable twin.

## The #1 invariant — self-hosted is byte-identical

With **no** managed selection (empty `MANAGED_SERVICES`, no `--managed-service`
flag) every baked byte, consumer endpoint literal, ArgoCD app and ESO line is
EXACTLY today's mainline. `gate_backing_services()` returns immediately on an empty
selection. Nothing about the default self-hosted image changes.

## How to select

Build-time, on the **x86** and **rpi5** node builders only (the two mesh-node
builders — client/standalone images have no cluster tree):

```sh
# env / brand.conf (WHITESPACE-separated id=endpoint tokens; commas are literal, so
# a kafka endpoint can be a comma-list of brokers):
MANAGED_SERVICES="kafka=msk-broker:9098 postgres-admin-bff=my.rds.amazonaws.com:5432"

# or the repeatable CLI flag (APPENDS to MANAGED_SERVICES):
build-x86-host-stage4.sh --role be \
  --managed-service kafka=msk-broker:9098 \
  --managed-service postgres-admin-bff=my.rds.amazonaws.com:5432
```

For each selected id the build (a) prunes the in-mesh workload (its ArgoCD
Application + manifests dir), (b) repoints the consumer endpoint env value(s) at
`<endpoint>`, (c) keeps the ESO Secret names/Vault paths so the operator's hosted
creds flow through unchanged, and (d) bakes `/etc/hugmesh/backing-services.conf`
+ `README-MANAGED.md` into the image.

Fail-closed: an unknown id, a **tier-3** (docs-only) id, or a malformed/empty
endpoint **aborts the build** with the reason.

`endpoint` shape per id:

| id | endpoint form | example |
|---|---|---|
| `postgres-*` | `host:port` (dbName fixed) | `my.rds.amazonaws.com:5432` |
| `kafka` | `host:port[,host:port…]` | `b-1.msk:9098,b-2.msk:9098` |
| `clickhouse` | `https://host:port` or `host:port` | `https://xyz.clickhouse.cloud:8443` |
| `velero-objectstore` | `aws` (real S3) or an S3-compatible URL | `aws` |
| `federation-bundles` | `bucket` or `bucket@https://endpoint` | `snap-bundles` |
| `smtp` | `host:port` (also flows via `MAIL_*`) | `email-smtp.us-east-1.amazonaws.com:587` |

Optional companions (env / brand.conf): `MANAGED_VELERO_BUCKET`,
`MANAGED_VELERO_REGION`, `MANAGED_FEDERATION_BUNDLES_REGION`.

## Studio + ncurses surface (M2)

The same axis is selectable in the two interactive front-ends. Every front-end just
composes the same `--managed-service id=endpoint` the builders parse — the empty
default (all self-hosted) emits nothing, so an untouched surface is byte-identical.

* **Studio wizard** (`studio/.../gui/pages/network.py`): a **Managed backing
  services** section on the Domain/mesh/services step. Per tier-1/2 service a
  *self-hosted (default) / managed* toggle plus an endpoint line-edit that is live
  only when *managed* is checked; tier-3 services are shown read-only with their
  blocker note (the builder refuses them in v1). The section is shown for
  cloud/mesh builds and platform-gated to x86/rpi5 (`gate_widgets`, like
  `optional_services`); it saves/loads `ImageConfig.managed_services`
  (`dict[str,str]` id→endpoint). Because it is an `ImageConfig` field it rides the
  `IMAGE_SPEC_JSON` / `--config` batch+web spec channel automatically.
* **`ImageConfig.managed_services`** (`studio/.../core/config.py`): scoped
  `_X86_RPI5` in the platform capability table; `to_cli_args()` emits one
  `--managed-service id=endpoint` per entry in sorted-id order (empty = no flag);
  `validate_identity()` fail-closes each id to the tier-1/2 set (a tier-3 id is
  REFUSED with its blocker) and shape-checks the endpoint (`host[:port]`/URL, no
  shell metacharacters). Mesh-wide by nature, so it is a single-image field — NOT a
  per-node `WorklistEntry` axis (every node talks to the same logical service; the
  base config's value deepcopies onto every materialized entry).
* **ncurses menu** (`scripts/build-menu.sh`): Options → **Managed backing services**
  (`managed_services_screen`) — per tier-1/2 service pick self-hosted/managed and an
  endpoint; tier-3 ids are shown but refused. Persisted as the space-separated
  `OPT_MANAGED_SERVICES` (`id=endpoint` tokens, so a kafka broker-list keeps its
  commas) via `save_conf`, and composed into the build flags as a repeatable
  `--managed-service "id=endpoint"` exactly as `OPT_SERVICES` composes
  `--optional-services`.

The **web worklist toggle** (admin-ui) that would surface managed vs self-hosted
state in the browser is a **separate cross-repo follow-up** (admin-ui + admin-bff),
not part of this generator-side surface. See the SEAM GAP note at the bottom.

## Difficulty ranking (verbatim-honest, from recon)

| Service | AWS / Azure target | Difficulty | Blocking specifics | v1 |
|---|---|---|---|---|
| Velero object store | S3 / Blob | **Trivial** | already aws-plugin + INI creds; edit the BSL coordinates, seed `hugmesh/velero`; Azure = plugin initContainer swap | **coded** |
| SMTP | SES / ACS | **Trivial** | pure data change through `gen-cluster-secrets` `MAIL_*`; zero manifest edits | **coded** |
| Kafka | MSK / Event Hubs | Easy | 1 env value (`admin-bff-api`); TLS+SASL props added out of band (none today) | **coded** |
| ClickHouse | ClickHouse Cloud | Easy | 3 endpoint literals; no AWS/Azure first-party | **coded** |
| Per-service Postgres ×core | RDS / Azure DB Flexible | Medium | dual URL envs per consumer (R2DBC + Liquibase), delete DB apps, re-run role-split SQL out of band, TLS params + truststore CA, Casdoor `sslmode=disable` hardcode, Citus initdb (federation/route-access) incompatible w/ vanilla RDS | **coded** (5 BFF + casdoor-pg) |
| federation-bundles | S3 / Blob | Easy | `APP_BUNDLES_STORAGE=s3` flag already exists; add `APP_BUNDLES_S3_*` | **coded** |
| Vault KV + ESO | Secrets Manager / Key Vault | Medium | 1 ClusterSecretStore + ~90 remoteRef renames + writer + provision.sh token-seeding removal | **docs-only** |
| Cassandra | Keyspaces / Cosmos-Cassandra | **Hard** | auth/TLS only in the dark hardening overlay; SigV4/port 9142; LWT/DC semantics; 5 consumers | **docs-only** |
| Harbor | ECR / ACR | **Hard** | registry host literal in ~30 kustomizations + dockerconfigjson + kaniko; robot-account Job has no analog; ECR 12h token expiry breaks static pull Secret; loses air-gap | **docs-only** |
| Vault PKI | ACM-PCA / Key Vault certs | **Hardest** | `VaultDynamicSecret` is Vault-only; ~25 `<app>-mtls` + 7 DB certs + rotation; USB-custody cluster-CA-import model has no managed analog | **docs-only** |

## Credentials custody

Managed creds are **operator-supplied only** — the generator NEVER mints a
managed-cloud credential, and creds are NEVER on argv or committed.

* **Postgres**: the hosted DB password lives at the SAME Vault path the minted
  value used (`secret/<brand>/<x>-db`, ESO Secret `<x>-db-auth` / `<x>-db-app-auth`).
  Seed it via the same env/keys-file `gen-cluster-secrets.sh` already reads.
* **velero object store** (the gap the recon flagged — the mesh only ever wrote
  this path by hand): `gen-cluster-secrets.sh` now resolves
  `MANAGED_VELERO_ACCESS_KEY_ID` / `MANAGED_VELERO_SECRET_ACCESS_KEY` (env ->
  keys-file `managed.velero.access_key_id` / `.secret_access_key` -> blank). When
  both resolve it writes `secret/<brand>/velero` (online) and mirrors the
  materialized `velero-cloud-credentials` Secret (ns `velero`, key `cloud` = AWS
  INI) into the offline `secrets.json` (chmod 600). **Blank = disabled**: nothing
  is written (a blank never clobbers a manually-seeded path; velero stays dark).
* **SMTP (SES/ACS)**: reuse the existing `MAIL_*` creds path — set `MAIL_HOST` to
  the SES/ACS submission endpoint, port 587, `MAIL_TLS=starttls`, and the SES SMTP
  user/password. Mail stays disabled until a real user+password resolve.
* **federation-bundles / kafka**: no static-key Secret. Federation bundles use the
  AWS default credential chain (IRSA / `AWS_ACCESS_KEY_ID` env / instance metadata)
  — do NOT rely on the dead `app.bundles.s3.access-key` yml keys. Kafka is plaintext
  today; a TLS+SASL managed broker needs Spring Kafka security props added out of
  band.

## App-level config transport (the fleet trap — avoided)

Where an app must choose local-vs-managed behaviour it is **property-switched**
(`@ConditionalOnProperty` on an `app.*` key fed by an env var, `matchIfMissing=true`
on the self-hosted default) — **never** a profile-named
`application-<x>.properties` under `SPRING_CONFIG_ADDITIONAL_LOCATION`. That
directory only ADDS a search path; a profile-named file loads only when profile
`<x>` is active and fails **silently** (six services once shipped keystore
passwords that never loaded this way). The endpoint rewrite here only changes env
VALUES already read on the self-hosted path.

## Per-service runbooks (tier 1–2)

### velero-objectstore (S3 / Blob) — tier 1
1. Provision the bucket + an IAM user/role with the Velero S3 permissions.
2. Build with `--managed-service velero-objectstore=aws` (real S3, drops the
   in-cluster `s3Url`) or `=https://<s3-compatible-host>`; set
   `MANAGED_VELERO_BUCKET` / `MANAGED_VELERO_REGION` if not the defaults
   (`hugmesh-backups` / `us-east-1`).
3. Seed creds: `MANAGED_VELERO_ACCESS_KEY_ID=… MANAGED_VELERO_SECRET_ACCESS_KEY=…`
   before `gen-cluster-secrets.sh`.
4. **Azure**: swap the plugin initContainer in `apps/55-velero.yaml` to
   `velero-plugin-for-microsoft-azure` — **not coded in v1**, do it by hand.

### smtp (SES / ACS) — tier 1
No manifest edit. Set `MAIL_HOST/MAIL_PORT/MAIL_USER/MAIL_PASSWORD` (env or
keys-file) to the SES/ACS submission endpoint; `--managed-service smtp=host:port`
only records the choice in `backing-services.conf`. DKIM is platform-side.

### kafka (MSK / Event Hubs) — tier 2
`--managed-service kafka=<bootstrap-servers>` rewrites `SPRING_KAFKA_BOOTSTRAP_SERVERS`
in admin-bff and prunes `apps/35-analytics-kafka.yaml` + `manifests/analytics/kafka`.
The `analytics-discovery` DNS-floor Service is left (harmless). **Add Spring Kafka
`security.protocol`/`sasl.*` props out of band** for a TLS+SASL managed broker
(none exist today).

### clickhouse (ClickHouse Cloud) — tier 2
`--managed-service clickhouse=https://<host>:8443` rewrites admin-bff
`CLICKHOUSE_URL` (prefixes `https://` if you omit a scheme) and the uptrace
`ch.dsn` host, and prunes the analytics-clickhouse app + manifests. TLS delta:
plaintext 8123/9000 -> 8443/9440. The uptrace DSN keeps `sslmode=disable` unless
you edit it.

### Per-service Postgres (RDS / Azure DB Flexible) — tier 2
Coded ids: `postgres-admin-bff`, `postgres-user-bff`, `postgres-mod-bff`,
`postgres-forum-bff`, `postgres-wiki-bff`, `postgres-casdoor`. Each rewrites BOTH
`SPRING_R2DBC_URL` and `SPRING_LIQUIBASE_URL` (miss one and Liquibase or the
runtime pool silently targets the wrong host), deletes the DB Application +
manifests, and keeps the `<x>-db-auth` / `<x>-db-app-auth` ESO Secrets.
`postgres-casdoor` does NOT prune `apps/05-casdoor.yaml` (that IS the IdP) — it
flips `host`/`sslmode` inside the Casdoor `dataSourceName` string and drops the
bundled `pg.yaml`.

Out-of-band, per DB:
* Re-run `initdb/10-roles.sh` (owner + least-priv app role) against the managed DB.
* Add `?ssl=true&sslMode=require` to the URLs and trust the managed CA in each
  app's truststore (built by the keystore initContainers).
* **federation-db and route-access-db are NOT managed ids** — they ship
  `initdb/90-citus.sh` and vanilla RDS has no Citus (Azure Cosmos DB for PostgreSQL
  does). Documented, not coded.

### federation-bundles (S3) — tier 2
`--managed-service federation-bundles=<bucket>` (or `bucket@https://endpoint`)
flips `APP_BUNDLES_STORAGE=s3` and injects `APP_BUNDLES_S3_BUCKET/ENDPOINT/REGION`
into the federation-api deployment. Creds use the AWS default chain (IRSA/env).

## Tier 3 — why not yet (docs only in v1)

The builder **refuses** `--managed-service` for these ids and dies with the
blocker. They are named in the registry so the inventory is complete.

* **vault-kv** (Secrets Manager / Key Vault): mechanical but broad — replace the one
  `ClusterSecretStore`, rewrite ~90 `remoteRef.key` names, re-point the
  `gen-cluster-secrets` writer, and drop the vault-token/vault-ca seeding for
  IRSA/workload-identity. Entangled with vault-pki (same server). A dedicated wave.
* **cassandra** (Keyspaces / Cosmos-Cassandra): auth/TLS knobs live only in the DARK
  `cassandra-hardening` overlay (today: no authenticator, plaintext 9042).
  Keyspaces/Cosmos mandate TLS + SigV4/service-user auth on 9142, unwired on the
  live path. Local-DC name, keyspace auto-creation and LWT/consistency semantics
  need app-level verification across 3 consumers.
* **harbor** (ECR / ACR): the registry HOST is a literal in ~30 kustomizations + the
  dockerconfigjson template + the kaniko template; the robot-account provisioning
  Job has no ECR/ACR analog; ECR's 12h token expiry breaks the static
  dockerconfigjson pull-secret (needs a credential-helper/IRSA refresher); loses the
  in-cluster air-gap posture the tree is built around.
* **vault-pki** (ACM-PCA / Key Vault certs): the hardest. `VaultDynamicSecret` is a
  Vault-only ESO generator; ACM-PCA / Key Vault certs have no drop-in "POST issue
  role -> cert+key via ESO". Needs a cert-manager re-architecture keeping every
  `<app>-mtls` Secret name/key. The USB-custody cluster-CA-import model (USB CA ==
  truststore anchor == pki_int signer) has NO managed analog.

## Local stack (validation only)

`tests/stack/compose.local.yaml` exposes `${MANAGED_*:-in-stack-default}` seams on
the DB consumers that exist in compose (admin-bff, forum-bff, wiki-bff), threaded
from `Makefile` `STACK_ENV`. UNSET = byte-identical in-stack default. The compose
stack has no Kafka/ClickHouse/MinIO container to replace, so local managed mode is
**DB-endpoint validation only** — image-time managed mode is the real thing.

```sh
make stack-up MANAGED_ADMIN_BFF_R2DBC_URL='r2dbc:postgresql://my.rds:5432/adminbff' \
              MANAGED_ADMIN_BFF_LIQUIBASE_URL='jdbc:postgresql://my.rds:5432/adminbff'
```

## Known SEAM GAP (read side / admin plane)

The read side that a future web management surface (admin-bff / admin-ui) would use
to display installed vs managed state relies on the per-brand
`hugmesh-installed-services-<domainSlug>` ConfigMap — which **the generator never
emits** (only the singular `installed-services` in `hugmesh-policy`). So the
admin-bff per-brand filter always falls back to the full catalog. A web
"backing-services" surface must either emit the per-brand ConfigMap or point the
provider at the policy ConfigMap — **do not depend on the per-brand CM existing**.
This is a cross-repo lane (admin-bff-api + admin-ui), separate from this
generator-side work.
