"""Every copy site of a brand row, by name, carries every key (hugmesh-generator#654, D5).

Qt-free. The record's three new row keys (``look``, ``ways``, ``issuer_port``) plus
``id`` ride the same path as ``tor`` did: a Domain row goes from an image config to
the local mesh, into a saved mesh and back into an image config, and through the
fleet — and every field survives at every named site (brand_model.COPY_SITES).

THE MUTATION BATTERY (the last test) is what makes the round trip a guard rather
than a description: for each site it copies the package, deletes ONE key at that
site in the way a hand-written key list would have dropped it, verifies the copy
really changed, and runs the round trip in a fresh process against the mutated
copy. Every mutation must turn the round trip red; a site whose mutation stays
green is a site the round trip does not cover.

Also here: the OLD-BYTES rule (a config and a saved mesh that use none of the new
keys write exactly the bytes they wrote before), and the --brand-record hand-over
pin (the flag is emitted exactly when a builder parses it).
"""
from __future__ import annotations

import glob
import json
import os
import shutil
import subprocess
import sys

import pytest

from hugmesh_studio.core import brand_model
from hugmesh_studio.core.config import (DOMAIN_FIELDS, DOMAIN_IDP_OWN, Domain, ImageConfig,
                                        domain_rows_to_dict)
from hugmesh_studio.core.fleet import (FleetConfig, FleetDomains, fleet_domain_fields,
                                       fleet_domains_from_config)
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
from hugmesh_studio.core.local_mesh_domains import (LocalMeshDomains, apply_imported_domains,
                                                    bootstrap_domain_records,
                                                    domains_from_bootstrap,
                                                    imported_mesh_domains, record_walk)
from hugmesh_studio.core.platform_info import HostInfo
from hugmesh_studio.core.worklist import WorklistConfig, WorklistEntry
from hugmesh_studio.core.worklist_driver import WorklistDriver

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)
OWN = "mesh.example"

# A row that says something in EVERY field, so a dropped key is a visible diff.
FULL_ROW = dict(
    name="shop.mesh.example", title="Shop", id="shop", images=["backend.rpi5"],
    optional_services=["games"], idp=DOMAIN_IDP_OWN, tor=True,
    look={"primary": "#112233", "font": "System UI"},
    ways={"internal_name": "shop.acme.internal",
          "public": {"provider": "duckdns", "inputs": {"host": "shop"},
                     "token_file": "/run/secrets/duckdns"},
          # per-domain VPN membership and egress (core/domain_reach, 2026-10-21)
          "tailnet": True,
          "egress": {"mode": "vpn", "conf": "/etc/hugmesh/egress/shop.conf"}},
    issuer_port=8002,
    # every field says something, or the battery is blind to it (_differences
    # compares None == None for a key the row does not carry)
    github_org="shop-org",
    # per-domain identity-provider settings (2026-10-21)
    idp_settings={"provider": "oidc", "issuer": "https://id.shop.example",
                  "client_id": "shop-app", "jwks": "https://id.shop.example/keys"},
)


def _row() -> Domain:
    return Domain(**{k: (dict(v) if isinstance(v, dict) else list(v)
                         if isinstance(v, list) else v) for k, v in FULL_ROW.items()})


def _expected() -> dict:
    # Hand-built, NOT through domain_rows_to_dict: that function is one of the sites
    # under test, and an expectation computed by the mutated function would agree
    # with it (the battery found exactly that on its first run).
    return json.loads(json.dumps(FULL_ROW))


def _differences(got: dict, where: str, ignore=()) -> list[str]:
    exp = _expected()
    out = []
    for k in DOMAIN_FIELDS:
        if k in ignore:
            continue
        if exp.get(k) != got.get(k):
            out.append(f"{where}: {k} = {got.get(k)!r}, expected {exp.get(k)!r}")
    return out


def _host():
    return HostInfo(os="linux", is_gentoo=True, has_docker=True, has_bash=True,
                    has_kvm=False, is_root=True, builder_image="hugmesh-builder")


def _round_trip_problems(tmp: str) -> list[str]:
    """Drive one full row through every copy site; return every dropped or changed
    key as 'site: key = got, expected'. [] is green. Pure, except the manifest v2
    driver wants an output dir under ``tmp``."""
    problems: list[str] = []
    row = _row()

    # ── config: to_dict -> from_dict (domain_rows_to_dict, _domain_from_dict) ──
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand="acme",
                      cluster_domain=OWN, domains=[row])
    saved = json.loads(json.dumps(cfg.to_dict()))
    problems += _differences(saved["domains"][0], "config.domain_rows_to_dict")
    back = ImageConfig.from_dict(saved)
    problems += _differences(domain_rows_to_dict(back.domains)[0],
                             "config.ImageConfig._domain_from_dict")

    # ── the two manifest emitters ──
    v1 = cfg.mesh_manifest()["domains"][0]
    problems += _differences(dict(v1, idp=v1.get("idp", "superdomain")),
                             "config.ImageConfig.mesh_manifest")
    wl = WorklistConfig(base=cfg, entries=[WorklistEntry(role="pki", platform="x86")])
    cfg.output_dir = os.path.join(tmp, "out")
    v2 = WorklistDriver(tmp, wl, host=_host()).manifest_v2()["domains"][0]
    problems += _differences(dict(v2, idp=v2.get("idp", "superdomain")),
                             "worklist_driver.WorklistDriver.manifest_v2")
    if v1 != v2:
        problems.append(f"the two manifest emitters disagree: {v1!r} != {v2!r}")

    # ── the local mesh: rows -> recorded -> saved mesh -> back ──
    md = LocalMeshDomains(domains=[Domain(name=OWN), _row()], own_name=OWN)
    recs = bootstrap_domain_records(md.domains, OWN)
    problems += _differences(dict(recs[0]), "local_mesh_domains.bootstrap_domain_records")
    boot = LocalMeshBootstrapConfig(brand="acme", cluster_domain=OWN, domains=recs,
                                    own_idp_domains=(FULL_ROW["name"],))
    boot2 = LocalMeshBootstrapConfig.from_dict(json.loads(json.dumps(boot.to_dict())))
    problems += _differences(dict(boot2.domains[0]), "local_mesh_bootstrap._domain_record")
    md2 = domains_from_bootstrap(boot2)
    problems += _differences(domain_rows_to_dict(md2.domains)[1],
                             "local_mesh_domains.domains_from_bootstrap")

    # record_walk writes a NEW row for a name the record carried only as an own-IdP
    # name (a CLI-made record): the form row's full shape must come with it
    cli_made = LocalMeshBootstrapConfig(brand="acme", cluster_domain=OWN,
                                        own_idp_domains=(FULL_ROW["name"],))
    record_walk(cli_made, md, [FULL_ROW["name"]])
    problems += _differences(dict(cli_made.domains[0]), "local_mesh_domains.record_walk")

    # the import into the node-image flow
    img = ImageConfig(mode="mesh", role="omnibus", platform="x86", cluster_domain=OWN)
    apply_imported_domains(img, imported_mesh_domains(boot2))
    problems += _differences(domain_rows_to_dict(img.domains)[0],
                             "local_mesh_domains.apply_imported_domains")

    # ── the fleet ──
    fd = FleetDomains(domains=[Domain(name=OWN), _row()], own_name=OWN)
    fc = FleetConfig(**fleet_domain_fields(fd))
    problems += _differences(domain_rows_to_dict(fc.domains)[1], "fleet.fleet_domain_fields")
    fc2 = FleetConfig.from_dict(json.loads(json.dumps(fc.to_dict())))
    fd2 = fleet_domains_from_config(fc2)
    problems += _differences(domain_rows_to_dict(fd2.domains)[1],
                             "fleet.fleet_domains_from_config")
    return problems


def test_round_trip_carries_every_key_through_every_site(tmp_path):
    problems = _round_trip_problems(str(tmp_path))
    assert problems == [], "\n".join(problems)


def test_every_named_copy_site_exists():
    """COPY_SITES names real functions, so the list cannot rot into prose."""
    import importlib
    for site in brand_model.COPY_SITES:
        mod_name, _, attr = site.partition(".")
        mod = importlib.import_module(f"hugmesh_studio.core.{mod_name}")
        obj = mod
        for part in attr.split("."):
            obj = getattr(obj, part)
        assert callable(obj), site


# ── the old-bytes rule ─────────────────────────────────────────────────────────────
def test_a_row_without_the_new_keys_writes_its_old_bytes():
    old = Domain(name="a.example", title="A", optional_services=["games"])
    assert domain_rows_to_dict([old])[0] == {
        "name": "a.example", "title": "A", "images": [], "optional_services": ["games"],
        "idp": "superdomain"}
    cfg = ImageConfig(mode="mesh", role="omnibus", cluster_domain=OWN, domains=[old])
    assert cfg.mesh_manifest()["domains"][0] == {
        "name": "a.example", "title": "A", "images": [], "optional_services": ["games"]}
    for key in ("login_style", "login_decor"):
        assert key not in cfg.mesh_manifest()
    recs = bootstrap_domain_records([Domain(name=OWN), old], OWN)
    assert recs == ({"name": "a.example", "title": "A", "optional_services": ["games"],
                     "idp": "superdomain"},)
    boot = LocalMeshBootstrapConfig(domains=recs)
    assert LocalMeshBootstrapConfig.from_dict(boot.to_dict()).domains == recs


def test_an_old_saved_mesh_and_old_config_produce_identical_argv_and_files(tmp_path):
    """A config from before #654 (no new keys anywhere) must build the same argv and
    the same manifest bytes as the same config loaded through the new code: the new
    fields default to nothing and emit nothing."""
    old_json = {"mode": "mesh", "role": "omnibus", "platform": "x86", "brand": "acme",
                "cluster_domain": OWN,
                "domains": [{"name": "a.example", "title": "A", "images": [],
                             "optional_services": [], "idp": "superdomain"}]}
    cfg = ImageConfig.from_dict(json.loads(json.dumps(old_json)))
    argv = cfg.to_cli_args()
    assert "--brand-record" not in argv
    for tok in argv:
        assert "login_style" not in tok and "login_decor" not in tok
    saved = cfg.to_dict()
    assert saved["domains"] == old_json["domains"]
    assert saved["login_style"] == "" and saved["brand_record"] == ""
    # a saved mesh from before #654: no superbrand block, no tor_release
    old_mesh = {"env": "test", "brand": "acme", "cluster_domain": OWN,
                "domains": [{"name": "a.example", "title": "", "idp": "superdomain",
                             "optional_services": []}]}
    boot = LocalMeshBootstrapConfig.from_dict(old_mesh)
    assert boot.superbrand == {} and boot.tor_release is False
    assert boot.domains == tuple(old_mesh["domains"])


def test_brand_record_flag_is_emitted_exactly_when_a_builder_parses_it():
    """The --brand-record hand-over pin: today NO image builder parses the flag, so
    the Studio must not emit it (a build would die on an unknown option). The day a
    builder (builders-brand-record lane) parses it, this turns red and says to move
    ``brand_record`` out of NON_ARGV_FIELDS."""
    parsers = [p for p in glob.glob(os.path.join(GENERATOR_DIR, "build-*-stage4.sh"))
               if "--brand-record" in open(p, encoding="utf-8", errors="replace").read()]
    cfg = ImageConfig(mode="mesh", role="omnibus", platform="x86", brand_record="/x.json")
    emitted = "--brand-record" in cfg.to_cli_args()
    assert emitted == bool(parsers), (
        f"builders parsing --brand-record: {parsers}; emitted: {emitted} — move "
        "brand_record between NON_ARGV_FIELDS and the argv table to match")


# ── the mutation battery ───────────────────────────────────────────────────────────
# (site, file, old text, new text): each deletes the ``look`` key at ONE site the way a
# hand-written key list would have — the mutation the design names at every site.
_DROP = 'if k != "look"'
MUTATIONS: tuple[tuple[str, str, str, str], ...] = (
    ("config.ImageConfig._domain_from_dict", "config.py",
     "kw = {k: v for k, v in x.items() if k in dom_f}",
     f"kw = {{k: v for k, v in x.items() if k in dom_f and k != 'look'}}"),
    ("config.domain_rows_to_dict", "config.py",
     "        row = dict(d) if isinstance(d, dict) else asdict(d)\n        for k in DOMAIN_OMIT_WHEN_EMPTY:",
     "        row = dict(d) if isinstance(d, dict) else asdict(d)\n        row.pop('look', None)\n        for k in DOMAIN_OMIT_WHEN_EMPTY:"),
    ("config.ImageConfig.mesh_manifest", "config.py",
     '"domains": manifest_domain_rows(self.domains),',
     f'"domains": [{{k: v for k, v in r.items() {_DROP}}} for r in manifest_domain_rows(self.domains)],'),
    ("worklist_driver.WorklistDriver.manifest_v2", "worklist_driver.py",
     '"domains": manifest_domain_rows(base.domains),',
     f'"domains": [{{k: v for k, v in r.items() {_DROP}}} for r in manifest_domain_rows(base.domains)],'),
    ("local_mesh_domains.bootstrap_domain_records", "local_mesh_domains.py",
     '        rec = domain_rows_to_dict([d])[0]\n        rec["name"] = name',
     '        rec = domain_rows_to_dict([d])[0]\n        rec.pop("look", None)\n        rec["name"] = name'),
    ("local_mesh_domains.domains_from_bootstrap", "local_mesh_domains.py",
     "loaded = domain_from_record_row(dict(rec, name=name))",
     f"loaded = domain_from_record_row({{k: v for k, v in dict(rec, name=name).items() {_DROP}}})"),
    ("local_mesh_domains.record_walk", "local_mesh_domains.py",
     "row = domain_rows_to_dict([form_row])[0] if form_row else {}",
     f"row = {{k: v for k, v in (domain_rows_to_dict([form_row])[0] if form_row else {{}}).items() {_DROP}}}"),
    ("local_mesh_domains.apply_imported_domains", "local_mesh_domains.py",
     "dom = domain_from_record_row(domain_rows_to_dict([row])[0])",
     f"dom = domain_from_record_row({{k: v for k, v in domain_rows_to_dict([row])[0].items() {_DROP}}})"),
    ("local_mesh_bootstrap._domain_record", "local_mesh_bootstrap.py",
     "        if k in rec or k not in x:\n            continue",
     '        if k in rec or k not in x or k == "look":\n            continue'),
    ("fleet.fleet_domain_fields", "fleet.py",
     '"domains": [Domain(**asdict(d)) for d in state.domains],',
     f'"domains": [Domain(**{{k: v for k, v in asdict(d).items() {_DROP}}}) for d in state.domains],'),
    ("fleet.fleet_domains_from_config", "fleet.py",
     "rows = [Domain(**asdict(d)) for d in cfg.domains]",
     f"rows = [Domain(**{{k: v for k, v in asdict(d).items() {_DROP}}}) for d in cfg.domains]"),
)


def test_battery_names_every_copy_site():
    assert {m[0] for m in MUTATIONS} == set(brand_model.COPY_SITES)


def test_every_field_says_something_in_the_full_row():
    """A field FULL_ROW leaves at its default is invisible to the round trip: a site
    that dropped it would compare default == default and stay green."""
    blank = Domain()
    for k in DOMAIN_FIELDS:
        assert k in FULL_ROW and FULL_ROW[k] != getattr(blank, k), k


#: The same battery for the per-domain sign-in settings (2026-10-21): each site's
#: mutation re-pointed from ``look`` to ``idp_settings``.
MUTATIONS_IDP = tuple((site, fname, old, new.replace("'look'", "'idp_settings'")
                       .replace('"look"', '"idp_settings"'))
                      for site, fname, old, new in MUTATIONS)


@pytest.mark.parametrize("site,fname,old,new", MUTATIONS_IDP,
                         ids=[m[0] for m in MUTATIONS_IDP])
def test_deleting_idp_settings_at_each_site_turns_the_round_trip_red(
        tmp_path, site, fname, old, new):
    assert "idp_settings" in new and "look" not in new, site
    test_deleting_a_key_at_each_site_turns_the_round_trip_red(tmp_path, site, fname,
                                                              old, new)


_RUNNER = """
import runpy, sys, tempfile
m = runpy.run_path(sys.argv[1], run_name="battery")
problems = m["_round_trip_problems"](tempfile.mkdtemp())
for p in problems:
    print(p)
sys.exit(1 if problems else 0)
"""


@pytest.mark.parametrize("site,fname,old,new", MUTATIONS, ids=[m[0] for m in MUTATIONS])
def test_deleting_a_key_at_each_site_turns_the_round_trip_red(tmp_path, site, fname, old, new):
    pkg_src = os.path.join(STUDIO_ROOT, "hugmesh_studio")
    mutated_root = tmp_path / "mutated"
    shutil.copytree(pkg_src, mutated_root / "hugmesh_studio",
                    ignore=shutil.ignore_patterns("__pycache__"))
    target = mutated_root / "hugmesh_studio" / "core" / fname
    text = target.read_text(encoding="utf-8")
    assert text.count(old) == 1, f"{site}: the mutation anchor is not unique/present in {fname}"
    mutated = text.replace(old, new)
    assert mutated != text, f"{site}: the mutation changed nothing"
    target.write_text(mutated, encoding="utf-8")
    env = dict(os.environ, PYTHONPATH=str(mutated_root), PYTHONDONTWRITEBYTECODE="1")
    env.pop("PYTEST_CURRENT_TEST", None)
    r = subprocess.run([sys.executable, "-c", _RUNNER, os.path.abspath(__file__)],
                       cwd=str(tmp_path), env=env, capture_output=True, text=True,
                       timeout=180)
    assert r.returncode != 0, (f"{site}: the round trip stayed GREEN with the key "
                               f"deleted at this site\n{r.stdout}\n{r.stderr}")
    assert site in r.stdout or "disagree" in r.stdout, (
        f"{site}: the round trip went red, but not at this site:\n{r.stdout}\n{r.stderr}")


def test_the_unmutated_round_trip_runs_green_in_a_fresh_process(tmp_path):
    """The battery's control: the same runner against the real package is green, so a
    red above is the mutation's doing and not the runner's."""
    env = dict(os.environ, PYTHONPATH=STUDIO_ROOT, PYTHONDONTWRITEBYTECODE="1")
    r = subprocess.run([sys.executable, "-c", _RUNNER, os.path.abspath(__file__)],
                       cwd=str(tmp_path), env=env, capture_output=True, text=True,
                       timeout=180)
    assert r.returncode == 0, f"{r.stdout}\n{r.stderr}"
