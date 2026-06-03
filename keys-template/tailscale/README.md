# Tailscale auth key

Place a tailscale auth/preauth key in a file named `authkey` here if you
want the node to join the headscale mesh automatically at first boot (set
`tailscale.enabled=true` and `tailscale.login_server` in `provision.json`).

On the PKI node the key is generated after headscale starts:

```bash
headscale users create snapdragon
headscale preauthkeys create --user snapdragon --reusable --expiration 24h
```

The PKI node's first-boot provisioning writes generated preauth keys to
`/var/lib/headscale/preauthkeys/<user>.key` — copy that onto the backend /
frontend KEYS sticks as `tailscale/authkey`.
