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
* ``mac`` / ``ip`` are the mesh-identity plan for the SHARED-NETWORK lane: today
  each guest sits alone behind its own QEMU user-net (slirp gives every guest
  10.0.2.15 and no cross-device link), so these are not consumed by the current
  launchers — they are minted here, deterministically and collision-free, so the
  runner's future shared-network mode has one source of identities and the GUI
  can already show which address each device WILL own. Deterministic: replanning
  the same session yields the same identities, so nothing in the UI reshuffles.
* ``keys_image`` is the entrypoint's own spelling (``<work>/runs/<safe>/keys.img``)
  so the row can point the operator at the emulated USB stick the existing tools
  build — this module never builds one itself.
"""
from __future__ import annotations

import hashlib
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
                    gateway_label=gateway_label(rows))


def front_door_url(plan: MeshPlan) -> str:
    """The emulated mesh's front-door URL, or "" for a plan with no gateway.

    ``https://127.0.0.1:<gateway ui_port>/`` — live once the gateway's web tunnel
    is up (:func:`web_tunnel_argv`); https because the guest's ingress serves TLS
    on 443 and the tunnel is a byte pipe, not a terminator.
    """
    gw = plan.gateway
    return f"https://{SSH_HOST}:{gw.ui_port}/" if gw else ""


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
