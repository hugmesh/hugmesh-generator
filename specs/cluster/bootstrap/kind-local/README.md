# kind-local — local kind bring-up (Vault + PKI + Casdoor + Harbor, + SSO slice)

> **`KIND_PROFILE=sso`** extends the core slice below with the **native-login
> path** — Cassandra, the route-access seed DB, the fe-gateway chart (Ingress
> re-classed to `nginx-internal`), admin-bff + user-bff (+ their Postgres), the
> Angular host shell, the login/social UI remotes, the **`/user/**` self-service
> remote** (profile, preferences, password change) and **federation-api + its
> Postgres** (the vanity/public-profile publish target a profile save calls) —
> then seeds Vault KV
> (`scripts/gen-cluster-secrets.sh` ONLINE mode through a `kubectl exec` shim
> into `vault-0`, so no host `vault` CLI is needed) and the deterministic e2e
> identity catalogue (`tests/qemu/seed-accounts.sh --roles` applied over a
> Casdoor port-forward). First-party images are **built locally and
> `kind load`ed** under the exact refs the manifests render
> (`registry.hugmesh.net/hugmesh/<repo>:main`, gateway `:dev`) — the
> in-cluster Harbor is empty on a fresh cluster and is not used.
>
> **What this profile does NOT deploy, said plainly.** It is a slice, not a small
> production cluster. The fe-gateway's route table is applied WHOLE, so roughly a
> dozen routes point at tiers this profile never brings up — be-gateway, Matrix
> (tuwunel), Mastodon (akkoma), the mod/forum/wiki/mesh/character-forge tiers and
> their UIs, api-docs and remote-fragment. Those paths answer **503 behind a live
> route**, which looks nothing like "not installed". The full, current inventory
> with a reason per entry is the `EXEMPT` table in
> `tests/scripts/kind_route_closure.py`, and
> `tests/scripts/test-kind-profile-route-closure.sh` fails the build if a routed
> Service is undeployed and *unexplained* — which is how `/user/**` was routed into
> the void on every kind cluster until 2026-08-26 while `/bff/user/**` answered
> `curl` perfectly.
>
> Driven end-to-end from the repo root:
>
> ```sh
> make kind-up       # bootstrap-kind.sh KIND_PROFILE=sso (idempotent — an
>                    # already-seeded Vault KV is KEPT, not re-minted; see
>                    # "The script is idempotent" below for why that matters)
> make kind-images   # build from ./.stack-src + kind load  (before/after kind-up both work)
> make kind-e2e      # spec 27 (native login) against https://hugmesh.net:8443
> make kind-down
> ```
>
> `make kind-e2e` maps `hugmesh.net -> 127.0.0.1` with a Chromium
> host-resolver rule (no `/etc/hosts`, no sudo) and rides the
> `kind-local.yaml` 443→8443 host port map into the internal ingress. This is
> the kind-cluster leg of the SSO e2e roadmap item — the same proof
> `tests/e2e/specs/27-native-login.spec.ts` runs against the compose stack.

A reusable, local, single-node [kind](https://kind.sigs.k8s.io/) cluster that
brings up a **curated slice** of the HugMesh GitOps tree so you can
validate the Vault → PKI → Casdoor → Harbor chain before it ever touches the
real multi-Pi hardware. This targets the **CORE reference `hugmesh.net`
apps/ tree** (`specs/cluster/apps/*.yaml` as committed to this repo) — it is
NOT a brand-templated tenant bring-up (that's `templates/apps/*.hbs` +
`brands/*.conf`, a separate rendering layer this script doesn't touch).

This tree was exercised end-to-end for the first time from this branch. Three
real, previously-unexercised bootstrap bugs were found and are baked into this
script/these manifests from the start (not left for the next person to
rediscover by trial and error) — see "Known bugs fixed here" below.

## Why a curated subset, not the real bring-up

`specs/cluster/bootstrap/bootstrap.sh` installs ArgoCD and then applies the
root `specs/cluster/app-of-apps.yaml`, which syncs **all 96** files under
`specs/cluster/apps/*.yaml` (91 `Application` + 5 `ApplicationSet` objects,
counted 2026-08-26) — the entire platform (GitLab, Cassandra, all 4 gateways,
Matrix/tuwunel, Mastodon/Akkoma, games, media-poisoner, analytics,
observability, …). That's correct for a real deployment but deliberately too
much for validating one change: it's slow, heavy, and syncs dozens of
Applications that a Vault/PKI/Casdoor/Harbor change never touches.

> That count said **81** here and in `bootstrap-kind.sh` until 2026-08-26, and
> had been wrong long enough that nobody re-derived it. Read it as a magnitude,
> not a checksum — nothing enforces it, and the point it makes ("far more than
> this pass needs") holds either way.

This script applies **only** the Applications needed to validate that chain,
directly with `kubectl` — **not** via the root app-of-apps.

### The curation is deliberate — and it is now SELECTABLE

Curating is the right call, and it was also a dead end: until 2026-08-26 the
only way to add an infra `Application` to this set was to **edit this script**.
`make kind-up` passed `KIND_PROFILE` and `MFA` and nothing else, and the Studio's
"Start DevOps lane" button passed nothing at all (it called `_make("kind-up")`
with no `extra_env`, on a `_make` that had always accepted one).

The visible cost of that: `apps/01-metrics-server.yaml` has existed all along —
chart `3.12.*`, namespace `kube-system`, sync-wave `-1` — and was in **no**
profile, while `KIND_PROFILE=sso` deploys **seven** `HorizontalPodAutoscaler`
objects (one each from `manifests/admin-bff-api`, `manifests/user-bff-api`,
`manifests/frontend`, and **four** from `manifests/social-ui`). An HPA with no
resource-metrics API does not fail, warn or degrade: it reports
`<unknown>/70%` forever and holds its Deployment at the replicas floor, which
from every surface looks exactly like a cluster that is not busy.

`KIND_ADDONS` is the selection channel. It does **not** widen the curated set by
default beyond metrics-server; it makes the set something a caller can *choose*.

| Add-on slug | Applications it adds | Default | Why |
|---|---|---|---|
| `metrics-server` | `apps/01-metrics-server.yaml` | **ON** | The resource-metrics API (`kubectl top`, and the seven HPAs above). ON by default because those HPAs are already applied and already inert — an opt-in default would ship the broken state as the normal one. |
| `keda` | `apps/01-metrics-server.yaml` + `apps/01b-keda.yaml` | off | The KEDA operator, the substrate for latency/queue-driven scaling. Its row carries metrics-server too: KEDA over an absent resource-metrics API leaves the CPU/memory HPAs inert, just wearing a different hat. |

```
make kind-up                                 # metrics-server (the default)
make kind-up KIND_ADDONS=metrics-server,keda
make kind-up KIND_ADDONS=none                # opt out; the HPAs go inert again
KIND_ADDONS_PRINT=1 bash specs/cluster/bootstrap/kind-local/bootstrap-kind.sh
                                             # read-only: resolve and stop
```

**Deliberately NOT offered yet**, because every slug here has to change something
observable or it is a checkbox that changes no bytes:

* `apps/01c-autoscaling-latency.yaml` — its KEDA `ScaledObject`s target the same
  Deployments the seven v2 HPAs already own, and KEDA will not co-own a
  Deployment that already has an HPA (the file says so itself). It also reads a
  Prometheus this cluster does not have.
* `apps/36-observability.yaml` — MANUAL-sync by design (no `syncPolicy.automated`).
  Applying the `Application` object would create an OutOfSync row and deploy
  nothing.

Guards: `tests/scripts/test-kind-addon-channel.sh` (offline; Studio → Makefile →
this script, plus the fail-closed and default-ON rules) and
`tests/scripts/test-kind-metrics-api.sh` (**behavioural**; asks a live cluster
whether `metrics.k8s.io` answers and whether a named HPA has stopped reporting
`<unknown>` — skips loudly, and never creates a cluster). The first proves the
wiring; only the second proves the metrics API. `tests/scripts/test-kind-profile-app-closure.sh`
reads the same `KIND_ADDON_MAP` block, so an add-on row that names an
`Application` without its bootstrap companion is caught like a profile entry is.

### Included (and why)

| Application file | Why it's here |
|---|---|
| `apps/02-vault.yaml` | The cluster secret store — the thing being validated. |
| `apps/06-vault-pki.yaml` | The PostSync Job that bootstraps `pki_int` + per-app issuing roles (including the `harbor` role added by the Harbor migration). |
| `apps/03-external-secrets.yaml` | ESO controller + CRDs — required for anything to read from Vault. |
| `apps/04-external-secrets-config.yaml` | The `ClusterSecretStore "hugmesh-vault"` + the `ExternalSecret`s that use it. |
| `apps/11-ingress-nginx-internal.yaml` | The `nginx-internal` IngressClass — Harbor's Ingress (from the migration branch) uses this class. The public `nginx` controller (`apps/10-ingress-nginx.yaml`) is skipped; nothing here needs public ingress. |
| `apps/05-casdoor.yaml` | The identity provider + its own dedicated `casdoor-pg` Postgres (Casdoor has zero Cassandra dependency). |
| `apps/03a-harbor.yaml` + `apps/03b-harbor-provision.yaml` | The registry migrated onto Vault-PKI-issued TLS + Casdoor OIDC. Both merged to `main`; since 2026-08-26 they are ordinary `CORE_APPS` entries read from this checkout, not bespoke `git show` fetches — see "Harbor is unmerged" below for what replaced that machinery. |
| `apps/01-metrics-server.yaml` | The resource-metrics API, added by the **default** `KIND_ADDONS=metrics-server` (not by the curated base). See "The curation is deliberate" above. |

Plus the two things that aren't ArgoCD `Application`s at all:
`specs/cluster/namespaces/namespaces.yaml` (plain `kubectl apply`) and
`specs/cluster/manifests/local-path` (the `hugmesh-local` StorageClass,
`kubectl apply -k`).

### Explicitly excluded

Everything else under `specs/cluster/apps/*.yaml` — most notably:
`00-cassandra.yaml`, `03-gitlab.yaml`, both gateway apps
(`20-gateway-be/fe/pki.yaml`, `22-gateway-superadmin.yaml`), `30-tuwunel.yaml`
(Matrix), `30-akkoma.yaml` (Mastodon), `50-games.yaml` / `06-casdoor-games.yaml`
(the entirely separate games realm), `51-media-poisoner.yaml`, the analytics/
observability/velero stack, `10-ingress-nginx.yaml` (public ingress), and
`09-lan-dns.yaml` (LAN-client wildcard DNS — irrelevant here since nothing in
this subset needs external LAN resolution or public ingress; it also isn't
wired into cluster-internal kube-dns automatically, so it wouldn't help this
validation anyway).

None of these are referenced, directly or transitively, by Vault, PKI,
Casdoor, or Harbor.

## Known bugs fixed here

Found during the first real end-to-end bring-up of this tree (kind, not the
real hardware) — none of these were exercised before:

1. **ArgoCD has no git credential for the private `hugmesh-generator`
   repo.** Every git-path `Application` in the curated set (Vault, vault-pki,
   external-secrets-config, Casdoor, harbor-provision) fails with
   `authentication required: Repository not found` without one. Fixed by the
   opt-in `ARGOCD_REPO_TOKEN` mechanism documented below. **The production
   `bootstrap.sh` now registers the identical credential** — it previously did
   NOT (this was a real gap; the claim that `keys-provision` already did it
   out-of-band was vapor). The real path now works like this: `keys-provision`
   reads a fine-grained read-only PAT from the offline KEYS USB
   (`KEYS/gitops/repo-token`, same custody as `vault/token`), exports it as
   `ARGOCD_REPO_TOKEN`, and `bootstrap.sh` creates the
   `hugmesh-generator-repo` repository Secret **before** applying the
   app-of-apps (failing closed with a clear error if no token is available).
   For a local kind cluster there is no KEYS USB — and no token is needed
   either: the **tokenless local sync path** (see "Repo access" below) mounts
   this checkout read-only into the kind node and serves it to ArgoCD from an
   in-cluster read-only `git daemon`. `ARGOCD_REPO_TOKEN` remains the
   override for pointing a kind cluster at GitHub instead.
2. **`vault-tls-init`'s image has no `openssl` binary.** The init container
   that generates Vault's listener TLS material ran `hashicorp/vault:1.21.4`
   and called `openssl` in both of `gen-tls.sh`'s branches (cluster-CA-signed
   and the DEV self-signed fallback) — that image ships only the `vault`
   binary, no `openssl` at all, so both branches failed identically. Fixed in
   `manifests/vault/deployment.yaml` by repointing that one init container at
   `alpine/openssl` (pinned by digest; verified it actually contains a working
   `openssl` CLI before pinning). The Vault server/sidecar containers are
   unchanged (they need the real `vault` binary, not `openssl`). The
   cluster-CA-signed vs. self-signed-dev-fallback contract and the external
   `cluster-ca` Secret shape are unchanged.
3. **`local-path-config` is missing `helperPod.yaml`.**
   `rancher/local-path-provisioner:v0.0.30` requires a `helperPod.yaml` key in
   its config ConfigMap and CrashLoops at startup without one (`invalid empty
   flag helper-pod-file ... helperPod.yaml is not exist in local-path-config
   ConfigMap`). Fixed in `manifests/local-path/local-path.yaml` by adding the
   verbatim upstream default helper-pod template for that provisioner version.

Bugs #2 and #3 are fixed directly in `specs/cluster/manifests/`, so they apply
to the real cluster too, not just kind. See `VAULT_BRANCH` below for how this
script picks up the #2 fix before it merges to `main`.

## Harbor is unmerged — how this script USED to handle it (retired 2026-08-26)

> **This section is history.** The Harbor migration and the `vault-tls-init`
> openssl fix have both merged. `HARBOR_BRANCH` and `VAULT_BRANCH` now default to
> `main`, `02-vault.yaml` / `03a-harbor.yaml` / `03b-harbor-provision.yaml` are
> ordinary `CORE_APPS` entries read from this checkout's working tree like
> everything else, and the three bespoke `git show` blocks are gone. What replaced
> them is `app_pin()`: a per-file pin that fires **only** when `VAULT_BRANCH` /
> `HARBOR_BRANCH` name something other than the revision the rest of the tree is
> read at, so the next not-yet-merged Application can still be validated the same
> way. Verified before the change: `git show HEAD:<path>` was byte-identical to
> the checked-out file for all three, and `03a`'s `sed` is a genuine no-op on it
> (`repoURL: https://helm.goharbor.io`, `targetRevision: 1.16.x` — neither
> expression matches).
>
> It was not a cosmetic collapse. Those three were **invisible** to
> `tests/scripts/test-kind-profile-app-closure.sh`, which models the applied set
> from the `*_APPS` arrays — so Harbor was applied but not modelled, and the guard
> carried two "ANALOGY" exemptions for `00b-cassandra-init`'s references to it.
> Modelling them retired both.

The Harbor registry migration lived on branch `feat/harbor-registry-migration`
(draft PR #254) — `main` had no Harbor manifests at all. This script fetched
Harbor's two `Application` objects straight from that branch
(`git show <branch>:specs/cluster/apps/03a-harbor.yaml` /
`03b-harbor-provision.yaml`) rather than from the local `main` checkout:

- **`03a-harbor.yaml`** sources a Helm chart (`helm.goharbor.io`), not a git
  path in this repo — applied as-is, no `targetRevision` rewrite needed.
- **`03b-harbor-provision.yaml`** sources a git path
  (`specs/cluster/manifests/harbor`) that only existed on the migration branch,
  so its `targetRevision: main` was rewritten to
  `targetRevision: feat/harbor-registry-migration` before applying, so
  ArgoCD's own controller fetched the *correct* manifest content live from
  that branch.

Every other curated Application (Vault, ESO, Casdoor, ingress-nginx-internal)
already exists on `main` unmodified and is applied straight from `main` — no
override.

**Known gap, by design:** the migration branch *also* adds a
`harbor-externalsecrets.yaml` (the `harbor-mtls` cert) under
`specs/cluster/manifests/external-secrets/`, and adds a `harbor` PKI role to
`manifests/vault-pki/pki-init-configmap.yaml`. Neither of those is overridden
here — `apps/04-external-secrets-config.yaml` and `apps/06-vault-pki.yaml` are
applied straight from `main`, which does **not** yet include the Harbor
additions. That means Harbor's own TLS secret and PKI issuing role won't
exist after this script runs, so Harbor's `Application` may sit at
`Progressing`/`Missing` rather than fully `Healthy`. **That's expected** —
the full end-to-end Harbor validation (once the migration branch's ESO/PKI
config additions are also in the loop) is a separate next step; this script's
job is just to get the cluster + curated apps up and confirm they apply
cleanly. Once #254 merges to `main`, drop `HARBOR_BRANCH` (or set it to
`main`) and everything converges from one place.

## Usage

```bash
cd specs/cluster/bootstrap/kind-local
./bootstrap-kind.sh
```

Env overrides (all optional):

| Var | Default | Purpose |
|---|---|---|
| `KIND_CLUSTER_NAME` | `hugmesh-local` | kind cluster name |
| `HUGMESH_GITOPS_REPO` | `https://github.com/hugmesh/hugmesh-generator.git` | repoURL rewritten into every non-Harbor Application (fork support, mirrors `bootstrap.sh`). **Left at the default with no token, it is replaced by the tokenless local sync URL** (see "Repo access" below). |
| `HUGMESH_GITOPS_REV` | `main` (`HEAD` on the local sync path) | targetRevision rewritten into every non-Harbor Application. On the tokenless local sync path an unset value defaults to `HEAD` — the branch this checkout has checked out — so ArgoCD syncs what you are actually running. |
| `HARBOR_BRANCH` | `main` | Per-file **branch pin** for `03a-harbor.yaml` + `03b-harbor-provision.yaml`. Both merged, so the default equals the revision everything else is read at and the pin is INERT: the files come from this checkout's working tree like every other `CORE_APPS` entry. Set it to an unmerged branch and those two go back to the `git show <branch>:<path>` path (`app_pin()`), which is why the machinery is kept. |
| `VAULT_BRANCH` | `main` | The same per-file branch pin for `02-vault.yaml` (and, live, `manifests/vault`). It carried the `vault-tls-init` openssl fix (bug #2 above) until that merged; inert at the default. |
| `KIND_ADDONS` | `metrics-server` | Infra add-on **selection** — comma- or space-separated slugs from the table in "The curation is deliberate" above, or the literal `none`. ⚠ An **empty** value — or one that is nothing but separators (`"   "`, a tab, a bare `,`) — means UNSET and falls back to the default; `none` is the only spelling for "no add-ons" (empty is what `make` and an empty picker produce by accident, and turning metrics-server off must not be reachable by accident). An unknown slug is refused loudly, like `MFA`. |
| `KIND_ADDONS_PRINT` | *(unset)* | Read-only: `1` resolves the add-on selection, prints it, and exits **without doing any bring-up work** (it says so). Exists so `tests/scripts/test-kind-addon-channel.sh` measures the real parse instead of a copy of it. |
| `SKIP_VAULT_BOOTSTRAP` | `0` | set `1` to stop after applying the curated Applications, before the Vault init/unseal/PKI step |
| `KIND_KV_RESEED` | `0` | `KIND_PROFILE=sso` only. Set `1` to re-mint **every** cluster secret even though Vault KV is already seeded. **DESTRUCTIVE**: existing Postgres/Cassandra volumes keep the old passwords and will reject the new ones — correct only against a fresh cluster or wiped PVCs. |
| `MFA` | *(unset — off)* | `KIND_PROFILE=sso` only (`make kind-up MFA=1`); refuses `core` loudly. The MFA operational flip (issue #47): appends a `mfa.enabled=true` **helm parameter** to every gateway Application this bootstrap applies, so the kind cluster runs live route-level MFA enforcement while the committed chart/apps stay default-OFF. Flips **only** `app.mfa.enabled` — the privileged floor is not reachable from here. Accepts `1/true/on`; anything else but `0/false/off/empty` fails closed. See `docs/MFA-ROLLOUT.md` §8; wiring gated by `tests/stack/test-mfa-flip-wiring.sh`. |
| `ARGOCD_REPO_TOKEN` | *(unset)* | **override**: point ArgoCD at GitHub with this credential instead of the default tokenless local sync — see below |

### Repo access — tokenless local sync (default) or `ARGOCD_REPO_TOKEN` (override)

`hugmesh-generator` is a **private** GitHub repo, and ArgoCD's repo-server
has no credential for it out of the box — without repo access every git-path
`Application` in the curated set sits at `ComparisonError: authentication
required`, `vault-0` is never created, and the bring-up is dead on arrival
(issue #48 was exactly this, reported as success by the old warn-and-continue
paths).

**The default is the tokenless local sync path — a local mesh needs no GitHub
credential at all.** At cluster-create time `bootstrap-kind.sh` appends a kind
`extraMounts` entry that mounts this checkout **read-only** into the kind node
at `/hugmesh/hugmesh-generator`; step 5b then deploys
`gitops-repo-server.yaml` — a pinned `git daemon` (upload-pack only, no
receive-pack, read-only mount) — and rewrites every Application's `repoURL` to

```
git://gitops-repo-server.devops.svc.cluster.local/hugmesh-generator
```

with `targetRevision: HEAD` (the branch this checkout has checked out) unless
`HUGMESH_GITOPS_REV` pins one. ArgoCD syncs **the tree you are actually
running**, entirely offline. Two properties worth knowing:

- `git daemon` serves **committed objects only** — a dirty or mid-build
  working tree serves its last commit: stale-but-consistent HEAD, exactly what
  a GitOps controller should see. Commit, and ArgoCD picks it up on its next
  poll; nothing ever reads your uncommitted edits.
- The mount can only be added when the cluster is **created**. A cluster
  created before this path existed doesn't have it — the script tells you so
  and names the fix (`kind delete cluster --name hugmesh-local` and re-run, or
  supply a token). Linked git worktrees can't be served either (their `.git`
  is a file pointing outside the mount) — run from a full clone.

**The override is `ARGOCD_REPO_TOKEN`** — for teams pointing a kind cluster at
GitHub, and the same variable the real cluster's `../bootstrap.sh` gets from
the offline KEYS USB (`KEYS/gitops/repo-token`) via `keys-provision`. It is
**strictly opt-in**: the script never runs `gh` or anything else to fetch a
token on its own, because silently materializing a live personal credential
into cluster storage as a side effect of "just run the script" should require
an explicit, deliberate choice:

```bash
export ARGOCD_REPO_TOKEN="$(GH_TOKEN= gh auth token)"   # or any PAT with read access to the repo
./bootstrap-kind.sh
```

**Fail-closed under `KIND_PROFILE=sso`:** if neither path is available (no
token, and the local sync can't serve — missing mount or worktree checkout),
the script **exits non-zero naming exactly what is missing** instead of
bringing up a cluster that cannot converge. `KIND_PROFILE=core` keeps the old
warn-and-continue for that case only (ArgoCD retries on its own once a
credential exists — export the var and re-run, or add the Secret by hand per
the ArgoCD docs). The `vault-0` wait is fail-closed on **both** profiles: if
the pod never runs, the script exits non-zero with the ArgoCD `vault`
Application's condition message (the missing-repo-access signature is named
explicitly) rather than warning and reporting success over a broken cluster.

The script is **idempotent**: re-running it against the same cluster skips
cluster creation, re-applies everything else (`kubectl apply` is a no-op on
unchanged content), detects an already-initialized Vault instead of re-running
`vault operator init`, keeps an existing `cluster-ca` Secret, and — under
`KIND_PROFILE=sso` — **keeps an already-seeded Vault KV** instead of re-minting
it (`seed-vault-kv.sh`).

> **That last clause used to be missing, and its absence made the whole claim
> false.** The KV step ran `scripts/gen-cluster-secrets.sh` with no already-done
> guard, and that script mints *every* password unconditionally
> (`openssl rand`) and `vault kv put`s it. The Postgres instances behind those
> passwords never re-read them — `initdb` only runs on an empty `PGDATA` — so a
> second `make kind-up` rotated Vault, ESO re-materialized the k8s Secrets, and
> the BFFs crash-looped on credentials their databases had never seen:
> `FATAL: password authentication failed for user "userbff"`. Hit live. The
> "idempotent" step wedged the cluster it claimed to converge.
>
> `seed-vault-kv.sh` now probes six sentinel KV paths (`casdoor`,
> `casdoor-apps`, `admin-bff-db`, `user-bff-db`, `route-access-db`,
> `cassandra-admin`) first: all populated ⇒ skip; none populated ⇒ seed; a
> *partial* set ⇒ hard failure with both remedies spelled out, because that is
> an interrupted first run where either choice is silently wrong. Set
> `KIND_KV_RESEED=1` to re-mint deliberately — **destructive**, correct only
> against a fresh cluster or wiped PVCs.

The identity seed is likewise **verified, not assumed**: after
`apply-systems-roles.sh` runs, `verify-seeded-identities.sh` re-authenticates
from scratch and reads the catalogue back out of Casdoor, so the script cannot
print `SSO slice seeded.` over an empty Casdoor. Both the apply hook and the
verifier check the Casdoor response **envelope** (`.status == "ok"`), because
Casdoor answers a *denied* call with **HTTP 200** and
`{"status":"error","msg":…}` (upstream `controllers/util.go`: `ResponseError()`
sets `Status: "error"` and never touches the HTTP status; `RequireSignedIn()`
and `RequireAdmin()` both report denials through it). The previous `curl -sf`
hook could therefore run the entire seed anonymously — empty cookie jar, every
`get-*` empty, every user "re-added", every role "skipped" — and exit 0.

### What it does, in order

1. Create the kind cluster from `kind-local.yaml` plus a runtime-rendered
   `extraMounts` entry (this checkout, read-only, at
   `/hugmesh/hugmesh-generator` — the tokenless local sync path's object
   store; single control-plane node; this is a validation tool, not a
   hardware topology simulation) — skipped if the cluster already exists.
2. Label the node `hugmesh.net/pki=true` +
   `hugmesh.net/local-path=true` (the only two capability labels the
   curated manifests actually select on — checked by grepping every
   `nodeSelector` in the included manifests; `kubernetes.io/arch=amd64` is
   already correct on a kind/amd64 node).
3. Apply namespaces + the `hugmesh-local` StorageClass, and strip the
   default-class annotation from kind's own `standard` StorageClass (both
   would otherwise claim to be *the* cluster default).
4. Install ArgoCD into namespace `devops`, pinned to
   `kubernetes.io/arch=amd64` — reusing `../bootstrap.sh`'s exact
   install/re-namespace/pin logic (NOT its root app-of-apps step).
5. Give ArgoCD repo access ("Repo access" above): register the
   `ARGOCD_REPO_TOKEN` credential if the operator exported one, otherwise
   deploy the in-cluster read-only `git daemon` and rewrite every
   Application's `repoURL` at it (failing closed under `KIND_PROFILE=sso` if
   neither path is available).
6. Apply the curated `Application` subset described above directly with
   `kubectl` (not the root app-of-apps).
7. Wait (best-effort, 5 minute budget) for those Applications to reach
   `Synced`/`Healthy`, printing a status table either way.
8. **LOCAL-DEV-ONLY**: wait for `vault-0` to be Running — **fail-closed**: a
   timeout exits non-zero with the `vault` Application's condition message
   (the old warn-and-`exit 0` here is how issue #48's broken cluster got
   reported as a success) — then run the one-time `vault operator init -key-shares=1
   -key-threshold=1` + `vault operator unseal` sequence by hand (replicating
   `keys-template/vault/README.md`'s documented real-world operator steps),
   seed the `vault-unseal` / `vault-bootstrap` / `vault-token` Secrets the
   auto-unseal sidecar / `vault-pki-init` Job / ESO `ClusterSecretStore`
   expect, and re-run `vault-pki-init` so `pki_int` + the per-app issuing
   roles actually exist. **Fresh key material is generated every run against
   a new cluster — nothing is hardcoded in this script, and none of this
   wires into the real offline KEYS-USB provisioning flow** (that's out of
   scope here; see the README for the real flow).

The cluster is **left running** afterward — this script's job is to get it up
and confirm the curated apply succeeds; full end-to-end validation (Harbor
pull/push, Casdoor login, etc.) is a separate follow-on step against this same
cluster.

## Reaching the real-looking hostnames from your dev machine

The core manifests hardcode real reference-cluster hostnames
(`registry.hugmesh.net`, `*.hugmesh.net`) rather than a
templated `{{CLUSTER_DOMAIN}}` — that templating only applies to
`templates/apps/*.hbs` for *other* tenant brands. There's no need to fake a
different domain for this validation; you do need a way to resolve those
names to the kind node without editing `/etc/hosts` (no passwordless sudo
assumed). `kind-local.yaml` maps the node's hostNetwork `ingress-nginx-internal`
ports out to the docker host at `:8080`/`:8443`, so from the dev machine:

```bash
curl -k --resolve registry.hugmesh.net:8443:127.0.0.1 https://registry.hugmesh.net:8443/v2/
curl -k --resolve scale.hugmesh.net:8443:127.0.0.1  https://scale.hugmesh.net:8443/
```

(`--resolve` only affects that one `curl` invocation — no system-wide DNS/hosts
change required.)

## Tear down

```bash
kind delete cluster --name hugmesh-local
```

(or whatever `KIND_CLUSTER_NAME` you used).
