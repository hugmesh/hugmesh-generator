# Snapdragon cluster architecture

Everything connects **behind `snapdragon.systems`** through per-namespace
Spring Cloud Gateways that validate a single internal Casdoor OAuth2 JWT.
Cloudflare maps the public `snapdragon.systems` / `snapdragon.games` names onto
those gateways (configured later, out of scope here).

## Nodes & images

| Image | Build | Arch | Role in the cluster |
|---|---|---|---|
| `pki` | `build-rpi5-stage4.sh --role pki` | aarch64 (RPi 5) | **Kubernetes control plane** + identity: headscale (mesh control), Casdoor, Cassandra, `snapdragon-pki-gateway` |
| `backend` | `build-rpi5-stage4.sh --role backend` | aarch64 (RPi 5) | tuwunel (Matrix), Akkoma (fediverse), Spring APIs, databases, `snapdragon-be-gateway` |
| `frontend` | `build-rpi5-stage4.sh --role frontend` | aarch64 (RPi 5) | `snapdragon.systems` Angular host federating `snapdragon-matrix-ui` + `snapdragon-mastodon-ui` (the ArgoCD grouping is still named `social-ui`), `snapdragon-fe-gateway` |
| `host` | `build-x86-host-stage4.sh` | x86_64 (desktop/server) | GPU worker: ArgoCD, GitLab/Runner/binhost (devops), `snapdragon.games`, owncast + tube (GPU-dependent video), heavy datastores (Kafka/ClickHouse/Uptrace), local-path/node-storage default (Mesa/Vulkan via `/dev/dri`) |

All nodes are hardened Gentoo, join one Kubernetes cluster, sit on one headscale
mesh, and are provisioned at first boot from a USB **KEYS** stick (see
[`keys-template/`](../keys-template/README.md)). The pki Pi is the kubeadm
control plane; backend/frontend Pis and the x86_64 host join it as workers and
are labelled (`snapdragon.systems/role`, `…/compute=gpu`) so workloads land on
the right hardware.

```mermaid
flowchart TD
    CF["Cloudflare edge<br/>snapdragon.systems / snapdragon.games"]
    CF --> FEGW["snapdragon-fe-gateway<br/>(snapdragon.systems)"]
    CF --> BEGW["snapdragon-be-gateway<br/>(api / matrix / mastodon .*)"]
    CF --> PKIGW["snapdragon-pki-gateway<br/>(id.snapdragon.systems)"]

    subgraph FE["snapdragon-frontend (frontend Pis)"]
        HOST["snapdragon.systems Angular host shell"]
        HOST --> MUI["snapdragon-matrix-ui"]
        HOST --> MASTUI["snapdragon-mastodon-ui"]
        HOST --> LOGINUI["snapdragon-login-ui"]
        HOST --> ADMINUI["snapdragon-admin-ui / mod-ui / user-ui / forum-ui"]
    end

    subgraph BE["snapdragon-backend (backend Pis)"]
        TUW["tuwunel (Matrix homeserver)"]
        AKK["Akkoma (Mastodon-API fediverse)"]
        APIS["Spring APIs + DBs"]
        FEDAPI["federation-api"]
        BFFS["admin / mod / user / forum BFFs"]
        PHPBB["phpBB (optional)"]
    end

    subgraph PKI["snapdragon-pki (pki Pi — control plane)"]
        CAS["Casdoor (IdP)"]
        CASS["Cassandra"]
        HS["headscale (mesh control)"]
    end

    subgraph X86["x86_64 GPU worker"]
        ARGO["ArgoCD"]
        DEVOPS["GitLab / Runner / binhost (devops)"]
        GAMES["snapdragon.games studio"]
        VIDEO["owncast + tube (GPU-dependent video)"]
        HEAVY["heavy datastores: Kafka / ClickHouse / Uptrace"]
        STORE["local-path / node-storage default"]
    end

    FEGW --> FE
    BEGW --> BE
    PKIGW --> PKI
    BE -. "games ns + argocd ns scheduled here" .-> X86

    subgraph ROADMAP["Roadmap / in-flight — NOT all shipped"]
        WC["Workload Console (admin-bff module, ships dark)"]
        MFA["Casdoor MFA (design done)"]
        DESKGOV["Desktop app governance (queued)"]
        NOTIFY["Notifications: external channels (in-flight)"]
        subgraph SSO["SSO / BFF JWT custody (ships dark)"]
            AUTHCORE["auth-core: account/session/MFA + custody seams (✅ 2.3.0)"]
            GWEXCH["gateway bff_-exchange filter (🚧 PR-C)"]
            LOGINOIDC["login-ui Casdoor OIDC + PKCE (🚧 PR-4)"]
            UBRELOC["user-bff OIDC login relocation (🚧 PR-A3)"]
        end
    end

    classDef planned stroke-dasharray:4,stroke:#888,color:#555;
    class ROADMAP,WC,MFA,DESKGOV,NOTIFY,SSO,AUTHCORE,GWEXCH,LOGINOIDC,UBRELOC planned;
```

> The **superadmin Service Catalog** surface (tailnet-only `snapdragon-superadmin-gateway`
> + Kaniko build namespace) is now ✅ shipped on `main` but is reachable **only**
> over the headscale tailnet via the internal ingress on the pki node — it is
> deliberately off every public-ingress gateway, so it is not drawn on the public
> fan-out above. See [§ Superadmin & multi-tenancy](#superadmin-multi-tenancy-and-the-role-cascade).

## The gateway pattern

`snapdragon-gateway` (Spring Cloud Gateway) is deployed once per namespace from
[one Helm chart](../specs/cluster/charts/snapdragon-gateway), differentiated by
`SPRING_APPLICATION_NAME`. Modelled on the org's `snapdragon-gateway` /
`snapdragon-id-gateway`:

- **OAuth2 resource server** against Casdoor's JWKS — the same JWT validates at
  every gateway and API.
- **`ExternalAuthHeaderFilter`** appends `External-Authorization` /
  `External-Auth-Provider` / `External-Auth-Id` so downstreams see the outside
  identity without re-decoding tokens.
- **Public paths** (`/api/auth`, `/api/login`, `/api/registration`) allow
  Google-federated sign-up; everything else is authenticated. **No external
  login UI is exposed** — login is internal to Casdoor.
- Routes per gateway are rendered into an `application-routes.yml` ConfigMap and
  loaded via `SPRING_CONFIG_ADDITIONAL_LOCATION`.

## Identity & login

Casdoor (`id.snapdragon.systems`) is the single IdP:

- **Admin-created accounts** sign in directly.
- **Google federation** handles public registration/sign-up.
- **tuwunel** (Matrix homeserver, OIDC) and **Akkoma** (Mastodon-API-compatible
  fediverse, OIDC) both SSO against Casdoor, so the `snapdragon.systems` front
  page can show **Matrix / Mastodon links to logged-in users** and hand each
  module a service access token — the
  [`snapdragon-matrix-ui`](https://github.com/Snapdragon-Systems/snapdragon-matrix-ui)
  and [`snapdragon-mastodon-ui`](https://github.com/Snapdragon-Systems/snapdragon-mastodon-ui)
  Angular micro-frontends never render their own login forms. The public
  hostnames stay `matrix.<domain>` / `mastodon.<domain>` for API compatibility,
  but the backing servers are tuwunel / Akkoma (never Synapse / Mastodon).

## Authentication / SSO (BFF JWT custody)

> **State convention:** ✅ shipped = merged to `main` · 🚧 in-flight = code on an
> open branch/PR, not yet merged · 🔭 planned = design-complete, no code. The whole
> ensemble **ships dark** behind flags that default off/blank, so a default
> deployment is byte-identical to today.

**The mandate:** SSO login works end-to-end with the Casdoor JWT kept **internal** —
the browser holds **only** an opaque `bff_` session cookie; the gateway swaps
`bff_` → an internal custody JWT just before resource-server validation; the user
never sees their own JWT. This relocates login out of the gateway (which keeps the
r2dbc/Casdoor management stack off its classpath) and into the BFF tier.

**Component ownership** (post auth-relocation):

- **`snapdragon-auth-core`** (shared jar `systems.snapdragon:snapdragon-auth-core`) —
  the stateful auth stack: `AccountStore`/`BffSession` (account + session + MFA),
  `OidcExchangeClient` (code→token + refresh), `BffCustodyCipher` (AES-256-GCM
  encrypt-at-rest for the held JWT), `SessionCookieService` (the opaque `bff_`
  cookie), `InternalTokenWebFilter` (mTLS + `X-Internal-Token` guard for
  `/bff/internal/**`). Consumed by **admin-bff + user-bff only** — never the gateway.
- **`snapdragon-admin-bff-api`** — owns account/session **data** (admin-bff-db) +
  the in-cluster `/bff/internal` account/session API + the custody/stamp + the
  session/exchange endpoints.
- **`snapdragon-user-bff-api`** — owns the login/OIDC **endpoints**
  (`/bff/auth/callback`, `/bff/login`, …); reads/writes account + session data over
  admin-bff `/bff/internal` (never touches admin-bff-db — the two BFF databases are
  mutually denied at the NetworkPolicy layer).
- **`snapdragon-gateway`** — the `BffJwtExchangeWebFilter` that swaps `bff_` →
  custody JWT (pre-security, fail-closed, dark) + the PUBLIC `/bff/auth/callback`
  route-access seed.
- **`snapdragon-login-ui`** — the Casdoor OIDC authorization-code + PKCE redirect +
  `/login/callback`.
- **`snapdragon-generator`** (this repo) — the `app-user-bff` Casdoor OIDC
  confidential client + the PUBLIC `/bff/auth/callback` route-access seed (#156).

```mermaid
sequenceDiagram
    autonumber
    participant B as Browser (login-ui)
    participant C as Casdoor (IdP)
    participant GW as snapdragon-gateway
    participant UB as user-bff
    participant AB as admin-bff (+ admin-bff-db)
    Note over B: "Sign in" - generate PKCE verifier+S256 challenge, state, nonce
    B->>C: redirect /login/oauth/authorize (code, S256)
    C-->>B: redirect /login/callback?code&state
    B->>GW: POST /bff/auth/callback {code, verifier} [PUBLIC route]
    GW->>UB: forward
    UB->>C: OidcExchangeClient.exchangeCode(code, verifier)
    C-->>UB: Casdoor JWTs [access + refresh]
    UB->>AB: /bff/internal ensureAccount, createSession - opaque bff_
    UB->>AB: /bff/internal custody/stamp [BffCustodyCipher.encrypt] - stored in bff_session.*_enc
    UB-->>B: Set-Cookie bff_ [opaque] - browser NEVER sees the JWT
    Note over B,GW: subsequent requests carry the opaque bff_
    B->>GW: Authorization: Bearer bff_... [any /api or /bff route]
    GW->>AB: /bff/internal/session/exchange [mTLS + X-Internal-Token]
    AB-->>GW: custody JWT [lazy-refresh near expiry, fail-closed]
    Note over GW: rewrite Authorization: Bearer custody-jwt, THEN resource-server JWT validation + route-access/revocation/MFA
    GW->>UB: forward [downstream sees a normal Casdoor JWT]
```

**Invariants** (the security contract — must hold in every deployment):

- The browser holds **only** the opaque `bff_` — the Casdoor JWT is never sent to
  or stored in the client.
- The custody JWT is **encrypted at rest** (AES-256-GCM) in `bff_session`
  (`access_token_enc` / `refresh_token_enc`).
- The gateway swap is **pre-security** and **fail-closed**: any exchange error ⇒
  `401`, and the raw `bff_` is **never** forwarded downstream.
- The `/bff/internal/**` surface is reachable only over mTLS + `X-Internal-Token`,
  and the two BFF databases (admin-bff-db / user-bff-db) are mutually denied at the
  NetworkPolicy layer.

**Ships-dark flags** (all default off/blank): `app.bff.oidc.enabled`
(user-bff/auth-core) · `app.bff.custody-key` (`BffCustodyCipher`) ·
`app.session.cookie.enabled` (the `bff_` cookie) ·
`snapdragon.gateway.bff-exchange.enabled` (gateway swap) · `__SNAP_OIDC_ENABLED__`
(login-ui).

### Progress (as of 2026-06-20)

**✅ shipped (merged to `main`):**

- **auth-core extracted + published (now `2.3.0`)** — shared account/session/MFA/Casdoor
  stack + the custody seams (`OidcExchangeClient`, `BffCustodyCipher`,
  `SessionCookieService`, `InternalTokenWebFilter`). The `2.1.0` BFF-JWT-custody
  columns, the `2.2.0` per-account session-listing seam and the `2.3.0`
  `gen_random_uuid()` mint change have all since shipped; admin-bff + user-bff
  both consume `2.3.0`.
- **admin-bff adopted auth-core** (PR #111) — behavior-preserving, 1517 tests green.
- **admin-bff `/bff/internal` account/session API** (PR #113) —
  ensure / get / complete / allowlist / sessions / namespaces, guarded by
  `InternalTokenWebFilter`; ships inert.
- (prior) gateway live + raw-API security proven + the SCG-5 route-namespace bug fixed.

> The `auth-core` `2.1.0` BFF-JWT-custody columns
> (`access_token_enc` / `refresh_token_enc` / `access_token_expires_at` /
> `custody_updated_at`) + `stampCustody` / `clearCustody` / `sessionRow` that this
> snapshot tracked as in-flight have since **shipped** (current published `2.3.0`).

**🚧 in-flight (open draft PRs, all dark):**

- **gateway PR-C** — `BffJwtExchangeWebFilter` (`bff_` → custody-JWT, pre-security,
  fail-closed, `snapdragon.gateway.bff-exchange.enabled`).
- **login-ui PR-4** — Casdoor OIDC + PKCE + `/login/callback` (`__SNAP_OIDC_ENABLED__`).
- **user-bff PR-A3** — OIDC login relocation + admin-bff internal client
  (`app.bff.oidc.enabled`).

**🔭 planned / next:**

- **admin-bff custody tail** — Liquibase band-180 (`bff_session` custody columns) +
  `/bff/internal/sessions/{token}/custody/stamp` + `/bff/internal/session/exchange`;
  bumps the auth-core dep in lockstep (the auth-core custody seam has since shipped
  in `2.3.0`).
- **generator #156** (✅ now merged) — `app-user-bff` Casdoor OIDC client + PUBLIC
  `/bff/auth/callback` route seed; the user-bff OIDC-enable + gateway BFF-session
  filter (#171) and the SSO-secret bootstrap seeding (#172) followed on `main`.
- a cross-repo **NetworkPolicy egress peer** user-bff → admin-bff internal `:8080`
  (manifests/generator).
- **SSO end-to-end live e2e** — kind + Playwright, proving the browser holds only `bff_`.

## GitOps

The pki control-plane installs ArgoCD (pinned to the x86_64 worker) and a root
**app-of-apps** pointing at [`specs/cluster`](../specs/cluster). ArgoCD then
syncs Casdoor, Cassandra, the three public gateways (behind an ingress-nginx
facade) plus the tailnet-only superadmin gateway, Akkoma + tuwunel, Forgejo
(in-cluster git), the Spring APIs, the frontend host, the matrix-ui / mastodon-ui
remotes (the `social-ui` ArgoCD grouping), and snapdragon.games. See
[`specs/cluster/README.md`](../specs/cluster/README.md).

> **GitOps source migration — ⏳ PARTIAL.** Today the root app-of-apps syncs from
> the **GitHub** `snapdragon-generator` repo. The move to an **in-cluster Forgejo**
> source-of-truth is scaffolded — the Forgejo deploy (`apps/09-forgejo.yaml`), the
> service-catalog `scmProvider` ApplicationSet (`apps/13-service-catalog.yaml`,
> already configured to scan the in-cluster Forgejo) and the deploy contract
> (`catalog/snapdragon-deploy.example.yaml`) all exist — but the source flip is
> **live-gated** (needs a booted Forgejo + admin + OIDC + the org mirror +
> `forgejo-scm-token`), and **no service repo has adopted `snapdragon-deploy.yaml`
> + a `deploy/` kustomize tree yet** (prep-able now). See [`DEVOPS.md`](DEVOPS.md).

### Autoscaling

CPU-based **HPA** is wired on many workloads — `frontend`, `social-ui`,
`remote-fragment`, `mod-bff-api`, `admin-bff-api`, `user-bff-api`, `forum-bff-api`,
`user-ui`, `mod-ui`, `forum-ui`, `api-docs` (`manifests/<svc>/hpa.yaml`) — backed
by **metrics-server** (`apps/01-metrics-server.yaml`). **KEDA** is also present
(`apps/01b-keda.yaml`) for event/queue-driven scaling. ⏳ **Remaining:**
latency/memory-based scaling beyond CPU.

## Secrets (Vault + USB)

Cluster secrets are generated once by
[`scripts/gen-cluster-secrets.sh`](../scripts/gen-cluster-secrets.sh) and pushed
to **HashiCorp Vault** (KV v2, mount `secret/`, base path `snapdragon/` — the
base segment tracks the brand slug). The **External Secrets Operator** then
materializes the k8s Secrets the workloads already consume — `casdoor-google`
(`snapdragon-pki`), `clickhouse-auth` (`snapdragon-backend` + `observability`)
and `uptrace-auth` (`observability`) — via a ClusterSecretStore
**`snapdragon-vault`** (provider `vault`, token auth from the `vault-token`
Secret in `external-secrets`), one ExternalSecret per Secret, refreshed hourly.
Workload `secretKeyRef`s are unchanged.

The same materialized secrets are also written to the KEYS stick at
`vault/secrets.json` (plus `vault/token` for online sync), so `keys-provision`
can create them offline — **Vault first, USB fallback** — when Vault is
unreachable.

## Mesh, storage & backups

- **Mesh:** headscale on the pki node; every node runs the tailscale client and
  joins via a preauth key from its KEYS stick.
- **Storage:** `storage.devices[]` in the KEYS manifest mounts attached M.2/NVMe
  or USB disks and can relocate `containerd`/`kubelet` data onto them.
- **Backups:** `backup.*` schedules etcd + PostgreSQL backups to attached
  storage and/or an NFS/CIFS network share (`/usr/local/sbin/snapdragon-backup`).

## Superadmin, multi-tenancy and the role cascade

The platform is **multi-tenant / multi-brand**: one fleet can host several
domains, and a least-privilege role cascade (**superadmin → admin → mod → user**,
domain-scoped, enforced at the gateway) governs every surface.

- **Multi-tenancy (✅ shipped):** per-domain CA loop (`brands/domains.conf`),
  per-domain namespace + mTLS isolation as the authoritative cross-domain
  boundary; one admin-bff ↔ one Casdoor org ↔ one homeserver per brand.
- **Superadmin (✅ shipped):** a real code-enforced role owning device-licenses and
  domain CRUD. Its Service Catalog console + `service-catalog-ui` remote are served by the
  tailnet-only `snapdragon-superadmin-gateway` (`apps/22-gateway-superadmin.yaml`)
  on the pki node's internal ingress — off every public gateway.
- **Superadmin Service Catalog (✅ shipped on `main`):** the data layer (admin-bff
  service-curation / app-profile / service-deployment) **and** the infra legs —
  the tailnet superadmin-gateway plus the Kaniko in-cluster build namespace
  (`apps/54-service-catalog-builder.yaml`, ships dark until a build lands) merged via
  PR #110. The per-build Kaniko Job is a template the admin-bff `AddService` task
  instantiates; ArgoCD never applies it directly.
- **Device-license + node-storage registries (✅ shipped):** see
  [`DEVICE-REGISTRY-KEY-ROTATION.md`](DEVICE-REGISTRY-KEY-ROTATION.md) and
  [`NODE-STORAGE.md`](NODE-STORAGE.md). Layer-B per-node sshd off the signed
  export is shipped; the Layer-A headscale ACL push is 🔭 deferred.
- **Optional-services framework (✅ build-time, 🚧 live cut-over):** akkoma /
  tuwunel / phpBB / games add/remove via the `apps/13a` ApplicationSet; the UI
  greys when a service is absent, and games defaults to `games.<domain>`. Today
  the build-time prune ships and the hardcoded `30-*/50-*` Applications still own
  the workloads — the live ApplicationSet cut-over is pending. See
  [`OPTIONAL-SERVICES.md`](OPTIONAL-SERVICES.md).
- **Egress-VPN, games App-Store control plane, owncast, tube, notifications
  in-app MVP (✅ shipped):** see [`EGRESS-VPN.md`](EGRESS-VPN.md),
  [`GAMES-APPSTORE.md`](GAMES-APPSTORE.md), and the cluster apps `29a`, `52`, `53`,
  `13c`.
- **Pen-test CI (✅ shipped):** continuous OWASP (ZAP DAST + Dependency-Check SCA +
  nuclei + k6) as a GitLab CI-pipeline stage, not a deployed CronJob. See
  [`PENTEST-SCHEDULES.md`](PENTEST-SCHEDULES.md).

### Roadmap (🔭 planned / 🚧 in-flight)

These are **not shipped as user-facing features** on `main`; the in-cluster
backstops noted below may already be present but inert.

- **🚧 Workload Console** — podman/OpenShift-like pod-management + live-log + exec
  federated admin-ui module (admin-bff 110-band). The least-privilege RBAC
  backstop is on `main` (`apps/14-workload-console-rbac.yaml`) but **ships dark**
  (`app.workload-console.k8s.enabled=false`); superadmin gets cross-cluster
  manage+exec, admins are default-blind until superadmin-granted read-only on
  their own domain.
- **🔭 Casdoor MFA** — WebAuthn + TOTP + recovery; per-role defaults
  (superadmin/admin required, mod relaxable, user optional); enforced via
  `amr/acr → MFA_SATISFIED` + `gateway_route_access.mfa_required` (fail-closed) +
  step-up for sudo / SSH-via-UI / remote-install. Design done (admin-bff
  Liquibase 150-band); see [`ROUTE-ACCESS.md`](ROUTE-ACCESS.md).
- **🔭 Desktop app governance** — per-license SSO-enforced sudo + admin-curated
  Plasma Discover store + user install-requests + admin remote-install; extends
  [`CLIENT-IMAGES.md`](CLIENT-IMAGES.md).
- **🚧 Notifications external channels** — Matrix DM + Akkoma feed + phpBB + email
  adapters on top of the shipped in-app MVP; mod-bff `notify_channels` directive.
- **🚧 Generator supply-chain hardening** — verify stage3 GPG/sha + headscale /
  tailscale binary checksums + de-default baked creds.

## Related repositories

| Repo | Role |
|---|---|
| `Snapdragon-Systems/snapdragon-generator` | This repo — image builders, provisioning, GitOps payload |
| `Snapdragon-Systems/snapdragon-gateway` | Shared Spring Cloud Gateway code/image |
| `Snapdragon-Systems/snapdragon-pki-gateway` | PKI/identity gateway (Casdoor OAuth2, Postgres routes) — renamed from `snapdragon-id-gateway` |
| `Snapdragon-Systems/snapdragon-be-gateway` | Backend gateway (per-node, reuses the shared gateway image) |
| `Snapdragon-Systems/snapdragon-fe-gateway` | Frontend gateway (per-node, reuses the shared gateway image) |
| `Snapdragon-Systems/snapdragon-actions` | Spring APIs |
| `Snapdragon-Systems/snapdragon-admin-bff-api` | Spring admin BFF (allowlist, namespace access, usage, token broker) |
| `Snapdragon-Systems/snapdragon-mod-bff-api` | Spring moderator BFF |
| `Snapdragon-Systems/snapdragon-user-bff-api` | Spring user BFF |
| `Snapdragon-Systems/snapdragon-forum-bff-api` | Spring forum BFF (phpBB-facing) |
| `Snapdragon-Systems/snapdragon-federation-api` | Public-profile / vanity-subdomain + federation resolver |
| `Snapdragon-Systems/snapdragon.systems` | Angular host front page (federates the remotes) |
| `Snapdragon-Systems/snapdragon-matrix-ui` | Matrix chat + WebRTC video micro-frontend (renamed from `snapdragon-social-ui`) |
| `Snapdragon-Systems/snapdragon-mastodon-ui` | Mastodon micro-frontend |
| `Snapdragon-Systems/snapdragon-login-ui` | Login/registration micro-frontend |
| `Snapdragon-Systems/snapdragon-admin-ui` | Admin console micro-frontend (role-gated) |
| `Snapdragon-Systems/snapdragon-mod-ui` | Moderator console micro-frontend |
| `Snapdragon-Systems/snapdragon-user-ui` | User console micro-frontend |
| `Snapdragon-Systems/snapdragon-forum-ui` | Forum micro-frontend |
| `Snapdragon-Systems/snapdragon-remote-fragment` | Shared federated-remote fragment scaffolding |
| `Snapdragon-Systems/snapdragon-superadmin-service-catalog-ui` | Superadmin Service Catalog console (genesis / 🚧 in-flight) |
| `owncast` / LocalTube (`tube`) | GPU-dependent video services (per-domain enable, federated per-user remotes) |
| `Snapdragon-Systems/snapdragon.games` | Game studio and portal (runs on the x86_64 GPU worker) |
| `Snapdragon-Systems/sdn` | headscale / SDN config |
