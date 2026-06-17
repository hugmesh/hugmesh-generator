# KEYS USB template

This directory is the template for the **FAT32 "KEYS" USB partition** that
the Gentoo RPi 5 image reads at first boot. Copy it onto a USB stick (label
the FAT32 partition `KEYS`), fill in your secrets, and insert it before the
first boot. The on-board `keys-provision` service finds it, mounts it
read-only, and applies everything described below — then writes a marker so
it won't run again unless you drop a `.provision-force` file on the stick.

The easiest way to produce a stick is:

```bash
sudo ./scripts/make-keys-usb.sh /dev/sdX ./keys-template
```

…after running `./scripts/gen-provision-keys.sh` to fill in password hashes
and SSH keys.

## Two KEYS USB types: pki (config) vs worker (keys only)

- **pki node USB** — the *config* stick: `users.json` (default accounts), the
  full `provision.json` (**all service config**: headscale, Vault/ESO, GitOps,
  kubernetes, storage, backups), the cluster CA/PKI, and the Vault token. The
  pki node is the single source of truth.
- **worker node USBs** (backend / frontend / host) — *keys only*: no
  `users.json` and no service config — just the cluster-join token + CA
  (`kubernetes.*`), the mesh authkey (`tailscale/authkey`), the cluster CA cert,
  and a break-glass `ssh/root.authorized_keys`. A worker joins the pki
  control-plane and gets **all** config + secrets from there (ArgoCD + Vault/ESO).
  See `examples/provision.{backend,frontend,host}.json`.
- **additional HA control-plane USBs** — a 2nd/3rd pki node that
  `kubeadm join --control-plane`s the existing cluster (instead of starting a
  second one). Carries the first CP's join token + CA hash + `certificate_key`
  (from `kubeadm init phase upload-certs`) + the shared `kubernetes/pki`. See
  `examples/provision.control-plane-additional.json`.

```bash
./scripts/gen-provision-keys.sh --role pki     -o keys-pki      # full + users
./scripts/gen-provision-keys.sh --role backend -o keys-backend  # keys only
./scripts/gen-provision-keys.sh --role control-plane-additional -o keys-pki-02  # HA CP
```

`scripts/build-all-roles.sh` does this per role automatically, dropping a
`keys-<role>` folder next to each ISO in the target directory.

## Layout

```
KEYS/                                 (FAT32, volume label "KEYS")
├── provision.json                    top-level manifest (see below)
├── users.json                        user + root account definitions
├── ssh/
│   ├── <user>.authorized_keys        per-user SSH public keys
│   └── host/ssh_host_*_key[.pub]     optional pinned host keys
├── headscale/
│   └── config.yaml                   optional headscale config override
├── tailscale/
│   └── authkey                       optional tailscale preauth key
├── kubernetes/
│   ├── kubeadm-config.yaml           optional kubeadm config override
│   └── pki/                          shared cluster CA / certs
├── vault/
│   ├── token                         Vault token / AppRole secret-id (online sync)
│   └── secrets.json                  offline copy of the materialized k8s Secrets
├── certs/                            certificates (trust store + files[])
├── vpn/
│   └── <domain>/                     OPTIONAL egress-VPN provider configs (per-domain)
│       ├── <name>.conf               ProtonVPN WireGuard config (FIRST-CLASS, SECRET)
│       └── <name>.ovpn               OpenVPN config (fallback, SECRET)
├── desktop-governance/               OPTIONAL desktop app-governance config (client desktops)
│   ├── flatpak/                      Discover -> BFF registry remote + Flathub-off list
│   ├── polkit/                       SSO-claim sudo gate (desktop-sudo)
│   ├── sssd/                         OIDC claim->group mapping (id.<domain> issuer)
│   └── discover/                     bearer-forward helper
└── secrets/
    ├── post-provision.sh             optional run[] hook
    ├── mail.json                     OPTIONAL SMTP creds (empty = mail disabled)
    └── cluster-creds.json            OPTIONAL mail + GitHub/Discord OAuth creds
```

> `vpn/<domain>/` is **OPTIONAL and absent by default** (the egress-VPN is a
> default-off optional service). It carries the provider-downloaded WireGuard
> (`.conf`, first-class) / OpenVPN (`.ovpn`, fallback) configs the mesh node uses
> for OUTGOING / egress traffic on public flows. `provision_vpn()` installs ONLY
> the node's OWN domain's configs (`.egress_vpn.domain` else
> `.snapdragon.cluster_domain`), mode `0600`, root-owned, into
> `/etc/snapdragon/vpn/`. A config under another tenant's `<domain>/` is never
> installed on this node (per-domain isolation). Stage them with
> `gen-provision-keys.sh --vpn-src DIR [--vpn-domain D]` (copies verbatim — these
> are **secrets**, never committed). See `keys-template/vpn/README.md`.

> `desktop-governance/` is **OPTIONAL and absent by default**. It carries the
> desktop app-governance config TEMPLATES for client desktops (laptop /
> chromebook / desktop). `provision_desktop_governance()` uses these only if the
> image did not bake them at `/etc/snapdragon/desktop-governance/`, then renders
> them (substituting the node's domain) into Discover/Flatpak, polkit, and SSSD.
> Default-deny / empty-store / ships-dark: no config ⇒ empty Discover store, no
> user has sudo. These files are **not secrets** (they carry hosts + the
> `desktop-sudo` claim name, never tokens). See
> `keys-template/desktop-governance/README.md`.

> `secrets/mail.json` + `secrets/cluster-creds.json` are **OPTIONAL and absent by
> default**. They carry outbound-mail (SMTP) and OAuth-provider client creds for
> `scripts/gen-cluster-secrets.sh` (which seeds Vault `secret/<brand>/mail` + the
> `casdoor-github`/`casdoor-discord`/`casdoor-smtp`/`akkoma-smtp` Secrets). Empty
> `user`/`password` ⇒ **no SMTP wired**: Casdoor + Akkoma keep native login +
> admin-approval registration. The brand `MAIL_PROVIDER` knob (`protonmail`
> default | `gmail` | `outlook` | `smtp` | `none`) selects the host/port/TLS
> preset. See `secrets/*.example.json` for the shape; `gen-provision-keys.sh`
> writes the real files (prompting with a 10s timeout, or copying from `--keys-src`).

## `provision.json`

| Key | Meaning |
|---|---|
| `hostname` | Sets `/etc/hostname` (overrides the build-time value). |
| `timezone` | Sets the system timezone. |
| `network.wifi.{ssid,psk,country}` | Synthesises a NetworkManager Wi-Fi profile. |
| `network` *(or `network/*.nmconnection`)* | Verbatim NM connection profiles are also copied. |
| `mesh.endpoint` | Mesh control-server URL override. **Empty = local-first**: defaults to the pki node's primary LAN IPv4 (`http://<lanip>:8080`), so the node works before any public DNS exists. |
| `mesh.magic_dns_domain` | headscale `dns.base_domain` (default `headnet.internal`). |
| `mesh.cp_dns_name` | **Stable** MagicDNS control-plane name (default `kube-api.<magic_dns_domain>`) used as kubeadm `controlPlaneEndpoint` + every join target. |
| `headscale.enabled` | Start the headscale control server (PKI node). |
| `headscale.config_file` | Path on KEYS to a config that replaces the default. |
| `headscale.server_url` | Highest-precedence endpoint override (else `mesh.endpoint`, else baked `HEADSCALE_URL`, else LAN IP). Rewrites `server_url:` in place before headscale starts. |
| `headscale.users[]` | headscale users to create once it is up. |
| `headscale.preauthkeys[]` | `{user,reusable,ephemeral}` preauth keys to mint. `reusable:true` lets **N nodes per role** share one key. |
| `tailscale.enabled` | Bring up the tailscale client. |
| `tailscale.{authkey_file,login_server,up_args}` | How to `tailscale up`. Empty `login_server` defaults to the same local-first endpoint. |
| `kubernetes.role` | `control-plane` \| `worker` \| `none`. |
| `kubernetes.bootstrap` | If `true`, actually run `kubeadm init`/`join`. If `false` (default) only stage config — run kubeadm by hand. |
| `kubernetes.first` | First (`true`) vs additional (`false`) **HA control-plane**. First → `kubeadm init --upload-certs`; additional → `kubeadm join --control-plane`. A live-endpoint probe overrides this so a node never re-inits an existing cluster. |
| `kubernetes.config_file` | kubeadm config override on KEYS (`controlPlaneEndpoint` = the stable `mesh.cp_dns_name`). |
| `kubernetes.pki_dir` | Directory on KEYS copied to `/etc/kubernetes/pki` (shared CA across control-plane nodes). |
| `kubernetes.join.{api_server,token,ca_cert_hash}` | Worker join parameters. Empty `api_server` auto-targets `mesh.cp_dns_name:6443`. |
| `kubernetes.join.certificate_key` | **Additional control-plane only**: the `--certificate-key` from the first CP's `kubeadm init phase upload-certs` (also persisted at `/etc/snapdragon/kubeadm-certificate-key`). |
| `snapdragon.role` | `pki` \| `backend` \| `frontend` — selects the cluster app set / namespace this node serves. |
| `snapdragon.cluster_domain` | Base domain for gateways/ingress/Casdoor. |
| `snapdragon.gitops.{enabled,argocd}` | On the PKI node, bootstrap ArgoCD + the app-of-apps. |
| `egress_vpn.domain` | OPTIONAL override for the node's own brand domain used to pick `KEYS/vpn/<domain>/` (defaults to `snapdragon.cluster_domain`). `provision_vpn()` installs ONLY this domain's configs, 0600. |
| `vault.*` | Seed HashiCorp Vault / External Secrets Operator state; Vault is primary, USB is the offline fallback (see below). |
| `storage.devices[]` | Set up attached M.2/NVMe or USB storage (see below). |
| `backup.*` | Schedule etcd + PostgreSQL backups to attached storage / network share. |
| `files[]` | `{src,dest,mode,owner}` — install arbitrary files from KEYS to absolute paths. |
| `run[]` | Scripts on KEYS to execute (as root) at the end of provisioning. |

### Attached storage (`storage.devices[]`)

Each entry mounts an attached disk and (optionally) relocates service data onto
it — handy for putting container/image layers on fast NVMe instead of the SD card.

| Field | Meaning |
|---|---|
| `match` | `nvme` \| `usb` \| `/dev/...` \| `LABEL=x` \| `UUID=x`. (`usb` skips the KEYS stick.) |
| `filesystem` | Filesystem (`ext4`, `xfs`, …). |
| `format` | **Destructive.** If `true`, GPT-partition + `mkfs` the device. Default `false`. |
| `label` | Filesystem label to apply when formatting. |
| `mountpoint` | Where to mount; added to `/etc/fstab` by UUID. |
| `options` | Mount options. |
| `use_for[]` | Relocate data dirs onto it: `containerd` (`/var/lib/containerd`), `kubelet`, `rancher`. |

### Backups (`backup.*`)

Backs up Kubernetes `etcd` (control-plane) and PostgreSQL (via `kubectl exec`
into the DB pods) on a cron schedule, to **any combination** of: attached
storage (`local`), an NFS share, and/or a CIFS/SMB share. The config is written
to `/etc/snapdragon/backup.json` (a plain file you can also edit on the device),
and the run script is `/usr/local/sbin/snapdragon-backup`.

| Field | Meaning |
|---|---|
| `enabled` | Master switch. |
| `schedule` | Cron expression (default `0 3 * * *`). |
| `retention_days` | Prune artifacts older than N days (0 = keep all). |
| `targets[]` | Any of `local`, `nfs`, `cifs` — each gets a copy. |
| `local.path` | Directory on attached storage (e.g. `/mnt/data/backups`). |
| `nfs.{server,export,mountpoint,options}` | NFS share, mounted via `/etc/fstab`. |
| `cifs.{unc,mountpoint,credentials_file}` | SMB/CIFS share; `credentials_file` is a path on KEYS. |
| `etcd` | If `true`, snapshot etcd (control-plane only). |
| `postgres[]` | `{namespace,selector,database,user}` per database to dump. |

### Secrets / Vault (`vault.*`)

Application secrets live in **HashiCorp Vault** (KV v2, mount `secret`, under the
brand base path — default `snapdragon/`). Vault is the **source of truth**; the
USB stick carries an **offline copy** so a fresh device can come up with no
reachable Vault. Integration is via the **External Secrets Operator (ESO)**: a
`ClusterSecretStore` named `snapdragon-vault` plus one `ExternalSecret` per
workload Secret (deployed by ArgoCD). The workloads keep their existing
`secretKeyRef` usage unchanged — ESO just materializes the Secrets below.

Runs after Kubernetes is up (requires `/etc/kubernetes/admin.conf`). Every step
is guarded and logged; a failure never aborts the rest of provisioning.

| Field | Meaning |
|---|---|
| `enabled` | Master switch. If not `true`, Vault/ESO seeding is skipped. |
| `address` | Vault URL (e.g. `https://vault.snapdragon.systems`). Empty ⇒ offline-only. |
| `kv_mount` | KV v2 mount used by the `ClusterSecretStore` (default `secret`). |
| `base_path` | Base segment under the mount; equals the brand slug (default `snapdragon`). |
| `token_file` | Path on KEYS to a Vault token / AppRole secret-id (default `vault/token`). |
| `install_eso` | Hint that ESO should be installed (ESO itself is deployed by ArgoCD). |

**Online (primary).** When `address` is set **and** `KEYS/vault/token` exists,
the token is loaded into a k8s Secret `vault-token` (key `token`) in the
`external-secrets` namespace so the `snapdragon-vault` `ClusterSecretStore` can
authenticate to Vault. ESO then keeps the workload Secrets in sync
(`refreshInterval 1h`).

**Offline (USB fallback).** `KEYS/vault/secrets.json` is an offline copy of the
materialized k8s Secrets, shaped as:

```json
{
  "<namespace>": {
    "<secretName>": { "<k8sKey>": "<value>", ... }
  }
}
```

If this bundle is present it is **always** applied (and is the sole source when
`address` is empty): each `namespace → secretName → {key: value}` is created via
`kubectl create secret generic … --dry-run=client -o yaml | kubectl apply -f -`,
so the Secrets exist even with no reachable Vault — i.e. they are *also available
via the attached USB*. The bundle mirrors exactly what ESO would materialize:

| Namespace | Secret | Keys (from Vault) |
|---|---|---|
| `snapdragon-pki` | `casdoor-google` | `clientId` ← `casdoor.google_client_id`, `clientSecret` ← `casdoor.google_client_secret` |
| `snapdragon-pki` | `casdoor-github` | `clientId` ← `casdoor.github_client_id`, `clientSecret` ← `casdoor.github_client_secret` |
| `snapdragon-pki` | `casdoor-discord` | `clientId` ← `casdoor.discord_client_id`, `clientSecret` ← `casdoor.discord_client_secret` |
| `snapdragon-pki` | `casdoor-smtp` *(opt)* | `CASDOOR_SMTP_*` ← `mail.{host,port,user,password,from}` |
| `snapdragon-backend` | `clickhouse-auth` | `password` ← `clickhouse.password` |
| `snapdragon-backend` | `akkoma-smtp` *(opt)* | `AKKOMA_SMTP_*` ← `mail.{host,port,user,password,tls,from}` |
| `observability` | `clickhouse-auth` | `password` ← `clickhouse.password` |
| `observability` | `uptrace-auth` | `pg-password` ← `uptrace.pg_password`, `project-token` ← `uptrace.project_token` |

The `casdoor-smtp` / `akkoma-smtp` rows are **optional**: the bundle only carries
them when real `mail.user` + `mail.password` resolve (otherwise no SMTP is wired).
`casdoor-github` / `casdoor-discord` are seeded with placeholders until real OAuth
client creds are supplied. The Vault paths backing these (KV v2, snake_case keys)
are `secret/snapdragon/casdoor`, `secret/snapdragon/clickhouse`,
`secret/snapdragon/uptrace`, and `secret/snapdragon/mail`.

## `users.json`

Each entry under `users[]`:

| Field | Meaning |
|---|---|
| `name` | Login name (required). |
| `comment`, `shell`, `uid`, `groups[]` | Standard account attributes. |
| `password_hash` | SHA-512 crypt hash (`openssl passwd -6` / `mkpasswd -m sha512crypt`). Preferred. |
| `password` | Plaintext fallback (hashed by the system on apply — avoid committing). |
| `sudo` | Add a sudoers entry. |
| `sudo_nopasswd` | Make that entry `NOPASSWD`. |
| `ssh_authorized_keys[]` | Public keys → `~/.ssh/authorized_keys`. |
| `ssh_authorized_keys_file` | Path on KEYS to an authorized_keys file. |

`root` is an object with `password_hash` and `ssh_authorized_keys[]`.

> **SSH is key-only.** A user with no key (and no console access) cannot log
> in, so always provide at least one `ssh_authorized_keys` entry or a host
> you can reach on the console.

## Security notes

- The stick is mounted `ro,nosuid,nodev,noexec`; provisioning never executes
  anything off it in place (run[] hooks are copied out first).
- Prefer `password_hash` over `password`. Generate hashes with
  `./scripts/gen-provision-keys.sh`.
- Keep the KEYS stick offline / in a safe once provisioning is done — it
  holds the cluster CA and preauth keys. Re-encrypt or wipe before reuse.
