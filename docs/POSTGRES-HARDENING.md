# Postgres hardening, per-machine-user roles, and opt-in Citus sharding

This document covers the Postgres posture for the application/RBAC databases:

- **(A)** per-machine-user **least-privilege roles** with their **own credentials**
  (no shared owner cred at runtime),
- **(B)** general **Postgres hardening**, and
- **(C)** an **opt-in, sharding-capable** (Citus) deployment topology that leaves
  the default single-node path unchanged and the apps' H2/Postgres-compat test
  slices untouched.

The databases in scope (each its own pod + PVC, ClusterIP-only):

| DB | Namespace | Owner role / DB | Consumer(s) | Tables |
|----|-----------|-----------------|-------------|--------|
| `route-access-db` | hugmesh-pki | `gateway` / `gateway` | admin-bff (W), pki/be/fe-gateway (R) | `gateway_route_access` |
| `federation-db` | hugmesh-backend | `federation` / `federation` | hugmesh-federation-api | `federation_modules`, `user_modules`, `moderation_requests`, `federation_override` |
| `admin-bff-db` | hugmesh-backend | `adminbff` / `adminbff` | hugmesh-admin-bff-api | `account`, `allowlist`, `bff_session`, `namespace_grant`, `iso_artifacts`, `gateway_route_access` |
| `mod-bff-db` | hugmesh-backend | `modbff` / `modbff` | hugmesh-mod-bff-api | `mod_action` |
| `user-bff-db` | hugmesh-backend | `userbff` / `userbff` | hugmesh-user-bff-api | `user_profile`, `user_preference`, `user_block` |
| `casdoor-pg` | hugmesh-pki | `casdoor` / `casdoor` | casdoor | (managed by Casdoor) |

`casdoor-pg` already sources its single `casdoor` user from the ESO `casdoor-db`
Secret and is Casdoor-managed; it is left as-is (no trivial least-privilege split
because Casdoor owns + migrates its own schema with that one role).

---

## (A) Per-machine-user roles + own credentials + least privilege

### Principle

Every DB still has an **owner role** (`POSTGRES_USER`) — but at **runtime** no
consumer logs in as the owner. Each consuming machine-user gets:

- its **own non-owner login role** (`NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT`),
- its **own password** (separate `openssl rand` value, in Vault + the offline
  bundle, never committed), materialized as its **own ESO `ExternalSecret`**, and
- **only the privileges it needs** (DML on its tables; no DDL).

The owner role is retained **only** for DDL / Liquibase (the single-consumer apps
run their changelog at boot with the owner cred) or, for `route-access-db`, as the
table owner the admin-bff's DDL path uses.

### Role / grant / credential matrix

| DB | Login role | Privileges | Used by (Deployment) | DB-pod env | ESO Secret (consumer) | Vault key |
|----|-----------|-----------|----------------------|------------|-----------------------|-----------|
| route-access-db | `gateway` (owner) | DDL/owner | — (DDL only) | `POSTGRES_PASSWORD` | `route-access-db-roles` | `route-access-db.owner_password` |
| route-access-db | `admin_bff` | `SELECT,INSERT,UPDATE,DELETE` on `gateway_route_access` | hugmesh-admin-bff-api | `ROUTE_ACCESS_ADMIN_BFF_PASSWORD` | `route-access-admin-bff` | `route-access-db.admin_bff_password` |
| route-access-db | `pki_gateway` | `SELECT` on `gateway_route_access` | hugmesh-pki-gateway | `ROUTE_ACCESS_PKI_GATEWAY_PASSWORD` | `route-access-pki-gateway` | `route-access-db.pki_gateway_password` |
| route-access-db | `be_gateway` | `SELECT` on `gateway_route_access` | hugmesh-be-gateway | `ROUTE_ACCESS_BE_GATEWAY_PASSWORD` | `route-access-be-gateway` | `route-access-db.be_gateway_password` |
| route-access-db | `fe_gateway` | `SELECT` on `gateway_route_access` | hugmesh-fe-gateway | `ROUTE_ACCESS_FE_GATEWAY_PASSWORD` | `route-access-fe-gateway` | `route-access-db.fe_gateway_password` |
| federation-db | `federation` (owner) | DDL/owner (Liquibase) | federation-api (Liquibase) | `POSTGRES_PASSWORD` | `federation-db-auth` | `federation-db.password` |
| federation-db | `federation_app` | DML on all tables + USAGE on schema/sequences | federation-api (R2DBC runtime) | `FEDERATION_APP_PASSWORD` | `federation-db-app-auth` | `federation-db.app_password` |
| admin-bff-db | `adminbff` (owner) | DDL/owner (Liquibase) | admin-bff (Liquibase) | `POSTGRES_PASSWORD` | `admin-bff-db-auth` | `admin-bff-db.password` |
| admin-bff-db | `adminbff_app` | DML on all tables + USAGE | admin-bff (R2DBC runtime) | `ADMINBFF_APP_PASSWORD` | `admin-bff-db-app-auth` | `admin-bff-db.app_password` |
| mod-bff-db | `modbff` (owner) | DDL/owner (Liquibase) | mod-bff (Liquibase) | `POSTGRES_PASSWORD` | `mod-bff-db-auth` | `mod-bff-db.password` |
| mod-bff-db | `modbff_app` | DML on all tables + USAGE | mod-bff (R2DBC runtime) | `MODBFF_APP_PASSWORD` | `mod-bff-db-app-auth` | `mod-bff-db.app_password` |
| user-bff-db | `userbff` (owner) | DDL/owner (Liquibase) | user-bff (Liquibase) | `POSTGRES_PASSWORD` | `user-bff-db-auth` | `user-bff-db.password` |
| user-bff-db | `userbff_app` | DML on all tables + USAGE | user-bff (R2DBC runtime) | `USERBFF_APP_PASSWORD` | `user-bff-db-app-auth` | `user-bff-db.app_password` |

The DB pod and its consumer reference the **same Vault property** so the role and
its credential always stay in sync.

### How the non-owner role gets DML on Liquibase-managed tables

The four single-consumer DBs create their tables via **Liquibase at app boot**,
*after* Postgres initdb. So the app role's table grants cannot be written as plain
`GRANT ... ON <table>` at initdb time (the tables don't exist yet). Instead
`initdb/10-roles.sh` uses **`ALTER DEFAULT PRIVILEGES FOR ROLE <owner>`** so that
**every table/sequence the owner later creates automatically grants DML** to the
app role — no per-migration grant edits, and the shared Liquibase changelogs the
apps run are **never modified** (so the H2 test slices are unaffected).

`route-access-db` is different: its table is seeded by `initdb/20-schema.sql`
(the gateways do not migrate), so the grants are explicit (and guarded on role
existence so the same file is reusable in the local dev stack).

#### admin-bff is the one service whose changelogs also GRANT explicitly

Every other BFF relies purely on the `ALTER DEFAULT PRIVILEGES` mechanism above and
carries **no SQL `GRANT` at all**. hugmesh-admin-bff-api additionally issues ~49
per-table `GRANT`s from its own changelogs. Those are belt-and-braces — the default
privileges already cover every table Liquibase creates — but they are **not free**,
because a `GRANT` to a role that does not exist is a hard error that aborts the
migration and the pod never starts.

That is exactly what happened on 2026-08-06: all 97 statements named `admin_bff`,
which is **route-access-db's** role (first data row of the matrix above), not a role
of admin-bff's own database. The matrix was right; the changelogs had copied a name
across a datasource boundary. They now target `adminbff_app`.

Two rules follow, and `lint:liquibase-grant-roles` enforces both across **all**
services:

1. **`[created]`** — a changelog may only `GRANT` to a role that *that service's own*
   `initdb` creates. Names are not portable between databases.
2. **`[connects]`** — the grantee must be a role something actually **logs in as** on
   that datasource (`SPRING_LIQUIBASE_USER` / `SPRING_R2DBC_USERNAME`). Merely making
   the name resolve — by adding a `CREATE ROLE` for whatever the changelog happens to
   say — un-wedges startup while the privileges land on a role with no sessions. That
   is the trap this bug set: compose and both Testcontainers harnesses each created
   `admin_bff` from the *changelog's* name so the statement would resolve, which is
   why every environment except the cluster was green.
3. **`[compose]`** — `tests/stack/compose.local.yaml` is read too, and held to the same
   matrix: a role its one-shot `*-db-init` shims `CREATE` must be one the *cluster*
   bootstrap for that Postgres creates, and every role the changelogs grant to must
   exist in compose as well. Without this leg rules 1 and 2 could be satisfied while
   the local stack quietly re-invented a third name, which is precisely the shape of
   the original failure.

   What `[compose]` deliberately does **not** require is that compose connect as the
   same role the cluster does. The local stack connects each app as the database
   **owner** (`adminbff`, `gateway`, …) rather than the least-privilege `*_app` role,
   because the per-user passwords come from ESO and do not exist locally. So compose
   proves the role *names* agree and that the migration runs; it cannot prove a
   privilege is sufficient for the restricted role. Only the cluster — or a
   Testcontainers run that logs in as `adminbff_app` — can.

If you add a `GRANT` to a changelog, take the role name from this matrix.

### initdb layout (mounted as a ConfigMap into `/docker-entrypoint-initdb.d`)

Postgres runs the files in **alphabetical order** on first start (empty data dir):

```
00-hardening.sql   REVOKE PUBLIC + per-DB timeouts + scram password_encryption
10-roles.sh        create the per-machine-user least-privilege login role(s)
                   from the per-user passwords in env (never committed)
20-schema.sql      (route-access-db only) table + canonical seed + table GRANTs
90-citus.sh        OPT-IN Citus enablement (no-op unless SHARDING_CITUS=on)
```

### Gateway credential plumbing (no app change)

The shared gateway image builds its route-access `ConnectionFactory` directly from
`ROUTE_ACCESS_R2DBC_URL` and has **no** separate username/password env. To give
each gateway its own least-privilege identity **without changing the gateway repo**
(and without breaking its H2 test slices), each gateway Deployment now:

1. mounts its own password as `ROUTE_ACCESS_DB_PASSWORD` (`secretKeyRef` to its own
   per-namespace ESO Secret), and
2. sets `ROUTE_ACCESS_R2DBC_URL` to
   `r2dbc:postgresql://<role>:$(ROUTE_ACCESS_DB_PASSWORD)@route-access-db…/gateway`,
   relying on **Kubernetes `$(VAR)` env interpolation** to inject the secret into
   the URL at pod start. The admin-bff's `ROUTE_ACCESS_R2DBC_URL` does the same
   with the `admin_bff` writer role.

The password never appears in git or in the rendered manifest literal — only the
`$(VAR)` reference does.

---

## (B) Postgres hardening applied

Applied via each DB Deployment's `POSTGRES_*` env + container `args` and the
`initdb/00-hardening.sql`:

- **scram-sha-256 everywhere** — `POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256
  --auth-local=scram-sha-256` (governs `pg_hba` method selection, so **no `trust`**
  for host or local), plus `password_encryption=scram-sha-256` both as an
  `ALTER SYSTEM` (00-hardening.sql) and a runtime `-c` flag (defence in depth).
- **No `trust` in `pg_hba`** — the alpine image's generated `pg_hba.conf` uses the
  scram method from the initdb flags for every host/local line; combined with
  `REVOKE … FROM PUBLIC` (CONNECT + schema), a new role can do nothing until
  explicitly granted.
- **`REVOKE ALL ON SCHEMA public FROM PUBLIC`** and `REVOKE ALL ON DATABASE …
  FROM PUBLIC` — every privilege is explicit; app roles get `USAGE` (never
  `CREATE`) on `public`.
- **No superuser for app roles** — every login role is
  `NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT`.
- **Per-role connection limits** — `CONNECTION LIMIT` per role (gateways 5,
  writers/apps 10–20) and a server cap (`max_connections` 50–60). The limit of 20
  on a BFF's app role is a budget for EVERY pod that connects as that role: each
  BFF Deployment sets `SPRING_R2DBC_POOL_INITIAL_SIZE=1` and
  `SPRING_R2DBC_POOL_MAX_SIZE=2`, so that (the autoscaler's `maxReplicas` plus the
  pods a rolling update adds) x pool stays within it (hugmesh-generator#663: with
  the unset default of 10 per pod, six pods asked for 60 and the sign-in answered
  500). `tests/scripts/test-db-connection-budget.sh` fails when it does not.
- **Timeouts** — per-DB `statement_timeout=30s`,
  `idle_in_transaction_session_timeout=60s`, `lock_timeout=10s` so a stuck client
  can't pin a connection or hold locks.
- **Auditable logins** — `log_connections`, `log_disconnections`, and
  `log_min_duration_statement=2000` (slow-statement log) so an unexpected superuser
  login or runaway query is visible.
- **Per-port DB ingress NetworkPolicies** (✅ DONE — merged PR #128, ADR-32) —
  `manifests/networkpolicy/db-ingress.yaml` adds a default-deny-except Ingress per
  DB pod that admits ONLY each store's real clients on its real port: the six
  Postgres pods (`route-access-db`, `admin-bff-db`, `mod-bff-db`, `user-bff-db`,
  `federation-db`, `forum-bff-db`) on `:5432` and `cassandra` on `:9042`, pinned by
  namespaceSelector AND podSelector peers. These ship in the **auto-synced**
  `apps/08-networkpolicy.yaml` Application (tier segmentation auto-sync was
  activated in merged PR #40; per-pod homeserver/forum isolation in merged PR #56);
  they are ingress-only (egress stays open), so a missed allow restores
  connectivity on removal.
- **Per-DB Vault-PKI server certs** (✅ DONE, ships dark — merged PR #124, ADR-32) —
  each dedicated Postgres DB now gets a Vault-PKI server cert on disk via the
  existing Vault-PKI + ESO pattern: `pki-externalsecrets.yaml` issues a per-DB
  `VaultDynamicSecret` (`pki_int/issue/<db>`) → `kubernetes.io/tls` Secret
  `<db>-mtls`, mounted read-only at `/etc/postgres-tls` (`optional: true` so the
  pod still starts before ESO). Postgres is **NOT** started with `ssl=on` and no
  consumer URL sets `sslMode`, so the **default wire path stays byte-identical**
  (cert present but unused).
- **In-cluster TLS — gated, ships dark (`PG_TLS_ENABLED`, default `false`).** DB
  Services are ClusterIP-only and confined by SELinux MCS levels + NetworkPolicy.
  Wire encryption between an app and its DB is **wired but inert**: each of the NINE
  dedicated DB pods (admin-bff-db, mod-bff-db, user-bff-db, federation-db,
  forum-bff-db, route-access-db, plus wiki-bff-db, mesh-bff-db and
  character-forge-bff-db, which this text predates; re-measured 2026-10-14, all nine
  still `PG_TLS_ENABLED: "false"`) mounts its Vault-PKI server cert read-only at `/etc/postgres-tls`
  AND boots through a small init wrapper `entrypoint/pg-tls-entrypoint.sh`
  (a SEPARATE ConfigMap, not in the initdb dir) that mirrors the egress-proxy
  entrypoint idiom:
  - `PG_TLS_ENABLED=false` (DEFAULT): the wrapper runs Postgres with the SAME static
    server args as before — **no `-c ssl=on`** — so the cert is unused and the wire
    path is **byte-identical** to the pre-TLS deployment.
  - `PG_TLS_ENABLED=true`: the wrapper appends
    `-c ssl=on -c ssl_cert_file=/etc/postgres-tls/tls.crt
    -c ssl_key_file=/etc/postgres-tls/tls.key`, so Postgres serves TLS. Server
    `ssl=on` still **accepts** non-TLS `host` connections, so flipping the server
    gate alone does NOT break consumers that have not yet set `sslmode`; tighten the
    consumer URLs to `?sslMode=require` (R2DBC) / `sslmode=require` (JDBC) and
    `pg_hba` to `hostssl` as a follow-up once every consumer negotiates TLS.

  **GATE / enablement (the documented "PR-C2" step):** flip `PG_TLS_ENABLED` to
  `"true"` in the DB Deployment (config-only — no new cert plumbing) ONLY after the
  Vault-PKI server-cert ESO Secret `<db>-mtls` is provisioned/materialized per DB.
  Until then it stays off; the DBs are single-node, same-namespace, and already
  MCS+NetworkPolicy-confined, so the default-off posture is safe. **The per-DB
  procedure, the order, the preflight (`scripts/pg-tls-preflight.sh`, which refuses
  the flip while `<db>-mtls` is missing or unusable) and the rollback are in
  `docs/DB-HARDENING-RUNBOOK.md`.** The flip is a git change and a Recreate rollout:
  with the Secret absent it takes the DB down, because the volume is `optional: true`. **Out of scope**
  (no dark-TLS cert mounted — would need new ESO certs first): casdoor/casdoor-games
  Postgres, akkoma-db, the phpBB forum Postgres, observability Postgres.

  **fsGroup / cert readability (live-verify fix):** a live container verify proved
  that with `PG_TLS_ENABLED=true` the pod crash-loops because the `<db>-mtls` Secret
  mounts root-owned `defaultMode: 0600` and postgres (uid 70) cannot read the key.
  Each TLS-enabled DB pod therefore sets pod-level `securityContext.fsGroup: 70`
  (the postgres group) alongside its `seLinuxOptions`, so the mounted cert/key are
  group-readable by postgres. `fsGroup: 70` is **harmless while ssl is off** and
  makes the future flip pure-config.


---

## (C) Opt-in Citus sharding (default OFF — single-node unchanged)

Sharding is provided at the **deployment/topology layer**, never by forcing
Postgres-only DDL into the apps' shared Liquibase changelogs (those stay
H2/Postgres-compatible for the test slices). It is **opt-in** and **off by
default**, so the plain single-node path is byte-for-byte unchanged.

### How to enable

Per DB you want to shard:

1. Override the Deployment `image` to a **Citus-enabled Postgres**
   (`citusdata/citus:12-pg16` — wire-compatible with PG16, ships the `citus`
   extension), and
2. set `SHARDING_CITUS=on` in the pod env.

With the default `postgres:16-alpine` image and `SHARDING_CITUS` unset/`off`, the
`90-citus.sh` hook exits immediately — nothing changes.

### Shard keys

| Table (DB) | Shard key | Distribution | Note |
|------------|-----------|--------------|------|
| `user_profile` (user-bff) | `user_id` | hash — **clean** | PK already **is** `user_id` |
| `user_preference` (user-bff) | `user_id` | hash, co-located with `user_profile` | per-user joins stay local |
| `user_block` (user-bff) | `user_id` | hash | **needs PK widened to `(id, user_id)`** (deferred app change) |
| `federation_modules` (federation) | `owner_user_id` | hash | **needs PK widened to include `owner_user_id`** (deferred) |
| `user_modules` (federation) | `owner_user_id` | hash | **needs PK widened to include `owner_user_id`** (deferred) |
| `gateway_route_access` (route-access / admin-bff) | `gateway` | **reference table** (replicated) | low cardinality + low write; replicate so every node reads locally |
| `mod_action` (mod-bff) | actor/subject id | hash | append log; distribute once PK includes the key (deferred) |

### Honest constraint (why distribution is a post-migration step)

Citus requires the **distribution column to be a member of every `UNIQUE`/`PRIMARY
KEY` constraint** on the table. Several tables PK on a surrogate `id` (`bigint`
identity or `uuid`) that is **not** the natural shard key:

- `user_profile` distributes cleanly **today** (its PK is `user_id`).
- `federation_modules`, `user_modules`, `user_block`, `mod_action` would need their
  PK/unique widened to include the shard key first. Doing that in the shared
  Liquibase changelog is an **app-side change** that we deliberately **defer** to
  keep the H2/Postgres-compat test slices untouched. Until then, those tables can
  run as Citus **reference tables** (replicated) if you need a multi-node cluster
  immediately.

Because the tables are created by Liquibase **after** initdb, `90-citus.sh` only
`CREATE EXTENSION citus` at first start; the actual `create_distributed_table(...)`
calls are emitted as a documented **one-shot post-migration step** (run them from a
`psql`/Job after the app's first boot). Each DB's `90-citus.sh` prints the exact
statements for that DB.

### Scaling to Citus workers

1. Deploy a Citus **coordinator** (the existing DB pod on the Citus image) and one
   or more **worker** StatefulSet pods (same Citus image).
2. Register workers on the coordinator: `SELECT citus_add_node('worker-0', 5432);`
   (repeat per worker).
3. Run the `create_distributed_table(...)` / `create_reference_table(...)` calls
   from `90-citus.sh` once; Citus rebalances shards across workers. Add capacity
   later with more `citus_add_node` + `SELECT rebalance_table_shards();`.

The single-node coordinator-only mode is fully functional, so you can enable Citus
first (coordinator only) and add workers when you actually need the horizontal
scale.

---

## Secret generation

`scripts/gen-cluster-secrets.sh` mints a **separate** `openssl rand` value for
every owner password, every non-owner app password, and every route-access
machine-user password, and delivers them BOTH to Vault (online) and the offline
USB bundle (`secrets.json`). The `secretstore.yaml` `ExternalSecret`s materialize
them into the per-namespace k8s Secrets the Deployments consume. No password is
ever committed to git — manifests carry only `secretKeyRef` / `$(VAR)` references.
