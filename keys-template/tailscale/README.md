# Tailscale auth key

To make a node join the headscale mesh automatically at first boot, put a
tailscale auth/preauth key in a file named `authkey` here. Also set
`tailscale.enabled=true` and `tailscale.login_server` in `provision.json`.

On the PKI node, make the key after headscale starts:

```bash
headscale users create hugmesh
headscale preauthkeys create --user hugmesh --reusable --expiration 24h
```

The PKI node's first-boot provisioning mints the keys listed in
`headscale.preauthkeys` of `provision.json` and writes them to
`/var/lib/headscale/preauthkeys/<user>.key`. Copy that file onto the backend and
frontend KEYS sticks as `tailscale/authkey`. These keys always expire after 24h.
They are single-use unless the entry sets `"reusable": true` (the template sets
`false`), so one minted key admits one node.

## Fleet full-mesh `up_args`

Pods and ClusterIP services on one node are meant to be reachable from any node
"as one LAN". `provision.json` `tailscale.up_args` (appended verbatim to
`tailscale up`) and the policy below make that happen. Each node sets:

```text
--advertise-tags=tag:hugmesh,tag:<role> \
--advertise-routes=10.244.0.0/16,10.96.0.0/12 \
--accept-routes \
--snat-subnet-routes=false \
--ssh
```

- `--advertise-tags=tag:hugmesh,tag:<role>` — the fleet membership tag plus the
  node's role tag (`tag:pki` / `tag:be` / `tag:fe` / `tag:host`).
  `headscale/policy.hujson` `tagOwners` allows them (owner `hugmesh`).
- `--advertise-routes=10.244.0.0/16,10.96.0.0/12` — the cluster pod and service
  CIDRs (keep them in sync with `kubernetes/kubeadm-config.yaml`). The policy's
  `autoApprovers.routes` approves them.
- `--accept-routes` — install the peers' approved subnet routes locally.
- `--snat-subnet-routes=false` — keep the real pod and service source IPs across
  the mesh.
- `--ssh` — Tailscale SSH (see the `ssh/` README).

The pki node's policy (`policy.hujson`) lets `tag:hugmesh` reach the two CIDRs on
all ports. It deliberately has no any-to-any rule between nodes. SSH rides its own
`ssh` block, and the control node's first verified Layer-A sync re-renders the
policy. Without a loaded policy, headscale falls back to allow-all with no tags
and no route approval.
