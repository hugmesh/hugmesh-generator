"""The offline "GitHub" the org-export tests share (core, GUI and TUI): a fake
generator checkout with a small compose file, three source repositories built from
the fixture copies of real repositories, a folder of bare repositories standing in
for the organisation, a fake ``gh`` on PATH that records its calls, and a runner that
refuses any real host. Not a test module (no ``test_`` prefix) so pytest never
collects it twice."""
from __future__ import annotations

import os
import shutil
import stat
import subprocess

from hugmesh_studio.core import org_export as oe

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURES = os.path.join(HERE, "fixtures", "org_export")
SOURCES = os.path.join(FIXTURES, "sources")

#: How the fixture writes its text files, on every OS (see make_world).
_TEXT = {"encoding": "utf-8", "newline": "\n"}

COMPOSE_LOCAL = """\
# a slice of the real compose.local.yaml: one first-party platform app, one stock
# image, one profile-gated service — the shape core/code_folders reads
services:
  hugmesh-actions:
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-actions
  actions-db:
    image: postgres:16-alpine
  hugmesh-forum-api:
    profiles: ["phpbb"]
    build:
      context: ${STACK_SRC:-../../.stack-src}/hugmesh-forum-api
"""

FAKE_GH = r"""#!/usr/bin/env bash
# fake gh: records every call; answers `repo view` / `repo create` from the bare
# repositories under $FAKE_GH_ROOT. Never touches the network.
set -eu
printf '%s\n' "$*" >> "$FAKE_GH_LOG"
root="$FAKE_GH_ROOT"
case "${1:-} ${2:-}" in
  "repo view")
    full="$3"; dir="$root/$full.git"
    if [ ! -d "$dir" ]; then
      echo "GraphQL: Could not resolve to a Repository with the name '$full'. (repository)" >&2
      exit 1
    fi
    empty=true
    if [ -n "$(git -C "$dir" for-each-ref refs/heads)" ]; then empty=false; fi
    vis=$(cat "$dir/VISIBILITY" 2>/dev/null || echo PRIVATE)
    printf '{"name":"%s","isEmpty":%s,"visibility":"%s"}\n' "${full#*/}" "$empty" "$vis"
    ;;
  "repo create")
    full="$3"; dir="$root/$full.git"
    mkdir -p "$(dirname "$dir")"; git init -q --bare "$dir"
    vis=PRIVATE
    for a in "$@"; do case "$a" in --public) vis=PUBLIC;; --internal) vis=INTERNAL;; esac; done
    echo "$vis" > "$dir/VISIBILITY"
    echo "https://github.com/$full"
    ;;
  *) echo "fake gh: unsupported: $*" >&2; exit 2;;
esac
"""


def git(cwd, *args, env=None) -> str:
    full = dict(os.environ, GIT_AUTHOR_NAME="Fixture", GIT_AUTHOR_EMAIL="f@example",
                GIT_COMMITTER_NAME="Fixture", GIT_COMMITTER_EMAIL="f@example")
    full.update(env or {})
    r = subprocess.run(["git", *args], cwd=cwd, env=full, stdout=subprocess.PIPE,
                       stderr=subprocess.PIPE, text=True, check=False)
    assert r.returncode == 0, f"git {' '.join(args)} in {cwd}: {r.stderr}"
    return r.stdout.strip()


def make_source_repo(root: str, name: str, extra_files: dict | None = None,
                     with_origin: bool = False) -> str:
    """A git repository at <root>/<name> holding the fixture files (+ extras)."""
    src = os.path.join(SOURCES, name)
    dst = os.path.join(root, name)
    shutil.copytree(src, dst)
    for rel, text in (extra_files or {}).items():
        full = os.path.join(dst, rel)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, "w", encoding="utf-8") as fh:
            fh.write(text)
    git(dst, "init", "-q", "-b", "main")
    git(dst, "add", "-A")
    git(dst, "-c", "commit.gpgsign=false", "commit", "-q", "-m", f"fixture {name}")
    if with_origin:
        # the shape of a real checkout: origin/HEAD -> origin/main
        git(dst, "update-ref", "refs/remotes/origin/main", "HEAD")
        git(dst, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    return dst


#: The git identity of "the person running the export" in every test: the engine
#: names no author of its own, so git would otherwise read the test host's
#: ``user.name`` / ``user.email`` and the suite would depend on the box it runs on.
RUNNER_IDENTITY = ("Test Exporter", "exporter@example.invalid")


class RecordingRunner(oe.SubprocessRunner):
    """The real runner with the fake gh first on PATH, every call recorded, a
    pinned git identity for the runner (see :data:`RUNNER_IDENTITY`), and a hard
    refusal of anything that names a real host."""

    def __init__(self, fake_bin: str, gh_root: str, gh_log: str):
        self.calls: list[list[str]] = []
        self.fake_bin, self.gh_root, self.gh_log = fake_bin, gh_root, gh_log

    def run(self, argv, *, cwd=None, env=None, timeout=600):
        for a in argv:
            assert "https://" not in a and "github.com" not in a and "git@" not in a, \
                f"a real host reached the runner: {argv}"
        self.calls.append(list(argv))
        full = dict(env or {})
        full["PATH"] = self.fake_bin + os.pathsep + os.environ.get("PATH", "")
        full["FAKE_GH_ROOT"] = self.gh_root
        full["FAKE_GH_LOG"] = self.gh_log
        # the runner's own identity, as `git config user.*` would give it; a config
        # that names an author wins because the engine passes it in ``env``
        full.setdefault("GIT_AUTHOR_NAME", RUNNER_IDENTITY[0])
        full.setdefault("GIT_AUTHOR_EMAIL", RUNNER_IDENTITY[1])
        full.setdefault("GIT_COMMITTER_NAME", RUNNER_IDENTITY[0])
        full.setdefault("GIT_COMMITTER_EMAIL", RUNNER_IDENTITY[1])
        return super().run(argv, cwd=cwd, env=full, timeout=timeout)

    def gh_calls(self) -> list[str]:
        try:
            with open(self.gh_log, encoding="utf-8") as fh:
                return [ln.strip() for ln in fh if ln.strip()]
        except OSError:
            return []


def make_world(tmp_path) -> dict:
    """A fake generator checkout, three source repositories (+ one stray checkout
    outside the domain's map), an empty 'GitHub', the fake gh and a recording
    runner, plus the config that ties them together."""
    gen = tmp_path / "generator"
    (gen / "tests" / "stack").mkdir(parents=True)
    # UTF-8 and LF on every OS: a bare write_text() on Windows writes the code page
    # (the compose file's em dash became 0x97) and CRLF
    (gen / "tests" / "stack" / "compose.local.yaml").write_text(COMPOSE_LOCAL, **_TEXT)
    # the fake generator is a git checkout too, so a config that keeps
    # include_generator (the saved-mesh door's default) exports it as well
    (gen / "README.md").write_text("a stand-in for hugmesh-generator in tests\n", **_TEXT)
    git(str(gen), "init", "-q", "-b", "main")
    git(str(gen), "add", "-A")
    git(str(gen), "-c", "commit.gpgsign=false", "commit", "-q", "-m", "fixture generator")
    src = tmp_path / "src"
    src.mkdir()
    make_source_repo(str(src), "hugmesh-parent", with_origin=True)
    make_source_repo(str(src), "hugmesh-commons")
    make_source_repo(str(src), "hugmesh-actions")
    # the other two links of the Java chain, as stand-ins (the parent fixture's
    # files under their names) so the default repository set has a checkout for each
    for name in ("hugmesh-build-config", "hugmesh-auth-core"):
        # the build-config stand-in has the real one's shape (a pom and NO mvnw);
        # a copy of the parent would hide the generated build's wrapper assumption
        shutil.copytree(os.path.join(SOURCES, "hugmesh-build-config" if name.endswith("config")
                                     else "hugmesh-parent"), str(src / name))
        (src / name / "STAND-IN.md").write_text(f"a stand-in for {name} in tests\n", **_TEXT)
        git(str(src / name), "init", "-q", "-b", "main")
        git(str(src / name), "add", "-A")
        git(str(src / name), "-c", "commit.gpgsign=false", "commit", "-q", "-m", name)
    stray = src / "hugmesh-stray"
    stray.mkdir()
    (stray / "README.md").write_text("not in any compose file\n", **_TEXT)
    git(str(stray), "init", "-q", "-b", "main")
    git(str(stray), "add", "-A")
    git(str(stray), "-c", "commit.gpgsign=false", "commit", "-q", "-m", "stray")
    gh_root = tmp_path / "github"
    gh_root.mkdir()
    fake_bin = tmp_path / "bin"
    fake_bin.mkdir()
    gh = fake_bin / "gh"
    gh.write_text(FAKE_GH, **_TEXT)
    gh.chmod(gh.stat().st_mode | stat.S_IXUSR)
    runner = RecordingRunner(str(fake_bin), str(gh_root), str(tmp_path / "gh.log"))
    cfg = oe.ExportConfig(
        domain="mesh.example", org="exampleorg", generator_dir=str(gen),
        source_mode="existing", source_dir=str(src),
        skip_repos=["hugmesh-build-config", "hugmesh-auth-core"],
        include_generator=False, out_dir=str(tmp_path / "out"),
        remote_base=f"file://{gh_root}/")
    return {"gen": str(gen), "src": str(src), "gh_root": str(gh_root),
            "runner": runner, "cfg": cfg, "tmp": tmp_path}


def bare(world, target: str) -> str:
    return os.path.join(world["gh_root"], "exampleorg", target + ".git")


def bare_log(world, target: str, ref: str = "main") -> list[str]:
    return git(bare(world, target), "log", "--format=%H %an <%ae>", ref).splitlines()


def saved_mesh_naming_the_org(world, label: str = "exported mesh", services=(),
                              mesh_services=()) -> str:
    """A saved-mesh record in the (isolated) Studio state dir whose own domain names
    the org (and selects ``services`` on its own ROW) and whose source is the world's
    checkouts — what the Go-Live step finds. ``mesh_services`` is the mesh-wide
    Services step's list (``LocalMeshBootstrapConfig.services``, what the mesh
    actually runs); left empty it stays ``None``, the untouched record's shape. The
    record's config is an ordinary LocalMeshBootstrapConfig.to_dict(); the two
    repositories the test world does not hold are skipped through the record's
    generic twin, written next to it for the step's 'config file' door."""
    from hugmesh_studio.core import saved_meshes
    from hugmesh_studio.core.config import Domain
    from hugmesh_studio.core.local_mesh_bootstrap import LocalMeshBootstrapConfig
    from hugmesh_studio.core.local_mesh_domains import bootstrap_domain_records
    rec = saved_meshes.SavedMesh(id="20260101-000000-abcd", label=label,
                                 generator_dir=world["gen"])
    rec.config = LocalMeshBootstrapConfig(
        cluster_domain="mesh.example", source_mode="existing", source_dir=world["src"],
        services=tuple(mesh_services) if mesh_services else None,
        domains=bootstrap_domain_records(
            [Domain(name="mesh.example", github_org="exampleorg",
                    optional_services=list(services))], "mesh.example")
    ).to_dict()
    return saved_meshes.save(rec)


def studio_parser():
    """The Studio parser's shape for the ``--org-export`` family: the two pre-existing
    arguments the CLI reuses (app.py's ``--generator-dir`` and ``--config``) plus
    ``add_cli_arguments`` — so a test can parse a Terminal line without ``main()``."""
    import argparse
    ap = argparse.ArgumentParser()
    ap.add_argument("--generator-dir", default="")
    ap.add_argument("--config", default="")
    oe.add_cli_arguments(ap)
    return ap


def parse_terminal_line(line: str, generator_dir: str) -> "oe.ExportConfig":
    """``config_from_args`` of a Terminal line the GUI and the TUI show (``python3 -m
    hugmesh_studio ...``): the config the CLI would plan from that line."""
    import shlex
    words = shlex.split(line)
    assert words[:3] == ["python3", "-m", "hugmesh_studio"], words
    args = studio_parser().parse_args(words[3:])
    return oe.config_from_args(args, args.generator_dir or generator_dir)
