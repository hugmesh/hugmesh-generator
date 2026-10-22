"""A domain's own look reaches that domain's sign-in page on the Docker mesh
(theme survey item B; core/look_serving.py).

The chain, every link offline: the bootstrap record -> LocalStackNode writes
tests/stack/.looks/ (one folder of stylesheets per added domain, the nginx Host map,
the extra `make view` rows) -> the committed HTTPS front door includes the map and
answers *-theme.css from the folder -> the Makefile mounts the folder only while the
map exists -> hugmesh-view serves one row per added domain. The parametrised
door test below removes each committed half in turn and expects "not served".
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import sys

import pytest

from hugmesh_studio.core import brand_look, look_serving, stack_limits, view_doors
from hugmesh_studio.core.local_mesh_bootstrap import (LocalMeshBootstrap,
                                                      LocalMeshBootstrapConfig)

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))


@pytest.fixture
def gen(tmp_path, monkeypatch):
    (tmp_path / "tests" / "stack").mkdir(parents=True)
    monkeypatch.setattr(stack_limits, "write_overlay", lambda *a, **k: None)
    monkeypatch.setattr(stack_limits, "compose_services", lambda _p: ["a"])
    return str(tmp_path)


def _cfg(**kw):
    base = dict(
        cluster_domain="mesh.example",
        superbrand={"look": {"primary": "#123456"}},
        domains=({"name": "shop.example", "look": {"primary": "#ff0000"}},
                 {"name": "blog.example"},
                 {"name": "mesh.example"}))
    base.update(kw)
    return LocalMeshBootstrapConfig(**base)


def _looks(gen):
    return look_serving.looks_dir(gen)


def _read(*parts):
    with open(os.path.join(*parts), encoding="utf-8") as fh:
        return fh.read()


# ── the record -> files -> map -> view rows chain ───────────────────────────────────
def test_a_bring_up_writes_each_added_domains_look_the_host_map_and_the_view_rows(gen):
    node = LocalMeshBootstrap(gen, _cfg())._stack_node()
    node._build_env()
    d = _looks(gen)
    assert node.looks_error == ""
    # the domain with its own look: its stylesheet is the record's composition
    want = brand_look.look_css(brand_look.effective_look(
        {"primary": "#123456"}, {"primary": "#ff0000"}))
    assert want and _read(d, "shop-example", "hug-theme.css") == want
    assert _read(d, "shop-example", "snap-theme.css") == want
    # an inheriting domain's file is the superbrand's, byte for byte
    assert (_read(d, "blog-example", "hug-theme.css")
            == _read(d, "default", "hug-theme.css"))
    # the map names ONLY the domain with its own look; never the mesh's own name
    live = [l for l in _read(d, look_serving.MAP_NAME).splitlines()
            if l.strip() and not l.startswith("#")]
    assert live == ["shop.example shop-example;"]
    # one view row per added domain, through the TLS door, on its own port
    rows = view_doors.parse(_read(d, look_serving.VIEW_NAME), {})
    assert [(r.name, r.lane, r.host, r.upstream, r.port, r.path) for r in rows] == [
        ("compose-brand-shop-example", "compose", "shop.example",
         "https://127.0.0.1:8488", 9100, "/login/"),
        ("compose-brand-blog-example", "compose", "blog.example",
         "https://127.0.0.1:8488", 9101, "/login/")]


def test_a_mesh_with_no_added_domain_writes_nothing(gen):
    node = LocalMeshBootstrap(gen, _cfg(domains=()))._stack_node()
    node._build_env()
    assert not os.path.exists(_looks(gen))


def test_dropping_the_last_added_domain_clears_the_folder_so_the_mount_goes_too(gen):
    LocalMeshBootstrap(gen, _cfg())._stack_node()._build_env()
    assert os.path.isfile(os.path.join(_looks(gen), look_serving.MAP_NAME))
    LocalMeshBootstrap(gen, _cfg(domains=()))._stack_node()._build_env()
    assert not os.path.exists(_looks(gen))


def test_a_read_env_writes_no_looks(gen):
    node = LocalMeshBootstrap(gen, _cfg())._stack_node()
    assert node._build_env(write_overlays=False) == node._build_env(write_overlays=False)
    assert not os.path.exists(_looks(gen))


def test_a_look_that_cannot_be_written_clears_the_old_folder_and_says_why(gen, monkeypatch):
    LocalMeshBootstrap(gen, _cfg())._stack_node()._build_env()
    node = LocalMeshBootstrap(gen, _cfg(domains=(
        {"name": "shop.example", "look": {"primary": "not-a-colour"}},)))._stack_node()
    node._build_env()                       # never raises: best-effort like .theme.css
    assert "domain looks not served" in node.looks_error
    assert not os.path.exists(_looks(gen))  # nothing from the earlier start is served


def test_only_safe_names_reach_the_nginx_map():
    rows = [{"name": "ok.example"}, {"name": "evil.example;}"}, {"name": "x"},
            {"name": "mesh.example"}, {"name": "OK.example"},
            {"name": "two.example", "id": "Bad_Id"}, {"name": "d.example", "id": "default"}]
    got = look_serving.served_brands(rows, "mesh.example")
    assert [(b.name, b.bid) for b in got] == [("ok.example", "ok-example")]


def test_the_plan_names_each_served_domain_and_its_view_address():
    plan = LocalMeshBootstrap(REPO, _cfg()).plan()
    assert "shop.example served by Host at the HTTPS door" in plan
    assert "shop.example: make view LANE=compose -> https://127.0.0.1:9100/login/" in plan
    assert "blog.example: make view LANE=compose -> https://127.0.0.1:9101/login/" in plan
    # a mesh with no added domain: the plan says nothing new
    assert "domain looks" not in LocalMeshBootstrap(REPO, _cfg(domains=())).plan()


# ── the committed front door, overlay and Makefile ──────────────────────────────────
def test_this_checkout_serves_looks_by_host():
    assert look_serving.door_serves_looks(REPO)


def test_the_overlay_mounts_the_folder_where_the_conf_reads_it():
    import yaml
    conf = _read(REPO, look_serving.TLS_FRONT_CONF_REL)
    with open(os.path.join(REPO, look_serving.LOOKS_COMPOSE_REL), encoding="utf-8") as fh:
        overlay = yaml.safe_load(fh)
    with open(os.path.join(REPO, "tests", "stack", "compose.local.yaml"),
              encoding="utf-8") as fh:
        base = yaml.safe_load(fh)
    assert "hugmesh-https-front" in base["services"]
    vols = overlay["services"]["hugmesh-https-front"]["volumes"]
    assert vols == [f"./.looks:{look_serving.MOUNT_POINT}:ro"]
    # the base never mounts it (Docker would create a missing folder as root)
    assert not any(".looks" in v for v in base["services"]["hugmesh-https-front"]["volumes"])
    assert re.search(r"map \$host \$hug_look \{\s*default _unmapped;\s*include "
                     + re.escape(look_serving.MOUNT_POINT) + r"/hosts\.map\*;", conf)
    assert f"root {look_serving.MOUNT_POINT}/$hug_look;" in conf
    assert "try_files /${hug_look_file}-theme.css @gateway;" in conf
    assert re.search(r"location @gateway \{\s*proxy_pass http://\$fe_gateway:8080"
                     r"\$request_uri;", conf)


def test_the_makefile_adds_the_overlay_only_while_the_map_exists():
    make = _read(REPO, "Makefile")
    assert ("STACK_LOOKS_FLAGS := $(if $(wildcard $(STACK_LOOKS_MAP)),"
            "-f $(STACK_LOOKS_COMPOSE),)") in make
    assert "STACK_LOOKS_MAP := tests/stack/.looks/hosts.map" in make
    up = [l for l in make.splitlines() if l.rstrip().endswith(" up -d")
          and "$(STACK_COMPOSE)" in l]
    assert up and all("$(STACK_LOOKS_FLAGS)" in l for l in up)


def test_the_folder_is_gitignored():
    assert re.search(r"^tests/stack/\.looks/$", _read(REPO, ".gitignore"), re.M)


@pytest.mark.parametrize("path,old,new", [
    (look_serving.TLS_FRONT_CONF_REL, "include /etc/hugmesh-looks/hosts.map*;", ""),
    (look_serving.TLS_FRONT_CONF_REL, "root /etc/hugmesh-looks/$hug_look;", ""),
    (look_serving.LOOKS_COMPOSE_REL, "./.looks:/etc/hugmesh-looks:ro", "./x:/y:ro"),
    ("Makefile", "-f $(STACK_LOOKS_COMPOSE)", "-f nothing.yaml"),
    ("Makefile", "$(STACK_LIMITS_FLAGS) $(STACK_LOOKS_FLAGS) $(STACK_EGRESS_FLAGS) up -d",
     "$(STACK_LIMITS_FLAGS) $(STACK_EGRESS_FLAGS) up -d"),
])
def test_the_measured_door_says_not_served_when_a_half_is_missing(tmp_path, path, old, new):
    for rel in (look_serving.TLS_FRONT_CONF_REL, look_serving.LOOKS_COMPOSE_REL, "Makefile"):
        os.makedirs(tmp_path / os.path.dirname(rel), exist_ok=True)
        shutil.copy(os.path.join(REPO, rel), tmp_path / rel)
    assert look_serving.door_serves_looks(str(tmp_path))
    text = (tmp_path / path).read_text(encoding="utf-8")
    assert old in text
    (tmp_path / path).write_text(text.replace(old, new), encoding="utf-8")
    assert not look_serving.door_serves_looks(str(tmp_path))


# ── the sentences ───────────────────────────────────────────────────────────────────
def test_every_route_says_where_a_domains_own_look_shows(tmp_path):
    for path in ("image", "fleet", "kind"):
        assert look_serving.own_look_sentence(path, REPO) == brand_look.DOCKER_ONLY_SENTENCE
    assert "not applied" in brand_look.DOCKER_ONLY_SENTENCE.lower()
    assert (look_serving.own_look_sentence("docker", REPO)
            == brand_look.DOCKER_SERVED_SENTENCE)
    # a checkout whose front door does not serve looks never claims it does
    assert (look_serving.own_look_sentence("docker", str(tmp_path))
            == brand_look.DOCKER_NOT_SERVED_SENTENCE)


# ── the view rows reach `make view` ────────────────────────────────────────────────
@pytest.fixture
def hv():
    """scripts/hugmesh-view.py loaded by path (registered by name while it runs:
    dataclasses resolve their module through sys.modules)."""
    spec = importlib.util.spec_from_file_location(
        "hugmesh_view_for_looks", os.path.join(REPO, "scripts", "hugmesh-view.py"))
    mod = importlib.util.module_from_spec(spec)
    sys.modules[spec.name] = mod
    try:
        spec.loader.exec_module(mod)
        yield mod
    finally:
        sys.modules.pop(spec.name, None)


def test_make_view_serves_the_generated_rows_with_the_shipped_catalog(tmp_path, hv):
    extra = tmp_path / "view.tsv"
    brands = look_serving.served_brands(
        [{"name": "shop.example", "look": {"primary": "#ff0000"}}], "mesh.example")
    extra.write_text(look_serving.view_rows_text(brands), encoding="utf-8")
    shipped = hv.load_catalog(hv.DEFAULT_CATALOG, {})
    got = hv.load_entries(hv.DEFAULT_CATALOG, {}, generated=str(extra))
    assert [e.name for e in got] == [e.name for e in shipped] + ["compose-brand-shop-example"]
    assert hv.select(got, "compose", [])[-1].host == "shop.example"
    # a catalog of your own is taken exactly as written
    own = tmp_path / "own.tsv"
    own.write_text("a\tcompose\th.example\thttp://127.0.0.1:1\t9300\t/\n", encoding="utf-8")
    assert [e.name for e in hv.load_entries(str(own), {}, generated=str(extra))] == ["a"]
    # a generated row can never replace a shipped door
    extra.write_text("app\tcompose\tx.example\thttp://127.0.0.1:1\t9301\t/\n",
                     encoding="utf-8")
    with pytest.raises(hv.ViewError):
        hv.load_entries(hv.DEFAULT_CATALOG, {}, generated=str(extra))


def test_make_view_list_shows_the_domain_rows(tmp_path, hv, monkeypatch):
    """The command `make view-list` / `make view LANE=compose` runs (main), not only
    the helper: a generated row is in what it lists."""
    extra = tmp_path / "view.tsv"
    extra.write_text(look_serving.view_rows_text(
        look_serving.served_brands([{"name": "shop.example"}], "")), encoding="utf-8")
    monkeypatch.setattr(hv, "GENERATED_CATALOG", str(extra))
    monkeypatch.delenv("HUGMESH_VIEW_TSV", raising=False)
    seen = []
    monkeypatch.setattr(hv, "cmd_list", lambda args, entries: seen.extend(entries) or 0)
    assert hv.main(["list", "--lane", "compose"]) == 0
    assert ("compose-brand-shop-example", "shop.example") in [(e.name, e.host) for e in seen]


def test_the_studio_reads_the_same_rows_as_the_script(tmp_path, hv):
    os.makedirs(tmp_path / "scripts")
    shutil.copy(os.path.join(REPO, view_doors.CATALOG_REL), tmp_path / view_doors.CATALOG_REL)
    os.makedirs(tmp_path / os.path.dirname(view_doors.GENERATED_REL))
    brands = look_serving.served_brands([{"name": "shop.example"}], "")
    (tmp_path / view_doors.GENERATED_REL).write_text(
        look_serving.view_rows_text(brands), encoding="utf-8")
    hv.DEFAULT_CATALOG = str(tmp_path / view_doors.CATALOG_REL)   # this tmp checkout's
    theirs = hv.load_entries(hv.DEFAULT_CATALOG, {},
                             generated=str(tmp_path / view_doors.GENERATED_REL))
    ours = view_doors.load_with_generated(str(tmp_path), {})
    assert [(d.name, d.host, d.upstream, d.port, d.path) for d in ours] == [
        (e.name, e.host, e.upstream, e.port, e.path) for e in theirs]
    assert ours[-1].name == "compose-brand-shop-example"
    # with a catalog override the generated rows are not added (the script's rule)
    env = {view_doors.CATALOG_ENV: str(tmp_path / "other.tsv")}
    shutil.copy(tmp_path / view_doors.CATALOG_REL, tmp_path / "other.tsv")
    assert "compose-brand-shop-example" not in [
        d.name for d in view_doors.load_with_generated(str(tmp_path), env)]
