#!/usr/bin/env python3
"""service_env_contract.py — cross-file environment-contract checker for specs/cluster.

Asserts, offline, against a specs/cluster tree PLUS the first-party service sources:

  [env-derived]   THE SYSTEMIC CHECK. For every first-party BFF container, this reads
                  that SERVICE's own application.yml and requires the Deployment to
                  override every `${ENV:default}` whose default names a namespace or
                  domain THIS CLUSTER DOES NOT HAVE. Nothing here is typed by hand:
                  the keys come from the service, the "what exists" set comes from
                  specs/cluster (see service_env_defaults.ClusterFacts). A new stale
                  default in any service repo fails this on the next run with no edit
                  to any list.
  [env-startup]   every placeholder with NO default at all is set — unset is not a
                  degraded feature, it is a pod that never starts (finding #15).
  [env-required]  the extra keys specs/cluster/service-env-contract.yaml pins for
                  reasons the defaults cannot express (agreement with the IdP, which
                  Secret a credential must come from) are emitted EXPLICITLY.
  [casdoor-*]     every value that has to agree with the Casdoor bootstrap DOES.
                  The expected values are DERIVED from manifests/casdoor/init-job.yaml
                  (the reconcile.py inside it is parsed as Python, by AST) and from the
                  init_data.json inside the ConfigMap — never restated in the contract.
                  So a change to either side, alone, turns this red.
  [stale-ref]     no env VALUE emitted by ANY workload in specs/cluster names a
                  namespace the tree does not create or a domain it does not serve.
                  Derived by the same rules — not a brand-prefix pattern list, which
                  is why it sees `casdoor.hugmesh-casdoor.svc.cluster.local`.

Plus [coverage]: every first-party *-bff-api Deployment is classified in the contract,
so a new BFF cannot arrive without someone stating what it must agree with.

Exit 0 = all checks pass. Exit 1 = a check failed. Exit 2 = the tool could not run
(missing file, unparseable input, or a casdoor-init shape it does not recognise —
which is a FAILURE, never a silent pass). Exit 3 = INCOMPLETE: a service source the
derived check needs is not present, so the check did not run. INCOMPLETE is a
failure too — the reserved-prefixes gate spent months green while its most valuable
stage printed "[SKIP] … (not checked out)", and this one will not repeat that.

Usage: service_env_contract.py <specs/cluster dir> [--contract <file>]
                               [--service-src <dir>]
Service sources are resolved from --service-src, $SERVICE_SRC_ROOT, <repo>/.service-src,
<repo>/.stack-src, or the checkout's parent directory (sibling clones), in that order.
"""
from __future__ import annotations

import ast
import json
import os
import re
import sys
from pathlib import Path

try:
    import yaml
except ImportError:  # pragma: no cover - guarded by the shell wrapper too
    print("  FAIL PyYAML not available (pip install pyyaml)")
    sys.exit(2)

sys.path.insert(0, str(Path(__file__).resolve().parent))
from service_env_defaults import ClusterFacts, classify, required_placeholders, stale_defaults  # noqa: E402


# ── failure/exit plumbing ────────────────────────────────────────────────────
FAILURES: list[str] = []
PASSES: list[str] = []


def fail(check: str, msg: str) -> None:
    FAILURES.append(f"  FAIL [{check}] {msg}")


def ok(check: str, msg: str) -> None:
    PASSES.append(f"  ok   [{check}] {msg}")


class Incomplete(Exception):
    """A check could not run because its input is absent.

    Never downgraded to a skip. A gate that reports PASS while its central stage
    never executed is worse than no gate: it is a standing claim that the class is
    covered.
    """


class Unrecognised(Exception):
    """The casdoor-init source no longer has a shape this checker understands.

    Raised, never swallowed: an extractor that cannot find what it is looking for
    must fail the gate, because the alternative is asserting agreement with a value
    we silently failed to read.
    """


# ── YAML helpers ─────────────────────────────────────────────────────────────
def load_docs(path: Path) -> list:
    try:
        return [d for d in yaml.safe_load_all(path.read_text(encoding="utf-8")) if d]
    except Exception as exc:  # noqa: BLE001 - report and abort, never continue
        print(f"  FAIL [yaml-parse] {path}: {exc}")
        sys.exit(2)


def pod_spec(doc: dict) -> dict:
    if doc.get("kind") == "CronJob":
        return doc["spec"]["jobTemplate"]["spec"]["template"]["spec"]
    return doc["spec"]["template"]["spec"]


def containers(doc: dict) -> list:
    spec = pod_spec(doc)
    return (spec.get("containers") or []) + (spec.get("initContainers") or [])


def env_map(doc: dict) -> dict:
    """name -> {'value': str} | {'secret': (name, key, optional)} for the app container.

    The app container is the one named after the Deployment (repo idiom); the
    build-keystore initContainer is deliberately excluded so its env cannot satisfy a
    requirement the running container never sees.
    """
    name = doc["metadata"]["name"]
    conts = pod_spec(doc).get("containers") or []
    chosen = next((c for c in conts if c.get("name") == name), conts[0] if conts else {})
    out: dict[str, dict] = {}
    for e in chosen.get("env") or []:
        ref = (e.get("valueFrom") or {}).get("secretKeyRef")
        if ref:
            out[e["name"]] = {"secret": (ref.get("name"), ref.get("key"), bool(ref.get("optional")))}
        else:
            out[e["name"]] = {"value": e.get("value")}
    return out


# ── casdoor-init extraction (AST, not regex) ─────────────────────────────────
def _const_str(node: ast.AST) -> str:
    if isinstance(node, ast.Constant) and isinstance(node.value, str):
        return node.value
    raise Unrecognised(f"expected a string literal, got {type(node).__name__}")


def _render_fstring(node: ast.AST, bindings: dict[str, str]) -> str:
    """Render an f-string whose only interpolations are bare names we know."""
    if isinstance(node, ast.Constant):
        return _const_str(node)
    if not isinstance(node, ast.JoinedStr):
        raise Unrecognised(f"expected an f-string, got {type(node).__name__}")
    parts = []
    for piece in node.values:
        if isinstance(piece, ast.Constant):
            parts.append(str(piece.value))
        elif isinstance(piece, ast.FormattedValue) and isinstance(piece.value, ast.Name):
            key = piece.value.id
            if key not in bindings:
                raise Unrecognised(f"f-string interpolates unknown name {key!r}")
            parts.append(bindings[key])
        else:
            raise Unrecognised("f-string interpolates an expression this checker cannot evaluate")
    return "".join(parts)


def _find_func(tree: ast.Module, name: str) -> ast.FunctionDef:
    for node in tree.body:
        if isinstance(node, ast.FunctionDef) and node.name == name:
            return node
    raise Unrecognised(f"casdoor-init has no function {name}()")


def _dict_value(d: ast.Dict, key: str) -> ast.AST:
    for k, v in zip(d.keys, d.values):
        if isinstance(k, ast.Constant) and k.value == key:
            return v
    raise Unrecognised(f"application dict has no {key!r} key")


class CasdoorSource:
    """The values casdoor-init ACTUALLY registers, read out of the manifest itself."""

    def __init__(self, cluster: Path, init_job_rel: str, init_data_rel: str):
        job_path = cluster / init_job_rel
        data_path = cluster / init_data_rel
        for p in (job_path, data_path):
            if not p.is_file():
                print(f"  FAIL [casdoor-source] missing {p}")
                sys.exit(2)

        docs = load_docs(job_path)
        cms = [d for d in docs if d.get("kind") == "ConfigMap" and "reconcile.py" in (d.get("data") or {})]
        jobs = [d for d in docs if d.get("kind") == "Job"]
        if not cms or not jobs:
            raise Unrecognised(f"{init_job_rel}: expected one ConfigMap carrying reconcile.py and one Job")
        self.script = cms[0]["data"]["reconcile.py"]
        tree = ast.parse(self.script)

        job_env = {e["name"]: e.get("value") for e in containers(jobs[0])[0].get("env") or []}
        self.job_org = job_env.get("CASDOOR_ORG")
        self.script_org_default = self._script_org_default(tree)
        self.init_data_org = self._init_data_org(data_path)

        self.apps = self._apps(tree)
        self.client_id_prefix = self._client_id_prefix(tree)
        self.default_redirect_tpl = _dict_value(self._app_dict(tree), "redirectUris")
        self.redirect_overrides = self._redirect_overrides(tree)
        self._assert_app_dict_wiring(tree)

    # -- organization ---------------------------------------------------------
    @staticmethod
    def _script_org_default(tree: ast.Module) -> str:
        for node in tree.body:
            if not isinstance(node, ast.Assign):
                continue
            if not any(isinstance(t, ast.Name) and t.id == "ORG" for t in node.targets):
                continue
            call = node.value
            if (
                isinstance(call, ast.Call)
                and isinstance(call.func, ast.Attribute)
                and call.func.attr == "get"
                and len(call.args) == 2
            ):
                return _const_str(call.args[1])
            raise Unrecognised("ORG is no longer os.environ.get('CASDOOR_ORG', <default>)")
        raise Unrecognised("casdoor-init script has no module-level ORG assignment")

    @staticmethod
    def _init_data_org(path: Path) -> str:
        for doc in load_docs(path):
            data = doc.get("data") or {}
            if "init_data.json" not in data:
                continue
            try:
                blob = json.loads(data["init_data.json"])
            except json.JSONDecodeError as exc:
                raise Unrecognised(f"init_data.json does not parse: {exc}") from exc
            orgs = blob.get("organizations") or []
            if len(orgs) != 1:
                raise Unrecognised(f"init_data.json declares {len(orgs)} organizations, expected exactly 1")
            return orgs[0]["name"]
        raise Unrecognised("no ConfigMap carrying init_data.json")

    # -- applications ---------------------------------------------------------
    @staticmethod
    def _apps(tree: ast.Module) -> dict[str, str]:
        for node in tree.body:
            if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "APPS" for t in node.targets
            ):
                if not isinstance(node.value, ast.Dict):
                    raise Unrecognised("APPS is no longer a dict literal")
                return {_const_str(k): _const_str(v) for k, v in zip(node.value.keys, node.value.values)}
        raise Unrecognised("casdoor-init script has no module-level APPS dict")

    @staticmethod
    def _app_dict(tree: ast.Module) -> ast.Dict:
        for node in ast.walk(_find_func(tree, "reconcile_app")):
            if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "app" for t in node.targets
            ):
                if not isinstance(node.value, ast.Dict):
                    raise Unrecognised("reconcile_app's `app` is no longer a dict literal")
                return node.value
        raise Unrecognised("reconcile_app() does not build an `app` dict")

    @staticmethod
    def _client_id_prefix(tree: ast.Module) -> str:
        for node in ast.walk(_find_func(tree, "reconcile_app")):
            if isinstance(node, ast.Assign) and any(
                isinstance(t, ast.Name) and t.id == "appname" for t in node.targets
            ):
                rendered = _render_fstring(node.value, {"name": "\x00"})
                if not rendered.endswith("\x00"):
                    raise Unrecognised("appname is no longer '<prefix>' + the app name")
                return rendered[:-1]
        raise Unrecognised("reconcile_app() does not assign appname")

    def _assert_app_dict_wiring(self, tree: ast.Module) -> None:
        """The registered clientId/name/organization must be the values we just read.

        Without this, the checker could faithfully derive `app-user-bff` while
        reconcile_app had quietly started registering something else entirely.
        """
        app = self._app_dict(tree)
        for key, want in (("name", "appname"), ("clientId", "appname"), ("organization", "ORG")):
            node = _dict_value(app, key)
            if not (isinstance(node, ast.Name) and node.id == want):
                raise Unrecognised(f"reconcile_app registers {key!r} from something other than `{want}`")

    @staticmethod
    def _redirect_overrides(tree: ast.Module) -> dict[str, ast.AST]:
        """`if name == "<app>": app["redirectUris"] = [...]` branches inside reconcile_app."""
        out: dict[str, ast.AST] = {}
        for node in ast.walk(_find_func(tree, "reconcile_app")):
            if not isinstance(node, ast.If):
                continue
            test = node.test
            if not (
                isinstance(test, ast.Compare)
                and isinstance(test.left, ast.Name)
                and test.left.id == "name"
                and len(test.ops) == 1
                and isinstance(test.ops[0], ast.Eq)
            ):
                continue
            who = _const_str(test.comparators[0])
            for stmt in node.body:
                if (
                    isinstance(stmt, ast.Assign)
                    and len(stmt.targets) == 1
                    and isinstance(stmt.targets[0], ast.Subscript)
                    and isinstance(stmt.targets[0].value, ast.Name)
                    and stmt.targets[0].value.id == "app"
                    and isinstance(stmt.targets[0].slice, ast.Constant)
                    and stmt.targets[0].slice.value == "redirectUris"
                ):
                    out[who] = stmt.value
        return out

    # -- public API used by the rules ----------------------------------------
    @property
    def org(self) -> str:
        return self.init_data_org

    def client_id(self, app: str) -> str:
        if app not in self.apps:
            raise Unrecognised(f"casdoor-init does not register an application named {app!r}")
        return f"{self.client_id_prefix}{app}"

    def redirect_uris(self, app: str) -> list[str]:
        if app not in self.apps:
            raise Unrecognised(f"casdoor-init does not register an application named {app!r}")
        node = self.redirect_overrides.get(app, self.default_redirect_tpl)
        if not isinstance(node, ast.List):
            raise Unrecognised(f"redirectUris for {app!r} is not a list literal")
        return [_render_fstring(el, {"name": app}) for el in node.elts]


# ── first-party services, and where their sources are ────────────────────────
#: the image idiom: <registry-or-org>/<name> is built from the repo hugmesh-<name>.
#: The prefix is matched, never SLICED BY LENGTH: `image[len(IMAGE_PREFIX):]` is what
#: broke tests/scripts/liquibase_grant_roles.py when the rebrand shortened the org
#: segment — the slice kept eating the old prefix's width and ate into the NAME, so the
#: checker went looking for a repo that does not exist and reported INCOMPLETE (reads as
#: a missing checkout, not a parser fault, so the gate stays dark). Taking the basename
#: is prefix-length independent and survives the next registry move
#: (`ghcr.io/hugmesh/...` included).
IMAGE_PREFIX = "hugmesh/"
#: every Spring service in this fleet keeps its packaged config here
APPLICATION_YML = "src/main/resources/application.yml"


class ServiceContainer:
    """One first-party BFF container, and the repo whose defaults it inherits."""

    def __init__(self, manifest: Path, deployment: str, container: dict):
        self.manifest = manifest
        self.deployment = deployment
        self.name = container.get("name")
        self.image = container.get("image", "")
        short = self.image.split("/")[-1].split(":")[0]
        self.repo = f"hugmesh-{short}"
        self.env: dict[str, dict] = {}
        for entry in container.get("env") or []:
            ref = (entry.get("valueFrom") or {}).get("secretKeyRef")
            if ref:
                self.env[entry["name"]] = {
                    "secret": (ref.get("name"), ref.get("key"), bool(ref.get("optional")))
                }
            else:
                self.env[entry["name"]] = {"value": entry.get("value")}

    @property
    def label(self) -> str:
        return self.deployment if self.name == self.deployment else f"{self.deployment}/{self.name}"


def first_party_bff_containers(cluster: Path) -> list[ServiceContainer]:
    """Every container in specs/cluster built from a first-party *-bff-api repo.

    Container-level, not Deployment-level, on purpose: hugmesh-owncast and
    hugmesh-tube each run their BFF as ONE container of a multi-container pod, and a
    Deployment-level scan would check the wrong container's env (or none).
    """
    out: list[ServiceContainer] = []
    for path in sorted((cluster / "manifests").glob("*/*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") != "Deployment":
                continue
            for cont in doc["spec"]["template"]["spec"].get("containers") or []:
                image = cont.get("image", "")
                if image.startswith(IMAGE_PREFIX) and "-bff-api" in image:
                    out.append(ServiceContainer(path, doc["metadata"]["name"], cont))
    return out


def resolve_service_src(repo_root: Path, explicit: str | None, repos: set[str]) -> Path:
    """The tree holding the service checkouts whose application.yml we must read.

    A candidate only counts if it carries EVERY repo we need: a partially populated
    root would silently check three services and skip six.
    """
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
        missing = sorted(r for r in repos if not (cand / r / APPLICATION_YML).is_file())
        if not missing:
            return cand
        tried.append(f"{cand} (missing {len(missing)}: {', '.join(missing[:4])}…)")
    raise Incomplete(
        "no service-source tree carries every first-party BFF's "
        f"{APPLICATION_YML}. Needed: {', '.join(sorted(repos))}. Tried: " + "; ".join(tried)
    )


def check_derived(svc: ServiceContainer, src_root: Path, facts: ClusterFacts) -> None:
    """[env-derived] + [env-startup] — the service's OWN config states the contract."""
    app_yml = src_root / svc.repo / APPLICATION_YML
    hits = stale_defaults(app_yml, facts)
    covered = 0
    for hit in hits:
        if set(hit.names) & set(svc.env):
            covered += 1
            continue
        fail(
            "env-derived",
            f"{svc.label}: none of {'/'.join(hit.names)} is set, so the pod adopts "
            f"{svc.repo}'s packaged default for {hit.prop} = {hit.default!r} — {hit.detail}",
        )
    if covered == len(hits):
        ok("env-derived", f"{svc.label}: all {len(hits)} stale-default keys in {svc.repo} are overridden")

    for names, prop in required_placeholders(app_yml):
        if set(names) & set(svc.env):
            ok("env-startup", f"{svc.label}: {'/'.join(names)} (no packaged default) is provided")
            continue
        fail(
            "env-startup",
            f"{svc.label}: {'/'.join(names)} has NO default in {svc.repo} ({prop}) and is not set — "
            "the container cannot start (\"Could not resolve placeholder\"), it does not degrade",
        )


def check_org_agreement(src: CasdoorSource) -> None:
    stated = {
        "init_data.json organizations[0].name": src.init_data_org,
        "casdoor-init Job env CASDOOR_ORG": src.job_org,
        "reconcile.py ORG default": src.script_org_default,
    }
    if len(set(stated.values())) == 1:
        ok("casdoor-org", f"all three statements of the organization agree: {src.org!r}")
        return
    fail(
        "casdoor-org",
        "the Casdoor bootstrap does not agree with itself on the organization name: "
        + ", ".join(f"{k} = {v!r}" for k, v in stated.items()),
    )


def check_service(cluster: Path, src: CasdoorSource, svc: dict, eso: dict) -> None:
    name = svc["name"]
    path = cluster / svc["manifest"]
    if not path.is_file():
        fail("env-required", f"{name}: contract points at a missing manifest {svc['manifest']}")
        return
    docs = [d for d in load_docs(path) if d.get("kind") == "Deployment" and d["metadata"]["name"] == name]
    if not docs:
        fail("env-required", f"{name}: no Deployment of that name in {svc['manifest']}")
        return
    env = env_map(docs[0])

    for rule in svc.get("requires") or []:
        key = rule["key"]
        entry = env.get(key)
        if entry is None:
            fail(
                "env-required",
                f"{name}: {key} is NOT set — the pod would silently use the service's own default. "
                f"{' '.join((rule.get('why') or '').split())}",
            )
            continue

        if "fromSecret" in rule:
            want_secret, want_key = rule["fromSecret"].split("/", 1)
            if "secret" not in entry:
                fail("env-secret", f"{name}: {key} must come from Secret {rule['fromSecret']}, not a literal")
                continue
            got_secret, got_key, got_optional = entry["secret"]
            if (got_secret, got_key) != (want_secret, want_key):
                fail(
                    "env-secret",
                    f"{name}: {key} reads {got_secret}/{got_key}, contract says {want_secret}/{want_key}",
                )
                continue
            want_optional = bool(rule.get("optional", False))
            if got_optional != want_optional:
                fail(
                    "env-secret",
                    f"{name}: {key} has optional={got_optional}, contract says optional={want_optional} "
                    "(a hard-required placeholder must fail at the kubernetes layer, not in Spring)",
                )
                continue
            if (want_secret, want_key) not in eso:
                fail(
                    "env-secret",
                    f"{name}: {key} mounts {want_secret}/{want_key}, which NO ExternalSecret materializes",
                )
                continue
            ok("env-secret", f"{name}: {key} <- {want_secret}/{want_key} (optional={want_optional})")
            continue

        value = entry.get("value")
        if value is None or str(value).strip() == "":
            fail("env-required", f"{name}: {key} is set to an empty value")
            continue

        if "mustEqual" in rule:
            expr = rule["mustEqual"]
            want = evaluate(src, expr)
            if value != want:
                fail(
                    "casdoor-agreement",
                    f"{name}: {key} = {value!r} but {expr} = {want!r} — the deployment and the "
                    "Casdoor bootstrap have drifted",
                )
                continue
            ok("casdoor-agreement", f"{name}: {key} == {expr} == {want!r}")
        elif "mustBeRegisteredRedirectUriOf" in rule:
            app = rule["mustBeRegisteredRedirectUriOf"]
            registered = src.redirect_uris(app)
            if value not in registered:
                fail(
                    "casdoor-agreement",
                    f"{name}: {key} = {value!r} is not among the redirectUris casdoor-init registers "
                    f"for {app!r} ({registered}) — Casdoor rejects the exchange",
                )
                continue
            ok("casdoor-agreement", f"{name}: {key} is a registered redirectUri of {app!r}")
        else:
            ok("env-required", f"{name}: {key} explicitly set")


def evaluate(src: CasdoorSource, expr: str) -> str:
    expr = expr.strip()
    if expr == "casdoor.org":
        return src.org
    m = re.fullmatch(r"casdoor\.(clientId|appName)\(([^)]+)\)", expr)
    if m:
        return src.client_id(m.group(2).strip())
    raise Unrecognised(f"contract uses an expression this checker does not implement: {expr!r}")


def load_external_secrets(root: Path) -> dict:
    """(secretName, key) -> path, for every ExternalSecret under the ESO dir."""
    out: dict[tuple[str, str], str] = {}
    if not root.is_dir():
        print(f"  FAIL [eso] missing external-secrets dir {root}")
        sys.exit(2)
    for path in sorted(root.glob("*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") != "ExternalSecret":
                continue
            target = ((doc.get("spec") or {}).get("target") or {})
            secret = target.get("name") or doc["metadata"]["name"]
            for item in (doc["spec"].get("data") or []):
                out[(secret, item["secretKey"])] = str(path)
            for key in ((target.get("template") or {}).get("data") or {}):
                out[(secret, key)] = str(path)
    return out


def check_emitted_values(cluster: Path, facts: ClusterFacts) -> None:
    """[stale-ref] — no workload in the tree may TELL a pod an address that is not there.

    Fleet-wide (every Deployment/StatefulSet/DaemonSet/Job/CronJob, app and init
    containers), and judged by the same derived rules as the defaults: a namespace
    specs/cluster does not create, or a domain it does not serve. The predecessor of
    this check matched a literal pre-rebrand brand prefix, so it was blind to
    `casdoor.hugmesh-casdoor.svc.cluster.local` — a post-rebrand-SHAPED name for a
    namespace that has never existed — which two live Deployments were emitting.
    """
    found = 0
    scanned = 0
    for path in sorted((cluster / "manifests").rglob("*.yaml")):
        for doc in load_docs(path):
            if doc.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"):
                continue
            try:
                spec = pod_spec(doc)
            except (KeyError, TypeError):
                continue
            for cont in (spec.get("containers") or []) + (spec.get("initContainers") or []):
                for entry in cont.get("env") or []:
                    value = entry.get("value")
                    if not isinstance(value, str):
                        continue
                    scanned += 1
                    hit = classify([entry["name"]], value, "env", facts)
                    if hit is None:
                        continue
                    found += 1
                    fail(
                        "stale-ref",
                        f"{doc['metadata']['name']}/{cont.get('name')}: {entry['name']} = {value!r} — {hit.detail}",
                    )
    if not found:
        ok("stale-ref", f"all {scanned} emitted env values name namespaces/domains this cluster has")


def check_coverage(cluster: Path, contract: dict, containers: list[ServiceContainer]) -> None:
    """Every first-party *-bff-api Deployment must be classified by the contract.

    Classification decides only whether a service has IdP/Vault agreement rules. The
    derived checks run on all of them either way — `noAgreementRules` is a statement
    about the IdP, never a way to opt out of the gate.
    """
    classified = {s["name"] for s in (contract.get("services") or [])}
    classified |= {s["name"] for s in (contract.get("noAgreementRules") or [])}
    found = {c.deployment for c in containers}
    missing = sorted(found - classified)
    if missing:
        fail(
            "coverage",
            "first-party BFF Deployment(s) not classified in service-env-contract.yaml "
            "(add to `services` with its IdP/Vault agreement rules, or to "
            f"`noAgreementRules` with why it holds none): {', '.join(missing)}",
        )
    else:
        ok("coverage", f"all {len(found)} first-party BFF Deployments are classified")
    stale = sorted(classified - found)
    if stale:
        fail(
            "coverage",
            "contract classifies service(s) that no first-party BFF Deployment provides — "
            f"a stale classification is itself drift: {', '.join(stale)}",
        )


def main(argv: list[str]) -> int:
    if not argv:
        print(__doc__)
        return 2
    cluster = Path(argv[0]).resolve()
    contract_path = cluster / "service-env-contract.yaml"
    if "--contract" in argv:
        contract_path = Path(argv[argv.index("--contract") + 1]).resolve()
    explicit_src = argv[argv.index("--service-src") + 1] if "--service-src" in argv else None
    if not cluster.is_dir():
        print(f"  FAIL [input] not a directory: {cluster}")
        return 2
    if "--list-repos" in argv:
        # The repos this tree obliges the gate to read, derived from the manifests.
        # CI drives its clone loop off THIS, so adding a BFF Deployment adds its
        # checkout automatically — a hand-written clone list in .gitlab-ci.yml would
        # reintroduce, one layer down, exactly the staleness this gate exists to stop.
        for repo in sorted({c.repo for c in first_party_bff_containers(cluster)}):
            print(repo)
        return 0
    if not contract_path.is_file():
        print(f"  FAIL [input] missing contract: {contract_path}")
        return 2

    contract = yaml.safe_load(contract_path.read_text(encoding="utf-8"))
    source = contract.get("casdoorSource") or {}
    repo_root = Path(__file__).resolve().parents[2]

    try:
        facts = ClusterFacts(cluster)
        containers = first_party_bff_containers(cluster)
        if not containers:
            raise Incomplete(
                f"no first-party {IMAGE_PREFIX}*-bff-api container found under {cluster}/manifests — "
                "the derived check would have had nothing to check"
            )
        src_root = resolve_service_src(repo_root, explicit_src, {c.repo for c in containers})
        print(f"  --   cluster facts: {len(facts.namespaces)} namespaces, domains {sorted(facts.domains)}")
        print(f"  --   service sources: {src_root} ({len(containers)} first-party BFF containers)")

        casdoor = CasdoorSource(cluster, source["initJob"], source["initData"])
        check_org_agreement(casdoor)
        eso = load_external_secrets(cluster / contract["externalSecretsDir"])
        for svc_container in containers:
            check_derived(svc_container, src_root, facts)
        for svc in contract.get("services") or []:
            check_service(cluster, casdoor, svc, eso)
        check_emitted_values(cluster, facts)
        check_coverage(cluster, contract, containers)
    except Incomplete as exc:
        print(f"  INCOMPLETE [env-derived] {exc}")
        print("       The derived check is the whole point of this gate; it did not run, so this")
        print("       is a FAILURE (rc 3), not a skip. Provide the checkouts (SERVICE_SRC_ROOT).")
        return 3
    except Unrecognised as exc:
        print(f"  FAIL [casdoor-source] {exc}")
        print("       This checker refuses to report agreement with a value it could not read.")
        return 2

    for line in PASSES:
        print(line)
    for line in FAILURES:
        print(line)
    print(f"  -- {len(PASSES)} ok, {len(FAILURES)} failed")
    return 1 if FAILURES else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
