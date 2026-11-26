"""'Go live when ready' (hugmesh-generator#1201) — config, builder args, API keys, and
both faces of the domain step.

Operator decisions (2026-11-25): choosing it at build time IS consent for that domain's
unattended go-live; when it is on, the domain step takes the provider's API key in a
masked field, and that key reaches the node on its KEYS stick only.

Pinned here:
* ``Domain.go_live`` / ``cluster_domain_go_live``: saved only when set, reloaded, junk
  and tor-onion refused at load;
* ``--domain-go-live`` emitted for x86 and rpi5 NODE roles only, own domain first;
* the API key: refused when malformed, never in repr / to_dict / the manifest, written
  0600 under go-live/ on edge-role sticks only, and a missing one blocks preflight;
* the TUI: ``go PROVIDER|off`` records, ``key`` makes the next line hidden and stores
  it without echoing it; the GUI row: shown on the image route, records on validate,
  the masked field holds nothing after entry.
The GUI half skips without a Qt binding; everything else never skips.
"""
import json
import os

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")

from hugmesh_studio.core import config as c                          # noqa: E402
from hugmesh_studio.core import golive_ready, golive_tokens           # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig            # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
SECRET = "SECRET-TOKEN-1201-abc"


@pytest.fixture(autouse=True)
def _fresh_token_store(monkeypatch):
    monkeypatch.setattr(golive_tokens, "_STORE", golive_tokens.TokenStore())


def _cfg(**kw):
    base = dict(platform="x86", role="backend", mode="mesh", cluster_domain="mesh.test",
                domains=[Domain(name="shop.test"), Domain(name="quiet.test")])
    base.update(kw)
    return ImageConfig(**base)


def _flags(cfg):
    a = cfg.to_cli_args()
    return [a[i + 1] for i, x in enumerate(a) if x == "--domain-go-live"]


# ── config ────────────────────────────────────────────────────────────────────────
def test_saved_only_when_set_and_reloaded():
    cfg = _cfg(cluster_domain_go_live="byo-domain")
    cfg.domains[0].go_live = "cloudflare-tunnel"
    d = cfg.to_dict()
    assert d["cluster_domain_go_live"] == "byo-domain"
    assert d["domains"][0]["go_live"] == "cloudflare-tunnel"
    assert "go_live" not in d["domains"][1]              # omit-when-empty
    assert "cluster_domain_go_live" not in _cfg().to_dict()
    back = ImageConfig.from_dict(json.loads(json.dumps(d)))
    assert back.cluster_domain_go_live == "byo-domain"
    assert [x.go_live for x in back.domains] == ["cloudflare-tunnel", ""]


@pytest.mark.parametrize("bad", ["tor-onion", "bogus", "BYO-DOMAIN"])
def test_junk_is_refused_at_load(bad):
    d = _cfg().to_dict()
    with pytest.raises(ValueError):
        ImageConfig.from_dict({**d, "cluster_domain_go_live": bad})
    d["domains"][0]["go_live"] = bad
    with pytest.raises(ValueError):
        ImageConfig.from_dict(d)


def test_manifest_carries_it_only_when_set():
    assert "cluster_domain_go_live" not in _cfg().mesh_manifest()
    m = _cfg(cluster_domain_go_live="duckdns").mesh_manifest()
    assert m["cluster_domain_go_live"] == "duckdns"


# ── builder args ──────────────────────────────────────────────────────────────────
def test_args_on_node_roles_own_domain_first():
    cfg = _cfg(cluster_domain_go_live="byo-domain")
    cfg.domains[0].go_live = "cloudflare-tunnel"
    assert _flags(cfg) == ["mesh.test=byo-domain", "shop.test=cloudflare-tunnel"]
    r = _cfg(platform="rpi5", role="backend", cluster_domain_go_live="duckdns")
    assert _flags(r) == ["mesh.test=duckdns"]


def test_no_args_when_off_or_on_a_client_or_another_platform():
    assert _flags(_cfg()) == []
    assert _flags(_cfg(role="laptop", cluster_domain_go_live="byo-domain")) == []
    assert golive_ready.get(_cfg(platform="frite"), "mesh.test") == ""
    cfg = _cfg(platform="frite", role="", cluster_domain_go_live="byo-domain")
    assert cfg._domain_go_live_args() == []


def test_the_lib_and_the_studio_agree_on_the_providers():
    lib = open(os.path.join(GENERATOR_DIR, "scripts", "_domain-golive-lib.sh")).read()
    line = [x for x in lib.splitlines() if x.startswith("DOMAIN_GOLIVE_PROVIDERS=")][0]
    assert sorted(line.split("=", 1)[1].strip('"').split()) == \
        sorted(c.GO_LIVE_AT_READY_PROVIDERS)


# ── API keys ──────────────────────────────────────────────────────────────────────
def test_token_store_refuses_junk_and_never_shows_values():
    st = golive_tokens.store()
    assert st.set("mesh.test", "two words")
    assert st.set("mesh.test", "line\nbreak")
    assert not st.has("mesh.test")
    assert st.set("mesh.test", SECRET) == ""
    assert SECRET not in repr(st)
    cfg = _cfg(cluster_domain_go_live="cloudflare-tunnel")
    assert SECRET not in json.dumps(cfg.to_dict())
    assert SECRET not in json.dumps(cfg.mesh_manifest())
    assert SECRET not in " ".join(cfg.to_cli_args())


def test_tokens_land_0600_on_edge_sticks_only(tmp_path):
    cfg = _cfg(cluster_domain_go_live="cloudflare-tunnel")
    cfg.domains[0].go_live = "byo-domain"                # needs no token
    golive_tokens.store().set("mesh.test", SECRET)
    edge = tmp_path / "keys-backend"
    assert golive_tokens.write_tokens(str(edge), cfg, "backend", "x86") == ["mesh.test"]
    f = edge / "go-live" / "mesh.test.token"
    assert f.read_text() == SECRET + "\n"
    assert oct(f.stat().st_mode & 0o777) == "0o600"
    assert oct((edge / "go-live").stat().st_mode & 0o777) == "0o700"
    assert not (edge / "go-live" / "shop.test.token").exists()
    for role, plat in (("pki", "x86"), ("frontend", "x86"), ("pki", "rpi5"),
                       ("laptop", "x86")):
        d = tmp_path / f"keys-{role}-{plat}"
        assert golive_tokens.write_tokens(str(d), cfg, role, plat) == []
        assert not (d / "go-live").exists()
    for role, plat in (("omnibus", "x86"), ("backend-gpu", "x86"), ("edge-ai", "x86"),
                       ("backend", "rpi5")):
        assert golive_tokens.is_edge_role(role, plat), (role, plat)


def test_a_missing_token_is_a_blocking_preflight_problem(tmp_path):
    from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
    from hugmesh_studio.core.worklist_driver import WorklistDriver
    base = _cfg(cluster_domain_go_live="cloudflare-tunnel")
    wl = WorklistConfig(base=base, entries=[WorklistEntry(id="backend.x86",
                                                          role="backend", platform="x86")])
    drv = WorklistDriver(GENERATOR_DIR, wl, generate_keys=True)
    msgs = [p for p in drv.preflight() if "go live when ready" in p]
    assert msgs and "Cloudflare Tunnel token" in msgs[0]
    golive_tokens.store().set("mesh.test", SECRET)
    assert not [p for p in drv.preflight() if "go live when ready" in p]
    drv_nokeys = WorklistDriver(GENERATOR_DIR, wl, generate_keys=False)
    assert [p for p in drv_nokeys.preflight() if "KEYS generation on" in p]


def test_state_line_says_consent_and_where_the_key_goes():
    assert golive_ready.state_line("a.test", "").startswith("Off")
    line = golive_ready.state_line("a.test", "cloudflare-tunnel")
    assert "no confirmation" in line and "the build refuses" in line
    golive_tokens.store().set("a.test", SECRET)
    line = golive_ready.state_line("a.test", "cloudflare-tunnel")
    assert "entered" in line and SECRET not in line


# ── TUI ───────────────────────────────────────────────────────────────────────────
def _tui_at_own():
    from hugmesh_studio.tui import journey
    j = journey.Journey(".")
    for line in ("", "3", "", "1", "", "", "", ""):
        j.feed(line)
    assert j.slug == "domains_choice"
    j.feed("y")
    j.feed("a shop.test")
    j.feed("")
    assert j.slug == "domain_services"
    return j


def test_tui_go_and_hidden_key():
    j = _tui_at_own()
    scr = j.screen()
    own = scr.current(j).name
    assert own == j.cfg.cluster_domain
    text = "\n".join(scr.lines(j))
    assert f"{golive_ready.ROW_LABEL}: Off" in text and "go PROVIDER|off" in text
    j.feed("go bogus")
    assert j.cfg.cluster_domain_go_live == ""
    j.feed("go cloudflare-tunnel")
    assert j.cfg.cluster_domain_go_live == "cloudflare-tunnel"
    assert "key=enter its API key" in "\n".join(scr.lines(j))
    j.feed("key")
    assert j.secret_input() is True and "hidden" in j.prompt()
    j.feed(SECRET)
    assert j.secret_input() is False
    assert golive_tokens.store().get(own) == SECRET
    assert SECRET not in (j.status or "")
    assert SECRET not in "\n".join(scr.lines(j))
    j.feed("go off")
    assert j.cfg.cluster_domain_go_live == ""
    j.feed("n")
    assert scr.current(j).name == "shop.test"
    j.feed("go byo-domain")
    assert j.cfg.domains[0].go_live == "byo-domain"
    j.feed("key")
    assert j.secret_input() is False and "needs none" in j.status


# ── GUI ───────────────────────────────────────────────────────────────────────────
def _qt():
    return pytest.importorskip("hugmesh_studio.gui.qt",
                               reason="no Qt binding (PySide6/PyQt6) installed")


@pytest.fixture(scope="module")
def qapp():
    qt = _qt()
    return (qt.QtWidgets.QApplication.instance()
            or qt.QtWidgets.QApplication(["hugmesh-studio-go-live-when-ready"]))


@pytest.fixture
def wiz(qapp, monkeypatch):
    from hugmesh_studio.core.platform_info import HostInfo
    from hugmesh_studio.gui import wizard as wizard_mod
    host = HostInfo(os="linux", is_gentoo=True, has_docker=False, has_bash=True,
                    has_kvm=False, is_root=False, builder_image="hugmesh-builder")
    monkeypatch.setattr(wizard_mod, "detect",
                        lambda builder_image="hugmesh-builder": host)
    w = wizard_mod.StudioWizard(GENERATOR_DIR)
    w.show()
    yield w
    w.close()
    w.deleteLater()


def _page(wiz):
    from _helpers import advance_to
    from hugmesh_studio.gui.pages import domain_services as page_mod
    cfg = wiz.cfg
    cfg.mode, cfg.role, cfg.additional_domains = "mesh", "omnibus", True
    cfg.domains = [Domain(name="shop.test")]
    wiz.restart()
    return advance_to(wiz, page_mod.DomainServicesPage)


def test_gui_row_records_and_the_key_field_keeps_nothing(wiz):
    page = _page(wiz)
    own = page.current_domain()
    assert own == wiz.cfg.cluster_domain
    assert page.glr_box.isVisible()
    assert page.glr_combo.currentData() == ""
    assert page.glr_note.text().startswith("Off")
    assert not page.glr_token.isVisible()
    page.glr_combo.setCurrentIndex(page.glr_combo.findData("cloudflare-tunnel"))
    assert page.glr_token.isVisible()
    assert "the build refuses" in page.glr_note.text()
    page.glr_token.setText(SECRET)
    page.glr_token.editingFinished.emit()
    assert golive_tokens.store().get(own) == SECRET
    assert page.glr_token.text() == ""
    assert "entered" in page.glr_note.text()
    page.validatePage()
    assert wiz.cfg.cluster_domain_go_live == "cloudflare-tunnel"
    page._step(1)
    assert page.current_domain() == "shop.test"
    assert page.glr_combo.currentData() == ""
    page.glr_combo.setCurrentIndex(page.glr_combo.findData("byo-domain"))
    assert not page.glr_token.isVisible()
    page.validatePage()
    assert wiz.cfg.domains[0].go_live == "byo-domain"
    assert SECRET not in json.dumps(wiz.cfg.to_dict())


def test_gui_row_is_hidden_on_the_docker_route(qapp):
    from hugmesh_studio.gui.pages.domain_services import DomainServicesWidget
    w = DomainServicesWidget(route="docker")
    w.glr_box.setVisible(True)
    w._paint_glr("a.test")
    assert not w.glr_box.isVisible()
    w.deleteLater()
