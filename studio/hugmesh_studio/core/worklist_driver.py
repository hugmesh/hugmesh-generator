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
``docker --privileged``); the per-entry ``build_subdir`` is the later parallelism seam.

Qt-free by construction — the GUI wraps :meth:`run_all` in a QThread and connects the
callbacks to signals; the headless tests drive it directly.
"""
from __future__ import annotations

import getpass
import json
import os
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

from .build_driver import BuildDriver
from .config import DOMAIN_IDP_SUPERDOMAIN, ImageConfig, image_class
from .platform_info import HostInfo, detect
from .worklist import WorklistConfig, WorklistEntry

# ── role → gen-provision-keys.sh key PROFILE ────────────────────────────────────────
# gen-provision-keys.sh only knows {pki, backend, frontend, host, ...}. build-all-roles.sh
# maps the fuller Studio/builder role set onto those profiles; mirror it here so the
# per-image key folder a node provisions from is generated with the RIGHT profile. Only
# NODE-class entries get keys (desktops take none); anything unmapped falls back to the
# 'host' worker profile (the fleet script's default for client/appliance images).
KEY_PROFILE: dict[str, str] = {
    "pki": "pki",
    "be": "backend",
    "fe": "frontend",
    "be+gpu": "backend",
    "omnibus": "pki",        # single-node control plane — the 'full' analogue -> pki
    "edge_ai": "host",       # GPU worker (build-all-roles: edge_ai/gpu-host -> host)
    "full": "pki",           # jetson single-node control plane -> pki
    "gpu-host": "host",      # jetson GPU worker -> host
    "generic": "host",       # plain arm64 server appliance
    "orangepizero2": "host",  # headless appliance
    "orangepizero2w": "host",  # headless appliance (Zero 2's H618 sibling)
    "orangepizero3": "host",  # headless appliance (Zero 2's H618 sibling)
    "orangepi3-lts": "host",  # headless appliance (Allwinner H6, pre-H616 gen)
    "orangepi4-lts": "host",  # light DESKTOP (Rockchip RK3399) — no flash-disk.sh
                              # desktop role token exists, so it maps to the generic
                              # host artifact glob like every other client image
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


def key_profile(role: str, platform: str = "") -> str:
    """The gen-provision-keys.sh ``--role`` profile for a Studio/builder role id."""
    return KEY_PROFILE.get(role, "host")


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
                 workdir: str | None = None):
        self.generator_dir = os.path.abspath(generator_dir)
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
        problems = self._output_dir_problems()
        per_entry = [(entry.id, BuildDriver(self.generator_dir, self.host,
                        graphical=self.graphical, workdir=self.workdir)
                      .preflight(cfg, self.backend))
                     for entry, cfg in self.materialize()]
        return problems + self._aggregate_per_entry(per_entry)

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
        return [f"Output directory is not writable: {probe} is owned by '{owner}' and "
                f"this Studio runs as '{getpass.getuser()}'. A native (sudo) build "
                f"leaves root-owned dirs behind; fix with: "
                f"sudo chown -R {getpass.getuser()} {probe}"]

    def preflight_warnings(self) -> list[str]:
        """Aggregate ADVISORY warnings (see BuildDriver.preflight_warnings) — the
        parallel non-blocking channel: rendered alongside the problems pane and
        written as leading Progress log lines, gating NOTHING and throttling
        nothing. Same dedupe shape as preflight()."""
        per_entry = [(entry.id, BuildDriver(self.generator_dir, self.host,
                        graphical=self.graphical, workdir=self.workdir)
                      .preflight_warnings(cfg, self.backend))
                     for entry, cfg in self.materialize()]
        return self._aggregate_per_entry(per_entry)

    # ---- mesh manifest v2 (design 2.6) ------------------------------------
    def manifest_v2(self) -> dict:
        base = self.worklist.base
        images = [{"id": entry.id, "role": entry.role, "platform": entry.platform,
                   "board": entry.board, "flavor": entry.flavor,
                   "encrypt_root": bool(cfg.encrypt_root)}
                  for entry, cfg in self.materialize()]
        return {
            "format": 2,
            "brand": base.brand, "brand_title": base.brand_title, "org": base.org,
            "cluster_domain": base.cluster_domain,
            "superdomain": base.effective_superdomain(),
            # per-domain idp (issue #47) is OMIT-WHEN-DEFAULT, exactly like the v1
            # shim (config.mesh_manifest): absent == superdomain for every consumer,
            # so a superdomain-only envelope keeps its pre-#47 bytes.
            "domains": [{"name": d.name, "title": d.title,
                         "optional_services": list(d.optional_services),
                         "images": list(d.images),
                         **({"idp": d.idp}
                            if d.idp != DOMAIN_IDP_SUPERDOMAIN else {})}
                        for d in base.domains],
            "users": [asdict(u) for u in base.users],
            "images": images,
        }

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

            driver = BuildDriver(self.generator_dir, self.host, graphical=self.graphical,
                                 workdir=self.workdir)
            with self._lock:
                self._drivers[i] = driver
            code = driver.run(cfg, self.backend,
                              on_line=(lambda ln, i=i: on_line(i, ln)) if on_line else None)
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

        return self.summary_exit_code()

    def _generate_keys(self, i: int, entry: WorklistEntry,
                       on_line: Callable[[int, str], None] | None,
                       on_keys: Callable[[int, str, bool], None] | None) -> None:
        """Generate the per-node KEYS folder (mesh, node-class, opt-in). A failure is
        recorded (keys_ok=False) and the partial folder removed — mirroring
        build-all-roles.sh, where a half-written keys-<role> must never look like a
        deliverable — but does NOT abort the remaining images."""
        keys_dir_ = keys_dir(self._output_dir(), entry.id)
        res = self.results[i]
        res.keys_path = keys_dir_
        script = os.path.join(self.generator_dir, GENKEYS_SCRIPT)
        cmd = [script, "--role", key_profile(entry.role, entry.platform),
               "--out", keys_dir_, "--random"]
        try:
            proc = subprocess.Popen(cmd, cwd=self.generator_dir, stdout=subprocess.PIPE,
                                    stderr=subprocess.STDOUT, text=True, bufsize=1,
                                    **proc_text.TEXT_IO)
            assert proc.stdout is not None
            for line in proc.stdout:
                if on_line:
                    on_line(i, line.rstrip("\n"))
            code = proc.wait()
        except OSError as e:
            if on_line:
                on_line(i, f"!! keys generation could not start: {e}")
            code = 1
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
