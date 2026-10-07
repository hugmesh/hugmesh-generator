# Domain-lock (force local-only / no-federation) — generator-side enforcement

Domain-lock makes a Matrix/Mastodon user **local-only**: they keep full access to
the local instance but cannot federate outbound. This document covers the
**generator** (cluster-manifest) half of that feature — the role seeds, the
authoritative egress backstop, and the custom Akkoma MRF. The admin-bff/mod-bff
service + reconcile + delegation and the UI surfaces live in their own repos.

## ADD-semantics, not a ban

Domain-lock is the **PRESENCE** of an additive marker role alongside the kept
access role — the opposite of a ban (the **ABSENCE** of the access role):

| | role change | gateway route rows | result |
|---|---|---|---|
| **ban** (access_suspension) | REMOVE `ROLE_MATRIX`/`ROLE_MASTODON` | stop matching | access denied |
| **domain-lock** (domain_lock) | ADD `ROLE_*_DOMAINLOCKED`, KEEP the access role | **UNTOUCHED** | full local access, no federation |

The user keeps `ROLE_MATRIX`/`ROLE_MASTODON`, so the **be-gateway is intentionally
untouched** — no route-access deny row is added. Enforcement is entirely the
homeserver/egress leg below. The two marker roles are named `ROLE_MATRIX_DOMAINLOCKED` and
`ROLE_MASTODON_DOMAINLOCKED` in Casdoor, and the existing
`casdoorAuthoritiesConverter` (`hugmesh-gateway` `CasdoorAuthorities.java`)
turns every `roles` entry into `ROLE_<UPPER>` (it strips one leading `ROLE_`
and re-adds it); **no converter change**.

Seeded present-but-empty in `manifests/casdoor/init-data-configmap.yaml` (siblings
of `ROLE_MATRIX`/`ROLE_MASTODON`). Membership is driven by the admin-bff/mod-bff
domain-lock flow writing a **separate `domain_lock` table** (ADD-active), NOT by
overloading `access_suspension` (REMOVE-semantics, closed ROLE_PATTERN).

## The three enforcement legs (generator owns leg 1 + 2)

Federation is **outbound**, so egress is the authoritative non-federation control.
Only `homeserver-egress.yaml` (below) restricts egress today, and only for the
akkoma, akkoma-db and tuwunel pods; the tier-wide and per-DB egress policies
exist but ship dark (`docs/CLUSTER-HARDENING-PLAN.md` §B).

1. **Egress NetworkPolicy + forward egress-proxy (AUTHORITATIVE backstop; the
   ONLY leg for Matrix/tuwunel).**
   - `manifests/networkpolicy/homeserver-egress.yaml` — `policyTypes: [Egress]` on
     the akkoma, akkoma-db and tuwunel pods. Default-deny egress; the akkoma pod
     may reach only DNS (kube-system), `akkoma-db:5432` and `egress-proxy:3128`,
     the tuwunel pod only DNS and `egress-proxy:3128` (it embeds RocksDB), and
     the akkoma-db pod only DNS. The homeservers get **no direct internet
     egress** — all outbound federation is forced through the proxy.
   - `manifests/egress-proxy/` — a squid forward proxy. Its allowlist is the seam
     the domain-lock reconcile loop materializes (`domainlock-allowlist` ConfigMap).
   - This is the **only** thing that can enforce **tuwunel/Matrix** non-federation:
     tuwunel/Conduit has no per-user federation control (only server-wide
     allow/deny lists + per-room `m.federate` at create-time).

2. **Custom Akkoma `ForceLocalForUsers` MRF (AUTHORITATIVE Mastodon leg).**
   - `manifests/akkoma/mrf/force_local_for_users_policy.ex` — for any actor in the
     force-local set, **filters the outbound delivery recipient set to LOCAL
     inboxes only** for ALL activity types/visibilities (public, unlisted,
     followers-only, direct, **Announce/boosts, replies, profile Update,
     outbound Follow**) — not merely rewriting `as:Public` → `#Public`. This closes
     the visibility-scoped, boost/reply, existing-remote-follower, and profile/
     follow leaks a public-only rewrite would miss.
   - `manifests/akkoma/Dockerfile` — builds the custom image (`FROM` a pinned
     Akkoma digest + `COPY` the `.ex` + recompile the release).
   - `manifests/akkoma/domainlock-sync-job.yaml` — PostSync reconcile that
     materializes `ROLE_MASTODON_DOMAINLOCKED` → the live force-local set the MRF
     reads (clone of `admin-sync-job.yaml`).

3. **Gateway/proxy request-interception filter** — UX + raw-API catch. Lives in
   `hugmesh-be-gateway` (not this repo).

Leg 1 (egress) is the foundation/braces; leg 2 (the akkoma MRF) is the
Mastodon-specific belt on top.

## What is GATED / SHIPS DARK vs LIVE

Everything that could change behaviour is **default-OFF** so this merges safely and
a plain `akkoma:stable` + `tuwunel` keep federating unchanged:

| artifact | state on merge | gate |
|---|---|---|
| `ROLE_*_DOMAINLOCKED` seeds | **LIVE** (empty roles, inert) | — |
| `homeserver-egress.yaml` NetworkPolicy | **LIVE**: listed in `manifests/networkpolicy/kustomization.yaml`, which the auto-sync (prune + selfHeal) app `apps/08-networkpolicy.yaml` applies | remove the line from the kustomization to roll back |
| `egress-proxy` deploy | ships **PASS-THROUGH** (forwards all); its app `apps/29a-egress-proxy.yaml` is **MANUAL-sync** | `DOMAINLOCK_EGRESS_ENABLED` (default `"false"`) |
| akkoma MRF `.ex` + `Dockerfile` | in repo, **not built/pinned**: the Dockerfile still carries the `REPLACE_WITH_PINNED_AKKOMA_DIGEST` and `REPLACE_WITH_AKKOMA_GIT_TAG` placeholders | build + pin the custom image |
| `:mrf policies` in `akkoma-config` | **commented out** | uncomment after custom image |
| `domainlock-sync-job.yaml` | **not wired** into `manifests/akkoma/kustomization.yaml`; its `image` is the placeholder `REPLACE_WITH_CUSTOM_AKKOMA_IMAGE` | `homeserver.domainlock.enabled` |

The first two rows interact: the egress policy is live, and the proxy it forces
traffic through is a manual-sync app. A cluster that has not synced
`apps/29a-egress-proxy.yaml` gives the homeservers no path to the internet. Sync
the proxy first.

The role NEVER ships advertised-as-enforced until the custom akkoma image + the
egress policy are real. Until then it is an explicit DEGRADED/dark state.

## Deploy ordering

1. **Seeds** (live, inert): `ROLE_*_DOMAINLOCKED` in Casdoor init-data.
2. **Egress backstop FIRST**: sync `egress-proxy` (pass-through) and confirm the
   `homeserver-egress` NetworkPolicy is applied, then run the LIVE connectivity
   validation below. This is the foundation and the only tuwunel/Matrix leg.
3. **Akkoma MRF belt**: build + pin the custom image, enable the `:mrf policies`
   block, wire `domainlock-sync-job.yaml`, set `homeserver.domainlock.enabled`.
4. **Flip enforcement on**: set `DOMAINLOCK_EGRESS_ENABLED=true` on the egress-proxy
   (loads the allowlist) once the reconcile loop is writing the force-local set.

### LIVE connectivity validation (before relying on the egress lock)

An incomplete allow-set silently breaks the homeserver. After syncing, verify
on-cluster:
- akkoma resolves DNS and reaches `akkoma-db:5432` (it boots + serves
  `/api/v1/instance`);
- a non-locked control user's public post STILL federates to a peer (pass-through
  gate off) — proves the proxy hop works and nothing legitimate was cut;
- tuwunel `/sync` + local rooms still work.
Rollback: `apps/08-networkpolicy.yaml` auto-syncs with prune and selfHeal, so a
`kubectl delete` of the policy is re-created. Remove the `homeserver-egress.yaml`
line from `manifests/networkpolicy/kustomization.yaml` and let the app prune it
(direct egress is restored). To stop the proxy, remove the `egress-proxy` app.

## Custom Akkoma image build + AGPL source publication

Akkoma is **AGPL-3.0**. The custom image (`manifests/akkoma/Dockerfile`) is a
**derivative work**, and AGPL §13 (network-use clause) requires offering the
**complete corresponding source** to every network user of the running server.

No script in this repo builds the image yet (no `build-*.sh`, script or Makefile
target references `manifests/akkoma/Dockerfile`). Whatever builds it MUST:
1. **Pin** the upstream base as a digest (`AKKOMA_BASE=...@sha256:...`) and keep
   `AKKOMA_SOURCE_REF` (the matching upstream git tag) in lock-step — the
   prod-hygiene gate forbids floating `:stable`/`:latest`.
2. **Publish this overlay** — `manifests/akkoma/Dockerfile` +
   `mrf/force_local_for_users_policy.ex` are tracked in this public repo (that IS
   the source contribution); the `.ex` carries the `AGPL-3.0-only` SPDX header.
3. **Surface an in-app source offer** — `AKKOMA_SOURCE_URL` (set in the Dockerfile)
   points at this manifests/akkoma tree; expose it to instance users.
4. Update `akkoma.yaml` + `domainlock-sync-job.yaml` to reference the pinned
   custom image (replace `git.akkoma.dev/.../akkoma:stable` and the
   `REPLACE_WITH_CUSTOM_AKKOMA_IMAGE` placeholder).

The Dockerfile sketches two recompile strategies (source-image vs OTP-release base)
— pick the one matching the pinned base and validate the recompile. The MRF
surfaces in `/nodeinfo` via `describe/0` so the e2e self-check can assert the custom
image is actually running.

## Files (this repo)

- `manifests/casdoor/init-data-configmap.yaml` — the two `ROLE_*_DOMAINLOCKED` seeds.
- `manifests/networkpolicy/homeserver-egress.yaml` — egress lock (listed in the
  kustomization beside it).
- `manifests/egress-proxy/` — forward proxy + gated allowlist + ArgoCD app
  (`apps/29a-egress-proxy.yaml`).
- `manifests/akkoma/Dockerfile`, `mrf/force_local_for_users_policy.ex`,
  `domainlock-sync-job.yaml`, and the dark `:mrf` block in `akkoma.yaml`.
