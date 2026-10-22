"""Orange Pi cluster NODE roles carry the mesh's cluster choices (EXPERIMENTAL boards).

The 2026-10-21 skeptic: Studio sent --release-state / --idp / --optional-services to x86
and rpi5 only, so an Orange Pi pki or omnibus node silently baked the builder defaults
(Casdoor, internal, akkoma tuwunel phpbb) while the Pi nodes of the same mesh baked what
the mesh chose. These tests pin that an Orange Pi NODE row now emits the same choices,
that the Orange Pi DESKTOP still emits none (its builder refuses them), that the two
host-daemon slugs the Orange Pi node image does not carry (tor, egress-vpn) are neither
offered nor emitted there, and that the Network page shows the controls on a node row.
"""
import os

import pytest

from hugmesh_studio.core.config import (
    OPTIONAL_SERVICES_BY_PLATFORM, ImageConfig, field_in_scope, strip_platform_unsupported,
)

CHOICES = dict(idp="oidc", idp_issuer="https://id.mesh.example", idp_client_id="hugmesh",
               release_state="public", optional_services=["owncast"],
               vault_addr="https://vault.mesh.example:8200")


@pytest.mark.parametrize("platform,role,ram", [("orangepi5", "pki", "8"),
                                               ("orangepi5", "omnibus", "16"),
                                               ("orangepi4-lts", "frontend", "4")])
def test_node_row_emits_the_mesh_cluster_choices(platform, role, ram):
    args = ImageConfig(mode="mesh", platform=platform, role=role, ram_gb=ram,
                       **CHOICES).to_cli_args()
    for pair in (("--release-state", "public"), ("--optional-services", "owncast"),
                 ("--idp", "oidc"), ("--idp-issuer", "https://id.mesh.example"),
                 ("--idp-client-id", "hugmesh"),
                 ("--vault-addr", "https://vault.mesh.example:8200")):
        i = args.index(pair[0])
        assert args[i + 1] == pair[1], (pair, args)


@pytest.mark.parametrize("platform", ["orangepi5", "orangepi4-lts"])
def test_desktop_row_emits_none_of_them(platform):
    args = ImageConfig(mode="mesh", platform=platform, role=platform, **CHOICES).to_cli_args()
    for flag in ("--release-state", "--optional-services", "--idp", "--vault-addr"):
        assert flag not in args, (flag, args)


@pytest.mark.parametrize("platform", ["orangepi5", "orangepi4-lts"])
def test_cluster_choices_are_node_class_only_on_the_orange_pi(platform):
    node = ImageConfig(mode="mesh", platform=platform, role="frontend")
    desk = ImageConfig(mode="mesh", platform=platform, role=platform)
    for f in ("release_state", "idp", "vault_addr", "optional_services", "games_domain"):
        assert field_in_scope(f, node), f
        assert not field_in_scope(f, desk), f


def test_rpi5_desktop_scope_is_unchanged():
    """The class rule rides class_platforms: rpi5 keeps its own (no) class rule."""
    desk = ImageConfig(mode="mesh", platform="rpi5", role="rpi5-desktop")
    assert field_in_scope("release_state", desk)
    assert field_in_scope("idp", desk)


@pytest.mark.parametrize("platform", ["orangepi5", "orangepi4-lts"])
def test_host_daemon_slugs_are_not_offered_and_are_dropped(platform):
    assert "tor" not in OPTIONAL_SERVICES_BY_PLATFORM[platform]
    assert "egress-vpn" not in OPTIONAL_SERVICES_BY_PLATFORM[platform]
    assert "owncast" in OPTIONAL_SERVICES_BY_PLATFORM[platform]
    cfg = ImageConfig(mode="mesh", platform=platform, role="frontend", ram_gb="4",
                      optional_services=["akkoma", "tor", "egress-vpn"])
    cleared = strip_platform_unsupported(cfg)
    assert cfg.optional_services == ["akkoma"]
    assert "optional_services" in cleared
    args = cfg.to_cli_args()
    assert "tor" not in " ".join(args) and "egress-vpn" not in " ".join(args)


def test_rpi5_keeps_tor():
    cfg = ImageConfig(mode="mesh", platform="rpi5", role="pki", optional_services=["tor"])
    strip_platform_unsupported(cfg)
    assert cfg.optional_services == ["tor"]


# ---------------------------------------------------------------- the page, looked at

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
_qt = pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")

from hugmesh_studio.core.platform_info import HostInfo          # noqa: E402
from hugmesh_studio.gui import wizard as wizard_mod             # noqa: E402
from hugmesh_studio.gui.pages.network import NetworkPage        # noqa: E402

QtWidgets = _qt.QtWidgets
STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
HOST = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                has_kvm=False, is_root=False, builder_image="hugmesh-builder")
PNG_DIR = os.environ.get("HUGMESH_STUDIO_PNG_DIR", "")


@pytest.fixture(autouse=True)
def _pinned_host(monkeypatch):
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": HOST)


@pytest.fixture(scope="module")
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


def _net(wiz, **cfg_kw):
    pid = [i for i in wiz.pageIds() if isinstance(wiz.page(i), NetworkPage)][0]
    wiz.cfg = ImageConfig(**cfg_kw)
    wiz.setStartId(pid)
    wiz.restart()
    wiz.setStartId(-1)
    QtWidgets.QApplication.processEvents()
    page = wiz.page(pid)
    assert wiz.currentPage() is page
    return page


def _grab(page, name):
    if PNG_DIR:
        os.makedirs(PNG_DIR, exist_ok=True)
        page.grab().save(os.path.join(PNG_DIR, name))


def _usable(w, min_w=60):
    return w.isVisible() and w.isEnabled() and w.width() >= min_w and w.height() >= 10


def test_node_row_page_shows_release_state_and_the_services(wiz):
    page = _net(wiz, mode="mesh", platform="orangepi5", role="pki", ram_gb="8")
    QtWidgets.QApplication.processEvents()
    _grab(page, "network-orangepi5-pki.png")
    assert _usable(page.release_state), (page.release_state.isVisible(),
                                         page.release_state.isEnabled(),
                                         page.release_state.size())
    assert _usable(page.service_boxes["owncast"], min_w=10), page.service_boxes["owncast"].size()
    for slug in ("tor", "egress-vpn"):
        box = page.service_boxes.get(slug)
        assert box is None or not box.isVisible(), f"{slug} is offered on an Orange Pi node"


def test_desktop_row_page_does_not_offer_release_state(wiz):
    page = _net(wiz, mode="mesh", platform="orangepi5", role="orangepi5")
    _grab(page, "network-orangepi5-desktop.png")
    assert not _usable(page.release_state)
    for slug in ("owncast", "games", "akkoma"):
        box = page.service_boxes.get(slug)
        assert box is None or not _usable(box, min_w=1), f"{slug} offered on the desktop"
