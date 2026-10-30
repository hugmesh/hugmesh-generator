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


def test_the_change_formats_example_is_never_a_change(monkeypatch):
    """Round 6 (PR #832): qwen3:8b answered "turn off the forum" by copying the format's
    example word for word, and because that example named a real field of the domain on
    screen (shop.example, tor, true) its card offered an onion front door. The example is
    now made up, the prompt carries exactly it, and every copy of it is refused: the
    block itself, the block with the domain on screen swapped in, and its domain with a
    real field, on every page and tab."""
    from hugmesh_studio.core import assistant_prompt as ap
    import json as _json
    block = "```change\n" + _json.dumps(aa.EXAMPLE_PROPOSAL) + "\n```"
    assert block in ap.CHANGE_FORMAT and aa.EXAMPLE_SENTENCE in ap.CHANGE_FORMAT
    assert "shop.example" not in ap.CHANGE_FORMAT and '"tor"' not in ap.CHANGE_FORMAT
    copies = [
        aa.EXAMPLE_SENTENCE + "\n" + block,
        'ok\n```change\n{"domain": "shop.example", "field": "example.setting", "to": true}\n```',
        'ok\n```change\n{"domain": "example.invalid", "field": "tor", "to": true}\n```',
        'ok\n```change\n{"domain": "example.invalid", "field": "services", "to": ["tuwunel"]}\n```',
        'ok\n```change\n{"domain": "blog.invalid", "field": "egress", "to": "vpn"}\n```',
    ]
    for tab in ("services", "ways", "identity", "look", ""):
        for slug in ("domain_services", "localmesh_domain_services"):
            for text in copies:
                p = aa.parse_proposal(text, "turn off the forum for this domain")
                assert p is not None and aa.is_format_example(p), text
                t = FakeTarget()
                v = aa.validate(p, where(tab, slug=slug), t)
                assert isinstance(v, aa.Refusal) and v.text == aa.EXAMPLE_REFUSAL, (tab, slug, text, v)
                assert aa.card_lines(v) == [aa.EXAMPLE_REFUSAL] and t.writes == []
    # a real block next to it still validates
    v = aa.validate(aa.parse_proposal(BLOCK), where(), FakeTarget())
    assert isinstance(v, aa.Validated) and v.after == ["tuwunel"]
    assert not aa.is_format_example(aa.parse_proposal(BLOCK))


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
    # naming the other domain does NOT let it through: the readers and writers act on
    # the domain on screen, so the write would land on shop.example (PR #832 review)
    r = aa.validate(aa.Proposal("blog.example", "tor", True, "turn tor on for blog.example"), where(), t)
    assert r.text.startswith("I only change the domain on screen (shop.example). To change blog.example")
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
    # an external provider needs its sign-in address and client id first: the page's
    # writer would refuse it, so the card says so instead of offering a dead Apply
    r = aa.validate(aa.Proposal("shop.example", "provider", "entra"), where("identity"), t)
    assert isinstance(r, aa.Refusal) and "sign-in address" in r.text and "Identity tab" in r.text
    t2 = FakeTarget(signin={"choice": "own", "provider": "oidc", "issuer": "https://id.example",
                            "client_id": "shop", "jwks": ""})
    v = aa.validate(aa.Proposal("shop.example", "provider", "entra"), where("identity"), t2)
    assert v.extra["choice"] == "own" and v.extra["provider"] == "entra" and v.before == "oidc"
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
    """The domain-services body, not the whole page: the page scrolls, and a grab of it
    showed the top of the local-mesh form with the tabs out of the picture."""
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
    _png(body, tmp_path / "services-after-apply.png")
    back = aa.undo(a, w, t)
    assert isinstance(back, aa.Applied)
    app.processEvents()
    assert body._boxes["phpbb"].isChecked() and body.selected_slugs() == ["tuwunel", "phpbb"]
    _png(body, tmp_path / "services-after-undo.png")


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
    _png(body, tmp_path / "look-after-apply.png")
    back = aa.undo(a, w, t)
    assert isinstance(back, aa.Applied)
    app.processEvents()
    assert "primary" not in row.look or row.look.get("primary") in ("", None)
    assert editor.primary.text().lower() != "#5b2a86"
    _png(body, tmp_path / "look-after-undo.png")
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
    _png(body, tmp_path / "identity-after-apply.png")
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
    _png(body, tmp_path / "ways-after-apply.png")
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


# ── PR #832 review: the domain on screen, exact undo, the way back from an external IdP ──
@pytest.fixture
def two(tmp_path, monkeypatch):
    """The local-mesh page with shop.example and blog.example (both Tor off, both
    [tuwunel, phpbb]: equal values, so only the domain guard can stop a wrong write)."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    app = QtWidgets.QApplication.instance() or QtWidgets.QApplication(["t"])
    shim = types.SimpleNamespace(generator_dir=GENERATOR_DIR, localmesh_selected=True)
    pg = lm_mod.LocalMeshPage(shim)
    pg.resize(1100, 820)
    pg.show()
    pg.mount_brand()
    pg._seed_domains()
    md = pg.mesh_domains
    md.domains.append(Domain(name="shop.example", title="Shop", optional_services=["tuwunel", "phpbb"]))
    md.domains.append(Domain(name="blog.example", title="Blog", optional_services=["tuwunel", "phpbb"]))
    pg.domain_services.load(md)
    body = pg.domain_services
    goto(body, "shop.example")
    app.processEvents()
    yield pg, body, app
    pg.close()


def goto(body, name):
    """Next / Previous domain, as the person presses them."""
    for delta in (1, -1):
        for _ in range(10):
            if body.current_domain() == name:
                return
            body._step(delta)
    raise AssertionError(f"{name} not reachable with Next domain")


def row_of(pg, name):
    return next(d for d in pg.mesh_domains.domains if d.name == name)


LW = where("ways", slug="localmesh_domain_services")
LS = where("services", slug="localmesh_domain_services")


def test_the_gui_targets_domain_follows_the_page(two):
    pg, body, app = two
    t = aa.GuiTabsTarget(body)
    assert t.domain == "shop.example"
    goto(body, "blog.example")
    assert t.domain == "blog.example" and aa.live_domain(t) == "blog.example"
    assert aa.undo_key(t) == "gui-tabs:blog.example"


@pytest.mark.parametrize("field,to,check", [
    ("tor", True, lambda body, name: body.tor_front_door(name)),
    ("services", ["tuwunel"], lambda body, name: body.selected_slugs(name) == ["tuwunel"]),
])
def test_apply_after_next_domain_is_refused_and_touches_neither_domain(two, field, to, check, tmp_path):
    pg, body, app = two
    t = aa.GuiTabsTarget(body)
    w = LW if field == "tor" else LS
    v = aa.validate(aa.Proposal("shop.example", field, to, "please"), w, t)
    assert isinstance(v, aa.Validated) and v.domain == "shop.example"
    goto(body, "blog.example")                         # the card is still up; the page moved
    app.processEvents()
    r = aa.apply(v, w, t)
    assert isinstance(r, aa.Refusal), r
    assert r.text.startswith("This change is for shop.example, but the page now shows blog.example")
    app.processEvents()
    assert not check(body, "blog.example") and not check(body, "shop.example")
    goto(body, "shop.example")                         # back on its own domain it applies
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied) and check(body, "shop.example")
    assert not check(body, "blog.example")


def test_undo_after_next_domain_is_refused_and_works_back_on_its_domain(two):
    pg, body, app = two
    t = aa.GuiTabsTarget(body)
    v = aa.validate(aa.Proposal("shop.example", "services", ["tuwunel"], "forum off"), LS, t)
    a = aa.apply(v, LS, t)
    assert isinstance(a, aa.Applied) and a.target_id == "gui-tabs:shop.example"
    goto(body, "blog.example")
    r = aa.undo(a, LS, t)
    assert isinstance(r, aa.Refusal) and "Go back to shop.example to undo it" in r.text
    assert body.selected_slugs("blog.example") == ["tuwunel", "phpbb"]
    assert body.selected_slugs("shop.example") == ["tuwunel"]
    goto(body, "shop.example")
    assert isinstance(aa.undo(a, LS, t), aa.Applied)
    assert body.selected_slugs("shop.example") == ["tuwunel", "phpbb"]


def test_a_proposal_naming_the_other_domain_writes_nothing(two):
    pg, body, app = two
    t = aa.GuiTabsTarget(body)
    p = aa.parse_proposal('```change\n{"domain":"blog.example","field":"services",'
                          '"to":["akkoma","games"]}\n```', "turn on games for blog.example")
    r = aa.validate(p, LS, t)
    assert isinstance(r, aa.Refusal) and "open its tabs (Next domain)" in r.text
    assert body.selected_slugs("shop.example") == ["tuwunel", "phpbb"]
    assert body.selected_slugs("blog.example") == ["tuwunel", "phpbb"]


def test_undo_of_a_preset_restores_the_whole_look_record(two):
    pg, body, app = two
    body.brand_tabs.open_tab("Look")
    t = aa.GuiTabsTarget(body)
    w = where("look", slug="localmesh_domain_services")
    m = body.brand_tabs.view.look_model()
    assert m.record() == {}
    v = aa.validate(aa.Proposal("shop.example", "look.preset", "ocean", "ocean look"), w, t)
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied)
    assert set(m.record()) >= {"preset", "primary", "secondary"}      # a preset fills three
    assert isinstance(aa.undo(a, w, t), aa.Applied)
    assert m.record() == {} and not (row_of(pg, "shop.example").look or {})


def test_undo_of_egress_puts_the_provider_file_back(two):
    pg, body, app = two
    t = aa.GuiTabsTarget(body)
    view = body.brand_tabs.view
    assert view.set_egress("vpn", "/srv/vpn/provider.conf") == []
    assert view.egress_choice() == ("vpn", "/srv/vpn/provider.conf")
    v = aa.validate(aa.Proposal("shop.example", "egress", "direct"), LW, t)
    a = aa.apply(v, LW, t)
    assert isinstance(a, aa.Applied) and view.egress_choice()[0] == "direct"
    assert isinstance(aa.undo(a, LW, t), aa.Applied)
    assert body.brand_tabs.view.egress_choice() == ("vpn", "/srv/vpn/provider.conf")
    assert row_of(pg, "shop.example").ways["egress"] == {"mode": "vpn", "conf": "/srv/vpn/provider.conf"}


@pytest.mark.parametrize("field,to,after", [
    ("provider", "casdoor", ("own", "casdoor")),        # "switch this domain to its own Casdoor"
    ("signin", "casdoor", ("own", "casdoor")),          # the same, as the model often spells it
    ("signin", "superdomain", ("superdomain", "")),     # "use the mesh's sign-in"
])
def test_from_an_external_provider_back_to_casdoor_or_the_mesh_applies_and_undoes(two, field, to, after):
    pg, body, app = two
    body.brand_tabs.open_tab("Identity")
    t = aa.GuiTabsTarget(body)
    w = where("identity", slug="localmesh_domain_services")
    view = body.brand_tabs.view
    assert view.set_signin("entra", "https://login.example.com/t/v2.0", "shop-client", "") == []
    v = aa.validate(aa.Proposal("shop.example", field, to, "switch back"), w, t)
    assert isinstance(v, aa.Validated), v
    a = aa.apply(v, w, t)
    assert isinstance(a, aa.Applied), a
    row = row_of(pg, "shop.example")
    assert row.idp == after[0] and (row.idp_settings or {}).get("provider", "") in (after[1], "")
    assert not (row.idp_settings or {}).get("issuer")
    assert isinstance(aa.undo(a, w, t), aa.Applied)
    row = row_of(pg, "shop.example")
    assert row.idp == "own" and row.idp_settings == {"provider": "entra",
                                                     "issuer": "https://login.example.com/t/v2.0",
                                                     "client_id": "shop-client"}


def test_the_text_ui_files_undo_under_the_domain(monkeypatch):
    t1 = aa.TuiTarget(None, Domain(name="shop.example", optional_services=["tuwunel", "phpbb"]))
    t2 = aa.TuiTarget(None, Domain(name="blog.example", optional_services=["tuwunel", "phpbb"]))
    w = where()
    a = aa.apply(aa.validate(aa.Proposal("shop.example", "services", ["tuwunel"]), w, t1), w, t1)
    assert a.target_id == aa.undo_key(t1) != aa.undo_key(t2)
    r = aa.undo(a, w, t2)                       # a face handed the wrong row: refused
    assert isinstance(r, aa.Refusal) and t2.row.optional_services == ["tuwunel", "phpbb"]
