# SSH keys — operator access over Tailscale

`scripts/gen-provision-keys.sh` populates this folder with the operator's
SSH-over-Tailscale keypair:

- **`<admin>_ed25519`** — the operator **PRIVATE** key. It stays in `keys-out/`
  (rides the key-USB, off-image, `.gitignore`'d via `*_ed25519`). Use it to SSH
  into a node **AS the privileged user over the tailnet** once the node is up:
  `ssh -i ssh/<admin>_ed25519 <admin>@<tailnet-ip>`.
- **`<admin>.authorized_keys`** — the matching **PUBLIC** key, baked into the
  privileged user's `~/.ssh/authorized_keys` at first boot.

SSH reachability is **tailnet-only**: `tailscale up --ssh` exposes Tailscale SSH
on the tailnet (not the public interface), and the headscale SSH ACL
(`headscale/policy.hujson`) admits **only the privileged user** — root and every
other account are denied an SSH session.

## Per-user authorized_keys

Drop additional OpenSSH public keys here, one file per user named
`<username>.authorized_keys` (e.g. `admin.authorized_keys`,
`root.authorized_keys`). On worker sticks `root.authorized_keys` is the
break-glass key (root login is otherwise locked).

Each file is merged into that user's `~/.ssh/authorized_keys` at first boot,
together with the `ssh_authorized_keys` array in `users.json` (and its
`ssh_authorized_keys_file`); the result is sorted with duplicates dropped. The user
must exist. `root.authorized_keys` goes to `/root/.ssh/authorized_keys`.

To pin SSH **host** identity across reflashes, place pre-generated host
keys in `ssh/host/` (files named `ssh_host_*_key` and `ssh_host_*_key.pub`, such
as `ssh_host_ed25519_key` and `ssh_host_rsa_key`). They are installed into
`/etc/ssh/` (private 0600, public 0644), so clients don't see a changed host key after a rebuild.

## In-UI SSH terminal — per-device HOST + BFF DIAL keypairs

When `GEN_DEVICE_SSH=true` (the default; `--no-device-ssh` to skip),
`gen-provision-keys.sh` mints the two keypairs the in-UI SSH terminal needs so
the BFF can dial this device over the tailnet and drive an operator console:

- **`ssh/host/ssh_host_ed25519_key{,.pub}`** — the **device sshd HOST keypair**.
  Generated here (no passphrase) and **baked** into the image by the host-key
  path above (`provision_ssh_host_keys()` installs it to `/etc/ssh/`). It gives
  the device a **stable host identity**; the BFF **pins** `host_key_fp`, closing
  trust-on-first-use. The private host key is the device's own identity, so it is
  legitimately baked.
- **`ssh/<dial_user>.authorized_keys`** — the **BFF DIAL PUBLIC key** (default
  dial user `bff-dial`, set with `--dial-user`). Baked into the dial user's
  `authorized_keys` via the per-user convention above so the BFF can authenticate.
  **PUBLIC** key only — safe to bake/bundle.

The matching **DIAL PRIVATE key** is **NOT** written here. It is written to
`keys-out/vault-seed/device/<id>/ssh/dial_private_key` (a sibling of, NOT inside,
this image-baked `ssh/` tree) and is **VAULT ONLY** — `make-keys-usb.sh` strips
`vault-seed/` so it never rides the KEYS stick, it is never baked into an image,
and it is never logged. The per-device `ExternalSecret`
(`specs/cluster/manifests/external-secrets/device-ssh-externalsecret.tpl.yaml`)
mounts it into the BFF. Alongside it, `vault-seed/device/<id>/ingest.json` carries
the **non-secret** ingest metadata (`host_key_fp`, `dial_pub_fp`, `dial_user`, and
the two public keys) the image-gen Job POSTs back to the BFF to register + pin the
device.
