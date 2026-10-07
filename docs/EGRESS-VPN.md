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
3. labels those pods `hugmesh.net/vpn-egress=true` so the
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

**The contract** lives in ONE file — `specs/cluster/egress-vpn-secret-contract.env`
— because it spans two repositories that never build together. The generator's
reader half (this repo) and the admin-bff writer half both merged green while
disagreeing on two of the three values, so the delivery leg could not deliver a
single byte:

| what | contract | the reader shipped | the writer shipped |
|---|---|---|---|
| namespace | `hugmesh-egress-vpn` | `hugmesh-egress-vpn` ✔ | `hugmesh-backend` ✘ |
| label | `hugmesh.net/optional-service=egress-vpn` | ✔ | ✔ |
| data key | the Secret's own `metadata.name` (`@name`) | `config` ✘ | ✔ |
| Secret name | == the export's `secretRef` | ✔ | ✔ |

Resolution, one value at a time:

- **namespace** — the generator's value wins, on the writer's own terms. It is
  the only one of the three admin-bff exposes as a lever
  (`EGRESS_VPN_SECRET_NAMESPACE`), and this repo owns the Deployment that sets
  it, so `manifests/admin-bff-api/deployment.yaml` now points admin-bff at
  `hugmesh-egress-vpn`. Adopting the writer's `hugmesh-backend` default instead
  would have handed a node-privileged, host-writing DaemonSet read access to
  every DB/OIDC/federation Secret in the app tier — RBAC has no label selector,
  so the namespace is the only expressible boundary.
- **data key** — admin-bff's value wins. `.addToStringData(secretRef, …)` is
  hardcoded, has no lever, and is pinned by a merged test; and key == name is
  deliberate (with it, a plain Secret volume projection already materialises the
  `${VPN_SECRET_DIR}/<secretRef>` file). `@name` is the contract's sentinel for
  that derivation — safe because `@` is not a legal Secret data-key character
  ("Each key must consist of alphanumeric characters, '-', '_' or '.'",
  core/v1 Secret API reference), so it can never collide with a real key.
- **write RBAC** — `manifests/egress-vpn/writer-rbac.yaml` grants the admin-bff
  pod's `backups-effector` SA `get/create/patch/update` on Secrets in that
  namespace and nowhere else. It was absent, and invisibly so: the writer
  swallows every failure to `false`, so an RBAC denial is indistinguishable from
  "delivery is off".

`tests/egress-vpn/test-secret-contract.sh` asserts every copy of these values —
in this repo's manifests AND in the admin-bff source, read from a sibling
checkout — against that one file, and exits 3 (INCOMPLETE, failing the job)
rather than half-checking when the sibling is absent.

**"Every copy" is SEARCHED FOR, not listed.** The first cut of that gate asserted
the three copies its author knew about and declared one source of truth while a
FOURTH sat in `specs/cluster/optional-services.yaml` carrying `secretKey:
config` — the exact broken value — read by nothing. Enumerating one more file
would have fixed that copy and left the next one just as invisible, so the gate
now runs a **copy census**: it greps the tree for every machine-read carrier of a
contract value and requires each to be either *verified* (a comparison in that
run actually read a value out of it — the set is populated from inside the
assertion helpers, so deleting an assertion drops the file back out) or
*exempt with a written reason*. A copy that did not exist when the census was
written still fails it. The one standing exemption is
`manifests/networkpolicy/egress-vpn-interaction.yaml`, where
`hugmesh.net/optional-service: egress-vpn` is the slug TAG every
optional-service object carries, not the Secret selector.

The registry's three fields are copies and now say so: they sit under a
`secretContract:` pointer at the contract file, and `secretKey` is `"@name"` —
QUOTED, because `@` is a YAML reserved indicator that cannot start a plain
scalar, so bare `@name` is a parse error rather than a string.

**SHIPS DARK, twice over.** `manifests/egress-vpn/kustomization.yaml` has
`resources: []` and is reachable only through the MANUAL-sync
`apps/13e-egress-vpn.yaml` (no `automated:` block) — the
`apps/08a-networkpolicy-egress.yaml` pattern. Even once synced, the DaemonSet's
`nodeSelector: hugmesh.net/egress-vpn=true` matches no node until an
operator labels the ones holding an assignment. Both halves are pruned wholesale
with the slug by `gate_optional_services()`.

That node-arming label is the contract's fifth value (`EGRESS_VPN_NODE_LABEL`),
and it earned its place there: it was written seven ways across the DaemonSet's
`nodeSelector` and header prose, three runbooks and the registry's
`nodeDeliveryLabel`, and asserted by none of them. Drift between the key the
projector selects on and the key a runbook tells an operator to apply does not
error. Upstream: "the DaemonSet controller will create Pods on nodes which match
that node selector" — so an unsatisfiable `nodeSelector` produces no Pods at
all, not even Pending ones, and therefore no scheduling event and no log line.
It is indistinguishable from a delivery leg that simply has not converged yet.
Unlike the three Secret values this one is generator-internal; admin-bff has no
side of it.

**How it is asserted, and why not the obvious way.** The expected value is read
from the DaemonSet's `nodeSelector` mapping — the key the kube-scheduler
actually evaluates — and every other carrier is graded against *that*. The first
attempt instead counted, per file, how many `hugmesh.net/*egress-vpn*`
tokens a runbook contained versus how many spelled the contract key: two numbers
off the same file, which move together for any edit that stays inside the
pattern. It passed a renamed prefix, it passed the transposition into
`hugmesh.net/vpn-egress` (the **pod** opt-in label documented 111 lines
above the node label — the single likeliest way to get this wrong), and it
passed deleting the instruction outright, printing "every node-label mention
spells the key" each time. The replacement finds label-shaped tokens by the
Kubernetes label *grammar*, classifies each one by the action the surrounding
prose describes (`nodeSelector`, or `label` near `node`) rather than by its
spelling, requires every node-arming one to equal the scheduler's key, requires
each file to carry at least one, and requires every remaining label to be named
as a known non-node label with a reason. A scan that finds nothing agrees with
everything, so finding nothing is red.

**FAIL-CLOSED.** A failed list prunes NOTHING (an API-server blip must not strip a
node of its VPN config), and a Secret with an empty/absent contract data key is
skipped rather than truncating a good file. The projector's RBAC is a namespaced
`Role` with `get`+`list` on `secrets` only — never a `ClusterRole`, no write verb
anywhere (the write grant is a separate identity in a separate file). SELinux: the
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

## Desktop images: `--egress-vpn FILE`

This is a different path from the node service above. `build-x86-host-stage4.sh
--egress-vpn FILE` bakes a WireGuard `.conf`, an OpenVPN `.ovpn` or an NM
`.nmconnection` into a **desktop** image. First boot imports it into
NetworkManager, and the user can add, remove or toggle it. `--egress-vpn-locked`
makes it autoconnect and keeps the user from removing it. A non-desktop role
ignores the flag and installs nothing for it. See
[`STANDALONE-DESKTOP.md`](STANDALONE-DESKTOP.md).

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
- `tests/egress-vpn/test-vpn-secret-projector.sh` — the delivery leg: the three
  contract values LIFTED FROM the DaemonSet manifest and asserted against
  `egress-vpn-secret-contract.env` (this half needs no tooling and can never
  skip), then the REAL projector loop (extracted from the DaemonSet) run with
  those manifest values against a contract-aware recording fake `kubectl` —
  filename == secretRef, 0600, idempotence, prune-on-unassign, a Secret carrying
  only the old `config` key delivering nothing, and the two fail-closed cases
  (failed list / empty key never destroy last-good). The first version of this
  test hardcoded the three values in its own invocation env, so it could not
  fail on the two that shipped wrong.
- `tests/egress-vpn/test-secret-contract.sh` — the CROSS-REPO gate: every copy of
  the contract in this repo's manifests, the `optional-services.yaml` registry
  entry, the two operator runbooks (the kustomization header's selector, this
  doc's contract table), plus the admin-bff writer source read out of a sibling
  checkout (data key, Secret name, label, the `EGRESS_VPN_SECRET_NAMESPACE`
  lever, both dark-by-default flags) — followed by the COPY CENSUS, which greps
  for carriers the assertions above do not name and fails on any that is neither
  verified nor exempt-with-a-reason. Exits 3 INCOMPLETE — never a green SKIP —
  when the sibling is missing.
- `tests/egress-vpn/test-optional-service-gate.sh` — the optional-service gate in
  `build-rpi5-stage4.sh`: default off, and an unselected build prunes the
  interaction NetworkPolicy, the delivery half and the node packages.
- `tests/egress-vpn/test-vpn-reconcile-verify.sh` — `vpn-verify.sh`, the
  signed-export consumer: it accepts a correctly signed envelope and rejects a
  tampered one.
- `tests/egress-vpn/test-x86-role-gate.sh` — `--egress-vpn` is desktop-only on
  every leg: the extracted PKGS block and kernel `ROLE_CLIENT` arm are eval'd for
  both extensions × both roles, so a node role can never emerge (or compile in)
  the VPN userspace the builder just told it it would ignore.

All of the above run in CI as the `egress-vpn-node-agents` verify job
(`.gitlab-ci.yml`, which loops over `tests/egress-vpn/*.sh`); they need only bash + stubbed tools — never a cluster, never
real `nft`/`ip`.
