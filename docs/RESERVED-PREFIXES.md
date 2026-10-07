# Reserved usernames / prefixes — the canonical rule and its enforcement layers

## What this is

A **reserved label** is a username or vanity-profile handle that no user may ever
register, because the same label is (or may become) a dedicated app path prefix or
subdomain route on the platform gateways. Vanity profiles are addressed as:

- `<username>.hugmesh.net` (a subdomain; resolved by the fe-gateway
  `Host=*.hugmesh.net` route → federation-api, see
  [`docs/ROUTE-ACCESS.md`](ROUTE-ACCESS.md) and the cluster README "Vanity
  subdomains"), and the equivalent `*.hugmesh.games` surfaces.

If a user could register `admin`, then `admin.hugmesh.net` / `hugmesh.net/admin`
would shadow the real platform route, or be shadowed by it. That is a
**vanity-collision**, and the reserved set forbids exactly those labels.

The reserved set is the **union** of:

- every dedicated **fe/be/pki gateway route prefix** (path first-segment),
- every reserved service **subdomain** (first DNS label),
- the **hugmesh.games** app prefixes, and
- defensive standard **web names** (`well-known`, `favicon`, `robots`,
  `health`/`healthz`, `metrics`, …).

## The rule

> **Every dedicated gateway route prefix MUST appear in the reserved list, and
> the app-repo `ReservedNames` copies MUST be kept in sync with it.**

A new route prefix that is not reserved is **drift**. The route-consistency check
(below) fails the build or sync, so it cannot ship.

## The canonical source of truth

[`specs/cluster/reserved-prefixes.yaml`](../specs/cluster/reserved-prefixes.yaml)
— `spec.reserved` is the list. Everything else is derived from it or checked against
it. It currently holds **82** labels (`metadata.revision: "9"`). Revision 2
held 65; the label counts by revision are 65 (2), 70 (3), 72 (4), 76 (5), 77 (6),
78 (7), 79 (8) and 82 (9). The 65 of revision 2 were:

- the 60-label union shared with the app repos, **plus `pleroma`** — akkoma's
  AdminFE is served at `/pleroma/admin/**` on the be-gateway (revision 1),
- **plus `_synapse` + `media`** — the publicly-routable homeserver client
  surfaces the route-access seed deploys on the be-gateway (`/_synapse/**`
  Matrix Synapse-compat, `/media/**` Mastodon media); real first-segment route
  prefixes a vanity username could shadow, surfaced by the consistency check,
- **plus `forum` + `phpbb`** — the phpBB community forum is a real, deployed,
  default-on, live-routed optional service since PR #164 (2026-06-23):
  `apps/30-phpbb.yaml`, `38-forum-bff-db.yaml`, `39-forum-bff-api.yaml` and
  `49-forum-ui.yaml` are all synced ArgoCD Applications, and `ROLE_FORUM` /
  `ROLE_FORUM_MOD` rows are seeded in
  [`20-schema.sql`](../specs/cluster/manifests/route-access/initdb/20-schema.sql).
  Its only public surfaces ride already-reserved prefixes (`/social/forum/**`,
  `/bff/forum/**`) rather than a dedicated `forum` first-segment route. So, like the
  `owncast`/`wiki` forward-reserves in
  [`reserved-prefixes.yaml`](../specs/cluster/reserved-prefixes.yaml), the
  route-consistency check does not demand the label. It is reserved defensively, so
  a vanity `forum`/`phpbb` handle (or a future `forum.<domain>` subdomain) can never
  collide.

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

The three app-repo `ReservedNames` copies must add the same labels to stay in sync.
The validate script's code-copy assertion flags a miss mechanically, and a run that
could not reach those copies reports `INCOMPLETE`, not `PASS` (see below).

### What is NOT reserved (and why)

The reserved set holds **publicly routable first-labels only**, not every
`kind: Service`. Internal Services are left out on purpose, so the username namespace
is not shrunk for nothing:

- the akkoma-proxy / tuwunel-proxy **mTLS sidecars**, reached only behind the
  already-reserved `mastodon.` / `matrix.` hosts,
- `*-db` / `*-pg` **datastores**, `kafka` / `eureka` / `cassandra` / `clickhouse`
  brokers, `lan-dns`, and the `hugmesh-*-api` / `-ui` / `-web` pod helpers. Each is
  reached through its reserved path or host prefix, not by its bare branded Service
  name, which sed-rebrands per deployer anyway.

The validate script enforces this scope with an explicit internal allowlist
(`SERVICE_ALLOW_EXACT` / `SERVICE_ALLOW_PATTERNS`). A naive "every Service must be
reserved" rule would be red on day one.

## The enforcement layers

| Layer | Where | What it enforces |
|---|---|---|
| **vanity-resolve** | `federation-api` `VanityController` / `ReservedNames` | refuses a reserved first-label when resolving `<user>.hugmesh.net` |
| **profile DB / registration** | `hugmesh-auth-core` `ReservedNames` (consumed by `user-bff-api` and `admin-bff-api`), `hugmesh-actions` | a profile/handle can't be saved/registered with a reserved name |
| **admin-route management** | `hugmesh-auth-core` `ReservedNames` (via `admin-bff-api`) | an admin can't create a route-access row that conflicts with a reserved name |
| **GitOps / admission** *(this repo)* | Kyverno `ClusterPolicy` + ConfigMap | blocks vanity-shadowing Ingress/HTTPRoute hosts + reserved vanity CRD handles at admission/sync |
| **route-federation consistency** *(this repo)* | `scripts/validate-reserved-prefixes.sh` (CI lint) | asserts the canonical set ⊇ every deployed route prefix; fails on drift |

The first three are the **app-repo** layers, already in place. The last two are the
**GitOps/ArgoCD layer**. They make the reserved set the single auditable source of
truth and catch drift at build time and at sync time.

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
reserved list from the ConfigMap (the single source) and:

1. **rejects an Ingress** whose host's first DNS label under
   `*.hugmesh.net` / `*.hugmesh.games` is reserved (unless the object
   is a platform component, `app.kubernetes.io/part-of=hugmesh.net`),
2. **rejects a Gateway-API `HTTPRoute`** on the same hostname rule, and also when its first path segment is a reserved prefix, and
3. **defensively rejects** a `VanityClaim`/`Profile`/`User` CRD whose handle is
   reserved. It is inert until such a CRD exists (the kind does not match), so it is
   safe to ship now as defence in depth that mirrors the app-repo `ReservedNames`.

**Why Kyverno** (over OPA/Gatekeeper or a custom webhook): the reserved set is a
small data list that the policy reads from a ConfigMap, so there is no custom webhook
image to build or maintain, and the list stays the single source of truth. No policy
engine was present in `apps/` before, so this adds one:

- [`specs/cluster/apps/15-kyverno.yaml`](../specs/cluster/apps/15-kyverno.yaml)
  — deploys the Kyverno chart (sync-wave `-1`, so the CRDs exist first).
- [`specs/cluster/apps/16-reserved-prefixes-policy.yaml`](../specs/cluster/apps/16-reserved-prefixes-policy.yaml)
  — applies the ConfigMap + ClusterPolicy (default wave, after Kyverno).

### 3. The always-on drift guard (works with or without Kyverno)

Kyverno can only validate resources that exist in the cluster. The platform routes
through **Spring Cloud Gateway route tables** (in the gateway-app Helm values) and the
**route-access DB**, not through Ingress/HTTPRoute path rules. So the authoritative
drift guard is
[`scripts/validate-reserved-prefixes.sh`](../scripts/validate-reserved-prefixes.sh),
which parses:

- `specs/cluster/apps/20-gateway-*.yaml` (route `path:`/`host:` + ingress
  `host`/`extraHosts`), and
- `specs/cluster/manifests/route-access/initdb/20-schema.sql` (`url_pattern` rows),

and asserts that the canonical reserved set is a **superset** of every first-segment
prefix and first-label subdomain it finds. It also asserts that the **ConfigMap mirror
== the source**. It is wired into [`.gitlab-ci.yml`](../.gitlab-ci.yml) as the
`lint:reserved-prefixes` stage (runs first on every branch). It catches a new route
prefix before it ships, whether or not Kyverno is installed.

The script runs **five stages** (each fails the build on a violation), plus a
half-rename gate that rejects first-party workload names carrying the retired
`-systems-` infix and checks that the host shell's paired names agree across the
manifests, the ArgoCD Application and the compose lane:

1. canonical source non-empty + no duplicates;
2. the in-cluster **ConfigMap mirror == the canonical source** exactly;
3. **route-consistency**: `reserved ⊇` every publicly-routable gateway route
   prefix (path/host first-segment + route-access `url_pattern` first-segment +
   reserved gateway hosts);
4. **scoped Service-name drift**: `reserved ⊇` the publicly routable Services (those
   a gateway route `uri` actually targets) **minus** the explicit internal allowlist
   (the mTLS proxies, `*-db`/`*-pg`, the `hugmesh-*` family,
   casdoor/headscale/signup-gate). A routed Service whose public first-label is
   neither reserved nor allowlisted is drift. The check is scoped: it never demands a
   label for a non-routable internal Service, so it is not red on day one;
5. **code-copy assertion**: each app-repo `ReservedNames.java` `RESERVED[_LABELS]` set
   is parsed and asserted **== the canonical set** (mechanical; it replaces
   hand-counting). Copies are looked up under `RESERVED_SIBLING_ROOT` (default:
   checkouts next to this repo). The deployed-but-defensive reserves (`forum`/`phpbb`,
   `owncast`/`wiki`) are expected in the canonical set without a dedicated
   first-segment route of their own, because their public surfaces ride
   already-reserved prefixes. Stages 3 and 4 never flag them.

### Stage 5 is REQUIRED — an unrun assertion is not a pass

Until 2026-07-29 an absent copy was reported `[SKIP]` and the run still ended
`RESULT: PASS`, exit 0. This repo's own CI job checked out no siblings, so the
assertion had never once run in a pipeline. That is how a `hugmesh-actions` copy
missing five canonical labels (`character-forge`, `hmdm`, `attest`,
`games-character-forge`, `games-shadows-of-the-net`) sat on a green main. The verdict
is now honest:

| outcome | exit | meaning |
| --- | --- | --- |
| `RESULT: PASS` | 0 | consistent, **and every declared copy was checked** |
| `RESULT: FAIL` | 1 | drift / mismatch (offending labels printed) |
| *fatal* | 2 | environment problem (missing input, no python3/PyYAML) |
| `RESULT: INCOMPLETE` | 3 | no drift in the stages that ran, but ≥1 copy was absent so the code-copy assertion **did not run** |

Partial coverage is INCOMPLETE. Two of three copies present is not a pass, because
the drifted copy could be the absent one.

To get a real PASS locally, point the gate at a tree holding the copies:

```bash
RESERVED_SIBLING_ROOT=/path/to/checkouts scripts/validate-reserved-prefixes.sh
```

`RESERVED_ALLOW_MISSING_COPIES=1` downgrades INCOMPLETE to exit 0 for a working copy
that has no siblings, but the verdict still reads `RESULT: PASS (INCOMPLETE …)`,
never a clean PASS. **Never set it in CI.** `.gitlab-ci.yml`'s `lint:reserved-prefixes`
clones the three sibling repos from the org mirror (CI job token, same recipe as
`sca:dependency-check`) so the assertion really runs, and
`lint:reserved-prefixes-gate-honesty`
(`tests/scripts/test-reserved-prefix-copy-gate.sh`) proves the gate cannot go back to
reporting a clean PASS on a skipped run.

## Adding a new dedicated route prefix (the workflow)

1. Add the route to the gateway app / `schema.sql` as usual.
2. Add the new first-segment label to `spec.reserved` in
   `specs/cluster/reserved-prefixes.yaml`.
3. Run `scripts/sync-reserved-configmap.sh` to regenerate the ConfigMap mirror.
4. **Add the same label to the app-repo `ReservedNames` copies**, so the
   resolve, registration and admin layers agree. There are three physical copies:
   `hugmesh-federation-api`, `hugmesh-actions`, and `hugmesh-auth-core` (the shared
   one that `user-bff-api` and `admin-bff-api` consume as a Maven dependency; they no
   longer carry their own file).
5. Run `RESERVED_SIBLING_ROOT=… scripts/validate-reserved-prefixes.sh`. It must print
   `RESULT: PASS`. A bare `RESULT: INCOMPLETE` means step 4 was **not verified**; do
   not treat it as done.

## Honest scope / deferrals

- The Kyverno policy enforces **Ingress/HTTPRoute hosts** and **vanity CRD handles**.
  The platform's real routing is Spring Cloud Gateway tables, which Kyverno does not
  parse. The validate script and the CI lint are the real drift guard for those (and
  the PreSync-style guard, since the same script can run as an ArgoCD resource hook).
  The split is intentional.
- The app-repo `ReservedNames` copies are **not** generated from this source; they
  live in three other repos. Step 4 above is a manual sync. The validate script's
  code-copy assertion verifies it mechanically, and CI now clones those repos so the
  assertion runs on every pipeline instead of skipping to a green result. A follow-up
  could publish `reserved.json` as a build artifact that the app repos pull, which
  would remove the manual sync.
- Every label added after revision 1 (`pleroma`, then `_synapse` / `media` /
  `forum` / `phpbb`, then the revision 3-9 labels above) must also reach the three
  copies (`hugmesh-federation-api` / `hugmesh-actions` / `hugmesh-auth-core`, the last
  covering `user-bff-api` + `admin-bff-api` via the Maven dependency). The code-copy
  assertion FAILs until they do. That is the intended signal.
- The scoped Service-name drift check (stage 4) keys on the route `uri` host, so it
  sees only Services that a **gateway route** targets. A Service exposed some other
  way (a future Ingress/HTTPRoute) is covered by the Kyverno host policy, not by
  stage 4. The internal allowlist is a script-side constant on purpose; promoting it
  to a manifest label (`hugmesh.net/reserved-exempt: true`) is a documented
  follow-up.

## The Casdoor pre-signup confusable gate

The reserved rule above is **exact-match**: a handle equal to a reserved label. The
companion **username-confusable** policy rejects look-alike handles (`4dmin` ~
`admin`, `аdmin` [Cyrillic] ~ `admin`, `r00t` ~ `root`, `akk0ma` ~ `akkoma`) that an
exact list can never catch. Casdoor, the platform's universal self-signup identity
mint, has only an exact-only forbidden-username list, so a confusable login would
otherwise be minted. The
[`manifests/signup-gate/`](../specs/cluster/manifests/signup-gate/) proxy is the
fail-closed enforcement seam in front of Casdoor's signup endpoints; see
[`docs/USERNAME-CONFUSABLE.md`](USERNAME-CONFUSABLE.md) for the full design.
