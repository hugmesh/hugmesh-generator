# HugMesh security model

Defense-in-depth: every application UI/API is a **distinct identity** at three
layers, and the container runtime + network are confined to those identities.

## 1. LSM — SELinux on every image

All images (RPi `pki`/`backend`/`frontend`, x86_64 `host`) build from the
`hardened/selinux` profile with SELinux as the LSM
AppArmor is removed. The stack is per arch and is what the kernel actually runs
(`tests/scripts/test-lsm-posture-honesty.sh` fails the build if an image advertises
a name its kernel did not compile in):

| Boards | `CONFIG_LSM` / `lsm=` | `lockdown=` |
|---|---|---|
| x86, rpi5 | `lockdown,yama,selinux,bpf` | `integrity` |
| the 8 ARM boards (La Frite, Jetson, Orange Pi Zero 2 / Zero 2W / Zero 3 / 3 LTS / 4 LTS / 5) | `lockdown,yama,selinux` | `integrity` |

`bpf` is registered only on x86 and rpi5. Both now build the BTF a
`BPF_PROG_TYPE_LSM` program needs to attach; that an attach really succeeds on a booted
image is not yet proven (see the README roadmap). Lockdown selects
`CONFIG_MODULE_SIG`, so modules built with the kernel are signed and an unsigned
out-of-tree `.ko` is refused at runtime on every board.

- **Pi (cross-built):** SELinux policy packages' `pkg_postinst` runs the *target*
  `semodule`, which can't execute under aarch64 cross-emerge — so `keys-provision`
  loads the base policy + relabels the filesystem **natively at first boot**
  (`provision_selinux()`), starting **permissive** (flip to enforcing after a
  clean relabel: `setenforce 1` + `SELINUX=enforcing`).
- **x86 (native):** policy loads at build time.
- Mode/type are set from the KEYS manifest: `selinux.mode` (default `permissive`),
  `selinux.type` (default `mcs`).

## 2. Containers locked to SELinux roles

`containerd` runs with `enable_selinux = true` (+ category range), so every pod
is labelled `container_t` with a unique MCS category pair — pods are mutually
isolated by SELinux. Kubernetes refines this per workload via
`securityContext.seLinuxOptions`, giving **each application its own role/level**.

## 3. The per-application identity matrix

Each app UI/API is one identity across SELinux, Casdoor and Kubernetes, with a
Vault-managed mTLS keystore:

| Application | k8s ServiceAccount | SELinux `seLinuxOptions` (level) | Casdoor user / role | JKS keystore (CN) |
|---|---|---|---|---|
| `hugmesh-pki-gateway` | `sa-pki-gateway` | `s0:c11` | `svc-pki-gateway` / `ROLE_GATEWAY` | `hugmesh-pki-gateway.hugmesh-pki.svc` |
| `hugmesh-be-gateway` | `sa-be-gateway` | `s0:c12` | `svc-be-gateway` / `ROLE_GATEWAY` | `hugmesh-be-gateway.hugmesh-backend.svc` |
| `hugmesh-fe-gateway` | `sa-fe-gateway` | `s0:c13` | `svc-fe-gateway` / `ROLE_GATEWAY` | `hugmesh-fe-gateway.hugmesh-frontend.svc` |
| `hugmesh-gateway-superadmin` | `sa-gateway-superadmin` | `s0:c17` | `svc-gateway-superadmin` / `ROLE_GATEWAY` | `hugmesh-gateway-superadmin.hugmesh-pki.svc` |
| `hugmesh-api` (actions) | `sa-api` | `s0:c22` | `svc-api` / `ROLE_API` | `hugmesh-api.hugmesh-backend.svc` |
| `admin-bff` (api) | `sa-admin-bff` | `s0:c23` | `svc-admin-bff` / `ROLE_ADMIN_API` | `admin-bff.hugmesh-backend.svc` |
| `admin-bff-db` | `sa-admin-bff-db` | `s0:c26` | (DB) | (non-Java: PEM, no JKS) |
| `federation-api` | `sa-federation` | `s0:c24` | `svc-federation` / `ROLE_FEDERATION` | `federation-api.hugmesh-backend.svc` |
| `federation-db` | `sa-federation-db` | `s0:c25` | (DB) | (non-Java: PEM, no JKS) |
| `mod-bff-api` | `sa-mod-bff` | `s0:c27` | `svc-mod-bff` / `ROLE_MOD_API` | `mod-bff.hugmesh-backend.svc` |
| `mod-bff-db` | `sa-mod-bff-db` | `s0:c28` | (DB) | (non-Java: PEM, no JKS) |
| `user-bff-api` | `sa-user-bff` | `s0:c29` | `svc-user-bff` / `ROLE_USER_API` | `user-bff.hugmesh-backend.svc` |
| `user-bff-db` | `sa-user-bff-db` | `s0:c38` | (DB) | (non-Java: PEM, no JKS) |
| `forum-bff-api` | `sa-forum-bff` | `s0:c53` | `svc-forum-bff` / `ROLE_FORUM_API` | `forum-bff.hugmesh-backend.svc` |
| `forum-bff-db` | `sa-forum-bff-db` | `s0:c52` | (DB) | (non-Java: PEM, no JKS) |
| `wiki-bff-api` | `sa-wiki-bff` | `s0:c69` | `svc-wiki-bff` / `ROLE_WIKI_API` | `wiki-bff.hugmesh-backend.svc` |
| `wiki-bff-db` | `sa-wiki-bff-db` | `s0:c68` | (DB) | (non-Java: PEM, no JKS) |
| `service-catalog-ui` (superadmin Service Catalog console; tailnet-only) | `sa-service-catalog-ui` | `s0:c49` | `svc-service-catalog-ui` / `ROLE_SUPERADMIN_UI` | `hugmesh-superadmin-service-catalog-ui.hugmesh-frontend.svc` |
| `service-catalog-builder` (Kaniko build pods) | (per-build) | `s0:c54` | (build pod) | (non-Java: no JKS) |
| `route-access` | `sa-route-access` | `s0:c15` | (DB) | — |
| `forgejo` (GitOps) | `sa-forgejo` | `s0:c16` | per-app svc user | — |
| `clickhouse` (analytics) | per-app SA | `s0:c19` | (DB) | — |
| `kafka` (analytics) | per-app SA | `s0:c20` | per-app svc user | — |
| `lan-dns` (coredns) | per-app SA | `s0:c57` | — | — |
| `cloudflared` | per-app SA | `s0:c56` | — | — |
| `casdoor` | per-app SA | `s0:c21` | (IdP) | (non-Java: PEM, no JKS) |
| `casdoor-pg` | per-app SA | `s0:c14` | (DB) | — |
| `signup-gate` | per-app SA | `s0:c36` | per-app svc user | — |
| `media-poisoner` | per-app SA | `s0:c18` | — | (non-Java: PEM, no JKS) |
| `egress-proxy` | per-app SA | `s0:c37` | — | — |
| `binhost` | per-app SA | `s0:c60` | — | — |
| `vault` | per-app SA | `s0:c70` | — | — |
| `anubis` (PoW gate) | per-app SA | `s0:c62` | — | — |
| `frontend` (host web) | per-app SA | `s0:c40` | — | — |
| `social-ui` (host-web / matrix / mastodon / login) | per-app SA | `s0:c41` / `s0:c42` / `s0:c43` / `s0:c44` | per-app svc user | — |
| `remote-fragment` | per-app SA | `s0:c45` | — | — |
| `mod-ui` | per-app SA | `s0:c46` | — | — |
| `user-ui` | per-app SA | `s0:c47` | — | — |
| `api-docs` | per-app SA | `s0:c48` | — | — |
| `forum-ui` | per-app SA | `s0:c58` | — | — |
| `wiki-ui` | per-app SA | `s0:c71` | — | — |
| `observability` (postgres / uptrace) | per-app SA | `s0:c59` / `s0:c61` | — | — |
| akkoma (mastodon) | per-app SA | `s0:c30` / `s0:c31` | per-app svc user | (non-Java: PEM, no JKS) |
| tuwunel (matrix) | per-app SA | `s0:c32` | per-app svc user | (non-Java: PEM, no JKS) |
| games | per-app SA | `s0:c33` | per-app svc user | (non-Java: PEM, no JKS) |
| casdoor-games | per-app SA | `s0:c35` | (IdP) | (non-Java: PEM, no JKS) |
| casdoor-games-pg | per-app SA | `s0:c34` | (DB) | — |
| owncast | per-app SA | `s0:c39` | per-app svc user | — |
| tube | per-app SA | `s0:c55` | per-app svc user | — |
| phpbb (forum) | per-app SA | `s0:c51` | per-app svc user | — |
| phpbb-db (forum) | per-app SA | `s0:c50` | (DB) | — |
| `cassandra` (gateway revocation + URL registry) | per-app SA | `s0:c63` | (DB) | (non-Java) |
| `velero` (cloud-backup controller — server) | `velero` | `s0:c64` | — (no Casdoor user; cluster controller) | (non-Java: no JKS) |
| `velero-node-agent` (Kopia filesystem/PV backups) | `velero` | `s0:c65` | — | (non-Java: no JKS) |
| `backups-status-sweep` (cloud-backup CR-status sweep CronJob) | `backups-sweep` | `s0:c66` | — | (non-Java: no JKS) |
| coturn (TURN/STUN — optional, default-off) | `sa-coturn` | `s0:c67` | per-app svc user | (non-Java: no JKS) |
| `edge-ai` (ollama inference — GPU) | per-app SA | `s0:c73` | — | (non-Java: no JKS) |
| `edge-ai-analysis` (task-oriented analysis API in front of edge-ai — optional, default-off) | per-app SA | `s0:c87` | — | (non-Java: no JKS) |
| `character-studio` (ui) | per-app SA | `s0:c74` | — | — |
| `image-builder` (app-image Kaniko build pods) | (per-build) | `s0:c75` | (build pod) | (non-Java: no JKS) |
| `edge-ai-tts` (Piper TTS) | per-app SA | `s0:c72` | — | (non-Java: no JKS) |
| meshbridge (Meshtastic ↔ Matrix bridge — optional, default-off) | `sa-meshbridge` | `s0:c76` | (Casdoor machine client — manual, see meshbridge ESO) | (non-Java: no JKS) |
| `headwind-db` (Headwind MDM Postgres — optional, default-off) | `sa-headwind-db` | `s0:c77` | (DB) | (non-Java: PEM, no JKS) |
| `headwind` (Headwind MDM app — optional, default-off) | `sa-headwind` | `s0:c78` | — (LocalAuth admin, not Casdoor — see headwind-admin ESO) | (Java/Tomcat: no JKS — plain HTTP, TLS terminated at gateway) |
| `attestation-server` (GrapheneOS AttestationServer — optional, default-off, single pod, no DB leg) | `sa-attestation-server` | `s0:c79` | — (SQLite-local accounts, not Casdoor — `/attest/api/**` gated ROLE_SUPERADMIN at the gateway) | (Java: no JKS — plain HTTP, TLS terminated at gateway) |
| `mesh-bff-api` (LoRa mesh BFF: node directory / bridge-sync) | (pod default SA) | `s0:c80` | `mesh-bff-casdoor-client` (client-credentials → ROLE_SERVICE, manual — see secretstore ESO) | `hugmesh-mesh-bff-api.hugmesh-backend.svc` |
| `mesh-bff-db` (dedicated Postgres for mesh-bff-api) | (pod default SA) | `s0:c81` | (DB) | (non-Java: PEM, no JKS) |
| `character-forge-bff-db` (character-forge — optional, default-off) | per-app SA | `s0:c82` | (DB) | (non-Java: PEM, no JKS) |
| `character-forge-bff-api` (character-forge — optional, default-off) | per-app SA | `s0:c83` | `svc-character-forge-bff` / `ROLE_CHARACTER_FORGE_API` | `hugmesh-character-forge-bff-api.hugmesh-backend.svc` |
| `character-forge-ui` (character-forge — optional, default-off) | per-app SA | `s0:c84` | — | — |

The matrix is the contract: `seLinuxOptions.level` per Deployment (added to each
chart/manifest), a `ServiceAccount` per app, a Casdoor service user+role created
at bootstrap, and a JKS keystore issued by `gen-keystores.sh`. Each MCS category
(`s0:cNN`) is **unique** — no two workloads may share one, so a compromised pod
cannot read another's category-isolated volumes.

> **service-catalog-ui note (reservation DISCHARGED 2026-08-26):** this row used to
> read "no Deployment yet" and mark `s0:c49` *(reserved)* — the console shipped only a
> federation descriptor
> (`manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml`),
> a gateway route and route-access rows, with nothing to serve them. The Deployment +
> Service now exist (`manifests/superadmin-service-catalog-ui/`) and carry exactly the
> reserved identity: `serviceAccountName: sa-service-catalog-ui` and
> `securityContext.seLinuxOptions: { type: container_t, level: "s0:c49" }`.
>
> **What that reservation cost while it was only prose:** `s0:c49` was silently taken
> by `edge-ai-analysis`, whose manifest picked it as "next free" — correctly, by the
> only evidence available to it, because a reservation with no Deployment is invisible
> to both a manifest scan and the `[mcs]` uniqueness gate (which compares *workloads*).
> The clash surfaced the moment the Deployment was written, and `edge-ai-analysis`
> was moved to `s0:c87`. The durable fix is not the renumber, it is that
> `edge-ai-analysis` had **no row in this matrix at all** — an unlisted workload
> cannot be avoided. Anything holding a category must appear above.

> **`cassandra` MCS note:** category `s0:c63` is injected via the bitnami
> cassandra 12.3.11 chart's **supported** `podSecurityContext.seLinuxOptions`
> **and** `containerSecurityContext.seLinuxOptions` values keys
> (`specs/cluster/apps/00-cassandra.yaml`) — only `seLinuxOptions.level` is set;
> all other securityContext chart defaults are untouched. This is a clean values
> override (no chart fork / template patch), so it is **not** an exemption.
>
> **Cassandra auth/TLS hardening (ADR-32, DARK — `manifests/cassandra-hardening/`):**
> the per-app least-privilege roles `admin_bff_cass` / `pki_gw_cass` / `be_gw_cass`
> / `fe_gw_cass` / `sa_gw_cass` / `federation_cass` are **Cassandra-internal DB
> login roles** (CQL `CREATE ROLE`, deny-by-default under `CassandraAuthorizer`),
> NOT separate pods/SAs — so they take **no new MCS category**. The two flip-time
> helper Jobs (`cassandra-bootstrap-roles`, `cassandra-tls-keystore-builder`) are
> Cassandra-tier admin clients and run **under the same `s0:c63`** (set explicitly
> in their pod `seLinuxOptions.level`), so they introduce no new node service and
> need **no new `specs/selinux/*.te`/`.fc` module**. **No new listening port** is
> opened: auth/TLS reuse the existing Cassandra CQL `:9042` already covered by the
> `db-ingress-cassandra` NetworkPolicy (PR #128). The credentials are ESO/Vault
> only (`secret/hugmesh/cassandra-admin`, `…/cassandra-app-creds`) — never in
> git. See `docs/CLUSTER-HARDENING-PLAN.md` §H for the enable order.

> **`velero` cloud-backups MCS note:** the opt-in/inert cloud-backups leg
> (`specs/cluster/apps/55-velero.yaml`, `specs/cluster/manifests/velero/`) runs
> THREE distinct pods in the `velero` namespace, each with its own unique
> category: the Velero **server** `s0:c64` and the **node-agent** DaemonSet
> `s0:c65` are injected via the upstream Velero 12.0.3 chart's **supported**
> `podSecurityContext.seLinuxOptions` + `containerSecurityContext.seLinuxOptions`
> (and `nodeAgent.podSecurityContext` / `nodeAgent.containerSecurityContext`)
> values keys — only `seLinuxOptions.level` set, all other chart securityContext
> defaults untouched (same clean values override as cassandra, no fork). The
> `backups-status-sweep` CronJob carries `s0:c66` on its pod `securityContext`
> (`specs/cluster/manifests/velero/sweep-cronjob.yaml`). The admin-bff
> `cloudbackup` **effector** identity (k8s SA `backups-effector`, granted
> create/get/list/patch on `velero.io` Backup/Restore via
> `specs/cluster/manifests/velero/rbac.yaml`) runs INSIDE the `admin-bff` pod and
> therefore inherits `admin-bff`'s `s0:c23` — it does **not** take a category of
> its own. The whole leg ships dark (app 55/56 manual-sync + the admin-bff
> `app.backups.effector.enabled=false` default), so these categories are reserved
> correct-by-construction and become live only on a deliberate superadmin opt-in.

> **`coturn` TURN-relay MCS note:** the OPTIONAL, DEFAULT-OFF coturn relay
> (`specs/cluster/manifests/coturn/`) carries category `s0:c67` on its pod
> `securityContext.seLinuxOptions.level` (`deployment.yaml`) and runs as the
> dedicated SA `sa-coturn` (`service-account.yaml`,
> `automountServiceAccountToken:false` — coturn needs no Kubernetes API). It
> co-resides in `hugmesh-backend` with tuwunel (`s0:c32`) so they can share the
> ESO-synced TURN long-term-credential secret (`coturn-shared-secret`), but the
> unique MCS category keeps the two pods category-isolated. coturn ships dark
> (RUNTIME-ONLY: no baked Application; gated by the apps/13a element +
> `installed-services` ConfigMap `coturn:"false"`), so the category becomes live
> only on a deliberate per-domain opt-in. See [`docs/COTURN.md`](COTURN.md).

> **Node-service custom domains:** the host-service SELinux domains in
> [`specs/selinux/*.te`](../specs/selinux/) are part of this contract for
> **node** processes (not pods). The full set:
>
> | Module (`.te`/`.fc`) | Domain(s) | Confines | Binary / labelled path |
> |---|---|---|---|
> | `localpath_provisioner` | `localpath_provisioner_t`, `localpath_provisioner_helper_t` | local-path-provisioner controller + busybox helper (pod, runtime transition) | `/mnt/{data,usb}/local-path` |
> | `otel_collector` | `otel_collector_t` | otel-collector DaemonSet (pod, runtime transition) | (no host exec; `/var/log/pods`) |
> | `hugmesh_authkeys` | `hugmesh_authkeys_t` (+ `hugmesh_authkeys_cache_t`) | the AuthorizedKeysCommand (sshd_t domtrans, runs as nobody) — **security-load-bearing** | `/usr/sbin/hugmesh-authorized-keys-lookup`; `/etc/hugmesh/registry` |
> | `hugmesh_device_registry_sync` | `hugmesh_device_registry_sync_t` | Layer-B registry sync daemon (writes the export cache + the sshd_config.d drop-in, reloads sshd) | `/usr/sbin/hugmesh-device-registry-sync` |
> | `hugmesh_breakglass` | (label only — `ssh_home_t`) | the loopback break-glass authorized_keys file so sshd reads it on enforcing | `/etc/ssh/break-glass.keys` |
> | `hugmesh_vpn` | `hugmesh_vpn_runner_t`, `hugmesh_vpn_reconcile_t` (+ `hugmesh_vpn_etc_t`, `hugmesh_vpn_runtime_t`) | egress-VPN runner (net_admin: wg/tun + ip-rule kill-switch) + the signed-export reconcile agent | `/usr/sbin/hugmesh-vpn-runner`, `/usr/sbin/hugmesh-vpn-reconcile`; `/etc/hugmesh/vpn` |
> | `hugmesh_node_storage` | `hugmesh_node_storage_t` (+ `hugmesh_node_storage_cache_t`) | node-storage reconcile agent (lsblk + FDE pool provision via provision.sh + kubectl nodePathMap patch) | `/usr/sbin/hugmesh-node-storage-reconcile`; `/var/lib/hugmesh/node-storage` |
> | `hugmesh_domain_reconcile` | `hugmesh_domain_reconcile_t` (+ `hugmesh_domain_reconcile_cache_t`) | domain-registry -> brand-repo bridge (#4): mTLS-fetch + verify the signed cross-domain export, then exec gen-keystores.sh + generate-brand-repos.sh to emit per-domain CA + brand GitOps repos into a node-local staging dir (NO block-device admin — emits files only) | `/usr/sbin/hugmesh-domain-reconcile`; `/var/lib/hugmesh/domain-registry` |
> | `hugmesh_policy_sync` | `hugmesh_policy_sync_t` | Layer-A headscale policy-sync agent (pki/control node only; renders + applies policy.hujson) | `/usr/sbin/gen-headscale-policy.sh` |
> | `hugmesh_oidc_token` | (label only — `user_runtime_t`) | the per-user SSO OIDC-token deposit dir read by the desktop bearer-forward GEN-SSO artifact | `/run/user/%{uid}/hugmesh` |
>
> Each row is a **node module** that loads via the **build-host policy compile**
> (the `.pp` is built on the x86 BUILD host, NOT first-boot — the Pi cannot run
> the refpolicy devel toolchain). The shared registry cache type
> `hugmesh_authkeys_cache_t` (declared in `hugmesh_authkeys.te`) is the
> on-disk handoff reused by the device-registry-sync, vpn-reconcile,
> node-storage, and policy-sync domains. See §2 — note that today these custom
> modules are authored but **not yet compiled/installed by any build step**;
> wiring the loader is a fleet-owned (protected) build-script change, precisely
> specified in [`docs/selinux-module-loading.md`](selinux-module-loading.md)
> (tracked separately, NOT applied in that doc's PR).

## 4. mTLS between namespaces — Vault-managed JKS keystores

Each Java machine-user (the Spring Cloud gateways + Spring services) gets its own
**JKS keystore** (private key + CA-signed cert) — its mTLS identity for
cross-namespace calls.

- **Generated** by [`scripts/gen-keystores.sh`](../scripts/gen-keystores.sh) from
  one cluster CA (run by `gen-provision-keys.sh` on the pki node). Verified by
  [`tests/keystores/test-keystores.sh`](../tests/keystores/test-keystores.sh).
- **Multi-tenancy (per-domain CA loop):** by default the generator provisions a
  single domain — byte-/functionally-identical to the pre-multi-tenancy output. A
  build can list multiple brands/domains in
  [`brands/domains.conf`](../brands/domains.conf); the generator then loops,
  **generating an independent-root CA (default) or importing a provided one**
  (the same `--ca-cert`/`--ca-key` seam, now per-domain) for each, and writing
  that domain's keystores under `keystores/<brand>/`. Each domain gets a **NARROW
  truststore** (its own root only) so per-brand gateway/BFF/UI instances deny
  cross-domain mTLS at the trust anchor (defense in depth). One **WIDE
  multi-anchor truststore** (every domain's root) is built under
  `keystores/architecture/` for the **architecture tier ONLY** (Vault /
  federation / superadmin), which must validate cross-domain mTLS. With one
  domain the wide store holds exactly the one root (== the narrow store). The
  single-domain byte-identical invariant + the N≥2 narrow/wide tiers + the
  per-domain import path are proven by
  [`tests/keystores/test-keystores-multidomain.sh`](../tests/keystores/test-keystores-multidomain.sh)
  (which diffs the refactored output against a frozen pre-refactor golden).
  **CA private keys never go in git** — only public certs/truststores; an
  imported `CA_KEY` path must point at the key-USB / a secret dir.
- **Vault-managed:** `gen-cluster-secrets.sh` pushes `keystores/*.jks` +
  `passwords.json` to Vault (KV); the External Secrets Operator syncs each into
  its namespace as a Secret; the pod mounts it and runs with
  `-Djavax.net.ssl.keyStore=/pki/<svc>.keystore.jks`.

## 5. Java truststore from the USB cert chain

`provision_truststore()` builds a PKCS12 truststore (and installs the JKS
truststore) from the **cluster CA / cert chain on the USB KEYS stick**, then
publishes `kube-system/hugmesh-truststore`. Java containers mount it and run
with `-Djavax.net.ssl.trustStore=/pki/truststore.p12
-Djavax.net.ssl.trustStoreType=PKCS12` (set via `JAVA_TOOL_OPTIONS` in the
charts), so all Java IO trusts the cluster CA.

## 6. Identity / login (recap)

Casdoor (`id.<domain>`) is the single OIDC IdP, reached **only from inside the
cluster** — it has **no public ingress** and the browser never talks to it. Human
login is a **native, first-party form**: `login-ui` POSTs username/password (+ any
MFA passcode) to user-bff `POST /bff/login`, which runs PKCE + the internal Casdoor
`/api/login` + code exchange server-side and returns only an opaque `bff_` session
cookie (no JWT, `code_verifier`, `state`, or Casdoor URL ever reaches the client).
Federated sign-up (Google/Discord) and registration stay admin-allowlist-gated
(two-stage). **Service users** (the per-app identities above) are separate Casdoor
accounts with service roles; the gateways validate the Casdoor JWT and the
`External-*` headers. No gateway route proxies Casdoor's `/login/oauth/authorize`
or its hosted UI to the browser.

## 7. Network — Calico via Vault, configured from KEYS

Calico is the CNI (`specs/cluster/apps/01-calico.yaml`). Its tunable config
(pod CIDR, encapsulation/IPIP/VXLAN, BGP ASN, NAT) comes from the KEYS
`provision.json` `calico` block, and its secrets (e.g. BGP passwords, typha
mTLS) are Vault-managed via External Secrets. Default-deny NetworkPolicies per
namespace complement the SELinux isolation.

### Fleet mesh — headscale/tailscale flat L3 (fleet-scoped, default-deny)

Every node joins one tailnet via headscale (control server on the pki/omnibus
node). The mesh is governed by a **default-deny, tag-based ACL** shipped as
`specs/etc/headscale/policy.hujson` and loaded with
`policy.mode: file` + `headscale policy set` (run by `provision_headscale`).

- **Membership tag.** Nodes self-apply `tag:hugmesh` (+ a per-role
  `tag:pki`/`tag:be`/`tag:fe`/`tag:host`) at join via
  `tailscale up --advertise-tags=...`. `tagOwners` restricts those tags to the
  `hugmesh` headscale user (the preauth-key owner), so only enrolled nodes
  can claim them. With OIDC join, the Casdoor `hugmesh/headscale` group
  gates enrolment (`allowed_groups`, matching the group's real `<owner>/<name>`
  claim shape — see `keys-template/headscale/config.yaml`) — two independent
  membership layers.
- **Full intra-fleet mesh.** The only `accept` rules are
  `tag:hugmesh → tag:hugmesh:*` (every node reaches every node, all ports)
  and `tag:hugmesh → {10.244.0.0/16, 10.96.0.0/12}:*` (pods + ClusterIP
  services). There is **no internet-wide `*` grant and no exit-node access** —
  the tailnet is fleet-scoped.
- **Pods/services as one LAN.** Each node advertises the cluster pod
  (`10.244.0.0/16`) and service (`10.96.0.0/12`) CIDRs
  (`--advertise-routes=...`) and accepts approved routes (`--accept-routes`).
  `autoApprovers.routes` maps exactly those two CIDRs to `tag:hugmesh`, so
  advertised subnet routes are **auto-approved** (no manual
  `headscale nodes approve-routes`); `provision_headscale` also backfills
  approval for any node that registered before the policy loaded.
  `--snat-subnet-routes=false` preserves real pod source IPs. IP forwarding for
  the subnet routers is already enabled cluster-wide
  (`specs/etc/sysctl.d/99-kubernetes.conf`: `net.ipv4.ip_forward=1`,
  `net.ipv6.conf.all.forwarding=1`).

The CIDRs in `policy.hujson`, the `--advertise-routes` flags, and
`kubeadm-config.yaml` (`podSubnet`/`serviceSubnet`) / `provision.json`
`.calico.pod_cidr` must stay in sync.

### Local-first mesh endpoint (no public domain required)

The control server's `server_url` is resolved **local-first** at first boot by
`provision_headscale` (`resolve_endpoint`), so a node provisioned before any
public DNS exists is still reachable by its LAN peers. Precedence (highest
first): `provision.json .headscale.server_url` → `.mesh.endpoint` → the baked
brand `HEADSCALE_URL` (`/etc/hugmesh/headscale-url`, written at build time
because env does not survive to first boot) → **default** `http://<the pki
node's primary RFC1918 LAN IPv4>:8080`. The single `server_url:` line in
`/etc/headscale/config.yaml` is rewritten **in place** (idempotent) *before*
`headscale` starts; the baked `http://127.0.0.1:8080` is only an ultimate
fallback. The tailscale **client** mirrors this: an empty
`.tailscale.login_server` defaults to the same resolved endpoint. A public
facade (`scale.<domain>`) can be published later without re-imaging — the
MagicDNS control-plane name stays stable across the IP→domain transition, so
clients only re-pin if `login_server` itself changes. `--snat-subnet-routes=
false` and the fleet-scoped, default-deny ACL are unchanged; the endpoint stays
on the tailnet/LAN by default (no internet-wide grant).

### HA control plane + VPN→k8s autodiscovery

The Kubernetes control plane is **N-node HA** and uses a **stable MagicDNS
endpoint**, never a node IP, as `controlPlaneEndpoint`:

- **Stable name.** `provision.json .mesh.cp_dns_name` (default
  `kube-api.<base_domain>`, i.e. `kube-api.headnet.internal`) is set as
  `controlPlaneEndpoint` in `kubeadm-config.yaml` and as every join target.
  After the control node is on the tailnet, `publish_cp_dns_record` resolves its
  **tailnet IP** (`tailscale ip -4`, fallback `headscale nodes list`) and writes
  a `dns.extra_records` A-record (`cp_dns_name → tailnet IP`) into the headscale
  config, then reloads headscale — so any mesh node resolves the API over the
  tailnet with **no baked-in control-plane IP**. `provision_hosts` also writes
  `cp_dns_name → pki IP` to `/etc/hosts` for the first-boot window before
  MagicDNS converges.
- **First vs additional control-plane** is data-driven and idempotent. The
  **first** CP (`role=control-plane`, `bootstrap=true`, `first` defaults true)
  runs `kubeadm init --upload-certs` and persists fresh join material
  (`/etc/hugmesh/kubeadm-join.cmd` + `kubeadm-certificate-key`, mode 0600).
  An **additional** CP (`first=false`, full `.kubernetes.join` incl.
  `certificate_key`) runs `kubeadm join … --control-plane --certificate-key`.
  The robust default keys off a probe of `https://<cp_dns_name>:6443/healthz`:
  if the cluster already answers, the node joins as **additional** regardless of
  the flag (so a re-imaged or mis-flagged node never re-inits a second cluster).
  Every branch guards on `/etc/kubernetes/{admin,kubelet}.conf` for
  idempotency.
- **Workers** (`role=worker`) `kubeadm join` the same `cp_dns_name:6443`. The
  `certSANs` in `kubeadm-config.yaml` cover the MagicDNS name, the control-node
  hostname, and loopback so additional CPs/clients validate the API cert.
- **N-per-role is unconstrained on the mesh.** `tag:hugmesh` (+ per-role
  tags) are all owned by the single `hugmesh` headscale user and the preauth
  key is `reusable`, so `tagOwners` gates *which* tags a node may claim, not
  *how many* nodes — N nodes per role join and mesh with no policy change.

## Status / validation

- LSM switch, container SELinux, truststore-from-USB, and keystore generation are
  implemented; keystore generation is **test-verified** (23/23). The SELinux
  cross-built Pi image needs a hardware/boot relabel pass to confirm.
- The per-app `seLinuxOptions`/`ServiceAccount`/Casdoor-user wiring and the Vault
  PKI→ESO→pod keystore sync are being rolled across the charts/manifests
  (matrix above is the target); Calico-via-Vault is GitOps-staged.
