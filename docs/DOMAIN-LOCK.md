# Domain-lock (force local-only / no-federation) — generator-side enforcement

Domain-lock makes a Matrix or Mastodon user **local-only**. The user keeps full
access to the local instance but cannot federate outbound. This document covers
the **generator** (cluster-manifest) half: the role seeds, the egress backstop,
and the custom Akkoma MRF. The admin-bff/mod-bff service, the reconcile loop,
delegation and the UI surfaces live in their own repos.

## ADD-semantics, not a ban

Domain-lock is the **presence** of an additive marker role next to the kept
access role. A ban is the opposite: the **absence** of the access role.

| | role change | gateway route rows | result |
|---|---|---|---|
| **ban** (access_suspension) | REMOVE `ROLE_MATRIX`/`ROLE_MASTODON` | stop matching | access denied |
| **domain-lock** (domain_lock) | ADD `ROLE_*_DOMAINLOCKED`, KEEP the access role | **UNTOUCHED** | full local access, no federation |

The user keeps `ROLE_MATRIX`/`ROLE_MASTODON`, so the be-gateway is left alone and
no route-access deny row is added. Enforcement is entirely the homeserver and
egress legs below.

The two marker roles are named `ROLE_MATRIX_DOMAINLOCKED` and
`ROLE_MASTODON_DOMAINLOCKED` in Casdoor. The existing `casdoorAuthoritiesConverter`
(`hugmesh-gateway` `CasdoorAuthorities.java`) turns every `roles` entry into
`ROLE_<UPPER>`: it strips one leading `ROLE_` and adds it back. No converter
change is needed.

The roles are seeded present-but-empty in `manifests/casdoor/init-data-configmap.yaml`,
beside `ROLE_MATRIX` and `ROLE_MASTODON`. The admin-bff/mod-bff domain-lock flow
fills them by writing a **separate `domain_lock` table** (ADD-active). It does not
reuse `access_suspension` (REMOVE-semantics, closed ROLE_PATTERN).

## The three enforcement legs (generator owns leg 1 + 2)

Federation is **outbound**, so egress is the authoritative non-federation control.
Only `homeserver-egress.yaml` (below) restricts egress today, and only for the
akkoma, akkoma-db and tuwunel pods. The tier-wide and per-DB egress policies
exist but ship dark (`docs/CLUSTER-HARDENING-PLAN.md` §B).

1. **Egress NetworkPolicy + forward egress-proxy.** This is the authoritative
   backstop and the **only** leg for Matrix/tuwunel.
   - `manifests/networkpolicy/homeserver-egress.yaml` sets `policyTypes: [Egress]`
     on the akkoma, akkoma-db and tuwunel pods. It denies all egress, then allows:
     - akkoma: DNS (kube-system), `akkoma-db:5432` and `egress-proxy:3128`;
     - tuwunel: DNS and `egress-proxy:3128` (it embeds RocksDB, so it needs no DB
       egress);
     - akkoma-db: DNS only.

     The homeservers get **no direct internet egress**. All outbound federation
     goes through the proxy.
   - `manifests/egress-proxy/` is a squid forward proxy. Its allowlist is the seam
     the domain-lock reconcile loop fills (`domainlock-allowlist` ConfigMap).
   - Nothing else can enforce **tuwunel/Matrix** non-federation. tuwunel/Conduit
     has no per-user federation control, only server-wide allow/deny lists and a
     per-room `m.federate` set at creation.

2. **Custom Akkoma `ForceLocalForUsers` MRF** (the authoritative Mastodon leg).
   - `manifests/akkoma/mrf/force_local_for_users_policy.ex`: for any actor in the
     force-local set, it filters the outbound recipient set to **local inboxes
     only**, for all activity types and visibilities (public, unlisted,
     followers-only, direct, Announce/boosts, replies, profile Update, outbound
     Follow). Rewriting `as:Public` to `#Public` alone would leave the
     visibility-scoped, boost/reply, existing-remote-follower and profile/follow
     leaks open.
   - `manifests/akkoma/Dockerfile` builds the custom image: `FROM` a pinned Akkoma
     digest, `COPY` the `.ex`, recompile the release.
   - `manifests/akkoma/domainlock-sync-job.yaml` is a PostSync reconcile. It
     turns `ROLE_MASTODON_DOMAINLOCKED` into the live force-local set the MRF
     reads. It is a clone of `admin-sync-job.yaml`.

3. **Gateway/proxy request-interception filter.** It covers UX and raw API calls.
   It lives in `hugmesh-be-gateway`, not in this repo.

Leg 1 is the foundation. Leg 2 is the Mastodon-specific layer on top.

## What is GATED / SHIPS DARK vs LIVE

| artifact | state on `main` | gate |
|---|---|---|
| `ROLE_*_DOMAINLOCKED` seeds | **LIVE** (empty roles, inert) | — |
| `homeserver-egress.yaml` NetworkPolicy | **LIVE**: listed in `manifests/networkpolicy/kustomization.yaml`, which the auto-sync (prune + selfHeal) app `apps/08-networkpolicy.yaml` applies | remove the line from the kustomization to roll back |
| `egress-proxy` deploy | ships **PASS-THROUGH** (forwards all); its app `apps/29a-egress-proxy.yaml` is **MANUAL-sync** | `DOMAINLOCK_EGRESS_ENABLED` (default `"false"`) |
| akkoma MRF `.ex` + `Dockerfile` | in repo, **not built or pinned**: the Dockerfile still carries the `REPLACE_WITH_PINNED_AKKOMA_DIGEST` and `REPLACE_WITH_AKKOMA_GIT_TAG` placeholders | build and pin the custom image |
| `:mrf policies` in `akkoma-config` | **commented out** | uncomment after the custom image exists |
| `domainlock-sync-job.yaml` | **not wired** into `manifests/akkoma/kustomization.yaml`; its `image` is the placeholder `REPLACE_WITH_CUSTOM_AKKOMA_IMAGE` | `homeserver.domainlock.enabled` |

The first two rows interact. The egress policy is live, and the proxy it forces
traffic through is a manual-sync app. A cluster that has not synced
`apps/29a-egress-proxy.yaml` gives the homeservers no path to the internet. Sync
the proxy first.

The role must never ship advertised as enforced until the custom akkoma image and
the egress policy are real. Until then domain-lock is in an explicit degraded,
dark state.

## Deploy ordering

1. **Seeds** (live, inert): `ROLE_*_DOMAINLOCKED` in Casdoor init-data.
2. **Egress backstop first.** Sync `egress-proxy` (pass-through), confirm the
   `homeserver-egress` NetworkPolicy is applied, then run the live connectivity
   validation below. This is the foundation and the only tuwunel/Matrix leg.
3. **Akkoma MRF.** Build and pin the custom image, enable the `:mrf policies`
   block, wire `domainlock-sync-job.yaml`, set `homeserver.domainlock.enabled`.
4. **Turn enforcement on.** Set `DOMAINLOCK_EGRESS_ENABLED=true` on the
   egress-proxy (it then loads the allowlist) once the reconcile loop is writing
   the force-local set.

### LIVE connectivity validation (before relying on the egress lock)

An incomplete allow-set silently breaks a homeserver. After syncing, verify on
the cluster:
- akkoma resolves DNS and reaches `akkoma-db:5432` (it boots and serves
  `/api/v1/instance`);
- a non-locked control user's public post still federates to a peer (the
  pass-through gate is off). This proves the proxy hop works and nothing
  legitimate was cut;
- tuwunel `/sync` and local rooms still work.

Rollback: `apps/08-networkpolicy.yaml` auto-syncs with prune and selfHeal, so a
`kubectl delete` of the policy is re-created. Remove the `homeserver-egress.yaml`
line from `manifests/networkpolicy/kustomization.yaml` and let the app prune it.
Direct egress is then restored. To stop the proxy, remove the `egress-proxy` app.

## Custom Akkoma image build + AGPL source publication

Akkoma is **AGPL-3.0**. The custom image (`manifests/akkoma/Dockerfile`) is a
**derivative work**. AGPL §13 (the network-use clause) requires you to offer the
**complete corresponding source** to every network user of the running server.

No script in this repo builds the image yet: no `build-*.sh`, script or Makefile
target references `manifests/akkoma/Dockerfile`. Whatever builds it MUST:
1. **Pin** the upstream base as a digest (`AKKOMA_BASE=...@sha256:...`) and keep
   `AKKOMA_SOURCE_REF` (the matching upstream git tag) in lock-step. The
   prod-hygiene gate forbids floating `:stable`/`:latest`.
2. **Publish this overlay.** `manifests/akkoma/Dockerfile` and
   `mrf/force_local_for_users_policy.ex` are tracked in this public repo, which is
   the source contribution. The `.ex` carries the `AGPL-3.0-only` SPDX header.
3. **Surface an in-app source offer.** `AKKOMA_SOURCE_URL` (set in the Dockerfile)
   points at this `manifests/akkoma` tree. Expose it to instance users.
4. **Update `akkoma.yaml` and `domainlock-sync-job.yaml`** to reference the pinned
   custom image. Replace `git.akkoma.dev/akkomagang/akkoma:stable` and the
   `REPLACE_WITH_CUSTOM_AKKOMA_IMAGE` placeholder.

The Dockerfile sketches two recompile strategies (source-image or OTP-release
base). Pick the one that matches the pinned base and validate the recompile. The
MRF reports itself in `/nodeinfo` through `describe/0`, so the e2e self-check can
assert that the custom image is the one running.

## Files (this repo)

- `manifests/casdoor/init-data-configmap.yaml`: the two `ROLE_*_DOMAINLOCKED` seeds.
- `manifests/networkpolicy/homeserver-egress.yaml`: the egress lock (listed in the
  kustomization beside it).
- `manifests/egress-proxy/`: forward proxy, gated allowlist, and its ArgoCD app
  (`apps/29a-egress-proxy.yaml`).
- `manifests/akkoma/Dockerfile`, `mrf/force_local_for_users_policy.ex`,
  `domainlock-sync-job.yaml`, and the dark `:mrf` block in `akkoma.yaml`.
