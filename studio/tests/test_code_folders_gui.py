"""The Code folders block of the local-mesh Repo source step, driven headless
through the REAL wizard with a fake opener (issue #689).

Pinned here:

* the block sits on the Repo source step in the stepped flow AND on the single
  page of LocalMeshDialog — one widget, two frames;
* every Open folder button hands EXACTLY its row's folder to the opener; a row whose
  folder is missing is a disabled button that names the reason beside it and in its
  tooltip; Open all opens every existing folder of that domain once; Open source
  root opens the root;
* an open nothing could confirm, or that failed, is reported INLINE with the path
  in a copyable field — no dialog anywhere in the block (a source scan);
* GEOMETRY at the wizard's smallest supported window (736x736) and a normal one:
  every button is drawn inside the block, tall enough to click, none overlap, and a
  long domain name or path elides instead of pushing a button out. #647 is why
  this is a test and not a reading of the layout code.
"""
import os
import shutil

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import code_folders as cf                      # noqa: E402
from hugmesh_studio.core.open_path import OpenResult                    # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.pages import _code_folders_widget as cfw        # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm                    # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtGui, QtWidgets              # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")

SMALLEST = (736, 736)          # gui.wizard.medium_size on an 800x800 screen
NORMAL = (1040, 706)           # a 768p laptop
PRESENT = ("hugmesh-gateway", "hugmesh-admin-ui", "hugmesh-owncast-ui",
           "hugmesh-forum-api")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-code-folders-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


@pytest.fixture
def src_tree(tmp_path):
    """An 'existing' source tree holding SOME of the checkouts."""
    src = tmp_path / "mine"
    for name in PRESENT:
        (src / name).mkdir(parents=True)
    return str(src)


@pytest.fixture
def fake_gen(tmp_path):
    """A generator checkout with the REAL compose files and no .stack-src: what a
    fresh clone-mode flow sees before anything was downloaded."""
    g = tmp_path / "gen"
    stack = g / "tests" / "stack"
    stack.mkdir(parents=True)
    real = os.path.join(GENERATOR_DIR, "tests", "stack")
    for name in os.listdir(real):
        if name.startswith("compose") and name.endswith(".yaml"):
            shutil.copy(os.path.join(real, name), stack / name)
    return str(g)


class FakeOpener:
    def __init__(self, outcome="verified"):
        self.outcome = outcome
        self.paths = []

    def __call__(self, path):
        self.paths.append(path)
        if self.outcome == "verified":
            return OpenResult(True, True, "fake exited 0", path)
        if self.outcome == "unverified":
            return OpenResult(True, False, "desktop fallback (QDesktopServices.openUrl)",
                              path, "the desktop reports the request was dispatched, "
                              "not that a file manager appeared; if nothing opened, "
                              "copy the path.")
        return OpenResult(False, False, "none", path,
                          "no file manager took the request (xdg-open exited 2)")


def _to(wiz, cls, limit=14):
    for _ in range(limit):
        if isinstance(wiz.currentPage(), cls):
            return wiz.currentPage()
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(wiz.currentPage()).__name__}"
    raise AssertionError(f"never reached {cls.__name__}")


def _to_source(wiz, extra_domain="chat.example.org", ticks=("owncast", "phpbb"),
               source_dir=None):
    """Welcome -> Mode -> Generate -> Env -> Domains (+1 row) -> Domain services
    (tick ``ticks`` on the added row) -> the Repo source step."""
    wiz.next()
    mode = wiz.currentPage()
    mode._buttons["localmesh"].setChecked(True)
    mode._on_mode_toggled()
    wiz.next()
    wiz.currentPage()._buttons["generate"].setChecked(True)
    wiz.next()
    ctl = wiz.localmesh_page
    _to(wiz, lm.LocalMeshDomainsPage)
    if extra_domain:
        ctl.domains_table._add(extra_domain, "Added")
    _to(wiz, lm.LocalMeshDomainServicesPage)
    if extra_domain and ticks:
        ctl.domain_services._step(1)
        for slug in ticks:
            ctl.domain_services._boxes[slug].setChecked(True)
    page = _to(wiz, lm.LocalMeshSourcePage)
    if source_dir is not None:
        ctl.src_existing.setChecked(True)
        ctl.src_dir.setText(source_dir)
    QtWidgets.QApplication.processEvents()
    return ctl, page


def _settle(n=3):
    for _ in range(n):
        QtWidgets.QApplication.processEvents()


# ── where the block lives ───────────────────────────────────────────────────────
def test_the_block_sits_on_the_repo_source_step(wiz):
    ctl, page = _to_source(wiz)
    block = ctl.code_folders
    assert isinstance(block, cfw.CodeFoldersWidget)
    assert page.isAncestorOf(block), "the Repo source step must host it"
    assert block.isVisible()
    assert block.map is not None
    assert [d.name for d in block.map.domains] == [ctl.mesh_domains.own_name,
                                                   "chat.example.org"]


def test_the_single_page_frame_hosts_the_same_block_with_the_own_domain(qapp):
    dlg = lm.LocalMeshDialog(GENERATOR_DIR)
    try:
        block = dlg.page.code_folders
        assert dlg.page.isAncestorOf(block)
        assert block.map is not None
        # no Domains step ever seeded a row here: the mesh's own domain stands in
        assert [d.name for d in block.map.domains] == [dlg.page._own_domain_name()]
        assert len(block.map.domains[0].apps) >= 6
    finally:
        dlg.close()
        dlg.deleteLater()


# ── the buttons hand over the right folder ──────────────────────────────────────
def test_each_open_folder_button_hands_exactly_its_folder_to_the_opener(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    opener = FakeOpener()
    block.set_opener(opener)
    enabled = {k for k, b in block.open_buttons.items() if b.isEnabled()}
    own = ctl.mesh_domains.own_name
    # the own domain chose no owncast, so it has no owncast row (2026-10-21)
    assert enabled == {(own, "hugmesh-gateway"), (own, "hugmesh-admin-ui"),
                       ("chat.example.org", "hugmesh-gateway"),
                       ("chat.example.org", "hugmesh-admin-ui"),
                       ("chat.example.org", "hugmesh-owncast-ui"),
                       ("chat.example.org", "hugmesh-forum-api")}   # phpbb's context
    for key, btn in block.open_buttons.items():
        before = len(opener.paths)
        btn.click()
        if key in enabled:
            assert opener.paths[before:] == [block.rows[key].path], key
            assert opener.paths[-1] == os.path.join(src_tree, key[1])
        else:
            assert len(opener.paths) == before, f"a disabled row must open nothing: {key}"
    # a selected row says which selection put it there, a platform row does not
    chat_rows = {k[1]: b for k, b in block.open_buttons.items() if k[0] == "chat.example.org"}
    assert "owncast" in block.rows[("chat.example.org", "hugmesh-owncast-ui")].reasons[-1]
    assert chat_rows["hugmesh-forum-api"].isEnabled()
    assert ("hugmesh-forum-api" not in {k[1] for k in block.open_buttons if k[0] == own})


def test_a_missing_folder_row_is_disabled_and_names_its_reason(wiz, src_tree, fake_gen):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    own = ctl.mesh_domains.own_name
    btn = block.open_buttons[(own, "hugmesh-federation-api")]
    assert not btn.isEnabled()
    reason = f"no hugmesh-federation-api checkout in {src_tree}"
    assert btn.toolTip() == reason
    assert block.rows[(own, "hugmesh-federation-api")].missing_reason == reason
    labels = [w for w in block.findChildren(cfw.ElidedLabel) if w.full_text() == reason]
    assert labels and labels[0].isVisible(), "the reason must be drawn beside the button"
    # Qt never fires a disabled button's click, so the handler itself is the second
    # guard: called directly (as a reuser might), a missing row still opens nothing
    opener = FakeOpener()
    block.set_opener(opener)
    block._open_one(own, "hugmesh-federation-api",
                    block.rows[(own, "hugmesh-federation-api")].path)
    block._open_one(own, "no-such-row", src_tree)
    assert opener.paths == []
    assert not block.result_note.isVisible()
    # clone mode with nothing downloaded: every row says so, and so does the root
    block.generator_dir = fake_gen
    ctl.src_clone.setChecked(True)
    _settle()
    assert block.map.source_mode == "clone"
    assert block.map.root == os.path.join(fake_gen, ".stack-src")
    assert not block.open_root_btn.isEnabled()
    assert block.open_root_btn.toolTip() == cf.NOT_DOWNLOADED_REASON
    assert block.notice.text() == cf.CLONE_MODE_NOTICE
    assert block.open_buttons, "clone mode still lists every app"
    for key, b in block.open_buttons.items():
        assert not b.isEnabled(), key
        assert "not downloaded yet" in b.toolTip(), key


def test_a_finished_verb_re_reads_the_folders_it_just_created(qapp, fake_gen):
    """'Generate & start' runs make stack-clone, which creates the checkouts the
    block reported as 'not downloaded yet'. No form control changes when it does, so
    the verb's completion path itself must refresh the block (single-page frame:
    the buttons and the block share one page and nothing else re-reads the map)."""
    dlg = lm.LocalMeshDialog(fake_gen)
    try:
        page = dlg.page
        page._probe_mesh_state = lambda: None
        page._save_run_log = lambda run, ok: ""
        page._runs = []
        block = page.code_folders
        own = page._own_domain_name()
        btn = block.open_buttons[(own, "hugmesh-gateway")]
        assert not btn.isEnabled() and "not downloaded yet" in btn.toolTip()
        clone = os.path.join(fake_gen, ".stack-src", "hugmesh-gateway")
        os.makedirs(clone)
        page._verb_done(True)
        _settle()
        btn = block.open_buttons[(own, "hugmesh-gateway")]
        assert btn.isEnabled(), "the Studio cloned it; the button must follow"
        assert btn.toolTip() == clone
        assert block.rows[(own, "hugmesh-gateway")].exists
    finally:
        dlg.close()
        dlg.deleteLater()


def test_open_all_opens_every_existing_folder_of_that_domain_once(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    opener = FakeOpener()
    block.set_opener(opener)
    own = ctl.mesh_domains.own_name
    block.open_all_buttons["chat.example.org"].click()
    chat = next(d for d in block.map.domains if d.name == "chat.example.org")
    assert sorted(opener.paths) == sorted(chat.openable_paths())
    assert len(opener.paths) == len(set(opener.paths)) == 4
    assert os.path.join(src_tree, "hugmesh-forum-api") in opener.paths
    opener.paths.clear()
    block.open_all_buttons[own].click()
    assert len(opener.paths) == 2 and os.path.join(src_tree, "hugmesh-forum-api") \
        not in opener.paths
    assert os.path.join(src_tree, "hugmesh-owncast-ui") not in opener.paths
    assert block.result_note.isVisible()
    assert "Opened 2 folders" in block.result_note.text()


def test_open_all_is_disabled_when_no_folder_of_the_domain_exists(wiz, tmp_path):
    empty = tmp_path / "empty"
    empty.mkdir()
    ctl, _page = _to_source(wiz, source_dir=str(empty))
    block = ctl.code_folders
    for name, btn in block.open_all_buttons.items():
        assert not btn.isEnabled(), name
        assert "No folder of" in btn.toolTip()
    assert block.open_root_btn.isEnabled()          # the root itself IS there


def test_open_source_root_hands_the_root(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    opener = FakeOpener()
    block.set_opener(opener)
    block.open_root_btn.click()
    assert opener.paths == [src_tree]
    ctl.src_dir.setText("")
    _settle()
    assert not block.open_root_btn.isEnabled()
    assert block.open_root_btn.toolTip() == cf.NO_SOURCE_DIR_REASON
    assert block.root_path.full_text() == cf.NO_SOURCE_DIR_REASON


# ── the outcome is inline, never a dialog ───────────────────────────────────────
def test_a_verified_open_is_reported_green_without_the_copy_field(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    block.set_opener(FakeOpener("verified"))
    block.open_buttons[(ctl.mesh_domains.own_name, "hugmesh-gateway")].click()
    assert block.result_note.isVisible()
    assert block.result_note.text().startswith("Opened " + os.path.join(src_tree, "hugmesh-gateway"))
    assert "#2e7d32" in block.result_note.styleSheet()
    assert not block.result_path.isVisible() and not block.copy_btn.isVisible()


def test_an_unverified_open_is_reported_amber_with_the_path_to_copy(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    block.set_opener(FakeOpener("unverified"))
    path = os.path.join(src_tree, "hugmesh-admin-ui")
    block.open_buttons[(ctl.mesh_domains.own_name, "hugmesh-admin-ui")].click()
    assert block.result_note.isVisible()
    assert "dispatched" in block.result_note.text()
    assert "#a65d00" in block.result_note.styleSheet()
    assert block.result_path.isVisible() and block.result_path.text() == path
    assert block.copy_btn.isVisible()
    block.copy_btn.click()
    try:
        clip = QtWidgets.QApplication.clipboard().text()
    except Exception:                                   # noqa: BLE001 — no clipboard
        clip = None
    assert clip in (path, None)
    assert block.copy_btn.text() in ("Copied", "Select and copy the path")


def test_a_failed_open_is_reported_red_with_the_reason_and_the_path(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    block.set_opener(FakeOpener("failed"))
    block.open_all_buttons["chat.example.org"].click()
    text = block.result_note.text()
    assert text.startswith("0 of 4 folders opened; Could not open ")
    assert "xdg-open exited 2" in text and "Copy the path" in text
    assert "#b00020" in block.result_note.styleSheet()
    assert block.result_path.isVisible()
    assert block.result_path.text() == block.last_results[0].path


class StillRunningHost:
    """A stand-in machine whose only opener never exits (the file manager itself).
    It records how long each call was ALLOWED to wait, and spends that time on a
    fake clock, so the test sees what a real window thread would have waited."""
    kind = "linux"
    startfile = None
    wsl_distro = ""
    environ = {}

    def __init__(self, clock):
        self.clock = clock
        self.calls = []
        self.waits = []

    def which(self, name):
        return f"/usr/bin/{name}" if name == "xdg-open" else None

    def run(self, argv, capture, wait_s):
        self.calls.append(argv[-1])
        self.waits.append(wait_s)
        self.clock[0] += wait_s
        return None, ""


def _every_folder_present(tmp_path, ctl, block):
    """Create ALL the checkouts the map names (a full source tree)."""
    src = tmp_path / "full"
    src.mkdir()
    ctl.src_existing.setChecked(True)
    ctl.src_dir.setText(str(src))
    _settle()
    for app in {a.name for d in block.map.domains for a in d.apps}:
        (src / app).mkdir(exist_ok=True)
    ctl.src_dir.setText(str(src) + " ")          # a no-op edit that forces a re-read
    ctl.src_dir.setText(str(src))
    _settle()
    return str(src)


def test_open_all_with_a_file_manager_that_never_exits_waits_once_not_per_folder(
        wiz, tmp_path, monkeypatch):
    """The freeze the integration skeptic measured: the real open_folder, a fake
    host whose opener stays running, a domain with every platform checkout."""
    from hugmesh_studio.core import open_path as op
    clock = [0.0]
    monkeypatch.setattr(op, "_now", lambda: clock[0])
    ctl, _page = _to_source(wiz)
    block = ctl.code_folders
    _every_folder_present(tmp_path, ctl, block)
    own = ctl.mesh_domains.own_name
    folders = block.map.domains[0].openable_paths()
    assert len(folders) >= 15, "this test needs a domain with most of its folders present"
    host = StillRunningHost(clock)
    block.set_host(host)
    block.open_all_buttons[own].click()
    assert len(host.calls) == len(folders)
    assert sum(host.waits) <= op.OPENER_WAIT_S, (
        f"{sum(host.waits):.0f}s of waiting on the window's thread for "
        f"{len(folders)} folders")
    # nothing confirmed any of it: amber, with the path to copy, never green
    assert "#a65d00" in block.result_note.styleSheet()
    assert "#2e7d32" not in block.result_note.styleSheet()
    assert f"Asked for {len(folders)} folders" in block.result_note.text()
    assert block.result_path.isVisible() and block.result_path.text() == folders[0]
    assert block.copy_btn.isVisible()


def test_a_single_open_that_stays_running_is_unconfirmed_not_green(
        wiz, src_tree, monkeypatch):
    from hugmesh_studio.core import open_path as op
    clock = [0.0]
    monkeypatch.setattr(op, "_now", lambda: clock[0])
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    block.set_host(StillRunningHost(clock))
    path = os.path.join(src_tree, "hugmesh-gateway")
    block.open_buttons[(ctl.mesh_domains.own_name, "hugmesh-gateway")].click()
    assert "#a65d00" in block.result_note.styleSheet()
    assert "nothing confirmed a window" in block.result_note.text()
    assert block.result_path.isVisible() and block.result_path.text() == path


def test_the_copy_button_forgets_a_previous_copy(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    block.set_opener(FakeOpener("unverified"))
    key = (ctl.mesh_domains.own_name, "hugmesh-admin-ui")
    block.open_buttons[key].click()
    block.copy_btn.click()
    assert block.copy_btn.text() != "Copy path"
    block.open_buttons[key].click()
    assert block.copy_btn.text() == "Copy path"


def test_a_missing_root_is_explained_in_a_wrapped_note_not_only_in_the_elided_line(
        wiz, tmp_path):
    gone = str(tmp_path / "nope")
    ctl, _page = _to_source(wiz, source_dir=gone)
    block = ctl.code_folders
    assert block.root_path.full_text() == gone
    assert block.root_note.isVisible() and block.root_note.wordWrap()
    assert block.root_note.text() == f"{gone} does not exist"
    ctl.src_dir.setText("~/src")
    _settle()
    assert "does not expand" in block.root_note.text()
    ctl.src_dir.setText(str(tmp_path))
    _settle()
    assert not block.root_note.isVisible()


def test_no_modal_anywhere_in_the_block():
    import inspect
    src = inspect.getsource(cfw)
    assert "QMessageBox" not in src and ".exec(" not in src
    mount = inspect.getsource(lm.LocalMeshPage._build_source_section)
    assert "QMessageBox" not in mount and ".exec(" not in mount


# ── the block follows the steps before it ───────────────────────────────────────
def test_the_block_follows_the_domains_table_and_the_source_cards(wiz, src_tree):
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    block = ctl.code_folders
    first = dict(block.open_buttons)
    ctl._refresh_plan()
    assert dict(block.open_buttons) == first, "an unchanged map must not rebuild"
    # a domain added on the Domains step shows up with its own rows
    wiz.back()
    wiz.back()
    assert isinstance(wiz.currentPage(), lm.LocalMeshDomainsPage)
    ctl.domains_table._add("wiki.example.org", "Wiki")
    _to(wiz, lm.LocalMeshSourcePage)
    assert "wiki.example.org" in block.open_all_buttons
    assert block.open_buttons[("wiki.example.org", "hugmesh-gateway")].isEnabled()
    # and the source cards switch the root and the notice
    ctl.src_clone.setChecked(True)
    _settle()
    assert block.map.root.endswith(cf.STACK_SRC_DIR)
    assert block.notice.text() == cf.CLONE_MODE_NOTICE
    assert block.root_path.full_text().startswith(block.map.root)


# ── geometry: a control that cannot be seen is not delivered ────────────────────
def _buttons(block):
    out = [("root", block.open_root_btn)]
    out += [((d, "ALL"), b) for d, b in block.open_all_buttons.items()]
    out += list(block.open_buttons.items())
    # the per-domain copies part (2026-10-21): Make N copies, Open copies folder, and
    # the two-click removal when a domain has extra copies
    for tag, buttons in (("MAKE", block.clone_buttons),
                         ("COPIES", block.open_copies_buttons),
                         ("REMOVE", block.remove_buttons),
                         ("KEEP", block.cancel_buttons)):
        out += [((d, tag), b) for d, b in buttons.items()
                if tag != "KEEP" or b.isVisibleTo(block)]
    return out


def _rect_in(widget, ancestor):
    return QtCore.QRect(widget.mapTo(ancestor, QtCore.QPoint(0, 0)), widget.size())


def _assert_block_geometry(block, page, size):
    viewport = page._content_scroll.viewport()
    content = page._content_scroll.widget()
    assert page._content_scroll.horizontalScrollBar().maximum() == 0, \
        "content wider than the viewport is cut off (no horizontal scrollbar exists)"
    assert content.width() <= viewport.width()
    assert block.width() <= viewport.width(), (block.width(), viewport.width())
    assert block.width() >= 400, "the block must get the page's width"
    rects = []
    for key, btn in _buttons(block):
        assert btn.isVisible(), key
        r = _rect_in(btn, block)
        assert block.rect().contains(r), (key, r, block.rect(), size)
        assert r.height() >= 20, (key, r.height())
        text_w = btn.fontMetrics().horizontalAdvance(btn.text())
        assert r.width() >= text_w + 8, f"{key}: button narrower than its label"
        for other_key, other in rects:
            assert not r.intersects(other), (key, other_key, r, other)
        rects.append((key, r))
    # the text columns elide instead of widening the row
    for lab in block.findChildren(cfw.ElidedLabel):
        if not lab.isVisible():
            continue
        lr = _rect_in(lab, block)
        assert block.rect().contains(lr), (lab.full_text(), lr)
        assert lab.minimumSizeHint().width() < 80
        drawn = lab.elided_text()
        assert drawn == lab.full_text() or "…" in drawn
    return rects


@pytest.mark.parametrize("size", [SMALLEST, NORMAL])
def test_every_control_is_drawn_inside_the_block_at_the_window_sizes(wiz, tmp_path,
                                                                      size):
    # three 60-character labels: wider than any supported window at any font, so
    # the header MUST elide rather than widen (a hostname may run to 253 chars)
    long_name = "-".join(["abcdefghij" * 6] * 3) + ".example.org"
    assert len(long_name) == 194
    # SIX nested components rather than one long one: an encrypted home (eCryptfs)
    # caps a single file name well under 255 bytes, and the point is the PATH length.
    deep = tmp_path
    for i in range(6):
        deep = deep / f"a-rather-long-directory-name-{i}"
    deep = deep / "source-tree"
    assert len(str(deep)) > 200
    for name in PRESENT:
        (deep / name).mkdir(parents=True)
    wiz.resize(*size)
    ctl, page = _to_source(wiz, extra_domain=long_name, source_dir=str(deep))
    _settle()
    block = ctl.code_folders
    assert wiz.size() == QtCore.QSize(*size)
    assert len(block.open_buttons) >= 2 * 6, "two domains, at least six apps each"
    rects = _assert_block_geometry(block, page, size)
    assert {(long_name, "MAKE"), (long_name, "COPIES")} <= dict(rects).keys()
    # the long domain name is elided in its header, and its Open all is still whole
    header = next(lab for lab in block.findChildren(cfw.ElidedLabel)
                  if lab.full_text() == f"Domain: {long_name}")
    assert "…" in header.elided_text()
    assert dict(rects)[(long_name, "ALL")].right() <= block.width()
    # the long path is elided in its cell too
    gw = block.rows[(long_name, "hugmesh-gateway")].path
    cell = next(lab for lab in block.findChildren(cfw.ElidedLabel) if lab.full_text() == gw)
    assert "…" in cell.elided_text()


def test_geometry_holds_at_a_small_font_too(wiz, src_tree, qapp):
    """#647's second finding: a column sized for 9 pt clipped again at 8 pt."""
    saved = qapp.font()
    small = QtGui.QFont(saved)
    small.setPointSize(8)
    qapp.setFont(small)
    try:
        wiz.resize(*SMALLEST)
        ctl, page = _to_source(wiz, source_dir=src_tree)
        _settle()
        _assert_block_geometry(ctl.code_folders, page, SMALLEST)
    finally:
        qapp.setFont(saved)


def test_the_rendered_block_is_a_real_picture(wiz, src_tree, tmp_path):
    """A grab of the block must not be blank, and the buttons must be where the
    geometry says: the pixel under an enabled button's centre is not the page
    background (a widget that is laid out but never painted would pass every
    geometry assertion above)."""
    wiz.resize(*SMALLEST)
    ctl, _page = _to_source(wiz, source_dir=src_tree)
    _settle()
    block = ctl.code_folders
    pix = block.grab()
    assert not pix.isNull() and pix.height() > 600
    out = tmp_path / "block.png"
    assert pix.save(str(out)) and out.stat().st_size > 1000
    img = pix.toImage()
    bg = img.pixelColor(2, 2)
    btn = block.open_buttons[(ctl.mesh_domains.own_name, "hugmesh-gateway")]
    c = _rect_in(btn, block).center()
    assert img.pixelColor(c.x(), c.y()) != bg or \
        img.pixelColor(c.x() - btn.width() // 2 + 1, c.y()) != bg


class _FakeGit:
    """Makes the folders a clone makes; every copy is clean."""

    def __init__(self):
        self.clones = []

    def __call__(self, argv, cwd):
        if argv[0] == "clone":
            self.clones.append(argv[3])
            os.makedirs(os.path.join(argv[-1], ".git"))
        if argv[0] == "rev-list":
            return 0, "0"
        return 0, ""


def test_the_copies_part_works_in_the_wizard_at_the_smallest_window(wiz, src_tree):
    """The per-domain copies inside the REAL Repo source step at 736x736: Make copies
    clones only what the domain has, the rows switch to the copies, and un-ticking a
    service on the domain arms a two-click removal. Pictures go to
    $CODE_FOLDERS_SHOTS_DIR when it is set, for a person to look at."""
    shots = os.environ.get("CODE_FOLDERS_SHOTS_DIR", "")
    wiz.resize(*SMALLEST)
    ctl, page = _to_source(wiz, source_dir=src_tree)
    _settle()
    block = ctl.code_folders
    git = _FakeGit()
    block.git_runner = git
    make = block.clone_buttons["chat.example.org"]
    assert make.isVisible() and make.isEnabled() and make.height() >= 20
    if shots:
        os.makedirs(shots, exist_ok=True)
        page._content_scroll.ensureWidgetVisible(make)
        _settle()
        assert wiz.grab().save(os.path.join(shots, "wizard-1-make-copies.png"))
    make.click()
    assert block.wait_idle()
    # owncast-ui and forum-api (phpbb) were chosen for chat; only present checkouts
    assert sorted(os.path.basename(p) for p in git.clones) == [
        "hugmesh-admin-ui", "hugmesh-forum-api", "hugmesh-gateway", "hugmesh-owncast-ui"]
    key = ("chat.example.org", "hugmesh-owncast-ui")
    assert block.row_paths[key].endswith(
        os.path.join("chat.example.org", "hugmesh-owncast-ui.chat.example.org"))
    # un-tick owncast on that domain, as the Domain services step would
    row = ctl.mesh_domains.domains[1]
    row.optional_services = [s for s in row.optional_services if s != "owncast"]
    ctl._refresh_code_folders()
    _settle()
    rm = block.remove_buttons["chat.example.org"]
    assert rm.text() == "Remove 1 extra folder…" and rm.isVisible() and rm.isEnabled()
    rm.click()
    assert block.wait_idle()                     # the check runs off the window thread
    _settle()
    rm = block.remove_buttons["chat.example.org"]
    assert rm.text() == "Click again to remove 1 folder" and rm.isEnabled()
    assert block.cancel_buttons["chat.example.org"].isVisible()
    _assert_block_geometry(block, page, SMALLEST)
    if shots:
        page._content_scroll.ensureWidgetVisible(rm)
        _settle()
        assert wiz.grab().save(os.path.join(shots, "wizard-2-armed.png"))
        assert block.grab().save(os.path.join(shots, "wizard-block-armed.png"))
    extra = os.path.join(block.plan.root, "chat.example.org",
                         "hugmesh-owncast-ui.chat.example.org")
    assert os.path.isdir(extra)                  # the first click removed nothing
    rm.click()
    assert block.wait_idle()
    assert not os.path.exists(extra)


def test_the_page_keeps_a_saved_meshs_copies_and_not_the_record_it_was_loaded_from(
        wiz, src_tree):
    """Meshes with the same own domain share one copies folder: a SAVED mesh that
    still has owncast on chat.example.org keeps that copy from being offered; the
    record the page's form was loaded from (``_loaded_record_id``) does not."""
    import json

    from hugmesh_studio.core import saved_meshes
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    wiz.resize(*SMALLEST)
    ctl, page = _to_source(wiz, source_dir=src_tree)
    _settle()
    block = ctl.code_folders
    block.git_runner = _FakeGit()
    block.clone_buttons["chat.example.org"].click()
    assert block.wait_idle()
    rec = saved_meshes.SavedMesh(
        id="20261021-130000-abcdef", label="Mesh A",
        config=LocalMeshBootstrapConfig.from_dict({"domains": [
            {"name": "chat.example.org", "optional_services": ["owncast", "phpbb"],
             "idp": "superdomain"}]}).to_dict())
    os.makedirs(saved_meshes.meshes_dir(), exist_ok=True)
    with open(rec.path(), "w") as fh:
        json.dump(rec.to_dict(), fh)
    row = ctl.mesh_domains.domains[1]
    row.optional_services = [s for s in row.optional_services if s != "owncast"]
    ctl._refresh_code_folders()
    _settle()
    assert "chat.example.org" not in block.remove_buttons
    note = block.claimed_labels["chat.example.org"]
    assert note.isVisible() and note.isEnabled() and note.width() >= 200
    assert "the saved mesh ‘Mesh A’ still has hugmesh-owncast-ui on chat.example.org" \
        in note.text()
    _assert_block_geometry(block, page, SMALLEST)
    ctl._loaded_record_id = rec.id
    ctl._refresh_code_folders()
    _settle()
    rm = block.remove_buttons["chat.example.org"]
    assert rm.text() == "Remove 1 extra folder…" and rm.isVisible() and rm.isEnabled()
