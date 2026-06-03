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
├── certs/                            certificates (trust store + files[])
└── secrets/
    └── post-provision.sh             optional run[] hook
```

## `provision.json`

| Key | Meaning |
|---|---|
| `hostname` | Sets `/etc/hostname` (overrides the build-time value). |
| `timezone` | Sets the system timezone. |
| `network.wifi.{ssid,psk,country}` | Synthesises a NetworkManager Wi-Fi profile. |
| `network` *(or `network/*.nmconnection`)* | Verbatim NM connection profiles are also copied. |
| `headscale.enabled` | Start the headscale control server (PKI node). |
| `headscale.config_file` | Path on KEYS to a config that replaces the default. |
| `headscale.users[]` | headscale users to create once it is up. |
| `headscale.preauthkeys[]` | `{user,reusable,ephemeral}` preauth keys to mint. |
| `tailscale.enabled` | Bring up the tailscale client. |
| `tailscale.{authkey_file,login_server,up_args}` | How to `tailscale up`. |
| `kubernetes.role` | `control-plane` \| `worker` \| `none`. |
| `kubernetes.bootstrap` | If `true`, actually run `kubeadm init`/`join`. If `false` (default) only stage config — run kubeadm by hand. |
| `kubernetes.config_file` | kubeadm config override on KEYS. |
| `kubernetes.pki_dir` | Directory on KEYS copied to `/etc/kubernetes/pki`. |
| `kubernetes.join.{api_server,token,ca_cert_hash}` | Worker join parameters. |
| `snapdragon.role` | `pki` \| `backend` \| `frontend` — selects the cluster app set / namespace this node serves. |
| `snapdragon.cluster_domain` | Base domain for gateways/ingress/Casdoor. |
| `snapdragon.gitops.{enabled,argocd}` | On the PKI node, bootstrap ArgoCD + the app-of-apps. |
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
