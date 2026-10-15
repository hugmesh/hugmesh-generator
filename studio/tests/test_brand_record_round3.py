"""Round 3 of the brand record's guards (hugmesh-generator#654), Qt-free. Each test pins
one defect the skeptics measured on the last head, and each was shown red under the
change that breaks it (see the commit message):

* ``--record`` with a ``--brand`` or ``--own-casdoor-domain`` that says something else
  is refused, like ``--cluster-domain`` and ``--with-tor`` already were, instead of the
  record silently winning (a different Vault path, a different set of own sign-ins);
* a legal 40-character design name copied into the record can still be saved;
* four guards no test used to fail for: a stored own-sign-in port at the first port,
  the Docker start accepting a superbrand title with an apostrophe, a commit that
  writes nothing while the record is refused, and a test mesh keeping no public name.
"""
from __future__ import annotations

import json
import os
import types

import pytest

from hugmesh_studio.core import brand_model as bm
from hugmesh_studio.core import local_mesh_bootstrap as lmb
from hugmesh_studio.core import own_casdoor
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)
from hugmesh_studio.core.local_mesh_domains import LocalMeshDomains
from hugmesh_studio.tui.localmesh import sync_brand_session
from hugmesh_studio.tui.superbrand_step import session_for

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)


@pytest.fixture(autouse=True)
def _state(tmp_path, monkeypatch):
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))


def _record_file(tmp_path, *, own=("shop.mesh.example",)) -> str:
    rec = bm.BrandRecord(
        superbrand=bm.Superbrand(id="acme", title="Acme Mesh", public_name="mesh.example"),
        brands=[Domain(name=n, title="Shop", idp=DOMAIN_IDP_OWN) for n in own]
        + [Domain(name="blog.mesh.example", idp="superdomain")])
    return bm.save_record(rec, str(tmp_path / "rec.json"))


# ── 1. the record never silently beats a flag that says something else ─────────────
def test_a_typed_brand_that_differs_from_the_record_is_refused(tmp_path, capsys):
    path = _record_file(tmp_path)
    rc = lmb.main(["plan", "--generator-dir", GENERATOR_DIR, "--record", path,
                   "--brand", "other"])
    err = capsys.readouterr().err
    assert rc == 2 and "acme" in err and "--brand other" in err, err
    # the same brand on both sides is no contradiction
    assert lmb.main(["plan", "--generator-dir", GENERATOR_DIR, "--record", path,
                     "--brand", "acme"]) == 0
    assert "Brand:      acme" in capsys.readouterr().out
    # and no --brand at all (the default) leaves the record to name it
    assert lmb.main(["plan", "--generator-dir", GENERATOR_DIR, "--record", path]) == 0
    assert "Brand:      acme" in capsys.readouterr().out


@pytest.mark.parametrize("typed,words", [
    (["blog.mesh.example"], "blog.mesh.example"),                   # one the record lacks
    (["shop.mesh.example", "blog.mesh.example"], "blog.mesh.example"),
    (["other.example"], "other.example"),
])
def test_an_own_signin_set_that_differs_from_the_record_is_refused(
        tmp_path, capsys, typed, words):
    path = _record_file(tmp_path)
    argv = ["plan", "--generator-dir", GENERATOR_DIR, "--record", path]
    for name in typed:
        argv += ["--own-casdoor-domain", name]
    rc = lmb.main(argv)
    err = capsys.readouterr().err
    assert rc == 2 and words in err and "own sign-in" in err, err


def test_an_own_signin_set_the_record_does_not_have_is_refused_both_ways(tmp_path, capsys):
    # the record gives shop its own sign-in; the flags name none of the record's
    path = _record_file(tmp_path)
    rc = lmb.main(["plan", "--generator-dir", GENERATOR_DIR, "--record", path,
                   "--own-casdoor-domain", "blog.mesh.example"])
    assert rc == 2 and "shop.mesh.example" in capsys.readouterr().err
    # a record with NO own sign-in refuses any typed one
    none = _record_file(tmp_path, own=())
    rc = lmb.main(["plan", "--generator-dir", GENERATOR_DIR, "--record", none,
                   "--own-casdoor-domain", "shop.mesh.example"])
    assert rc == 2 and "shop.mesh.example" in capsys.readouterr().err


def test_the_same_own_signin_set_in_any_order_is_no_contradiction(tmp_path, capsys):
    path = _record_file(tmp_path, own=("shop.mesh.example", "club.mesh.example"))
    rc = lmb.main(["plan", "--generator-dir", GENERATOR_DIR, "--record", path,
                   "--own-casdoor-domain", "club.mesh.example",
                   "--own-casdoor-domain", "shop.mesh.example"])
    out = capsys.readouterr().out
    assert rc == 0 and "shop.mesh.example" in out and "club.mesh.example" in out, out


def test_a_refusal_applies_nothing_to_the_config(tmp_path):
    rec = bm.load_record(_record_file(tmp_path))
    rec.superbrand.ways = {"tor": True}
    cfg = LocalMeshBootstrapConfig(brand="other", own_idp_domains=("blog.mesh.example",))
    with pytest.raises(ValueError, match="--brand other"):
        bm.apply_record_to_bootstrap(rec, cfg)
    assert cfg.brand == "other" and cfg.with_tor is False and not cfg.superbrand
    assert cfg.domains == () and cfg.own_idp_domains == ("blog.mesh.example",)
    # the cluster-domain refusal comes after the Tor way was read: it must not leave it set
    rec.superbrand.public_name = "mesh.example"
    cfg2 = LocalMeshBootstrapConfig(cluster_domain="real.example")
    with pytest.raises(ValueError, match="real.example"):
        bm.apply_record_to_bootstrap(rec, cfg2)
    assert cfg2.with_tor is False and cfg2.brand == "hugmesh"


def test_the_studios_own_screens_may_replace_the_brand_and_the_own_signin_set(tmp_path):
    rec = bm.load_record(_record_file(tmp_path))
    cfg = LocalMeshBootstrapConfig(brand="other", own_idp_domains=("blog.mesh.example",))
    bm.apply_record_to_bootstrap(rec, cfg, typed_flags=False)
    assert cfg.brand == "acme" and cfg.own_idp_domains == ("shop.mesh.example",)


def test_the_default_brand_the_check_skips_is_the_bootstraps_default():
    assert bm._BOOTSTRAP_DEFAULT_BRAND == lmb.DEFAULT_BRAND


# ── 2. a legal 40-character design name is no secret ────────────────────────────────
def test_a_forty_character_design_name_copied_into_the_record_can_be_saved(tmp_path):
    name = "design-2026-abcdefghijklmnopqrstuvwxyz12"
    assert len(name) == 40 and bm._DESIGN_NAME_RE.fullmatch(name)
    bm.save_design(name, bm.Superbrand(id="x", title="A look", look={"primary": "#112233"}))
    rec = bm.BrandRecord(superbrand=bm.Superbrand(id="acme"))
    bm.choose_design(rec, name, "2026-10-15")
    assert bm.secret_problems(rec.to_dict()) == []
    path = bm.save_record(rec, str(tmp_path / "r.json"))
    assert bm.load_record(path).copied_from["design"] == name
    # a dashless run of letters and digits, the other legal 40-character shape
    flat = "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0"
    assert bm.secret_problems({"copied_from": {"design": flat, "date": "2026-10-15"}}) == []


def test_a_secret_under_the_design_key_is_still_refused():
    # the exemption is the design NAME rule, not the key: a real token shape, and a
    # value no design name could be, are refused where they sit
    assert bm.secret_problems({"copied_from": {"design": "ghp_" + "a1" * 12}})
    assert bm.secret_problems({"copied_from": {"design": "A1" * 25}})
    # the key is only exempt under copied_from
    assert bm.secret_problems({"look": {"design": "a1b2c3d4e5f6a7b8c9d0a1b2c3d4e5f6a7b8c9d0"}})


# ── 3. four guards a mutation used to leave standing ───────────────────────────────
def test_a_stored_port_at_the_first_own_signin_port_is_kept_when_the_list_is_reordered():
    assert own_casdoor.ports_for(["b", "a"], {"a": 8001}) == {"a": 8001, "b": 8002}
    # brand B owns the first port, so the first own sign-in port is the next one: a port
    # stored at exactly that is kept, and one below it (B's) is not
    assert own_casdoor.ports_for(["b", "a"], {"a": 8002}, brand_b=True) == \
        {"a": 8002, "b": 8003}
    assert own_casdoor.ports_for(["a"], {"a": 8001}, brand_b=True) == {"a": 8002}


def test_the_docker_start_accepts_a_superbrand_title_with_an_apostrophe():
    sb = bm.Superbrand(id="acme", title="Bob's Shop")
    rec = bm.BrandRecord(superbrand=sb)
    assert bm.record_problems(rec, docker_start=True) == []
    assert any("title" in p.lower() or "apostrophe" in p.lower() or "’" in p
               for p in bm.record_problems(rec)), "the strict form must still refuse it"
    cfg = LocalMeshBootstrapConfig(brand="acme", superbrand={"title": "Bob's Shop"})
    assert not [p for p in LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()
                if "brand record" in p.lower()], LocalMeshBootstrap(GENERATOR_DIR, cfg).validate()


def _docker_session(env="test", domain=""):
    boot = LocalMeshBootstrapConfig(env=env, cluster_domain=domain)
    state = LocalMeshDomains(domains=[Domain(name=domain or "hugmesh.net")],
                             own_name=domain or "hugmesh.net")
    return boot, state, session_for(types.SimpleNamespace(), "docker", (boot, state),
                                    GENERATOR_DIR)


def test_a_commit_writes_nothing_while_the_record_is_refused(tmp_path):
    boot, state, s = _docker_session()
    state.domains.append(Domain(name="x.mesh.example", id="default"))   # a reserved id
    assert s.set_identity("id", "acme") == ""
    problems = s.commit(save=True)
    assert problems and any("reserved" in p for p in problems), problems
    assert boot.brand == "hugmesh" and not boot.superbrand        # the carrier is untouched
    assert not os.path.exists(bm.record_path())                   # and so is the file


def test_a_test_mesh_keeps_no_public_name_even_when_a_domain_was_typed():
    boot, state, s = _docker_session(env="test", domain="typed.example")
    s.set_identity("id", "acme")
    sync_brand_session(s, boot)
    assert s.sb.public_name == "" and s.sb.central_signin == "", (
        s.sb.public_name, s.sb.central_signin)
    # the production mesh's own name is still taken from the page
    boot2, state2, s2 = _docker_session(env="prod", domain="typed.example")
    s2.set_identity("id", "acme")
    sync_brand_session(s2, boot2)
    assert s2.sb.public_name == "typed.example"


@pytest.mark.parametrize("body", [{"brands": 5}, {"superbrand": ["x"]}, [1, 2]])
def test_a_record_file_with_the_wrong_shape_is_refused_with_a_sentence(tmp_path, capsys, body):
    path = tmp_path / "bad.json"
    path.write_text(json.dumps(body))
    for verb in ("show-record", "plan"):
        rc = lmb.main([verb, "--record", str(path), "--generator-dir", GENERATOR_DIR])
        cap = capsys.readouterr()
        assert rc == 2 and "[refused]" in cap.err, (verb, rc, cap)
