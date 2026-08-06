# Egress VPN (split-tunnel, fail-closed) — generator-side

Admins + superadmins import provider-downloaded VPN configs (ProtonVPN WireGuard
`.conf` **first-class**; OpenVPN `.ovpn` fallback) that mesh **nodes** use for
**OUTGOING / egress** traffic on PUBLIC-facing flows — coturn UDP audio/video,
made-public services, and (only on explicit assignment) akkoma/matrix federation.
The tailnet control plane + cluster-internal traffic stay **DIRECT** (split-tunnel).

This document is the **generator** (node-image) half: the key-USB delivery, the
node-level OpenRC service + split-tunnel runner, and the optional-services gate.
The control plane (Liquibase + `/bff/admin/egress-vpn` CRUD/assign), the
superadmin UI, and the signed-export reconcile bridge live in their own repos /
PRs.

## Node-level, not a per-pod sidecar

A NEW OpenRC service `/etc/init.d/hugmesh-egress-vpn` (Gentoo OpenRC; nodes are
**-systemd**) brings up ONE `wg-quick` (or `openvpn`) interface per node that
carries the node's public egress. Carrying the policy once per node — rather than
a sidecar per pod — keeps the kill-switch + `ip rule` priorities in one place and
lets the reconcile agent flip a single interface. TCP federation + UDP coturn ride
the one interface, selected by `fwmark`.

## Split-tunnel = `ip rule` PRIORITY + `Table=off`

`/usr/sbin/hugmesh-vpn-runner` owns ALL routing (wg-quick is forced
`Table = off`; OpenVPN runs `--route-noexec`). The VPN table (`176`) holds a
SINGLE forward route, `default dev wg0`:

| prio | rule | table | effect |
|---|---|---|---|
| 10 | `iif tailscale0` | main | tailnet ingress replies stay DIRECT |
| 20 | `from 100.64.0.0/10` | main | tailnet/CGNAT source stays DIRECT |
| 30 | `to 10.244.0.0/16` | main | pod CIDR (cluster-internal) DIRECT |
| 40 | `to 10.96.0.0/12` | main | service CIDR (cluster-internal) DIRECT |
| 100 | `fwmark 0x76` | **176** | ONLY marked public traffic → VPN |

The DIRECT rules (prio 10–40, table `main`) ALWAYS beat the VPN catch-all (prio
100) regardless of `fwmark` — so tailnet + cluster traffic NEVER enters the VPN.
Only packets MARKED `0x76` (set by `hugmesh-vpn-mark`, below) match the prio-100
rule and egress via `wg0`.

## Packet marking — `hugmesh-vpn-mark`

`/usr/sbin/hugmesh-vpn-mark` is the leg that actually puts traffic ON the
tunnel. The reconcile agent records the verified export's service slugs in
`/var/lib/hugmesh/egress-vpn/marked-services`, then runs `hugmesh-vpn-mark
apply`, which — in the SAME pass, marks before labels —

1. resolves each slug to its RUNNING pod IPs over the node's own admin
   kubeconfig (`app.kubernetes.io/name: <slug>`, namespace `hugmesh-backend`;
   IPs outside the pod CIDR — hostNetwork/node IPs — are refused);
2. loads ONE atomic `nft -f` transaction owning `table inet hugmesh_vpn`
   (create-if-missing + flush + redefine ⇒ idempotent; never touches another
   table): a `prerouting`/mangle chain that `return`s early for pod/service/
   tailnet destinations and sets `meta mark set 0x76` on packets sourced from
   the resolved pod IPs;
3. labels those pods `snapdragon.systems/vpn-egress=true` so the
   `egress-vpn-interaction` NetworkPolicy loosens their direct egress — which
   the mark then routes into table 176.

FAIL-CLOSED: a malformed `marked-services` row / kubectl failure / rejected
ruleset aborts with ZERO mutation; a labelling failure rolls back to the fully
cleared state; `clear` unlabels FIRST and drops the table only when unlabelling
succeeded (a loosened pod is never left unmarked). The runner's `down` runs
`hugmesh-vpn-mark clear` BEFORE the routing teardown; the reconcile agent's
empty-export teardown refuses to accept the export (and retries next cycle) if
the clear fails. Pod-IP churn converges via the 60s reconcile cron.

## Kill-switch / FAIL-CLOSED

Table 176 also carries a `blackhole default metric 1000` guard. While `wg0` is up,
`default dev wg0` wins; if `wg0` DROPS, the route is withdrawn and marked traffic
hits the blackhole → `EPERM` (**fail closed**) instead of falling through to the
WAN default. A VPN outage therefore takes the PUBLIC egress offline rather than
LEAKING the node's real WAN IP. Tailnet/cluster traffic (higher-priority DIRECT
rules on `main`) is unaffected. The SAME `default dev wg0` + blackhole is installed
on the **IPv6** table 176 (DNS / v6 leak guard) so a v6-capable marked flow cannot
bypass the v4 kill-switch.

> **Residual risk (by design):** fail-closed means a VPN provider outage takes the
> assigned PUBLIC service offline (coturn relay / made-public egress) until the
> tunnel recovers or the assignment is removed. This is the intended trade-off
> over leaking the node WAN IP. Operators monitor via `hugmesh-vpn-runner
> status` / the reconcile agent's reported state.

## Secrets off-git

The `.conf`/`.ovpn` ride the key-USB under `KEYS/vpn/<domain>/` (+ the build-side
`keys-out/vpn/<domain>/`). `provision_vpn()` (in the keys-provision flow) reads
ONLY the node's OWN domain and installs them `0600` root-owned into
`/etc/hugmesh/vpn/`, pointing `active.conf` at the first config (WireGuard wins
over OpenVPN). The runtime UI path instead delivers a config as a K8s Secret via
ESO; Postgres holds only `secret_ref` + metadata. See `keys-template/vpn/README.md`.

## Runtime config-byte delivery — the secret-projector

`hugmesh-vpn-reconcile` reads the config BYTES from `${VPN_SECRET_DIR}/<secretRef>`
on the **node host** (default `/etc/hugmesh/vpn-secret`) — the signed export
carries only `secretRef` + metadata. `manifests/egress-vpn/` is the hop that puts
them there: a `secret-projector` DaemonSet that syncs the labelled config Secrets
onto that hostPath as `0600` root-owned files named after the Secret.

**The contract** (the admin-bff/ESO half must match):

| what | value | why |
|---|---|---|
| namespace | `hugmesh-egress-vpn` | the RBAC boundary — a node-privileged projector must not be able to read `hugmesh-backend`'s DB/OIDC Secrets |
| label | `snapdragon.systems/optional-service: egress-vpn` | selection is by LABEL, so the control plane keeps minting `egress-vpn-<domain>-<name>` with no generator change |
| data key | `config` | the raw `.conf`/`.ovpn` bytes; the extension comes from the export's `kind` |
| Secret name | == the export's `secretRef` | it becomes the filename the agent opens |

**SHIPS DARK, twice over.** `manifests/egress-vpn/kustomization.yaml` has
`resources: []` and is reachable only through the MANUAL-sync
`apps/13e-egress-vpn.yaml` (no `automated:` block) — the
`apps/08a-networkpolicy-egress.yaml` pattern. Even once synced, the DaemonSet's
`nodeSelector: snapdragon.systems/egress-vpn=true` matches no node until an
operator labels the ones holding an assignment. Both halves are pruned wholesale
with the slug by `gate_optional_services()`.

**FAIL-CLOSED.** A failed list prunes NOTHING (an API-server blip must not strip a
node of its VPN config), and a Secret with an empty/absent `config` key is skipped
rather than truncating a good file. RBAC is a namespaced `Role` with `get`+`list`
on `secrets` only — never a `ClusterRole`, no write verb anywhere. SELinux: the
pod requests `spc_t` (writing under `/etc` on an enforcing node, like the NVIDIA
device plugin) and `/etc/hugmesh/vpn-secret` is labelled `hugmesh_vpn_etc_t` by
`specs/selinux/hugmesh_vpn.fc`, so the reconcile agent reads it under its
EXISTING pattern — the delivery leg adds no host domain.

## Default-off optional service

The egress VPN is a **default-off** optional service. The OpenRC service + runner
are baked into every node image but are INERT: the service is NOT linked into a
runlevel by the builders, and with no `active.conf` the runner is a no-op (public
egress falls back to the existing Squid egress-proxy / direct). It is enabled by
the optional-services gate (when selected) or flipped on per-assignment by the
signed reconcile agent. The gate prunes `net-vpn/wireguard-tools` +
`net-vpn/openvpn` from images that do not select it.

v1 keeps akkoma/tuwunel HTTP federation on the existing Squid egress-proxy; the
VPN is primarily for coturn UDP + made-public egress, and akkoma/tuwunel egress is
loosened onto the VPN only on an explicit assignment.

## Type-sniff

`active.conf` is type-sniffed at start: an `[Interface]`/`[Peer]` config →
`wg-quick`; a `remote …` / `client` / `dev tun` config → `openvpn`. WireGuard is
first-class.

## Tests

- `tests/egress-vpn/test-provision-vpn.sh` — `provision_vpn()` own-domain-only +
  0600 + cross-tenant DENY + fail-closed no-ops.
- `tests/egress-vpn/test-split-tunnel.sh` — the runner's `ip rule` priorities,
  fwmark catch-all, the v4+v6 `default dev wg0` + blackhole kill-switch, `down`
  teardown, and type-sniff (rootless via a recording fake `ip`; an optional real
  netns smoke runs under root).
- `tests/egress-vpn/test-vpn-mark.sh` — the packet-marking leg: marked-services
  → expected `hugmesh_vpn` nft ruleset, marks-before-labels ordering, idempotent
  re-runs, out-of-CIDR refusal, fail-closed aborts/rollbacks, full teardown, and
  the runner/reconcile/builder wiring (rootless via recording fake `nft` +
  `kubectl`).
- `tests/egress-vpn/test-vpn-secret-projector.sh` — the delivery leg: the REAL
  projector loop (extracted from the DaemonSet) against a recording fake
  `kubectl` — filename == secretRef, 0600, idempotence, prune-on-unassign, and
  the two fail-closed cases (failed list / empty key never destroy last-good).
- `tests/egress-vpn/test-x86-role-gate.sh` — `--egress-vpn` is desktop-only on
  every leg: the extracted PKGS block and kernel `ROLE_CLIENT` arm are eval'd for
  both extensions × both roles, so a node role can never emerge (or compile in)
  the VPN userspace the builder just told it it would ignore.

All of the above run in CI as the `egress-vpn-node-agents` verify job
(`.gitlab-ci.yml`); they need only bash + stubbed tools — never a cluster, never
real `nft`/`ip`.
