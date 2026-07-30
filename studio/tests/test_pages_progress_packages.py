"""ProgressPage per-PACKAGE tree — JOB -> STAGE -> GROUP -> PACKAGE.

Drives the REAL page's slots (offscreen Qt, same harness as test_pages_progress.py) with
lines copied from the real transcript of session ``20260725-140638-09692d``
(``build-standalone-unaffiliated.x86.log``, 3.16M lines — the same evidence base as
test_emerge_packages.py, cited by line number at each use) and asserts the GUI face the
operator asked for: every package listed under its emerge group with a live QProgressBar,
a Flags column read from the package's own portage log, build-tool telemetry compact in
the row + full in the tooltip, and click-to-open of the package's emerge log — honestly,
including the not-yet-written case.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import Domain, ImageConfig, User    # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo              # noqa: E402
from hugmesh_studio.core import worklist_driver as wd               # noqa: E402
from hugmesh_studio.core.progress_parse import platforms            # noqa: E402
from hugmesh_studio.core.worklist import (                         # noqa: E402
    WorklistConfig, WorklistEntry, synthesize)
from hugmesh_studio.gui import wizard as wizard_mod                 # noqa: E402
from hugmesh_studio.gui.qt import Qt, QtWidgets                     # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod      # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

_RED = "#c5221f"
_GREEN = "#188038"
_BLUE = "#1a73e8"

# SGR wrappers exactly as the builders / portage emit them (same constants as
# test_emerge_packages.py, verified byte-for-byte there with od -c).
_GREEN_SGR, _RESET_SGR = "\x1b[32m", "\x1b[39;49;00m"
_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"


def _banner(text: str) -> str:
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


def _elog(text: str) -> str:
    return f"{_GREEN_SGR} * {_RESET_SGR}{text}"


# The real freetype elog header, reproduced verbatim (321 bytes on disk —
# media-libs:freetype-2.14.3:20260725-211000.log of the reference session).
_FREETYPE_LOG = "\n".join([
    _elog("Package:    media-libs/freetype-2.14.3:2"),
    _elog("Repository: gentoo"),
    _elog("Maintainer: fonts@gentoo.org"),
    _elog("USE:        X abi_x86_64 adobe-cff amd64 bzip2 cleartype-hinting elibc_glibc "
          "harfbuzz kernel_linux png"),
    _elog("FEATURES:   nostrip preserve-libs"),
]) + "\n"


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


def _fresh_row(wiz, platform="x86", log_root=""):
    """A page with ONE direct-slot row, advanced into the platform's emerge stage."""
    page = _progress_page(wiz)
    page._reset()
    page._build_row(0, f"acme-{platform}", platform, log_root=log_root)
    return page


def _run_to_completion(qapp, page, timeout_ms=5000):
    if page.worker is not None:
        page.worker.wait(timeout_ms)
    for _ in range(500):
        qapp.processEvents()
        if page.isComplete():
            break


def _mesh_base(tmp_path):
    b = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                    brand_title="Acme", org="Acme-Inc", cluster_domain="acme.example",
                    superdomain="core.acme.internal", output_dir=str(tmp_path / "out"))
    b.domains = [Domain(name="acme.example", title="Acme")]
    b.users = [User(username="root-admin", domain="core.acme.internal", role="superadmin")]
    return b


def _install_replay_builddriver(monkeypatch, lines, code=0):
    class ReplayBuildDriver:
        def __init__(self, gen, host, graphical=False, workdir=None):
            self.workdir = workdir
            self.cancelled = False

        def run(self, cfg, backend, on_line=None):
            if on_line:
                for ln in lines:
                    on_line(ln)
            return code

        def cancel(self):
            self.cancelled = True

        def preflight(self, cfg, backend):
            return []

        def command_string(self, cfg, backend=None):
            return f"cmd:{cfg.role}"

    monkeypatch.setattr(wd, "BuildDriver", ReplayBuildDriver)


def _install_fake_genkeys(monkeypatch):
    class FakeProc:
        def __init__(self):
            self.stdout = iter(["generating keys"])

        def wait(self):
            return 0

    monkeypatch.setattr(wd.subprocess, "Popen", lambda cmd, **kw: FakeProc())


# a minimal real-shaped emerge run: the pinned group banner, then duktape's counter
# lines exactly as the transcript prints them (L17744 / L17792 / L17834).
_PKG_STREAM = [
    _banner("Native emerge inside chroot"),
    _banner("Emerge group: image"),
    ">>> Emerging (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo",
    ">>> Installing (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo",
    ">>> Completed (1 of 258) dev-lang/duktape-2.7.0-r3::gentoo",
]


# ── columns: symbolic renumber, Flags added ────────────────────────────────────────────
def test_flags_column_exists_and_constants_are_symbolic(wiz):
    """The Flags column sits between Progress and Time, and every index is a module
    constant — the existing tests' hardcoded text(1)/foreground(0) reads stay valid."""
    assert (progress_mod._COL_NAME, progress_mod._COL_PROGRESS,
            progress_mod._COL_FLAGS, progress_mod._COL_TIME) == (0, 1, 2, 3)
    page = _progress_page(wiz)
    assert page.tree.columnCount() == 4
    hdr = page.tree.headerItem()
    assert hdr.text(progress_mod._COL_PROGRESS) == "Progress"
    assert hdr.text(progress_mod._COL_FLAGS) == "Flags"
    assert hdr.text(progress_mod._COL_TIME) == "Time"


# ── the third level: packages under the emerge stage, grouped ──────────────────────────
def test_packages_nest_under_the_emerging_stage_grouped_by_group(wiz):
    page = _fresh_row(wiz)
    row = page._rows[0]
    for ln in _PKG_STREAM:
        page._on_line(0, ln)
    # the group node is a child of the stage that was RUNNING when the packages appeared.
    # Under the canonical ladder the "Native emerge inside chroot" banner is compat for
    # x86 stage 10 ("Emerge @system") and the "Emerge group: image" banner advances to
    # stage 11 ("Emerge role payload") — image is the role payload's group, so that is
    # the honest owner.
    assert row.tracker.cur == 11
    gitem = row.group_items["image"]
    assert gitem.parent() is row.stage_items[11]
    assert gitem.text(progress_mod._COL_NAME) == "image"
    # the package row is a child of the GROUP node, showing the full atom
    item = row.pkg_items["dev-lang/duktape-2.7.0-r3"]
    assert item.parent() is gitem
    assert "dev-lang/duktape-2.7.0-r3" in item.text(progress_mod._COL_NAME)
    # jobs still have exactly the phase-table stages as direct children (the group is a
    # level UNDER a stage, never a fabricated sixth stage)
    from hugmesh_studio.core.progress_parse import platform_phases
    assert row.job_item.childCount() == len(platform_phases("x86"))


def test_every_package_seen_is_listed_not_just_the_current_one(wiz):
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: image"))
    atoms = ["dev-lang/duktape-2.7.0-r3", "sys-libs/zlib-1.3.1-r1",
             "app-arch/xz-utils-5.6.4"]
    for n, atom in enumerate(atoms, start=1):
        page._on_line(0, f">>> Emerging ({n} of 3) {atom}::gentoo")
        page._on_line(0, f">>> Completed ({n} of 3) {atom}::gentoo")
    assert set(row.pkg_items) == set(atoms)
    assert row.group_items["image"].childCount() == 3
    # completed rows KEEP their state (general progress with all packages): all green ✓
    for atom in atoms:
        assert row.pkg_items[atom].foreground(0).color().name() == _GREEN
        assert row.pkg_bars[atom].value() == 100


def test_pre_banner_packages_are_ungrouped_never_filed_under_image(wiz):
    """The pinned parser contract: before the first `==> Emerge group:` banner the group
    is honestly unknown — the GUI must not invent an 'image' heading for it."""
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, ">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")  # L96
    assert "" in row.group_items and "image" not in row.group_items
    assert row.group_items[""].text(progress_mod._COL_NAME) == "ungrouped"


# ── the per-package bar: ladder-driven, embedded, monotonic ────────────────────────────
def test_package_bar_is_an_embedded_widget_driven_by_the_ladder(wiz):
    """The bar rides setItemWidget in the Progress column (the exact idiom of the job
    bars) and climbs the real ebuild ladder — gettext's own lines, transcript L322-16270
    — monotonically, reaching 100 only on the Completed line."""
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: system"))
    page._on_line(0, ">>> Emerging (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    atom = "sys-devel/gettext-0.22.5-r2"
    item = row.pkg_items[atom]
    cell = page.tree.itemWidget(item, progress_mod._COL_PROGRESS)
    assert cell is not None and row.pkg_bars[atom].parent() is cell
    seen = [row.pkg_bars[atom].value()]
    for ln in (">>> Unpacking source...",
               ">>> Preparing source in /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work",
               ">>> Configuring source in /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work",
               ">>> Compiling source in /var/tmp/portage/sys-devel/gettext-0.22.5-r2/work",
               ">>> Test phase [not enabled]: sys-devel/gettext-0.22.5-r2",
               ">>> Install sys-devel/gettext-0.22.5-r2 into /var/tmp/portage/...",
               ">>> Completed installing sys-devel/gettext-0.22.5-r2 into ..."):
        page._on_line(0, ln)
        seen.append(row.pkg_bars[atom].value())
    assert seen == sorted(seen), f"package bar regressed: {seen}"
    assert seen[-1] < 100, "100 must be reserved for the Completed counter line"
    assert row.pkg_items[atom].foreground(0).color().name() == _BLUE  # running
    page._on_line(0, ">>> Completed (1 of 1) sys-devel/gettext-0.22.5-r2::gentoo")
    assert row.pkg_bars[atom].value() == 100
    assert row.pkg_items[atom].foreground(0).color().name() == _GREEN


def test_ninja_counter_shows_compact_tool_info_and_refines_the_bar(wiz):
    """The operator's telemetry ask: the [N/M] ninja counter lands next to the bar
    (elided — a real ninja line is ~4 KB) and refines the compile percent exactly as the
    parser computes it (15 + (64*788)//1186 = 57, the inkscape live-proof value)."""
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: image"))
    page._on_line(0, ">>> Emerging (1 of 8) media-gfx/inkscape-1.4.3::gentoo")
    page._on_line(0, ">>> Compiling source in /var/tmp/portage/media-gfx/inkscape-1.4.3/work")
    long_tail = "x" * 200                      # stands in for the 4 KB g++ argv
    page._on_line(0, f"[788/1186] /usr/bin/x86_64-pc-linux-gnu-g++ {long_tail}")
    atom = "media-gfx/inkscape-1.4.3"
    assert row.pkg_bars[atom].value() == 57
    label = row.pkg_tools[atom]
    assert label.text().startswith("[788/1186]")
    assert len(label.text()) <= progress_mod._TOOL_CELL_CHARS
    assert label.text().endswith("…"), "a 200-char tool line must be elided in the cell"
    # the tooltip carries the header block + the tool line (longer elide)
    tip = row.pkg_items[atom].toolTip(progress_mod._COL_NAME)
    assert atom in tip and "tool: [788/1186]" in tip


# ── Flags column + header tooltip from the package's own portage log ───────────────────
def test_flags_column_and_tooltip_come_from_the_real_elog_header(wiz, tmp_path):
    log_root = tmp_path / "portage-build"
    log_root.mkdir()
    (log_root / "media-libs:freetype-2.14.3:20260725-211000.log").write_text(
        _FREETYPE_LOG, encoding="utf-8")
    page = _fresh_row(wiz, log_root=str(log_root))
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: dependencies"))
    page._on_line(0, ">>> Emerging (1 of 258) media-libs/freetype-2.14.3::gentoo")
    atom = "media-libs/freetype-2.14.3"
    item = row.pkg_items[atom]
    flags = item.text(progress_mod._COL_FLAGS)
    assert "adobe-cff" in flags and "harfbuzz" in flags
    assert "\x1b" not in flags                      # ANSI never reaches a painted cell
    assert item.toolTip(progress_mod._COL_FLAGS) == flags   # cell elides; tip is full
    tip = item.toolTip(progress_mod._COL_NAME)
    # the FULL header block, per the operator addition — every row portage wrote
    assert "Package: media-libs/freetype-2.14.3:2" in tip
    assert "Repository: gentoo" in tip
    assert "Maintainer: fonts@gentoo.org" in tip
    assert "FEATURES: nostrip preserve-libs" in tip


# ── click-to-log ───────────────────────────────────────────────────────────────────────
def test_clicking_a_package_opens_its_emerge_log_in_the_shared_pane(wiz, tmp_path):
    log_root = tmp_path / "portage-build"
    log_root.mkdir()
    log_file = log_root / "media-libs:freetype-2.14.3:20260725-211000.log"
    log_file.write_text(_FREETYPE_LOG + "checking for gcc... yes\n", encoding="utf-8")
    page = _fresh_row(wiz, log_root=str(log_root))
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: dependencies"))
    page._on_line(0, ">>> Emerging (1 of 258) media-libs/freetype-2.14.3::gentoo")
    atom = "media-libs/freetype-2.14.3"

    page._on_item_clicked(row.pkg_items[atom])
    text = page.log.toPlainText()
    assert "USE:        X abi_x86_64 adobe-cff" in text   # the file's own content
    assert "checking for gcc... yes" in text
    assert "\x1b" not in text                             # display-safe, no boxes
    assert atom in page.log_header.text()
    assert "dependencies" in page.log_header.text()
    # the watch-help names the PACKAGE's file — the real tail-follow idiom of this page
    assert str(log_file) in page.log_help.text()
    assert f"tail -F -n +1 {log_file}" in page.log_help.text()
    # while a package log is shown, arriving STREAM lines must not interleave into it
    page._on_line(0, "  some unrelated stream line")
    assert "some unrelated stream line" not in page.log.toPlainText()
    # clicking back to the JOB restores the stream view
    page._on_item_clicked(row.job_item)
    assert page._selected_pkg is None
    assert "some unrelated stream line" in page.log.toPlainText()


def test_clicking_a_package_with_no_log_yet_says_so_honestly(wiz, tmp_path):
    """A not-yet-written log must never render as an empty box that reads as an empty
    log — the pane says what is missing and where it will appear; the tick follow then
    loads the file the moment it exists."""
    log_root = tmp_path / "portage-build"
    log_root.mkdir()
    page = _fresh_row(wiz, log_root=str(log_root))
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: image"))
    page._on_line(0, ">>> Emerging (1 of 8) dev-lang/duktape-2.7.0-r3::gentoo")
    atom = "dev-lang/duktape-2.7.0-r3"

    page._on_item_clicked(row.pkg_items[atom])
    assert "No emerge log for dev-lang/duktape-2.7.0-r3 yet" in page.log.toPlainText()
    assert str(log_root) in page.log.toPlainText()        # says WHERE it will appear
    assert "(no log yet)" in page.log_header.text()

    # portage writes the file -> the 1s tick's follow loads it without another click
    (log_root / "dev-lang:duktape-2.7.0-r3:20260725-210000.log").write_text(
        _elog("Package:    dev-lang/duktape-2.7.0-r3:0") + "\n"
        + _elog("USE:        abi_x86_64 amd64") + "\n", encoding="utf-8")
    page._on_tick()
    assert "USE:        abi_x86_64 amd64" in page.log.toPlainText()
    assert "(no log yet)" not in page.log_header.text()


def test_clicking_a_group_header_falls_back_to_the_stage_slice(wiz):
    page = _fresh_row(wiz)
    row = page._rows[0]
    for ln in _PKG_STREAM:
        page._on_line(0, ln)
    page._on_item_clicked(row.group_items["image"])
    # the group has no log of its own; the pane shows the OWNING stage's slice
    # (stage 11, "Emerge role payload" — the canonical stage the image group belongs to)
    assert page._selected_pkg is None
    assert page._selected_stage == 11
    assert "Emerging" in page.log.toPlainText()


# ── failure ────────────────────────────────────────────────────────────────────────────
def test_failed_package_is_red_terminal_and_its_group_expands(wiz):
    """The real libreoffice failure block (transcript L2794910-12): the row goes red ✗,
    the bar freezes short of 100, and the group node expands so the culprit is visible."""
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: world"))
    page._on_line(0, ">>> Emerging (561 of 805) app-office/libreoffice-25.2.7.2-r1::gentoo")
    page._on_line(0, ">>> Failed to emerge app-office/libreoffice-25.2.7.2-r1, Log file:")
    page._on_line(0, "")
    page._on_line(0, ">>>  '/var/log/portage/build/app-office:libreoffice-25.2.7.2-r1:"
                     "20260726-024143.log'")
    atom = "app-office/libreoffice-25.2.7.2-r1"
    item = row.pkg_items[atom]
    assert item.foreground(0).color().name() == _RED
    assert "✗" in item.text(progress_mod._COL_NAME)
    assert row.pkg_bars[atom].value() < 100
    assert row.group_items["world"].isExpanded()


# ── group counters ─────────────────────────────────────────────────────────────────────
def test_group_node_shows_done_of_total_from_parser_totals(wiz):
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: system"))
    page._on_line(0, ">>> Emerging (1 of 3) sys-apps/baselayout-2.17::gentoo")
    page._on_line(0, ">>> Completed (1 of 3) sys-apps/baselayout-2.17::gentoo")
    page._on_line(0, ">>> Emerging (2 of 3) sys-devel/gettext-0.22.5-r2::gentoo")
    page._on_line(0, ">>> Completed (2 of 3) sys-devel/gettext-0.22.5-r2::gentoo")
    assert row.group_items["system"].text(progress_mod._COL_PROGRESS) == "2 of 3 done"


# ── performance: no wholesale rebuilds, items are stable ───────────────────────────────
def test_items_are_created_once_and_non_package_lines_touch_nothing(wiz):
    page = _fresh_row(wiz)
    row = page._rows[0]
    for ln in _PKG_STREAM:
        page._on_line(0, ln)
    atom = "dev-lang/duktape-2.7.0-r3"
    item_before = row.pkg_items[atom]
    bar_before = row.pkg_bars[atom]
    group_before = row.group_items["image"]
    # a flood of non-package compiler noise: no new items, no replaced widgets
    for k in range(500):
        page._on_line(0, f"  CC lib/foo_{k}.o")
    assert row.pkg_items[atom] is item_before
    assert row.pkg_bars[atom] is bar_before
    assert row.group_items["image"] is group_before
    assert group_before.childCount() == 1
    # and a further package line still lands on the SAME structures (no rebuild)
    page._on_line(0, ">>> Emerging (2 of 258) sys-libs/zlib-1.3.1-r1::gentoo")
    assert row.pkg_items[atom] is item_before
    assert group_before.childCount() == 2


# ── mesh AND standalone, every platform ────────────────────────────────────────────────
@pytest.mark.parametrize("platform", platforms())
def test_package_rows_appear_for_every_build_platform(wiz, platform):
    """No per-platform branch may exclude packages: the same slot path renders package
    rows for every platform table (mesh node platforms and client platforms share these
    builders).

    Updated for #474 (the builders' emerge-group banners): every platform's phase
    table now lists 'Emerge group: system' as a PATTERN of its @system-ish phase, so
    feeding that banner legitimately ADVANCES the stage tracker — the group therefore
    nests under the stage that banner just opened, which is the intended design
    ("the group under whichever stage was running when its packages appeared"). The
    original pre-#474 expectation (group under the JOB because no stage had been
    crossed) asserted a premise the merged tables made unreachable for real builder
    output; the job-fallback path itself is still covered by
    test_group_seen_before_any_stage_nests_under_the_job, which uses a group banner
    deliberately ABSENT from every phase table."""
    page = _fresh_row(wiz, platform=platform)
    row = page._rows[0]
    page._on_line(0, _banner("Emerge group: system"))
    page._on_line(0, ">>> Emerging (1 of 2) sys-devel/gettext-0.22.5-r2::gentoo")
    atom = "sys-devel/gettext-0.22.5-r2"
    assert atom in row.pkg_items, f"platform {platform} lost its package rows"
    gitem = row.group_items["system"]
    tracker_idx = row.tracker.cur
    assert tracker_idx >= 0, (
        f"platform {platform}: the system group banner is a phase pattern since #474 "
        f"and must advance the stage tracker")
    assert gitem.parent() is row.stage_items[tracker_idx], (
        f"platform {platform}: the group must nest under the stage its banner opened")


def test_group_seen_before_any_stage_nests_under_the_job(wiz):
    """The honest job-level fallback the parametrized test used to pin: a group whose
    banner matches NO phase pattern (here: 'dependencies', which only x86 tables — and
    only a LATER phase — carry) arriving before any stage banner nests under the JOB
    itself, never nowhere. Uses rpi5, whose tables carry no 'dependencies' pattern at
    all, so the premise cannot rot the way the 'system' one did."""
    page = _fresh_row(wiz, platform="rpi5")
    row = page._rows[0]
    page._on_line(0, _banner("Emerge group: dependencies"))
    page._on_line(0, ">>> Emerging (1 of 2) sys-devel/gettext-0.22.5-r2::gentoo")
    assert "sys-devel/gettext-0.22.5-r2" in row.pkg_items
    assert row.tracker.cur < 0, "premise broken: rpi5 now has a dependencies pattern"
    assert row.group_items["dependencies"].parent() is row.job_item


def test_mesh_worklist_gets_package_rows_and_wired_log_roots(monkeypatch, qapp, wiz,
                                                             tmp_path):
    """End-to-end through the real worker/dispatch path for a MESH worklist (node roles
    on two platforms): every job row gets package rows, and log_root is wired to the
    entry's own wl-<id>/sysroot/var/log/portage/build — the exact layout verified on the
    real session 20260725-140638-09692d."""
    _install_replay_builddriver(monkeypatch, _PKG_STREAM, code=0)
    _install_fake_genkeys(monkeypatch)
    wl = WorklistConfig(base=_mesh_base(tmp_path),
                        entries=[WorklistEntry(role="pki", platform="x86"),
                                 WorklistEntry(role="be", platform="rpi5")])
    wiz.worklist = wl
    wiz.build_backend = None
    wiz.generate_node_keys = True
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.isComplete()
    for i, eid in enumerate(("pki.x86", "be.rpi5")):
        row = page._rows[i]
        assert row.log_root == os.path.join(
            page._session.workdir, f"wl-{eid}", "sysroot", "var", "log",
            "portage", "build")
        assert "dev-lang/duktape-2.7.0-r3" in row.pkg_items, f"{eid} lost its packages"


def test_standalone_build_gets_package_rows_too(monkeypatch, qapp, wiz, tmp_path):
    """Same end-to-end proof for a STANDALONE (client) image — the other half of 'all
    images in mesh and standalone builds'."""
    _install_replay_builddriver(monkeypatch, _PKG_STREAM, code=0)
    cfg = ImageConfig(mode="standalone", role="standalone-thick", platform="x86",
                      brand="acme", output_dir=str(tmp_path / "out"))
    wiz.worklist = synthesize(cfg)
    wiz.build_backend = None
    wiz.generate_node_keys = True
    page = _progress_page(wiz)
    page.initializePage()
    _run_to_completion(qapp, page)
    assert page.isComplete()
    row = page._rows[0]
    assert "dev-lang/duktape-2.7.0-r3" in row.pkg_items
    assert row.pkg_bars["dev-lang/duktape-2.7.0-r3"].value() == 100
    assert row.log_root.endswith(os.path.join(
        "wl-standalone-thick.x86", "sysroot", "var", "log", "portage", "build"))
