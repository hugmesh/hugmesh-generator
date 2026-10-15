"""core/org_export — the Go-Live "Export to GitHub org" engine, proven OFFLINE.

"GitHub" is a folder of bare repositories under a temp dir; ``gh`` is a fake on PATH
that records every call and answers ``repo view`` / ``repo create`` from that folder;
the sources are real files of three real repositories (tests/fixtures/org_export/
sources, copied read-only via ``git archive`` of their default branches) turned into
git repositories per test. Every git/gh call goes through a recording runner that
REFUSES any https URL, so a real org can never be reached from here.

What is pinned:

* the repository set comes from the code-folder map of the domain (platform apps +
  the domain's selected services) plus the Java build chain — a checkout outside
  that map is never exported;
* names: hugmesh-<x> -> <brand>-<x>, brand from the org slug; contents: org path
  segments and exported repository names, exact-token and idempotent; Java
  packages, Maven groupIds, Angular scopes and label keys untouched;
* exclusions (CLAUDE.md, .claude/, node_modules, secret-shaped files) and the
  refusal on a planted banned marker, naming the file;
* apply: one fresh commit per repository authored as the person running it (the
  runner's git identity, or the config's author), never a force push or a delete,
  ``unchanged`` on a second run, an existing non-empty repository refused unless
  'update via branch', and nothing created when there is no identity at all;
* the generated site repository: its files, its workflows parse as YAML and list
  every exported repository, on vars.RUNS_ON;
* the CLI: PLAN prints the plan, APPLY refuses without --apply;
* the per-domain org field round-trips through configs and saved-mesh records.
"""
from __future__ import annotations

import json
import os
import re
import shlex
import shutil

import pytest
import yaml

from hugmesh_studio.core import local_mesh_domains as lmd
from hugmesh_studio.core import org_export as oe
from hugmesh_studio.core.config import Domain, ImageConfig, github_org_problem
from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig

from _org_export_helpers import (  # noqa: E402
    FIXTURES, RUNNER_IDENTITY, RecordingRunner, bare as _bare, bare_log as _bare_log,
    git as _git, make_world, parse_terminal_line, saved_mesh_naming_the_org)

# the banned markers are spelled from parts here too: this file is part of the
# generator's own exported tree
CO_AUTHOR = "Co-Authored" + "-By"


@pytest.fixture
def world(tmp_path):
    """See _org_export_helpers.make_world: a fake generator checkout, the source
    repositories, an empty 'GitHub', the fake gh and a recording runner."""
    return make_world(tmp_path)



# ── configuration ───────────────────────────────────────────────────────────────────
def test_config_refuses_a_bad_org_or_domain(world):
    cfg = world["cfg"]
    assert cfg.problems() == []
    bad = oe.ExportConfig(domain="Not a domain", org="-bad-", generator_dir=world["gen"])
    problems = "\n".join(bad.problems())
    assert "domain must be" in problems and "not a GitHub org slug" in problems
    assert github_org_problem("a" * 40).startswith("GitHub org")
    assert github_org_problem("exampleorg") == "" and github_org_problem("") == ""


def test_brand_derives_from_the_org_slug():
    assert oe.brand_from_org("exampleorg") == "example"
    assert oe.brand_from_org("my-org") == "my"
    assert oe.brand_from_org("Acme") == "acme"
    assert oe.brand_from_org("org") == "org"          # nothing left: keep it
    cfg = oe.ExportConfig(org="exampleorg", brand="custom")
    assert cfg.effective_brand == "custom"
    assert oe.ExportConfig(domain="mesh.example", org="exampleorg").site_repo \
        == "mesh.example.github.io"


def test_defaults_name_no_real_organisation():
    """The engine's built-in defaults carry placeholders only: no concrete org, brand
    or domain (the neutrality rule; test_org_export_neutrality pins the strings)."""
    cfg = oe.ExportConfig()
    assert cfg.org == "" and cfg.brand == "" and cfg.domain == ""
    assert cfg.rename_map == {}
    assert cfg.author_name == "" and cfg.author_email == ""     # no person built in
    assert not hasattr(oe, "SNAPSHOT_AUTHOR")
    rules = oe.rename_rules(oe.ExportConfig(org="exampleorg"), ["hugmesh-parent"])
    assert all("exampleorg" in rep or "example-" in rep for _rx, rep, _n in rules)


# ── the repository set ──────────────────────────────────────────────────────────────
def test_repo_set_is_the_code_folder_map_plus_the_build_chain(world):
    cfg = world["cfg"]
    names, notes = oe.domain_repo_names(cfg)
    # hugmesh-actions: the one platform build context; the stock image is a note
    assert names == ["hugmesh-actions", "hugmesh-parent", "hugmesh-commons"]
    assert "hugmesh-stray" not in names and "hugmesh-forum-api" not in names
    assert any("stock image" in n for n in notes)
    # selecting phpbb for the domain adds the profile's build context
    cfg2 = oe.ExportConfig(**{**cfg.to_dict(), "optional_services": ["phpbb"]})
    names2, _ = oe.domain_repo_names(cfg2)
    assert "hugmesh-forum-api" in names2
    # the chain and the generator are on by default; the config can drop them
    cfg3 = oe.ExportConfig(**{**cfg.to_dict(), "skip_repos": [], "include_generator": True})
    names3, _ = oe.domain_repo_names(cfg3)
    assert names3[-5:] == [*oe.BUILD_LIBRARY_REPOS, oe.GENERATOR_REPO]


# ── the plan ────────────────────────────────────────────────────────────────────────
def test_plan_renames_repositories_and_rewrites_exact_tokens_only(world):
    cfg, runner = world["cfg"], world["runner"]
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    by = {r.source: r for r in p.repos}
    assert set(by) == {"hugmesh-actions", "hugmesh-parent", "hugmesh-commons"}
    assert by["hugmesh-parent"].target == "example-parent"
    assert by["hugmesh-parent"].target_full == "exampleorg/example-parent"
    assert by["hugmesh-parent"].ref == "refs/remotes/origin/main"      # origin/HEAD read
    assert by["hugmesh-commons"].ref == "HEAD"
    assert all(r.action == "create" for r in p.repos)            # nothing exists yet
    assert all(r.visibility == "private" for r in p.repos)
    # the commons pom names its parent artifact and the org's registry: both rewritten
    pom = open(os.path.join(by["hugmesh-commons"].workdir, "pom.xml"), encoding="utf-8").read()
    assert "<artifactId>example-parent</artifactId>" in pom
    assert "hugmesh-parent" not in pom
    assert "<groupId>net.hugmesh</groupId>" in pom                 # groupId untouched
    assert "github.com/hugmesh/" not in pom
    assert "pom.xml" in by["hugmesh-commons"].rewrites
    # a Java source keeps its package
    java = os.path.join(by["hugmesh-commons"].workdir,
                        "src/main/java/net/hugmesh/commons/security/RoleName.java")
    assert "package net.hugmesh.commons.security;" in open(java, encoding="utf-8").read()
    # the plan files exist and the text names every target
    text = open(os.path.join(p.out_dir, "org-export-plan.txt"), encoding="utf-8").read()
    for r in p.repos:
        assert r.target_full in text
    assert "mesh.example.github.io" in text
    assert "Deliberately NOT renamed" in text
    plan_json = json.load(open(os.path.join(p.out_dir, "org-export-plan.json")))
    assert plan_json["config"]["org"] == "exampleorg"
    # plan() never ran gh beyond `repo view`, and never git push
    assert all(c[:2] == ["gh", "repo"] and c[2] == "view" for c in runner.calls if c[0] == "gh")
    assert not any(c[:2] == ["git", "push"] for c in runner.calls)


def test_rewrite_rules_leave_packages_labels_and_scopes_alone_and_are_idempotent():
    cfg = oe.ExportConfig(domain="mesh.example", org="exampleorg")
    rules = oe.rename_rules(cfg, ["hugmesh-gateway", "hugmesh-user-ui", "hugmesh-user"])
    text = "\n".join([
        "image: ghcr.io/hugmesh/hugmesh-gateway:main",
        "url: https://github.com/hugmesh/hugmesh-user-ui.git",
        "uses: hugmesh/hugmesh-gateway/.github/workflows/x.yml@main",
        "package net.hugmesh.gateway;",
        "<groupId>net.hugmesh</groupId>",
        "import { x } from '@hugmesh/user-ui';",
        "hugmesh.net/vpn-egress: 'true'",
        "app: hugmesh-fe-gateway",            # a compose service, not a repo name
        "hugmesh-user-ui-extra",             # a longer token: not a repo name
        "service hugmesh-user-ui",
    ])
    once, n = oe.rewrite_text(text, rules)
    assert n > 0
    assert "ghcr.io/exampleorg/example-gateway:main" in once
    assert "https://github.com/exampleorg/example-user-ui.git" in once
    assert "uses: exampleorg/example-gateway/" in once
    assert "package net.hugmesh.gateway;" in once
    assert "<groupId>net.hugmesh</groupId>" in once
    assert "'@hugmesh/user-ui'" in once
    assert "hugmesh.net/vpn-egress" in once
    assert "app: hugmesh-fe-gateway" in once
    assert "hugmesh-user-ui-extra" in once
    assert "service example-user-ui" in once
    twice, n2 = oe.rewrite_text(once, rules)
    assert n2 == 0 and twice == once


def test_rename_map_file_extends_and_overrides_the_defaults(world, tmp_path):
    rm = tmp_path / "rename-map.json"
    rm.write_text(json.dumps({
        "repos": {"hugmesh-parent": "example-platform-parent"},
        "tokens": [{"pattern": r"\bExtra Token\b", "replace": "Renamed Token",
                    "note": "test"}],
        "skip_rewrite": ["LICENSE"]}))
    loaded = oe.load_rename_map(str(rm))
    cfg = world["cfg"]
    cfg.rename_map = oe.merge_rename_maps({}, loaded)
    assert oe.repo_target_name("hugmesh-parent", cfg) == "example-platform-parent"
    assert oe.repo_target_name("hugmesh-commons", cfg) == "example-commons"
    rules = oe.rename_rules(cfg, ["hugmesh-parent"])
    assert rules[-1][2] == "test"
    assert oe.rewrite_text("Extra Token and hugmesh-parent", rules)[0] \
        == "Renamed Token and example-platform-parent"
    bad = tmp_path / "bad.json"
    bad.write_text(json.dumps({"tokens": [{"pattern": "(", "replace": ""}]}))
    with pytest.raises(Exception):
        oe.load_rename_map(str(bad))
    bad.write_text(json.dumps({"excludes": ["x"]}))          # a typo'd key is refused
    with pytest.raises(ValueError, match="unknown keys excludes"):
        oe.load_rename_map(str(bad))


def test_the_rename_maps_exclude_list_drops_a_file_from_the_snapshot(world, tmp_path):
    """What a banned-marker refusal points at: a test script holding an example token
    is EXCLUDED (never published) rather than rewritten around. ``<repo>:<glob>``
    scopes the rule to one source repository; a bare glob applies to every one."""
    cfg, runner = world["cfg"], world["runner"]
    token = "github_pat_" + "11FAKE" + "A" * 30
    for name in ("hugmesh-commons", "hugmesh-actions"):
        src = os.path.join(world["src"], name)
        os.makedirs(os.path.join(src, "tests"), exist_ok=True)
        with open(os.path.join(src, "tests", "fake-token.sh"), "w", encoding="utf-8") as fh:
            fh.write(f"TOKEN={token}\n")
        _git(src, "add", "-A")
        _git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant")
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    refused = {r.source for r in p.repos if r.action == "refused: banned marker"}
    assert refused == {"hugmesh-commons", "hugmesh-actions"}
    note = next(r for r in p.repos if r.source == "hugmesh-commons").notes[0]
    assert "exclude list" in note and "hugmesh-commons:<path>" in note
    # scoped to one repository: only that one is unblocked
    cfg.rename_map = oe.merge_rename_maps({}, {"exclude": ["hugmesh-commons:tests/fake-token.sh"]})
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    by = {r.source: r for r in p.repos}
    assert not by["hugmesh-commons"].blocked
    assert "tests/fake-token.sh: excluded by the rename map" in by["hugmesh-commons"].excluded
    assert not os.path.exists(os.path.join(by["hugmesh-commons"].workdir, "tests", "fake-token.sh"))
    assert by["hugmesh-actions"].blocked
    # a bare glob applies everywhere
    cfg.rename_map = oe.merge_rename_maps({}, {"exclude": ["tests/fake-*.sh"]})
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    assert p.blocked == []


def test_snapshot_excludes_assistant_files_build_output_and_secrets(world):
    cfg, runner = world["cfg"], world["runner"]
    src = os.path.join(world["src"], "hugmesh-parent")
    for rel, text in {"CLAUDE.md": "never published\n",
                      ".claude/settings.json": "{}\n",
                      "node_modules/x/index.js": "x\n",
                      "target/classes/A.class": "\0\0",
                      "certs/server.key": "not a real key\n",
                      ".env": "SECRET=1\n",
                      "docs/kept.md": "kept\n"}.items():
        full = os.path.join(src, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)
    _git(src, "add", "-A", "-f")
    _git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant")
    # the export reads the DEFAULT branch (origin/main here), not a local HEAD
    p_stale = oe.plan(cfg, runner, stamp="20260101T000000Z")
    assert next(r for r in p_stale.repos if r.source == "hugmesh-parent").excluded == []
    _git(src, "update-ref", "refs/remotes/origin/main", "HEAD")
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    rp = next(r for r in p.repos if r.source == "hugmesh-parent")
    assert not rp.blocked
    excluded = "\n".join(rp.excluded)
    for name in ("CLAUDE.md", ".claude/settings.json", "node_modules/x/index.js",
                 "target/classes/A.class", "certs/server.key", ".env"):
        assert name in excluded, excluded
        assert not os.path.exists(os.path.join(rp.workdir, name))
    assert not os.path.isdir(os.path.join(rp.workdir, ".claude"))
    assert os.path.isfile(os.path.join(rp.workdir, "docs", "kept.md"))


def _plant(src, files):
    for rel, text in files.items():
        full = os.path.join(src, rel)
        os.makedirs(os.path.dirname(full) or src, exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)
    _git(src, "add", "-A", "-f")
    _git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant")
    _git(src, "update-ref", "refs/remotes/origin/main", "HEAD")


def test_an_npmrc_is_dropped_by_content_and_env_examples_stay(world):
    """A token-free .npmrc is build configuration a Dockerfile COPYs; a login is not."""
    cfg, runner = world["cfg"], world["runner"]
    _plant(os.path.join(world["src"], "hugmesh-parent"), {
        ".npmrc": "legacy-peer-deps=true\n",
        "tokened/.npmrc": "//registry.example/:_authToken=${NPM_TOKEN}\n",
        "basic/.npmrc": "//registry.example/:_password=abc\n",
        "plain/.npmrc": "_auth=abc\n",
        ".env.example": "API_URL=\n",
        ".env.sample": "API_URL=\n",
        ".env.template": "API_URL=\n",
        ".env.local": "API_URL=secret\n",
        ".env.production": "API_URL=secret\n",
        "Dockerfile.test": "COPY package*.json .npmrc ./\n"})
    p = oe.plan(cfg, runner, stamp="20260101T000000Z", probe=False)
    rp = next(r for r in p.repos if r.source == "hugmesh-parent")
    for kept in (".npmrc", ".env.example", ".env.sample", ".env.template"):
        assert os.path.isfile(os.path.join(rp.workdir, kept)), kept
        assert not any(e.startswith(kept + ":") for e in rp.excluded), rp.excluded
    assert open(os.path.join(rp.workdir, ".npmrc")).read() == "legacy-peer-deps=true\n"
    for gone in ("tokened/.npmrc", "basic/.npmrc", "plain/.npmrc", ".env.local",
                 ".env.production"):
        assert not os.path.exists(os.path.join(rp.workdir, gone)), gone
        assert any(e.startswith(gone + ":") for e in rp.excluded), (gone, rp.excluded)
    assert "tokened/.npmrc: npm login in .npmrc" in rp.excluded
    assert not rp.blocked


def test_an_unreadable_npmrc_is_dropped_and_named_as_such_never_published(world, monkeypatch):
    """Fail closed: an .npmrc the export cannot read might hold a login, so it is
    left out and the plan says why (a readable token-free one stays: see above)."""
    import builtins
    cfg, runner = world["cfg"], world["runner"]
    _plant(os.path.join(world["src"], "hugmesh-parent"), {
        "legacy-peer-deps.txt": "x\n", "web/.npmrc": "legacy-peer-deps=true\n"})
    real_open = builtins.open

    def refusing_open(file, mode="r", *a, **kw):
        if str(file).endswith("/web/.npmrc"):
            raise PermissionError(13, "Permission denied", str(file))
        return real_open(file, mode, *a, **kw)

    monkeypatch.setattr(builtins, "open", refusing_open)
    try:
        p = oe.plan(cfg, runner, stamp="20260101T000000Z", probe=False)
    finally:
        monkeypatch.undo()
    rp = next(r for r in p.repos if r.source == "hugmesh-parent")
    assert "web/.npmrc: unreadable .npmrc (could hold a login)" in rp.excluded, rp.excluded
    assert not os.path.exists(os.path.join(rp.workdir, "web", ".npmrc"))
    plan_file = json.load(open(os.path.join(p.out_dir, "org-export-plan.json")))
    named = [e for r in plan_file["repos"] for e in r["excluded"]]
    assert "web/.npmrc: unreadable .npmrc (could hold a login)" in named, "the plan must say it"
    # the check itself, with no plan around it
    d = os.path.join(os.path.dirname(rp.workdir), "unreadable-probe")
    os.makedirs(os.path.join(d, ".npmrc"))               # a directory cannot be read as a file
    assert oe._excluded_reason(".npmrc", d) == "unreadable .npmrc (could hold a login)"


def test_a_rename_that_is_not_a_repository_name_is_a_problem_and_touches_nothing(
        world, tmp_path):
    cfg, runner = world["cfg"], world["runner"]
    victim = tmp_path / "VICTIM"
    victim.mkdir()
    (victim / "precious.txt").write_text("keep\n")
    for bad in ("../../VICTIM", "../x", "a/b", "..", ".hidden", "x y", ""):
        cfg.rename_map = {"repos": {"hugmesh-commons": bad}}
        assert any("bad repository rename" in pr for pr in cfg.problems()), bad
        with pytest.raises(ValueError, match="bad repository rename"):
            oe.plan(cfg, runner, probe=False)
    cfg.rename_map = {"repos": {"../src": "ok"}}
    assert any("bad repository rename" in pr for pr in cfg.problems())
    cfg.rename_map = {"repos": ["hugmesh-commons"]}
    assert any("repos must be an object" in pr for pr in cfg.problems())
    assert (victim / "precious.txt").read_text() == "keep\n"
    assert not os.path.exists(os.path.join(world["gen"], "out", "org-export"))


@pytest.mark.parametrize("bad, fragment", [
    (["hugmesh-commons"], "rename_map must be an object"),
    ("hugmesh-commons", "rename_map must be an object"),
    (7, "rename_map must be an object"),
    ({"tokens": {"pattern": "a", "replace": "b"}}, "tokens must be a list"),
    ({"tokens": 3}, "tokens must be a list"),
    ({"tokens": ["a"]}, "every token rule needs pattern and replace"),
    # a string where a list of globs belongs would be read one character at a time,
    # and the lone "*" would drop every file of every repository
    ({"exclude": "*.md"}, "exclude must be a list of glob strings"),
    ({"skip_rewrite": "*.md"}, "skip_rewrite must be a list of glob strings"),
    ({"exclude": [3]}, "exclude must be a list of glob strings"),
])
def test_a_rename_map_of_the_wrong_shape_is_a_problem_line_not_a_traceback(
        world, bad, fragment):
    """A hand-edited inline map: problems() must answer with lines (the pages and
    the CLI print them), never raise AttributeError / TypeError out of the check."""
    cfg = world["cfg"]
    cfg.rename_map = bad
    lines = cfg.problems()
    assert any(fragment in ln for ln in lines), lines
    with pytest.raises(ValueError, match=re.escape(fragment)):
        oe.plan(cfg, world["runner"], probe=False)


@pytest.mark.parametrize("rename_map, fragment", [
    (["x"], "rename_map must be an object"),
    ({"exclude": "*.md"}, "exclude must be a list of glob strings"),
    ({"skip_rewrite": "*.md"}, "skip_rewrite must be a list of glob strings"),
    ({"tokens": {"pattern": "a", "replace": "b"}}, "tokens must be a list"),
])
def test_the_two_file_doors_refuse_a_rename_map_of_the_wrong_shape(
        world, tmp_path, rename_map, fragment):
    """The config file's inline map and a --rename-map file: a ValueError naming the
    part, never an AttributeError further on and never characters read as globs."""
    inline = tmp_path / "export.json"
    inline.write_text(json.dumps({"org": "exampleorg", "domain": "mesh.example",
                                  "rename_map": rename_map}))
    with pytest.raises(ValueError, match=re.escape(fragment)):
        oe.load_config(str(inline), world["gen"])
    if isinstance(rename_map, dict):
        standalone = tmp_path / "map.json"
        standalone.write_text(json.dumps(rename_map))
        with pytest.raises(ValueError, match=re.escape(fragment)):
            oe.load_rename_map(str(standalone))


def test_a_config_file_with_a_bad_inline_rename_is_refused_at_load(world, tmp_path):
    path = tmp_path / "export.json"
    path.write_text(json.dumps({"org": "exampleorg", "domain": "mesh.example",
                                "rename_map": {"repos": {"hugmesh-commons": "../../VICTIM"}}}))
    with pytest.raises(ValueError, match="bad repository rename"):
        oe.load_config(str(path), world["gen"])


def test_the_work_directory_guard_stops_a_target_that_escapes_even_if_problems_is_bypassed(
        world, tmp_path):
    victim = tmp_path / "VICTIM"
    victim.mkdir()
    (victim / "precious.txt").write_text("keep\n")
    cfg = world["cfg"]
    cfg.rename_map = {"repos": {"hugmesh-commons": "../../VICTIM"}}
    out_dir = str(tmp_path / "guard-out")
    os.makedirs(out_dir)
    with pytest.raises(ValueError, match="not a repository name"):
        oe._prepare_repo(world["runner"], "hugmesh-commons", cfg, [], out_dir, [])
    assert (victim / "precious.txt").read_text() == "keep\n"


def test_each_java_repository_records_the_settings_file_a_github_build_can_use(world):
    """The repository-root settings.xml of the fixtures is the GitLab registry file;
    only the file under .github reads the GitHub Packages login."""
    p = oe.plan(world["cfg"], world["runner"], stamp="20260101T000000Z", probe=False)
    by = {r.source: r for r in p.repos}
    assert by["hugmesh-parent"].maven_settings == ".github/maven-ci-settings.xml"
    assert by["hugmesh-commons"].maven_settings == ""
    assert any("GitLab registry file" in n for n in by["hugmesh-commons"].notes)
    rows = {r["source"]: r for r in json.load(
        open(os.path.join(p.site.workdir, "repos.json")))["repos"]}
    assert rows["hugmesh-parent"]["settings"] == ".github/maven-ci-settings.xml"
    assert rows["hugmesh-commons"]["settings"] == ""
    assert not any("CI_API_V4_URL" in open(os.path.join(p.site.workdir, f), encoding="utf-8").read()
                   for f in (".github/workflows/build-all.yml", "repos.json"))


def _maven_step_script(site_workdir):
    doc = yaml.safe_load(open(os.path.join(site_workdir, ".github/workflows/build-all.yml"),
                              encoding="utf-8"))
    step = next(st for st in doc["jobs"]["build"]["steps"]
                if st.get("name", "").startswith("Maven verify"))
    return step["run"], step["env"]


@pytest.mark.parametrize("settings, token, want_rc, want_args", [
    (".github/maven-ci-settings.xml", "tok", 0, "-B -s .github/maven-ci-settings.xml verify"),
    (".github/maven-ci-settings.xml", "", 1, None),     # fails early and says why
    ("", "", 0, "-B verify"),                             # no settings file: plain verify
    # a root settings.xml that is not the GitLab one needs no read token: the empty-token
    # stop belongs to the CI settings file alone
    ("settings.xml", "", 0, "-B -s settings.xml verify"),
])
def test_the_generated_maven_step_runs_the_recorded_settings_and_needs_the_token(
        world, tmp_path, settings, token, want_rc, want_args):
    """The step's own shell, run against a stub mvnw: what it passes is what the
    plan recorded, and the CI settings file never runs without a read token."""
    import subprocess
    p = oe.plan(world["cfg"], world["runner"], stamp="20260101T000000Z", probe=False)
    script, env = _maven_step_script(p.site.workdir)
    assert set(env) == {"UPSTREAM_PACKAGES_ACTOR", "UPSTREAM_PACKAGES_TOKEN", "MAVEN_SETTINGS"}
    work = tmp_path / "mvn-step"
    work.mkdir()
    mvnw = work / "mvnw"
    mvnw.write_text('#!/bin/sh\necho "mvnw $*" > ran.txt\n')
    mvnw.chmod(0o755)
    res = subprocess.run(["bash", "-c", script], cwd=work, capture_output=True, text=True,
                         env={"PATH": os.environ["PATH"], "MAVEN_SETTINGS": settings,
                              "UPSTREAM_PACKAGES_TOKEN": token,
                              "UPSTREAM_PACKAGES_ACTOR": "someone"})
    assert res.returncode == want_rc, res.stdout + res.stderr
    if want_args:
        assert (work / "ran.txt").read_text().strip() == f"mvnw {want_args}"
    else:
        assert "PACKAGES_READ_TOKEN" in res.stdout and not (work / "ran.txt").exists()


def _site_step(site_workdir, job, step_id=None, name_prefix=None):
    doc = yaml.safe_load(open(os.path.join(site_workdir, ".github/workflows/build-all.yml"),
                              encoding="utf-8"))
    return next(st for st in doc["jobs"][job]["steps"]
                if (step_id and st.get("id") == step_id)
                or (name_prefix and st.get("name", "").startswith(name_prefix)))


def test_the_matrix_the_repos_job_builds_carries_each_repositorys_settings_file_to_maven(
        world, tmp_path):
    """The hand-off repos.json -> `repos` job (jq) -> matrix row -> Maven step: the
    parent (which has the CI settings file) must reach mvnw with -s, and the commons
    library (which has only the GitLab file) must reach it with none."""
    import subprocess
    p = oe.plan(world["cfg"], world["runner"], stamp="20260101T000000Z", probe=False)
    step = _site_step(p.site.workdir, "repos", step_id="list")
    gh_out = tmp_path / "gh-output.txt"
    gh_out.write_text("")
    res = subprocess.run(["bash", "-c", step["run"]], cwd=p.site.workdir,
                         capture_output=True, text=True,
                         env={"PATH": os.environ["PATH"], "GITHUB_OUTPUT": str(gh_out)})
    assert res.returncode == 0, res.stdout + res.stderr
    outputs = dict(ln.split("=", 1) for ln in gh_out.read_text().splitlines() if "=" in ln)
    rows = {r["name"]: r for r in json.loads(outputs["matrix"])["include"]}
    assert set(rows) == {r.target for r in p.repos}, rows
    assert rows["example-parent"]["settings"] == ".github/maven-ci-settings.xml", rows
    assert rows["example-commons"]["settings"] == "", rows
    assert rows["example-parent"]["build"] == "java", rows
    script, _env = _maven_step_script(p.site.workdir)
    for name, want in (("example-parent", "-B -s .github/maven-ci-settings.xml verify"),
                       ("example-commons", "-B verify")):
        work = tmp_path / f"mvn-{name}"
        work.mkdir()
        mvnw = work / "mvnw"
        mvnw.write_text('#!/bin/sh\necho "mvnw $*" > ran.txt\n')
        mvnw.chmod(0o755)
        done = subprocess.run(
            ["bash", "-c", script], cwd=work, capture_output=True, text=True,
            env={"PATH": os.environ["PATH"], "MAVEN_SETTINGS": rows[name]["settings"],
                 "UPSTREAM_PACKAGES_TOKEN": "tok", "UPSTREAM_PACKAGES_ACTOR": "someone"})
        assert done.returncode == 0, done.stdout + done.stderr
        assert (work / "ran.txt").read_text().strip() == f"mvnw {want}", name


def test_a_root_settings_file_that_is_not_the_gitlab_one_is_used_when_no_ci_file(tmp_path):
    wd = tmp_path / "wd"
    wd.mkdir()
    assert oe._maven_settings(str(wd)) == ("", "")
    (wd / "settings.xml").write_text("<settings/>\n")
    assert oe._maven_settings(str(wd)) == ("settings.xml", "")
    (wd / ".github").mkdir()
    (wd / ".github" / "maven-ci-settings.xml").write_text("<settings/>\n")
    assert oe._maven_settings(str(wd)) == (".github/maven-ci-settings.xml", "")


def test_a_planted_banned_marker_refuses_that_repository_and_names_the_file(world):
    cfg, runner = world["cfg"], world["runner"]
    src = os.path.join(world["src"], "hugmesh-commons")
    with open(os.path.join(src, "NOTES.md"), "w", encoding="utf-8") as fh:
        fh.write(f"a note\n\n{CO_AUTHOR}: Someone <x@example>\n")
    _git(src, "add", "-A")
    _git(src, "-c", "commit.gpgsign=false", "commit", "-q", "-m", "plant")
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    rp = next(r for r in p.repos if r.source == "hugmesh-commons")
    assert rp.action == "refused: banned marker"
    assert rp.banned == ["NOTES.md: co-author trailer"]
    assert rp in p.blocked
    text = "\n".join(oe.plan_lines(p))
    assert "BLOCKED" in text and "NOTES.md: co-author trailer" in text
    # the site's repos.json leaves the blocked repository out
    repos_json = json.load(open(os.path.join(p.site.workdir, "repos.json")))
    assert "example-commons" not in [r["name"] for r in repos_json["repos"]]
    # and apply never creates or pushes it
    res = oe.apply(p, runner)
    skipped = next(r for r in res.repos if r.target == "exampleorg/example-commons")
    assert skipped.skipped.startswith("refused: banned marker")
    assert not os.path.isdir(_bare(world, "example-commons"))
    assert os.path.isdir(_bare(world, "example-parent"))


def test_other_banned_markers_are_recognised():
    found = {label for label, rx in oe.BANNED_MARKERS
             if rx.search("x\n-----BEGIN RSA PRIVATE KEY-----\nabc\n")}
    assert found == {"private key header"}
    # a quoted MENTION of the header (a scanner's own pattern) is not a key
    assert not any(rx.search('pat="-----BEGIN PRIVATE KEY-----"') for _l, rx in oe.BANNED_MARKERS)
    assert any(rx.search("token ghp_" + "a" * 36) for _l, rx in oe.BANNED_MARKERS)
    assert any(rx.search("see https://" + "claude" + ".ai/code/x") for _l, rx in oe.BANNED_MARKERS)
    # prose that happens to say "generated with --enable-games" is not the footer
    assert not any(rx.search("generated with `--enable-games`") for _l, rx in oe.BANNED_MARKERS)


# ── apply ───────────────────────────────────────────────────────────────────────────
def test_apply_pushes_one_fresh_commit_per_repository_never_force(world):
    cfg, runner = world["cfg"], world["runner"]
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    res = oe.apply(p, runner)
    assert res.failures == []
    assert [r.target for r in res.repos] == [
        "exampleorg/example-actions", "exampleorg/example-parent",
        "exampleorg/example-commons", "exampleorg/mesh.example.github.io"]
    for r in res.repos:
        assert r.action == "create" and r.branch == "main" and r.commit
        assert r.url.startswith("file://")
        log = _bare_log(world, r.target.split("/", 1)[1])
        assert len(log) == 1, log                       # a single commit: no history
        # authored as the PERSON RUNNING the export (the runner's git identity): the
        # engine names nobody of its own (the neutrality rule covers people too)
        assert log[0].endswith(f"{RUNNER_IDENTITY[0]} <{RUNNER_IDENTITY[1]}>"), log[0]
        assert log[0].startswith(r.commit)
    # the fixture's own commit never travelled: the bare repo knows nothing of it
    src_head = _git(os.path.join(world["src"], "hugmesh-parent"), "rev-parse", "HEAD")
    assert src_head not in _bare_log(world, "example-parent")[0]
    # never a force push, a delete, a mirror
    for call in res.calls:
        joined = " ".join(call)
        assert "--force" not in joined and "--mirror" not in joined
        assert "--delete" not in joined and " -f " not in f" {joined} "
        if call[:2] == ["git", "push"]:
            assert call[-1].startswith("HEAD:refs/heads/")
    # gh was the fake, called only for view/create
    verbs = {" ".join(c.split()[:2]) for c in runner.gh_calls()}
    assert verbs == {"repo view", "repo create"}
    created = [c for c in runner.gh_calls() if c.startswith("repo create")]
    assert all("--private" in c for c in created)
    # the result file audits every repository
    data = json.load(open(res.result_path))
    assert {r["target"] for r in data["repos"]} == {r.target for r in res.repos}
    assert all(r["commit"] and not r["skipped"] for r in data["repos"])


def test_a_configured_author_wins_and_no_identity_at_all_creates_nothing(world):
    """``author_name`` / ``author_email`` in the config override the runner's
    identity. With neither — no config author, no git identity — apply refuses
    BEFORE creating anything: every repository is reported skipped with git's own
    reason, and the stand-in GitHub stays empty (otherwise `gh repo create` would
    have made the empty repositories and the commits failed one by one)."""
    cfg, runner = world["cfg"], world["runner"]
    cfg.author_name, cfg.author_email = "Someone Else", "someone@example.invalid"
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    assert "Snapshot commits authored as: Someone Else <someone@example.invalid> (from the config)" \
        in oe.plan_lines(p)
    res = oe.apply(p, runner)
    assert res.failures == []
    assert _bare_log(world, "example-parent")[0].endswith("Someone Else <someone@example.invalid>")

    class NoIdentityRunner(RecordingRunner):
        def run(self, argv, *, cwd=None, env=None, timeout=600):
            full = dict(env or {})
            for k in ("GIT_AUTHOR_NAME", "GIT_AUTHOR_EMAIL", "GIT_COMMITTER_NAME",
                      "GIT_COMMITTER_EMAIL"):
                full[k] = ""                 # an empty value: git treats it as unset
            # and no user.name / user.email anywhere git looks
            full["HOME"] = str(world["tmp"] / "no-home")
            full["XDG_CONFIG_HOME"] = str(world["tmp"] / "no-home")
            full["GIT_CONFIG_GLOBAL"] = os.devnull
            full["GIT_CONFIG_SYSTEM"] = os.devnull
            full["GIT_CONFIG_NOSYSTEM"] = "1"
            return oe.SubprocessRunner.run(self, argv, cwd=cwd, env={
                **full, "PATH": self.fake_bin + os.pathsep + os.environ.get("PATH", ""),
                "FAKE_GH_ROOT": self.gh_root, "FAKE_GH_LOG": self.gh_log}, timeout=timeout)

    cfg.author_name = cfg.author_email = ""
    cfg.org = "otherorg"                          # a fresh org folder: nothing exists yet
    bare_runner = NoIdentityRunner(runner.fake_bin, runner.gh_root, runner.gh_log)
    p = oe.plan(cfg, bare_runner, stamp="20260101T000000Z")
    assert "Snapshot commits authored as: your own git identity" in "\n".join(oe.plan_lines(p))
    res = oe.apply(p, bare_runner)
    assert len(res.failures) == len(res.repos) == 4
    assert all("no git identity for the snapshot commits" in r.skipped for r in res.repos)
    assert not os.path.isdir(os.path.join(world["gh_root"], "otherorg"))
    assert not any(c.startswith("repo create") for c in bare_runner.gh_calls()
                   if "otherorg" in c)
    assert os.path.isfile(res.result_path)


def test_second_run_reports_unchanged_and_pushes_nothing(world):
    cfg, runner = world["cfg"], world["runner"]
    first = oe.apply(oe.plan(cfg, runner, stamp="20260101T000000Z"), runner)
    assert first.failures == []
    p2 = oe.plan(cfg, runner, stamp="20260202T000000Z")
    # the probe now sees the repositories, non-empty
    assert all(r.action == "exists (compared at apply)" for r in p2.repos)
    runner.calls.clear()
    second = oe.apply(p2, runner)
    assert second.failures == []
    assert all(r.action == "unchanged" for r in second.repos), [r.action for r in second.repos]
    assert not any(c[:2] == ["git", "push"] for c in runner.calls)
    for r in second.repos:
        assert len(_bare_log(world, r.target.split("/", 1)[1])) == 1


def test_an_existing_different_repository_is_refused_unless_update_via_branch(world):
    cfg, runner = world["cfg"], world["runner"]
    # somebody else's content already on main
    bare = _bare(world, "example-parent")
    os.makedirs(os.path.dirname(bare))
    _git(world["gh_root"], "init", "-q", "--bare", bare)
    other = world["tmp"] / "other"
    other.mkdir()
    (other / "README.md").write_text("theirs\n")
    _git(str(other), "init", "-q", "-b", "main")
    _git(str(other), "add", "-A")
    _git(str(other), "-c", "commit.gpgsign=false", "commit", "-q", "-m", "theirs")
    _git(str(other), "push", "-q", bare, "HEAD:refs/heads/main")
    theirs = _git(bare, "rev-parse", "main")
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    parent = next(r for r in p.repos if r.source == "hugmesh-parent")
    assert parent.action == "exists (compared at apply)"
    res = oe.apply(p, runner)
    r = next(x for x in res.repos if x.target == "exampleorg/example-parent")
    assert r.action == "refused: existing non-empty repository" and r.skipped
    assert _git(bare, "rev-parse", "main") == theirs          # untouched
    assert _git(bare, "for-each-ref", "--format=%(refname)").splitlines() == ["refs/heads/main"]
    # update via branch: export/<stamp>, main still theirs, nothing opened
    cfg.update = oe.UPDATE_BRANCH
    p2 = oe.plan(cfg, runner, stamp="20260303T000000Z")
    assert next(x for x in p2.repos if x.source == "hugmesh-parent").action == "update via branch"
    res2 = oe.apply(p2, runner)
    r2 = next(x for x in res2.repos if x.target == "exampleorg/example-parent")
    assert r2.action == "update via branch" and r2.branch == "export/20260303T000000Z"
    assert not r2.skipped
    assert _git(bare, "rev-parse", "main") == theirs
    assert len(_bare_log(world, "example-parent", "export/20260303T000000Z")) == 1


def test_a_repository_whose_content_is_on_another_branch_is_refused_too(world):
    """Measured before the fix: apply asked the remote for ``refs/heads/main`` ONLY, so
    a repository whose content lives on ``master`` looked empty — apply pushed a new
    ``main`` into it with the default ``update: refuse`` and reported the action as
    'update (empty repository)', on a repository the plan's own probe had just called
    non-empty (skeptic, round 1, blocker 2)."""
    cfg, runner = world["cfg"], world["runner"]
    bare = _bare(world, "example-parent")
    os.makedirs(os.path.dirname(bare))
    _git(world["gh_root"], "init", "-q", "--bare", "-b", "master", bare)
    other = world["tmp"] / "other"
    other.mkdir()
    (other / "README.md").write_text("theirs, on master\n")
    _git(str(other), "init", "-q", "-b", "master")
    _git(str(other), "add", "-A")
    _git(str(other), "-c", "commit.gpgsign=false", "commit", "-q", "-m", "theirs")
    _git(str(other), "push", "-q", bare, "HEAD:refs/heads/master")
    theirs = _git(bare, "rev-parse", "master")
    assert _git(bare, "for-each-ref", "--format=%(refname)").splitlines() == ["refs/heads/master"]
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    parent = next(r for r in p.repos if r.source == "hugmesh-parent")
    assert parent.action == "exists (compared at apply)"
    res = oe.apply(p, runner)
    r = next(x for x in res.repos if x.target == "exampleorg/example-parent")
    assert r.action == "refused: existing non-empty repository", (r.action, r.skipped)
    assert "master" in r.skipped and r.branch == ""
    assert _git(bare, "rev-parse", "master") == theirs
    assert _git(bare, "for-each-ref", "--format=%(refname)").splitlines() == ["refs/heads/master"]
    pushes = [c for c in runner.calls if c[:2] == ["git", "push"] and "example-parent" in c[3]]
    assert pushes == [], pushes
    # update via branch: export/<stamp> beside master, no main invented
    cfg.update = oe.UPDATE_BRANCH
    p2 = oe.plan(cfg, runner, stamp="20260303T000000Z")
    res2 = oe.apply(p2, runner)
    r2 = next(x for x in res2.repos if x.target == "exampleorg/example-parent")
    assert r2.action == "update via branch" and r2.branch == "export/20260303T000000Z"
    assert not r2.skipped
    assert sorted(_git(bare, "for-each-ref", "--format=%(refname)").splitlines()) == \
        ["refs/heads/export/20260303T000000Z", "refs/heads/master"]
    assert _git(bare, "rev-parse", "master") == theirs


def test_a_repository_gh_calls_non_empty_with_no_branch_at_all_is_refused(world):
    """The other half of the non-main refusal: ``gh repo view`` says ``isEmpty: false``
    while ``git ls-remote --heads`` lists no branch (the repository holds tags only).
    The fake gh derives isEmpty from refs/heads, so it cannot answer this way; a
    wrapping runner answers the view itself and lets every other call through. Before
    this test, dropping gh's answer (``elif branches:``) left the suite green and apply
    pushed a new main into a repository gh had just called non-empty (skeptic, round 2,
    mutation M-E)."""
    cfg, runner = world["cfg"], world["runner"]
    bare = _bare(world, "example-parent")
    os.makedirs(os.path.dirname(bare))
    _git(world["gh_root"], "init", "-q", "--bare", bare)
    other = world["tmp"] / "other"
    other.mkdir()
    (other / "README.md").write_text("theirs, tagged only\n")
    _git(str(other), "init", "-q", "-b", "main")
    _git(str(other), "add", "-A")
    _git(str(other), "-c", "commit.gpgsign=false", "commit", "-q", "-m", "theirs")
    _git(str(other), "push", "-q", bare, "HEAD:refs/tags/v1")
    assert _git(bare, "for-each-ref", "--format=%(refname)").splitlines() == ["refs/tags/v1"]
    assert _git(bare, "ls-remote", "--heads", bare) == ""          # no branch, really

    class NonEmptyViewRunner(RecordingRunner):
        def run(self, argv, *, cwd=None, env=None, timeout=600):
            if argv[:3] == ["gh", "repo", "view"] and argv[3] == "exampleorg/example-parent":
                self.calls.append(list(argv))
                body = json.dumps({"name": "example-parent", "isEmpty": False,
                                   "visibility": "PRIVATE"}).encode()
                return oe.RunResult(0, body, b"")
            return super().run(argv, cwd=cwd, env=env, timeout=timeout)

    stub = NonEmptyViewRunner(runner.fake_bin, runner.gh_root, runner.gh_log)
    p = oe.plan(cfg, stub, stamp="20260101T000000Z")
    parent = next(r for r in p.repos if r.source == "hugmesh-parent")
    assert parent.action == "exists (compared at apply)"
    res = oe.apply(p, stub)
    r = next(x for x in res.repos if x.target == "exampleorg/example-parent")
    assert r.action == "refused: existing non-empty repository", (r.action, r.skipped)
    assert "content gh reports as non-empty" in r.skipped and r.branch == ""
    assert _git(bare, "for-each-ref", "--format=%(refname)").splitlines() == ["refs/tags/v1"]
    pushes = [c for c in stub.calls if c[:2] == ["git", "push"] and "example-parent" in c[3]]
    assert pushes == [], pushes
    # the other repositories, which the fake gh really saw as missing, were created
    assert {x.action for x in res.repos if x.target != "exampleorg/example-parent"} == {"create"}
    # update via branch: export/<stamp> beside the tag, no main invented
    cfg.update = oe.UPDATE_BRANCH
    res2 = oe.apply(oe.plan(cfg, stub, stamp="20260303T000000Z"), stub)
    r2 = next(x for x in res2.repos if x.target == "exampleorg/example-parent")
    assert r2.action == "update via branch" and r2.branch == "export/20260303T000000Z"
    assert not r2.skipped
    assert sorted(_git(bare, "for-each-ref", "--format=%(refname)").splitlines()) == \
        ["refs/heads/export/20260303T000000Z", "refs/tags/v1"]


def test_a_missing_checkout_is_reported_not_invented(world):
    cfg, runner = world["cfg"], world["runner"]
    shutil.rmtree(os.path.join(world["src"], "hugmesh-commons"))
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    rp = next(r for r in p.repos if r.source == "hugmesh-commons")
    assert rp.action == "missing source" and rp.blocked
    assert "no git checkout at" in rp.notes[0]


# ── the site repository ─────────────────────────────────────────────────────────────
def test_site_repo_lists_every_exported_repository_and_its_workflows_parse(world):
    cfg, runner = world["cfg"], world["runner"]
    p = oe.plan(cfg, runner, stamp="20260101T000000Z")
    site = p.site
    assert site.target == "mesh.example.github.io" and site.kind == "site"
    files = sorted(os.path.relpath(os.path.join(d, f), site.workdir)
                   for d, _dirs, fs in os.walk(site.workdir) for f in fs)
    assert files == [".github/workflows/build-all.yml", ".github/workflows/pages.yml",
                     "README.md", "index.html", "repos.json"]
    repos_json = json.load(open(os.path.join(site.workdir, "repos.json")))
    assert repos_json["domain"] == "mesh.example" and repos_json["org"] == "exampleorg"
    names = [r["name"] for r in repos_json["repos"]]
    assert names == ["example-actions", "example-parent", "example-commons"]
    builds = {r["name"]: r["build"] for r in repos_json["repos"]}
    assert builds == {"example-actions": "java", "example-parent": "java",
                      "example-commons": "java"}
    assert all(r["url"] == f"https://github.com/exampleorg/{r['name']}" for r in repos_json["repos"])
    for wf in (".github/workflows/build-all.yml", ".github/workflows/pages.yml"):
        text = open(os.path.join(site.workdir, wf), encoding="utf-8").read()
        doc = yaml.safe_load(text)
        assert isinstance(doc, dict) and "jobs" in doc, wf
        # every {{PLACEHOLDER}} filled; ${{ expr }} is Actions syntax and stays
        assert not re.search(r"\{\{[A-Z_]+\}\}", text), wf
        for job in doc["jobs"].values():
            assert "vars.RUNS_ON" in str(job["runs-on"]), (wf, job["runs-on"])
    build = open(os.path.join(site.workdir, ".github/workflows/build-all.yml"),
                 encoding="utf-8").read()
    # the clone step takes the org and the matrix name, with a token input
    assert "repository: exampleorg/${{ matrix.name }}" in build
    assert "secrets.EXPORT_READ_TOKEN" in build
    assert "repos.json" in build                                # the list is read, not inlined
    # the repository-root settings.xml is the GitLab registry file: never passed
    assert '-s "${MAVEN_SETTINGS}"' in build and "-s settings.xml" not in build
    assert "UPSTREAM_PACKAGES_ACTOR: ${{ secrets.PACKAGES_READ_ACTOR || github.actor }}" in build
    assert "UPSTREAM_PACKAGES_TOKEN: ${{ secrets.PACKAGES_READ_TOKEN }}" in build
    assert "MAVEN_SETTINGS: ${{ matrix.settings }}" in build
    assert "secrets.GITHUB_TOKEN" not in build     # the job token cannot read a sibling's package
    assert "ci.yml" not in build
    assert "npm ci" in build and "npm run build" in build and "npm test" in build
    assert "uses: actions/checkout@v4" in build                 # the org's own pin level
    pages = open(os.path.join(site.workdir, ".github/workflows/pages.yml"),
                 encoding="utf-8").read()
    assert "actions/deploy-pages@v4" in pages and "pages: write" in pages
    index = open(os.path.join(site.workdir, "index.html"), encoding="utf-8").read()
    assert "repos.json" in index and "exampleorg" in index
    # every exported repository is reachable from the site's list, by name
    for r in p.repos:
        assert r.target in names


# ── the text both faces show, and the CLI ───────────────────────────────────────────
def test_plan_lines_name_every_target_and_what_is_not_renamed(world):
    p = oe.plan(world["cfg"], world["runner"], stamp="20260101T000000Z", probe=False)
    lines = oe.plan_lines(p)
    text = "\n".join(lines)
    assert lines[0].startswith("Export for mesh.example -> GitHub org exampleorg (brand example")
    for r in [*p.repos, p.site]:
        assert r.target_full in text
    for n in oe.NOT_RENAMED:
        assert n in text
    assert "Nothing has been created or pushed" in text
    cmd = oe.cli_command(world["cfg"], "APPLY")
    assert cmd.startswith("python3 -m hugmesh_studio --org-export APPLY --domain mesh.example "
                          "--org exampleorg --source-dir")
    assert cmd.endswith("--apply")
    # what is snapshotted is said per repository: the ref and the commit
    for r in p.repos:
        assert f"  {r.source}: {r.ref} @ {r.source_commit[:12]}" in lines
    assert any(ln.startswith("Snapshot commits authored as:") for ln in lines)
    # handed over with a config file: --config carries the file's rules, --domain
    # picks the row; a rename map travels too; nothing the file already says is
    # repeated (the out folder is the file's own here)
    cfg_path = world["tmp"] / "export.json"
    cfg_path.write_text(json.dumps(world["cfg"].to_dict()))
    cmd = oe.cli_command(world["cfg"], "PLAN", config_path=str(cfg_path),
                         rename_map_path="/x/map.json")
    assert cmd == (f"python3 -m hugmesh_studio --org-export PLAN --config {cfg_path} "
                   "--domain mesh.example --rename-map /x/map.json")
    # a file that cannot be read now: every value is spelled out, so the line stays
    # exact rather than silently falling back to the defaults
    cmd = oe.cli_command(world["cfg"], "PLAN", config_path="/x/missing.json")
    for flag in ("--source-dir", "--out", "--remote-base"):
        assert flag in cmd, (flag, cmd)


def test_a_candidate_from_a_generic_config_file_keeps_the_files_rules(world, tmp_path):
    """The GUI/TUI 'Add config file' door: a generic export config's skip_repos,
    include_generator, rename_map, visibility and update used to be dropped on the
    way to the candidate, so both faces planned the DEFAULTS of such a file
    (correctness skeptic B4). The candidate now carries the loaded config and
    ``to_config`` starts from it; what a face passes explicitly still wins."""
    cfg = world["cfg"]
    cfg.visibility = "public"
    cfg.update = oe.UPDATE_BRANCH
    cfg.rename_map = oe.merge_rename_maps({}, {"exclude": ["hugmesh-actions:Dockerfile"],
                                               "repos": {"hugmesh-commons": "example-core"}})
    path = tmp_path / "export.json"
    path.write_text(json.dumps(cfg.to_dict()))
    (c,) = oe.candidates_from_file(str(path), "/ignored")
    assert c.config is not None and c.config.skip_repos == cfg.skip_repos
    back = c.to_config()
    assert back.to_dict() == cfg.to_dict()
    over = c.to_config(visibility="internal", out_dir="/elsewhere")
    assert over.visibility == "internal" and over.out_dir == "/elsewhere"
    assert over.include_generator is False and over.skip_repos == cfg.skip_repos
    assert over.rename_map["exclude"] == ["hugmesh-actions:Dockerfile"]
    # a candidate from a saved mesh / image config carries no file config: defaults
    mesh = oe.candidates_from_file(os.path.join(FIXTURES, "mesh-config.json"), "/g")[0]
    assert mesh.config is None and mesh.to_config().include_generator is True
    # and the plan made from the file candidate honours every rule
    p = oe.plan(c.to_config(), world["runner"], stamp="20260101T000000Z", probe=False)
    targets = [r.target for r in p.repos]
    assert "example-generator" not in targets and "example-build-config" not in targets
    assert "example-core" in targets
    actions = next(r for r in p.repos if r.source == "hugmesh-actions")
    assert "Dockerfile: excluded by the rename map" in actions.excluded


def test_the_forbidden_flag_guard_fires_on_every_spelling(world):
    """``_run_checked`` is the ONE door every git/gh call takes at apply; a mutation
    that dropped its check survived the suite (correctness skeptic C2). Pinned: a
    force, a mirror, a delete, a prune and a ``+ref`` force-spelling all raise
    before the runner is reached, and the recorded call list stays empty."""
    runner = world["runner"]
    calls: list = []
    for argv in (["git", "push", "--force", "x"], ["git", "push", "-f", "x"],
                 ["git", "push", "--force-with-lease", "x"], ["git", "push", "--mirror", "x"],
                 ["git", "push", "--delete", "x", "main"], ["git", "fetch", "--prune", "x"],
                 ["git", "push", "x", "+HEAD:refs/heads/main"]):
        with pytest.raises(RuntimeError, match="never used"):
            oe._run_checked(runner, calls, argv)
    assert calls == [] and not any(c[:2] == ["git", "push"] for c in runner.calls)
    ok = oe._run_checked(runner, calls, ["git", "--version"])
    assert ok.returncode == 0 and calls == [["git", "--version"]]


def test_the_site_title_is_html_escaped_and_a_bad_inline_regex_is_a_problem(world):
    cfg = world["cfg"]
    cfg.site_title = 'Mesh <b>"&"</b>'
    p = oe.plan(cfg, world["runner"], stamp="20260101T000000Z", probe=False)
    html_text = open(os.path.join(p.site.workdir, "index.html"), encoding="utf-8").read()
    assert "Mesh &lt;b&gt;&quot;&amp;&quot;&lt;/b&gt;" in html_text
    assert "<b>" not in html_text.split("<h1>", 1)[1].split("</h1>", 1)[0]
    cfg.rename_map = {"tokens": [{"pattern": "ok"}]}
    assert any("needs pattern and replace" in pr for pr in cfg.problems())
    cfg.rename_map = {"tokens": [{"pattern": "(", "replace": "x"}]}
    assert any("bad regex" in pr for pr in cfg.problems())
    with pytest.raises(ValueError, match="bad regex"):      # a problem line, no traceback
        oe.plan(cfg, world["runner"], probe=False)


def test_the_generators_own_tree_exports_clean_with_the_documented_exclusions():
    """The generator is exported by default, and its own tree carries two test
    fixtures the banned-marker scan refuses (a fake AWS key, a fake fine-grained
    token). Without a way to drop them every GUI/TUI plan for a real domain was
    'refused: banned marker' (correctness skeptic B4). The ready-made exclusion
    map fixtures/org_export/generator-rename-map.json, which docs/GOLIVE-ORG-EXPORT.md
    points at, must keep this checkout's tree exportable — and this test is what
    goes red when a new fixture with a marker lands. Scans HEAD of this checkout
    (~5 s)."""
    gen = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    if not (os.path.isdir(os.path.join(gen, ".git")) or os.path.isfile(os.path.join(gen, ".git"))):
        pytest.skip("not a git checkout of the generator")
    out = os.path.join(os.environ.get("TMPDIR") or "/tmp", "org-export-self-scan")
    cfg = oe.ExportConfig(domain="mesh.example", org="exampleorg", generator_dir=gen,
                          out_dir=out, ref="HEAD")
    rules = oe.rename_rules(cfg, [oe.GENERATOR_REPO])
    runner = oe.SubprocessRunner()
    bare = oe._prepare_repo(runner, oe.GENERATOR_REPO, cfg, rules, out, [])
    assert bare.banned == ["tests/cloud-deploy/test-cloud-deploy-driver.sh: AWS access key",
                           "tests/scripts/test-stack-clone-credential.sh: GitHub fine-grained token"], \
        ("the generator's own banned markers changed: update generator-rename-map.json, "
         "docs/GOLIVE-ORG-EXPORT.md and this list", bare.banned)
    cfg.rename_map = oe.merge_rename_maps(
        {}, oe.load_rename_map(os.path.join(FIXTURES, "generator-rename-map.json")))
    clean = oe._prepare_repo(runner, oe.GENERATOR_REPO, cfg, rules, out, [])
    assert clean.banned == [] and not clean.blocked, clean.banned
    assert sum("excluded by the rename map" in x for x in clean.excluded) == 2
    doc = open(os.path.join(gen, "docs", "GOLIVE-ORG-EXPORT.md"), encoding="utf-8").read()
    for rel in ("tests/cloud-deploy/test-cloud-deploy-driver.sh",
                "tests/scripts/test-stack-clone-credential.sh", "generator-rename-map.json"):
        assert rel in doc, f"docs/GOLIVE-ORG-EXPORT.md does not name {rel}"
    shutil.rmtree(out, ignore_errors=True)


def test_cli_plan_prints_and_apply_refuses_without_the_flag(world, monkeypatch, capsys):
    from hugmesh_studio import app as app_mod
    monkeypatch.setenv("PATH", world["runner"].fake_bin + os.pathsep + os.environ["PATH"])
    monkeypatch.setenv("FAKE_GH_ROOT", world["gh_root"])
    monkeypatch.setenv("FAKE_GH_LOG", world["runner"].gh_log)
    # the CLI uses the real runner: the person's git identity, pinned here so the
    # test does not depend on the box's user.name / user.email
    for k, v in (("GIT_AUTHOR_NAME", RUNNER_IDENTITY[0]), ("GIT_AUTHOR_EMAIL", RUNNER_IDENTITY[1]),
                 ("GIT_COMMITTER_NAME", RUNNER_IDENTITY[0]),
                 ("GIT_COMMITTER_EMAIL", RUNNER_IDENTITY[1])):
        monkeypatch.setenv(k, v)
    cfg_path = world["tmp"] / "export.json"
    cfg_path.write_text(json.dumps(world["cfg"].to_dict()))
    base = ["--generator-dir", world["gen"], "--config", str(cfg_path)]
    assert app_mod.main([*base, "--org-export", "PLAN"]) == 0
    out = capsys.readouterr().out
    assert "exampleorg/example-parent" in out and "Nothing has been created" in out
    assert not os.path.isdir(_bare(world, "example-parent"))
    rc = app_mod.main([*base, "--org-export", "APPLY"])
    err = capsys.readouterr().err
    assert rc == 2 and "pass --apply" in err
    assert not os.path.isdir(_bare(world, "example-parent"))
    assert app_mod.main([*base, "--org-export", "APPLY", "--apply"]) == 0
    out = capsys.readouterr().out
    assert "Result file:" in out
    assert len(_bare_log(world, "example-parent")) == 1
    # an unknown key in the generic config is refused, not ignored
    bad = world["tmp"] / "bad.json"
    bad.write_text(json.dumps({"domain": "mesh.example", "org": "exampleorg", "token": "x"}))
    assert app_mod.main(["--generator-dir", world["gen"], "--config", str(bad),
                         "--org-export", "PLAN"]) == 2
    assert "unknown keys token" in capsys.readouterr().err


# ── where the domains with an org come from ─────────────────────────────────────────
def test_candidates_from_the_fixture_mesh_config_and_a_saved_mesh_record(tmp_path):
    cands = oe.candidates_from_file(os.path.join(FIXTURES, "mesh-config.json"), "/g")
    assert [(c.domain, c.org) for c in cands] == [("mesh.example", "exampleorg")]
    assert cands[0].generator_dir == "/g"
    # a saved-mesh record carries the org RAW in its config dict, read without the
    # bootstrap loader (so the step sees it even where that loader drops the key)
    rec = {"id": "m1", "label": "my mesh", "generator_dir": "/gen",
           "config": {"cluster_domain": "mesh.example", "source_mode": "existing",
                      "source_dir": "/src",
                      "domains": [{"name": "mesh.example", "title": "", "idp": "superdomain",
                                   "optional_services": ["phpbb"], "github_org": "exampleorg"},
                                  {"name": "chat.mesh.example", "title": "", "idp": "own",
                                   "optional_services": []}]}}
    path = tmp_path / "rec.json"
    path.write_text(json.dumps(rec))
    cands = oe.candidates_from_file(str(path))
    assert len(cands) == 1
    c = cands[0]
    assert (c.domain, c.org, c.source_mode, c.source_dir, c.generator_dir) == \
        ("mesh.example", "exampleorg", "existing", "/src", "/gen")
    assert c.optional_services == ["phpbb"]          # the own row's services travel
    assert "my mesh" in c.where
    cfg = oe.load_config(str(path))
    assert cfg.domain == "mesh.example" and cfg.org == "exampleorg"
    # a generic config: round trip through the CLI's own dict
    gen = tmp_path / "g.json"
    gen.write_text(json.dumps({"domain": "mesh.example", "org": "exampleorg",
                               "visibility": "public", "rename_map": {"repos": {"a": "b"}}}))
    cfg = oe.load_config(str(gen), generator_dir="/g")
    assert cfg.visibility == "public" and cfg.rename_map["repos"] == {"a": "b"}


def test_the_own_domains_selected_services_reach_its_repository_set(world, tmp_path, monkeypatch):
    """Measured before the fix: every door built the OWN domain's candidate with no
    services, so the repositories its selected services add (the phpbb profile's
    hugmesh-forum-api in the test world) were never planned for it — while an added
    row with the same services got them (skeptic, round 1, mutation M16 survived)."""
    from hugmesh_studio.core import saved_meshes
    gen = world["gen"]
    own_row = {"name": "mesh.example", "title": "", "idp": "superdomain",
               "optional_services": ["phpbb"], "github_org": "exampleorg"}
    added_row = {"name": "chat.mesh.example", "title": "", "idp": "own",
                 "optional_services": ["phpbb"], "github_org": "otherorg"}

    def names_for(c):
        return oe.domain_repo_names(c.to_config(generator_dir=gen, source_mode="existing",
                                                source_dir=world["src"]))[0]

    # a saved-mesh record through the config-file door
    rec = {"id": "m1", "label": "my mesh", "generator_dir": gen,
           "config": {"cluster_domain": "mesh.example", "source_mode": "existing",
                      "source_dir": world["src"], "domains": [own_row, added_row]}}
    path = tmp_path / "rec.json"
    path.write_text(json.dumps(rec))
    cands = oe.candidates_from_file(str(path))
    assert [(c.domain, c.org, c.optional_services) for c in cands] == \
        [("mesh.example", "exampleorg", ["phpbb"]), ("chat.mesh.example", "otherorg", ["phpbb"])]
    assert "hugmesh-forum-api" in names_for(cands[0])
    assert "hugmesh-forum-api" in names_for(cands[1])
    # the same record through the Studio state dir (what the Go-Live step scans)
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    sm = saved_meshes.SavedMesh(id="20260101-000000-abcd", label="my mesh", generator_dir=gen)
    sm.config = dict(rec["config"])
    saved_meshes.save(sm)
    scanned = oe.saved_mesh_candidates()
    assert [(c.domain, c.optional_services) for c in scanned] == \
        [("mesh.example", ["phpbb"]), ("chat.mesh.example", ["phpbb"])]
    assert "hugmesh-forum-api" in names_for(scanned[0])
    # an ImageConfig: the own domain's services are cluster_domain_services
    img = {"mode": "mesh", "cluster_domain": "mesh.example",
           "cluster_domain_github_org": "exampleorg", "cluster_domain_services": ["phpbb"],
           "domains": [{"name": "chat.mesh.example", "optional_services": [], "idp": "own"}]}
    ipath = tmp_path / "image.json"
    ipath.write_text(json.dumps(img))
    cands = oe.candidates_from_file(str(ipath), gen)
    assert [(c.domain, c.org, c.optional_services) for c in cands] == \
        [("mesh.example", "exampleorg", ["phpbb"])]
    assert "hugmesh-forum-api" in names_for(cands[0])
    # ... and load_config, the CLI's door, carries them into the plan itself
    cfg = oe.load_config(str(ipath), generator_dir=gen)
    cfg.source_mode, cfg.source_dir = "existing", world["src"]
    assert cfg.optional_services == ["phpbb"]
    assert "hugmesh-forum-api" in oe.domain_repo_names(cfg)[0]
    # without the selection the forum api is NOT in the set: the assertion above bites
    cfg.optional_services = []
    assert "hugmesh-forum-api" not in oe.domain_repo_names(cfg)[0]


def test_the_mesh_wide_services_step_reaches_the_own_domains_export(world, tmp_path, monkeypatch):
    """The most ordinary local mesh: the org typed on the own row, the services picked
    on the mesh-wide Services step. That per-row selection is recorded and NOT
    enforced (core/local_mesh_domains: the compose profiles come from ``services``),
    so the own row says [] while the mesh builds hugmesh-forum-api. Measured before
    the fix (integration skeptic, rounds 2 and 0): the own candidate carried no
    service and the export left the forum api out. Now the record's ``services`` is
    read too, narrowed to the domain catalogue, and unioned with the row's own."""
    from hugmesh_studio.core import saved_meshes
    gen = world["gen"]

    def record(services, row_services=()):
        cfg = LocalMeshBootstrapConfig(
            cluster_domain="mesh.example", source_mode="existing", source_dir=world["src"],
            services=services,
            domains=lmd.bootstrap_domain_records(
                [Domain(name="mesh.example", github_org="exampleorg",
                        optional_services=list(row_services)),
                 Domain(name="chat.mesh.example", github_org="otherorg")], "mesh.example"))
        return {"id": "m1", "label": "my mesh", "generator_dir": gen, "config": cfg.to_dict()}

    rec = record(("phpbb", "argocd", "metrics-server"))
    assert rec["config"]["domains"][0]["optional_services"] == []      # the row is empty
    assert rec["config"]["services"] == ["phpbb", "argocd", "metrics-server"]
    path = tmp_path / "rec.json"
    path.write_text(json.dumps(rec))
    own, added = oe.candidates_from_file(str(path))
    assert (own.domain, own.optional_services) == ("mesh.example", ["phpbb"])   # infra slugs own no repo
    assert (added.domain, added.optional_services) == ("chat.mesh.example", [])  # the own domain's only
    assert "hugmesh-forum-api" in oe.domain_repo_names(own.to_config())[0]
    assert "hugmesh-forum-api" not in oe.domain_repo_names(added.to_config())[0]
    # the same record through the Studio state dir (what the Go-Live step scans) ...
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    sm = saved_meshes.SavedMesh(id="20260101-000000-abcd", label="my mesh", generator_dir=gen)
    sm.config = dict(rec["config"])
    saved_meshes.save(sm)
    assert [(c.domain, c.optional_services) for c in oe.saved_mesh_candidates()] == \
        [("mesh.example", ["phpbb"]), ("chat.mesh.example", [])]
    # ... and through the CLI's door
    assert oe.load_config(str(path), domain="mesh.example").optional_services == ["phpbb"]
    # the union: the row's own selection first, the mesh-wide extras after, no repeats
    rec2 = record(("phpbb", "akkoma"), row_services=["akkoma", "games"])
    path2 = tmp_path / "rec2.json"
    path2.write_text(json.dumps(rec2))
    assert oe.candidates_from_file(str(path2))[0].optional_services == ["akkoma", "games", "phpbb"]
    # services=None (no picker used) and a junk value are "nothing" — the old reading
    rec3 = record(None)
    assert rec3["config"]["services"] is None
    path3 = tmp_path / "rec3.json"
    path3.write_text(json.dumps(rec3))
    assert oe.candidates_from_file(str(path3))[0].optional_services == []
    rec3["config"]["services"] = "phpbb"
    path3.write_text(json.dumps(rec3))
    assert oe.candidates_from_file(str(path3))[0].optional_services == []


def test_the_terminal_line_parses_back_to_the_exact_config_the_face_planned(
        world, tmp_path, monkeypatch):
    """Measured before the fix (correctness skeptic, round 0, blocker 1): the GUI and
    the TUI handed a file over as --config only for a GENERIC export config; a saved
    mesh or an image config became ``--domain D --org O``, so the line planned
    without the domain's selected services — one repository fewer than the step —
    and with --apply exported that smaller set, exit 0, no warning. Now every
    candidate's file travels as --config and every picker that differs from the
    file is a flag: the line's parse IS the face's config, field for field."""
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    saved_mesh_naming_the_org(world, services=["phpbb"])
    (c,) = oe.saved_mesh_candidates()
    assert c.config is None                       # not a generic config: the old gap
    # the ordinary case: the record as it is, the GUI's default pickers
    cfg = c.to_config(out_dir=str(tmp_path / "out"))
    line = oe.cli_command(cfg, "PLAN", config_path=c.path)
    assert f"--config {c.path} --domain mesh.example" in line and "--org " not in line
    back = parse_terminal_line(line, world["gen"])
    assert back == cfg
    assert oe.domain_repo_names(back) == oe.domain_repo_names(cfg)
    assert "hugmesh-forum-api" in oe.domain_repo_names(back)[0]
    # ... and WITHOUT the file the same export loses the service: the equality bites
    bare = parse_terminal_line(oe.cli_command(cfg, "PLAN"), world["gen"])
    assert bare != cfg and "hugmesh-forum-api" not in oe.domain_repo_names(bare)[0]
    # every picker changed over the file reaches the line and parses back
    rm = tmp_path / "extra.json"
    rm.write_text(json.dumps({"exclude": ["hugmesh-parent:LICENSE"]}))
    other_src = tmp_path / "other-src"
    other_src.mkdir()
    cfg2 = c.to_config(out_dir=str(tmp_path / "out2"), visibility="public",
                       update=oe.UPDATE_BRANCH, source_mode="existing",
                       source_dir=str(other_src), brand="otherbrand",
                       remote_base=f"file://{world['gh_root']}/")
    cfg2.rename_map = oe.merge_rename_maps(cfg2.rename_map or {}, oe.load_rename_map(str(rm)))
    plan_line = oe.cli_command(cfg2, "PLAN", config_path=c.path, rename_map_path=str(rm))
    apply_line = oe.cli_command(cfg2, "APPLY", config_path=c.path, rename_map_path=str(rm))
    for flag in (f"--source-dir {other_src} --source-mode existing", f"--rename-map {rm}",
                 f"--out {tmp_path / 'out2'}", "--visibility public", "--update branch",
                 "--brand otherbrand", f"--remote-base file://{world['gh_root']}/"):
        assert flag in plan_line, (flag, plan_line)
    # the apply form is the plan form with the verb swapped and the flag appended
    assert apply_line == plan_line.replace("--org-export PLAN", "--org-export APPLY", 1) + " --apply"
    assert parse_terminal_line(apply_line, world["gen"]) == cfg2
    # a cleared Source folder means the clone root: the file's folder is dropped, as the GUI does
    cfg3 = c.to_config(source_mode="clone", source_dir="")
    line3 = oe.cli_command(cfg3, "PLAN", config_path=c.path)
    assert "--source-mode clone" in line3 and "--source-dir" not in line3
    assert parse_terminal_line(line3, world["gen"]) == cfg3
    # the reverse flips over a generic file: it says public/branch, the pickers say private/refuse
    gen_cfg = world["cfg"]
    gen_cfg.visibility, gen_cfg.update = "public", oe.UPDATE_BRANCH
    gpath = tmp_path / "export.json"
    gpath.write_text(json.dumps(gen_cfg.to_dict()))
    (g,) = oe.candidates_from_file(str(gpath), world["gen"])
    cfg4 = g.to_config(visibility="private", update=oe.UPDATE_REFUSE)
    line4 = oe.cli_command(cfg4, "PLAN", config_path=g.path)
    assert "--visibility private" in line4 and "--update refuse" in line4
    assert parse_terminal_line(line4, world["gen"]) == cfg4
    # --update-via-branch keeps working, and the two spellings agree
    assert parse_terminal_line(line4 + " --update-via-branch", world["gen"]).update == oe.UPDATE_BRANCH


def test_a_services_value_that_is_not_a_list_is_no_selection_not_five_letters(tmp_path):
    """A hand-edited record can hold ``"optional_services": "phpbb"``; read raw and
    listed, that is ``['p', 'h', 'p', 'b', 'b']`` — five services the catalogue never
    heard of (skeptic, round 2). Only a list of strings counts, on the own row, on an
    added row and on an ImageConfig's ``cluster_domain_services`` alike."""
    rec = {"id": "m1", "label": "edited", "generator_dir": "/gen",
           "config": {"cluster_domain": "mesh.example",
                      "domains": [{"name": "mesh.example", "idp": "superdomain",
                                   "optional_services": "phpbb", "github_org": "exampleorg"},
                                  {"name": "chat.mesh.example", "idp": "own",
                                   "optional_services": "akkoma", "github_org": "otherorg"},
                                  {"name": "mixed.mesh.example", "idp": "own",
                                   "optional_services": ["phpbb", 7, None, "akkoma"],
                                   "github_org": "thirdorg"}]}}
    path = tmp_path / "rec.json"
    path.write_text(json.dumps(rec))
    cands = oe.candidates_from_file(str(path))
    assert [(c.domain, c.optional_services) for c in cands] == \
        [("mesh.example", []), ("chat.mesh.example", []), ("mixed.mesh.example", ["phpbb", "akkoma"])]
    img = {"mode": "mesh", "cluster_domain": "mesh.example",
           "cluster_domain_github_org": "exampleorg", "cluster_domain_services": "phpbb",
           "domains": []}
    ipath = tmp_path / "image.json"
    ipath.write_text(json.dumps(img))
    (c,) = oe.candidates_from_file(str(ipath), "/g")
    assert c.optional_services == []


def test_saved_mesh_candidates_scan_the_studio_state_dir(tmp_path, monkeypatch):
    from hugmesh_studio.core import saved_meshes
    monkeypatch.setenv("HUGMESH_STUDIO_STATE_DIR", str(tmp_path / "state"))
    assert oe.saved_mesh_candidates() == []
    rec = saved_meshes.SavedMesh(id="20260101-000000-abcd", label="exported mesh",
                                 generator_dir="/gen")
    rec.config = LocalMeshBootstrapConfig(
        cluster_domain="mesh.example",
        domains=lmd.bootstrap_domain_records(
            [Domain(name="mesh.example", github_org="exampleorg"),
             Domain(name="other.example")], "mesh.example")).to_dict()
    saved_meshes.save(rec)
    cands = oe.saved_mesh_candidates()
    assert [(c.domain, c.org) for c in cands] == [("mesh.example", "exampleorg")]
    assert cands[0].where == "saved mesh exported mesh"


# ── the per-domain org field (core/config + local_mesh_domains) ─────────────────────
def test_domain_github_org_round_trips_and_is_omitted_when_empty():
    cfg = ImageConfig(mode="mesh", cluster_domain="mesh.example")
    cfg.domains = [Domain(name="a.example"), Domain(name="b.example", github_org="exampleorg")]
    d = cfg.to_dict()
    assert "github_org" not in d["domains"][0]           # absent by default: old bytes
    assert d["domains"][1]["github_org"] == "exampleorg"
    assert "cluster_domain_github_org" not in d           # the own domain's, same rule
    back = ImageConfig.from_dict(d)
    assert back.domains[0].github_org == "" and back.domains[1].github_org == "exampleorg"
    m = cfg.mesh_manifest()
    assert "github_org" not in m["domains"][0] and m["domains"][1]["github_org"] == "exampleorg"
    assert "cluster_domain_github_org" not in m
    cfg.cluster_domain_github_org = "exampleorg"
    assert cfg.to_dict()["cluster_domain_github_org"] == "exampleorg"
    assert cfg.mesh_manifest()["cluster_domain_github_org"] == "exampleorg"
    assert ImageConfig.from_dict(cfg.to_dict()).cluster_domain_github_org == "exampleorg"
    # junk fails loudly at load, like idp and tor
    with pytest.raises(ValueError):
        ImageConfig.from_dict({"domains": [{"name": "x.example", "github_org": "-bad"}]})
    with pytest.raises(ValueError):
        ImageConfig.from_dict({"cluster_domain_github_org": "has space"})
    # null / absent is "" (every pre-existing config)
    assert ImageConfig.from_dict({"domains": [{"name": "x.example", "github_org": None}],
                                  "cluster_domain_github_org": None}).domains[0].github_org == ""


def test_local_mesh_record_carries_the_org_and_the_own_row_when_it_has_one():
    rows = [Domain(name="mesh.example", github_org="exampleorg"),
            Domain(name="chat.mesh.example"),
            Domain(name="x.mesh.example", github_org="otherorg", tor=True)]
    recs = lmd.bootstrap_domain_records(rows, "mesh.example")
    assert [r["name"] for r in recs] == ["mesh.example", "chat.mesh.example", "x.mesh.example"]
    assert recs[0]["github_org"] == "exampleorg"           # the own row IS recorded now
    assert "github_org" not in recs[1]                     # omit-when-empty
    assert recs[2]["github_org"] == "otherorg" and recs[2]["tor"] is True
    # without an org the own row stays unrecorded: emission neutrality holds
    assert lmd.bootstrap_domain_records([Domain(name="mesh.example")], "mesh.example") == ()
    # the in-memory read-back and the walk carry it
    cfg = LocalMeshBootstrapConfig(cluster_domain="mesh.example", domains=recs)
    md = lmd.domains_from_bootstrap(cfg)
    assert md.by_name("mesh.example").github_org == "exampleorg"
    assert md.by_name("x.mesh.example").github_org == "otherorg"
    md.by_name("chat.mesh.example").github_org = "thirdorg"
    lmd.record_walk(cfg, md, ["chat.mesh.example"])
    assert dict(cfg.domains[1])["github_org"] == "thirdorg"
    lines = lmd.imported_domains_lines(md)
    assert any("exports to GitHub org otherorg" in ln for ln in lines)
    assert cfg.to_dict()["domains"][0]["github_org"] == "exampleorg"


def test_a_saved_mesh_reopened_through_the_bootstrap_loader_keeps_every_org():
    """The Studio re-opens a saved mesh through ``LocalMeshBootstrapConfig.from_dict``
    (pages/localmesh._load_saved), then saves it again from the form. Measured
    before the fix: from_dict dropped ``github_org`` from every row, the form showed
    no org, and the next save wrote the record back WITHOUT it — the export
    candidate vanished after one re-open (both skeptics, round 0)."""
    rows = [Domain(name="mesh.example", github_org="exampleorg"),
            Domain(name="chat.mesh.example", github_org="otherorg", tor=True),
            Domain(name="plain.mesh.example")]
    on_disk = LocalMeshBootstrapConfig(
        cluster_domain="mesh.example",
        domains=lmd.bootstrap_domain_records(rows, "mesh.example")).to_dict()
    assert [r.get("github_org") for r in on_disk["domains"]] == ["exampleorg", "otherorg", None]
    back = LocalMeshBootstrapConfig.from_dict(on_disk)
    assert [dict(r).get("github_org") for r in back.domains] == ["exampleorg", "otherorg", None]
    assert "github_org" not in dict(back.domains[2])        # omit-when-empty survives too
    md = lmd.domains_from_bootstrap(back)
    assert [(d.name, d.github_org) for d in md.domains] == [
        ("mesh.example", "exampleorg"), ("chat.mesh.example", "otherorg"),
        ("plain.mesh.example", "")]
    # the re-save paths: a walk written into the record, and a fresh record from the form
    lmd.record_walk(back, md, ["chat.mesh.example"])
    assert [r.get("github_org") for r in back.to_dict()["domains"]] == \
        ["exampleorg", "otherorg", None]
    again = lmd.bootstrap_domain_records(md.domains, md.own_name)
    assert [r.get("github_org") for r in again] == ["exampleorg", "otherorg", None]
    assert LocalMeshBootstrapConfig.from_dict(
        LocalMeshBootstrapConfig(cluster_domain="mesh.example", domains=again).to_dict()
    ).to_dict()["domains"] == list(again)
    # a hand-edited record with a non-slug org is dropped by the loader, like a
    # non-true tor: the form never shows a value the Domains step would refuse
    bad = dict(on_disk)
    bad["domains"] = [dict(on_disk["domains"][0], github_org="bad-")]
    assert "github_org" not in dict(LocalMeshBootstrapConfig.from_dict(bad).domains[0])
