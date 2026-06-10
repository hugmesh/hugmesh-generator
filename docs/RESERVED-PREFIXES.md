# Reserved usernames / prefixes — the canonical rule and its enforcement layers

## What this is

A **reserved label** is a username / vanity-profile handle that a user may
**never** register, because the same label is (or may become) a **dedicated app
path-prefix or subdomain route** on the platform gateways. Vanity profiles are
addressed as:

- `<username>.snapdragon.systems` (a subdomain; resolved by the fe-gateway
  `Host=*.snapdragon.systems` route → federation-api, see
  [`docs/ROUTE-ACCESS.md`](ROUTE-ACCESS.md) and the cluster README "Vanity
  subdomains"), and the equivalent `*.snapdragon.games` surfaces.

If a user could register, say, `admin`, then `admin.snapdragon.systems` /
`snapdragon.systems/admin` would **shadow** (or be shadowed by) the real
platform route — a **vanity-collision**. The reserved set forbids exactly those
labels.

The reserved set is the **union** of:

- every dedicated **fe/be/pki gateway route prefix** (path first-segment),
- every reserved service **subdomain** (first DNS label),
- the **snapdragon.games** app prefixes, and
- defensive standard **web names** (`well-known`, `favicon`, `robots`,
  `health`/`healthz`, `metrics`, …).

## The rule

> **Every dedicated gateway route prefix MUST appear in the reserved list, and
> the app-repo `ReservedNames` copies MUST be kept in sync with it.**

A newly added route prefix that is *not* reserved is **drift**: the
route-consistency check (below) fails the build/sync so it can never ship.

## The canonical source of truth

[`specs/cluster/reserved-prefixes.yaml`](../specs/cluster/reserved-prefixes.yaml)
— `spec.reserved` is **the** list. Everything else is derived from or checked
against it. It currently holds **61** labels (the 60-label union shared with the
app repos **plus `pleroma`** — akkoma's AdminFE is served at `/pleroma/admin/**`
on the be-gateway, a dedicated route prefix the consistency check surfaced;
the app-repo copies must add it too).

## The enforcement layers

| Layer | Where | What it enforces |
|---|---|---|
| **vanity-resolve** | `federation-api` `VanityController` / `ReservedNames` | refuses a reserved first-label when resolving `<user>.snapdragon.systems` |
| **profile DB / registration** | `user-bff-api` `ReservedNames`, `snapdragon-actions` | a profile/handle can't be saved/registered with a reserved name |
| **admin-route management** | `admin-bff-api` `ReservedNames` | an admin can't create a route-access row that conflicts with a reserved name |
| **GitOps / admission** *(this repo)* | Kyverno `ClusterPolicy` + ConfigMap | blocks vanity-shadowing Ingress/HTTPRoute hosts + reserved vanity CRD handles at admission/sync |
| **route-federation consistency** *(this repo)* | `scripts/validate-reserved-prefixes.sh` (CI lint) | asserts the canonical set ⊇ every deployed route prefix; fails on drift |

The first three are the **app-repo** layers (already in place). This document
adds the last two — the **GitOps/ArgoCD layer** — so the reserved set is the
single auditable source of truth and drift is caught at build *and* sync time.

## The GitOps / ArgoCD layer (this repo)

### 1. Canonical source + in-cluster mirror

- [`specs/cluster/reserved-prefixes.yaml`](../specs/cluster/reserved-prefixes.yaml)
  — the source.
- [`specs/cluster/manifests/policy/reserved-prefixes-configmap.yaml`](../specs/cluster/manifests/policy/reserved-prefixes-configmap.yaml)
  — a ConfigMap (`snapdragon-policy/reserved-prefixes`) that mirrors the list
  into the cluster as `reserved.json`. This is the **auditable in-cluster copy**
  the Kyverno policy reads, so the policy and the source can't drift.
- Regenerate the mirror with
  [`scripts/sync-reserved-configmap.sh`](../scripts/sync-reserved-configmap.sh)
  after editing the source.

### 2. Admission policy (Kyverno) — chosen approach

[`specs/cluster/manifests/policy/reserved-prefixes-policy.yaml`](../specs/cluster/manifests/policy/reserved-prefixes-policy.yaml)
is a Kyverno `ClusterPolicy` (`validationFailureAction: Enforce`) that reads the
reserved list **from the ConfigMap** (single source) and:

1. **rejects an Ingress** whose host's first DNS label under
   `*.snapdragon.systems` / `*.snapdragon.games` is reserved (unless the object
   is a platform component, `app.kubernetes.io/part-of=snapdragon.systems`),
2. **rejects a Gateway-API `HTTPRoute`** on the same hostname rule, and
3. **defensively rejects** a `VanityClaim`/`Profile`/`User` CRD whose handle is
   reserved — **inert** until such a CRD exists (the kind won't match), so it is
   safe to ship now as defence-in-depth mirroring the app-repo `ReservedNames`.

**Why Kyverno** (over an OPA/Gatekeeper or a custom webhook): the reserved set
is a small **data list** the policy reads from a ConfigMap, so there is no
custom webhook image to build/maintain and the list stays the single source of
truth. No policy engine was previously present in `apps/`, so this adds one:

- [`specs/cluster/apps/15-kyverno.yaml`](../specs/cluster/apps/15-kyverno.yaml)
  — deploys the Kyverno chart (sync-wave `-1`, so the CRDs exist first).
- [`specs/cluster/apps/16-reserved-prefixes-policy.yaml`](../specs/cluster/apps/16-reserved-prefixes-policy.yaml)
  — applies the ConfigMap + ClusterPolicy (default wave, after Kyverno).

### 3. The always-on drift guard (works with or without Kyverno)

Kyverno can only validate **resources that exist** in the cluster — but the
platform routes via **Spring Cloud Gateway route tables** (in the gateway-app
Helm values) + the **route-access DB**, not via Ingress/HTTPRoute path rules. So
the **authoritative** drift guard is
[`scripts/validate-reserved-prefixes.sh`](../scripts/validate-reserved-prefixes.sh),
which parses:

- `specs/cluster/apps/20-gateway-*.yaml` (route `path:`/`host:` + ingress
  `host`/`extraHosts`), and
- `specs/cluster/manifests/route-access/initdb/20-schema.sql` (`url_pattern` rows),

and asserts the canonical reserved set is a **superset** of every first-segment
prefix / first-label subdomain found. It also asserts the **ConfigMap mirror ==
the source**. It is wired into [`.gitlab-ci.yml`](../.gitlab-ci.yml) as the
`lint:reserved-prefixes` stage (runs first on every branch). This is what
catches a newly added route prefix before it ships, independent of whether
Kyverno is installed.

## Adding a new dedicated route prefix (the workflow)

1. Add the route to the gateway app / `schema.sql` as usual.
2. Add the new first-segment label to `spec.reserved` in
   `specs/cluster/reserved-prefixes.yaml`.
3. Run `scripts/sync-reserved-configmap.sh` to regenerate the ConfigMap mirror.
4. Run `scripts/validate-reserved-prefixes.sh` — it must PASS.
5. **Add the same label to the app-repo `ReservedNames` copies**
   (federation-api / user-bff-api / snapdragon-actions / admin-bff-api) so the
   resolve/registration/admin layers agree.

## Honest scope / deferrals

- The Kyverno policy enforces **Ingress/HTTPRoute hosts** and **vanity CRD
  handles**. The platform's actual routing is Spring Cloud Gateway tables, which
  Kyverno does not parse — the **validate script + CI lint** are the real drift
  guard for those (and the PreSync-style guard, since the same script can run as
  an ArgoCD resource hook). This split is intentional and documented above.
- The app-repo `ReservedNames` copies are **not** auto-generated from this
  source (they live in three other repos). Step 5 above is a manual sync; a
  follow-up could publish `reserved.json` as a build artifact the app repos pull.
- `pleroma` was added to the canonical set by the consistency check; the app
  repos must add it to reach parity.
