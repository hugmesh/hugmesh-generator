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
| `admin-bff` | `sa-admin-bff` | `s0:c23` | `svc-admin-bff` / `ROLE_ADMIN_API` | `admin-bff.snapdragon-backend.svc` |
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

## Status / validation

- LSM switch, container SELinux, truststore-from-USB, and keystore generation are
  implemented; keystore generation is **test-verified** (23/23). The SELinux
  cross-built Pi image needs a hardware/boot relabel pass to confirm.
- The per-app `seLinuxOptions`/`ServiceAccount`/Casdoor-user wiring and the Vault
  PKI→ESO→pod keystore sync are being rolled across the charts/manifests
  (matrix above is the target); Calico-via-Vault is GitOps-staged.
