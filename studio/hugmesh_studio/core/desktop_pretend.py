"""The Desktop step's "Check with emerge --pretend" — Qt-free.

Runs the image's OWN builder with ``--pretend-only`` (build-x86-host-stage4.sh; the
in-chroot half is scripts/_pretend-lib.sh) in the builder container, ONE AT A TIME
machine-wide, and parses the wire contract it prints:

    ==> Pretend result: status=clean|needs|error rc=N seed_python=a,b video_cards=x,y
    ==> Pretend needs: package.use <line>
    ==> Pretend needs: accept_keywords <line>
    ==> Pretend needs: mask <line>
    ==> Pretend needs: license <line>
    ===== PRETEND RESOLVER OUTPUT =====
    ... the last lines the resolver printed ...
    ===== END PRETEND RESOLVER OUTPUT =====

Exit status: 0 clean, 3 needs changes, anything else error. :func:`parse` FAILS CLOSED:
no result line, or a result line that contradicts the exit status, is "error".

The pretend sysroot lives in its own ``--build-subdir pretend-<hash of the desktop-relevant
config>`` under the out dir: it is never an image build's sysroot and nothing is packaged
from it. HONESTY: the run resolves seed + @world + payload in one pass; the real build
merges @world first and its own fail-fast gate re-checks the payload after that, so
"clean" means "no wall the resolver can see from the seed", not "the build will succeed"
(:data:`HONESTY_NOTE`, shown wherever a result is).

x86 only in this phase: the ARM builders cross-compile from the host and have no
pretend mode yet (:func:`supported`).
"""
from __future__ import annotations

import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from typing import Callable

from . import desktop_spec as ds

RESULT_PREFIX = "==> Pretend result: "
NEEDS_PREFIX = "==> Pretend needs: "
EXCERPT_BEGIN = "===== PRETEND RESOLVER OUTPUT ====="
EXCERPT_END = "===== END PRETEND RESOLVER OUTPUT ====="
EXIT_CLEAN, EXIT_NEEDS = 0, 3
STATUSES = ("clean", "needs", "error")
NEED_KINDS = ("package.use", "accept_keywords", "mask", "license")
#: The kinds an overlay may take; mask/license edits are the operator's call, never ours.
APPLICABLE_KINDS = ("package.use", "accept_keywords")

HONESTY_NOTE = (
    "This check resolves the seed + @world + this image's packages in ONE pass. The real "
    "build merges @world first and re-checks the packages after that, so 'clean' means "
    "'no USE or keyword wall the resolver can see from the seed', not 'the build will "
    "succeed'.")

MIN_FREE_GIB = 60
MIN_MEM_GIB = 8

_RESULT_RE = re.compile(
    r"^==> Pretend result: status=(?P<status>\w+) rc=(?P<rc>-?\d+) "
    r"seed_python=(?P<py>\S*) video_cards=(?P<vc>\S*)\s*$")
_NEEDS_RE = re.compile(r"^==> Pretend needs: (?P<kind>package\.use|accept_keywords|mask|license) (?P<line>\S.*)$")
_ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


@dataclass
class PretendResult:
    status: str = "error"
    rc: int = 1
    seed_python: list[str] = field(default_factory=list)
    video_cards: list[str] = field(default_factory=list)
    needs: list[tuple[str, str]] = field(default_factory=list)
    excerpt: list[str] = field(default_factory=list)
    reason: str = ""            # why status is error, in plain words
    run_id: str = ""
    log_path: str = ""

    def applicable_needs(self) -> list[ds.OverlayChange]:
        return [ds.OverlayChange(k, line) for k, line in self.needs if k in APPLICABLE_KINDS]

    def operator_needs(self) -> list[tuple[str, str]]:
        return [(k, line) for k, line in self.needs if k not in APPLICABLE_KINDS]

    def summary(self) -> dict:
        """What the config keeps (spec.last_pretend): no excerpt, no paths beyond the log."""
        return {"status": self.status, "run": self.run_id, "at": _now(),
                "needs": [f"{k} {line}" for k, line in self.needs],
                "seed_python": self.seed_python, "video_cards": self.video_cards,
                "log": self.log_path}

    def to_dict(self) -> dict:
        return asdict(self)


def _now() -> str:
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def parse(lines, exit_code: int | None = None) -> PretendResult:
    """Read the builder's output (an iterable of lines) into a PretendResult."""
    res = PretendResult()
    found = False
    in_excerpt = False
    for raw in lines:
        line = _ANSI.sub("", raw.rstrip("\n"))
        if line.startswith(EXCERPT_BEGIN):
            in_excerpt = True
            continue
        if line.startswith(EXCERPT_END):
            in_excerpt = False
            continue
        if in_excerpt:
            res.excerpt.append(line)
            continue
        m = _RESULT_RE.match(line)
        if m:
            found = True
            res.status = m["status"] if m["status"] in STATUSES else "error"
            res.rc = int(m["rc"])
            res.seed_python = [x for x in m["py"].split(",") if x]
            res.video_cards = [x for x in m["vc"].split(",") if x]
            continue
        m = _NEEDS_RE.match(line)
        if m:
            item = (m["kind"], ds.normalise_line(m["line"]))
            if item not in res.needs:
                res.needs.append(item)
    if not found:
        res.status = "error"
        res.reason = ("The builder printed no pretend result (it stopped before the "
                      "resolver ran — see the log).")
    elif res.status == "needs" and not res.needs:
        res.status, res.reason = "error", "The result said 'needs' but named no change."
    elif res.status == "clean" and res.needs:
        res.status, res.reason = "error", "The result said 'clean' but also named changes."
    if exit_code is not None and res.status != "error":
        want = {"clean": EXIT_CLEAN, "needs": EXIT_NEEDS}[res.status]
        if exit_code != want:
            res.reason = (f"The builder exited {exit_code}, which contradicts "
                          f"status={res.status}.")
            res.status = "error"
    if res.status == "error" and not res.reason:
        res.reason = "The resolution failed without naming a USE or keyword change."
    return res


# ── which configs can be checked ─────────────────────────────────────────────


def supported(cfg) -> str:
    """"" when this config can run the check, else why not."""
    if not ds.applies(cfg):
        return "This image builds no desktop."
    if not ds.is_x86(cfg):
        return ("The emerge --pretend check runs on x86 images for now: the ARM builders "
                "cross-compile from the host and have no pretend mode yet.")
    return ""


def pretend_config(cfg):
    """The config the check actually runs: the image's own, plus --pretend-only and its
    own build subdir; the extra accounts are left out (they change no package and their
    passwords exist only at build time)."""
    pcfg = copy.deepcopy(cfg)
    spec = ds.spec_of(pcfg)
    spec.extra_users = []
    ds.store(pcfg, spec)
    pcfg.local_pass = ""
    pcfg.build_subdir = f"pretend-{config_key(cfg)}"
    pcfg.resume = False
    flags = (getattr(pcfg, "extra_flags", "") or "").strip()
    pcfg.extra_flags = (flags + " --pretend-only").strip()
    return pcfg


def config_key(cfg) -> str:
    """sha8 of the desktop-relevant part of the config: one pretend sysroot per shape."""
    probe = copy.deepcopy(cfg)
    spec = ds.spec_of(probe)
    spec.extra_users, spec.history, spec.last_pretend = [], [], {}
    ds.store(probe, spec)
    keys = ("platform", "role", "mode", "desktop", "capable", "steam", "gpu_driver",
            "packages_add", "packages_drop", "desktop_spec")
    blob = json.dumps({k: getattr(probe, k, None) for k in keys}, sort_keys=True, default=str)
    return hashlib.sha256(blob.encode()).hexdigest()[:8]


def command(cfg, driver, backend: str | None = None) -> list[str]:
    """The argv for the check (the builder's own invocation via BuildDriver)."""
    return driver.command(pretend_config(cfg), backend or driver.host.default_backend)


# ── the machine-wide gate: one build / QEMU at a time ───────────────────────

#: A process is a build or an emulated device when the PROGRAM it runs is one: argv[0]
#: (qemu-system-*, the QEMU runner) or, for an interpreter, argv[1] (bash
#: ./build-<platform>-stage4.sh). Matching the whole command line would also match any
#: shell or grep that merely MENTIONS those names (pgrep -f's self-match trap), and a
#: gate that waits on a grep never opens.
_BUSY_PROG = re.compile(r"^(qemu-system-[A-Za-z0-9_]+|hugmesh-qemu-runner[A-Za-z0-9_.-]*|"
                        r"build-[a-z0-9-]+-stage4\.sh)$")
_INTERPRETERS = ("bash", "sh", "dash", "env", "sudo", "python3", "python")


def _busy_program(argv: list[str]) -> str:
    """The build / QEMU program ``argv`` runs, or ""."""
    if not argv:
        return ""
    first = os.path.basename(argv[0])
    if _BUSY_PROG.match(first):
        return first
    if first in _INTERPRETERS:
        for arg in argv[1:3]:
            if arg.startswith("-"):
                continue
            base = os.path.basename(arg)
            if _BUSY_PROG.match(base):
                return base
            break
    return ""


def _proc_cmdlines() -> list[list[str]]:
    out = []
    try:
        pids = [p for p in os.listdir("/proc") if p.isdigit()]
    except OSError:
        return out
    me = str(os.getpid())
    for pid in pids:
        if pid == me:
            continue
        try:
            with open(f"/proc/{pid}/cmdline", "rb") as fh:
                raw = fh.read()
        except OSError:
            continue
        out.append([a.decode("utf-8", "replace") for a in raw.split(b"\0") if a])
    return out


def _docker_images_running() -> list[str]:
    if not shutil.which("docker"):
        return []
    try:
        r = subprocess.run(["docker", "ps", "--format", "{{.Image}}"], capture_output=True,
                           text=True, timeout=15, check=False)
    except (OSError, subprocess.SubprocessError):
        return []
    return [x.strip() for x in r.stdout.splitlines() if x.strip()]


def _mem_available_gib() -> float | None:
    try:
        with open("/proc/meminfo", encoding="ascii") as fh:
            for line in fh:
                if line.startswith("MemAvailable:"):
                    return int(line.split()[1]) / (1024 * 1024)
    except (OSError, ValueError):
        return None
    return None


def gate(out_dir: str, *, sessions_active: bool = False, supervisor_running: bool = False,
         procs: list[str] | None = None, images: list[str] | None = None,
         mem_gib: float | None = -1.0, free_gib: float | None = -1.0) -> str:
    """"" when the check may start NOW, else the inline reason it may not. Builds and
    QEMU runs are strictly one at a time on this machine; a pretend run is a build
    container, so it waits its turn like one. The keyword arguments let tests (and
    callers that already know) supply each fact."""
    if sessions_active or supervisor_running:
        return "A build is running in this Studio; the check waits until it finishes."
    procs = _proc_cmdlines() if procs is None else procs
    for argv in procs:
        prog = _busy_program(argv.split() if isinstance(argv, str) else argv)
        if prog:
            return (f"Another build or emulated device is running on this machine "
                    f"({prog}); builds and QEMU runs go one at a time.")
    images = _docker_images_running() if images is None else images
    for img in images:
        if img.startswith("hugmesh-builder") or "hugmesh-qemu-runner" in img:
            return f"A builder container ({img}) is running; builds go one at a time."
    if mem_gib == -1.0:
        mem_gib = _mem_available_gib()
    if mem_gib is not None and mem_gib < MIN_MEM_GIB:
        return f"Only {mem_gib:.1f} GiB of memory is free; the check needs {MIN_MEM_GIB} GiB."
    if free_gib == -1.0:
        try:
            os.makedirs(out_dir, exist_ok=True)
            free_gib = shutil.disk_usage(out_dir).free / (1024 ** 3)
        except OSError:
            free_gib = None
    if free_gib is not None and free_gib < MIN_FREE_GIB:
        return (f"Only {free_gib:.0f} GiB is free under {out_dir}; the check unpacks a seed "
                f"and needs {MIN_FREE_GIB} GiB.")
    return ""


# ── running it ───────────────────────────────────────────────────────────────


def record_dir(out_dir: str, cfg) -> str:
    return os.path.join(out_dir, "pretend", config_key(cfg))


def run(cfg, driver, *, out_dir: str, on_line: Callable[[str], None] | None = None,
        backend: str | None = None) -> PretendResult:
    """Run the check (blocking — callers use a worker thread), record the log and the
    parsed result under ``<out>/pretend/<key>/`` and return it. The caller gates first."""
    why = supported(cfg)
    if why:
        return PretendResult(status="error", reason=why)
    run_id = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    rdir = record_dir(out_dir, cfg)
    os.makedirs(rdir, exist_ok=True)
    log_path = os.path.join(rdir, f"{run_id}.log")
    lines: list[str] = []
    backend = backend or driver.host.default_backend
    argv = command(cfg, driver, backend)
    with open(log_path, "w", encoding="utf-8") as log:
        log.write("$ " + " ".join(argv) + "\n")

        def sink(line: str) -> None:
            lines.append(line)
            log.write(line + "\n")
            if on_line:
                on_line(line)

        rc = driver._stream(argv, sink, backend)
    res = parse(lines, rc)
    res.run_id, res.log_path = run_id, log_path
    with open(os.path.join(rdir, f"{run_id}.json"), "w", encoding="utf-8") as fh:
        json.dump(res.to_dict(), fh, indent=2)
    return res


def record(cfg, res: PretendResult) -> None:
    """Keep the result's summary on the config (spec.last_pretend), for the assistant,
    the Review page and the session record."""
    spec = ds.spec_of(cfg)
    spec.last_pretend = res.summary()
    ds.store(cfg, spec)


def facts(res: PretendResult | dict | None, *, excerpt_lines: int = 40) -> list[str]:
    """Plain lines the local AI assistant reads (assistant_context pretend collector)."""
    if not res:
        return ["emerge --pretend: not run yet for this configuration."]
    if isinstance(res, dict):
        out = [f"emerge --pretend status: {res.get('status', '?')} (run {res.get('run', '')})"]
        out += [f"needs: {n}" for n in res.get("needs", [])]
        return out
    out = [f"emerge --pretend status: {res.status} (run {res.run_id})"]
    if res.reason and res.status == "error":
        out.append(f"why: {res.reason}")
    if res.seed_python:
        out.append("seed PYTHON_TARGETS: " + " ".join(res.seed_python))
    if res.video_cards:
        out.append("VIDEO_CARDS: " + " ".join(res.video_cards))
    out += [f"needs: {k} {line}" for k, line in res.needs]
    if res.excerpt:
        out.append("resolver output (last lines):")
        out += res.excerpt[-excerpt_lines:]
    return out
