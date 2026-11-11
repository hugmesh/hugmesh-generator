"""GUI-20: the Network, Home and System steps refuse a malformed value on NEXT, inline,
on the field it was typed into — driven against the REAL wizard, offscreen.

Measured on main before the fix (offscreen walker, 1200x800), each of these passed
Next and was refused later, at Review, and sometimes worded against a different field:

* Network "Public Apex Domain" = 'not a domain!'. On a mesh this was refused nine pages
  later, as "Cannot assemble this build: invalid domain: 'not a domain!'".
* Network "Tailscale Root Domain" = 'Bad Root!' (mesh), and "Games Domain" = 'games!'
  (cloud). Both failed the same way, at Review.
* Network "Egress VPN" = 'garbage endpoint'. This was caught only in Review's bottom
  preflight pane.
* Home "Local User" = 'Bad User', refused at Review as "invalid local_user".
* System "Default user" = 'Root User', refused at Review as "invalid local_user". That
  is the Home step's field.

Each refusal is a red label under the field, naming the caption. There is never a
modal: validatePage runs headless, and a QMessageBox there hangs the run. The label is
brought into the page's viewport, and the section that holds it is opened. A value the
operator cannot see (a hidden row, or a field this flow does not emit) is never
refused. The check runs AFTER the page's whole collect, so a collect_all() that ignores
the answer still collects every other field.
"""
import os

import pytest

# must be set BEFORE the first QApplication is created
os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.platform_info import HostInfo   # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod      # noqa: E402
from hugmesh_studio.gui.qt import QtCore, QtWidgets      # noqa: E402

from _helpers import (   # noqa: E402
    advance_to, check_worklist_rows, pick_mode, pick_role, type_login_password,
)

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(autouse=True)
def modals(monkeypatch):
    """Every QMessageBox entry point is a recorder: a refusal here must never be one."""
    seen = []
    for name in ("exec", "exec_", "information", "warning", "critical", "question"):
        if hasattr(QtWidgets.QMessageBox, name):
            monkeypatch.setattr(QtWidgets.QMessageBox, name,
                                lambda *a, _n=name, **k: seen.append(_n) or 0)
    yield seen
    assert seen == [], f"a refusal opened a modal: {seen}"


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-gui20"]))


@pytest.fixture
def wiz(qapp, monkeypatch, tmp_path):
    # a cwd where no generator-relative name exists, so "relative to the checkout" is
    # what is being tested, not "relative to wherever pytest happened to start"
    monkeypatch.chdir(tmp_path)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()          # offscreen: makes isVisible() and the scroll geometry meaningful
    yield w
    w.close()
    w.deleteLater()


def _scroll_to_bottom(page):
    """Put the operator where Next is easiest to reach after filling the page: at the
    bottom. A refusal under a field at the top must still be seen from there."""
    QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.LayoutRequest)
    sb = page._content_scroll.verticalScrollBar()
    sb.setValue(sb.maximum())
    return sb.maximum()


def _scroll_to_top(page):
    QtCore.QCoreApplication.sendPostedEvents(None, QtCore.QEvent.Type.LayoutRequest)
    sb = page._content_scroll.verticalScrollBar()
    sb.setValue(0)
    assert sb.maximum() > 0, "the page no longer scrolls: viewport check is moot"


def _in_viewport(page, label) -> bool:
    """The label is on screen inside the page's scroll viewport, not just 'visible'."""
    vp = page._content_scroll.viewport()
    top_left = label.mapTo(vp, QtCore.QPoint(0, 0))
    r = QtCore.QRect(top_left, label.size())
    return label.isVisible() and label.height() > 0 and vp.rect().intersects(r)


def _refused(wiz, label, *, caption, value):
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before, f"{caption}={value!r} passed Next"
    assert label.isVisible(), f"{caption}: refused with no visible reason"
    text = label.text()
    assert text.startswith(f"{caption}: "), text
    assert repr(value) in text or value in text, text
    for internal in ("local_user", "invalid domain", "cluster_domain", "egress_vpn"):
        assert internal not in text, f"the refusal names the config field: {text}"
    return text


def _passes(wiz):
    before = wiz.currentId()
    page = wiz.currentPage()
    type_login_password(page)
    wiz.next()
    assert wiz.currentId() != before, f"{type(page).__name__} refused a valid value"


def _cloud_network(wiz):
    pick_mode(wiz, "cloud")
    pick_role(wiz, "desktop")
    return advance_to(wiz, wizard_mod.NetworkPage)


def _mesh(wiz, *ids):
    pick_mode(wiz, "mesh")
    wl = advance_to(wiz, wizard_mod.WorklistPage)
    check_worklist_rows(wl, *(ids or ("pki.x86",)))
    return wl


# ── Network: Public Apex Domain ────────────────────────────────────────────────────

def test_cloud_apex_domain_is_refused_inline_and_brought_into_view(wiz):
    net = _cloud_network(wiz)
    assert net.domain_row.isVisible() and not net.domain.isReadOnly()
    net.domain.setText("not a domain!")
    assert _scroll_to_bottom(net) > 0, "the page no longer scrolls: viewport check is moot"
    assert not _in_viewport(net, net.domain_row)
    _refused(wiz, net.domain_error, caption="Public Apex Domain", value="not a domain!")
    assert _in_viewport(net, net.domain_error), "the refusal is off screen"
    assert net.identity_section.is_expanded()
    # fixed -> through, and the label goes with it
    net.domain.setText("example.org")
    _passes(wiz)
    assert not net.domain_error.isVisible()
    assert wiz.cfg.cluster_domain == "example.org"


def test_cloud_apex_refusal_reopens_a_folded_section(wiz):
    net = _cloud_network(wiz)
    net.domain.setText("not a domain!")
    net.identity_section.set_expanded(False)
    _refused(wiz, net.domain_error, caption="Public Apex Domain", value="not a domain!")
    assert net.identity_section.is_expanded()


def test_mesh_apex_refusal_says_where_it_is_changed(wiz):
    """On a mesh the apex is a read-only mirror of the superbrand (#654). A loaded
    config can still carry a bad one, so the refusal points at the superbrand step
    instead of telling the operator to edit a field they cannot type into."""
    _mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.domain.isReadOnly()
    net.domain.setText("not a domain!")      # what a loaded/mirrored value looks like
    text = _refused(wiz, net.domain_error, caption="Public Apex Domain",
                    value="not a domain!")
    assert "Branding page" in text


def test_cloud_games_domain_is_refused_inline(wiz):
    net = _cloud_network(wiz)
    net.games_domain.setText("games!")
    _refused(wiz, net.games_domain_error, caption="Games Domain", value="games!")
    assert not net.domain_error.isVisible(), "the apex is fine: its label must stay hidden"
    net.games_domain.setText("games.example.org")
    _passes(wiz)
    assert wiz.cfg.games_domain == "games.example.org"


# ── Network: Tailscale Root Domain (mesh only — read-only and not collected in cloud) ─

def test_mesh_superdomain_is_refused_inline(wiz):
    _mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert net.superdomain_row.isVisible() and not net.superdomain.isReadOnly()
    net.superdomain.setText("Bad Root!")
    net.mesh_section.set_expanded(False)
    _scroll_to_bottom(net)
    _refused(wiz, net.superdomain_error, caption="Tailscale Root Domain",
             value="Bad Root!")
    assert net.mesh_section.is_expanded()
    assert _in_viewport(net, net.superdomain_error)
    net.superdomain.setText("acme.internal")
    _passes(wiz)
    assert wiz.cfg.superdomain == "acme.internal"


# ── Network: Egress VPN (preflight's own existence test, at the field) ─────────────

def test_cloud_missing_egress_profile_is_refused_inline(wiz, tmp_path):
    net = _cloud_network(wiz)
    assert net.egress_row.isVisible()
    net.egress.setText("garbage endpoint")
    net.egress_section.set_expanded(False)
    text = _refused(wiz, net.egress_error, caption="Egress VPN", value="garbage endpoint")
    # relative = relative to the generator checkout, said out loud
    assert os.path.join(GENERATOR_DIR, "garbage endpoint") in text
    assert net.egress_section.is_expanded()
    assert _in_viewport(net, net.egress_error)
    conf = tmp_path / "wg0.conf"
    conf.write_text("[Interface]\n")
    net.egress.setText(str(conf))
    _passes(wiz)
    assert wiz.cfg.egress_vpn == str(conf)
    assert not net.egress_error.isVisible()


def test_relative_egress_path_resolves_against_the_generator_checkout(wiz):
    """brand.conf.example ships in the checkout; the test's cwd is a tmp dir where it
    does NOT exist. Preflight finds it there, so the page must too."""
    assert not os.path.exists("brand.conf.example")
    net = _cloud_network(wiz)
    net.egress.setText("brand.conf.example")
    _passes(wiz)


def test_hidden_egress_on_a_mesh_node_is_never_refused(wiz):
    _mesh(wiz)
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.egress_row.isVisible()
    net.egress.setText("garbage endpoint")   # a stale value in a hidden widget
    _passes(wiz)
    assert wiz.cfg.egress_vpn == ""


def test_hidden_apex_on_a_standalone_x86_image_is_never_refused(wiz):
    """standalone x86 bakes no cluster plane: the rows are hidden and the field is not
    collected, so a loaded value is not this page's to refuse."""
    pick_mode(wiz, "standalone")
    net = advance_to(wiz, wizard_mod.NetworkPage)
    assert not net.domain_row.isVisible()
    wiz.cfg.cluster_domain = "not a domain!"
    net.domain.setText("not a domain!")
    _passes(wiz)


def test_cloud_superdomain_is_display_only_and_never_refused(wiz):
    """In cloud the Tailscale Root Domain is a read-only derived display, not collected
    and not emitted (--superdomain is mesh-only)."""
    net = _cloud_network(wiz)
    assert net.superdomain.isReadOnly()
    wiz.cfg.superdomain = "Bad Root!"
    _passes(wiz)


def test_network_refusal_still_collects_the_rest_of_the_page(wiz):
    """collect_all() re-runs validatePage and ignores its answer (Review, save): the
    check must come after the collect, or one bad field drops every later one."""
    net = _cloud_network(wiz)
    net.domain.setText("not a domain!")
    net.proxy_stack.setCurrentText("on")
    net.snort.setChecked(not net.snort.isChecked())
    want_snort = net.snort.isChecked()
    assert net.validatePage() is False
    assert wiz.cfg.proxy_stack == "on" and wiz.cfg.snort is want_snort


_NETWORK_REFUSALS = ("domain_error", "games_domain_error", "superdomain_error",
                     "egress_error")


@pytest.mark.parametrize("flow", ["cloud", "mesh", "standalone"])
def test_untouched_defaults_pass_every_network_flow(wiz, flow):
    """Control: nothing typed, nothing refused, no refusal label left on screen."""
    if flow == "cloud":
        net = _cloud_network(wiz)
    elif flow == "mesh":
        _mesh(wiz)
        net = advance_to(wiz, wizard_mod.NetworkPage)
    else:
        pick_mode(wiz, flow)
        net = advance_to(wiz, wizard_mod.NetworkPage)
    _passes(wiz)
    for name in _NETWORK_REFUSALS:
        label = net.findChild(QtWidgets.QLabel, name)
        assert label is not None, name
        assert label.isHidden(), f"{flow}: {name} shown on untouched defaults"


# ── System: Default user ───────────────────────────────────────────────────────────

def test_mesh_default_user_is_refused_inline_naming_default_user(wiz):
    _mesh(wiz)
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.user_row.isVisible()
    sysp.user.setText("Root User")
    _refused(wiz, sysp.user_error, caption="Default user", value="Root User")
    assert not sysp.hostname_error.isVisible(), "refused on the wrong field's label"
    sysp.user.setText("rootuser")
    _passes(wiz)
    assert not sysp.user_error.isVisible()
    assert wiz.cfg.user == "rootuser"


def test_hidden_default_user_is_never_refused(wiz):
    """standalone x86: --local-user carries the account, the row is hidden and -u is
    cleared — a stale value in the hidden widget must not block Next."""
    pick_mode(wiz, "standalone")
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert not sysp.user_row.isVisible()
    sysp.user.setText("Root User")
    _passes(wiz)
    assert wiz.cfg.user == ""


def test_system_refusal_still_collects_the_rest_of_the_page(wiz):
    """The node fallback credentials are collected AFTER -u on this page: a refusal
    that returned early would drop them from a collect_all()."""
    _mesh(wiz)
    sysp = advance_to(wiz, wizard_mod.SystemPage)
    assert sysp.creds.isVisible()
    sysp.user.setText("Root User")
    sysp.creds_optin.setChecked(True)
    sysp.user_password.setText("node-fallback-pw")
    assert sysp.validatePage() is False
    assert wiz.cfg.user_password == "node-fallback-pw"


# ── Home: Local User ───────────────────────────────────────────────────────────────

def test_standalone_local_user_is_refused_inline(wiz):
    pick_mode(wiz, "standalone")
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.local_user.isVisible()
    home.local_user.setText("Bad User")
    type_login_password(home)
    # The label sits under the login group, below the fold when the page is at its top
    # (measured offscreen: viewport 624 px, label at y~796). Start there.
    _scroll_to_top(home)
    _refused(wiz, home.login_err, caption="Local User", value="Bad User")
    assert _in_viewport(home, home.login_err), "the refusal is off screen"
    home.local_user.setText("walker")
    _passes(wiz)
    assert wiz.cfg.local_user == "walker"
    assert not home.login_err.isVisible()


def test_cloud_local_user_is_refused_inline(wiz):
    pick_mode(wiz, "cloud")
    pick_role(wiz, "desktop")
    home = advance_to(wiz, wizard_mod.HomePage)
    assert home.local_user.isVisible()
    home.local_user.setText("Bad User")
    _refused(wiz, home.login_err, caption="Local User", value="Bad User")


def test_hidden_login_group_on_a_mesh_node_is_not_refused(wiz):
    """Deliberate limit: on a mesh node flow the whole login group is hidden
    (local_login_applies), so there is no field to fix and a refusal here would be a
    Next nobody can satisfy. Only a loaded config can put a bad value there; Review's
    assembly error remains its backstop."""
    _mesh(wiz)
    home = advance_to(wiz, wizard_mod.HomePage)
    assert not home.local_user.isVisible()
    home.local_user.setText("Bad User")
    _passes(wiz)
    assert not home.login_err.isVisible()


def test_password_refusals_still_win_first(wiz):
    """The existing mismatch refusal is untouched and still answers first."""
    pick_mode(wiz, "standalone")
    home = advance_to(wiz, wizard_mod.HomePage)
    home.local_user.setText("Bad User")
    home.local_pass.setText("one-password")
    home.local_pass_confirm.setText("another-password")
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before
    assert "do not match" in home.login_err.text()
