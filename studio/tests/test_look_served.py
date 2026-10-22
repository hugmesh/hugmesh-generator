"""A domain's own look reaches that domain's sign-in page on the Docker mesh
(theme survey item B; core/look_serving.py).

The chain, every link offline: the bootstrap record -> LocalStackNode.start() writes
tests/stack/.looks/ (one folder of stylesheets per added domain, a by-host/<name>/
folder per domain with its own look, the extra `make view` rows) -> the committed
HTTPS front door answers *-theme.css from by-host/$host/ -> the Makefile mounts the
folder only while by-host/ exists -> hugmesh-view serves one row per added domain.
The parametrised door test below removes each committed half in turn and expects
"not served".
"""
from __future__ import annotations

import importlib.util
import os
import re
import shutil
import sys

import pytest

from hugmesh_studio.core import (brand_look, local_stack_node, look_serving, stack_limits,
                                  view_doors)
from hugmesh_studio.core.local_stack_node import LocalStackNode
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


def _hosts(gen):
    d = os.path.join(_looks(gen), look_serving.HOSTS_DIRNAME)
    return sorted(os.listdir(d)) if os.path.isdir(d) else None


def _snapshot(root):
    """Every file under ``root`` with its bytes (None when ``root`` is missing)."""
    if not os.path.isdir(root):
        return None
    out = {}
    for dirpath, _dirs, files in os.walk(root):
        for f in files:
            p = os.path.join(dirpath, f)
            with open(p, "rb") as fh:
                out[os.path.relpath(p, root)] = fh.read()
    return out


class _FakeMake:
    """Stands in for `make` (subprocess.run in local_stack_node): records each target
    and answers rc 0, so a verb runs its real Python path and no container starts."""
    def __init__(self):
        self.targets = []

    def __call__(self, argv, **kw):
        self.targets.append(argv[1])
        return local_stack_node.subprocess.CompletedProcess(argv, 0, "", "")


@pytest.fixture
def fake_make(monkeypatch):
    fake = _FakeMake()
    monkeypatch.setattr(local_stack_node.subprocess, "run", fake)
    monkeypatch.setattr(LocalStackNode, "preflight", lambda self: [])
    monkeypatch.setattr(LocalStackNode, "cold_build_expected", lambda self: False)
    return fake


# ── the record -> files -> map -> view rows chain ───────────────────────────────────
def test_a_bring_up_writes_each_added_domains_look_its_host_folder_and_the_view_rows(
        gen, fake_make):
    node = LocalMeshBootstrap(gen, _cfg())._stack_node()
    assert node.start() == (True, "")
    assert fake_make.targets == ["stack-up"]
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
    # a Host folder ONLY for the domain with its own look; never the mesh's own name
    assert _hosts(gen) == ["shop.example"]
    for f in ("hug-theme.css", "snap-theme.css"):
        assert _read(d, "by-host", "shop.example", f) == want
    assert not os.path.exists(os.path.join(d, "hosts.map"))
    # one view row per added domain, through the TLS door, on its own port
    rows = view_doors.parse(_read(d, look_serving.VIEW_NAME), {})
    assert [(r.name, r.lane, r.host, r.upstream, r.port, r.path) for r in rows] == [
        ("compose-brand-shop-example", "compose", "shop.example",
         "https://127.0.0.1:8488", 9100, "/login/"),
        ("compose-brand-blog-example", "compose", "blog.example",
         "https://127.0.0.1:8488", 9101, "/login/")]


def test_the_door_can_read_the_looks_under_a_strict_umask(gen, fake_make):
    """nginx's workers in the front door are not the operator: a Studio started with
    umask 077 must still leave every folder and stylesheet readable by anyone, or
    try_files falls through to the gateway silently."""
    old = os.umask(0o077)
    try:
        assert LocalMeshBootstrap(gen, _cfg())._stack_node().start()[0]
    finally:
        os.umask(old)
    d = _looks(gen)
    seen = 0
    for dirpath, _dirs, files in os.walk(d):
        assert os.stat(dirpath).st_mode & 0o005 == 0o005, dirpath
        for f in files:
            assert os.stat(os.path.join(dirpath, f)).st_mode & 0o004, f
            seen += 1
    assert os.path.isfile(os.path.join(d, "by-host", "shop.example", "hug-theme.css"))
    assert seen >= 7


def test_a_mesh_with_no_added_domain_writes_nothing(gen, fake_make):
    node = LocalMeshBootstrap(gen, _cfg(domains=()))._stack_node()
    node.start()
    assert not os.path.exists(_looks(gen))


def test_dropping_the_last_added_domain_clears_the_folder_so_the_mount_goes_too(
        gen, fake_make):
    LocalMeshBootstrap(gen, _cfg())._stack_node().start()
    assert os.path.isdir(os.path.join(_looks(gen), look_serving.HOSTS_DIRNAME))
    LocalMeshBootstrap(gen, _cfg(domains=()))._stack_node().start()
    assert not os.path.exists(_looks(gen))


def test_a_domain_added_or_switched_later_changes_the_host_folders_as_a_set(gen, fake_make):
    """The stale-map blocker: what the door serves must follow the record at every
    start, with no restart of the door. The door reads by-host/<Host>/ per request
    (pinned below and proven in a throwaway nginx), so the folders ARE the state."""
    LocalMeshBootstrap(gen, _cfg())._stack_node().start()
    assert _hosts(gen) == ["shop.example"]
    # blog.example gets a look of its own on the second start: its folder appears
    LocalMeshBootstrap(gen, _cfg(domains=(
        {"name": "shop.example", "look": {"primary": "#ff0000"}},
        {"name": "blog.example", "look": {"primary": "#00ff00"}})))._stack_node().start()
    assert _hosts(gen) == ["blog.example", "shop.example"]
    assert "#00ff00" in _read(_looks(gen), "by-host", "blog.example", "hug-theme.css")
    # shop.example goes back to inheriting: its folder goes, so the gateway answers it
    LocalMeshBootstrap(gen, _cfg(domains=(
        {"name": "shop.example"},
        {"name": "blog.example", "look": {"primary": "#00ff00"}})))._stack_node().start()
    assert _hosts(gen) == ["blog.example"]


def test_a_round_one_host_map_is_removed_at_the_next_start(gen, fake_make):
    """The first version wrote .looks/hosts.map; nothing reads it now, so a start
    removes it rather than leave a file that looks like it still matters."""
    os.makedirs(_looks(gen))
    with open(os.path.join(_looks(gen), look_serving.LEGACY_MAP_NAME), "w") as fh:
        fh.write("shop.example shop-example;\n")
    LocalMeshBootstrap(gen, _cfg())._stack_node().start()
    assert not os.path.exists(os.path.join(_looks(gen), look_serving.LEGACY_MAP_NAME))
    assert _hosts(gen) == ["shop.example"]


def test_a_bare_node_never_touches_the_looks(gen, fake_make):
    """The stack tray (and the pod views) build LocalStackNode(generator_dir), which
    knows nothing about domains. Its Start and Stop must leave the folder exactly as
    the last Studio start wrote it, or the overlay drops and every look is lost."""
    LocalMeshBootstrap(gen, _cfg())._stack_node().start()
    before = _snapshot(_looks(gen))
    assert before and "by-host/shop.example/hug-theme.css" in before
    bare = LocalStackNode(gen)
    assert bare.start()[0] and bare.stop()[0]
    bare._build_env()
    assert fake_make.targets == ["stack-up", "stack-up", "stack-halt"]
    assert _snapshot(_looks(gen)) == before


def test_only_a_start_writes_the_looks(gen, fake_make):
    """A page that holds the EMPTY default config (the e2e page) runs make verbs too;
    only a start may write or clear the folder, so those verbs leave it alone."""
    LocalMeshBootstrap(gen, _cfg())._stack_node().start()
    before = _snapshot(_looks(gen))
    empty = LocalMeshBootstrap(gen, LocalMeshBootstrapConfig())._stack_node()
    assert empty.stop()[0]
    empty._build_env()
    assert _snapshot(_looks(gen)) == before


def test_a_read_env_writes_no_looks(gen):
    node = LocalMeshBootstrap(gen, _cfg())._stack_node()
    assert node._build_env(write_overlays=False) == node._build_env(write_overlays=False)
    node._build_env()
    assert not os.path.exists(_looks(gen))


def test_a_look_that_cannot_be_written_clears_the_old_folder_and_says_why(gen, fake_make):
    LocalMeshBootstrap(gen, _cfg())._stack_node().start()
    node = LocalMeshBootstrap(gen, _cfg(domains=(
        {"name": "shop.example", "look": {"primary": "not-a-colour"}},)))._stack_node()
    seen = []
    ok, msg = node.start(on_line=seen.append)   # never raises: best-effort
    assert "domain looks not served" in node.looks_error
    assert not os.path.exists(_looks(gen))  # nothing from the earlier start is served
    # ...and the operator is TOLD, first thing in the run log and in the message
    assert seen and seen[0].startswith("[looks] domain looks not served")
    assert "mesh's own look" in seen[0]
    assert msg.startswith("[looks] domain looks not served")
    # the buffered path (no on_line) says it too
    ok, msg = node.stop()
    assert msg.startswith("[looks] domain looks not served")


def test_a_disk_error_while_writing_is_said_and_leaves_no_old_look_served(
        gen, fake_make, monkeypatch):
    """Skeptic 2's N8: an OSError while writing was swallowed by no test. It must be
    said first in the run log, and an earlier start's host folders must not stay
    served under the new record (the sentence says every domain shows the mesh's)."""
    LocalMeshBootstrap(gen, _cfg())._stack_node().start()
    assert _hosts(gen) == ["shop.example"]
    real_write = brand_look.write_look_files

    def half_then_fail(*a, **k):
        real_write(*a, **k)
        raise OSError(28, "No space left on device")
    monkeypatch.setattr(brand_look, "write_look_files", half_then_fail)
    node = LocalMeshBootstrap(gen, _cfg())._stack_node()
    ok, msg = node.start()                  # the buffered path: make is faked
    assert ok, msg
    assert node.looks_error.startswith("domain looks not written: ")
    assert "No space left on device" in node.looks_error
    assert msg.startswith("[looks] domain looks not written")
    assert _hosts(gen) is None, "an earlier start's look is still served"


def test_only_safe_names_become_folders():
    rows = [{"name": "ok.example"}, {"name": "evil.example;}"}, {"name": "x"},
            {"name": "mesh.example"}, {"name": "OK.example"},
            {"name": "two.example", "id": "Bad_Id"}, {"name": "d.example", "id": "default"},
            {"name": "h.example", "id": "by-host"}, {"name": "../up.example"},
            {"name": "a/b.example"}]
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
    assert f"root {look_serving.MOUNT_POINT}/by-host/$host;" in conf
    assert "try_files /${hug_look_file}-theme.css @gateway;" in conf
    # nothing about the looks is read only at start (a map or an include would go
    # stale on a running door: the round-1 blocker)
    live = look_serving._live(conf)
    assert "hugmesh-looks" not in live.replace(
        f"root {look_serving.MOUNT_POINT}/by-host/$host;", "")
    assert not re.search(r"^\s*(map|include)\b.*hugmesh-looks", live, re.M)
    assert re.search(r"location @gateway \{\s*proxy_pass http://\$fe_gateway:8080"
                     r"\$request_uri;", conf)


@pytest.mark.parametrize("uri,hit", [
    # what login-ui really requests: it links the stylesheet RELATIVELY, so the
    # request carries the page's path (the round-1 skeptic's root-only mutation
    # `^/(hug|snap)-theme` kept every other test green while missing all of these)
    ("/login/hug-theme.css", "hug"),
    ("/_remotes/login/snap-theme.css", "snap"),
    ("/hug-theme.css", "hug"),
    ("/snap-theme.css", "snap"),
    ("/login/", None),
    ("/login/xhug-theme.css", None),
    ("/login/hug-theme.css.bak", None),
    ("/login/hug-theme.cssx", None),
    ("/login/hug-themeXcss", None),
    ("/hosts.map", None),
])
def test_the_committed_theme_location_matches_the_paths_a_sign_in_page_requests(uri, hit):
    """nginx matches a regex location against the normalised URI WITHOUT the query
    string, so the path alone is what is run through the committed regex here."""
    rx = look_serving.theme_location_regex(_read(REPO, look_serving.TLS_FRONT_CONF_REL))
    assert rx is not None, "the theme location is gone from tls-front/default.conf"
    m = rx.search(uri)
    assert (m.group("hug_look_file") if m else None) == hit


def test_the_makefile_adds_the_overlay_only_while_the_host_folders_exist():
    make = _read(REPO, "Makefile")
    assert ("STACK_LOOKS_FLAGS := $(if $(wildcard $(STACK_LOOKS_GATE)),"
            "-f $(STACK_LOOKS_COMPOSE),)") in make
    assert "STACK_LOOKS_GATE := tests/stack/.looks/by-host" in make
    up = [l for l in make.splitlines() if l.rstrip().endswith(" up -d")
          and "$(STACK_COMPOSE)" in l]
    assert up and all("$(STACK_LOOKS_FLAGS)" in l for l in up)


def test_the_folder_is_gitignored():
    assert re.search(r"^tests/stack/\.looks/$", _read(REPO, ".gitignore"), re.M)


@pytest.mark.parametrize("path,old,new", [
    (look_serving.TLS_FRONT_CONF_REL, "root /etc/hugmesh-looks/by-host/$host;",
     "root /etc/hugmesh-looks/$host;"),
    (look_serving.TLS_FRONT_CONF_REL, "(?:^|/)(?<hug_look_file>", "^/(?<hug_look_file>"),
    (look_serving.TLS_FRONT_CONF_REL, "try_files /${hug_look_file}-theme.css @gateway;",
     "try_files /${hug_look_file}-theme.css =404;"),
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


# ── a domain's own look is composed over the mesh's WHOLE look (skeptic 2 blocker) ──
def test_a_domain_with_its_own_look_keeps_the_rest_of_the_meshs_whole_look(gen, fake_make):
    """The mesh's header, footer, pictures and font live outside the record's eight
    look keys. A domain with one colour of its own must still get them on its sign-in
    page, because its Look tab shows them as inherited."""
    whole = {"primary": "#123456", "header_bg": "#abcdef", "footer_bg": "#fedcba"}
    node = LocalMeshBootstrap(gen, _cfg(login_look=whole))._stack_node()
    assert node.start() == (True, "")
    served = _read(_looks(gen), "by-host", "shop.example", "hug-theme.css").lower()
    assert "#ff0000" in served                      # its own colour
    assert "#abcdef" in served and "#fedcba" in served   # the mesh's header and footer
    assert served == brand_look.look_css(
        brand_look.effective_look(whole, {"primary": "#ff0000"})).lower()


def test_without_the_whole_look_the_eight_recorded_keys_are_used_as_before(gen):
    """The CLI and every older record carry no ``login_look``: the record's look."""
    boot = LocalMeshBootstrap(gen, _cfg())
    assert boot.superbrand_look() == {"primary": "#123456"}
    boot = LocalMeshBootstrap(gen, _cfg(login_look={"header_bg": "#abcdef"}))
    assert boot.superbrand_look() == {"header_bg": "#abcdef"}


def test_the_whole_look_survives_a_record_round_trip():
    cfg = _cfg(login_look={"header_bg": "#abcdef", "header_hidden": True})
    back = LocalMeshBootstrapConfig.from_dict(cfg.to_dict())
    assert back.login_look == {"header_bg": "#abcdef", "header_hidden": True}
    assert LocalMeshBootstrapConfig.from_dict(
        dict(cfg.to_dict(), login_look="junk")).login_look == {}


def test_a_domain_with_its_own_look_keeps_the_meshs_pictures_and_uploaded_font(
        gen, fake_make, tmp_path):
    """The other two nouns the Look tab shows as inherited: the mesh's pictures and its
    uploaded font live outside the record's eight look keys too, and must reach the
    stylesheet served at a domain that took one colour of its own."""
    from hugmesh_studio.core import brand_images
    from test_look_model import png_bytes
    font = tmp_path / "Brand-Face.woff2"
    font.write_bytes(b"wOF2" + b"\x00" * 60)
    logo = brand_images.reencode(png_bytes(8, 8), "logo").data_uri()
    whole = {"primary": "#123456", "logo_image": logo, "font_file": str(font),
             "font_licence": "SIL OFL 1.1", "font_source": "example foundry"}
    node = LocalMeshBootstrap(gen, _cfg(login_look=whole))._stack_node()
    assert node.start() == (True, "")
    served = _read(_looks(gen), "by-host", "shop.example", "hug-theme.css")
    assert "#ff0000" in served.lower()                     # its own colour
    assert logo in served, "the mesh's logo picture is not carried"
    assert "data:font/woff2;base64," in served, "the mesh's uploaded font is not carried"
    assert '"Brand Face"' in served


def test_without_the_whole_look_a_domains_served_page_keeps_the_recorded_mesh_look(
        gen, fake_make):
    """The CLI and older records carry no ``login_look``: a domain with one colour of its
    own is served the superbrand's recorded look under it, not the shipped defaults (an
    empty superbrand look here would drop the mesh's secondary colour silently)."""
    sb = {"primary": "#123456", "secondary": "#0000aa"}
    node = LocalMeshBootstrap(gen, _cfg(superbrand={"look": sb}))._stack_node()
    assert node.start() == (True, "")
    served = _read(_looks(gen), "by-host", "shop.example", "hug-theme.css").lower()
    assert "#ff0000" in served                             # its own primary
    assert "#0000aa" in served, "the mesh's recorded secondary colour is not carried"
    assert served == brand_look.look_css(
        brand_look.effective_look(sb, {"primary": "#ff0000"})).lower()


def test_the_docker_served_sentence_says_what_does_not_show_the_domains_look():
    """Two true limits the skeptics found missing from the Docker Look tab: a running
    `make view` gives a new name no row until it is stopped, and the kind lane started
    from the same page shows the mesh's own look on every domain."""
    s = brand_look.DOCKER_SERVED_SENTENCE
    assert "\"make view-stop\"" in s
    assert "DevOps (kind) lane" in s and "show the mesh's own look" in s
