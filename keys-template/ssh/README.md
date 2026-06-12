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

Each file is concatenated into that user's `~/.ssh/authorized_keys` at
first boot. This is an alternative/supplement to the `ssh_authorized_keys`
arrays inside `users.json`.

To pin SSH **host** identity across reflashes, place pre-generated host
keys in `ssh/host/` (`ssh_host_ed25519_key`, `ssh_host_ed25519_key.pub`,
`ssh_host_rsa_key`, ...). They are installed into `/etc/ssh/` with correct
permissions, so clients don't see a changed host key after a rebuild.
