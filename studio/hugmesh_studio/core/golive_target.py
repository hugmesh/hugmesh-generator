"""Go-live TARGET — which node a go-live verb runs against (Qt-free, all OS).

The operator ask: "allow golive from qemu emulated mesh on all OS studio and cli".
Every go-live verb (status | list | plan | commit | rollback) runs against a TARGET:

* LOCAL — this host is itself a HugMesh node. Today's behaviour (GoLiveDriver runs the
  checkout's driver with bash), except that ``commit`` is refused unless this host
  really is a node: ``/etc/hugmesh/release-state`` exists and
  ``hugmesh-firewall-reconcile`` is installed (:func:`local_node_refusal`, "B1").
* EMULATED — a running keep-alive device: a record from
  ``qemu_devices.discover_devices(<work>)`` (the docker lane, Linux and WSL2) or from
  ``qemu_windows.running(<work>)`` (QEMU for Windows, WHPX).

For an emulated target this host runs ONLY ``ssh`` — never bash, never the checkout's
driver. The guest's own baked ``/usr/sbin/hugmesh-go-live`` is the authority: ``status``
and ``list`` are read from it, so a guest whose baked driver is older than the checkout
still answers for itself.

THE FLOW (each step is one function below, and each argv is pinned by a test):

1. :func:`probe_argv` / :func:`parse_probe` — one read-only ssh round trip: is the
   driver baked (B8), the cluster domain, the domains file, and the onion exports.
2. :func:`remote_verb_argv` — ``ssh … sudo -n hugmesh-go-live list|status|plan …``.
3. ``plan``: :func:`stage_token_remote` sends the masked token over ssh STDIN into a
   guest ``mktemp`` under ``umask 077`` (the value is never on any argv), the plan runs
   with ``--token-file <that path>``, then :func:`remove_token_remote` deletes it — on
   the error path too (:func:`run_plan`). :func:`fetch_artifacts` copies the plan's
   files back with ``ssh … cat`` into ``<work>/golive/<label>/`` for display.
4. ``commit`` / ``rollback``: :func:`commit_argv` / :func:`rollback_argv` are
   ``ssh -t …`` and NEVER carry ``-y``: the guest driver's confirmation prompt runs on
   the ssh pty, and that TTY confirmation is the security boundary.
   :func:`terminal_spec` opens them in a terminal on Linux (cloud_deploy.TERMINALS),
   WSL2 (cmd.exe/wt.exe interop around wsl.exe) and native Windows (a new console).
5. :func:`write_journal` — ``<work>/golive/<label>.json`` (provider, domain, the
   device's started_at, UTC time, exit code; no secrets). A commit/rollback that
   exited non-zero (refused, declined, ssh failed) is kept apart as ``refused`` and
   never becomes the recorded action. :func:`earlier_boot` says when the journal
   belongs to an earlier boot of the device — a FACT about the record, never a
   posture: a device can boot again from its golden image (whatever that image
   bakes) or from a save (whatever it held when it was saved), so nothing here infers
   the posture from a restart.
6. The posture is READ, never inferred: :func:`read_posture` asks the device itself
   over one read-only ssh round trip — the two witnesses the go-live proof lane uses,
   ``hugmesh-go-live status`` and the anchored ``nft list table inet
   hugmesh_release_gate`` check — and says ``unknown (device not reachable)`` when it
   cannot ask. :func:`device_report` is what every face shows under the device's
   status: that reading, the save the device booted from (with the posture the save
   was taken in, recorded by core.emulation_save), and the journal.

WHAT IS REFUSED (each with a sentence, :func:`refusal`): a target that is not running
or has no ssh port or key (no channel to it); a client role or a platform whose image
bakes no go-live driver (not a go-live server node); a WHPX record without an ssh key;
a guest with no driver (the probe, B8); a local commit off-node (B1); an ingress IP in
the slirp 10.0.2.0/24 or mesh-L2 10.77.0.0/24 range (:func:`refuse_private_ingress`);
Tailscale Funnel on an emulated mesh, whose control plane is its own headscale
(:func:`headscale_refusal` — plan and commit both, so every face refuses it).

Inbound reachability through a host relay (publishing 0.0.0.0:80/443 from this host
into the container) is deliberately NOT built: it exposes the operator's workstation
and needs an operator decision first. :func:`mechanism_reachability` says honestly what
each mechanism can and cannot do from an emulated node.

The CLI (``python -m hugmesh_studio.core.golive_target …``) runs the same functions.
"""
from __future__ import annotations

import argparse
import dataclasses
import ipaddress
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import time
from collections.abc import Callable
from dataclasses import dataclass, field

from . import qemu_devices, qemu_windows

__all__ = [
    "KIND_LOCAL", "KIND_DOCKER", "KIND_WHPX", "KINDS", "LOCAL_LABEL",
    "GUEST_DRIVER", "GUEST_OUT_ROOT", "TOKEN_PREFIX",
    "GoLiveTarget", "Probe", "TerminalSpec",
    "local_target", "target_from_device", "target_from_whpx", "targets", "find_target",
    "same_binding", "rebind", "binding_change",
    "refusal", "local_node_refusal", "probe_argv", "parse_probe", "probe",
    "probe_refusal", "remote_argv", "remote_verb_argv", "stage_token_remote",
    "remove_token_remote", "guest_out_dir", "fetch_artifacts", "artifacts_dir",
    "run_plan", "commit_argv", "rollback_argv", "terminal_spec", "journal_path",
    "write_journal", "read_journal", "earlier_boot", "journal_status",
    "POSTURE_PUBLIC", "POSTURE_INTERNAL", "POSTURE_MIXED", "POSTURE_UNKNOWN",
    "RELEASE_GATE_TABLE", "Posture", "posture_argv", "parse_posture", "read_posture",
    "posture_phrase", "posture_line", "READ_NOW", "utc_now", "save_origin", "boot_origin",
    "device_report",
    "mechanism_reachability", "refuse_private_ingress", "EPHEMERAL_NOTE",
    "HEADSCALE_REFUSED_PROVIDERS", "HEADSCALE_REFUSED_MECHANISMS", "headscale_refusal",
    "add_cli_arguments", "run_studio_cli", "main",
]

KIND_LOCAL = "local"
KIND_DOCKER = "emulated-docker"
KIND_WHPX = "emulated-whpx"
KINDS = (KIND_LOCAL, KIND_DOCKER, KIND_WHPX)

#: The LOCAL row's label (what ``--target`` names it by on the CLI).
LOCAL_LABEL = "this-host"

#: The guest's baked driver, resolved through sudo's secure_path (/usr/sbin).
GUEST_DRIVER = "hugmesh-go-live"
#: Where a plan run from here writes inside the guest: a fresh sub-directory per run
#: under the driver's own default (GL_OUT_DIR), so the artifacts copied back are this
#: run's and never a file a previous plan left behind.
GUEST_OUT_ROOT = "/var/lib/hugmesh/go-live/out"
#: The guest-side token file prefix (``mktemp`` adds the random suffix).
TOKEN_PREFIX = "/run/hugmesh-golive-tok."
_TOKEN_PATH_RE = re.compile(r"^/run/hugmesh-golive-tok\.[A-Za-z0-9]{6,}$")
#: A plan artifact name we will ``cat`` back: one path component, no dot-file.
_ARTIFACT_NAME_RE = re.compile(r"^[A-Za-z0-9_+-][A-Za-z0-9._+-]{0,127}$")
#: Driver inputs that reach the guest's shell inside the one remote-command string.
#: shlex quotes every one, but a provider/domain outside these shapes is refused
#: before it ever gets that far (and the WSL path passes through cmd.exe, too).
_PROVIDER_RE = re.compile(r"^[a-z0-9][a-z0-9-]{0,62}$")
_DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")

#: Roles whose images bake no go-live driver (scripts/_roles-lib.sh's client class
#: plus the ARM desktop role ids; tests/qemu/assertions.sh forbids the go-live
#: reconciler on every one of them).
CLIENT_ROLES = frozenset({
    "laptop", "chromebook", "desktop", "standalone-thin", "standalone-thick",
    "standalone-unaffiliated", "rpi5-desktop", "jetson-desktop", "frite",
    "orangepi5", "orangepi4-lts",
})
#: Platforms whose images bake no go-live driver.
NON_GOLIVE_PLATFORMS = ("frite", "jetson", "orangepi")

#: Non-interactive ssh: a dead port or a password prompt fails fast instead of
#: hanging a worker thread; no host-key chatter in a streamed plan.
_BATCH_OPTIONS = ("-o", "BatchMode=yes", "-o", "ConnectTimeout=15", "-o", "LogLevel=ERROR")

#: Slirp (QEMU user networking) and the emulated mesh's L2: addresses no registrar
#: record can point at.
_PRIVATE_INGRESS_NETS = (ipaddress.ip_network("10.0.2.0/24"),
                         ipaddress.ip_network("10.77.0.0/24"))

#: Funnel is a feature of Tailscale's HOSTED control plane. Self-hosted headscale does
#: not implement it, and an emulated mesh is coordinated by its own headscale by
#: construction (tests/qemu/docker-entrypoint.sh enables it on pki/generic/omnibus and
#: points every other node at it), so on an emulated target nothing could ever publish.
HEADSCALE_REFUSED_PROVIDERS = frozenset({"tailscale-funnel"})
HEADSCALE_REFUSED_MECHANISMS = frozenset({"funnel"})

#: Shown on the Flip step for every emulated target. It says what a boot starts from,
#: never what posture that is: Status reads the device itself (:func:`read_posture`).
EPHEMERAL_NOTE = ("this posture lives on this run's disk only: the next boot starts "
                  "again from the golden image (in whatever posture it bakes) or from a "
                  "Save (in the posture it was saved in) — Save the device to keep it; "
                  "Status reads the posture from the device itself")


# ── the target ──────────────────────────────────────────────────────────────────────
@dataclass(frozen=True)
class GoLiveTarget:
    """One place a go-live verb can run. For an emulated kind, ``ssh_base_argv`` is
    ``ssh <options> user@127.0.0.1`` with NO remote command; every verb appends one."""
    kind: str = KIND_LOCAL
    label: str = LOCAL_LABEL
    ssh_base_argv: tuple[str, ...] = ()
    running: bool = True
    platform: str = ""
    role: str = ""
    started_at: str = ""
    ssh_port: int = 0
    ssh_key: str = ""
    ssh_user: str = ""
    work_dir: str = ""
    #: The HOST path of the save this boot of the device started from ("" = its
    #: golden image) — the record's ``boot_save`` (qemu_devices.Device).
    boot_save: str = ""

    @property
    def is_local(self) -> bool:
        return self.kind == KIND_LOCAL

    @property
    def is_remote(self) -> bool:
        return not self.is_local

    @property
    def ssh_options(self) -> tuple[str, ...]:
        """The options between ``ssh`` and the destination."""
        return tuple(self.ssh_base_argv[1:-1])

    @property
    def destination(self) -> str:
        return self.ssh_base_argv[-1] if self.ssh_base_argv else ""


def local_target() -> GoLiveTarget:
    return GoLiveTarget(kind=KIND_LOCAL, label=LOCAL_LABEL)


def target_from_device(dev: qemu_devices.Device, work_dir: str = "") -> GoLiveTarget:
    """A docker-lane keep-alive record. The base argv is qemu_devices.ssh_argv's own
    (the same key, loopback port and throwaway host-key options as the device's login
    button), as the record's always-present wheel user.

    The guest host key is NOT pinned (StrictHostKeyChecking=no): the keep-alive record
    carries no host key yet. Pinning needs the harness to record the guest's key at
    boot (ssh-keyscan of the loopback port) and ssh_argv to use it with
    StrictHostKeyChecking=yes — a follow-up across tests/qemu and qemu_devices."""
    base = qemu_devices.ssh_argv(dev, dev.ssh_user) if dev.ssh_user else ()
    return GoLiveTarget(
        kind=KIND_DOCKER, label=dev.label, ssh_base_argv=tuple(base),
        running=dev.is_running, platform=dev.platform, role=dev.role,
        started_at=dev.started_at, ssh_port=dev.ssh_host_port, ssh_key=dev.ssh_key,
        ssh_user=dev.ssh_user, work_dir=work_dir, boot_save=dev.boot_save)


def target_from_whpx(rec: dict, work_dir: str = "") -> GoLiveTarget:
    """A QEMU-for-Windows record (``qemu_windows.running``). Today those records carry
    ``ssh_port`` but no ``ssh_key``/``ssh_user``, and :func:`refusal` says so; once
    the Windows side records them, the same ssh-only path works there."""
    try:
        port = int(rec.get("ssh_port") or 0)
    except (TypeError, ValueError):
        port = 0
    key = str(rec.get("ssh_key") or "")
    user = str(rec.get("ssh_user") or "")
    base: tuple[str, ...] = ()
    if key and user:
        base = ("ssh", "-i", key, "-p", str(port), "-o", "StrictHostKeyChecking=no",
                "-o", "UserKnownHostsFile=" + os.devnull, f"{user}@127.0.0.1")
    return GoLiveTarget(
        kind=KIND_WHPX, label=str(rec.get("label") or ""), ssh_base_argv=base,
        running=True, platform=str(rec.get("platform") or "x86"),
        role=str(rec.get("role") or ""), started_at=str(rec.get("started_at") or ""),
        ssh_port=port, ssh_key=key, ssh_user=user, work_dir=work_dir)


def targets(work_dir: str, *, include_local: bool = True,
            discover: Callable[[str], list] = qemu_devices.discover_devices,
            whpx_running: Callable[[str], list] = qemu_windows.running
            ) -> list[GoLiveTarget]:
    """LOCAL first, then every docker-lane device (newest first, stopped ones too so
    the picker can say WHY they are refused), then every running WHPX device."""
    out: list[GoLiveTarget] = [local_target()] if include_local else []
    out += [target_from_device(d, work_dir) for d in discover(work_dir)]
    try:
        live = whpx_running(work_dir)
    except OSError:
        live = []
    out += [target_from_whpx(r, work_dir) for r in live if r.get("label")]
    return out


def find_target(rows: list[GoLiveTarget], label: str) -> GoLiveTarget | None:
    if label in ("", "local", LOCAL_LABEL):
        return next((t for t in rows if t.is_local), None)
    return next((t for t in rows if t.label == label), None)


def _binding(t: GoLiveTarget) -> tuple:
    return (t.kind, t.label, t.ssh_port, t.started_at, t.running, t.ssh_base_argv)


def same_binding(a: GoLiveTarget, b: GoLiveTarget) -> bool:
    """True when ``a`` and ``b`` are the same BOOT of the same device over the same ssh
    channel (port, key, user), not merely the same label. A keep-alive device that
    restarts comes back on the first free port of the harness's range with a new
    started_at, and a stopped device's port can be handed to another device
    (tests/qemu/run-qemu-docker.sh claim_port) — so a label alone does not say where
    an ssh would land."""
    return _binding(a) == _binding(b)


def rebind(target: GoLiveTarget, rows: list[GoLiveTarget]) -> GoLiveTarget:
    """``target``'s device as ``rows`` (a fresh :func:`targets` read) says it is NOW.
    LOCAL is returned as it is. A device whose record is gone is returned NOT running,
    so :func:`refusal` turns it away instead of anything being sent to its old port."""
    if target.is_local:
        return target
    fresh = next((r for r in rows if (r.kind, r.label) == (target.kind, target.label)),
                 None)
    if fresh is None:
        return dataclasses.replace(target, running=False)
    if target.work_dir and not fresh.work_dir:
        fresh = dataclasses.replace(fresh, work_dir=target.work_dir)
    return fresh


def binding_change(target: GoLiveTarget, rows: list[GoLiveTarget]) -> str:
    """"" while ``target`` is still the device's current record; otherwise the sentence
    that says what changed since it was picked (stopped, or restarted on another port
    or boot) — the faces refuse to run or hand over a commit/rollback until the device
    is picked again from a re-scan."""
    if target.is_local:
        return ""
    fresh = rebind(target, rows)
    if same_binding(fresh, target):
        return ""
    name = target.label or "the device"
    if not fresh.running:
        return (f"{name} has stopped since it was picked (it was on ssh port "
                f"{target.ssh_port}, which another device may now hold) — re-scan the "
                "devices and pick it again before anything is sent to it.")
    moved = []
    if fresh.ssh_port != target.ssh_port:
        moved.append(f"ssh port {target.ssh_port} -> {fresh.ssh_port}")
    if fresh.started_at != target.started_at:
        moved.append(f"booted again at {fresh.started_at or '?'}")
    return (f"{name} restarted since it was picked ({'; '.join(moved) or 'its record changed'})"
            " — what was read from it belongs to the earlier boot, not this one. Re-scan "
            "the devices and pick it again before the flip.")


# ── refusals ────────────────────────────────────────────────────────────────────────
def _which_sbin(name: str) -> str | None:
    """``command -v`` plus the sbin directories a desktop user's PATH often lacks."""
    found = shutil.which(name)
    if found:
        return found
    for d in ("/usr/local/sbin", "/usr/sbin", "/sbin"):
        cand = os.path.join(d, name)
        if os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    return None


def local_node_refusal(etc_dir: str | None = None,
                       which: Callable[[str], str | None] | None = None) -> str:
    """B1: why THIS host cannot commit, "" when it is a HugMesh node. The driver's own
    ``GL_ETC_HUGMESH`` seam names the /etc/hugmesh it reads."""
    which = which or _which_sbin
    etc = etc_dir or os.environ.get("GL_ETC_HUGMESH", "/etc/hugmesh")
    missing = []
    if not os.path.exists(os.path.join(etc, "release-state")):
        missing.append(f"{os.path.join(etc, 'release-state')} does not exist")
    if not which("hugmesh-firewall-reconcile"):
        missing.append("hugmesh-firewall-reconcile is not installed")
    if not missing:
        return ""
    return ("this host is not a HugMesh node — pick a device (" + "; ".join(missing)
            + "). A commit here would write a marker nothing enforces.")


def _host_os() -> str:
    """``os.name`` — a seam, so the shared logic's tests run the same on every OS."""
    return os.name


def refusal(target: GoLiveTarget, osname: str | None = None) -> str:
    """Why no go-live verb can run against ``target``, "" when one can. LOCAL is never
    refused here (plan/status/list work as a preview anywhere); its commit has its own
    refusal, :func:`local_node_refusal`. ``osname`` is ``os.name`` unless a test
    passes another."""
    if target.is_local:
        return ""
    name = target.label or "(unnamed device)"
    if target.kind == KIND_DOCKER and (osname or _host_os()) == "nt":
        return (f"{name} is a docker-lane device, and that lane runs bash scripts this "
                "Windows build of the Studio cannot run — go live from the Studio inside "
                "WSL2, or start the device under QEMU for Windows.")
    if target.kind == KIND_WHPX and not (target.ssh_key and target.ssh_user):
        return (f"{name} runs under QEMU for Windows, whose device record carries no ssh "
                "key or user yet, so there is no channel to its go-live driver. The "
                "Windows side must record ssh_key and ssh_user when it starts a device.")
    if not target.running:
        return (f"{name} is not running — there is no channel to a stopped device. "
                "Start it on the Mesh emulation page first.")
    if target.ssh_port <= 0:
        return (f"{name} published no ssh port — there is no channel to the device "
                "(its keep-alive run did not forward ssh).")
    if not target.ssh_key or not target.ssh_user or not target.ssh_base_argv:
        return (f"{name}'s record names no ssh key or user — there is no channel to "
                "the device.")
    plat = (target.platform or "").lower()
    if target.role in CLIENT_ROLES:
        return (f"{name} is a {target.role} client — client images bake no go-live "
                "driver; go-live runs on a server node (pki, backend, frontend, omnibus).")
    if any(plat.startswith(p) for p in NON_GOLIVE_PLATFORMS):
        return (f"{name} runs on {target.platform}, whose images bake no go-live driver — "
                "not a go-live server node.")
    return ""


# ── ssh argv ────────────────────────────────────────────────────────────────────────
def remote_argv(target: GoLiveTarget, remote: list[str], *, tty: bool = False) -> list[str]:
    """``ssh <options> [-t | batch options] user@127.0.0.1 '<remote, shell-quoted>'``.
    The remote command is ONE argv element, parsed by the guest's login shell, so it is
    ``shlex.join``-ed here and nowhere else. ``tty`` (commit/rollback) asks for a pty
    and leaves BatchMode off (LogLevel=ERROR still keeps ssh's own "Permanently
    added" line off the confirm prompt); every other verb is non-interactive."""
    if not target.ssh_base_argv:
        raise ValueError(refusal(target) or f"{target.label}: no ssh channel")
    mode = ("-t", "-o", "LogLevel=ERROR") if tty else _BATCH_OPTIONS
    return ["ssh", *target.ssh_options, *mode, target.destination, shlex.join(remote)]


def _flags(opts) -> list[str]:
    return list(opts.to_cli_args(include_token_file=True))


def headscale_refusal(target: GoLiveTarget, provider: str = "", mechanism: str = "") -> str:
    """Why ``provider`` (or a ``mechanism``) cannot run on ``target`` because the mesh
    is coordinated by headscale; "" when it can. LOCAL is never refused here: a real
    node may sit on a Tailscale-hosted tailnet, and its own driver's plan says so."""
    if target.is_local:
        return ""
    if (provider not in HEADSCALE_REFUSED_PROVIDERS
            and mechanism not in HEADSCALE_REFUSED_MECHANISMS):
        return ""
    return (f"{provider or 'Funnel'} is refused on {target.label or 'this device'}: "
            "Funnel is a feature of Tailscale's hosted control plane, and an emulated "
            "mesh is coordinated by its own self-hosted headscale, which does not "
            "implement Funnel — nothing would ever be published. Pick tor-onion, or a "
            "rehearsal provider such as byo-domain.")


def _check_inputs(target: GoLiveTarget, opts) -> str:
    if getattr(opts, "provider", "") and not _PROVIDER_RE.match(opts.provider):
        return f"provider '{opts.provider}' is not a provider id ([a-z0-9-])."
    why = headscale_refusal(target, getattr(opts, "provider", ""))
    if why:
        return why
    dom = getattr(opts, "domain", "")
    if dom and not _DOMAIN_RE.match(dom):
        return f"domain '{dom}' is not a lowercase DNS name."
    return refuse_private_ingress(getattr(opts, "ingress_ip", ""))


def remote_verb_argv(target: GoLiveTarget, verb: str, opts=None) -> list[str]:
    """``ssh … sudo -n hugmesh-go-live <verb> <flags>`` for the non-interactive verbs.
    Flags come from ``GoLiveOptions.to_cli_args`` (so all three front-ends spell them
    alike). commit/rollback are NOT built here: they need the pty (:func:`commit_argv`)."""
    if verb in ("commit", "rollback"):
        raise ValueError(f"{verb} needs a terminal — use commit_argv/rollback_argv")
    flags = _flags(opts) if opts is not None else []
    if "-y" in flags or "--yes" in flags:            # unreachable today; kept as a law
        raise ValueError("refusing -y/--yes: the TTY confirmation is the boundary")
    return remote_argv(target, ["sudo", "-n", GUEST_DRIVER, verb, *flags])


def commit_argv(target: GoLiveTarget, provider: str, domain: str = "",
                persist_public: bool = False) -> list[str]:
    """``ssh -t … sudo hugmesh-go-live commit --provider P [--domain D]
    [--persist-public]`` — NO -y: the guest driver's confirm runs on the ssh pty."""
    if not provider or not _PROVIDER_RE.match(provider):
        raise ValueError(f"provider '{provider}' is not a provider id")
    if domain and not _DOMAIN_RE.match(domain):
        raise ValueError(f"domain '{domain}' is not a lowercase DNS name")
    why = headscale_refusal(target, provider)
    if why:
        raise ValueError(why)
    remote = ["sudo", GUEST_DRIVER, "commit", "--provider", provider]
    if domain:
        remote += ["--domain", domain]
    if persist_public:
        remote += ["--persist-public"]
    return remote_argv(target, remote, tty=True)


def rollback_argv(target: GoLiveTarget, revert_release_state: bool = False) -> list[str]:
    """``ssh -t … sudo hugmesh-go-live rollback [--revert-release-state]`` — NO -y."""
    remote = ["sudo", GUEST_DRIVER, "rollback"]
    if revert_release_state:
        remote += ["--revert-release-state"]
    return remote_argv(target, remote, tty=True)


# ── probe (B2 + B8) ─────────────────────────────────────────────────────────────────
#: POSIX sh only (the guest's /bin/sh), sentinel-delimited so a file with no trailing
#: newline, or one that is absent, cannot run into the next section.
_PROBE_SCRIPT = (
    "echo ::driver; command -v " + GUEST_DRIVER + " || true; "
    "echo ::cluster-domain; cat /etc/hugmesh/cluster-domain 2>/dev/null; echo; "
    "echo ::domains; cat /etc/hugmesh/domains 2>/dev/null; echo; "
    "echo ::release-state; cat /etc/hugmesh/release-state 2>/dev/null; echo; "
    "for f in /var/lib/hugmesh/tor/hostname /var/lib/hugmesh/tor/*.hostname; do "
    "[ -f \"$f\" ] || continue; echo \"::tor ${f##*/}\"; cat \"$f\" 2>/dev/null; echo; "
    "done; echo ::end")


@dataclass
class Probe:
    """What one read-only ssh round trip learned about a guest."""
    ok: bool = False                 # the ssh call itself worked and reached ::end
    error: str = ""                  # why not, when not
    driver: str = ""                 # `command -v hugmesh-go-live`, "" when absent
    cluster_domain: str = ""
    domains_text: str = ""           # /etc/hugmesh/domains, verbatim ("" when absent)
    release_state: str = ""
    onion_files: dict[str, str] = field(default_factory=dict)   # name -> content

    @property
    def has_driver(self) -> bool:
        return bool(self.driver)


def probe_argv(target: GoLiveTarget) -> list[str]:
    return remote_argv(target, ["sudo", "-n", "sh", "-c", _PROBE_SCRIPT])


def parse_probe(text: str) -> Probe:
    p = Probe()
    section = ""
    buf: dict[str, list[str]] = {}
    for raw in (text or "").splitlines():
        line = raw.rstrip("\r")
        if line.startswith("::"):
            section = line[2:].strip()
            if section == "end":
                p.ok = True
                break
            buf.setdefault(section, [])
            continue
        if section:
            buf.setdefault(section, []).append(line)
    words = [w.strip() for w in buf.get("driver", []) if w.strip()]
    p.driver = words[0] if words and words[0].startswith("/") else ""
    p.cluster_domain = "".join("".join(buf.get("cluster-domain", [])).split())
    p.domains_text = "\n".join(ln for ln in buf.get("domains", []) if ln.strip())
    p.release_state = "".join("".join(buf.get("release-state", [])).split())
    for sec, lines in buf.items():
        if sec.startswith("tor "):
            name = sec[4:].strip()
            if name == "hostname" or (name.endswith(".hostname") and "/" not in name):
                p.onion_files[name] = "\n".join(ln for ln in lines if ln.strip())
    if not p.ok:
        p.error = "the probe's answer was cut short"
    return p


def probe(target: GoLiveTarget, run=None, timeout: float = 45) -> Probe:
    """Run :func:`probe_argv` once; a failed ssh call is a Probe with ``error`` set."""
    run = run or subprocess.run
    why = refusal(target)
    if why:
        return Probe(error=why)
    try:
        r = run(probe_argv(target), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, timeout=timeout)
    except (OSError, subprocess.SubprocessError) as e:
        return Probe(error=f"ssh to {target.label} failed: {e}")
    if r.returncode != 0:
        err = (r.stderr or "").strip().splitlines()
        return Probe(error=f"ssh to {target.label} failed (exit {r.returncode})"
                     + (f": {err[-1]}" if err else ""))
    return parse_probe(r.stdout or "")


def probe_refusal(target: GoLiveTarget, p: Probe) -> str:
    """B8 (and an unreachable guest) as a sentence; "" when the guest can go live."""
    if p.error:
        return f"{target.label}: cannot read the device — {p.error}"
    if not p.has_driver:
        return (f"{target.label} has no go-live driver ({GUEST_DRIVER} is not installed "
                "in the image) — not a go-live server node.")
    return ""


# ── secret staging ──────────────────────────────────────────────────────────────────
_STAGE_SCRIPT = ("umask 077; t=$(mktemp " + TOKEN_PREFIX + "XXXXXX) && cat >\"$t\" "
                 "&& echo \"$t\"")


def stage_token_remote(target: GoLiveTarget, secret: str, run=None,
                       timeout: float = 45) -> str:
    """Write ``secret`` into a fresh 0600 guest file over ssh STDIN and return its
    guest path. The value is never on any argv (host or guest). Raises
    ``RuntimeError`` when the guest did not hand back a path of the expected shape."""
    run = run or subprocess.run
    argv = remote_argv(target, ["sudo", "-n", "sh", "-c", _STAGE_SCRIPT])
    r = run(argv, input=secret.rstrip("\n") + "\n", stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, text=True, timeout=timeout)
    path = (r.stdout or "").strip().splitlines()
    path = path[-1].strip() if path else ""
    if r.returncode != 0 or not _TOKEN_PATH_RE.match(path):
        raise RuntimeError(f"could not stage the token on {target.label} (exit "
                           f"{r.returncode}); nothing was written to argv")
    return path


def remove_token_remote(target: GoLiveTarget, guest_path: str, run=None,
                        timeout: float = 45) -> bool:
    run = run or subprocess.run
    if not _TOKEN_PATH_RE.match(guest_path or ""):
        return False
    try:
        r = run(remote_argv(target, ["sudo", "-n", "rm", "-f", "--", guest_path]),
                stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL, timeout=timeout)
    except (OSError, subprocess.SubprocessError):
        return False
    return r.returncode == 0


# ── plan artifacts ──────────────────────────────────────────────────────────────────
def guest_out_dir(stamp: str = "") -> str:
    stamp = stamp or time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
    return f"{GUEST_OUT_ROOT}/studio-{stamp}"


def artifacts_dir(work_dir: str, label: str) -> str:
    return os.path.join(work_dir, "golive", qemu_devices.safe_label(label))


def fetch_artifacts(target: GoLiveTarget, guest_dir: str, local_dir: str,
                    run=None, timeout: float = 45) -> list[str]:
    """Copy every regular file of ``guest_dir`` into ``local_dir`` with ``ssh … cat``
    and return the local paths. Names are checked before they are used: one path
    component, no dot-file — a name the guest invents cannot write outside
    ``local_dir``. Files a previous run left in ``local_dir`` are removed first."""
    run = run or subprocess.run
    if not guest_dir.startswith(GUEST_OUT_ROOT + "/") or ".." in guest_dir:
        raise ValueError(f"refusing to read {guest_dir}: not under {GUEST_OUT_ROOT}")
    listing = run(remote_argv(target, [
        "sudo", "-n", "sh", "-c",
        'cd "$1" && for f in *; do [ -f "$f" ] && printf "%s\\n" "$f"; done; true',
        "sh", guest_dir]),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        text=True, timeout=timeout)
    if listing.returncode != 0:
        raise RuntimeError(f"could not list {guest_dir} on {target.label}")
    os.makedirs(local_dir, exist_ok=True)
    for old in os.listdir(local_dir):
        p = os.path.join(local_dir, old)
        if os.path.isfile(p) and not os.path.islink(p):
            os.remove(p)
    got: list[str] = []
    for name in (listing.stdout or "").splitlines():
        name = name.strip()
        if not _ARTIFACT_NAME_RE.match(name):
            continue
        r = run(remote_argv(target, ["sudo", "-n", "cat", "--", f"{guest_dir}/{name}"]),
                stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, timeout=timeout)
        if r.returncode != 0:
            continue
        dest = os.path.join(local_dir, name)
        with open(dest, "wb") as fh:
            fh.write(r.stdout if isinstance(r.stdout, bytes) else
                     (r.stdout or "").encode())
        got.append(dest)
    return got


def run_plan(target: GoLiveTarget, opts, *, on_line: Callable[[str], None] | None = None,
             work_dir: str = "", popen=None, run=None,
             cancel=None, on_proc: Callable | None = None, stamp: str = "") -> int:
    """``plan`` on an emulated target: stage the token (if ``opts.token_file`` names a
    HOST file, its content goes over ssh stdin), stream the guest driver's plan, delete
    the guest token file whatever happened, copy the artifacts back. Returns the exit
    code (2 = refused before anything ran)."""
    run = run or subprocess.run
    popen = popen or subprocess.Popen
    say = on_line or (lambda _l: None)
    why = refusal(target) or _check_inputs(target, opts)
    if why:
        say(f"!! {why}")
        return 2
    secret = ""
    if opts.token_file:
        try:
            with open(opts.token_file, encoding="utf-8") as fh:
                secret = fh.read()
        except OSError as e:
            say(f"!! cannot read the token file: {e.strerror or e}")
            return 2
    out_dir = guest_out_dir(stamp)
    remote_opts = dataclasses.replace(opts, out_dir=out_dir, keys_dir="", token_file="")
    guest_tok = ""
    rc = 1
    try:
        if secret.strip():
            guest_tok = stage_token_remote(target, secret, run=run)
            remote_opts = dataclasses.replace(remote_opts, token_file=guest_tok)
        proc = popen(remote_verb_argv(target, "plan", remote_opts),
                     stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                     stderr=subprocess.STDOUT, text=True, bufsize=1)
        if on_proc:
            on_proc(proc)
        for line in proc.stdout:
            say(line.rstrip("\n"))
            if cancel is not None and cancel.is_set():
                proc.terminate()
                break
        rc = proc.wait()
    except (OSError, RuntimeError, subprocess.SubprocessError) as e:
        say(f"!! {e}")
        rc = rc or 1
    finally:
        secret = ""
        if guest_tok and not remove_token_remote(target, guest_tok, run=run):
            say(f"!! could not delete the staged token {guest_tok} on {target.label} — "
                "it is root-only (0600) and goes with the device's overlay")
    if rc == 0 and work_dir:
        local = artifacts_dir(work_dir, target.label)
        try:
            got = fetch_artifacts(target, out_dir, local, run=run)
            say(f"[studio] copied {len(got)} plan artifact(s) from {target.label} to "
                f"{local}")
        except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as e:
            say(f"!! could not copy the plan artifacts back: {e}")
    return rc


# ── terminals ───────────────────────────────────────────────────────────────────────
@dataclass
class TerminalSpec:
    """How to open ``argv`` for the operator: Popen(argv, creationflags=…)."""
    argv: list[str]
    creationflags: int = 0
    how: str = ""                    # "linux" | "wsl-wt" | "wsl-start" | "nt"


_HOLD = '; rc=$?; echo; read -r -p "press Enter to close..." _; exit "$rc"'


def _wt_escape(arg: str) -> str:
    # wt.exe splits its command line on ';' (its own sub-command separator), quoted
    # or not; a literal one is spelled '\;'.
    return arg.replace(";", "\\;")


def terminal_spec(cmd_argv: list[str], *, osname: str | None = None,
                  is_wsl: bool | None = None, wsl_distro: str | None = None,
                  has_interop: bool | None = None,
                  which: Callable[[str], str | None] | None = None,
                  terminals=None) -> TerminalSpec | None:
    """Open ``cmd_argv`` (an ``ssh -t …``) in a terminal, or None when none can be
    opened (the caller then shows the exact command to copy).

    * native Windows: the argv itself in a NEW console (Windows OpenSSH), as the Mesh
      emulation page's WHPX login does;
    * Linux and WSL2 with a Linux terminal emulator: the shared cloud_deploy.TERMINALS
      list, held open at the end so the driver's result stays readable;
    * WSL2 without one: Windows Terminal (``cmd.exe /c start "" wt.exe wsl.exe -d
      <distro> -- …``), else a plain console (``cmd.exe /c start "" wsl.exe …``) —
      only when WSL interop is on."""
    from .cloud_deploy import TERMINALS
    osname = osname or _host_os()
    which = which or shutil.which
    if osname == "nt":
        return TerminalSpec(list(cmd_argv), getattr(subprocess, "CREATE_NEW_CONSOLE", 0x10),
                            "nt")
    for binary, exec_args in (terminals if terminals is not None else TERMINALS):
        if which(binary):
            script = shlex.join(cmd_argv) + _HOLD
            return TerminalSpec([binary, *exec_args, "bash", "-c", script], 0, "linux")
    if is_wsl is None:
        from .platform_info import detect_wsl
        is_wsl = detect_wsl()[0]
    if not is_wsl:
        return None
    if has_interop is None:
        has_interop = bool(os.environ.get("WSL_INTEROP"))
    distro = wsl_distro if wsl_distro is not None else os.environ.get("WSL_DISTRO_NAME", "")
    if not has_interop or not which("cmd.exe"):
        return None
    inner = ["wsl.exe", *(["-d", distro] if distro else []), "--", *cmd_argv]
    if which("wt.exe"):
        return TerminalSpec(["cmd.exe", "/c", "start", "", "wt.exe",
                             *[_wt_escape(a) for a in inner]], 0, "wsl-wt")
    return TerminalSpec(["cmd.exe", "/c", "start", "", *inner], 0, "wsl-start")


# ── the host-side journal ───────────────────────────────────────────────────────────
def journal_path(work_dir: str, label: str) -> str:
    return os.path.join(work_dir, "golive", qemu_devices.safe_label(label) + ".json")


_JOURNAL_KEYS = ("label", "kind", "action", "provider", "domain", "started_at", "at",
                 "confirmed")


def write_journal(target: GoLiveTarget, action: str, provider: str = "",
                  domain: str = "", *, confirmed: bool | None = None,
                  rc: int | None = None, now: str = "") -> str:
    """Record what this host asked the device to do. Holds NO secret: provider,
    domain, the device's started_at, the UTC time and the exit code only.

    ``rc`` is the exit code of a commit/rollback run in this terminal (the CLI). A
    non-zero ``rc`` — the device's driver refused, the operator declined the confirm,
    or ssh failed — changed NOTHING on the device, so it never becomes the recorded
    action: it is kept beside the last action that did go through (or was launched)
    under ``refused``, and :func:`journal_status` says it did not go through.
    ``confirmed`` is None for a commit the GUI only LAUNCHED in a detached terminal."""
    path = journal_path(target.work_dir, target.label)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    at = now or time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if rc is not None and rc != 0:
        prior = read_journal(target.work_dir, target.label) or {}
        rec = {k: prior.get(k, "") for k in _JOURNAL_KEYS}
        rec.update(label=target.label, kind=target.kind,
                   confirmed=prior.get("confirmed") if prior.get("action") else None,
                   rc=prior.get("rc"),
                   refused={"action": action, "provider": provider, "domain": domain,
                            "started_at": target.started_at, "at": at, "rc": rc})
    else:
        if rc is not None:
            confirmed = True
        rec = {"label": target.label, "kind": target.kind, "action": action,
               "provider": provider, "domain": domain, "started_at": target.started_at,
               "at": at, "confirmed": confirmed, "rc": rc, "refused": None}
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8") as fh:
        json.dump(rec, fh, indent=1)
    os.replace(tmp, path)
    return path


def read_journal(work_dir: str, label: str) -> dict | None:
    try:
        with open(journal_path(work_dir, label), encoding="utf-8") as fh:
            rec = json.load(fh)
    except (OSError, ValueError):
        return None
    return rec if isinstance(rec, dict) else None


def earlier_boot(journal: dict | None, target: GoLiveTarget) -> bool:
    """True when the journal was written during an EARLIER boot of this device (its
    started_at is not the live record's). A fact about the record ONLY: the boot since
    may have come from the golden image or from a save taken while it was public, so
    this says nothing about the posture — :func:`read_posture` asks the device."""
    if not journal or not target.is_remote:
        return False
    then = str(journal.get("started_at") or "")
    return bool(then) and then != (target.started_at or "")


def journal_status(work_dir: str, target: GoLiveTarget) -> str:
    j = read_journal(work_dir, target.label)
    if not j:
        return ""
    said: list[str] = []
    act = j.get("action") or ""
    if act:
        if j.get("confirmed") is None:
            # The GUI's terminal is detached: this host knows the commit was LAUNCHED,
            # not whether the operator answered y on the device's TTY.
            head = (f"{act} launched from this host (the confirmation happened on the "
                    "device's TTY — its status says whether it went through)")
        elif j["confirmed"]:
            head = f"last {act} from this host"
        else:
            # A journal written before refusals were kept apart: the attempt failed.
            head = f"last {act} attempt from this host did NOT go through"
        what = (f"{head}: {j.get('provider') or '-'} {j.get('domain') or ''} at "
                f"{j.get('at', '?')}").replace("  ", " ")
        if earlier_boot(j, target):
            # WHEN, never WHAT: the posture now is the device's own reading.
            what += (f" — during an earlier boot (the device booted again at "
                     f"{target.started_at or '?'})")
        said.append(what)
    ref = j.get("refused")
    if isinstance(ref, dict) and ref.get("action"):
        said.append((f"{ref['action']} attempted from this host did NOT go through (exit "
                     f"{ref.get('rc', '?')}: refused by the device, declined at its "
                     f"confirm, or ssh failed) — nothing changed: "
                     f"{ref.get('provider') or '-'} {ref.get('domain') or ''} at "
                     f"{ref.get('at', '?')}").replace("  ", " "))
    return "; ".join(said)


# ── the posture, read from the device (never inferred) ─────────────────────────────
POSTURE_PUBLIC = "public"
POSTURE_INTERNAL = "internal"
POSTURE_MIXED = "mixed"
POSTURE_UNKNOWN = "unknown"

#: The reconcile-owned netfilter table (specs/usr/sbin/hugmesh-firewall-reconcile).
RELEASE_GATE_TABLE = "hugmesh_release_gate"

#: ONE read-only round trip, BOTH witnesses — the same script the go-live proof lane
#: (tests/qemu/golive-emulated.sh) and the live prover's witness run: what the driver
#: says (``effective posture:``) and what netfilter enforces (the table, then nft's
#: exit status). ``@@end@@`` says the answer was not cut short.
_POSTURE_SCRIPT = (f"{GUEST_DRIVER} status; echo @@nft@@; "
                   f"nft list table inet {RELEASE_GATE_TABLE}; echo @@nftrc=$?@@; "
                   "echo @@end@@")
_ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
_STATUS_POSTURE_RE = re.compile(r"^effective posture:[ \t]*([a-z]*)")
#: "Loaded" is nft's exit 0 AND the table's own header at the START of a line. When the
#: table is absent, real nft exits 1 and echoes ``list table inet hugmesh_release_gate``
#: — an unanchored match read that MISSING table as a loaded one with no drop rule,
#: i.e. public (the FG3 lane's finding, kept here).
_NFT_HEADER_RE = re.compile(r"^table inet " + RELEASE_GATE_TABLE + r" \{")
_NFT_DROP_RE = re.compile(r"tcp dport \{ ?80, ?443 ?\} drop")
_NFT_RC_RE = re.compile(r"^@@nftrc=([0-9]+)@@$")


@dataclass(frozen=True)
class Posture:
    """What the device itself says its posture is: the driver's ``status`` and the nft
    release gate, each public | internal | unknown. ``reachable`` is False when no
    answer came back (no channel, ssh failed); ``asked`` is False when nothing was
    sent at all (the picked binding is stale, say). ``at`` is when it was read (UTC)."""
    status: str = POSTURE_UNKNOWN
    nft: str = POSTURE_UNKNOWN
    reachable: bool = False
    asked: bool = True
    error: str = ""
    at: str = ""

    @property
    def verdict(self) -> str:
        """public | internal when BOTH witnesses say it; unknown when neither could be
        read; mixed otherwise (one says public, the other internal or nothing)."""
        if not self.reachable:
            return POSTURE_UNKNOWN
        if self.status == self.nft and self.status in (POSTURE_PUBLIC, POSTURE_INTERNAL):
            return self.status
        if self.status == POSTURE_UNKNOWN and self.nft == POSTURE_UNKNOWN:
            return POSTURE_UNKNOWN
        return POSTURE_MIXED

    def _why_unknown(self) -> str:
        if not self.asked:
            return "not read"
        if not self.reachable:
            return "device not reachable"
        return "the device answered, but neither witness could be read"

    def phrase(self) -> str:
        """Short: ``PUBLIC``, ``INTERNAL``, ``MIXED (…)`` or ``unknown (why)`` — what a
        save's manifest is quoted as ("booted from a save taken while PUBLIC")."""
        v = self.verdict
        if v in (POSTURE_PUBLIC, POSTURE_INTERNAL):
            return v.upper()
        if v == POSTURE_MIXED:
            return (f"MIXED (hugmesh-go-live status {self.status}, the nft release gate "
                    f"{self.nft})")
        return f"unknown ({self._why_unknown()})"

    def sentence(self) -> str:
        """The whole reading, for a face: both witnesses named, or why there is none."""
        v = self.verdict
        if v in (POSTURE_PUBLIC, POSTURE_INTERNAL):
            # the verdict and "both" first: a face's pane may be narrow
            return (f"{v.upper()} — both witnesses say {v} (hugmesh-go-live status; nft "
                    f"table inet {RELEASE_GATE_TABLE})")
        if v == POSTURE_MIXED:
            nft = (self.nft if self.nft != POSTURE_UNKNOWN else
                   f"unknown (table inet {RELEASE_GATE_TABLE} absent or unreadable)")
            said = (f"MIXED — hugmesh-go-live status says {self.status}, the nft release "
                    f"gate says {nft}")
            if POSTURE_UNKNOWN not in (self.status, self.nft):
                # both read, and they disagree: the reconcile has not caught up yet. An
                # unreadable witness (no table loaded, no driver) is not a lag, and
                # nothing promises it converges.
                said += ("; hugmesh-firewall-reconcile converges them at boot and every "
                         "60 s, so read it again in a minute")
            return said
        return (f"unknown ({self._why_unknown()})"
                + (f" — {self.error}" if self.error else ""))

    def as_record(self) -> dict:
        """Plain data (a save manifest's ``golive_posture``); ``posture`` is the verdict,
        written for a reader and recomputed from the witnesses on the way back in."""
        return {"posture": self.verdict, "status": self.status, "nft": self.nft,
                "reachable": self.reachable, "asked": self.asked, "error": self.error,
                "at": self.at}

    @classmethod
    def from_record(cls, rec: object) -> "Posture":
        if not isinstance(rec, dict):
            return cls(asked=False, error="no posture was recorded")
        known = (POSTURE_PUBLIC, POSTURE_INTERNAL, POSTURE_UNKNOWN)

        def word(key: str) -> str:
            w = str(rec.get(key) or "")
            return w if w in known else POSTURE_UNKNOWN
        return cls(status=word("status"), nft=word("nft"),
                   reachable=bool(rec.get("reachable")),
                   asked=bool(rec.get("asked", True)), error=str(rec.get("error") or ""),
                   at=str(rec.get("at") or ""))


def posture_argv(target: GoLiveTarget) -> list[str]:
    return remote_argv(target, ["sudo", "-n", "sh", "-c", _POSTURE_SCRIPT])


def parse_posture(text: str) -> tuple[str, str, bool]:
    """``(status, nft, complete)`` from :data:`_POSTURE_SCRIPT`'s stdout, by the proof
    lane's rules: status is the FIRST ``effective posture:`` line (public | internal,
    else unknown); nft is unknown unless nft exited 0 AND the anchored table header is
    there, then internal when the 80/443 drop rule is in the table and public when it
    is not. A missing ``@@nftrc`` marker is not an exit 0. ``complete`` is False when
    the answer stopped before ``@@end@@``."""
    status, seen_status = POSTURE_UNKNOWN, False
    nft_lines: list[str] = []
    rc = ""
    section = "status"
    complete = False
    for raw in (text or "").splitlines():
        line = _ANSI_RE.sub("", raw.rstrip("\r"))
        if line == "@@end@@":
            complete = True
            break
        if line == "@@nft@@":
            section = "nft"
            continue
        m = _NFT_RC_RE.match(line)
        if m:
            rc, section = m.group(1), "after"
            continue
        if section == "status" and not seen_status:
            m = _STATUS_POSTURE_RE.match(line)
            if m:
                seen_status = True
                if m.group(1) in (POSTURE_PUBLIC, POSTURE_INTERNAL):
                    status = m.group(1)
        elif section == "nft":
            nft_lines.append(line)
    if rc != "0" or not any(_NFT_HEADER_RE.match(ln) for ln in nft_lines):
        nft = POSTURE_UNKNOWN
    elif any(_NFT_DROP_RE.search(ln) for ln in nft_lines):
        nft = POSTURE_INTERNAL
    else:
        nft = POSTURE_PUBLIC
    return status, nft, complete


def utc_now() -> str:
    """Now, as every read time and journal entry here is written (UTC, to the second)."""
    return time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())


def read_posture(target: GoLiveTarget, run=None, timeout: float = 45,
                 now: str = "") -> Posture:
    """Ask the device for its posture: one read-only ssh round trip (:func:`posture_argv`).
    A refused target is never asked over ssh: one with no channel (stopped, no ssh port
    or key) reads ``unknown (device not reachable)``, one this host will not use (a
    client image, a docker-lane device from native Windows) ``unknown (not read)`` —
    each with the refusal as the reason. An ssh that failed (exit 255, a timeout) is
    not reachable either. Never raises."""
    run = run or subprocess.run
    at = now or utc_now()
    why = refusal(target)
    if why:
        channel = target.running and target.ssh_port > 0 and bool(target.ssh_base_argv)
        return Posture(asked=not channel, error=why, at=at)
    try:
        r = run(posture_argv(target), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
                stderr=subprocess.PIPE, text=True, timeout=timeout)
    except (OSError, ValueError, subprocess.SubprocessError) as e:
        return Posture(error=f"ssh to {target.label} failed: {e}", at=at)
    err = (r.stderr or "").strip().splitlines()
    tail = f": {err[-1]}" if err else ""
    if r.returncode == 255:
        # ssh's own exit status: the connection failed, the device was not asked
        return Posture(error=f"ssh to {target.label} failed (exit 255){tail}", at=at)
    status, nft, complete = parse_posture(r.stdout or "")
    error = "" if complete else f"the answer was cut short (exit {r.returncode}){tail}"
    return Posture(status=status, nft=nft, reachable=True, error=error, at=at)


def posture_phrase(rec: object) -> str:
    """A recorded posture (a save manifest's ``golive_posture``) in a few words."""
    if not isinstance(rec, dict):
        return "not recorded"
    return Posture.from_record(rec).phrase()


def save_origin(boot_save: str) -> str:
    """``boot_save`` (a saved disk) and the posture its save was TAKEN in — core.
    emulation_save reads it from the device right before pausing it and writes it in
    the set's manifest: "a save taken while PUBLIC (mesh-…, saved …)". A save with no
    manifest beside it, or one written before the posture was recorded, says so."""
    from .emulation_save import saved_device_entry   # lazy: it imports this module
    found = saved_device_entry(boot_save)
    name = str(found.get("session") or os.path.basename(os.path.dirname(boot_save))
               or boot_save)
    when = f", saved {found['created_at']}" if found.get("created_at") else ""
    rec = found.get("golive_posture")
    if not isinstance(rec, dict):
        return (f"a save ({name}{when}) whose go-live posture was not recorded when it "
                "was saved")
    saved = Posture.from_record(rec)
    was = "its posture was " if saved.verdict == POSTURE_UNKNOWN else ""
    return f"a save taken while {was}{saved.phrase()} ({name}{when})"


def boot_origin(target: GoLiveTarget) -> str:
    """"" for this host or a boot from the golden image; for a boot from a save, which
    save and the posture it was taken in (:func:`save_origin`). That is the posture
    the disk came up with — what the device says NOW is :func:`read_posture`'s. A
    record that is not running (stopped, or gone) has no boot to speak of: its line
    says *last* booted, and that it is not running."""
    if target.is_local or not target.boot_save:
        return ""
    origin = save_origin(target.boot_save)
    if not target.running:
        return f"last booted from {origin} — it is not running now"
    return f"booted from {origin}"


#: ``when`` for a reading printed as it is taken (CLI ``status``, a GUI pane's refresh).
READ_NOW = "now"


def posture_line(posture: Posture, when: str = READ_NOW) -> str:
    """The one posture line every face prints. A reading that was taken carries WHEN
    it was read: ``device posture now (read <UTC>): …`` where the face reads as it
    prints, ``device posture <when> (read <UTC>): …`` where it quotes an earlier
    reading (the TUI's plan screen: ``at the last s``). A reading with no time on it
    is never called ``now``. Nothing sent at all is ``device posture: unknown (not
    read) — why``: no ``now``, and no time, because there was no read."""
    if not posture.asked:
        return f"device posture: {posture.sentence()}"
    if not posture.at:
        return f"device posture (read time not recorded): {posture.sentence()}"
    return f"device posture {when} (read {posture.at}): {posture.sentence()}"


def device_report(work_dir: str, target: GoLiveTarget, posture: Posture, *,
                  when: str = READ_NOW) -> str:
    """What every face shows under an emulated device's status, one fact per line: the
    posture the device reported (``posture`` — :func:`read_posture`, or an unasked
    Posture when the face must not ssh) with its read time (:func:`posture_line`), the
    save it booted from, and the journal of what this host asked of it. "" for this
    host.

    ``target`` must be the device's CURRENT record: the save line and the journal's
    "earlier boot" test are both made against it. A face whose pick went stale passes
    the fresh record (:func:`rebind`), never the one it picked — that one's save and
    started_at belong to a boot that is over."""
    if target.is_local:
        return ""
    lines = [posture_line(posture, when)]
    origin = boot_origin(target)
    if origin:
        lines.append(origin)
    js = journal_status(work_dir, target)
    if js:
        lines.append(js)
    return "\n".join(lines)


# ── honest per-mechanism labels ─────────────────────────────────────────────────────
_REHEARSAL = ("REHEARSAL — the posture flips inside the emulated node, but nothing "
              "outside this workstation can reach it; the harness publishes loopback "
              "ssh only")


def mechanism_reachability(mechanism: str, target: GoLiveTarget,
                           provider: str = "") -> str:
    """What a mechanism really achieves from ``target``; "" for LOCAL (a real node)."""
    if target.is_local:
        return ""
    if mechanism in ("deeplink", "onion"):
        text = "can be really reachable (outbound only)"
        if provider == "cloudflare-tunnel":
            text += ("; but the tunnel token is consumed only by the PROD ExternalSecret, "
                     "so on an emulated mesh the tunnel will not start")
        return text
    if mechanism in ("files", "ddns", "instructions"):
        return _REHEARSAL
    if mechanism == "funnel":
        return "not on headscale"
    return ""


def refuse_private_ingress(ip: str) -> str:
    """A sentence when ``ip`` is a slirp or mesh-L2 address; "" otherwise."""
    if not ip:
        return ""
    try:
        addr = ipaddress.ip_address(ip.strip())
    except ValueError:
        return ""
    for net in _PRIVATE_INGRESS_NETS:
        if addr in net:
            return (f"ingress IP {ip} is inside {net} (the emulator's private network) — "
                    "no registrar record can point at it. Give the public address the "
                    "record should carry.")
    return ""


# ── CLI ─────────────────────────────────────────────────────────────────────────────
_REPO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), os.pardir,
                                          os.pardir, os.pardir))
VERBS = ("targets", "probe", "status", "list", "plan", "commit", "rollback")


def add_arguments(p: argparse.ArgumentParser) -> None:
    p.add_argument("verb", choices=VERBS)
    p.add_argument("--target", default="", metavar="LABEL",
                   help=f"device label (see `targets`); '{LOCAL_LABEL}' is this host")
    p.add_argument("--work", default="", help="the runner's --work dir "
                   "(default <generator-dir>/out/qemu-runs)")
    p.add_argument("--generator-dir", default=_REPO_ROOT)
    p.add_argument("--provider", default="")
    p.add_argument("--domain", default="")
    p.add_argument("--ingress-ip", default="")
    p.add_argument("--ingress-ipv6", default="")
    p.add_argument("--tunnel-cname", default="")
    p.add_argument("--ddns-service", default="duckdns")
    p.add_argument("--ddns-subdomain", default="")
    p.add_argument("--ttl", default="")
    p.add_argument("--token-file", default="", help="HOST file holding the token; its "
                   "content goes to the device over ssh stdin, never on argv")
    p.add_argument("--persist-public", action="store_true")
    p.add_argument("--revert-release-state", action="store_true")
    p.add_argument("--json", action="store_true")


def _work(args) -> str:
    return os.path.abspath(args.work or qemu_devices.default_work_dir(args.generator_dir))


def run_cli(args, *, out=None, call=None, isatty=None) -> int:
    from .golive_driver import GoLiveDriver, GoLiveOptions
    out = out or sys.stdout
    say = lambda s="": print(s, file=out, flush=True)      # noqa: E731
    work = _work(args)
    rows = targets(work)
    if args.verb == "targets":
        if args.json:
            say(json.dumps([dict(dataclasses.asdict(t), refusal=refusal(t))
                            for t in rows], indent=1))
            return 0
        for t in rows:
            why = refusal(t) or (local_node_refusal() if t.is_local else "")
            say(f"{t.label:<24} {t.kind:<16} {'ok' if not why else why}")
        return 0
    t = find_target(rows, args.target)
    if t is None:
        say(f"!! no target '{args.target}' — see `targets` (work dir {work})")
        return 2
    t = dataclasses.replace(t, work_dir=t.work_dir or work)
    drv = GoLiveDriver(args.generator_dir, target=t)
    if args.verb == "probe":
        if t.is_local:
            say("probe reads a device; this host's own files are read directly")
            return 2
        p = probe(t)
        if args.json:
            say(json.dumps(dataclasses.asdict(p), indent=1))
        else:
            why = probe_refusal(t, p)
            say(why or f"{t.label}: driver {p.driver}; cluster domain "
                f"{p.cluster_domain or '<unset>'}; release-state {p.release_state or '?'}; "
                f"onion files {sorted(p.onion_files) or 'none'}")
        return 1 if probe_refusal(t, p) else 0
    blocker = drv.blocker()
    if blocker:
        say(f"!! {blocker}")
        if args.verb == "status" and t.is_remote:
            # No guess: a device that could not be reached reads "unknown", with the
            # save it booted from and the journal still said. Which "unknown" is
            # read_posture's to say for a record this host refuses (it sends nothing:
            # a client image is "not read", a stopped device "not reachable") and
            # for a guest that answered the probe but bakes no driver (it IS asked:
            # nft can say what it is). Only a probe that got no answer is said here.
            if refusal(t) or not drv.probe().error:
                posture = read_posture(t)
            else:
                posture = Posture(error=blocker, at=utc_now())
            say(device_report(work, t, posture))
        return 2
    if args.verb == "status":
        say(drv.status_text())
        if t.is_remote:
            say(device_report(work, t, read_posture(t)))
        return 0
    if args.verb == "list":
        for pr in drv.providers():
            say(f"{pr.id:<20} {pr.mechanism:<13} {pr.status:<6} {pr.title}"
                + (f"  [{mechanism_reachability(pr.mechanism, t, pr.id)}]"
                   if t.is_remote else ""))
        return 0
    opts = GoLiveOptions(provider=args.provider, domain=args.domain,
                         ingress_ip=args.ingress_ip, ingress_ipv6=args.ingress_ipv6,
                         tunnel_cname=args.tunnel_cname, ddns_service=args.ddns_service,
                         ddns_subdomain=args.ddns_subdomain, ttl=args.ttl,
                         token_file=args.token_file)
    if args.verb == "plan":
        if t.is_remote:
            # The same verdict `list`, the GUI and the TUI show, before the plan runs:
            # a plan that cannot reach anything must not read as a go-live.
            pr = drv.provider(args.provider) if args.provider else None
            mech = pr.mechanism if pr else ""
            reach = mechanism_reachability(mech, t, args.provider)
            if reach:
                say(f"[reachability] {args.provider} ({mech}) from {t.label}: {reach}")
        # run_plan refuses what cannot run there (Funnel on headscale, a slirp ingress)
        return drv.run("plan", opts, on_line=say)
    # commit / rollback: ssh -t in the caller's own terminal, which must BE one.
    tty = isatty() if isatty is not None else sys.stdin.isatty()
    if not tty:
        say(f"!! {args.verb} needs a terminal: the device asks you to confirm on a TTY, "
            "and there is deliberately no way around that.")
        return 2
    try:
        if args.verb == "commit":
            if t.is_local:
                why = local_node_refusal()
                if why:
                    say(f"!! {why}")
                    return 2
            argv = drv.commit_command(opts, persist=args.persist_public,
                                      absolute=t.is_local)
        else:
            argv = drv.rollback_command(revert_release_state=args.revert_release_state,
                                        absolute=t.is_local)
    except ValueError as e:
        say(f"!! {e}")
        return 2
    call = call or subprocess.call
    if t.is_local:
        # The checkout's driver, by its absolute path, from the checkout, with the
        # in-repo registry — exactly what `plan` and the GUI's terminal run; the
        # operator's own cwd is wherever they typed this.
        rc = call(argv, cwd=drv.generator_dir, env=drv._driver_env())
    else:
        rc = call(argv)
    if t.is_remote:
        # rc != 0 (refused, declined, ssh failed) is journalled as NOT having gone
        # through; it never overwrites the last action that did.
        write_journal(t, args.verb, args.provider if args.verb == "commit" else "",
                      args.domain if args.verb == "commit" else "", rc=rc)
    return rc


def _parser(prog: str) -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(prog=prog, description="Go live from this host or from a "
                                "running emulated device (ssh only; the device's own "
                                "hugmesh-go-live is the authority).")
    add_arguments(p)
    return p


def main(argv: list[str] | None = None) -> int:
    return run_cli(_parser("python -m hugmesh_studio.core.golive_target").parse_args(argv))


def add_cli_arguments(ap: argparse.ArgumentParser) -> None:
    """``--go-live-target VERB [options]`` on the Studio's own parser (Qt-free)."""
    ap.add_argument("--go-live-target", nargs=argparse.REMAINDER, default=None,
                    metavar="VERB",
                    help="headless: go live from this host or a running emulated device. "
                         "VERB is targets, probe, status, list, plan, commit or rollback; "
                         "the options after it are those of python -m "
                         "hugmesh_studio.core.golive_target.")


def run_studio_cli(rest: list[str], generator_dir: str) -> int:
    p = _parser("hugmesh-studio --go-live-target")
    p.set_defaults(generator_dir=generator_dir)
    return run_cli(p.parse_args(rest))


if __name__ == "__main__":
    raise SystemExit(main())
