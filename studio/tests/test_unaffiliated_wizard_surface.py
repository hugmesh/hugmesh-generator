"""The unaffiliated desktop wizard must not offer platform machinery.

Operator report: "unaffiliated desktop image wizard still shows options like mesh
services and branding and login when it shouldn't".

``standalone-unaffiliated`` builds a plain Gentoo desktop with ZERO HugMesh
affiliation. ``ImageConfig._check_unaffiliated_conflicts()`` already HARD-ERRORS on
every one of those fields — brand identity, branding assets, tailscale, sso — so the
wizard was showing choices whose only possible outcomes were "leave it alone" or
"break the build". Two surfaces were still visible:

  * the BrandingPage — shown greyed, with an apology note, and still requiring a
    click through Next. Now skipped outright via ``applies_to``.
  * the NetworkPage's "Optional cluster services" picker — fully enabled, with an
    orange note admitting the values are "accepted but IGNORED". Now hidden for this
    role (other client-class roles keep the note: their flags really are parsed, and
    a branded desktop can be re-rolled as a node).

The load-bearing property of skipping a page in this wizard is that it must be
EMISSION-NEUTRAL (``StudioWizard.nextId``: applies_to may return False "ONLY when
every config field the page emits is already at the mode-correct default"). Skipping
BrandingPage would have BROKEN that on its own — the page's own ``validatePage``
was what blanked stale branding, and a skipped page never validates. So RolePage now
blanks those fields when the role is committed, and the tests below pin exactly that.
"""
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

pytest.importorskip("hugmesh_studio.gui.qt",
                    reason="no Qt binding (PySide6/PyQt6) installed")

from hugmesh_studio.core.config import ImageConfig, UNAFFILIATED_ROLE   # noqa: E402
from hugmesh_studio.core.platform_info import HostInfo                  # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod                     # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                             # noqa: E402
from hugmesh_studio.gui.pages.branding import BrandingPage              # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage                # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")


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
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _unaff_cfg(**kw):
    base = dict(mode="standalone", platform="x86", role=UNAFFILIATED_ROLE)
    base.update(kw)
    return ImageConfig(**base)


def _branded_cfg(**kw):
    base = dict(mode="standalone", platform="x86", role="standalone-thick")
    base.update(kw)
    return ImageConfig(**base)


def _page(wiz, cls):
    return wiz.page([i for i in wiz.pageIds() if isinstance(wiz.page(i), cls)][0])


# ── the BrandingPage disappears (branding + web-login theme with it) ──────────────────
def test_branding_page_is_skipped_for_the_unaffiliated_role(wiz):
    page = _page(wiz, BrandingPage)
    assert page.applies_to(_unaff_cfg()) is False, (
        "the unaffiliated role hard-conflicts on every branding field — the page can "
        "only render greyed, so it must not be part of the flow at all")


def test_branding_page_is_skipped_for_the_composable_unaffiliated_flag(wiz):
    """--unaffiliated (G22) reaches the same builder posture from any x86 client role,
    so the page must vanish for it too — not just for the dedicated role id."""
    page = _page(wiz, BrandingPage)
    assert page.applies_to(_branded_cfg(unaffiliated=True)) is False


def test_branding_page_still_applies_to_a_branded_desktop(wiz):
    """The mutation guard: a rule that hid the page from EVERYONE would also pass the
    two assertions above."""
    page = _page(wiz, BrandingPage)
    assert page.applies_to(_branded_cfg()) is True


def test_the_wizard_flow_really_omits_the_branding_page(wiz):
    """applies_to is only a promise; nextId() is what the operator walks. Pin the real
    traversal so a change to the skip machinery cannot silently re-introduce the page."""
    wiz.cfg = _unaff_cfg()
    branding_id = [i for i in wiz.pageIds() if isinstance(wiz.page(i), BrandingPage)][0]
    role_id = wiz._page_ids["role"]
    wiz.setStartId(role_id)
    wiz.restart()
    wiz.setStartId(-1)
    seen, guard = [], 0
    while wiz.currentId() != -1 and guard < 40:
        seen.append(wiz.currentId())
        if not wiz.currentPage().validatePage():
            break
        nxt = wiz.currentPage().nextId() if hasattr(wiz.currentPage(), "nextId") else None
        nxt = wiz.nextId()
        if nxt == -1:
            break
        wiz.setStartId(nxt); wiz.restart(); wiz.setStartId(-1)
        guard += 1
    assert branding_id not in seen, "the branding page is still reachable in the flow"


# ── RolePage blanks branding, which is what makes the skip legal ──────────────────────
def test_committing_the_unaffiliated_role_blanks_every_branding_field(wiz):
    """Without this the skip would REGRESS: BrandingPage.validatePage used to be what
    cleared stale branding, and a skipped page never validates — so an operator who
    set a theme and then switched to unaffiliated would carry it into a ValueError."""
    from hugmesh_studio.gui.pages.role import RolePage
    page = _page(wiz, RolePage)
    wiz.cfg = _unaff_cfg(theme="dark", wallpaper="/tmp/w.png",
                         grub_theme="/tmp/g", accent_color="#ff0000",
                         brand_logo="/tmp/l.png", brand_locked=True)
    page.initializePage()
    page.validatePage()
    c = wiz.cfg
    for field in ("theme", "branding_dir", "wallpaper", "grub_background",
                  "grub_theme", "login_background", "brand_logo",
                  "accent_color", "color_scheme"):
        assert getattr(c, field) == "", f"{field} survived the unaffiliated role commit"
    assert c.brand_locked is False
    # and the whole point: the config must now be emittable rather than a hard error.
    c.to_cli_args()


def test_a_branded_role_keeps_its_branding(wiz):
    """Mutation guard for the blanking above — a clear that ran unconditionally would
    silently wipe every branded desktop's theme."""
    from hugmesh_studio.gui.pages.role import RolePage
    page = _page(wiz, RolePage)
    wiz.cfg = _branded_cfg(theme="dark")
    page.initializePage()
    page.validatePage()
    assert wiz.cfg.theme == "dark"


# ── the NetworkPage's cluster-services picker ────────────────────────────────────────
def _shown_net(wiz, cfg):
    pid = [i for i in wiz.pageIds() if isinstance(wiz.page(i), NetworkPage)][0]
    wiz.cfg = cfg
    wiz.setStartId(pid)
    wiz.restart()                      # fires initializePage() with cfg in place
    wiz.setStartId(-1)
    QtWidgets.QApplication.processEvents()
    page = wiz.page(pid)
    assert wiz.currentPage() is page   # non-current pages report everything invisible
    return page


def test_cluster_services_are_hidden_on_an_unaffiliated_image(wiz):
    page = _shown_net(wiz, _unaff_cfg())
    assert not page.services_box.isVisible(), (
        "the optional cluster-services picker is platform machinery — the role exists "
        "to bake none of it")
    assert not page.services_role_note.isVisible(), (
        "the 'accepted but IGNORED' note is redundant once the box is gone")


def test_hiding_the_services_box_leaves_the_emission_neutral(wiz):
    """Hiding a control must never change what gets built."""
    page = _shown_net(wiz, _unaff_cfg())
    page.validatePage()
    argv = wiz.cfg.to_cli_args()
    assert "--optional-services" not in argv, (
        f"a hidden picker still emitted a service selection: {argv}")


def test_a_branded_desktop_still_sees_the_services_box_and_its_note(wiz):
    """Mutation guard: the other client-class roles keep BOTH the picker and the
    honesty note — their flags are genuinely parsed, and a branded desktop can be
    re-rolled as a node later."""
    page = _shown_net(wiz, _branded_cfg())
    assert page.services_box.isVisible()
    assert page.services_role_note.isVisible()
