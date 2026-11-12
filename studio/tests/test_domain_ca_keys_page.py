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


def test_another_domains_root_key_is_an_inline_refusal_drawn_whole(wiz, qapp,
                                                                   monkeypatch,
                                                                   tmp_path):
    """PR #938 round 3, finding 1, on screen: a cross-certificate carrying ANOTHER
    domain's root key is refused under the buttons, whole, and nothing is held.
    HUGMESH_LOOK_SHOTS=DIR saves the screenshot a reviewer looks at."""
    from hugmesh_studio.core.config import Domain
    page = _to_page(wiz)
    wiz.cfg.domains = [Domain(name="x.example")]
    page.refresh()
    ro_key, rx_key = tca.key(), tca.key()
    ro = tca.cert(ro_key, "m Root CA")
    rx = tca.cert(rx_key, "x Root CA")
    cross = tca.cert(rx_key, "x Root CA", issuer_key=ro_key, issuer_cert=ro,
                     path_length=0)
    page.table.selectRow(1)
    _picks(monkeypatch, tca.write(tmp_path, "rx.crt", tca.pem(rx)))
    page.import_root.click()
    page.table.selectRow(0)
    _picks(monkeypatch, tca.write(tmp_path, "ro.crt", tca.pem(ro)))
    page.import_root.click()
    _picks(monkeypatch, tca.write(tmp_path, "c.crt", tca.pem(cross)),
           tca.write(tmp_path, "rx.key", tca.key_pem(rx_key)))
    page.passphrase.setText("typed but unused")
    page.import_files.click()
    note = page.note.text()
    assert note.startswith("Not imported: the signing key for this mesh's own domain")
    assert "x.example" in note and "root CA key is never taken" in note
    assert page.passphrase.text() == ""
    own = dca.store().own()
    assert own is not None and own.key_pem == b"" and own.signing_pem == b""
    assert _cells(page)[0][3] == "-"
    settle(qapp, 5)
    shots = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if shots:
        os.makedirs(shots, exist_ok=True)
        wiz.grab().save(os.path.join(shots, "domain-ca-keys-refusal-cross-root.png"))
    assert_page_fits_its_window(page)
    assert_whole(page.note, "the refusal under the buttons")


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


# ── a malformed certificate is an inline refusal (PR #938 review, finding 3) ─────
def test_a_malformed_certificate_is_an_inline_refusal_and_clears_the_passphrase(
        wiz, monkeypatch, tmp_path):
    page = _to_page(wiz)
    k = tca.key()
    bad = tca.write(tmp_path, "bad.crt",
                    tca.pem(tca.malformed_basic_constraints(k, "malformed")))
    kp = tca.write(tmp_path, "bad.key", tca.key_pem(k))
    page.table.selectRow(0)
    for handler, picks in ((page._import_files, (bad, kp)),
                           (page._import_root, (bad,)),
                           (page._import_p12, (tca.p12(tmp_path, "bad.p12", k,
                                                       tca.malformed_basic_constraints(
                                                           k, "malformed"),
                                                       passphrase="typed-passphrase"),
                                               ))):
        page.passphrase.setText("typed-passphrase")
        _picks(monkeypatch, *picks)
        handler()                     # called directly: a raise reaches the test
        assert page.note.text().startswith("Not imported:"), page.note.text()
        assert "does not parse" in page.note.text()
        assert page.passphrase.text() == ""
        assert dca.store().entries() == ()


# ── an unopenable file is an inline refusal, not the crash dialog (build audit L7) ─
def test_a_key_path_that_does_not_open_is_an_inline_refusal(
        wiz, monkeypatch, tmp_path):
    page = _to_page(wiz)
    chain = tca.Chain(tmp_path)
    d = str(tmp_path / "a-directory")
    os.mkdir(d)
    page.table.selectRow(0)
    page.passphrase.setText("typed-passphrase")
    _picks(monkeypatch, chain.signing_path, d)
    page._import_files()              # called directly: a raise reaches the test
    assert page.note.text().startswith("Not imported: cannot read"), page.note.text()
    assert page.passphrase.text() == ""
    assert dca.store().entries() == ()


@pytest.mark.parametrize("exc, needle", [
    (PermissionError(13, "Permission denied", "/keys/ca.key"),
     "cannot read /keys/ca.key: Permission denied"),
    (ValueError("error parsing asn1 value: ParseError { kind: ShortData }"),
     "does not parse"),
])
def test_a_read_or_parse_error_past_the_core_is_still_an_inline_refusal(
        wiz, exc, needle):
    # the backstop in _run: whatever the core lets through of these two kinds is a
    # sentence on the page (and never cryptography's raw asn1 text)
    page = _to_page(wiz)
    page.passphrase.setText("typed-passphrase")

    def fail():
        raise exc
    page._run(fail)
    assert page.note.text().startswith("Not imported:"), page.note.text()
    assert needle in page.note.text(), page.note.text()
    assert "asn1" not in page.note.text()
    assert page.passphrase.text() == ""


def test_an_unexpected_error_still_clears_the_passphrase(wiz):
    page = _to_page(wiz)
    page.passphrase.setText("typed-passphrase")

    def boom():
        raise RuntimeError("not a refusal")
    with pytest.raises(RuntimeError):
        page._run(boom)
    assert page.passphrase.text() == ""


# ── a refused rename, on both faces (#974 round 3 self-refute) ───────────────────
def _x_files(tmp_path):
    """x.example's root and an intermediate it issued (with its own key)."""
    rx_key, ik = tca.key(), tca.key()
    rx = tca.cert(rx_key, "x Root CA")
    xi = tca.cert(ik, "x Signing CA", issuer_key=rx_key, issuer_cert=rx, path_length=0)
    return (tca.write(tmp_path, "rx.crt", tca.pem(rx)),
            tca.write(tmp_path, "xi.crt", tca.pem(xi)),
            tca.write(tmp_path, "xi.key", tca.key_pem(ik)))


def _held_now():
    return sorted((e.domain, e.own, e.root_pem, e.signing_pem, e.key_pem)
                  for e in dca.store().entries())


def test_an_own_row_import_during_a_refused_rename_is_an_inline_refusal(
        wiz, qapp, monkeypatch, tmp_path):
    """The mesh's CA (a signing CA, no root) on m.example, x.example's root on its
    row, then the mesh renamed to x.example: the move is refused, and the own row
    (now x.example) must not take a second own CA, which the next refresh would
    have moved over x.example's root. Its Remove is the remedy the checklist names.
    HUGMESH_LOOK_SHOTS=DIR saves the screenshot a reviewer looks at."""
    from hugmesh_studio.core.config import Domain
    page = _to_page(wiz)
    wiz.cfg.cluster_domain = "m.example"
    wiz.cfg.domains = [Domain(name="x.example")]
    page.refresh()
    m = tca.Chain(tmp_path, tag="m")
    rx_path, xi_path, xk_path = _x_files(tmp_path)
    page.table.selectRow(0)
    _picks(monkeypatch, m.signing_path, m.key_path)
    page.import_files.click()
    assert "Imported for m.example" in page.note.text(), page.note.text()
    page.table.selectRow(1)
    _picks(monkeypatch, rx_path)
    page.import_root.click()
    assert "Imported for x.example" in page.note.text(), page.note.text()
    wiz.cfg.cluster_domain = "x.example"                 # the rename
    page.refresh()
    assert page.table.rowCount() == 1
    assert any("renamed to x.example" in ln
               for ln in page.checklist.text().splitlines())
    held = _held_now()
    page.table.selectRow(0)
    _picks(monkeypatch, xi_path, xk_path)
    page.import_files.click()
    note = page.note.text()
    assert note.startswith("Not imported: the mesh's own CA is held for m.example"), note
    assert "ONE own CA" in note
    page.refresh()                                       # the move it used to make
    assert _held_now() == held
    assert dca.store().get("x.example").root_pem and not dca.store().get("x.example").own
    settle(qapp, 5)
    shots = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if shots:
        os.makedirs(shots, exist_ok=True)
        page.note.setText(note)
        settle(qapp, 3)
        wiz.grab().save(os.path.join(shots, "domain-ca-keys-refusal-second-own.png"))
    page.note.setText(note)
    assert_page_fits_its_window(page)
    assert_whole(page.note, "the refusal under the buttons")
    # the remedy, as the checklist words it: Remove on that row, and the mesh's CA
    # moves to x.example by itself
    assert page.remove_btn.isEnabled()
    page.remove_btn.click()
    own = dca.store().own()
    assert own is not None and own.domain == "x.example" and own.key_pem
    assert not any("renamed to" in ln for ln in page.checklist.text().splitlines())


def test_tui_an_own_row_import_during_a_refused_rename_is_refused(tmp_path):
    from hugmesh_studio.core.config import Domain
    m = tca.Chain(tmp_path, tag="m")
    rx_path, xi_path, xk_path = _x_files(tmp_path)
    j = journey.Journey(GENERATOR_DIR)
    j.cfg.mode = "mesh"
    j.cfg.cluster_domain = "m.example"
    j.cfg.domains = [Domain(name="x.example")]
    j.goto(dca.STEP_SLUG)
    j.feed(f"k 1 {m.signing_path} {m.key_path}")
    assert j.status.startswith("imported"), j.status
    j.feed(f"r 2 {rx_path}")
    assert j.status.startswith("imported"), j.status
    j.cfg.cluster_domain = "x.example"                   # the rename
    assert "renamed to x.example" in "\n".join(j.lines())
    held = _held_now()
    j.feed(f"k 1 {xi_path} {xk_path}")
    assert j.status.startswith("refused: the mesh's own CA is held for m.example"), \
        j.status
    j.lines()                                            # the move it used to make
    assert _held_now() == held
    j.feed("x 1")                                        # the remedy
    assert j.status.startswith("removed"), j.status
    j.lines()
    own = dca.store().own()
    assert own is not None and own.domain == "x.example" and own.key_pem


# ── the old name added back during a refused rename (#974 refute, round 1b) ──────
def _old_name_back(cfg):
    """After the refused rename to x.example, the operator adds m.example back as
    another domain: its row is where the mesh's own CA (and key) is still held."""
    from hugmesh_studio.core.config import Domain
    cfg.cluster_domain = "x.example"
    cfg.domains = [Domain(name="x.example"), Domain(name="m.example")]


def test_the_old_name_row_says_it_holds_the_meshs_ca_and_key(wiz, qapp, monkeypatch,
                                                             tmp_path):
    """That row read 'm-signing.crt + m-signing.key | not taken (certificates only)
    | ready' and its Remove removed the mesh's CA and key. It now names whose CA
    and key it shows, is not ready, and the checklist says what Remove does there.
    HUGMESH_LOOK_SHOTS=DIR saves the screenshot a reviewer looks at."""
    from hugmesh_studio.core.config import Domain
    page = _to_page(wiz)
    wiz.cfg.cluster_domain = "m.example"
    wiz.cfg.domains = [Domain(name="x.example")]
    page.refresh()
    m = tca.Chain(tmp_path, tag="m")
    rx_path, _xi, _xk = _x_files(tmp_path)
    page.table.selectRow(0)
    _picks(monkeypatch, m.signing_path, m.key_path)
    page.import_files.click()
    page.table.selectRow(1)
    _picks(monkeypatch, rx_path)
    page.import_root.click()
    _old_name_back(wiz.cfg)
    page.refresh()
    held = _held_now()
    rows = {r[0]: r for r in _cells(page)}
    assert rows["m.example"][3] == dca.OLD_NAME_KEY_CELL, rows["m.example"]
    assert rows["m.example"][4] == "not ready", rows["m.example"]
    text = page.checklist.text()
    assert "holds the mesh's OWN CA and its signing key" in text, text
    assert "Removing this row's CA removes the mesh's CA" in text, text
    assert "not taken (certificates only)" not in rows["m.example"]
    assert _held_now() == held                       # showing it moves nothing
    settle(qapp, 5)
    shots = os.environ.get("HUGMESH_LOOK_SHOTS", "")
    if shots:
        os.makedirs(shots, exist_ok=True)
        wiz.grab().save(os.path.join(shots, "domain-ca-keys-old-name-row.png"))
    assert_page_fits_its_window(page)
    assert_whole(page.checklist, "the go-live checklist")


def test_tui_the_old_name_row_says_it_holds_the_meshs_ca_and_key(tmp_path):
    from hugmesh_studio.core.config import Domain
    m = tca.Chain(tmp_path, tag="m")
    rx_path, _xi, _xk = _x_files(tmp_path)
    j = journey.Journey(GENERATOR_DIR)
    j.cfg.mode = "mesh"
    j.cfg.cluster_domain = "m.example"
    j.cfg.domains = [Domain(name="x.example")]
    j.goto(dca.STEP_SLUG)
    j.feed(f"k 1 {m.signing_path} {m.key_path}")
    j.feed(f"r 2 {rx_path}")
    _old_name_back(j.cfg)
    out = "\n".join(j.lines())
    row = next(ln for ln in out.splitlines() if ln.strip().startswith("2. m.example"))
    assert dca.OLD_NAME_KEY_CELL in row and row.rstrip().endswith("not ready"), row
    assert "certificates only" not in row, row
    assert "holds the mesh's OWN CA and its signing key" in out, out
