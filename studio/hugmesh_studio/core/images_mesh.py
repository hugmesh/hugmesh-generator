"""The mesh a node-image flow describes: SAVE it, and START it locally while its
images build (model + IO, no Qt).

OPERATOR ASK (2026-11-09): "when someone makes a mesh in the mesh node images studio
path, they should have the option to save that mesh before proceeding to the build as
well as starting that mesh locally as the build proceeds".

ONE RECORD TYPE. "Saved" means a :class:`.saved_meshes.SavedMesh` — the same record
the Saved meshes table lists. Its ``lanes.compose_project`` is its OWN
(:func:`project_for`), so every consumer of the record — ``LocalMeshBootstrap.for_record``
(the CLI ``mesh-restore``, the table's Start/Restore), ``mesh_monitor`` — drives that
project from the record's worktree and ports (:func:`bootstrap_for_record`), and
REFUSES while either is missing (a draft that never started beside a build): it never
falls back to the checkout's ``hugmesh-local``. The node-image
configuration becomes its ``config`` through ONE projection
(:func:`.local_mesh_domains.bootstrap_config_from_images`, the inverse of the #636
import), and the build it came from is a pointer (``SavedMesh.build``), because the
per-node settings (role, platform, board, encryption, passwords) have no place on a
Docker mesh. One flow writes one record: a second Save, the automatic save at
dispatch and a restart of the same build all overwrite it.

WHAT "START LOCALLY WHILE IT BUILDS" RUNS. The platform stack (the compose lane, never
kind) with the same brand, domains, sign-in, services and Tor as the images — not the
images themselves, which do not exist until the build ends. It runs BESIDE whatever
this checkout already runs, so it is isolated three ways:

* its own compose project (:func:`project_for`) — containers, networks, volumes and
  built images all carry that name (``LocalStackNode(project=...)``);
* its own generator WORKTREE under the Studio state dir (:meth:`AlongsideMesh.worktree`)
  — ``make stack-*`` writes run state into the checkout it runs in
  (``.e2e-credentials``, ``keys-out/``, ``tests/stack/.theme.css``, the generated
  overlays, the TLS front's certificates), and a second mesh writing those in the
  operator's checkout would re-mint the password every persona of the first one signs
  in with. The worktree builds from the checkout's own ``.stack-src`` (never cloned or
  reset: ``source_mode="existing"``);
* its own host ports for the four ``${...}`` doors compose.local.yaml publishes.

WHAT IT CANNOT ISOLATE, AND THEREFORE REFUSES. ``compose.real.yaml`` (included by
compose.local.yaml) publishes Casdoor on a FIXED ``8000:8000`` and the social tier on
fixed 8008/3000/4000, and the test issuer every token carries is
``http://localhost:8000``. Two meshes cannot both have that port, so while another
mesh holds it this lane refuses and names the container holding it
(:func:`plan_alongside`). Domains with their own Casdoor publish fixed 8001+ the same
way, and are refused for the same reason. And it refuses when the memory the build
is CAPPED at leaves too little for a mesh, or when the build has no cap — the build is
what the operator asked for, and a mesh beside it must never starve it. The cap is the
one the build really runs under (:func:`build_memory_cap`): a native build has none;
a Docker build has ``resource_limits.effective()`` (env, saved GUI setting, auto).

A FAILED LOCAL START NEVER FAILS THE BUILD. Every entry point here returns
``(ok, lines)`` and catches its own errors; the GUI runs it on its own thread and
writes the lines into the build log.

STOPPING is ``make stack-halt`` on THIS project only (volumes kept). Never
:meth:`.local_mesh_bootstrap.LocalMeshBootstrap.down`: that also stops the tailnet
overlay, whose compose project is the fixed ``hugmesh-mesh`` — the operator's.

Qt-free; ``capture``/``start``/``stop`` block and belong on a worker thread.
"""
from __future__ import annotations

import argparse
import copy
import json
import os
import socket
import subprocess
import sys
from dataclasses import dataclass, field

from . import host_resources, resource_limits, saved_meshes, vaults
from .state_paths import state_dir

#: ``SavedMesh.build["source"]`` for a record saved from the node-image flow.
SOURCE_IMAGES = "images"

#: Compose project prefix of a mesh started beside a node-image build.
PROJECT_PREFIX = "hugmesh-img-"

#: Memory a local mesh is expected to take. Measured 2026-11-09: the operator's running
#: hugmesh-local (51 containers, social + Tor) held ~6.0 GiB. Overridable for a host
#: whose mesh is smaller or larger (bytes, or a docker-style size such as ``8g``).
MESH_MEMORY_ENV = "HUGMESH_ALONGSIDE_MESH_MEMORY"
DEFAULT_MESH_BYTES = 6 * host_resources.GIB

#: Host ports compose publishes as literals (compose.real.yaml): Casdoor always, the
#: social tier with the ``social`` profile. Not movable, so a holder is a refusal.
FIXED_PORTS = (8000,)
SOCIAL_FIXED_PORTS = (8008, 3000, 4000)

#: The four ``${VAR:-default}`` host ports compose.local.yaml publishes, with the
#: first port this lane tries for each (well away from the checkout's defaults).
PORT_ENVS = (("PUBLIC_HOST_PORT", 18088), ("PUBLIC_HTTPS_PORT", 18488),
             ("TOR_SOCKS_HOST_PORT", 19050), ("ANUBIS_HOST_PORT", 18923))

_CMD_TIMEOUT = 60


# ── the record ─────────────────────────────────────────────────────────────────
def project_for(record_id: str) -> str:
    """The compose project of the mesh a record describes when it runs beside a
    build: one per record, so two saved meshes never share volumes."""
    tail = (record_id or "").rsplit("-", 1)[-1].lower()
    tail = "".join(c for c in tail if c.isalnum())[:12] or "draft"
    return PROJECT_PREFIX + tail


def build_ref(session_id: str, worklist) -> dict:
    """``SavedMesh.build`` for a node-image flow: the build session (filled in at
    dispatch; "" before) and the worklist entry ids."""
    ids = [str(getattr(e, "id", "") or "") for e in (getattr(worklist, "entries", None)
                                                      or ())]
    return {"source": SOURCE_IMAGES, "session_id": str(session_id or ""),
            "worklist_ids": [i for i in ids if i]}


def for_session(session_id: str) -> saved_meshes.SavedMesh | None:
    """The record saved for build session ``session_id``, or None. ONE build writes
    ONE record: the dispatch save and a restart of the same session find it here."""
    if not session_id:
        return None
    for r in saved_meshes.scan()[0]:
        b = r.build if isinstance(r.build, dict) else {}
        if b.get("source") == SOURCE_IMAGES and b.get("session_id") == session_id:
            return r
    return None


def foreign_record_refusal(rec) -> str:
    """Why this module must not ACT on ``rec`` ("" when it may): every verb here —
    ``save --record``, ``gate``, ``start``, ``stop`` and :class:`AlongsideMesh` itself —
    drives a record the node-image flow made, i.e. one with its OWN compose project
    (:func:`.saved_meshes.is_own_project`) AND ``build.source == "images"``.

    PR #937 round 3: ``start <id>`` of a record saved on the local-mesh page (the
    checkout's hugmesh-local) rewrote its ``lanes.compose_project`` to
    ``hugmesh-img-<id>`` — plus a worktree and ports — even when the start failed,
    and ``save --record <id>`` did the same through ``capture``. From then on every
    consumer drove that record as a mesh it never was. A fresh images record is the
    only one this module may create; anything else is refused with this sentence
    and nothing is written."""
    if rec is None:
        return ""
    label = getattr(rec, "label", "") or getattr(rec, "id", "") or "this record"
    build = rec.build if isinstance(getattr(rec, "build", None), dict) else {}
    if not saved_meshes.is_own_project(rec):
        return (f"'{label}' is this checkout's own mesh "
                f"({saved_meshes.record_project(rec)}), not one saved from the "
                "node-image flow — the node-image commands never start, stop, gate or "
                "overwrite it. Use the Local mesh page's Saved meshes table (or "
                "`python -m hugmesh_studio.core.local_mesh_bootstrap mesh-restore "
                f"{getattr(rec, 'id', '')}`). Nothing was written.")
    if build.get("source") != SOURCE_IMAGES:
        return (f"'{label}' runs as its own compose project "
                f"{saved_meshes.record_project(rec)} but was not saved from the "
                "node-image flow (its build source is "
                f"{build.get('source') or 'not recorded'!r}), so the node-image "
                "commands do not act on it. Nothing was written.")
    return ""


def derived_label(cfg, worklist=None) -> str:
    """The name a Save offers when none is typed (the saved-meshes derivation of the
    projected configuration)."""
    from .local_mesh_domains import bootstrap_config_from_images
    try:
        return saved_meshes.derived_label_of(
            bootstrap_config_from_images(cfg, worklist).to_dict())
    except Exception:                    # noqa: BLE001 — a placeholder, never a crash
        return "saved mesh"


@dataclass
class SaveResult:
    ok: bool
    message: str
    record: saved_meshes.SavedMesh | None = None


def save(generator_dir: str, cfg, worklist=None, *, label: str = "",
         record_id: str = "", session_id: str = "") -> SaveResult:
    """Save the mesh ``cfg`` (an ImageConfig) describes as a saved-mesh record.

    Overwrites, in this order: the record ``record_id`` (this flow saved before), the
    record already saved for ``session_id`` (a restarted build), else a NEW record.
    A typed ``label`` another record already has is refused (Delete is confirmed by
    typing the name); an empty one keeps the overwritten record's name or derives a
    unique one. ``session_id`` is merged into the record's build pointer and an
    empty one never clears a pointer the record already has.

    BLOCKING (``saved_meshes.capture``: docker volume ls, git rev-parse). Never raises:
    a failure is ``SaveResult(ok=False, message=...)``."""
    from .local_mesh_bootstrap import LocalMeshBootstrap
    from .local_mesh_domains import bootstrap_config_from_images
    try:
        boot_cfg = bootstrap_config_from_images(cfg, worklist)
        records = saved_meshes.scan()[0]
        prior = None
        if record_id:
            prior = next((r for r in records if r.id == record_id), None)
        if prior is None and session_id:
            prior = for_session(session_id)
        # never overwrite a record this flow did not make (a hugmesh-local record
        # named by --record): capture would rewrite its compose project to
        # hugmesh-img-<id>. Refused BEFORE any write.
        foreign = foreign_record_refusal(prior)
        if foreign:
            return SaveResult(False, foreign)
        rid = prior.id if prior is not None else saved_meshes.new_id()
        typed = (label or "").strip()
        if typed:
            owner = saved_meshes.label_owner(typed, records, exclude_id=rid)
            if owner is not None:
                return SaveResult(False, f"another saved mesh is already called "
                                         f"'{owner.label}' — pick another name")
        elif prior is None:
            typed = saved_meshes.unique_label(
                saved_meshes.derived_label_of(boot_cfg.to_dict()), records)
        # the record's id is chosen BEFORE capture so its compose project is known:
        # capture reads that project's state (nothing of it runs yet), never the
        # checkout's own mesh — whose running containers would otherwise make a
        # draft read "ran" and list another mesh's volumes as its own
        # (a stub for a NEW record says it never ran: an empty last_seen would read
        # as a legacy record that did, and the draft would claim an earlier run)
        stub = prior if prior is not None else saved_meshes.SavedMesh(
            id=rid, last_seen={"compose_running": False, "kind_running": False})
        project = project_for(rid)
        # ...and the bootstrap capture reads credential pointers through is the one
        # this mesh RUNS as: its own worktree (keys-out/, .e2e-credentials), never
        # the operator's checkout, whose live password file a record of THIS mesh
        # would otherwise claim (creds_match against hugmesh-local's file). The
        # record is still filed under the checkout (rec.generator_dir), so the
        # Saved meshes table and the node-image picker list it there.
        wt = worktree_path(rid, prior)
        boot = LocalMeshBootstrap(wt, boot_cfg, project=project)
        rec = saved_meshes.capture(generator_dir, boot_cfg, boot._stack_node(), boot,
                                   label=typed, project=project, overwrite=stub,
                                   kind_running=False)
        old = dict(prior.build) if prior is not None and isinstance(prior.build, dict) \
            else {}
        ref = build_ref(session_id or old.get("session_id", ""), worklist)
        if not ref["worklist_ids"] and old.get("worklist_ids"):
            ref["worklist_ids"] = list(old["worklist_ids"])
        # what a run beside a build recorded (worktree, ports) survives a re-save
        for k in ("alongside",):
            if k in old:
                ref[k] = old[k]
        rec.build = ref
        if prior is not None and isinstance(prior.lanes, dict):
            for k in ("host_ports", "worktree"):
                if k in prior.lanes:
                    rec.lanes[k] = prior.lanes[k]
        # where this mesh runs (deterministic per record): every consumer of the
        # record reads it from here (LocalMeshBootstrap.for_record) and refuses
        # while it does not exist — a draft never falls back to the checkout
        rec.lanes.setdefault("worktree", wt)
        rec.notes.insert(0, (
            f"Saved from the node-image flow ({len(ref['worklist_ids'])} image(s)). "
            "This record is the mesh those images "
            "join: brand, domains, sign-in, services and Tor. The per-image settings "
            "(role, platform, board, encryption, passwords) are in build session "
            + (ref["session_id"] or "(not started yet)") + "."))
        path = saved_meshes.save(rec)
        if not path:
            return SaveResult(False, "the record could not be written under "
                                     f"{saved_meshes.meshes_dir()}")
        saved_meshes.drop_unreferenced_copies(rec)
        verb = "updated" if prior is not None else "saved"
        return SaveResult(True, f"{verb} '{rec.label}' (not run yet — a draft until "
                                f"it runs)", rec)
    except Exception as e:                # noqa: BLE001 — a save never raises
        return SaveResult(False, f"could not save the mesh: {e}")


# ── the resource gate ──────────────────────────────────────────────────────────
def mesh_memory_bytes(env=None) -> int:
    env = os.environ if env is None else env
    raw = (env.get(MESH_MEMORY_ENV) or "").strip()
    if raw:
        b = _size_bytes(raw)
        if b:
            return b
    return DEFAULT_MESH_BYTES


def _size_bytes(raw: str) -> int:
    """A docker-style size (``8g``, ``6144m``, plain bytes) in bytes; 0 if unreadable."""
    raw = (raw or "").strip().lower()
    mult = {"k": 1024, "m": 1024 ** 2, "g": 1024 ** 3, "t": 1024 ** 4}
    try:
        if raw and raw[-1] in mult:
            return int(float(raw[:-1]) * mult[raw[-1]])
        if raw.endswith("b") and raw[:-1].isdigit():
            return int(raw[:-1])
        return int(raw)
    except ValueError:
        return 0


def port_free(port: int) -> bool:
    """Whether ``port`` can be bound on every address compose publishes on (a
    bind test; nothing listens afterwards)."""
    for fam, addr in ((socket.AF_INET, "0.0.0.0"), (socket.AF_INET, "127.0.0.1")):
        s = socket.socket(fam, socket.SOCK_STREAM)
        try:
            s.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
            s.bind((addr, port))
        except OSError:
            return False
        finally:
            s.close()
    return True


def port_holder(port: int) -> str:
    """The docker container publishing host ``port``, or "" (not docker, or unknown)."""
    try:
        r = subprocess.run(["docker", "ps", "--format", "{{.Names}}\t{{.Ports}}"],
                           capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    needle = f":{port}->"
    for ln in r.stdout.splitlines():
        name, _, ports = ln.partition("\t")
        if needle in ports:
            return name.strip()
    return ""


def free_ports(is_free=port_free, taken=()) -> dict[str, int]:
    """One free host port per :data:`PORT_ENVS` entry, scanning up from its start."""
    out: dict[str, int] = {}
    used = set(taken)
    for env_name, start in PORT_ENVS:
        p = start
        while p < start + 500 and (p in used or not is_free(p)):
            p += 1
        out[env_name] = p
        used.add(p)
    return out


@dataclass
class AlongsidePlan:
    """What starting the mesh beside the build would do — or why it will not."""
    ok: bool
    reasons: list[str] = field(default_factory=list)
    notes: list[str] = field(default_factory=list)
    ports: dict = field(default_factory=dict)
    need_bytes: int = 0
    headroom_bytes: int = 0

    def lines(self) -> list[str]:
        """The verdict as log lines. A refusal is its reasons only: the notes (the
        ports it would take, the first-start image build) describe a start that is
        not going to happen, and in the progress panel's tail they pushed the reason
        itself out of view."""
        if not self.ok:
            return ["This mesh will NOT start beside the build:",
                    *(f"  - {r}" for r in self.reasons)]
        return ["A local copy of this mesh can start beside the build.",
                *(f"  · {n}" for n in self.notes)]


def _gib(b: int) -> str:
    return f"{b / host_resources.GIB:.1f} GiB"


def container_project(name: str) -> str:
    """The compose project label of container ``name`` ("" when docker cannot say)."""
    try:
        r = subprocess.run(["docker", "inspect", "-f",
                            '{{index .Config.Labels "com.docker.compose.project"}}',
                            name], capture_output=True, text=True, timeout=10)
    except (OSError, subprocess.SubprocessError):
        return ""
    out = (r.stdout or "").strip()
    return out if r.returncode == 0 and out != "<no value>" else ""


def holder_in_project(name: str, project: str, project_of=None) -> bool:
    """Whether container ``name`` belongs to compose project ``project``: its compose
    label when docker answers, else compose's own naming (``<project>-<service>-<n>``)."""
    if not name or not project:
        return False
    project_of = container_project if project_of is None else project_of
    label = project_of(name)
    if label:
        return label == project
    return name.startswith(project + "-")


def _fixed_ports_of(boot_cfg) -> list[int]:
    try:
        social = bool(boot_cfg.effective_social())
    except Exception:                    # noqa: BLE001
        social = False
    return list(FIXED_PORTS) + (list(SOCIAL_FIXED_PORTS) if social else [])


def _port_role(p: int) -> str:
    return (" (Casdoor, the sign-in every token names)" if p == 8000 else
            " (the social tier)")


def fixed_port_refusals(boot_cfg, *, is_free=None, holder=None, project: str = "",
                        project_of=None) -> list[str]:
    """One sentence per FIXED host port this mesh publishes that something already
    holds (8000 always — Casdoor; 8008, 3000, 4000 with the social tier), naming the
    container holding it. ``[]`` = all free. The probes default to this module's
    :func:`port_free` / :func:`port_holder`, looked up at call time.

    Shared by :func:`plan_alongside` (before a start beside a build) and by
    ``LocalMeshBootstrap.fixed_port_refusal`` for every bootstrap of a mesh with its
    own compose project (a saved record's Start/Restore): with the checkout's mesh
    up, `make stack-up` in the worktree would otherwise create containers and then
    die on Casdoor's port. ``project`` (that bootstrap's own) skips a port its OWN
    container holds — the mesh is already up, and a re-up does not bind it twice."""
    is_free = port_free if is_free is None else is_free
    holder = port_holder if holder is None else holder
    out: list[str] = []
    for p in _fixed_ports_of(boot_cfg):
        if not is_free(p):
            who = holder(p)
            if project and holder_in_project(who, project, project_of):
                # held by THIS mesh's own container (it is already up): a re-up of
                # the same project does not bind the port twice
                continue
            out.append(
                f"host port {p} is already in use" + (f" by {who}" if who else "")
                + " — compose publishes it as a fixed port"
                + _port_role(p)
                + ", so two local meshes cannot run at once; stop the other mesh "
                  "first, then start this one (tick 'Start this mesh locally' for a "
                  "build, or with no build running `python -m "
                  "hugmesh_studio.core.images_mesh start <record id> --not-building`)")
    return out


def checkout_fixed_port_refusals(boot_cfg, project: str = vaults.DEFAULT_PROJECT, *,
                                 is_free=None, holder=None, project_of=None,
                                 records=None) -> list[str]:
    """The REVERSE collision (PR #937 round 3): one sentence per fixed host port the
    checkout's own mesh (``project``, hugmesh-local) publishes that a container of
    ANOTHER compose project holds — a mesh started beside a build
    (``hugmesh-img-<id>``), most likely. Without it a start/restore of hugmesh-local
    ran ``make stack-up``, created its containers and died on Casdoor's bind.

    Deliberately narrower than :func:`fixed_port_refusals`: a port held by
    hugmesh-local's OWN container (it is already up — a warm re-up or a restore of
    the running mesh) is not a collision, and a holder docker cannot name (not a
    container, or docker unreadable) is not refused on a guess — the checkout's own
    mesh was never gated on that and ``make stack-up`` still says what failed."""
    is_free = port_free if is_free is None else is_free
    holder = port_holder if holder is None else holder
    out: list[str] = []
    for p in _fixed_ports_of(boot_cfg):
        if is_free(p):
            continue
        who = holder(p)
        if not who or holder_in_project(who, project, project_of):
            continue
        rid = ""
        try:
            pool = saved_meshes.scan()[0] if records is None else records
            for r in pool:
                rp = saved_meshes.record_project(r)
                if saved_meshes.is_own_project(r) and holder_in_project(
                        who, rp, project_of):
                    rid = r.id
                    break
        except Exception:                # noqa: BLE001 — the hint is optional
            rid = ""
        remedy = (f"stop it first (`python -m hugmesh_studio.core.images_mesh stop "
                  f"{rid}`, or Stop on its row in Saved meshes)" if rid else
                  "stop that mesh first")
        out.append(f"host port {p} is already in use by {who}, a container of another "
                   f"local mesh — compose publishes it as a fixed port{_port_role(p)}, "
                   f"so {project} cannot run beside it; {remedy}, then start this one. "
                   "Nothing was started.")
    return out


#: The build backends :func:`plan_alongside` knows the memory cap of.
BACKEND_DOCKER = "docker"
BACKEND_NATIVE = "native"


def build_memory_cap(backend: str | None, env=None, meminfo: dict | None = None,
                     limits: "resource_limits.ResourceLimits | None" = None
                     ) -> tuple[bool, str | None, str]:
    """``(known, cap, why)``: the memory cap a node-image build on ``backend`` will
    ACTUALLY run under — the value the builder's argv carries, not a re-derivation.

    * ``docker`` -> ``resource_limits.effective().memory`` (env knob, then the
      operator's SAVED GUI setting, then the auto formula) — exactly what
      ``build_driver.docker_limit_args()`` puts on ``docker run``. ``None`` = the
      setting is "all memory": no cap.
    * ``native`` -> no cap, ever: the native builder runs on the host under sudo,
      outside any cgroup (build_driver: "native has no cgroup cap").
    * anything else (unknown, ``none``, not passed) -> not known; the gate refuses.
    """
    b = (backend or "").strip().lower()
    if b == BACKEND_NATIVE:
        return True, None, "a native build runs on the host with no memory cap"
    if b == BACKEND_DOCKER:
        env = os.environ if env is None else env
        lim = limits if limits is not None else resource_limits.effective(
            env=env, meminfo=meminfo)
        if lim.memory is None:
            return True, None, ("the Docker build's memory limit is 'all memory' "
                                "(the Studio's resource limits, or "
                                f"{host_resources.MEMORY_ENV}=off), so it has no cap")
        return True, str(lim.memory), f"the Docker build is capped at {lim.memory}"
    return False, None, ("which backend the build runs on is not known"
                         + (f" ({backend!r})" if backend else "")
                         + ", so neither is its memory cap")


def plan_alongside(boot_cfg, *, building: bool, backend: str | None = None,
                   limits: "resource_limits.ResourceLimits | None" = None,
                   meminfo: dict | None = None,
                   env=None, is_free=None, holder=None) -> AlongsidePlan:
    """Whether the mesh ``boot_cfg`` describes can start beside a node-image build on
    this host, and with which ports. PURE given its probes (``meminfo``, ``is_free``,
    ``holder`` — the tests pass fakes); the defaults read /proc and bind-test.

    Refuses (``ok=False``, every reason listed) when:
    * a FIXED host port this mesh publishes is held (8000 always — Casdoor; 8008,
      3000, 4000 with the social tier) — by another local mesh, most likely;
    * a domain runs its own Casdoor (fixed ports 8001+, the same problem);
    * the memory left after the host reserve and — while ``building`` — the build's
      own memory cap is less than a mesh takes (:func:`mesh_memory_bytes`), or the
      build has no cap at all (it may then use every byte).

    THE BUILD'S CAP is the one it will really get (:func:`build_memory_cap`): a
    ``native`` build has none, a ``docker`` one has ``resource_limits.effective()``
    (``limits`` overrides it for a caller that already resolved it). A caller that
    does not say which ``backend`` the build runs on is refused while ``building``
    — a gate that guesses the cap is the gate that let a mesh starve a build.
    """
    env = os.environ if env is None else env
    # the probes are looked up at CALL time (a def-time default could not be
    # replaced by a caller patching this module, and the CLI passes none)
    is_free = port_free if is_free is None else is_free
    holder = port_holder if holder is None else holder
    mi = host_resources.read_meminfo() if meminfo is None else meminfo
    plan = AlongsidePlan(ok=True)
    plan.reasons.extend(fixed_port_refusals(boot_cfg, is_free=is_free, holder=holder))
    own = tuple(getattr(boot_cfg, "own_idp_domains", ()) or ())
    if own:
        plan.reasons.append(
            "domain(s) with their own Casdoor (" + ", ".join(own) + ") publish fixed "
            "host ports 8001 and up, which cannot be moved for a second mesh. It "
            "cannot run beside anything; to run it as this checkout's own mesh, "
            "'Load into the form' in the Saved meshes table and use 'Generate && "
            "start' (that is hugmesh-local, and only once nothing else runs there)")
    need = mesh_memory_bytes(env)
    total = int(mi.get("MemTotal", 0) or 0)
    avail = int(mi.get("MemAvailable", 0) or 0)
    plan.need_bytes = need
    if total <= 0:
        plan.reasons.append("this host's memory could not be read (/proc/meminfo), so "
                            "a mesh beside the build cannot be shown to fit")
    else:
        head = avail - host_resources.HOST_RESERVE_BYTES
        uncapped = False
        if building:
            known, flag, why = build_memory_cap(backend, env=env, meminfo=mi,
                                                limits=limits)
            cap = _size_bytes(flag) if flag else 0
            if not known or flag is None or cap <= 0:
                uncapped = True
                plan.reasons.append(
                    (f"{why} — it may use all of this host's memory, so a mesh "
                     "beside it could starve it" if known and flag is None else
                     f"the build's memory cap ({flag}) cannot be read, so a mesh "
                     "beside it cannot be shown to fit" if known else
                     f"{why} — a mesh beside it cannot be shown to fit"))
                head = 0
            else:
                head -= cap
                plan.notes.append(f"the build may use up to {_gib(cap)} ({why})")
        plan.headroom_bytes = max(0, head)
        if head < need and not uncapped:
            plan.reasons.append(
                f"not enough memory: {_gib(max(0, head))} left "
                f"({_gib(avail)} available − {_gib(host_resources.HOST_RESERVE_BYTES)} "
                "kept for the desktop" + (" − the build's cap" if building else "")
                + f"), a local mesh takes about {_gib(need)} ({MESH_MEMORY_ENV} "
                  "overrides the estimate)")
    if getattr(boot_cfg, "env", "test") == "prod":
        plan.notes.append("the images are for a PRODUCTION mesh; the local copy runs "
                          "as a test mesh (localhost sign-in, no tailnet)")
    plan.ports = free_ports(is_free)
    plan.notes.append("its own ports: " + ", ".join(
        f"{k}={v}" for k, v in plan.ports.items()))
    plan.notes.append("the first start builds this mesh's service images under its own "
                      "project name (the cached layers of the checkout's mesh are reused "
                      "when the source is unchanged)")
    plan.ok = not plan.reasons
    return plan


# ── the mesh beside the build ──────────────────────────────────────────────────
def alongside_root() -> str:
    return os.path.join(state_dir(), "alongside")


def worktree_path(record_id: str, rec: saved_meshes.SavedMesh | None = None) -> str:
    """The generator worktree a record's mesh runs from: the one the record names
    (``lanes.worktree``), else ``<state>/alongside/<id>/generator``."""
    lanes = (rec.lanes if rec is not None and isinstance(rec.lanes, dict) else {})
    wt = str(lanes.get("worktree") or "")
    return wt or os.path.join(alongside_root(), record_id, "generator")


def _cli_start_hint(rec_id: str) -> str:
    return (f"`python -m hugmesh_studio.core.images_mesh start {rec_id} "
            "--not-building` (or tick 'Start this mesh locally' on the node-image "
            "Build screen)")


class AlongsideMesh:
    """The saved mesh ``rec``, run beside a build from its own worktree and project."""

    def __init__(self, generator_dir: str, rec: saved_meshes.SavedMesh):
        self.generator_dir = os.path.abspath(generator_dir)
        self.rec = rec
        # the record's own project when it names one; never the checkout's
        self.project = (saved_meshes.record_project(rec)
                        if saved_meshes.is_own_project(rec) else project_for(rec.id))

    @property
    def worktree(self) -> str:
        return worktree_path(self.rec.id, self.rec)

    def refusal(self) -> str:
        """Why this record's mesh cannot be STARTED, RESTORED or STOPPED from a saved
        record right now ("" when it can): it runs only from its own worktree, on
        its own project and ports, and a draft that never started beside a build
        has neither a worktree nor ports. Acting anyway would mean acting on the
        checkout — ``make stack-up``/``stack-seed`` on hugmesh-local, writing the
        checkout's ``.e2e-credentials`` — which this refusal exists to rule out."""
        label = self.rec.label or self.rec.id
        wt = self.worktree
        head = (f"'{label}' runs as its own compose project {self.project} from its "
                f"own worktree, never as this checkout's "
                f"{vaults.DEFAULT_PROJECT}")
        hint = _cli_start_hint(self.rec.id)
        if not os.path.exists(os.path.join(wt, ".git")):
            if not (self.rec.lanes or {}).get("host_ports"):
                return (f"{head}, and it has never been started, so it has no worktree "
                        f"or ports of its own yet. Start it with {hint}. Nothing was "
                        "started or seeded.")
            return (f"{head}, and that worktree ({wt}) is gone. Start it again with "
                    f"{hint}, which makes a new one. Nothing was started or seeded.")
        ports = (self.rec.lanes or {}).get("host_ports") or {}
        if not isinstance(ports, dict) or "PUBLIC_HOST_PORT" not in ports:
            return (f"{head}, and the record names no host ports of its own (the "
                    "checkout's defaults belong to hugmesh-local). Start it with "
                    f"{hint}, which picks free ones. Nothing was started or seeded.")
        return ""

    def _source_dir(self) -> str:
        src = self.rec.source if isinstance(self.rec.source, dict) else {}
        d = str(src.get("dir") or "")
        return d if d and os.path.isdir(d) else os.path.join(self.generator_dir,
                                                               ".stack-src")

    def boot_config(self):
        """The record's config as THIS lane runs it: a test mesh, credentials under
        the worktree, built from the checkout's source tree (never cloned or reset)."""
        from .local_mesh_bootstrap import LocalMeshBootstrapConfig
        cfg = LocalMeshBootstrapConfig.from_dict(copy.deepcopy(self.rec.config or {}))
        cfg.env = "test"
        cfg.auth_key = ""
        cfg.out_dir = os.path.join(self.worktree, "keys-out")
        cfg.source_mode = "existing"
        cfg.source_dir = self._source_dir()
        return cfg

    def bootstrap(self, ports: dict | None = None):
        from .local_mesh_bootstrap import LocalMeshBootstrap
        ports = dict(ports or (self.rec.lanes or {}).get("host_ports") or {})
        host_ports = {k: str(v) for k, v in ports.items()}
        if "PUBLIC_HOST_PORT" in host_ports:
            # seed-e2e.sh dials the front door at a FIXED default (localhost:8088 —
            # the checkout's mesh); point it at this one
            host_ports["FRONT_DOOR"] = f"http://localhost:{host_ports['PUBLIC_HOST_PORT']}"
        return LocalMeshBootstrap(self.worktree, self.boot_config(), project=self.project,
                                  host_ports=host_ports)

    def prepare_worktree(self) -> tuple[bool, str]:
        """``git worktree add --detach`` of the checkout's HEAD (reused when present).

        A worktree whose DIRECTORY was deleted is still registered in the checkout
        (``.git/worktrees/<name>``), and a plain ``add`` at the same path dies with
        "missing but already registered worktree" — which made the refusal's own
        remedy ("Start it again ..., which makes a new one") fail (PR #937 round 3).
        ``git worktree prune`` first: it drops only registrations whose directory is
        gone (a locked one is kept), never a worktree that still exists. A prune
        that fails is not fatal; the add then says what is wrong."""
        wt = self.worktree
        if os.path.exists(os.path.join(wt, ".git")):
            return True, f"worktree {wt} (reused)"
        os.makedirs(os.path.dirname(wt), exist_ok=True)
        try:
            subprocess.run(["git", "-C", self.generator_dir, "worktree", "prune"],
                           capture_output=True, text=True, timeout=_CMD_TIMEOUT)
        except (OSError, subprocess.SubprocessError):
            pass
        try:
            r = subprocess.run(["git", "-C", self.generator_dir, "worktree", "add",
                                "--detach", wt, "HEAD"], capture_output=True, text=True,
                               timeout=_CMD_TIMEOUT)
        except (OSError, subprocess.SubprocessError) as e:
            return False, f"git worktree add failed: {e}"
        if r.returncode != 0:
            return False, ("git worktree add failed: "
                           + (r.stderr or r.stdout).strip()[-400:])
        return True, f"worktree {wt} (new, at the checkout's HEAD)"

    def start(self, *, building: bool, backend: str | None = None, on_line=None,
              cancel=None, limits=None, meminfo: dict | None = None, env=None,
              is_free=None, holder=None) -> tuple[bool, list[str]]:
        """Gate, then bring the mesh up beside the build. Never raises. ``backend``
        is the build's backend (``docker``/``native``) while ``building`` — the gate
        refuses without it (:func:`plan_alongside`).

        Refuses a record this flow did not make (:func:`foreign_record_refusal`)
        before anything else. The record is written ONLY after a successful ``up``
        (its project, ports and worktree, then "ran"): a refused or failed start
        leaves the record file byte-identical."""
        log: list[str] = []

        def note(line: str) -> None:
            log.append(line)
            if on_line is not None:
                try:
                    on_line(line)
                except Exception:        # noqa: BLE001 — a viewer never sinks the start
                    pass
        try:
            foreign = foreign_record_refusal(self.rec)
            if foreign:
                note(f"[local mesh] refused — {foreign}")
                return False, log
            plan = plan_alongside(self.boot_config(), building=building,
                                  backend=backend, limits=limits, meminfo=meminfo,
                                  env=env, is_free=is_free, holder=holder)
            for ln in plan.lines():
                note(ln)
            if not plan.ok:
                return False, log
            ok, msg = self.prepare_worktree()
            note(f"[local mesh] {msg}")
            if not ok:
                return False, log
            boot = self.bootstrap(plan.ports)
            ok, _lines = boot.up(on_line=note, cancel=cancel)
            note(f"[local mesh] {'up' if ok else 'FAILED'} — compose project "
                 f"{self.project}" + (f", front door {boot._stack_node().web_url}"
                                      if ok else ""))
            if ok:
                # only now does the record learn where it runs: a failed start must
                # not leave it naming ports/a project nothing came up on
                self._record_lanes(plan.ports, save=False)
                self._mark_ran()
            return ok, log
        except Exception as e:           # noqa: BLE001 — never fails the build
            note(f"[local mesh] FAILED: {e}")
            return False, log

    def stop(self) -> tuple[bool, list[str]]:
        """``make stack-halt`` for THIS project only (volumes kept). Never the
        bootstrap's down(), which also stops the operator's tailnet overlay."""
        foreign = foreign_record_refusal(self.rec)
        if foreign:
            return False, [f"[local mesh] refused — {foreign}"]
        if not os.path.isdir(self.worktree):
            return True, [f"[local mesh] nothing to stop ({self.project} never started "
                          "here)"]
        try:
            node = self.bootstrap()._stack_node()
            before = node.status()
            ok, msg = node.stop()
        except Exception as e:           # noqa: BLE001
            return False, [f"[local mesh] stop FAILED: {e}"]
        if ok:
            return True, [f"[local mesh] stopped {self.project} ({before.detail}); its "
                          "volumes are kept"]
        return False, [f"[local mesh] stop FAILED: {msg.strip()[-400:]}"]

    def status(self) -> str:
        try:
            st = self.bootstrap()._stack_node().status()
            return f"{self.project}: {'running' if st.running else 'not running'} " \
                   f"({st.detail})"
        except Exception as e:           # noqa: BLE001
            return f"{self.project}: unknown ({e})"

    def _record_lanes(self, ports: dict, *, save: bool = True) -> None:
        self.rec.lanes = dict(self.rec.lanes or {})
        self.rec.lanes["compose_project"] = self.project
        self.rec.lanes["host_ports"] = dict(ports)
        self.rec.lanes["worktree"] = self.worktree
        self.rec.notes = [n for n in self.rec.notes if not n.startswith("Runs beside")]
        self.rec.notes.append(
            f"Runs beside its node-image build as compose project {self.project} from "
            f"the worktree {self.worktree} (ports: " + ", ".join(
                f"{k}={v}" for k, v in ports.items()) + ").")
        if save:
            saved_meshes.save(self.rec)

    def _mark_ran(self) -> None:
        self.rec.last_seen = dict(self.rec.last_seen or {})
        self.rec.last_seen.update({"compose_running": True, "running_env": "test",
                                   "at": saved_meshes._now()})
        saved_meshes.save(self.rec)


def bootstrap_for_record(generator_dir: str, rec: saved_meshes.SavedMesh):
    """The bootstrap a saved record of a mesh with its OWN compose project runs as —
    what :meth:`.local_mesh_bootstrap.LocalMeshBootstrap.for_record` returns for it:
    its project, its recorded host ports (and the seeder's front door on them), its
    worktree as the generator dir, and the config this lane runs (a test mesh, keys
    under the worktree, the checkout's source tree never cloned or reset).

    NEVER the checkout: when the worktree or the ports are not there the bootstrap
    still names the record's project and worktree, and carries
    :meth:`AlongsideMesh.refusal` as ``lane_refusal`` — every acting entry point
    (``guard_host_local``, ``start_saved``, ``restore``, ``down``, ``clean``) refuses
    with that sentence, while read-only callers (the node-image picker) still get
    the record's config."""
    lane = AlongsideMesh(generator_dir, rec)
    boot = lane.bootstrap()
    boot.lane_refusal = lane.refusal()
    return boot


# ── CLI (parity with the GUI's Save strip and the progress page) ───────────────
def host_default_backend() -> str:
    """The backend a build on this host runs on when none is chosen — the same
    ``HostInfo.default_backend`` the GUI's dispatch falls back to. "" when the
    probe fails (the gate then refuses: the cap is not known)."""
    try:
        from .platform_info import detect
        return str(detect().default_backend or "")
    except Exception:                    # noqa: BLE001 — unknown, and the gate says so
        return ""


def _load_cfg(path: str):
    from .config import ImageConfig
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if isinstance(data, dict) and "base" in data and "entries" in data:
        from .worklist import WorklistConfig
        wl = WorklistConfig.from_dict(data)
        return wl.base, wl
    return ImageConfig.from_dict(data), None


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(
        prog="python -m hugmesh_studio.core.images_mesh",
        description="Save the mesh a node-image configuration describes, and run it "
                    "locally beside a build.")
    ap.add_argument("--generator-dir", default=os.getcwd())
    sub = ap.add_subparsers(dest="verb", required=True)
    s = sub.add_parser("save", help="save a node-image config (or worklist) as a "
                                    "saved mesh")
    s.add_argument("config", help="a saved Studio config or worklist JSON")
    s.add_argument("--label", default="")
    s.add_argument("--record", default="", help="overwrite this record id")
    s.add_argument("--session", default="", help="the build session it belongs to")
    backend_help = ("the backend the build runs on (docker = capped by the Studio's "
                    "resource limits, native = no cap); default: this host's default "
                    "backend")
    g = sub.add_parser("gate", help="say whether a saved mesh can start beside a build")
    g.add_argument("record")
    g.add_argument("--not-building", action="store_true")
    g.add_argument("--backend", choices=(BACKEND_DOCKER, BACKEND_NATIVE), default="",
                   help=backend_help)
    st = sub.add_parser("start", help="start a saved mesh beside a build")
    st.add_argument("record")
    st.add_argument("--not-building", action="store_true")
    st.add_argument("--backend", choices=(BACKEND_DOCKER, BACKEND_NATIVE), default="",
                    help=backend_help)
    sp = sub.add_parser("stop", help="stop a saved mesh started beside a build")
    sp.add_argument("record")
    args = ap.parse_args(argv)
    if args.verb == "save":
        if args.record:
            # the same refusal save() makes, said here as a refusal (rc 2, stderr):
            # --record naming a record this flow did not make writes nothing
            foreign = foreign_record_refusal(saved_meshes.find(args.record))
            if foreign:
                print(f"refused — {foreign}", file=sys.stderr)
                return 2
        try:
            cfg, wl = _load_cfg(args.config)
        except (OSError, ValueError, TypeError) as e:
            print(f"cannot read {args.config}: {e}", file=sys.stderr)
            return 2
        res = save(args.generator_dir, cfg, wl, label=args.label, record_id=args.record,
                   session_id=args.session)
        print(res.message)
        if res.record is not None:
            print(f"id: {res.record.id}")
        return 0 if res.ok else 1
    rec = saved_meshes.find(args.record)
    if rec is None:
        print(f"no saved mesh with id {args.record!r}", file=sys.stderr)
        return 2
    foreign = foreign_record_refusal(rec)
    if foreign:
        # refused before the lane is even built: nothing probed, nothing written
        print(f"refused — {foreign}", file=sys.stderr)
        return 2
    lane = AlongsideMesh(args.generator_dir, rec)
    if args.verb == "gate":
        plan = plan_alongside(lane.boot_config(), building=not args.not_building,
                              backend=args.backend or host_default_backend())
        print("\n".join(plan.lines()))
        return 0 if plan.ok else 1
    if args.verb == "start":
        ok, _ = lane.start(building=not args.not_building,
                           backend=args.backend or host_default_backend(),
                           on_line=print)
        return 0 if ok else 1
    ok, lines = lane.stop()
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
