# Snapdragon cluster architecture

Everything connects **behind `snapdragon.systems`** through per-namespace
Spring Cloud Gateways that validate a single internal Casdoor OAuth2 JWT.
Cloudflare maps the public `snapdragon.systems` / `snapdragon.games` names onto
those gateways (configured later, out of scope here).

## Nodes & images

| Image | Build | Arch | Role in the cluster |
|---|---|---|---|
| `pki` | `build-rpi5-stage4.sh --role pki` | aarch64 (RPi 5) | **Kubernetes control plane** + identity: headscale (mesh control), Casdoor, Cassandra, `snapdragon-pki-gateway` |
| `backend` | `build-rpi5-stage4.sh --role backend` | aarch64 (RPi 5) | Matrix (Synapse), Mastodon, Spring APIs, databases, `snapdragon-be-gateway` |
| `frontend` | `build-rpi5-stage4.sh --role frontend` | aarch64 (RPi 5) | `snapdragon.systems` Angular host + `snapdragon-social-ui`, `snapdragon-fe-gateway` |
| `host` | `build-x86-host-stage4.sh` | x86_64 (desktop/server) | GPU worker: ArgoCD, `snapdragon.games`, extra backend capacity (Mesa/Vulkan via `/dev/dri`) |

All nodes are hardened Gentoo, join one Kubernetes cluster, sit on one headscale
mesh, and are provisioned at first boot from a USB **KEYS** stick (see
[`keys-template/`](../keys-template/README.md)). The pki Pi is the kubeadm
control plane; backend/frontend Pis and the x86_64 host join it as workers and
are labelled (`snapdragon.systems/role`, `…/compute=gpu`) so workloads land on
the right hardware.

```
                          Cloudflare (snapdragon.systems / snapdragon.games)
                                           │
                 ┌─────────────────────────┼──────────────────────────┐
                 ▼                          ▼                          ▼
        snapdragon-fe-gateway      snapdragon-be-gateway      snapdragon-pki-gateway
        (snapdragon.systems)   (api/matrix/mastodon.*)        (id.snapdragon.systems)
                 │                          │                          │
   ┌─────────────┴───────┐     ┌────────────┴───────────┐     ┌────────┴─────────┐
   │ snapdragon-frontend │     │   snapdragon-backend   │     │  snapdragon-pki  │
   │  • systems web host │     │  • Matrix (Synapse)    │     │  • Casdoor (IdP) │
   │  • social-ui (mtx/  │     │  • Mastodon            │     │  • Cassandra     │
   │    mastodon remotes)│     │  • Spring APIs + DBs   │     │  • headscale     │
   └─────────────────────┘     └────────────────────────┘     └──────────────────┘
        frontend Pis                  backend Pis                pki Pi (CP)
                                           
                    argocd ns + snapdragon-games ns  ──►  x86_64 GPU worker
```

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
- Matrix (Synapse OIDC) and Mastodon (OIDC) both SSO against Casdoor, so the
  `snapdragon.systems` front page can show **Matrix / Mastodon links to
  logged-in users** and hand each module a service access token — the
  [`snapdragon-social-ui`](https://github.com/Snapdragon-Systems/snapdragon-social-ui)
  Angular micro-frontends never render their own login forms.

## GitOps

The pki control-plane installs ArgoCD (pinned to the x86_64 worker) and a root
**app-of-apps** pointing at [`specs/cluster`](../specs/cluster). ArgoCD then
syncs Casdoor, Cassandra, the three gateways, Matrix, Mastodon, the Spring APIs,
the frontend host, the social-ui, and snapdragon.games. See
[`specs/cluster/README.md`](../specs/cluster/README.md).

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

## Related repositories

| Repo | Role |
|---|---|
| `Snapdragon-Systems/catalyst-scripts` | This repo — image builders, provisioning, GitOps payload |
| `Snapdragon-Systems/snapdragon-gateway` | Shared Spring Cloud Gateway code/image |
| `Snapdragon-Systems/snapdragon-pki-gateway` | PKI/identity gateway (Casdoor OAuth2, Postgres routes) — renamed from `snapdragon-id-gateway` |
| `Snapdragon-Systems/snapdragon-be-gateway` | Backend gateway (per-node, reuses the shared gateway image) |
| `Snapdragon-Systems/snapdragon-fe-gateway` | Frontend gateway (per-node, reuses the shared gateway image) |
| `Snapdragon-Systems/snapdragon-auth` | Spring Authorization Server |
| `Snapdragon-Systems/snapdragon-actions` | Spring APIs |
| `Snapdragon-Systems/snapdragon-admin-bff` | Spring admin BFF (allowlist, namespace access, usage, token broker) |
| `Snapdragon-Systems/snapdragon.systems` | Angular host front page (federates the remotes) |
| `Snapdragon-Systems/snapdragon-matrix-ui` | Matrix chat + WebRTC video micro-frontend (renamed from `snapdragon-social-ui`) |
| `Snapdragon-Systems/snapdragon-mastodon-ui` | Mastodon micro-frontend |
| `Snapdragon-Systems/snapdragon-login-ui` | Login/registration micro-frontend |
| `Snapdragon-Systems/snapdragon-admin-ui` | Admin console micro-frontend (role-gated) |
| `Snapdragon-Systems/snapdragon.games` | Game (runs on the x86_64 GPU worker) |
| `Snapdragon-Systems/sdn` | headscale / SDN config |
