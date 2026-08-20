"""Whole-mesh emulation planner (Qt-free) — issue #50 items 7-9.

After a mesh's images are built, the operator wants to emulate the WHOLE mesh
locally: every image of one build session booted as an emulated device at once,
each row visible with per-section status, loginable over ssh, provisioned from an
emulated USB KEYS stick, and the mesh's web front door reachable from the desktop
browser. This module is the Qt-free half of that screen
(gui/pages/mesh_emulation.py is the other), exactly as core/qemu_tests.py and
core/qemu_devices.py split the single-device test page.

WHAT THIS MODULE OWNS vs WHAT THE EXISTING TOOLS OWN
----------------------------------------------------
Nothing here boots anything. The containerized harness
(tests/qemu/run-qemu-docker.sh + docker-entrypoint.sh) already owns booting a
row, publishing its ssh on loopback, building the per-run FAT32 KEYS image
(make-test-keys.sh via docker-entrypoint.sh:699 ``KEYS_IMG="${RUN_DIR}/keys.img"``)
and writing the device registry core/qemu_devices.py reads. This module only:

  * PLANS a mesh: one :class:`PlannedDevice` per image the session holds, with
    non-conflicting ports, MAC/IP identities and the KEYS-image path the
    entrypoint will use — pure arithmetic over ``qemu_tests.discover_rows``,
    unit-testable with no docker, no qemu and no images;
  * builds the argv for the runner (through ``qemu_tests.runner_command``, the
    single argv author, so the mesh lane can never spell a flag differently from
    the device-test lane);
  * reads the plan back against the live registry / result JSON to answer
    "what is each device's boot / ssh / provision / web section doing";
  * funnels every process launch through ONE function, :func:`spawn`, whose
    interface is documented below precisely so tests can mock it.

WHAT A PLAN'S NUMBERS MEAN (and which are live today)
-----------------------------------------------------
* ``ssh_port`` mirrors the runner's own allocation plan: run-qemu-docker.sh:155
  owns the loopback range 22300-22399 and allocates from it low-to-high, skipping
  busy ports. The plan assigns ``SSH_PORT_MIN + index`` so the preview matches
  what an idle host will actually get; the REGISTRY record stays the authority
  once a device is up (the GUI reads ssh actions from it, never from the plan).
* ``ui_port`` is LIVE: it is the local port the web tunnel binds
  (:func:`web_tunnel_argv`). The guest's web front door listens on guest :443
  (launch-pi.sh:245 forwards its container-side UI port to guest 443), and the
  only thing the keep-alive runner publishes to the host is ssh — so the desktop
  reaches the UI through an ssh -L tunnel over that published port, using only
  what exists today. The range starts at 9443 (the launchers' own documented
  alternate UI port) — deliberately OFF :8443 and :8080, which the operator's
  live local mesh and headscale occupy.
* ``mac`` / ``ip`` / ``mesh_net`` are the mesh identity of the SHARED-NETWORK
  lane, and they are now CONSUMED, not merely previewed: :func:`identities_json`
  serialises them into the identity file that ``tests/qemu/run-qemu-docker.sh
  --mesh-net`` and ``tests/qemu/mesh-cluster.sh --identities`` read, which is how
  a MAC/IP shown in the UI is the same MAC/IP the guest's NIC and its
  ``KEYS/network/mesh0.nmconnection`` end up carrying. Minted here,
  deterministically and collision-free, so there is exactly ONE source of
  identities: replanning the same session yields the same identities, so nothing
  in the UI reshuffles and a re-boot of one row rejoins the same L2 at the same
  address. Without a mesh spec each guest still sits alone behind its own QEMU
  user-net (slirp gives every guest 10.0.2.15 and no cross-device link) — the
  shared L2 is opt-in on every layer.
* ``keys_image`` is the entrypoint's own spelling (``<work>/runs/<safe>/keys.img``)
  so the row can point the operator at the emulated USB stick the existing tools
  build — this module never builds one itself.
"""
from __future__ import annotations

import hashlib
import json
import os
import threading  # noqa: F401 — spawn()'s signature names threading.Event
from collections.abc import Callable
from dataclasses import dataclass, field

from .qemu_devices import (RUNS_SUBDIR, SSH_HOST, SSH_OPTIONS, safe_label)
from .qemu_tests import (DEFAULT_WORK_SUBDIR, QemuRunOptions, RUNNER_SCRIPT,
                         BuildSession, DeviceRow, platform_rank, runner_command)

#: The runner's own keep-alive ssh range (run-qemu-docker.sh:155 DEV_PORT_MIN/MAX).
#: Mirrored, not invented: the plan previews the allocation the runner will make on
#: an idle host, and a plan outside this range would preview ports the runner then
#: refuses to publish ("refusing to publish out-of-range port").
SSH_PORT_MIN = 22300
SSH_PORT_MAX = 22399

#: Where the web tunnels bind on the host, one per device. 9443 is the launchers'
#: own documented alternate UI port (launch-pi.sh usage: ``--ui-port 9443``); the
#: range must stay OFF :8443 (the operator's live local-mesh kind cluster and the
#: e2e baseURL) and :8080 (headscale) — publishing an emulated mesh onto the live
#: one's ports is how a browser ends up asserting against the wrong mesh.
UI_PORT_MIN = 9443
UI_PORT_MAX = 9499

#: The guest-side port the web tunnel lands on. Every launcher forwards its UI
#: port to guest 443 (launch-pi.sh:245 / launch-x86.sh:220 / launch-arm.sh:298
#: ``hostfwd=tcp::${UI_PORT}-:443``): 443 is where the image's ingress actually
#: listens, so the tunnel goes straight there.
GUEST_UI_PORT = 443

#: QEMU's locally-administered OUI — every MAC this planner mints starts with it,
#: so a planned NIC can never collide with real hardware on the operator's LAN.
MAC_PREFIX = "52:54:00"

#: The planned mesh subnet (/24). Host .1 is reserved for the future shared
#: network's gateway; devices start at .11 (single digits stay recognisably
#: reserved). RFC1918, and deliberately NOT 10.0.2.0/24 — that is slirp's own
#: subnet inside every guest today, and a plan reusing it would read as if the
#: current NICs already carried these addresses.
MESH_SUBNET = "10.77.0"
_IP_FIRST = 11

#: The mesh addresses' prefix length. The plan is one flat /24 per session, so
#: this is the number that ends up in the guest's nmconnection (``address1=
#: <ip>/24``) — emitted as data rather than hard-coded in the shell consumers,
#: which is the whole point of the identity file.
MESH_PREFIX_LEN = 24

#: The shared L2 itself, as a QEMU socket-netdev multicast SPEC (``ADDR:PORT``,
#: what ``launch-*.sh --mesh-net`` takes). 239.0.0.0/8 is the administratively
#: scoped IPv4 multicast block — it never leaves the local network — and
#: 239.118.72.0/24 is the /24 the landed mesh-cluster.sh driver already picked,
#: kept so both lanes stay inside one recognisable range.
#:
#: The GROUP and PORT are derived from the session, not fixed: two meshes
#: emulated from two different sessions on one workstation must not share a
#: broadcast domain, or node1 of session A would see node1 of session B's ARP
#: and both clusters would be minting nodes on the same wire.
MESH_MCAST_PREFIX = "239.118.72"
_MCAST_GROUP_FIRST, _MCAST_GROUP_LAST = 1, 254
MESH_PORT_MIN = 47300
MESH_PORT_MAX = 47399

#: The per-device sections the GUI badges. Order is presentation order.
SECTIONS = ("boot", "ssh", "provision", "web")

#: Section-status vocabulary. A section is exactly one of these; the GUI colours
#: from the value, never from the detail text.
ST_OK, ST_PENDING, ST_FAILED, ST_OFF, ST_UNKNOWN = (
    "ok", "pending", "failed", "off", "unknown")

#: Which role serves the mesh's web FRONT DOOR, most-preferred first. ``omnibus``
#: is the all-in-one node, ``fe`` is the ingress the e2e suite drives
#: (tests/e2e/playwright.config.ts baseURL), then the remaining node roles as
#: fallbacks so a partial mesh still names SOME front door rather than none.
GATEWAY_ROLES = ("omnibus", "fe", "be", "be+gpu", "pki")


@dataclass(frozen=True)
class PlannedDevice:
    """One device of the mesh plan: a session image plus its planned identity."""
    label: str          # "rpi5/pki" — the harness's <platform>/<role> spelling
    platform: str
    arch: str
    role: str
    image: str          # absolute path to the golden .img/.img.xz
    index: int          # boot-order position (Pi first — platform_rank)
    ssh_port: int       # planned loopback ssh (the registry is authoritative once up)
    ui_port: int        # LIVE: where this device's web tunnel binds on the host
    mac: str            # planned NIC identity (shared-network lane)
    ip: str             # planned mesh address (shared-network lane)
    keys_image: str     # the emulated USB KEYS stick the entrypoint builds/attaches


@dataclass
class MeshPlan:
    """Everything the mesh-emulation screen needs about one session's mesh."""
    session_path: str
    session_name: str
    work_dir: str
    devices: list[PlannedDevice] = field(default_factory=list)
    gateway_label: str = ""
    #: The session's shared-L2 SPEC (``ADDR:PORT``), the same string every one of
    #: this plan's devices passes to ``launch-*.sh --mesh-net``. Defaulted rather
    #: than required so a hand-built plan (tests, older callers) still constructs.
    mesh_net: str = ""

    @property
    def gateway(self) -> PlannedDevice | None:
        return self.device(self.gateway_label)

    def device(self, label: str) -> PlannedDevice | None:
        for d in self.devices:
            if d.label == label:
                return d
        return None


def gateway_label(rows: list[DeviceRow]) -> str:
    """Which row serves the mesh's web front door — "" for an empty session.

    By role preference (:data:`GATEWAY_ROLES`), platform-independent: a mesh whose
    fe is an rpi5 and a mesh whose fe is x86 have the same front door. A session
    with none of the preferred roles still gets one (the first row in boot order)
    so the web action degrades to "this device's UI" rather than vanishing.
    """
    if not rows:
        return ""
    by_role = {r.role: r for r in sorted(
        rows, key=lambda r: (platform_rank(r.platform), r.platform, r.role))}
    for role in GATEWAY_ROLES:
        if role in by_role:
            return by_role[role].label
    return sorted(rows, key=lambda r: (platform_rank(r.platform),
                                       r.platform, r.role))[0].label


def _mesh_mac(session_name: str, index: int) -> str:
    """A deterministic, session-scoped, per-device MAC under the QEMU OUI.

    Two hash bytes from the SESSION name keep two different sessions' plans from
    colliding on a future shared network; the last byte is the device index, so
    within one plan uniqueness is arithmetic rather than probabilistic.
    """
    digest = hashlib.sha256(session_name.encode("utf-8")).digest()
    return f"{MAC_PREFIX}:{digest[0]:02x}:{digest[1]:02x}:{index:02x}"


def mesh_net_spec(session_name: str) -> str:
    """This session's shared-L2 SPEC — ``<mcast group>:<port>``, deterministic.

    The SPEC every device of ONE plan passes to ``launch-*.sh --mesh-net``: the
    UDP-multicast form needs no listener ordering, so all N nodes simply join the
    group and no node has to boot before another. Group and port both come from
    the session digest (bytes 2 and 3 — the MAC takes 0 and 1, so the two
    derivations cannot correlate), which keeps two concurrently emulated sessions
    on two different wires while replanning one session always returns to its own.
    """
    digest = hashlib.sha256(session_name.encode("utf-8")).digest()
    span = _MCAST_GROUP_LAST - _MCAST_GROUP_FIRST + 1
    group = _MCAST_GROUP_FIRST + digest[2] % span
    port = MESH_PORT_MIN + digest[3] % (MESH_PORT_MAX - MESH_PORT_MIN + 1)
    return f"{MESH_MCAST_PREFIX}.{group}:{port}"


def plan_mesh(session: BuildSession, generator_dir: str, *,
              work_dir: str = "") -> MeshPlan:
    """The mesh plan for one build session — pure arithmetic, boots nothing.

    One :class:`PlannedDevice` per row ``qemu_tests.discover_rows`` found in the
    session (newest artifact per platform/role, exactly what the runner would
    boot), in boot order. Ports and identities are assigned by index, so they are
    unique BY CONSTRUCTION and deterministic across replans of the same session;
    the ranges are validated rather than trusted, and a session too large for one
    of them raises ValueError instead of silently wrapping into a collision.
    """
    work = work_dir or os.path.join(generator_dir, DEFAULT_WORK_SUBDIR)
    rows = sorted(session.rows,
                  key=lambda r: (platform_rank(r.platform), r.platform, r.role))
    for limit, what in ((SSH_PORT_MAX - SSH_PORT_MIN + 1, "ssh ports"),
                        (UI_PORT_MAX - UI_PORT_MIN + 1, "web-tunnel ports"),
                        (245 - _IP_FIRST, "mesh addresses")):
        if len(rows) > limit:
            raise ValueError(
                f"session {session.name!r} holds {len(rows)} devices, more than "
                f"the {limit} {what} the plan can assign without conflicts")

    devices = [PlannedDevice(
        label=row.label, platform=row.platform, arch=row.arch, role=row.role,
        image=row.image, index=i,
        ssh_port=SSH_PORT_MIN + i,
        ui_port=UI_PORT_MIN + i,
        mac=_mesh_mac(session.name, i),
        ip=f"{MESH_SUBNET}.{_IP_FIRST + i}",
        keys_image=os.path.join(work, RUNS_SUBDIR, safe_label(row.label),
                                "keys.img"),
    ) for i, row in enumerate(rows)]

    return MeshPlan(session_path=session.path, session_name=session.name,
                    work_dir=work, devices=devices,
                    gateway_label=gateway_label(rows),
                    mesh_net=mesh_net_spec(session.name))


def front_door_url(plan: MeshPlan) -> str:
    """The emulated mesh's front-door URL, or "" for a plan with no gateway.

    ``https://127.0.0.1:<gateway ui_port>/`` — live once the gateway's web tunnel
    is up (:func:`web_tunnel_argv`); https because the guest's ingress serves TLS
    on 443 and the tunnel is a byte pipe, not a terminator.
    """
    gw = plan.gateway
    return f"https://{SSH_HOST}:{gw.ui_port}/" if gw else ""


# ── the identity file: ONE source of MACs/IPs/L2, for the shell lanes ─────────────

def _as_mesh_plan(plan) -> MeshPlan:
    """Accept a :class:`MeshPlan` or anything carrying one as ``.mesh``.

    ``core.emulation.EmulationPlan`` embeds this planner's output as ``.mesh``, so
    every caller that already holds a facade plan can emit identities from it
    without unwrapping (and without this module importing the facade, which
    imports this one). A TEST-lane plan has ``mesh=None`` and raises here rather
    than silently emitting an empty identity file — a mesh with no identities is
    a mesh whose nodes cannot address each other.

    Structural, not ``isinstance``, and that is load-bearing rather than lax:
    ``python -m hugmesh_studio.core.mesh_emulation`` loads THIS file twice — once
    as ``__main__`` and once, under its package name, by the facade it imports —
    so the plan handed back carries the OTHER copy's ``MeshPlan`` class and an
    identity check would reject a perfectly good plan.
    """
    mesh = plan if hasattr(plan, "devices") else getattr(plan, "mesh", None)
    if mesh is None or not hasattr(mesh, "devices"):
        raise ValueError("no mesh plan to take identities from — plan the session "
                         "in the DEPLOY lane (a TEST plan mints no mesh identities)")
    return mesh


def identities(plan) -> list[dict]:
    """The plan's mesh identities as plain data, one entry per planned device.

    ``[{label, mac, ip, prefix_len, subnet, mesh_net}]``, in boot order. THE
    machine-readable contract between this planner and the shell lanes that boot
    guests: ``run-qemu-docker.sh --mesh-net auto --identities FILE`` hands each
    row's ``mac``/``ip`` to its launcher and to the KEYS payload, and
    ``mesh-cluster.sh --identities FILE`` takes its three nodes' identities from
    the same file. Every field is a string except ``prefix_len`` so a consumer
    can spell ``address1=<ip>/<prefix_len>`` without re-deriving anything.

    ``mesh_net`` is repeated on every entry deliberately: a consumer that reads
    one row must not have to look elsewhere for the wire that row is on, and a
    file whose rows disagree is then visibly wrong rather than quietly partial.
    """
    mesh = _as_mesh_plan(plan)
    subnet = f"{MESH_SUBNET}.0/{MESH_PREFIX_LEN}"
    net = mesh.mesh_net or mesh_net_spec(mesh.session_name)
    return [{"label": d.label, "mac": d.mac, "ip": d.ip,
             "prefix_len": MESH_PREFIX_LEN, "subnet": subnet, "mesh_net": net}
            for d in mesh.devices]


def identities_json(plan, *, indent: int = 2) -> str:
    """:func:`identities` as JSON text (newline-terminated) — the file itself."""
    return json.dumps(identities(plan), indent=indent) + "\n"


def write_identities(plan, path: str) -> str:
    """Write the identity file to ``path`` (creating its directory) and return it.

    Written whole and then renamed: the consumers are shell scripts that may read
    the file while a second plan is being written next to it, and half an identity
    file is a mesh with half its addresses.
    """
    directory = os.path.dirname(os.path.abspath(path))
    if directory:
        os.makedirs(directory, exist_ok=True)
    tmp = f"{path}.tmp.{os.getpid()}"
    with open(tmp, "w", encoding="utf-8") as fh:
        fh.write(identities_json(plan))
    os.replace(tmp, path)
    return path


# ── argv builders (all through the existing runner — no new process shapes) ───────

def start_mesh_argv(generator_dir: str, plan: MeshPlan, *,
                    jobs: int = 2, mem_mb: int = 2048,
                    timeout_s: int = 2400) -> list[str]:
    """argv that boots the WHOLE mesh: the runner's own fan-out over the session.

    ``--keep-alive`` is what turns a test run into a standing mesh — the guests
    stay up after their assertions and register under ``<work>/devices/``, which
    is everything the GUI's table reads. Built through ``runner_command`` so the
    flags can never drift from the device-test page's spelling.
    """
    return runner_command(generator_dir, QemuRunOptions(
        artifacts_dir=plan.session_path, work_dir=plan.work_dir,
        jobs=jobs, mem_mb=mem_mb, timeout_s=timeout_s, keep_alive=True))


def start_device_argv(generator_dir: str, plan: MeshPlan,
                      planned: PlannedDevice, *, jobs: int = 1,
                      mem_mb: int = 2048, timeout_s: int = 2400) -> list[str]:
    """argv that boots ONE planned device (``--keep-alive --only <label>``) —
    the same re-entry the device-test page's per-row Start uses.

    NOTE (T2): ``--only`` is a SUBSTRING filter, so ``x86/be`` also drags in
    be+gpu/be-ha rows. The caller-facing author that fixes this is
    core.emulation.start_device_argv, which addresses the row with T1's
    ``--only-exact`` (and can also start from a live record's ``artifacts``
    field); this spelling stays until the GUI/TUI move onto the facade (T3/T4),
    whose tests pin the current argv.
    """
    return runner_command(generator_dir, QemuRunOptions(
        artifacts_dir=plan.session_path, work_dir=plan.work_dir,
        only=planned.label, jobs=jobs, mem_mb=mem_mb, timeout_s=timeout_s,
        keep_alive=True))


def stop_device_argv(generator_dir: str, planned, *, work_dir: str = "") -> list[str]:
    """argv that stops ONE device — the runner's ``--stop-device LABEL`` (it owns
    the container name; same verb qemu_devices.device_control_argv emits).

    ``work_dir`` fixes the start/stop asymmetry this module shipped with: every
    START argv pinned ``--work`` to the plan's work dir, while the stops let the
    runner default — so a mesh running in a custom ``--work`` booted there and then
    "stopped" against the default registry, which held no such device. Callers that
    know the work dir (core.emulation always does) pass it; the parameter stays
    optional so the TUI's existing calls keep working until T4.

    ``planned`` may be a planned device, a live registry record, or a bare label
    string — only ``.label`` is read, and a stop only needs the name.
    """
    argv = [os.path.join(generator_dir, RUNNER_SCRIPT)]
    if work_dir:
        argv += ["--work", work_dir]
    label = getattr(planned, "label", planned)
    return argv + ["--stop-device", str(label)]


def stop_mesh_argv(generator_dir: str, *, work_dir: str = "") -> list[str]:
    """argv for the fleet-wide stop — the runner's ``--stop-all-devices``.

    ``work_dir`` for the same asymmetry fix as ``stop_device_argv``: the sweep
    reads the registry under the runner's ``--work``, so a custom-work mesh needs
    the stop aimed at ITS registry.
    """
    argv = [os.path.join(generator_dir, RUNNER_SCRIPT)]
    if work_dir:
        argv += ["--work", work_dir]
    return argv + ["--stop-all-devices"]


def web_tunnel_argv(dev, planned: PlannedDevice) -> list[str]:
    """argv for the ssh tunnel that makes the device's web UI reachable.

    ``dev`` is the LIVE registry record (core.qemu_devices.Device) — the tunnel
    rides the device's published ssh port and its run key, both of which only the
    registry knows. ``-N`` because this session exists to forward, not to run a
    shell; ``-L <ui_port>:127.0.0.1:443`` binds the plan's local port and lands on
    the guest's own loopback 443, where the image's ingress listens — so the ONLY
    published port a device needs is the ssh one the keep-alive runner already
    publishes.

    Raises ValueError for a record that cannot carry a tunnel (no published port /
    no key), for the same reason qemu_devices.ssh_argv never falls back to port
    22: on this host 127.0.0.1:22 is the operator's own sshd.
    """
    if not dev.ssh_host_port or dev.ssh_host_port <= 0:
        raise ValueError(f"{planned.label} published no ssh port, so there is "
                         "nothing to tunnel the web UI through")
    if not dev.ssh_key:
        raise ValueError(f"{planned.label}'s record names no ssh key, so the "
                         "tunnel has no identity to authenticate with")
    return ["ssh", "-i", dev.ssh_key, "-p", str(dev.ssh_host_port), *SSH_OPTIONS,
            "-N", "-L", f"{planned.ui_port}:{SSH_HOST}:{GUEST_UI_PORT}",
            f"{dev.ssh_user}@{SSH_HOST}"]


# ── plan vs reality: per-section status ────────────────────────────────────────────

def device_status(dev) -> tuple[str, str]:
    """(status, badge text) for a row's overall badge, from the registry record.

    ``dev`` is the live core.qemu_devices.Device or None for a device that never
    registered. The registry's own state words are shown, not re-invented; only
    the STATUS KIND (which colours the badge) is mapped.
    """
    if dev is None:
        return ST_OFF, "not started"
    if not dev.is_running:
        return ST_OFF, dev.state or "stopped"
    if dev.state == "booting":
        return ST_PENDING, "booting"
    if dev.state == "assertions":
        return ST_PENDING, "assertions"
    if dev.state == "running":
        return ST_OK, "up"
    return ST_UNKNOWN, dev.state


def section_statuses(planned: PlannedDevice, dev, result: dict | None, *,
                     gateway: bool = False) -> dict[str, tuple[str, str]]:
    """{section: (status, detail)} for one row — every entry honest, none inferred.

    ``dev`` is the live registry record (or None: never registered), ``result``
    the row's assertion JSON from ``qemu_tests.read_results`` (or None: no verdict
    yet). Sections:

    * ``boot`` — is the emulated device up (the registry's answer);
    * ``ssh``  — is a login reachable (a published port plus a key; the record is
      only written once the guest answered ssh, so "up but port 0" is stated as
      pending rather than guessed at);
    * ``provision`` — did the image provision correctly (the assertion verdict,
      which asserts exactly the keys-provision/first-boot surface; a device that
      has not finished a run yet is pending, not failed);
    * ``web``  — the front door. Only the gateway row carries it (the others say
      whose it is); OK means "a tunnel can be opened NOW", not that one is open —
      whether the browser reached it is the browser's answer, not this module's.
    """
    running = dev is not None and dev.is_running
    out: dict[str, tuple[str, str]] = {}

    st, text = device_status(dev)
    out["boot"] = (st, text if dev is None else f"{text} (registry)")

    if dev is None:
        out["ssh"] = (ST_OFF, "not started")
    elif not running:
        out["ssh"] = (ST_OFF, f"device is {dev.state or 'stopped'}")
    elif dev.ssh_host_port > 0 and dev.ssh_key:
        out["ssh"] = (ST_OK, f"{SSH_HOST}:{dev.ssh_host_port}")
    else:
        out["ssh"] = (ST_PENDING, "registered, but no published port/key yet")

    if result is not None:
        verdict = str(result.get("status", ""))
        detail = (f"{result.get('assertions_passed', '?')} passed, "
                  f"{result.get('assertions_failed', '?')} failed")
        if verdict == "PASS":
            out["provision"] = (ST_OK, detail)
        elif verdict in ("FAIL", "ERROR"):
            out["provision"] = (ST_FAILED, detail)
        else:
            out["provision"] = (ST_UNKNOWN, f"verdict {verdict!r}")
    else:
        out["provision"] = ((ST_PENDING, "no verdict yet") if running
                            else (ST_OFF, "not started"))

    if not gateway:
        out["web"] = (ST_OFF, "served by the gateway row")
    elif running and dev.ssh_host_port > 0 and dev.ssh_key:
        out["web"] = (ST_OK,
                      f"tunnel ready — https://{SSH_HOST}:{planned.ui_port}/")
    elif running:
        out["web"] = (ST_PENDING, "gateway is up, but its ssh is not "
                                  "published yet (the tunnel rides it)")
    else:
        out["web"] = (ST_OFF, "gateway is not up")
    return out


# ── THE process boundary ───────────────────────────────────────────────────────────

def spawn(argv: list[str], cwd: str,
          on_line: Callable[[str], None] | None = None,
          cancel: "threading.Event | None" = None) -> int:
    """Alias for :func:`hugmesh_studio.core.emulation.spawn` — see there.

    The implementation was PROMOTED to core/emulation.py (T2): the facade is THE
    single process boundary for every emulation surface, and two spellings of "run
    a plan's argv" is exactly the drift this refactor exists to close. This alias
    stays so tui/meshemu.py (and anything else that spells ``mesh_emulation.spawn``)
    keeps working until T4 retires it; the import is lazy to keep the module graph
    acyclic (emulation imports THIS module at top level).
    """
    from .emulation import spawn as _spawn
    return _spawn(argv, cwd, on_line=on_line, cancel=cancel)


# ── CLI: mint the identity file the shell lanes consume ────────────────────────────
# Deliberately one subcommand and nothing else. The rich CLI is the facade's
# (``python -m hugmesh_studio.core.emulation plan|up|status|…``); this face exists
# because the identity FILE is a build product two bash drivers read, and asking an
# operator to pipe a plan through jq to produce it would be a second identity
# source in all but name.

_REPO_ROOT = os.path.dirname(os.path.dirname(os.path.dirname(
    os.path.dirname(os.path.abspath(__file__)))))


def main(argv: list[str] | None = None) -> int:
    import argparse                 # CLI-only imports: `import mesh_emulation`
    import sys                      # stays as thin as the planner it wraps

    from . import qemu_tests as qt

    p = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.mesh_emulation",
        description=("Emit ONE build session's mesh identities — the "
                     "{label, mac, ip, prefix_len, subnet, mesh_net} file that "
                     "tests/qemu/run-qemu-docker.sh --identities and "
                     "tests/qemu/mesh-cluster.sh --identities consume, so every "
                     "layer addresses a device by the same MAC and IP."))
    p.add_argument("subcommand", choices=("identities",))
    p.add_argument("--generator-dir", default=_REPO_ROOT,
                   help="the hugmesh-generator checkout (default: this one)")
    p.add_argument("--session", default="",
                   help="build session: a name under out/sessions or a path "
                        "(default: the newest COMPLETE session)")
    p.add_argument("--work", default="",
                   help="runner --work dir (default: <generator>/out/qemu-runs)")
    p.add_argument("--out", default="",
                   help="write the file here instead of stdout (atomically)")
    args = p.parse_args(argv)

    # Lazy, and only here: core.emulation imports THIS module at top level, so a
    # module-level import back would be a cycle. The planning itself goes through
    # the facade on purpose — one lane resolving sessions differently from the
    # other is the drift the facade exists to prevent.
    from .emulation import EmulationMode, plan as plan_session

    session = args.session or qt.default_session(args.generator_dir)
    if session is None:
        print("no build session with images under out/sessions — build images "
              "first, or pass --session", file=sys.stderr)
        return 1
    try:
        pl = plan_session(args.generator_dir, session, EmulationMode.DEPLOY,
                          work_dir=args.work, epoch="")
    except ValueError as exc:
        print(exc, file=sys.stderr)
        return 1
    if not pl.rows:
        print(f"session {pl.session_name} holds no runnable images — nothing to "
              "mint identities for", file=sys.stderr)
        return 1
    if args.out:
        print(write_identities(pl, args.out))
    else:
        sys.stdout.write(identities_json(pl))
    return 0


if __name__ == "__main__":
    import sys as _sys
    _sys.exit(main())
