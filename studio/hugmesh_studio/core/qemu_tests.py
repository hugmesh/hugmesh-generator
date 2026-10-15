"""Containerized QEMU emulated-device test driver (Qt-free).

The Studio front-end for ``tests/qemu/run-qemu-docker.sh``. Like core/build_matrix.py
this module is deliberately Qt-free and side-effect-free at import time, so every
resolution rule below is unit-testable HERMETICALLY — no docker, no qemu, no images.

WHY THE TESTS ARE CONTAINERIZED (the constraint that shapes this whole module)
-----------------------------------------------------------------------------
Lifting a kernel out of a golden ``.img`` needs a loop mount, and building a
throwaway rootfs from a stage4 needs mkfs + an xattr-preserving untar. Both need
root. On a workstation that means an interactive ``sudo`` password, which a GUI
cannot supply — so the Studio would be unable to run its own device tests. A
``--privileged`` container is root for anyone in the ``docker`` group, so the
whole matrix runs unattended. See docker/Dockerfile.qemu-runner.

WHAT THIS MODULE OWNS vs WHAT THE SHELL OWNS
--------------------------------------------
The shell script is the single source of truth for RUNNING a row. This module
only:
  * enumerates build SESSIONS and the device rows their artifacts imply, so the
    Studio can offer "images built in another session" without shelling out;
  * builds the argv for the runner;
  * reads back the per-row result JSON the runner emits.
``parse_artifact_name`` mirrors the runner's own parsing rule; the two are
cross-checked by test_qemu_tests.py against the SAME sample names, so drift in
either direction fails a test rather than silently selecting the wrong image.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import subprocess
import threading

from . import proc_text
from . import roles
from collections.abc import Callable
from dataclasses import dataclass, field

from .platform_info import wsl_docker_remedy
from . import proc_group

#: Where the builders drop per-session artifact dirs, relative to the generator repo.
SESSIONS_SUBDIR = os.path.join("out", "sessions")
#: The host-side runner this module drives.
RUNNER_SCRIPT = os.path.join("tests", "qemu", "run-qemu-docker.sh")
#: Default scratch root (decompressed images, overlays, per-row result JSON).
DEFAULT_WORK_SUBDIR = os.path.join("out", "qemu-runs")

#: The mesh manifest the wizard writes into a session dir. Spelled locally rather
#: than imported from core/worklist_driver (its MANIFEST_NAME) because that module
#: pulls config/build_driver and this one stays import-light; test_qemu_tests.py
#: cross-checks the two spellings so they cannot drift.
MESH_MANIFEST_NAME = "hugmesh-mesh-manifest.json"
#: The builders' shared session log and the per-image log rule — the same names
#: core/build_sessions.py owns (LOG_NAME / image_log_name), cross-checked by test.
SHARED_BUILD_LOG = "build.log"
IMAGE_LOG_PREFIX = "build-"
IMAGE_LOG_SUFFIX = ".log"

#: Image extensions a device row can be built from, longest-first so ".img.xz"
#: is stripped before ".img" ever matches.
_IMAGE_SUFFIXES = (".img.xz", ".img")

#: Blobs that live beside the images but are not bootable disks.
_NON_IMAGE_MARKERS = ("kernel", "initramfs", "initrd", "squashfs")

#: The builders' ``BUILD_TS`` — ``date -u +%Y%m%dT%H%M%SZ`` — which is the LAST
#: field of every artifact name (build-rpi5-stage4.sh IMG_PATH,
#: build-x86-host-stage4.sh IMG_PATH). This regex is the structural anchor that
#: says "this file was minted by our builders", and it replaced a literal
#: ``hugmesh-`` PREFIX check that could not survive a branded build.
#:
#: WHY THE PREFIX HAD TO GO. The builders name artifacts ``${BRAND}-…``, and
#: BRAND is whatever the operator configured (``--brand sdhm``, or the forced
#: ``gentoo`` of an unaffiliated build) — only the DEFAULT brand is "hugmesh".
#: Anchoring on the default meant a mesh built as ``sdhm-rpi5-arm64-pki-test-…``
#: parsed as nothing, ``discover_rows`` returned [], every session read
#: "0 images", and the emulation picker was EMPTY with "No build session …
#: holds a bootable image yet" — for a build that had in fact finished all
#: three Pi images (out/sessions/20260830-185641-8e88a6, brand=sdhm).
#:
#: The rejection this anchor still owes the caller — "that .img is not ours" —
#: is now carried by SHAPE rather than by brand: six '-'-separated fields and a
#: trailing UTC stamp. ``some-third-party.img`` and ``backup-of-something.img``
#: fail it exactly as before; ``sdhm-…`` and ``gentoo-…`` no longer do.
_STAMP_RE = re.compile(r"^\d{8}T\d{6}Z$")

#: brand + platform + arch + <role…> + env + stamp.
_MIN_NAME_FIELDS = 6

#: Platforms whose rows are slowest and most relied on, in the order the
#: runner boots them. aarch64 has no KVM on an x86_64 host, so every Pi/ARM row
#: is pure TCG emulation and wants to start first; x86 gets KVM and is quick.
_PLATFORM_ORDER = {"rpi5": 0, "rpi4": 0, "rpi3": 0}
_PLATFORM_ORDER_ARM_DEFAULT = 1
_PLATFORM_ORDER_X86 = 2


def platform_rank(platform: str) -> int:
    """Boot-order rank: Pi first, other ARM next, x86 last.

    Mirrors ``platform_rank()`` in tests/qemu/run-qemu-docker.sh — the Studio
    previews the order the runner will actually use, so a user is never shown a
    plan the harness then reorders.
    """
    if platform in _PLATFORM_ORDER:
        return _PLATFORM_ORDER[platform]
    if platform == "x86":
        return _PLATFORM_ORDER_X86
    return _PLATFORM_ORDER_ARM_DEFAULT


@dataclass(frozen=True)
class DeviceRow:
    """One emulated device: a platform/role pair backed by a concrete artifact."""
    platform: str
    arch: str
    role: str
    env: str
    image: str          # absolute path to the .img / .img.xz
    stamp: str = ""     # <stamp> from the filename; "" when unparseable
    #: The ``${BRAND}`` field the artifact was BUILT under ("hugmesh", "sdhm",
    #: "gentoo" for an unaffiliated build). Carried so a row can SAY which brand
    #: it came from; never matched against, because matching on it is the bug
    #: this field exists to keep fixed.
    brand: str = ""

    @property
    def label(self) -> str:
        return f"{self.platform}/{self.role}"

    @property
    def compressed(self) -> bool:
        return self.image.endswith(".img.xz")

    @property
    def basename(self) -> str:
        return os.path.basename(self.image)


@dataclass
class BuildSession:
    """A build session dir plus the device rows its artifacts support."""
    path: str
    name: str
    rows: list[DeviceRow] = field(default_factory=list)
    mtime: float = 0.0
    #: How many images the build that minted this session INTENDED (see
    #: ``expected_image_count``). 0 = unknowable, which reads as complete: a
    #: session with no build logs and no manifest cannot be accused of missing
    #: anything.
    expected_images: int = 0

    @property
    def has_images(self) -> bool:
        return bool(self.rows)

    @property
    def is_partial(self) -> bool:
        """Did the build intend more images than the dir holds bootable rows for?

        True for a session whose build ABORTED mid-fleet — e.g.
        out/sessions/20260819-125930-89bb8e, which holds 4 per-image build logs
        and exactly 1 bootable image. Booting "the whole mesh" from such a
        session silently emulates a fraction of it, so pickers badge these and
        ``default_session`` skips them.
        """
        return self.expected_images > len(self.rows)

    def completeness_badge(self) -> str:
        """"PARTIAL — 1 of 4 image(s)" for an aborted build, "" when complete."""
        if not self.is_partial:
            return ""
        return f"PARTIAL — {len(self.rows)} of {self.expected_images} image(s)"

    @property
    def platforms(self) -> list[str]:
        return sorted({r.platform for r in self.rows})

    def summary(self) -> str:
        """One line for a picker: what this session can actually be tested with."""
        if not self.rows:
            return f"{self.name} — no images"
        by_platform: dict[str, list[str]] = {}
        for r in sorted(self.rows, key=lambda r: (platform_rank(r.platform), r.role)):
            by_platform.setdefault(r.platform, []).append(r.role)
        parts = [f"{p} ({', '.join(roles)})" for p, roles in by_platform.items()]
        badge = self.completeness_badge()
        return (f"{self.name} — {len(self.rows)} image(s): " + "; ".join(parts)
                + (f" [{badge}]" if badge else ""))


def declared_brand(artifacts_dir: str) -> str:
    """The ``brand`` the session's own mesh manifest declares, or "".

    THE BRAND FIELD CAN CONTAIN THE DELIMITER. ``${BRAND}`` is only ever validated
    as a DNS label (core/validate.py ``validate_brand``), and a DNS label may hold
    hyphens — so ``--brand my-mesh`` mints ``my-mesh-rpi5-arm64-pki-test-<stamp>``,
    where a positional "field 0 is the brand" split reads brand=my, platform=mesh,
    arch=rpi5 and role=arm64-pki. Every one of those is wrong, and the session
    would list COMPLETE while planning a device no launcher can dispatch.

    The manifest beside the artifacts is the only witness that can settle it, so
    when it names a brand the prefix is stripped BY NAME rather than by position
    (the same ``${brandplat#"${BRAND}"-}`` rule scripts/publish-images.sh:256
    already applies). It is used ONLY to find the end of the brand — never to
    accept or reject a file, because rejecting on the brand is the bug that hid
    three finished Pi images from the picker. A file whose brand is not the
    declared one (an ``out/`` root holding several brands) simply falls back to
    the positional split, exactly as before.

    Returns "" for a dir with no manifest, an unreadable one, or one that names no
    brand — i.e. the positional rule stays the default and this is a refinement.
    """
    try:
        with open(os.path.join(artifacts_dir, MESH_MANIFEST_NAME), encoding="utf-8") as fh:
            record = json.load(fh)
    except (OSError, ValueError):
        return ""
    brand = record.get("brand") if isinstance(record, dict) else None
    return brand if isinstance(brand, str) else ""


def _split_artifact_name(basename: str, brand: str = "") -> list[str] | None:
    """The '-'-separated fields of a bootable role image, or None.

    Shared by :func:`parse_artifact_name` and :func:`artifact_stamp` so the two
    cannot disagree about what counts as one of our artifacts — they used to
    apply the field-count rule separately, and only one of them the prefix rule.

    ``brand``, when given (:func:`declared_brand`), is the session's own declared
    brand: a leading ``<brand>-`` is then removed as ONE field however many
    hyphens it spells, so field 1 is the platform for a hyphenated brand too. The
    trailing "-" matters — brand "snap" must not swallow the head of
    ``snapdragon-…``. With no declared brand the split is purely positional, which
    is right for every brand that holds no hyphen (hugmesh, sdhm, gentoo).
    """
    name = basename
    for suffix in _IMAGE_SUFFIXES:
        if name.endswith(suffix):
            name = name[: -len(suffix)]
            break
    else:
        return None

    lowered = name.lower()
    if any(marker in lowered for marker in _NON_IMAGE_MARKERS):
        return None

    if brand and name.startswith(brand + "-"):
        parts = [brand] + name[len(brand) + 1:].split("-")
    else:
        parts = name.split("-")
    if len(parts) < _MIN_NAME_FIELDS:
        return None
    if not _STAMP_RE.match(parts[-1]):
        return None
    return parts


def parse_artifact_name(basename: str, brand: str = "") -> tuple[str, str, str, str] | None:
    """``<brand>-<platform>-<arch>-<role>-<env>-<stamp>.img[.xz]`` -> (platform, arch, role, env).

    Returns None for anything that is not a bootable role image.

    The role may itself contain '-' (``standalone-thin``, ``backend-gpu``), so the
    name is parsed from BOTH ends: the first two fields are the brand and platform,
    the third is the arch, and the LAST two fields before the extension are env and
    stamp — whatever remains in the middle is the role, hyphens and all. A naive
    ``split('-')[3]`` would truncate every hyphenated role to "standalone".

    THE FIRST FIELD IS THE BRAND, AND IT IS NOT "hugmesh". It is whatever
    ``--brand`` the build ran under: ``hugmesh`` only by default, ``sdhm`` for the
    operator's own mesh, ``gentoo`` for an unaffiliated build (which forces the
    neutral identity, build-x86-host-stage4.sh). This function used to require the
    literal ``hugmesh-`` prefix, which meant a completed branded mesh parsed as
    zero rows, ``discover_sessions(only_with_images=True)`` dropped the session,
    and the Studio's emulation picker came up EMPTY on a build that had finished.
    The brand is READ (see :func:`artifact_brand`), never matched against.

    What still rejects a foreign file is the SHAPE, which is also what the shell
    runner checks (tests/qemu/run-qemu-docker.sh ``discover_rows``): at least six
    '-'-separated fields, and a trailing ``YYYYmmddTHHMMSSZ`` build stamp. A brand
    slug is opaque; a stamp is not, so the stamp is the anchor.

    ``brand`` is the session's DECLARED brand (:func:`declared_brand`), and it
    exists because a brand may itself contain '-': ``validate_brand`` only requires
    a DNS label, so ``--brand my-mesh`` yields ``my-mesh-rpi5-arm64-pki-test-…``
    and a positional split would read platform=mesh, arch=rpi5, role=arm64-pki.
    Passed, it ends the brand by NAME instead. It is never used to accept or
    reject — an artifact under a different brand still parses positionally.

    The parsed role is CANONICALIZED (scripts/_roles-lib.sh). Artifacts already on
    disk keep whatever spelling they were built under — ``hugmesh-x86-amd64-be-…``,
    ``…-host-…`` — and they are NOT renamed; they are already-emitted artifacts. But
    every consumer that keys on the role (the emulation grid label, the boot order,
    :data:`mesh_emulation.GATEWAY_ROLES`) must see ONE spelling, or an x86 backend
    and a Pi backend read as two different roles. That mismatch is why
    ``GATEWAY_ROLES`` could never match ``be+gpu`` (whose artifact was named ``host``)
    and never matched a Pi node at all.
    """
    parts = _split_artifact_name(basename, brand)
    if parts is None:
        return None
    platform, arch = parts[1], parts[2]
    env = parts[-2]
    role = "-".join(parts[3:-2])
    if not platform or not role:
        return None
    return platform, arch, roles.canonicalize(role), env


def artifact_brand(basename: str, brand: str = "") -> str:
    """The ``${BRAND}`` field an artifact was built under, or "" if it has none.

    Diagnostic only: ``discover_rows`` records it on the row so a caller can SAY
    which brand an image came from (and could one day compare it against the
    session's own manifest ``brand``). Nothing selects, filters or orders on it —
    selecting on the brand is the rule that hid three finished Pi images from the
    picker, and the ``hugmesh-mesh-manifest.json`` beside them is the witness that
    would have been needed to do it correctly.
    """
    parts = _split_artifact_name(basename, brand)
    return parts[0] if parts else ""


def artifact_stamp(basename: str, brand: str = "") -> str:
    """The ``<stamp>`` field of an artifact name, or "" if it has none.

    Kept separate from ``parse_artifact_name`` so that function's 4-tuple stays
    the parsing contract the shell runner is checked against.
    """
    parts = _split_artifact_name(basename, brand)
    return parts[-1] if parts else ""


def discover_rows(artifacts_dir: str) -> list[DeviceRow]:
    """Every device row the artifacts in ``artifacts_dir`` can boot, Pi first.

    One row per (platform, role) — a directory routinely holds several builds of
    the same role, and booting each would multiply a 20-minute emulated run by
    however many rebuilds happened to land there.

    Which one survives matters more than it looks. Selection is NEWEST STAMP
    FIRST, and only then decompressed-over-compressed:

    * Newest wins because the whole point of rebuilding a role is to test the
      rebuild. Entries arrive in sorted-name order, i.e. oldest first, so a
      "keep the incumbent" rule silently pins every result to the OLDEST
      artifact — a freshly rebuilt image reports a green pass its bits were
      never involved in (2026-08-14: rpi5/pki resolved to the 08-07 build while
      a rebuild of the same role sat beside it).
    * Decompressed wins among equal stamps because the runner would otherwise
      spend minutes re-expanding 9-20GB it already has on disk.

    Stamps are ``YYYYmmddTHHMMSSZ``, so a plain string compare is chronological.

    A ZERO-BYTE artifact is not a row. The builder creates ``${IMG_PATH}`` before
    it partitions it, so a run killed in that window leaves a 0-byte ``.img``
    behind (out/sessions/20260830-173335-d51b24 holds exactly that). Counting it
    would read an aborted 1-of-2 build as 2-of-2 and hand the operator a device
    that cannot boot — the same class of lie ``is_partial`` exists to prevent, so
    the guard lives here rather than in the picker. The shell runner applies the
    same rule (``[ -s ]`` in tests/qemu/run-qemu-docker.sh discover_rows).
    """
    if not os.path.isdir(artifacts_dir):
        return []

    best: dict[tuple[str, str], DeviceRow] = {}
    try:
        entries = sorted(os.listdir(artifacts_dir))
    except OSError:
        return []

    # The session's own manifest, when it has one, says where the brand FIELD ends
    # — which a positional split cannot know for a hyphenated brand. See
    # declared_brand(); the shell runner reads the same key out of the same file.
    brand = declared_brand(artifacts_dir)

    for entry in entries:
        parsed = parse_artifact_name(entry, brand)
        if parsed is None:
            continue
        platform, arch, role, env = parsed
        path = os.path.join(artifacts_dir, entry)
        if not os.path.isfile(path):
            continue
        try:
            if os.path.getsize(path) <= 0:
                continue
        except OSError:
            continue
        row = DeviceRow(platform=platform, arch=arch, role=role, env=env, image=path,
                        stamp=artifact_stamp(entry, brand), brand=artifact_brand(entry, brand))
        key = (platform, role)
        prior = best.get(key)
        if prior is None or (row.stamp, not row.compressed) > (prior.stamp, not prior.compressed):
            best[key] = row

    return sorted(best.values(), key=lambda r: (platform_rank(r.platform), r.platform, r.role))


def expected_image_count(session_path: str) -> int:
    """How many images the build that minted ``session_path`` INTENDED. 0 = unknown.

    Two witnesses, most-faithful first:

    * per-image build logs (``build-<id>.log``, core/build_sessions.image_log_name):
      one is created when an image's build STARTS, so their count is what the run
      actually attempted — a manifest can name images the operator deselected, but
      a log only exists for a build that began;
    * the mesh manifest's ``images`` list (``hugmesh-mesh-manifest.json``): the
      fallback for a session whose builder died before minting a single per-image
      log, or that predates per-image logs.

    Comparing this against ``len(rows)`` is deliberately a COUNT comparison, not a
    label match: manifest ids spell roles differently from artifact names on some
    platforms (``be.rpi5`` builds ``hugmesh-rpi5-arm64-backend-…``), so a name-based
    pairing would false-positive on exactly the sessions it matters for.
    """
    try:
        names = os.listdir(session_path)
    except OSError:
        return 0
    logs = [n for n in names
            if n.startswith(IMAGE_LOG_PREFIX) and n.endswith(IMAGE_LOG_SUFFIX)
            and n != SHARED_BUILD_LOG]
    if logs:
        return len(logs)
    manifest = os.path.join(session_path, MESH_MANIFEST_NAME)
    try:
        with open(manifest, encoding="utf-8") as fh:
            record = json.load(fh)
    except (OSError, ValueError):
        return 0
    images = record.get("images") if isinstance(record, dict) else None
    return len(images) if isinstance(images, list) else 0


def discover_sessions(generator_dir: str, *, only_with_images: bool = True) -> list[BuildSession]:
    """Build sessions under ``out/sessions/``, newest first.

    A session dir is minted when a build STARTS, so many hold no artifacts at
    all; ``only_with_images`` keeps those out of a picker whose every entry is
    supposed to be runnable.
    """
    root = os.path.join(generator_dir, SESSIONS_SUBDIR)
    if not os.path.isdir(root):
        return []

    sessions: list[BuildSession] = []
    try:
        names = os.listdir(root)
    except OSError:
        return []

    for name in names:
        path = os.path.join(root, name)
        if not os.path.isdir(path):
            continue
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            mtime = 0.0
        session = BuildSession(path=path, name=name, rows=discover_rows(path), mtime=mtime,
                               expected_images=expected_image_count(path))
        if only_with_images and not session.has_images:
            continue
        sessions.append(session)

    sessions.sort(key=lambda s: s.mtime, reverse=True)
    return sessions


def newest_session(generator_dir: str) -> BuildSession | None:
    """The newest session that actually holds images, or None."""
    sessions = discover_sessions(generator_dir, only_with_images=True)
    return sessions[0] if sessions else None


def default_session(generator_dir: str) -> BuildSession | None:
    """The session a picker should preselect: the newest COMPLETE one.

    A partial session (a build that aborted mid-fleet) still LISTS — its images are
    real and individually runnable — but defaulting to it silently hands the
    operator a 1-of-4 mesh whose "whole mesh" actions emulate a fraction of what
    was configured. When every session with images is partial, the newest of them
    is still the answer: runnable-with-a-badge beats nothing.
    """
    sessions = discover_sessions(generator_dir, only_with_images=True)
    for session in sessions:
        if not session.is_partial:
            return session
    return sessions[0] if sessions else None


@dataclass
class QemuRunOptions:
    """Everything the runner needs for one fan-out."""
    artifacts_dir: str = ""          # explicit artifacts dir (a session path)
    work_dir: str = ""               # scratch; defaults to <generator>/out/qemu-runs
    platform: str = ""               # filter: only this platform
    role: str = ""                   # filter: only this role
    only: str = ""                   # substring filter on "<platform>/<role>"
    #: EXACT "<platform>/<role>" equality — the runner's --only-exact. This is the
    #: spelling a per-device Start uses: --only is a substring filter, so
    #: "x86/be" would also drag in be+gpu and be-ha rows.
    only_exact: str = ""
    mode: str = "golden"             # golden | stage4
    jobs: int = 2
    mem_mb: int = 2048
    smp: int = 2
    timeout_s: int = 2400
    #: Wall clock for the in-guest assertion ssh (--assert-timeout); 0 = the
    #: entrypoint's own default, and like every other default here it is then
    #: NOT emitted.
    assert_timeout_s: int = 0
    #: Additional wheel logins created on every guest (--extra-user, repeatable).
    extra_users: tuple[str, ...] = ()
    list_only: bool = False
    build_image: bool = False
    keep: bool = False
    #: Cap (GiB) on the decompressed-image cache under <work>/images
    #: (--cache-max-gb); 0 = unbounded, the runner's own default.
    cache_max_gb: int = 0
    #: Leave the guests RUNNING once their assertions finish (``--keep-alive``)
    #: instead of powering them off, and let the entrypoint register each one under
    #: ``<work>/devices/``. This is what makes core/qemu_devices.py have anything to
    #: read, so it is a FIELD rather than something a caller pins onto an instance:
    #: ``runner_command`` below is the single argv author for both the Studio's
    #: command preview and its spawn, and it can only emit what it knows about.
    #: Distinct from ``keep`` above, which only preserves per-run scratch dirs.
    keep_alive: bool = False


def runner_command(generator_dir: str, opts: QemuRunOptions) -> list[str]:
    """argv for tests/qemu/run-qemu-docker.sh.

    Only non-default knobs are emitted, so the printed command stays readable and
    a future default change in the shell script is not frozen here.
    """
    cmd: list[str] = [os.path.join(generator_dir, RUNNER_SCRIPT)]
    if opts.artifacts_dir:
        cmd += ["--artifacts", opts.artifacts_dir]
    cmd += ["--work", opts.work_dir or os.path.join(generator_dir, DEFAULT_WORK_SUBDIR)]
    if opts.platform:
        cmd += ["--platform", opts.platform]
    if opts.role:
        cmd += ["--role", opts.role]
    if opts.only:
        cmd += ["--only", opts.only]
    if opts.only_exact:
        cmd += ["--only-exact", opts.only_exact]
    if opts.mode and opts.mode != "golden":
        cmd += ["--mode", opts.mode]
    cmd += ["--jobs", str(opts.jobs),
            "--mem", str(opts.mem_mb),
            "--smp", str(opts.smp),
            "--timeout", str(opts.timeout_s)]
    if opts.assert_timeout_s > 0:
        cmd += ["--assert-timeout", str(opts.assert_timeout_s)]
    if opts.cache_max_gb > 0:
        cmd += ["--cache-max-gb", str(opts.cache_max_gb)]
    for user in opts.extra_users:
        cmd += ["--extra-user", user]
    if opts.list_only:
        cmd.append("--list")
    if opts.build_image:
        cmd.append("--build-image")
    if opts.keep:
        cmd.append("--keep")
    if opts.keep_alive:
        cmd.append("--keep-alive")
    return cmd


def command_string(generator_dir: str, opts: QemuRunOptions) -> str:
    return " ".join(shlex.quote(x) for x in runner_command(generator_dir, opts))


def result_filename(label: str) -> str:
    """``rpi5/pki`` -> ``rpi5_pki.json``. Mirrors RESULT_JSON in docker-entrypoint.sh."""
    return label.replace("/", "_").replace("+", "_") + ".json"


def read_results(work_dir: str, labels: list[str] | None = None) -> list[dict]:
    """The per-row result JSON the runner emits, worst-first.

    Failures sort to the top: a 7-row matrix where one row failed should not make
    the operator scroll to find it.

    ``labels`` scopes the read to the rows of ONE run and should be passed
    whenever the caller knows them. The results dir lives under the persistent
    work dir (it caches multi-GB decompressed images, so it is never wiped), and
    therefore accumulates every row ever run — across sessions, artifacts and
    days. Reading it wholesale presents rows from an unrelated earlier run, or a
    different artifact generation, as the current run's outcome.
    """
    results_dir = os.path.join(work_dir, "results")
    if not os.path.isdir(results_dir):
        return []
    wanted = {result_filename(l) for l in labels} if labels is not None else None
    out: list[dict] = []
    for name in sorted(os.listdir(results_dir)):
        if not name.endswith(".json"):
            continue
        if wanted is not None and name not in wanted:
            continue
        try:
            with open(os.path.join(results_dir, name), encoding="utf-8") as fh:
                out.append(json.load(fh))
        except (OSError, ValueError):
            continue
    rank = {"FAIL": 0, "ERROR": 1, "PASS": 2}
    out.sort(key=lambda r: (rank.get(str(r.get("status")), 3), str(r.get("label", ""))))
    return out


def results_summary(results: list[dict]) -> tuple[int, int, int]:
    """(passed, failed, total) over a result list."""
    passed = sum(1 for r in results if r.get("status") == "PASS")
    total = len(results)
    return passed, total - passed, total


#: Default wall clock for the NON-BLOCKING docker probe below. Deliberately much
#: shorter than the synchronous default: the async caller is a wizard page's
#: initializePage, where a hung docker daemon must cost a few seconds of "checking…"
#: badge, never a frozen window.
DOCKER_PROBE_TIMEOUT_S = 4.0


def docker_available(timeout_s: float = 15.0) -> tuple[bool, str]:
    """Whether this host can run the containerized harness at all.

    The Studio must say so up-front rather than let the operator configure a run
    that dies at spawn — the same reasoning as WelcomePage's no-build-backend note.

    Under WSL the generic reason is actively misleading: there is no daemon in the
    distro to start and no 'docker' group to join, because Docker Desktop runs the
    daemon on the Windows side and exposes it per distro through a checkbox. So the
    WSL remedy REPLACES the generic advice rather than being appended to it — sending
    the operator to `systemctl start docker` in a distro that has no such unit is how
    an unhelpful message becomes a wrong one.
    """
    try:
        proc = subprocess.run(["docker", "info"], stdout=subprocess.DEVNULL,
                              stderr=subprocess.PIPE, text=True, timeout=timeout_s)
    except FileNotFoundError:
        wsl = wsl_docker_remedy()
        return False, ("docker was not found on PATH." + (" " + wsl if wsl else ""))
    except (OSError, subprocess.SubprocessError) as exc:
        return False, f"could not run docker: {exc}"
    if proc.returncode != 0:
        wsl = wsl_docker_remedy()
        if wsl:
            return False, "cannot talk to the docker daemon. " + wsl
        return False, ("cannot talk to the docker daemon — is it running, and is "
                       "your user in the 'docker' group?")
    return True, "docker is available."


def docker_available_async(on_result: Callable[[bool, str], None], *,
                           timeout_s: float = DOCKER_PROBE_TIMEOUT_S) -> threading.Thread:
    """``docker_available`` without the page freeze: probe on a daemon thread.

    ``docker info`` against a hung daemon takes the FULL timeout to answer, and
    both device pages used to run it synchronously inside initializePage — 15
    seconds of a frozen window before the page even painted. This variant returns
    immediately and calls ``on_result(ok, reason)`` FROM THE WORKER THREAD once the
    probe answers; Qt callers marshal that back to the GUI thread themselves (a
    queued signal), exactly as they do for every other worker in the app.

    The started thread is returned so callers (and tests) can join it; it is a
    daemon thread, so a probe still hanging at app exit cannot hold the process
    hostage. A probe that raises delivers the failure through ``on_result`` rather
    than dying silently on a thread nobody watches.
    """
    def _probe() -> None:
        try:
            ok, why = docker_available(timeout_s=timeout_s)
        except Exception as exc:  # noqa: BLE001 — a probe thread must never die mute
            ok, why = False, f"docker probe failed: {exc}"
        on_result(ok, why)

    thread = threading.Thread(target=_probe, name="qemu-docker-probe", daemon=True)
    thread.start()
    return thread


class QemuTestRunner:
    """Spawns the runner and streams its output, cancellably.

    Mirrors core/build_driver.py's streaming contract (spawn, per-line callback,
    exit code, cancel()) so the GUI can drive it with the SAME worker thread the
    build and cloud-deploy pages already use.
    """

    def __init__(self, generator_dir: str):
        self.generator_dir = generator_dir
        self._proc: subprocess.Popen | None = None
        self._cancel = threading.Event()

    def run(self, opts: QemuRunOptions,
            on_line: Callable[[str], None] | None = None) -> int:
        """Run the matrix, calling ``on_line`` per output line. Returns the exit code."""
        cmd = runner_command(self.generator_dir, opts)
        if on_line:
            on_line(f"$ {command_string(self.generator_dir, opts)}")
        self._cancel.clear()
        try:
            # start_new_session: the runner spawns docker containers that must be
            # signalled as a group on cancel, exactly as build_driver does for the
            # native sudo->bash->emerge tree.
            self._proc = subprocess.Popen(
                cmd, cwd=self.generator_dir, stdout=subprocess.PIPE,
                stderr=subprocess.STDOUT, text=True, bufsize=1, start_new_session=True,
                **proc_text.TEXT_IO)
        except OSError as exc:
            if on_line:
                on_line(f"!! could not start the runner: {exc}")
            return 127
        assert self._proc.stdout is not None
        for line in self._proc.stdout:
            if on_line:
                on_line(line.rstrip("\n"))
            if self._cancel.is_set():
                break
        return self._proc.wait()

    def cancel(self) -> None:
        """Stop the run and the containers it started."""
        self._cancel.set()
        proc = self._proc
        if proc is None or proc.poll() is not None:
            return
        proc_group.terminate_group(proc)
