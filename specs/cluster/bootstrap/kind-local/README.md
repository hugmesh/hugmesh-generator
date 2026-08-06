# kind-local — local kind bring-up (Vault + PKI + Casdoor + Harbor, + SSO slice)

> **`KIND_PROFILE=sso`** extends the core slice below with the **native-login
> path** — Cassandra, the route-access seed DB, the fe-gateway chart (Ingress
> re-classed to `nginx-internal`), admin-bff + user-bff (+ their Postgres), the
> Angular host shell and the login/social UI remotes — then seeds Vault KV
> (`scripts/gen-cluster-secrets.sh` ONLINE mode through a `kubectl exec` shim
> into `vault-0`, so no host `vault` CLI is needed) and the deterministic e2e
> identity catalogue (`tests/qemu/seed-accounts.sh --roles` applied over a
> Casdoor port-forward). First-party images are **built locally and
> `kind load`ed** under the exact refs the manifests render
> (`registry.hugmesh.systems/hugmesh/<repo>:main`, gateway `:dev`) — the
> in-cluster Harbor is empty on a fresh cluster and is not used.
>
> Driven end-to-end from the repo root:
>
> ```sh
> make kind-up       # bootstrap-kind.sh KIND_PROFILE=sso (idempotent — an
>                    # already-seeded Vault KV is KEPT, not re-minted; see
>                    # "The script is idempotent" below for why that matters)
> make kind-images   # build from ./.stack-src + kind load  (before/after kind-up both work)
> make kind-e2e      # spec 27 (native login) against https://hugmesh.systems:8443
> make kind-down
> ```
>
> `make kind-e2e` maps `hugmesh.systems -> 127.0.0.1` with a Chromium
> host-resolver rule (no `/etc/hosts`, no sudo) and rides the
> `kind-local.yaml` 443→8443 host port map into the internal ingress. This is
> the kind-cluster leg of the SSO e2e roadmap item — the same proof
> `tests/e2e/specs/27-native-login.spec.ts` runs against the compose stack.

A reusable, local, single-node [kind](https://kind.sigs.k8s.io/) cluster that
brings up a **curated slice** of the HugMesh GitOps tree so you can
validate the Vault → PKI → Casdoor → Harbor chain before it ever touches the
real multi-Pi hardware. This targets the **CORE reference `hugmesh.systems`
apps/ tree** (`specs/cluster/apps/*.yaml` as committed to this repo) — it is
NOT a brand-templated tenant bring-up (that's `templates/apps/*.hbs` +
`brands/*.conf`, a separate rendering layer this script doesn't touch).

This tree was exercised end-to-end for the first time from this branch. Three
real, previously-unexercised bootstrap bugs were found and are baked into this
script/these manifests from the start (not left for the next person to
rediscover by trial and error) — see "Known bugs fixed here" below.

## Why a curated subset, not the real bring-up

`specs/cluster/bootstrap/bootstrap.sh` installs ArgoCD and then applies the
root `specs/cluster/app-of-apps.yaml`, which syncs **all 81** `Application`
objects under `specs/cluster/apps/*.yaml` — the entire platform (GitLab,
Cassandra, all 4 gateways, Matrix/tuwunel, Mastodon/Akkoma, games,
media-poisoner, analytics, observability, …). That's correct for a real
deployment but deliberately too much for validating one change: it's slow,
heavy, and syncs dozens of Applications that a Vault/PKI/Casdoor/Harbor change
never touches.

This script applies **only** the Applications needed to validate that chain,
directly with `kubectl` — **not** via the root app-of-apps.

### Included (and why)

| Application file | Why it's here |
|---|---|
| `apps/02-vault.yaml` | The cluster secret store — the thing being validated. |
| `apps/06-vault-pki.yaml` | The PostSync Job that bootstraps `pki_int` + per-app issuing roles (including the `harbor` role added by the Harbor migration). |
| `apps/03-external-secrets.yaml` | ESO controller + CRDs — required for anything to read from Vault. |
| `apps/04-external-secrets-config.yaml` | The `ClusterSecretStore "hugmesh-vault"` + the `ExternalSecret`s that use it. |
| `apps/11-ingress-nginx-internal.yaml` | The `nginx-internal` IngressClass — Harbor's Ingress (from the migration branch) uses this class. The public `nginx` controller (`apps/10-ingress-nginx.yaml`) is skipped; nothing here needs public ingress. |
| `apps/05-casdoor.yaml` | The identity provider + its own dedicated `casdoor-pg` Postgres (Casdoor has zero Cassandra dependency). |
| `apps/03a-harbor.yaml` + `apps/03b-harbor-provision.yaml` | The registry being migrated onto Vault-PKI-issued TLS + Casdoor OIDC. Not yet on `main` — see "Harbor is unmerged" below. |

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
   For a local kind cluster there is no KEYS USB, so the same manual
   `ARGOCD_REPO_TOKEN` export remains a prerequisite here.
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

## Harbor is unmerged — how this script handles it

The Harbor registry migration lives on branch `feat/harbor-registry-migration`
(open **draft** PR #254) — `main` has no Harbor manifests at all yet. This
script fetches Harbor's two `Application` objects straight from that branch
(`git show <branch>:specs/cluster/apps/03a-harbor.yaml` /
`03b-harbor-provision.yaml`) rather than from the local `main` checkout:

- **`03a-harbor.yaml`** sources a Helm chart (`helm.goharbor.io`), not a git
  path in this repo — applied as-is, no `targetRevision` rewrite needed.
- **`03b-harbor-provision.yaml`** sources a git path
  (`specs/cluster/manifests/harbor`) that only exists on the migration branch,
  so its `targetRevision: main` is rewritten to
  `targetRevision: feat/harbor-registry-migration` before applying, so
  ArgoCD's own controller fetches the *correct* manifest content live from
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
| `HUGMESH_GITOPS_REPO` | `https://github.com/Snapdragon-Systems/hugmesh-generator.git` | repoURL rewritten into every non-Harbor Application (fork support, mirrors `bootstrap.sh`) |
| `HUGMESH_GITOPS_REV` | `main` | targetRevision rewritten into every non-Harbor Application |
| `HARBOR_BRANCH` | `feat/harbor-registry-migration` | branch the two Harbor Applications (+ `03b`'s manifests) are fetched from |
| `VAULT_BRANCH` | `feat/kind-local-bringup` | branch `02-vault.yaml` (and, live, `manifests/vault`) is fetched from — carries the `vault-tls-init` openssl fix (bug #2 above) until it merges to `main`; drop it (or set to `main`) once merged |
| `SKIP_VAULT_BOOTSTRAP` | `0` | set `1` to stop after applying the curated Applications, before the Vault init/unseal/PKI step |
| `KIND_KV_RESEED` | `0` | `KIND_PROFILE=sso` only. Set `1` to re-mint **every** cluster secret even though Vault KV is already seeded. **DESTRUCTIVE**: existing Postgres/Cassandra volumes keep the old passwords and will reject the new ones — correct only against a fresh cluster or wiped PVCs. |
| `ARGOCD_REPO_TOKEN` | *(unset)* | **required** for the git-path Applications (Vault, vault-pki, ESO config, Casdoor, harbor-provision) to actually sync — see below |

### Repo credentials (`ARGOCD_REPO_TOKEN`)

`hugmesh-generator` is a **private** GitHub repo. ArgoCD's repo-server has
no credential for it out of the box, so every git-path `Application` in the
curated set fails to sync with `authentication required: Repository not
found` until one is registered. The real cluster registers this on its own
bootstrap path (`../bootstrap.sh`), with the token sourced out-of-band from the
offline KEYS USB (`KEYS/gitops/repo-token`) by `keys-provision` (exported as
`ARGOCD_REPO_TOKEN`); there's no such side-channel for a local kind cluster, so
this script is **strictly opt-in** here — it never runs `gh` or anything else
to fetch a token on its own, because silently materializing a live personal
credential into cluster storage as a side effect of "just run the script"
is exactly the kind of thing that should require an explicit, deliberate
choice. Export a token yourself before running it:

```bash
export ARGOCD_REPO_TOKEN="$(GH_TOKEN= gh auth token)"   # or any PAT with read access to the repo
./bootstrap-kind.sh
```

Without it, the script still completes (ArgoCD installs, the curated
Applications get created, local storage/namespaces/Vault-init all work), but
`vault`, `vault-pki`, `external-secrets-config`, `casdoor`, and
`harbor-provision` will sit at sync status `Unknown` with a
`ComparisonError` until a token is supplied and those Applications are
resynced (ArgoCD retries automatically once the credential exists — no need
to re-run this script, just export the var and re-run, or add the Secret by
hand per the ArgoCD docs).

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

1. Create the kind cluster from `kind-local.yaml` (single control-plane node;
   this is a validation tool, not a hardware topology simulation) — skipped
   if it already exists.
2. Label the node `snapdragon.systems/pki=true` +
   `snapdragon.systems/local-path=true` (the only two capability labels the
   curated manifests actually select on — checked by grepping every
   `nodeSelector` in the included manifests; `kubernetes.io/arch=amd64` is
   already correct on a kind/amd64 node).
3. Apply namespaces + the `hugmesh-local` StorageClass, and strip the
   default-class annotation from kind's own `standard` StorageClass (both
   would otherwise claim to be *the* cluster default).
4. Install ArgoCD into namespace `devops`, pinned to
   `kubernetes.io/arch=amd64` — reusing `../bootstrap.sh`'s exact
   install/re-namespace/pin logic (NOT its root app-of-apps step).
5. Apply the curated `Application` subset described above directly with
   `kubectl` (not the root app-of-apps).
6. Wait (best-effort, 5 minute budget) for those Applications to reach
   `Synced`/`Healthy`, printing a status table either way.
7. **LOCAL-DEV-ONLY**: run the one-time `vault operator init -key-shares=1
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
(`registry.hugmesh.systems`, `*.hugmesh.systems`) rather than a
templated `{{CLUSTER_DOMAIN}}` — that templating only applies to
`templates/apps/*.hbs` for *other* tenant brands. There's no need to fake a
different domain for this validation; you do need a way to resolve those
names to the kind node without editing `/etc/hosts` (no passwordless sudo
assumed). `kind-local.yaml` maps the node's hostNetwork `ingress-nginx-internal`
ports out to the docker host at `:8080`/`:8443`, so from the dev machine:

```bash
curl -k --resolve registry.hugmesh.systems:8443:127.0.0.1 https://registry.hugmesh.systems:8443/v2/
curl -k --resolve scale.hugmesh.systems:8443:127.0.0.1  https://scale.hugmesh.systems:8443/
```

(`--resolve` only affects that one `curl` invocation — no system-wide DNS/hosts
change required.)

## Tear down

```bash
kind delete cluster --name hugmesh-local
```

(or whatever `KIND_CLUSTER_NAME` you used).
