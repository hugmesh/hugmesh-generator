#!/usr/bin/env python3
"""Every Postgres role a service's Liquibase changelogs GRANT to must be created by
THAT service's own database bootstrap — and must be a role something actually
connects as.

WHY THIS EXISTS
---------------
hugmesh-admin-bff-api CrashLoopBackOff'd in the kind cluster and could never start:

    Migration failed for changeset db/changelog/008-access-suspension.xml::
      008-access-suspension-grant::hugmesh
    Reason: ERROR: role "admin_bff" does not exist
      [Failed SQL: GRANT SELECT, INSERT, UPDATE ON access_suspension TO admin_bff]

All 97 GRANT/REVOKE statements in that service's changelogs named `admin_bff`. That
role is real — but it belongs to the SEPARATE route-access/gateway Postgres
(manifests/route-access/initdb/10-roles.sh), where admin-bff is merely a client. In
admin-bff's OWN database the bootstrap creates `adminbff_app`
(manifests/admin-bff-db/initdb/10-roles.sh), which is also the role the app connects
as (SPRING_R2DBC_USERNAME). A role name had been copied across a datasource boundary.

It shipped because every environment that ran the changelog OUTSIDE the cluster had a
shim that created the missing role so the GRANT would merely resolve: the compose
stack's `admin-bff-db-init` service and both Testcontainers harnesses. Those shims
took their name from the changelog instead of from the bootstrap, so compose and CI
were green on a role the cluster did not have. Nothing compared the two sides.

THE TWO INVARIANTS
------------------
For each service, over the datasource its changelogs actually run against
(SPRING_LIQUIBASE_URL):

  [created]  every GRANT/REVOKE grantee is created by that service's own DB bootstrap
             (initdb CREATE ROLE/USER, or the POSTGRES_USER owner).
  [connects] every grantee is a role something actually logs in as on that datasource
             (SPRING_LIQUIBASE_USER or SPRING_R2DBC_USERNAME).

[connects] is what makes this more than a syntax check. Adding `CREATE ROLE admin_bff`
to admin-bff's bootstrap would have satisfied [created] and un-wedged startup while
leaving all 97 statements granting privileges to a role with no sessions — a placebo
that [connects] refuses.

  [mounted]  the initdb file that creates the roles is published into a ConfigMap and
             mounted at /docker-entrypoint-initdb.d, so the bootstrap actually RUNS.
             A role script present in the tree but unmounted creates nothing.

  [compose]  tests/stack/compose.local.yaml's role shims name roles the CLUSTER
             bootstrap creates, and every granted role is creatable locally too.

[compose] exists because the local stack is where this bug hid. compose created
`admin_bff` itself — a real role, of a DIFFERENT database — so the GRANT resolved and
`make stack-up` was green while the cluster had no such role. A gate that read only
the cluster manifests would leave that trap armed: someone would "fix" a future
divergence by adding another invented role to compose and be green again. So the
shim's role name must be one the cluster's own bootstrap for that Postgres creates,
and conversely every role the changelogs grant to must exist in compose, or the local
stack is failing to exercise the migration it claims to run.

WHAT THIS CAN AND CANNOT SEE
----------------------------
The bootstraps live in THIS repo; the changelogs live in the SERVICE repos. So the
gate needs the service checkouts. It does not guess and it does not skip: a checkout
it cannot read is exit 3 INCOMPLETE, never a silent pass. CI supplies them with the
same blobless+sparse clone recipe lint:service-env-contract uses, driven off
--list-repos so the list is derived from the manifests rather than hand-maintained.

[compose] compares role NAMES and role EXISTENCE. It deliberately does not require
compose to connect as the same role the cluster does: the local stack connects
admin-bff-api as the database OWNER `adminbff` rather than the least-privilege
`adminbff_app`, a documented dev deviation (no per-user Secret passwords locally).
That deviation is therefore NOT policed here — a privilege bug that only shows up
when you connect as the restricted role remains invisible to compose, and only the
cluster or a Testcontainers run as `adminbff_app` would surface it.

Two services (tube, owncast) name a database this tree does not define. They carry no
GRANTs today, so there is nothing to check; the moment either gains one, the missing
bootstrap becomes a FAIL rather than a shrug.

EXIT CODES
  0  invariants hold          2  bad input / unparseable manifest
  1  invariant violated       3  INCOMPLETE — corpus unavailable, the check did NOT run
"""

from __future__ import annotations

import glob
import os
import re
import sys
from pathlib import Path
from xml.etree import ElementTree as ET

try:
    import yaml
except ModuleNotFoundError:  # hard-fail: a missing parser must never read as "no findings"
    sys.stderr.write(
        "FATAL: PyYAML is not installed. This gate parses Kubernetes manifests; without it\n"
        "       it would inspect nothing and exit 0. Install pyyaml (pip install pyyaml).\n"
    )
    raise SystemExit(2)

IMAGE_PREFIX = "snapdragon-systems/"
CHANGELOG_REL = Path("src/main/resources/db")
COMPOSE_REL = Path("tests/stack/compose.local.yaml")
INITDB_MOUNT = "/docker-entrypoint-initdb.d"

# Grantees that are not roles a bootstrap could create.
PSEUDO_ROLES = {"public", "current_user", "session_user", "current_role"}

# One definition of "this SQL creates a role", used for the cluster initdb scripts AND
# for the compose shims, so the two sides cannot drift apart by parsing differently.
CREATE_ROLE_RE = re.compile(
    r"\bCREATE\s+(?:ROLE|USER)\s+(?:IF\s+NOT\s+EXISTS\s+)?\"?([A-Za-z_][A-Za-z0-9_]*)\"?", re.I
)
PSQL_HOST_RE = re.compile(r"\bpsql\b[^\n]*?\s-h\s+([A-Za-z0-9_.-]+)")
JDBC_HOST_RE = re.compile(r"jdbc:postgresql://([^.:/]+)")

PASSES: list[str] = []
FAILURES: list[str] = []


class Incomplete(Exception):
    """The corpus needed to run a check is unavailable. Exit 3, never a pass."""


class Unrecognised(Exception):
    """A file we must understand did not parse. Exit 2, never a pass."""


# ─────────────────────────────── SQL extraction ────────────────────────────────


def split_statements(sql: str) -> list[str]:
    """Split on `;` outside single-quoted strings and $$-quoted bodies."""
    out, buf, i, n = [], [], 0, len(sql)
    in_squote = False
    dollar_tag: str | None = None
    while i < n:
        ch = sql[i]
        if dollar_tag is not None:
            if sql.startswith(dollar_tag, i):
                buf.append(dollar_tag)
                i += len(dollar_tag)
                dollar_tag = None
                continue
        elif in_squote:
            if ch == "'":
                in_squote = False
        else:
            m = re.match(r"\$[A-Za-z_]*\$", sql[i:])
            if m:
                dollar_tag = m.group(0)
                buf.append(dollar_tag)
                i += len(dollar_tag)
                continue
            if ch == "'":
                in_squote = True
            elif ch == ";":
                out.append("".join(buf))
                buf = []
                i += 1
                continue
        buf.append(ch)
        i += 1
    out.append("".join(buf))
    return [s for s in out if s.strip()]


def grantees(statement: str) -> list[str] | None:
    """Grantee roles of a GRANT/REVOKE statement, or None if it is neither.

    Asserts the SHAPE of the statement rather than matching a literal line, so a
    reformatted, multi-line or multi-grantee GRANT is still read correctly.
    """
    head = re.match(r"\s*(GRANT|REVOKE)\b", statement, re.I)
    if not head:
        return None
    kw = "TO" if head.group(1).upper() == "GRANT" else "FROM"
    parts = re.split(rf"\b{kw}\b", statement, flags=re.I)
    if len(parts) < 2:
        return None
    tail = parts[-1]
    tail = re.split(r"\bWITH\b|\bGRANTED\s+BY\b", tail, flags=re.I)[0]
    found = []
    for raw in tail.split(","):
        tok = raw.strip().strip('"').strip()
        tok = re.sub(r"^(GROUP|ROLE)\s+", "", tok, flags=re.I).strip().strip('"')
        if not tok or tok.lower() in PSEUDO_ROLES:
            continue
        if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", tok):
            found.append(tok)
    return found


def sql_text_blocks(path: Path) -> list[str]:
    """SQL-bearing text of a changelog file.

    For XML changelogs ONLY <sql>/<rollback> element text counts — prose in
    <comment> and XML comments describes GRANTs constantly ("a GRANT giving a USER
    read access") and must never be mistaken for one. ElementTree drops comments.
    """
    if path.suffix.lower() == ".sql":
        return [path.read_text(encoding="utf-8", errors="replace")]
    if path.suffix.lower() != ".xml":
        return []
    try:
        root = ET.parse(str(path)).getroot()
    except ET.ParseError as exc:
        raise Unrecognised(f"{path}: {exc}") from exc
    blocks = []
    for el in root.iter():
        tag = el.tag.rsplit("}", 1)[-1].lower()
        if tag in {"sql", "rollback"}:
            blocks.append("".join(el.itertext()))
    return blocks


def granted_roles(repo_src: Path) -> tuple[dict[str, list[str]], int, int]:
    """(role -> sample locations, statements seen, changelog files scanned)."""
    roles: dict[str, list[str]] = {}
    stmts = 0
    files = sorted(
        p
        for p in repo_src.rglob("*")
        if p.is_file() and p.suffix.lower() in {".xml", ".sql"}
    )
    for path in files:
        for block in sql_text_blocks(path):
            for statement in split_statements(block):
                got = grantees(statement)
                if got is None:
                    continue
                stmts += 1
                for role in got:
                    roles.setdefault(role, []).append(path.name)
    return roles, stmts, len(files)


# ─────────────────────────────── cluster facts ─────────────────────────────────


def load_docs(path: Path) -> list[dict]:
    try:
        return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if isinstance(d, dict)]
    except yaml.YAMLError as exc:
        raise Unrecognised(f"{path}: {exc}") from exc


class Service:
    def __init__(self, manifest: Path, name: str, container: dict):
        self.manifest = manifest
        self.name = name
        env = {e["name"]: e for e in (container.get("env") or []) if isinstance(e, dict)}
        self.image = container.get("image", "")
        short = self.image[len(IMAGE_PREFIX):].split(":")[0]
        self.repo = short if short.startswith("hugmesh-") else f"hugmesh-{short}"
        self.liquibase_url = (env.get("SPRING_LIQUIBASE_URL") or {}).get("value", "")
        self.liquibase_user = (env.get("SPRING_LIQUIBASE_USER") or {}).get("value")
        self.runtime_user = (env.get("SPRING_R2DBC_USERNAME") or {}).get("value")
        m = re.match(r"jdbc:postgresql://([^.:/]+)", self.liquibase_url)
        self.db_host = m.group(1) if m else None

    @property
    def login_roles(self) -> set[str]:
        return {r for r in (self.liquibase_user, self.runtime_user) if r}


def discover_services(cluster: Path) -> list[Service]:
    """Services whose changelogs run against a Postgres, derived from the manifests.

    SPRING_LIQUIBASE_URL is the datasource Liquibase migrates — so it is the database
    whose bootstrap must create the granted roles. Deriving from it (rather than a
    hand-written list) is what stops a newly added BFF from being silently unchecked.
    """
    found: list[Service] = []
    for path in sorted(cluster.glob("manifests/*/deployment.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") != "Deployment":
                continue
            for cont in doc["spec"]["template"]["spec"].get("containers") or []:
                env_names = {e.get("name") for e in (cont.get("env") or []) if isinstance(e, dict)}
                if "SPRING_LIQUIBASE_URL" in env_names:
                    found.append(Service(path, doc["metadata"]["name"], cont))
    return found


def db_dir_for(cluster: Path, host: str) -> Path | None:
    """Directory of the manifest set that defines the Service named `host`."""
    for path in sorted(cluster.glob("manifests/**/*.yaml")):
        try:
            docs = load_docs(path)
        except Unrecognised:
            continue
        for doc in docs:
            if doc.get("kind") == "Service" and doc.get("metadata", {}).get("name") == host:
                return path.parent
    return None


def created_roles(db_dir: Path) -> tuple[set[str], list[Path]]:
    """Roles the DB bootstrap creates: initdb CREATE ROLE/USER + the POSTGRES_USER owner."""
    roles: set[str] = set()
    creating: list[Path] = []
    for path in sorted((db_dir / "initdb").glob("*")) if (db_dir / "initdb").is_dir() else []:
        if not path.is_file():
            continue
        text = path.read_text(encoding="utf-8", errors="replace")
        hits = {m.group(1) for m in CREATE_ROLE_RE.finditer(text)}
        if hits:
            roles |= hits
            creating.append(path)
    for path in sorted(db_dir.glob("*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") != "Deployment":
                continue
            for cont in doc["spec"]["template"]["spec"].get("containers") or []:
                for env in cont.get("env") or []:
                    if isinstance(env, dict) and env.get("name") == "POSTGRES_USER" and env.get("value"):
                        roles.add(env["value"])
    return roles, creating


def initdb_is_mounted(db_dir: Path, creating: list[Path]) -> str | None:
    """None if the role-creating files are published AND mounted; else the reason."""
    kust = db_dir / "kustomization.yaml"
    if not kust.is_file():
        return f"no kustomization.yaml in {db_dir} — nothing publishes initdb/ into a ConfigMap"
    published: set[str] = set()
    for doc in load_docs(kust):
        for gen in doc.get("configMapGenerator") or []:
            for entry in gen.get("files") or []:
                published.add(Path(str(entry).split("=")[-1]).name)
    missing = [p.name for p in creating if p.name not in published]
    if missing:
        return f"initdb file(s) {', '.join(missing)} are not in any configMapGenerator files: list"
    for path in sorted(db_dir.glob("*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") != "Deployment":
                continue
            for cont in doc["spec"]["template"]["spec"].get("containers") or []:
                for mount in cont.get("volumeMounts") or []:
                    if isinstance(mount, dict) and mount.get("mountPath") == INITDB_MOUNT:
                        return None
    return f"no container mounts {INITDB_MOUNT} — the initdb scripts would never run"


# ──────────────────────────── the local compose stack ──────────────────────────


def _command_text(svc: dict) -> str:
    cmd = svc.get("command")
    if cmd is None:
        return ""
    if isinstance(cmd, (list, tuple)):
        return "\n".join(str(c) for c in cmd)
    return str(cmd)


class Compose:
    """tests/stack/compose.local.yaml, as far as Postgres ROLES are concerned.

    Reading compose is not decoration. The local stack is where the `admin_bff` bug
    hid: its one-shot `admin-bff-db-init` service created the role the CHANGELOG
    named, so the GRANT resolved locally and every `make stack-up` was green while the
    cluster had no such role. The shim name must be DERIVED from the cluster bootstrap,
    and only a checker that reads both files can hold anyone to that.
    """

    def __init__(self, path: Path):
        self.path = path
        docs = load_docs(path)
        services = (docs[0].get("services") if docs else None) or {}
        if not isinstance(services, dict) or not services:
            raise Unrecognised(
                f"{path}: no non-empty `services:` mapping — the local stack could not be read, "
                "and a compose file this checker cannot parse must never read as 'compose agrees'"
            )
        self.services = {k: v for k, v in services.items() if isinstance(v, dict)}

    def env(self, service: str) -> dict[str, str]:
        raw = (self.services.get(service) or {}).get("environment") or {}
        if isinstance(raw, list):
            raw = dict(e.split("=", 1) for e in raw if isinstance(e, str) and "=" in e)
        if not isinstance(raw, dict):
            return {}
        return {str(k): "" if v is None else str(v) for k, v in raw.items()}

    def shim_roles(self) -> dict[str, dict[str, list[str]]]:
        """host -> {role: [compose services that CREATE it]}, from psql one-shots."""
        out: dict[str, dict[str, list[str]]] = {}
        for name, svc in sorted(self.services.items()):
            text = _command_text(svc)
            roles = {m.group(1) for m in CREATE_ROLE_RE.finditer(text)} if text else set()
            if not roles:
                continue
            hosts = {m.group(1) for m in PSQL_HOST_RE.finditer(text)}
            if len(hosts) != 1:
                raise Unrecognised(
                    f"{self.path}: compose service '{name}' creates role(s) "
                    f"{', '.join(sorted(roles))} but this checker resolved {len(hosts)} psql "
                    f"target host(s) {sorted(hosts)} in its command. It will not guess which "
                    "database a CREATE ROLE lands in"
                )
            host = hosts.pop()
            for role in roles:
                out.setdefault(host, {}).setdefault(role, []).append(name)
        return out

    def liquibase_host(self, service: str) -> str | None:
        m = JDBC_HOST_RE.search(self.env(service).get("SPRING_LIQUIBASE_URL", ""))
        return m.group(1) if m else None

    def roles_on(self, host: str) -> set[str]:
        """Roles that exist on compose's `host` Postgres: the POSTGRES_USER owner the
        image creates on first init, plus anything a shim CREATEs."""
        roles = set(self.shim_roles().get(host, {}))
        owner = self.env(host).get("POSTGRES_USER")
        if owner:
            roles.add(owner)
        return roles


def check_compose_shims(cluster: Path, compose: Compose) -> None:
    """[compose] every role the local stack invents must be one the cluster creates.

    The verbatim incident: compose created `admin_bff`, admin-bff-db's cluster bootstrap
    creates `adminbff_app`. Both are real role names; only one of them exists on the
    database the changelogs actually migrate.
    """
    for host, roles in sorted(compose.shim_roles().items()):
        db_dir = db_dir_for(cluster, host)
        if db_dir is None:
            FAILURES.append(
                f"  FAIL [compose] {compose.path.name} creates role(s) "
                f"{', '.join(sorted(roles))} on '{host}', but this tree defines no Service "
                f"named '{host}' — so there is no cluster bootstrap to derive the name from "
                "and the local stack is free to invent one"
            )
            continue
        created, _ = created_roles(db_dir)
        for role, where in sorted(roles.items()):
            if role in created:
                PASSES.append(
                    f"  ok   [compose] {', '.join(sorted(where))} creates '{role}' on {host} — "
                    f"the same role {db_dir.name}'s cluster bootstrap creates"
                )
            else:
                FAILURES.append(
                    f"  FAIL [compose] {', '.join(sorted(where))} creates role '{role}' on "
                    f"'{host}', which {db_dir.name}'s cluster bootstrap never creates (it creates "
                    f"{{{', '.join(sorted(created)) or '—'}}}). A role invented locally makes the "
                    "changelog's GRANT resolve in compose and NOWHERE ELSE — that is exactly how "
                    "'role \"admin_bff\" does not exist' got as far as a live cluster"
                )


def resolve_src_root(repo_root: Path, explicit: str | None, repos: set[str]) -> Path:
    """A tree carrying EVERY service checkout. Partial roots are refused: one that
    carried three of ten would check three and silently ignore seven."""
    candidates: list[Path] = []
    for raw in (explicit, os.environ.get("SERVICE_SRC_ROOT")):
        if raw:
            candidates.append(Path(raw))
    candidates += [repo_root / ".service-src", repo_root / ".stack-src", repo_root.parent]
    tried: list[str] = []
    for cand in candidates:
        if not cand.is_dir():
            tried.append(f"{cand} (absent)")
            continue
        missing = sorted(r for r in repos if not (cand / r / CHANGELOG_REL).is_dir())
        if not missing:
            return cand
        tried.append(f"{cand} (missing {len(missing)}: {', '.join(missing[:4])}…)")
    raise Incomplete(
        f"no tree carries every service's {CHANGELOG_REL}. Needed: {', '.join(sorted(repos))}. "
        "Tried: " + "; ".join(tried)
    )


# ────────────────────────────────── the gate ───────────────────────────────────


def check(cluster: Path, src_root: Path, services: list[Service], compose: Compose) -> None:
    check_compose_shims(cluster, compose)
    total_statements = 0
    for svc in sorted(services, key=lambda s: s.repo):
        repo_src = src_root / svc.repo / CHANGELOG_REL
        if not repo_src.is_dir():
            raise Incomplete(f"{svc.repo}: no {CHANGELOG_REL} at {repo_src}")
        roles, stmts, files = granted_roles(repo_src)
        total_statements += stmts
        if files == 0:
            raise Incomplete(
                f"{svc.repo}: {repo_src} holds no .xml/.sql changelog files — the scan would "
                "have had nothing to read, which is not the same as having nothing to fix"
            )

        if not roles:
            PASSES.append(f"  ok   [{svc.repo}] no GRANT/REVOKE in {files} changelog files")
            continue

        db_dir = db_dir_for(cluster, svc.db_host) if svc.db_host else None
        if db_dir is None:
            FAILURES.append(
                f"  FAIL [{svc.repo}] grants to {', '.join(sorted(roles))} but this tree defines no "
                f"Service named '{svc.db_host}' (from SPRING_LIQUIBASE_URL in {svc.manifest}), so "
                "its bootstrap cannot be checked"
            )
            continue

        created, creating = created_roles(db_dir)
        if not created:
            FAILURES.append(
                f"  FAIL [{svc.repo}] scanned {db_dir}/initdb and found NO created role — either the "
                "bootstrap creates none or the scan is broken; both mean this gate proves nothing"
            )
            continue

        for role in sorted(roles):
            where = sorted(set(roles[role]))[:3]
            loc = f"{', '.join(where)}{'…' if len(set(roles[role])) > 3 else ''}"
            if role not in created:
                FAILURES.append(
                    f"  FAIL [{svc.repo}] [created] GRANT/REVOKE to role '{role}' ({loc}) but "
                    f"{db_dir.name}'s bootstrap creates only {{{', '.join(sorted(created))}}} — "
                    "Liquibase will abort with 'role does not exist' and the pod will never start"
                )
            elif role not in svc.login_roles:
                FAILURES.append(
                    f"  FAIL [{svc.repo}] [connects] GRANT/REVOKE to role '{role}' ({loc}) which "
                    f"nothing connects as on this datasource (liquibase={svc.liquibase_user}, "
                    f"runtime={svc.runtime_user}) — the privileges would go to a role with no sessions"
                )
            else:
                PASSES.append(
                    f"  ok   [{svc.repo}] grants to '{role}' — created by {db_dir.name}/initdb "
                    f"and connected as ({'liquibase' if role == svc.liquibase_user else 'runtime'})"
                )

        # The same roles, on the LOCAL stack. A grant to a role compose cannot create is
        # a migration compose never really runs — the failure mode is just deferred to
        # whoever brings the stack up next.
        chost = compose.liquibase_host(svc.repo)
        if chost is None:
            FAILURES.append(
                f"  FAIL [compose] {svc.repo} grants to {', '.join(sorted(roles))} but "
                f"{compose.path.name} has no service '{svc.repo}' with a SPRING_LIQUIBASE_URL "
                "— those GRANTs are never exercised locally, so the local stack cannot fail on "
                "them and every divergence surfaces first in a cluster"
            )
        else:
            local = compose.roles_on(chost)
            absent = sorted(r for r in roles if r not in local)
            if absent:
                FAILURES.append(
                    f"  FAIL [compose] {svc.repo} grants to {', '.join(absent)}, which "
                    f"{compose.path.name}'s '{chost}' never creates (it has "
                    f"{{{', '.join(sorted(local)) or '—'}}}) — `make stack-up` would abort on "
                    f"ERROR: role \"{absent[0]}\" does not exist"
                )
            else:
                PASSES.append(
                    f"  ok   [compose] {svc.repo}'s granted role(s) "
                    f"{', '.join(sorted(roles))} all exist on compose's '{chost}'"
                )

        if creating:
            reason = initdb_is_mounted(db_dir, creating)
            if reason:
                FAILURES.append(f"  FAIL [{svc.repo}] [mounted] {reason}")
            else:
                PASSES.append(
                    f"  ok   [{svc.repo}] {db_dir.name}/initdb "
                    f"({', '.join(p.name for p in creating)}) is ConfigMap-published and mounted"
                )

    # Vacuity control. Every service legitimately having zero grants is indistinguishable
    # from the statement parser having rotted, so refuse to certify a corpus with no
    # GRANT/REVOKE in it at all.
    if total_statements == 0:
        FAILURES.append(
            "  FAIL [vacuity] not one GRANT/REVOKE statement was found across every service's "
            "changelogs. The invariant cannot hold vacuously: either the SQL extraction is "
            "broken or the corpus is wrong. Refusing to report a pass."
        )


def main(argv: list[str]) -> int:
    if not argv:
        print(
            "usage: liquibase_grant_roles.py <specs/cluster> [--service-src DIR] "
            "[--compose FILE] [--list-repos]"
        )
        return 2
    cluster = Path(argv[0]).resolve()
    if not cluster.is_dir():
        print(f"  FAIL [input] not a directory: {cluster}")
        return 2
    explicit = argv[argv.index("--service-src") + 1] if "--service-src" in argv else None
    repo_root = Path(__file__).resolve().parents[2]
    compose_path = Path(
        argv[argv.index("--compose") + 1] if "--compose" in argv else repo_root / COMPOSE_REL
    )

    try:
        services = discover_services(cluster)
        if not services:
            raise Incomplete(
                f"no Deployment under {cluster}/manifests sets SPRING_LIQUIBASE_URL — the gate "
                "would have had no service to check"
            )
        if "--list-repos" in argv:
            for repo in sorted({s.repo for s in services}):
                print(repo)
            return 0
        if not compose_path.is_file():
            raise Incomplete(
                f"no local-stack compose file at {compose_path}. The [compose] leg compares the "
                "local stack's role shims against the cluster bootstrap; without the file it "
                "compares nothing, and the local stack is precisely where this bug hid"
            )
        compose = Compose(compose_path)
        src_root = resolve_src_root(repo_root, explicit, {s.repo for s in services})
        print(f"  --   {len(services)} service(s) with a Liquibase datasource; sources: {src_root}")
        print(f"  --   local stack: {compose_path}")
        check(cluster, src_root, services, compose)
    except Incomplete as exc:
        print(f"  INCOMPLETE {exc}")
        print("       Comparing changelogs against bootstraps IS this gate; it did not run, so this")
        print("       is a FAILURE (rc 3), not a skip. Provide the checkouts (SERVICE_SRC_ROOT).")
        return 3
    except Unrecognised as exc:
        print(f"  FAIL [parse] {exc}")
        print("       This checker refuses to report agreement with a file it could not read.")
        return 2

    for line in PASSES:
        print(line)
    for line in FAILURES:
        print(line)
    print(f"  -- {len(PASSES)} ok, {len(FAILURES)} failed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
