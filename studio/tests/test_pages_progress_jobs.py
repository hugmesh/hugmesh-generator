"""ProgressPage under PARALLEL emerge (``--jobs``) — several package rows LIVE at once, and
portage's own scheduler aggregate on the group header.

Same harness as test_pages_progress_packages.py (offscreen Qt, the real page's real slots).
The lines fed below are the shapes of the operator's real parallel transcript
``out/sessions/20260729-065121-ce11e0/build-pki.rpi5.log`` — a 304-line verbatim excerpt of
it is committed as ``data/emerge_jobs_rpi5_excerpt.log`` and the parser-side tests assert
against that; here the concern is the GUI face:

* the group node carries "<done> of <total> done  ·  <R> running" once portage has spoken,
  and is textually UNCHANGED on a serial build (no Jobs line -> no suffix);
* three concurrent package rows each show their own step glyph, their own determinate bar
  and their own tool line, advancing TOGETHER off the existing 1s tick;
* the repaint stays fingerprint-gated — 1752 of a real build's 22,025 lines are repeated
  scheduler lines and none of them may cost a widget write;
* a fault on the poll path cannot escape the tick slot. That last one is not hypothetical
  housekeeping: the operator runs PyQt6, where an unhandled exception in a Qt slot calls
  qFatal and ABORTS the process.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import emerge_packages as ep                   # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402
from hugmesh_studio.gui.pages import progress as progress_mod           # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=True, builder_image="hugmesh-builder")

_CYAN, _BOLD, _RST = "\x1b[36m", "\x1b[1m", "\x1b[0m"
_GREEN_SGR, _RESET_SGR = "\x1b[32m", "\x1b[39;49;00m"

# the real ROOT a cross build merges into (build-pki.rpi5.log, L137)
_ROOT = "/out/wl-pki.rpi5/sysroot/"


def _banner(text: str) -> str:
    return f"{_CYAN}{_BOLD}==> {text}{_RST}"


def _elog(text: str) -> str:
    return f"{_GREEN_SGR} * {_RESET_SGR}{text}"


def _jobs(done, total, running=0, merge_wait=0):
    """A ">>> Jobs:" line with portage's right-alignment run, exactly as the real
    transcript prints it (L142/L146/L148)."""
    clauses = ""
    if running:
        clauses += f", {running} running"
    if merge_wait:
        clauses += f", {merge_wait} merge wait"
    head = f">>> Jobs: {done} of {total} complete{clauses}"
    return f"{head}{' ' * max(1, 72 - len(head))}Load avg: 6.71, 6.83, 5.95"


def _emerging(n, total, atom):
    return f">>> Emerging ({n} of {total}) {atom}::gentoo for {_ROOT}"


def _completed(n, total, atom):
    return f">>> Completed ({n} of {total}) {atom}::gentoo to {_ROOT}"


_HEADER = "\n".join([
    _elog("Package:    net-libs/nghttp2-1.68.0:0/1.14"),
    _elog("Repository: gentoo"),
    _elog("USE:        abi_x86_64 amd64 elibc_glibc kernel_linux"),
]) + "\n"

ATOMS = ["dev-libs/pkg1-1.0", "dev-libs/pkg2-2.0", "dev-libs/pkg3-3.0"]


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def _isolated_state_dir(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(autouse=True)
def _poll_every_call(monkeypatch):
    """poll()'s rate limit exists for the 1 Hz GUI tick; a test drives several ticks in the
    same microsecond, so the interval is opened up rather than the clock faked."""
    monkeypatch.setattr(ep, "POLL_MIN_INTERVAL", 0.0)


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


def _fresh_row(wiz, platform="x86", log_root=""):
    page = wiz.page(wiz._page_ids["progress"])
    page._reset()
    page._build_row(0, f"acme-{platform}", platform, log_root=log_root)
    return page


def _open_parallel(wiz, log_root, n=3):
    """A page whose row has THREE packages concurrently in flight, opened exactly the way a
    cross builder's parallel emerge opens them (group banner, scheduler line, then the
    ROOT-targeted Emerging lines)."""
    page = _fresh_row(wiz, log_root=log_root)
    row = page._rows[0]
    row.job_t_start = 0.0          # what _on_entry_start sets; the tick needs it
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: system"))
    page._on_line(0, _jobs(0, n, running=n))
    for i, atom in enumerate(ATOMS[:n], start=1):
        page._on_line(0, _emerging(i, n, atom))
    return page, row


def _write(root, atom, body):
    cat, pf = atom.split("/", 1)
    (root / f"{cat}:{pf}:20260730-043807.log").write_text(body, encoding="utf-8")


def _append(root, atom, body):
    cat, pf = atom.split("/", 1)
    with open(root / f"{cat}:{pf}:20260730-043807.log", "a", encoding="utf-8") as fh:
        fh.write(body)


# ── the scheduler aggregate on the group header ────────────────────────────────────────
def test_group_header_shows_portages_parallel_aggregate(wiz, tmp_path):
    root = tmp_path / "build"
    root.mkdir()
    page, row = _open_parallel(wiz, str(root))
    cell = row.group_items["system"].text(progress_mod._COL_PROGRESS)
    assert cell == "0 of 3 done  ·  3 running"
    # merge wait is reported too — it is a distinct real state (283 lines of the rpi5 log)
    page._on_line(0, _jobs(1, 3, merge_wait=1))
    assert row.group_items["system"].text(progress_mod._COL_PROGRESS) == \
        "0 of 3 done  ·  1 merge wait"


def test_serial_group_header_text_is_unchanged(wiz):
    """No ">>> Jobs:" line means no suffix — the serial x86 path's cell is the same string
    it has always been."""
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: system"))
    page._on_line(0, ">>> Emerging (1 of 3) dev-libs/pkg1-1.0::gentoo")
    page._on_line(0, ">>> Completed (1 of 3) dev-libs/pkg1-1.0::gentoo")
    cell = row.group_items["system"].text(progress_mod._COL_PROGRESS)
    assert cell == "1 of 3 done"
    assert "·" not in cell


def test_repeated_identical_scheduler_lines_cost_no_repaint(wiz, tmp_path):
    """1752 of the real build's 22,025 lines are these, most of them byte-identical
    repeats. The revision compare is what keeps them free."""
    root = tmp_path / "build"
    root.mkdir()
    page, row = _open_parallel(wiz, str(root))
    rev = row.sched_rev
    for _ in range(200):
        page._on_line(0, _jobs(0, 3, running=3))
    assert row.sched_rev == rev


def test_a_scheduler_line_before_any_package_is_painted_when_the_group_appears(wiz):
    """The aggregate can arrive before the first Emerging line. The figures are real, they
    just have nowhere to go yet — so the revision is NOT consumed and the next repaint
    picks them up rather than dropping them."""
    page = _fresh_row(wiz)
    row = page._rows[0]
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: system"))
    page._on_line(0, _jobs(0, 4, running=4))
    assert row.group_items == {}
    page._on_line(0, _emerging(1, 4, ATOMS[0]))
    assert "4 running" in row.group_items["system"].text(progress_mod._COL_PROGRESS)


def test_parallel_detection_opens_the_group_once(wiz, tmp_path):
    """Under --jobs the whole point is that several rows are live at once, so the tree opens
    itself when the parser proves parallelism — once, so it never fights an operator who
    collapses it again."""
    root = tmp_path / "build"
    root.mkdir()
    page, row = _open_parallel(wiz, str(root))
    gitem = row.group_items["system"]
    assert row.pkg_parallel_shown is True
    assert gitem.isExpanded()
    page.tree.collapseItem(gitem)
    page._on_line(0, _jobs(1, 3, running=2))
    assert not gitem.isExpanded()          # not re-opened behind the operator's back


# ── THE feature: several rows live at the same time ────────────────────────────────────
def test_three_concurrent_rows_advance_together_on_the_existing_tick(wiz, tmp_path):
    root = tmp_path / "build"
    root.mkdir()
    page, row = _open_parallel(wiz, str(root))
    # three rows, three bars, all honestly at zero — the stream carries nothing about them
    assert list(row.pkg_items) == ATOMS
    assert len(row.pkg_bars) == 3
    assert [row.pkg_bars[a].value() for a in ATOMS] == [0, 0, 0]

    # portage creates each package's own log and starts writing DIFFERENT phases into them
    _write(root, ATOMS[0], _HEADER + ">>> Unpacking source...\n"
                                     ">>> Configuring source in /var/tmp/portage/w ...\n"
                                     "checking for a BSD-compatible install... /usr/bin/install\n")
    _write(root, ATOMS[1], _HEADER + ">>> Unpacking source...\n"
                                     ">>> Source prepared.\n")
    _write(root, ATOMS[2], _HEADER + ">>> Unpacking source...\n"
                                     ">>> Compiling source in /var/tmp/portage/w ...\n"
                                     "[120/240] cc -o foo.o foo.c\n")

    page._on_tick()                        # the EXISTING elapsed-time tick, nothing new

    # all three bars moved, to three DIFFERENT live values, in one tick
    values = [row.pkg_bars[a].value() for a in ATOMS]
    assert values == [10, 5, 47], values
    assert len(set(values)) == 3
    # each row's own step glyph and its own tool line
    steps = [row.pkg_progress[a].step for a in ATOMS]
    assert steps == [ep.STEP_CONFIGURE, ep.STEP_PREPARE, ep.STEP_COMPILE]
    assert row.pkg_tools[ATOMS[0]].text().startswith("configure: checking")
    assert "[120/240]" in row.pkg_tools[ATOMS[2]].text()
    assert row.pkg_tools[ATOMS[1]].text() == ""
    # …and the Flags column filled itself from each package's own elog header
    assert row.pkg_items[ATOMS[0]].text(progress_mod._COL_FLAGS) == \
        "abi_x86_64 amd64 elibc_glibc kernel_linux"

    # a second tick moves only the log that grew
    _append(root, ATOMS[1], ">>> Compiling source in /var/tmp/portage/w ...\n")
    page._on_tick()
    assert [row.pkg_bars[a].value() for a in ATOMS] == [10, 15, 47]


def test_a_concurrent_row_is_settled_only_by_the_stream(wiz, tmp_path):
    """">>> Done." in a package's own log is the end of the EBUILD, not of the merge — so a
    polled row tops out at install/85 and only the stream's "Completed (N of M)" fills the
    bar. The other two rows stay visibly unsettled, which is the honest state."""
    root = tmp_path / "build"
    root.mkdir()
    page, row = _open_parallel(wiz, str(root))
    _write(root, ATOMS[0], _HEADER + "\n".join([
        ">>> Unpacking source...", ">>> Compiling source in /w ...", ">>> Source compiled.",
        ">>> Install dev-libs/pkg1-1.0 into /var/tmp/portage/.../image",
        ">>> Completed installing dev-libs/pkg1-1.0 into /var/tmp/portage/.../image",
        ">>> Done.",
    ]) + "\n")
    page._on_tick()
    assert row.pkg_bars[ATOMS[0]].value() == 85
    assert row.pkg_progress[ATOMS[0]].step == ep.STEP_INSTALL

    page._on_line(0, _completed(1, 3, ATOMS[0]))
    assert row.pkg_bars[ATOMS[0]].value() == 100
    assert row.pkg_progress[ATOMS[0]].step == ep.STEP_DONE
    assert [row.pkg_bars[a].value() for a in ATOMS[1:]] == [0, 0]
    assert row.group_items["system"].text(progress_mod._COL_PROGRESS).startswith("1 of 3 done")


def test_a_serial_row_is_not_polled_at_all(wiz, tmp_path):
    """The proven serial path must be untouched: with one package in flight and no evidence
    of --jobs, the tick reads nothing from disk even though the log is sitting there."""
    root = tmp_path / "build"
    root.mkdir()
    page = _fresh_row(wiz, log_root=str(root))
    row = page._rows[0]
    row.job_t_start = 0.0
    page._on_line(0, _banner("Native emerge inside chroot"))
    page._on_line(0, _banner("Emerge group: system"))
    page._on_line(0, ">>> Emerging (1 of 3) dev-libs/pkg1-1.0::gentoo")
    _write(root, ATOMS[0], _HEADER + ">>> Compiling source in /w ...\n")
    page._on_tick()
    assert row.pkg_bars[ATOMS[0]].value() == 0
    assert row.pkg_progress[ATOMS[0]].step == ep.STEP_QUEUED


# ── the tick slot must not be able to kill the app ─────────────────────────────────────
def test_a_fault_in_the_poll_path_cannot_escape_the_tick_slot(wiz, tmp_path, monkeypatch):
    """The operator runs PyQt6, where an unhandled exception in a Qt slot calls qFatal and
    ABORTS the process — so a fault while reading inside the build's chroot must degrade the
    live view, never end the build session. Reported once, then latched off."""
    root = tmp_path / "build"
    root.mkdir()
    page, row = _open_parallel(wiz, str(root))

    def boom(now=None):
        raise RuntimeError("sysroot went away mid-poll")

    monkeypatch.setattr(row.pkg_parser, "poll", boom)
    page._on_tick()                                    # must not raise
    assert row.pkg_poll_off is True
    text = page.log.toPlainText()
    assert "live per-package log follow disabled" in text
    assert "sysroot went away mid-poll" in text
    page._on_tick()
    page._on_tick()
    assert page.log.toPlainText().count("live per-package log follow disabled") == 1
    # and the rest of the tick still did its job
    assert row.job_item.text(progress_mod._COL_TIME) != ""


def test_the_tick_keeps_running_the_elapsed_repaint_when_polling_is_off(wiz, tmp_path):
    """The latch is scoped to the package follow — job/stage elapsed time must keep
    ticking, because that is how the operator knows the build is alive at all."""
    root = tmp_path / "build"
    root.mkdir()
    page, row = _open_parallel(wiz, str(root))
    row.pkg_poll_off = True
    page._on_tick()
    assert row.job_item.text(progress_mod._COL_TIME) != ""
    assert row.stage_items[row.tracker.cur].text(progress_mod._COL_TIME) != ""
