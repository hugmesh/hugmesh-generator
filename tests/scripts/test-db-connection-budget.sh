#!/usr/bin/env bash
# =============================================================================
# test-db-connection-budget.sh — every service that can run more than one
# replica must fit its database role's connection limit at its LARGEST replica
# count, and every database must have room for all of its roles at once.
#
# WHAT HAPPENED (measured on the kind cluster hugmesh-local, 2026-09-30).
# The persona sign-in answered "Sign-in failed: Internal Server Error".
# hugmesh-user-bff-api logged
#     500 Server Error for HTTP POST "/bff/login"
#     caused by 500 Internal Server Error from POST .../bff/internal/accounts/ensure
# and hugmesh-admin-bff-api logged, for that very request,
#     DataAccessResourceFailureException: Failed to obtain R2DBC Connection
# while admin-bff-db logged FATAL: too many connections for role "adminbff_app".
# The numbers, read live:
#     rolconnlimit(adminbff_app)      = 20   (initdb/10-roles.sh: CONNECTION LIMIT 20)
#     max_connections                 = 60   (entrypoint: -c max_connections=60)
#     r2dbc pool per replica          = 10   (NO spring.r2dbc.pool.* anywhere; the
#                                             Spring Boot / r2dbc-pool default; each
#                                             pod held exactly 10 idle connections)
#     HorizontalPodAutoscaler max     = 6    (hpa.yaml: minReplicas 2, maxReplicas 6)
#     6 replicas x 10 = 60 > 20 (role)  and  > 57 (max_connections - 3 reserved)
# Two pods held the whole budget of 20, the other four could not open a single
# connection, and every request routed to them failed. At the HPA's minimum,
# 2 x 10 = 20 = 20: it held with ZERO margin, which is why nothing failed until
# the metrics API answered for the first time on 2026-09-30 (metrics-server had
# been installed on 2026-09-24T16:08Z) and both autoscalers went 2 -> 3 -> 6 in
# a minute, on a memory target read against a 256Mi request that the JVM
# exceeds at idle. hugmesh-generator#663 has the full account.
#
# WHAT THIS PINS, offline, over specs/cluster/manifests (no cluster, no network):
#   For every Deployment whose container carries SPRING_R2DBC_URL +
#   SPRING_R2DBC_USERNAME:
#     (1) the role named by SPRING_R2DBC_USERNAME is created with an explicit
#         CONNECTION LIMIT in the initdb of the database the URL's host names
#         (manifests/<db>/initdb/*.sh); a role without a limit is FAIL (the
#         budget would be unbounded and this test could not reason about it);
#     (2) that database's entrypoint sets -c max_connections=N; missing is FAIL;
#     (3) replicas_max = the maxReplicas of the HorizontalPodAutoscaler whose
#         scaleTargetRef names the Deployment, else the Deployment's
#         spec.replicas, else 1;
#     (4) pool_max = SPRING_R2DBC_POOL_MAX_SIZE from the container env, else 10
#         (the r2dbc-pool default that Spring Boot applies when the property is
#         absent — pinned here as an ASSUMPTION so a future default change shows
#         up as a red test, not as a silent budget change);
#     (5) pool_initial = SPRING_R2DBC_POOL_INITIAL_SIZE, else 10 (same default);
#         pool_initial <= pool_max, or r2dbc-pool refuses to build the pool and
#         the pod never becomes ready;
#     (6) replicas_max x pool_max <= rolconnlimit                    (per role)
#     (7) sum(rolconnlimit of every role a Deployment uses) + superuser reserved
#         (3, Postgres' default) <= max_connections                 (per database)
#   Zero candidate Deployments is FAIL: a census that finds nothing has lost the
#   tree, not proved it clean.
#
# OUT OF SCOPE, and why: the gateway Helm chart (charts/hugmesh-gateway) opens
# its route-access connections UNPOOLED (ConnectionFactories.get on a plain
# r2dbc:postgresql:// URL) so it has no fixed per-replica pool to multiply; and
# the compose stack (tests/stack) runs one instance of everything with no role
# limits. Both are noted in the issue, neither is measured here.
#
# NEGATIVE CONTROL: BUDGET_ROOT=<tree> runs the same analyser over another
# checkout. On origin/main c882fb67 (before the pool env landed) this file is
# RED on all seven BFF Deployments: 6 x 10 = 60 > 20. The mutation battery in
# the landing PR breaks each side of the inequality and sees RED.
#
# Needs bash + python3 + PyYAML (the debian shell-suites job installs and
# preflights PyYAML; the alpine job has py3-yaml).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="${BUDGET_ROOT:-$(cd "${HERE}/../.." && pwd)}"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "  FAIL PyYAML is required (pip install pyyaml / apk add py3-yaml)"; exit 2; }
[ -d "${REPO}/specs/cluster/manifests" ] || { echo "  FAIL ${REPO}/specs/cluster/manifests is not a directory"; exit 2; }

REPO="${REPO}" python3 - <<'PY'
import os, re, sys, glob
import yaml

REPO = os.environ["REPO"]
MAN = os.path.join(REPO, "specs", "cluster", "manifests")
DEFAULT_POOL_MAX = 10       # r2dbc-pool default when spring.r2dbc.pool.max-size is absent
DEFAULT_POOL_INITIAL = 10   # r2dbc-pool default when spring.r2dbc.pool.initial-size is absent
SUPERUSER_RESERVED = 3      # Postgres default superuser_reserved_connections

P = F = 0
def ok(m):
    global P; P += 1; print("  PASS " + m)
def bad(m):
    global F; F += 1; print("  FAIL " + m)

def load_all(path):
    with open(path) as fh:
        try:
            return [d for d in yaml.safe_load_all(fh) if isinstance(d, dict)]
        except yaml.YAMLError as e:
            bad("%s: not parseable YAML: %s" % (os.path.relpath(path, REPO), e)); return []

deployments = []   # (path, doc)
hpas = []          # (path, doc)
for path in sorted(glob.glob(os.path.join(MAN, "*", "*.yaml"))):
    for doc in load_all(path):
        k = doc.get("kind")
        if k == "Deployment":
            deployments.append((path, doc))
        elif k == "HorizontalPodAutoscaler":
            hpas.append((path, doc))

def env_value(container, name):
    for e in container.get("env") or []:
        if e.get("name") == name:
            return e.get("value")
    return None

def hpa_max_for(dep_name, dep_ns):
    hits = []
    for path, h in hpas:
        ref = (h.get("spec") or {}).get("scaleTargetRef") or {}
        ns = (h.get("metadata") or {}).get("namespace")
        if ref.get("kind") == "Deployment" and ref.get("name") == dep_name and (ns is None or dep_ns is None or ns == dep_ns):
            hits.append((path, (h.get("spec") or {}).get("maxReplicas")))
    return hits

def role_limit(db_dir, role):
    """CONNECTION LIMIT N on the CREATE ROLE <role> line of the db's initdb scripts."""
    found = []
    for sh in sorted(glob.glob(os.path.join(db_dir, "initdb", "*"))):
        try:
            text = open(sh, errors="replace").read()
        except OSError:
            continue
        for m in re.finditer(r"CREATE\s+ROLE\s+%s\b([^;]*);" % re.escape(role), text):
            lim = re.search(r"CONNECTION\s+LIMIT\s+(-?\d+)", m.group(1))
            found.append((os.path.relpath(sh, REPO), int(lim.group(1)) if lim else None))
    return found

def db_max_connections(db_dir):
    found = []
    for f in sorted(glob.glob(os.path.join(db_dir, "**", "*"), recursive=True)):
        if not os.path.isfile(f):
            continue
        try:
            text = open(f, errors="replace").read()
        except OSError:
            continue
        for m in re.finditer(r"max_connections=(\d+)", text):
            found.append((os.path.relpath(f, REPO), int(m.group(1))))
    return found

per_db = {}   # db_dir -> list of (dep, role, limit)
candidates = 0
for path, dep in deployments:
    meta = dep.get("metadata") or {}
    dep_name = meta.get("name"); dep_ns = meta.get("namespace")
    spec = dep.get("spec") or {}
    tspec = ((spec.get("template") or {}).get("spec") or {})
    for c in tspec.get("containers") or []:
        url = env_value(c, "SPRING_R2DBC_URL"); role = env_value(c, "SPRING_R2DBC_USERNAME")
        if not url or not role:
            continue
        candidates += 1
        label = "%s (%s)" % (dep_name, os.path.relpath(path, REPO))
        m = re.match(r"r2dbc:(?:pool:)?postgresql://(?:[^@/]*@)?([^:/]+)", url)
        if not m:
            bad("%s: SPRING_R2DBC_URL %r is not a postgresql R2DBC URL this test understands" % (label, url)); continue
        host = m.group(1).split(".")[0]
        db_dir = os.path.join(MAN, host)
        if not os.path.isdir(db_dir):
            bad("%s: database host %r has no manifests/%s directory to read limits from" % (label, host, host)); continue

        limits = role_limit(db_dir, role)
        if not limits:
            bad("%s: role %r is not created by manifests/%s/initdb (no CREATE ROLE line)" % (label, role, host)); continue
        if len(limits) > 1:
            bad("%s: role %r is created %d times under manifests/%s/initdb: %s" % (label, role, len(limits), host, limits)); continue
        lim_file, lim = limits[0]
        if lim is None or lim < 0:
            bad("%s: role %r in %s has no CONNECTION LIMIT (unbounded: the budget cannot be reasoned about)" % (label, role, lim_file)); continue

        mcs = db_max_connections(db_dir)
        if not mcs:
            bad("%s: manifests/%s sets no max_connections= anywhere (the database budget is unknown)" % (label, host)); continue
        max_conn = min(v for _, v in mcs)

        hpa_hits = hpa_max_for(dep_name, dep_ns)
        if len(hpa_hits) > 1:
            bad("%s: %d HorizontalPodAutoscalers target it: %s" % (label, len(hpa_hits), hpa_hits)); continue
        if hpa_hits:
            hpa_file, replicas_max = hpa_hits[0]
            if not isinstance(replicas_max, int):
                bad("%s: %s has no integer maxReplicas" % (label, os.path.relpath(hpa_file, REPO))); continue
            src = "HPA %s maxReplicas" % os.path.relpath(hpa_file, REPO)
        else:
            replicas_max = spec.get("replicas", 1)
            if replicas_max is None: replicas_max = 1
            src = "spec.replicas"

        raw_max = env_value(c, "SPRING_R2DBC_POOL_MAX_SIZE")
        raw_init = env_value(c, "SPRING_R2DBC_POOL_INITIAL_SIZE")
        try:
            pool_max = int(raw_max) if raw_max is not None else DEFAULT_POOL_MAX
            pool_init = int(raw_init) if raw_init is not None else DEFAULT_POOL_INITIAL
        except ValueError:
            bad("%s: SPRING_R2DBC_POOL_*_SIZE is not an integer (max=%r initial=%r)" % (label, raw_max, raw_init)); continue
        pool_src = "env" if raw_max is not None else "r2dbc-pool DEFAULT (no SPRING_R2DBC_POOL_MAX_SIZE)"

        if pool_init > pool_max:
            bad("%s: SPRING_R2DBC_POOL_INITIAL_SIZE %d > SPRING_R2DBC_POOL_MAX_SIZE %d: r2dbc-pool refuses to build the pool" % (label, pool_init, pool_max))
        else:
            ok("%s: pool initial %d <= max %d" % (label, pool_init, pool_max))

        need = replicas_max * pool_max
        if need <= lim:
            ok("%s: %d replicas (%s) x pool %d (%s) = %d <= CONNECTION LIMIT %d for role %s" % (label, replicas_max, src, pool_max, pool_src, need, lim, role))
        else:
            bad("%s: %d replicas (%s) x pool %d (%s) = %d > CONNECTION LIMIT %d for role %s (%s): pods beyond the budget fail every query" % (label, replicas_max, src, pool_max, pool_src, need, lim, role, lim_file))

        per_db.setdefault(host, {"max_conn": max_conn, "mc_src": mcs, "roles": {}})
        per_db[host]["roles"][role] = lim

if candidates == 0:
    bad("no Deployment under specs/cluster/manifests carries SPRING_R2DBC_URL + SPRING_R2DBC_USERNAME: the census found nothing (tree moved?)")

for host in sorted(per_db):
    d = per_db[host]
    total = sum(d["roles"].values()) + SUPERUSER_RESERVED
    if total <= d["max_conn"]:
        ok("database %s: role limits %s + %d reserved = %d <= max_connections %d" % (host, d["roles"], SUPERUSER_RESERVED, total, d["max_conn"]))
    else:
        bad("database %s: role limits %s + %d reserved = %d > max_connections %d (%s)" % (host, d["roles"], SUPERUSER_RESERVED, total, d["max_conn"], d["mc_src"]))

print("\n%d passed / %d failed" % (P, F))
sys.exit(1 if F else 0)
PY
