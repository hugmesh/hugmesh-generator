"""core/code_folders — the app-to-folder map of a local mesh (issue #689). Qt-free.

What is pinned:

* the folders come from the BUILD's own compose contexts, nothing else: the
  platform rows of every domain are exactly ``expected_build_contexts()`` (the same
  regex, the same file);
* clone mode roots at ./.stack-src, existing mode at the operator's tree, and a
  folder that is not there is never offered as openable — it carries the reason;
* a domain's selected optional services add what their mechanism names (a profile's
  build context, a federation module's always-on services), a stock-image service
  gets a note instead of a row, an unknown or Kubernetes-lane slug says so;
* the clone-mode notice matches what scripts/clone-all-repos.sh really does.
"""
import os

import pytest

from hugmesh_studio.core import code_folders as cf
from hugmesh_studio.core import local_services
from hugmesh_studio.core.config import DOMAIN_IDP_OWN, Domain
from hugmesh_studio.core.domain_services import DOMAIN_CATALOGUE
from hugmesh_studio.core.local_mesh_bootstrap import expected_build_contexts

STUDIO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
GENERATOR_DIR = os.path.dirname(STUDIO_ROOT)

COMPOSE_LOCAL = """\
# a slice of the real file's shape: include, an x- anchor, services with and
# without profiles, block and inline profile lists, stock images
include:
  - path: compose.alt-social.yaml
  - path: compose.games.yaml
  - path: compose.real.yaml
  - path: compose.social-profile.yaml
  - path: compose.missing.yaml

x-amd64: &amd64
  platform: linux/amd64

services:
  admin-bff-db:
    <<: *amd64
    image: postgres:16-alpine
  hugmesh-pki-gateway:
    <<: *amd64
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-gateway
      args: { ROLE: pki }
  hugmesh-fe-gateway:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-gateway
  hugmesh-admin-bff-api:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-admin-bff-api
  hugmesh-owncast-bff-api:
    build:
      context: "${STACK_SRC:-../../.stack-src}/hugmesh-owncast-bff-api"
  owncast-bff-db:
    image: postgres:16-alpine
  hugmesh-owncast-ui:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-owncast-ui
  hugmesh-user-ui:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-user-ui
  hugmesh-character-forge-ui:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-character-forge-bff-api/frontend
  hugmesh-tor:
    profiles:
      - "tor"
    build:
      context: ./tor
  hugmesh-anubis:
    profiles: ["anubis"]
    image: ghcr.io/techarohq/anubis:v1.25.0

volumes:
  admin-bff-pg:
"""

COMPOSE_ALT = """\
services:
  phpbb-db:
    profiles: ["phpbb"]
    image: postgres:16-alpine
  phpbb:
    profiles: ["phpbb"]
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-forum-api
  akkoma:
    profiles: ["akkoma"]
    image: teslamint/akkoma:v3.20.0@sha256:3b0929d8553bc5f98619f632b4840c09642a863ec16061bd5def6e77518df78c
"""

COMPOSE_GAMES = """\
services:
  hugmesh-wasm-fragment:
    profiles: ["games"]
    image: hugmesh-games/wasm-fragment:dev
    build:
      context: ${GAMES_SRC:-../../../hugmesh-games}
"""

COMPOSE_REAL = """\
services:
  tuwunel:
    image: ghcr.io/matrix-construct/tuwunel:v1.7.0
  mastodon-web:
    image: ghcr.io/mastodon/mastodon:v4.3.1
"""

COMPOSE_SOCIAL = """\
services:
  tuwunel:
    profiles: [social]
  mastodon-web:
    profiles: [social]
"""


@pytest.fixture
def gen(tmp_path):
    """A generator checkout holding the compose slice above and a .stack-src with
    ONE checkout (hugmesh-gateway), so clone mode has one present and the rest
    missing."""
    g = tmp_path / "gen"
    stack = g / "tests" / "stack"
    stack.mkdir(parents=True)
    (stack / "compose.local.yaml").write_text(COMPOSE_LOCAL)
    (stack / "compose.alt-social.yaml").write_text(COMPOSE_ALT)
    (stack / "compose.games.yaml").write_text(COMPOSE_GAMES)
    (stack / "compose.real.yaml").write_text(COMPOSE_REAL)
    (stack / "compose.social-profile.yaml").write_text(COMPOSE_SOCIAL)
    (stack / "tor").mkdir()
    (g / ".stack-src" / "hugmesh-gateway").mkdir(parents=True)
    return str(g)


def _apps(m, domain):
    return {a.name: a for d in m.domains if d.name == domain for a in d.apps}


def _notes(m, domain):
    return [n for d in m.domains if d.name == domain for n in d.notes]


# ── the parse ───────────────────────────────────────────────────────────────────
def test_compose_files_are_the_main_file_plus_its_existing_includes(gen):
    names = [os.path.basename(p) for p in cf.compose_files(gen)]
    assert names == ["compose.local.yaml", "compose.alt-social.yaml",
                     "compose.games.yaml", "compose.real.yaml",
                     "compose.social-profile.yaml"]        # the missing one skipped


def test_stack_services_merge_profiles_across_overlays(gen):
    by = {s.name: s for s in cf.stack_services(gen)}
    assert by["hugmesh-pki-gateway"].context.endswith("/hugmesh-gateway")
    assert by["hugmesh-pki-gateway"].profiles == ()
    assert by["hugmesh-tor"].profiles == ("tor",) and by["hugmesh-tor"].context == "./tor"
    assert by["hugmesh-anubis"].profiles == ("anubis",) and by["hugmesh-anubis"].context == ""
    assert by["hugmesh-owncast-bff-api"].context.endswith("/hugmesh-owncast-bff-api")
    # compose.social-profile.yaml TAGS compose.real.yaml's tuwunel; the image stays
    assert by["tuwunel"].profiles == ("social",)
    assert by["tuwunel"].image.startswith("ghcr.io/matrix-construct/tuwunel")
    assert by["tuwunel"].files == ("compose.real.yaml", "compose.social-profile.yaml")
    assert "admin-bff-pg" not in by                          # volumes are not services


def test_platform_rows_are_exactly_the_builds_own_context_list():
    """THE derivation contract: on the real tree the platform rows of a domain are
    the repo names ``expected_build_contexts`` parses from compose.local.yaml — same
    regex, same file — so no row can name a folder compose would not resolve."""
    m = cf.code_folder_map(GENERATOR_DIR, "clone", "", [Domain(name="hugmesh.local")])
    plat = {a.name for a in m.domains[0].apps
            if a.kind == cf.KIND_REPO and cf.REASON_PLATFORM in a.reasons}
    assert plat == set(expected_build_contexts(GENERATOR_DIR))
    assert len(plat) >= 20
    # one folder however many services build from it
    gw = _apps(m, "hugmesh.local")["hugmesh-gateway"]
    assert set(gw.services) == {"hugmesh-pki-gateway", "hugmesh-be-gateway",
                                "hugmesh-fe-gateway"}


def test_every_catalogue_slug_resolves_on_the_real_tree_never_silently():
    """Each per-domain slug either adds a row (reason ``selected: <slug>``) or
    leaves a note naming the slug. A federation slug whose services were renamed
    away from ``hugmesh-<module>-…`` would fail here, which is the point."""
    for slug in DOMAIN_CATALOGUE:
        m = cf.code_folder_map(GENERATOR_DIR, "clone", "",
                               [Domain(name="d.example", optional_services=[slug])])
        rows = [a for a in m.domains[0].apps if f"selected: {slug}" in a.reasons]
        notes = [n for n in m.domains[0].notes if n.startswith(f"{slug}:")]
        assert rows or notes, f"{slug} vanished from the map"
        svc = local_services.by_slug(slug)
        if svc is not None and svc.is_federation():
            assert rows, f"federation slug {slug} matched no hugmesh-{svc.module}-* service"


# ── clone mode ──────────────────────────────────────────────────────────────────
def test_clone_mode_roots_at_stack_src_and_marks_what_is_not_downloaded(gen):
    m = cf.code_folder_map(gen, "clone", "", [Domain(name="hugmesh.local")])
    assert m.source_mode == "clone"
    assert m.root == os.path.join(gen, ".stack-src")
    assert m.root_exists is True and m.root_reason == ""
    assert m.notice == cf.CLONE_MODE_NOTICE
    apps = _apps(m, "hugmesh.local")
    assert apps["hugmesh-gateway"].exists and apps["hugmesh-gateway"].openable
    assert apps["hugmesh-gateway"].path == os.path.join(gen, ".stack-src", "hugmesh-gateway")
    missing = apps["hugmesh-admin-bff-api"]
    assert missing.exists is False and missing.openable is False
    assert missing.missing_reason == cf.NOT_DOWNLOADED_REASON
    assert "not downloaded yet" in missing.missing_reason
    # the frontend sub-context is the SAME checkout
    forge = apps["hugmesh-character-forge-bff-api"]
    assert forge.services == ("hugmesh-character-forge-ui",)
    assert forge.path.endswith("hugmesh-character-forge-bff-api")


def test_clone_mode_with_no_stack_src_yet(gen):
    import shutil
    shutil.rmtree(os.path.join(gen, ".stack-src"))
    m = cf.code_folder_map(gen, "clone", "", [Domain(name="hugmesh.local")])
    assert m.root_exists is False
    assert m.root_reason == cf.NOT_DOWNLOADED_REASON
    assert all(not a.openable for a in m.domains[0].apps)
    assert m.domains[0].openable_paths() == ()


# ── existing mode ───────────────────────────────────────────────────────────────
def test_existing_mode_roots_at_the_operators_tree(gen, tmp_path):
    src = tmp_path / "mine"
    (src / "hugmesh-user-ui").mkdir(parents=True)
    m = cf.code_folder_map(gen, "existing", str(src), [Domain(name="hugmesh.local")])
    assert m.root == str(src) and m.root_exists
    assert m.notice == cf.EXISTING_MODE_NOTICE
    apps = _apps(m, "hugmesh.local")
    assert apps["hugmesh-user-ui"].openable
    assert apps["hugmesh-user-ui"].path == str(src / "hugmesh-user-ui")
    gw = apps["hugmesh-gateway"]
    assert not gw.openable                      # .stack-src's copy is NOT consulted
    assert gw.missing_reason == f"no hugmesh-gateway checkout in {src}"
    assert m.domains[0].openable_paths() == (str(src / "hugmesh-user-ui"),)


def test_existing_mode_with_no_directory_typed_yet(gen):
    m = cf.code_folder_map(gen, "existing", "   ", [Domain(name="hugmesh.local")])
    assert m.root == "" and m.root_exists is False
    assert m.root_reason == cf.NO_SOURCE_DIR_REASON
    apps = _apps(m, "hugmesh.local")
    assert apps["hugmesh-gateway"].path == ""
    assert apps["hugmesh-gateway"].missing_reason == cf.NO_SOURCE_DIR_REASON


def test_existing_mode_with_a_directory_that_does_not_exist(gen, tmp_path):
    m = cf.code_folder_map(gen, "existing", str(tmp_path / "gone"),
                           [Domain(name="hugmesh.local")])
    assert m.root_exists is False and "does not exist" in m.root_reason


# ── the root is spelled exactly as the build spells it ──────────────────────────
@pytest.mark.parametrize("typed", ["~/x", "../x", "  /tmp  ", "rel/dir", "/a//b/../c"])
def test_the_existing_root_is_the_exact_path_the_build_reads(gen, typed):
    """source_root must equal the STACK_SRC the stack node hands to make — not a
    similar-looking path. The build does NOT expand ``~``; this holds the two to one
    spelling so neither can drift (a typed ~/src once enabled folders under the real
    home while make read <cwd>/~/src)."""
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    node = LocalStackNode(gen, source_mode="existing", source_dir=typed)
    built = node._build_env(write_overlays=False)["STACK_SRC"]
    assert cf.source_root(gen, "existing", typed) == built


def test_a_typed_tilde_is_not_expanded_so_no_row_points_at_the_real_home(
        gen, tmp_path, monkeypatch):
    home = tmp_path / "home"
    (home / "x" / "hugmesh-gateway").mkdir(parents=True)
    monkeypatch.setenv("HOME", str(home))
    m = cf.code_folder_map(gen, "existing", "~/x", [Domain(name="hugmesh.local")])
    assert m.root == os.path.abspath("~/x") and m.root != str(home / "x")
    assert m.root_exists is False
    assert "does not expand" in m.root_reason
    assert all(not a.openable for a in m.domains[0].apps)
    assert m.domains[0].openable_paths() == ()


# ── per-domain services ─────────────────────────────────────────────────────────
def test_a_domain_without_optional_services_runs_only_the_platform_apps(gen):
    m = cf.code_folder_map(gen, "clone", "", [Domain(name="plain.example")])
    apps = _apps(m, "plain.example")
    assert set(apps) == {"hugmesh-gateway", "hugmesh-admin-bff-api",
                         "hugmesh-owncast-bff-api", "hugmesh-owncast-ui",
                         "hugmesh-user-ui", "hugmesh-character-forge-bff-api"}
    assert all(a.reasons == (cf.REASON_PLATFORM,) for a in apps.values())
    notes = _notes(m, "plain.example")
    assert len(notes) == 1 and notes[0].startswith("Also runs 1 stock image")
    assert "postgres:16-alpine" in notes[0]


def test_a_profile_slug_adds_its_build_context_as_a_selected_row(gen):
    m = cf.code_folder_map(gen, "clone", "",
                           [Domain(name="forum.example", optional_services=["phpbb"])])
    apps = _apps(m, "forum.example")
    assert apps["hugmesh-forum-api"].reasons == ("selected: phpbb",)
    assert apps["hugmesh-forum-api"].services == ("phpbb",)
    assert apps["hugmesh-forum-api"].missing_reason == cf.NOT_DOWNLOADED_REASON
    # its backing database is implied, not noted
    assert not any(n.startswith("phpbb:") for n in _notes(m, "forum.example"))


def test_a_federation_slug_marks_the_always_on_services_named_after_its_module(gen):
    m = cf.code_folder_map(gen, "clone", "",
                           [Domain(name="live.example", optional_services=["owncast"])])
    apps = _apps(m, "live.example")
    assert apps["hugmesh-owncast-ui"].reasons == (cf.REASON_PLATFORM, "selected: owncast")
    assert apps["hugmesh-owncast-bff-api"].reasons == (cf.REASON_PLATFORM,
                                                       "selected: owncast")
    assert apps["hugmesh-user-ui"].reasons == (cf.REASON_PLATFORM,)
    assert "owncast" in apps["hugmesh-owncast-ui"].why()


def test_a_stock_image_service_gets_a_note_and_no_row(gen):
    m = cf.code_folder_map(gen, "clone", "",
                           [Domain(name="s.example", optional_services=["akkoma", "tuwunel"])])
    apps = _apps(m, "s.example")
    assert "akkoma" not in apps and "tuwunel" not in apps
    notes = _notes(m, "s.example")
    akk = [n for n in notes if n.startswith("akkoma:")]
    assert akk == ["akkoma: runs stock images only (teslamint/akkoma:v3.20.0) — no "
                   "source folder"]                         # digest stripped
    tuw = [n for n in notes if n.startswith("tuwunel:")]
    assert len(tuw) == 1 and "ghcr.io/matrix-construct/tuwunel:v1.7.0" in tuw[0] \
        and "ghcr.io/mastodon/mastodon:v4.3.1" in tuw[0]


def test_games_builds_from_a_sibling_checkout_resolved_like_compose_does(gen, tmp_path):
    m = cf.code_folder_map(gen, "clone", "",
                           [Domain(name="g.example", optional_services=["games"])],
                           environ={})
    row = _apps(m, "g.example")["hugmesh-games"]
    assert row.kind == cf.KIND_PATH
    assert row.path == os.path.normpath(os.path.join(gen, "..", "hugmesh-games"))
    assert not row.exists and row.missing_reason.endswith("does not exist")
    # GAMES_SRC overrides, exactly as ${GAMES_SRC:-…} does for compose
    other = tmp_path / "elsewhere"
    other.mkdir()
    m2 = cf.code_folder_map(gen, "clone", "",
                            [Domain(name="g.example", optional_services=["games"])],
                            environ={"GAMES_SRC": str(other)})
    row2 = _apps(m2, "g.example")["elsewhere"]
    assert row2.path == str(other) and row2.openable


def test_an_unknown_or_kubernetes_lane_slug_says_so(gen):
    m = cf.code_folder_map(gen, "clone", "",
                           [Domain(name="k.example",
                                   optional_services=["workloadConsole", "nosuch"])])
    notes = _notes(m, "k.example")
    assert any(n.startswith("workloadConsole:") and "Kubernetes" in n for n in notes)
    assert any(n.startswith("nosuch:") and "no folder" in n for n in notes)
    assert "nosuch" not in _apps(m, "k.example")


def test_an_own_sign_in_domain_notes_its_casdoor_has_no_folder(gen):
    m = cf.code_folder_map(gen, "clone", "",
                           [Domain(name="own.example", idp=DOMAIN_IDP_OWN)])
    assert any(n.startswith("Own sign-in") for n in _notes(m, "own.example"))
    m2 = cf.code_folder_map(gen, "clone", "", [Domain(name="sd.example")])
    assert not any(n.startswith("Own sign-in") for n in _notes(m2, "sd.example"))


def test_saved_record_dicts_are_accepted_like_domain_rows(gen):
    rec = {"name": "rec.example", "title": "", "idp": "superdomain",
           "optional_services": ["phpbb"]}
    m = cf.code_folder_map(gen, "clone", "", [rec, {"name": "  "}])
    assert [d.name for d in m.domains] == ["rec.example"]
    assert "hugmesh-forum-api" in _apps(m, "rec.example")


def test_open_all_opens_each_existing_folder_once(gen):
    m = cf.code_folder_map(gen, "clone", "", [Domain(name="hugmesh.local")])
    dom = m.domains[0]
    assert dom.openable_paths() == (os.path.join(gen, ".stack-src", "hugmesh-gateway"),)
    assert len([a for a in dom.apps if a.name == "hugmesh-gateway"]) == 1
    # the contract holds for rows a reuser (#651) builds by hand too: two rows on
    # one folder, and a missing one, give that folder ONCE
    p = os.path.join(gen, ".stack-src", "hugmesh-gateway")
    rows = (cf.AppFolder("a", cf.KIND_REPO, p, True, "", ("x",), ("platform",)),
            cf.AppFolder("b", cf.KIND_REPO, p, True, "", ("y",), ("platform",)),
            cf.AppFolder("c", cf.KIND_REPO, p + "-gone", False, "no", ("z",), ("platform",)))
    assert cf.DomainFolders("d", rows).openable_paths() == (p,)


# ── the clone-mode notice is true of the script ────────────────────────────────
def test_the_clone_notice_matches_what_clone_all_repos_really_does():
    with open(os.path.join(GENERATOR_DIR, "scripts", "clone-all-repos.sh"),
              encoding="utf-8") as fh:
        script = fh.read()
    # the reset happens, on checkouts the disposability check lets through …
    assert 'reset --hard --quiet "origin/${GIT_REF}"' in script
    assert "checkout_is_disposable" in script
    # … and that check counts COMMITS only, so tracked-file edits are discarded
    assert 'rev-list --count "origin/$2..HEAD"' in script
    assert "Working-tree edits are deliberately NOT" in script
    assert "survive a reset anyway" in script               # "Untracked files\n# survive…"
    assert "KEPT" in script
    for phrase in ("git-resets it to origin/main", "uncommitted edits to tracked files",
                   "LOST", "local commits is kept", "untracked files survive",
                   "Build from a source tree I already have"):
        assert phrase in cf.CLONE_MODE_NOTICE, phrase
    assert "GIT_REF:-main" in script                       # "origin/main" is the default


def test_the_existing_mode_notice_is_backed_by_the_no_clone_interlock():
    from hugmesh_studio.core.local_stack_node import LocalStackNode
    env = LocalStackNode(GENERATOR_DIR, source_mode="existing",
                         source_dir=GENERATOR_DIR)._build_env()
    assert env.get("STACK_NO_CLONE") == "1"
    assert "fetched, updated or git-reset" in cf.EXISTING_MODE_NOTICE
