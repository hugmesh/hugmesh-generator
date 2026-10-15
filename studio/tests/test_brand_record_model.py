"""The brand record itself (hugmesh-generator#654, D1-D5, D10, D20): Qt-free.

* the record round-trips and leaves every empty key out (older files keep their bytes);
* a pre-#654 mesh manifest loads as a record (migration);
* every id refusal of D4, each with its reason, and the default id;
* a planted token, a PEM block and a Tor key line fail the save, and nothing is written;
* the generated builder profile: safe values single-quoted, re-parsed strictly, a
  title with shell syntax refused, and a real bash harness sources it without running
  anything;
* the superbrand store: choosing a design COPIES it into the record, which never
  refers back to the store;
* set_ways is the one writer of the Tor way (the row's ``tor`` field);
* effective_look says where each value comes from, in the model's words;
* issuer ports are stored, never recomputed from position; BRAND_B owns 8001;
* the unaffiliated rule's fourth site: identity refused, look allowed;
* one id for every consumer: a stored id reaches the Tor key folder AND the sign-in
  registry, and a stored id the Docker mesh cannot honour yet is refused;
* one representation of the sign-in page's style: the look, read by show-record, the
  image config and the manifest header alike;
* the superbrand's Tor way is applied on the start path, and a flag that contradicts
  it is refused rather than overridden.
"""
from __future__ import annotations

import json
import os
import subprocess

import pytest

from hugmesh_studio.core import brand_model as bm
from hugmesh_studio.core import domain_services, own_casdoor, plain_words
from hugmesh_studio.core.config import (DOMAIN_IDP_OWN, Domain, ImageConfig,
                                        domain_from_record_row)
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


def _record() -> bm.BrandRecord:
    sb = bm.Superbrand(id="acme", title="Acme Mesh", org="example", public_name="mesh.example",
                       internal_root="acme.internal",
                       look={"primary": "#112233", "font": "System UI", "style": "glass"})
    shop = Domain(name="shop.mesh.example", title="Shop", idp=DOMAIN_IDP_OWN, tor=True,
                  look={"primary": "#aa0000"})
    blog = Domain(name="blog.mesh.example", title="Blog")
    return bm.BrandRecord(superbrand=sb, brands=[shop, blog])


# ── round trip and the old-bytes rule ─────────────────────────────────────────────
def test_record_round_trips_and_leaves_empty_keys_out(tmp_path):
    rec = _record()
    path = bm.save_record(rec, str(tmp_path / "brand-record.json"))
    text = open(path, encoding="utf-8").read()
    d = json.loads(text)
    assert d["schema"] == 1
    assert set(d["superbrand"]) == {"id", "title", "org", "public_name", "internal_root", "look"}
    assert "ways" not in d["superbrand"] and "central_signin" not in d["superbrand"]
    assert "look" not in d["brands"][1] and "tor" not in d["brands"][1]
    assert "issuer_port" not in d["brands"][0] and "id" not in d["brands"][0]
    assert "copied_from" not in d
    again = bm.load_record(path)
    assert again == rec
    # the same inputs write the same bytes — no clock value in the file
    assert open(bm.save_record(rec, str(tmp_path / "again.json")), encoding="utf-8").read() == text


def test_a_mesh_manifest_from_before_the_record_loads_as_one():
    manifest = {"brand": "acme", "brand_title": "Acme", "org": "example",
                "cluster_domain": "mesh.example", "superdomain": "acme.internal",
                "domains": [{"name": "shop.mesh.example", "title": "Shop",
                             "optional_services": [], "images": [], "idp": "own"}],
                "users": []}
    rec = bm.BrandRecord.from_dict(manifest)
    assert rec.superbrand.id == "acme" and rec.superbrand.internal_root == "acme.internal"
    assert rec.ids() == ["shop-mesh-example"]       # the id its running mesh already uses
    assert rec.brands[0].idp == DOMAIN_IDP_OWN


def test_a_newer_schema_is_refused_not_guessed():
    with pytest.raises(ValueError):
        bm.BrandRecord.from_dict({"schema": 99, "superbrand": {"id": "a"}, "brands": []})


def test_manifest_is_a_projection_of_the_record():
    rec = _record()                                  # its look says style glass
    m = bm.manifest_from_record(rec)
    assert m["brand"] == "acme" and m["superdomain"] == "acme.internal"
    assert m["cluster_domain"] == "mesh.example" and m["login_style"] == "glass"
    assert "login_decor" not in m
    assert m["domains"][0]["idp"] == "own" and "idp" not in m["domains"][1]
    # the same rows ImageConfig writes for the same brands
    cfg = ImageConfig(mode="mesh", role="omnibus", brand="acme", brand_title="Acme Mesh",
                      org="example", cluster_domain="mesh.example",
                      superdomain="acme.internal", login_style="glass",
                      domains=list(rec.brands))
    assert cfg.mesh_manifest()["domains"] == m["domains"]
    for k in ("brand", "brand_title", "org", "cluster_domain", "superdomain", "login_style"):
        assert cfg.mesh_manifest()[k] == m[k]


def test_image_config_and_record_convert_both_ways():
    cfg = ImageConfig(mode="mesh", role="omnibus", brand="acme", brand_title="Acme",
                      org="example", cluster_domain="mesh.example",
                      login_primary_color="#112233", login_style="sharp",
                      domains=[Domain(name="shop.mesh.example", look={"font": "System UI"})])
    rec = bm.record_from_image_config(cfg)
    assert rec.superbrand.look == {"primary": "#112233", "style": "sharp"}
    assert rec.brands[0].look == {"font": "System UI"}
    other = ImageConfig(mode="mesh", role="omnibus")
    bm.apply_record_to_image_config(rec, other)
    assert other.brand == "acme" and other.login_primary_color == "#112233"
    assert other.login_style == "sharp" and other.domains[0].look == {"font": "System UI"}
    assert other.additional_domains is True


def test_style_and_decor_have_one_representation_the_look():
    """show-record, the image config and the manifest header read the SAME value:
    a record whose look says glass gives cfg.login_style glass and a manifest header
    login_style glass (before this, two fields were never reconciled and show-record
    printed a style the image config never got)."""
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme", look={"style": "glass",
                                                                   "decor": "none"}))
    assert bm.record_problems(rec) == []
    assert bm.effective_look(rec)["style"] == ("glass", plain_words.LOOK_SOURCE["default"])
    assert rec.superbrand.login_style == "glass" and rec.superbrand.login_decor == "none"
    cfg = ImageConfig(mode="mesh", role="omnibus")
    bm.apply_record_to_image_config(rec, cfg)
    assert cfg.login_style == "glass" and cfg.login_decor == "none"
    m = bm.manifest_from_record(rec)
    assert m["login_style"] == "glass" and m["login_decor"] == "none"
    # the saved block carries the look only — no second key to disagree with it
    assert set(rec.superbrand.to_dict()) == {"id", "look"}
    # an early block with separate login_style/login_decor keys folds into the look,
    # and the look's own value wins when both are present
    early = bm.Superbrand.from_dict({"id": "acme", "login_style": "sharp",
                                     "login_decor": "none", "look": {"style": "glass"}})
    assert early.look == {"style": "glass", "decor": "none"} and early.login_style == "glass"
    # a pre-#654 manifest's header style lands in the look too
    old = bm.BrandRecord.from_dict({"brand": "acme", "login_style": "sharp", "domains": []})
    assert old.superbrand.look == {"style": "sharp"}
    # an unknown value is refused once, through the look
    bad = bm.BrandRecord(superbrand=bm.Superbrand(id="acme", look={"style": "wobbly"}))
    assert [p for p in bm.record_problems(bad) if "style" in p] == [
        "superbrand: unknown look.style ‘wobbly’"]


def test_an_empty_look_value_sets_nothing_on_the_image_config():
    """look.bg_effect "" passes validation (an empty value says nothing); applying it
    must not write "" into a field whose table has no "" (theme.BG_EFFECTS)."""
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme", look={"bg_effect": "",
                                                                   "primary": "#112233"}))
    assert bm.record_problems(rec) == []
    cfg = ImageConfig(mode="mesh", role="omnibus")
    before = cfg.login_bg_effect
    bm.apply_record_to_image_config(rec, cfg)
    assert cfg.login_bg_effect == before and cfg.login_primary_color == "#112233"


def test_a_record_that_says_nothing_about_a_field_leaves_the_image_config_alone():
    """One rule for every superbrand field: a record that carries no style, decoration
    or internal root name says nothing, so applying it keeps what the image config
    had (skeptic r1 C2: three fields were blanked while the others were kept)."""
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme", look={"primary": "#112233"}))
    cfg = ImageConfig(mode="mesh", role="omnibus", login_style="sharp", login_decor="none",
                      superdomain="core.acme.internal", brand_title="Kept")
    bm.apply_record_to_image_config(rec, cfg)
    assert (cfg.login_style, cfg.login_decor, cfg.superdomain, cfg.brand_title) == (
        "sharp", "none", "core.acme.internal", "Kept")
    assert cfg.brand == "acme" and cfg.login_primary_color == "#112233"
    # a record that DOES say something overrides, as before
    rec.superbrand.look.update({"style": "glass", "decor": "none"})
    rec.superbrand.internal_root = "acme.internal"
    bm.apply_record_to_image_config(rec, cfg)
    assert (cfg.login_style, cfg.superdomain) == ("glass", "acme.internal")


# ── the id rule (D4) ───────────────────────────────────────────────────────────────
@pytest.mark.parametrize("candidate,why", [
    ("", "needs an id"),
    ("Shop", "not a DNS label"),
    ("-shop", "not a DNS label"),
    ("shop-", "not a DNS label"),
    ("a" * 60, "not a DNS label"),
    ("sh/op", "not a DNS label"),
    ("sh.op", "not a DNS label"),
    ("default", "reserved"),
    ("domains", "reserved"),
    ("acme", "the superbrand's id"),
    ("shop-pki", "-pki"),
    ("example", "existing brands/example.conf profile"),
    ("blog", "already taken"),
])
def test_every_id_refusal_names_its_reason(candidate, why):
    p = bm.brand_id_problem(candidate, superbrand_id="acme", taken=("blog",),
                            profiles=bm.profile_names(GENERATOR_DIR))
    assert why in p, p


def test_a_good_id_passes_and_the_default_is_the_slug_of_the_public_name():
    assert bm.brand_id_problem("shop", superbrand_id="acme") == ""
    assert bm.brand_id_problem("a" * 59, superbrand_id="acme") == ""
    assert bm.brand_id(Domain(name="shop.mesh.example")) == "shop-mesh-example"
    assert bm.brand_id(Domain(name="shop.mesh.example", id="shop")) == "shop"
    assert bm.brand_id(Domain(name="shop.mesh.example", id="shop")) == own_casdoor.slug("shop")


def test_a_stored_id_reaches_every_consumer_or_is_refused():
    """D4: one text every consumer shares. The Tor key folder reads the stored id
    (this assertion is what the skeptics' surviving mutation lacked), own_casdoor's
    registry and overlay read it when given the ids mapping, and the two agree for one
    row. The Docker mesh's stack node does not pass that mapping yet, so a record
    whose stored id differs from the derived one is REFUSED with that reason, and a
    stored id equal to the derived one is accepted — every consumer then derives the
    same text."""
    row = Domain(name="shop.mesh.example", id="shop", idp=DOMAIN_IDP_OWN, tor=True)
    assert domain_services.onion_slug("shop.mesh.example", "shop") == "shop"
    assert domain_services.onion_slug("shop.mesh.example") == "shop-mesh-example"
    assert domain_services.onion_tenant(row) == "shop"
    ids = {"shop.mesh.example": "shop"}
    env = own_casdoor.tenancy_env(["shop.mesh.example"], "http://localhost:8000", ids=ids)
    assert env["APP_TENANCY_HOSTS"] == "shop.mesh.example=shop"
    assert env["APP_TENANCY_ISSUERS"].endswith(
        "http://casdoor-shop.localtest.me:8001=shop")
    overlay = own_casdoor.compose_overlay(["shop.mesh.example"], ids=ids)
    assert "  casdoor-shop:\n" in overlay and "casdoor-shop-pg:" in overlay
    assert "shop-mesh-example" not in overlay
    # the onion's tenant IS the tenant the registry maps the brand's host to
    registered = dict(h.split("=") for h in env["APP_TENANCY_HOSTS"].split(","))
    assert domain_services.onion_tenant(row) == registered["shop.mesh.example"]
    # without ids every function derives exactly what it did before
    assert own_casdoor.tenancy_env(["a.example"], "http://x") == own_casdoor.tenancy_env(
        ["a.example"], "http://x", ids={})
    assert own_casdoor.compose_overlay(["a.example"]) == own_casdoor.compose_overlay(
        ["a.example"], ids=None)
    # the record refuses the split while the stack node derives
    rec = _record()
    rec.brands[0].id = "shop"
    problems = bm.record_problems(rec)
    assert problems == ["brand shop.mesh.example: its stored id ‘shop’ differs from the id "
                        "its public name derives (‘shop-mesh-example’); "
                        + bm.STORED_ID_MUST_MATCH]
    assert bm.stored_id_problem(rec.brands[0]) and bm.STORED_ID_MUST_MATCH in bm.stored_id_problem(rec.brands[0])
    rec.brands[0].id = "shop-mesh-example"
    assert bm.record_problems(rec) == [] and bm.stored_id_problem(rec.brands[0]) == ""
    assert bm.stored_id_problem(Domain(name="shop.mesh.example")) == ""


def test_a_recorded_row_with_an_empty_sign_in_takes_the_default():
    """The lenient loader's empty-idp branch (a hand-edited saved mesh)."""
    assert domain_from_record_row({"name": "a.example", "idp": ""}).idp == "superdomain"
    assert domain_from_record_row({"name": "a.example", "idp": None}).idp == "superdomain"
    assert domain_from_record_row({"name": "a.example", "idp": "own"}).idp == "own"


def test_profile_names_read_the_brands_folder_minus_the_ca_registry():
    names = bm.profile_names(GENERATOR_DIR)
    assert "example" in names and "local" in names and "domains" not in names


def test_record_problems_refuses_a_duplicate_id_and_a_port_on_a_superbrand_signin():
    rec = _record()
    rec.brands.append(Domain(name="shop2.mesh.example", id="shop-mesh-example"))
    rec.brands[1].issuer_port = 8003            # blog signs in through the superbrand
    problems = bm.record_problems(rec)
    assert any("already taken" in p for p in problems)
    assert any("takes no sign-in port" in p for p in problems)


# ── the secret scan (D5) ───────────────────────────────────────────────────────────
@pytest.mark.parametrize("planted,why", [
    ("tskey-auth-k1234567890abcdefXYZ-rest", "token-shaped"),
    ("ghp_" + "a" * 36, "token-shaped"),
    ("-----BEGIN PRIVATE KEY-----\nMIIE...\n-----END PRIVATE KEY-----", "PEM block"),
    ("== ed25519v1-secret: type0 ==", "Tor key line"),
    ("ED25519-V3:abcdef0123456789", "Tor key line"),
    ("eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.c2lnbmF0dXJlLXNpZ25hdHVyZQ", "token-shaped"),
    ("A" * 20 + "0" * 24, "long opaque"),
])
def test_a_planted_secret_fails_the_save_and_writes_nothing(tmp_path, planted, why):
    rec = _record()
    rec.superbrand.ways = {"public": {"provider": "duckdns", "inputs": {"note": planted},
                                      "token_file": "/run/secrets/duckdns"}}
    path = str(tmp_path / "brand-record.json")
    with pytest.raises(bm.RecordRefused) as ei:
        bm.save_record(rec, path)
    assert any(why in p for p in ei.value.problems), ei.value.problems
    assert not os.path.exists(path) and not os.path.exists(path + ".tmp")


def test_a_value_under_a_secret_named_key_is_refused_but_a_file_pointer_is_not():
    assert bm.secret_problems({"api_token": "abc"}) == ["record.api_token: a value under a "
                                                        "key that names a secret"]
    assert bm.secret_problems({"token_file": "/run/secrets/duckdns"}) == []
    # public things that LOOK long are not tokens: a Tor address, a URL, a path
    onion = "a" * 40 + "0" * 16 + ".onion"
    assert bm.secret_problems({"x": onion}) == []
    assert bm.secret_problems({"x": "https://example/" + "a1" * 30}) == []
    assert bm.secret_problems({"x": "/var/lib/" + "a1" * 30}) == []


# ── the generated builder profile (D5) ─────────────────────────────────────────────
def test_builder_profile_is_single_quoted_and_re_parses_strictly():
    rec = _record()
    text = bm.builder_profile(rec)
    assert "BRAND='acme'" in text and "BRAND_TITLE='Acme Mesh'" in text
    assert "SUPERDOMAIN='acme.internal'" in text
    assert "TOR_BRANDS='shop-mesh-example=shop-mesh-example'" in text
    parsed = bm.parse_builder_profile(text)
    assert parsed["BRANDS"] == "shop-mesh-example blog-mesh-example"
    # a line that is not KEY='safe value' is refused by the strict reader
    for bad in ("BRAND=acme", "BRAND='a'; touch x", "BRAND='$(touch x)'",
                "x() { :; }", "BRAND=\"acme\""):
        with pytest.raises(ValueError):
            bm.parse_builder_profile(text + bad + "\n")


@pytest.mark.parametrize("title", ["$(touch /tmp/x)", "Acme `id`", "O'Brien", 'Say "hi"',
                                   "a\\b", "x; rm -rf y", "line\nbreak", "A&B", "f(x)"])
def test_a_title_with_shell_syntax_is_refused_and_no_profile_is_written(tmp_path, title):
    rec = _record()
    rec.superbrand.title = title
    with pytest.raises(bm.ProfileRefused) as ei:
        bm.builder_profile(rec)
    assert any("BRAND_TITLE" in p for p in ei.value.problems)
    # the CLI verb writes NOTHING on a refusal
    path = str(tmp_path / "rec.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(rec.to_dict(), fh)          # bypassing save_record on purpose
    out = str(tmp_path / "profile.conf")
    rc = bm.main(["profile", "--record", path, "--out", out])
    assert rc == 1 and not os.path.exists(out)


def test_a_bash_harness_sources_the_profile_and_runs_nothing(tmp_path):
    """The real consumer: a builder `source`s the profile. Under set -eu with a
    sentinel the harness proves the values arrive verbatim and no command ran."""
    rec = _record()
    rec.superbrand.title = "Acme Mesh, v2: a/b @home +plus"
    prof = tmp_path / "brand.profile"
    prof.write_text(bm.builder_profile(rec), encoding="utf-8")
    sentinel = tmp_path / "ran"
    script = ("set -eu; . \"$1\"; printf '%s\\n%s\\n%s\\n' \"$BRAND\" \"$BRAND_TITLE\" "
              "\"$SUPERDOMAIN\"; [ ! -e \"$2\" ]")
    r = subprocess.run(["bash", "-c", script, "harness", str(prof), str(sentinel)],
                       capture_output=True, text=True, timeout=30)
    assert r.returncode == 0, r.stderr
    assert r.stdout.splitlines() == ["acme", "Acme Mesh, v2: a/b @home +plus", "acme.internal"]
    assert bm.parse_builder_profile(prof.read_text(encoding="utf-8"))["BRAND_TITLE"] == \
        rec.superbrand.title


def test_branding_dir_writes_strict_key_value_and_refuses_a_quote(tmp_path):
    rec = _record()
    path = bm.write_branding_dir(rec, str(tmp_path / "branding"))
    assert open(path, encoding="utf-8").read().splitlines()[1:] == [
        'BRAND_NAME="acme"', 'BRAND_TITLE="Acme Mesh"', 'ACCENT_COLOR="#112233"']
    rec.superbrand.title = 'Acme "Mesh"'
    with pytest.raises(bm.RecordRefused):
        bm.write_branding_dir(rec, str(tmp_path / "branding2"))
    assert not os.path.exists(tmp_path / "branding2" / "brand.conf")


# ── the superbrand store (D5) ──────────────────────────────────────────────────────
def test_choosing_a_design_copies_it_and_later_edits_change_no_record(tmp_path, monkeypatch):
    """A design is a superbrand's title, organisation and look — what one would reuse
    on another mesh. Choosing it copies those three; the mesh's own identity (id,
    public name, internal root name, central sign-in) and its ways stay (skeptic r1
    C1: a design with no id used to leave the record unsaveable, and one with another
    id used to replace the mesh's)."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    design = bm.Superbrand(id="other", public_name="other.example", title="Acme Mesh",
                           org="example", look={"primary": "#112233"})
    path = bm.save_design("acme-blue", design)
    assert bm.list_designs() == ["acme-blue"]
    # the stored file holds the design's three fields, nothing that names a mesh
    assert set(json.load(open(path, encoding="utf-8"))) == {"title", "org", "look"}
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme", public_name="mesh.example",
                                                  internal_root="acme.internal",
                                                  ways={"tor": True}))
    bm.choose_design(rec, "acme-blue", "2026-10-14")
    assert rec.superbrand.look == {"primary": "#112233"}
    assert (rec.superbrand.title, rec.superbrand.org) == ("Acme Mesh", "example")
    assert (rec.superbrand.id, rec.superbrand.public_name, rec.superbrand.internal_root,
            rec.superbrand.ways) == ("acme", "mesh.example", "acme.internal", {"tor": True})
    assert rec.copied_from == {"design": "acme-blue", "date": "2026-10-14"}
    # the stored design changes; the record does not — and the loaded copy is not
    # the record's object either
    design.look["primary"] = "#ff0000"
    bm.save_design("acme-blue", design)
    assert rec.superbrand.look == {"primary": "#112233"}
    loaded = bm.load_design("acme-blue")
    loaded.look["primary"] = "#00ff00"
    assert rec.superbrand.look == {"primary": "#112233"}
    text = open(bm.save_record(rec, str(tmp_path / "r.json")), encoding="utf-8").read()
    assert "acme-blue" in text and "#ff0000" not in text and "other.example" not in text
    with pytest.raises(ValueError):
        bm.choose_design(rec, "acme-blue", "today")      # the date is an input, YYYY-MM-DD
    with pytest.raises(ValueError):
        bm.save_design("../evil", design)


def test_record_path_is_in_the_studio_state_folder(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    assert bm.record_path() == str(tmp_path / "state" / "brand-record.json")
    assert bm.designs_dir() == str(tmp_path / "state" / "superbrands")


# ── the look and the ways (D7, D10) ────────────────────────────────────────────────
def test_effective_look_names_the_source_of_each_value():
    rec = _record()
    shop = rec.brands[0]
    look = bm.effective_look(rec, shop)
    assert look["primary"] == ("#aa0000", plain_words.LOOK_SOURCE["own"])
    assert look["font"] == ("System UI", plain_words.LOOK_SOURCE["inherited"])
    assert look["decor"] == ("", plain_words.LOOK_SOURCE["inherited"])
    assert bm.effective_look(rec)["primary"] == ("#112233", plain_words.LOOK_SOURCE["default"])


def test_the_look_problems_refuse_unknown_keys_and_values():
    assert bm.look_problems({"primary": "#112233", "style": "glass"}, "x") == []
    bad = bm.look_problems({"colour": "#1", "primary": "red", "preset": "nope",
                            "mode": "dim", "font": "Comic", "style": "wobbly",
                            "decor": "bells", "bg_effect": "lava"}, "x")
    assert len(bad) == 8


def test_set_ways_is_the_one_writer_and_writes_the_tor_field(tmp_path):
    rec = _record()
    assert bm.set_ways(rec, "blog-mesh-example", internal_name="blog.acme.internal",
                       tor=True, public={"provider": "duckdns", "inputs": {"host": "blog"},
                                         "token_file": "/run/secrets/duckdns"}) == []
    blog = rec.brand("blog-mesh-example")
    assert blog.tor is True                          # the SAME field the manifest reads
    assert blog.ways["internal_name"] == "blog.acme.internal"
    assert bm.manifest_from_record(rec)["domains"][1]["tor"] is True
    # refused: a name outside the internal root, a token in the inputs, an unknown brand
    assert bm.set_ways(rec, "blog-mesh-example", internal_name="blog.other.internal")
    before = dict(blog.ways)
    assert bm.set_ways(rec, "blog-mesh-example",
                       public={"provider": "duckdns",
                               "inputs": {"token": "ghp_" + "a" * 36}})
    assert blog.ways == before                       # nothing written on a refusal
    assert bm.set_ways(rec, "nobody") == ["no brand with id ‘nobody’ in this record"]
    # the superbrand's own ways
    assert bm.set_ways(rec, "acme", tor=True) == []
    assert rec.superbrand.ways["tor"] is True
    # a brand's Tor address is its tor field: a tor key in a brand's ways is a second
    # place saying the same thing, and is refused by name
    assert bm.ways_problems({"tor": True}, "brand x") == [
        "brand x: unknown way ‘tor’ (internal_name, public); a brand's Tor address is "
        "its tor field, written by set_ways"]
    assert bm.ways_problems({"tor": True}, "superbrand", superbrand=True) == []
    assert bm.ways_problems({"tor": "yes"}, "superbrand", superbrand=True) == [
        "superbrand: ways.tor must be yes or no (true/false)"]
    assert bm.ways_problems({"other": 1}, "superbrand", superbrand=True) == [
        "superbrand: unknown way ‘other’ (internal_name, public, tor)"]
    rec.brands[0].ways = {"tor": True}
    assert any("a brand's Tor address is its tor field" in p for p in bm.record_problems(rec))


def test_the_superbrands_tor_way_drives_the_start_path_and_a_contradicting_flag_is_refused():
    """What show-record prints and what up --record starts are ONE answer: the
    record's ways.tor becomes with_tor; a flag saying the opposite is refused, never
    silently overridden; a record without the key leaves the flags alone."""
    rec = _record()
    assert bm.set_ways(rec, "acme", tor=True) == []
    cfg = LocalMeshBootstrapConfig()
    bm.apply_record_to_bootstrap(rec, cfg)
    assert cfg.with_tor is True and cfg.effective_with_tor() is True
    assert bm.record_from_bootstrap(cfg).superbrand.ways["tor"] is True
    # a matching selection is fine; one that leaves tor out contradicts the record
    bm.apply_record_to_bootstrap(rec, LocalMeshBootstrapConfig(services=("tor",)))
    with pytest.raises(ValueError, match="leaves out tor"):
        bm.apply_record_to_bootstrap(rec, LocalMeshBootstrapConfig(services=("tuwunel",)))
    # the record says no: --with-tor contradicts it; a selection naming tor too
    assert bm.set_ways(rec, "acme", tor=False) == []
    off = LocalMeshBootstrapConfig(with_tor=True)
    with pytest.raises(ValueError, match="--with-tor was given"):
        bm.apply_record_to_bootstrap(rec, off)
    assert off.brand != "acme"                     # nothing applied on a refusal
    with pytest.raises(ValueError, match="names tor"):
        bm.apply_record_to_bootstrap(rec, LocalMeshBootstrapConfig(services=("tor",)))
    plain = LocalMeshBootstrapConfig()
    bm.apply_record_to_bootstrap(rec, plain)
    assert plain.with_tor is False
    # no way recorded: the flags are the caller's
    rec.superbrand.ways = {}
    kept = LocalMeshBootstrapConfig(with_tor=True)
    bm.apply_record_to_bootstrap(rec, kept)
    assert kept.with_tor is True


def test_way_effects_cover_every_way_on_every_path_in_the_models_words():
    rec = _record()
    eff = bm.way_effects(rec, rec.brands[0])
    assert len(eff) == len(plain_words.WAYS) * len(plain_words.PATHS)
    assert ("Tor address", "yes", "Docker mesh", plain_words.WAY_EFFECT[("tor", "docker")]) in eff
    assert ("internal name", "shop-mesh-example.acme.internal", "node image",
            plain_words.WAY_EFFECT[("internal_name", "image")]) in eff


# ── issuer ports (D4) ──────────────────────────────────────────────────────────────
def test_issuer_ports_are_stored_and_never_recomputed_from_position():
    rec = _record()
    rec.brands.append(Domain(name="forum.mesh.example", idp=DOMAIN_IDP_OWN))
    ports = bm.store_issuer_ports(rec)
    assert ports == {"shop.mesh.example": 8001, "forum.mesh.example": 8002}
    # remove the first own brand: the second KEEPS its port
    rec.brands = [d for d in rec.brands if d.name != "shop.mesh.example"]
    assert bm.issuer_ports(rec) == {"forum.mesh.example": 8002}
    # a new own brand takes the first free port, not the removed brand's by position
    rec.brands.append(Domain(name="wiki.mesh.example", idp=DOMAIN_IDP_OWN))
    assert bm.issuer_ports(rec) == {"forum.mesh.example": 8002, "wiki.mesh.example": 8001}


def test_brand_b_owns_8001_so_studio_brands_start_at_8002():
    assert own_casdoor.ports_for(["a", "b"], brand_b=True) == {"a": 8002, "b": 8003}
    assert own_casdoor.ports_for(["a", "b"]) == {"a": 8001, "b": 8002}
    # a stored port below the base (8001 while BRAND_B is set) is re-allocated
    assert own_casdoor.ports_for(["a"], {"a": 8001}, brand_b=True) == {"a": 8002}
    # two names claiming one stored port: the first keeps it
    assert own_casdoor.ports_for(["a", "b"], {"a": 8005, "b": 8005}) == {"a": 8005, "b": 8001}
    env = own_casdoor.tenancy_env(["a.example"], "http://localhost:8000", {"a.example": 8007})
    assert "casdoor-a-example.localtest.me:8007=a-example" in env["APP_TENANCY_ISSUERS"]
    assert '"8007:8000"' in own_casdoor.compose_overlay(["a.example"], {"a.example": 8007})
    # without a mapping the table-position rule is byte-identical to before
    assert own_casdoor.compose_overlay(["a.example"]) == own_casdoor.compose_overlay(
        ["a.example"], {})


def test_the_sign_in_port_line_says_what_the_docker_mesh_does_today():
    """The stored port is RECORDED; the stack node still publishes by table position,
    so show-record never calls a stored port effective when the mesh will not use it."""
    own = ["shop.mesh.example", "forum.mesh.example"]
    assert bm.sign_in_port_sentence(Domain(name="shop.mesh.example", idp=DOMAIN_IDP_OWN,
                                           issuer_port=8002), own) == (
        "sign-in port 8002 recorded — the Docker mesh still publishes it at 8001 (by "
        "table position) until the mesh reads the record")
    assert bm.sign_in_port_sentence(Domain(name="forum.mesh.example", idp=DOMAIN_IDP_OWN,
                                           issuer_port=8002), own) == (
        "sign-in port 8002 (recorded; the Docker mesh publishes it there too)")
    assert bm.sign_in_port_sentence(Domain(name="forum.mesh.example", idp=DOMAIN_IDP_OWN),
                                    own) == (
        "sign-in port 8002 on the Docker mesh (by table position; none recorded)")
    lines = "\n".join(bm.show_record_lines(_record()))
    assert "sign-in port 8001 on the Docker mesh (by table position; none recorded)" in lines


# ── the unaffiliated rule (D20) ────────────────────────────────────────────────────
def test_unaffiliated_refuses_identity_and_allows_look():
    look_only = bm.BrandRecord(superbrand=bm.Superbrand(id="hugmesh",
                                                        look={"primary": "#112233"}))
    assert bm.record_problems(look_only, unaffiliated=True) == []
    assert any("no brand identity" in p
               for p in bm.record_problems(_record(), unaffiliated=True))
    titled = bm.BrandRecord(superbrand=bm.Superbrand(id="hugmesh", title="Acme"))
    assert any("no brand identity" in p for p in bm.record_problems(titled, unaffiliated=True))


# ── the bootstrap config carries the record ────────────────────────────────────────
def test_bootstrap_config_and_record_convert_both_ways():
    rec = _record()
    rec.superbrand.central_signin = "http://localhost:8000"
    cfg = LocalMeshBootstrapConfig()
    bm.apply_record_to_bootstrap(rec, cfg)
    assert cfg.brand == "acme" and cfg.cluster_domain == "mesh.example"
    assert cfg.own_idp_domains == ("shop.mesh.example",)
    assert cfg.superbrand["title"] == "Acme Mesh" and "id" not in cfg.superbrand
    assert cfg.domains[0]["look"] == {"primary": "#aa0000"} and cfg.domains[0]["tor"] is True
    again = bm.record_from_bootstrap(cfg)
    assert again.superbrand.id == "acme" and again.superbrand.look == rec.superbrand.look
    assert [d.name for d in again.brands] == [d.name for d in rec.brands]
    assert again.brands[0].look == {"primary": "#aa0000"}
    # the record of a pre-#654 config is the plain default superbrand, no brands
    plain = bm.record_from_bootstrap(LocalMeshBootstrapConfig())
    assert plain.superbrand.id == "hugmesh" and plain.brands == []


# ── round 2 findings: what the Docker start reads is the record's own-sign-in list ──
def _own_cfg(rows, own_idp):
    return LocalMeshBootstrapConfig(
        brand="acme", cluster_domain="mesh.example", own_idp_domains=tuple(own_idp),
        domains=tuple({"name": n, "title": "", "idp": idp, "optional_services": []}
                      for n, idp in rows))


def test_own_idp_domains_wins_over_what_a_recorded_row_says_about_sign_in():
    """The compose lane registers a sign-in for exactly the names in own_idp_domains.
    A row that says 'own' for a name that is not in the list therefore signs in
    through the superbrand on the running mesh, and must not take a port in
    show-record (it used to, and shifted every later brand's port)."""
    cfg = _own_cfg([("ghost.mesh.example", DOMAIN_IDP_OWN),
                    ("real.mesh.example", "superdomain")], ["real.mesh.example"])
    rec = bm.record_from_bootstrap(cfg)
    by_name = {d.name: d for d in rec.brands}
    assert by_name["ghost.mesh.example"].idp == "superdomain"
    assert by_name["real.mesh.example"].idp == DOMAIN_IDP_OWN
    assert bm.issuer_ports(rec) == {"real.mesh.example": 8001}


def test_own_sign_in_rows_follow_the_own_idp_domains_order_not_the_recorded_order():
    """Recorded rows alpha, zed; own_idp_domains (zed, alpha): the plan and the stack
    node give zed the first port, so the record must list zed first or show-record
    prints alpha on 8001."""
    cfg = _own_cfg([("alpha.mesh.example", DOMAIN_IDP_OWN),
                    ("mid.mesh.example", "superdomain"),
                    ("zed.mesh.example", DOMAIN_IDP_OWN)],
                   ["zed.mesh.example", "alpha.mesh.example"])
    rec = bm.record_from_bootstrap(cfg)
    assert [d.name for d in rec.brands if d.idp == DOMAIN_IDP_OWN] == [
        "zed.mesh.example", "alpha.mesh.example"]
    assert bm.issuer_ports(rec) == {"zed.mesh.example": 8001, "alpha.mesh.example": 8002}
    # a row that is not an own sign-in keeps its place between them
    assert [d.name for d in rec.brands][1] == "mid.mesh.example"


def test_choosing_a_design_that_has_only_a_look_keeps_the_title_and_organisation(
        tmp_path, monkeypatch):
    """A design file carries only the keys it was saved with. Copying one that has a
    look and nothing else must not blank the record's title and organisation."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    bm.save_design("only-look", bm.Superbrand(look={"primary": "#112233"}))
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme", title="Acme Mesh", org="example",
                                                  public_name="mesh.example",
                                                  look={"primary": "#ffffff"}))
    bm.choose_design(rec, "only-look", "2026-10-14")
    assert rec.superbrand.look == {"primary": "#112233"}
    assert (rec.superbrand.title, rec.superbrand.org) == ("Acme Mesh", "example")
    # a design that DOES carry a title still replaces it
    bm.save_design("with-title", bm.Superbrand(title="Other Title", look={"primary": "#000000"}))
    bm.choose_design(rec, "with-title", "2026-10-14")
    assert rec.superbrand.title == "Other Title" and rec.superbrand.org == "example"


def test_a_superbrand_id_may_name_a_profile_but_not_be_reserved_or_end_in_pki():
    """record_problems checks the superbrand id with no profile list on purpose: the
    superbrand IS usually the profile brands/<id>.conf names (the dead 'names an
    existing' branch is gone). Every other id rule still applies to it."""
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="hugmesh", public_name="m.example"))
    assert bm.record_problems(rec, profiles=("hugmesh",)) == []
    for bad in ("default", "domains", "acme-pki"):
        rec.superbrand.id = bad
        probs = bm.record_problems(rec, profiles=(bad,))
        assert len(probs) == 1 and probs[0].startswith("superbrand: "), (bad, probs)
