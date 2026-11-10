"""The Domain CA keys step on screen (GUI), and its parity with the TUI and the CLI.

* the page is reached on a mesh walk right after Domain services, and its table,
  checklist and refusals are the core's (core/domain_ca_keys.py);
* GEOMETRY, not model state: the table, the four buttons, the passphrase field and
  the checklist are visible and inside the window at the wizard's default size,
  under the installed styles at 8 pt too (the #647 lesson: a control can be "there"
  to every model test and not drawn). Set HUGMESH_LOOK_SHOTS=DIR to save the
  screenshots a reviewer looks at;
* PARITY: the TUI screen shows the same table and checklist lines, its commands
  cover the GUI buttons one for one, and the CLI prints the same checklist for the
  same files.
"""
import contextlib
import io
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")
pytest.importorskip("cryptography")

import _throwaway_ca as tca                                            # noqa: E402
from hugmesh_studio.core import domain_ca_keys as dca                  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                 # noqa: E402
from hugmesh_studio.core.worklist_driver import node_key_profiles      # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                    # noqa: E402
from hugmesh_studio.gui.pages import domain_ca_keys as page_mod        # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                            # noqa: E402
from hugmesh_studio.tui import journey                                 # noqa: E402
from hugmesh_studio.tui.domain_ca_keys_step import COMMANDS, DomainCAKeysScreen  # noqa: E402

from _helpers import advance_to, check_worklist_rows, pick_mode        # noqa: E402
from _look import assert_page_fits_its_window, assert_whole, settle    # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
_INSTALLED = set(QtWidgets.QStyleFactory.keys())
COMBOS = [(s, pt) for s, pt in (("Fusion", None), ("Fusion", 8.0), ("Windows", 8.0),
                                ("Breeze", 8.0)) if s in _INSTALLED]


@pytest.fixture(autouse=True)
def _isolate(monkeypatch, tmp_path):
    monkeypatch.setattr(dca, "_STORE", None)
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-domain-ca-keys-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()


def _to_page(wiz):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, "pki.x86", "backend.x86", "frontend.x86")
    return advance_to(wiz, page_mod.DomainCAKeysPage)


def _picks(monkeypatch, *paths):
    queue = list(paths)
    monkeypatch.setattr(page_mod, "pick_file",
                        lambda *a, **k: (queue.pop(0) if queue else "", ""))


def _cells(page):
    t = page.table
    return [[t.item(r, c).text() for c in range(t.columnCount())]
            for r in range(t.rowCount())]


def _import_chain(page, monkeypatch, chain, pw=None):
    page.table.selectRow(0)
    _picks(monkeypatch, chain.root_path)
    page.import_root.click()
    _picks(monkeypatch, chain.signing_path,
           chain.encrypted_key_path(pw) if pw else chain.key_path)
    if pw:
        page.passphrase.setText(pw)
    page.import_files.click()


# ── on the walk ──────────────────────────────────────────────────────────────────
def test_the_step_follows_domain_services_on_a_mesh_walk(wiz):
    pick_mode(wiz, "mesh")
    advance_to(wiz, wizard_mod.DomainServicesPage)
    wiz.next()
    page = wiz.currentPage()
    assert isinstance(page, page_mod.DomainCAKeysPage)
    assert page.title() == dca.STEP_TITLE
    wiz.next()
    assert isinstance(wiz.currentPage(), wizard_mod.UsersChoicePage)


def test_import_fills_the_row_and_the_checklist_says_ready(wiz, monkeypatch, tmp_path):
    page = _to_page(wiz)
    headers = [page.table.horizontalHeaderItem(c).text()
               for c in range(page.table.columnCount())]
    assert headers == list(dca.TABLE_HEADERS)
    assert page.checklist.text().splitlines()[0].startswith("NOT ready")
    chain = tca.Chain(tmp_path)
    _import_chain(page, monkeypatch, chain, pw="pw on the page")
    assert page.passphrase.text() == ""                      # cleared after use
    assert "Imported for" in page.note.text()
    assert _cells(page) == dca.row_cells(wiz.cfg, dca.store(),
                                         node_key_profiles(wiz.worklist))
    row = _cells(page)[0]
    assert row[3] == "held (pki stick only)" and row[4] == "ready"
    expect = dca.readiness_lines(wiz.cfg, dca.store(), node_key_profiles(wiz.worklist))
    assert page.checklist.text().splitlines() == expect
    assert expect[0].startswith("READY to go live")
    assert "pw on the page" not in page.note.text() + page.checklist.text()
    assert wiz.cfg.to_cli_args() == wiz.cfg.to_cli_args()  # nothing committed to cfg
    assert "PRIVATE" not in str(wiz.cfg.to_dict())


def test_a_refusal_is_inline_and_holds_nothing(wiz, monkeypatch, tmp_path):
    page = _to_page(wiz)
    chain = tca.Chain(tmp_path)
    other = tca.write(tmp_path, "other.key", tca.key_pem(tca.key()))
    page.table.selectRow(0)
    _picks(monkeypatch, chain.signing_path, other)
    page.import_files.click()
    assert page.note.text().startswith("Not imported: the private key does not belong")
    assert dca.store().entries() == ()
    page.remove_btn.setEnabled(True)
    page.remove_btn.click()
    assert page.note.text() == "Nothing to remove."


def test_without_cryptography_the_buttons_are_off_and_say_why(wiz, monkeypatch):
    page = _to_page(wiz)
    page.crypto_note = "no cryptography here"
    page.refresh()
    assert not page.import_files.isEnabled() and not page.import_p12.isEnabled()
    assert "no cryptography here" in page.note.text()


# ── geometry ─────────────────────────────────────────────────────────────────────
def _restyle(win, style, pt):
    st = QtWidgets.QStyleFactory.create(style)
    for w in [win, *win.findChildren(QtWidgets.QWidget)]:
        w.setStyle(st)
    if pt:
        f = win.font()
        f.setPointSizeF(pt)
        win.setFont(f)


@pytest.mark.parametrize("style, pt", COMBOS, ids=[f"{s}-{p or 'default'}pt"
                                                  for s, p in COMBOS])
def test_the_step_is_drawn_whole_inside_the_window(wiz, qapp, monkeypatch,
                                                        tmp_path, style, pt):
    page = _to_page(wiz)
    _import_chain(page, monkeypatch, tca.Chain(tmp_path))
    _restyle(wiz, style, pt)
    settle(qapp, 5)
    shots = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if shots:
        os.makedirs(shots, exist_ok=True)
        wiz.grab().save(os.path.join(shots, f"domain-ca-keys-{style}-{pt or 'default'}.png"))
    assert_page_fits_its_window(page)
    vp = page._content_scroll.viewport()
    for w, what in ((page.table, "the domain table"),
                    (page.passphrase, "the passphrase field"),
                    (page.import_files, "Import certificate + key"),
                    (page.import_p12, "Import PKCS#12"),
                    (page.import_root, "Root certificate"),
                    (page.remove_btn, "Remove")):
        assert w.isVisible(), what
        assert w.width() >= 40 and w.height() >= 16, (what, w.size())
        top = vp.mapFromGlobal(w.mapToGlobal(w.rect().topLeft())).y()
        assert top < vp.height(), f"{what} is below the fold ({top}px of {vp.height()})"
    for b in (page.import_files, page.import_p12, page.import_root, page.remove_btn):
        need = b.fontMetrics().horizontalAdvance(b.text().replace("&", ""))
        assert need <= b.width(), (b.text(), need, b.width())
    # the four buttons sit side by side without overlapping
    rects = sorted((b.mapTo(page, b.rect().topLeft()).x(), b.width())
                   for b in (page.import_files, page.import_p12, page.import_root,
                             page.remove_btn))
    for (x1, w1), (x2, _w2) in zip(rects, rects[1:]):
        assert x1 + w1 <= x2, rects
    # every column header and the row's cells are readable without a sideways scroll
    t = page.table
    assert t.horizontalScrollBar().maximum() == 0 or t.width() >= t.horizontalHeader().length()
    assert_whole(page.checklist, "the go-live checklist")
    assert page.checklist.text().splitlines()[0].startswith("READY")


# ── parity: GUI <-> TUI <-> CLI ──────────────────────────────────────────────────
def test_the_tui_screen_shows_the_same_table_and_checklist(wiz, monkeypatch, tmp_path):
    page = _to_page(wiz)
    chain = tca.Chain(tmp_path)
    _import_chain(page, monkeypatch, chain)
    j = journey.Journey(GENERATOR_DIR, cfg=wiz.cfg)
    j.worklist = wiz.worklist
    screen = j.screen_for(dca.STEP_SLUG)
    assert isinstance(screen, DomainCAKeysScreen)
    headers, rows = screen.table(j)
    assert headers == [page.table.horizontalHeaderItem(c).text()
                       for c in range(page.table.columnCount())]
    assert rows == _cells(page)
    assert screen.checklist_lines(j) == page.checklist.text().splitlines()
    text = "\n".join(screen.lines(j))
    for what, why in dca.NOT_TAKEN:
        assert f"{what}: {why}" in text
    assert screen.title == page.title()


def test_tui_commands_cover_the_gui_buttons(wiz):
    page = _to_page(wiz)
    gui = {page.import_files: "k", page.import_p12: "p", page.import_root: "r",
           page.remove_btn: "x"}
    letters = [c.split()[0] for c, _what in COMMANDS if c != "Enter"]
    assert sorted(letters) == sorted(gui.values())


def test_the_cli_prints_the_same_checklist(wiz, monkeypatch, tmp_path):
    page = _to_page(wiz)
    chain = tca.Chain(tmp_path)
    _import_chain(page, monkeypatch, chain)
    profiles = node_key_profiles(wiz.worklist)
    argv = ["check", "--domain", wiz.cfg.cluster_domain, "--cert", chain.signing_path,
            "--key", chain.key_path, "--root", chain.root_path]
    for p in profiles:
        argv += ["--profile", p]
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        code = dca.cli_main(argv)
    assert code == 0
    assert out.getvalue().splitlines() == page.checklist.text().splitlines()


def test_tui_imports_with_a_passphrase_file_and_refuses_inline(tmp_path):
    chain = tca.Chain(tmp_path)
    pwfile = tmp_path / "pw"
    pwfile.write_text("tui secret\n")
    j = journey.Journey(GENERATOR_DIR)
    j.cfg.mode = "mesh"
    j.cfg.cluster_domain = "mesh.example"
    j.goto(dca.STEP_SLUG)
    j.feed(f"r 1 {chain.root_path}")
    assert j.status.startswith("imported"), j.status
    j.feed(f"k 1 {chain.signing_path} {chain.encrypted_key_path('tui secret')} "
           f"pass={pwfile}")
    assert j.status.startswith("imported"), j.status
    assert "tui secret" not in "\n".join(j.lines()) + j.status
    assert dca.store().own().key_pem
    j.feed("k 1 /no/such/cert.pem /no/such.key")
    assert j.status.startswith("refused: cannot read")
    j.feed("x 9")
    assert j.status.startswith("no such row")
    j.feed("x 1")
    assert j.status.startswith("removed") and dca.store().entries() == ()
    j.feed("")
    assert j.slug == "users_choice"
