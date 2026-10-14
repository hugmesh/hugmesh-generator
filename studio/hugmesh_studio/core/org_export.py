"""Export a domain's repositories to a GitHub organisation — the Qt-free engine behind
the Go-Live wizard's optional "Export to GitHub org" step.

The operator's ask: "export the needed repositories in a domain to a given github org
that can be configured as part of the domain in studio; the github org will have a
github site repo called <yourdomain>.github.io and it will clone all the repos and build
actions from the hugmesh project ... copy over the existing code in the repos and
rename as needed."

THE API, kept small on purpose::

    cfg    = ExportConfig(domain="mesh.example", org="exampleorg", ...)
    plan   = plan(cfg, runner)                 # read-only: snapshots + the plan table
    result = apply(plan, runner)               # creates/pushes; needs an explicit call

Every ``git`` and ``gh`` call goes through ONE injected :class:`Runner`
(:class:`SubprocessRunner` for real; tests substitute a recording one with a fake
``gh`` on PATH and local bare repositories as "GitHub"), so the engine can be proven
end to end without the network.

WHAT "THE NEEDED REPOSITORIES IN A DOMAIN" MEANS HERE — and where it comes from:
:func:`core.code_folders.code_folder_map` (PR 743) is the ONE map from a domain row to
the checkouts its mesh builds: every first-party compose build context under
``${STACK_SRC}/hugmesh-<name>`` with no ``profiles:`` key is a PLATFORM app (every
domain runs it), and a domain's selected optional services add what their mechanism
names (a profile's build context, a federation module's services). Stock images carry
no folder and are never exported. On top of that map this module adds the repositories
the exported tree needs to BUILD at all: the Java library chain
(:data:`BUILD_LIBRARY_REPOS`: build-config -> parent -> commons -> auth-core, the chain
hugmesh-auth-core/.github/workflows/release-chain.yml publishes) and the generator
itself (the repository a mesh is generated from; ``include_generator``). The config
can add (``extra_repos``) or drop (``skip_repos``) names; nothing here keeps a second
list of "needed repositories".

THE SNAPSHOT. Each repository is exported as a FRESH single commit of its default
branch (``git archive``, no history), authored as the person running the export
(their own git identity — ``user.name`` / ``user.email`` — unless the config names
``author_name`` / ``author_email``; no person is built in). The tree
EXCLUDES ``CLAUDE.md``, any ``.claude/`` directory, ``.stack-src``, ``node_modules``,
build output, worktree files and secret-shaped files (:data:`EXCLUDED_DIRS`,
:data:`EXCLUDED_NAMES`, :data:`SECRET_GLOBS`), and the export REFUSES a repository —
naming the file — when a banned marker (:data:`BANNED_MARKERS`: a co-author trailer,
a tool footer, an assistant session link, an API key, a private-key header) is found
in what would be published.

THE RENAME MAP lives in one place (:func:`rename_rules`): repository names follow
``hugmesh-<name> -> <brand>-<name>`` (``brand`` derives from the org slug:
``exampleorg -> example``, overridable), and file CONTENTS get exact-token rewrites of
the org path segment (``ghcr.io/hugmesh/`` -> ``ghcr.io/<org>/``, ``github.com/hugmesh/``,
``hugmesh/hugmesh-<name>`` owner/repo refs) and of every exported repository's name.
Deliberately NOT renamed (:data:`NOT_RENAMED`): Java packages and Maven groupIds
(``net.hugmesh``), Angular package scopes (``@hugmesh/``), Kubernetes label keys
(``hugmesh.net/...``), compose service / systemd unit / script names that are not a
repository name, file and directory names, and the cluster domain — the memory of the
``systems.hugmesh -> net.hugmesh`` move says those are a separate, heavy migration.
Rewrites are exact-token and idempotent (a second run changes nothing), and a
``--rename-map FILE`` merges extra rules over the defaults.

THE SITE REPOSITORY ``<domain>.github.io`` is generated from the templates under
``org_export_site/``: a small static page listing the exported repositories from a
generated ``repos.json``, a workflow that clones every exported repository (one
matrix job each, a token input for private ones) and runs what each repository's own
CI runs — ``./mvnw -B -s settings.xml verify`` for a Java repository, ``npm ci``,
``npm run build`` and ``npm test`` (Karma, ChromeHeadlessCI) for an Angular one — on
``vars.RUNS_ON`` the way the org's workflows do, and a Pages workflow that publishes
the site. NOTE: the org holds no composite GitHub Actions (``hugmesh-actions`` is a
Java service, and no ``action.yml`` or ``workflow_call`` exists on any default
branch), so the build steps are spelled inline, taken from the repositories' own
``ci.yml`` files.

NEVER: a force push, a delete, a mirror, or a push into an existing non-empty
repository — whatever branch its content lives on (apply lists EVERY head and reads
``gh``'s ``isEmpty`` too; a repository with a ``master`` and no ``main`` is non-empty)
— unless its ``main`` already holds exactly the snapshot tree (reported
``unchanged``) or the config chose ``update: branch`` (pushed to ``export/<stamp>``,
nothing opened). Credentials are POINTERS: the person's own ``gh auth login`` and git
credential helper at run time; no token is ever read, stored or passed.
"""
from __future__ import annotations

import datetime as _dt
import fnmatch
import html
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import tarfile
from dataclasses import asdict, dataclass, field

from .config import Domain, github_org_problem

__all__ = [
    "ExportConfig", "RepoPlan", "Plan", "RepoResult", "Result", "Runner",
    "SubprocessRunner", "RunResult", "ExportCandidate",
    "BUILD_LIBRARY_REPOS", "GENERATOR_REPO", "SITE_REPO_SUFFIX",
    "VISIBILITY_CHOICES", "UPDATE_REFUSE", "UPDATE_BRANCH", "NOT_RENAMED",
    "EXCLUDED_DIRS", "EXCLUDED_NAMES", "SECRET_GLOBS", "BANNED_MARKERS",
    "brand_from_org", "repo_target_name", "rename_rules", "rewrite_text",
    "domain_repo_names", "load_config", "load_rename_map", "candidates_from_file",
    "saved_mesh_candidates", "plan", "apply", "plan_lines", "result_lines",
    "cli_command", "run_cli", "add_cli_arguments",
]

#: The Java build chain every exported service resolves at build time, in publish
#: order — exported with the apps so the tree can build (and be published) at all.
BUILD_LIBRARY_REPOS = ("hugmesh-build-config", "hugmesh-parent", "hugmesh-commons",
                       "hugmesh-auth-core")
#: The repository a mesh is generated from (this one): exported unless the config
#: says ``include_generator: false``.
GENERATOR_REPO = "hugmesh-generator"
SITE_REPO_SUFFIX = ".github.io"

VISIBILITY_CHOICES = ("private", "public", "internal")
UPDATE_REFUSE = "refuse"      # an existing non-empty repository is never touched
UPDATE_BRANCH = "branch"      # ... unless pushed to export/<stamp>, opening nothing
UPDATE_CHOICES = (UPDATE_REFUSE, UPDATE_BRANCH)

#: Directory names dropped anywhere in a snapshot.
EXCLUDED_DIRS = frozenset({".claude", ".stack-src", "node_modules", "target", "dist",
                           ".angular", "__pycache__", ".pytest_cache", ".git",
                           ".worktrees"})
#: File names dropped anywhere in a snapshot.
EXCLUDED_NAMES = frozenset({"CLAUDE.md", ".e2e-credentials"})
#: Secret-shaped file names (fnmatch on the base name) dropped from a snapshot.
SECRET_GLOBS = ("*.pem", "*.key", "*.p12", "*.pfx", "*.jks", "*.keystore", ".env",
                ".env.*", "id_rsa*", "id_ed25519*", "id_ecdsa*", ".npmrc", ".netrc",
                "*.secret", "*credentials*.json", "*.kubeconfig")

# The banned markers are spelled from PARTS so this module's own source (which is
# part of the generator's exported tree) never carries one.
_CO_AUTHOR = "Co-Authored" + "-By"
_TOOL_FOOTER = "Generated with"            # the footer's case; prose is lower-case
_SESSION_URL = "claude" + ".ai/"
#: ``(label, compiled regex)`` — a hit anywhere in a text file refuses the repository.
BANNED_MARKERS = (
    ("co-author trailer", re.compile(re.escape(_CO_AUTHOR), re.IGNORECASE)),
    ("tool footer", re.compile(re.escape(_TOOL_FOOTER) + r" \[")),
    ("robot footer", re.compile("\U0001F916")),
    ("assistant session link", re.compile(re.escape(_SESSION_URL), re.IGNORECASE)),
    ("GitHub token", re.compile(r"\b(?:ghp|gho|ghu|ghs|ghr)_[A-Za-z0-9]{36}\b")),
    ("GitHub fine-grained token", re.compile(r"\bgithub_pat_[A-Za-z0-9_]{22,}\b")),
    ("AWS access key", re.compile(r"\bAKIA[0-9A-Z]{16}\b")),
    ("Slack token", re.compile(r"\bxox[baprs]-[A-Za-z0-9-]{10,}\b")),
    ("private key header", re.compile(
        r"^-----BEGIN (?:RSA |EC |DSA |OPENSSH |PGP |ENCRYPTED )?PRIVATE KEY-----\s*$",
        re.MULTILINE)),
)

#: What the default rename map deliberately leaves alone (shown in every plan).
NOT_RENAMED = (
    "Java packages and Maven groupIds (net.hugmesh.*): a separate, heavy migration",
    "Angular package scopes (@hugmesh/*)",
    "Kubernetes label keys and API groups (hugmesh.net/*): frozen wire contracts",
    "compose service, systemd unit and script names that are not a repository name",
    "file and directory names (only contents are rewritten)",
    "the cluster domain and every hostname (templated at build time, not a rename)",
)

_TOKEN_BEFORE = r"(?<![A-Za-z0-9_@-])"
_TOKEN_AFTER = r"(?![A-Za-z0-9_-])"
_BRAND_RE = re.compile(r"^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?$")
_DOMAIN_RE = re.compile(r"^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$")
_REPO_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$")


# ── the runner seam ────────────────────────────────────────────────────────────────
@dataclass
class RunResult:
    returncode: int
    stdout: bytes = b""
    stderr: bytes = b""

    @property
    def text(self) -> str:
        return self.stdout.decode("utf-8", "replace")

    @property
    def err(self) -> str:
        return self.stderr.decode("utf-8", "replace")


class Runner:
    """The ONE way the engine runs ``git`` and ``gh``. ``run`` returns a
    :class:`RunResult` and never raises on a non-zero exit."""

    def run(self, argv: list[str], *, cwd: str | None = None,
            env: dict[str, str] | None = None, timeout: int = 600) -> RunResult:
        raise NotImplementedError


class SubprocessRunner(Runner):
    """The real thing. ``GH_TOKEN``/``GITHUB_TOKEN`` are REMOVED from the child
    environment on purpose: the ambient fine-grained token on this host cannot
    push, and the person's own ``gh auth login`` (the keyring) is the credential
    both ``gh`` and git's ``gh auth git-credential`` helper fall back to."""

    def run(self, argv, *, cwd=None, env=None, timeout=600) -> RunResult:
        full = dict(os.environ)
        full.pop("GH_TOKEN", None)
        full.pop("GITHUB_TOKEN", None)
        full.update(env or {})
        try:
            r = subprocess.run(argv, cwd=cwd, env=full, stdout=subprocess.PIPE,
                               stderr=subprocess.PIPE, timeout=timeout, check=False)
        except (OSError, subprocess.SubprocessError) as exc:
            return RunResult(127, b"", str(exc).encode())
        return RunResult(r.returncode, r.stdout or b"", r.stderr or b"")


# ── configuration ──────────────────────────────────────────────────────────────────
def brand_from_org(org: str) -> str:
    """The brand prefix an org slug implies: lower-cased, with a trailing ``org`` /
    ``-org`` dropped when something is left (``exampleorg -> example``,
    ``my-org -> my``, ``acme -> acme``). Overridable by ``ExportConfig.brand``."""
    s = (org or "").strip().lower()
    for suffix in ("-org", "org"):
        if s.endswith(suffix) and len(s) > len(suffix):
            s = s[: -len(suffix)]
            break
    return s.strip("-")


@dataclass
class ExportConfig:
    """Everything an export needs, from configuration and arguments only — no
    literal for any particular organisation lives in this module."""
    domain: str = ""
    org: str = ""
    brand: str = ""                       # "" = brand_from_org(org)
    visibility: str = "private"
    update: str = UPDATE_REFUSE
    generator_dir: str = ""
    source_mode: str = "existing"         # code_folders.source_root's spelling
    source_dir: str = ""
    optional_services: list[str] = field(default_factory=list)
    extra_repos: list[str] = field(default_factory=list)
    skip_repos: list[str] = field(default_factory=list)
    include_generator: bool = True
    include_build_libraries: bool = True
    rename_map: dict = field(default_factory=dict)
    out_dir: str = ""
    # "" = the runner's own git identity (user.name / user.email): the snapshots
    # are authored by whoever runs the export, and no person is built in here
    author_name: str = ""
    author_email: str = ""
    remote_base: str = "https://github.com/"
    ref: str = ""                         # "" = the checkout's origin/HEAD, origin/main, HEAD
    site_title: str = ""

    @property
    def effective_brand(self) -> str:
        return (self.brand or "").strip().lower() or brand_from_org(self.org)

    @property
    def site_repo(self) -> str:
        return f"{self.domain.strip().lower()}{SITE_REPO_SUFFIX}"

    def problems(self) -> list[str]:
        """Why this config cannot be planned; [] when it can."""
        out: list[str] = []
        d = (self.domain or "").strip().lower()
        if not d or not _DOMAIN_RE.match(d):
            out.append(f"domain must be a lowercase dotted hostname, got {self.domain!r}")
        p = github_org_problem(self.org)
        if not (self.org or "").strip():
            out.append("org is required (the GitHub organisation slug)")
        elif p:
            out.append(p)
        if not _BRAND_RE.match(self.effective_brand):
            out.append(f"brand {self.effective_brand!r} is not a lowercase slug")
        if self.visibility not in VISIBILITY_CHOICES:
            out.append(f"visibility must be one of {', '.join(VISIBILITY_CHOICES)}, "
                       f"got {self.visibility!r}")
        if self.update not in UPDATE_CHOICES:
            out.append(f"update must be one of {', '.join(UPDATE_CHOICES)}, "
                       f"got {self.update!r}")
        if not self.generator_dir or not os.path.isdir(self.generator_dir):
            out.append(f"generator_dir is not a directory: {self.generator_dir!r}")
        for name in list(self.extra_repos) + list(self.skip_repos):
            if not _REPO_RE.match(name or ""):
                out.append(f"not a repository name: {name!r}")
        # an inline rename map is checked here as load_rename_map checks a file, so
        # a bad regex is a problem line, never a traceback at plan time
        for rule in (self.rename_map or {}).get("tokens") or []:
            if not isinstance(rule, dict) or "pattern" not in rule or "replace" not in rule:
                out.append("rename_map: every token rule needs pattern and replace")
                continue
            try:
                re.compile(str(rule["pattern"]))
            except re.error as exc:
                out.append(f"rename_map: bad regex {rule['pattern']!r}: {exc}")
        if not self.remote_base.endswith("/"):
            out.append("remote_base must end with '/'")
        return out

    def to_dict(self) -> dict:
        return asdict(self)


_GENERIC_KEYS = set(ExportConfig.__dataclass_fields__)


def load_rename_map(path: str) -> dict:
    """A rename-map file: ``{"repos": {src: dst}, "tokens": [{"pattern", "replace",
    "note"}], "skip_rewrite": [glob, ...], "exclude": [glob, ...]}``. Any key may be
    absent. ``skip_rewrite`` leaves a file's CONTENTS alone; ``exclude`` drops the
    file from the snapshot altogether (what a banned-marker refusal points at: a
    test script holding an example token is excluded, never published). Both are
    fnmatch globs on the repository-relative path, with ``<repo>:<glob>`` scoping a
    rule to one source repository."""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError("rename map must be a JSON object")
    unknown = sorted(set(data) - {"repos", "tokens", "skip_rewrite", "exclude"})
    if unknown:
        raise ValueError(f"rename map: unknown keys {', '.join(unknown)}")
    out = {"repos": dict(data.get("repos") or {}),
           "tokens": list(data.get("tokens") or []),
           "skip_rewrite": list(data.get("skip_rewrite") or []),
           "exclude": list(data.get("exclude") or [])}
    for src, dst in out["repos"].items():
        if not (_REPO_RE.match(str(src)) and _REPO_RE.match(str(dst))):
            raise ValueError(f"rename map: bad repository rename {src!r} -> {dst!r}")
    for rule in out["tokens"]:
        if not isinstance(rule, dict) or "pattern" not in rule or "replace" not in rule:
            raise ValueError("rename map: every token rule needs pattern and replace")
        re.compile(rule["pattern"])          # fail loudly on a bad regex, at load
    return out


def merge_rename_maps(base: dict, extra: dict) -> dict:
    """``extra`` over ``base``: repo renames override by source name, token rules
    append (the operator's run AFTER the defaults), skip globs union."""
    return {"repos": {**dict(base.get("repos") or {}), **dict(extra.get("repos") or {})},
            "tokens": list(base.get("tokens") or []) + list(extra.get("tokens") or []),
            "skip_rewrite": list(dict.fromkeys(list(base.get("skip_rewrite") or [])
                                               + list(extra.get("skip_rewrite") or []))),
            "exclude": list(dict.fromkeys(list(base.get("exclude") or [])
                                          + list(extra.get("exclude") or [])))}


def _glob_matches(rel: str, repo: str, globs) -> bool:
    """``rel`` (repository-relative) matches a rename-map glob; ``<repo>:<glob>``
    scopes a glob to one source repository."""
    for g in globs or ():
        g = str(g)
        if ":" in g:
            scope, _, pattern = g.partition(":")
            if scope != repo:
                continue
            g = pattern
        if fnmatch.fnmatch(rel, g):
            return True
    return False


@dataclass
class ExportCandidate:
    """A domain that names an org, as found in a saved mesh or a config file. A
    candidate read from a GENERIC export config keeps that whole config
    (``config``), so its ``skip_repos``, ``include_generator``, ``rename_map`` and
    the rest reach the plan a face makes from it — they used to be dropped here,
    which left every GUI/TUI plan from such a file with the defaults."""
    domain: str
    org: str
    optional_services: list[str] = field(default_factory=list)
    source_mode: str = "clone"
    source_dir: str = ""
    generator_dir: str = ""
    where: str = ""                       # "saved mesh 'label'" / "config file x"
    path: str = ""
    config: "ExportConfig | None" = None

    def label(self) -> str:
        return f"{self.domain} -> {self.org}" + (f"  ({self.where})" if self.where else "")

    def to_config(self, **over) -> ExportConfig:
        """An :class:`ExportConfig` for this candidate: the file's own config when
        it came from one, else the defaults; ``over`` wins in both cases."""
        kw = dict(self.config.to_dict()) if self.config is not None else {}
        kw.update(dict(domain=self.domain, org=self.org,
                       optional_services=list(self.optional_services),
                       source_mode=self.source_mode or "clone", source_dir=self.source_dir,
                       generator_dir=self.generator_dir))
        kw.update(over)
        return ExportConfig(**kw)


def _candidates_from_rows(rows, own_name: str, own_org: str, *, own_services=(),
                          source_mode: str, source_dir: str, generator_dir: str,
                          where: str, path: str) -> list[ExportCandidate]:
    """The own domain first (when it names an org), then every row that does. The
    own domain's selected services come from its OWN ROW when the rows carry one (a
    saved-mesh record lists the own domain among ``domains[]``), else from
    ``own_services`` (an ImageConfig keeps them as ``cluster_domain_services``) — they
    used to be dropped here, so the one domain most worth exporting was planned
    without the repositories its services add."""
    out: list[ExportCandidate] = []
    seen: set[str] = set()
    own = (own_name or "").strip()
    if own and (own_org or "").strip():
        services = _slugs(own_services)
        for row in rows or ():
            if str(_get(row, "name", "") or "").strip() == own:
                services = _slugs(_get(row, "optional_services", [])) or services
        out.append(ExportCandidate(own, own_org.strip(), services, source_mode, source_dir,
                                   generator_dir, where, path))
        seen.add(own)
    for row in rows or ():
        name = str(_get(row, "name", "") or "").strip()
        org = str(_get(row, "github_org", "") or "").strip()
        if not name or not org or name in seen:
            continue
        seen.add(name)
        out.append(ExportCandidate(name, org, _slugs(_get(row, "optional_services", [])),
                                   source_mode, source_dir, generator_dir, where, path))
    return out


def _get(row, key, default=None):
    if isinstance(row, dict):
        return row.get(key, default)
    return getattr(row, key, default)


def _slugs(value) -> list[str]:
    """A service list read RAW off a record: a list (or tuple) of strings, nothing
    else. A hand-edited record can hold ``"phpbb"`` where a list belongs, and
    ``list("phpbb")`` is five one-letter services; anything that is not a list is
    "no selection", the way the ImageConfig door treats ``cluster_domain_services``."""
    if not isinstance(value, (list, tuple)):
        return []
    return [s for s in value if isinstance(s, str)]


def candidates_from_file(path: str, generator_dir: str = "") -> list[ExportCandidate]:
    """The domains-with-an-org a JSON file carries. Three shapes are read:

    * a GENERIC export config (``{"domain", "org", ...}``) — one candidate;
    * an ImageConfig (``{"domains": [...], "cluster_domain", ...}``) — every row with
      a ``github_org``, plus the own domain when ``cluster_domain_github_org`` is set;
    * a saved-mesh record (``{"config": {"domains": [...], ...}}``) — the same, read
      RAW off the record (so a key the bootstrap loader does not know still counts).
    """
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a JSON object")
    where = f"config file {os.path.basename(path)}"
    if "org" in data and "domain" in data:
        cfg = load_config(path, generator_dir=generator_dir)
        return [ExportCandidate(cfg.domain, cfg.org, list(cfg.optional_services),
                                cfg.source_mode, cfg.source_dir, cfg.generator_dir,
                                where, path, config=cfg)]
    if isinstance(data.get("config"), dict):          # a saved-mesh record
        c = data["config"]
        own = str(c.get("cluster_domain") or "").strip()
        own_org = ""
        for row in c.get("domains") or ():
            if isinstance(row, dict) and str(row.get("name") or "").strip() == own:
                own_org = str(row.get("github_org") or "")
        return _candidates_from_rows(
            c.get("domains") or (), own, own_org,
            source_mode=str(c.get("source_mode") or "clone"),
            source_dir=str(c.get("source_dir") or ""),
            generator_dir=str(data.get("generator_dir") or generator_dir or ""),
            where=f"saved mesh {data.get('label') or data.get('id') or ''}".strip(),
            path=path)
    if "domains" in data:                             # an ImageConfig
        return _candidates_from_rows(
            data.get("domains") or (), str(data.get("cluster_domain") or ""),
            str(data.get("cluster_domain_github_org") or ""),
            own_services=_slugs(data.get("cluster_domain_services")),
            source_mode="clone", source_dir="", generator_dir=generator_dir,
            where=where, path=path)
    raise ValueError(f"{path}: neither an export config, an image config nor a "
                     "saved-mesh record")


def saved_mesh_candidates(generator_dir: str = "") -> list[ExportCandidate]:
    """Every domain with an org across the saved meshes on THIS machine
    (``core.saved_meshes.scan``), read raw off each record's config dict."""
    from . import saved_meshes                 # lazy: it reads the Studio state dir
    out: list[ExportCandidate] = []
    try:
        recs, _problems = saved_meshes.scan()
    except Exception:                          # noqa: BLE001 — a broken state dir is "none"
        return out
    for rec in recs:
        c = rec.config if isinstance(rec.config, dict) else {}
        own = str(c.get("cluster_domain") or "").strip()
        own_org = ""
        for row in c.get("domains") or ():
            if isinstance(row, dict) and str(row.get("name") or "").strip() == own:
                own_org = str(row.get("github_org") or "")
        out.extend(_candidates_from_rows(
            c.get("domains") or (), own, own_org,
            source_mode=str(c.get("source_mode") or "clone"),
            source_dir=str(c.get("source_dir") or ""),
            generator_dir=rec.generator_dir or generator_dir,
            where=f"saved mesh {rec.label or rec.id}".strip(), path=rec.path()))
    return out


def load_config(path: str, generator_dir: str = "", domain: str = "",
                org: str = "") -> ExportConfig:
    """An :class:`ExportConfig` from a JSON file (any of the three shapes
    :func:`candidates_from_file` reads). ``domain``/``org`` pick a row from an image
    config or a record with several, and override a generic config's values."""
    with open(path, encoding="utf-8") as fh:
        data = json.load(fh)
    if not isinstance(data, dict):
        raise ValueError(f"{path}: not a JSON object")
    if "org" in data and "domain" in data:
        unknown = sorted(set(data) - _GENERIC_KEYS)
        if unknown:
            raise ValueError(f"{path}: unknown keys {', '.join(unknown)}")
        kw = {k: v for k, v in data.items() if k in _GENERIC_KEYS}
        if isinstance(kw.get("rename_map"), dict):
            kw["rename_map"] = merge_rename_maps({}, kw["rename_map"])
        cfg = ExportConfig(**kw)
        if domain:
            cfg.domain = domain
        if org:
            cfg.org = org
        if not cfg.generator_dir:
            cfg.generator_dir = generator_dir
        return cfg
    cands = candidates_from_file(path, generator_dir)
    if domain:
        cands = [c for c in cands if c.domain == domain.strip().lower()]
    if not cands:
        raise ValueError(f"{path}: no domain with a GitHub org"
                         + (f" named {domain!r}" if domain else ""))
    if len(cands) > 1:
        raise ValueError(f"{path}: several domains carry an org "
                         f"({', '.join(c.domain for c in cands)}) — pass --domain")
    cfg = cands[0].to_config()
    if org:
        cfg.org = org
    if not cfg.generator_dir:
        cfg.generator_dir = generator_dir
    return cfg


# ── the rename map ─────────────────────────────────────────────────────────────────
def repo_target_name(name: str, cfg: ExportConfig) -> str:
    """``hugmesh-<x> -> <brand>-<x>``, unless the map names the target itself."""
    explicit = dict(cfg.rename_map.get("repos") or {}).get(name)
    if explicit:
        return str(explicit)
    if name.startswith("hugmesh-"):
        return f"{cfg.effective_brand}-{name[len('hugmesh-'):]}"
    return name


def rename_rules(cfg: ExportConfig, repo_names) -> list[tuple[re.Pattern, str, str]]:
    """``[(regex, replacement, note), ...]`` applied IN ORDER to every text file:
    the org path segment first (so a later token rule never sees a half-rewritten
    path), then every exported repository name longest-first (so ``hugmesh-user-ui``
    is not touched by ``hugmesh-user``), then the operator's extra rules."""
    org = cfg.org.strip()
    rules: list[tuple[re.Pattern, str, str]] = [
        (re.compile(r"ghcr\.io/hugmesh/"), f"ghcr.io/{org}/", "image path"),
        (re.compile(r"github\.com/hugmesh/"), f"github.com/{org}/", "clone URL / link"),
        (re.compile(r"github\.com:hugmesh/"), f"github.com:{org}/", "ssh clone URL"),
        (re.compile(r"maven\.pkg\.github\.com/hugmesh/"), f"maven.pkg.github.com/{org}/",
         "package registry"),
        (re.compile(r"(?<![A-Za-z0-9_@.-])hugmesh/(?=hugmesh-[A-Za-z0-9])"), f"{org}/",
         "owner/repo reference"),
    ]
    for name in sorted(set(repo_names), key=len, reverse=True):
        target = repo_target_name(name, cfg)
        if target != name:
            rules.append((re.compile(_TOKEN_BEFORE + re.escape(name) + _TOKEN_AFTER),
                          target, f"repository name {name} -> {target}"))
    for rule in cfg.rename_map.get("tokens") or []:
        rules.append((re.compile(rule["pattern"]), str(rule["replace"]),
                      str(rule.get("note") or "extra rule")))
    return rules


def rewrite_text(text: str, rules) -> tuple[str, int]:
    """Apply the rules; ``(new text, number of replacements)``."""
    total = 0
    for rx, rep, _note in rules:
        text, n = rx.subn(rep, text)
        total += n
    return text, total


# ── the repository set ─────────────────────────────────────────────────────────────
def domain_repo_names(cfg: ExportConfig) -> tuple[list[str], list[str]]:
    """``(repository names, notes)`` for the config's domain: the code-folder map's
    ``KIND_REPO`` rows (platform apps + the domain's selected services), the Java
    build chain, the generator, plus/minus the config's lists. Stock images and
    in-repo paths (the Tor folder) are notes, never repositories."""
    from . import code_folders as cf           # lazy: it parses compose files
    row = Domain(name=cfg.domain.strip().lower(),
                 optional_services=list(cfg.optional_services))
    cmap = cf.code_folder_map(cfg.generator_dir, cfg.source_mode, cfg.source_dir, [row])
    names: list[str] = []
    notes: list[str] = []
    for dom in cmap.domains:
        for app in dom.apps:
            if app.kind == cf.KIND_REPO:
                if app.name not in names:
                    names.append(app.name)
            else:
                notes.append(f"{app.name}: a folder inside the generator, not a "
                             "repository — exported with the generator")
        notes.extend(dom.notes)
    if cfg.include_build_libraries:
        for name in BUILD_LIBRARY_REPOS:
            if name not in names:
                names.append(name)
    if cfg.include_generator and GENERATOR_REPO not in names:
        names.append(GENERATOR_REPO)
    for name in cfg.extra_repos:
        if name and name not in names:
            names.append(name)
    skip = {s for s in cfg.skip_repos if s}
    names = [n for n in names if n not in skip]
    return names, notes


def _source_path(name: str, cfg: ExportConfig) -> str:
    """Where ``name``'s checkout is read from: the generator checkout for the
    generator itself, else ``<source root>/<name>``."""
    from . import code_folders as cf
    if name == GENERATOR_REPO:
        return os.path.abspath(cfg.generator_dir)
    root = cf.source_root(cfg.generator_dir, cfg.source_mode, cfg.source_dir)
    return os.path.join(root, name) if root else ""


# ── the plan ───────────────────────────────────────────────────────────────────────
@dataclass
class RepoPlan:
    source: str                       # hugmesh-<name> (or the site's "" )
    target: str                       # <brand>-<name> / <domain>.github.io
    org: str
    visibility: str
    action: str                       # see ACTIONS
    kind: str = "other"               # java | java+settings | angular | site | other
    source_path: str = ""
    ref: str = ""
    source_commit: str = ""
    workdir: str = ""
    files: int = 0
    excluded: list[str] = field(default_factory=list)
    rewrites: dict = field(default_factory=dict)      # path -> replacements
    banned: list[str] = field(default_factory=list)   # "path: marker"
    notes: list[str] = field(default_factory=list)

    @property
    def target_full(self) -> str:
        return f"{self.org}/{self.target}"

    @property
    def blocked(self) -> bool:
        return self.action.startswith("refused") or self.action.startswith("missing")


ACTIONS = ("create", "update (empty repository)", "exists (compared at apply)",
           "update via branch", "unchanged", "refused: banned marker",
           "refused: existing non-empty repository", "missing source")


@dataclass
class Plan:
    config: ExportConfig
    repos: list[RepoPlan]
    site: RepoPlan
    rename_rules: list[str]
    not_renamed: list[str]
    notes: list[str]
    out_dir: str
    stamp: str = ""

    @property
    def blocked(self) -> list[RepoPlan]:
        return [r for r in self.repos if r.blocked]

    def to_dict(self) -> dict:
        return {"config": self.config.to_dict(), "stamp": self.stamp,
                "out_dir": self.out_dir,
                "repos": [asdict(r) for r in self.repos], "site": asdict(self.site),
                "rename_rules": list(self.rename_rules),
                "not_renamed": list(self.not_renamed), "notes": list(self.notes)}


def _is_text(path: str) -> bool:
    try:
        with open(path, "rb") as fh:
            head = fh.read(8192)
    except OSError:
        return False
    return b"\0" not in head


def _excluded_reason(rel: str) -> str:
    parts = rel.split("/")
    for p in parts[:-1]:
        if p in EXCLUDED_DIRS:
            return f"directory {p}/"
    base = parts[-1]
    if base in EXCLUDED_DIRS:
        return f"directory {base}/"
    if base in EXCLUDED_NAMES:
        return "excluded file name"
    for g in SECRET_GLOBS:
        if fnmatch.fnmatch(base, g):
            return f"secret-shaped name ({g})"
    return ""


def _resolve_ref(runner: Runner, path: str, wanted: str) -> tuple[str, str]:
    """``(ref, commit)`` of the default branch: the checkout's ``origin/HEAD``, else
    ``origin/main``, else ``HEAD`` — or ``wanted`` when the config names one."""
    cands = [wanted] if wanted else []
    r = runner.run(["git", "symbolic-ref", "-q", "refs/remotes/origin/HEAD"], cwd=path)
    if r.returncode == 0 and r.text.strip():
        cands.append(r.text.strip())
    cands += ["refs/remotes/origin/main", "HEAD"]
    for ref in cands:
        r = runner.run(["git", "rev-parse", "-q", "--verify", f"{ref}^{{commit}}"],
                       cwd=path)
        if r.returncode == 0 and r.text.strip():
            return ref, r.text.strip()
    return "", ""


def _snapshot(runner: Runner, path: str, ref: str, workdir: str) -> list[str]:
    """``git archive`` the ref into ``workdir`` (emptied first); returns the files."""
    if os.path.isdir(workdir):
        shutil.rmtree(workdir)
    os.makedirs(workdir)
    r = runner.run(["git", "archive", "--format=tar", ref], cwd=path, timeout=1800)
    if r.returncode != 0:
        raise RuntimeError(f"git archive {ref} failed in {path}: {r.err.strip()}")
    files: list[str] = []
    with tarfile.open(fileobj=io.BytesIO(r.stdout), mode="r:") as tf:
        for member in tf.getmembers():
            if not (member.isfile() or member.isdir() or member.issym()):
                continue
            # never let an archive write outside its own directory
            dest = os.path.normpath(os.path.join(workdir, member.name))
            if not dest.startswith(os.path.abspath(workdir) + os.sep) \
                    and dest != os.path.abspath(workdir):
                continue
            try:
                try:
                    tf.extract(member, workdir, filter="data")
                except TypeError:
                    # a Python older than 3.12 / 3.11.4 / 3.10.12 has no extraction
                    # filter; the path check above is what keeps the write inside
                    tf.extract(member, workdir)
            except (tarfile.FilterError, OSError):
                # a link that points outside the tree, or a name the filter
                # refuses: left out of the snapshot rather than written anywhere
                continue
            if member.isfile():
                files.append(member.name)
    return sorted(files)


def _prepare_repo(runner: Runner, name: str, cfg: ExportConfig, rules, out_dir: str,
                  skip_globs) -> RepoPlan:
    target = repo_target_name(name, cfg)
    rp = RepoPlan(source=name, target=target, org=cfg.org.strip(),
                  visibility=cfg.visibility, action="")
    rp.source_path = _source_path(name, cfg)
    git_marker = os.path.join(rp.source_path, ".git") if rp.source_path else ""
    # a worktree's .git is a FILE pointing at the main repository; both count
    if not git_marker or not (os.path.isdir(git_marker) or os.path.isfile(git_marker)):
        rp.action = "missing source"
        rp.notes.append(f"no git checkout at {rp.source_path or '<no source root>'}")
        return rp
    rp.ref, rp.source_commit = _resolve_ref(runner, rp.source_path, cfg.ref)
    if not rp.ref:
        rp.action = "missing source"
        rp.notes.append(f"{rp.source_path}: no origin/HEAD, origin/main or HEAD to export")
        return rp
    rp.workdir = os.path.join(out_dir, "work", target)
    files = _snapshot(runner, rp.source_path, rp.ref, rp.workdir)
    exclude_globs = list(cfg.rename_map.get("exclude") or [])
    kept: list[str] = []
    for rel in files:
        why = _excluded_reason(rel)
        if not why and _glob_matches(rel, name, exclude_globs):
            why = "excluded by the rename map"
        if why:
            rp.excluded.append(f"{rel}: {why}")
            try:
                os.unlink(os.path.join(rp.workdir, rel))
            except OSError:
                pass
            continue
        kept.append(rel)
    # drop the directories the exclusions emptied (and the excluded dirs themselves)
    for dirpath, dirnames, _files in os.walk(rp.workdir, topdown=True):
        for d in list(dirnames):
            if d in EXCLUDED_DIRS:
                shutil.rmtree(os.path.join(dirpath, d), ignore_errors=True)
                dirnames.remove(d)
    for dirpath, dirnames, filenames in os.walk(rp.workdir, topdown=False):
        if not dirnames and not filenames and dirpath != rp.workdir:
            try:
                os.rmdir(dirpath)
            except OSError:
                pass
    rp.files = len(kept)
    rp.kind = _kind(rp.workdir)
    for rel in kept:
        full = os.path.join(rp.workdir, rel)
        if not _is_text(full):
            continue
        try:
            with open(full, encoding="utf-8") as fh:
                text = fh.read()
        except (OSError, UnicodeDecodeError):
            continue
        for label, rx in BANNED_MARKERS:
            if rx.search(text):
                rp.banned.append(f"{rel}: {label}")
        if _glob_matches(rel, name, skip_globs):
            continue
        new, n = rewrite_text(text, rules)
        if n:
            rp.rewrites[rel] = n
            with open(full, "w", encoding="utf-8") as fh:
                fh.write(new)
    if rp.banned:
        rp.action = "refused: banned marker"
        rp.notes.append("remove the marker from the source repository, or drop the "
                        "file from the snapshot with the rename map's exclude list "
                        f"(\"{name}:<path>\") — the export never publishes it")
    return rp


def _kind(workdir: str) -> str:
    if os.path.isfile(os.path.join(workdir, "pom.xml")):
        return "java+settings" if os.path.isfile(os.path.join(workdir, "settings.xml")) \
            else "java"
    if os.path.isfile(os.path.join(workdir, "angular.json")):
        return "angular"
    return "other"


def _probe(runner: Runner, rp: RepoPlan, cfg: ExportConfig) -> None:
    """Ask ``gh`` whether the target exists and is empty; decide the action word.
    A probe that fails (no gh, no login, no network) leaves the decision to apply,
    and says so — never guesses 'create'."""
    r = runner.run(["gh", "repo", "view", rp.target_full, "--json",
                    "name,isEmpty,visibility"], timeout=60)
    if r.returncode != 0:
        err = r.err.strip().lower()
        if "could not resolve" in err or "not found" in err or "404" in err:
            rp.action = "create"
            return
        rp.action = "exists (compared at apply)"
        rp.notes.append(f"gh repo view did not answer ({r.err.strip()[:120] or 'no gh'}): "
                        "apply decides create/update from the repository itself")
        return
    try:
        info = json.loads(r.text or "{}")
    except ValueError:
        info = {}
    if info.get("isEmpty"):
        rp.action = "update (empty repository)"
    elif cfg.update == UPDATE_BRANCH:
        rp.action = "update via branch"
    else:
        rp.action = "exists (compared at apply)"
    vis = str(info.get("visibility") or "").lower()
    if vis and vis != cfg.visibility:
        rp.notes.append(f"exists as {vis}; visibility is never changed by the export")


def plan(cfg: ExportConfig, runner: Runner | None = None, *, probe: bool = True,
         stamp: str = "") -> Plan:
    """The read-only half: the repository set, one snapshot per repository under
    ``<out>/work/``, the rewrites and exclusions per file, the banned-marker scan,
    the generated site repository, and the plan files. Nothing is created or
    pushed; with ``probe`` the target repositories are LOOKED AT through ``gh``."""
    runner = runner or SubprocessRunner()
    problems = cfg.problems()
    if problems:
        raise ValueError("; ".join(problems))
    cfg.domain = cfg.domain.strip().lower()
    cfg.org = cfg.org.strip()
    stamp = stamp or _dt.datetime.now(_dt.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    out_dir = os.path.abspath(cfg.out_dir or os.path.join(
        cfg.generator_dir, "out", "org-export", cfg.domain))
    os.makedirs(out_dir, exist_ok=True)
    names, notes = domain_repo_names(cfg)
    rules = rename_rules(cfg, names)
    skip_globs = list(cfg.rename_map.get("skip_rewrite") or [])
    repos: list[RepoPlan] = []
    for name in names:
        rp = _prepare_repo(runner, name, cfg, rules, out_dir, skip_globs)
        if not rp.action:
            if probe:
                _probe(runner, rp, cfg)
            else:
                rp.action = "exists (compared at apply)"
        repos.append(rp)
    site = _prepare_site(cfg, repos, out_dir, stamp)
    if probe:
        _probe(runner, site, cfg)
    else:
        site.action = "exists (compared at apply)"
    p = Plan(config=cfg, repos=repos, site=site,
             rename_rules=[f"{rx.pattern!s} -> {rep}  ({note})" for rx, rep, note in rules],
             not_renamed=list(NOT_RENAMED), notes=notes, out_dir=out_dir, stamp=stamp)
    with open(os.path.join(out_dir, "org-export-plan.json"), "w", encoding="utf-8") as fh:
        json.dump(p.to_dict(), fh, indent=2, sort_keys=True)
    with open(os.path.join(out_dir, "org-export-plan.txt"), "w", encoding="utf-8") as fh:
        fh.write("\n".join(plan_lines(p)) + "\n")
    return p


# ── the site repository ────────────────────────────────────────────────────────────
def _render(template: str, values: dict[str, str]) -> str:
    for k, v in values.items():
        template = template.replace("{{" + k + "}}", v)
    return template


def _build_word(kind: str) -> str:
    return {"java": "java", "java+settings": "java", "angular": "angular"}.get(kind, "none")


def _prepare_site(cfg: ExportConfig, repos: list[RepoPlan], out_dir: str,
                  stamp: str) -> RepoPlan:
    site = RepoPlan(source="", target=cfg.site_repo, org=cfg.org, visibility=cfg.visibility,
                    action="", kind="site")
    site.workdir = os.path.join(out_dir, "work", cfg.site_repo)
    if os.path.isdir(site.workdir):
        shutil.rmtree(site.workdir)
    os.makedirs(os.path.join(site.workdir, ".github", "workflows"))
    exported = [r for r in repos if not r.blocked]
    rows = [{"name": r.target, "source": r.source, "build": _build_word(r.kind),
             "settings": r.kind == "java+settings", "visibility": r.visibility,
             "url": f"https://github.com/{r.org}/{r.target}"} for r in exported]
    # NO run stamp anywhere in the site's content: the same inputs must give the
    # same tree, so a re-run reports the site `unchanged` like every other repository
    repos_json = {"domain": cfg.domain, "org": cfg.org, "brand": cfg.effective_brand,
                  "site": cfg.site_repo, "repos": rows}
    # TITLE is free text and renders into index.html only, so it is HTML-escaped
    # here; the other values are regex-validated slugs and hostnames
    values = {"DOMAIN": cfg.domain, "ORG": cfg.org, "BRAND": cfg.effective_brand,
              "SITE_REPO": cfg.site_repo,
              "TITLE": html.escape(cfg.site_title or cfg.domain, quote=True),
              "REPO_COUNT": str(len(rows))}
    from .org_export_site import TEMPLATES     # lazy: ~10 KB of text, only needed here
    written: list[str] = []
    for dst, template in TEMPLATES:
        text = _render(template, values)
        with open(os.path.join(site.workdir, dst), "w", encoding="utf-8") as fh:
            fh.write(text)
        written.append(dst)
    with open(os.path.join(site.workdir, "repos.json"), "w", encoding="utf-8") as fh:
        json.dump(repos_json, fh, indent=2)
    written.append("repos.json")
    site.files = len(written)
    site.notes.append(f"generated: {', '.join(written)}")
    if len(exported) != len(repos):
        site.notes.append(f"{len(repos) - len(exported)} repository(ies) left out of "
                          "repos.json because their export is blocked")
    return site


# ── apply ──────────────────────────────────────────────────────────────────────────
@dataclass
class RepoResult:
    target: str
    url: str
    action: str
    commit: str = ""
    tree: str = ""
    branch: str = ""
    skipped: str = ""

    @property
    def ok(self) -> bool:
        return not self.skipped


@dataclass
class Result:
    stamp: str
    repos: list[RepoResult]
    result_path: str = ""
    calls: list[list[str]] = field(default_factory=list)

    @property
    def failures(self) -> list[RepoResult]:
        return [r for r in self.repos if r.skipped]

    def to_dict(self) -> dict:
        return {"stamp": self.stamp, "repos": [asdict(r) for r in self.repos]}


_FORBIDDEN_FLAGS = ("--force", "-f", "--force-with-lease", "--mirror", "--delete",
                    "--prune")


def _git_env(cfg: ExportConfig, stamp: str) -> dict[str, str]:
    date = stamp if stamp.endswith("Z") and "T" in stamp else ""
    # the person's gh login is the credential — never a token in the env
    env = {"GIT_TERMINAL_PROMPT": "0"}
    # an author only when the config names one; otherwise git's own identity of
    # the person running the export (user.name / user.email) authors the snapshot
    if (cfg.author_name or "").strip() and (cfg.author_email or "").strip():
        env.update({"GIT_AUTHOR_NAME": cfg.author_name.strip(),
                    "GIT_AUTHOR_EMAIL": cfg.author_email.strip(),
                    "GIT_COMMITTER_NAME": cfg.author_name.strip(),
                    "GIT_COMMITTER_EMAIL": cfg.author_email.strip()})
    if date:
        iso = f"{date[0:4]}-{date[4:6]}-{date[6:8]}T{date[9:11]}:{date[11:13]}:{date[13:15]}+0000"
        env["GIT_AUTHOR_DATE"] = iso
        env["GIT_COMMITTER_DATE"] = iso
    return env


def _run_checked(runner: Runner, calls: list[list[str]], argv: list[str], **kw) -> RunResult:
    for flag in argv:
        if flag in _FORBIDDEN_FLAGS or (flag.startswith("+") and argv[0] == "git"):
            raise RuntimeError(f"refusing to run {shlex.join(argv)}: {flag} is never used")
    calls.append(list(argv))
    return runner.run(argv, **kw)


def _commit_snapshot(runner, calls, rp: RepoPlan, cfg: ExportConfig, stamp: str,
                     message: str) -> tuple[str, str]:
    """One fresh commit in the work tree; ``(commit, tree)``."""
    env = _git_env(cfg, stamp)
    wd = rp.workdir
    if os.path.isdir(os.path.join(wd, ".git")):
        shutil.rmtree(os.path.join(wd, ".git"))
    for argv in (["git", "init", "-q", "-b", "main"],
                 ["git", "-c", "core.autocrlf=false", "add", "-A"],
                 ["git", "-c", "commit.gpgsign=false", "commit", "-q", "--allow-empty",
                  "-m", message]):
        r = _run_checked(runner, calls, argv, cwd=wd, env=env)
        if r.returncode != 0:
            raise RuntimeError(f"{shlex.join(argv)} failed in {wd}: {r.err.strip()}")
    commit = _run_checked(runner, calls, ["git", "rev-parse", "HEAD"], cwd=wd).text.strip()
    tree = _run_checked(runner, calls, ["git", "rev-parse", "HEAD^{tree}"],
                        cwd=wd).text.strip()
    return commit, tree


def _push_one(runner, calls, rp: RepoPlan, cfg: ExportConfig, stamp: str,
              create_missing: bool) -> RepoResult:
    url = f"{cfg.remote_base}{rp.target_full}.git"
    res = RepoResult(target=rp.target_full, url=url, action=rp.action)
    if rp.blocked:
        res.skipped = rp.action + ("; " + "; ".join(rp.notes) if rp.notes else "")
        return res
    message = (f"Export {rp.source or rp.target} for {cfg.domain}\n\n"
               f"Single-commit snapshot of {rp.source or 'the generated site'}"
               + (f" at {rp.source_commit[:12]} ({rp.ref})" if rp.source_commit else "")
               + f", exported to {rp.target_full} on {stamp}.")
    res.commit, res.tree = _commit_snapshot(runner, calls, rp, cfg, stamp, message)
    # does the target exist? (gh repo view; a missing one is created, private by default)
    view = _run_checked(runner, calls, ["gh", "repo", "view", rp.target_full, "--json",
                                        "name,isEmpty"], timeout=60)
    if view.returncode != 0:
        if not create_missing:
            res.skipped = f"gh repo view failed: {view.err.strip()[:160]}"
            return res
        r = _run_checked(runner, calls, ["gh", "repo", "create", rp.target_full,
                                         f"--{cfg.visibility}", "--description",
                                         f"{rp.source or rp.target} exported for {cfg.domain}"],
                         timeout=120)
        if r.returncode != 0:
            res.skipped = f"gh repo create failed: {r.err.strip()[:160]}"
            return res
        res.action = "create"
    # EVERY branch, not just main: a repository whose content lives on master (or any
    # other branch) has no main and used to pass as empty — apply then pushed a new
    # main into it and reported 'update (empty repository)' on a repository gh had
    # just called non-empty. gh's own isEmpty answer counts as well.
    heads = _run_checked(runner, calls, ["git", "ls-remote", "--heads", url],
                         cwd=rp.workdir, env=_git_env(cfg, stamp), timeout=120)
    if heads.returncode != 0:
        res.skipped = f"git ls-remote failed: {heads.err.strip()[:160]}"
        return res
    branches = [ln.split("\t", 1)[1].removeprefix("refs/heads/")
                for ln in heads.text.splitlines() if "\t" in ln]
    try:
        info = json.loads(view.text or "{}") if view.returncode == 0 else {}
    except ValueError:
        info = {}
    if "main" in branches:
        # main exists: equal tree -> unchanged; else branch mode or refuse
        fetch = _run_checked(runner, calls, ["git", "fetch", "-q", url, "refs/heads/main"],
                             cwd=rp.workdir, env=_git_env(cfg, stamp), timeout=600)
        remote_tree = ""
        if fetch.returncode == 0:
            remote_tree = _run_checked(runner, calls, ["git", "rev-parse", "FETCH_HEAD^{tree}"],
                                       cwd=rp.workdir).text.strip()
        if remote_tree and remote_tree == res.tree:
            res.action = "unchanged"
            res.branch = "main"
            return res
        if cfg.update != UPDATE_BRANCH:
            res.action = "refused: existing non-empty repository"
            res.skipped = ("main already holds a different tree; choose 'update via "
                           "branch' to push export/<stamp> instead")
            return res
        res.branch = f"export/{stamp}"
        res.action = "update via branch"
    elif branches or info.get("isEmpty") is False:
        # non-empty, but nothing on main: never a push into it
        holds = ", ".join(branches) if branches else "content gh reports as non-empty"
        if cfg.update != UPDATE_BRANCH:
            res.action = "refused: existing non-empty repository"
            res.skipped = (f"the repository has no main but holds {holds}; choose "
                           "'update via branch' to push export/<stamp> instead")
            return res
        res.branch = f"export/{stamp}"
        res.action = "update via branch"
    else:
        res.branch = "main"
        if res.action not in ("create",):
            res.action = "update (empty repository)"
    push = _run_checked(runner, calls, ["git", "push", "-q", url,
                                        f"HEAD:refs/heads/{res.branch}"],
                        cwd=rp.workdir, env=_git_env(cfg, stamp), timeout=1800)
    if push.returncode != 0:
        res.skipped = f"git push failed: {push.err.strip()[:200]}"
    return res


def apply(p: Plan, runner: Runner | None = None, *, progress=None) -> Result:
    """The write half: for every repository of the plan that is not blocked, create
    the target when missing (``gh repo create``, the plan's visibility), commit the
    snapshot and push it to ``main`` with a plain ``git push`` — never force, never
    delete. The site repository goes last. ``progress(RepoResult)`` is called after
    each repository. The result file lists every repository, its URL, commit and
    what was skipped, so a run can be audited and re-run (a re-run reports
    ``unchanged`` for what already matches)."""
    runner = runner or SubprocessRunner()
    cfg = p.config
    stamp = p.stamp
    calls: list[list[str]] = []
    results: list[RepoResult] = []
    # No author in the config means git's own identity of the person running this.
    # Asked ONCE, up front: without it every commit would fail AFTER `gh repo create`
    # had already made the empty repositories.
    if not ((cfg.author_name or "").strip() and (cfg.author_email or "").strip()):
        ident = _run_checked(runner, calls, ["git", "var", "GIT_AUTHOR_IDENT"],
                             cwd=p.out_dir, env=_git_env(cfg, stamp), timeout=60)
        if ident.returncode != 0:
            why = ("no git identity for the snapshot commits: set git config user.name "
                   "and user.email, or author_name / author_email in the export config "
                   f"({ident.err.strip().splitlines()[0] if ident.err.strip() else 'git var GIT_AUTHOR_IDENT failed'})")
            results = [RepoResult(target=rp.target_full,
                                  url=f"{cfg.remote_base}{rp.target_full}.git",
                                  action=rp.action, skipped=why) for rp in [*p.repos, p.site]]
            result = Result(stamp=stamp, repos=results, calls=calls)
            path = os.path.join(p.out_dir, f"org-export-result-{stamp}.json")
            with open(path, "w", encoding="utf-8") as fh:
                json.dump(result.to_dict(), fh, indent=2)
            result.result_path = path
            return result
    for rp in [*p.repos, p.site]:
        if not rp.workdir and not rp.blocked:
            rp.action = "missing source"
        try:
            res = _push_one(runner, calls, rp, cfg, stamp, create_missing=True)
        except RuntimeError as exc:
            res = RepoResult(target=rp.target_full,
                             url=f"{cfg.remote_base}{rp.target_full}.git",
                             action=rp.action, skipped=str(exc))
        results.append(res)
        if progress:
            progress(res)
    result = Result(stamp=stamp, repos=results, calls=calls)
    path = os.path.join(p.out_dir, f"org-export-result-{stamp}.json")
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(result.to_dict(), fh, indent=2)
    result.result_path = path
    return result


# ── the text both faces show ───────────────────────────────────────────────────────
def plan_lines(p: Plan) -> list[str]:
    """The plan as text — the ONE rendering the GUI step, the TUI step and the CLI
    print (parity-pinned by test)."""
    cfg = p.config
    author = (f"{cfg.author_name.strip()} <{cfg.author_email.strip()}> (from the config)"
              if (cfg.author_name or "").strip() and (cfg.author_email or "").strip()
              else "your own git identity (git config user.name / user.email)")
    out = [f"Export for {cfg.domain} -> GitHub org {cfg.org} (brand {cfg.effective_brand}, "
           f"{cfg.visibility}, existing repositories: "
           f"{'update via export/<stamp> branch' if cfg.update == UPDATE_BRANCH else 'refused unless unchanged'})",
           f"Plan files: {p.out_dir}",
           f"Snapshot commits authored as: {author}", ""]
    rows = [("SOURCE", "TARGET", "ACTION", "KIND", "FILES", "REWRITTEN", "EXCLUDED")]
    for r in [*p.repos, p.site]:
        rows.append((r.source or "(generated)", r.target_full, r.action, r.kind,
                     str(r.files), str(len(r.rewrites)), str(len(r.excluded))))
    widths = [max(len(row[i]) for row in rows) for i in range(len(rows[0]))]
    for row in rows:
        out.append("  ".join(c.ljust(w) for c, w in zip(row, widths)).rstrip())
    blocked = p.blocked
    if blocked:
        out += ["", "BLOCKED (nothing is exported for these until fixed):"]
        for r in blocked:
            out.append(f"  {r.source}: {r.action}")
            for b in r.banned:
                out.append(f"    {b}")
            for n in r.notes:
                out.append(f"    {n}")
    # what is snapshotted: the ref and commit per repository (the default branch of
    # each checkout, never the branch that happens to be checked out)
    snaps = [r for r in p.repos if r.source_commit]
    if snaps:
        out += ["", "Snapshots (the default branch of each checkout, at this commit):"]
        out += [f"  {r.source}: {r.ref} @ {r.source_commit[:12]}" for r in snaps]
    out += ["", "Renamed (exact tokens, idempotent):"]
    out += [f"  {rule}" for rule in p.rename_rules]
    out += ["", "Deliberately NOT renamed (extend the rename map to change this):"]
    out += [f"  {n}" for n in p.not_renamed]
    if p.notes:
        out += ["", "Notes:"] + [f"  {n}" for n in p.notes]
    out += ["", "Nothing has been created or pushed. Apply needs the typed org name "
            "(GUI/TUI) or --apply (CLI)."]
    return out


def result_lines(res: Result) -> list[str]:
    out = [f"Export run {res.stamp}: {len(res.repos) - len(res.failures)} done, "
           f"{len(res.failures)} skipped"]
    for r in res.repos:
        if r.skipped:
            out.append(f"  SKIPPED {r.target}: {r.skipped}")
        else:
            out.append(f"  {r.action:<28} {r.target}  {r.branch}  {r.commit[:12]}  {r.url}")
    if res.result_path:
        out.append(f"Result file: {res.result_path}")
    return out


def cli_command(cfg: ExportConfig, verb: str = "PLAN", config_path: str = "",
                rename_map_path: str = "") -> str:
    """The exact terminal command for this export (what the GUI and TUI hand over)."""
    argv = ["python3", "-m", "hugmesh_studio", "--org-export", verb]
    if config_path:
        # --domain picks the row when the file carries several; harmless otherwise
        argv += ["--config", config_path, "--domain", cfg.domain]
    else:
        argv += ["--domain", cfg.domain, "--org", cfg.org]
        if cfg.source_dir:
            argv += ["--source-dir", cfg.source_dir, "--source-mode", cfg.source_mode]
    if rename_map_path:
        argv += ["--rename-map", rename_map_path]
    if cfg.out_dir:
        argv += ["--out", cfg.out_dir]
    if cfg.visibility != "private":
        argv += ["--visibility", cfg.visibility]
    if cfg.update == UPDATE_BRANCH:
        argv += ["--update-via-branch"]
    if verb == "APPLY":
        argv += ["--apply"]
    return " ".join(shlex.quote(a) for a in argv)


# ── the CLI ────────────────────────────────────────────────────────────────────────
def add_cli_arguments(ap) -> None:
    """The ``--org-export`` family on the Studio's argparse parser (Qt-free)."""
    ap.add_argument("--org-export", choices=["PLAN", "APPLY"], default=None,
                    help="headless: export a domain's repositories to a GitHub org. "
                         "PLAN snapshots and writes the plan under --out (touches no "
                         "repository); APPLY creates/pushes and REFUSES without --apply.")
    ap.add_argument("--domain", default="",
                    help="with --org-export: the domain (or which row of --config)")
    ap.add_argument("--org", default="",
                    help="with --org-export: the GitHub organisation slug")
    ap.add_argument("--rename-map", metavar="FILE", default="",
                    help="with --org-export: extra rename rules merged over the defaults")
    ap.add_argument("--out", metavar="DIR", default="",
                    help="with --org-export: where the plan, work trees and result go "
                         "(default <generator>/out/org-export/<domain>)")
    ap.add_argument("--apply", action="store_true",
                    help="with --org-export APPLY: the required explicit confirmation")
    ap.add_argument("--visibility", choices=list(VISIBILITY_CHOICES), default=None,
                    help="with --org-export: visibility of repositories the export "
                         "CREATES (default private)")
    ap.add_argument("--update-via-branch", action="store_true",
                    help="with --org-export: push an existing non-empty repository to "
                         "export/<stamp> instead of refusing it")
    ap.add_argument("--source-dir", default="",
                    help="with --org-export: the folder holding the hugmesh-* checkouts")
    ap.add_argument("--source-mode", choices=["existing", "clone"], default=None,
                    help="with --org-export: existing (--source-dir) or clone (.stack-src)")
    ap.add_argument("--brand", default="",
                    help="with --org-export: the brand prefix (default: from the org)")
    ap.add_argument("--remote-base", default="",
                    help="with --org-export: the git remote prefix (default "
                         "https://github.com/; a file:// path for an offline rehearsal)")
    ap.add_argument("--no-probe", action="store_true",
                    help="with --org-export PLAN: do not ask gh whether targets exist")


def run_cli(args, generator_dir: str, out=print, err=None) -> int:
    """``--org-export PLAN|APPLY``. Exit 0 on a clean plan / apply, 1 when the plan
    is blocked or a repository was skipped, 2 on bad input."""
    import sys
    err = err or (lambda m: print(m, file=sys.stderr))
    try:
        if args.config:
            cfg = load_config(args.config, generator_dir=generator_dir,
                              domain=args.domain, org=args.org)
        else:
            if not (args.domain and args.org):
                err("error: --org-export needs --config FILE, or --domain and --org")
                return 2
            cfg = ExportConfig(domain=args.domain, org=args.org,
                               generator_dir=generator_dir)
        if args.rename_map:
            cfg.rename_map = merge_rename_maps(cfg.rename_map or {},
                                               load_rename_map(args.rename_map))
        if args.out:
            cfg.out_dir = args.out
        if args.visibility:
            cfg.visibility = args.visibility
        if args.update_via_branch:
            cfg.update = UPDATE_BRANCH
        if args.source_dir:
            cfg.source_dir = args.source_dir
            cfg.source_mode = args.source_mode or "existing"
        elif args.source_mode:
            cfg.source_mode = args.source_mode
        if args.brand:
            cfg.brand = args.brand
        if args.remote_base:
            cfg.remote_base = args.remote_base
        if not cfg.generator_dir:
            cfg.generator_dir = generator_dir
        problems = cfg.problems()
        if problems:
            for pr in problems:
                err(f"error: {pr}")
            return 2
        runner = SubprocessRunner()
        p = plan(cfg, runner, probe=not args.no_probe)
    except (ValueError, OSError, RuntimeError) as exc:
        err(f"error: {exc}")
        return 2
    for line in plan_lines(p):
        out(line)
    if args.org_export == "PLAN":
        return 1 if p.blocked else 0
    if not args.apply:
        err("error: --org-export APPLY refused: pass --apply to confirm (the plan "
            "above is what it would do)")
        return 2
    if p.blocked:
        err("error: the plan is blocked; nothing is applied until every repository "
            "above is clean")
        return 1
    res = apply(p, runner, progress=lambda r: out(
        f"  {r.action:<28} {r.target}" + (f"  SKIPPED: {r.skipped}" if r.skipped else "")))
    for line in result_lines(res):
        out(line)
    return 1 if res.failures else 0
