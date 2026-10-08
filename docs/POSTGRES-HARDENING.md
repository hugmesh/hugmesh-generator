# Postgres hardening, per-machine-user roles, and opt-in Citus sharding

This document covers the Postgres posture for the application/RBAC databases:

- **(A)** per-machine-user **least-privilege roles** with their **own credentials**
  (no shared owner credential at runtime),
- **(B)** general **Postgres hardening**, and
- **(C)** an **opt-in, sharding-capable** (Citus) deployment topology. It leaves the
  default single-node path unchanged and the apps' H2/Postgres-compat test slices
  untouched.

The databases in scope (each its own pod and PVC, ClusterIP-only):

| DB | Namespace | Owner role / DB | Consumer(s) | Tables (examples) |
|----|-----------|-----------------|-------------|--------|
| `route-access-db` | hugmesh-pki | `gateway` / `gateway` | admin-bff (W), pki/be/fe/superadmin-gateway (R) | `gateway_route_access` |
| `federation-db` | hugmesh-backend | `federation` / `federation` | hugmesh-federation-api | `federation_modules`, `user_modules`, `moderation_requests`, `federation_override` |
| `admin-bff-db` | hugmesh-backend | `adminbff` / `adminbff` | hugmesh-admin-bff-api | `account`, `allowlist`, `bff_session`, `namespace_grant`, `iso_artifacts`, `gateway_route_access` |
| `mod-bff-db` | hugmesh-backend | `modbff` / `modbff` | hugmesh-mod-bff-api | `mod_action` |
| `user-bff-db` | hugmesh-backend | `userbff` / `userbff` | hugmesh-user-bff-api | `user_profile`, `user_preference`, `user_block` |
| `forum-bff-db` | hugmesh-backend | `forumbff` / `forumbff` | hugmesh-forum-bff-api | (Liquibase-managed) |
| `wiki-bff-db` | hugmesh-backend | `wikibff` / `wikibff` | hugmesh-wiki-bff-api | (Liquibase-managed) |
| `mesh-bff-db` | hugmesh-backend | `meshbff` / `meshbff` | hugmesh-mesh-bff-api | (Liquibase-managed) |
| `character-forge-bff-db` | hugmesh-backend | `charforgebff` / `charforgebff` | hugmesh-character-forge-bff-api | (Liquibase-managed) |
| `casdoor-pg` | hugmesh-pki | `casdoor` / `casdoor` | casdoor | (managed by Casdoor) |

`casdoor-pg` already takes its single `casdoor` user from the ESO `casdoor-db`
Secret and is Casdoor-managed, so it is left as is. There is no simple
least-privilege split, because Casdoor owns and migrates its own schema with that
one role.

---

## (A) Per-machine-user roles + own credentials + least privilege

### Principle

Every DB still has an **owner role** (`POSTGRES_USER`), but at **runtime** no
consumer logs in as the owner. Each consuming machine user gets:

- its **own non-owner login role** (`NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT`),
- its **own password** (a separate `openssl rand` value, kept in Vault and the
  offline bundle, never committed), delivered as its **own ESO `ExternalSecret`**, and
- **only the privileges it needs**: DML on its tables, no DDL.

The owner role is kept **only** for DDL and Liquibase. The single-consumer apps run
their changelog at boot with the owner credential. For `route-access-db`, the owner
is the table owner that the admin-bff's DDL path uses.

### Role / grant / credential matrix

| DB | Login role | Privileges | Used by (Deployment) | DB-pod env | ESO Secret (consumer) | Vault key |
|----|-----------|-----------|----------------------|------------|-----------------------|-----------|
| route-access-db | `gateway` (owner) | DDL/owner | — (DDL only) | `POSTGRES_PASSWORD` | `route-access-db-roles` | `route-access-db.owner_password` |
| route-access-db | `admin_bff` | `SELECT,INSERT,UPDATE,DELETE` on `gateway_route_access` | hugmesh-admin-bff-api | `ROUTE_ACCESS_ADMIN_BFF_PASSWORD` | `route-access-admin-bff` | `route-access-db.admin_bff_password` |
| route-access-db | `pki_gateway` | `SELECT` on `gateway_route_access` | hugmesh-pki-gateway | `ROUTE_ACCESS_PKI_GATEWAY_PASSWORD` | `route-access-pki-gateway` | `route-access-db.pki_gateway_password` |
| route-access-db | `be_gateway` | `SELECT` on `gateway_route_access` | hugmesh-be-gateway | `ROUTE_ACCESS_BE_GATEWAY_PASSWORD` | `route-access-be-gateway` | `route-access-db.be_gateway_password` |
| route-access-db | `fe_gateway` | `SELECT` on `gateway_route_access` | hugmesh-fe-gateway | `ROUTE_ACCESS_FE_GATEWAY_PASSWORD` | `route-access-fe-gateway` | `route-access-db.fe_gateway_password` |
| route-access-db | `superadmin_gateway` | `SELECT` on `gateway_route_access` | hugmesh-superadmin-gateway | `ROUTE_ACCESS_SUPERADMIN_GATEWAY_PASSWORD` | `route-access-superadmin-gateway` | `route-access-db.superadmin_gateway_password` |
| federation-db | `federation` (owner) | DDL/owner (Liquibase) | federation-api (Liquibase) | `POSTGRES_PASSWORD` | `federation-db-auth` | `federation-db.password` |
| federation-db | `federation_app` | DML on all tables + USAGE on schema/sequences | federation-api (R2DBC runtime) | `FEDERATION_APP_PASSWORD` | `federation-db-app-auth` | `federation-db.app_password` |
| admin-bff-db | `adminbff` (owner) | DDL/owner (Liquibase) | admin-bff (Liquibase) | `POSTGRES_PASSWORD` | `admin-bff-db-auth` | `admin-bff-db.password` |
| admin-bff-db | `adminbff_app` | DML on all tables + USAGE | admin-bff (R2DBC runtime) | `ADMINBFF_APP_PASSWORD` | `admin-bff-db-app-auth` | `admin-bff-db.app_password` |
| mod-bff-db | `modbff` (owner) | DDL/owner (Liquibase) | mod-bff (Liquibase) | `POSTGRES_PASSWORD` | `mod-bff-db-auth` | `mod-bff-db.password` |
| mod-bff-db | `modbff_app` | DML on all tables + USAGE | mod-bff (R2DBC runtime) | `MODBFF_APP_PASSWORD` | `mod-bff-db-app-auth` | `mod-bff-db.app_password` |
| user-bff-db | `userbff` (owner) | DDL/owner (Liquibase) | user-bff (Liquibase) | `POSTGRES_PASSWORD` | `user-bff-db-auth` | `user-bff-db.password` |
| user-bff-db | `userbff_app` | DML on all tables + USAGE | user-bff (R2DBC runtime) | `USERBFF_APP_PASSWORD` | `user-bff-db-app-auth` | `user-bff-db.app_password` |
| forum-bff-db | `forumbff` (owner) | DDL/owner (Liquibase) | forum-bff (Liquibase) | `POSTGRES_PASSWORD` | `forum-bff-db-auth` | `forum-bff-db.password` |
| forum-bff-db | `forumbff_app` | DML on all tables + USAGE | forum-bff (R2DBC runtime) | `FORUMBFF_APP_PASSWORD` | `forum-bff-db-app-auth` | `forum-bff-db.app_password` |
| wiki-bff-db | `wikibff` (owner) | DDL/owner (Liquibase) | wiki-bff (Liquibase) | `POSTGRES_PASSWORD` | `wiki-bff-db-auth` | `wiki-bff-db.password` |
| wiki-bff-db | `wikibff_app` | DML on all tables + USAGE | wiki-bff (R2DBC runtime) | `WIKIBFF_APP_PASSWORD` | `wiki-bff-db-app-auth` | `wiki-bff-db.app_password` |
| mesh-bff-db | `meshbff` (owner) | DDL/owner (Liquibase) | mesh-bff (Liquibase) | `POSTGRES_PASSWORD` | `mesh-bff-db-auth` | `mesh-bff-db.password` |
| mesh-bff-db | `meshbff_app` | DML on all tables + USAGE | mesh-bff (R2DBC runtime) | `MESHBFF_APP_PASSWORD` | `mesh-bff-db-app-auth` | `mesh-bff-db.app_password` |
| character-forge-bff-db | `charforgebff` (owner) | DDL/owner (Liquibase) | character-forge-bff (Liquibase) | `POSTGRES_PASSWORD` | `character-forge-bff-db-auth` | `character-forge-bff-db.password` |
| character-forge-bff-db | `charforgebff_app` | DML on all tables + USAGE | character-forge-bff (R2DBC runtime) | `CHARFORGEBFF_APP_PASSWORD` | `character-forge-bff-db-app-auth` | `character-forge-bff-db.app_password` |

The DB pod and its consumer reference the **same Vault property**, so the role and
its credential stay in sync.

### How the non-owner role gets DML on Liquibase-managed tables

The single-consumer DBs (federation, admin-bff, mod-bff, user-bff, forum-bff,
wiki-bff, mesh-bff, character-forge-bff) create their tables through **Liquibase at
app boot**, *after* Postgres initdb. The app role's table grants therefore cannot be
plain `GRANT ... ON <table>` statements at initdb time, because the tables do not
exist yet. Instead `initdb/10-roles.sh` uses **`ALTER DEFAULT PRIVILEGES FOR ROLE
<owner>`**. Every table and sequence the owner later creates then grants DML to the
app role automatically. No per-migration grant edits are needed, and the shared
Liquibase changelogs the apps run are **never modified**, so the H2 test slices are
unaffected.

`route-access-db` is different. Its table is seeded by `initdb/20-schema.sql` (the
gateways do not migrate), so the grants are explicit. They are guarded on role
existence so the same file can be reused in the local dev stack.

#### admin-bff is the one service whose changelogs also GRANT explicitly

Every other BFF relies only on the `ALTER DEFAULT PRIVILEGES` mechanism above and
carries **no SQL `GRANT` at all**. hugmesh-admin-bff-api additionally issues
per-table `GRANT`s from its own changelogs (dozens of `GRANT … TO adminbff_app`
statements spread over its `src/main/resources/db/changelog` files). These are
belt-and-braces, because the default privileges already cover every table Liquibase
creates. But they are **not free**: a `GRANT` to a role that does not exist is a
hard error that aborts the migration, and the pod never starts.

That is what happened on 2026-08-06. All 97 statements named `admin_bff`, which is
**route-access-db's** role (a row of the matrix above), not a role of admin-bff's own
database. The matrix was right. The changelogs had copied a name across a datasource
boundary. They now target `adminbff_app`.

Three rules follow, and `lint:liquibase-grant-roles`
(`tests/scripts/test-liquibase-grant-roles.sh`) enforces them across **all** services:

1. **`[created]`** — a changelog may only `GRANT` to a role that *that service's own*
   `initdb` creates. Role names are not portable between databases.
2. **`[connects]`** — the grantee must be a role something actually **logs in as** on
   that datasource (`SPRING_LIQUIBASE_USER` / `SPRING_R2DBC_USERNAME`). Making the
   name resolve is not enough: adding a `CREATE ROLE` for whatever name the changelog
   happens to use un-wedges startup, but the privileges then land on a role with no
   sessions. That is the trap this bug set. Compose and both Testcontainers
   harnesses each created `admin_bff` from the *changelog's* name so the statement
   would resolve, which is why every environment except the cluster was green.
3. **`[compose]`** — `tests/stack/compose.local.yaml` is read too, and held to the
   same matrix. A role its one-shot `*-db-init` shims `CREATE` must be one the
   *cluster* bootstrap for that Postgres creates, and every role the changelogs
   grant to must exist in compose as well. Without this rule, rules 1 and 2 could
   pass while the local stack quietly invented a third name, which is the shape of
   the original failure.

   `[compose]` deliberately does **not** require compose to connect as the same role
   the cluster does. The local stack connects each app as the database **owner**
   (`adminbff`, `gateway`, …) and not as the least-privilege `*_app` role, because
   the per-user passwords come from ESO and do not exist locally. So compose proves
   that the role *names* agree and that the migration runs. It cannot prove that a
   privilege is enough for the restricted role. Only the cluster, or a
   Testcontainers run that logs in as `adminbff_app`, can.

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
`ROUTE_ACCESS_R2DBC_URL`. It has **no** separate username or password env. To give
each gateway its own least-privilege identity **without changing the gateway repo**
(and without breaking its H2 test slices), each gateway Deployment now:

1. mounts its own password as `ROUTE_ACCESS_DB_PASSWORD` (`secretKeyRef` to its own
   per-namespace ESO Secret), and
2. sets `ROUTE_ACCESS_R2DBC_URL` to
   `r2dbc:postgresql://<role>:$(ROUTE_ACCESS_DB_PASSWORD)@route-access-db…/gateway`.
   **Kubernetes `$(VAR)` env interpolation** injects the secret into the URL at pod
   start. The admin-bff's `ROUTE_ACCESS_R2DBC_URL` does the same with the
   `admin_bff` writer role.

The password never appears in git or in the rendered manifest literal. Only the
`$(VAR)` reference does.

---

## (B) Postgres hardening applied

Applied through each DB Deployment's `POSTGRES_*` env and container `args`, and
through `initdb/00-hardening.sql`:

- **scram-sha-256 everywhere** — `POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256
  --auth-local=scram-sha-256` (governs `pg_hba` method selection, so there is **no
  `trust`** for host or local), plus `password_encryption=scram-sha-256` both as an
  `ALTER SYSTEM` (00-hardening.sql) and as a runtime `-c` flag (defence in depth).
- **No `trust` in `pg_hba`** — the alpine image's generated `pg_hba.conf` uses the
  scram method from the initdb flags for every host and local line. Together with
  `REVOKE … FROM PUBLIC` (CONNECT + schema), a new role can do nothing until it is
  explicitly granted something.
- **`REVOKE ALL ON SCHEMA public FROM PUBLIC`** and `REVOKE ALL ON DATABASE …
  FROM PUBLIC` — every privilege is explicit. App roles get `USAGE` (never
  `CREATE`) on `public`.
- **No superuser for app roles** — every login role is
  `NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT`.
- **Per-role connection limits** — `CONNECTION LIMIT` per role (gateways 5,
  writers/apps 10–20) and a server cap (`max_connections` 50–60). The limit of 20
  on a BFF's app role is a budget for EVERY pod that connects as that role. Each
  BFF Deployment sets `SPRING_R2DBC_POOL_INITIAL_SIZE=1` and
  `SPRING_R2DBC_POOL_MAX_SIZE=2`, so that (the autoscaler's `maxReplicas` plus the
  pods a rolling update adds) x pool stays within it (hugmesh-generator#663: with
  the unset default of 10 per pod, six pods asked for 60 and the sign-in answered
  500). `tests/scripts/test-db-connection-budget.sh` fails when it does not.
- **Timeouts** — per-DB `statement_timeout=30s`,
  `idle_in_transaction_session_timeout=60s` and `lock_timeout=10s`, so a stuck
  client cannot pin a connection or hold locks.
- **Auditable logins** — `log_connections`, `log_disconnections`, and
  `log_min_duration_statement=2000` (slow-statement log), so an unexpected superuser
  login or runaway query is visible.
- **Per-port DB ingress NetworkPolicies** (✅ DONE, ADR-32) —
  `manifests/networkpolicy/db-ingress.yaml` adds a default-deny-except Ingress per
  DB pod that admits ONLY each store's real clients on its real port. It covers
  the nine dedicated Postgres pods (`route-access-db`, `admin-bff-db`, `mod-bff-db`,
  `user-bff-db`, `federation-db`, `forum-bff-db`, `mesh-bff-db`,
  `character-forge-bff-db`, `wiki-bff-db`) and `casdoor-pg` / `casdoor-games-pg` on
  `:5432`, and `cassandra` on `:9042`. Peers are pinned by namespaceSelector AND
  podSelector. The file is listed in `manifests/networkpolicy/kustomization.yaml`,
  which the **auto-synced** `apps/08-networkpolicy.yaml` Application (prune +
  selfHeal) applies, so the policies are live. (The header comment of
  `db-ingress.yaml` still says "MANUAL-sync / ships dark"; it predates the
  auto-sync.) They are ingress-only, so a missed allow restores connectivity on
  removal. A separate, dark `manifests/networkpolicy/db-egress.yaml` locks DNS-only
  egress on the six Postgres pods that `tier-egress.yaml` excludes. It is enabled
  only through the manual `apps/08a-networkpolicy-egress.yaml` overlay.
- **Per-DB Vault-PKI server certs** (✅ DONE, ships dark, ADR-32) — each dedicated
  Postgres DB gets a Vault-PKI server cert on disk through the existing Vault-PKI +
  ESO pattern. `pki-externalsecrets.yaml` issues a per-DB `VaultDynamicSecret`
  (`pki_int/issue/<db>`) into a `kubernetes.io/tls` Secret `<db>-mtls`, mounted
  read-only at `/etc/postgres-tls` (`optional: true`, so the pod still starts before
  ESO). Postgres is **NOT** started with `ssl=on` and no consumer URL sets
  `sslMode`, so the **default wire path stays byte-identical** (cert present but
  unused).
- **In-cluster TLS — gated, ships dark (`PG_TLS_ENABLED`, default `false`).** DB
  Services are ClusterIP-only and confined by SELinux MCS levels and NetworkPolicy.
  Wire encryption between an app and its DB is **wired but inert**. Each of the nine
  DB pods (admin-bff-db, mod-bff-db, user-bff-db, federation-db, forum-bff-db,
  route-access-db, mesh-bff-db, wiki-bff-db, character-forge-bff-db) mounts its
  Vault-PKI server cert read-only at `/etc/postgres-tls` AND boots through a small
  init wrapper, `entrypoint/pg-tls-entrypoint.sh` (a SEPARATE ConfigMap, not in the
  initdb dir), which follows the egress-proxy entrypoint idiom:
  - `PG_TLS_ENABLED=false` (DEFAULT): the wrapper runs Postgres with the SAME static
    server args as before, with **no `-c ssl=on`**. The cert is unused and the wire
    path is **byte-identical** to the pre-TLS deployment.
  - `PG_TLS_ENABLED=true`: the wrapper appends
    `-c ssl=on -c ssl_cert_file=/etc/postgres-tls/tls.crt
    -c ssl_key_file=/etc/postgres-tls/tls.key`, so Postgres serves TLS. Server
    `ssl=on` still **accepts** non-TLS `host` connections, so flipping the server
    gate alone does NOT break consumers that have not yet set `sslmode`. As a
    follow-up, once every consumer negotiates TLS, tighten the consumer URLs to
    `?sslMode=require` (R2DBC) / `sslmode=require` (JDBC) and `pg_hba` to `hostssl`.

  **Gate / enablement (the documented "PR-C2" step):** flip `PG_TLS_ENABLED` to
  `"true"` in the DB Deployment (config-only, no new cert plumbing) ONLY after the
  Vault-PKI server-cert ESO Secret `<db>-mtls` is provisioned and materialized for
  that DB. Until then it stays off. The DBs are single-node, same-namespace and
  already MCS + NetworkPolicy confined, so the default-off posture is safe.
  **Out of scope** (no dark-TLS cert mounted; they would need new ESO certs first):
  casdoor, casdoor-games and casdoor-domain Postgres, akkoma-db, the phpBB forum
  Postgres, the Headwind Postgres, observability Postgres.

  **fsGroup / cert readability (live-verify fix):** a live container verify proved
  that with `PG_TLS_ENABLED=true` the pod crash-loops, because the `<db>-mtls`
  Secret mounts root-owned with `defaultMode: 0600` and postgres (uid 70) cannot read
  the key. Each TLS-enabled DB pod therefore sets pod-level `securityContext.fsGroup:
  70` (the postgres group) next to its `seLinuxOptions`, so the mounted cert and key
  are group-readable by postgres. `fsGroup: 70` is **harmless while ssl is off** and
  makes the future flip pure config.

---

## (C) Opt-in Citus sharding (default OFF — single-node unchanged)

Sharding is provided at the **deployment/topology layer**. It never forces
Postgres-only DDL into the apps' shared Liquibase changelogs (those stay
H2/Postgres-compatible for the test slices). It is **opt-in** and **off by default**,
so the plain single-node path is byte-for-byte unchanged.

### How to enable

Per DB you want to shard:

1. Override the Deployment `image` to a **Citus-enabled Postgres**
   (`citusdata/citus:12-pg16`, wire-compatible with PG16, ships the `citus`
   extension), and
2. set `SHARDING_CITUS=on` in the pod env.

With the default `postgres:16-alpine` image and `SHARDING_CITUS` unset or `off`, the
`90-citus.sh` hook exits immediately and nothing changes.

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

admin-bff-db's `90-citus.sh` also makes `account`, `allowlist` and `namespace_grant`
reference tables.

### Honest constraint (why distribution is a post-migration step)

Citus requires the **distribution column to be a member of every `UNIQUE`/`PRIMARY
KEY` constraint** on the table. Several tables use a surrogate `id` (`bigint`
identity or `uuid`) as the PK, and `id` is **not** the natural shard key:

- `user_profile` distributes cleanly **today** (its PK is `user_id`).
- `federation_modules`, `user_modules`, `user_block` and `mod_action` would first need
  their PK or unique constraint widened to include the shard key. Doing that in the
  shared Liquibase changelog is an **app-side change** that we deliberately **defer**,
  to keep the H2/Postgres-compat test slices untouched. Until then, those tables can
  run as Citus **reference tables** (replicated) if you need a multi-node cluster
  immediately.

The tables are created by Liquibase **after** initdb, so `90-citus.sh` only runs
`CREATE EXTENSION citus` at first start. The actual `create_distributed_table(...)`
calls are a documented **one-shot post-migration step**: run them from a `psql` or a
Job after the app's first boot. Each DB's `90-citus.sh` carries the exact statements
for that DB.

### Scaling to Citus workers

1. Deploy a Citus **coordinator** (the existing DB pod on the Citus image) and one
   or more **worker** StatefulSet pods (same Citus image).
2. Register workers on the coordinator: `SELECT citus_add_node('worker-0', 5432);`
   (repeat per worker).
3. Run the `create_distributed_table(...)` / `create_reference_table(...)` calls
   from `90-citus.sh` once. Citus rebalances shards across workers. Add capacity
   later with more `citus_add_node` calls and `SELECT rebalance_table_shards();`.

The single-node coordinator-only mode is fully functional, so you can enable Citus
first (coordinator only) and add workers when you need the horizontal scale.

---

## Secret generation

`scripts/gen-cluster-secrets.sh` mints a **separate** `openssl rand` value for every
owner password, every non-owner app password, and every route-access machine-user
password. It delivers them BOTH to Vault (online) and to the offline USB bundle
(`secrets.json`). The `secretstore.yaml` `ExternalSecret`s materialize them into the
per-namespace k8s Secrets the Deployments consume. No password is ever committed to
git. Manifests carry only `secretKeyRef` / `$(VAR)` references.
