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
| `route-access-db` | snapdragon-pki | `gateway` / `gateway` | admin-bff (W), pki/be/fe-gateway (R) | `gateway_route_access` |
| `federation-db` | snapdragon-backend | `federation` / `federation` | snapdragon-federation-api | `federation_modules`, `user_modules`, `moderation_requests`, `federation_override` |
| `admin-bff-db` | snapdragon-backend | `adminbff` / `adminbff` | snapdragon-admin-bff-api | `account`, `allowlist`, `bff_session`, `namespace_grant`, `iso_artifacts`, `gateway_route_access` |
| `mod-bff-db` | snapdragon-backend | `modbff` / `modbff` | snapdragon-mod-bff-api | `mod_action` |
| `user-bff-db` | snapdragon-backend | `userbff` / `userbff` | snapdragon-user-bff-api | `user_profile`, `user_preference`, `user_block` |
| `casdoor-pg` | snapdragon-pki | `casdoor` / `casdoor` | casdoor | (managed by Casdoor) |

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
| route-access-db | `admin_bff` | `SELECT,INSERT,UPDATE,DELETE` on `gateway_route_access` | snapdragon-admin-bff-api | `ROUTE_ACCESS_ADMIN_BFF_PASSWORD` | `route-access-admin-bff` | `route-access-db.admin_bff_password` |
| route-access-db | `pki_gateway` | `SELECT` on `gateway_route_access` | snapdragon-pki-gateway | `ROUTE_ACCESS_PKI_GATEWAY_PASSWORD` | `route-access-pki-gateway` | `route-access-db.pki_gateway_password` |
| route-access-db | `be_gateway` | `SELECT` on `gateway_route_access` | snapdragon-be-gateway | `ROUTE_ACCESS_BE_GATEWAY_PASSWORD` | `route-access-be-gateway` | `route-access-db.be_gateway_password` |
| route-access-db | `fe_gateway` | `SELECT` on `gateway_route_access` | snapdragon-fe-gateway | `ROUTE_ACCESS_FE_GATEWAY_PASSWORD` | `route-access-fe-gateway` | `route-access-db.fe_gateway_password` |
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
  writers/apps 10–20) and a server cap (`max_connections` 50–60).
- **Timeouts** — per-DB `statement_timeout=30s`,
  `idle_in_transaction_session_timeout=60s`, `lock_timeout=10s` so a stuck client
  can't pin a connection or hold locks.
- **Auditable logins** — `log_connections`, `log_disconnections`, and
  `log_min_duration_statement=2000` (slow-statement log) so an unexpected superuser
  login or runaway query is visible.
- **In-cluster TLS** — DB Services are ClusterIP-only and confined by SELinux MCS
  levels + NetworkPolicy. For wire encryption between an app and its DB, mount the
  Vault-PKI server cert and start Postgres with `-c ssl=on -c
  ssl_cert_file=… -c ssl_key_file=…`, then add `?sslMode=require` (R2DBC) /
  `sslmode=require` (JDBC) to the consumer URLs. This is **documented but not
  enabled by default** here because the DBs are single-node, same-namespace, and
  already MCS+NetworkPolicy-confined; it is the natural next step once the
  Vault-PKI server-cert ESO Secret is wired per DB (tracked as a deferral).

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
