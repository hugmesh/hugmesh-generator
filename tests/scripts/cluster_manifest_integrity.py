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
# the pre-rebrand backend namespace, which nothing anywhere creates).
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
    # ── REMOVED 2026-08-26: "hugmesh-superadmin-service-catalog-ui.hugmesh-frontend",
    # exempted here with the rationale "rendered by the service-catalog-builder
    # ApplicationSet (apps/54-service-catalog-builder.yaml)". EVERY CLAUSE OF THAT
    # SENTENCE WAS FALSE. apps/54 is `kind: Application`, not an ApplicationSet — it
    # has no generator and no template, so it renders nothing per-anything. Its
    # `source.path` is manifests/service-catalog-builder, whose kustomization lists
    # exactly one resource (namespace-and-netpol.yaml): a Namespace and a
    # default-deny NetworkPolicy. No Service, no Deployment, nothing that could
    # produce one. The Service simply did not exist, the superadmin gateway's
    # service-catalog route resolved to nothing, and this entry is what kept the gate
    # green about it for weeks.
    #
    # A false exemption is worse than a missing check: the check RAN, PASSED, and
    # printed a number that counted this route as resolved. The Deployment + Service
    # now exist (manifests/superadmin-service-catalog-ui/), so nothing needs
    # exempting — [route-service] resolves it for real.
    #
    # RULE FOR THIS SET, learned here: an entry's rationale must name a file whose
    # CONTENT renders the Service. Before adding one, open that file and confirm it
    # has a template that emits `kind: Service`. "An ApplicationSet somewhere makes
    # it" is not evidence; it is what this entry said.
}

# `pki_int/issue/<role>` references whose issuing role is KNOWINGLY not created
# by vault-pki-init yet. Each must be documented as dark at its reference site.
PKI_ROLES_KNOWN_UNPROVISIONED = {
    # manifests/external-secrets/meshbridge-externalsecrets.yaml says so inline:
    # "Requires a `meshbridge-client` issuing role in the Vault PKI loop
    #  ... until then the Secret never materializes and the pod mounts it optional:".
    "meshbridge-client",
    # manifests/cassandra-hardening ships DARK behind a manual-sync Application
    # (apps/00a-cassandra-hardening.yaml: hugmesh.net/ships: dark).
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
    # casdoor-pg / casdoor-games-pg USED TO SIT HERE. ADR-32 had scoped itself to
    # the backend BFF/federation Postgres pods + route-access-db + Cassandra, so
    # the identity provider's own stores stayed reachable from every pod in their
    # namespace plus tier-ingress' cross-namespace from-set — carried as a TODO on
    # this list rather than fixed. Both now get the standard treatment (a per-pod
    # policy in networkpolicy/db-ingress.yaml + the paired `app NotIn` exclusion in
    # tier-ingress.yaml), so the check enforces them like every other database and
    # nothing needs exempting. Do not re-add an entry here to make a red go green:
    # this set exists so NEW drift is caught, and every entry left in it is a hole
    # that is still open.
}

# Distinct workload names that intentionally SHARE one MCS category, with the
# reason. docs/SECURITY.md's rule is "no two workloads may share one"; these two
# are Cassandra maintenance Jobs that must reach Cassandra's own category-labelled
# volumes, documented in SECURITY.md's "`cassandra` MCS note".
MCS_SHARED_OK = {
    # cassandra-bootstrap was `cassandra-bootstrap-roles` while it lived in the
    # dark cassandra-hardening overlay; it is now the LIVE keyspace+role bootstrap
    # (manifests/cassandra-init). Same workload, same reason for the shared
    # category — only the name changed.
    "s0:c63": {"cassandra-bootstrap", "cassandra-tls-keystore-builder"},
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
def sql_without_comments(text):
    """The SQL with its `--` line comments removed, single-quoted literals respected.

    A COMMENTED-OUT SEED ROW IS NOT A SEED ROW. Matching a `('<gw>', '<pattern>',`
    row against the raw file text lets

        -- DISABLED ('hugmesh-superadmin-gateway', '/superadmin/service-catalog/**', ...

    satisfy a check whose entire purpose is that the row is SEEDED: initdb never
    executes it, decide() returns NO_RULE, and the gateway forwards on the coarse
    authenticated() floor. That comment-token inversion is a standing trap in this
    repo — the fix is to strip comments BEFORE matching, not to trust an anchor
    alone (ROW_RE below anchors as well; belt and braces, since both are cheap).

    The single-quote state machine is not decoration: a route pattern or a
    rationale string may legitimately contain `--`, and cutting at the first one
    would silently truncate a real row and turn this into a false PASS in the other
    direction. `''` inside a literal is SQL's escaped quote and does not end it.
    """
    out = []
    for line in text.splitlines():
        in_str = False
        cut = None
        i = 0
        while i < len(line):
            ch = line[i]
            if in_str:
                if ch == "'":
                    if i + 1 < len(line) and line[i + 1] == "'":
                        i += 1          # '' — an escaped quote, still inside
                    else:
                        in_str = False
            elif ch == "'":
                in_str = True
            elif ch == "-" and i + 1 < len(line) and line[i + 1] == "-":
                cut = i
                break
            i += 1
        out.append(line if cut is None else line[:cut])
    return "\n".join(out)


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
                    spec = d.get("spec") or {}
                    # INGRESS-AXIS ONLY. Ingress and Egress are independent axes, so an
                    # Egress-only policy naming a DB pod proves NOTHING about who may
                    # dial its 5432 — counting one as "the per-pod policy" would report
                    # isolation that does not exist. Real files this bites:
                    # networkpolicy/db-egress.yaml selects all five backend DB pods on
                    # the Egress axis, and tier-egress.yaml carries its own `app NotIn`
                    # exclusion list which is deliberately NOT the ingress one.
                    # k8s defaulting when policyTypes is omitted: Ingress is always set,
                    # Egress only when egress rules are present.
                    ptypes = spec.get("policyTypes")
                    if ptypes is None:
                        ptypes = ["Ingress", "Egress"] if spec.get("egress") else ["Ingress"]
                    if "Ingress" not in ptypes:
                        continue
                    sel = spec.get("podSelector") or {}
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
        ok("[db-isolation]", "all %d in-scope Postgres workloads have a per-pod INGRESS policy "
                             "AND are excluded from the broad tier policy (%d known gap(s) skipped)"
                             % (len(dbs) - len(DB_ISOLATION_KNOWN_GAPS),
                                len(DB_ISOLATION_KNOWN_GAPS)))


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
# merge concatenated the whole pre-rebrand `owner:` roles array in
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


# ── 12) Velero backup encryption + recurring-schedule darkness ───────────────
# Two pins for the cloud-backups leg (docs/CLOUD-BACKUPS.md):
#   a) [velero-repo-credentials] — Velero keys every kopia backup repository from
#      the Secret velero-repo-credentials (key repository-password) in its
#      install namespace, and when that Secret is absent at first-repo time it
#      CREATES it itself with upstream's WELL-KNOWN static default
#      ("static-passw0rd", pkg/repository/keys). The ExternalSecret templating it
#      from Vault (secret/hugmesh/velero property repo_password) is what makes
#      "encrypted backups" honest: drop it — or typo the key/property — and every
#      repo is keyed by a password published in Velero's source while the whole
#      tree still applies green.
#   b) [velero-schedule-dark] — the recurring-schedule template must STAY dark:
#      never an active resource of manifests/velero/kustomization.yaml AND
#      paused: true inside the file (the feature's double-gate contract). An
#      active or unpaused Schedule silently starts real backups on a cluster
#      whose superadmin only opted into installing the engine.
def check_hpa_replicas(root):
    """A Deployment an HPA scales must NOT pin spec.replicas.

    Both write the same field, so pinning it makes GitOps and the autoscaler
    fight in a loop that never converges: the HPA scales to minReplicas, ArgoCD
    reads that as drift and writes the manifest value back, the HPA scales up
    again. Measured on kind 2026-08-22 — seven Deployments sat at generation
    ~950-964 after 38 hours (a rewrite every ~2.4 minutes) and their
    Applications never left OutOfSync. It is silent: every pod is Running and
    healthy, so nothing looks wrong except a sync status that will not clear.

    Checked as a PAIR, never by reading replicas alone: `replicas: 1` is
    perfectly correct on a Deployment with no HPA, and that is most of them.
    """
    scaled = {}
    for path in yaml_files(root):
        for doc in docs_of(path):
            if not isinstance(doc, dict) or doc.get("kind") != "HorizontalPodAutoscaler":
                continue
            tgt = (doc.get("spec") or {}).get("scaleTargetRef") or {}
            ns = (doc.get("metadata") or {}).get("namespace")
            scaled[(ns, tgt.get("kind"), tgt.get("name"))] = os.path.relpath(path, root)

    checked = 0
    for path in yaml_files(root):
        for doc in docs_of(path):
            if not isinstance(doc, dict) or doc.get("kind") != "Deployment":
                continue
            meta = doc.get("metadata") or {}
            key = (meta.get("namespace"), "Deployment", meta.get("name"))
            if key not in scaled:
                continue
            checked += 1
            if (doc.get("spec") or {}).get("replicas") is not None:
                fail("[hpa-replicas]",
                     "%s: Deployment %s/%s pins spec.replicas=%s while the HPA in %s "
                     "scales it (minReplicas=%s). Both write that field, so ArgoCD and "
                     "the autoscaler will overwrite each other forever and the "
                     "Application never reaches Synced. Delete the replicas key — the "
                     "HPA owns it."
                     % (os.path.relpath(path, root), meta.get("namespace"),
                        meta.get("name"), doc["spec"]["replicas"], scaled[key],
                        _hpa_min(root, key)))
    if scaled and not checked:
        fail("[hpa-replicas]",
             "%d HorizontalPodAutoscaler(s) name a scale target, but no Deployment "
             "matched any of them — the pairing lookup found nothing and this check "
             "proved nothing. A namespace or name key has drifted." % len(scaled))
    elif checked:
        ok("[hpa-replicas]",
           "%d HPA-scaled Deployment(s) leave spec.replicas to the autoscaler" % checked)


def _hpa_min(root, key):
    for path in yaml_files(root):
        for doc in docs_of(path):
            if not isinstance(doc, dict) or doc.get("kind") != "HorizontalPodAutoscaler":
                continue
            tgt = (doc.get("spec") or {}).get("scaleTargetRef") or {}
            if ((doc.get("metadata") or {}).get("namespace"), tgt.get("kind"),
                    tgt.get("name")) == key:
                return (doc.get("spec") or {}).get("minReplicas")
    return "?"


def check_velero_backups(root):
    # a) the repo-password ExternalSecret
    found = None
    for path in yaml_files(root):
        for d in docs_of(path):
            if d.get("kind") != "ExternalSecret":
                continue
            meta = d.get("metadata") or {}
            spec = d.get("spec") or {}
            tgt = ((spec.get("target") or {}).get("name")) or meta.get("name")
            if tgt == "velero-repo-credentials" and meta.get("namespace") == "velero":
                found = (os.path.relpath(path, root), spec)
    if found is None:
        fail("[velero-repo-credentials]",
             "no ExternalSecret targets Secret 'velero-repo-credentials' in namespace 'velero' — "
             "Velero then creates that Secret itself with upstream's WELL-KNOWN static default "
             "password ('static-passw0rd'), so every kopia backup repository is 'encrypted' with "
             "a password published in Velero's source (docs/CLOUD-BACKUPS.md)")
    else:
        rel, spec = found
        entries = [e for e in (spec.get("data") or [])
                   if isinstance(e, dict) and e.get("secretKey") == "repository-password"]
        if not entries:
            fail("[velero-repo-credentials]",
                 "%s: the velero-repo-credentials ExternalSecret materializes no "
                 "'repository-password' key — Velero reads EXACTLY that key name; anything else "
                 "leaves the repo password on upstream's static default" % rel)
        else:
            rr = entries[0].get("remoteRef") or {}
            if rr.get("key") != "hugmesh/velero" or rr.get("property") != "repo_password":
                fail("[velero-repo-credentials]",
                     "%s: repository-password is sourced from Vault %r property %r instead of "
                     "hugmesh/velero property repo_password — the property gen-cluster-secrets.sh "
                     "seeds. ESO can never sync it, the Secret never materializes, and kopia "
                     "falls back to the well-known default" % (rel, rr.get("key"), rr.get("property")))
            else:
                ok("[velero-repo-credentials]",
                   "%s templates velero/velero-repo-credentials key repository-password from "
                   "Vault hugmesh/velero property repo_password" % rel)

    # b) recurring-schedule darkness
    tmpl = os.path.join(root, "manifests", "velero", "schedule-template.yaml")
    kz = os.path.join(root, "manifests", "velero", "kustomization.yaml")
    bad = False
    sched_docs = docs_of(tmpl) if os.path.exists(tmpl) else []
    if not any(d.get("kind") == "Schedule" for d in sched_docs):
        fail("[velero-schedule-dark]",
             "manifests/velero/schedule-template.yaml is missing or carries no velero.io Schedule "
             "document — the darkness pin has nothing to hold (renamed/emptied file? the "
             "kustomization comment + docs/CLOUD-BACKUPS.md 'Recurring schedules' still point here)")
        bad = True
    else:
        for d in sched_docs:
            if d.get("kind") == "Schedule" and (d.get("spec") or {}).get("paused") is not True:
                fail("[velero-schedule-dark]",
                     "manifests/velero/schedule-template.yaml Schedule %r is not `paused: true` — "
                     "gate 2 of the double-dark contract: an operator who uncomments the "
                     "kustomization resource line must still get ZERO backups until an explicit "
                     "unpause (docs/CLOUD-BACKUPS.md 'Recurring schedules')"
                     % ((d.get("metadata") or {}).get("name"),))
                bad = True
    try:
        resources = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("resources") or []
    except Exception as exc:
        fail("[velero-schedule-dark]", "could not read %s: %s" % (kz, exc))
        resources, bad = [], True
    for r in resources:
        for d in docs_of(os.path.join(root, "manifests", "velero", r)):
            if d.get("kind") == "Schedule":
                bad = True
                fail("[velero-schedule-dark]",
                     "manifests/velero/kustomization.yaml ACTIVELY applies %s carrying Velero "
                     "Schedule %r — the recurring-schedule template ships DARK (commented "
                     "resource line); wiring it in is a deliberate live-cluster superadmin "
                     "opt-in, never a default (docs/CLOUD-BACKUPS.md 'Recurring schedules')"
                     % (r, (d.get("metadata") or {}).get("name")))
    if not bad:
        ok("[velero-schedule-dark]",
           "schedule-template.yaml stays dark: paused: true and not an active kustomization resource")


# ── 14) federated REMOTE surfaces: descriptor -> Service -> Deployment -> Application
#        -> gateway route -> route-access, as ONE derived chain ──────────────────
# WHY (observed 2026-08-26). The superadmin Service Catalog console shipped with
# FOUR of its five links present and the middle one missing. A federation
# descriptor named a Service. A gateway route forwarded to that Service. A
# route-access row gated its path ROLE_SUPERADMIN. docs/SECURITY.md reserved its
# ServiceAccount and MCS category. There was no Deployment and no Service — the
# chain ended in nothing, and every request to the console 503'd at the gateway.
#
# Nothing caught it because each artefact only ever asserted its own half. Worse,
# the ONE check that could have (route-service) had been taught to EXEMPT this
# exact Service with a rationale — "rendered by the service-catalog-builder
# ApplicationSet (apps/54)" — in which apps/54 is not an ApplicationSet and its
# kustomization renders a Namespace and a NetworkPolicy. The gate ran, passed, and
# counted the route as resolved.
#
# So this check walks the WHOLE chain from the descriptor outward and requires each
# link to exist and to AGREE. Everything is derived from the descriptor's own
# fields — rename its remoteEntry host or change its mountAt and every downstream
# assertion follows it. Nothing here is a restatement of a literal that also
# appears in the manifests.
#
# It also pins the strip-prefix, which is the OTHER silent failure on this path and
# the one that looks like success: see check_remote_strip_prefix below.
FEDERATION_DESCRIPTOR_KIND = "FederationModuleRegistration"
REMOTE_ENTRY_RE = re.compile(
    r"^https?://([a-z0-9][a-z0-9.-]*?)\.([a-z0-9][a-z0-9-]*)\.svc\.cluster\.local"
    r"(?::(\d+))?(/.*)?$")


def _service_index(root):
    """-> {"<name>.<ns>": (relpath, service-doc)} for every Service in the tree."""
    out = {}
    for dirpath, _dn, filenames in os.walk(root):
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in sorted(filenames):
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            for d in docs_of(path):
                if d.get("kind") != "Service":
                    continue
                m = d.get("metadata") or {}
                out["%s.%s" % (m.get("name"), m.get("namespace") or defns)] = \
                    (os.path.relpath(path, root), d)
    return out


def _workload_index(root):
    """-> [(relpath, ns, doc)] for every Deployment/StatefulSet/DaemonSet in the tree."""
    out = []
    for dirpath, _dn, filenames in os.walk(root):
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in sorted(filenames):
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            for d in docs_of(path):
                if d.get("kind") not in ("Deployment", "StatefulSet", "DaemonSet"):
                    continue
                out.append((os.path.relpath(path, root),
                            (d.get("metadata") or {}).get("namespace") or defns, d))
    return out


def _application_source_paths(root):
    """-> {source.path: relpath} over every Application/ApplicationSet in the tree.

    Both the plain `spec.source.path` and an ApplicationSet's
    `spec.template.spec.source.path` count: either one makes ArgoCD sync that
    directory. A manifest directory NO Application names is not deployed at all,
    however correct its contents are."""
    out = {}
    for path in yaml_files(root):
        rel = os.path.relpath(path, root)
        for d in docs_of(path):
            if d.get("kind") not in ("Application", "ApplicationSet"):
                continue
            spec = d.get("spec") or {}
            candidates = [(spec.get("source") or {}).get("path"),
                          (((spec.get("template") or {}).get("spec") or {})
                           .get("source") or {}).get("path")]
            for src in (spec.get("sources") or []):
                if isinstance(src, dict):
                    candidates.append(src.get("path"))
            for c in candidates:
                if isinstance(c, str) and c:
                    out.setdefault(c.rstrip("/"), rel)
    return out


def _federation_descriptors(root):
    out = []
    for path in yaml_files(root):
        for d in docs_of(path):
            if d.get("kind") == FEDERATION_DESCRIPTOR_KIND:
                out.append((os.path.relpath(path, root), d))
    return out


def _route_by_target(root):
    """-> {"<svc>.<ns>": [(gateway, route-dict)]} for in-cluster gateway routes."""
    out = defaultdict(list)
    for gw, routes in sorted(_gateways(root).items()):
        for r in routes:
            if not isinstance(r, dict):
                continue
            m = URI_RE.match(r.get("uri") or "")
            if not m:
                continue
            out["%s.%s" % (m.group(1), m.group(2))].append((gw, r))
    return out


def check_federation_remotes(root):
    descriptors = _federation_descriptors(root)
    if not descriptors:
        fail("[federation-remote]",
             "no %s document exists anywhere under specs/cluster — this check derives "
             "EVERY assertion from those descriptors, so with none present it proves "
             "nothing at all. If the descriptor kind was renamed, rename it here too; "
             "do not let the check go quietly vacuous." % FEDERATION_DESCRIPTOR_KIND)
        return

    services = _service_index(root)
    workloads = _workload_index(root)
    app_paths = _application_source_paths(root)
    routes_by_target = _route_by_target(root)
    schema = os.path.join(root, "manifests", "route-access", "initdb", "20-schema.sql")
    # COMMENT-STRIPPED on the way in, and the row is anchored at line start in
    # step (e) below. Both halves matter: a row that has been commented out is
    # not seeded, and a check that reads raw text would accept
    #   -- DISABLED ('<gw>', '/superadmin/service-catalog/**', ...
    # as proof of the very row whose absence it exists to report.
    schema_text = (sql_without_comments(open(schema, encoding="utf-8").read())
                   if os.path.exists(schema) else "")

    bad = 0
    for rel, doc in descriptors:
        name = (doc.get("metadata") or {}).get("name") or "<unnamed>"
        spec = doc.get("spec") or {}
        entry = spec.get("remoteEntry") or ""
        mount = spec.get("mountAt") or ""
        m = REMOTE_ENTRY_RE.match(entry)
        if not m:
            bad += 1
            fail("[federation-remote]",
                 "%s: descriptor %r has remoteEntry %r, which is not an in-cluster "
                 "<service>.<namespace>.svc.cluster.local URL — the host's "
                 "loadRemoteModule has no resolvable bundle root and nothing below "
                 "can be derived from it" % (rel, name, entry))
            continue
        svc, ns, port = m.group(1), m.group(2), int(m.group(3) or 80)
        key = "%s.%s" % (svc, ns)

        # (a) the Service the descriptor points at must exist, on the stated port.
        if key not in services:
            bad += 1
            fail("[federation-remote]",
                 "%s: descriptor %r points remoteEntry at %s, but NO Service %r exists "
                 "in namespace %r. The gateway route in front of it then resolves to "
                 "nothing and the console is a 503 — which is exactly what shipped."
                 % (rel, name, entry, svc, ns))
            continue
        svc_rel, svc_doc = services[key]
        ports = [(p or {}).get("port") for p in ((svc_doc.get("spec") or {}).get("ports") or [])]
        if port not in ports:
            bad += 1
            fail("[federation-remote]",
                 "%s: descriptor %r fetches remoteEntry on port %d, but Service %s (%s) "
                 "exposes %s. The federation manifest hands that URL straight to the "
                 "browser's loadRemoteModule, so a port the Service does not serve is a "
                 "connection refused at runtime, not a config warning."
                 % (rel, name, port, key, svc_rel, ports))

        # (b) something must actually BACK that Service.
        selector = (svc_doc.get("spec") or {}).get("selector") or {}
        backing = []
        for wl_rel, wl_ns, wl in workloads:
            if wl_ns != ns or not selector:
                continue
            labels = (((wl.get("spec") or {}).get("template") or {})
                      .get("metadata") or {}).get("labels") or {}
            if all(labels.get(k) == v for k, v in selector.items()):
                backing.append((wl_rel, wl))
        if not backing:
            bad += 1
            fail("[federation-remote]",
                 "%s: descriptor %r resolves to Service %s (%s) but NO Deployment/"
                 "StatefulSet/DaemonSet in %r carries labels matching its selector %s "
                 "— a Service with no endpoints answers every request with a connection "
                 "refused, and looks perfectly healthy in `kubectl get svc`."
                 % (rel, name, key, svc_rel, ns, selector))
        else:
            # (c) …and the directory holding it must be synced by an Application.
            wl_rel = backing[0][0]
            manifest_dir = "specs/cluster/" + os.path.dirname(wl_rel)
            if manifest_dir not in app_paths:
                bad += 1
                fail("[federation-remote]",
                     "%s: descriptor %r is backed by %s, but NO Application/ApplicationSet "
                     "names %r as a source.path — ArgoCD never applies that directory, so "
                     "the Deployment exists in git and nowhere else. Correct YAML that "
                     "nothing syncs is indistinguishable from no YAML at all."
                     % (rel, name, wl_rel, manifest_dir))

        # (d) a gateway must route the descriptor's mountAt to that Service.
        if not mount:
            bad += 1
            fail("[federation-remote]",
                 "%s: descriptor %r declares no mountAt — the host has no path to mount "
                 "the remote at and no route can be checked against it" % (rel, name))
            continue
        want_path = mount.rstrip("/") + "/**"
        hits = [(gw, r) for (gw, r) in routes_by_target.get(key, [])
                if want_path in [p.strip() for p in (r.get("path") or "").split(",")]]
        if not hits:
            others = ["%s:%s" % (gw, r.get("path")) for (gw, r) in routes_by_target.get(key, [])]
            bad += 1
            fail("[federation-remote]",
                 "%s: descriptor %r mounts at %r, so some gateway must route %r to "
                 "Service %s. None does (routes to that Service: %s). The host shell "
                 "would resolve the module and then fetch its bundles from a path the "
                 "gateway does not forward."
                 % (rel, name, mount, want_path, key, others or "none"))
            continue

        # (e) …and the route-access seed must gate that same pattern on that gateway.
        for gw, _r in hits:
            if not re.search(r"^\s*\(\s*'%s'\s*,\s*'%s'\s*,"
                             % (re.escape(gw), re.escape(want_path)),
                             schema_text, re.M):
                bad += 1
                fail("[federation-remote]",
                     "%s: gateway %s routes the remote's mountAt %r but 20-schema.sql "
                     "seeds NO gateway_route_access row for that (gateway, pattern) pair. "
                     "decide() returns NO_RULE and the gateway forwards on the coarse "
                     "authenticated() floor — an internal/superadmin remote served to any "
                     "logged-in user." % (rel, gw, want_path))
    if not bad:
        ok("[federation-remote]",
           "all %d federation remote descriptor(s) resolve end to end: Service + backing "
           "workload + syncing Application + gateway route at mountAt + route-access row"
           % len(descriptors))


# ── 15) a federated remote's gateway route MUST strip its own path prefix ────
# THE FAILURE THIS CATCHES IS A BLANK PAGE, NOT A 404 — which is why it survives
# review. Every one of these remotes is a standalone nginx image built with
# `<base href="/">` and an SPA `try_files $uri $uri/ /index.html` fallback. Under a
# route that does NOT strip its prefix, a request for
# /superadmin/service-catalog/remoteEntry.json reaches the container as that literal
# path, matches no file, and the fallback returns index.html — HTTP 200,
# Content-Type text/html. Native federation feeds that HTML to JSON.parse and dies
# on `Unexpected token '<'`. Pod Ready, gateway logging 200s, empty <body>.
#
# apps/20-gateway-fe.yaml carried exactly this on EVERY micro-frontend remote for
# years (its route block records the fix: adding StripPrefix made
# GET .../remoteEntry.json return the real federation manifest instead of
# index.html), and apps/22-gateway-superadmin.yaml then shipped the superadmin
# console's route with the same omission.
#
# ── DISCOVERY, AND WHY IT WAS WIDENED (2026-08-26, review finding) ───────────
# The first cut discovered a "remote" two ways: a Service a FederationModuleRegistration
# descriptor names as a remoteEntry host, or a workload whose HTTP probe path ends in
# /remoteEntry.json. MEASURED, that is 1 descriptor and 2 probing workloads
# (character-forge, character-studio) in the whole tree — and the OTHER EIGHT
# micro-frontend routes on apps/20-gateway-fe.yaml (matrix-ui, mastodon-ui, forum-ui,
# login-ui, admin-ui, mod-ui, user-ui, api-docs) name remoteEntry.json only in header
# COMMENTS. They were invisible. A reviewer deleted the StripPrefix filter from
# /admin/** and /social/matrix/** — the exact shipped defect class, on the exact
# gateway the fix commit called out — and this check still printed a pass. The
# comment that claimed "add a remote tomorrow and it is covered" was false for the
# MAJORITY in-repo shape.
#
# So discovery is now the TIER, not the two lucky members of it: every gateway route
# whose target Service lives in a namespace where a descriptor/probe DID find a
# bundle root is a micro-frontend route and must account for its own prefix. The tier
# namespace set is still derived (from the descriptors/probes), never written down.
#
# Two routes in that tier legitimately do NOT strip, and BOTH exclusions are derived
# from the tree rather than listed:
#
#   apex-served — the same Service is also the target of that gateway's `/**` route.
#     A container answering the site root is the HOST SHELL: it is mounted at `/`,
#     its router owns the whole path, and stripping would eat the deep link it needs.
#     (This is what apps/20's `remote-deeplink-to-host-shell` route is.)
#   self-served prefix — the backing workload's own directory ships an nginx config
#     declaring a `location` under the route's first path segment, i.e. the container
#     really does serve that prefix. manifests/remote-fragment/nginx.conf serves
#     content-addressed bundles at /_fragments/<slug>/<hash>/…, so its /_fragments/**
#     route must NOT strip. Delete those location blocks and this check turns red —
#     it is reading the evidence, not trusting a name.
#
# Everything else in the tier is strip-checked, and the REQUIRED count is the segment
# depth of the route's own path. Both exclusions are PRINTED by name on the pass line:
# a skip nobody can see is how this check went vacuous the first time.
def _remote_bundle_services(root):
    """-> {"<svc>.<ns>": why} for Services PROVEN to serve a federation bundle root.

    Descriptor-named or probe-proven only. This is the SEED that derives the tier
    namespace set below; it is deliberately not the whole answer (see the header).
    """
    out = {}
    services = _service_index(root)
    for rel, doc in _federation_descriptors(root):
        m = REMOTE_ENTRY_RE.match((doc.get("spec") or {}).get("remoteEntry") or "")
        if m:
            out["%s.%s" % (m.group(1), m.group(2))] = \
                "named as a remoteEntry host by %s" % rel
    for wl_rel, wl_ns, wl in _workload_index(root):
        probes = re.findall(r"path:\s*(\S*/remoteEntry\.json)", dump_of(wl))
        if not probes:
            continue
        labels = (((wl.get("spec") or {}).get("template") or {})
                  .get("metadata") or {}).get("labels") or {}
        for key, (_svc_rel, svc_doc) in services.items():
            if not key.endswith("." + str(wl_ns)):
                continue
            sel = (svc_doc.get("spec") or {}).get("selector") or {}
            if sel and all(labels.get(k) == v for k, v in sel.items()):
                out.setdefault(key, "backing workload %s probes %s" % (wl_rel, probes[0]))
    return out


def _backing_workload(root, key, services, workloads):
    """-> (relpath, doc) of the workload whose pod labels match Service `key`."""
    if key not in services:
        return None
    sel = ((services[key][1].get("spec") or {}).get("selector") or {})
    if not sel:
        return None
    ns = key.split(".", 1)[1]
    for wl_rel, wl_ns, wl in workloads:
        if wl_ns != ns:
            continue
        labels = (((wl.get("spec") or {}).get("template") or {})
                  .get("metadata") or {}).get("labels") or {}
        if all(labels.get(k) == v for k, v in sel.items()):
            return (wl_rel, wl)
    return None


_LOCATION_RE = re.compile(r"^\s*location\s+([^{\n]+)\{", re.M)


def _self_served_prefixes(root, wl_rel):
    """-> set of URL prefixes an in-tree nginx config beside the workload declares.

    Only real evidence counts: the files are read out of the workload's OWN manifest
    directory (where a ConfigMap-generated nginx.conf lives), never inferred from a
    name. A container whose config has `location /_fragments/` genuinely serves that
    prefix and must be handed the unstripped path.
    """
    prefixes = set()
    d = os.path.dirname(os.path.join(root, wl_rel))
    if not os.path.isdir(d):
        return prefixes
    for name in sorted(os.listdir(d)):
        path = os.path.join(d, name)
        if not os.path.isfile(path):
            continue
        try:
            text = text_of(path)
        except Exception:
            continue
        for blob in _LOCATION_RE.findall(text):
            for pref in re.findall(r"\^?(/[A-Za-z0-9_.\-/]*)", blob):
                if len(pref) > 1:
                    prefixes.add(pref.rstrip("/") or "/")
    return prefixes


def _tier_routes(root):
    """Classify every gateway route into the micro-frontend tier.

    -> (strip_checked, apex_served, self_served, remotes, tier_ns)
    where strip_checked is [(gw, route, path, depth, svc_key, wl_rel)] and the two
    skip lists are human-readable strings, printed by name on the pass line.
    """
    remotes = _remote_bundle_services(root)
    tier_ns = {k.split(".", 1)[1] for k in remotes}
    services = _service_index(root)
    workloads = _workload_index(root)

    # A Service this gateway also serves at the apex `/**` is the host shell.
    apex = set()
    for gw, routes in sorted(_gateways(root).items()):
        for r in routes:
            if not isinstance(r, dict):
                continue
            m = URI_RE.match(r.get("uri") or "")
            if not m:
                continue
            for raw in (r.get("path") or "").split(","):
                if raw.strip() in ("/**", "/*", "/"):
                    apex.add((gw, "%s.%s" % (m.group(1), m.group(2))))

    strip_checked, apex_served, self_served = [], [], []
    for gw, routes in sorted(_gateways(root).items()):
        for r in routes:
            if not isinstance(r, dict):
                continue
            m = URI_RE.match(r.get("uri") or "")
            if not m:
                continue
            key = "%s.%s" % (m.group(1), m.group(2))
            if key not in remotes and m.group(2) not in tier_ns:
                continue
            back = _backing_workload(root, key, services, workloads)
            wl_rel = back[0] if back else None
            for raw in (r.get("path") or "").split(","):
                path = raw.strip()
                if not path.endswith("/**"):
                    continue
                segs = [seg for seg in path[:-3].split("/") if seg]
                if not segs:
                    continue                       # the apex route itself
                if (gw, key) in apex:
                    apex_served.append("%s %s -> %s" % (gw, path, key))
                    continue
                served = _self_served_prefixes(root, wl_rel) if wl_rel else set()
                own = "/" + segs[0]
                if any(p.startswith(own) for p in served):
                    self_served.append("%s %s -> %s (its own nginx config declares "
                                       "location %s)" % (gw, path, key, own))
                    continue
                strip_checked.append((gw, r, path, len(segs), key, wl_rel))
    return strip_checked, apex_served, self_served, remotes, tier_ns


def check_remote_strip_prefix(root):
    strip_checked, apex_served, self_served, remotes, tier_ns = _tier_routes(root)
    if not remotes:
        fail("[remote-strip-prefix]",
             "found ZERO federation-remote bundle Services — neither a descriptor "
             "remoteEntry host nor a workload probing /remoteEntry.json. Both discovery "
             "routes have gone stale, so the micro-frontend tier cannot be derived, this "
             "check has nothing to assert, and it must not report a pass.")
        return
    bad = 0
    for gw, r, path, depth, key, _wl_rel in strip_checked:
        filters = [str(f) for f in (r.get("filters") or [])]
        strips = [f for f in filters if f.startswith("StripPrefix=")]
        why = remotes.get(key, "in the micro-frontend tier namespace %r, which %s"
                               % (key.split(".", 1)[1],
                                  "a federation descriptor/probe identifies as a "
                                  "bundle-root tier"))
        if not strips:
            bad += 1
            fail("[remote-strip-prefix]",
                 "gateway %s route %r forwards %s to the micro-frontend %s "
                 "(%s) with NO StripPrefix filter. These remotes are standalone nginx "
                 "images with <base href=\"/\"> and an SPA try_files fallback, so "
                 "%s/remoteEntry.json comes back as index.html with HTTP 200 and "
                 "Content-Type text/html; native federation JSON.parses that HTML "
                 "and the console renders BLANK. Add StripPrefix=%d (the segment "
                 "depth of this route's own path). If this container really does serve "
                 "the prefix itself, ship its nginx config in its manifest directory — "
                 "this check reads `location` blocks there and skips such routes by name."
                 % (gw, r.get("id"), path, key, why, path[:-3], depth))
            continue
        got = strips[0].split("=", 1)[1].strip()
        if got != str(depth):
            bad += 1
            fail("[remote-strip-prefix]",
                 "gateway %s route %r forwards %s to the micro-frontend %s "
                 "with %s, but the path has %d segment(s) before the wildcard. "
                 "Stripping too few leaves a prefix the container has no files "
                 "under (SPA fallback -> index.html with 200); stripping too many "
                 "eats a real path segment. It must be StripPrefix=%d."
                 % (gw, r.get("id"), path, key, strips[0], depth, depth))
    if not strip_checked:
        fail("[remote-strip-prefix]",
             "%d federation-remote bundle Service(s) were discovered (%s) but NOT ONE "
             "gateway route into the tier namespace(s) %s was left to strip-check — "
             "every candidate was skipped as apex-served or self-served. The pairing "
             "found nothing, so this check proved nothing."
             % (len(remotes), ", ".join(sorted(remotes)), ", ".join(sorted(tier_ns))))
    elif not bad:
        ok("[remote-strip-prefix]",
           "all %d gateway route(s) into the micro-frontend tier (%s) strip exactly "
           "their own path depth; %d bundle root(s) proven by descriptor/probe, the "
           "rest derived from the tier. NOT strip-checked, each for a derived reason "
           "and named here rather than skipped silently: %d apex-served [%s]; %d "
           "self-served prefix [%s]"
           % (len(strip_checked), ", ".join(sorted(tier_ns)), len(remotes),
              len(apex_served), "; ".join(apex_served) or "none",
              len(self_served), "; ".join(self_served) or "none"))


# ── 15b) …and that correctly-stripped route must point at the RIGHT remote ───
# DECLARED AS A SURVIVING MUTATION IN THE FIRST CUT, AND CLOSED HERE. StripPrefix=2
# on /social/matrix/** is exactly as correct when the route forwards to
# hugmesh-mastodon-ui as when it forwards to hugmesh-matrix-ui — [remote-strip-prefix]
# counts segments and never looks at the target's identity, and [federation-remote]
# only notices for the ONE Service a descriptor names. Swap two `uri:` lines in
# apps/20-gateway-fe.yaml and every gate stayed green while /social/matrix served the
# Mastodon shell.
#
# THE DERIVATION: a micro-frontend's mount path and its Service name are two spellings
# of the same feature slug, and the repo is consistent about it —
#   /social/matrix/**            -> hugmesh-matrix-ui
#   /admin/**                    -> hugmesh-admin-ui
#   /api-docs/**                 -> hugmesh-api-docs
#   /character-forge/**          -> hugmesh-character-forge-ui
#   /superadmin/service-catalog/** -> hugmesh-superadmin-service-catalog-ui
# so the LAST path segment before the wildcard must appear as a hyphen-delimited
# token run in the target Service name. Nothing is listed here: the pairs are read out
# of the route table each run.
#
# WHEN THIS IS WRONG: a remote whose mount path legitimately does not name its
# Service. That is a real possibility and the failure text says so — the fix is then
# to make the two agree (rename one) or, if they genuinely must differ, to give the
# remote a FederationModuleRegistration descriptor, which pins mountAt -> Service
# directly and is the stronger statement anyway.
def _slug_tokens(name):
    return [t for t in re.split(r"[^a-z0-9]+", name.lower()) if t]


def check_remote_route_targets(root):
    strip_checked, _apex, _self, remotes, tier_ns = _tier_routes(root)
    if not strip_checked:
        fail("[remote-route-target]",
             "no micro-frontend tier route was classified, so there is no route/target "
             "pair to check. See [remote-strip-prefix] for why discovery came up empty; "
             "this check must not report a pass on an empty set.")
        return
    bad = 0
    for gw, r, path, _depth, key, _wl_rel in strip_checked:
        svc = key.split(".", 1)[0]
        want = _slug_tokens(path[:-3].strip("/").split("/")[-1])
        have = _slug_tokens(svc)
        joined = "-".join(have)
        if "-".join(want) in joined:
            continue
        bad += 1
        fail("[remote-route-target]",
             "gateway %s route %r mounts %s but forwards it to Service %s, whose name "
             "does not contain the mount's own slug %r. A route pointed at the WRONG "
             "remote is invisible to every other check here: the StripPrefix count is "
             "still right, the Service still exists and is still healthy, and the user "
             "simply gets a different application than the URL promises. Either make the "
             "two agree, or give this remote a %s descriptor, which states mountAt -> "
             "Service outright and is checked by [federation-remote]."
             % (gw, r.get("id"), path, key, "-".join(want),
                FEDERATION_DESCRIPTOR_KIND))
    if not bad:
        ok("[remote-route-target]",
           "all %d micro-frontend tier route(s) forward to a Service whose name carries "
           "the mount path's own slug (%d tier namespace(s), %d descriptor/probe-proven "
           "bundle root(s))"
           % (len(strip_checked), len(tier_ns), len(remotes)))


# ── 16) a build-Job TEMPLATE's Secret mounts must be PROVISIONED AND SYNCED ──
# WHY (observed 2026-08-26). manifests/service-catalog-builder/kaniko-build-job.
# template.yaml mounts `service-catalog-builder-registry` as a `secret:` volume with
# NO `optional: true`, and nothing in the tree created it. Its README asserted the
# Secret was "ESO-materialized into the build namespace — never in git" as though an
# ExternalSecret existed. None did.
#
# WHAT THAT COSTS, precisely: a non-optional secret volume is a HARD kubelet
# precondition. The Job is created fine (the API server does not check that a
# referenced Secret exists), the Job controller reports a pod, and the pod sits in
# ContainerCreating/FailedMount until activeDeadlineSeconds — 1800s here. Not a 4xx
# the calling effector could surface, not a CrashLoopBackOff anybody watches: a
# thirty-minute silent hang. That is a worse failure than an outright error, and it
# is the one a template makes easy, because a template is never applied by ArgoCD
# and so is never validated by anything.
#
# DERIVED FROM THE TEMPLATE ITSELF. The Secret NAMES are read out of the template's
# volumes/imagePullSecrets, and the NAMESPACE out of the `kind: Namespace` its own
# directory ships (the same directory the Application syncs) — because the template
# writes it as the ${BUILD_NAMESPACE} placeholder and a literal here would just be a
# second copy of the value to drift. Rename the Secret in the template alone and
# this goes RED; that is the difference between a guard and a restatement.
#
# ── THREE HOLES A REVIEWER DROVE THROUGH THE FIRST CUT (2026-08-26) ──────────
# (i) `optional: true` WAS A SILENT ESCAPE HATCH. The first cut collected only
#     non-optional mounts, so adding one line to the kaniko volume dropped the mount
#     out of the checked set entirely — the pass line went from "all 2" to "all 1"
#     and nothing failed. It does not make the build work: kaniko then starts with no
#     /kaniko/.docker/config.json and the push 401s at the end of a full image build.
#     So OPTIONAL MOUNTS ARE CHECKED TOO, and counted separately on the pass line —
#     `optional:` changes WHEN the build dies, not WHETHER.
# (ii) A DIRECTORY THAT YIELDED NO REFS WAS SKIPPED IN SILENCE (`if not refs:
#     continue`). Deleting the whole volume block would have been a free pass. A
#     kaniko template is now held to a floor derived from its own args: a container
#     that runs `--destination=` PUSHES to a registry, and a push with no credential
#     Secret anywhere in its pod spec is reported, not skipped. Every directory that
#     yields nothing is printed by name with the reason.
# (iii) "THE FILE EXISTS" WAS TREATED AS "THE SECRET IS PROVISIONED". The provider
#     scan walked the filesystem and never consulted the kustomization graph, so
#     deleting the ONE line that wires the ExternalSecret into
#     external-secrets/kustomization.yaml left the gate green while ArgoCD would
#     never apply the file, the Secret would never materialise, and the pod would
#     hang for its full 1800s — the original defect, restored, undetected. This is
#     the same standard [federation-remote] step (c) already states out loud:
#     correct YAML that nothing syncs is indistinguishable from no YAML at all. A
#     provider now counts only if its own directory's kustomization lists it in
#     `resources:`, and an unwired file is reported AS unwired, by path, so the
#     failure names the one line to put back.
def _kustomization_resources(dirpath):
    """-> (has_kustomization, {resource entries}) for one directory."""
    kz = os.path.join(dirpath, "kustomization.yaml")
    if not os.path.exists(kz):
        kz = os.path.join(dirpath, "kustomization.yml")
        if not os.path.exists(kz):
            return False, set()
    try:
        doc = yaml.safe_load(open(kz, encoding="utf-8")) or {}
    except Exception:
        return True, set()
    out = set()
    for r in (doc.get("resources") or []):
        if isinstance(r, str):
            out.add(r.strip().lstrip("./"))
    return True, out


def _external_secret_targets(root):
    """-> (provided, unwired)

    provided : {"<secret>.<ns>"} that a SYNCED ExternalSecret/Secret manifest creates.
    unwired  : {"<secret>.<ns>": relpath} for a manifest that WOULD create it but is
               not listed in its own directory's kustomization `resources:`.

    The split is the whole point. A directory with a kustomization.yaml is rendered
    by that file and nothing else; a .yaml sitting beside it that no `resources:`
    entry names is dead text on disk. Counting it as a provider is how a one-line
    deletion re-opened defect 12 with the gate still green.
    """
    provided, unwired = set(), {}
    for dirpath, _dn, filenames in os.walk(root):
        has_kz, resources = _kustomization_resources(dirpath)
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in sorted(filenames):
            if not name.endswith((".yaml", ".yml")):
                continue
            path = os.path.join(dirpath, name)
            wired = (not has_kz) or (name in resources)
            for d in docs_of(path):
                if d.get("kind") not in ("ExternalSecret", "Secret"):
                    continue
                meta = d.get("metadata") or {}
                ns = meta.get("namespace") or defns
                tgt = (((d.get("spec") or {}).get("target") or {}).get("name")
                       if d.get("kind") == "ExternalSecret" else None) or meta.get("name")
                key = "%s.%s" % (tgt, ns)
                if wired:
                    provided.add(key)
                else:
                    unwired.setdefault(key, os.path.relpath(path, root))
    return provided, unwired


def _template_secret_refs(doc):
    """-> {secret-name: optional?} for every Secret a pod spec mounts or pulls with.

    OPTIONAL MOUNTS ARE INCLUDED, flagged rather than dropped — see hole (i) above.
    """
    names = {}
    spec = ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
    for v in (spec.get("volumes") or []):
        sec = (v or {}).get("secret") or {}
        if sec.get("secretName"):
            names[sec["secretName"]] = bool(sec.get("optional"))
        for src in ((v or {}).get("projected") or {}).get("sources") or []:
            s2 = (src or {}).get("secret") or {}
            if s2.get("name"):
                names[s2["name"]] = bool(s2.get("optional"))
    for ips in (spec.get("imagePullSecrets") or []):
        if (ips or {}).get("name"):
            names.setdefault(ips["name"], False)
    return names


def _pushes_an_image(doc):
    """True if any container in this pod spec pushes to a registry (kaniko et al.).

    Read out of the container args, not from an image name: `--destination=` is the
    flag that makes a build a PUSH, and a push needs a credential.
    """
    spec = ((doc.get("spec") or {}).get("template") or {}).get("spec") or {}
    for c in (spec.get("containers") or []) + (spec.get("initContainers") or []):
        for a in ((c or {}).get("args") or []) + ((c or {}).get("command") or []):
            if "--destination" in str(a):
                return True
    return False


def check_build_template_secrets(root):
    provided, unwired = _external_secret_targets(root)
    template_dirs = defaultdict(list)
    for dirpath, _dn, filenames in os.walk(root):
        for name in sorted(filenames):
            if name.endswith(".template.yaml") or name.endswith(".template.yml"):
                template_dirs[dirpath].append(os.path.join(dirpath, name))
    if not template_dirs:
        fail("[build-template-secret]",
             "no *.template.yaml exists anywhere under specs/cluster. This check reads "
             "the Secret names out of those templates, so with none present it asserts "
             "nothing. If the naming convention changed, change it here too rather than "
             "letting the check pass empty.")
        return

    bad = checked = optional_checked = 0
    empty_dirs = []
    for dirpath in sorted(template_dirs):
        rel_dir = os.path.relpath(dirpath, root)
        # The build namespace this directory's Application creates. The templates say
        # ${BUILD_NAMESPACE}; the directory's own Namespace resource is what that
        # placeholder is bound to, and it is the namespace ESO must target.
        namespaces = set()
        for name in sorted(os.listdir(dirpath)):
            if not name.endswith((".yaml", ".yml")) or name.endswith(
                    (".template.yaml", ".template.yml")):
                continue
            for d in docs_of(os.path.join(dirpath, name)):
                if d.get("kind") == "Namespace":
                    namespaces.add((d.get("metadata") or {}).get("name"))
        refs = {}
        pushers = []
        for tpath in template_dirs[dirpath]:
            for d in docs_of(tpath):
                if d.get("kind") not in ("Job", "CronJob", "Deployment", "StatefulSet",
                                         "DaemonSet", "Pod"):
                    continue
                inner = d
                if d.get("kind") == "CronJob":
                    inner = ((d.get("spec") or {}).get("jobTemplate") or {})
                trel = os.path.relpath(tpath, root)
                if _pushes_an_image(inner):
                    pushers.append(trel)
                for n, is_opt in _template_secret_refs(inner).items():
                    if "$" in n or "{" in n:
                        continue           # placeholder, bound per build
                    refs[n] = (trel, is_opt)
        if not refs:
            # NO SILENT SKIP. A registry-pushing template with no credential Secret at
            # all is the same defect as one naming a Secret nobody creates — deleting
            # the volume must not be cheaper than renaming it.
            if pushers:
                bad += 1
                fail("[build-template-secret]",
                     "%s: %s runs a container with `--destination=` (it PUSHES an image) "
                     "but its pod spec mounts NO Secret and sets no imagePullSecrets. "
                     "Kaniko then starts with no /kaniko/.docker/config.json and the push "
                     "401s after a full image build. Deleting the credential volume must "
                     "not be a cheaper way past this gate than renaming it."
                     % (rel_dir, ", ".join(sorted(set(pushers)))))
            else:
                empty_dirs.append("%s (no Secret mount, no `--destination=` push)" % rel_dir)
            continue
        if len(namespaces) != 1:
            bad += 1
            fail("[build-template-secret]",
                 "%s: its template(s) mount Secret(s) %s, but the directory declares %d "
                 "`kind: Namespace` resource(s) (%s) — this check derives the build "
                 "namespace from that one Namespace and cannot say WHERE those Secrets "
                 "must exist. Do not hardcode the namespace here; fix the directory so "
                 "it declares exactly one."
                 % (rel_dir, sorted(refs), len(namespaces), sorted(namespaces) or "none"))
            continue
        ns = namespaces.pop()
        for secret_name in sorted(refs):
            trel, is_opt = refs[secret_name]
            checked += 1
            if is_opt:
                optional_checked += 1
            key = "%s.%s" % (secret_name, ns)
            if key in provided:
                continue
            bad += 1
            if key in unwired:
                fail("[build-template-secret]",
                     "%s mounts Secret %r in namespace %r, and %s WOULD provision it — "
                     "but that file is NOT listed in its own directory's kustomization "
                     "`resources:`, so kustomize never renders it and ArgoCD never "
                     "applies it. The Secret never materialises and the build pod hangs "
                     "in ContainerCreating until activeDeadlineSeconds, exactly as if "
                     "the file did not exist. Correct YAML that nothing syncs is "
                     "indistinguishable from no YAML at all — put the resources: line "
                     "back." % (trel, secret_name, ns, unwired[key]))
                continue
            fail("[build-template-secret]",
                 "%s mounts Secret %r in namespace %r%s, but NOTHING provisions it "
                 "there (no synced ExternalSecret target, no synced Secret manifest). "
                 "A non-optional secret volume is a hard kubelet precondition: the Job "
                 "is created, a pod appears, and it sits in ContainerCreating/"
                 "FailedMount until activeDeadlineSeconds — a silent hang, not an error "
                 "the caller can surface. Marking the mount `optional: true` does NOT "
                 "fix it; it only moves the failure from FailedMount to a 401 at push "
                 "time after a full image build. Because the Job is a TEMPLATE, ArgoCD "
                 "never applies it, so nothing else in this repo can see the missing "
                 "Secret."
                 % (trel, secret_name, ns,
                    " (mounted `optional: true`)" if is_opt else ""))
    if not checked:
        fail("[build-template-secret]",
             "found %d directory/directories with a *.template.yaml but extracted ZERO "
             "Secret mounts from them — the extraction has drifted from the templates' "
             "shape and this check proved nothing." % len(template_dirs))
    elif not bad:
        ok("[build-template-secret]",
           "all %d Secret mount(s) in build-Job templates are provisioned by a KUSTOMIZE-"
           "SYNCED manifest in the build namespace their own directory declares (%d of "
           "them mounted `optional: true` and checked anyway — optional changes when the "
           "build dies, not whether); %d template directory/directories yielded no "
           "mount and push nothing: %s"
           % (checked, optional_checked, len(empty_dirs),
              "; ".join(empty_dirs) or "none"))


# ── 17) every MCS category a workload claims must be LISTED in the identity matrix ─
# WHY (observed 2026-08-26). docs/SECURITY.md §3 had RESERVED `s0:c49` (with SA
# `sa-service-catalog-ui`) for the superadmin service-catalog console, whose
# Deployment did not exist yet. `edge-ai-analysis` later picked c49 with the comment
# "next free" — and it WAS next free by the only evidence available to that author: a
# scan of the live manifests, in which nothing carried c49. The [mcs] uniqueness check
# could not see the clash either, because it compares WORKLOADS and a reservation
# with no Deployment is not one. The collision surfaced only when the console's
# Deployment was finally written, months later, and by then the reservation had been
# quietly voided.
#
# The renumber was not the fix. The fix is that `edge-ai-analysis` had NO ROW IN THE
# MATRIX AT ALL — an unlisted workload cannot be avoided by the next person doing a
# "next free" scan, and the matrix is the only place a reservation can live. So: a
# level that appears in a workload manifest must also appear in docs/SECURITY.md §3,
# and no level may appear on two different rows of it (which is how a reservation and
# a live claim could coexist unnoticed).
#
# The doc is OUTSIDE the tree under test (the negative-control harness stages
# specs/cluster alone), so its location is resolved from HUGMESH_DOCS_DIR when set and
# from <root>/../../docs otherwise. If it cannot be read this check FAILS — it never
# skips: a gate that cannot look must not report a pass.
#
# EXEMPTIONS ARE SELF-VERIFYING, deliberately. This gate's own history is a FALSE
# exemption ("rendered by the service-catalog-builder ApplicationSet") that hid a
# missing Service for weeks, so an entry here is not taken on trust: the rationale
# names a file, and the level must actually be discussed in that file, or the
# exemption itself is reported as the failure.
MCS_DOC_EXEMPT = {
    # The casdoor-domain BASE overlay's placeholders. docs/DOMAIN-IDP.md states they
    # are "never meant to go live" — the per-domain ApplicationSet patches a real
    # per-domain level over them — so they are not identities the matrix should carry.
    "s0:c85": "docs/DOMAIN-IDP.md",
    "s0:c86": "docs/DOMAIN-IDP.md",
}


def _docs_dir(root):
    env = os.environ.get("HUGMESH_DOCS_DIR")
    if env:
        return env
    return os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(root))), "docs")


def check_mcs_documented(root):
    docs = _docs_dir(root)
    sec = os.path.join(docs, "SECURITY.md")
    if not os.path.exists(sec):
        fail("[mcs-documented]",
             "cannot read %s (docs dir %r) — the identity matrix is the authority this "
             "check compares against, so with it unreadable the check proves nothing and "
             "must not pass. Set HUGMESH_DOCS_DIR if the docs live elsewhere." % (sec, docs))
        return
    doc_text = open(sec, encoding="utf-8").read()
    rows = defaultdict(list)
    for line in doc_text.splitlines():
        if not line.startswith("|"):
            continue
        first = line.split("|")[1].strip() if line.count("|") > 1 else line
        for lv in re.findall(r"`(s0:c\d+)`", line):
            rows[lv].append(first)
    if not rows:
        fail("[mcs-documented]",
             "parsed ZERO `s0:cNN` cells out of %s's tables — the matrix format has "
             "drifted from what this check reads, so it would silently exempt every "
             "workload. Fix the parse, do not delete the check." % sec)
        return

    bad = 0
    for lv in sorted(rows, key=lambda x: int(x.split("c")[1])):
        if len(rows[lv]) > 1:
            bad += 1
            fail("[mcs-documented]",
                 "docs/SECURITY.md lists MCS category %s on %d different rows (%s). One "
                 "category, one identity — two rows is how a RESERVATION and a live claim "
                 "coexisted unnoticed until the reserved workload was finally deployed."
                 % (lv, len(rows[lv]), "; ".join(rows[lv])))

    claimed = defaultdict(set)
    for path in yaml_files(root):
        for d in docs_of(path):
            if d.get("kind") not in WORKLOAD_KINDS:
                continue
            for m in MCS_RE.finditer(dump_of(d)):
                claimed[m.group(1)].add((d.get("metadata") or {}).get("name"))
    for lv in sorted(claimed, key=lambda x: int(x.split("c")[1])):
        if lv in rows:
            continue
        evidence = MCS_DOC_EXEMPT.get(lv)
        if evidence is None:
            bad += 1
            fail("[mcs-documented]",
                 "workload(s) %s claim MCS category %s, which appears in NO row of "
                 "docs/SECURITY.md §3. The matrix is where the next 'next free' scan "
                 "looks and where a category can be RESERVED before its Deployment "
                 "exists; a claim that is not listed there is invisible to that scan — "
                 "which is exactly how s0:c49 was taken out from under a reservation. "
                 "Add the row." % (", ".join(sorted(claimed[lv])), lv))
            continue
        epath = os.path.join(docs, os.path.basename(evidence))
        if not os.path.exists(epath) or lv not in open(epath, encoding="utf-8").read():
            bad += 1
            fail("[mcs-documented]",
                 "MCS category %s (claimed by %s) is exempted from the matrix with the "
                 "rationale %r, but %s does not mention %s. An exemption whose stated "
                 "evidence does not exist is worse than no check: this gate already lost "
                 "weeks to one. Verify the rationale or drop the exemption."
                 % (lv, ", ".join(sorted(claimed[lv])), evidence, evidence, lv))
    if not bad:
        ok("[mcs-documented]",
           "all %d workload-claimed MCS categories appear in docs/SECURITY.md §3 (%d "
           "documented rows, %d self-verified exemption(s))"
           % (len(claimed), len(rows), len(MCS_DOC_EXEMPT)))



# ── 18) a CROSS-NAMESPACE gateway route needs a NetworkPolicy that admits it ──
# DECLARED AS A SURVIVING MUTATION IN THE FIRST CUT, AND CLOSED HERE. That cut said
# deriving "which gateway namespace must reach which UI pod" would need the gateway
# pods' real labels, "which only exist on a cluster". That was wrong twice over: the
# route table names the gateway AND its target, apps/*-gateway-*.yaml names each
# gateway's own destination namespace, and NAMESPACE-level admittance is all a
# NetworkPolicy from-set needs to be judged on. Nothing here needs a cluster.
#
# WHAT IT COSTS WHEN IT IS MISSING. manifests/networkpolicy/tier-ingress.yaml's
# hugmesh-frontend policy is `podSelector: {}` — it selects EVERY frontend pod, which
# makes every frontend pod default-deny for ingress — and its from-set is exactly
# hugmesh-frontend (self), devops and ingress-nginx. The superadmin Service Catalog
# console is the first frontend workload whose only front door is a gateway in
# ANOTHER namespace (hugmesh-superadmin-gateway, in hugmesh-pki), so without
# manifests/networkpolicy/superadmin-ui-ingress.yaml the pod runs Ready, `kubectl get`
# is clean, the Deployment is healthy — and every request through its gateway dies in
# the CNI with no event, no restart and no pod-side log. Deleting that one file used
# to be free.
#
# THE RULE, and it is deliberately narrow: for each in-cluster gateway route whose
# TARGET namespace differs from the GATEWAY's own namespace, if any Ingress
# NetworkPolicy in the target namespace selects the target pod (which makes it
# default-deny), then at least one of the policies selecting it must admit the
# gateway's namespace on the target port. Where NO policy selects the pod there is no
# default-deny and nothing to prove — that case is COUNTED AND NAMED on the pass
# line, never skipped in silence.
#
# Everything is read out of the tree: the gateway namespace from
# spec.destination.namespace, the target pod's labels from the Service selector and
# the backing workload, the peer namespace from
# `namespaceSelector.matchLabels[kubernetes.io/metadata.name]` (the convention
# db-ingress.yaml and tier-ingress.yaml already use throughout).
def _gateway_namespaces(root):
    """-> {gateway-instance-name: the namespace its Application deploys into}."""
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
            spec = d.get("spec") or {}
            values = ((spec.get("source") or {}).get("helm") or {}).get("values")
            if not isinstance(values, str):
                continue
            try:
                v = yaml.safe_load(values)
            except Exception:
                continue
            inst = ((v or {}).get("instance") or {}).get("name")
            ns = (spec.get("destination") or {}).get("namespace")
            if inst and ns:
                out[inst] = ns
    return out


def _selector_matches(sel, labels):
    """k8s LabelSelector semantics. `{}`/None selects EVERYTHING (k8s, not Python)."""
    if not sel:
        return True
    for k, v in (sel.get("matchLabels") or {}).items():
        if labels.get(k) != v:
            return False
    for expr in (sel.get("matchExpressions") or []):
        key, op = (expr or {}).get("key"), (expr or {}).get("operator")
        vals = (expr or {}).get("values") or []
        cur = labels.get(key)
        if op == "In" and cur not in vals:
            return False
        if op == "NotIn" and cur in vals:
            return False
        if op == "Exists" and key not in labels:
            return False
        if op == "DoesNotExist" and key in labels:
            return False
    return True


def _netpols(root):
    """-> [(relpath, ns, doc)] for every NetworkPolicy a kustomization actually renders.

    WIRED-ONLY, for the same reason [build-template-secret] counts only synced
    providers: a policy file that its own directory's kustomization does not list in
    `resources:` is never applied, so counting it as protection would let one deleted
    line re-open a route that dies in the CNI while the gate stayed green.
    """
    out = []
    for dirpath, _dn, filenames in os.walk(root):
        has_kz, resources = _kustomization_resources(dirpath)
        defns = None
        kz = os.path.join(dirpath, "kustomization.yaml")
        if os.path.exists(kz):
            try:
                defns = (yaml.safe_load(open(kz, encoding="utf-8")) or {}).get("namespace")
            except Exception:
                defns = None
        for name in sorted(filenames):
            if not name.endswith((".yaml", ".yml")):
                continue
            if has_kz and name not in resources:
                continue
            path = os.path.join(dirpath, name)
            for d in docs_of(path):
                if d.get("kind") != "NetworkPolicy":
                    continue
                meta = d.get("metadata") or {}
                out.append((os.path.relpath(path, root),
                            meta.get("namespace") or defns, d))
    return out


def _target_pod_port(svc_doc, route_port, wl_doc):
    """Resolve the Service port a route names down to the POD port a policy gates."""
    ports = (svc_doc.get("spec") or {}).get("ports") or []
    chosen = None
    for p in ports:
        if (p or {}).get("port") == route_port:
            chosen = p
            break
    if chosen is None and ports:
        chosen = ports[0]
    if chosen is None:
        return route_port
    tgt = chosen.get("targetPort", chosen.get("port"))
    if isinstance(tgt, int):
        return tgt
    spec = ((wl_doc.get("spec") or {}).get("template") or {}).get("spec") or {} \
        if wl_doc else {}
    for c in (spec.get("containers") or []):
        for cp in ((c or {}).get("ports") or []):
            if (cp or {}).get("name") == tgt:
                return cp.get("containerPort")
    return chosen.get("port")


def check_gateway_netpol(root):
    gw_ns = _gateway_namespaces(root)
    if not gw_ns:
        fail("[gateway-netpol]",
             "could not resolve ANY gateway's own namespace from apps/*gateway*.yaml "
             "(spec.destination.namespace). Every assertion below is derived from that "
             "map, so with it empty this check proves nothing and must not pass.")
        return
    services = _service_index(root)
    workloads = _workload_index(root)
    policies = _netpols(root)

    checked = bad = 0
    unrestricted = []
    for gw, routes in sorted(_gateways(root).items()):
        src_ns = gw_ns.get(gw)
        if not src_ns:
            continue
        for r in routes:
            if not isinstance(r, dict):
                continue
            m = URI_RE.match(r.get("uri") or "")
            if not m:
                continue
            svc, dst_ns = m.group(1), m.group(2)
            if dst_ns == src_ns:
                continue                      # same namespace: not this check's claim
            key = "%s.%s" % (svc, dst_ns)
            if key not in services:
                continue                      # [route-service] owns that failure
            svc_doc = services[key][1]
            sel = (svc_doc.get("spec") or {}).get("selector") or {}
            back = _backing_workload(root, key, services, workloads)
            if not back or not sel:
                continue                      # [federation-remote]/[route-service] own it
            wl_rel, wl_doc = back
            labels = (((wl_doc.get("spec") or {}).get("template") or {})
                      .get("metadata") or {}).get("labels") or {}
            port_txt = (r.get("uri") or "").rsplit(":", 1)[-1].rstrip("/")
            route_port = int(port_txt) if port_txt.isdigit() else 80
            pod_port = _target_pod_port(svc_doc, route_port, wl_doc)

            selecting = [(prel, p) for (prel, pns, p) in policies
                         if pns == dst_ns
                         and "Ingress" in ((p.get("spec") or {}).get("policyTypes")
                                           or ["Ingress"])
                         and _selector_matches((p.get("spec") or {}).get("podSelector"),
                                               labels)]
            if not selecting:
                unrestricted.append("%s -> %s (no Ingress policy selects that pod)"
                                    % (gw, key))
                continue
            checked += 1
            admitted = False
            for _prel, p in selecting:
                for rule in ((p.get("spec") or {}).get("ingress") or []):
                    froms = (rule or {}).get("from")
                    peer_ok = False
                    if not froms:
                        peer_ok = True         # `from` absent/empty == every source
                    for peer in (froms or []):
                        nsel = (peer or {}).get("namespaceSelector")
                        if nsel is None:
                            continue           # podSelector-only == same namespace only
                        want = (nsel.get("matchLabels") or {}).get(
                            "kubernetes.io/metadata.name")
                        if want is None or want == src_ns:
                            peer_ok = True
                            break
                    if not peer_ok:
                        continue
                    rports = (rule or {}).get("ports")
                    if not rports or any((rp or {}).get("port") in (pod_port, None)
                                         for rp in rports):
                        admitted = True
                        break
                if admitted:
                    break
            if admitted:
                continue
            bad += 1
            fail("[gateway-netpol]",
                 "gateway %s (namespace %r) route %r forwards to %s on pod port %s, but "
                 "NO NetworkPolicy in %r admits %r to that pod — %d policy/policies do "
                 "select it (%s), which makes it default-deny for Ingress. The pod runs "
                 "Ready, the Deployment is healthy and `kubectl get` is clean while "
                 "every request through this gateway dies in the CNI: no event, no "
                 "restart, no pod-side log, just a gateway timeout. Add a per-pod "
                 "ingress policy admitting %r on %s (see manifests/networkpolicy/"
                 "superadmin-ui-ingress.yaml) rather than widening the tier from-set, "
                 "which would admit every pod in %r to every pod in %r."
                 % (gw, src_ns, r.get("id"), key, pod_port, dst_ns, src_ns,
                    len(selecting), ", ".join(sorted(pr for pr, _ in selecting)),
                    src_ns, pod_port, src_ns, dst_ns))
    if not checked:
        fail("[gateway-netpol]",
             "not ONE cross-namespace gateway route landed on a pod that any Ingress "
             "NetworkPolicy selects, so this check asserted nothing. Either the route "
             "table or the policy set has drifted out from under it; a gate that "
             "matches nothing must not report a pass.")
    elif not bad:
        ok("[gateway-netpol]",
           "all %d cross-namespace gateway route(s) onto a default-denied pod are "
           "admitted by a NetworkPolicy naming the gateway's own namespace on the "
           "route's pod port; %d further cross-namespace route(s) land on pods NO "
           "Ingress policy selects (no default-deny, nothing to admit): %s"
           % (checked, len(unrestricted), "; ".join(sorted(unrestricted)) or "none"))


# ── 19) the ServiceAccount half of the identity matrix ───────────────────────
# DECLARED AS A SURVIVING MUTATION IN THE FIRST CUT, AND CLOSED HERE. [mcs-documented]
# pins the SELinux column of docs/SECURITY.md §3; the ServiceAccount column was still
# prose, so changing this console's `serviceAccountName` off the RESERVED
# `sa-service-catalog-ui` — or deleting the line, or deleting the ServiceAccount
# manifest — cost nothing. The SA is the workload's cluster identity: its RBAC, its
# projected token audience and the subject every Role/RoleBinding in the tree names.
#
# TWO ASSERTIONS, both derived:
#   (a) NO DANGLING BINDINGS. Every `serviceAccountName` a workload sets must resolve
#       to a ServiceAccount authored in the SAME namespace. A workload naming an SA
#       that does not exist never starts (the pod is rejected outright). Measured over
#       this tree: 0 violations today, so this is a floor, not a wish.
#   (b) THE MATRIX IS BINDING WHERE BOTH HALVES EXIST. Where docs/SECURITY.md §3 pins
#       one `sa-*` name against an MCS level, and a ServiceAccount by that name really
#       is authored in the workload's namespace, the workload claiming that level MUST
#       bind it. Both halves must exist for the row to be enforceable — which is why
#       rows whose SA is `per-app SA` / `(per-build)` / `—`, and rows naming an SA no
#       manifest creates, are COUNTED AND NAMED on the pass line instead of being
#       dropped. There are 14 of the latter in this tree: a real, pre-existing gap
#       (the documented `sa-admin-bff`, `sa-federation`, `sa-mod-bff`… do not exist as
#       objects at all), out of this unit's scope to fix, and stated rather than
#       hidden so the next reader sees the number instead of a clean green line.
SA_CELL_RE = re.compile(r"^`(sa-[a-z0-9][a-z0-9-]*)`$")


def check_workload_service_accounts(root):
    docs = _docs_dir(root)
    sec = os.path.join(docs, "SECURITY.md")
    if not os.path.exists(sec):
        fail("[workload-sa]",
             "cannot read %s (docs dir %r) — the §3 identity matrix is the authority "
             "for the ServiceAccount column, so with it unreadable this check proves "
             "nothing. Set HUGMESH_DOCS_DIR if the docs live elsewhere." % (sec, docs))
        return

    accounts = set()
    for path in yaml_files(root):
        for d in docs_of(path):
            if d.get("kind") == "ServiceAccount":
                meta = d.get("metadata") or {}
                accounts.add((meta.get("name"), meta.get("namespace")))
    if not accounts:
        fail("[workload-sa]",
             "found ZERO `kind: ServiceAccount` manifests under specs/cluster. Both "
             "assertions below resolve against that set, so with it empty every binding "
             "would look dangling and every matrix row unenforceable — the extraction "
             "has drifted, fix it rather than letting the check pass.")
        return

    bad = 0
    bound = 0
    for wl_rel, wl_ns, wl in _workload_index(root):
        spec = ((wl.get("spec") or {}).get("template") or {}).get("spec") or {}
        sa = spec.get("serviceAccountName")
        if not sa or sa == "default":
            continue
        bound += 1
        if (sa, wl_ns) in accounts:
            continue
        bad += 1
        fail("[workload-sa]",
             "%s binds serviceAccountName %r, but NO ServiceAccount by that name is "
             "authored in namespace %r anywhere under specs/cluster. The kubelet cannot "
             "admit a pod whose ServiceAccount does not exist, so this workload never "
             "starts at all — and unlike a bad image it fails before any container log "
             "exists to explain it." % (wl_rel, sa, wl_ns))

    rows = defaultdict(list)
    for line in open(sec, encoding="utf-8").read().splitlines():
        if not line.startswith("|"):
            continue
        cells = [c.strip() for c in line.strip("|").split("|")]
        if len(cells) < 2:
            continue
        for lv in re.findall(r"`(s0:c\d+)`", line):
            rows[lv].append((cells[0], cells[1]))

    claimed = defaultdict(list)
    for wl_rel, wl_ns, wl in _workload_index(root):
        for m in MCS_RE.finditer(dump_of(wl)):
            claimed[m.group(1)].append((wl_rel, wl_ns, wl))

    unenforceable = []

    # (b2) THE DOCS SIDE OF THE SAME BINDING. Checked FIRST, and separately, because
    # the (b) loop below can only enforce a row whose named SA really exists — so
    # RENAMING THE CELL would otherwise un-enforce the row in silence, which is the
    # same "edit the authority instead of the artefact" move [mcs-documented]'s
    # self-verifying exemptions exist to stop. Read the other way round: a workload
    # that binds a reserved-shape `sa-*` ServiceAccount which EXISTS must be named by
    # its own MCS row. Rows whose SA cell is `per-app SA` / `(per-build)` / `—` are
    # counted as unenforceable rather than failed — that is a documentation posture,
    # not a contradiction.
    sa_bound = 0
    for wl_rel, wl_ns, wl in _workload_index(root):
        got = (((wl.get("spec") or {}).get("template") or {})
               .get("spec") or {}).get("serviceAccountName")
        if not got or not got.startswith("sa-") or (got, wl_ns) not in accounts:
            continue
        for m in MCS_RE.finditer(dump_of(wl)):
            row = rows.get(m.group(1))
            if not row or len(row) != 1:
                continue
            doc_name, sa_cell = row[0]
            cell = SA_CELL_RE.match(sa_cell)
            if not cell:
                unenforceable.append("%s (%s) binds %s but its matrix row states %r, "
                                     "not one reserved name"
                                     % (m.group(1), doc_name, got, sa_cell))
                continue
            sa_bound += 1
            if cell.group(1) == got:
                continue
            bad += 1
            fail("[workload-sa]",
                 "%s binds ServiceAccount %r and claims MCS category %s, but that "
                 "category's docs/SECURITY.md §3 row (%s) reserves %r instead. The "
                 "matrix is the authority the next 'which identity is free' scan reads, "
                 "so the two must not disagree — and editing the ROW rather than the "
                 "manifest is exactly how a reservation gets quietly voided. Fix "
                 "whichever half is wrong; do not leave both."
                 % (wl_rel, got, m.group(1), doc_name, cell.group(1)))

    enforced = 0
    for lv in sorted(claimed, key=lambda x: int(x.split("c")[1])):
        row = rows.get(lv)
        if not row or len(row) != 1:
            continue                       # [mcs-documented] owns the missing/dup row
        doc_name, sa_cell = row[0]
        m = SA_CELL_RE.match(sa_cell)
        if not m:
            continue                       # `per-app SA` / `(per-build)` / `—`
        want = m.group(1)
        for wl_rel, wl_ns, wl in claimed[lv]:
            if (want, wl_ns) not in accounts:
                unenforceable.append("%s pins %s for %s but no such ServiceAccount is "
                                     "authored in %s" % (lv, want, doc_name, wl_ns))
                continue
            enforced += 1
            got = (((wl.get("spec") or {}).get("template") or {})
                   .get("spec") or {}).get("serviceAccountName")
            if got == want:
                continue
            bad += 1
            fail("[workload-sa]",
                 "%s claims MCS category %s, whose docs/SECURITY.md §3 row RESERVES "
                 "ServiceAccount %r — and that ServiceAccount is authored in %r — but "
                 "the workload binds %r. The SA is the pod's cluster identity: its "
                 "RBAC, its projected-token audience and the subject every RoleBinding "
                 "names. Drifting off the reserved name leaves the reserved SA an "
                 "unused object and the pod running as something the matrix does not "
                 "describe, with neither half complaining."
                 % (wl_rel, lv, want, wl_ns, got))

    if not enforced or not sa_bound:
        fail("[workload-sa]",
             "not ONE workload-claimed MCS category resolved to a docs/SECURITY.md §3 "
             "row naming an `sa-*` ServiceAccount that also exists in the tree, so "
             "assertion (b) checked nothing. The matrix format or the SA naming "
             "convention has drifted; fix the parse rather than leaving a vacuous pass.")
    elif not bad:
        ok("[workload-sa]",
           "all %d workload ServiceAccount binding(s) resolve to a ServiceAccount "
           "authored in the same namespace; all %d whose docs/SECURITY.md §3 row "
           "reserves a concrete `sa-*` name bind exactly that name, and all %d that "
           "bind a reserved-shape `sa-*` are named by their own matrix row (both "
           "directions, so neither the manifest nor the doc can drift alone); %d "
           "further matrix row(s) are NOT enforceable (stated, not skipped): %s"
           % (bound, enforced, sa_bound, len(unenforceable),
              "; ".join(sorted(set(unenforceable))) or "none"))


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
    check_velero_backups(root)
    check_hpa_replicas(root)
    check_federation_remotes(root)
    check_remote_strip_prefix(root)
    check_remote_route_targets(root)
    check_build_template_secrets(root)
    check_mcs_documented(root)
    check_gateway_netpol(root)
    check_workload_service_accounts(root)
    for check, msg in notes:
        print("  PASS %-24s %s" % (check, msg))
    for check, msg in failures:
        print("  FAIL %-24s %s" % (check, msg))
    print()
    print("== %d checks passed, %d findings ==" % (len(notes), len(failures)))
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
