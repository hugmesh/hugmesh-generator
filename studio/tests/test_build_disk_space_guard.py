"""Free-space preflight for Studio builds (defect L4).

THE INCIDENT. Session 20261110-220215-cde67f, a 23-image mesh, ran for 1.5 h into a
full disk. ENOSPC stopped its FIRST image (pki.x86) at the .img step, with about 36 GiB
written (a 22.7 GiB payload, 12 GiB of a 27.5 GiB .img and a 1.3 GiB stage4), and the
four images after it. Their error tails read ``sfdisk: cannot open ...pki-test-...img``,
``cannot open pool lockfile ... No space left on device`` and ``tar: ... Cannot open: No
space left on device``. How much was free when the session started is not recorded.
Nothing checked free space before dispatch or between images, so the session record held
mid-build crashes where a refusal belonged.

THE CONTRACT UNDER TEST
* ``WorklistDriver.preflight()`` BLOCKS when the output filesystem cannot hold the next
  (first) image.
* ``WorklistDriver.preflight_warnings()`` WARNS when the first image fits but the whole
  worklist does not.
* ``WorklistDriver.run_all()`` RE-CHECKS before each queued image. An image that no longer
  fits is not dispatched. It is recorded FAILED with a ``!!`` line that names the shortfall,
  which is the line the session record's error tail keeps.
* An unknowable free-space answer (-1) never refuses, the same rule
  ``emulation_save.preflight_refusal`` follows.
* A RESTART builds into the session dir an earlier run used. What the image's own build
  system (``wl-<id>/sysroot``) already holds there is not needed again, whether the
  builder continues from it (``--resume``, the Studio's default) or rebuilds it in place,
  so it is counted, and the operator is never told to delete it. ``preflight()`` refuses
  only what no measurement could change and never walks a tree. ``run_all()`` measures
  the tree on the build thread when the answer depends on it.

No real disk is involved. The probe is ``emulation_save._disk_usage``, the injectable
seam ``emulation_save.free_bytes_for`` already reads. conftest pins it to a roomy answer
for the rest of the suite, and each test here pins it to the answer it needs. The size of
an earlier build tree comes from ``build_driver._measure_tree``, pinned the same way.
"""
from __future__ import annotations

import collections
import os
import re

import pytest

from hugmesh_studio.core import build_driver as bd
from hugmesh_studio.core import emulation_save as es
from hugmesh_studio.core import worklist_driver as wd
from hugmesh_studio.core.config import ROLE_CHOICES, ImageConfig
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
GIB = 1024 ** 3
_Usage = collections.namedtuple("_Usage", "total used free")

# What one real build actually leaves on disk, independent of the estimate under test.
# Measured on the incident session: an x86 pki image held a ~23 GiB payload (its build
# tree) plus a ~28 GiB .img. ARM is smaller: an rpi5 node's payload has to fit its
# 9216 MiB root, so about 8 GiB of tree. The simulation consumes THESE, so a passing test
# means no dispatched build ran out of space, not that the code agrees with its own
# constants. A build over a tree an earlier run left writes only what that tree lacks,
# plus the images.
_X86_TREE, _X86_IMAGES = 23 * GIB, 28 * GIB
_ARM_TREE, _ARM_IMAGES = 8 * GIB, 7 * GIB
_X86_FOOTPRINT, _ARM_FOOTPRINT = _X86_TREE + _X86_IMAGES, _ARM_TREE + _ARM_IMAGES
_ENOSPC = "tee: /out/build.log: No space left on device"


def host():
    return HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")


class _Disk:
    """A filesystem with ``free`` bytes. Every probe call is recorded."""

    def __init__(self, free: int):
        self.free = free
        self.probed: list[str] = []

    def __call__(self, path):
        self.probed.append(str(path))
        return _Usage(total=2048 * GIB, used=0, free=self.free)


def _pin_disk(monkeypatch, free: int) -> _Disk:
    disk = _Disk(free)
    monkeypatch.setattr(es, "_disk_usage", disk)
    return disk


def _mesh(tmp_path, roles):
    base = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                       brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                       superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    return WorklistConfig(base=base, entries=[
        WorklistEntry(role=r, platform=p, hostname=f"n{i}")
        for i, (r, p) in enumerate(roles)])


def _incident_roles():
    """Every mesh role on every platform it offers, in the Studio's own order: 23
    images, the same count as the incident's mesh (a worklist allows each
    role x platform pair once)."""
    pairs = [(role, plat) for role, plats, _label in ROLE_CHOICES["mesh"] for plat in plats]
    assert len(pairs) == 23
    return pairs


def _fake_builds(monkeypatch, disk: _Disk, held=None):
    """BuildDriver stand-in that writes a real-sized footprint to ``disk``. A build that
    starts without that much free space fails the way the incident's did.

    ``held`` is the simulation's own truth about a RESTART: bytes the image's build tree
    from an earlier run already holds, by ``wl-<id>`` name. Those bytes are on the disk
    already (not in ``disk.free``), and the build writes only the rest of the tree."""
    started: list[str] = []
    held = held or {}

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir

        def run(self, cfg, backend, on_line=None):
            started.append(cfg.platform)
            tree, images = ((_X86_TREE, _X86_IMAGES) if cfg.platform == "x86"
                            else (_ARM_TREE, _ARM_IMAGES))
            need = tree - min(held.get(cfg.build_subdir, 0), tree) + images
            if disk.free < need:
                disk.free = 0
                if on_line:
                    on_line(_ENOSPC)
                return 1
            disk.free -= need
            return 0

        def cancel(self):
            pass

        def preflight(self, cfg, backend):
            return []

        def preflight_warnings(self, cfg, backend):
            return []

    monkeypatch.setattr(wd, "BuildDriver", FakeBuildDriver)
    return started


# ── the incident, reproduced at driver level ──────────────────────────────────────
def test_the_23_image_mesh_never_dispatches_a_build_the_disk_cannot_hold(monkeypatch, tmp_path):
    """THE REGRESSION, on a simulated disk: 23 images and 117 GiB free. (117 GiB is what
    the incident host showed five hours after its session ended. What that session had
    when it started is not recorded, and its first image already ran out.) Before the
    fix all 23 were dispatched, and every one after the space ran out failed mid-build
    with ENOSPC, simulated here as an error-tail line a real session recorded. After the
    fix nothing hits ENOSPC. The images that no longer fit are refused before dispatch,
    each with a reason."""
    disk = _pin_disk(monkeypatch, 117 * GIB)
    started = _fake_builds(monkeypatch, disk)
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    (tmp_path / "out").mkdir()
    (tmp_path / "gen").mkdir()
    drv = wd.WorklistDriver(str(tmp_path / "gen"), _mesh(tmp_path, _incident_roles()),
                            host=host())
    assert drv.preflight() == []          # the FIRST image fits, so the session may start

    lines: list[tuple[int, str]] = []
    code = drv.run_all(on_line=lambda i, ln: lines.append((i, ln)))

    enospc = [i for i, ln in lines if ln == _ENOSPC]
    assert enospc == [], f"{len(enospc)} image(s) were dispatched onto a full disk"
    refused = [r.index for r in drv.results if r.status == wd.FAILED]
    assert refused, "nothing was refused, so the simulated disk never ran short"
    assert len(started) + len(refused) == 23
    for i in refused:
        why = [ln for j, ln in lines if j == i and ln.startswith("!! ")]
        assert why and "not enough free disk space" in why[0], (i, why)
    assert code == 1                      # the session is honestly not complete
    # every check measured the filesystem the builds write to, never the checkout's
    assert set(disk.probed) == {str(tmp_path / "out")}


def test_a_refused_image_reaches_a_terminal_failed_row_and_the_run_continues(monkeypatch, tmp_path):
    """The refusal goes down the normal FAILED path. The row gets a start and a done
    signal (so the GUI settles it and copies its tail into the session record), and an
    ARM image after a refused x86 image still runs when it fits."""
    disk = _pin_disk(monkeypatch, 40 * GIB)   # too small for x86, enough for one rpi5
    started = _fake_builds(monkeypatch, disk)
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    wl = _mesh(tmp_path, [("pki", "x86"), ("backend", "rpi5"), ("rpi5-desktop", "rpi5")])
    drv = wd.WorklistDriver(str(tmp_path), wl, host=host())
    starts, dones, lines = [], [], []
    drv.run_all(on_entry_start=starts.append,
                on_entry_done=lambda i, c: dones.append((i, c)),
                on_line=lambda i, ln: lines.append((i, ln)))
    # 40 GiB: the x86 image (55 + 10 margin) is refused without being dispatched; the
    # first rpi5 (20 + 10) fits and its real 15 GiB leaves 25; the second rpi5 no
    # longer fits and is refused too.
    assert started == ["rpi5"]
    assert [r.status for r in drv.results] == [wd.FAILED, wd.OK, wd.FAILED]
    assert starts == [0, 1, 2]
    assert dones == [(0, 1), (1, 0), (2, 1)]
    assert drv.results[0].exit_code == 1
    assert drv._drivers == {}
    assert [i for i, ln in lines if ln.startswith("!! ")] == [0, 2]


def test_the_refusal_names_where_how_much_and_how_short(monkeypatch, tmp_path):
    _pin_disk(monkeypatch, 43 * GIB)
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    out = str(tmp_path / "out" / "sessions" / "20261111-000000-abcdef")
    why = bd.disk_space_refusal(cfg, out)
    assert out in why
    assert "65" in why                    # 55 GiB estimate + 10 GiB margin
    assert "43.0 GiB" in why              # free
    assert "22.0 GiB short" in why
    assert bd.SPACE_ENV in why            # the escape hatch is named


# ── restart: the build tree an earlier run left ──────────────────────────────────────
# One x86 image needs 55 + 10 = 65 GiB when nothing of it exists, and 55 - 23 + 10 = 42
# over the finished build tree of an earlier run. ARM: 20 + 10 = 30 and 20 - 7 + 10 = 23.
def _earlier_tree(session, entry_id, populated=True):
    """The build system an earlier run of this image left in the session dir. Every
    builder decides "populated" by ``sysroot/etc/gentoo-release``, the file planted
    here. Without it the builder extracts a fresh stage3 and nothing is reused."""
    sysroot = session / f"wl-{entry_id}" / "sysroot"
    (sysroot / "etc").mkdir(parents=True)
    if populated:
        (sysroot / "etc" / "gentoo-release").write_text("Gentoo Base System release 2.18\n")
    return sysroot


def _restart(tmp_path, roles=(("pki", "x86"),), resume=True, populated=True):
    """A driver RESTARTING a session in which every image left a build tree behind."""
    session = tmp_path / "out" / "sessions" / "s1"
    wl = _mesh(tmp_path, list(roles))
    wl.base.resume = resume
    for entry in wl.entries:
        _earlier_tree(session, entry.id, populated)
    return wd.WorklistDriver(str(tmp_path), wl, host=host(), workdir=str(session)), session


class _Tree:
    """The tree-measurement seam: answers a scripted size and records every call."""

    def __init__(self, holds: int, **facts):
        self.holds, self.facts = holds, facts
        self.calls: list[tuple[str, int]] = []
        self.on_call = None             # runs while the "walk" is under way
        self.sees_stop = True           # False: the walk had returned before the Stop
        self.stop_asked: list[bool] = []    # what the walk's Stop check answered

    def __call__(self, path, *, enough=0, seconds=0, should_stop=None):
        self.calls.append((str(path), enough))
        if self.on_call:
            self.on_call()
        self.stop_asked.append(bool(should_stop and should_stop()))
        stopped = self.sees_stop and self.stop_asked[-1]
        return bd.TreeMeasure(bytes=self.holds, stopped=stopped, **self.facts)


def _pin_tree(monkeypatch, holds: int, **facts) -> _Tree:
    tree = _Tree(holds, **facts)
    # raising=False: on a tree without the seam these tests must fail on what the driver
    # DID, not on the seam being absent.
    monkeypatch.setattr(bd, "_measure_tree", tree, raising=False)
    return tree


def _space(messages):
    return [m for m in messages if "disk space" in m]


def _run(drv):
    starts, dones, lines = [], [], []
    code = drv.run_all(on_entry_start=starts.append,
                       on_entry_done=lambda i, c: dones.append((i, c)),
                       on_line=lambda i, ln: lines.append((i, ln)))
    return code, starts, dones, [ln for _i, ln in lines]


def _argv(drv, session):
    """The builder argv the Studio dispatches for the driver's first image."""
    _entry, cfg = drv.materialize()[0]
    return bd.BuildDriver(str(session), host(), workdir=str(session)).command(cfg, "native")


def test_a_resume_restart_is_not_told_to_delete_the_tree_it_continues_from(monkeypatch, tmp_path):
    """THE ROUND-2 DEFECT. The Studio's default restart passes --resume, and every builder
    then skips the stage3 extraction and continues from the populated sysroot. The
    refusal said "The builder wipes it before rebuilding ... deleting it first is part of
    the answer", which throws away the very tree the restart was about to continue from."""
    _pin_disk(monkeypatch, 30 * GIB)
    tree = _pin_tree(monkeypatch, 0)
    drv, session = _restart(tmp_path)
    [why] = _space(drv.preflight())
    assert "delet" not in why.lower() and "wipe" not in why.lower(), why
    assert str(session / "wl-pki.x86" / "sysroot") in why
    assert "continues from it" in why and "is passed --resume" in why
    assert "--resume" in _argv(drv, session)        # and that is what is really passed
    # 55 - 23 + 10: the tree is counted in full, and the image still does not fit
    assert "Even with all 23 GiB counted" in why
    assert "needs about 42 GiB" in why and "only 30.0 GiB is free, 12.0 GiB short" in why
    assert bd.SPACE_ENV in why
    assert tree.calls == []                         # preflight never walks a tree


@pytest.mark.parametrize("resume", [True, False])
@pytest.mark.parametrize("free_gib, blocked", [(41, True), (42, False), (64, False)])
def test_a_restart_counts_the_build_tree_the_image_already_has(monkeypatch, tmp_path, resume,
                                                               free_gib, blocked):
    """With or without --resume, the space the earlier tree holds is not needed again: the
    builder continues from it, or rebuilds it where it is. So an x86 restart is blocked
    below 55 - 23 + 10 = 42 GiB, not below 65. Between the two the answer depends on how
    much of the tree is there, which preflight does not measure and so does not refuse."""
    _pin_disk(monkeypatch, free_gib * GIB)
    tree = _pin_tree(monkeypatch, 0)
    drv, _session = _restart(tmp_path, resume=resume)
    assert bool(_space(drv.preflight())) is blocked
    assert tree.calls == []


def test_a_restart_without_resume_says_the_tree_is_rebuilt_in_place(monkeypatch, tmp_path):
    """Resume unticked: the Studio passes no --resume and the builder rebuilds the tree
    where it is. x86, rpi5, orangepi5 and orangepi4-lts remove the sysroot first and the
    other six extract the stage3 over it, so "wipes" would be wrong for six of ten. The
    message says what is passed, and still does not send the operator to delete it."""
    _pin_disk(monkeypatch, 30 * GIB)
    drv, session = _restart(tmp_path, resume=False)
    [why] = _space(drv.preflight())
    assert "rebuilds it in place" in why and "is not passed --resume" in why
    assert "continues from it" not in why
    assert "delet" not in why.lower() and "wipe" not in why.lower(), why
    assert "--resume" not in _argv(drv, session)
    assert "needs about 42 GiB" in why


@pytest.mark.parametrize("free_gib, blocked", [(64, True), (65, False)])
def test_a_tree_with_no_extracted_system_is_not_counted(monkeypatch, tmp_path, free_gib, blocked):
    """No ``sysroot/etc/gentoo-release``: the earlier run died before or during the stage3
    extraction (four of the incident session's six trees look like this). No builder
    continues from such a tree, so nothing is counted, assumed or measured: the image
    needs the full 65 GiB, and the message does not speak of an earlier tree."""
    disk = _pin_disk(monkeypatch, free_gib * GIB)
    tree = _pin_tree(monkeypatch, 23 * GIB)
    drv, _session = _restart(tmp_path, populated=False)
    problems = _space(drv.preflight())
    assert bool(problems) is blocked
    if blocked:
        assert "needs about 65 GiB" in problems[0] and "earlier run" not in problems[0]
    started = _fake_builds(monkeypatch, disk)
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    drv.run_all()
    assert started == ([] if blocked else ["x86"])
    assert tree.calls == []


@pytest.mark.parametrize("free_gib, blocked", [(22, True), (23, False)])
def test_an_arm_restart_counts_its_smaller_tree(monkeypatch, tmp_path, free_gib, blocked):
    """ARM: 20 - 7 + 10 = 23 GiB over a finished tree. The share is 7 and not more because
    every build writes the rest again: for an rpi5 node the 9.5 GiB raw .img (a 9216 MiB
    root), the stage4, the filesystem tarball and the compressed image."""
    _pin_disk(monkeypatch, free_gib * GIB)
    drv, _session = _restart(tmp_path, roles=[("backend", "rpi5")])
    assert bool(_space(drv.preflight())) is blocked


@pytest.mark.parametrize("free_gib, blocked", [(24, True), (25, False)])
def test_the_override_keeps_the_trees_proportion_of_the_estimate(monkeypatch, tmp_path,
                                                                free_gib, blocked):
    """HUGMESH_BUILD_IMAGE_SPACE=25 says one image needs 25 GiB. The part an earlier tree
    may already hold keeps its proportion (23 of 55, so 10.45 of 25), and a restart needs
    25 - 10.45 + 10 = 24.55 GiB. Crediting the table's 23 GiB against a 25 GiB image
    would leave 12."""
    monkeypatch.setenv(bd.SPACE_ENV, "25")
    _pin_disk(monkeypatch, free_gib * GIB)
    drv, _session = _restart(tmp_path)
    assert bool(_space(drv.preflight())) is blocked


def test_a_restart_over_a_finished_tree_is_dispatched(monkeypatch, tmp_path):
    """The reviewer's case: a populated wl-pki.x86/sysroot and 43 GiB free. The tree holds
    23 GiB and the resumed build writes 28 more, which 43 GiB holds, yet it was refused
    below 65. Right before the image starts, on the build thread, its tree is measured
    for exactly the credit that makes the image fit (65 - 43 = 22 GiB), after a line that
    says so."""
    disk = _pin_disk(monkeypatch, 43 * GIB)
    tree = _pin_tree(monkeypatch, 23 * GIB)
    started = _fake_builds(monkeypatch, disk, held={"wl-pki.x86": 23 * GIB})
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    drv, session = _restart(tmp_path)
    assert _space(drv.preflight()) == []
    code, _starts, dones, lines = _run(drv)
    assert started == ["x86"] and dones == [(0, 0)] and code == 0
    assert _ENOSPC not in lines
    sysroot = str(session / "wl-pki.x86" / "sysroot")
    assert tree.calls == [(sysroot, 22 * GIB)]
    said = [ln for ln in lines if ln.startswith("== ")]
    assert len(said) == 1 and "measuring the build tree" in said[0] and sysroot in said[0]


def test_a_restart_over_a_half_built_tree_is_refused_not_run_into_a_full_disk(monkeypatch,
                                                                             tmp_path):
    """Why the tree is MEASURED and not taken as finished. An earlier run that died early
    left 5 GiB of a 23 GiB tree. The rebuild writes the other 18 plus 28 of images, which
    43 GiB does not hold: dispatched, it ends in ENOSPC, the incident again. The refusal
    says what was found and what is still needed (55 - 5 + 10 = 60 GiB)."""
    disk = _pin_disk(monkeypatch, 43 * GIB)
    _pin_tree(monkeypatch, 5 * GIB)
    started = _fake_builds(monkeypatch, disk, held={"wl-pki.x86": 5 * GIB})
    drv, _session = _restart(tmp_path)
    assert _space(drv.preflight()) == []       # preflight cannot tell, so it does not block
    code, _starts, dones, lines = _run(drv)
    assert started == [] and dones == [(0, 1)] and code == 1
    assert drv.results[0].status == wd.FAILED
    assert _ENOSPC not in lines
    [why] = [ln for ln in lines if ln.startswith("!! ")]
    assert why.startswith("!! pki.x86 not started: not enough free disk space")
    assert "It holds 5.0 GiB" in why and "needs about 60 GiB" in why
    assert "only 43.0 GiB is free, 17.0 GiB short" in why
    assert "continues from it" in why
    assert "delet" not in why.lower() and "wipe" not in why.lower(), why


@pytest.mark.parametrize("short_by, dispatched", [(0, True), (1, False)])
def test_the_measured_tree_must_hold_all_of_the_credit_the_image_needs(monkeypatch, tmp_path,
                                                                      short_by, dispatched):
    """50 GiB free and 65 needed: the tree has to hold 15 GiB. Exactly that much is
    enough, and one byte less is not."""
    disk = _pin_disk(monkeypatch, 50 * GIB)
    tree = _pin_tree(monkeypatch, 15 * GIB - short_by)
    started = _fake_builds(monkeypatch, disk, held={"wl-pki.x86": 15 * GIB})
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    drv, _session = _restart(tmp_path)
    _run(drv)
    assert tree.calls and tree.calls[0][1] == 15 * GIB
    assert started == (["x86"] if dispatched else [])


def test_an_unknowable_disk_neither_refuses_nor_measures_a_restart(monkeypatch, tmp_path):
    """free_bytes_for's -1 on a restart: the rule is the same as on a first run (never
    refuse on an unknowable answer), and no tree is walked to decide nothing."""
    def broken(path):
        raise PermissionError(13, "Permission denied", str(path))

    monkeypatch.setattr(es, "_disk_usage", broken)
    tree = _pin_tree(monkeypatch, 0)
    started = _fake_builds(monkeypatch, _Disk(500 * GIB))
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    drv, _session = _restart(tmp_path)
    assert _space(drv.preflight()) == [] and _space(drv.preflight_warnings()) == []
    _run(drv)
    assert started == ["x86"] and tree.calls == []


def test_the_dispatch_check_gives_no_verdict_for_a_walk_that_was_stopped(monkeypatch, tmp_path):
    """dispatch_space_refusal's own contract, without the driver: None (not "" and not a
    refusal) when the walk reports it was stopped, whatever it had counted."""
    _pin_disk(monkeypatch, 43 * GIB)
    session = tmp_path / "out" / "sessions" / "s1"
    _earlier_tree(session, "pki.x86")
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    said = []
    for holds in (0, 23 * GIB):
        monkeypatch.setattr(bd, "_measure_tree", lambda path, **kw: bd.TreeMeasure(
            bytes=holds, stopped=True))
        assert bd.dispatch_space_refusal(cfg, str(session), on_measure=said.append,
                                         build_tree=str(session / "wl-pki.x86")) is None
    assert said == [str(session / "wl-pki.x86" / "sysroot")] * 2
    # and the same walk, not stopped: a verdict either way
    monkeypatch.setattr(bd, "_measure_tree", lambda path, **kw: bd.TreeMeasure(bytes=0))
    assert "It holds 0.0 GiB" in bd.dispatch_space_refusal(
        cfg, str(session), build_tree=str(session / "wl-pki.x86"))
    monkeypatch.setattr(bd, "_measure_tree", lambda path, **kw: bd.TreeMeasure(bytes=23 * GIB))
    assert bd.dispatch_space_refusal(cfg, str(session),
                                     build_tree=str(session / "wl-pki.x86")) == ""


def test_no_more_than_the_trees_share_is_ever_counted():
    """Whatever a tree is measured at, the part of the estimate that every build writes
    again (the images and archives) stays needed."""
    space = bd.ImageSpace(estimate=55 * GIB, share=23 * GIB, sysroot="/x/sysroot")
    assert space.need() == 65 * GIB
    assert space.need(5 * GIB) == 60 * GIB
    assert space.need(23 * GIB) == space.need(400 * GIB) == 42 * GIB
    assert space.need(-5 * GIB) == 65 * GIB
    assert [space.credit_wanted(f * GIB) for f in (41, 42, 43, 64, 65)] == [
        0, 23 * GIB, 22 * GIB, 1 * GIB, 0]
    assert space.credit_wanted(-1) == 0
    assert bd.ImageSpace(0, 0, "").credit_wanted(5 * GIB) == 0


@pytest.mark.parametrize("free_gib, dispatched, said", [
    (65, True, ""),                                    # fits with nothing counted
    (41, False, "Even with all 23 GiB counted"),       # too small even for a finished tree
])
def test_no_tree_is_measured_when_the_answer_cannot_change(monkeypatch, tmp_path, free_gib,
                                                           dispatched, said):
    """Reading a tree costs up to minutes on a slow disk (43 s for a real 24 GiB x86 tree on
    the incident host). It is worth that only between 42 and 65 GiB, where it decides."""
    disk = _pin_disk(monkeypatch, free_gib * GIB)
    tree = _pin_tree(monkeypatch, 23 * GIB)
    started = _fake_builds(monkeypatch, disk, held={"wl-pki.x86": 23 * GIB})
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    drv, _session = _restart(tmp_path)
    _code, _starts, _dones, lines = _run(drv)
    assert started == (["x86"] if dispatched else [])
    assert tree.calls == []
    assert not [ln for ln in lines if ln.startswith("== ")]
    refusals = [ln for ln in lines if ln.startswith("!! ")]
    assert bool(refusals) is not dispatched
    if said:
        assert said in refusals[0]


def test_a_stop_while_the_tree_is_measured_starts_nothing_and_blames_nothing(monkeypatch,
                                                                            tmp_path):
    """Measuring can take minutes, and Stop has to work during it: the image is not
    dispatched, its row is STOPPED and not FAILED, and no refusal is written for a check
    that never finished."""
    disk = _pin_disk(monkeypatch, 43 * GIB)
    tree = _pin_tree(monkeypatch, 1 * GIB)
    started = _fake_builds(monkeypatch, disk)
    drv, _session = _restart(tmp_path)
    tree.on_call = lambda: drv.cancel(0)
    _code, starts, dones, lines = _run(drv)
    assert started == [] and starts == [0] and dones == [(0, None)]
    assert drv.results[0].status == wd.STOPPED and drv.results[0].exit_code is None
    assert not [ln for ln in lines if ln.startswith("!! ")]
    assert tree.stop_asked == [True]        # the walk itself was told, so it can end early


def test_a_stop_that_lands_as_the_measurement_ends_still_starts_nothing(monkeypatch, tmp_path):
    """The walk found the tree finished and returned, and the Stop arrived in the same
    moment. The image fits, but it was stopped: it must not start."""
    disk = _pin_disk(monkeypatch, 43 * GIB)
    tree = _pin_tree(monkeypatch, 23 * GIB)
    tree.sees_stop = False
    started = _fake_builds(monkeypatch, disk, held={"wl-pki.x86": 23 * GIB})
    drv, _session = _restart(tmp_path, roles=[("pki", "x86"), ("backend", "x86")])
    tree.on_call = drv.cancel_all
    _code, _starts, dones, lines = _run(drv)
    assert started == [] and dones == [(0, None), (1, None)]
    assert [r.status for r in drv.results] == [wd.STOPPED, wd.STOPPED]
    assert not [ln for ln in lines if ln.startswith("!! ")]


def test_a_measurement_cut_short_counts_only_what_it_proved_and_says_so(monkeypatch, tmp_path):
    """The walk hit its time limit, and three directories were root-only. What it counted
    is a lower bound, so only that is credited (never the full share on a guess), and the
    refusal tells the operator both facts."""
    disk = _pin_disk(monkeypatch, 43 * GIB)
    _pin_tree(monkeypatch, 5 * GIB, cut_short=True, unreadable=3)
    started = _fake_builds(monkeypatch, disk, held={"wl-pki.x86": 23 * GIB})
    drv, _session = _restart(tmp_path)
    _code, _starts, _dones, lines = _run(drv)
    assert started == []
    [why] = [ln for ln in lines if ln.startswith("!! ")]
    assert "It holds at least 5.0 GiB" in why
    assert f"measuring it stopped at the {bd.TREE_MEASURE_SECONDS}-second limit" in why
    assert "3 of its directories or files could not be read and are not counted" in why
    assert "needs about 60 GiB" in why


def test_a_refused_restart_image_does_not_stop_the_ones_after_it(monkeypatch, tmp_path):
    """A restart of two images at 43 GiB: the x86 one has a half-built tree and is
    refused, and the rpi5 one after it has a finished tree and still builds."""
    disk = _pin_disk(monkeypatch, 43 * GIB)
    sizes = {"wl-pki.x86": 5 * GIB, "wl-backend.rpi5": 8 * GIB}
    started = _fake_builds(monkeypatch, disk, held=sizes)
    monkeypatch.setattr(wd.WorklistDriver, "_generate_keys", lambda *a, **k: None)
    drv, _session = _restart(tmp_path, roles=[("pki", "x86"), ("backend", "rpi5")])
    walked: list[str] = []

    def measure(path, *, enough=0, seconds=0, should_stop=None):
        walked.append(os.path.basename(os.path.dirname(str(path))))
        return bd.TreeMeasure(bytes=sizes[walked[-1]])

    monkeypatch.setattr(bd, "_measure_tree", measure, raising=False)
    _code, _starts, dones, lines = _run(drv)
    assert started == ["rpi5"] and dones == [(0, 1), (1, 0)]
    assert walked == ["wl-pki.x86"]          # 43 GiB holds an rpi5 image outright: no walk
    assert _ENOSPC not in lines


@pytest.mark.parametrize("free_gib, warned", [(73, True), (74, False)])
def test_the_whole_list_warning_counts_the_trees_a_restart_already_has(monkeypatch, tmp_path,
                                                                      free_gib, warned):
    """Two x86 images restarted over their finished trees need (55 - 23) * 2 + 10 = 74 GiB
    together, not 120. The warning says how many trees it counted, and measures none."""
    _pin_disk(monkeypatch, free_gib * GIB)
    tree = _pin_tree(monkeypatch, 0)
    drv, _session = _restart(tmp_path, roles=[("pki", "x86"), ("backend", "x86")])
    assert _space(drv.preflight()) == []
    warnings = _space(drv.preflight_warnings())
    assert bool(warnings) is warned
    if warned:
        assert "need about 74 GiB together" in warnings[0]
        assert "the build trees 2 of them already have" in warnings[0]
        assert "choose an output folder" not in warnings[0]    # a restart cannot move
    assert tree.calls == []


def test_a_first_run_says_nothing_of_an_earlier_tree(monkeypatch, tmp_path):
    """A first run into a new session dir has no tree to count, and its refusal still
    offers the bigger disk (a restart cannot move, so its refusal does not)."""
    _pin_disk(monkeypatch, 43 * GIB)
    fresh = tmp_path / "out" / "sessions" / "s2"
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, [("pki", "x86")]),
                            host=host(), workdir=str(fresh))
    [why] = _space(drv.preflight())
    assert "earlier run" not in why and "--resume" not in why
    assert "choose an output folder on a bigger disk" in why
    drv, _session = _restart(tmp_path)
    _pin_disk(monkeypatch, 30 * GIB)
    assert "choose an output folder" not in _space(drv.preflight())[0]


# ── what the message claims about the builders, held to the builders ────────────────
def _one_image_per_platform():
    """(mode, role, platform) for every platform the Studio offers, from its role table."""
    seen: dict[str, tuple[str, str, str]] = {}
    for mode, rows in ROLE_CHOICES.items():
        for role, platforms, _label in rows:
            for platform in platforms:
                seen.setdefault(platform, (mode, role, platform))
    return [seen[p] for p in sorted(seen)]


@pytest.mark.parametrize("mode, role, platform", _one_image_per_platform())
def test_every_builder_continues_from_a_populated_sysroot_when_the_studio_passes_resume(
        mode, role, platform):
    """The three facts the restart arithmetic and its wording stand on, for all ten
    builders: the build system is ``<work dir>/<build subdir>/sysroot`` (so
    ``wl-<id>/sysroot`` in a Studio session), a populated one is told by
    ``etc/gentoo-release``, and with --resume the builder skips the extraction and
    continues from it. And the Studio passes --resume exactly when Resume is ticked."""
    cfg = ImageConfig(mode=mode, role=role, platform=platform, brand="acme",
                      brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                      superdomain="core.acme.internal")
    cfg.resume = True
    assert "--resume" in cfg.to_cli_args()
    cfg.resume = False
    assert "--resume" not in cfg.to_cli_args()
    with open(os.path.join(GENERATOR_DIR, cfg.builder_script), encoding="utf-8") as fh:
        script = fh.read()
    assert 'BUILD_ROOT="${WORK_DIR}/${BUILD_SUBDIR}"' in script
    assert 'SYSROOT="${BUILD_ROOT}/sysroot"' in script
    reuse = re.search(r'^if \[ -f "\$\{SYSROOT\}/etc/gentoo-release" \] && \$\{RESUME\}; then\n'
                      r'(?:.*\n)*?^else$', script, re.M)
    assert reuse, f"{cfg.builder_script}: the --resume reuse branch moved"
    assert "skipping extraction" in reuse.group(0)
    assert "rm -rf" not in reuse.group(0)      # under --resume the tree is never removed


def test_the_builders_that_do_not_take_resume_never_all_wipe(monkeypatch):
    """"The builder wipes it before rebuilding" was the round-1 wording. Without --resume
    four builders remove a populated sysroot and six extract the stage3 over it, which
    is why the message says "rebuilds it in place" for all of them."""
    wipes, overlays = [], []
    for _mode, _role, platform in _one_image_per_platform():
        script_name = ImageConfig(platform=platform).builder_script
        with open(os.path.join(GENERATOR_DIR, script_name), encoding="utf-8") as fh:
            script = fh.read()
        branch = re.search(r'^if \[ -f "\$\{SYSROOT\}/etc/gentoo-release" \] && \$\{RESUME\}; then\n'
                           r'(?:.*\n)*?^else\n((?:.*\n)*?)^fi$', script, re.M)
        assert branch, script_name
        (wipes if re.search(r'rm -rf "\$\{SYSROOT(:\?)?\}"', branch.group(1))
         else overlays).append(platform)
    assert sorted(wipes) == ["orangepi4-lts", "orangepi5", "rpi5", "x86"]
    assert len(overlays) == 6 and "frite" in overlays and "jetson" in overlays


# ── the walk itself ─────────────────────────────────────────────────────────────────
_CHUNK = 64 * 1024


def _file(path, chunks=1):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(os.urandom(_CHUNK) * chunks)   # not sparse, not compressible


def test_measuring_counts_what_the_tree_holds(tmp_path):
    for name in ("etc/gentoo-release", "usr/lib64/libc.so.6", "var/db/pkg/sys-libs/glibc/CONTENTS"):
        _file(tmp_path / "sysroot" / name)
    got = bd.measure_tree(str(tmp_path / "sysroot"))
    assert got.bytes >= 3 * _CHUNK
    assert got.bytes < 3 * _CHUNK + 4 * 1024 * 1024       # and nothing that is not there
    assert (got.cut_short, got.unreadable, got.stopped) == (False, 0, False)


def test_measuring_stops_as_soon_as_enough_is_counted(tmp_path):
    """The caller needs to know whether a credit is there, not how big the tree is. Once
    that many bytes are counted the rest is not read (a finished 24 GiB tree would
    otherwise always cost its full walk)."""
    for n in range(40):
        _file(tmp_path / "sysroot" / f"usr/lib64/lib{n}.so")
    whole = bd.measure_tree(str(tmp_path / "sysroot")).bytes
    got = bd.measure_tree(str(tmp_path / "sysroot"), enough=3 * _CHUNK)
    assert 3 * _CHUNK <= got.bytes < whole
    assert (got.cut_short, got.stopped) == (False, False)


def test_measuring_does_not_follow_a_symlink_out_of_the_tree(tmp_path):
    _file(tmp_path / "elsewhere" / "big", chunks=64)             # 4 MiB outside the tree
    _file(tmp_path / "sysroot" / "etc" / "gentoo-release")
    try:
        os.symlink(tmp_path / "elsewhere", tmp_path / "sysroot" / "mnt", target_is_directory=True)
        os.symlink(tmp_path / "elsewhere" / "big", tmp_path / "sysroot" / "big")
    except (OSError, NotImplementedError):
        pytest.skip("this host cannot create symlinks")
    assert bd.measure_tree(str(tmp_path / "sysroot")).bytes < 64 * _CHUNK


def test_measuring_skips_what_is_on_another_filesystem(monkeypatch, tmp_path):
    """A crashed build leaves /proc, /sys and /dev bound under its sysroot, and they are
    not the tree. Simulated by giving the tree's root another device number, which makes
    every entry in it foreign."""
    if os.name == "nt":
        pytest.skip("a Windows directory listing carries no device number to compare")
    _file(tmp_path / "sysroot" / "etc" / "gentoo-release")
    real_stat = os.stat
    root = str(tmp_path / "sysroot")

    def other_device(path, *a, **k):
        st = real_stat(path, *a, **k)
        if str(path) != root:
            return st
        return os.stat_result((st.st_mode, st.st_ino, st.st_dev + 1, *tuple(st)[3:]))

    monkeypatch.setattr(bd.os, "stat", other_device)
    assert bd.measure_tree(root).bytes == 0


def test_measuring_counts_what_a_sparse_file_really_holds(tmp_path):
    """A raw .img is created at its full length and filled later. Counted by length, a
    half-written one would be credited for space it never took."""
    _file(tmp_path / "sysroot" / "etc" / "gentoo-release")
    hole = tmp_path / "sysroot" / "var" / "sparse.img"
    hole.parent.mkdir(parents=True)
    with open(hole, "wb") as fh:
        fh.truncate(64 * 1024 * 1024)
    blocks = getattr(os.stat(hole), "st_blocks", None)
    if blocks is None or blocks * 512 > 1024 * 1024:
        pytest.skip("this filesystem does not keep the file sparse (eCryptfs, Windows)")
    assert bd.measure_tree(str(tmp_path / "sysroot")).bytes < 8 * 1024 * 1024


def test_an_entry_counts_for_its_blocks_and_for_its_length_only_without_them():
    """The same rule without a filesystem (the test above skips where files do not stay
    sparse). A 64 MiB file holding 8 blocks counts 4096 bytes. A stat with no block
    count, which is what Windows gives, counts its length."""
    from types import SimpleNamespace
    assert bd._allocated_bytes(SimpleNamespace(st_size=64 << 20, st_blocks=8)) == 4096
    assert bd._allocated_bytes(SimpleNamespace(st_size=64 << 20, st_blocks=0)) == 0
    assert bd._allocated_bytes(SimpleNamespace(st_size=64 << 20)) == 64 << 20


def test_measuring_counts_a_file_with_two_names_once(tmp_path):
    _file(tmp_path / "one" / "bin" / "busybox", chunks=16)
    _file(tmp_path / "two" / "bin" / "busybox", chunks=16)
    try:
        os.link(tmp_path / "two" / "bin" / "busybox", tmp_path / "two" / "bin" / "sh")
    except (OSError, NotImplementedError):
        pytest.skip("this filesystem cannot hard-link")
    one, two = (bd.measure_tree(str(tmp_path / n)).bytes for n in ("one", "two"))
    assert two < one + 16 * _CHUNK


def test_measuring_reports_what_it_could_not_read(tmp_path):
    if os.name == "nt" or os.geteuid() == 0:
        pytest.skip("needs a directory this user cannot read")
    _file(tmp_path / "sysroot" / "etc" / "gentoo-release")
    _file(tmp_path / "sysroot" / "root" / "secret", chunks=16)
    (tmp_path / "sysroot" / "root").chmod(0)
    try:
        got = bd.measure_tree(str(tmp_path / "sysroot"))
    finally:
        (tmp_path / "sysroot" / "root").chmod(0o700)
    assert got.unreadable == 1 and _CHUNK <= got.bytes < 16 * _CHUNK
    assert bd.measure_tree(str(tmp_path / "no-such-tree")) == bd.TreeMeasure(0, unreadable=1)


def test_measuring_gives_up_at_its_time_limit_with_what_it_has(monkeypatch, tmp_path):
    for n in range(6):
        _file(tmp_path / "sysroot" / f"f{n}")
    monkeypatch.setattr(bd, "_TREE_CHECK_EVERY", 2)
    whole = bd.measure_tree(str(tmp_path / "sysroot")).bytes
    got = bd.measure_tree(str(tmp_path / "sysroot"), seconds=-1)   # the limit has passed
    assert got.cut_short and not got.stopped and 0 < got.bytes < whole


def test_measuring_ends_when_the_operator_stops_the_image(monkeypatch, tmp_path):
    for n in range(6):
        _file(tmp_path / "sysroot" / f"f{n}")
    monkeypatch.setattr(bd, "_TREE_CHECK_EVERY", 2)
    asked = []
    got = bd.measure_tree(str(tmp_path / "sysroot"),
                          should_stop=lambda: asked.append(1) or len(asked) >= 2)
    assert got.stopped and not got.cut_short and len(asked) == 2
    assert got.bytes < bd.measure_tree(str(tmp_path / "sysroot")).bytes


# ── session start: block on the next image, warn on the whole list ─────────────────
def test_preflight_blocks_when_the_first_image_cannot_fit(monkeypatch, tmp_path):
    _pin_disk(monkeypatch, 43 * GIB)      # this workstation's /home on 2026-11-11
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, [("pki", "x86")]), host=host())
    problems = [p for p in drv.preflight() if "disk space" in p]
    assert len(problems) == 1
    assert "not enough free disk space" in problems[0]


@pytest.mark.parametrize("roles, blocked", [
    ([("pki", "x86"), ("backend", "rpi5")], True),     # the next image is the x86 one
    ([("backend", "rpi5"), ("pki", "x86")], False),    # the next image is the rpi5 one
])
def test_preflight_judges_the_next_image_not_any_image(monkeypatch, tmp_path, roles, blocked):
    """Only the FIRST entry blocks the session. With 40 GiB free an rpi5 image fits and
    an x86 one does not, so the order of the same two images decides."""
    _pin_disk(monkeypatch, 40 * GIB)
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, roles), host=host())
    assert bool([p for p in drv.preflight() if "disk space" in p]) is blocked
    warned = bool([w for w in drv.preflight_warnings() if "disk space" in w])
    assert warned is not blocked          # a blocked session is not also warned about


def test_preflight_checks_the_output_dir_filesystem(monkeypatch, tmp_path):
    """The probe must be asked about the dir the builds write to, not the checkout.
    The session dir does not exist yet, so free_bytes_for walks up to an existing
    ancestor of it."""
    disk = _pin_disk(monkeypatch, 500 * GIB)
    (tmp_path / "out").mkdir()
    drv = wd.WorklistDriver(str(tmp_path / "gen"), _mesh(tmp_path, [("pki", "x86")]),
                            host=host(), workdir=str(tmp_path / "out" / "sessions" / "s1"))
    drv.preflight()
    assert str(tmp_path / "out") in disk.probed


def test_preflight_passes_when_only_later_images_do_not_fit_and_warns_instead(monkeypatch, tmp_path):
    _pin_disk(monkeypatch, 117 * GIB)
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, _incident_roles()), host=host())
    assert not [p for p in drv.preflight() if "disk space" in p]
    warnings = [w for w in drv.preflight_warnings() if "disk space" in w]
    assert len(warnings) == 1
    assert "re-checked before it starts" in warnings[0]


@pytest.mark.parametrize("free_gib", [55, 60, 64])
def test_a_blocked_session_is_not_also_told_its_first_image_passes(monkeypatch, tmp_path,
                                                                  free_gib):
    """Between the estimate (55 GiB) and the estimate plus its margin (65 GiB) the first
    image is refused. The warning must judge it by the same need, margin included, or a
    session that is blocked would also read "The first image passes this check"."""
    _pin_disk(monkeypatch, free_gib * GIB)
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, [("pki", "x86"), ("backend", "x86")]),
                            host=host())
    assert _space(drv.preflight())
    assert _space(drv.preflight_warnings()) == []


def test_no_space_warning_when_the_whole_list_fits(monkeypatch, tmp_path):
    _pin_disk(monkeypatch, 4096 * GIB)
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, _incident_roles()), host=host())
    assert not [p for p in drv.preflight() if "disk space" in p]
    assert not [w for w in drv.preflight_warnings() if "disk space" in w]


@pytest.mark.parametrize("free_gib, warned", [(119, True), (120, False)])
def test_the_whole_list_warning_counts_every_image(monkeypatch, tmp_path, free_gib, warned):
    """Two x86 images need 55 + 55 + a 10 GiB margin = 120 GiB together. The first one
    fits in either case, so the session is not blocked; the warning must price BOTH
    images, the first included, or it stays quiet on a disk that cannot finish."""
    _pin_disk(monkeypatch, free_gib * GIB)
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, [("pki", "x86"), ("backend", "x86")]),
                            host=host())
    assert not [p for p in drv.preflight() if "disk space" in p]
    assert bool([w for w in drv.preflight_warnings() if "disk space" in w]) is warned


def test_a_disk_with_nothing_free_refuses(monkeypatch, tmp_path):
    """0 bytes free is a real answer, and the state the incident left its disk in. Only
    free_bytes_for's -1 (unknowable) skips the check; a full disk must still refuse."""
    _pin_disk(monkeypatch, 0)
    cfg = ImageConfig(mode="mesh", role="backend", platform="rpi5")
    assert "not enough free disk space" in bd.disk_space_refusal(cfg, str(tmp_path))
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, [("backend", "rpi5")]), host=host())
    assert [p for p in drv.preflight() if "disk space" in p]


def test_unknowable_free_space_never_refuses(monkeypatch, tmp_path):
    """-1 from free_bytes_for (an unreadable filesystem) must not block a build that
    may well fit. Same rule as emulation_save.preflight_refusal."""
    def broken(path):
        raise PermissionError(13, "Permission denied", str(path))

    monkeypatch.setattr(es, "_disk_usage", broken)
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    assert bd.disk_space_refusal(cfg, str(tmp_path / "out")) == ""
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, [("pki", "x86")]), host=host())
    assert not [p for p in drv.preflight() if "disk space" in p]
    assert not [w for w in drv.preflight_warnings() if "disk space" in w]


@pytest.mark.parametrize("free_gib, refused", [(64, True), (65, False), (66, False)])
def test_the_x86_need_is_estimate_plus_margin_exactly(monkeypatch, tmp_path, free_gib, refused):
    _pin_disk(monkeypatch, free_gib * GIB)
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    assert bool(bd.disk_space_refusal(cfg, str(tmp_path))) is refused


@pytest.mark.parametrize("free_gib, refused", [(29, True), (30, False)])
def test_an_arm_image_needs_less_than_an_x86_one(monkeypatch, tmp_path, free_gib, refused):
    _pin_disk(monkeypatch, free_gib * GIB)
    cfg = ImageConfig(mode="mesh", role="backend", platform="rpi5")
    assert bool(bd.disk_space_refusal(cfg, str(tmp_path))) is refused


# Every board the Studio offers other than x86, read from its own role table so a new
# board is covered the day it is added.
_ARM_PLATFORMS = sorted({p for rows in ROLE_CHOICES.values() for _role, plats, _label in rows
                         for p in plats} - {"x86"})


@pytest.mark.parametrize("platform", _ARM_PLATFORMS)
def test_every_arm_board_is_priced_as_arm(monkeypatch, tmp_path, platform):
    """rpi5 is not the only ARM board. A Jetson or Orange Pi image priced as x86 would be
    refused on a disk that holds it (30 GiB free is enough for 20 + 10)."""
    assert "rpi5" in _ARM_PLATFORMS and len(_ARM_PLATFORMS) > 1
    cfg = ImageConfig(mode="mesh", role="backend", platform=platform)
    _pin_disk(monkeypatch, 30 * GIB)
    assert bd.disk_space_refusal(cfg, str(tmp_path)) == ""
    _pin_disk(monkeypatch, 29 * GIB)
    assert "not enough free disk space" in bd.disk_space_refusal(cfg, str(tmp_path))


# ── the operator's override ───────────────────────────────────────────────────────────
@pytest.mark.parametrize("value", ["0", "off", "none", "OFF"])
def test_the_guard_can_be_switched_off(monkeypatch, tmp_path, value):
    _pin_disk(monkeypatch, 1 * GIB)
    monkeypatch.setenv(bd.SPACE_ENV, value)
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    assert bd.disk_space_refusal(cfg, str(tmp_path)) == ""


def test_the_override_replaces_the_per_image_estimate(monkeypatch, tmp_path):
    _pin_disk(monkeypatch, 40 * GIB)
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    monkeypatch.setenv(bd.SPACE_ENV, "25")        # 25 + 10 margin = 35 <= 40
    assert bd.disk_space_refusal(cfg, str(tmp_path)) == ""
    monkeypatch.setenv(bd.SPACE_ENV, "31")        # 31 + 10 margin = 41 > 40
    assert "not enough free disk space" in bd.disk_space_refusal(cfg, str(tmp_path))


@pytest.mark.parametrize("value", ["lots", "nan", "inf", "1e308", "-5"])
def test_an_unusable_override_falls_back_to_the_estimate(monkeypatch, tmp_path, value):
    """A typo, or a number that is not a usable size, must neither raise (run_all calls
    this before every image) nor silently switch the guard off."""
    _pin_disk(monkeypatch, 43 * GIB)
    monkeypatch.setenv(bd.SPACE_ENV, value)
    cfg = ImageConfig(mode="mesh", role="pki", platform="x86")
    assert "not enough free disk space" in bd.disk_space_refusal(cfg, str(tmp_path))
