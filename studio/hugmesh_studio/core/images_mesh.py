"""The mesh a node-image flow describes: SAVE it, and START it locally while its
images build (model + IO, no Qt).

OPERATOR ASK (2026-11-09): "when someone makes a mesh in the mesh node images studio
path, they should have the option to save that mesh before proceeding to the build as
well as starting that mesh locally as the build proceeds".

ONE RECORD TYPE. "Saved" means a :class:`.saved_meshes.SavedMesh` — the same record
the Saved meshes table lists and the local Docker mesh starts from. The node-image
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
has reserved leaves too little for a mesh — the build is what the operator asked for,
and a mesh beside it must never starve it.

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

from . import host_resources, saved_meshes
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
        boot = LocalMeshBootstrap(generator_dir, boot_cfg, project=project)
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
        head = ("A local copy of this mesh can start beside the build."
                if self.ok else "This mesh will NOT start beside the build:")
        return [head, *(f"  - {r}" for r in self.reasons),
                *(f"  · {n}" for n in self.notes)]


def _gib(b: int) -> str:
    return f"{b / host_resources.GIB:.1f} GiB"


def plan_alongside(boot_cfg, *, building: bool, meminfo: dict | None = None,
                   env=None, is_free=port_free, holder=port_holder) -> AlongsidePlan:
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
    """
    env = os.environ if env is None else env
    mi = host_resources.read_meminfo() if meminfo is None else meminfo
    plan = AlongsidePlan(ok=True)
    social = False
    try:
        social = bool(boot_cfg.effective_social())
    except Exception:                    # noqa: BLE001
        social = False
    fixed = list(FIXED_PORTS) + (list(SOCIAL_FIXED_PORTS) if social else [])
    for p in fixed:
        if not is_free(p):
            who = holder(p)
            plan.reasons.append(
                f"host port {p} is already in use" + (f" by {who}" if who else "")
                + " — compose publishes it as a fixed port"
                + (" (Casdoor, the sign-in every token names)" if p == 8000 else
                   " (the social tier)")
                + ", so two local meshes cannot run at once; stop the other mesh "
                  "first, or start this one from the Saved meshes table after it")
    own = tuple(getattr(boot_cfg, "own_idp_domains", ()) or ())
    if own:
        plan.reasons.append(
            "domain(s) with their own Casdoor (" + ", ".join(own) + ") publish fixed "
            "host ports 8001 and up, which cannot be moved for a second mesh — start it "
            "from the Saved meshes table instead")
    need = mesh_memory_bytes(env)
    total = int(mi.get("MemTotal", 0) or 0)
    avail = int(mi.get("MemAvailable", 0) or 0)
    plan.need_bytes = need
    if total <= 0:
        plan.reasons.append("this host's memory could not be read (/proc/meminfo), so "
                            "a mesh beside the build cannot be shown to fit")
    else:
        head = avail - host_resources.HOST_RESERVE_BYTES
        if building:
            flag = host_resources.build_memory_flag(env=env, meminfo=mi)
            if flag is None:
                plan.reasons.append(
                    f"the build runs without a memory cap ({host_resources.MEMORY_ENV} "
                    "is off), so it may use all of this host's memory — a mesh beside "
                    "it could starve it")
                head = 0
            else:
                cap = _size_bytes(flag)
                head -= cap
                plan.notes.append(f"the build may use up to {_gib(cap)} "
                                  f"({host_resources.MEMORY_ENV})")
        plan.headroom_bytes = max(0, head)
        if head < need and not any("memory cap" in r for r in plan.reasons):
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


class AlongsideMesh:
    """The saved mesh ``rec``, run beside a build from its own worktree and project."""

    def __init__(self, generator_dir: str, rec: saved_meshes.SavedMesh):
        self.generator_dir = os.path.abspath(generator_dir)
        self.rec = rec
        self.project = str((rec.lanes or {}).get("compose_project") or "")
        if not self.project.startswith(PROJECT_PREFIX):
            self.project = project_for(rec.id)

    @property
    def worktree(self) -> str:
        return os.path.join(alongside_root(), self.rec.id, "generator")

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
        """``git worktree add --detach`` of the checkout's HEAD (reused when present)."""
        wt = self.worktree
        if os.path.exists(os.path.join(wt, ".git")):
            return True, f"worktree {wt} (reused)"
        os.makedirs(os.path.dirname(wt), exist_ok=True)
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

    def start(self, *, building: bool, on_line=None, cancel=None,
              meminfo: dict | None = None, env=None,
              is_free=port_free, holder=port_holder) -> tuple[bool, list[str]]:
        """Gate, then bring the mesh up beside the build. Never raises."""
        log: list[str] = []

        def note(line: str) -> None:
            log.append(line)
            if on_line is not None:
                try:
                    on_line(line)
                except Exception:        # noqa: BLE001 — a viewer never sinks the start
                    pass
        try:
            plan = plan_alongside(self.boot_config(), building=building, meminfo=meminfo,
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
            self._record_lanes(plan.ports)
            ok, _lines = boot.up(on_line=note, cancel=cancel)
            note(f"[local mesh] {'up' if ok else 'FAILED'} — compose project "
                 f"{self.project}" + (f", front door {boot._stack_node().web_url}"
                                      if ok else ""))
            if ok:
                self._mark_ran()
            return ok, log
        except Exception as e:           # noqa: BLE001 — never fails the build
            note(f"[local mesh] FAILED: {e}")
            return False, log

    def stop(self) -> tuple[bool, list[str]]:
        """``make stack-halt`` for THIS project only (volumes kept). Never the
        bootstrap's down(), which also stops the operator's tailnet overlay."""
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

    def _record_lanes(self, ports: dict) -> None:
        self.rec.lanes = dict(self.rec.lanes or {})
        self.rec.lanes["compose_project"] = self.project
        self.rec.lanes["host_ports"] = dict(ports)
        self.rec.lanes["worktree"] = self.worktree
        self.rec.notes = [n for n in self.rec.notes if not n.startswith("Runs beside")]
        self.rec.notes.append(
            f"Runs beside its node-image build as compose project {self.project} from "
            f"the worktree {self.worktree} (ports: " + ", ".join(
                f"{k}={v}" for k, v in ports.items()) + ").")
        saved_meshes.save(self.rec)

    def _mark_ran(self) -> None:
        self.rec.last_seen = dict(self.rec.last_seen or {})
        self.rec.last_seen.update({"compose_running": True, "running_env": "test",
                                   "at": saved_meshes._now()})
        saved_meshes.save(self.rec)


# ── CLI (parity with the GUI's Save strip and the progress page) ───────────────
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
    g = sub.add_parser("gate", help="say whether a saved mesh can start beside a build")
    g.add_argument("record")
    g.add_argument("--not-building", action="store_true")
    st = sub.add_parser("start", help="start a saved mesh beside a build")
    st.add_argument("record")
    st.add_argument("--not-building", action="store_true")
    sp = sub.add_parser("stop", help="stop a saved mesh started beside a build")
    sp.add_argument("record")
    args = ap.parse_args(argv)
    if args.verb == "save":
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
    lane = AlongsideMesh(args.generator_dir, rec)
    if args.verb == "gate":
        plan = plan_alongside(lane.boot_config(), building=not args.not_building)
        print("\n".join(plan.lines()))
        return 0 if plan.ok else 1
    if args.verb == "start":
        ok, _ = lane.start(building=not args.not_building, on_line=print)
        return 0 if ok else 1
    ok, lines = lane.stop()
    print("\n".join(lines))
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
