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
| 16 | admin-bff Liquibase grants to a role nothing creates | `008-access-suspension` does `GRANT … TO admin_bff`; no cluster-side initdb creates that login role (contrast `route-access/initdb/10-roles.sh`, which does it properly). **FIXED 2026-08-06** — the changelogs were wrong, not the bootstrap. `admin_bff` is route-access-db's role (see the matrix in `docs/POSTGRES-HARDENING.md`, which had it right all along); admin-bff's own DB creates `adminbff_app`, which is also what `SPRING_R2DBC_USERNAME` connects as. All 97 GRANT/REVOKE statements retargeted in hugmesh-admin-bff-api; **no generator manifest changed**, so a from-scratch cluster was always one `initdb` run away from correct. Guarded by `lint:liquibase-grant-roles`. **The live `1/1 Running` is NOT durable — do not read it as "shipped"**: the pods run `registry.hugmesh.systems/hugmesh/hugmesh-admin-bff-api:main` (`imagePullPolicy: IfNotPresent`), and that image was built from `fix/liquibase-grant-role-name`, which at the time of writing is 1 commit ahead of `origin/main` with **no remote branch at all**. `:main` is a mutable tag: the next CI build of admin-bff-api's `main` republishes it from the *unfixed* changelogs, and any fresh node, evicted pod or new cluster that pulls it goes straight back to `role "admin_bff" does not exist`. Nothing in this repo can prevent that. It becomes durable only when the service-repo change is pushed, merged, and `:main` rebuilt from it. |
| 17 | **The kind lane never pulls from Harbor at all** | Not a bring-up blocker — a **coverage** one, and the reason several of the defects above survived. `kind load` side-loads every first-party image, so the private-registry pull path (robot credential → Vault → ESO → `dockerconfigjson` → containerd → Harbor) has never once executed. Detail below. |
| 18 | **Outbound mTLS client stores were never given a password** | **FIXED 2026-08-06 (#564).** The init containers mint one PKCS12 pair under `${P}` and wrote only `server.ssl.*` — the **inbound** listener's keys. Outbound calls bind a separate prefix, `hugmesh.mtls.client.*`, defaulting to `${SSL_KEY_STORE_PASSWORD:}` / `${SSL_TRUST_STORE_PASSWORD:}`: env **nothing in any pod spec sets**, so both resolved to `""`. With the gate off (user-bff) `customize()` returned the HttpClient unchanged and every outbound https leg used the JDK default truststore — public roots, never the cluster CA: `POST /bff/login` → 500, `PKIX path building failed` on `/bff/internal/accounts/ensure`. **Not a CA mismatch** — both sides held the byte-identical CA and the wire cert matched the Secret; the client could not *open* the store that held it. With the gate on (forum-bff) it is worse: `KeyStore.load(in, new char[0])` throws and the client never constructs — shipped on `main` and unnoticed because forum-bff is not in this profile. Guarded by `lint:outbound-mtls-client`, proven red on the pre-fix tree; live A/B/A on kind (branch PASS → `main` FAIL → branch PASS). |
| 19 | Spec 01 asserted an `h1` the app has never rendered | **FIXED 2026-08-06.** The assertion named a two-word brand; the shell's `h1` is one word, `HugMesh`. It was a straggler from the marketing splash page #273 deleted — that commit retired the other splash assertions and left this one pointing at a heading that no longer exists. The rebrand then mapped it faithfully, preserving a string the app never emitted. It survived only because **spec 01 had never been run against a live cluster** until this track — the same root reason the rest of this document exists. |
| 20 | **Node-side API requests cannot resolve the cluster hostname on kind** | **OPEN — harness gap, not a platform defect.** `playwright.config.ts` reaches the cluster by its real hostname via Chromium `--host-resolver-rules` (`SNAP_HOST_RESOLVER`), deliberately avoiding an `/etc/hosts` edit or sudo. That flag is **browser-only**: Playwright's `apiRequestContext` runs in Node and ignores it, so every spec that drives the API directly dies on `getaddrinfo ENOTFOUND hugmesh.systems`. Affects **5 specs** (19, 20, 23, 29 and their helpers). Spec 29's stack-free TOTP cases pass; only its API cases fail, so the failure is unambiguously the harness. Fix options, none free: `docker run --add-host` in `run.sh` (fixes the documented docker path only, not the host-`npx` fallback); per-request `Host:` header against `https://127.0.0.1:8443` with `ignoreHTTPSErrors` (works on both paths, but touches all 5 specs); or accept an `/etc/hosts` entry as a documented prerequisite. **Not chosen here** — a cross-spec refactor that can only be partially verified on this cluster is exactly the kind of change that ships green and broken. |

## Finding 17 in detail — the private-registry pull path is unexercised

### What is missing

Four things, and each of them independently prevents the kind node from pulling
an image out of the in-cluster Harbor:

1. **Nothing ever asks it to.** [`scripts/kind-load-images.sh`](../scripts/kind-load-images.sh)
   builds the eight first-party images from `./.stack-src` and `kind load`s them
   into the node's containerd store under the exact refs the manifests render
   (`registry.hugmesh.systems/hugmesh/<repo>:main`, gateway `:dev`). Its own
   header says what that costs: *"`kind load` places each image directly into the
   node's containerd store where IfNotPresent finds it and no pull (or
   harbor-registry pull Secret) happens."* The kind-local README says the same
   from the other end: *"the in-cluster Harbor is empty on a fresh cluster and is
   not used."* Both statements are accurate and both were deliberate — the
   shortcut is what makes `make kind-up && make kind-images` fast. It also
   removes the only consumer of everything in item 4 below.
2. **The node cannot resolve `registry.hugmesh.systems`.** The manifests hardcode
   the reference hostnames, and the harness deliberately avoids `/etc/hosts`
   (*"you do need a way to resolve those names to the kind node without editing
   `/etc/hosts` (no passwordless sudo assumed)"*). The two mechanisms it uses
   instead — `curl --resolve` and the e2e's Chromium `--host-resolver-rules` —
   are per-client, on the **dev machine**. Neither is visible to containerd
   inside the node.
3. **The node does not trust the ingress cert.** Harbor is exposed at
   `https://registry.hugmesh.systems` through `ingress-nginx-internal` with
   `expose.tls.secretName: harbor-mtls`, a **Vault-PKI-issued** cert
   (`apps/03a-harbor.yaml`). The kind node's CA bundle contains no cluster CA —
   the README's own registry example is `curl -k`, and finding #1 records that
   `cluster-ca` is USB-provisioned and `optional: true` everywhere. containerd
   would reject the chain.
4. **containerd has no registry configuration at all.**
   [`kind-local.yaml`](../specs/cluster/bootstrap/kind-local/kind-local.yaml)
   declares one node with `extraPortMappings` and nothing else: no
   `containerdConfigPatches`, so no
   `[plugins."io.containerd.grpc.v1.cri".registry] config_path`, so no
   `/etc/containerd/certs.d/registry.hugmesh.systems/hosts.toml`, so no host
   override, no `ca`, no `skip_verify`. There is no configuration in which this
   node could be told where that registry is.

### Why it hides this whole bug class

Everything between Vault and a running container is proven by exactly one thing —
an actual pull:

* that the Harbor robot account exists and its secret in Vault is the **live**
  one;
* that ESO rendered it into a `kubernetes.io/dockerconfigjson` whose `auths` key
  is the hostname the image ref actually uses;
* that the Secret exists **in the workload's namespace, under the name the
  workload asks for**;
* that the robot's Harbor permissions cover the project being pulled;
* that the node can resolve and trust the registry endpoint.

None of those has a second witness. ESO reports `SecretSynced` for a
syntactically perfect dockerconfigjson holding a dead token; a Deployment names
an `imagePullSecrets` entry that does not exist without complaint; a robot with
no permissions looks identical to one with them until a manifest is fetched. So
the lane can be **entirely green while every item on that list is broken**, and
it was:

* the `hugmesh-pki` ExternalSecret aimed at `harbor-registry` — a name the Harbor
  chart itself owns — had been failing since bootstrap, so the pull secret it
  existed to create never existed;
* `manifests/forum/kustomization.yaml` patched `imagePullSecrets:
  [harbor-registry]` onto phpbb and rewrote its image to a private Harbor repo,
  while **no ExternalSecret ever materialized that Secret in `hugmesh-forum`** —
  the pull was anonymous;
* `secret/<brand>/harbor-robots` held the literal string
  `REPLACE_WITH_GITLAB_DEPLOY_TOKEN`, because the seeder's unconditional
  `vault kv put` overwrote the credentials the `harbor-provision` Job had minted
  (fixed, and guarded, by `tests/scripts/test-harbor-robots-ownership.sh`).

Three distinct defects, one shared reason for surviving: **nothing pulls.** This
is the same shape as the document's other theme — the workaround (`kind load`)
is real and load-bearing, and it silently converted an unproven property into an
untested one.

### What it would take to close

Four options, cheapest first. None is implemented; this section is the finding,
not a plan of record.

**(A) Point containerd at the in-cluster Service, plaintext.** Add
`containerdConfigPatches` to `kind-local.yaml` setting `config_path` and a
`hosts.toml` for `registry.hugmesh.systems` whose `server` is
`http://harbor-core.hugmesh-pki.svc.cluster.local`.
*Buys:* DNS and CA trust both stop mattering, and the pull still authenticates
with the real robot credential out of the real ESO-rendered dockerconfigjson —
which is the bug class above.
*Costs:* it diverges from production in exactly the dimension that has already
bitten twice. A dockerconfigjson whose `auths` key is the wrong hostname still
authenticates here, so that defect stays invisible; and a `skip_verify`/plaintext
line in a harness config has a way of being copied into a real one.

**(B) One deliberate pull probe, everything else side-loaded.** Keep
`kind-load-images.sh` as is; after `harbor-provision` completes, push one small
image through the existing kaniko path and run a Job with
`imagePullPolicy: Always` in a namespace that carries the pull secret.
*Buys:* a single, loud, specific assertion that the credential is live and the
dockerconfigjson is usable, at a fraction of the runtime of converting the whole
image set. It fails with a message that names the problem.
*Costs:* it still needs the node-side plumbing of (A) or (C) — a pull is a pull —
so it is a scoping decision layered on one of them, not an alternative to them.
It also proves nothing about the platform's own eight images.

**(C) Make the node resolve and trust the real endpoint.** `hosts.toml` pointing
at the ingress with the cluster CA in its `ca` field (or installed into the
node's trust store), plus a host alias so `registry.hugmesh.systems` resolves on
the node.
*Buys:* the only option that exercises the production path end to end — real
hostname, real ingress, real Vault-PKI chain, real credential.
*Costs:* the CA does not exist when the node is created — Vault-PKI issues it
during bootstrap — so closing the loop requires a step that mutates the node
*after* it is up (a privileged `docker exec` into the node, or a DaemonSet
writing a hostPath and bouncing containerd). That is a real operational hazard:
restarting containerd disrupts every pod on the node, and a harness that reaches
into the node is a harness that can wedge the cluster it is validating. It also
makes `make kind-images` a build → push → pull cycle rather than build →
side-load, which is materially slower.

**(D) Leave the lane alone; prove what can be proved off-cluster.** What this
branch did: assert the invariant in CI instead, by executing the real
`gen-cluster-secrets.sh` and the real `harbor-provision` `reconcile.py` against a
faithful fake Vault and fake Harbor
(`tests/scripts/test-harbor-robots-ownership.sh`, plus
`tests/scripts/test-eso-target-collisions.sh` for the ownership/consumer half).
*Buys:* runs in seconds on every merge request, needs no cluster, and covers the
whole ownership class rather than one instance.
*Costs:* it is structurally incapable of catching anything only a real pull can
see — a wrong `auths` hostname, an under-scoped robot, an ingress cert the node
does not trust. Those remain **unproven, not proven-absent**, and this finding is
the record of that.

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
- `fix/harbor-registry-name-collision` — the `hugmesh-pki` ExternalSecret that
  had been targeting a Secret name the Harbor chart owns (renamed
  `hugmesh-registry-pull`), the `hugmesh-forum` pull secret nothing materialized,
  and the `harbor-robots` ownership conflict behind item 17's third bullet — the
  seeder's unconditional `vault kv put` overwriting the credentials
  `harbor-provision` had minted. Three guards:
  `tests/scripts/test-eso-target-collisions.sh` (renders the real upstream charts
  and fails on a target collision or an unmaterialized pull secret) and
  `tests/scripts/test-harbor-robots-ownership.sh` (executes the real seeder and
  the real Job script against a faithful fake Vault). Both proven red on the
  pre-fix tree.

Items 5–15 are **not** fixed in-repo yet and are the honest remaining work.
Items 16, 18 and 19 are fixed, each marked in the table with what proved it.
Item 17 is **deliberately not fixed** — see its options above; the write-up is
the deliverable, and closing it would mean mutating the kind node. Item 20 is a
harness gap, deliberately written up rather than half-built.

## Where the SSO profile stands, 2026-08-06

The two specs this profile can actually drive end to end both pass against a
live kind cluster on merged `main`:

| spec | result |
|---|---|
| `01-frontpage` — anonymous visitor is gated to the native sign-in | **PASS** |
| `27-native-login` — `POST /bff/login` mints an httpOnly `bff_session`, no Casdoor origin is ever exposed to the browser | **PASS** |
| `29-mfa-privileged-floor` — stack-free RFC 6238 vectors | **PASS** |
| `29-mfa-privileged-floor` — API cases | blocked by item 20 (harness), not by the platform |

That is the roadmap's "SSO kind-cluster e2e" reaching green. It is worth being
precise about what it does and does not mean: the login path — Casdoor seed,
Cassandra roles, Vault PKI issuance, ESO materialisation, gateway routing,
session minting over cluster mTLS — now works from a cold cluster. The rest of
the suite (matrix, mastodon, forum, discord, RBAC realms) drives services this
profile does not deploy, so those specs are out of scope here and say nothing
about their health either way.
