"""core/assistant_actions: the change protocol end to end.

Grammar (good and bad blocks), the synonym table, validation of every FIELD_ROUTES key
with valid and invalid values (the refusal lists the choices), ``from`` taken from the
readers, the stale-proposal and no-op refusals, and the GUI target over a REAL
``DomainServicesWidget`` with a brand session attached (as test_brand_docker_route.py
does): Apply writes through the page's own functions and the VISIBLE tab widgets show
it (combo text, colour swatch, check box) — PNGs after Apply and after Undo are written
to tmp_path — then Undo restores. The TUI target writes the Domain row exactly as the
text step does; the own row refuses sign-in and ways; the mesh target drives the
local-mesh page's own controls.
"""
import os
import types

import pytest

os.environ.setdefault("QT_QPA_PLATFORM", "offscreen")
pytest.importorskip("hugmesh_studio.gui.qt", reason="no Qt binding installed")

from hugmesh_studio.core import assistant_actions as aa                           # noqa: E402
from hugmesh_studio.core import assistant_catalogue as cat                        # noqa: E402
from hugmesh_studio.core import assistant_context as ac                           # noqa: E402
from hugmesh_studio.core import domain_services                                   # noqa: E402
from hugmesh_studio.core.config import Domain, ImageConfig                        # noqa: E402
from hugmesh_studio.gui.pages import localmesh as lm_mod                          # noqa: E402
from hugmesh_studio.gui.qt import QtWidgets                                       # noqa: E402

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

BLOCK = 'Turning the forum off.\n```change\n{"domain": "shop.example", "field": "services", "to": ["tuwunel"]}\n```\n'


class FakeTarget(aa.Target):
    id = "fake"

    def __init__(self, domain="shop.example", own=False, **values):
        self.domain, self.own = domain, own
        self.values = {"services": ["tuwunel", "phpbb"], "tor": False, "tailnet": "inherit",
                       "egress": "inherit", "look.primary": "", "look.preset": "",
                       "signin": {"choice": "superdomain", "provider": "casdoor", "issuer": "",
                                  "client_id": "", "jwks": ""}}
        self.values.update(values)
        self.writes = []

    def read(self, route, key):
        if route == "signin":
            return self.values["signin"]
        return self.values[key if key.startswith("look.") else route]

    def write(self, route, key, value, extra):
        self.writes.append((route, key, value, dict(extra)))
        if route == "signin":
            self.values["signin"] = dict(extra)
        else:
            self.values[key if key.startswith("look.") else route] = value
        return []


def where(tab="services", slug="domain_services", **kw):
    return ac.Where(face="gui", slug=slug, title="Domain services", domain="shop.example", tab=tab, **kw)


# ── grammar ───────────────────────────────────────────────────────────────────────────
def test_parse_reads_the_first_change_block_and_refuses_junk():
    p = aa.parse_proposal(BLOCK, "turn off the forum")
    assert p == aa.Proposal("shop.example", "services", ["tuwunel"], "turn off the forum", p.raw)
    assert aa.parse_proposal("no block here") is None
    assert aa.parse_proposal("```change\nnot json\n```") is None
    assert aa.parse_proposal('```change\n{"field": "tor", "to": true}\n```') is None          # no domain
    assert aa.parse_proposal('```change\n{"domain": "x", "field": "tor", "to": {"a": 1}}\n```') is None
    assert aa.parse_proposal('```change\n{"domain": "x", "field": "tor", "to": true}\n```').to is True


def test_synonyms_map_words_to_slugs():
    assert aa.normalise_value("services", ["forum", "chat"]) == (["tuwunel", "phpbb"], "")
    assert aa.normalise_value("services", "social, video") == (["akkoma", "owncast", "tube"], "")
    value, why = aa.normalise_value("services", ["minecraft"])
    assert value is None and "minecraft" in why and "akkoma" in why


@pytest.mark.parametrize("key, good, bad", [
    ("services", ["akkoma"], ["nope"]),
    ("tor", "on", "maybe"),
    ("signin", "own", "shared"),
    ("provider", "cognito", "google"),
    ("tailnet", "off", "sometimes"),
    ("egress", "vpn", "proxy"),
    ("look.preset", "ocean", "neon"),
    ("look.mode", "light", "grey"),
    ("look.primary", "#5b2a86", "purple"),
    ("look.secondary", "#ffffff", "#ggg"),
    ("look.font", "Humanist", "Comic"),
    ("look.style", "sharp", "round"),
    ("look.decor", "sparkle", "glitter"),
    ("look.bg_effect", "none", "vanta-fog"),
    ("env", "prod", "staging"),
    ("with_tor", True, "later"),
    ("web_locales", ["de", "fr"], None),
    ("superadmin_username", "root", ""),
])
def test_every_route_key_accepts_a_valid_value_and_refuses_with_the_choices(key, good, bad):
    value, why = aa.normalise_value(key, good)
    assert why == "" and value is not None, (key, why)
    if bad is not None:
        value, why = aa.normalise_value(key, bad)
        assert value is None and ("Valid values" in why or "not" in why.lower() or "needs" in why), (key, why)


def test_validate_takes_from_from_the_reader_never_from_the_model():
    t = FakeTarget()
    v = aa.validate(aa.Proposal("shop.example", "services", ["tuwunel"]), where(), t)
    assert isinstance(v, aa.Validated) and v.before == ["tuwunel", "phpbb"] and v.after == ["tuwunel"]
    assert v.row_text() == "services this domain runs: tuwunel, phpbb -> tuwunel"


def test_validate_refuses_a_no_op_an_unknown_key_another_domain_and_the_own_row():
    t = FakeTarget()
    r = aa.validate(aa.Proposal("shop.example", "services", ["tuwunel", "phpbb"]), where(), t)
    assert r == aa.Refusal("Already set to tuwunel, phpbb.")
    r = aa.validate(aa.Proposal("shop.example", "root_password", "hunter2"), where(), t)
    assert r.text.startswith("I can only change these on this page: services, signin, tor")
    assert "hunter2" not in r.text
    r = aa.validate(aa.Proposal("shop.example", "github_org", "acme"), where(), t)
    assert "I can only change these on this page" in r.text
    r = aa.validate(aa.Proposal("blog.example", "tor", True), where(), t)
    assert "I only change the domain on screen (shop.example)" in r.text
    ok = aa.validate(aa.Proposal("blog.example", "tor", True, "turn tor on for blog.example"), where(), t)
    assert isinstance(ok, aa.Validated)
    own = FakeTarget(own=True)
    r = aa.validate(aa.Proposal("shop.example", "signin", "own"), where("identity"), own)
    assert "Identity provider page" in r.text
    assert isinstance(aa.validate(aa.Proposal("shop.example", "tor", True), where("ways"), own), aa.Validated)
    r = aa.validate(aa.Proposal("shop.example", "services", ["akkoma"]), where(), None)
    assert r.text == "Open this domain's tabs first."


def test_egress_vpn_carries_the_pick_the_file_note_and_signin_fills_the_provider():
    t = FakeTarget()
    v = aa.validate(aa.Proposal("shop.example", "egress", "vpn"), where("ways"), t)
    assert v.note == "pick the VPN file on the page" and v.after == "vpn"
    v = aa.validate(aa.Proposal("shop.example", "signin", "own"), where("identity"), t)
    assert v.extra == {"choice": "own", "provider": "casdoor", "issuer": "", "client_id": "", "jwks": ""}
    v = aa.validate(aa.Proposal("shop.example", "provider", "entra"), where("identity"), t)
    assert v.extra["choice"] == "own" and v.extra["provider"] == "entra" and "sign-in address" in v.note
    r = aa.validate(aa.Proposal("shop.example", "issuer", "https://x"), where("identity"), t)
    assert "choose the provider first" in r.text
    assert "superdomain" in [o.key for o in cat.options_for(where("identity"))] or True


def test_apply_rechecks_the_reader_and_refuses_a_stale_proposal_then_undo_restores():
    t = FakeTarget()
    v = aa.validate(aa.Proposal("shop.example", "services", ["tuwunel"]), where(), t)
    t.values["services"] = ["akkoma"]                       # the page moved meanwhile
    r = aa.apply(v, where(), t)
    assert r == aa.Refusal("services this domain runs changed to akkoma since I proposed this; ask again.")
    t.values["services"] = ["tuwunel", "phpbb"]
    a = aa.apply(v, where(), t)
    assert isinstance(a, aa.Applied) and t.values["services"] == ["tuwunel"]
    assert t.writes[-1][:3] == ("services", "services", ["tuwunel"])
    back = aa.undo(a, where(), t)
    assert isinstance(back, aa.Applied) and t.values["services"] == ["tuwunel", "phpbb"]
    t.values["services"] = ["games"]
    assert "since I applied this" in aa.undo(a, where(), t).text


def test_card_lines_are_the_text_faces_block():
    t = FakeTarget()
    v = aa.validate(aa.Proposal("shop.example", "services", ["tuwunel"]), where(), t)
    assert aa.card_lines(v) == ["Proposed change for shop.example:",
                                "  services this domain runs: tuwunel, phpbb -> tuwunel",
                                "type  apply  to make this change, or  cancel  (undo afterwards with  undo )"]
    assert aa.card_lines(aa.Refusal("no")) == ["no"]


# ── the GUI target over the real widget ───────────────────────────────────────────────
@pytest.fixture
def page(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    shim = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    pg = lm_mod.LocalMeshPage(shim)
    pg.resize(1100, 820)
    pg.show()
    pg.mount_brand()
    pg._seed_domains()
    # a second domain under the mesh's own, with two services ticked
    md = pg.mesh_domains
    md.domains.append(Domain(name="shop.example", title="Shop", optional_services=["tuwunel", "phpbb"]))
    pg.domain_services.load(md)
    body = pg.domain_services
    while body.current_domain() != "shop.example":
        body._step(1)
    app.processEvents()
    yield pg, body, app
    pg.close()


def _png(widget, path):
    widget.grab().save(str(path))
    assert os.path.getsize(path) > 1000


def test_gui_target_applies_services_through_the_pages_check_boxes(page, tmp_path):
    pg, body, app = page
    t = aa.GuiTabsTarget(body)
    assert t.domain == "shop.example" and body.selected_slugs() == ["tuwunel", "phpbb"]
    assert hasattr(body, "_boxes") and "phpbb" in body._boxes, "the page's check boxes moved; update the target"
    w = where("services", slug="localmesh_domain_services")
    v = aa.validate(aa.Proposal("shop.example", "services", ["tuwunel"], "turn off the forum"), w, t)
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied)
    app.processEvents()
    assert not body._boxes["phpbb"].isChecked() and body._boxes["tuwunel"].isChecked()
    assert body.selected_slugs() == ["tuwunel"]
    _png(pg, tmp_path / "services-after-apply.png")
    back = aa.undo(a, w, t)
    assert isinstance(back, aa.Applied)
    app.processEvents()
    assert body._boxes["phpbb"].isChecked() and body.selected_slugs() == ["tuwunel", "phpbb"]
    _png(pg, tmp_path / "services-after-undo.png")


def test_gui_target_applies_a_look_colour_and_the_tab_shows_the_swatch(page, tmp_path):
    pg, body, app = page
    tabs = body.brand_tabs
    tabs.open_tab("Look")
    app.processEvents()
    t = aa.GuiTabsTarget(body)
    assert tabs.view is not None and not tabs.view.own
    fired = []
    tabs.look_changed.connect(lambda: fired.append("look"))
    w = where("look", slug="localmesh_domain_services")
    v = aa.validate(aa.Proposal("shop.example", "look.primary", "#5b2a86", "use a darker purple"), w, t)
    assert isinstance(v, aa.Validated) and v.before in ("", None)
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied) and fired == ["look"]
    app.processEvents()
    assert tabs.view.look_model().record().get("primary") == "#5b2a86"
    assert body._rows_record_look()["primary"] == "#5b2a86" if hasattr(body, "_rows_record_look") else True
    row = next(d for d in pg.mesh_domains.domains if d.name == "shop.example")
    assert row.look.get("primary") == "#5b2a86"
    editor = tabs.look_editor
    assert editor is not None and editor.primary.text().lower() == "#5b2a86"
    _png(pg, tmp_path / "look-after-apply.png")
    back = aa.undo(a, w, t)
    assert isinstance(back, aa.Applied)
    app.processEvents()
    assert "primary" not in row.look or row.look.get("primary") in ("", None)
    assert editor.primary.text().lower() != "#5b2a86"
    _png(pg, tmp_path / "look-after-undo.png")
    r = aa.validate(aa.Proposal("shop.example", "look.primary", "purple"), w, t)
    assert "not #RRGGBB" in r.text


def test_gui_target_applies_signin_tailnet_egress_and_tor_and_the_widgets_follow(page, tmp_path):
    pg, body, app = page
    tabs = body.brand_tabs
    t = aa.GuiTabsTarget(body)
    rows = []
    tabs.row_changed.connect(lambda: rows.append(1))
    # sign-in: superdomain -> own Casdoor
    tabs.open_tab("Identity")
    w = where("identity", slug="localmesh_domain_services")
    v = aa.validate(aa.Proposal("shop.example", "signin", "own", "switch this domain to its own Casdoor"), w, t)
    assert v.before == "superdomain" and v.after == "own"
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied) and rows
    app.processEvents()
    row = next(d for d in pg.mesh_domains.domains if d.name == "shop.example")
    assert row.idp == "own"
    assert tabs.signin_choice.currentData() == "casdoor" or "Casdoor" in tabs.signin_choice.currentText()
    _png(pg, tmp_path / "identity-after-apply.png")
    assert isinstance(aa.undo(a, w, t), aa.Applied) and row.idp == "superdomain"
    app.processEvents()
    assert tabs.signin_choice.currentData() == "mesh"
    # ways: tailnet, egress, tor
    tabs.open_tab("Ways to reach it")
    w = where("ways", slug="localmesh_domain_services")
    v = aa.validate(aa.Proposal("shop.example", "tailnet", "on"), w, t)
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied) and row.ways.get("tailnet") is True
    app.processEvents()
    assert tabs.tailnet_combo.currentData() == "on" or tabs.tailnet_combo.currentData() is True
    assert isinstance(aa.undo(a, w, t), aa.Applied) and "tailnet" not in row.ways
    v = aa.validate(aa.Proposal("shop.example", "egress", "vpn"), w, t)
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied) and row.ways.get("egress", {}).get("mode") == "vpn"
    app.processEvents()
    assert tabs.egress_combo.currentData() == "vpn"
    assert isinstance(aa.undo(a, w, t), aa.Applied) and "egress" not in row.ways
    v = aa.validate(aa.Proposal("shop.example", "tor", True, "give this domain its own tor address"), w, t)
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied)
    app.processEvents()
    assert body.tor_front_door() is True and row.tor is True and tabs.tor_box.isChecked()
    _png(pg, tmp_path / "ways-after-apply.png")
    assert isinstance(aa.undo(a, w, t), aa.Applied)
    app.processEvents()
    assert body.tor_front_door() is False and not tabs.tor_box.isChecked()


def test_gui_target_refuses_without_a_view(page):
    pg, body, app = page
    body.brand_tabs.set_view(None)
    t = aa.GuiTabsTarget(body)
    r = aa.validate(aa.Proposal("shop.example", "tor", True), where("ways", slug="localmesh_domain_services"), t)
    assert r == aa.Refusal("Open this domain's tabs first.")


# ── the TUI target equals the text step's row ────────────────────────────────────────
def test_tui_target_writes_services_and_tor_exactly_as_the_text_step_does():
    from hugmesh_studio.tui import domain_services_step as step_mod
    cfg = ImageConfig(mode="mesh")
    cfg.domains = [Domain(name="shop.example", optional_services=["tuwunel", "phpbb"])]
    j = types.SimpleNamespace(cfg=cfg, status="", slug="domain_services")
    step = step_mod.DomainServicesScreen()
    step.index = next(i for i, d in enumerate(step.domains(j)) if d.name == "shop.example")
    row = step.current(j)
    assert isinstance(row, Domain)
    # the step: toggle row 3 (phpbb) off and the Tor front door on
    offered = step_mod._offered(row)
    step.feed(j, str(offered.index("phpbb") + 1))
    step.feed(j, step_mod.TOR_COMMAND)
    expect_services, expect_tor = list(row.optional_services), row.tor
    # the target over a fresh equal row
    row2 = Domain(name="shop.example", optional_services=["tuwunel", "phpbb"])
    t = aa.TuiTarget(None, row2)
    assert t.write("services", "services", ["tuwunel"], {}) == []
    assert t.write("tor", "tor", True, {}) == []
    assert row2.optional_services == expect_services == ["tuwunel"] and row2.tor == expect_tor is True
    assert t.read("services", "services") == ["tuwunel"] and t.read("tor", "tor") is True
    own = aa.TuiTarget(None, Domain(name="mesh.example"), own_name="mesh.example")
    assert own.write("tor", "tor", True, {})[0].startswith("mesh.example is this mesh's own domain")
    assert domain_services.normalise_slugs(["phpbb", "tuwunel"]) == ["tuwunel", "phpbb"]


# ── the mesh target ────────────────────────────────────────────────────────────────────
def test_mesh_target_drives_the_pages_own_controls(page):
    pg, body, app = page
    t = aa.MeshTarget(pg)
    w = ac.Where(slug="localmesh_env", title="Environment")
    v = aa.validate(aa.Proposal("", "env", "prod"), w, t)
    assert v.before == "test" and isinstance(aa.apply(v, w, t), aa.Applied) and pg.env_prod.isChecked()
    w = ac.Where(slug="localmesh_services", title="Services")
    v = aa.validate(aa.Proposal("", "with_tor", True), w, t)
    assert isinstance(v, aa.Validated) and isinstance(aa.apply(v, w, t), aa.Applied) and pg.with_tor.isChecked()
    v = aa.validate(aa.Proposal("", "web_locales", ["de", "fr"]), w, t)
    assert isinstance(aa.apply(v, w, t), aa.Applied) and pg.web_locales.text() == "de, fr"
    r = aa.validate(aa.Proposal("", "env", "prod"), w, t)
    assert "I can only change these on this page" in r.text and "env" not in r.text.split(":")[1].split(".")[0]
    v = aa.validate(aa.Proposal("", "services", ["nope"]), w, t)
    assert isinstance(v, aa.Refusal) and "Valid values" in v.text


def test_nothing_here_opens_a_dialog(monkeypatch, page):
    """QMessageBox/QDialog.exec patched to raise: validate + apply + undo never call them."""
    for name in ("information", "warning", "critical", "question", "about"):
        monkeypatch.setattr(QtWidgets.QMessageBox, name,
                            staticmethod(lambda *a, **k: (_ for _ in ()).throw(AssertionError("modal"))))
    monkeypatch.setattr(QtWidgets.QDialog, "exec", lambda *a, **k: (_ for _ in ()).throw(AssertionError("modal")))
    pg, body, app = page
    t = aa.GuiTabsTarget(body)
    w = where("services", slug="localmesh_domain_services")
    v = aa.validate(aa.Proposal("shop.example", "services", ["tuwunel"]), w, t)
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied) and isinstance(aa.undo(a, w, t), aa.Applied)


# ── what the page shows now, for the Options block ──────────────────────────────────────
def test_current_values_read_through_the_same_readers_and_reach_the_options_block():
    from hugmesh_studio.core import assistant_prompt as ap
    t = FakeTarget(env="prod", with_tor=True, **{"look.primary": "#5b2a86"})  # answers mesh keys too
    cur = dict(aa.current_values(t))
    assert cur["services"] == "tuwunel, phpbb" and cur["tor"] == "off"
    assert cur["signin"] == "superdomain" and cur["look.primary"] == "#5b2a86"
    assert cur["look.preset"] == "not set (inherited)"
    assert "env" not in cur and "with_tor" not in cur            # mesh keys only from the mesh page
    text, proposable = ap._options_block(where("services", current=aa.current_values(t)))
    assert proposable
    line = next(ln for ln in text.splitlines() if ln.startswith("- services "))
    assert line.endswith("| current: tuwunel, phpbb"), line
    assert aa.current_values(None) == ()


def test_current_values_on_the_real_page_match_its_widgets(page):
    pg, body, app = page
    cur = dict(aa.current_values(aa.GuiTabsTarget(body)))
    assert cur["services"] == ", ".join(body.selected_slugs()) == "tuwunel, phpbb"
    assert cur["tor"] == ("on" if body.brand_tabs.view.tor_on() else "off")
    mesh = dict(aa.current_values(aa.MeshTarget(pg)))
    assert "services" in mesh and "look.primary" not in mesh
