"""The GUI's door to ISSUING HugMesh tokens (gui/mesh_token_issue_dialog.py), reached
from the tray's mesh section and the Local mesh page.

Operator ask (2026-11-04): "make sure locally created mesh can also generate tokens
through both the web ui and the gui/tui/cli on all platforms". The core it drives is
tested in test_mesh_token_issue.py; here: the role gates shell access, Mint is only
offered when a headscale container is running (the headscale user is optional: the
placeholder shows the default its labels name, else hugmesh), Issue checks every field
before it creates or mints anything, and the token, the issuer fingerprint and the
sentence about sending the fingerprint separately are what the operator sees.

Headless (QT_QPA_PLATFORM=offscreen). Docker is never run: the container probe and
the mint are monkeypatched. One test signs for real with ssh-keygen (skipped when
absent, like test_mesh_token.py).
"""
from __future__ import annotations

import os
import time

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core import mesh_token as mt                     # noqa: E402
from hugmesh_studio.gui import mesh_token_issue_dialog as dmod        # noqa: E402
from hugmesh_studio.gui import tray as tray_mod                       # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                           # noqa: E402

from test_localmesh_saved_meshes import page, qapp  # noqa: E402,F401 — fixtures by name

GENERATOR_DIR = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
PASTED = "hskey-auth-pasted-0123456789abcdef"
MINTED = "hskey-auth-minted-0123456789abcdef"
FP = "SHA256:fakefingerprint"

try:
    KEYGEN = mt.ssh_keygen()
except mt.TokenError:
    KEYGEN = None


def _no_container():
    raise mt.TokenError("tool", "No running headscale container was found (docker ps "
                                "--filter name=headscale listed none).")


def _settle(qapp, dlg, timeout_s=30.0):
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        busy = False
        for n in ("_probe", "_job"):
            t = getattr(dlg, n, None)
            if t is not None:
                t.wait(100)
                busy = True
        qapp.processEvents()
        if not busy:
            return
    pytest.fail("the dialog's background work did not finish")


LABELS = {"user": "members", "key_tags": ("tag:hugmesh",)}


def _dialog(qapp, monkeypatch, container=None, labels=None, **prefill):
    monkeypatch.setattr(mt, "find_headscale_container",
                        (lambda runner=None: container) if container else _no_container)
    # docker inspect is never run: the labels of whichever container is asked about
    monkeypatch.setattr(mt, "headscale_labels",
                        lambda name, runner=None: dict(labels or {}))
    dlg = dmod.IssueTokenDialog(**prefill)
    _settle(qapp, dlg)
    return dlg


def _fill(dlg, role="admin", shell=True):
    dlg.mesh.setCurrentText("west")
    dlg.domain.setText("example.org")
    dlg.role.setCurrentText(role)
    dlg.shell.setChecked(shell)
    dlg.login_server.setText("https://hs.example.org")


def _fake_token(kw) -> str:
    """A token parse() accepts, built from the arguments issue() was called with (the
    signature is not checked by parse, and these tests never verify it)."""
    now = int(time.time())
    g = mt.MeshGrant(mesh=kw["mesh"], domain=kw["domain"], role=kw["role"],
                     shell=kw["shell"], login_server=kw["login_server"],
                     auth_key=kw["auth_key"], expires=now + kw["lifetime_s"], issued=now,
                     issuer="ssh-ed25519 AAAA", id="00")
    body = mt._canonical(mt._payload(g))
    return f"{mt.FORMAT}.{mt._b64u(body)}.{mt._b64u(b'sig')}"


@pytest.fixture
def core(monkeypatch):
    """ensure_issuer / mint / issue faked; records the order and the arguments."""
    seen = {"order": [], "issue": None, "mint": None}

    def ensure(mesh, **_k):
        seen["order"].append(("ensure", mesh))
        return "/fake/issuer_ed25519", "ssh-ed25519 AAAA", FP

    def check(key_path, **_k):
        seen["order"].append(("check", key_path))

    def mint(**kw):
        seen["order"].append(("mint", kw["user"]))
        seen["mint"] = {k: kw[k] for k in ("user", "lifetime_s", "container")}
        seen["tags"] = kw["tags"]
        return MINTED

    def issue(**kw):
        seen["order"].append(("issue", kw["mesh"]))
        seen["issue"] = kw
        return _fake_token(kw)

    monkeypatch.setattr(mt, "ensure_issuer", ensure)
    monkeypatch.setattr(mt, "check_signing", check)
    monkeypatch.setattr(mt, "mint_preauth_key", mint)
    monkeypatch.setattr(mt, "issue", issue)
    return seen


# ── field gating ─────────────────────────────────────────────────────────────────
def test_shell_access_is_only_offered_to_admin_and_superadmin(qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch)
    for role in mt.ROLES:
        dlg.role.setCurrentText("admin")
        dlg.shell.setChecked(True)
        dlg.role.setCurrentText(role)
        if role in mt.SHELL_ROLES:
            assert dlg.shell.isEnabled() and dlg.shell.isChecked()
        else:
            assert not dlg.shell.isEnabled() and not dlg.shell.isChecked(), role
            assert dlg.shell.toolTip() == dmod.SHELL_ONLY_TIP


def test_the_lifetime_stops_at_90_days_in_either_unit(qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch)
    assert dlg.lifetime_s() == 7 * 86400
    assert dlg.lifetime.maximum() == 90
    dlg.unit.setCurrentText("hours")
    assert dlg.lifetime.maximum() == 90 * 24
    dlg.lifetime.setValue(10_000)
    assert dlg.lifetime_s() == mt.MAX_LIFETIME_S


def test_the_pre_auth_key_field_hides_what_is_typed(qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch)
    assert dlg.auth_key.echoMode() == QtWidgets.QLineEdit.EchoMode.Password


def test_mint_is_disabled_with_the_reason_when_no_headscale_runs(qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch)
    assert not dlg.mint_radio.isEnabled()
    assert dlg.paste_radio.isChecked()
    assert "No running headscale container was found" in dlg.mint_radio.toolTip()


def test_mint_names_the_container_it_found(qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch, container="hugmesh-headscale")
    assert "hugmesh-headscale" in dlg.mint_radio.text()
    assert dlg.container.currentText() == "hugmesh-headscale"
    assert dlg.hs_user.text() == "" and dlg.mint_radio.isEnabled()


def test_mint_is_offered_with_no_user_typed_and_mints_for_the_labels_user(
        qapp, monkeypatch, core):
    """The headscale user is optional: the placeholder shows the user the found
    container's label names, and an empty field mints for it, with the label's tags."""
    dlg = _dialog(qapp, monkeypatch, container="hs", labels=LABELS)
    assert dlg.hs_user.text() == "" and dlg.hs_user.isEnabled()
    assert dlg.hs_user.placeholderText() == "default: members (from hs's label)"
    assert mt.NAME_MINT_USER in dlg.hs_user.toolTip() == (
        "The headscale user the minted key is for; leave it empty for the default. "
        + dmod.DEFAULT_USER_TIP)
    assert dlg.mint_radio.isEnabled()
    assert "the headscale user members (from hs's label)" in dlg.mint_radio.toolTip()
    _fill(dlg)
    dlg.mint_radio.setChecked(True)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert core["mint"]["user"] == "members" and core["tags"] == ("tag:hugmesh",)
    assert ("minted in hs for the headscale user members, asking for tag:hugmesh"
            in dlg.status.text())


def test_without_labels_an_empty_user_mints_for_hugmesh(qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch, container="hs")
    assert dlg.hs_user.placeholderText().startswith(f"default: {mt.DEFAULT_MINT_USER},")
    assert dlg.mint_radio.isEnabled()
    _fill(dlg)
    dlg.mint_radio.setChecked(True)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert core["mint"]["user"] == "hugmesh" and core["tags"] == ()
    assert "for the headscale user hugmesh:" in dlg.status.text()


def test_the_placeholder_names_the_label_only_for_the_container_it_came_from(
        qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch, container="hs", labels=LABELS)
    dlg.container.setCurrentText("other-hs")
    assert dlg.hs_user.placeholderText().startswith(f"default: {mt.DEFAULT_MINT_USER},")
    dlg.container.setCurrentText("hs")
    assert "members" in dlg.hs_user.placeholderText()


def test_a_typed_user_wins_over_the_labels(qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch, container="hs", labels=LABELS)
    _fill(dlg)
    dlg.hs_user.setText("ops")
    assert "the headscale user ops" in dlg.mint_radio.toolTip()
    dlg.mint_radio.setChecked(True)
    dlg.hs_user.setText("bad user")
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert "is not a headscale user name" in dlg.status.text() and core["order"] == []
    dlg.hs_user.setText("ops")
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    # the key-tags label is the label user's (members), never forced on another user
    assert core["mint"]["user"] == "ops" and core["tags"] == ()


def test_several_containers_are_offered_to_pick_from(qapp, monkeypatch, core):
    """"Name the one to mint the key in" is something the dialog lets you do."""
    def several(runner=None):
        raise mt.TokenError("tool", "Several running containers match headscale (a-hs, "
                                    "b-hs). Name the one to mint the key in.",
                            choices=("a-hs", "b-hs"))
    monkeypatch.setattr(mt, "find_headscale_container", several)
    dlg = dmod.IssueTokenDialog()
    _settle(qapp, dlg)
    assert [dlg.container.itemText(i) for i in range(dlg.container.count())] == \
        ["a-hs", "b-hs"]
    assert dlg.container.currentText() == ""
    assert not dlg.mint_radio.isEnabled()
    assert "Name the one to mint the key in" in dlg.mint_radio.toolTip()
    dlg.hs_user.setText("joiners")
    dlg.container.setCurrentText("b-hs")
    assert dlg.mint_radio.isEnabled() and "b-hs" in dlg.mint_radio.text()
    _fill(dlg)
    dlg.mint_radio.setChecked(True)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert core["mint"]["container"] == "b-hs"


def test_with_no_container_found_typing_its_name_offers_mint(qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch)
    dlg.hs_user.setText("joiners")
    assert dlg.mint_radio.toolTip().startswith("Unavailable: No running headscale")
    assert not dlg.mint_radio.isEnabled()
    dlg.container.setCurrentText("hs")
    assert dlg.mint_radio.isEnabled()
    dlg.container.setCurrentText("")
    assert not dlg.mint_radio.isEnabled()
    dlg.container.setCurrentText("--privileged")
    _fill(dlg)
    dlg.mint_radio.setChecked(True)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert "is not a container name" in dlg.status.text() and core["order"] == []


def test_prefill_lands_in_the_fields(qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch, mesh="west", domain="example.org",
                  login_server="https://hs.example.org")
    assert dlg.mesh.currentText() == "west"
    assert dlg.domain.text() == "example.org"
    assert dlg.login_server.text() == "https://hs.example.org"


# ── issuing ──────────────────────────────────────────────────────────────────────
def test_issue_with_a_pasted_key_shows_the_token_and_the_fingerprint(qapp, monkeypatch,
                                                                       core):
    dlg = _dialog(qapp, monkeypatch)
    _fill(dlg)
    dlg.auth_key.setText(PASTED)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    kw = core["issue"]
    assert kw["auth_key"] == PASTED and kw["interactive"] is False
    assert kw["key_path"] == "/fake/issuer_ed25519"
    assert (kw["mesh"], kw["domain"], kw["role"], kw["shell"]) == (
        "west", "example.org", "admin", True)
    assert kw["lifetime_s"] == 7 * 86400
    assert core["order"] == [("ensure", "west"), ("issue", "west")]
    assert dlg.token().startswith(f"{mt.FORMAT}.")
    assert mt.parse(dlg.token())[0].auth_key == PASTED
    assert FP in dlg.fingerprint.text()
    assert dmod.FINGERPRINT_NOTE in dlg.fingerprint.text()
    assert dlg.status.text().startswith("Issued: admin in example.org (mesh west), "
                                        "accepts SSH from the mesh")
    assert dlg.copy_btn.isEnabled()
    assert dlg.auth_key.text() == ""          # single-use: it is in the token now
    assert PASTED not in dlg.status.text() + dlg.fingerprint.text()


def test_copy_puts_the_token_on_the_clipboard(qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch)
    _fill(dlg)
    dlg.auth_key.setText(PASTED)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    dlg.copy_btn.click()
    assert QtWidgets.QApplication.clipboard().text() == dlg.token()
    assert dlg.status.text().endswith("Copied to the clipboard.")


def test_issue_with_mint_checks_the_issuer_signs_then_mints_for_the_named_user(
        qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch, container="hugmesh-headscale")
    _fill(dlg, role="mod", shell=False)
    dlg.unit.setCurrentText("hours")
    dlg.lifetime.setValue(12)
    dlg.hs_user.setText("joiners")
    dlg.mint_radio.setChecked(True)
    assert not dlg.auth_key.isEnabled()
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert core["order"] == [("ensure", "west"), ("check", "/fake/issuer_ed25519"),
                             ("mint", "joiners"), ("issue", "west")]
    assert core["mint"] == {"user": "joiners", "lifetime_s": 12 * 3600,
                            "container": "hugmesh-headscale"}
    assert core["issue"]["auth_key"] == MINTED and core["issue"]["shell"] is False
    assert core["issue"]["interactive"] is False
    assert "minted in hugmesh-headscale for the headscale user joiners" in dlg.status.text()
    assert dlg.status.text().endswith(mt.SERVER_DECIDES)
    assert "tags" not in dlg.status.text()
    assert MINTED not in dlg.status.text()


def test_a_named_headscale_user_is_the_one_minted_for(qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch, container="hs")
    _fill(dlg)
    dlg.hs_user.setText("ops")
    dlg.mint_radio.setChecked(True)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert core["mint"]["user"] == "ops"


def test_a_bad_field_is_refused_before_anything_is_created_or_minted(
        qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch, container="hs")
    _fill(dlg)
    dlg.login_server.setText("https://hs.elsewhere.org")
    dlg.hs_user.setText("joiners")
    dlg.mint_radio.setChecked(True)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert core["order"] == []
    assert "outside its access domain example.org" in dlg.status.text()
    assert dlg.token() == "" and not dlg.copy_btn.isEnabled()


def test_no_key_and_no_mint_says_what_to_do(qapp, monkeypatch, core):
    dlg = _dialog(qapp, monkeypatch)
    _fill(dlg)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert core["order"] == []
    assert dlg.status.text() == dmod.NO_KEY


def test_a_core_failure_shows_its_sentence(qapp, monkeypatch, core):
    def broken(**kw):
        raise mt.TokenError("signature", "ssh-keygen could not sign the token: boom")
    monkeypatch.setattr(mt, "issue", broken)
    dlg = _dialog(qapp, monkeypatch)
    _fill(dlg)
    dlg.auth_key.setText(PASTED)
    dlg.issue_btn.click()
    _settle(qapp, dlg)
    assert dlg.status.text() == "ssh-keygen could not sign the token: boom"
    assert dlg.issue_btn.isEnabled() and not dlg.copy_btn.isEnabled()
    assert dlg.auth_key.text() == PASTED      # nothing issued: the key is kept


@pytest.mark.skipif(KEYGEN is None, reason="no OpenSSH ssh-keygen")
def test_a_real_studio_issuer_signs_a_token_this_computer_accepts(qapp, monkeypatch):
    dlg = _dialog(qapp, monkeypatch)
    _fill(dlg)
    dlg.auth_key.setText(PASTED)
    dlg.issue_btn.click()
    _settle(qapp, dlg, timeout_s=120)
    g = mt.verify(dlg.token())              # trusted: the issuer key was created now
    assert (g.mesh, g.role, g.shell, g.auth_key) == ("west", "admin", True, PASTED)
    assert mt.fingerprint(g.issuer) in dlg.fingerprint.text()
    assert "created now; this computer trusts it" in dlg.fingerprint.text()
    assert dmod.known_meshes() == ["west"]


# ── where it is reached from ─────────────────────────────────────────────────────
def test_the_tray_mesh_section_offers_issuing(qapp, monkeypatch):
    monkeypatch.setattr(mt, "load_grant", lambda: None)
    tray = tray_mod.build_tray(GENERATOR_DIR, show_mesh=True, show_stack=False,
                               builds_provider=lambda: [])
    texts = [a.text() for a in tray.contextMenu().actions()]
    assert tray_mod.ISSUE_TOKEN_LABEL in texts
    assert texts.index(tray_mod.ISSUE_TOKEN_LABEL) == texts.index(tray_mod.TOKEN_LABEL) + 1


def test_the_local_mesh_page_opens_it_prefilled(page, monkeypatch):
    page.boot_login_server.setText("https://hs.hugmesh.net")
    want = {"mesh": "hugmesh", "domain": page._own_domain_name(),
            "login_server": "https://hs.hugmesh.net"}
    assert page.issue_token_prefill() == want
    opened = []
    monkeypatch.setattr(mt, "find_headscale_container", _no_container)
    monkeypatch.setattr(dmod.IssueTokenDialog, "exec",
                        lambda self: opened.append(
                            (self.mesh.currentText(), self.domain.text(),
                             self.login_server.text())) or 0)
    page.issue_token_btn.click()
    assert opened == [(want["mesh"], want["domain"], want["login_server"])]
    _settle(QtWidgets.QApplication.instance(), page._issue_token_dialog)
