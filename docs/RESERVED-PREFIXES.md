# Reserved usernames / prefixes — the canonical rule and its enforcement layers

## What this is

A **reserved label** is a username / vanity-profile handle that a user may
**never** register, because the same label is (or may become) a **dedicated app
path-prefix or subdomain route** on the platform gateways. Vanity profiles are
addressed as:

- `<username>.hugmesh.net` (a subdomain; resolved by the fe-gateway
  `Host=*.hugmesh.net` route → federation-api, see
  [`docs/ROUTE-ACCESS.md`](ROUTE-ACCESS.md) and the cluster README "Vanity
  subdomains"), and the equivalent `*.hugmesh.games` surfaces.

If a user could register, say, `admin`, then `admin.hugmesh.net` /
`hugmesh.net/admin` would **shadow** (or be shadowed by) the real
platform route — a **vanity-collision**. The reserved set forbids exactly those
labels.

The reserved set is the **union** of:

- every dedicated **fe/be/pki gateway route prefix** (path first-segment),
- every reserved service **subdomain** (first DNS label),
- the **hugmesh.games** app prefixes, and
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
against it. It currently holds **82** labels (`metadata.revision: "9"`). Revision 2
held 65; the label counts by revision are 65 (2), 70 (3), 72 (4), 76 (5), 77 (6),
78 (7), 79 (8) and 82 (9). The 65 of revision 2 were:

- the 60-label union shared with the app repos, **plus `pleroma`** — akkoma's
  AdminFE is served at `/pleroma/admin/**` on the be-gateway (revision 1),
- **plus `_synapse` + `media`** — the publicly-routable homeserver client
  surfaces the route-access seed deploys on the be-gateway (`/_synapse/**`
  Matrix Synapse-compat, `/media/**` Mastodon media); real first-segment route
  prefixes a vanity username could shadow, surfaced by the consistency check,
- **plus `forum` + `phpbb`** — the phpBB community forum is a **real, deployed,
  DEFAULT-ON, live-routed** optional service since PR #164 (2026-06-23):
  `apps/30-phpbb.yaml`, `38-forum-bff-db.yaml`, `39-forum-bff-api.yaml`,
  `49-forum-ui.yaml` are all synced ArgoCD Applications, and `ROLE_FORUM` /
  `ROLE_FORUM_MOD` rows are seeded in
  [`20-schema.sql`](../specs/cluster/manifests/route-access/initdb/20-schema.sql).
  Its only public surfaces ride already-reserved prefixes (`/social/forum/**`,
  `/bff/forum/**`) rather than a dedicated `forum`-first-segment route, so —
  same shape as the `owncast`/`wiki` forward-reserves in
  [`reserved-prefixes.yaml`](../specs/cluster/reserved-prefixes.yaml) — the
  route-consistency check doesn't demand the label; it is reserved defensively
  so a vanity `forum`/`phpbb` handle (or a future `forum.<domain>` subdomain)
  can never collide.

Later revisions added (names as in the file's header comment): revision 3 `tube`,
`games-instances-console`, `superadmin`, and the forward-reserves `owncast` and
`wiki`; revision 4 `character-studio` and `v1` (the `/v1/analyze/**` route); revision 5
the webroot filenames `index.html`, `favicon.ico`, `importmap.json` and
`remoteEntry.json`; revision 6 `ai` (the `ai.<domain>` edge-AI host); revision 7 `hmdm`;
revision 8 `attest`; revision 9 `character-forge`, `games-character-forge` and
`games-shadows-of-the-net`. `hmdm`, `attest` and `character-forge` are real
first-segment routes that shipped in the same change as the route, unlike the
`forum`/`phpbb`/`owncast`/`wiki` forward-reserves.

PR numbers on this page (for example "PR #164") come from the pre-squash history
and no longer resolve to the same work in the org; rely on the named files.

The three app-repo `ReservedNames` copies must add the same labels to stay in
sync (the validate script's **code-copy assertion** flags them mechanically, and
a run that could not reach those copies reports `INCOMPLETE`, not `PASS` — see
below).

### What is NOT reserved (and why)

The reserved set is **publicly-routable first-labels only** — NOT a list of every
`kind: Service`. Internal, non-publicly-routable Services are deliberately
excluded so the username namespace isn't needlessly shrunk:

- the akkoma-proxy / tuwunel-proxy **mTLS sidecars** (reached only behind the
  already-reserved `mastodon.` / `matrix.` hosts),
- `*-db` / `*-pg` **datastores**, `kafka` / `eureka` / `cassandra` / `clickhouse`
  brokers, `lan-dns`, and the `hugmesh-*-api` / `-ui` / `-web` pod helpers
  (each reached via its **reserved path/host prefix**, not by its bare branded
  Service name — which sed-rebrands per deployer anyway).

The validate script enforces this scope via an **explicit internal allowlist**
(`SERVICE_ALLOW_EXACT` / `SERVICE_ALLOW_PATTERNS`) so a naive "every Service must
be reserved" rule — which would be **red on day one** — is avoided.

## The enforcement layers

| Layer | Where | What it enforces |
|---|---|---|
| **vanity-resolve** | `federation-api` `VanityController` / `ReservedNames` | refuses a reserved first-label when resolving `<user>.hugmesh.net` |
| **profile DB / registration** | `hugmesh-auth-core` `ReservedNames` (consumed by `user-bff-api` and `admin-bff-api`), `hugmesh-actions` | a profile/handle can't be saved/registered with a reserved name |
| **admin-route management** | `hugmesh-auth-core` `ReservedNames` (via `admin-bff-api`) | an admin can't create a route-access row that conflicts with a reserved name |
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
  — a ConfigMap (`hugmesh-policy/reserved-prefixes`) that mirrors the list
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
   `*.hugmesh.net` / `*.hugmesh.games` is reserved (unless the object
   is a platform component, `app.kubernetes.io/part-of=hugmesh.net`),
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

The script runs **five stages** (each fails the build on a violation), plus a
half-rename gate that rejects first-party workload names carrying the retired
`-systems-` infix and checks that the host shell's paired names agree across the
manifests, the ArgoCD Application and the compose lane:

1. canonical source non-empty + no duplicates;
2. the in-cluster **ConfigMap mirror == the canonical source** exactly;
3. **route-consistency**: `reserved ⊇` every publicly-routable gateway route
   prefix (path/host first-segment + route-access `url_pattern` first-segment +
   reserved gateway hosts);
4. **scoped Service-name drift**: `reserved ⊇` the **publicly-routable Services**
   — those a gateway route `uri` actually targets — **minus** the explicit
   internal allowlist (the mTLS proxies, `*-db`/`*-pg`, the `hugmesh-*`
   family, casdoor/headscale/signup-gate). A routed Service whose public
   first-label is neither reserved nor allowlisted is drift. This is the
   **scoped** check — it never demands a label for a non-routable internal
   Service, so it is not red day-one;
5. **code-copy assertion**: each app-repo `ReservedNames.java`
   `RESERVED[_LABELS]` set is parsed and asserted **== the canonical set**
   (mechanical, replaces hand-counting). Copies are looked up under
   `RESERVED_SIBLING_ROOT` (default: checkouts next to this repo). The
   **deployed-but-defensive** reserves (`forum`/`phpbb`, `owncast`/`wiki`) are
   expected in the canonical set **without a dedicated first-segment route of
   their own** (their public surfaces ride already-reserved prefixes), so
   stages 3/4 never flag them.

### Stage 5 is REQUIRED — an unrun assertion is not a pass

Until 2026-07-29 an absent copy was reported `[SKIP]` and the run still ended
`RESULT: PASS`, exit 0 — while this repo's own CI job checked out no siblings, so
the assertion had **never once run in a pipeline**. That is how a
`hugmesh-actions` copy missing five canonical labels (`character-forge`, `hmdm`,
`attest`, `games-character-forge`, `games-shadows-of-the-net`) sat on a green
main. Now the verdict is honest:

| outcome | exit | meaning |
| --- | --- | --- |
| `RESULT: PASS` | 0 | consistent, **and every declared copy was checked** |
| `RESULT: FAIL` | 1 | drift / mismatch (offending labels printed) |
| *fatal* | 2 | environment problem (missing input, no python3/PyYAML) |
| `RESULT: INCOMPLETE` | 3 | no drift in the stages that ran, but ≥1 copy was absent so the code-copy assertion **did not run** |

Partial coverage counts as INCOMPLETE: 2 of 3 copies present is not a pass, since
the drifted copy could be the absent one.

To get a real PASS locally, point the gate at a tree holding the copies:

```bash
RESERVED_SIBLING_ROOT=/path/to/checkouts scripts/validate-reserved-prefixes.sh
```

`RESERVED_ALLOW_MISSING_COPIES=1` downgrades INCOMPLETE to exit 0 for a working
copy that genuinely has no siblings — but the verdict still reads
`RESULT: PASS (INCOMPLETE …)`, never a clean PASS. **Never set it in CI**:
`.gitlab-ci.yml`'s `lint:reserved-prefixes` clones the three sibling repos from
the org mirror (CI job token, same recipe as `sca:dependency-check`) so the
assertion genuinely runs, and `lint:reserved-prefixes-gate-honesty`
(`tests/scripts/test-reserved-prefix-copy-gate.sh`) proves the gate cannot go back
to reporting a clean PASS on a skipped run.

## Adding a new dedicated route prefix (the workflow)

1. Add the route to the gateway app / `schema.sql` as usual.
2. Add the new first-segment label to `spec.reserved` in
   `specs/cluster/reserved-prefixes.yaml`.
3. Run `scripts/sync-reserved-configmap.sh` to regenerate the ConfigMap mirror.
4. **Add the same label to the app-repo `ReservedNames` copies** so the
   resolve/registration/admin layers agree. Three physical copies:
   `hugmesh-federation-api`, `hugmesh-actions`, and `hugmesh-auth-core` (the
   shared one `user-bff-api` + `admin-bff-api` consume as a Maven dependency —
   they no longer carry their own file).
5. Run `RESERVED_SIBLING_ROOT=… scripts/validate-reserved-prefixes.sh` — it must
   print `RESULT: PASS`. A bare `RESULT: INCOMPLETE` means step 4 was **not
   verified**; do not treat it as done.

## Honest scope / deferrals

- The Kyverno policy enforces **Ingress/HTTPRoute hosts** and **vanity CRD
  handles**. The platform's actual routing is Spring Cloud Gateway tables, which
  Kyverno does not parse — the **validate script + CI lint** are the real drift
  guard for those (and the PreSync-style guard, since the same script can run as
  an ArgoCD resource hook). This split is intentional and documented above.
- The app-repo `ReservedNames` copies are **not** auto-generated from this
  source (they live in three other repos). Step 4 above is a manual sync; the
  validate script's **code-copy assertion** mechanically verifies it — CI now
  clones those repos so the assertion actually runs on every pipeline instead of
  skipping to a green result. A follow-up could publish `reserved.json` as a
  build artifact the app repos pull, removing the manual sync entirely.
- Every label added after revision 1 (`pleroma`, then `_synapse` / `media` /
  `forum` / `phpbb`, then the revision 3-9 labels above) must also reach the three
  copies (`hugmesh-federation-api` / `hugmesh-actions` / `hugmesh-auth-core`, the last
  covering `user-bff-api` + `admin-bff-api` via the Maven dependency). The code-copy
  assertion FAILs until they do — that is the intended signal.
- The scoped Service-name drift check (stage 4) keys on the route `uri` host, so
  it only sees Services a **gateway route** targets. A Service exposed by some
  other mechanism (a future Ingress/HTTPRoute) is covered by the Kyverno host
  policy, not stage 4. The internal allowlist is intentionally a script-side
  constant here; promoting it to a manifest label
  (`hugmesh.net/reserved-exempt: true`) is a documented follow-up.

## The Casdoor pre-signup confusable gate

The reserved rule above is **exact-match** (a handle equal to a reserved label).
The companion **username-confusable** policy rejects look-alike handles
(`4dmin` ~ `admin`, `аdmin` [Cyrillic] ~ `admin`, `r00t` ~ `root`,
`akk0ma` ~ `akkoma`) that an exact list can never catch. Casdoor — the platform's
universal self-signup identity mint — has only an **exact-only** forbidden-username
list, so a confusable login would otherwise be minted. The
[`manifests/signup-gate/`](../specs/cluster/manifests/signup-gate/) proxy is the
fail-closed enforcement seam in front of Casdoor's signup endpoints; see
[`docs/USERNAME-CONFUSABLE.md`](USERNAME-CONFUSABLE.md) for the full design.
