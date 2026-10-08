# SSH keys — operator access over Tailscale

`scripts/gen-provision-keys.sh` fills this folder with the operator's
SSH-over-Tailscale keypair:

- **`<admin>_ed25519`** — the operator **PRIVATE** key. It stays in `keys-out/`
  (it rides the key-USB, stays off the image, and `.gitignore` skips it via
  `*_ed25519`). Once the node is up, use it to SSH in **AS the privileged user over
  the tailnet**: `ssh -i ssh/<admin>_ed25519 <admin>@<tailnet-ip>`.
- **`<admin>.authorized_keys`** — the matching **PUBLIC** key, baked into the
  privileged user's `~/.ssh/authorized_keys` at first boot.

SSH reachability is **tailnet-only**. `tailscale up --ssh` exposes Tailscale SSH on
the tailnet, not on the public interface. The headscale SSH ACL
(`headscale/policy.hujson`) admits **only the privileged user**. Root and every
other account are denied an SSH session.

## Per-user authorized_keys

Drop more OpenSSH public keys here, one file per user, named
`<username>.authorized_keys` (for example `admin.authorized_keys` and
`root.authorized_keys`). On worker sticks `root.authorized_keys` is the
break-glass key (root login is otherwise locked).

Each file is merged into that user's `~/.ssh/authorized_keys` at first boot,
together with the `ssh_authorized_keys` array in `users.json` (and its
`ssh_authorized_keys_file`). The result is sorted with duplicates dropped. The
user must exist. `root.authorized_keys` goes to `/root/.ssh/authorized_keys`.

To pin the SSH **host** identity across reflashes, place pre-generated host keys
in `ssh/host/` (files named `ssh_host_*_key` and `ssh_host_*_key.pub`, such as
`ssh_host_ed25519_key` and `ssh_host_rsa_key`). They are installed into
`/etc/ssh/` (private 0600, public 0644), so clients do not see a changed host key
after a rebuild.

## In-UI SSH terminal — per-device HOST + BFF DIAL keypairs

When `GEN_DEVICE_SSH=true` (the default; pass `--no-device-ssh` to skip),
`gen-provision-keys.sh` makes the two keypairs the in-UI SSH terminal needs. With
them the BFF can dial this device over the tailnet and drive an operator console:

- **`ssh/host/ssh_host_ed25519_key{,.pub}`** — the **device sshd HOST keypair**.
  It is generated here (no passphrase) and **baked** into the image by the
  host-key path above (`provision_ssh_host_keys()` installs it to `/etc/ssh/`).
  It gives the device a **stable host identity**. The BFF **pins** `host_key_fp`,
  which closes trust-on-first-use. The private host key is the device's own
  identity, so baking it is legitimate.
- **`ssh/<dial_user>.authorized_keys`** — the **BFF DIAL PUBLIC key** (default
  dial user `bff-dial`; set it with `--dial-user`). It is baked into the dial
  user's `authorized_keys` through the per-user convention above, so the BFF can
  authenticate. **PUBLIC** key only, safe to bake and bundle.

The matching **DIAL PRIVATE key** is **NOT** written here. It goes to
`keys-out/vault-seed/device/<id>/ssh/dial_private_key`, a sibling of this
image-baked `ssh/` tree, not inside it. It is **VAULT ONLY**. `make-keys-usb.sh`
strips `vault-seed/`, so it never rides the KEYS stick. It is never baked into an
image and never logged. The per-device `ExternalSecret`
(`specs/cluster/manifests/external-secrets/device-ssh-externalsecret.tpl.yaml`)
mounts it into the BFF. Next to it, `vault-seed/device/<id>/ingest.json` holds the
**non-secret** ingest metadata (`host_key_fp`, `dial_pub_fp`, `dial_user`, and the
two public keys). The image-gen Job POSTs it back to the BFF to register and pin
the device.
