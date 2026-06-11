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
homeserver/egress leg below. The two marker roles auto-convert via the existing
`casdoorAuthoritiesConverter` (`matrix-domainlocked` → `ROLE_MATRIX_DOMAINLOCKED`,
`mastodon-domainlocked` → `ROLE_MASTODON_DOMAINLOCKED`); **no converter change**.

Seeded present-but-empty in `manifests/casdoor/init-data-configmap.yaml` (siblings
of `ROLE_MATRIX`/`ROLE_MASTODON`). Membership is driven by the admin-bff/mod-bff
domain-lock flow writing a **separate `domain_lock` table** (ADD-active), NOT by
overloading `access_suspension` (REMOVE-semantics, closed ROLE_PATTERN).

## The three enforcement legs (generator owns leg 1 + 2)

There is **no egress control today** — every existing NetworkPolicy is
`policyTypes: [Ingress]` and the tier-ingress header says egress is left open.
Federation is **outbound**, so egress is the authoritative non-federation control.

1. **Egress NetworkPolicy + forward egress-proxy (AUTHORITATIVE backstop; the
   ONLY leg for Matrix/tuwunel).**
   - `manifests/networkpolicy/homeserver-egress.yaml` — `policyTypes: [Egress]` on
     the akkoma/tuwunel pods. Default-deny egress; re-allow ONLY DNS (kube-system),
     `akkoma-db:5432`, and `egress-proxy:3128`. The homeservers get **no direct
     internet egress** — all outbound federation is forced through the proxy.
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
   `snapdragon-be-gateway` (not this repo).

Leg 1 (egress) is the foundation/braces; leg 2 (the akkoma MRF) is the
Mastodon-specific belt on top.

## What is GATED / SHIPS DARK vs LIVE

Everything that could change behaviour is **default-OFF** so this merges safely and
a plain `akkoma:stable` + `tuwunel` keep federating unchanged:

| artifact | state on merge | gate |
|---|---|---|
| `ROLE_*_DOMAINLOCKED` seeds | **LIVE** (empty roles, inert) | — |
| `homeserver-egress.yaml` NetworkPolicy | in repo; app is **MANUAL-sync** | sync `apps/29a-egress-proxy.yaml` + validate |
| `egress-proxy` deploy | ships **PASS-THROUGH** (forwards all) | `DOMAINLOCK_EGRESS_ENABLED` (default `false`) |
| akkoma MRF `.ex` + `Dockerfile` | in repo, **not built/pinned** | build + pin the custom image |
| `:mrf policies` in `akkoma-config` | **commented out** | uncomment after custom image |
| `domainlock-sync-job.yaml` | **not wired** into kustomization | `homeserver.domainlock.enabled` |

The role NEVER ships advertised-as-enforced until the custom akkoma image + the
egress policy are real. Until then it is an explicit DEGRADED/dark state.

## Deploy ordering

1. **Seeds** (live, inert): `ROLE_*_DOMAINLOCKED` in Casdoor init-data.
2. **Egress backstop FIRST**: sync `egress-proxy` (pass-through) + the
   `homeserver-egress` NetworkPolicy, then run the LIVE connectivity validation
   below. This is the foundation and the only tuwunel/Matrix leg.
3. **Akkoma MRF belt**: build + pin the custom image, enable the `:mrf policies`
   block, wire `domainlock-sync-job.yaml`, set `homeserver.domainlock.enabled`.
4. **Flip enforcement on**: set `DOMAINLOCK_EGRESS_ENABLED=true` on the egress-proxy
   (loads the allowlist) once the reconcile loop is writing the force-local set.

### LIVE connectivity validation (before relying on the egress lock)

The egress lock ships behind a **manual** ArgoCD app because an incomplete
allow-set silently breaks the homeserver. After syncing, verify on-cluster:
- akkoma resolves DNS and reaches `akkoma-db:5432` (it boots + serves
  `/api/v1/instance`);
- a non-locked control user's public post STILL federates to a peer (pass-through
  gate off) — proves the proxy hop works and nothing legitimate was cut;
- tuwunel `/sync` + local rooms still work.
Rollback: revert `apps/29a-egress-proxy.yaml` to remove the app, or
`kubectl delete -k manifests/networkpolicy` (egress policies removed → direct
egress restored).

## Custom Akkoma image build + AGPL source publication

Akkoma is **AGPL-3.0**. The custom image (`manifests/akkoma/Dockerfile`) is a
**derivative work**, and AGPL §13 (network-use clause) requires offering the
**complete corresponding source** to every network user of the running server.

The build (in `build-x86-host-stage4.sh`, alongside the other first-party images)
MUST:
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
- `manifests/networkpolicy/homeserver-egress.yaml` — egress lock (+ kustomization).
- `manifests/egress-proxy/` — forward proxy + gated allowlist + ArgoCD app
  (`apps/29a-egress-proxy.yaml`).
- `manifests/akkoma/Dockerfile`, `mrf/force_local_for_users_policy.ex`,
  `domainlock-sync-job.yaml`, and the dark `:mrf` block in `akkoma.yaml`.
