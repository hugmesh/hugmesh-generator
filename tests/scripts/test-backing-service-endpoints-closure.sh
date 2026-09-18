#!/usr/bin/env bash
# test-backing-service-endpoints-closure.sh — the manifest-side guard for operator
# DECISION 34a/34b (2026-09-17, hugmesh-generator#347 answer table,
# hugmesh-admin-bff-api#9).
#
# WHY IT EXISTS. 34a was one of the SIX answers that went AGAINST the
# recommendation. The call put to the operator was a SINGLE
# `backing-service-endpoints` ConfigMap in hugmesh-backend; the operator DECLINED
# it and chose ONE ConfigMap PER NAMESPACE — the same object name and the same key
# scheme in every namespace on the managed-Postgres axis — accepting the cost (a
# fan-out writer in admin-bff and one RBAC grant per namespace) deliberately.
#
# The generator manifests ARE that answer's artefact, and before this file nothing
# in this repo tested them. An adversarial review measured exactly that on
# 2026-09-17: five manifest mutations were applied to the branch that shipped the
# answer and FIVE SURVIVED — including a literal revert to the single
# hugmesh-backend object the operator had declined — while every guard the pull
# request cited as "Verification" stayed green (test-guard-integrity.sh 20/0,
# test-kind-profile-app-closure.sh 23/0, test-argocd-serverside-diff.sh 17/0,
# tests/cluster/test-bootstrap-applies-baked-apps.sh 48/0,
# test-brand-path-validation.sh 20/0). Those suites were green BEFORE the change
# and green after every revert of it: they are regression checks that nothing else
# broke, not verification of this work. The Java half (admin-bff-api
# BackingServiceEndpointPlanTest) does go red on a hardcoded namespace, but it
# asserts a Java String constant in a DIFFERENT repo with no causal link to any
# manifest — it stays green while the shipped manifests are the declined shape.
#
# So: this suite goes RED when decision 34a is reverted, in either direction.
#
# WHAT IT PINS
#   1. THE AXIS. The object exists, with the decided name, in EVERY namespace on
#      the axis — and is REACHED by its directory's kustomization.yaml. Deleting
#      the pki + games objects (the literal revert to the declined single-object
#      shape) fails here, and so does deleting the owncast / tube / forum ones.
#   2. THE FAN-OUT GRANT. Role + RoleBinding `backing-service-endpoints-writer` in
#      every axis namespace, resourceNames-closed to the one object, bound to the
#      SA admin-bff already runs as. Deleting the fan-out fails.
#   3. THE KEYSTONE, MECHANICALLY. `RespectIgnoreDifferences=true` must be in the
#      owning Application's syncOptions, and its `ignoreDifferences` jsonPointers
#      must equal the ConfigMap's data keys EXACTLY — both directions. This is the
#      check whose absence apps/16 records in its own comment: its sibling pointer
#      list was hand-maintained, fell behind at 12 pointers against 14 elements,
#      and a superadmin toggle of either unlisted slug was selfHealed straight back
#      to git's baseline with the CR still reporting success. A hand-maintained
#      list with no recomputation is not a keystone, it is a comment.
#   4. BYTE-IDENTITY. Every seeded value is character-for-character a literal that
#      is already in a consumer Deployment, carries no credential and no `$(VAR)`
#      (Kubernetes does NOT expand `$(VAR)` inside ConfigMap data), and its two
#      fields differ only by URL scheme. Corrupting a seeded host fails.
#   5. CONSUMER DRIFT, the converse. A Deployment that carries a plain
#      credential-free Postgres URL in an axis namespace must either be seeded or
#      be named in UNSEEDED_CONSUMERS with a written reason. A new BFF that lands a
#      literal and no key is caught the day it lands, not the day someone notices.
#   6. AXIS DRIFT. A manifests directory that holds a Postgres address must map to
#      a namespace that is ON the axis or in EXCLUDED_NAMESPACES with a written
#      reason. This is what stops the axis itself from rotting into a list someone
#      once measured.
#   Both allowlists carry the ANTI-ROT converse this repo already applies to
#   tests/scripts/test-guard-integrity.sh's ALLOW_UNWIRED: an entry that no longer
#   describes a real gap is DEAD and fails, because a stale exemption is how a
#   closed hole stays exempt forever.
#
# WHAT IT DELIBERATELY DOES NOT CLAIM. It cannot tell you that a `configMapKeyRef`
# edit does not restart a running pod (that is the Kubernetes contract decision 34b
# rests on, and it must be exercised on a cluster), nor that the rolling restart
# lands cleanly under mTLS, nor anything about Liquibase's first contact with an
# empty managed database. Those stay on the issue as human-verification items.
#
# Offline and hermetic: bash + python3 stdlib only. No PyYAML, no cluster, no
# network, no root, no docker.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

# The analysed tree. An ENV var, because the negative controls below must point the
# same analyser at trees carrying each defect on purpose. Capture what was
# INHERITED before any defaulting — this check is worthless if it runs after the
# assignment that always sets these.
BSE_INHERITED=""
for v in BSE_ROOT BSE_KEY_FLOOR BSE_AXIS_FLOOR BSE_DEPLOY_FLOOR; do
  [ -n "${!v+x}" ] && BSE_INHERITED="${BSE_INHERITED} ${v}"
done
BSE_ROOT="${BSE_ROOT:-${REPO}}"

# Whether this invocation is a control run is a POSITIONAL ARGUMENT, never an
# environment variable: an inherited env var would silently downgrade a real CI run
# to a control run — skipping the controls AND relaxing the floors — and nothing
# would say so. (The same trap is recorded in
# tests/scripts/test-kind-profile-app-closure.sh and test-argocd-serverside-diff.sh.)
CHILD=no
[ "${1:-}" = "--analyse-only" ] && CHILD=yes

pass=0; fail=0
ok()  { echo "  PASS $*"; pass=$((pass+1)); }
bad() { echo "  FAIL $*"; fail=$((fail+1)); }

# A guard that skips is a guard that never guards; this repo has shipped several.
command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }

# Vacuity floors. If the scanner goes blind — the manifests tree moves, the key
# scheme changes, the file naming changes — it must FAIL rather than report a tidy
# green over a set it is no longer computing. MEASURED on this tree 2026-09-17:
# 10 seeded keys, 6 axis namespaces, 10 deployment.yaml files under
# specs/cluster/manifests carry a postgresql:// literal.
BSE_KEY_FLOOR="${BSE_KEY_FLOOR:-10}"
BSE_AXIS_FLOOR="${BSE_AXIS_FLOOR:-6}"
BSE_DEPLOY_FLOOR="${BSE_DEPLOY_FLOOR:-8}"

# A REAL run must not be able to inherit a different tree or relaxed floors from
# the environment — that is how a "green" CI run comes to mean nothing.
if [ "${CHILD}" = "no" ] && [ -n "${BSE_INHERITED}" ]; then
  echo "FATAL: refusing to run with inherited override(s):${BSE_INHERITED}" >&2
  echo "       (they exist for this file's own negative controls, which pass --analyse-only)" >&2
  exit 1
fi

echo "== backing-service-endpoints closure (decision 34a/34b) =="
echo "   tree: ${BSE_ROOT}"
echo

BSE_ROOT="${BSE_ROOT}" BSE_KEY_FLOOR="${BSE_KEY_FLOOR}" BSE_AXIS_FLOOR="${BSE_AXIS_FLOOR}" \
BSE_DEPLOY_FLOOR="${BSE_DEPLOY_FLOOR}" python3 - <<'PY'
import os, re, sys

root = os.environ["BSE_ROOT"]
KEY_FLOOR    = int(os.environ["BSE_KEY_FLOOR"])
AXIS_FLOOR   = int(os.environ["BSE_AXIS_FLOOR"])
DEPLOY_FLOOR = int(os.environ["BSE_DEPLOY_FLOOR"])

P, F = 0, 0
def ok(m):
    global P
    P += 1
    print("  PASS %s" % m)
def bad(m):
    global F
    F += 1
    print("  FAIL %s" % m)

CM_NAME   = "backing-service-endpoints"
ROLE_NAME = "backing-service-endpoints-writer"
SA_NAME   = "backups-effector"
SA_NS     = "hugmesh-backend"
FIELDS    = ("r2dbc-url", "liquibase-url")
SCHEME    = {"r2dbc-url": "r2dbc:postgresql://", "liquibase-url": "jdbc:postgresql://"}

# ── THE AXIS ─────────────────────────────────────────────────────────────────
# The SIX namespaces operator decision 34a fans out over: every namespace in
# specs/cluster that holds a Postgres address, minus hugmesh-frontend (see
# EXCLUDED_NAMESPACES). `file` is where that namespace's object lives and `app` is
# the ArgoCD Application that delivers it — three of the six are created by their
# own OPTIONAL-service Application, so their object must ship from THAT
# Application's directory or the always-on one could never sync on a default mesh.
# Leg 6 below re-derives this set from the tree, so it cannot quietly fall behind.
AXIS = [
    ("hugmesh-backend", "specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-backend.yaml",
     "specs/cluster/manifests/backing-service-endpoints/rbac.yaml",
     "specs/cluster/apps/17-backing-service-endpoints.yaml"),
    ("hugmesh-pki", "specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-pki.yaml",
     "specs/cluster/manifests/backing-service-endpoints/rbac.yaml",
     "specs/cluster/apps/17-backing-service-endpoints.yaml"),
    ("hugmesh-games", "specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-games.yaml",
     "specs/cluster/manifests/backing-service-endpoints/rbac.yaml",
     "specs/cluster/apps/17-backing-service-endpoints.yaml"),
    ("hugmesh-owncast", "specs/cluster/manifests/owncast/backing-service-endpoints.yaml",
     "specs/cluster/manifests/owncast/backing-service-endpoints.yaml",
     "specs/cluster/apps/52-owncast.yaml"),
    ("hugmesh-tube", "specs/cluster/manifests/tube/backing-service-endpoints.yaml",
     "specs/cluster/manifests/tube/backing-service-endpoints.yaml",
     "specs/cluster/apps/53-tube.yaml"),
    ("hugmesh-forum", "specs/cluster/manifests/forum/backing-service-endpoints.yaml",
     "specs/cluster/manifests/forum/backing-service-endpoints.yaml",
     "specs/cluster/apps/30-phpbb.yaml"),
]

# A manifests directory whose Deployment carries a plain, credential-free Postgres
# URL that is NOT a ConfigMap key. dir<TAB>reason. Anti-rot: an entry whose
# directory no longer has such a literal is dead and fails.
UNSEEDED_CONSUMERS = {
    "character-forge-bff-api": "no specs/cluster/backing-services.yaml registry id; minting one is a registry decision (tier, dbName, esoSecret, vaultPath, managed target) nobody has made",
    "federation-api":          "no registry id, and federation-db ships initdb/90-citus.sh while vanilla RDS has no Citus (backing-services.yaml:262-263) — it cannot join the managed axis at all",
    "mesh-bff-api":            "no specs/cluster/backing-services.yaml registry id; same undecided registry question as character-forge",
    "owncast":                 "real env seam but no registry id; its namespace ConfigMap ships with data:{} for exactly this reason",
    "tube":                    "real env seam but no registry id; its namespace ConfigMap ships with data:{} for exactly this reason",
}

# A namespace that holds a Postgres address and is deliberately NOT on the axis.
# ns<TAB>reason. Anti-rot: an entry that is on the axis, or that no longer holds an
# address anywhere in the tree, is dead and fails.
EXCLUDED_NAMESPACES = {
    "hugmesh-frontend": "the SEVENTH namespace with a Postgres address, and correctly off the axis: every address there is a route-access URL with the password interpolated INTO it (r2dbc:postgresql://fe_gateway:$(ROUTE_ACCESS_DB_PASSWORD)@...), Kubernetes does not expand $(VAR) inside ConfigMap data, and a ConfigMap is not a Secret",
}
# Directories whose manifests carry an address but which pin NO namespace of their
# own, so no namespace can be derived from them. dir<TAB>reason.
EXCLUDED_DIRS = {
    "casdoor-domain": "the ENV-PARAMETERIZED per-domain Casdoor base; its namespace (<nsPrefix>-pki) is injected per instance by the casdoor-domains ApplicationSet, so this directory pins none and the axis cannot name it",
    "observability":  "uptrace's own DSN carries the password inline (postgres://uptrace:${UPTRACE_PG_PASSWORD}@uptrace-pg) and the directory pins no namespace; a credential-bearing address cannot live in a git-committed ConfigMap",
}

def read(rel):
    p = os.path.join(root, rel)
    if not os.path.isfile(p):
        return None
    return open(p, encoding="utf-8", errors="replace").read()

def docs(text):
    """Split a multi-document YAML file, comment lines stripped."""
    out, cur = [], []
    for line in text.split("\n"):
        if line.rstrip() == "---":
            out.append("\n".join(cur)); cur = []
            continue
        if line.lstrip().startswith("#"):
            continue
        cur.append(line)
    out.append("\n".join(cur))
    return [d for d in out if d.strip()]

def kind_of(doc):
    m = re.search(r"^kind:\s*(\S+)\s*$", doc, re.M)
    return m.group(1) if m else ""

def meta(doc, field):
    """metadata.<field> — the FIRST two-space-indented occurrence, i.e. inside
    metadata:, never a nested pod-template or subject field (those are deeper)."""
    m = re.search(r"^metadata:\s*$((?:\n(?:[ \t].*)?)*)", doc, re.M)
    if not m:
        return ""
    for line in m.group(1).split("\n"):
        mm = re.match(r"^  %s:\s*(\S.*?)\s*$" % field, line)
        if mm:
            return mm.group(1)
    return ""

def cm_data(doc):
    """The ConfigMap's data keys and values. `data: {}` is an empty mapping."""
    m = re.search(r"^data:\s*(\{\s*\})?\s*$", doc, re.M)
    if not m:
        return None
    if m.group(1):
        return {}
    rest = doc[m.end():]
    out = {}
    for line in rest.split("\n"):
        if line.strip() == "":
            continue
        if not line.startswith("  "):
            break
        mm = re.match(r'^  ([A-Za-z0-9][A-Za-z0-9._-]*):\s*"(.*)"\s*$', line)
        if mm:
            out[mm.group(1)] = mm.group(2)
    return out

def kust_resources(rel_dir):
    """The `resources:` list of a directory's kustomization.yaml."""
    text = read(os.path.join(rel_dir, "kustomization.yaml"))
    if text is None:
        return None
    body = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    m = re.search(r"^resources:\s*$((?:\n(?:[ \t].*)?)*)", body, re.M)
    if not m:
        return []
    out = []
    for line in m.group(1).split("\n"):
        mm = re.match(r"^\s+-\s+(\S+?)\s*(#.*)?$", line)
        if mm:
            out.append(mm.group(1))
        elif line.strip() and not line.startswith((" ", "\t")):
            break
    return out

def kust_namespace(rel_dir):
    text = read(os.path.join(rel_dir, "kustomization.yaml"))
    if text is None:
        return ""
    for line in text.split("\n"):
        if line.lstrip().startswith("#"):
            continue
        m = re.match(r"^namespace:\s*(\S+)\s*$", line)
        if m:
            return m.group(1)
    return ""

# ── LEG 1: the object exists in EVERY axis namespace, and is REACHED ──────────
print("-- 1) one backing-service-endpoints ConfigMap per axis namespace (decision 34a) --")
seeded = {}          # ns -> {key: value}
missing_axis = []
for ns, cm_rel, _rbac_rel, _app_rel in AXIS:
    text = read(cm_rel)
    if text is None:
        missing_axis.append("%s: %s does not exist" % (ns, cm_rel))
        continue
    found = None
    for d in docs(text):
        if kind_of(d) == "ConfigMap" and meta(d, "name") == CM_NAME:
            found = d
            break
    if found is None:
        missing_axis.append("%s: %s carries no ConfigMap named %s" % (ns, cm_rel, CM_NAME))
        continue
    if meta(found, "namespace") != ns:
        missing_axis.append("%s: the ConfigMap in %s declares namespace %r"
                            % (ns, cm_rel, meta(found, "namespace")))
        continue
    data = cm_data(found)
    if data is None:
        missing_axis.append("%s: the ConfigMap in %s has no data: block at all" % (ns, cm_rel))
        continue
    seeded[ns] = data
    # REACHED: a file kustomize never renders is a file that does not ship.
    rel_dir = os.path.dirname(cm_rel)
    res = kust_resources(rel_dir)
    if res is None:
        missing_axis.append("%s: %s/kustomization.yaml does not exist" % (ns, rel_dir))
    elif os.path.basename(cm_rel) not in res:
        missing_axis.append("%s: %s is not listed in %s/kustomization.yaml resources: — "
                            "kustomize never renders it, so the object does not ship"
                            % (ns, os.path.basename(cm_rel), rel_dir))
if missing_axis:
    bad("the per-namespace fan-out is INCOMPLETE — this is decision 34a reverted "
        "toward the single-object shape the operator declined:")
    for m in missing_axis:
        print("         %s" % m)
else:
    ok("all %d axis namespaces carry a %r ConfigMap that their kustomization renders"
       % (len(AXIS), CM_NAME))

if len(AXIS) < AXIS_FLOOR:
    bad("the axis is %d namespaces, floor is %d — decision 34a's census has been "
        "shrunk in this guard itself" % (len(AXIS), AXIS_FLOOR))
else:
    ok("axis cardinality %d >= floor %d" % (len(AXIS), AXIS_FLOOR))

all_keys = {}        # ns -> sorted keys
total_keys = 0
for ns in seeded:
    all_keys[ns] = sorted(seeded[ns])
    total_keys += len(seeded[ns])
if total_keys < KEY_FLOOR:
    bad("only %d seeded key(s) found across the axis, floor is %d — the scanner has "
        "gone blind, or the seed was emptied" % (total_keys, KEY_FLOOR))
else:
    ok("%d seeded key(s) across the axis (floor %d)" % (total_keys, KEY_FLOOR))

# ── LEG 2: the RBAC fan-out, one grant per namespace ─────────────────────────
print()
print("-- 2) the fan-out grant exists in every axis namespace (the N RBAC grants 34a paid for) --")
rbac_problems = []
for ns, _cm_rel, rbac_rel, _app_rel in AXIS:
    text = read(rbac_rel)
    if text is None:
        rbac_problems.append("%s: %s does not exist" % (ns, rbac_rel))
        continue
    role = binding = None
    for d in docs(text):
        k = kind_of(d)
        if k == "Role" and meta(d, "name") == ROLE_NAME and meta(d, "namespace") == ns:
            role = d
        if k == "RoleBinding" and meta(d, "name") == ROLE_NAME and meta(d, "namespace") == ns:
            binding = d
    if role is None:
        rbac_problems.append("%s: no Role %r in that namespace (%s)" % (ns, ROLE_NAME, rbac_rel))
    else:
        if CM_NAME not in role:
            rbac_problems.append("%s: the Role is not resourceNames-closed to %r" % (ns, CM_NAME))
        if not re.search(r'verbs:\s*\[[^\]]*"patch"', role):
            rbac_problems.append("%s: the Role grants no patch verb — the writer cannot write"
                                 % ns)
    if binding is None:
        rbac_problems.append("%s: no RoleBinding %r in that namespace (%s)" % (ns, ROLE_NAME, rbac_rel))
    else:
        if not re.search(r"name:\s*%s\b" % re.escape(SA_NAME), binding) or \
           not re.search(r"namespace:\s*%s\b" % re.escape(SA_NS), binding):
            rbac_problems.append("%s: the RoleBinding does not bind ServiceAccount %s/%s — the "
                                 "grant is inert" % (ns, SA_NS, SA_NAME))
        if not re.search(r"^roleRef:", binding, re.M) or ROLE_NAME not in binding:
            rbac_problems.append("%s: the RoleBinding's roleRef does not name %r" % (ns, ROLE_NAME))
if rbac_problems:
    bad("the RBAC fan-out is INCOMPLETE — decision 34a's accepted cost is only part paid:")
    for m in rbac_problems:
        print("         %s" % m)
else:
    ok("every axis namespace has a resourceNames-closed Role + RoleBinding bound to %s/%s"
       % (SA_NS, SA_NAME))

# ── LEG 3: the keystone, recomputed ──────────────────────────────────────────
print()
print("-- 3) the ignoreDifferences keystone is RECOMPUTED, not hand-maintained --")
key_problems = []
for ns, _cm_rel, _rbac_rel, app_rel in AXIS:
    text = read(app_rel)
    if text is None:
        key_problems.append("%s: its owning Application %s does not exist" % (ns, app_rel))
        continue
    body = "\n".join(l for l in text.split("\n") if not l.lstrip().startswith("#"))
    want = set("/data/%s" % k for k in seeded.get(ns, {}))
    # The ignoreDifferences entry for THIS object, if any.
    got = set()
    have_entry = False
    for m in re.finditer(r"(?ms)^\s*-\s*group:.*?(?=^\s*-\s*group:|\Z)", body):
        blk = m.group(0)
        if ("kind: ConfigMap" in blk and re.search(r"name:\s*%s\b" % re.escape(CM_NAME), blk)
                and re.search(r"namespace:\s*%s\b" % re.escape(ns), blk)):
            have_entry = True
            got |= set(re.findall(r"^\s*-\s*(/data/\S+)\s*$", blk, re.M))
    if want and not have_entry:
        key_problems.append("%s: %d seeded key(s) and NO ignoreDifferences entry in %s — "
                            "selfHeal re-applies git's baseline every sync interval and the "
                            "effector's write is undone while the ledger still reports managed"
                            % (ns, len(want), app_rel))
    elif not want and have_entry:
        key_problems.append("%s: an ignoreDifferences entry exists in %s for a ConfigMap with NO "
                            "data keys — it un-enforces nothing and implies a writer that has "
                            "nothing to write" % (ns, app_rel))
    elif want != got:
        key_problems.append("%s: the jsonPointers in %s do NOT equal the ConfigMap's keys. "
                            "missing exemption(s): %s ; orphan pointer(s): %s"
                            % (ns, app_rel,
                               ", ".join(sorted(want - got)) or "none",
                               ", ".join(sorted(got - want)) or "none"))
    # RespectIgnoreDifferences is the half that makes selfHeal honour the block.
    if want and "RespectIgnoreDifferences=true" not in body:
        key_problems.append("%s: %s has an ignoreDifferences block but NO "
                            "RespectIgnoreDifferences=true in syncOptions — selfHeal ignores "
                            "the exemptions entirely and the write is reverted within a sync "
                            "interval" % (ns, app_rel))
if key_problems:
    bad("the keystone does not close:")
    for m in key_problems:
        print("         %s" % m)
else:
    ok("every axis namespace's exemption set equals its ConfigMap's key set exactly, and "
       "every Application that needs RespectIgnoreDifferences=true has it")

# ── LEG 4: byte-identity, and no credential in a git-committed ConfigMap ─────
print()
print("-- 4) every seeded value is byte-identical to a consumer Deployment literal --")
deploy_files, deploy_text = [], ""
mdir = os.path.join(root, "specs/cluster/manifests")
if os.path.isdir(mdir):
    for d in sorted(os.listdir(mdir)):
        p = os.path.join(mdir, d, "deployment.yaml")
        if os.path.isfile(p):
            t = open(p, encoding="utf-8", errors="replace").read()
            if "postgresql://" in t:
                deploy_files.append(d)
            deploy_text += t + "\n"
if len(deploy_files) < DEPLOY_FLOOR:
    bad("only %d Deployment(s) under specs/cluster/manifests carry a postgresql:// literal, "
        "floor is %d — the byte-identity leg is reading almost nothing"
        % (len(deploy_files), DEPLOY_FLOOR))
else:
    ok("%d consumer Deployment(s) scanned for literals (floor %d)"
       % (len(deploy_files), DEPLOY_FLOOR))

value_problems = []
ids_seen = {}
for ns, data in sorted(seeded.items()):
    for key, val in sorted(data.items()):
        if "." not in key:
            value_problems.append("%s/%s: key is not <service-id>.<field>" % (ns, key))
            continue
        sid, field = key.rsplit(".", 1)
        if field not in FIELDS:
            value_problems.append("%s/%s: unknown field %r (expected one of %s)"
                                  % (ns, key, field, ", ".join(FIELDS)))
            continue
        if not val.startswith(SCHEME[field]):
            value_problems.append("%s/%s: value does not start with %r"
                                  % (ns, key, SCHEME[field]))
        if "$(" in val or "@" in val:
            value_problems.append("%s/%s: the value carries a credential or a $(VAR) — "
                                  "a git-committed, world-readable ConfigMap must never hold "
                                  "one, and Kubernetes does not expand $(VAR) inside ConfigMap "
                                  "data" % (ns, key))
        if ('value: "%s"' % val) not in deploy_text:
            value_problems.append("%s/%s: the value is NOT byte-identical to any consumer "
                                  "Deployment literal — introducing this object would move a "
                                  "self-hosted mesh's database. value=%r" % (ns, key, val))
        ids_seen.setdefault((ns, sid), {})[field] = val
for (ns, sid), fields in sorted(ids_seen.items()):
    if set(fields) != set(FIELDS):
        value_problems.append("%s/%s: %d key(s), expected both %s — miss one and Liquibase or "
                              "the runtime pool silently targets the wrong host"
                              % (ns, sid, len(fields), " + ".join(FIELDS)))
        continue
    a = fields["r2dbc-url"][len(SCHEME["r2dbc-url"]):]
    b = fields["liquibase-url"][len(SCHEME["liquibase-url"]):]
    if a != b:
        value_problems.append("%s/%s: the two handles disagree after the scheme (%r vs %r) — "
                              "Liquibase and the runtime pool would target different databases"
                              % (ns, sid, a, b))
# The key prefix must be a registry id, verbatim.
reg = read("specs/cluster/backing-services.yaml") or ""
reg_ids, cur, tier, docs_only = {}, None, None, None
for line in reg.split("\n"):
    m = re.match(r"^\s*-\s*id:\s*(\S+)\s*$", line)
    if m:
        if cur:
            reg_ids[cur] = (tier, docs_only)
        cur, tier, docs_only = m.group(1), None, None
        continue
    m = re.match(r"^\s*tier:\s*(\d+)\s*$", line)
    if m and cur:
        tier = int(m.group(1))
    m = re.match(r"^\s*docsOnly:\s*(\S+)\s*$", line)
    if m and cur:
        docs_only = m.group(1).strip().lower() == "true"
if cur:
    reg_ids[cur] = (tier, docs_only)
for (ns, sid) in sorted(ids_seen):
    if sid not in reg_ids:
        value_problems.append("%s/%s: the key prefix is not a specs/cluster/backing-services.yaml "
                              "id — an id invented in a manifest is correct the day it is "
                              "written and wrong forever after (#58)" % (ns, sid))
    else:
        t, d = reg_ids[sid]
        if d or (t not in (1, 2)):
            value_problems.append("%s/%s: registry entry is tier %s docsOnly=%s — the effector "
                                  "cannot actuate it" % (ns, sid, t, d))
if value_problems:
    bad("the seeded values do not hold:")
    for m in value_problems:
        print("         %s" % m)
else:
    ok("all %d seeded value(s) are byte-identical, credential-free, paired, and carry a "
       "tier-1/2 registry id" % total_keys)

# ── LEG 5: consumer drift, the converse ──────────────────────────────────────
print()
print("-- 5) no consumer carries a plain Postgres literal that the axis does not know about --")
drift, dirs_with_unseeded = [], set()
seeded_values = set()
for data in seeded.values():
    seeded_values |= set(data.values())
if os.path.isdir(mdir):
    for d in sorted(os.listdir(mdir)):
        p = os.path.join(mdir, d, "deployment.yaml")
        if not os.path.isfile(p):
            continue
        for line in open(p, encoding="utf-8", errors="replace"):
            if line.lstrip().startswith("#"):
                continue
            m = re.search(r'value:\s*"((?:r2dbc|jdbc):postgresql://[^"]*)"', line)
            if not m:
                continue
            val = m.group(1)
            if "$(" in val or "@" in val:
                continue           # credential-bearing: cannot join this axis at all
            if val in seeded_values:
                continue
            dirs_with_unseeded.add(d)
            if d not in UNSEEDED_CONSUMERS:
                drift.append("%s/deployment.yaml carries an unseeded plain literal %r and is "
                             "not in UNSEEDED_CONSUMERS — either give it a key or record why "
                             "it has none" % (d, val))
stale_unseeded = [d for d in UNSEEDED_CONSUMERS if d not in dirs_with_unseeded]
noreason = [d for d, r in UNSEEDED_CONSUMERS.items() if len(r.strip()) < 20]
if drift:
    bad("consumer drift:")
    for m in drift:
        print("         %s" % m)
else:
    ok("every unseeded plain literal is recorded with a reason (%d entr(y/ies))"
       % len(UNSEEDED_CONSUMERS))
if stale_unseeded:
    bad("UNSEEDED_CONSUMERS names director(y/ies) with no unseeded plain literal any more — "
        "the gap is closed and the exemption is dead: %s" % ", ".join(sorted(stale_unseeded)))
else:
    ok("no dead UNSEEDED_CONSUMERS entry")
if noreason:
    bad("UNSEEDED_CONSUMERS entr(y/ies) carry no real reason: %s" % ", ".join(sorted(noreason)))
else:
    ok("every UNSEEDED_CONSUMERS entry carries a written reason")

# ── LEG 6: the axis itself is re-derived from the tree ───────────────────────
print()
print("-- 6) the axis is re-derived: no namespace with a Postgres address is silently off it --")
ADDR = re.compile(r"(?:r2dbc|jdbc):postgresql://|postgres://|PGHOST|PHPBB_DB_HOST|host=[a-z0-9-]+-pg\b|SQL_HOST")
axis_ns = set(ns for ns, _c, _r, _a in AXIS)
derived, undeclared, dirless = set(), [], []
if os.path.isdir(mdir):
    for d in sorted(os.listdir(mdir)):
        dd = os.path.join(mdir, d)
        if not os.path.isdir(dd):
            continue
        # Which namespace does an address in THIS directory land in? The
        # directory's kustomization `namespace:` transformer if it has one;
        # otherwise the namespace the address-bearing document pins on itself
        # (manifests/backing-service-endpoints/ is that shape — its objects each
        # carry an explicit metadata.namespace and its kustomization sets none).
        # A directory where neither answers must be recorded in EXCLUDED_DIRS.
        dir_ns = kust_namespace("specs/cluster/manifests/%s" % d)
        hits = set()
        for fn in sorted(os.listdir(dd)):
            if not fn.endswith((".yaml", ".yml")):
                continue
            ftext = open(os.path.join(dd, fn), encoding="utf-8", errors="replace").read()
            if not any(ADDR.search(l) for l in ftext.split("\n")
                       if not l.lstrip().startswith("#")):
                continue
            if dir_ns:
                hits.add(dir_ns)
                continue
            own = set()
            for doc in docs(ftext):
                if ADDR.search(doc) and meta(doc, "namespace"):
                    own.add(meta(doc, "namespace"))
            hits |= own if own else {""}
        if not hits:
            continue
        if "" in hits:
            hits.discard("")
            if d not in EXCLUDED_DIRS:
                dirless.append("%s holds a Postgres address and pins no namespace — it is "
                               "neither on the axis nor recorded in EXCLUDED_DIRS" % d)
        for ns in sorted(hits):
            derived.add(ns)
            if ns not in axis_ns and ns not in EXCLUDED_NAMESPACES:
                undeclared.append("%s (from manifests/%s) holds a Postgres address, is NOT on "
                                  "the axis, and is NOT in EXCLUDED_NAMESPACES — decision 34a's "
                                  "census has drifted" % (ns, d))
if undeclared or dirless:
    bad("axis drift:")
    for m in undeclared + dirless:
        print("         %s" % m)
else:
    ok("every namespace derived from the tree is on the axis or recorded as excluded "
       "(%d derived, %d excluded namespace(s), %d excluded director(y/ies))"
       % (len(derived), len(EXCLUDED_NAMESPACES), len(EXCLUDED_DIRS)))

missing_from_tree = sorted(axis_ns - derived)
if missing_from_tree:
    bad("axis namespace(s) this guard names that the tree no longer shows a Postgres address "
        "for — the axis entry is dead, or the scanner has gone blind: %s"
        % ", ".join(missing_from_tree))
else:
    ok("every axis namespace is still derivable from the tree")

dead_excl = [n for n in EXCLUDED_NAMESPACES if n in axis_ns]
noreason_excl = [n for n, r in list(EXCLUDED_NAMESPACES.items()) + list(EXCLUDED_DIRS.items())
                 if len(r.strip()) < 20]
if dead_excl:
    bad("EXCLUDED_NAMESPACES names namespace(s) that ARE on the axis now — drop them: %s"
        % ", ".join(sorted(dead_excl)))
else:
    ok("no EXCLUDED_NAMESPACES entry shadows an axis namespace")
if noreason_excl:
    bad("exclusion entr(y/ies) carry no real reason: %s" % ", ".join(sorted(noreason_excl)))
else:
    ok("every exclusion entry carries a written reason")

print()
print("== backing-service-endpoints closure: %d passed, %d failed ==" % (P, F))
sys.exit(1 if F else 0)
PY
rc=$?
if [ "${rc}" -eq 0 ]; then pass=$((pass+1)); else fail=$((fail+1)); fi

if [ "${CHILD}" = "yes" ]; then
  exit "${rc}"
fi

# ── NEGATIVE CONTROLS ────────────────────────────────────────────────────────
# Every leg above is re-run against COPIES OF THE REAL TREE carrying each defect on
# purpose — not against synthesised miniatures, because the defect this guard was
# written for was applied to the real manifests and survived. Each control asserts
# the mutation CHANGED something before asserting the analyser caught it: a sed
# whose pattern has drifted no-ops, exits 0, and leaves a byte-identical "mutated"
# tree, which would report a tidy PASS for a reason that has nothing to do with the
# property under test.
echo
echo "-- negative controls (each is a real revert of decision 34a/34b) --"

T="$(mktemp -d)"
trap 'rm -rf "${T}"' EXIT

mktree() {
  # $1 = name. Copies the real specs/cluster into a fresh tree.
  mkdir -p "${T}/$1/specs"
  cp -a "${BSE_ROOT}/specs/cluster" "${T}/$1/specs/cluster"
  echo "${T}/$1"
}

run_probe() {
  BSE_ROOT="$1" bash "${BASH_SOURCE[0]}" --analyse-only >/dev/null 2>&1
}

control() {
  # $1 label  $2 expect(caught|clean)  $3 tree
  local label
  local expect
  local tree
  label="$1"; expect="$2"; tree="$3"
  if run_probe "${tree}"; then
    if [ "${expect}" = "clean" ]; then ok "control (${label}): the clean twin passes"
    else bad "control (${label}): the defect was NOT caught — the leg that should see it is blind"; fi
  else
    if [ "${expect}" = "caught" ]; then ok "control (${label}): caught, as it must be"
    else bad "control (${label}): the CLEAN tree failed — this guard fails on everything, which is as useless as failing on nothing"; fi
  fi
}

changed() {
  # $1 label  $2 tree  — assert the mutation actually moved bytes.
  local label
  local tree
  label="$1"; tree="$2"
  if diff -rq "${BSE_ROOT}/specs/cluster" "${tree}/specs/cluster" >/dev/null 2>&1; then
    bad "control (${label}): the mutation changed NOTHING — this control is inert"
    return 1
  fi
  return 0
}

# (a) the clean twin.
C="$(mktree clean)"
control "no defect" clean "${C}"

# (b) GM1 — THE LITERAL REVERT the operator declined: delete the pki + games
#     objects and their kustomization lines, leaving one hugmesh-backend ConfigMap.
C="$(mktree gm1)"
rm -f "${C}/specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-pki.yaml" \
      "${C}/specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-games.yaml"
sed -i '/- endpoints-hugmesh-pki.yaml/d;/- endpoints-hugmesh-games.yaml/d' \
      "${C}/specs/cluster/manifests/backing-service-endpoints/kustomization.yaml"
changed "GM1 revert to the single hugmesh-backend object" "${C}" && \
  control "GM1 revert to the single hugmesh-backend object (the declined recommendation)" caught "${C}"

# (c) GM1b — the optional-namespace half reverted: delete owncast's object.
C="$(mktree gm1b)"
rm -f "${C}/specs/cluster/manifests/owncast/backing-service-endpoints.yaml"
sed -i '/- backing-service-endpoints.yaml/d' "${C}/specs/cluster/manifests/owncast/kustomization.yaml"
changed "GM1b owncast object deleted" "${C}" && \
  control "GM1b the fan-out shrunk from six namespaces to five" caught "${C}"

# (d) GM1c — the object is there but nothing renders it: drop only the
#     kustomization line. This is the silent half; the file reads fine in review.
C="$(mktree gm1c)"
sed -i '/- backing-service-endpoints.yaml/d' "${C}/specs/cluster/manifests/tube/kustomization.yaml"
changed "GM1c tube object unreferenced" "${C}" && \
  control "GM1c the object exists but its kustomization no longer renders it" caught "${C}"

# (e) GM2 — delete the pki + games RBAC fan-out, leaving one Role.
C="$(mktree gm2)"
python3 - "${C}" <<'PYC'
import sys, re
p = sys.argv[1] + "/specs/cluster/manifests/backing-service-endpoints/rbac.yaml"
t = open(p, encoding="utf-8").read()
parts = t.split("\n---\n")
keep = [d for d in parts if "namespace: hugmesh-pki" not in d and "namespace: hugmesh-games" not in d]
open(p, "w", encoding="utf-8").write("\n---\n".join(keep))
PYC
changed "GM2 RBAC fan-out deleted" "${C}" && \
  control "GM2 the pki+games RBAC fan-out deleted (the N grants 34a paid for)" caught "${C}"

# (f) GM2b — the forum grant deleted while its ConfigMap stays.
C="$(mktree gm2b)"
python3 - "${C}" <<'PYC'
import sys
p = sys.argv[1] + "/specs/cluster/manifests/forum/backing-service-endpoints.yaml"
t = open(p, encoding="utf-8").read()
parts = t.split("\n---\n")
open(p, "w", encoding="utf-8").write(parts[0])
PYC
changed "GM2b forum grant deleted" "${C}" && \
  control "GM2b one namespace's Role+RoleBinding deleted, its ConfigMap left in place" caught "${C}"

# (g) GM3 — drop 2 of the 10 ignoreDifferences pointers (the apps/16 failure).
C="$(mktree gm3)"
sed -i '/- \/data\/postgres-wiki-bff.r2dbc-url/d;/- \/data\/postgres-wiki-bff.liquibase-url/d' \
      "${C}/specs/cluster/apps/17-backing-service-endpoints.yaml"
changed "GM3 two pointers dropped" "${C}" && \
  control "GM3 two ignoreDifferences pointers dropped (a key with no exemption)" caught "${C}"

# (h) GM3b — an ORPHAN pointer for a key that does not exist.
C="$(mktree gm3b)"
sed -i 's|        - /data/postgres-wiki-bff.liquibase-url|        - /data/postgres-wiki-bff.liquibase-url\n        - /data/postgres-ghost.r2dbc-url|' \
      "${C}/specs/cluster/apps/17-backing-service-endpoints.yaml"
changed "GM3b orphan pointer added" "${C}" && \
  control "GM3b an orphan jsonPointer for a key that does not exist" caught "${C}"

# (i) GM4 — remove RespectIgnoreDifferences, the half the file itself calls THE
#     KEYSTONE. Everything still looks right; selfHeal reverts every write.
C="$(mktree gm4)"
sed -i 's/, RespectIgnoreDifferences=true//' "${C}/specs/cluster/apps/17-backing-service-endpoints.yaml"
changed "GM4 RespectIgnoreDifferences removed" "${C}" && \
  control "GM4 RespectIgnoreDifferences=true removed (selfHeal ignores every exemption)" caught "${C}"

# (j) GM5 — break byte-identity: point one seeded value at a different host.
C="$(mktree gm5)"
sed -i 's|postgres-wiki-bff.r2dbc-url: "r2dbc:postgresql://wiki-bff-db|postgres-wiki-bff.r2dbc-url: "r2dbc:postgresql://WRONG-HOST|' \
      "${C}/specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-backend.yaml"
changed "GM5 seeded value corrupted" "${C}" && \
  control "GM5 a seeded value that is no longer the consumer's literal (a silent database move)" caught "${C}"

# (k) GM6 — a new key lands with no pointer: the exact apps/16 rot, forwards.
C="$(mktree gm6)"
cat >> "${C}/specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-backend.yaml" <<'EOF'
  postgres-casdoor.r2dbc-url: "r2dbc:postgresql://casdoor-pg.hugmesh-pki.svc.cluster.local:5432/casdoor"
  postgres-casdoor.liquibase-url: "jdbc:postgresql://casdoor-pg.hugmesh-pki.svc.cluster.local:5432/casdoor"
EOF
changed "GM6 new key with no exemption" "${C}" && \
  control "GM6 a new seeded key lands with no ignoreDifferences pointer" caught "${C}"

# (l) GM7 — a new consumer lands a plain literal with no key and no recorded
#     reason. The forward-drift direction leg 5 exists for.
C="$(mktree gm7)"
mkdir -p "${C}/specs/cluster/manifests/newthing-bff-api"
cat > "${C}/specs/cluster/manifests/newthing-bff-api/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: hugmesh-newthing-bff-api
  namespace: hugmesh-backend
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: SPRING_R2DBC_URL
              value: "r2dbc:postgresql://newthing-bff-db.hugmesh-backend.svc.cluster.local:5432/newthingbff"
EOF
cat > "${C}/specs/cluster/manifests/newthing-bff-api/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: hugmesh-backend
resources:
  - deployment.yaml
EOF
changed "GM7 new unseeded consumer" "${C}" && \
  control "GM7 a new consumer with a plain literal, no key and no recorded reason" caught "${C}"

# (m) GM8 — a namespace with a Postgres address that is not on the axis and not
#     excluded: the axis census itself rotting.
C="$(mktree gm8)"
mkdir -p "${C}/specs/cluster/manifests/newns-thing"
cat > "${C}/specs/cluster/manifests/newns-thing/deployment.yaml" <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: thing
spec:
  template:
    spec:
      containers:
        - name: app
          env:
            - name: SPRING_R2DBC_URL
              value: "r2dbc:postgresql://thing-db.hugmesh-newns.svc.cluster.local:5432/thing"
EOF
cat > "${C}/specs/cluster/manifests/newns-thing/kustomization.yaml" <<'EOF'
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
namespace: hugmesh-newns
resources:
  - deployment.yaml
EOF
changed "GM8 new namespace off the axis" "${C}" && \
  control "GM8 a seventh namespace with a Postgres address, off the axis and unrecorded" caught "${C}"

# (n) THE BLIND-CENSUS control. An EMPTY tree must FAIL on the floors rather than
#     pass over zero files — the shape in which a guard reports green while reading
#     nothing at all.
mkdir -p "${T}/empty/specs/cluster"
control "blind census (an empty specs/cluster)" caught "${T}/empty"

# (o) THE SABOTAGE CONTROL. Remove the leg that catches GM1 from a COPY of this
#     file and require that GM1 then PASSES. If it still fails, the controls above
#     are measuring something other than the property under test — the state
#     adversarial review has repeatedly found guards in. The copy runs from ${T},
#     never from tests/scripts/, so a read-only checkout cannot turn this into a
#     red that says nothing about the property.
sed 's|    bad("the per-namespace fan-out is INCOMPLETE|    ok("the per-namespace fan-out is INCOMPLETE|' \
  "${BASH_SOURCE[0]}" > "${T}/sabotage.sh"
if cmp -s "${T}/sabotage.sh" "${BASH_SOURCE[0]}"; then
  bad "control (sabotage): the sabotage sed changed NOTHING — its pattern no longer matches the axis-presence leg, so this control is inert"
else
  # GM1 must be isolated to the axis-presence leg for this to mean anything: with
  # the pki+games ConfigMaps gone their RBAC docs are still present, which leg 2
  # accepts (it asks for the grant, not for the object), and the keystone leg is
  # satisfied because those namespaces have no keys either way.
  C="$(mktree sab)"
  rm -f "${C}/specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-pki.yaml" \
        "${C}/specs/cluster/manifests/backing-service-endpoints/endpoints-hugmesh-games.yaml"
  sed -i '/- endpoints-hugmesh-pki.yaml/d;/- endpoints-hugmesh-games.yaml/d' \
        "${C}/specs/cluster/manifests/backing-service-endpoints/kustomization.yaml"
  if BSE_ROOT="${C}" bash "${T}/sabotage.sh" --analyse-only >/dev/null 2>&1; then
    ok "control (sabotage): with the axis-presence leg removed, the declined single-object revert is NO LONGER caught — so that leg really is what catches it"
  else
    bad "control (sabotage): the single-object revert still fails with its leg removed — the controls are measuring something else"
  fi
fi

echo
echo "== backing-service-endpoints guard: ${pass} passed, ${fail} failed =="
[ "${fail}" -eq 0 ]
