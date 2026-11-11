"""Free-space preflight for Studio builds (defect L4).

THE INCIDENT. Session 20261110-220215-cde67f: a 23-image mesh started with about
117 GiB free under its output dir and ran for 1.5 h before ENOSPC took out 5 images.
Its error tails read ``truncate: failed to truncate ...pki-test-...img``,
``tee: /out/build.log: No space left on device`` and ``cannot open pool lockfile ...
No space left on device``. Nothing checked free space before dispatch or between images,
so the session record held a mid-build crash where a refusal belonged.

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

No real disk is involved. The probe is ``emulation_save._disk_usage``, the injectable
seam ``emulation_save.free_bytes_for`` already reads. conftest pins it to a roomy answer
for the rest of the suite, and each test here pins it to the answer it needs.
"""
from __future__ import annotations

import collections

import pytest

from hugmesh_studio.core import build_driver as bd
from hugmesh_studio.core import emulation_save as es
from hugmesh_studio.core import worklist_driver as wd
from hugmesh_studio.core.config import ROLE_CHOICES, ImageConfig
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry

GIB = 1024 ** 3
_Usage = collections.namedtuple("_Usage", "total used free")

# What one real build actually leaves on disk, independent of the estimate under test.
# Measured on the incident session: an x86 pki image held a ~23 GiB payload plus a
# ~28 GiB .img. ARM is smaller. The simulation consumes THESE, so a passing test means
# no dispatched build ran out of space, not that the code agrees with its own constants.
_X86_FOOTPRINT, _ARM_FOOTPRINT = 51 * GIB, 15 * GIB
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


def _fake_builds(monkeypatch, disk: _Disk):
    """BuildDriver stand-in that writes a real-sized footprint to ``disk``. A build that
    starts without that much free space fails the way the incident's did."""
    started: list[str] = []

    class FakeBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir

        def run(self, cfg, backend, on_line=None):
            started.append(cfg.platform)
            need = _X86_FOOTPRINT if cfg.platform == "x86" else _ARM_FOOTPRINT
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
    """THE REGRESSION. 117 GiB free, 23 images. Before the fix all 23 were dispatched.
    Every one after the space ran out failed mid-build with ENOSPC (simulated here as the
    error-tail line the real session recorded). After the fix nothing hits ENOSPC. The
    images that no longer fit are refused before dispatch, each with a reason."""
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


def test_no_space_warning_when_the_whole_list_fits(monkeypatch, tmp_path):
    _pin_disk(monkeypatch, 4096 * GIB)
    drv = wd.WorklistDriver(str(tmp_path), _mesh(tmp_path, _incident_roles()), host=host())
    assert not [p for p in drv.preflight() if "disk space" in p]
    assert not [w for w in drv.preflight_warnings() if "disk space" in w]


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
