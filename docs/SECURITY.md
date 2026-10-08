# HugMesh security model

Defense in depth: every application UI/API is meant to be a **distinct identity** at
three layers (SELinux, Casdoor, Kubernetes). The container runtime and the network
are confined to those identities. §3 says which parts are enforced and which are
still the target.

## 1. LSM — SELinux on every image

All ten stage4 images (the three RPi 5 role images `pki`/`backend`/`frontend`,
the x86_64 `host`, Frite, Jetson and the Orange Pi family) build from the
`hardened/selinux` profile (`specs-*/portage/profile/parent`) with SELinux as the
LSM. The kernel `CONFIG_LSM` is `lockdown,yama,selinux,bpf` on x86 and RPi 5
(`specs-x86/kernel/hardened-k8s.config`, `specs-rpi5/kernel/hardened-k8s.config`;
the x86 cmdline carries `lsm=lockdown,yama,selinux,bpf`) and `yama,selinux` on the
Frite, Jetson and Orange Pi kernels. AppArmor is disabled
(`disable CONFIG_SECURITY_APPARMOR` in the x86 and RPi 5 fragments).

- **Pi (cross-built):** SELinux policy packages' `pkg_postinst` runs the *target*
  `semodule`, which can't execute under aarch64 cross-emerge — so `keys-provision`
  loads the base policy + relabels the filesystem **natively at first boot**
  (`provision_selinux()`), starting **permissive**.
- **x86 (native):** the base policy is already built in the image. The hugmesh
  node-policy modules (§3) are still loaded at first boot by `provision_selinux()`.
- Mode/type are set from the KEYS manifest: `selinux.mode` (default `permissive`),
  `selinux.type` (default `mcs`). Every image boots **permissive**. The
  `selinux-enforce-gate` service that could flip a node to enforcing ships inert
  unless the image was built with `HUGMESH_SELINUX_ENFORCE_GATE=1`
  ([`docs/selinux-module-loading.md`](selinux-module-loading.md)).

## 2. Containers locked to SELinux roles

`containerd` runs with `enable_selinux = true` and `selinux_category_range = 1024`
(`specs/etc/containerd/config.toml`). Every pod is labelled `container_t` with a
unique MCS category pair, so pods are mutually isolated by SELinux. Kubernetes
refines this per workload through `securityContext.seLinuxOptions`, which gives
**each application its own role/level**.

## 3. The per-application identity matrix

Each app UI/API is meant to be one identity across SELinux, Casdoor and Kubernetes,
with a Vault-issued mTLS certificate. The SELinux level and ServiceAccount columns
are enforced: `tests/scripts/test-cluster-manifest-integrity.sh`
([mcs-documented], [workload-sa]) compares them with the manifests. The other two
columns are the design target; see the status note under the table.

| Application | k8s ServiceAccount | SELinux `seLinuxOptions` (level) | Casdoor user / role (target) | mTLS cert name (`.cluster.local` is appended) |
|---|---|---|---|---|
| `hugmesh-pki-gateway` | `sa-pki-gateway` | `s0:c11` | `svc-pki-gateway` / `ROLE_GATEWAY` | `hugmesh-pki-gateway.hugmesh-pki.svc` |
| `hugmesh-be-gateway` | `sa-be-gateway` | `s0:c12` | `svc-be-gateway` / `ROLE_GATEWAY` | `hugmesh-be-gateway.hugmesh-backend.svc` |
| `hugmesh-fe-gateway` | `sa-fe-gateway` | `s0:c13` | `svc-fe-gateway` / `ROLE_GATEWAY` | `hugmesh-fe-gateway.hugmesh-frontend.svc` |
| `hugmesh-gateway-superadmin` | `sa-gateway-superadmin` | `s0:c17` | `svc-gateway-superadmin` / `ROLE_GATEWAY` | `hugmesh-superadmin-gateway.hugmesh-pki.svc` |
| `hugmesh-api` (actions) | `sa-api` | `s0:c22` | `svc-api` / `ROLE_API` | `hugmesh-api.hugmesh-backend.svc` |
| `admin-bff` (api) | `sa-admin-bff` | `s0:c23` | `svc-admin-bff` / `ROLE_ADMIN_API` | `hugmesh-admin-bff-api.hugmesh-backend.svc` |
| `admin-bff-db` | `sa-admin-bff-db` | `s0:c26` | (DB) | (non-Java: PEM, no JKS) |
| `federation-api` | `sa-federation` | `s0:c24` | `svc-federation` / `ROLE_FEDERATION` | `hugmesh-federation-api.hugmesh-backend.svc` |
| `federation-db` | `sa-federation-db` | `s0:c25` | (DB) | (non-Java: PEM, no JKS) |
| `mod-bff-api` | `sa-mod-bff` | `s0:c27` | `svc-mod-bff` / `ROLE_MOD_API` | `hugmesh-mod-bff-api.hugmesh-backend.svc` |
| `mod-bff-db` | `sa-mod-bff-db` | `s0:c28` | (DB) | (non-Java: PEM, no JKS) |
| `user-bff-api` | `sa-user-bff` | `s0:c29` | `svc-user-bff` / `ROLE_USER_API` | `hugmesh-user-bff-api.hugmesh-backend.svc` |
| `user-bff-db` | `sa-user-bff-db` | `s0:c38` | (DB) | (non-Java: PEM, no JKS) |
| `forum-bff-api` | `sa-forum-bff` | `s0:c53` | `svc-forum-bff` / `ROLE_FORUM_API` | `hugmesh-forum-bff-api.hugmesh-backend.svc` |
| `forum-bff-db` | `sa-forum-bff-db` | `s0:c52` | (DB) | (non-Java: PEM, no JKS) |
| `wiki-bff-api` | `sa-wiki-bff` | `s0:c69` | `svc-wiki-bff` / `ROLE_WIKI_API` | `hugmesh-wiki-bff-api.hugmesh-backend.svc` |
| `wiki-bff-db` | `sa-wiki-bff-db` | `s0:c68` | (DB) | (non-Java: PEM, no JKS) |
| `service-catalog-ui` (superadmin Service Catalog console; tailnet-only) | `sa-service-catalog-ui` | `s0:c49` | `svc-service-catalog-ui` / `ROLE_SUPERADMIN_UI` | — (no `<app>-mtls` ExternalSecret) |
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

The matrix is the contract for `seLinuxOptions.level` per Deployment and a
`ServiceAccount` per app. Each MCS category (`s0:cNN`) is **unique** — no two
workloads may share one, so a compromised pod cannot read another's
category-isolated volumes.

**Status of the other two columns (checked 2026-10-07).**
- *Casdoor user / role.* `manifests/casdoor/init-data-configmap.yaml` seeds only
  `svc-pki-gateway`, `svc-be-gateway`, `svc-fe-gateway` (`ROLE_GATEWAY`),
  `svc-api` (`ROLE_API`), `svc-admin-bff` (`ROLE_ADMIN_API`) and `svc-signup-gate`
  (`ROLE_SERVICE`). The `casdoor-init` job also creates client-credentials
  machine apps for `user-bff` (`ROLE_API`), `matrix` / `mastodon` / `fragment-sync`
  (`ROLE_USER`), `harbor` and `headscale`. The users and roles shown for the other
  rows (`svc-gateway-superadmin`, `svc-federation`, `svc-mod-bff`, `svc-user-bff`,
  `svc-forum-bff`, `svc-wiki-bff`, `svc-service-catalog-ui`,
  `svc-character-forge-bff`, `ROLE_FEDERATION`, `ROLE_MOD_API`, `ROLE_USER_API`,
  `ROLE_FORUM_API`, `ROLE_WIKI_API`, `ROLE_SUPERADMIN_UI`,
  `ROLE_CHARACTER_FORGE_API`) appear nowhere in `specs/`, `scripts/` or `tests/`.
  They are the target, not the shipped state.
- *mTLS cert.* Pods do not mount JKS files. Vault `pki_int` issues a short-lived
  cert per app, External Secrets syncs it into a `<app>-mtls` TLS Secret
  (`tls.crt`, `tls.key`, `ca.crt`), and a `build-keystore` init container (in the
  gateway chart and in `manifests/admin-bff-api/deployment.yaml`) turns it into a
  PKCS12 keystore and truststore in a tmpfs `/stores` volume with a pod-local random
  password. The cert's CN is the name in the column with `.cluster.local` appended
  (`common_name` in `manifests/external-secrets/pki-externalsecrets.yaml`). The
  offline `gen-keystores.sh` fallback keystores cover only seven services:
  `<brand>-pki-gateway`, `-be-gateway`, `-fe-gateway`, `-api`, `-admin-bff-api`,
  `-mod-bff-api`, `-user-bff-api`. See §4.

> **service-catalog-ui note (reservation discharged 2026-08-26).** This row used to
> read "no Deployment yet" and mark `s0:c49` *(reserved)*. The console shipped only a
> federation descriptor
> (`manifests/federation-api/register-superadmin-service-catalog.descriptor.yaml`),
> a gateway route and route-access rows, with nothing to serve them. The Deployment
> and Service now exist (`manifests/superadmin-service-catalog-ui/`) and carry
> exactly the reserved identity: `serviceAccountName: sa-service-catalog-ui` and
> `securityContext.seLinuxOptions: { type: container_t, level: "s0:c49" }`.
>
> **What the reservation cost while it was only prose.** `edge-ai-analysis` took
> `s0:c49` as "next free". That was correct by the only evidence it had, because a
> reservation with no Deployment is invisible to a manifest scan and to the `[mcs]`
> uniqueness gate (which compares *workloads*). The clash surfaced when the
> Deployment was written, and `edge-ai-analysis` moved to `s0:c87`. The lasting fix
> is not the renumber. `edge-ai-analysis` had **no row in this matrix at all**, and
> an unlisted workload cannot be avoided. Anything that holds a category must appear
> above.

> **`cassandra` MCS note.** Category `s0:c63` is set through the bitnami cassandra
> 12.3.11 chart's **supported** `podSecurityContext.seLinuxOptions` **and**
> `containerSecurityContext.seLinuxOptions` values keys
> (`specs/cluster/apps/00-cassandra.yaml`). Only `seLinuxOptions.level` is set; all
> other securityContext chart defaults are untouched. This is a clean values override
> (no chart fork, no template patch), so it is **not** an exemption.
>
> **Cassandra auth (live) and TLS (dark, ADR-32).** The per-app least-privilege
> roles `admin_bff_cass`, `pki_gw_cass`, `be_gw_cass`, `fe_gw_cass`, `sa_gw_cass` and
> `federation_cass` are **Cassandra-internal login roles** (CQL `CREATE ROLE`,
> deny-by-default under `CassandraAuthorizer`). They are not separate pods or
> ServiceAccounts, so they take **no new MCS category**. The live `cassandra-bootstrap`
> Job creates them (`apps/00b-cassandra-init.yaml`, `manifests/cassandra-init/`). The
> dark TLS helper Job (`cassandra-tls-keystore-builder`,
> `manifests/cassandra-hardening/`) is also a Cassandra-tier admin client. Both Jobs
> run **under the same `s0:c63`**, set in their pod `seLinuxOptions.level`. They add
> no node service and need **no new `specs/selinux/*.te`/`.fc` module**. **No new
> listening port** is opened: auth and TLS reuse the CQL port `:9042`, which the
> `db-ingress-cassandra` NetworkPolicy already covers. The credentials come from
> ESO/Vault only (`secret/<brand>/cassandra-admin`, `…/cassandra-app-creds`) and are
> never in git. See `docs/CLUSTER-HARDENING-PLAN.md` §H.

> **`velero` cloud-backups MCS note.** The opt-in, inert cloud-backups leg
> (`specs/cluster/apps/55-velero.yaml`, `specs/cluster/manifests/velero/`) runs
> THREE distinct pods in the `velero` namespace, each with its own unique category:
> - the Velero **server** `s0:c64` and the **node-agent** DaemonSet `s0:c65`, set
>   through the upstream Velero 12.0.3 chart's **supported**
>   `podSecurityContext.seLinuxOptions` and `containerSecurityContext.seLinuxOptions`
>   values keys (and `nodeAgent.podSecurityContext` /
>   `nodeAgent.containerSecurityContext`). Only `seLinuxOptions.level` is set and
>   every other chart securityContext default is untouched: the same clean values
>   override as cassandra, with no fork;
> - the `backups-status-sweep` CronJob, which carries `s0:c66` on its pod
>   `securityContext` (`specs/cluster/manifests/velero/sweep-cronjob.yaml`).
>
> The admin-bff `cloudbackup` **effector** identity (k8s SA `backups-effector`,
> granted create/get/list/patch on `velero.io` Backup/Restore through
> `specs/cluster/manifests/velero/rbac.yaml`) runs INSIDE the `admin-bff` pod. It
> inherits `admin-bff`'s `s0:c23` and does **not** take a category of its own. The
> whole leg ships dark (apps 55/56 manual-sync, and the admin-bff default
> `app.backups.effector.enabled=false`). These categories are therefore reserved
> correct by construction and become live only on a deliberate superadmin opt-in.

> **`coturn` TURN-relay MCS note.** The OPTIONAL, DEFAULT-OFF coturn relay
> (`specs/cluster/manifests/coturn/`) carries category `s0:c67` on its pod
> `securityContext.seLinuxOptions.level` (`deployment.yaml`). It runs as the
> dedicated SA `sa-coturn` (`service-account.yaml`,
> `automountServiceAccountToken: false`, because coturn needs no Kubernetes API). It
> shares the `hugmesh-backend` namespace with tuwunel (`s0:c32`) so that both can use
> the ESO-synced TURN long-term-credential secret (`coturn-shared-secret`). The
> unique MCS category keeps the two pods category-isolated. coturn ships dark
> (RUNTIME-ONLY: no baked Application; gated by the apps/13a element and the
> `installed-services` ConfigMap entry `coturn:"false"`), so the category becomes live
> only on a deliberate per-domain opt-in. See [`docs/COTURN.md`](COTURN.md).

> **Node-service custom domains.** The host-service SELinux domains in
> [`specs/selinux/*.te`](../specs/selinux/) are part of this contract for **node**
> processes (not pods). The full set:
>
> | Module (`.te`/`.fc`) | Domain(s) | Confines | Binary / labelled path |
> |---|---|---|---|
> | `localpath_provisioner` | `localpath_provisioner_t`, `localpath_provisioner_helper_t` | local-path-provisioner controller + busybox helper (pod, runtime transition) | `/mnt/{data,usb}/local-path` |
> | `otel_collector` | `otel_collector_t` | otel-collector DaemonSet (pod, runtime transition) | (no host exec; `/var/log/pods`) |
> | `hugmesh_authkeys` | `hugmesh_authkeys_t` (+ `hugmesh_authkeys_cache_t`) | the AuthorizedKeysCommand (sshd_t domtrans, runs as nobody) — **security-load-bearing**. Its `.fc` also carries the two label-only entries below (no `.te` of their own) | `/usr/sbin/hugmesh-authorized-keys-lookup`; `/etc/hugmesh/registry` |
> | `hugmesh_device_registry_sync` | `hugmesh_device_registry_sync_t` | Layer-B registry sync daemon (writes the export cache + the sshd_config.d drop-in, reloads sshd) | `/usr/sbin/hugmesh-device-registry-sync` |
> | (in `hugmesh_authkeys.fc`) break-glass | (label only — `ssh_home_t`) | the loopback break-glass authorized_keys file so sshd reads it on enforcing | `/etc/ssh/break-glass.keys` |
> | `hugmesh_vpn` | `hugmesh_vpn_runner_t`, `hugmesh_vpn_reconcile_t` (+ `hugmesh_vpn_etc_t`, `hugmesh_vpn_runtime_t`) | egress-VPN runner (net_admin: wg/tun + ip-rule kill-switch) + the signed-export reconcile agent | `/usr/sbin/hugmesh-vpn-runner`, `/usr/sbin/hugmesh-vpn-reconcile`; `/etc/hugmesh/vpn` |
> | `hugmesh_node_storage` | `hugmesh_node_storage_t` (+ `hugmesh_node_storage_cache_t`) | node-storage reconcile agent (lsblk + FDE pool provision via provision.sh + kubectl nodePathMap patch) | `/usr/sbin/hugmesh-node-storage-reconcile`; `/var/lib/hugmesh/node-storage` |
> | `hugmesh_domain_reconcile` | `hugmesh_domain_reconcile_t` (+ `hugmesh_domain_reconcile_cache_t`) | domain-registry -> brand-repo bridge (#4): mTLS-fetch + verify the signed cross-domain export, then exec gen-keystores.sh + generate-brand-repos.sh to emit per-domain CA + brand GitOps repos into a node-local staging dir (NO block-device admin — emits files only) | `/usr/sbin/hugmesh-domain-reconcile`; `/var/lib/hugmesh/domain-registry` |
> | `hugmesh_policy_sync` | `hugmesh_policy_sync_t` | Layer-A headscale policy-sync agent (pki/control node only; renders + applies policy.hujson) | `/usr/sbin/gen-headscale-policy.sh` |
> | (in `hugmesh_authkeys.fc`) oidc token | (label only — `user_runtime_t`) | the per-user SSO OIDC-token deposit dir read by the desktop bearer-forward GEN-SSO artifact | `/run/user/[^/]+/hugmesh` |
> | `hugmesh_tor` | `hugmesh_tor_reconcile_t` (+ `hugmesh_tor_etc_t`, `hugmesh_tor_var_lib_t`) | the Tor onion-service reconcile agent (writes the managed `/etc/tor/torrc`, restarts the distro `tor`, exports the `.onion` hostname). The Tor daemon itself is confined by the upstream `tor_t` | `/usr/sbin/hugmesh-tor-reconcile`; `/etc/hugmesh/tor`; `/var/lib/hugmesh/tor` |
>
> There are nine `.te` modules. Each is a **node module** compiled by the
> **build-host policy compile** (the `.pp` is built on the x86 BUILD host, NOT
> first-boot — the Pi cannot run the refpolicy devel toolchain). The shared
> registry cache type `hugmesh_authkeys_cache_t` (declared in
> `hugmesh_authkeys.te`) is the on-disk handoff reused by the device-registry-sync,
> domain-reconcile, vpn-reconcile, node-storage, and policy-sync domains.
> `scripts/_selinux-policy-lib.sh`, called from all ten `build-*-stage4.sh`,
> compiles and installs the modules into every image, and `provision_selinux()`
> loads them at first boot. `localpath_provisioner`, `otel_collector` and
> `hugmesh_tor` are installed only where the upstream policy modules they need are
> present. The images still boot **permissive**; the modules' `# INFERRED-WIDE`
> rules have not been narrowed. See
> [`docs/selinux-module-loading.md`](selinux-module-loading.md).

## 4. mTLS between namespaces — Vault-issued certs, one cluster CA

Every Java machine user (the Spring Cloud gateways and the Spring services) has its
own mTLS identity for cross-namespace calls. There are two cert paths, both rooted
in one cluster CA (the header of [`scripts/gen-keystores.sh`](../scripts/gen-keystores.sh)
says the same):

- **In-cluster (preferred, what pods use).** Vault `pki_int` imports the cluster CA
  (provisioned to the `vault` namespace as the `cluster-ca` Secret from the pki
  USB) and issues a short-lived cert per app. External Secrets syncs each into a
  `<app>-mtls` TLS Secret (`tls.crt`, `tls.key`, `ca.crt`) in the app's namespace
  (`manifests/vault-pki`, `manifests/external-secrets/pki-externalsecrets.yaml`).
  A `build-keystore` init container (gateway chart
  `specs/cluster/charts/hugmesh-gateway/templates/deployment.yaml`; admin-bff in
  `manifests/admin-bff-api/deployment.yaml`) builds a PKCS12 keystore and
  truststore in a tmpfs `/stores` volume. It generates the store password in the
  init container, so the password is never in git, a Secret or Vault. The app
  loads it through a generated `application.properties`
  (`hugmesh.tls.key-store=/stores/keystore.p12`, `…trust-store=/stores/truststore.p12`).
  The gateway chart sets the TLS protocol floor to TLS 1.3
  (`server.ssl.enabled-protocols`, `keystore.tlsProtocols`; `docs/CRYPTO-AUDIT.md`
  row 6).
- **Offline / USB (the CA and fallback keystores).** `scripts/gen-keystores.sh`,
  run by `gen-provision-keys.sh` on the pki node, generates the cluster CA
  (`certs/cluster-ca.crt` is the trust anchor on every KEYS stick), per-service
  fallback keystores `keystores/<svc>.keystore.jks`, a truststore and
  `passwords.json`. Because the in-cluster certs chain to this same CA, the offline
  truststore validates them. No manifest under `specs/cluster` mounts the
  `.keystore.jks` files. Verified by
  [`tests/keystores/test-keystores.sh`](../tests/keystores/test-keystores.sh)
  (26/26 on 2026-10-07).
- **Multi-tenancy (per-domain CA loop):** by default the generator provisions a
  single domain — byte-/functionally-identical to the pre-multi-tenancy output. A
  build can list multiple brands/domains in
  [`brands/domains.conf`](../brands/domains.conf); the generator then loops,
  **generating an independent-root CA (default) or importing a provided one**
  (the same `--ca-cert`/`--ca-key` seam, now per-domain) for each, and writing
  that domain's keystores under `keystores/<brand>/`. Each domain gets a **NARROW
  truststore** (its own root only) so per-brand gateway/BFF/UI instances deny
  cross-domain mTLS at the trust anchor (defense in depth). The gateway chart
  selects the tier with `keystore.trustTier` (`NARROW` by default, `WIDE` for the
  architecture tier). One **WIDE multi-anchor truststore** (every domain's root) is
  built under `keystores/architecture/` for the **architecture tier ONLY** (Vault /
  federation / superadmin), which must validate cross-domain mTLS. With one
  domain the wide store holds exactly the one root (== the narrow store). The
  single-domain byte-identical invariant + the N≥2 narrow/wide tiers + the
  per-domain import path are proven by
  [`tests/keystores/test-keystores-multidomain.sh`](../tests/keystores/test-keystores-multidomain.sh)
  (30/30 on 2026-10-07; it diffs the refactored output against a frozen
  pre-refactor golden).
  **CA private keys never go in git** — only public certs/truststores; an
  imported `CA_KEY` path must point at the key-USB / a secret dir.

## 5. Java truststore from the USB cert chain

`provision_truststore()` builds a PKCS12 truststore (`truststore.p12`) from the
**cluster CA / cert chain on the USB KEYS stick**, copies any `keystores/*.jks`
from the stick next to it, and publishes `kube-system/hugmesh-truststore`. The
node-level truststore serves host-side Java processes: they must be started with
`-Djavax.net.ssl.trustStore=<that file> -Djavax.net.ssl.trustStoreType=PKCS12` (the
comment above `provision_truststore()` says so). No `specs/cluster` manifest sets
those `javax.net.ssl` properties, and `JAVA_TOOL_OPTIONS` is not used for this.
In-cluster Java pods get their trust anchor from the `build-keystore` init
container in §4.

## 6. Identity / login (recap)

Casdoor is the OIDC IdP.

- **Exposure.** The superdomain Casdoor ships with **no Ingress** and is reached from
  inside the cluster. A per-domain Casdoor (`idp: own`) carries its own Ingress at
  `id.<clusterDomain>` (`manifests/casdoor-domain/ingress.yaml`). No front-door route
  (fe-gateway, be-gateway) exposes Casdoor. The pki-gateway is not internet-facing
  (the internal ingress on the pki node serves it, LAN/VPN only). It does route
  `/api/auth/**`, `/login/**` and `/.well-known/**` to Casdoor, and it sends
  `/api/signup` and `/api/login` through the signup-gate first
  ([`docs/USERNAME-CONFUSABLE.md`](USERNAME-CONFUSABLE.md)).
- **Human login is a native, first-party form.** The browser's sign-in does not go to
  Casdoor. `login-ui` POSTs username and password (plus any MFA passcode) to user-bff
  `POST /bff/login`. user-bff runs PKCE, the internal Casdoor `/api/login` and the
  code exchange server-side, and returns only an opaque `bff_` session cookie. No
  JWT, `code_verifier`, `state` or Casdoor URL ever reaches the client.
- **Sign-up.** Federated sign-up (Google/Discord) and registration stay
  admin-allowlist-gated (two-stage).
- **Service users** (the per-app identities in §3) are separate Casdoor accounts with
  service roles. §3 says which are seeded. The gateways validate the Casdoor JWT and
  the `External-*` headers.

## 7. Network — Calico via Vault, configured from KEYS

Calico is the CNI (`specs/cluster/apps/01-calico.yaml`, Tigera operator). Its
tunable config (pod CIDR, encapsulation, BGP, NAT, block size) comes from the KEYS
`provision.json` `calico` block, which `provision_calico()` renders into the
Installation CR. The app header says its secrets (typha mTLS, BGP passwords) are
Vault-managed via External Secrets, but no ExternalSecret for them exists in
`manifests/external-secrets/` and BGP is disabled by default
(`calico.bgp.enabled: false`), so that part is not built. Default-deny ingress
NetworkPolicies per tier (`docs/CLUSTER-HARDENING-PLAN.md` §B) complement
the SELinux isolation. Egress default-deny ships dark.

### Fleet mesh — headscale/tailscale (fleet-scoped, default-deny)

Every node joins one tailnet via headscale (control server on the pki/omnibus
node). The mesh is governed by a **default-deny, tag-based ACL** loaded with
`policy.mode: file` (`specs/etc/headscale/config.yaml`) and `headscale policy set`
(run by `provision_headscale`).

- **Membership tag.** Nodes self-apply `tag:hugmesh` (+ a per-role
  `tag:pki`/`tag:be`/`tag:fe`/`tag:host`) at join through `tailscale up
  --advertise-tags=...`, which comes from `.tailscale.up_args` in `provision.json`
  (`keys-template/provision.json`, `keys-template/examples/`). `tagOwners` restricts
  those tags to the `hugmesh` headscale user (the preauth-key owner), so only
  enrolled nodes can claim them. With OIDC join, the Casdoor `hugmesh/headscale`
  group gates enrolment (`allowed_groups`, matching the group's real
  `<owner>/<name>` claim shape — see `keys-template/headscale/config.yaml`) — two
  independent membership layers.
- **Pod/service data plane only.** The one `accept` rule in `acls` is
  `tag:hugmesh → {10.244.0.0/16, 10.96.0.0/12}:*` (pods + ClusterIP services,
  all ports). The earlier any-to-any rule `tag:hugmesh → tag:hugmesh:*` was
  **dropped** ([FIX-DROPMESHRULE]) because it exposed every node's :22 to every
  other node. There is **no internet-wide `*` grant and no exit-node access** —
  the tailnet is fleet-scoped.
- **SSH is a separate, default-deny block.** `tailscale up --ssh` is on by default
  (`.tailscale.ssh`). The `ssh` section of the policy allows only the privileged
  user (`@@TS_SSH_USER@@`, rewritten by keys-provision; root and other accounts are
  denied). The image bakes `policy.bootstrap.hujson`, which first boot stages as
  `/etc/headscale/policy.hujson` unless the KEYS stick carries its own
  `headscale/policy.hujson` (that wins). On the control node, `gen-headscale-policy.sh`
  (Layer A of the device-license registry) re-renders it from
  `policy.hujson.tmpl` after the first signature-verified registry export, with
  one `ssh` edge per permitted operator and server-forced destination tags
  (`tag:dev_*`, `tag:dom_*`, `tag:mesh_*`, `tag:superadmin`, set by
  `hugmesh-headscale-forcetags`, which no node can self-advertise). See
  [`docs/DEVICE-REGISTRY-KEY-ROTATION.md`](DEVICE-REGISTRY-KEY-ROTATION.md).
  `specs/etc/headscale/policy.hujson` is a reference copy that the builders no
  longer bake; neither it nor `keys-template/headscale/policy.hujson` carries the
  any-to-any rule, though the header comments of both still describe the old
  full-mesh policy.
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

The CIDRs in the headscale policies, the `--advertise-routes` flags, and
`kubeadm-config.yaml` (`podSubnet`/`serviceSubnet`) / `provision.json`
`.calico.pod_cidr` must stay in sync.

### Local-first mesh endpoint (no public domain required)

`provision_headscale` resolves the control server's `server_url` **local-first** at
first boot (`resolve_endpoint`), so a node provisioned before any public DNS exists
is still reachable by its LAN peers. Precedence, highest first:

1. `provision.json .headscale.server_url`;
2. `.mesh.endpoint`;
3. the baked brand `HEADSCALE_URL` (`/etc/hugmesh/headscale-url`, written at build
   time because env does not survive to first boot);
4. **default** `http://<the pki node's primary RFC1918 LAN IPv4>:8080`.

The single `server_url:` line in `/etc/headscale/config.yaml` is rewritten **in
place** (idempotent) *before* `headscale` starts. The baked `http://127.0.0.1:8080`
is only an ultimate fallback.

The tailscale **client** mirrors this. An empty `.tailscale.login_server` defaults to
the same resolved endpoint on the control node. On a worker or additional control
plane it defaults to `resolve_control_endpoint`, which takes the override, then the
baked `HEADSCALE_URL`, then the pki node's LAN IP from `.nodes[]`. A worker never
points at its own LAN IP.

A public facade (`scale.<domain>`) can be published later without re-imaging. The
MagicDNS control-plane name stays stable across the IP→domain transition, so clients
re-pin only if `login_server` itself changes. `--snat-subnet-routes=false` and the
fleet-scoped, default-deny ACL are unchanged, and the endpoint stays on the
tailnet/LAN by default (no internet-wide grant).

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
- **N-per-role is not limited by the policy.** `tag:hugmesh` (+ per-role tags) are
  all owned by the single `hugmesh` headscale user, so `tagOwners` gates *which*
  tags a node may claim, not *how many* nodes. N nodes per role join and mesh with
  no policy change. The limit is the preauth key: the template
  (`keys-template/provision.json`, `.headscale.preauthkeys[]`) mints one key with
  `"reusable": false`. Mint one key per node, or set `reusable` to `true`.

## Status / validation

Checked against `origin/main` on 2026-10-07.

- **Implemented:** the LSM switch, container SELinux (`enable_selinux`, per-workload
  `seLinuxOptions.level` and `ServiceAccount`, both checked by
  `test-cluster-manifest-integrity.sh`), truststore-from-USB, offline keystore and CA
  generation (`test-keystores.sh` 26/26, `test-keystores-multidomain.sh` 30/30), the
  Vault PKI → ESO → `build-keystore` path for gateway and admin-bff pods, and the
  node-policy module build/install/load (§3).
- **Not enforcing:** every image boots SELinux **permissive**. The nine node modules
  are loaded, and the enforce-gate ships inert. Whether a cross-built Pi image
  relabels cleanly still needs a hardware boot check.
- **Not built as the matrix describes:** most Casdoor service users and roles in §3
  (see the status note under the matrix), and the Calico typha/BGP ExternalSecrets
  named in `apps/01-calico.yaml`.
