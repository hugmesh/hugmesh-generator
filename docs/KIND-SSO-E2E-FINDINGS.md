# Kind SSO e2e — what the first real cluster run found

_2026-08-05. Produced by standing up `KIND_PROFILE=sso` (see
[`specs/cluster/bootstrap/kind-local/README.md`](../specs/cluster/bootstrap/kind-local/README.md))
and driving the native-login path end to end for the first time._

## Why this document exists

The roadmap item asked for one thing: run
[`tests/e2e/specs/27-native-login.spec.ts`](../tests/e2e/specs/27-native-login.spec.ts)
against a **kind cluster**, not just the compose stack. Building the harness was
the easy half. The hard half is the finding below, and it is the actual value of
the exercise:

> **The GitOps cluster payload had never been run end to end.** Every defect
> listed here is a fresh-cluster blocker that no amount of compose testing could
> surface, because the compose stack works around each one *locally* and the
> workaround was never propagated to `specs/cluster`.

That pattern — *fixed in compose, never fixed in the cluster manifests* — is the
theme. `tests/stack/compose.local.yaml` even documents several of these in
comments, right next to the local fix.

Status of the e2e itself: **not green.** The chain now reaches Casdoor, mints a
real session against a real IdP, and fails downstream on cluster state. Each
blocker below was fixed live (imperatively) to reach the next one, which is how
the list was produced. The fixes belong in the repo; several already have
branches (see the bottom).

## Blockers, in the order a fresh cluster hits them

| # | Blocker | Effect on a fresh cluster |
|---|---|---|
| 1 | `cluster-ca` Secret is USB-provisioned and `optional: true` everywhere | `vault-tls-init` self-signs, `vault-pki-init` spins forever on `Error loading CA File: /ca/tls.crt`. Nothing ever times out loudly. |
| 2 | Nothing mounts the KV v2 engine at `secret/` | The ESO `ClusterSecretStore` contract (`keys-template/vault/README.md`) points at a mount that only exists if an operator ran `vault secrets enable` by hand. |
| 3 | `superadmin_gateway_password` never seeded (both delivery paths) | ESO fails the **whole** `route-access-db-roles` Secret → `route-access-db` never starts → `gateway_route_access` (the authorization source of truth) does not exist → every gateway silently falls back to its baked `CanonicalSeed`. |
| 4 | pki_int role `allowed_domains` omits the `<svc>.<ns>` SAN | Every generic-loop app's mTLS cert issuance 400s (`subject alternate name … not allowed by this role`). The `media-poisoner` and `harbor` roles hand-patch this exact form — it was hit twice and patched per-role instead of in the loop. |
| 5 | Gateways get **no** Cassandra credentials | `00-cassandra.yaml` takes the Bitnami chart default (password auth **on**); the gateway chart passes none. `cassandra-hardening` creates least-privilege roles (`fe_gw_cass`, …) that **nothing is wired to use**. |
| 6 | No cluster-side keyspace bootstrap | Compose has a `cassandra-init` creating `snapdragon_gateway` / `snapdragon_federation`; the cluster payload has no equivalent, and `schema-action: CREATE_IF_NOT_EXISTS` creates tables, never keyspaces. |
| 7 | **Gateway probes hit a role-gated endpoint** | `/actuator/health/{liveness,readiness}` is gated by the gateway's own `SecurityConfig` (INFRA_PATHS), so an unauthenticated kubelet probe **always** gets 401 → readiness never passes → liveness kills a perfectly healthy pod. Compose documents this exact behaviour and accepts 401 in its healthcheck; the chart never got the fix. **No gateway can ever become Ready in k8s.** |
| 8 | Casdoor never imports the mounted `init_data.json` | Verified on a *completely fresh* database, correct path (`/init_data.json`, cwd `/`), valid JSON. No `hugmesh` organization is ever created. |
| 9 | …so the built-in admin keeps Casdoor's default password `123` | `init_data.json` is what sets it. **Security exposure:** the identity provider ships with a well-known credential wherever it is reachable, and the Vault-provisioned password is never applied. |
| 10 | `casdoor-init` never checks API responses | It prints `added app-user-bff` for every app while running **anonymous-denied** against Casdoor. A totally failed run is indistinguishable from a successful one — which is why 8/9 went unnoticed. |
| 11 | `CASDOOR_ORG` unset in the cluster manifest | user-bff uses its stale default org `snapdragon` → `The user: snapdragon/e2e-user doesn't exist`. Compose sets it, with a comment explaining precisely this. |
| 12 | OIDC `client-id` mismatch | user-bff defaults to `user-bff`; `casdoor-init` registers `app-user-bff` → `Invalid client_id`. |
| 13 | `APP_BFF_OIDC_REDIRECT_URI` default is pre-rebrand | Defaults to `https://snapdragon.systems/login/callback`; Casdoor registers `https://hugmesh.systems/login/callback`. Unset in the cluster manifest. |
| 14 | Pre-rebrand namespace defaults across the BFFs | user-bff resolves `casdoor.snapdragon-pki…` and `snapdragon-admin-bff-api.snapdragon-backend…` (NXDOMAIN). Counted on `origin/main`: **user-bff 16, admin-bff 22, mod-bff 9, federation 3, forum 3, wiki 2** stale refs; the generator overrides none of them. |
| 15 | `SVC_PASSWORD` hard-required, never provided | admin-bff fails bean creation (`Could not resolve placeholder 'SVC_PASSWORD'`). Compose sets it; the cluster manifest does not. |
| 16 | admin-bff Liquibase grants to a role nothing creates | `008-access-suspension` does `GRANT … TO admin_bff`; no cluster-side initdb creates that login role (contrast `route-access/initdb/10-roles.sh`, which does it properly). |

## Two systemic observations

**Silent failure is the common factor.** Almost every item above fails *quietly*:
ESO marks one Secret `SecretSyncedError` among 87; a probe returns 401 forever;
`casdoor-init` prints success; a gateway falls back to a baked seed instead of
erroring. Adding the fixes without adding the guards would leave the same class
free to return — which is why the two branches below ship a contract test each,
both proven red on the pre-fix tree.

**Compose is not evidence for the cluster.** Every workaround exists in
`tests/stack/compose.local.yaml`, usually with a comment describing the bug.
Compose green has been treated as proof the platform works; it proves the
*services* work, not the *payload*.

## What is fixed in-repo already

- `fix/cluster-secret-contract-drift` — seeds the missing properties and adds
  `tests/scripts/test-eso-seed-contract.sh`, which cross-checks **every**
  ExternalSecret reference against both delivery paths. It found **29**
  unsatisfiable references pre-fix, including `user-bff-hs-token`'s
  `svc-password` (same all-or-nothing shape, loses the custody key with it).
- `fix/pki-role-san-namespace` — fixes the role loop plus a matching-rules
  contract test.
- `feat/kind-sso-e2e` — this harness, plus items 1, 2 and the node role label.

Items 5–16 are **not** fixed in-repo yet and are the honest remaining work.
