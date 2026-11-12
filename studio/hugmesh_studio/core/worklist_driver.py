"""WorklistDriver — sequential, failure-tolerant execution of a worklist (design 2.5).

The worklist envelope (:mod:`.worklist`) is a MODEL; this is the runner. It projects the
envelope with :meth:`WorklistConfig.materialize` and builds each entry in turn with a FRESH
:class:`~.build_driver.BuildDriver` per image — that per-image driver is what makes an
honest per-image Stop possible (its cancel targets exactly one build's container / process
group). Failure is tolerated, not fatal: a failed image is recorded red and the run
CONTINUES, exactly like ``scripts/build-all-roles.sh``'s ``BUILDS_FAILED`` accumulation,
and the aggregate summary exit code is nonzero if anything did not finish clean.

It also owns the ONCE-PER-WORKLIST steps that used to live in ``BuildPage._build``:

* the mesh manifest v2 envelope (``format: 2`` + ``images[]``) is written up front;
* after each successful NODE build, provisioning key material is generated via
  ``scripts/gen-provision-keys.sh`` — the role→key-profile map mirrors
  ``build-all-roles.sh`` so bypassing the fleet script does not silently LOSE the keys a
  node provisions from. Mesh-only, and opt-out (the Review page's "generate node key-zips"
  checkbox, default on).

Sequential-only in v1 (same-arch build trees + loop-device contention under
``docker --privileged``); the per-entry ``build_subdir`` is the later hook for parallelism.

Qt-free by construction — the GUI wraps :meth:`run_all` in a QThread and connects the
callbacks to signals; the headless tests drive it directly.
"""
from __future__ import annotations

import getpass
import json
import ntpath
import os
import re
import shlex
import shutil
import subprocess
import threading

try:  # POSIX only — absent on Windows, where the MSI installs this same code.
    import pwd
except ImportError:  # pragma: no cover - exercised on Windows, not in CI
    pwd = None  # type: ignore[assignment]

from . import proc_text
from collections.abc import Callable
from dataclasses import asdict, dataclass, field

from .build_driver import (BuildDriver, disk_space_refusal, disk_space_warning,
                           dispatch_space_refusal)
from . import domain_ca_keys
from . import mesh_control, pki_lan
from . import roles
from .config import (ImageConfig, User, brand_header_fields, image_class,
                     manifest_domain_rows)
from .platform_info import HostInfo, detect
from .worklist import WorklistConfig, WorklistEntry

# ── role → gen-provision-keys.sh key PROFILE ────────────────────────────────────
# THE table lives in scripts/_roles-lib.sh (HUGMESH_ROLE_KEYPROFILE) and is read
# through core/roles.py. It used to be a hand-written dict here — the FOURTH copy of
# the same mapping (build-x86's printed hints and docker/build-image.sh's two
# identical blocks were the others) — and it ended in ``.get(role, "host")``.
#
# That silent fallback is the reason this is not a cosmetic change. The old dict knew
# `be`/`fe` and did NOT know `backend`/`frontend`, so renaming only the Studio id
# would have quietly downgraded every backend and frontend node to the `host` worker
# keys profile: a node provisioned with the wrong credentials, reported as success.
# There is no fallback now.
#
# Only NODE-class images reach here (the caller gates on image_class == "node").
# A handful of Studio role IDS are not role tokens at all — they are PLATFORM names
# used as role ids by the standalone/cloud mode menus (frite, orangepi5, the Orange
# Pi appliances). Those are listed here explicitly, with the reason, rather than
# absorbed by a catch-all: each is a single-role client/appliance image that
# provisions from the plain `host` worker profile exactly like the Frite client
# (mirrors scripts/build-all-roles.sh's own per-platform keys blocks).
_PLATFORM_PSEUDO_ROLE_PROFILE: dict[str, str] = {
    "frite": "host",
    "orangepi5": "host",
    "orangepizero2": "host",
    "orangepizero2w": "host",
    "orangepizero3": "host",
    "orangepi3-lts": "host",
    "orangepi4-lts": "host",
}


GENKEYS_SCRIPT = os.path.join("scripts", "gen-provision-keys.sh")
MANIFEST_NAME = "hugmesh-mesh-manifest.json"

# Per-image terminal/lifecycle states (mirror the ProgressPage row icons).
QUEUED, RUNNING, OK, FAILED, STOPPED = "queued", "running", "ok", "failed", "stopped"


def keys_dir(out_dir: str, entry_id: str) -> str:
    """``<out>/keys-<entry id>`` — the folder ``gen-provision-keys.sh`` is pointed at
    for one node, and therefore the folder an operator actually opens to find that
    node's credentials.

    Module-level and pure because it has TWO callers that must never disagree:
    :meth:`WorklistDriver._generate_keys`, which creates it, and the ask-20 users
    card, whose whole job is to tell the operator where it will be. ``out_dir`` is
    whatever ``_output_dir()`` resolves to for the run — on the GUI path that is ALWAYS
    the per-session dir (``progress.py`` passes ``workdir=session.workdir``), never the
    bare output dir.
    """
    return os.path.join(out_dir, f"keys-{entry_id}")


def node_key_profiles(worklist) -> list[str] | None:
    """The KEYS profile of every NODE image in ``worklist`` (the images the keys step
    runs for), or None when there is no worklist yet. An entry with no declared
    profile is skipped here; the keys step itself fails it loudly."""
    if worklist is None:
        return None
    base = worklist.base
    out = []
    for e in worklist.entries:
        if image_class(base.mode, e.role) != "node":
            continue
        try:
            out.append(key_profile(e.role, e.platform))
        except roles.RoleVocabularyError:
            continue
    return out


def key_profile(role: str, platform: str = "") -> str:
    """The gen-provision-keys.sh ``--role`` profile for a Studio/builder role id.

    Raises :class:`roles.RoleVocabularyError` for an id with no declared profile.
    Deliberately loud: the previous ``.get(role, "host")`` answered every unknown id
    with the worker profile, so a stale table produced a node holding the wrong
    credentials and nothing anywhere said so. The caller turns this into a failed
    KEYS step for that one image, not a wrong one.
    """
    pseudo = _PLATFORM_PSEUDO_ROLE_PROFILE.get(role)
    if pseudo is not None:
        return pseudo
    return roles.key_profile(role)


@dataclass
class EntryResult:
    entry: WorklistEntry
    index: int
    status: str = QUEUED
    exit_code: int | None = None
    keys_path: str | None = None
    keys_ok: bool | None = None   # None = not attempted (desktop / non-mesh / opt-out)


class WorklistDriver:
    def __init__(self, generator_dir: str, worklist: WorklistConfig,
                 host: HostInfo | None = None, backend: str | None = None,
                 generate_keys: bool = True, graphical: bool = False,
                 workdir: str | None = None,
                 ca_store: "domain_ca_keys.DomainCAStore | None" = None):
        self.generator_dir = os.path.abspath(generator_dir)
        # The Domain CA keys step's in-memory store (None = the process store). An
        # empty store adds nothing to any gen-provision-keys.sh call.
        self.ca_store = ca_store
        self.worklist = worklist
        self.host = host or detect()
        self.backend = backend or self.host.default_backend
        self.generate_keys = generate_keys
        # Runtime-only work-dir override (per-session artifact dirs): None — every
        # headless/golden channel — keeps _output_dir() and every per-image BuildDriver
        # byte-identical to before. The GUI's ProgressPage passes the per-session
        # <out>/sessions/<id>/ dir here at REAL dispatch; it is driver state, never
        # written into the config, so previews/goldens for the same config only differ
        # where the run itself will (the -w / docker -v out mount).
        self.workdir = workdir
        # Threaded to every per-image BuildDriver this driver constructs so a GUI-launched
        # native build (the ProgressPage's run driver, graphical=True) elevates through a
        # graphical auth path instead of prompting into an invisible terminal.
        self.graphical = graphical
        self._materialized: list[tuple[WorklistEntry, ImageConfig]] | None = None
        self.results: list[EntryResult] = [
            EntryResult(entry=e, index=i) for i, e in enumerate(worklist.entries)]
        # cancel plumbing (callbacks fire from the run thread; cancel(i)/cancel_all() from
        # the GUI thread) — a lock guards the live-driver handle map.
        self._cancel_all = threading.Event()
        self._cancelled: set[int] = set()
        self._drivers: dict[int, BuildDriver] = {}
        self._current = -1
        self._lock = threading.Lock()

    # ---- projection --------------------------------------------------------
    def materialize(self) -> list[tuple[WorklistEntry, ImageConfig]]:
        """Cached ``worklist.materialize()`` so preflight, the manifest, and the run all
        agree on the exact same projected configs."""
        if self._materialized is None:
            self._materialized = self.worklist.materialize()
        return self._materialized

    def _is_mesh(self) -> bool:
        return self.worklist.base.mode == "mesh"

    def _output_dir(self) -> str:
        return (self.workdir or self.worklist.base.output_dir
                or os.path.join(self.generator_dir, "out"))

    # ---- previews / preflight ---------------------------------------------
    def command_string(self, cfg: ImageConfig, backend: str | None = None) -> str:
        """The exact per-image builder invocation (for the Review page's Preview button).
        Delegates to a throwaway BuildDriver so flag translation stays single-sourced —
        including the session workdir override, which is what keeps the preview honest
        (it shows LITERALLY the -w the dispatched build will run with)."""
        return BuildDriver(self.generator_dir, self.host, graphical=self.graphical,
                           workdir=self.workdir).command_string(cfg, backend or self.backend)

    @staticmethod
    def _aggregate_per_entry(per_entry: list[tuple[str, list[str]]]) -> list[str]:
        """Shared dedupe shape for preflight() and preflight_warnings(): a message
        common to EVERY image is reported once (unlabelled); an image-specific one is
        prefixed ``[<entry.id>]``."""
        if len(per_entry) <= 1:
            return per_entry[0][1] if per_entry else []
        n = len(per_entry)
        counts: dict[str, int] = {}
        for _eid, probs in per_entry:
            for p in probs:
                counts[p] = counts.get(p, 0) + 1
        out: list[str] = []
        shared_done: set[str] = set()
        for eid, probs in per_entry:
            for p in probs:
                if counts[p] == n:                       # every image has it -> once
                    if p not in shared_done:
                        out.append(p)
                        shared_done.add(p)
                else:
                    out.append(f"[{eid}] {p}")
        return out

    def preflight(self) -> list[str]:
        """Aggregate preflight problems (empty = OK) — the BLOCKING channel: this is
        what the Review page's problems pane renders and isComplete() keys on, and
        what ProgressPage refuses dispatch over."""
        problems = self._output_dir_problems() + self._disk_space_problems()
        # A mesh's KEYS sticks need the pki node's fixed LAN address (core/pki_lan.py):
        # without it every worker dials a public URL that cannot answer before go-live.
        # Blocking here, where the Review page and the dispatch refuse, and only when
        # this run makes sticks.
        if self.generate_keys and self._is_mesh():
            pki_problem = pki_lan.problem(self.worklist.base)
            if pki_problem:
                problems.append(pki_problem)
            problems += mesh_control.problems(self.worklist)
        per_entry = [(entry.id, BuildDriver(self.generator_dir, self.host,
                        graphical=self.graphical, workdir=self.workdir)
                      .preflight(cfg, self.backend))
                     for entry, cfg in self.materialize()]
        return problems + self._aggregate_per_entry(per_entry)

    def _build_tree(self, entry: WorklistEntry) -> str:
        """This image's ``wl-<id>`` dir under the work dir. On a RESTART into the same
        session it holds the build system the earlier run left, and the free-space
        check counts what that holds (build_driver.image_space)."""
        return os.path.join(self._output_dir(), entry.build_subdir)

    def _disk_space_problems(self) -> list[str]:
        """Can the output filesystem take the NEXT image? (empty = yes)

        Only the first entry blocks the session: a later one that will not fit is
        refused by run_all()'s re-check when its turn comes, and an ARM image after it
        may still fit. preflight_warnings() says up front when the whole list will not.

        This runs on the GUI thread at dispatch, so it never measures a build tree an
        earlier run left: it takes one as finished and refuses only what would not fit
        even then. run_all() measures before it starts the image."""
        materialized = self.materialize()
        if not materialized:
            return []
        entry, cfg = materialized[0]
        why = disk_space_refusal(cfg, self._output_dir(),
                                 build_tree=self._build_tree(entry))
        return [why] if why else []

    def _output_dir_problems(self) -> list[str]:
        """Can this run actually WRITE where it is about to write? (empty = yes)

        Same rule BuildDriver.preflight() states for builder-hard-errors: catching a
        guaranteed-fatal condition here turns a post-dispatch dead end into a message on
        the Review page. This one is not hypothetical — a NATIVE (sudo) build creates
        ``<out>/sessions/`` and ``<out>/shared/`` as ROOT, and the Studio itself runs as
        the desktop user, so the next GUI run cannot create its own session dir. A mesh
        hit it hardest: run_all() writes the v2 manifest into the session workdir BEFORE
        the first image starts, so the whole run died at "queued" with an empty log.

        Checked against the nearest EXISTING ancestor: the session dir usually does not
        exist yet (we are about to make it), so the parent's writability is the real
        question."""
        out = self._output_dir()
        probe = os.path.abspath(out)
        while not os.path.exists(probe):
            parent = os.path.dirname(probe)
            if parent == probe:            # walked to the root without finding anything
                return [f"Output directory is unreachable: {out}"]
            probe = parent
        if os.access(probe, os.W_OK | os.X_OK):
            return []
        try:
            # Without pwd (Windows) the numeric uid is still the honest answer, and
            # the advice below is POSIX-shaped anyway — this whole warning is about
            # a root-owned output directory left by a native sudo build.
            owner = pwd.getpwuid(os.stat(probe).st_uid).pw_name if pwd else str(os.stat(probe).st_uid)
        except (KeyError, OSError):
            owner = str(os.stat(probe).st_uid)
        # The remedy prunes any directory named `sysroot`: a build system that a
        # person chowns to themselves produces, on the next --resume, an image
        # whose every directory is theirs and whose sshd and tor refuse to start
        # (hugmesh-generator#659). Same shape as the Makefile's chown-artifacts.
        user = getpass.getuser()
        # Quoted: a path with a space in it would otherwise be two arguments to find.
        return [f"Output directory is not writable: {probe} is owned by '{owner}' and "
                f"this Studio runs as '{user}'. A native (sudo) build "
                f"leaves root-owned dirs behind; fix with: "
                f"sudo find {shlex.quote(probe)} -type d -name sysroot -prune -o -exec chown -h {shlex.quote(user)} {{}} + "
                f"(not 'chown -R' over the whole directory: the build system "
                f"snap-build-*/sysroot under it must stay root's, or a later "
                f"--resume builds a broken image)"]

    def preflight_warnings(self) -> list[str]:
        """Aggregate ADVISORY warnings (see BuildDriver.preflight_warnings) — the
        parallel non-blocking channel: rendered alongside the problems pane and
        written as leading Progress log lines, gating NOTHING and throttling
        nothing. Same dedupe shape as preflight()."""
        per_entry = [(entry.id, BuildDriver(self.generator_dir, self.host,
                        graphical=self.graphical, workdir=self.workdir)
                      .preflight_warnings(cfg, self.backend))
                     for entry, cfg in self.materialize()]
        materialized = self.materialize()
        space = disk_space_warning(
            [cfg for _entry, cfg in materialized], self._output_dir(),
            build_trees=[self._build_tree(entry) for entry, _cfg in materialized])
        return self._aggregate_per_entry(per_entry) + ([space] if space else [])

    # ---- mesh manifest v2 (design 2.6) ------------------------------------
    def manifest_v2(self) -> dict:
        base = self.worklist.base
        # "hostname" is the EXPLICIT per-image name the build bakes ("" = the builder
        # derives its role name) — additive since issue #229, so a provisioning
        # consumer can tell the nodes apart by the name each one actually boots with.
        images = [{"id": entry.id, "role": entry.role, "platform": entry.platform,
                   "board": entry.board, "flavor": entry.flavor,
                   "encrypt_root": bool(cfg.encrypt_root),
                   "hostname": cfg.hostname}
                  for entry, cfg in self.materialize()]
        return {
            "format": 2,
            # The header and the rows come from the SAME two functions the v1 shim
            # (config.mesh_manifest) calls (#654, D5): the header is a projection of
            # the record's superbrand block, and the rows carry every Domain field by
            # the field list — idp OMIT-WHEN-DEFAULT (#47), tor/look/ways/issuer_port/github_org
            # OMIT-WHEN-EMPTY — so the two emitters cannot disagree and a field added
            # to Domain reaches this envelope without a change here. (Until #654 this
            # spelled its own four-key row and would have dropped any new field.)
            **brand_header_fields(base.brand, base.brand_title, base.org,
                                  base.cluster_domain, base.effective_superdomain(),
                                  base.login_style, base.login_decor),
            "domains": manifest_domain_rows(base.domains),
            # per-user `roles` (issue #228) is OMIT-WHEN-SINGLE too (User.to_dict), so
            # v2 and the v1 shim emit the same user rows byte for byte.
            "users": [u.to_dict() for u in self.manifest_users()],
            "images": images,
            # the own domain's per-domain services (#494): OMIT-WHEN-EMPTY, exactly
            # as the v1 shim (config.mesh_manifest) emits it.
            **({"cluster_domain_services": list(base.cluster_domain_services)}
               if base.cluster_domain_services else {}),
            # the own domain's export org: OMIT-WHEN-EMPTY, exactly as the v1 shim.
            **({"cluster_domain_github_org": base.cluster_domain_github_org.strip()}
               if (getattr(base, "cluster_domain_github_org", "") or "").strip() else {}),
        }

    def manifest_users(self) -> list[User]:
        """The Users the mesh manifest carries: the Users-table rows PLUS the people
        named on desktop entries (issue #279). Before this, manifest_v2 emitted
        ``base.users`` alone, so a desktop-derived person reached every per-image
        ``ImageConfig.users`` (and the v1 shim's ``mesh_manifest()``) but never the
        one artifact cluster provisioning actually reads — the account the
        2026-08-14 ask was for was never created. Same source and same dedup as
        ``WorklistConfig._materialize_one`` step 3, so the v2 envelope and every
        image's v1 shim agree row for row: a Users-table row (richer: email /
        registration) always wins over the derived one."""
        base = self.worklist.base
        users = list(base.users)
        users += self.worklist.desktop_users(
            skip={(u.username, u.domain) for u in users})
        return users

    def write_manifest_v2(self) -> str:
        out = self._output_dir()
        os.makedirs(out, exist_ok=True)
        path = os.path.join(out, MANIFEST_NAME)
        with open(path, "w", encoding="utf-8") as fh:
            json.dump(self.manifest_v2(), fh, indent=2)
        return path

    # ---- the run -----------------------------------------------------------
    def run_all(self,
                on_entry_start: Callable[[int], None] | None = None,
                on_line: Callable[[int, str], None] | None = None,
                on_entry_done: Callable[[int, int | None], None] | None = None,
                on_manifest: Callable[[str], None] | None = None,
                on_keys: Callable[[int, str, bool], None] | None = None) -> int:
        """Build every entry sequentially, tolerating failures. Returns the aggregate
        summary exit code (0 iff every image finished OK and no keys generation failed).
        Callbacks are optional; the GUI worker wires them to Qt signals."""
        materialized = self.materialize()
        if self._is_mesh():
            mpath = self.write_manifest_v2()
            if on_manifest:
                on_manifest(mpath)

        for i, (entry, cfg) in enumerate(materialized):
            res = self.results[i]
            if self._cancel_all.is_set() or i in self._cancelled:
                res.status = STOPPED
                if on_entry_done:
                    on_entry_done(i, None)
                continue

            res.status = RUNNING
            with self._lock:
                self._current = i
            if on_entry_start:
                on_entry_start(i)

            # Re-check free space before EVERY image (defect L4). Earlier images' build
            # trees and products stay in the session dir, so the disk that held image 1
            # may not hold image 5. A refused image is never dispatched: it takes the
            # normal FAILED path below, and its "!!" line is what the session record's
            # error tail keeps, instead of an ENOSPC crash an hour into the build.
            #
            # On a RESTART the image's build tree from the earlier run is still in the
            # session dir, and what it holds is not needed again. This is the build
            # thread, so that tree is measured here when the answer depends on it (it
            # can take minutes, hence the line before it and the Stop check during it).
            refusal = dispatch_space_refusal(
                cfg, self._output_dir(), build_tree=self._build_tree(entry),
                should_stop=lambda i=i: self._stop_requested(i),
                on_measure=(lambda tree, i=i: on_line(
                    i, f"== free disk space: measuring the build tree an earlier run "
                       f"left at {tree} (up to a few minutes on a slow disk) ..."))
                if on_line else None)
            if refusal is None or self._stop_requested(i):
                # Stopped before anything was dispatched (most likely while the tree
                # was being measured). There is no driver to cancel and no verdict to
                # report: the row settles STOPPED below, with no exit code.
                code = None
            elif refusal:
                if on_line:
                    on_line(i, f"!! {entry.id} not started: {refusal}")
                code = 1
            else:
                driver = BuildDriver(self.generator_dir, self.host,
                                     graphical=self.graphical, workdir=self.workdir)
                with self._lock:
                    self._drivers[i] = driver
                try:
                    code = driver.run(cfg, self.backend,
                                      on_line=(lambda ln, i=i: on_line(i, ln)) if on_line else None)
                except Exception as e:  # noqa: BLE001 - one image's raise must not strand the run
                    # #374: ElevationRefused (HUGMESH_STUDIO_NO_ELEVATION / pytest) or an
                    # OSError from Popen. Left to propagate, this entry stayed RUNNING and
                    # registered, on_entry_done never fired, and the session was recorded
                    # 'stopped' (the operator-Stop state). Fail THIS image and keep going —
                    # the same tolerate-failures contract as a non-zero exit.
                    if on_line:
                        on_line(i, f"!! {e}")
                    code = 1
            with self._lock:
                self._drivers.pop(i, None)
                cancelled = i in self._cancelled or self._cancel_all.is_set()

            res.exit_code = code
            if cancelled:
                res.status = STOPPED
            elif code == 0:
                res.status = OK
            else:
                res.status = FAILED

            if (self.generate_keys and self._is_mesh() and res.status == OK
                    and image_class(cfg.mode, entry.role) == "node"):
                self._generate_keys(i, entry, on_line, on_keys)

            if on_entry_done:
                on_entry_done(i, code)

        if self.generate_keys and self._is_mesh():
            self._hand_mesh_ca_on(on_line)
        # The control onion's secret key leaves this computer on the pki stick only: it
        # is removed here once a stick this run made holds an identical copy (a failed or
        # stopped pki keys step keeps it, for the re-run). The address stays.
        if self.generate_keys and self._is_mesh():
            mesh_control.forget_secret(
                self.worklist.base, self._output_dir(),
                [r.keys_path for r in self.results if r.keys_ok and r.keys_path])
        return self.summary_exit_code()

    def _hand_mesh_ca_on(self, on_line: Callable[[int, str], None] | None) -> None:
        """Give every generated keys folder without one the pki stick's mesh CA CERTIFICATE.

        The pki node's headscale serves HTTPS with a certificate from the mesh CA its
        stick carries, and a node trusts it only through its own stick's ``certs/*.crt``
        (docs/HEADSCALE-DERP.md). With the Domain CA keys step every stick already gets
        ``--ca-cert``; without it the pki stick makes its own CA and the other sticks get
        none, so they could not log in. Mirrors scripts/build-all-roles.sh. The
        certificate only: a file that holds a private key is never copied."""
        done = [(i, r.keys_path) for i, r in enumerate(self.results) if r.keys_ok and r.keys_path]
        sources = [os.path.join(p, "certs", "cluster-ca.crt") for _, p in done
                   if os.path.isfile(os.path.join(p, "certs", "cluster-ca.key"))
                   and os.path.isfile(os.path.join(p, "certs", "cluster-ca.crt"))]
        if not sources:
            return
        try:
            with open(sources[0], "rb") as f:
                data = f.read()
        except OSError:
            return
        if b"PRIVATE KEY" in data or b"-----BEGIN CERTIFICATE-----" not in data:
            return
        for i, p in done:
            certs = os.path.join(p, "certs")
            if (os.path.isfile(os.path.join(certs, "cluster-ca.key"))
                    or os.path.isfile(os.path.join(certs, "cluster-ca.crt"))):
                continue
            try:
                os.makedirs(certs, exist_ok=True)
                with open(os.path.join(certs, "cluster-ca.crt"), "wb") as f:
                    f.write(data)
            except OSError as e:
                if on_line:
                    on_line(i, f"!! could not copy the mesh CA into {certs}: {e} — this node "
                               "cannot verify the mesh's headscale")
                continue
            if on_line:
                on_line(i, f"mesh CA: certs/cluster-ca.crt from {os.path.dirname(os.path.dirname(sources[0]))} "
                           "(this node trusts the mesh's headscale)")
        others = [s for s in sources[1:] if open(s, "rb").read() != data]
        if others and on_line:
            on_line(done[0][0], "!! another pki stick has its OWN mesh CA ("
                    + ", ".join(others) + "); nodes provisioned from it and from the other "
                    "sticks do not trust each other's headscale")

    def _genkeys_command(self, script: str, brand: str, args: list[str],
                         osname: str | None = None,
                         ca_dir: str | None = None) -> list[str]:
        """argv for ``gen-provision-keys.sh <args>`` (``args`` carries ``--out DIR``).

        On native Windows the script cannot be executed directly (WinError 193: it is
        bash), so every mesh build there ended FAILED at its keys step. With the docker
        backend it runs in the builder image instead, which is where the image build
        already runs the same script and which carries its tools (jq, openssl,
        ssh-keygen, python3, and keytool for the pki keystores); only the ``--out``
        value changes, to the mounted folder.
        ``osname`` is ``os.name`` unless a test passes another."""
        if (osname or os.name) != "nt" or self.backend != "docker":
            return [script, *args]
        args = list(args)
        i = args.index("--out") + 1
        # ntpath, not os.path: this branch only runs for native Windows, and a test on
        # Linux must split a C:\ path the way Windows does.
        parent, name = ntpath.split(ntpath.abspath(args[i]))
        args[i] = f"/keys/{name}"
        mounts = ["-v", f"{self.generator_dir}:/src", "-v", f"{parent}:/keys"]
        if ca_dir:
            # The Domain CA keys material (a private temp dir) is mounted READ-ONLY
            # at /ca and every path into it is rewritten; nothing else of it moves.
            mounts += ["-v", f"{ca_dir}:/ca:ro"]
            args = [self._ca_arg_in_container(a, ca_dir) for a in args]
        return ["docker", "run", "--rm", "--init", *mounts,
                "-e", f"BRAND={brand}", "-w", "/src", self.host.builder_image,
                "bash", "./" + GENKEYS_SCRIPT.replace(os.sep, "/"), *args]

    @staticmethod
    def _ca_arg_in_container(arg: str, ca_dir: str) -> str:
        """A host path into the CA temp dir -> its /ca path (also NAME=PATH)."""
        name, sep, value = arg.partition("=")
        target = value if sep else arg
        prefix = ca_dir.rstrip("\\/")
        if not (target == prefix or target.startswith(prefix + "\\")
                or target.startswith(prefix + "/")):
            return arg
        mapped = "/ca/" + ntpath.basename(target.replace("/", "\\"))
        return f"{name}={mapped}" if sep else mapped

    def _genkeys_line(self, line: str, out: str, osname: str | None = None) -> str:
        """One line of ``gen-provision-keys.sh`` output as the operator should read it.

        In the builder container (:meth:`_genkeys_command`) the script only knows the
        mounted ``/keys/<name>``, and its closing "Next:" advice is a Linux ``sudo
        ./scripts/make-keys-usb.sh /dev/sdX ...``: the log on Windows named a folder
        that exists only in the container and a command that cannot run there. The
        container path becomes the real folder (``out``), and the make-keys-usb step
        becomes what to do on Windows. Elsewhere the script ran on the host with the
        host path, so its lines are already true and pass unchanged."""
        if (osname or os.name) != "nt" or self.backend != "docker":
            return line
        host = ntpath.abspath(out)
        if "make-keys-usb.sh" in line and "/dev/sd" in line:
            step = re.match(r"\s*(?:\d+\.\s+)?", line).group(0)
            # make-keys-usb.sh partitions and formats a block device with parted and
            # mkfs.vfat -F 32, copies the folder, and leaves vault-seed/ off the stick;
            # the node finds the stick by its KEYS label. FAT32 only, never exFAT:
            # only the x86 and rpi5 kernels carry exFAT, so a jetson/frite/orangepi
            # node would not mount it and would come up unprovisioned. Windows'
            # Format dialog offers FAT32 only up to 32 GB, hence the size.
            return (f"{step}Make the KEYS stick: format a USB stick of 32 GB or less "
                    f"as FAT32 (not exFAT or NTFS, which some nodes cannot mount) "
                    f"with the volume label KEYS and copy everything in {host} onto "
                    f"it except its vault-seed folder (that is for Vault only, never "
                    f"the stick). make-keys-usb.sh does this on Linux; it cannot run "
                    f"on Windows.")
        name = re.escape(ntpath.basename(host))
        return re.sub(r"(?<![\w./-])/keys/" + name + r"((?:/[^\s'\"(),]*)?)",
                      lambda m: host + m.group(1).replace("/", "\\"), line)

    def _generate_keys(self, i: int, entry: WorklistEntry,
                       on_line: Callable[[int, str], None] | None,
                       on_keys: Callable[[int, str, bool], None] | None,
                       osname: str | None = None) -> None:
        """Generate the per-node KEYS folder (mesh, node-class, opt-in). A failure is
        recorded (keys_ok=False) and the partial folder removed — mirroring
        build-all-roles.sh, where a half-written keys-<role> must never look like a
        deliverable — but does NOT abort the remaining images."""
        keys_dir_ = keys_dir(self._output_dir(), entry.id)
        res = self.results[i]
        res.keys_path = keys_dir_
        script = os.path.join(self.generator_dir, GENKEYS_SCRIPT)
        base = self.worklist.base
        ca = None
        profile = ""
        try:
            # INSIDE the try on purpose: key_profile() now RAISES for a role with no
            # declared profile instead of guessing "host". That must fail this one
            # image's keys step (recorded, partial folder removed) — never abort the
            # rest of the worklist, and never silently mis-provision.
            #
            # The brand and the internal root name go WITH the call (#654, D5). Until
            # then the script was started with neither: gen-provision-keys.sh reads
            # BRAND from the environment (default hugmesh) and derives the superdomain
            # as <BRAND>.internal, so a worklist built for brand acme / root
            # acme.internal wrote provision.json entries for hugmesh.internal — the
            # one file every node reads to join the mesh. --superdomain is the
            # script's own flag; BRAND is its env knob (and the brands/<BRAND>.conf
            # profile selector the builders use for the same images).
            profile = key_profile(entry.role, entry.platform)
            # Domain CA keys: written for THIS call only and removed in the finally
            # below. The key path reaches the pki profile only (args_for).
            st = self.ca_store or domain_ca_keys.store()
            moved = domain_ca_keys.rekey_own(base, st)
            if moved:
                # the mesh's domain was renamed onto a row holding another
                # domain's CA: no stick is made from a store that does not follow
                # the config (every stick fails its keys step, with the reason)
                raise domain_ca_keys.CAImportError(moved)
            if profile == domain_ca_keys.KEY_PROFILE:
                # The go-live checklist gates the KEY: while it is not READY no CA
                # key is placed, and this pki stick is not made with a throwaway CA
                # in its place either (the stick fails, with the reason).
                refusal = domain_ca_keys.placement_refusal(
                    base, st, node_key_profiles(self.worklist))
                if refusal:
                    raise domain_ca_keys.CAImportError(refusal)
            # Only the pki stick's call ever has the key FILE written.
            ca = domain_ca_keys.materialize(
                st, with_key=(profile == domain_ca_keys.KEY_PROFILE))
            ca_args = ca.args_for(profile) if ca is not None else []
            if ca is not None and on_line:
                on_line(i, ("domain CA: this pki stick gets the signing key "
                            f"({domain_ca_keys.STICK_KEY_PATH}) and the public "
                            "certificates" if "--ca-key" in ca_args else
                            f"domain CA: this {profile} stick gets public "
                            "certificates only"))
            # The pki node's LAN address (core/pki_lan.py) goes onto EVERY stick: the
            # pki's own /etc/hosts rows and each worker's pre-go-live control dial.
            cmd = self._genkeys_command(script, base.brand, [
                "--role", profile,
                "--out", keys_dir_, "--random",
                "--superdomain", base.effective_superdomain(),
                *pki_lan.genkeys_args(base),
                *mesh_control.genkeys_args(base, self._output_dir()), *ca_args], osname,
                ca_dir=ca.root if ca is not None else None)
            env = dict(os.environ)
            env["BRAND"] = base.brand
            proc = subprocess.Popen(cmd, cwd=self.generator_dir, env=env,
                                    stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                                    **proc_text.TEXT_IO)
            assert proc.stdout is not None
            no_keytool = False
            for line in proc.stdout:
                no_keytool = no_keytool or line.strip() == "ERROR: need keytool"
                if on_line:
                    on_line(i, self._genkeys_line(line.rstrip("\n"), keys_dir_, osname))
            code = proc.wait()
            if code != 0 and no_keytool and cmd[:2] == ["docker", "run"] and on_line:
                # A builder image made before Dockerfile.build carried a JDK has no
                # keytool, which the pki node's keystores (gen-keystores.sh) need.
                on_line(i, f"!! the builder image {self.host.builder_image} has no "
                           f"keytool (a JDK tool the pki keystores need). Rebuild it from "
                           f"this checkout's Dockerfile.build, which installs one: docker "
                           f"build -f Dockerfile.build -t {self.host.builder_image} . in "
                           f"{self.generator_dir}")
            if code == 0 and ca is not None:
                # After the fact: did a CA private key land anywhere it must not?
                problems = domain_ca_keys.scan_keys_dir(keys_dir_, profile, ca.spki)
                for p in problems:
                    if on_line:
                        on_line(i, f"!! domain CA placement: {p}")
                if problems:
                    code = 1
        except domain_ca_keys.CAImportError as e:
            if on_line:
                on_line(i, f"!! keys generation not started: domain CA: {e}")
            code = 1
        except (OSError, roles.RoleVocabularyError) as e:
            if on_line:
                on_line(i, f"!! keys generation could not start: {e}")
            code = 1
        finally:
            if ca is not None:
                ca.cleanup()
        res.keys_ok = (code == 0)
        if not res.keys_ok:
            shutil.rmtree(keys_dir_, ignore_errors=True)  # never leave a partial folder
            if on_line:
                on_line(i, f"!! keys generation FAILED for {entry.id} — removed partial "
                           f"{keys_dir_}")
        if on_keys:
            on_keys(i, keys_dir_, bool(res.keys_ok))

    def summary_exit_code(self) -> int:
        """0 iff every image finished OK and every attempted keys generation succeeded —
        else 1 (build-all-roles.sh semantics: any BUILDS_FAILED or KEYS_FAILED -> exit 1)."""
        for r in self.results:
            if r.status != OK:
                return 1
            if r.keys_ok is False:
                return 1
        return 0

    # ---- cancel ------------------------------------------------------------
    def _stop_requested(self, i: int) -> bool:
        """Has the operator stopped image ``i`` (or the whole run)?"""
        with self._lock:
            return i in self._cancelled or self._cancel_all.is_set()

    def cancel(self, i: int) -> None:
        """Stop image ``i``: kill it if running, or skip it if not yet started (the
        sequential loop marks it stopped). Safe to call for a finished image."""
        with self._lock:
            self._cancelled.add(i)
            driver = self._drivers.get(i)
        if driver is not None:
            driver.cancel()

    def cancel_all(self) -> None:
        """Stop the whole run: kill the current image and skip every remaining one."""
        self._cancel_all.set()
        with self._lock:
            driver = self._drivers.get(self._current)
        if driver is not None:
            driver.cancel()
