# Egress VPN (split-tunnel, fail-closed) — generator-side

Admins and superadmins import VPN configs downloaded from a provider (ProtonVPN
WireGuard `.conf` is **first-class**; OpenVPN `.ovpn` is the fallback). Mesh **nodes**
use them for **OUTGOING / egress** traffic on PUBLIC-facing flows: coturn UDP
audio/video, made-public services, and (only on explicit assignment) akkoma/matrix
federation. The tailnet control plane and cluster-internal traffic stay **DIRECT**
(split-tunnel).

This page is the **generator** (node-image) half: key-USB delivery, the node-level
OpenRC service and split-tunnel runner, and the optional-services gate. The control
plane (Liquibase and `/bff/admin/egress-vpn` CRUD/assign), the superadmin UI and the
signed-export reconcile bridge live in their own repos.

## Node-level, not a per-pod sidecar

The OpenRC service `/etc/init.d/hugmesh-egress-vpn` (Gentoo OpenRC; nodes are
**-systemd**) brings up ONE `wg-quick` (or `openvpn`) interface per node. That
interface carries the node's public egress. One policy per node, not a sidecar per
pod, keeps the kill-switch and `ip rule` priorities in one place and lets the
reconcile agent flip a single interface. TCP federation and UDP coturn share the
interface, selected by `fwmark`.

## Split-tunnel = `ip rule` PRIORITY + `Table=off`

`/usr/sbin/hugmesh-vpn-runner` owns ALL routing (wg-quick is forced to
`Table = off`; OpenVPN runs `--route-noexec`). The VPN table (`176`) holds ONE
forward route, `default dev wg0`:

| prio | rule | table | effect |
|---|---|---|---|
| 10 | `iif tailscale0` | main | tailnet ingress replies stay DIRECT |
| 20 | `from 100.64.0.0/10` | main | tailnet/CGNAT source stays DIRECT |
| 30 | `to 10.244.0.0/16` | main | pod CIDR (cluster-internal) DIRECT |
| 40 | `to 10.96.0.0/12` | main | service CIDR (cluster-internal) DIRECT |
| 100 | `fwmark 0x76` | **176** | ONLY marked public traffic → VPN |

The DIRECT rules (prio 10–40, table `main`) ALWAYS beat the VPN catch-all (prio
100), whatever the `fwmark`. Tailnet and cluster traffic NEVER enters the VPN. Only
packets MARKED `0x76` (set by `hugmesh-vpn-mark`, below) match the prio-100 rule and
leave through `wg0`.

## Packet marking — `hugmesh-vpn-mark`

`/usr/sbin/hugmesh-vpn-mark` is the leg that puts traffic ON the tunnel. The
reconcile agent writes the verified export's service slugs to
`/var/lib/hugmesh/egress-vpn/marked-services`, then runs `hugmesh-vpn-mark apply`.
In ONE pass, marks before labels, `apply`:

1. resolves each slug to its RUNNING pod IPs over the node's own admin
   kubeconfig (`app.kubernetes.io/name: <slug>`, namespace `hugmesh-backend`;
   IPs outside the pod CIDR — hostNetwork/node IPs — are refused);
2. loads ONE atomic `nft -f` transaction owning `table inet hugmesh_vpn`
   (create-if-missing + flush + redefine ⇒ idempotent; never touches another
   table): a `prerouting`/mangle chain that `return`s early for pod/service/
   tailnet destinations and sets `meta mark set 0x76` on packets sourced from
   the resolved pod IPs;
3. labels those pods `hugmesh.net/vpn-egress=true` so the
   `egress-vpn-interaction` NetworkPolicy loosens their direct egress — which
   the mark then routes into table 176.

FAIL-CLOSED: a malformed `marked-services` row, a kubectl failure or a rejected
ruleset aborts with ZERO mutation. A labelling failure rolls back to the fully
cleared state. `clear` unlabels FIRST and drops the table only if unlabelling
succeeded, so a loosened pod is never left unmarked. The runner's `down` runs
`hugmesh-vpn-mark clear` BEFORE the routing teardown. If the clear fails, the
reconcile agent's empty-export teardown refuses the export and retries next cycle.
Pod-IP churn converges through the 60s reconcile cron.

## Kill-switch / FAIL-CLOSED

Table 176 also carries a `blackhole default metric 1000` guard. While `wg0` is up,
`default dev wg0` wins. If `wg0` DROPS, the route is withdrawn and marked traffic hits
the blackhole and gets `EPERM` (**fail closed**), instead of falling through to the
WAN default. A VPN outage takes the PUBLIC egress offline. It does not LEAK the
node's real WAN IP. Tailnet and cluster traffic (higher-priority DIRECT rules on
`main`) is unaffected. The **IPv6** table 176 gets the SAME `default dev wg0` +
blackhole (DNS / v6 leak guard), so a v6 marked flow cannot bypass the v4
kill-switch.

> **Residual risk (by design):** fail-closed means a VPN provider outage takes the
> assigned PUBLIC service (coturn relay, made-public egress) offline until the tunnel
> recovers or the assignment is removed. That is the intended trade against leaking
> the node WAN IP. Monitor with `hugmesh-vpn-runner status` and the reconcile agent's
> reported state.

## Secrets off-git

The `.conf`/`.ovpn` files ride the key-USB under `KEYS/vpn/<domain>/` (and the
build-side `keys-out/vpn/<domain>/`). `provision_vpn()` (in the keys-provision flow)
reads ONLY the node's OWN domain. It installs the files `0600`, root-owned, in
`/etc/hugmesh/vpn/` and points `active.conf` at the first config (WireGuard wins over
OpenVPN). The runtime UI path delivers a config as a K8s Secret through ESO instead.
Postgres holds only `secret_ref` and metadata. See `keys-template/vpn/README.md`.

## Runtime config-byte delivery — the secret-projector

`hugmesh-vpn-reconcile` reads the config BYTES from `${VPN_SECRET_DIR}/<secretRef>`
on the **node host** (default `/etc/hugmesh/vpn-secret`). The signed export carries
only `secretRef` and metadata. `manifests/egress-vpn/` puts the bytes there: a
`secret-projector` DaemonSet syncs the labelled config Secrets onto that hostPath as
`0600` root-owned files named after the Secret.

**The contract** lives in ONE file, `specs/cluster/egress-vpn-secret-contract.env`,
because it spans two repositories that never build together. The generator's reader
half (this repo) and the admin-bff writer half both merged green while disagreeing on
two of the three values, so the delivery leg could not deliver a single byte:

| what | contract | the reader shipped | the writer shipped |
|---|---|---|---|
| namespace | `hugmesh-egress-vpn` | `hugmesh-egress-vpn` ✔ | `hugmesh-backend` ✘ |
| label | `hugmesh.net/optional-service=egress-vpn` | ✔ | ✔ |
| data key | the Secret's own `metadata.name` (`@name`) | `config` ✘ | ✔ |
| Secret name | == the export's `secretRef` | ✔ | ✔ |

Resolution, one value at a time:

- **namespace** — the generator's value wins, on the writer's own terms. It is the
  only one of the three that admin-bff exposes as a lever
  (`EGRESS_VPN_SECRET_NAMESPACE`), and this repo owns the Deployment that sets it. So
  `manifests/admin-bff-api/deployment.yaml` now points admin-bff at
  `hugmesh-egress-vpn`. The writer's default, `hugmesh-backend`, would have given a
  node-privileged, host-writing DaemonSet read access to every DB, OIDC and
  federation Secret in the app tier. RBAC has no label selector, so the namespace is
  the only boundary that can be expressed.
- **data key** — admin-bff's value wins. `.addToStringData(secretRef, …)` is
  hardcoded, has no lever, and is pinned by a merged test. Key == name is also
  deliberate: a plain Secret volume projection then already creates the
  `${VPN_SECRET_DIR}/<secretRef>` file. `@name` is the contract's sentinel for that
  derivation. It is safe because `@` is not a legal Secret data-key character
  ("Each key must consist of alphanumeric characters, '-', '_' or '.'", core/v1
  Secret API reference), so it never collides with a real key.
- **write RBAC** — `manifests/egress-vpn/writer-rbac.yaml` grants the admin-bff
  pod's `backups-effector` SA `get/create/patch/update` on Secrets in that namespace
  and nowhere else. It was missing, and nobody could see that: the writer turns every
  failure into `false`, so an RBAC denial looks the same as "delivery is off".

`tests/egress-vpn/test-secret-contract.sh` checks every copy of these values, in this
repo's manifests AND in the admin-bff source (read from a sibling checkout), against
that one file. It exits 3 (INCOMPLETE, failing the job) instead of half-checking when
the sibling is missing.

**"Every copy" is SEARCHED FOR, not listed.** The first version of that gate checked
the three copies its author knew about. A FOURTH sat in
`specs/cluster/optional-services.yaml` with `secretKey: config`, the broken value,
and nothing read it. So the gate now runs a **copy census**. It greps the tree for
every machine-read carrier of a contract value. Each must be *verified* (a comparison
in that run actually read a value from it) or *exempt with a written reason*. A copy
added later still fails the census. The one standing exemption is
`manifests/networkpolicy/egress-vpn-interaction.yaml`, where
`hugmesh.net/optional-service: egress-vpn` is the slug TAG every optional-service
object carries, not the Secret selector.

The registry's three fields are copies and say so: they sit under a `secretContract:`
pointer at the contract file. `secretKey` is `"@name"`, QUOTED, because `@` is a YAML
reserved indicator that cannot start a plain scalar. A bare `@name` is a parse error.

**SHIPS DARK, twice over.** `manifests/egress-vpn/kustomization.yaml` has
`resources: []` and is reachable only through the MANUAL-sync
`apps/13e-egress-vpn.yaml` (no `automated:` block), the same pattern as
`apps/08a-networkpolicy-egress.yaml`. Even once synced, the DaemonSet's
`nodeSelector: hugmesh.net/egress-vpn=true` matches no node until an operator labels
the nodes that hold an assignment. `gate_optional_services()` prunes both halves with
the slug.

That node-arming label is the contract's fifth value (`EGRESS_VPN_NODE_LABEL`). It
was written seven ways across the DaemonSet's `nodeSelector` and header prose, three
runbooks and the registry's `nodeDeliveryLabel`, and nothing asserted any of them.
Drift between the key the projector selects on and the key a runbook tells an
operator to apply does not raise an error. Upstream: "the DaemonSet controller will
create Pods on nodes which match that node selector". So an unsatisfiable
`nodeSelector` makes no Pods at all, not even Pending ones, and leaves no scheduling
event and no log line. It looks the same as a delivery leg that has not converged yet.
Unlike the three Secret values, this one is generator-internal. admin-bff has no side
of it.

**How it is asserted.** The expected value is read from the DaemonSet's
`nodeSelector` mapping, the key the kube-scheduler actually evaluates. Every other
carrier is graded against *that*. An earlier version counted tokens per file, so it
agreed with itself after a renamed prefix, after a swap to the **pod** opt-in label
(`hugmesh.net/vpn-egress`, the likeliest mistake), and after the instruction was
deleted. The current gate finds label-shaped tokens by the Kubernetes label *grammar*
and classifies each by the action the surrounding prose describes (`nodeSelector`, or
`label` near `node`), not by its spelling. Every node-arming token must equal the
scheduler's key. Each file must carry at least one. Every other label must be named
as a known non-node label, with a reason. A scan that finds nothing agrees with
everything, so finding nothing is red.

**FAIL-CLOSED.** A failed list prunes NOTHING (an API-server blip must not strip a
node of its VPN config). A Secret with an empty or missing contract data key is
skipped, not used to cut a good file short. The projector's RBAC is a namespaced
`Role` with `get`+`list` on `secrets` only: never a `ClusterRole`, and no write verb
anywhere (the write grant is a separate identity in a separate file). SELinux: the
pod requests `spc_t` (it writes under `/etc` on an enforcing node, like the NVIDIA
device plugin). `specs/selinux/hugmesh_vpn.fc` labels `/etc/hugmesh/vpn-secret` as
`hugmesh_vpn_etc_t`, so the reconcile agent reads it under its EXISTING pattern. The
delivery leg adds no host domain.

## Default-off optional service

The egress VPN is a **default-off** optional service. The OpenRC service and runner
are baked into every node image but are INERT. The builders do NOT link the service
into a runlevel, and with no `active.conf` the runner does nothing (public egress
falls back to the existing Squid egress-proxy, or goes direct). The optional-services
gate (when selected) or the signed reconcile agent (per assignment) turns it on. The
gate prunes `net-vpn/wireguard-tools` and `net-vpn/openvpn` from images that do not
select it.

v1 keeps akkoma/tuwunel HTTP federation on the existing Squid egress-proxy. The VPN
is mainly for coturn UDP and made-public egress. akkoma/tuwunel egress moves onto the
VPN only on an explicit assignment.

## Type-sniff

The runner type-sniffs `active.conf` at start. An `[Interface]`/`[Peer]` config goes
to `wg-quick`. A `remote …` / `client` / `dev tun` config goes to `openvpn`.
WireGuard is first-class.

## Tests

All of these run in CI as the `egress-vpn-node-agents` verify job (`.gitlab-ci.yml`,
which loops over `tests/egress-vpn/*.sh`). They need only bash and stubbed tools:
no cluster, no real `nft`/`ip`.

- `tests/egress-vpn/test-provision-vpn.sh` — `provision_vpn()` reads only its own
  domain, writes `0600`, denies cross-tenant reads, and fails closed.
- `tests/egress-vpn/test-split-tunnel.sh` — the runner's `ip rule` priorities, the
  fwmark catch-all, the v4+v6 `default dev wg0` + blackhole kill-switch, `down`
  teardown and type-sniff (rootless, with a recording fake `ip`; an optional real netns
  smoke test runs under root).
- `tests/egress-vpn/test-vpn-mark.sh` — the packet-marking leg: marked-services to the
  expected `hugmesh_vpn` nft ruleset, marks before labels, idempotent re-runs,
  out-of-CIDR refusal, fail-closed aborts and rollbacks, full teardown, and the
  runner/reconcile/builder wiring (rootless, with recording fake `nft` and `kubectl`).
- `tests/egress-vpn/test-vpn-secret-projector.sh` — the delivery leg. It lifts the three
  contract values FROM the DaemonSet manifest and checks them against
  `egress-vpn-secret-contract.env` (this half needs no tooling and cannot skip). Then it
  runs the REAL projector loop (extracted from the DaemonSet) with those values against
  a contract-aware recording fake `kubectl`: filename == secretRef, `0600`,
  idempotence, prune-on-unassign, a Secret with only the old `config` key delivers
  nothing, and the two fail-closed cases (failed list, empty key) never destroy
  last-good. The first version hardcoded the three values in its own env, so it could
  not fail on the two that shipped wrong.
- `tests/egress-vpn/test-secret-contract.sh` — the CROSS-REPO gate: every copy of the
  contract in this repo's manifests, the `optional-services.yaml` registry entry, the
  two operator runbooks (the kustomization header's selector, this page's contract
  table) and the admin-bff writer source read from a sibling checkout (data key, Secret
  name, label, the `EGRESS_VPN_SECRET_NAMESPACE` lever, both dark-by-default flags).
  Then the COPY CENSUS, which fails on any carrier that is neither verified nor exempt
  with a reason. It exits 3 INCOMPLETE, never a green SKIP, when the sibling is missing.
- `tests/egress-vpn/test-optional-service-gate.sh` — the optional-service gate in
  `build-rpi5-stage4.sh`: default off, and an unselected build prunes the interaction
  NetworkPolicy, the delivery half and the node packages.
- `tests/egress-vpn/test-vpn-reconcile-verify.sh` — `vpn-verify.sh`, the signed-export
  consumer: it accepts a correctly signed envelope and rejects a tampered one.
- `tests/egress-vpn/test-x86-role-gate.sh` — `--egress-vpn` is desktop-only on every
  leg. The test evals the extracted PKGS block and the kernel `ROLE_CLIENT` arm for
  both extensions and both roles, so a node role can never emerge (or compile in) the
  VPN userspace the builder said it would ignore.
