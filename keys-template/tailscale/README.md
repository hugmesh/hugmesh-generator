# Tailscale auth key

Place a tailscale auth/preauth key in a file named `authkey` here if you
want the node to join the headscale mesh automatically at first boot (set
`tailscale.enabled=true` and `tailscale.login_server` in `provision.json`).

On the PKI node the key is generated after headscale starts:

```bash
headscale users create hugmesh
headscale preauthkeys create --user hugmesh --reusable --expiration 24h
```

The PKI node's first-boot provisioning writes generated preauth keys to
`/var/lib/headscale/preauthkeys/<user>.key` — copy that onto the backend /
frontend KEYS sticks as `tailscale/authkey`.

## Fleet full-mesh `up_args`

The mesh is a flat L3 fabric: every node reaches every node, and pods/ClusterIP
services on one node are reachable from any node "as one LAN". That is driven
entirely by `provision.json` `tailscale.up_args` (appended verbatim to
`tailscale up`). Each node sets:

```text
--advertise-tags=tag:hugmesh,tag:<role> \
--advertise-routes=10.244.0.0/16,10.96.0.0/12 \
--accept-routes \
--snat-subnet-routes=false
```

- `--advertise-tags=tag:hugmesh,tag:<role>` — fleet membership tag plus the
  node's role tag (`tag:pki` / `tag:be` / `tag:fe` / `tag:host`). Allowed by
  `headscale/policy.hujson` `tagOwners` (owner `hugmesh`).
- `--advertise-routes=10.244.0.0/16,10.96.0.0/12` — the cluster pod + service
  CIDRs (keep in sync with `kubernetes/kubeadm-config.yaml`). Auto-approved by
  the policy's `autoApprovers.routes`.
- `--accept-routes` — install peers' approved subnet routes locally.
- `--snat-subnet-routes=false` — preserve real pod/service source IPs across the
  mesh.

The pki node's policy (`policy.hujson`) is what makes `tag:hugmesh ↔
tag:hugmesh` and the two CIDRs reachable; without a loaded policy headscale
falls back to allow-all with no tags or route approval.
