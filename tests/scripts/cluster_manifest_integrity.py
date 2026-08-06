#!/usr/bin/env python3
"""Static referential-integrity checks over a specs/cluster tree.

Usage: cluster_manifest_integrity.py <path-to-specs/cluster>
Exit 0 = every check passed. Exit 1 = at least one check failed.

Driven by tests/scripts/test-cluster-manifest-integrity.sh, which also runs the
negative controls (each check is re-run against a deliberately corrupted copy of
the tree and must bite). See that script's header for the shipped defects this
gate exists to catch.

Deliberately dependency-light: PyYAML + bash only, so it runs in the
`python:3-slim` CI image with no cluster, no kubectl and no network.
"""
import json
import os
import re
import subprocess
import sys
import tempfile
from collections import defaultdict

import yaml

# ── allowlists ───────────────────────────────────────────────────────────────
# Namespaces the platform does NOT declare with a `kind: Namespace` manifest but
# which legitimately exist: upstream operator/add-on namespaces that their own
# ArgoCD Application creates via `CreateNamespace=true`, plus kube-system.
# A namespace that is neither declared here nor created in-repo is drift (e.g.
# the pre-rebrand `snapdragon-backend`, which nothing anywhere creates).
EXTERNAL_NAMESPACES = {
    "argocd",            # ArgoCD's own install namespace (apps/00-argocd bootstrap)
    "external-secrets",  # ESO operator (apps/03-external-secrets, CreateNamespace=true)
    "hugmesh-casdoor",   # Casdoor chart release ns (apps/05-casdoor, CreateNamespace=true)
    "ingress-nginx",     # public ingress controller chart
    "ingress-nginx-internal",  # in-cluster/PKI ingress controller chart
    "keda",              # KEDA autoscaler chart
    "kube-system",       # kubelet/metrics-server/CNI add-ons
    "kyverno",           # Kyverno policy engine chart
    "tigera-operator",   # Calico operator chart
    "velero",            # Velero backup chart
}

# Publicly-routed gateway targets whose Service object is NOT authored under
# manifests/: they are rendered by a Helm chart or an ApplicationSet template.
# Keyed "<service>.<namespace>" — narrow and explicit on purpose.
ROUTE_SERVICE_ALLOW = {
    # the four gateways themselves — charts/hugmesh-gateway renders their Service
    # from `.Values.instance.name` (apps/20-gateway-*.yaml, 22-gateway-superadmin).
    "hugmesh-pki-gateway.hugmesh-pki",
    "hugmesh-be-gateway.hugmesh-backend",
    "hugmesh-fe-gateway.hugmesh-frontend",
    "hugmesh-superadmin-gateway.hugmesh-pki",
    # per-instance game-server console, rendered by the 13c ApplicationSet.
    "games-instances-console.hugmesh-games-instances",
    # superadmin service-catalog UI, rendered by the service-catalog-builder
    # ApplicationSet (apps/54-service-catalog-builder.yaml).
    "hugmesh-superadmin-service-catalog-ui.hugmesh-frontend",
}

# `pki_int/issue/<role>` references whose issuing role is KNOWINGLY not created
# by vault-pki-init yet. Each must be documented as dark at its reference site.
PKI_ROLES_KNOWN_UNPROVISIONED = {
    # manifests/external-secrets/meshbridge-externalsecrets.yaml says so inline:
    # "Requires a `meshbridge-client` issuing role in the Vault PKI loop
    #  ... until then the Secret never materializes and the pod mounts it optional:".
    "meshbridge-client",
    # manifests/cassandra-hardening ships DARK behind a manual-sync Application
    # (apps/00a-cassandra-hardening.yaml: snapdragon.systems/ships: dark).
    "cassandra",
}

# Postgres workloads NOT covered by ADR-32's per-pod db-ingress isolation.
# These are pre-existing KNOWN GAPS, not approvals — recorded here so the check
# catches NEW drift (which is how mesh-bff-db slipped in) instead of being
# deleted for being red. Keyed "<app-label>.<namespace>".
DB_ISOLATION_KNOWN_GAPS = {
    # test-runner-only Akkoma federation peer; manifests/test-runner is deleted
    # from every prod tree (see the lint:prod-hygiene bake), so it never ships.
    "akkoma-peer-db.hugmesh-backend",
    # Casdoor's own Postgres pair. ADR-32 scoped itself to "the seven backend
    # BFF/federation Postgres pods" + route-access-db + Cassandra; the identity
    # provider's stores were never brought in. They remain reachable from every
    # pod in their namespace plus tier-ingress' cross-namespace from-set.
    # TODO(ADR-32 follow-up): give both a per-pod policy + a NotIn exclusion.
    "casdoor-pg.hugmesh-pki",
    "casdoor-games-pg.hugmesh-games",
}

# Distinct workload names that intentionally SHARE one MCS category, with the
# reason. docs/SECURITY.md's rule is "no two workloads may share one"; these two
# are Cassandra maintenance Jobs that must reach Cassandra's own category-labelled
# volumes, documented in SECURITY.md's "`cassandra` MCS note".
MCS_SHARED_OK = {
    "s0:c63": {"cassandra-bootstrap-roles", "cassandra-tls-keystore-builder"},
}

WORKLOAD_KINDS = ("Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob")

failures = []
notes = []


def fail(check, msg):
    failures.append((check, msg))


def ok(check, msg):
    notes.append((check, msg))


# ── loaders ──────────────────────────────────────────────────────────────────
class DupKeyLoader(yaml.SafeLoader):
    """SafeLoader that REJECTS duplicate mapping keys.

    Plain safe_load silently applies last-wins, which is exactly how two fused
    Kubernetes objects (duplicate apiVersion/kind/metadata/spec) slipped through
    review AND through `kustomize build` reporting only a vague complaint.
    """


def _no_dup(loader, node, deep=False):
    mapping = {}
    for key_node, value_node in node.value:
        key = loader.construct_object(key_node, deep=deep)
        if key in mapping:
            raise yaml.constructor.ConstructorError(
                None, None,
                "duplicate key %r (line %d)" % (key, key_node.start_mark.line + 1),
                node.start_mark)
        mapping[key] = loader.construct_object(value_node, deep=deep)
    return mapping


DupKeyLoader.add_constructor(yaml.resolver.BaseResolver.DEFAULT_MAPPING_TAG, _no_dup)


_DUMP_CACHE = {}


def dump_of(doc):
    key = id(doc)
    if key not in _DUMP_CACHE:
        _DUMP_CACHE[key] = yaml.safe_dump(doc)
    return _DUMP_CACHE[key]


def yaml_files(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        # Helm chart templates are Go templates, not YAML — excluded by design.
        if os.sep + "charts" + os.sep in dirpath + os.sep and "templates" in dirpath.split(os.sep):
            continue
        for name in sorted(filenames):
            if name.endswith((".yaml", ".yml")):
                yield os.path.join(dirpath, name)


_DOC_CACHE = {}
_TEXT_CACHE = {}


def docs_of(path):
    """Parsed documents of one file. Cached: nine checks walk the same ~430 files
    and a re-parse each time makes the gate too slow to sit in the lint stage."""
    if path not in _DOC_CACHE:
        try:
            _DOC_CACHE[path] = [d for d in yaml.safe_load_all(open(path, encoding="utf-8"))
                                if isinstance(d, dict)]
        except Exception:
            _DOC_CACHE[path] = []
    return _DOC_CACHE[path]


def text_of(path):
    if path not in _TEXT_CACHE:
        _TEXT_CACHE[path] = open(path, encoding="utf-8", errors="replace").read()
    return _TEXT_CACHE[path]


# ── 1/2) YAML validity + duplicate keys ──────────────────────────────────────
def check_yaml(root):
    scanned = parse_bad = dup_bad = 0
    for path in yaml_files(root):
        scanned += 1
        rel = os.path.relpath(path, root)
        try:
            list(yaml.safe_load_all(open(path, encoding="utf-8")))
        except Exception as exc:
            parse_bad += 1
            fail("[yaml-parse]", "%s does not parse: %s" % (rel, str(exc).replace("\n", " ")[:200]))
            continue
        try:
            list(yaml.load_all(open(path, encoding="utf-8"), DupKeyLoader))
        except yaml.constructor.ConstructorError as exc:
            dup_bad += 1
            fail("[yaml-duplicate-key]",
                 "%s has a duplicate mapping key (two objects fused into one document?): %s"
                 % (rel, exc.problem))
        except Exception as exc:
            dup_bad += 1
            fail("[yaml-duplicate-key]", "%s: %s" % (rel, str(exc).replace("\n", " ")[:200]))
    if not parse_bad:
        ok("[yaml-parse]", "all %d YAML files under specs/cluster parse" % scanned)
    if not dup_bad:
        ok("[yaml-duplicate-key]", "no duplicate mapping keys in %d YAML files" % scanned)


# ── 3) namespace referential integrity ───────────────────────────────────────
NS_URI_RE = re.compile(r"[a-z0-9][a-z0-9.-]*\.([a-z0-9][a-z0-9-]*)\.svc\.cluster\.local")


def check_namespaces(root):
    created = set()
    for path in yaml_files(root):
        for d in docs_of(path):
            if d.get("kind") == "Namespace":
                created.add(d.get("metadata", {}).get("name"))
    known = created | EXTERNAL_NAMESPACES
    used = defaultdict(set)
    for path in yaml_files(root):
        rel = os.path.relpath(path, root)
        for d in docs_of(path):
            ns = (d.get("metadata") or {}).get("namespace")
            if ns:
                used[ns].add(rel)
            if d.get("kind") == "Application":
                dns = ((d.get("spec") or {}).get("destination") or {}).get("namespace")
                if dns:
                    used[dns].add(rel)
            if d.get("kind") == "Kustomization" and d.get("namespace"):
                used[d["namespace"]].add(rel)
        text = text_of(path)
        for m in NS_URI_RE.finditer(text):
            used[m.group(1)].add(rel)
    bad = 0
    for ns in sorted(used):
        if "$" in ns or "{" in ns:      # ${BUILD_NAMESPACE} style placeholders
            continue
        if ns in known:
            continue
        bad += 1
        fail("[namespace]",
             "namespace %r is referenced but NOTHING creates it (no kind: Namespace, "
             "not an upstream add-on ns); referenced from: %s"
             % (ns, ", ".join(sorted(used[ns])[:4])))
    if not bad:
        ok("[namespace]", "every referenced namespace is created in-repo or a known add-on ns "
                          "(%d in-repo, %d external)" % (len(created), len(EXTERNAL_NAMESPACES)))


# ── 4) gateway route uri -> Service resolution ───────────────────────────────
URI_RE = re.compile(r"^https?://([a-z0-9][a-z0-9.-]*?)\.([a-z0-9][a-z0-9-]*)\.svc\.cluster\.local(?::\d+)?/?$")


def _services(root):
    svc = set()
    for dirpath, _dn, filenames in os.walk(root):
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in filenames:
            if not name.endswith((".yaml", ".yml")):
                continue
            for d in docs_of(os.path.join(dirpath, name)):
                if d.get("kind") == "Service":
                    m = d.get("metadata") or {}
                    svc.add("%s.%s" % (m.get("name"), m.get("namespace") or defns))
    return svc


def _gateways(root):
    """-> {gateway-instance-name: [route dicts]} from the four gateway Applications."""
    out = {}
    appdir = os.path.join(root, "apps")
    if not os.path.isdir(appdir):
        return out
    for name in sorted(os.listdir(appdir)):
        if "gateway" not in name or not name.endswith(".yaml"):
            continue
        for d in docs_of(os.path.join(appdir, name)):
            if d.get("kind") != "Application":
                continue
            values = (((d.get("spec") or {}).get("source") or {}).get("helm") or {}).get("values")
            if not isinstance(values, str):
                continue
            try:
                v = yaml.safe_load(values)
            except Exception:
                continue
            inst = ((v or {}).get("instance") or {}).get("name")
            if inst:
                out[inst] = (v or {}).get("routes") or []
    return out


def check_route_services(root):
    svc = _services(root)
    bad = 0
    total = 0
    for gw, routes in sorted(_gateways(root).items()):
        for r in routes:
            uri = (r or {}).get("uri") or ""
            m = URI_RE.match(uri)
            if not m:
                continue          # non-cluster (lb://, external https://…) — out of scope
            total += 1
            key = "%s.%s" % (m.group(1), m.group(2))
            if key in svc or key in ROUTE_SERVICE_ALLOW:
                continue
            bad += 1
            fail("[route-service]",
                 "gateway %s route %r targets %s but no Service %r exists in namespace %r"
                 % (gw, r.get("id"), uri, m.group(1), m.group(2)))
    if not bad:
        ok("[route-service]", "all %d in-cluster gateway route targets resolve to a real Service" % total)


# ── 5) route-access seed rows -> real gateway ids ────────────────────────────
ROW_RE = re.compile(r"^\s*\('([a-z0-9][a-z0-9-]*)'\s*,", re.M)


def check_route_access(root):
    schema = os.path.join(root, "manifests", "route-access", "initdb", "20-schema.sql")
    if not os.path.exists(schema):
        fail("[route-access-gateway]", "missing %s" % schema)
        return
    gateways = set(_gateways(root))
    if not gateways:
        fail("[route-access-gateway]", "could not read any gateway instance name from apps/*gateway*.yaml")
        return
    seen = defaultdict(int)
    for m in ROW_RE.finditer(open(schema, encoding="utf-8").read()):
        seen[m.group(1)] += 1
    bad = 0
    for gw in sorted(seen):
        if gw in gateways:
            continue
        bad += 1
        fail("[route-access-gateway]",
             "20-schema.sql seeds %d gateway_route_access row(s) for gateway id %r, which is not "
             "one of the deployed gateways (%s). Each gateway loads ONLY its own rows and "
             "default-denies a route with zero allow rows, so those rows are dead authz."
             % (seen[gw], gw, ", ".join(sorted(gateways))))
    if not bad:
        ok("[route-access-gateway]",
           "all %d seeded gateway ids match a deployed gateway" % len(seen))


# ── 6) Vault PKI issuing roles ───────────────────────────────────────────────
VAULT_STUB = r"""
set -u
vault() {
  case "${1:-}" in
    status) return 0 ;;
    "secrets") echo '{"pki_int/":{}}' ; return 0 ;;
    read)
      case "$*" in
        *-field=certificate*) echo "STUBCERT" ;;
      esac
      return 0 ;;
    write)
      case "${2:-}" in
        */roles/*) printf '%s\n' "${2##*/roles/}" >> "$ROLE_OUT" ;;
      esac
      return 0 ;;
  esac
  return 0
}
sleep() { return 0; }
export -f vault 2>/dev/null || true
. "$SCRIPT_PATH"
"""


def check_pki_roles(root):
    cm = os.path.join(root, "manifests", "vault-pki", "pki-init-configmap.yaml")
    if not os.path.exists(cm):
        fail("[pki-roles]", "missing %s" % cm)
        return
    try:
        script = yaml.safe_load(open(cm, encoding="utf-8"))["data"]["init-pki.sh"]
    except Exception as exc:
        fail("[pki-roles]", "could not extract init-pki.sh from the ConfigMap: %s" % exc)
        return

    # Run the REAL script under a vault stub so BASH — not a regex — decides what
    # the role word-list expands to. This is what catches the fused for-loop:
    # `bash -n` is happy with it because `for`/`app`/`in` are ordinary words
    # inside a for-list, and only expansion reveals the junk roles.
    with tempfile.TemporaryDirectory() as td:
        sp = os.path.join(td, "init-pki.sh")
        ro = os.path.join(td, "roles.txt")
        open(sp, "w", encoding="utf-8").write(script)
        open(ro, "w").close()
        env = dict(os.environ, SCRIPT_PATH=sp, ROLE_OUT=ro)
        proc = subprocess.run(["bash", "-c", VAULT_STUB], env=env,
                              capture_output=True, text=True, timeout=60)
        created = [line.strip() for line in open(ro, encoding="utf-8") if line.strip()]
    if not created:
        fail("[pki-roles]", "executing init-pki.sh under a vault stub created ZERO issuing roles "
                            "(stderr: %s)" % proc.stderr.strip()[:300])
        return

    bad = 0
    # (a) no shell keyword / non-identifier ever becomes an issuing role. A role
    #     named `for` mints cluster-CA-chained server+client certs for CN `for`.
    # `app` and `entry` are the loop VARIABLE names this file has used over time;
    # a fused header puts the variable name itself into the word list, so both
    # stay listed even after a rename.
    shellish = {"for", "in", "do", "done", "app", "entry", "then", "fi", "else",
                "while", "case", "esac"}
    for role in created:
        if role in shellish or not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", role):
            bad += 1
            fail("[pki-roles]",
                 "vault-pki-init would create issuing role %r — a shell keyword/garbage token, "
                 "not a workload. It mints server+client certs off the cluster CA for an "
                 "identity nobody audits (two `for <var> in ...` headers line-continued into one?)"
                 % role)
    # (b) no duplicates (a duplicate means two loops both claim the same role).
    dupes = {r for r in created if created.count(r) > 1}
    for role in sorted(dupes):
        bad += 1
        fail("[pki-roles]", "issuing role %r is written more than once by init-pki.sh" % role)

    # (c) every pki_int/issue/<role> the manifests reference must be created.
    referenced = set()
    for path in yaml_files(root):
        for d in docs_of(path):
            if d.get("kind") != "VaultDynamicSecret":
                continue
            p = (d.get("spec") or {}).get("path") or ""
            if p.startswith("pki_int/issue/"):
                referenced.add(p.split("/", 2)[2])
    missing = sorted(referenced - set(created) - PKI_ROLES_KNOWN_UNPROVISIONED)
    for role in missing:
        bad += 1
        fail("[pki-roles]",
             "a VaultDynamicSecret requests pki_int/issue/%s but vault-pki-init never creates "
             "that role — the Secret can never materialize" % role)
    if not bad:
        ok("[pki-roles]", "init-pki.sh creates %d well-formed issuing roles covering all %d "
                          "referenced pki_int/issue/* paths" % (len(created), len(referenced)))


# ── 7) *-mtls Secrets: every consumer has a provider ─────────────────────────
def check_mtls_secrets(root):
    provided = set()
    consumed = defaultdict(set)
    for dirpath, _dn, filenames in os.walk(root):
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in filenames:
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            for d in docs_of(path):
                meta = d.get("metadata") or {}
                ns = meta.get("namespace") or defns
                if d.get("kind") == "ExternalSecret":
                    target = ((d.get("spec") or {}).get("target") or {})
                    provided.add("%s.%s" % (target.get("name") or meta.get("name"), ns))
                elif d.get("kind") in WORKLOAD_KINDS:
                    dumped = dump_of(d)
                    for m in re.finditer(r"secretName:\s*([A-Za-z0-9._-]+)", dumped):
                        if m.group(1).endswith("-mtls"):
                            consumed["%s.%s" % (m.group(1), ns)].add(rel)
    bad = 0
    for key in sorted(consumed):
        if key in provided:
            continue
        bad += 1
        name, _, ns = key.rpartition(".")
        fail("[mtls-secret]",
             "workload(s) %s mount Secret %r in namespace %r but NO ExternalSecret targets it — "
             "the mount is `optional:`, so the pod starts happily WITHOUT TLS and nothing reports it"
             % (", ".join(sorted(consumed[key])), name, ns))
    if not bad:
        ok("[mtls-secret]", "all %d mounted *-mtls Secrets have an ExternalSecret provider "
                            "in the same namespace" % len(consumed))


# ── 8) SELinux MCS category uniqueness ───────────────────────────────────────
MCS_RE = re.compile(r'level:\s*"?(s0:c[0-9]+)"?')


def check_mcs(root):
    by_level = defaultdict(set)
    for path in yaml_files(root):
        rel = os.path.relpath(path, root)
        for d in docs_of(path):
            if d.get("kind") not in WORKLOAD_KINDS:
                continue
            name = (d.get("metadata") or {}).get("name")
            for m in MCS_RE.finditer(dump_of(d)):
                by_level[m.group(1)].add((name, rel))
    bad = 0
    for level in sorted(by_level, key=lambda x: int(x.split("c")[1])):
        workloads = {n for n, _ in by_level[level]}
        if len(workloads) < 2:
            continue
        if MCS_SHARED_OK.get(level) == workloads:
            continue
        bad += 1
        fail("[mcs]",
             "SELinux MCS category %s is claimed by %d DIFFERENT workloads (%s). docs/SECURITY.md "
             "§3: 'Each MCS category is unique — no two workloads may share one, so a compromised "
             "pod cannot read another's category-isolated volumes.'"
             % (level, len(workloads),
                "; ".join("%s (%s)" % (n, f) for n, f in sorted(by_level[level]))))
    if not bad:
        ok("[mcs]", "all %d SELinux MCS categories map to exactly one workload" % len(by_level))


# ── 9) ADR-32: every Postgres pod is isolated, and STAYS isolated ────────────
def check_db_isolation(root):
    """A DB pod needs BOTH halves or it has no isolation at all.

    k8s NetworkPolicy is additive with no deny: manifests/networkpolicy/
    tier-ingress.yaml admits the whole namespace (+ frontend + ingress) to every
    pod it selects, so a per-pod db-ingress policy only bites once tier-ingress
    STOPS selecting that pod via its `app NotIn [...]` term. Miss either half —
    mesh-bff-db shipped missing both — and the store is reachable on 5432 from
    every pod in the tier, straight past the BFF authz it sits behind.
    """
    dbs = {}
    per_pod = defaultdict(set)
    excluded = defaultdict(set)
    broad = set()
    for dirpath, _dn, filenames in os.walk(root):
        if os.sep + "charts" + os.sep in dirpath + os.sep:
            continue
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in filenames:
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            for d in docs_of(path):
                meta = d.get("metadata") or {}
                ns = meta.get("namespace") or defns
                kind = d.get("kind")
                if kind in ("Deployment", "StatefulSet"):
                    tpl = ((d.get("spec") or {}).get("template") or {})
                    labels = (tpl.get("metadata") or {}).get("labels") or {}
                    ports = [p.get("containerPort")
                             for c in ((tpl.get("spec") or {}).get("containers") or [])
                             for p in (c.get("ports") or [])]
                    if 5432 in ports and labels.get("app"):
                        dbs[(labels["app"], ns)] = os.path.relpath(path, root)
                elif kind == "NetworkPolicy":
                    sel = (d.get("spec") or {}).get("podSelector") or {}
                    ml = sel.get("matchLabels") or {}
                    me = sel.get("matchExpressions") or []
                    if ml.get("app"):
                        per_pod[ns].add(ml["app"])
                    if not ml and not me:
                        broad.add(ns)
                    for expr in me:
                        if expr.get("key") == "app" and expr.get("operator") == "NotIn":
                            excluded[ns] |= set(expr.get("values") or [])
                            broad.add(ns)
    bad = 0
    for (app, ns), rel in sorted(dbs.items()):
        if "%s.%s" % (app, ns) in DB_ISOLATION_KNOWN_GAPS:
            continue
        problems = []
        if app not in per_pod.get(ns, set()):
            problems.append("no per-pod db-ingress NetworkPolicy selects app=%s" % app)
        if ns in broad and app not in excluded.get(ns, set()):
            problems.append("not in the tier-ingress `app NotIn [...]` exclusion, so the broad "
                            "namespace+frontend policy re-admits it")
        if problems:
            bad += 1
            fail("[db-isolation]",
                 "Postgres workload %s (ns %s, %s) is not isolated: %s"
                 % (app, ns, rel, "; ".join(problems)))
    if not bad:
        ok("[db-isolation]", "all %d in-scope Postgres workloads have a per-pod policy AND are "
                             "excluded from the broad tier policy"
                             % (len(dbs) - len(DB_ISOLATION_KNOWN_GAPS)))


# ── 10) SERVICE-only internal ingest surfaces are not externally reachable ───
# gateway_route_access is Ant-matched and the DECIDING rule is the LONGEST
# matching url_pattern (hugmesh-gateway GatewayRouteAccessService.decide:
# longest match wins, explicit deny wins inside that set, and a path with NO
# matching pattern at all returns NO_RULE => the request is FORWARDED on the
# coarse authenticated() floor). So a `/bff/<tier>/**` tier floor SUBSUMES every
# `/bff/<tier>/internal/**` receiver beneath it, and an internal prefix that no
# row mentions is not "unroutable" — it is UNGOVERNED, which is weaker still.
#
# Three separate comments in this tree asserted such surfaces were "NOT routed
# here"; all three were matched by a live `**` route predicate. This check makes
# the assertion mechanical instead of editorial.
def _ant_match(pattern, path):
    """Minimal Spring AntPathMatcher subset: `**` spans segments, `*` does not."""
    pseg, tseg = pattern.split("/"), path.split("/")

    def walk(i, j):
        while i < len(pseg):
            if pseg[i] == "**":
                if i + 1 == len(pseg):
                    return True
                for k in range(j, len(tseg) + 1):
                    if walk(i + 1, k):
                        return True
                return False
            if j >= len(tseg):
                return False
            if pseg[i] != tseg[j] and "*" not in pseg[i]:
                return False
            if "*" in pseg[i] and pseg[i] != "*":
                return False        # partial globs unused in this seed
            i += 1
            j += 1
        return j == len(tseg)

    return walk(0, 0)


# Concrete probe paths for the SERVICE-only receivers. Each MUST be denied (or
# unreachable) through every gateway. Two sources feed this set:
#   (a) DISCOVERED — any in-cluster URL in the tree with an `internal` path
#       segment (that is how the meshbridge -> user-bff / mesh-bff legs are
#       declared), so a NEW internal receiver is covered the day it is wired; and
#   (b) DECLARED below — receivers configured from a base-URL + path in code, so
#       no full URL exists in a manifest to discover.
INTERNAL_SURFACES_DECLARED = {
    # admin-bff's internal API. SecurityConfig.java:208 permitAll()s the whole
    # prefix app-side (InternalTokenWebFilter is the only wall and it is inert
    # when app.internal.token is unset), and the gateway reaches it via the
    # /bff/** admin-bff catch-all.
    "/bff/internal/session/introspect",
    "/bff/internal/accounts/ensure",
}
INTERNAL_SEG_RE = re.compile(
    r"https?://[a-z0-9][a-z0-9.-]*\.svc\.cluster\.local(?::\d+)?(/[A-Za-z0-9_./{}-]*)")
ROW_FULL_RE = re.compile(
    r"^\s*\('([a-z0-9-]+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)", re.M)


# ── 10) env secretKeyRef -> ExternalSecret KEY-level integrity + the MFA
#        factor-key posture pin ──────────────────────────────────────────────
# Two defect classes nothing else here sees:
#   a) a secretKeyRef whose Secret IS produced by an ExternalSecret but whose KEY
#      is not among the keys that ExternalSecret materializes. With the ref now
#      REQUIRED that typo is boot-blocking: kubelet holds the pod in
#      CreateContainerConfigError forever, and every static gate stayed green on
#      exactly this plant (key `factor-keyX`) before this check existed.
#      Effective keys are the target.template.data keys when a template is
#      present (the template REPLACES the default materialization — casdoor-db
#      declares data key `password` but templates `username`+`password`, and the
#      username ref is legitimate), else the data[].secretKey set; ExternalSecrets
#      using dataFrom are opaque to a static read and are skipped, counted.
#   b) the admin-bff APP_MFA_FACTOR_KEY ref regressing to `optional: true`. The
#      manifest arms APP_CASDOOR_MFA_ENABLED, so the factor key is load-bearing:
#      an absent Secret must surface at the Kubernetes layer, not as a booted pod
#      whose cipher is inert and whose TOTP enrolls silently refuse. Re-planting
#      `optional: true` passed every gate green before this check existed, and
#      docs/MFA-ROLLOUT.md §4.1 now documents the required posture — this pins it.
# Refs to Secret names NO ExternalSecret declares (vault-bootstrap, operator-
# provided oauth secrets, test-runner bootstrap) are legitimately out-of-band for
# a static read: they are COUNTED in the pass note, never silently skipped.
def check_secret_key_refs(root):
    declared = {}
    refs = []
    for dirpath, _dn, filenames in os.walk(root):
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in filenames:
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, root)
            for d in docs_of(path):
                meta = d.get("metadata") or {}
                ns = meta.get("namespace") or defns
                if d.get("kind") == "ExternalSecret":
                    spec = d.get("spec") or {}
                    tgt = ((spec.get("target") or {}).get("name")) or meta.get("name")
                    tmpl = (((spec.get("target") or {}).get("template") or {}).get("data")) or {}
                    keys = set(tmpl) if tmpl else \
                        {e.get("secretKey") for e in (spec.get("data") or []) if isinstance(e, dict)} - {None}
                    declared[(tgt, ns)] = (keys, bool(spec.get("dataFrom")))
                def walk(o):
                    if isinstance(o, dict):
                        vf = o.get("valueFrom") or {}
                        if isinstance(vf, dict) and isinstance(vf.get("secretKeyRef"), dict) and "name" in o:
                            refs.append((rel, ns, o.get("name"), vf["secretKeyRef"]))
                        for v in o.values():
                            walk(v)
                    elif isinstance(o, list):
                        for i in o:
                            walk(i)
                walk(d)
    bad = out_of_band = opaque = 0
    factor_refs = []
    for rel, ns, env_name, ref in refs:
        rn, rk = ref.get("name"), ref.get("key")
        if env_name == "APP_MFA_FACTOR_KEY":
            factor_refs.append((rel, ns, ref))
        entry = declared.get((rn, ns))
        if entry is None:
            out_of_band += 1
            continue
        keys, has_datafrom = entry
        if has_datafrom:
            opaque += 1
            continue
        if rk not in keys:
            bad += 1
            fail("[secret-key]",
                 "%s env %s reads Secret %r key %r, but the ExternalSecret targeting it "
                 "materializes only %s — the key can NEVER exist; a non-optional ref "
                 "holds the pod in CreateContainerConfigError forever, an optional one "
                 "boots the pod without the value and nothing reports it"
                 % (rel, env_name, rn, rk, sorted(keys)))
    if not factor_refs:
        fail("[mfa-factor-key]",
             "no workload under specs/cluster carries an APP_MFA_FACTOR_KEY secretKeyRef at all — "
             "the posture pin below has nothing to hold, and admin-bff's armed MFA has no key source")
    for rel, ns, ref in factor_refs:
        problems = []
        if ref.get("name") != "admin-bff-mfa" or ref.get("key") != "factor-key":
            problems.append("must reference Secret admin-bff-mfa key factor-key, got %r/%r"
                            % (ref.get("name"), ref.get("key")))
        # Truthy-string tolerant: `optional: "true"` is not a bool to PyYAML, and while the
        # API server would reject the string at apply time, this gate must red on the INTENT
        # in the file rather than report a false 'REQUIRED (no optional:)' pass note.
        if ref.get("optional") in (True, "true", "True", "TRUE", "yes", "on", "1"):
            problems.append("carries `optional: true` — the manifest arms APP_CASDOOR_MFA_ENABLED, so "
                            "the required posture (docs/MFA-ROLLOUT.md §4.1) is what makes an absent "
                            "Secret a loud scheduling failure instead of a silently inert MFA cipher")
        if problems:
            fail("[mfa-factor-key]", "%s: %s" % (rel, "; ".join(problems)))
        else:
            ok("[mfa-factor-key]",
               "%s APP_MFA_FACTOR_KEY -> admin-bff-mfa/factor-key, REQUIRED (no optional:)" % rel)
    if not bad:
        ok("[secret-key]",
           "all %d env secretKeyRefs whose Secret an ExternalSecret declares read a key it "
           "actually materializes (%d out-of-band Secret name(s) not statically checkable, "
           "%d dataFrom-opaque)" % (len(refs) - out_of_band - opaque, out_of_band, opaque))


def check_internal_surfaces(root):
    probes = set(INTERNAL_SURFACES_DECLARED)
    for path in yaml_files(root):
        for m in INTERNAL_SEG_RE.finditer(text_of(path)):
            p = m.group(1)
            if "internal" in p.strip("/").split("/"):
                probes.add(p)
    schema = os.path.join(root, "manifests", "route-access", "initdb", "20-schema.sql")
    rows = []
    if os.path.exists(schema):
        for m in ROW_FULL_RE.finditer(open(schema, encoding="utf-8").read()):
            rows.append((m.group(1), m.group(2), m.group(4) == "true"))
    if not rows:
        fail("[internal-surface]", "could not parse any gateway_route_access row from %s" % schema)
        return

    bad = 0
    checked = 0
    for gw, routes in sorted(_gateways(root).items()):
        patterns = [r.get("path") for r in routes if isinstance(r, dict) and r.get("path")]
        gw_rows = [(p, a) for (g, p, a) in rows if g == gw]
        for probe in sorted(probes):
            if not any(_ant_match(pat, probe) for pat in patterns):
                continue          # this gateway does not route the surface at all
            checked += 1
            matching = [(p, a) for (p, a) in gw_rows if _ant_match(p, probe)]
            if not matching:
                bad += 1
                fail("[internal-surface]",
                     "%s routes the SERVICE-only surface %s but NO gateway_route_access row "
                     "matches it — decide() returns NO_RULE and the gateway FORWARDS it on the "
                     "coarse authenticated() floor. Add an explicit `allow=false` row."
                     % (gw, probe))
                continue
            best = max(len(p) for (p, _a) in matching)
            deciding = [(p, a) for (p, a) in matching if len(p) == best]
            if not any(a is False for (_p, a) in deciding):
                bad += 1
                fail("[internal-surface]",
                     "%s routes the SERVICE-only surface %s and its DECIDING (longest, %r) "
                     "route-access rule is an ALLOW — every holder of that role reaches the "
                     "internal receiver from outside. Add an explicit `allow=false` row at a "
                     "pattern at least as specific." % (gw, probe, deciding[0][0]))
    if not bad:
        ok("[internal-surface]",
           "all %d routed SERVICE-only internal surfaces are explicitly denied at their gateway "
           "(%d distinct probe paths)" % (checked, len(probes)))


# ── 11) embedded JSON inside ConfigMap/Secret values ─────────────────────────
# A ConfigMap key becomes a FILE at the mount point, so its value is a whole
# document in ANOTHER language that the consuming process — not Kubernetes —
# parses. Nothing above could see inside one: [yaml-parse] only proves the block
# scalar is a well-formed YAML *string*, which it is even when the JSON it
# carries is garbage, and kubectl/kustomize apply a ConfigMap without ever
# looking at its values.
#
# manifests/casdoor/init-data-configmap.yaml shipped that way: a botched #451
# merge concatenated the whole pre-rebrand `owner: "snapdragon"` roles array in
# front of the rebranded one, leaving what had been the array's last element as
# an interior element with no trailing comma —
#     Expecting ',' delimiter: line 42 column 5 (char 4764)
# Casdoor imports init_data.json wholesale on boot, so the ENTIRE identity seed
# (the organization, every role including ROLE_IMAGE_BUILDER, every svc-* user)
# was silently skipped while the ConfigMap around it stayed perfectly valid YAML
# and this gate stayed green.
#
# GENERIC BY CONSTRUCTION: any key ending `.json`, in `data` or `stringData`, on
# any ConfigMap or Secret anywhere in the tree. There is no filename, key name
# or path list to extend — a ConfigMap added tomorrow is covered the day it
# lands. Values are NEVER echoed (only object, key and parse position), so a
# Secret's stringData cannot leak into a CI log.
EMBEDDED_JSON_SECTIONS = ("data", "stringData")


def _json_no_dup(pairs):
    """object_pairs_hook that REJECTS duplicate object keys.

    json.loads applies silent last-wins, the same failure mode DupKeyLoader
    exists for on the YAML side: two entries fused or pasted together parse
    cleanly and one of them just disappears from what the consumer reads.
    """
    seen = {}
    for key, value in pairs:
        if key in seen:
            raise ValueError("duplicate object key %r" % key)
        seen[key] = value
    return seen


def check_embedded_json(root):
    scanned = parse_bad = dup_bad = 0
    for path in yaml_files(root):
        rel = os.path.relpath(path, root)
        for d in docs_of(path):
            if d.get("kind") not in ("ConfigMap", "Secret"):
                continue
            name = (d.get("metadata") or {}).get("name") or "<unnamed>"
            for section in EMBEDDED_JSON_SECTIONS:
                values = d.get(section)
                if not isinstance(values, dict):
                    continue
                for key in sorted(values):
                    value = values[key]
                    if not key.endswith(".json") or not isinstance(value, str):
                        continue
                    scanned += 1
                    where = "%s %s/%s %s[%r]" % (rel, d.get("kind"), name, section, key)
                    try:
                        json.loads(value)
                    except ValueError as exc:
                        parse_bad += 1
                        fail("[json-parse]",
                             "%s is NOT valid JSON: %s. That value is a FILE at the mount "
                             "point and the consumer parses it whole, so an unparseable "
                             "document means the consumer reads NOTHING from it — which "
                             "is how the Casdoor seed silently lost its entire identity "
                             "import. The ConfigMap around it is valid YAML, which is why "
                             "[yaml-parse] cannot see this."
                             % (where, str(exc).replace("\n", " ")[:200]))
                        continue
                    try:
                        json.loads(value, object_pairs_hook=_json_no_dup)
                    except ValueError as exc:
                        dup_bad += 1
                        fail("[json-duplicate-key]",
                             "%s parses but has a %s — JSON is silently last-wins, so the "
                             "earlier entry is dropped from what the consumer reads and "
                             "nothing reports it (two objects pasted together by a merge?)"
                             % (where, str(exc).replace("\n", " ")[:200]))
    if not parse_bad:
        ok("[json-parse]",
           "all %d embedded *.json values in ConfigMap/Secret data parse" % scanned)
    if not dup_bad:
        ok("[json-duplicate-key]",
           "no duplicate object key in %d embedded *.json values" % scanned)


def main():
    if len(sys.argv) != 2:
        print(__doc__)
        return 2
    root = sys.argv[1]
    if not os.path.isdir(root):
        print("no such tree: %s" % root)
        return 2
    check_yaml(root)
    check_namespaces(root)
    check_route_services(root)
    check_route_access(root)
    check_pki_roles(root)
    check_mtls_secrets(root)
    check_secret_key_refs(root)
    check_mcs(root)
    check_db_isolation(root)
    check_internal_surfaces(root)
    check_embedded_json(root)
    for check, msg in notes:
        print("  PASS %-24s %s" % (check, msg))
    for check, msg in failures:
        print("  FAIL %-24s %s" % (check, msg))
    print()
    print("== %d checks passed, %d findings ==" % (len(notes), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
