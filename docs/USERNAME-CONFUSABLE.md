# Username uniqueness + confusable rejection — policy and the Casdoor pre-signup gate

## What this is

Two complementary registration-time rules protect the username namespace:

1. **Reserved (exact)** — a handle may not **equal** a reserved label (a dedicated
   gateway route prefix / service subdomain). Source of truth + enforcement:
   [`docs/RESERVED-PREFIXES.md`](RESERVED-PREFIXES.md).
2. **Confusable (look-alike)** — a handle may not be a **homoglyph / added-char /
   alt-spelling** of an existing username **or** a reserved label. This catches
   what an exact list cannot: `4dmin` ~ `admin`, `аdmin` (Cyrillic а) ~ `admin`,
   `r00t` ~ `root`, `akk0ma` ~ `akkoma`, `ad-min` ~ `admin`.

This document covers the **generator (GitOps) repo's** part of (2): the
**Casdoor pre-signup gate** that runs the confusable engine in front of the
platform's universal self-signup. The engine itself (the skeleton algorithm, the
availability endpoint, the DB table) lives in **`snapdragon-federation-api`**;
the per-layer registration checks live in `user-bff-api` / `snapdragon-actions` /
`admin-bff-api`. Those repos own their own changes — this doc summarizes the
policy so the GitOps wiring is legible.

## The skeleton — a RECOMPUTABLE CACHE, not a unique DB identity

The confusable engine reduces each candidate to a canonical **skeleton** and
matches skeletons. **The skeleton is NOT a unique database identity** — it is a
**recomputable, derived cache** (a non-unique index). The reasons are load-bearing:

- ICU explicitly documents that confusable **skeletons are NOT stable across ICU
  releases** ([ICU4J `SpoofChecker`](https://unicode-org.github.io/icu-docs/apidoc/released/icu4j/com/ibm/icu/text/SpoofChecker.html));
  a `UNIQUE(skeleton)` constraint would become wrong on an ICU upgrade.
- The **real DB backstop stays the exact-username identity** — the existing slug
  `UNIQUE` constraint and the `017` (federation) / `004` (user-bff) `NOT IN`
  CHECKs — which are **never weakened** by this work.

Operationally: `icu4j` is **pinned**; every ICU upgrade is gated behind a
**re-index migration** that recomputes all skeletons and re-checks collisions in
one transaction before commit. The skeleton column carries a `skeleton_icu_version`
so a version mismatch is detectable.

Algorithm (computed once per candidate, in this order — owned by
federation-api's `UsernameSkeletonService`):

1. lowercase + trim (`Locale.ROOT`);
2. **reject** (do not strip) any default-ignorable / format (Cf) / zero-width
   (`U+200B–200D`, `U+FEFF`) / bidi-control (`U+202A–202E`, `U+2066–2069`) code
   point — before any folding;
3. NFKD normalize, strip combining marks (category Mn);
4. ICU `SpoofChecker` with `CONFUSABLE | RESTRICTION_LEVEL` (MODERATELY_RESTRICTIVE)
   — reject mixed-script, then `getSkeleton` (`getBidiSkeleton` for RTL-capable
   surfaces like `displayName`);
5. ASCII leet/homoglyph fold (`0→o`, `1→l/i`, `5→s`, …) — **without** the
   documented over-blockers `rn→m` and `vv→w`;
6. strip separators (`-`, `_`, `.`, space);
7. collapse runs of length **≥ 3** (so `anna` / `matt` survive while `rooot→root`,
   `aaadmin→admin` still collide).

Match tiers (reject if any holds): (a) `skeleton == existing user's skeleton`;
(b) `skeleton ∈` the precomputed **reserved-skeleton** set; (c) length-scaled
Damerau-Levenshtein typo-squat vs the reserved-skeleton set; (d) an
anti-impersonation affix rule (`reserved + {official, team, support, -1, …}`) for
the high-value reserved set. **Self-exclusion is by EXACT username only** — a
different owner with a confusable handle is still flagged.

## The availability endpoint (federation-api, INTERNAL)

`GET /api/federation/username/{candidate}/availability` →
`{available, collide, reason: exact|confusable|reserved, matchedWith, skeleton}`.
It is **INTERNAL / ROLE_SERVICE gated** (not public — it would be an enumeration
oracle) and applied at BOTH the write (registration) and read
(`VanityController.resolveLabel`) layers. `override=confusable` is honored for
`ROLE_ADMIN` only — **never** overriding `reserved`/`exact` — and is audited.

## The Casdoor pre-signup gate (this repo)

Casdoor is the platform's universal self-signup mint, but its native
forbidden-username list is **exact-only**, so it cannot reject a confusable. The
[`manifests/signup-gate/`](../specs/cluster/manifests/signup-gate/) proxy closes
that gap.

### Mechanism — a thin reverse-proxy in front of the signup endpoints

`signup-gate` (ns `snapdragon-pki`) is a small stdlib reverse-proxy. The
pki-gateway routes the two username-MINTING paths to it FIRST, before the
`casdoor-*` routes:

| path | what it is | gated |
|---|---|---|
| `POST /api/signup` | native self-signup | yes (username from body) |
| `POST /api/login` | normal login **and** OAuth provider signup-completion | only the `type=signup` branch |

For a minting request the proxy: reads the candidate username → mints a Casdoor
**client-credentials SERVICE JWT** (`app-signup-gate` / `ROLE_SERVICE`) → calls
the federation availability endpoint → on `collide=true` returns **HTTP 409**
(the signup is **never** forwarded to Casdoor, so no confusable login is minted) →
otherwise forwards the original request verbatim to `casdoor:8000` and streams the
response back. **Every other path is a transparent pass-through.**

**FAIL-CLOSED:** if the availability check is unreachable (short timeout + one
retry) the proxy **rejects** the signup (`503`) rather than admit a possible
confusable during a federation outage. `reserved`/`exact` retain their own local +
DB backstops; this gate adds the confusable dimension. (`AVAILABILITY_FAIL_OPEN`
can flip this for a controlled rollout, default `false`.)

### Why a proxy and not (only) a Casdoor webhook

Casdoor's native webhooks fire **after** the event — they can audit/reconcile but
cannot **veto** a signup. So the **pre-signup proxy is the PRIMARY gate**. A
Casdoor native webhook is *also* registered (by `casdoor-init`, see below) as a
**post-signup reconcile backstop**: it POSTs the signup/update event to the
proxy's `/casdoor/webhook` receiving path, which re-runs availability and
**disables** (`setForbidden`) any confusable that slipped past the pre-gate
(race / backfill / ICU skeleton shift). Belt and braces.

### Wiring (files in this repo)

- [`manifests/signup-gate/proxy-configmap.yaml`](../specs/cluster/manifests/signup-gate/proxy-configmap.yaml)
  — the stdlib proxy `proxy.py` (pre-signup gate + `/casdoor/webhook` backstop).
- [`manifests/signup-gate/deployment.yaml`](../specs/cluster/manifests/signup-gate/deployment.yaml)
  — `Deployment` + `Service` (`signup-gate:8000` → casdoor). Reads
  `FEDERATION_URL`, the `signup-gate-casdoor` clientId/secret, the optional
  `signup-gate-webhook` secret. Fail-closed by default; readOnlyRootFilesystem,
  drop ALL caps, non-root, fresh MCS level `c36`.
- [`apps/05a-signup-gate.yaml`](../specs/cluster/apps/05a-signup-gate.yaml) —
  ArgoCD app (sync-wave 1, after casdoor + federation-api).
- [`apps/20-gateway-pki.yaml`](../specs/cluster/apps/20-gateway-pki.yaml) — the
  `signup-gate-signup` / `signup-gate-login` routes BEFORE the casdoor routes.
- [`manifests/casdoor/init-data-configmap.yaml`](../specs/cluster/manifests/casdoor/init-data-configmap.yaml)
  — `ROLE_SERVICE` role + `svc-signup-gate` machine user.
- [`manifests/casdoor/init-job.yaml`](../specs/cluster/manifests/casdoor/init-job.yaml)
  — `app-signup-gate` OAuth2 application (client-credentials) + the
  `signup-gate-reconcile` native webhook registration.
- [`manifests/external-secrets/secretstore.yaml`](../specs/cluster/manifests/external-secrets/secretstore.yaml)
  — `signup-gate-casdoor` (clientId/secret from Vault `casdoor-apps` property
  `signup-gate`) + optional `signup-gate-webhook`.
- [`scripts/gen-cluster-secrets.sh`](../scripts/gen-cluster-secrets.sh) — adds
  `signup-gate` to `CASDOOR_APPS` so the per-app client-secret is generated +
  stored in Vault.

### Operational prerequisites / honest scope

- **Federation availability endpoint must exist** — it is delivered by the
  `snapdragon-federation-api` confusable PR (parallel work). Until it is live the
  fail-closed proxy would 503 every signup; deploy the federation change first, or
  set `AVAILABILITY_FAIL_OPEN=true` for the interim.
- **Cross-namespace reachability** — the proxy calls
  `snapdragon-federation-api.snapdragon-backend:8080` from `snapdragon-pki`. The
  NetworkPolicy tiers must admit `signup-gate` → federation-api:8080 (it does not
  today; add a from-rule when the netpol layer is activated — until then the
  default-allow dev posture lets it through).
- **Casdoor API shape is version-specific** — the signup body field, the
  `/api/login` `type=signup` branch, the client-credentials token endpoint, and
  the webhook event schema must be validated against the deployed
  `casbin/casdoor:3.80.0`. The proxy is a reviewed scaffold; keep the admin-bff
  `CasdoorReservedSync` reconcile/sweep job enabled as a backstop until verified
  live.
- **No secrets in git** — all credentials are ESO-from-Vault.

## displayName (companion surface, user-bff-api)

`displayName` is free text and is the actual human-visible impersonation vector;
it gets the same SpoofChecker mixed-script / restriction-level + zero-width/bidi
rejection and a skeleton-collision-vs-reserved/other-users check at
`ProfileService.save` (owned by `user-bff-api`). It ties into the
`displayName` + `screenReaderName` profile feature.
