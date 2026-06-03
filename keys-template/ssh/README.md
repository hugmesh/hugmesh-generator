# Per-user authorized_keys

Drop OpenSSH public keys here, one file per user named
`<username>.authorized_keys` (e.g. `admin.authorized_keys`,
`root.authorized_keys`).

Each file is concatenated into that user's `~/.ssh/authorized_keys` at
first boot. This is an alternative/supplement to the `ssh_authorized_keys`
arrays inside `users.json`.

To pin SSH **host** identity across reflashes, place pre-generated host
keys in `ssh/host/` (`ssh_host_ed25519_key`, `ssh_host_ed25519_key.pub`,
`ssh_host_rsa_key`, ...). They are installed into `/etc/ssh/` with correct
permissions, so clients don't see a changed host key after a rebuild.
