"""The standalone login password: typed twice, required, and refused INLINE.

Operator report (2026-10-30, standalone-thick x86, unaffiliated): "I wasn't able to use
the password I entered in the gui to login to the gentoo standalone image". The image
lost it at first boot (specs/etc/local.d/01-firstboot.start.tmpl and
specs/usr/sbin/hugmesh-home-setup — guarded by
tests/scripts/test-standalone-login-firstboot.sh). The wizard had two holes of its own,
pinned here:

  * a single masked "Local Password" entry: a typo is baked into the image silently;
  * a standalone image built with NO password: its first boot mints a random one-time
    password whose banner nobody sees on a graphical desktop, root is locked, and there
    is no KEYS stick or SSO — an image nobody can log in to.

HomePage refuses both with an inline label (never a modal: validatePage runs headless
here). The Qt-free rule, and BuildDriver.preflight() refusing a config that never
passed HomePage, are pinned in test_standalone_login_rule.py (which the Qt-free CI job
runs; this file needs a Qt binding).

The page is rendered offscreen and grabbed to a PNG; the geometry of the confirm row and
the refusal label is asserted, so "the field exists" cannot mean "the field is invisible".
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import UNAFFILIATED_ROLE  # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod  # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets  # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
PW = "correct horse battery"


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="session")
def qapp():
    return (QtWidgets.QApplication.instance()
            or QtWidgets.QApplication(["hugmesh-studio-tests"]))


@pytest.fixture
def wiz(qapp):
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.resize(1100, 1400)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _advance_to(wiz, page_cls):
    for _ in range(64):
        page = wiz.currentPage()
        if isinstance(page, page_cls):
            return page
        before = wiz.currentId()
        wiz.next()
        assert wiz.currentId() != before, \
            f"flow stuck on {type(page).__name__} (validatePage rejected?)"
    raise AssertionError(f"never reached {page_cls.__name__}")


def _home_on(wiz, role):
    page = _advance_to(wiz, wizard_mod.RolePage)
    assert page.select_role(role), f"role {role} not offered"
    home = _advance_to(wiz, wizard_mod.HomePage)
    assert wiz.cfg.mode == "standalone" and wiz.cfg.role == role
    return home


def _visible_box(widget, page):
    """The widget is shown AND laid out with a real size inside the page."""
    assert widget.isVisibleTo(page), f"{widget!r} is hidden"
    r = widget.geometry()
    assert r.width() > 20 and r.height() > 5, f"{widget!r} has no geometry: {r}"
    return widget.mapTo(page, r.topLeft())


# ── HomePage ──────────────────────────────────────────────────────────────────

@pytest.mark.parametrize("role", ["standalone-thick", UNAFFILIATED_ROLE])
def test_standalone_without_password_is_refused_inline(wiz, role):
    home = _home_on(wiz, role)
    QtWidgets.QApplication.processEvents()
    home.local_pass.setText("")
    home.local_pass_confirm.setText("")
    before = wiz.currentId()
    wiz.next()
    assert wiz.currentId() == before, "advanced past HomePage with no login password"
    assert home.login_err.isVisibleTo(home)
    assert "Login Password" in home.login_err.text()
    assert wiz.cfg.local_pass == ""


def test_mismatched_confirmation_is_refused_and_nothing_collected(wiz):
    home = _home_on(wiz, UNAFFILIATED_ROLE)
    home.local_pass.setText(PW)
    home.local_pass_confirm.setText(PW + "x")
    assert home.validatePage() is False
    assert "do not match" in home.login_err.text()
    assert home.login_err.isVisibleTo(home)
    assert wiz.cfg.local_pass == ""


def test_matching_password_is_collected_and_reaches_the_argv(wiz):
    home = _home_on(wiz, UNAFFILIATED_ROLE)
    home.local_user.setText("magus")
    home.local_pass.setText(PW)
    home.local_pass_confirm.setText(PW)
    assert home.validatePage() is True
    assert not home.login_err.isVisibleTo(home)
    c = wiz.cfg
    assert c.local_user == "magus" and c.local_pass == PW
    args = c.to_cli_args()
    pairs = list(zip(args, args[1:]))
    assert ("--local-user", "magus") in pairs
    assert ("--local-pass", PW) in pairs


def test_show_password_toggles_both_fields(wiz):
    home = _home_on(wiz, "standalone-thick")
    pw_mode = QtWidgets.QLineEdit.EchoMode.Password
    assert home.local_pass.echoMode() == pw_mode
    assert home.local_pass_confirm.echoMode() == pw_mode
    home.show_pass.setChecked(True)
    assert home.local_pass.echoMode() == QtWidgets.QLineEdit.EchoMode.Normal
    assert home.local_pass_confirm.echoMode() == QtWidgets.QLineEdit.EchoMode.Normal
    home.show_pass.setChecked(False)
    assert home.local_pass.echoMode() == pw_mode


def test_rendered_login_group_shows_confirm_row_and_refusal(wiz, tmp_path):
    """Render the page and assert what a person would see: the password row, the
    confirm row under it, the reveal toggle and the red refusal, all inside the
    'Your Login' group, in that order, with real size."""
    home = _home_on(wiz, UNAFFILIATED_ROLE)
    home.local_pass.setText(PW)
    home.local_pass_confirm.setText("typo")
    assert home.validatePage() is False
    QtWidgets.QApplication.processEvents()
    login = home.login
    p_pass = _visible_box(home.local_pass, login)
    p_conf = _visible_box(home.local_pass_confirm_row, login)
    p_show = _visible_box(home.show_pass, login)
    p_err = _visible_box(home.login_err, login)
    assert p_pass.y() < p_conf.y() < p_show.y() < p_err.y()
    for w in (home.local_pass_confirm_row, home.login_err):
        top = w.mapTo(login, w.rect().topLeft())
        assert login.rect().contains(top), f"{w!r} drawn outside the login group"
    png = os.environ.get("HUGMESH_TEST_PNG_OUT") or str(tmp_path / "home-login.png")
    assert login.grab().save(png), "could not render the login group"
    assert os.path.getsize(png) > 1000
