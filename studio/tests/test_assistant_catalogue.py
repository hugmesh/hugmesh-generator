"""core/assistant_catalogue: generated from the code, complete, and the pages json
regenerates identically.
"""
import dataclasses
import json
import os
import subprocess
import sys

from hugmesh_studio.core import assistant_actions as aa
from hugmesh_studio.core import assistant_catalogue as cat
from hugmesh_studio.core import brand_model, config, theme, theme_presets
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def test_every_field_of_every_scope_appears_exactly_once():
    dom = cat.catalogue("domain")
    for name in config.DOMAIN_FIELDS:
        assert sum(1 for o in dom if o.source == name) >= 1, name
    for key in ("services", "signin", "tor", "tailnet", "egress", "github_org"):
        assert sum(1 for o in dom if o.key == key) == 1, key
    for key in brand_model.LOOK_KEYS:
        assert sum(1 for o in dom if o.key == f"look.{key}") == 1, key
    mesh = cat.catalogue("mesh")
    for f in dataclasses.fields(LocalMeshBootstrapConfig):
        assert sum(1 for o in mesh if o.key == f.name) == 1, f.name
    img = cat.catalogue("image")
    for f in dataclasses.fields(config.ImageConfig):
        assert sum(1 for o in img if o.key == f.name) == 1, f.name
    assert len(cat.catalogue()) == len(dom) + len(mesh) + len(img)


def test_choices_come_from_the_code_tables():
    d = {o.key: o for o in cat.catalogue("domain")}
    assert d["services"].choices == tuple(config.OPTIONAL_SERVICES_CHOICES)
    assert d["signin"].choices == tuple(config.DOMAIN_IDP_CHOICES)
    assert d["provider"].choices == tuple(config.IDP_CHOICES) and "AWS Cognito" in d["provider"].doc
    assert d["look.preset"].choices == tuple(p.preset_id for p in theme_presets.PRESETS)
    assert d["look.mode"].choices == tuple(theme_presets.MODES)
    assert d["look.style"].choices == tuple(theme.STYLE_VARIANTS)
    assert d["look.decor"].choices == tuple(theme.DECOR_VARIANTS)
    assert [c.split(" (")[0] for c in d["look.bg_effect"].choices] == list(theme.BG_EFFECTS)
    assert any("not selectable yet" in c for c in d["look.bg_effect"].choices)
    assert d["tailnet"].choices == ("inherit", "on", "off") and d["egress"].choices == ("inherit", "vpn", "direct")
    assert d["look.primary"].kind == "colour" and d["tor"].kind == "bool"
    m = {o.key: o for o in cat.catalogue("mesh")}
    assert m["env"].choices == tuple(config.ENV_CHOICES) and m["services"].choices
    assert m["auth_key"].secret and m["egress_vpn_conf"].secret and m["login_theme_css"].secret
    i = {o.key: o for o in cat.catalogue("image")}
    assert i["mode"].choices == ("standalone", "cloud", "mesh")
    assert i["platform"].choices == ("x86", "rpi5", "frite", "jetson")
    assert i["idp"].choices == tuple(config.IDP_CHOICES)
    for name in config.SECRET_FIELDS:
        assert i[name].secret, name
    assert all(o.choices for o in cat.catalogue() if o.kind == "enum")


def test_the_pages_json_regenerates_identically_and_names_real_pages():
    with open(cat.PAGES_FILE, encoding="utf-8") as fh:
        have = json.load(fh)
    assert have == cat.compute_pages()
    assert "role" in have["mode"] and "domains" in have["domains"]
    r = subprocess.run([sys.executable, os.path.join(GENERATOR_DIR, "scripts", "local-ai", "catalogue-pages.py"),
                        "--check"], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr


def test_options_for_slices_by_page_and_puts_the_open_tab_first():
    class W:
        slug, tab = "domain_services", "ways"
    keys = [o.key for o in cat.options_for(W)]
    assert keys[:3] == ["tor", "tailnet", "egress"] and "services" in keys and "look.preset" in keys
    assert "github_org" not in keys
    W.tab = "look"
    assert cat.options_for(W)[0].key.startswith("look.")

    class M:
        slug, tab = "localmesh_services", ""
    mkeys = [o.key for o in cat.options_for(M)]
    assert "with_tor" in mkeys and "services" in mkeys and "env" not in mkeys

    class R:
        slug, tab = "role", ""
        cfg = config.ImageConfig()
    rkeys = [o.key for o in cat.options_for(R)]
    assert "mode" in rkeys and "role" in rkeys

    class N:
        slug, tab = "", ""
    assert cat.options_for(N) == []


def test_render_options_shows_current_values_and_never_a_secret():
    class W:
        slug, tab = "localmesh_env", ""
    opts = cat.options_for(W)
    text = cat.render_options(opts, current=lambda o: {"env": "prod", "auth_key": "tskey-LEAK"}.get(o.key))
    assert "- env (env): test | prod — test = LAN-only test mesh" in text and "| current: prod" in text
    assert "auth_key" in text and "(set, never shown)" in text and "LEAK" not in text
    assert cat.tokens(text) <= 600


def test_every_proposal_key_exists_in_the_catalogue_with_a_setter():
    for key, (scope, _route) in aa.FIELD_ROUTES.items():
        opt = cat.find(key.replace("@mesh", ""), scope)
        assert opt is not None and opt.setter, key


def test_catalogue_text_lists_the_eight_domain_keys_the_operator_asked_for():
    text = cat.catalogue_text("domain")
    for key in ("services", "signin", "tor", "tailnet", "egress", "look.preset", "look.primary", "github_org"):
        assert f"\n- {key} (" in text, key
    assert "the assistant can propose a change" in text and "set on the page, never shown" in cat.catalogue_text("mesh")
    assert cat.catalogue_text("nope").startswith("no such scope")
