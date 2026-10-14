# Kind SSO e2e — what the first real cluster run found

_2026-08-05. Produced by standing up `KIND_PROFILE=sso` (see
[`specs/cluster/bootstrap/kind-local/README.md`](../specs/cluster/bootstrap/kind-local/README.md))
and driving the native-login path end to end for the first time._

## Why this document exists

The roadmap asked for one thing: run
[`tests/e2e/specs/27-native-login.spec.ts`](../tests/e2e/specs/27-native-login.spec.ts)
against a **kind cluster**, not only the compose stack. The harness was the easy
part. The finding below is the real result:

> **Nobody had ever run the GitOps cluster payload end to end.** Every defect
> listed here blocks a fresh cluster. Compose testing could not show them:
> compose works around each one *locally*, and the workaround never reached
> `specs/cluster`.

The theme is *fixed in compose, never fixed in the cluster manifests*.
`tests/stack/compose.local.yaml` documents several of these in comments, next to
the local fix.

> ### Status of the e2e — read this line, not the narrative below
>
> **GREEN as of the 2026-08-06 run against a live kind cluster on merged
> `main`**, for the two specs this profile can actually drive: `01-frontpage`
> PASS and `27-native-login` PASS, plus `29-mfa-privileged-floor`'s stack-free
> RFC 6238 vectors. That run is tabulated in
> [Where the SSO profile stands, 2026-08-06](#where-the-sso-profile-stands-2026-08-06)
> at the end of this document, which is the single measured statement of record.
>
> Scope, stated so "green" cannot be over-read: `29-mfa-privileged-floor`'s API
> cases are blocked by harness item 20, not by the platform, and the rest of the
> suite (matrix, mastodon, forum, discord, RBAC realms) drives services this
> profile does not deploy — those specs are out of scope here and this result
> says nothing about them. **"the e2e is green" is not "the platform is finished"**.
>
> **Re-measured 2026-10-14:** blockers 1-16 hold on `main`, and #693 (item 27) is the
> next one: [see the last section](#re-measured-2026-10-14).
>
> **Item status on 2026-10-07 (`origin/main` @ `cbf5d9a6`).** Items 5-15 are
> fixed on `main` (#540-#544, #551, #552; marked in the table). Item 24 is fixed in
> the gateway source. Items 17, 25 and 26 are still open. Item 20 has a helper
> (`apiContext`, #569) that only spec 29 uses; specs 19, 20 and 23 still call
> Playwright's built-in `request` fixture. No kind e2e run after 2026-08-06 is
> recorded in this repo, so the green result above is dated, not re-measured.

**During the 2026-08-05 run this section narrates, the e2e was not green.** The
chain reached Casdoor and minted a real session against a real IdP. Then it
failed on cluster state. Each blocker below was fixed live, by hand, to reach
the next one. That is how the list was made. The fixes belong in the repo. Four
branches carried them (see the bottom; all four are merged).

> **Do not quote the previous paragraph as the current status.** It narrates the
> first run on 2026-08-05, and it stood unqualified for a month. On 2026-09-09
> two Iteration 1 lanes read this file and posted opposite headlines:
> `hugmesh-admin-bff-api#2` cited the 08-06 table and said green;
> `hugmesh-generator#47` cited this paragraph (as ":24") and said not green. The
> 08-06 table is newer and wins. See #332.

## Blockers, in the order a fresh cluster hits them

| # | Blocker | Effect on a fresh cluster |
|---|---|---|
| 1 | `cluster-ca` Secret is USB-provisioned and `optional: true` everywhere | **PARTLY FIXED (kind only).** The kind bootstrap now mints a throwaway local-dev `cluster-ca` (`bootstrap-kind.sh:607-633`); the manifests still mount it `optional: true` (`vault-pki/pki-init-job.yaml:69`). Real clusters are unchanged. `vault-tls-init` self-signs, `vault-pki-init` spins forever on `Error loading CA File: /ca/tls.crt`. Nothing ever times out loudly. |
| 2 | Nothing mounts the KV v2 engine at `secret/` | **FIXED for kind.** `bootstrap-kind.sh:1617` runs `vault secrets enable -path=secret -version=2 kv`. The ESO `ClusterSecretStore` contract (`keys-template/vault/README.md`) points at a mount that only exists if an operator ran `vault secrets enable` by hand. |
| 3 | `superadmin_gateway_password` never seeded (both delivery paths) | **FIXED (#534).** The property is referenced at `external-secrets/secretstore.yaml:965-966`, and `tests/scripts/test-eso-seed-contract.sh` now gates every reference. ESO fails the **whole** `route-access-db-roles` Secret → `route-access-db` never starts → `gateway_route_access` (the authorization source of truth) does not exist → every gateway silently falls back to its baked `CanonicalSeed`. |
| 4 | pki_int role `allowed_domains` omits the `<svc>.<ns>` SAN | **FIXED (#522, 2026-08-05).** The generic role loop sets `allowed_domains="${svc},${svc_ns},${svc_ns}.svc.cluster.local"` (`vault-pki/pki-init-configmap.yaml:194`). Every generic-loop app's mTLS cert issuance 400s (`subject alternate name … not allowed by this role`). The `media-poisoner` and `harbor` roles hand-patch this exact form — it was hit twice and patched per-role instead of in the loop. |
| 5 | Gateways get **no** Cassandra credentials | **FIXED 2026-08-06 (#541, #551).** The chart sets `SPRING_CASSANDRA_USERNAME` / `SPRING_CASSANDRA_PASSWORD` (`charts/hugmesh-gateway/templates/deployment.yaml:189-191`). `00-cassandra.yaml` takes the Bitnami chart default (password auth **on**); the gateway chart passes none. `cassandra-hardening` creates least-privilege roles (`fe_gw_cass`, …) that **nothing is wired to use**. |
| 6 | No cluster-side keyspace bootstrap | **FIXED 2026-08-06 (#541, #551).** `manifests/cassandra-init` and `apps/00b-cassandra-init.yaml` create the keyspaces, roles and grants; #551 added the Application to the kind `sso` profile. Compose has a `cassandra-init` creating `hugmesh_gateway` / `hugmesh_federation`; the cluster payload has no equivalent, and `schema-action: CREATE_IF_NOT_EXISTS` creates tables, never keyspaces. |
| 7 | **Gateway probes hit a role-gated endpoint** | **FIXED 2026-08-06 (#540).** The chart probes accept the 401 (`charts/hugmesh-gateway/templates/deployment.yaml:216-260`). The gateway image still gates `/actuator/**`; that was left as is. `/actuator/health/{liveness,readiness}` is gated by the gateway's own `SecurityConfig` (INFRA_PATHS), so an unauthenticated kubelet probe **always** gets 401 → readiness never passes → liveness kills a perfectly healthy pod. Compose documents this exact behaviour and accepts 401 in its healthcheck; the chart never got the fix. **No gateway can ever become Ready in k8s.** |
| 8 | Casdoor never imports the mounted `init_data.json` | **FIXED 2026-08-06 (#542, #552).** `app.conf` now sets `initDataFile` (`casdoor/app-conf-configmap.yaml:44-48`); #552 added the one application the import needs. Verified on a *completely fresh* database, correct path (`/init_data.json`, cwd `/`), valid JSON. No `hugmesh` organization is ever created. |
| 9 | …so the built-in admin keeps Casdoor's default password `123` | **FIXED 2026-08-06 (#542)** with item 8. `init_data.json` is what sets it. **Security exposure:** the identity provider ships with a well-known credential wherever it is reachable, and the Vault-provisioned password is never applied. |
| 10 | `casdoor-init` never checks API responses | **FIXED 2026-08-06 (#542).** The init Job now reads the response body, not just the HTTP status (`casdoor/init-job.yaml:14-22`). It prints `added app-user-bff` for every app while running **anonymous-denied** against Casdoor. A totally failed run is indistinguishable from a successful one — which is why 8/9 went unnoticed. |
| 11 | `CASDOOR_ORG` unset in the cluster manifest | **FIXED 2026-08-06 (#543, #544).** `CASDOOR_ORG` is `hugmesh` (`user-bff-api/deployment.yaml:168`). user-bff uses its stale pre-rebrand default org → `The user: <pre-rebrand-org>/e2e-user doesn't exist`. Compose sets it, with a comment explaining precisely this. |
| 12 | OIDC `client-id` mismatch | **FIXED 2026-08-06 (#543, #544).** `APP_BFF_OIDC_CLIENT_ID` is `app-user-bff` (`user-bff-api/deployment.yaml:496`). user-bff defaults to `user-bff`; `casdoor-init` registers `app-user-bff` → `Invalid client_id`. |
| 13 | `APP_BFF_OIDC_REDIRECT_URI` default is pre-rebrand | **FIXED 2026-08-06 (#543, #544).** `APP_BFF_OIDC_REDIRECT_URI` is `https://hugmesh.net/login/callback` (`user-bff-api/deployment.yaml:508`). Defaults to the stale pre-rebrand host; Casdoor registers `https://hugmesh.net/login/callback`. Unset in the cluster manifest. |
| 14 | Pre-rebrand namespace defaults across the BFFs | **FIXED 2026-08-06 (#543, #544).** The counts are the 2026-08-05 measurement. user-bff resolves `casdoor.hugmesh-pki…` and `hugmesh-admin-bff-api.hugmesh-backend…` (NXDOMAIN). Counted on `origin/main`: **user-bff 16, admin-bff 22, mod-bff 9, federation 3, forum 3, wiki 2** stale refs; the generator overrides none of them. |
| 15 | `SVC_PASSWORD` hard-required, never provided | **FIXED 2026-08-06 (#543, #544).** admin-bff's `SVC_PASSWORD` comes from the existing `user-bff-hs-token` / `svc-password` ExternalSecret (`admin-bff-api/deployment.yaml:769-773`). admin-bff fails bean creation (`Could not resolve placeholder 'SVC_PASSWORD'`). Compose sets it; the cluster manifest does not. |
| 16 | admin-bff Liquibase grants to a role nothing creates | `008-access-suspension` does `GRANT … TO admin_bff`; no cluster-side initdb creates that login role (contrast `route-access/initdb/10-roles.sh`, which does it properly). **FIXED 2026-08-06; the source fix is on `hugmesh-admin-bff-api` `main` (merged 2026-08-15 as `0cb9221`; on 2026-10-07, `src/main/resources` has 0 `TO admin_bff` and 169 `adminbff_app`).** The changelogs were wrong, not the bootstrap. `admin_bff` is route-access-db's role (see the matrix in `docs/POSTGRES-HARDENING.md`, which had it right all along); admin-bff's own DB creates `adminbff_app`, which is also what `SPRING_R2DBC_USERNAME` connects as. All 97 GRANT/REVOKE statements retargeted in hugmesh-admin-bff-api; **no generator manifest changed**, so a from-scratch cluster was always one `initdb` run away from correct. Guarded by `lint:liquibase-grant-roles`. **On 2026-08-06 the live `1/1 Running` was NOT durable — it must not be read as "shipped"**: the pods ran `registry.hugmesh.net/hugmesh/hugmesh-admin-bff-api:main` (`imagePullPolicy: IfNotPresent`), and that image was built from `fix/liquibase-grant-role-name`, which at the time of writing was 1 commit ahead of `origin/main` with **no remote branch at all**. `:main` is a mutable tag: the next CI build of admin-bff-api's `main` republishes it from the *unfixed* changelogs, and any fresh node, evicted pod or new cluster that pulls it goes straight back to `role "admin_bff" does not exist`. Nothing in this repo can prevent that. It became durable only when the service-repo change was pushed, merged, and `:main` rebuilt from it. The merge is verified above; whether the `:main` image a given cluster pulls was rebuilt after it is UNVERIFIED. |
| 17 | **The kind lane never pulls from Harbor at all** | **STILL OPEN on 2026-10-07:** `kind-local.yaml` has no `containerdConfigPatches`, and `scripts/kind-load-images.sh` still side-loads every image. Not a bring-up blocker — a **coverage** one, and the reason several of the defects above survived. `kind load` side-loads every first-party image, so the private-registry pull path (robot credential → Vault → ESO → `dockerconfigjson` → containerd → Harbor) has never once executed. Detail below. |
| 18 | **Outbound mTLS client stores were never given a password** | **FIXED 2026-08-06 (#564).** The init containers mint one PKCS12 pair under `${P}` and wrote only `server.ssl.*` — the **inbound** listener's keys. Outbound calls bind a separate prefix, `hugmesh.mtls.client.*`, defaulting to `${SSL_KEY_STORE_PASSWORD:}` / `${SSL_TRUST_STORE_PASSWORD:}`: env **nothing in any pod spec sets**, so both resolved to `""`. With the gate off (user-bff) `customize()` returned the HttpClient unchanged and every outbound https leg used the JDK default truststore — public roots, never the cluster CA: `POST /bff/login` → 500, `PKIX path building failed` on `/bff/internal/accounts/ensure`. **Not a CA mismatch** — both sides held the byte-identical CA and the wire cert matched the Secret; the client could not *open* the store that held it. With the gate on (forum-bff) it is worse: `KeyStore.load(in, new char[0])` throws and the client never constructs — shipped on `main` and unnoticed because forum-bff is not in this profile. Guarded by `lint:outbound-mtls-client`, proven red on the pre-fix tree; live A/B/A on kind (branch PASS → `main` FAIL → branch PASS). |
| 19 | Spec 01 asserted an `h1` the app has never rendered | **FIXED 2026-08-06.** The assertion named a two-word brand; the shell's `h1` is one word, `HugMesh`. It was a straggler from the marketing splash page #273 deleted — that commit retired the other splash assertions and left this one pointing at a heading that no longer exists. The rebrand then mapped it faithfully, preserving a string the app never emitted. It survived only because **spec 01 had never been run against a live cluster** until this track — the same root reason the rest of this document exists. |
| 20 | **Node-side API requests cannot resolve the cluster hostname on kind** | **PARTLY CLOSED — harness gap, not a platform defect.** #569 added `resolveForNode()` and `apiContext()` to `tests/e2e/specs/helpers.ts` (the Host-header option below); only spec 29 uses `apiContext` (9 call sites). `page.request` still cannot resolve on kind (the helper's own comment says so), and specs 19, 20 and 23 still use the built-in `request` fixture. No kind run since then is recorded, so whether spec 29's API cases now pass is UNVERIFIED. The 2026-08-05 write-up follows. `playwright.config.ts` reaches the cluster by its real hostname via Chromium `--host-resolver-rules` (`SNAP_HOST_RESOLVER`), deliberately avoiding an `/etc/hosts` edit or sudo. That flag is **browser-only**: Playwright's `apiRequestContext` runs in Node and ignores it, so every spec that drives the API directly dies on `getaddrinfo ENOTFOUND hugmesh.net`. Affects **5 specs** (19, 20, 23, 29 and their helpers; only four are named, the fifth is not identified, so the count is UNVERIFIED). Spec 29's stack-free TOTP cases pass; only its API cases fail, so the failure is unambiguously the harness. Fix options, none free: `docker run --add-host` in `run.sh` (fixes the documented docker path only, not the host-`npx` fallback); per-request `Host:` header against `https://127.0.0.1:8443` with `ignoreHTTPSErrors` (works on both paths, but touches all 5 specs); or accept an `/etc/hosts` entry as a documented prerequisite. **Not chosen here** — a cross-spec refactor that can only be partially verified on this cluster is exactly the kind of change that ships green and broken. |
| 21 | The two lanes seeded **different persona catalogues** | **FIXED 2026-08-06.** `seed-accounts.sh`'s `SYSTEMS_ROLE_USERS` is an OVERRIDE, so a caller wanting one extra persona had to restate the whole base list. compose (`seed-e2e.sh`) did; `bootstrap-kind.sh` did not, and therefore seeded **no extras at all**. On a cluster where everything else worked, spec 29 answered `native login e2e-fleet -> 401` — a persona that had never been created, reading exactly like a broken login. `tests/e2e-extra-personas.sh` is now the one definition, sourced by both lanes, with an additive `EXTRA_ROLE_USERS` door. Resolved catalogue 15 → 30. Guarded by `lint:e2e-persona-catalogue`. |
| 22 | **`ROLE_FLEET_ADMIN` was never created in Casdoor** | **FIXED 2026-08-06.** Seeding the personas made `apply-systems-roles.sh` refuse — correctly: `FATAL: role hugmesh/ROLE_FLEET_ADMIN does not exist in Casdoor`. `route-access/initdb/20-schema.sql` seeds a **live authorization row** granting `ROLE_FLEET_ADMIN` on `/bff/admin/phone-fleet/**` while `init-data-configmap.yaml` never declared the role. **Not a test-only defect**: no account on any cluster could hold it, so the fleet-owner phone console was unreachable in production too. Exactly one role was missing of the 21 the authz rows name. Guarded by rule 5 of the same gate. Note for operators: Casdoor imports `init_data.json` at **boot**, so adding a role needs a pod restart, not just a ConfigMap apply. |
| 23 | **The gateways spoke plain HTTP into admin-bff's TLS port** | **FIXED 2026-08-06 (generator side).** Both `20-gateway-{fe,be}.yaml` carried `BFF_BASE_URL: http://hugmesh-admin-bff-api…:8080` while admin-bff serves TLS with `client-auth=need`, so `BffSessionAuthFilter` died as `Connection prematurely closed BEFORE response` and every `/bff/session` answered 503. Every *other* reference to that peer was already `https`; these two were missed when admin-bff's server TLS went on. Guarded by rule 4 of `lint:outbound-mtls-client`, whose TLS-serving set is DERIVED from whichever manifests set `SSL_ENABLED=true`. |
| 24 | The gateway's introspection WebClient uses the **default JDK trust** | **FIXED IN SOURCE (hugmesh-gateway `fada7fb`, 2026-08-14).** `DownstreamMtlsConfig.downstreamMtlsWebClientCustomizer` (`DownstreamMtlsConfig.java:121` on `main`) is the `WebClientCustomizer` bean. Whether the gateway image a cluster runs was rebuilt after it is UNVERIFIED, and `hugmesh-gateway#97`, the number the 2026-08-06 write-up cited, cannot be resolved with `gh` today. The 2026-08-06 write-up follows, **as written then:** With #23 fixed the failure moved one layer, to `(certificate_unknown) PKIX path building failed`, and `/bff/session` still 503s. `DownstreamMtlsConfig` registers its `SslContext` as an `HttpClientCustomizer` — a *Spring Cloud Gateway* hook that only reaches the routed-proxy HttpClient. Boot's `WebClient.Builder` consults `WebClientCustomizer` beans instead, so `bffIntrospectWebClient` never got the cluster CA — while its javadoc claimed it did. Fixed in the gateway repo (bean proven load-bearing: test red without it, 5/5 with it); **needs a rebuilt gateway image to go live**. |
| 25 | **Non-Spring callers never got the mTLS wave** | **STILL OPEN on 2026-10-07:** `EXEMPT_HTTP_TLS` in `tests/scripts/test-outbound-mtls-client.sh:232` still names the same four files, and the gate passes (14/0). Four call sites address TLS-serving peers over `http://` and have no PKCS12 stores or client identity at all, so a scheme flip alone would trade a connection error for a handshake error: `remote-fragment/deployment.yaml` → federation-api, `test-runner/test-job-{lean,heavy}.yaml` → admin-bff's report-ingest, and the `charts/hugmesh-gateway/values.yaml` default `api-default` route. The wave only ever reached the Spring services, which get stores from an init container and client config from a `@ConfigurationProperties` prefix; nothing gave the Jobs and sync sidecars an equivalent. Exempted **by name with reasons** in `test-outbound-mtls-client.sh` and anti-rot checked, so an exemption that stops describing a real defect fails the build. |
| 26 | `lint:service-env-contract` has a structural **blind spot** | **STILL OPEN on 2026-10-07 (documented):** `.gitlab-ci.yml:1624-1640` still runs `sparse-checkout set src/main/resources`. It derives its key list from each service's `application.yml`, deliberately so nobody maintains a list. But a property whose yaml default is EMPTY can still resolve to a hardcoded stale host in **Java** — which is exactly how admin-bff's `SessionExchangeConfig.DEFAULT_SELF_HOST` (pre-rebrand, NXDOMAIN) survived and 503'd every `/bff/session`. Structurally it could never have been seen: the CI job sparse-checks out `src/main/resources` only, so `src/main/java` is never on disk. **An empty yaml default is not evidence of a safe default.** |

## Finding 17 in detail — the private-registry pull path is unexercised

### What is missing

Four separate things stop the kind node from pulling an image from the in-cluster
Harbor:

1. **Nothing ever asks it to.** [`scripts/kind-load-images.sh`](../scripts/kind-load-images.sh)
   builds the first-party images (eight on 2026-08-05, ten on 2026-10-07) from `./.stack-src` and `kind load`s them
   into the node's containerd store under the exact refs the manifests render
   (`registry.hugmesh.net/hugmesh/<repo>:main`, gateway `:dev`). Its own
   header names the cost: *"`kind load` places each image directly into the
   node's containerd store where IfNotPresent finds it and no pull (or
   harbor-registry pull Secret) happens."* The kind-local README says the same
   from the other end: *"the in-cluster Harbor is empty on a fresh cluster and is
   not used."* Both are accurate and both are deliberate. The shortcut keeps
   `make kind-images` and `make kind-up` fast. It also removes the only consumer
   of everything in item 4 below.
2. **The node cannot resolve `registry.hugmesh.net`.** The manifests hardcode
   the hostnames, and the harness deliberately avoids `/etc/hosts`
   (*"you do need a way to resolve those names to the kind node without editing
   `/etc/hosts` (no passwordless sudo assumed)"*). It uses two other mechanisms,
   `curl --resolve` and the e2e's Chromium `--host-resolver-rules`. Both work
   per client, on the **dev machine**. Containerd inside the node sees neither.
3. **The node does not trust the ingress cert.** Harbor is exposed at
   `https://registry.hugmesh.net` through `ingress-nginx-internal`, with
   `expose.tls.secretName: harbor-mtls`, a **Vault-PKI-issued** cert
   (`apps/03a-harbor.yaml`). The kind node's CA bundle holds no cluster CA. The
   README's own registry example is `curl -k`, and finding #1 records that
   `cluster-ca` is USB-provisioned and `optional: true` everywhere. Containerd
   would reject the chain.
4. **containerd has no registry configuration at all.**
   [`kind-local.yaml`](../specs/cluster/bootstrap/kind-local/kind-local.yaml)
   declares one node with `extraPortMappings` and nothing else. It has no
   `containerdConfigPatches`, so no
   `[plugins."io.containerd.grpc.v1.cri".registry] config_path`, so no
   `/etc/containerd/certs.d/registry.hugmesh.net/hosts.toml`, so no host
   override, no `ca`, no `skip_verify`. Nothing tells this node where that
   registry is.

### Why it hides this whole bug class

Only an actual pull proves anything between Vault and a running container:

* that the Harbor robot account exists and its secret in Vault is the **live**
  one;
* that ESO rendered it into a `kubernetes.io/dockerconfigjson` whose `auths` key
  is the hostname the image ref actually uses;
* that the Secret exists **in the workload's namespace, under the name the
  workload asks for**;
* that the robot's Harbor permissions cover the project being pulled;
* that the node can resolve and trust the registry endpoint.

None of those has a second witness. ESO reports `SecretSynced` for a
well-formed dockerconfigjson that holds a dead token. A Deployment can name an
`imagePullSecrets` entry that does not exist, and nothing complains. A robot
with no permissions looks like one with them until a manifest is fetched. So the
lane can be **entirely green while every item on that list is broken**, and it
was:

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

Three defects, one reason they survived: **nothing pulls.** It is the
document's other theme again. The workaround (`kind load`) is real and carries
load. It also turned an unproven property into an untested one.

### What it would take to close

Four options, cheapest first. None is implemented. This section is the finding,
not a plan of record.

**(A) Point containerd at the in-cluster Service, plaintext.** Add
`containerdConfigPatches` to `kind-local.yaml` setting `config_path` and a
`hosts.toml` for `registry.hugmesh.net` whose `server` is
`http://harbor-core.hugmesh-pki.svc.cluster.local`.
*Buys:* DNS and CA trust stop mattering, and the pull still authenticates with
the real robot credential from the real ESO-rendered dockerconfigjson. That is
the bug class above.
*Costs:* it diverges from production in the one place that has already bitten
twice. A dockerconfigjson whose `auths` key names the wrong hostname still
authenticates here, so that defect stays hidden. A `skip_verify` or plaintext
line in a harness config can also get copied into a real one.

**(B) One deliberate pull probe, everything else side-loaded.** Keep
`kind-load-images.sh` as is; after `harbor-provision` completes, push one small
image through the existing kaniko path and run a Job with
`imagePullPolicy: Always` in a namespace that carries the pull secret.
*Buys:* one loud, specific assertion that the credential is live and the
dockerconfigjson works, at a fraction of the runtime of converting the whole
image set. It fails with a message that names the problem.
*Costs:* it still needs the node-side plumbing of (A) or (C), because a pull is
a pull. It narrows the scope of one of them; it does not replace them. It also
proves nothing about the platform's own images.

**(C) Make the node resolve and trust the real endpoint.** `hosts.toml` pointing
at the ingress with the cluster CA in its `ca` field (or installed into the
node's trust store), plus a host alias so `registry.hugmesh.net` resolves on
the node.
*Buys:* the only option that exercises the production path end to end: real
hostname, real ingress, real Vault-PKI chain, real credential.
*Costs:* the CA does not exist when the node is created, because Vault-PKI
issues it during bootstrap. So a step must change the node *after* it is up: a
privileged `docker exec` into the node, or a DaemonSet that writes a hostPath
and bounces containerd. That is a real hazard. Restarting containerd disrupts
every pod on the node, and a harness that reaches into the node can wedge the
cluster it is validating. It also turns `make kind-images` from build and
side-load into build, push and pull, which is much slower.

**(D) Leave the lane alone; prove what can be proved off-cluster.** What this
branch did: assert the invariant in CI instead, by executing the real
`gen-cluster-secrets.sh` and the real `harbor-provision` `reconcile.py` against a
faithful fake Vault and fake Harbor
(`tests/scripts/test-harbor-robots-ownership.sh`, plus
`tests/scripts/test-eso-target-collisions.sh` for the ownership/consumer half).
*Buys:* runs in seconds on every merge request, needs no cluster, and covers the
whole ownership class, not one instance.
*Costs:* it cannot catch anything that only a real pull can see: a wrong `auths`
hostname, an under-scoped robot, an ingress cert the node does not trust. Those
stay **unproven, not proven-absent**, and this finding is the record of that.

## Two systemic observations

**Silent failure is the common factor.** Almost every item above fails
*quietly*. ESO marks one Secret `SecretSyncedError` among 87. A probe returns
401 forever. `casdoor-init` prints success. A gateway falls back to a baked seed
instead of erroring. Fixes without guards would let the same class return, which
is why the branches below shipped a contract test each, both proven red on the
pre-fix tree.

**Compose is not evidence for the cluster.** Every workaround lives in
`tests/stack/compose.local.yaml`, usually with a comment describing the bug.
Compose green has passed for proof that the platform works. It proves that the
*services* work, not the *payload*.

## What is fixed in-repo already

All four branches are merged into `main`: #534 (`fix/cluster-secret-contract-drift`), #522 (`fix/pki-role-san-namespace`), #520 (`feat/kind-sso-e2e`) and #553 (`fix/harbor-registry-name-collision`). The list below is the 2026-08-05 account.

- `fix/cluster-secret-contract-drift` — seeds the missing properties and adds
  `tests/scripts/test-eso-seed-contract.sh`, which cross-checks **every**
  ExternalSecret reference against both delivery paths. It found **29**
  unsatisfiable references pre-fix on its first version and **41** once the gate was reworked (#534), including `user-bff-hs-token`'s
  `svc-password` (same all-or-nothing shape, loses the custody key with it).
- `fix/pki-role-san-namespace` — fixes the role loop plus a matching-rules
  contract test.
- `feat/kind-sso-e2e` — this harness, plus items 1, 2 and the node role label.
- `fix/harbor-registry-name-collision` — the `hugmesh-pki` ExternalSecret that
  had been targeting a Secret name the Harbor chart owns (renamed
  `hugmesh-registry-pull`), the `hugmesh-forum` pull secret nothing materialized,
  and the `harbor-robots` ownership conflict behind item 17's third bullet — the
  seeder's unconditional `vault kv put` overwriting the credentials
  `harbor-provision` had minted. Two guards:
  `tests/scripts/test-eso-target-collisions.sh` (renders the real upstream charts
  and fails on a target collision or an unmaterialized pull secret) and
  `tests/scripts/test-harbor-robots-ownership.sh` (executes the real seeder and
  the real Job script against a faithful fake Vault). Both proven red on the
  pre-fix tree.

On 2026-08-06 items 5–15 were **not** fixed in-repo; they were the remaining work. They were fixed the same day or soon after (#540-#544, #551, #552), as the table now marks. Items 16, 18, 19 and 21-23 are fixed, each marked in the table with what proved it.
Item 17 is **deliberately not fixed**; see its options above. The write-up is the deliverable, and closing it would mean changing the kind node. Items 25 and 26 are still OPEN, each with the reason it was written up rather than half-built. Item 20 is partly closed and item 24 is fixed in the gateway source (see the table).

## Where the SSO profile stands, 2026-08-06

The two specs this profile can actually drive end to end both pass against a
live kind cluster on merged `main`:

| spec | result |
|---|---|
| `01-frontpage` — anonymous visitor is gated to the native sign-in | **PASS** |
| `27-native-login` — `POST /bff/login` mints an httpOnly `bff_session`, no Casdoor origin is ever exposed to the browser | **PASS** |
| `29-mfa-privileged-floor` — stack-free RFC 6238 vectors | **PASS** |
| `29-mfa-privileged-floor` — API cases | blocked by item 20 (harness), not by the platform |

That is the roadmap's "SSO kind-cluster e2e" reaching green. What it means: the
login path now works from a cold cluster. That path covers the Casdoor seed,
Cassandra roles, Vault PKI issuance, ESO materialisation, gateway routing and
session minting over cluster mTLS. What it does not mean: the rest of the suite
(matrix, mastodon, forum, discord, RBAC realms) drives services this profile
does not deploy. Those specs are out of scope here and say nothing about their
health either way.

## Re-measured 2026-10-14

Blockers 1-16 are re-checked on `origin/main` @ `c0c46601` against the tree and
the offline guards, not against a cluster. Nothing here was run on a live cluster; the last kind run on record is
the 2026-08-06 one above (and the 2026-10-07 rebuild, which found item 27). The
`#NNN` numbers in the table above are issue or branch numbers from the original
write-up, not reliable GitHub pull request numbers (`gh pr view 534` is an
unrelated Studio change, and several of the others do not resolve), so this table
cites commits.

| # | State on main | Evidence |
|---|---|---|
| 1 | Fixed for kind only | `bootstrap-kind.sh` mints a throwaway `cluster-ca`; `vault-pki/pki-init-job.yaml` still mounts it `optional: true`. A real cluster still needs the operator's CA (operator-only). |
| 2 | Fixed for kind | `vault secrets enable -path=secret -version=2 kv` in `bootstrap-kind.sh`. |
| 3 | Fixed | `tests/scripts/test-eso-seed-contract.sh`: 29 passed, 0 failed. |
| 4 | Fixed | `07320e1a`; `vault-pki/pki-init-configmap.yaml` role loop. |
| 5 | Fixed | `cff35917`; `charts/hugmesh-gateway/templates/deployment.yaml:189-191` sets `SPRING_CASSANDRA_USERNAME` / `_PASSWORD`; `test-cassandra-cluster-wiring.sh`: 44 negative controls, PASS. |
| 6 | Fixed | `cff35917`, `1d57735d`; `manifests/cassandra-init/` and `apps/00b-cassandra-init.yaml`; `bootstrap-kind.sh` lists it in `APP_NAMES` for the sso profile. |
| 7 | Fixed | `effd9364`; the chart's readiness and liveness probes accept 200 or 401 (`deployment.yaml:241-262`); `tests/stack/test-probe-auth-surface.sh`: 16 negative controls, PASS. |
| 8 | Fixed | `da6d970a`, `668d386e`; `casdoor/app-conf-configmap.yaml:56` sets `initDataFile = "/init_data.json"`; `init-data-configmap.yaml` declares the `applications` block the import needs. |
| 9 | Fixed in the manifests | Same commit: `init_data.json` and `casdoor-init` set the admin password from the ESO value. The live IdP behind a given cluster is not measured. |
| 10 | Fixed | `da6d970a`; `casdoor/init-job.yaml` reads response bodies; `test-casdoor-init-honesty.sh`: 67 passed, 0 failed. |
| 11-13 | Fixed | `7742bde3`; `user-bff-api/deployment.yaml:168` (`CASDOOR_ORG`), `:496` (client id), `:508` (redirect URI). |
| 14 | Fixed | `7742bde3`; `test-service-env-contract.sh` PASS with 27 negative controls. It reads the BFF source checkouts it finds next to this repo (here: `SERVICE_SRC_ROOT=/home/magus/Github`, whose HEADs are not all `origin/main`), so treat that run as indicative; CI clones the services itself. |
| 15 | Fixed | `7742bde3`; `admin-bff-api/deployment.yaml:769-773` takes `SVC_PASSWORD` from `user-bff-hs-token` / `svc-password`. |
| 16 | Fixed in source | `0cb9221` is an ancestor of `hugmesh-admin-bff-api` `origin/main` (`b51e02af`); that tree has 0 `TO admin_bff` and 169 `adminbff_app` under `src/main/resources`; `admin-bff-api/deployment.yaml:273-274` connects as `adminbff_app`. Whether the `:main` image a cluster pulls was rebuilt after it is not verified. |

Items 18-19 and 21-24 are marked fixed in the table above and were not re-run.
Still open: 17 (the kind lane never pulls from Harbor), 20 (harness; specs 19, 20
and 23 still use the built-in `request` fixture), 25 and 26. A guard run today
agrees with the notes on 25: `tests/scripts/test-outbound-mtls-client.sh` passes
14 of 14 with `EXEMPT_HTTP_TLS` still naming the four exempt call sites.

### 27. The BFFs cannot validate a Casdoor JWT on kind (hugmesh-generator#693)

**OPEN on main.** `POST /bff/login` mints the cookie (spec 27 stays green), but the
first call that validates a token, `GET /bff/session`, answers 500: the ten
kustomize-managed JWT-validating manifests set only `CASDOOR_ISSUER_URI`
(`https://id.hugmesh.net`), the signing-key fetch goes to that name, and it does
not resolve inside the cluster. The gateway chart already sets `CASDOOR_JWKS_URI`
to the in-cluster Service. The fix is the manifests plus three NetworkPolicies
that admit the pods the hugmesh-pki tier policy did not
(`manifests/networkpolicy/casdoor-jwks-ingress.yaml`), guarded offline by
`tests/scripts/test-bff-jwks-in-cluster.sh` (25 negative controls). It is in
draft pull request #709, which conflicts with current main only in
`tests/scripts/test-guard-integrity.sh` (the suite census). The live proof (`make kind-tor`, then
`make kind-e2e-tor`, on a fresh bootstrap) has not been run. Until it has, the
spec 27 PASS above proves less than "login works".
