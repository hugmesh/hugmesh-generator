"""The per-JOB package-list affordance is GREYED until that job reaches its emerge phase.

Operator, 2026-07-29, after watching a live build with the per-package tree: "we can see the
packages now in the current builder and this is good leave this as a default with the option
to expand greyed out until things reach the emerge phase". They had opened the tree while the
job was still at "Verify seed" — a control that looks live and yields nothing reads as a
broken feature.

What these tests pin, driving the REAL page's real slots (offscreen Qt, the same harness as
test_pages_progress_packages.py / test_pages_progress_jobs.py):

* the control EXISTS from the first paint and is disabled + greyed + honestly explained,
  before emerge, on an x86 AND on an ARM platform;
* it enables on the FIRST real emerge signal — and on ARM too. When this gate shipped the
  tables named their emerge stages differently per platform ("Emerge packages" on x86,
  "Phase 1: @system" on ARM), so a label rule would silently never have enabled on ARM;
  the uniformity pass has since made the labels canonical and SHARED ("Emerge @system" /
  "Emerge role payload" everywhere), but the gate still keys on the emerge-group SIGNAL,
  never the label — the enable tests below prove it with real banner streams, and the
  pre-uniformity ARM banners in this module double as a compat-policy regression test;
* it is PER JOB: two images in different phases, two different states;
* it never regresses — collapse/expand, a later stage, and a finished build all keep it live;
* nothing on this path can escape a Qt slot. The operator runs PyQt6, where an unhandled
  exception in a slot calls qFatal and ABORTS the process.

Banner lines are the REAL builder banners (their `banner "..."` call sites, mirrored in
core/progress-tables.json, which a drift probe in test_progress_parse.py already holds to the
builders); the emerge/counter lines are the shapes of the operator's own transcripts
(out/sessions/20260725-140638-09692d for x86, .../20260729-065121-ce11e0 for rpi5).
"""
import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.core.progress_parse import platform_phases          # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod           # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"

# the real ROOT an rpi5 cross build merges into (build-pki.rpi5.log, L137)
_ARM_ROOT = "/out/wl-pki.rpi5/sysroot/"


def _banner(text: str) -> str:
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


def _jobs(done, total, running=0):
    """A ">>> Jobs:" scheduler line with portage's right-alignment run, as the real
    parallel transcript prints it (build-pki.rpi5.log L142/L146)."""
    head = f">>> Jobs: {done} of {total} complete"
    if running:
        head = f">>> Jobs: {done} of {total} complete, {running} running"
    return f"{head}{' ' * max(1, 72 - len(head))}Load avg: 6.71, 6.83, 5.95"


# x86: the banners that precede the emerge stage, then the emerge stage's own banners.
# "Verifying stage3 seed signature" is phase 4 ("Verify seed") — the exact place the
# operator opened the tree.
_X86_PRE_EMERGE = [
    _banner("Rebranding baked config"),
    _banner("Verifying prerequisites"),
    _banner("Preparing build directories"),
    _banner("Fetching amd64 hardened stage3 seed"),
    _banner("Verifying stage3 seed signature"),
]
_X86_EMERGE_BANNER = _banner("Native emerge inside chroot")   # x86 phase 10 opens
_X86_GROUP_BANNER = _banner("Emerge group: image")

# rpi5 (ARM): the SAME shape of run, with the ARM builder's own banner vocabulary. Note
# that none of these strings is the x86 one — that is the anti-hardcode proof.
_ARM_PRE_EMERGE = [
    _banner("Rebranding baked config"),
    _banner("Preparing build directories"),
    _banner("Fetching latest arm64 stage3 seed"),
    _banner("Verifying stage3 seed signature"),
    _banner("Extracting seed stage3"),
]
_ARM_EMERGE_BANNER = _banner("Phase 1: Cross-building @system")
_ARM_GROUP_BANNER = _banner("Emerge group: system")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    yield w
    w.close()
    w.deleteLater()


def _progress_page(wiz):
    return wiz.page(wiz._page_ids["progress"])


def _fresh_page(wiz, rows=(("acme-x86", "x86"),)):
    """A page with N direct-slot rows (no driver, no worker) — the established harness."""
    page = _progress_page(wiz)
    page._reset()
    for i, (label, platform) in enumerate(rows):
        page._build_row(i, label, platform)
    return page


def _feed(page, i, lines):
    for ln in lines:
        page._on_line(i, ln)


# ── 1. present, but disabled + greyed + explained, BEFORE emerge ───────────────────────
@pytest.mark.parametrize("platform,pre,emerge_stage_label", [
    ("x86", _X86_PRE_EMERGE, "Emerge @system"),
    ("rpi5", _ARM_PRE_EMERGE, "Emerge @system"),
])
def test_affordance_is_present_but_disabled_before_emerge(wiz, platform, pre,
                                                          emerge_stage_label):
    """Both an x86 and an ARM job: the control is REAL (a widget in the job row), it is
    disabled, it carries the honest hint, and there is genuinely nothing to show yet."""
    page = _fresh_page(wiz, rows=((f"acme-{platform}", platform),))
    row = page._rows[0]
    _feed(page, 0, pre)
    btn = page.tree.itemWidget(row.job_item, progress_mod._COL_FLAGS)
    assert btn is not None and btn is row.pkg_btn          # present from the first paint
    assert btn.text() == progress_mod._PKG_EXPAND_TEXT
    assert btn.isEnabled() is False                        # NOT clickable-but-empty
    assert row.pkg_expandable is False
    assert btn.toolTip() == progress_mod._PKG_EXPAND_HINT
    assert "emerge phase" in btn.toolTip()                 # says WHY, in the operator's terms
    # visibly greyed, pinned by the stylesheet rather than left to the active style
    assert "QToolButton:disabled" in btn.styleSheet() and "#888888" in btn.styleSheet()
    # and the disabled state is honest: no group node, no package row exists
    assert row.group_items == {} and row.pkg_items == {}
    # the job is genuinely still short of its emerge stage on this platform
    labels = [s.label for s in row.tracker.stages]
    assert emerge_stage_label in labels
    assert row.tracker.cur < labels.index(emerge_stage_label)


def test_every_platform_shares_the_canonical_emerge_stage_labels(wiz):
    """HISTORY, INVERTED ON PURPOSE. This test used to pin that x86 ("Emerge packages")
    and ARM ("Phase 1: @system") did NOT share an emerge-stage label — the fact that made
    a label-matching gate silently dead on ARM. The uniformity pass made the labels
    canonical and identical everywhere (that is its entire point), so the old assertion
    now pins the opposite of the intended state. What survives of the original intent:
    the gate must key on the emerge-group SIGNAL, never the label — proven by the enable
    tests in this module, which drive it with real (including pre-uniformity/compat)
    banner streams. Here we pin the new deliberate fact instead: every platform's table
    names its emerge stages with the SAME canonical labels."""
    for platform in ("x86", "rpi5", "jetson", "frite", "orangepi5", "orangepizero2",
                     "orangepizero2w", "orangepizero3", "orangepi3-lts",
                     "orangepi4-lts"):
        labels = [p["label"] for p in platform_phases(platform)]
        assert "Emerge @system" in labels, platform
        assert "Emerge role payload" in labels, platform
        assert not any(lbl.startswith("Phase ") for lbl in labels), (
            f"{platform}: a pre-uniformity 'Phase N' label survives: {labels}")


# ── 2. it enables on the FIRST real emerge signal ──────────────────────────────────────
def test_enables_on_the_first_emerge_group_banner_x86(wiz):
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE + [_X86_EMERGE_BANNER])
    assert row.pkg_btn.isEnabled() is False        # the STAGE banner alone is not emerging
    page._on_line(0, _X86_GROUP_BANNER)            # the builder announces the emerge group
    assert row.pkg_expandable is True
    assert row.pkg_btn.isEnabled() is True
    assert row.pkg_btn.toolTip() == progress_mod._PKG_EXPAND_READY_HINT


def test_enables_on_the_first_emerge_group_banner_arm(wiz):
    """The same signal on an ARM platform, whose stage is named "Phase 1: @system"."""
    page = _fresh_page(wiz, rows=(("acme-rpi5", "rpi5"),))
    row = page._rows[0]
    _feed(page, 0, _ARM_PRE_EMERGE + [_ARM_EMERGE_BANNER])
    assert row.pkg_btn.isEnabled() is False
    page._on_line(0, _ARM_GROUP_BANNER)
    assert row.pkg_expandable is True
    assert row.pkg_btn.isEnabled() is True
    # and the packages really do arrive right behind it — the enable was not premature
    page._on_line(0, f">>> Emerging (1 of 149) dev-libs/xxhash-0.8.3-r2::gentoo "
                     f"for {_ARM_ROOT}")
    assert "dev-libs/xxhash-0.8.3-r2" in row.pkg_items


def test_enables_on_the_first_package_row_when_no_group_banner_was_printed(wiz):
    """GROUP_UNKNOWN: a package portage names before any `==> Emerge group:` banner still
    proves this job is emerging (the tree files it under "ungrouped")."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE + [_X86_EMERGE_BANNER])
    assert row.pkg_btn.isEnabled() is False
    page._on_line(0, ">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    assert row.pkg_expandable is True and row.pkg_btn.isEnabled() is True
    assert "" in row.group_items                   # honestly ungrouped, and still enabled


def test_enables_on_portages_own_scheduler_line(wiz):
    """Under --jobs portage may talk before it names an atom: its ">>> Jobs:" line is
    emerge running, so the control goes live on it too."""
    page = _fresh_page(wiz, rows=(("acme-rpi5", "rpi5"),))
    row = page._rows[0]
    _feed(page, 0, _ARM_PRE_EMERGE + [_ARM_EMERGE_BANNER])
    assert row.pkg_btn.isEnabled() is False
    page._on_line(0, _jobs(0, 149, running=3))
    assert row.pkg_parser.scheduler().seen is True
    assert row.pkg_expandable is True and row.pkg_btn.isEnabled() is True


# ── 3. per job, never global ───────────────────────────────────────────────────────────
def test_two_jobs_in_different_phases_have_independent_affordances(wiz):
    """A multi-image worklist: image 0 emerging, image 1 still fetching its seed."""
    page = _fresh_page(wiz, rows=(("acme-x86", "x86"), ("acme-rpi5", "rpi5")))
    emerging, fetching = page._rows[0], page._rows[1]
    _feed(page, 1, _ARM_PRE_EMERGE)                      # job 1: seed work only
    _feed(page, 0, _X86_PRE_EMERGE + [_X86_EMERGE_BANNER, _X86_GROUP_BANNER])
    assert emerging.pkg_btn.isEnabled() is True
    assert fetching.pkg_btn.isEnabled() is False
    assert fetching.pkg_btn.toolTip() == progress_mod._PKG_EXPAND_HINT
    # job 1 keeps being driven WHILE job 0 emerges — through BOTH paths (its own lines and
    # the shared 1s tick). Neither may leak job 0's state onto it: this is what a
    # gate that asked "is ANY row emerging?" would get wrong.
    emerging.job_t_start = fetching.job_t_start = time.monotonic()
    page._on_line(1, _banner("Installing spec files"))
    page._on_tick()
    assert fetching.pkg_expandable is False
    assert fetching.pkg_btn.isEnabled() is False
    assert fetching.pkg_btn.toolTip() == progress_mod._PKG_EXPAND_HINT
    # and job 1 goes live on its OWN signal, without touching job 0
    _feed(page, 1, [_ARM_EMERGE_BANNER, _ARM_GROUP_BANNER])
    assert fetching.pkg_btn.isEnabled() is True and emerging.pkg_btn.isEnabled() is True


# ── 4. it never regresses ──────────────────────────────────────────────────────────────
def test_stays_enabled_after_the_emerge_phase_completes(wiz):
    """A finished build keeps its packages browsable — later stages and the terminal
    settle must not re-grey a control the operator already saw go live."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE + [
        _X86_EMERGE_BANNER, _X86_GROUP_BANNER,
        ">>> Emerging (1 of 1) dev-lang/duktape-2.7.0-r3::gentoo",
        ">>> Installing (1 of 1) dev-lang/duktape-2.7.0-r3::gentoo",
        ">>> Completed (1 of 1) dev-lang/duktape-2.7.0-r3::gentoo",
        _banner("Cleaning sysroot"),                 # well past emerge now
        _banner("Packaging stage4 tarball"),
    ])
    assert row.pkg_btn.isEnabled() is True
    page._on_entry_done(0, 0)                        # exit 0 -> ok -> job settles
    assert row.terminal is True
    assert row.pkg_expandable is True and row.pkg_btn.isEnabled() is True
    assert row.pkg_btn.toolTip() == progress_mod._PKG_EXPAND_READY_HINT
    # _on_entry_done collapses a settled job; the control lives on the JOB row, so it is
    # still there and still live
    assert page.tree.itemWidget(row.job_item, progress_mod._COL_FLAGS) is row.pkg_btn


def test_collapse_and_re_expand_do_not_regress_the_affordance(wiz):
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE + [_X86_EMERGE_BANNER, _X86_GROUP_BANNER,
                                      ">>> Emerging (1 of 2) sys-libs/zlib-1.3.1-r1::gentoo"])
    assert row.pkg_btn.isEnabled() is True
    page.tree.collapseItem(row.job_item)
    assert row.pkg_btn.isEnabled() is True
    page.tree.expandItem(row.job_item)
    row.job_t_start = time.monotonic()                # what _on_tick walks a row for
    page._on_tick()                                   # the other drive path, 1 Hz
    assert row.pkg_expandable is True and row.pkg_btn.isEnabled() is True


def test_the_1s_tick_drives_the_gate_too_not_only_the_line_path(wiz):
    """Both call sites are real. Feeding the PARSER directly (bypassing _on_line) leaves
    the affordance to the tick — the one clock that still runs when the stream has gone
    quiet inside a long compile."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE + [_X86_EMERGE_BANNER])
    row.job_t_start = time.monotonic()
    assert row.pkg_btn.isEnabled() is False
    row.pkg_parser.feed(_X86_GROUP_BANNER)            # parser only: no _on_line, no repaint
    assert row.pkg_btn.isEnabled() is False
    page._on_tick()
    assert row.pkg_expandable is True and row.pkg_btn.isEnabled() is True


# ── 5. what the control actually does ──────────────────────────────────────────────────
def test_the_enabled_affordance_opens_the_package_groups(wiz):
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE + [
        _X86_EMERGE_BANNER, _X86_GROUP_BANNER,
        ">>> Emerging (1 of 2) sys-libs/zlib-1.3.1-r1::gentoo"])
    gitem = row.group_items["image"]
    page.tree.collapseItem(gitem)
    page.tree.collapseItem(row.job_item)
    row.pkg_btn.click()                               # the real Qt click path
    assert row.job_item.isExpanded() is True
    assert gitem.parent().isExpanded() is True        # the stage hosting the group
    assert gitem.isExpanded() is True                 # the group itself
    assert row.pkg_items["sys-libs/zlib-1.3.1-r1"].parent() is gitem


def test_a_disabled_affordance_is_inert_even_when_driven_programmatically(wiz):
    """The disabled button cannot emit clicked; the slot refuses anyway (belt and braces),
    so nothing expands and nothing raises."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE)
    page.tree.collapseItem(row.job_item)
    row.pkg_btn.click()                               # a real click on a disabled button
    page._expand_packages(0)                          # and the slot called directly
    assert row.job_item.isExpanded() is False
    assert row.pkg_expandable is False
    page._expand_packages(99)                         # out of range: no IndexError
    page._expand_packages(-1)


# ── 6. it cannot abort the operator's PyQt6 Studio ─────────────────────────────────────
def test_a_fault_in_the_enable_check_cannot_escape_the_line_slot(wiz):
    """_on_line and _on_tick are Qt slots; on PyQt6 an unhandled exception there calls
    qFatal and ABORTS the app mid-build. A broken parser degrades the affordance, nothing
    more — and the line still reaches the log."""
    page = _fresh_page(wiz)
    row = page._rows[0]
    row.job_t_start = time.monotonic()                # so _on_tick really walks this row

    def _boom(_row):
        raise RuntimeError("wrapped C/C++ object has been deleted")

    page._emerge_started = _boom                      # the gate's own read, blown up
    page._on_line(0, _X86_PRE_EMERGE[0])              # must not raise
    page._on_tick()                                   # nor from the tick path
    assert row.pkg_expandable is False                # honest: still greyed
    del page._emerge_started
    # not latched off — the very next line re-evaluates and can still enable it
    page._on_line(0, _X86_EMERGE_BANNER)
    page._on_line(0, _X86_GROUP_BANNER)
    assert row.pkg_expandable is True and row.pkg_btn.isEnabled() is True


def test_a_fault_in_the_expand_slot_is_reported_not_raised(wiz):
    page = _fresh_page(wiz)
    row = page._rows[0]
    _feed(page, 0, _X86_PRE_EMERGE + [_X86_EMERGE_BANNER, _X86_GROUP_BANNER])

    def _boom(_item):
        raise RuntimeError("expandItem failed")

    page.tree.expandItem = _boom
    page._expand_packages(0)                          # must not raise
    assert "could not open the package list" in page.log.toPlainText()


# ── 7. the hint text itself ────────────────────────────────────────────────────────────
def test_the_hint_texts_exist_and_are_short_and_honest(wiz):
    assert progress_mod._PKG_EXPAND_HINT == (
        "packages appear once the build reaches the emerge phase")
    assert len(progress_mod._PKG_EXPAND_HINT) < 80
    assert "Packages" in progress_mod._PKG_EXPAND_TEXT
    assert "packages" in progress_mod._PKG_EXPAND_READY_HINT.lower()
