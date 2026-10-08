# Username uniqueness + confusable rejection — policy and the Casdoor pre-signup gate

## What this is

Two registration-time rules protect the username namespace:

1. **Reserved (exact).** A handle may not **equal** a reserved label (a dedicated
   gateway route prefix or service subdomain). The source of truth and the
   enforcement are in [`docs/RESERVED-PREFIXES.md`](RESERVED-PREFIXES.md).
2. **Confusable (look-alike).** A handle may not be a **homoglyph, added-character
   or alternate spelling** of an existing username **or** a reserved label. An
   exact list cannot catch these: `4dmin` ~ `admin`, `аdmin` (Cyrillic а) ~ `admin`,
   `r00t` ~ `root`, `akk0ma` ~ `akkoma`, `ad-min` ~ `admin`.

This document covers the **generator (GitOps) repo's** part of rule 2: the
**Casdoor pre-signup gate** that runs the confusable engine in front of the
platform's universal self-signup. The engine itself (the skeleton algorithm, the
availability endpoint, the DB table) lives in **`hugmesh-federation-api`**. The
per-layer registration checks live in `user-bff-api`, `hugmesh-actions` and
`admin-bff-api`. Those repos own their own changes. This page summarizes the
policy so the GitOps wiring makes sense.

## The skeleton — a RECOMPUTABLE CACHE, not a unique DB identity

The confusable engine reduces each candidate to a canonical **skeleton** and
compares skeletons. **The skeleton is not a unique database identity.** It is a
**derived cache** (a non-unique index) that can be recomputed. Two reasons:

- ICU documents that confusable **skeletons are not stable across ICU
  releases** ([ICU4J `SpoofChecker`](https://unicode-org.github.io/icu-docs/apidoc/released/icu4j/com/ibm/icu/text/SpoofChecker.html)).
  A `UNIQUE(skeleton)` constraint would become wrong on an ICU upgrade.
- The **real DB backstop stays the exact username**: the existing slug `UNIQUE`
  constraint and the `017` (federation) / `004` (user-bff) `NOT IN` CHECKs. This
  work never weakens them.

In practice: `icu4j` is **pinned**. Every ICU upgrade goes through a **re-index
migration** that recomputes all skeletons and re-checks collisions in one
transaction before commit. The skeleton column carries a `skeleton_icu_version`,
so a version mismatch can be detected.

The algorithm runs once per candidate, in this order (owned by federation-api's
`UsernameSkeletonService`):

1. lowercase and trim (`Locale.ROOT`);
2. **reject** (do not strip) any default-ignorable, format (Cf), zero-width
   (`U+200B–200D`, `U+FEFF`) or bidi-control (`U+202A–202E`, `U+2066–2069`) code
   point, before any folding;
3. NFKD-normalize, then strip combining marks (category Mn);
4. ICU `SpoofChecker` with `CONFUSABLE | RESTRICTION_LEVEL` (MODERATELY_RESTRICTIVE):
   reject mixed-script, then `getSkeleton` (`getBidiSkeleton` for RTL-capable
   surfaces such as `displayName`);
5. ASCII leet/homoglyph fold (`0→o`, `1→l/i`, `5→s`, …), **without** the known
   over-blockers `rn→m` and `vv→w`;
6. strip separators (`-`, `_`, `.`, space);
7. collapse runs of length **≥ 3**, so `anna` and `matt` survive while `rooot→root`
   and `aaadmin→admin` still collide.

Match tiers (reject if any holds):
(a) `skeleton == existing user's skeleton`;
(b) `skeleton ∈` the precomputed **reserved-skeleton** set;
(c) length-scaled Damerau-Levenshtein typo-squat distance to the reserved-skeleton set;
(d) an anti-impersonation affix rule (`reserved + {official, team, support, -1, …}`)
for the high-value reserved set.

**Self-exclusion is by exact username only.** A different owner with a confusable
handle is still flagged.

## The availability endpoint (federation-api, INTERNAL)

`GET /api/federation/username/{candidate}/availability` →
`{available, collide, reason: exact|confusable|reserved, matchedWith, skeleton}`.
It is **internal and `ROLE_SERVICE` gated**. It is not public, because it would be
an enumeration oracle. It runs at BOTH the write (registration) and read
(`VanityController.resolveLabel`) layers.

`override=confusable` is honored for `ROLE_ADMIN` only and is audited. It turns a
`confusable` or `exact` verdict into `available`. It **never** overrides
`reserved` or a hard reject (`mixed-script`, `zero-width`, `empty`)
(`UsernameAvailabilityController` javadoc in federation-api).

## The Casdoor pre-signup gate (this repo)

Casdoor is the platform's universal self-signup mint. Its native forbidden-username
list is **exact-only**, so it cannot reject a confusable. The
[`manifests/signup-gate/`](../specs/cluster/manifests/signup-gate/) proxy closes
that gap.

### Mechanism — a thin reverse-proxy in front of the signup endpoints

`signup-gate` (namespace `hugmesh-pki`) is a small stdlib reverse proxy. The
pki-gateway sends the two username-minting paths to it FIRST, before the
`casdoor-*` routes:

| path | what it is | gated |
|---|---|---|
| `POST /api/signup` | native self-signup | yes (username from body) |
| `POST /api/login` | normal login **and** OAuth provider signup-completion | only the `type=signup` branch |

For a minting request the proxy does this:
1. reads the candidate username;
2. mints a Casdoor **client-credentials service JWT** (`app-signup-gate` / `ROLE_SERVICE`);
3. calls the federation availability endpoint;
4. on `collide=true`, returns **HTTP 409**. The signup is never forwarded to
   Casdoor, so no confusable login is minted;
5. otherwise forwards the original request unchanged to `casdoor:8000` and
   streams the response back.

**Every other path passes through untouched.**

**Fail-closed:** if the availability check is unreachable (short timeout plus one
retry), the proxy **rejects** the signup (`503`). It does not admit a possible
confusable during a federation outage. `reserved` and `exact` keep their own local
and DB backstops; this gate adds the confusable dimension. `AVAILABILITY_FAIL_OPEN`
can flip this for a controlled rollout. The default is `false`.

### Why a proxy and not (only) a Casdoor webhook

Casdoor's native webhooks fire **after** the event. They can audit and reconcile
but cannot **veto** a signup. The **pre-signup proxy is therefore the primary
gate**.

A Casdoor native webhook is also registered (by `casdoor-init`, see below) as a
**post-signup reconcile backstop**. It POSTs the signup/update event to the proxy's
`/casdoor/webhook` path. The proxy re-runs availability and **disables**
(`setForbidden`) any confusable that slipped past the pre-gate (a race, a backfill,
or an ICU skeleton shift).

### Wiring (files in this repo)

- [`manifests/signup-gate/proxy-configmap.yaml`](../specs/cluster/manifests/signup-gate/proxy-configmap.yaml):
  the stdlib proxy `proxy.py` (pre-signup gate + `/casdoor/webhook` backstop).
- [`manifests/signup-gate/deployment.yaml`](../specs/cluster/manifests/signup-gate/deployment.yaml):
  `Deployment` and `Service` (`signup-gate:8000` → casdoor). It reads
  `FEDERATION_URL`, the `signup-gate-casdoor` clientId/secret, and the optional
  `signup-gate-webhook` secret. Fail-closed by default, read-only root filesystem,
  all capabilities dropped, non-root, MCS level `c36`.
- [`apps/05a-signup-gate.yaml`](../specs/cluster/apps/05a-signup-gate.yaml):
  ArgoCD app (sync-wave 1, after casdoor and federation-api).
- [`apps/20-gateway-pki.yaml`](../specs/cluster/apps/20-gateway-pki.yaml): the
  `signup-gate-signup` and `signup-gate-login` routes, BEFORE the casdoor routes.
- [`manifests/casdoor/init-data-configmap.yaml`](../specs/cluster/manifests/casdoor/init-data-configmap.yaml):
  `ROLE_SERVICE` role and `svc-signup-gate` machine user.
- [`manifests/casdoor/init-job.yaml`](../specs/cluster/manifests/casdoor/init-job.yaml):
  the `app-signup-gate` OAuth2 application (client-credentials) and the
  `signup-gate-reconcile` native webhook registration.
- [`manifests/external-secrets/secretstore.yaml`](../specs/cluster/manifests/external-secrets/secretstore.yaml):
  `signup-gate-casdoor` (clientId/secret from Vault `casdoor-apps` property
  `signup-gate`) and the optional `signup-gate-webhook`.
- [`scripts/gen-cluster-secrets.sh`](../scripts/gen-cluster-secrets.sh): adds
  `signup-gate` to `CASDOOR_APPS`, so the per-app client secret is generated and
  stored in Vault.

### Operational prerequisites / honest scope

- **The federation availability endpoint must exist.** It does:
  `UsernameAvailabilityController` on `hugmesh-federation-api` `main` serves
  `/api/federation/username/{candidate}/availability`. If the federation image a
  cluster runs predates it, the fail-closed proxy answers 503 to every signup.
  Deploy a federation-api that carries the endpoint first, or set
  `AVAILABILITY_FAIL_OPEN=true` for the interim.
- **Cross-namespace reachability is NOT admitted.** The proxy calls
  `hugmesh-federation-api.hugmesh-backend:8080` from `hugmesh-pki`. No
  NetworkPolicy in `specs/cluster/manifests/networkpolicy/` admits `signup-gate`
  to federation-api:8080. The `hugmesh-backend` `tier-ingress` policy admits only
  the `hugmesh-backend`, `hugmesh-frontend`, `devops` and `ingress-nginx`
  namespaces, and `gateway-crossns-ingress.yaml` adds only the superadmin gateway.
  `apps/08-networkpolicy.yaml` auto-syncs, so on a cluster running it the call is
  dropped and the fail-closed proxy rejects the signups it gates. Add a from-rule
  for `signup-gate` before relying on this gate. (Tier ingress is default-deny, so
  the old default-allow dev posture no longer lets the call through.)
- **The Casdoor API shape is version-specific.** The signup body field, the
  `/api/login` `type=signup` branch, the client-credentials token endpoint and the
  webhook event schema must be validated against the deployed
  `casbin/casdoor:3.80.0`. The proxy is a reviewed scaffold. Keep the admin-bff
  `CasdoorReservedSync` reconcile/sweep job enabled as a backstop until it is
  verified live.
- **No secrets in git.** All credentials come from Vault through ESO.

## displayName (companion surface, user-bff-api)

`displayName` is free text and is the real human-visible impersonation vector. It
gets the same SpoofChecker mixed-script and restriction-level checks, the same
zero-width and bidi rejection, and a skeleton-collision check against reserved
labels and other users, at `ProfileService.save` (owned by `user-bff-api`). It ties
into the `displayName` + `screenReaderName` profile feature.
