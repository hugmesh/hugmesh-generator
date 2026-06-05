# Snapdragon security model

Defense-in-depth: every application UI/API is a **distinct identity** at three
layers, and the container runtime + network are confined to those identities.

## 1. LSM — SELinux on every image

All images (RPi `pki`/`backend`/`frontend`, x86_64 `host`) build from the
`hardened/selinux` profile with SELinux as the LSM
(`CONFIG_LSM="yama,selinux,bpf"`, `lsm=...,selinux` on the kernel
cmdline). AppArmor is removed.

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
| `snapdragon-pki-gateway` | `sa-pki-gateway` | `s0:c11` | `svc-pki-gateway` / `ROLE_GATEWAY` | `snapdragon-pki-gateway.snapdragon-pki.svc` |
| `snapdragon-be-gateway` | `sa-be-gateway` | `s0:c12` | `svc-be-gateway` / `ROLE_GATEWAY` | `snapdragon-be-gateway.snapdragon-backend.svc` |
| `snapdragon-fe-gateway` | `sa-fe-gateway` | `s0:c13` | `svc-fe-gateway` / `ROLE_GATEWAY` | `snapdragon-fe-gateway.snapdragon-frontend.svc` |
| `snapdragon-auth` | `sa-auth` | `s0:c21` | `svc-auth` / `ROLE_AUTH` | `snapdragon-auth.snapdragon-pki.svc` |
| `snapdragon-api` (actions) | `sa-api` | `s0:c22` | `svc-api` / `ROLE_API` | `snapdragon-api.snapdragon-backend.svc` |
| `snapdragon-admin-bff` | `sa-admin-bff` | `s0:c23` | `svc-admin-bff` / `ROLE_ADMIN_API` | `snapdragon-admin-bff.snapdragon-backend.svc` |
| matrix / mastodon / casdoor / games | per-app SA | `s0:c3x` | per-app svc user | (non-Java: PEM, no JKS) |

The matrix is the contract: `seLinuxOptions.level` per Deployment (added to each
chart/manifest), a `ServiceAccount` per app, a Casdoor service user+role created
at bootstrap, and a JKS keystore issued by `gen-keystores.sh`.

## 4. mTLS between namespaces — Vault-managed JKS keystores

Each Java machine-user (the Spring Cloud gateways + Spring services) gets its own
**JKS keystore** (private key + CA-signed cert) — its mTLS identity for
cross-namespace calls.

- **Generated** by [`scripts/gen-keystores.sh`](../scripts/gen-keystores.sh) from
  one cluster CA (run by `gen-provision-keys.sh` on the pki node). Verified by
  [`tests/keystores/test-keystores.sh`](../tests/keystores/test-keystores.sh).
- **Vault-managed:** `gen-cluster-secrets.sh` pushes `keystores/*.jks` +
  `passwords.json` to Vault (KV); the External Secrets Operator syncs each into
  its namespace as a Secret; the pod mounts it and runs with
  `-Djavax.net.ssl.keyStore=/pki/<svc>.keystore.jks`.

## 5. Java truststore from the USB cert chain

`provision_truststore()` builds a PKCS12 truststore (and installs the JKS
truststore) from the **cluster CA / cert chain on the USB KEYS stick**, then
publishes `kube-system/snapdragon-truststore`. Java containers mount it and run
with `-Djavax.net.ssl.trustStore=/pki/truststore.p12
-Djavax.net.ssl.trustStoreType=PKCS12` (set via `JAVA_TOOL_OPTIONS` in the
charts), so all Java IO trusts the cluster CA.

## 6. Identity / login (recap)

Casdoor (`id.<domain>`) is the single OIDC IdP. Human login/registration is
Google/Discord-only and admin-allowlist-gated (two-stage). **Service users**
(the per-app identities above) are separate Casdoor accounts with service roles;
the gateways validate the Casdoor JWT and the `External-*` headers.

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

- **Membership tag.** Nodes self-apply `tag:snapdragon` (+ a per-role
  `tag:pki`/`tag:be`/`tag:fe`/`tag:host`) at join via
  `tailscale up --advertise-tags=...`. `tagOwners` restricts those tags to the
  `snapdragon` headscale user (the preauth-key owner), so only enrolled nodes
  can claim them. With OIDC join, the Casdoor `/headscale` group gates enrolment
  — two independent membership layers.
- **Full intra-fleet mesh.** The only `accept` rules are
  `tag:snapdragon → tag:snapdragon:*` (every node reaches every node, all ports)
  and `tag:snapdragon → {10.244.0.0/16, 10.96.0.0/12}:*` (pods + ClusterIP
  services). There is **no internet-wide `*` grant and no exit-node access** —
  the tailnet is fleet-scoped.
- **Pods/services as one LAN.** Each node advertises the cluster pod
  (`10.244.0.0/16`) and service (`10.96.0.0/12`) CIDRs
  (`--advertise-routes=...`) and accepts approved routes (`--accept-routes`).
  `autoApprovers.routes` maps exactly those two CIDRs to `tag:snapdragon`, so
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
brand `HEADSCALE_URL` (`/etc/snapdragon/headscale-url`, written at build time
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
  (`/etc/snapdragon/kubeadm-join.cmd` + `kubeadm-certificate-key`, mode 0600).
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
- **N-per-role is unconstrained on the mesh.** `tag:snapdragon` (+ per-role
  tags) are all owned by the single `snapdragon` headscale user and the preauth
  key is `reusable`, so `tagOwners` gates *which* tags a node may claim, not
  *how many* nodes — N nodes per role join and mesh with no policy change.

## Status / validation

- LSM switch, container SELinux, truststore-from-USB, and keystore generation are
  implemented; keystore generation is **test-verified** (23/23). The SELinux
  cross-built Pi image needs a hardware/boot relabel pass to confirm.
- The per-app `seLinuxOptions`/`ServiceAccount`/Casdoor-user wiring and the Vault
  PKI→ESO→pod keystore sync are being rolled across the charts/manifests
  (matrix above is the target); Calico-via-Vault is GitOps-staged.
