"""A person's other sign-in handles (hugmesh-generator#1107).

The operator, verbatim: "make sure also there's a way when adding users to specify
their other SSO login handles/users". ``User.signin_handles`` holds an optional Google
account (an email) and Discord username. Each later becomes an invite in that
provider's allowlist; the account is linked by the provider's immutable id at first
sign-in. What these pin:

* the vocabulary, the checks and the stored (trimmed, lowercased) form;
* the default is byte-identical in the saved config and both manifests; a value
  round-trips; junk fails loudly at load; nothing reaches argv;
* the Users page has a column per provider that writes the row, refuses a bad handle
  inline (no dialog) after collecting every row, and warns live when a row registers
  through a provider with no handle; the text table shows the handles;
* every new control is visible and usable at the default size.
"""
from __future__ import annotations

import json
import os
from types import SimpleNamespace

import pytest

from hugmesh_studio.core.config import (
    SIGNIN_HANDLE_PROVIDERS, SIGNIN_HANDLES_NOT_APPLIED, ImageConfig, User,
    clean_signin_handles, signin_handle_problem, signin_handles_problem,
    user_signin_handle_warnings)


def _cfg(users) -> ImageConfig:
    return ImageConfig(mode="mesh", configure_users=True, users=list(users))


# ── the model ───────────────────────────────────────────────────────────────────────
def test_the_providers():
    assert SIGNIN_HANDLE_PROVIDERS == ("google", "discord")


@pytest.mark.parametrize("prov,value", [
    ("google", "Alice@Example.org"), ("google", ""), ("discord", "alice_01"),
    ("discord", "a.b"), ("discord", "  Bob.Two  ")])
def test_valid_handles(prov, value):
    assert signin_handle_problem(prov, value) == ""


@pytest.mark.parametrize("prov,value", [
    ("google", "alice"), ("google", "alice@"), ("discord", "a"), ("discord", "a..b"),
    ("discord", "x" * 33), ("discord", "has space"), ("github", "alice"),
    ("google", 5)])
def test_invalid_handles(prov, value):
    assert signin_handle_problem(prov, value)


def test_clean_keeps_known_providers_in_order_lowercased_and_drops_empties():
    assert clean_signin_handles({"discord": " Bob.Two ", "google": "A@B.org"}) == \
        {"google": "a@b.org", "discord": "bob.two"}
    assert clean_signin_handles({"google": "", "discord": None}) == {}
    assert list(clean_signin_handles({"discord": "bb", "google": "a@b.co"})) == \
        ["google", "discord"]


def test_whole_value_shape():
    assert signin_handles_problem(None) == ""
    assert signin_handles_problem({}) == ""
    assert signin_handles_problem("alice@example.org")
    assert signin_handles_problem({"github": "alice"})


def test_registration_advice():
    assert user_signin_handle_warnings(User(username="a", registration="gmail"))
    assert user_signin_handle_warnings(User(username="a", registration="discord"))
    assert not user_signin_handle_warnings(
        User(username="a", registration="gmail", signin_handles={"google": "a@b.co"}))
    assert not user_signin_handle_warnings(User(username="a", registration="password"))
    assert not user_signin_handle_warnings(User(username="a"))


# ── saved shapes ────────────────────────────────────────────────────────────────────
def test_default_user_says_nothing_anywhere():
    cfg = _cfg([User(username="alice", domain="mesh.example")])
    assert "signin_handles" not in cfg.to_dict()["users"][0]
    assert "signin_handles" not in cfg.mesh_manifest()["users"][0]
    assert "signin_handles" not in User(username="alice").to_dict()


def test_handles_round_trip_and_reach_the_manifest(tmp_path):
    cfg = _cfg([User(username="alice", domain="mesh.example",
                     signin_handles={"google": "alice@example.org",
                                     "discord": "alice_01"})])
    path = tmp_path / "c.json"
    cfg.save(str(path))
    raw = json.loads(path.read_text())
    assert raw["users"][0]["signin_handles"] == {"google": "alice@example.org",
                                                 "discord": "alice_01"}
    back = ImageConfig.load(str(path))
    assert back.users[0].signin_handles == {"google": "alice@example.org",
                                            "discord": "alice_01"}
    assert back.mesh_manifest()["users"][0]["signin_handles"] == \
        {"google": "alice@example.org", "discord": "alice_01"}


def test_load_cleans_and_refuses_junk():
    back = ImageConfig.from_dict({"mode": "mesh", "users": [
        {"username": "a", "signin_handles": {"discord": " Bob ", "google": ""}}]})
    assert back.users[0].signin_handles == {"discord": "bob"}
    for junk in ({"google": "not-an-email"}, {"github": "x"}, "a@b.co"):
        with pytest.raises(ValueError, match="user 'a'"):
            ImageConfig.from_dict({"mode": "mesh", "users": [
                {"username": "a", "signin_handles": junk}]})


def test_never_reaches_argv():
    plain = _cfg([User(username="alice")]).to_cli_args()
    with_h = _cfg([User(username="alice",
                        signin_handles={"google": "alice@example.org"})]).to_cli_args()
    assert plain == with_h


# ── the text table ──────────────────────────────────────────────────────────────────
def test_the_text_users_table_shows_the_handles_the_note_and_the_advice():
    from hugmesh_studio.tui.journey import UsersScreen
    cfg = _cfg([User(username="alice", signin_handles={"google": "alice@example.org"}),
                User(username="bob", registration="discord")])
    text = "\n".join(UsersScreen().lines(SimpleNamespace(cfg=cfg)))
    assert "other sign-ins" in text
    assert "google:alice@example.org" in text
    assert SIGNIN_HANDLES_NOT_APPLIED in text
    assert "Bob registers with discord" in text or "bob registers with discord" in text


# ── the window ──────────────────────────────────────────────────────────────────────
qt = pytest.importorskip("hugmesh_studio.gui.qt",
                         reason="no Qt binding (PySide6/PyQt6) installed")
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")


@pytest.fixture(scope="module")
def qapp():
    from hugmesh_studio.gui.qt import QtWidgets
    return QtWidgets.QApplication.instance() or QtWidgets.QApplication(
        ["hugmesh-studio-signin-handles"])


def _page(qapp, users=()):
    from hugmesh_studio.gui.pages import users as users_mod
    cfg = _cfg(users)
    wiz = SimpleNamespace(cfg=cfg, generator_dir="")
    page = users_mod.UsersPage(wiz)
    page.initializePage()
    page.resize(900, 640)
    page.show()
    for _ in range(3):
        qapp.processEvents()
    return wiz, page, users_mod


def _set(page, r, col, text):
    from hugmesh_studio.gui.qt import QtWidgets
    page.table.setItem(r, col, QtWidgets.QTableWidgetItem(text))


def test_the_page_has_a_column_per_provider_and_the_note(qapp):
    wiz, page, m = _page(qapp, [User(username="alice",
                                     signin_handles={"discord": "alice_01"})])
    heads = [page.table.horizontalHeaderItem(c).text()
             for c in range(page.table.columnCount())]
    assert heads[-2:] == ["Google account", "Discord username"]
    assert page.table.item(0, m._COL_DISCORD).text() == "alice_01"
    assert page.table.item(0, m._COL_GOOGLE).text() == ""
    help_ = page.handles_help
    assert help_.isVisible() and help_.wordWrap()
    assert SIGNIN_HANDLES_NOT_APPLIED in help_.text()
    assert help_.width() <= page.width()
    shot = os.environ.get("HUGMESH_SIGNIN_HANDLES_SHOT", "")
    if shot:
        page.grab().save(shot)


def test_the_page_writes_handles_on_next(qapp):
    wiz, page, m = _page(qapp, [User(username="alice")])
    _set(page, 0, m._COL_GOOGLE, " Alice@Example.org ")
    _set(page, 0, m._COL_DISCORD, "Alice_01")
    assert page.validatePage() is True
    assert wiz.cfg.users[0].signin_handles == {"google": "alice@example.org",
                                               "discord": "alice_01"}
    assert not page.handles_error.isVisible()


def test_a_bad_handle_is_refused_inline_and_nothing_is_written(qapp):
    wiz, page, m = _page(qapp, [User(username="alice"), User(username="bob")])
    _set(page, 0, m._COL_GOOGLE, "not-an-email")
    _set(page, 1, m._COL_DISCORD, "a..b")
    before = [u.to_dict() for u in wiz.cfg.users]
    assert page.validatePage() is False
    err = page.handles_error.text()
    assert page.handles_error.isVisible()
    assert err.startswith("Not saved:") and "alice" in err and "bob" in err  # every row
    assert [u.to_dict() for u in wiz.cfg.users] == before


def test_registering_through_a_provider_with_no_handle_warns_live(qapp):
    wiz, page, m = _page(qapp, [User(username="alice", registration="gmail")])
    assert page.warn.isVisible() and "no Google account is recorded" in page.warn.text()
    _set(page, 0, m._COL_GOOGLE, "alice@example.org")
    qapp.processEvents()
    assert not page.warn.isVisible()


def test_the_editor_under_the_table_edits_the_selected_row_and_is_visible(qapp):
    wiz, page, m = _page(qapp, [User(username="alice"),
                                User(username="bob", signin_handles={"discord": "bob_2"})])
    for prov, edit in page.handle_edits.items():
        assert edit.isVisible() and edit.isEnabled(), prov
        assert edit.width() >= 170, (prov, edit.width())
        right = edit.mapTo(page, qt.QtCore.QPoint(edit.width(), 0)).x()
        assert right <= page.width(), (prov, right, page.width())
    assert page.table.currentRow() == 0
    assert "alice" in page.handles_for.text()
    page.handle_edits["google"].setText("alice@example.org")
    page.handle_edits["google"].textEdited.emit("alice@example.org")
    assert page.table.item(0, m._COL_GOOGLE).text() == "alice@example.org"
    page.table.setCurrentCell(1, m._COL_USER)
    assert page.handle_edits["discord"].text() == "bob_2"
    assert page.handle_edits["google"].text() == ""
    assert page.validatePage() is True
    assert wiz.cfg.users[0].signin_handles == {"google": "alice@example.org"}
    assert wiz.cfg.users[1].signin_handles == {"discord": "bob_2"}


def test_add_user_selects_the_new_row_for_the_editor(qapp):
    wiz, page, m = _page(qapp, [User(username="alice")])
    btn = [b for b in page.findChildren(qt.QtWidgets.QPushButton) if b.text() == "Add user"][0]
    btn.click()
    assert page.table.currentRow() == 1
    page.handle_edits["discord"].setText("new_user")
    page.handle_edits["discord"].textEdited.emit("new_user")
    assert page.table.item(1, m._COL_DISCORD).text() == "new_user"
