#!/usr/bin/env bash
# =============================================================================
# validate-reserved-prefixes.sh — route-federation consistency / drift guard.
# =============================================================================
# Asserts that the CANONICAL reserved-prefix set
# (specs/cluster/reserved-prefixes.yaml) is a SUPERSET of every dedicated route
# prefix / reserved subdomain actually deployed by the GitOps tree, i.e.:
#
#   reserved  ⊇  { first path-segment of every gateway route (apps/20-gateway-*.yaml) }
#               ∪ { first DNS label of every reserved gateway host / extraHost }
#               ∪ { first segment of every gateway_route_access.url_pattern (schema.sql) }
#
# If a NEW dedicated route prefix is added (to a gateway app or the route-access
# seed) without also reserving it, this check FAILS — catching the drift that
# would let a vanity username collide with a real platform route.
#
# STAGES (each FAILs the build on a violation):
#   1) canonical source is non-empty + has no duplicates;
#   2) the in-cluster ConfigMap mirror
#      (manifests/policy/reserved-prefixes-configmap.yaml) == the canonical source
#      exactly (so the Kyverno policy and the GitOps list cannot drift);
#   3) reserved ⊇ every PUBLICLY-ROUTABLE gateway route prefix (the original
#      route-consistency assertion above);
#   4) SCOPED Service-name drift — reserved ⊇ the PUBLICLY-ROUTABLE Services
#      (those a gateway route uri/host actually targets), MINUS an explicit
#      INTERNAL allowlist (mTLS proxies, *-db/*-pg datastores, infra brokers,
#      lan-dns, the hugmesh-*-api/-ui/-web pod helpers). This is the design's
#      "scoped" check: a naive "every kind:Service must be reserved" rule would be
#      RED on day one (akkoma-proxy/kafka/*-db are Services but never public), so
#      we scope to what a route actually exposes and exempt the rest by allowlist;
#   5) CODE-COPY assertion — parse each app-repo ReservedNames.java
#      RESERVED[_LABELS] set and assert it EQUALS the canonical set. REQUIRED:
#      every declared copy must be present and checked. PLANNED reserves
#      (forum/phpbb) are expected in the canonical set without a deployed route —
#      they are NEVER flagged by stage 3/4.
#
# WHY STAGE 5 IS NO LONGER "SKIP AND STILL PASS". Until 2026-07-29 an absent
# sibling checkout printed `[SKIP] … (not checked out)` and the run still ended
# `RESULT: PASS`. That is a gate reporting green *because it skipped its own most
# valuable check* — and drift in exactly those copies is the failure this repo has
# hit TWICE (hugmesh-actions missing `character-forge`/`hmdm`/`attest`/the two
# games slugs; and before that the #42 gap the copies' own javadoc records). The
# repo's own CI checked out no siblings, so the assertion had NEVER once run in a
# pipeline while advertising PASS. Now: a copy that cannot be checked makes the
# run INCOMPLETE (exit 3, distinct result line), and .gitlab-ci.yml's
# lint:reserved-prefixes clones the three sibling repos so it genuinely runs.
#
# Wired into .gitlab-ci.yml (lint stage). Uses python3 + PyYAML for robust YAML
# parsing; degrades to a clear error if python3/PyYAML is absent.
#
# EXIT CODES
#   0  PASS       — consistent, and every stage (including the code-copy
#                   assertion) actually ran.
#   1  FAIL       — drift / mismatch (prints the offending labels).
#   2  FATAL      — environment problem (missing input file, no python3/PyYAML).
#   3  INCOMPLETE — no violation found, but the code-copy assertion could NOT run
#                   (one or more ReservedNames.java copies absent). Non-zero on
#                   purpose: an unrun assertion is not a pass. Point
#                   RESERVED_SIBLING_ROOT at a tree holding the copies, or set
#                   RESERVED_ALLOW_MISSING_COPIES=1 to opt out DELIBERATELY (that
#                   downgrades to exit 0 but still prints the distinct
#                   `RESULT: PASS (INCOMPLETE …)` line — never a clean PASS).
set -euo pipefail

# Repo-root-relative paths (resolve from this script's location).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

CANONICAL="${REPO_ROOT}/specs/cluster/reserved-prefixes.yaml"
CONFIGMAP="${REPO_ROOT}/specs/cluster/manifests/policy/reserved-prefixes-configmap.yaml"
SCHEMA_SQL="${REPO_ROOT}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
GATEWAY_GLOB="${REPO_ROOT}/specs/cluster/apps"
MANIFESTS_DIR="${REPO_ROOT}/specs/cluster/manifests"

# Where to look for the app-repo ReservedNames.java copies (stage 5, code-copy
# assertion). Default: sibling checkouts next to this repo (…/GitHub/<repo>).
# Override the search root with RESERVED_SIBLING_ROOT (CI clones them into a temp
# dir and points this at it). An absent copy makes the run INCOMPLETE (exit 3) —
# see the EXIT CODES block above.
SIBLING_ROOT="${RESERVED_SIBLING_ROOT:-$(cd "${REPO_ROOT}/.." && pwd)}"

# Deliberate opt-out for a working copy that genuinely has no siblings checked
# out. Downgrades INCOMPLETE (exit 3) to exit 0 — but the verdict line still says
# PASS (INCOMPLETE …), so no run can be mistaken for a complete one. NEVER set
# this in CI: the whole point of the CI clone below is that the assertion runs.
ALLOW_MISSING_COPIES="${RESERVED_ALLOW_MISSING_COPIES:-0}"

for f in "$CANONICAL" "$CONFIGMAP" "$SCHEMA_SQL"; do
  [[ -f "$f" ]] || { echo "FATAL: missing required file: $f" >&2; exit 2; }
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required to parse the gateway YAML." >&2
  exit 2
fi

# Hand off to python for the actual set-logic (YAML + SQL parsing). The script
# prints a human report and exits non-zero on any violation.
python3 - "$CANONICAL" "$CONFIGMAP" "$SCHEMA_SQL" "$GATEWAY_GLOB" "$MANIFESTS_DIR" \
         "$SIBLING_ROOT" "$ALLOW_MISSING_COPIES" "$REPO_ROOT" <<'PY'
import glob
import json
import os
import re
import sys

(
    canonical_path,
    configmap_path,
    schema_path,
    gateway_dir,
    manifests_dir,
    sibling_root,
    allow_missing_copies_raw,
    repo_root,
) = sys.argv[1:9]

allow_missing_copies = allow_missing_copies_raw.strip().lower() in {
    "1", "true", "yes", "on"}

try:
    import yaml
except Exception as e:  # pragma: no cover
    print(f"FATAL: PyYAML is required ({e}).", file=sys.stderr)
    sys.exit(2)


def first_label(host: str) -> str:
    return host.split(".", 1)[0]


def first_segment(path: str) -> str:
    # "/well-known/**" -> ".well-known"? No: strip leading slash, take up to next
    # slash/glob; the literal segment as routed.
    p = path.strip()
    p = p.lstrip("/")
    seg = re.split(r"[/*]", p, maxsplit=1)[0]
    return seg


# Path/host first-labels that are NOT dedicated app prefixes and must be ignored:
#   - apex host (hugmesh) and wildcards (*) are not reserved labels
#   - "/" (front page) and "/**" (catch-all) yield empty segments
#   - DEEP sub-paths that are NOT a first segment of a top-level route. We only
#     ever take the FIRST segment, so e.g. /api/v1/pleroma/... contributes "api".
IGNORE = {"", "hugmesh", "*"}

# Normalization: a few deployed segments carry punctuation the reserved list
# spells without it (the reserved list is the username/label form). Map them.
NORMALIZE = {
    ".well-known": "well-known",  # /.well-known/** route -> reserved 'well-known'
}


def normalize(label: str) -> str:
    return NORMALIZE.get(label, label)


# ---- 1) canonical source ---------------------------------------------------
with open(canonical_path) as fh:
    canon_doc = yaml.safe_load(fh)
reserved = canon_doc.get("spec", {}).get("reserved", [])
if not isinstance(reserved, list) or not reserved:
    print(f"FATAL: {canonical_path} has no spec.reserved list", file=sys.stderr)
    sys.exit(2)
# duplicate guard
dupes = sorted({x for x in reserved if reserved.count(x) > 1})
if dupes:
    print(f"FAIL: canonical reserved list has DUPLICATES: {dupes}", file=sys.stderr)
    sys.exit(1)
reserved_set = set(reserved)

# ---- 2) configmap mirror must equal the canonical source -------------------
with open(configmap_path) as fh:
    cm_doc = yaml.safe_load(fh)
cm_raw = cm_doc.get("data", {}).get("reserved.json")
if cm_raw is None:
    print(f"FATAL: {configmap_path} has no data['reserved.json']", file=sys.stderr)
    sys.exit(2)
cm_set = set(json.loads(cm_raw))
if cm_set != reserved_set:
    only_canon = sorted(reserved_set - cm_set)
    only_cm = sorted(cm_set - reserved_set)
    print("FAIL: ConfigMap mirror DRIFTED from canonical source:", file=sys.stderr)
    if only_canon:
        print(f"  in canonical but NOT ConfigMap: {only_canon}", file=sys.stderr)
    if only_cm:
        print(f"  in ConfigMap but NOT canonical: {only_cm}", file=sys.stderr)
    print("  -> re-run scripts/sync-reserved-configmap.sh", file=sys.stderr)
    sys.exit(1)

# ---- 3) deployed route prefixes from the gateway apps ----------------------
deployed = {}  # label -> set(sources)
# Services a gateway route uri actually TARGETS — i.e. the PUBLICLY-ROUTABLE
# Services (stage 4 scopes its drift check to these, not every kind:Service).
routed_services = {}  # service-name -> set(sources)


def add(label, source):
    label = normalize(label)
    if label in IGNORE:
        return
    deployed.setdefault(label, set()).add(source)


def service_of_uri(uri):
    """Extract the in-cluster Service name a route uri points at.
    e.g. https://hugmesh-federation-api.hugmesh-backend.svc.cluster.local:8080
         -> 'hugmesh-federation-api' ; returns None for non-cluster uris."""
    m = re.match(r"^[a-z0-9+.-]+://([a-z0-9-]+)\.[a-z0-9-]+\.svc\.cluster\.local", str(uri))
    return m.group(1) if m else None


gateway_files = sorted(glob.glob(os.path.join(gateway_dir, "20-gateway-*.yaml")))
if not gateway_files:
    print(f"FATAL: no gateway apps matched {gateway_dir}/20-gateway-*.yaml", file=sys.stderr)
    sys.exit(2)

for gf in gateway_files:
    base = os.path.basename(gf)
    with open(gf) as fh:
        for app in yaml.safe_load_all(fh):
            if not app:
                continue
            helm = (((app.get("spec") or {}).get("source") or {}).get("helm") or {})
            values_raw = helm.get("values")
            if not values_raw:
                continue
            values = yaml.safe_load(values_raw) or {}
            ing = values.get("ingress") or {}
            # ingress host + extraHosts (reserved subdomains)
            if ing.get("host"):
                add(first_label(str(ing["host"])), f"{base}:ingress.host")
            for eh in (ing.get("extraHosts") or []):
                add(first_label(str(eh)), f"{base}:ingress.extraHosts")
            # routes: path first-segments + host predicates + targeted Service
            for r in (values.get("routes") or []):
                if r.get("path"):
                    add(first_segment(str(r["path"])), f"{base}:route[{r.get('id','?')}].path")
                if r.get("host"):
                    add(first_label(str(r["host"])), f"{base}:route[{r.get('id','?')}].host")
                if r.get("uri"):
                    svc = service_of_uri(r["uri"])
                    if svc:
                        routed_services.setdefault(svc, set()).add(
                            f"{base}:route[{r.get('id','?')}].uri")

# ---- 4) route-access schema.sql url_pattern first-segments -----------------
with open(schema_path) as fh:
    sql = fh.read()
for m in re.finditer(r"'(/[^']*)'", sql):
    add(first_segment(m.group(1)), "schema.sql:url_pattern")

# Accumulate violations across all remaining stages so one run reports them all.
failed = False

# ---- 5) the assertion: reserved ⊇ deployed route prefixes ------------------
missing = sorted(set(deployed) - reserved_set)

print("== reserved-prefix route-consistency check ==")
print(f"canonical reserved labels : {len(reserved_set)}")
print(f"ConfigMap mirror          : OK (matches canonical)")
print(f"deployed route prefixes   : {len(deployed)}")
print("deployed prefixes observed :")
for label in sorted(deployed):
    mark = "OK " if label in reserved_set else "MISSING"
    src = ", ".join(sorted(deployed[label]))
    print(f"  [{mark}] {label:<14} <- {src}")

if missing:
    failed = True
    print()
    print("FAIL: these DEPLOYED route prefixes are NOT in the canonical reserved set:", file=sys.stderr)
    for label in missing:
        print(f"  - {label}  (sources: {', '.join(sorted(deployed[label]))})", file=sys.stderr)
    print(file=sys.stderr)
    print("Add each to specs/cluster/reserved-prefixes.yaml (and the app-repo", file=sys.stderr)
    print("ReservedNames copies), re-run scripts/sync-reserved-configmap.sh, retry.", file=sys.stderr)
else:
    print()
    print(f"PASS: canonical reserved set covers all {len(deployed)} deployed route prefixes.")

# ---- 6) SCOPED Service-name drift -------------------------------------------
# A naive "every kind:Service must be reserved" check would be RED day-one
# (akkoma-proxy / *-db / kafka / eureka are Services but never publicly routable).
# So we scope to the PUBLICLY-ROUTABLE Services — the ones a gateway route uri
# actually targets — and exempt the rest by an EXPLICIT allowlist. A routed
# Service whose name's first label is NOT reserved AND NOT allowlisted is drift.
#
# The allowlist is the set of routed-but-internal targets: the platform's own
# gateways/BFFs/UIs (already covered by their PATH prefix, e.g. /bff, /admin —
# the bare hugmesh-*-api/-ui/-web Service name is an implementation detail,
# not a public username surface) plus infra patterns. Keep it narrow and explicit.
SERVICE_ALLOW_EXACT = {
    # mTLS homeserver PROXY sidecars — internal, behind the reserved mastodon./
    # matrix. hosts; never a public first-label of their own.
    "akkoma-proxy", "tuwunel-proxy",
    # identity / mesh internals reached only via reserved hosts (id./scale.) or a
    # reserved path (/login, /api/auth, /.well-known).
    "casdoor", "casdoor-games", "headscale",
    # the Casdoor pre-signup confusable gate proxy — an internal seam in front of
    # casdoor's /api/signup + /api/login (manifests/signup-gate). Reached only via
    # those specific paths, never a public username first-label of its own.
    "signup-gate",
    # NOTE: the host-shell web Service used to need an EXACT entry here — it kept a
    # pre-rebrand name because it is the compose DNS name the fe-gateway routes
    # target, so renaming it needed both sides moved together. It was renamed to
    # `hugmesh-host-shell` — matching its build context and repo — and is now covered
    # by the `^hugmesh-.*$` family pattern below, exactly as the character-forge pair
    # was. (Its PUBLIC surface is unchanged: the frontend-host /** catch-all.)
    # This used to record a SPLIT: the compose lane had moved but the specs/cluster
    # lane was still `hugmesh-systems-web`, a half-renamed hybrid carrying no banned
    # token — which is precisely why no grep-driven sweep ever found it. Both lanes
    # now say `hugmesh-host-shell`, and that is no longer a NOTE anybody has to
    # remember: stage 6b below ASSERTS it, cross-lane, and fails on any future hybrid.
    # NOTE: the two character-forge Services used to need EXACT entries here
    # (they were created under the pre-rebrand brand prefix).
    # The HugMesh rebrand renamed them to
    # hugmesh-character-forge-{bff-api,ui}, so they are now covered by the
    # `^hugmesh-.*$` family pattern below and the exact entries were removed.
    # (Their PUBLIC surface — the reserved `/character-forge/**` +
    # `/bff/character-forge/**` route prefixes — is still what stages 3/5 enforce;
    # the `character-forge` LABEL itself stays reserved, it is a feature slug and
    # was NOT rebranded.)
}
# Regex patterns for routed-but-internal Service families:
#   * ALL `hugmesh-*` Services — the platform's own gateways / BFFs / UIs /
#     APIs / web / remote-fragment. These are ALWAYS reached via a reserved PATH
#     prefix or reserved HOST (already checked by stages 3/5); the bare branded
#     Service name (which sed-rebrands per deployer, see the branding model) is an
#     implementation detail, NOT a public username first-label. Exempt as a family
#     so adding a new hugmesh-*-api/-ui never trips this stage spuriously — its
#     PUBLIC surface (the route prefix) is what stage 3/5 enforces is reserved.
#   * `*-db` / `*-pg` datastores — never publicly routed.
SERVICE_ALLOW_PATTERNS = [
    re.compile(r"^hugmesh-.*$"),  # the platform-internal hugmesh-* family
    re.compile(r"^.*-(db|pg)$"),     # *-db / *-pg datastores
]


def service_allowed(name):
    if name in SERVICE_ALLOW_EXACT:
        return True
    return any(p.match(name) for p in SERVICE_ALLOW_PATTERNS)


svc_drift = sorted(
    name
    for name in routed_services
    if first_label(name) not in reserved_set and not service_allowed(name)
)

print()
print("== scoped publicly-routable Service drift check ==")
print(f"routed Services (route uri targets): {len(routed_services)}")
for name in sorted(routed_services):
    if first_label(name) in reserved_set:
        mark = "OK(reserved)"
    elif service_allowed(name):
        mark = "OK(allowlist)"
    else:
        mark = "DRIFT"
    print(f"  [{mark:<13}] {name}")

if svc_drift:
    failed = True
    print()
    print("FAIL: these PUBLICLY-ROUTABLE Services are neither reserved nor allowlisted:", file=sys.stderr)
    for name in svc_drift:
        print(f"  - {name}  (targeted by: {', '.join(sorted(routed_services[name]))})", file=sys.stderr)
    print(file=sys.stderr)
    print("Either reserve the Service's public first-label in", file=sys.stderr)
    print("specs/cluster/reserved-prefixes.yaml, or add it to the explicit internal", file=sys.stderr)
    print("allowlist in this script (SERVICE_ALLOW_EXACT / SERVICE_ALLOW_PATTERNS).", file=sys.stderr)
else:
    print()
    print("PASS: every publicly-routable Service is reserved or explicitly allowlisted.")

# ---- 6b) HALF-RENAME gate: hybrid names + the host shell's paired move -------
# WHY THIS STAGE EXISTS
# --------------------
# The host shell was renamed `snapdragon-systems-web` -> `hugmesh-host-shell`, but
# an intermediate sweep left it as `hugmesh-systems-web`. That hybrid carries NO
# banned token — it is already `hugmesh-` prefixed — so every grep-driven rename
# sweep since has reported the tree CLEAN while the cluster lane still pointed at
# a Service by its half-renamed name. It survived precisely because it looked done.
#
# Worse, the rename is a PAIRED move. The Deployment name, its `app:` selector
# labels, the Service name, the HPA scaleTargetRef, the PDB selector and the ArgoCD
# Application name must all move in one commit — move a subset and the Service
# selects no pods, or ArgoCD orphans the old Application — and the fe-gateway's
# `/**` catch-all in the OTHER lane has to move with it or the front page 502s.
# Nothing about any single file makes that coupling visible, which is how the
# kustomize image match keys broke before.
#
# So both halves become assertions here rather than prose anyone must remember:
#   (a) NO first-party workload name may be a `-systems-` hybrid, in any lane.
#   (b) Every name in the host shell's paired set must be the SAME string, across
#       the cluster manifests, the ArgoCD Application, and the compose lane.
FIRST_PARTY_NAME_RE = re.compile(r"(?:\{\{BRAND\}\}|hugmesh)-[a-z0-9-]+")

# The DEPLOYABLE lanes — the files that actually name workloads and route to
# them. Deliberately TEXT-scanned, not YAML-parsed: the hybrid survived inside a
# bash array in bootstrap-kind.sh and an nginx.conf comment, neither of which a
# structured parse would ever reach. Scoped to these lanes so that prose
# elsewhere (this script's own history note, a test's SHELL_HINT rationale) may
# still spell the retired name when explaining it.
HYBRID_SCAN_GLOBS = [
    "specs/cluster/apps/*.yaml",
    "specs/cluster/manifests/**/*.yaml",
    "specs/cluster/manifests/**/*.conf",
    "specs/cluster/bootstrap/**/*.sh",
    "templates/apps/*.hbs",
    "tests/stack/compose.local.yaml",
    "tests/stack/gateway-routes/**/*.yml",
]


def is_hybrid(name):
    """A first-party name that still carries the retired `systems` infix."""
    return "-systems-" in name or name.endswith("-systems")


hybrids = {}  # name -> set("relpath:line")
for pattern in HYBRID_SCAN_GLOBS:
    for path in sorted(glob.glob(os.path.join(repo_root, pattern), recursive=True)):
        rel = os.path.relpath(path, repo_root)
        try:
            with open(path, encoding="utf-8", errors="replace") as fh:
                for lineno, line in enumerate(fh, 1):
                    for name in FIRST_PARTY_NAME_RE.findall(line):
                        if is_hybrid(name):
                            hybrids.setdefault(name, set()).add(f"{rel}:{lineno}")
        except OSError as e:
            print(f"FATAL: cannot read {rel} ({e})", file=sys.stderr)
            sys.exit(2)

print()
print("== half-rename hybrid gate ==")
print(f"deployable lanes scanned : {len(HYBRID_SCAN_GLOBS)} glob(s)")
if hybrids:
    failed = True
    print()
    print("FAIL: first-party workload name(s) still carry the retired `-systems-` "
          "infix — this is a HALF-RENAMED hybrid:", file=sys.stderr)
    for name in sorted(hybrids):
        print(f"  - {name}", file=sys.stderr)
        for src in sorted(hybrids[name]):
            print(f"      {src}", file=sys.stderr)
    print(file=sys.stderr)
    print("A hybrid is `hugmesh-`-prefixed, so it carries no banned token and NO "
          "grep-driven", file=sys.stderr)
    print("rename sweep will ever surface it. Finish the rename in every lane in "
          "ONE commit.", file=sys.stderr)
else:
    print("PASS: no `-systems-` hybrid in any first-party workload name.")


def uri_host_label(uri):
    """First DNS label of a route uri's host, for cluster AND compose spellings.
    http://hugmesh-host-shell.hugmesh-frontend.svc.cluster.local:80 -> host-shell? no:
      -> 'hugmesh-host-shell'  ; http://hugmesh-host-shell:8080 -> 'hugmesh-host-shell'."""
    m = re.match(r"^[a-z0-9+.-]+://([a-z0-9-]+)", str(uri))
    return m.group(1) if m else None


def load_docs(relpath):
    with open(os.path.join(repo_root, relpath)) as fh:
        return [d for d in yaml.safe_load_all(fh) if d]


def find_route(node, route_id):
    """Depth-first search for a route dict with this id, under ANY `routes:` list.
    Deliberately shape-agnostic: the cluster lane nests routes under an ArgoCD
    helm `values` string, the compose lane under
    spring.cloud.gateway.server.webflux.routes, and that Spring path has already
    moved once (…gateway.routes -> …gateway.server.webflux.routes). Hard-coding
    either spelling would make this assertion quietly stop finding the route —
    the same silent-pass failure the whole stage exists to prevent."""
    if isinstance(node, dict):
        for r in (node.get("routes") or []) if isinstance(node.get("routes"), list) else []:
            if isinstance(r, dict) and r.get("id") == route_id:
                return r
        for v in node.values():
            hit = find_route(v, route_id)
            if hit:
                return hit
    elif isinstance(node, list):
        for v in node:
            hit = find_route(v, route_id)
            if hit:
                return hit
    return None


def route_uri_by_id(relpath, route_id):
    """The uri of one route in an ArgoCD-wrapped or plain Spring route table."""
    for doc in load_docs(relpath):
        helm = (((doc.get("spec") or {}).get("source") or {}).get("helm") or {})
        if helm.get("values"):
            hit = find_route(yaml.safe_load(helm["values"]) or {}, route_id)
            if hit:
                return hit.get("uri")
        hit = find_route(doc, route_id)
        if hit:
            return hit.get("uri")
    # A route id that resolves NOWHERE must fail the assertion, not pass it
    # silently as "nothing to compare".
    return f"<no route id '{route_id}' in {relpath}>"


# (b) the host shell's paired set. ANCHOR on the Service name in the frontend
# manifests — the Service is what the gateway route dials, so it is the one name
# every other member of the set has to agree with.
FRONTEND_DIR = "specs/cluster/manifests/frontend"
paired = {}  # human label -> observed value
try:
    fe_docs = load_docs(f"{FRONTEND_DIR}/deployment.yaml")
    dep = next(d for d in fe_docs if d.get("kind") == "Deployment")
    svc = next(d for d in fe_docs if d.get("kind") == "Service")
    shell = svc["metadata"]["name"]

    paired["Deployment metadata.name"] = dep["metadata"]["name"]
    paired["Deployment metadata.labels.app"] = (dep["metadata"].get("labels") or {}).get("app")
    paired["Deployment spec.selector.matchLabels.app"] = \
        ((dep["spec"].get("selector") or {}).get("matchLabels") or {}).get("app")
    paired["Deployment pod template labels.app"] = \
        ((dep["spec"]["template"].get("metadata") or {}).get("labels") or {}).get("app")
    paired["Service spec.selector.app"] = (svc["spec"].get("selector") or {}).get("app")

    hpa = next(d for d in load_docs(f"{FRONTEND_DIR}/hpa.yaml")
               if d.get("kind") == "HorizontalPodAutoscaler")
    paired["HPA metadata.name"] = hpa["metadata"]["name"]
    paired["HPA spec.scaleTargetRef.name"] = (hpa["spec"].get("scaleTargetRef") or {}).get("name")

    pdb = next(d for d in load_docs(f"{FRONTEND_DIR}/pdb.yaml")
               if d.get("kind") == "PodDisruptionBudget")
    paired["PDB metadata.name"] = pdb["metadata"]["name"]
    paired["PDB spec.selector.matchLabels.app"] = \
        ((pdb["spec"].get("selector") or {}).get("matchLabels") or {}).get("app")

    app = next(d for d in load_docs("specs/cluster/apps/40-frontend.yaml")
               if d.get("kind") == "Application")
    paired["ArgoCD Application metadata.name"] = app["metadata"]["name"]

    # BOTH lanes' front-page catch-all must dial that same Service.
    paired["cluster fe route[frontend-host].uri"] = uri_host_label(
        route_uri_by_id("specs/cluster/apps/20-gateway-fe.yaml", "frontend-host"))
    paired["compose fe route[frontend-host].uri"] = uri_host_label(
        route_uri_by_id("tests/stack/gateway-routes/fe/application-routes.yml", "frontend-host"))

    # …and the compose lane must actually DEFINE a service under that name.
    compose = load_docs("tests/stack/compose.local.yaml")[0]
    compose_services = set((compose.get("services") or {}).keys())
    paired["compose.local.yaml services[<shell>]"] = \
        shell if shell in compose_services else f"<absent: {sorted(compose_services)[:1]}…>"
except (OSError, KeyError, StopIteration, TypeError) as e:
    failed = True
    shell = None
    print()
    print(f"FAIL: cannot resolve the host shell's paired name set ({e!r}).", file=sys.stderr)

if shell:
    mismatched = {k: v for k, v in paired.items() if v != shell}
    print()
    print("== host-shell paired-move assertion ==")
    print(f"anchor (frontend Service name) : {shell}")
    for k in sorted(paired):
        mark = "OK" if paired[k] == shell else "MISMATCH"
        print(f"  [{mark:<8}] {k} = {paired[k]}")
    if mismatched:
        failed = True
        print()
        print("FAIL: the host shell's name did NOT move as one set. These disagree "
              f"with the Service name '{shell}':", file=sys.stderr)
        for k in sorted(mismatched):
            print(f"  - {k} = {mismatched[k]}", file=sys.stderr)
        print(file=sys.stderr)
        print("Selector labels, the Service, the HPA target, the PDB selector, the "
              "ArgoCD Application", file=sys.stderr)
        print("name and BOTH lanes' /** catch-all route must move in the SAME "
              "commit — a partial move", file=sys.stderr)
        print("means the Service selects no pods, or the front page 502s.", file=sys.stderr)
    else:
        print()
        print(f"PASS: all {len(paired)} members of the host-shell name set agree "
              "across both lanes.")

# ---- 7) CODE-COPY assertion: each ReservedNames.java set == canonical -------
# Mechanically asserts the app-repo ReservedNames copies match the canonical set
# (replaces hand-counting). There are THREE physical copies today: federation-api
# and actions each keep their own literal duplicate, and hugmesh-auth-core holds
# the shared copy that user-bff-api + admin-bff-api both consume as a Maven
# dependency (`import systems.hugmesh.authcore.reserved.ReservedNames`) — so
# checking auth-core covers both BFFs, which no longer carry their own file. (The
# old userbff/profile + adminbff/reserved paths were removed when the copy was
# consolidated into auth-core; listing them here only produced silent SKIPs and
# left the real shared copy unchecked.) NOT SKIP-AND-PASS: a copy that is not
# present is reported [MISSING] and makes the whole run INCOMPLETE (exit 3) — an
# assertion that did not run is not a pass, and the previous skip-and-still-PASS
# behaviour is precisely why the hugmesh-actions drift survived in a "green" tree.
# Point RESERVED_SIBLING_ROOT at a tree holding the copies (CI clones them), or
# set RESERVED_ALLOW_MISSING_COPIES=1 to opt out deliberately. Handles both field
# names in use (RESERVED_LABELS in federation-api; RESERVED in
# hugmesh-actions/hugmesh-auth-core).
CODE_COPIES = [
    ("federation-api", "hugmesh-federation-api",
     "src/main/java/net/hugmesh/federation/controller/ReservedNames.java"),
    ("actions", "hugmesh-actions",
     "src/main/java/net/hugmesh/actions/registration/ReservedNames.java"),
    ("auth-core", "hugmesh-auth-core",
     "src/main/java/net/hugmesh/authcore/reserved/ReservedNames.java"),
]

# Pull the quoted string literals out of the `RESERVED[_LABELS] = Set.of( … );`
# initializer only (so doc-comment examples elsewhere in the file are ignored).
SET_OF_RE = re.compile(
    r"\b(?:RESERVED_LABELS|RESERVED)\s*=\s*Set\.of\((.*?)\)\s*;", re.S)
STRLIT_RE = re.compile(r'"([^"\\]*)"')


def parse_java_reserved(path):
    src = open(path, encoding="utf-8").read()
    m = SET_OF_RE.search(src)
    if not m:
        return None
    # Strip comments from the captured Set.of(...) body BEFORE harvesting string
    # literals, so a quoted token that only appears inside a // or /* */ comment
    # (e.g. an illustrative example) is NOT falsely picked up as a reserved label
    # and treated as drift. Block comments first, then line comments.
    body = m.group(1)
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    body = re.sub(r"//[^\n]*", "", body)
    return {s.lower() for s in STRLIT_RE.findall(body)}


# Regression assertion: a quoted token inside a comment within the Set.of body
# must NOT be harvested (the comment-stripping above). We exercise the same code
# path by writing a tiny throwaway file and parsing it, asserting the commented
# token is absent and the real tokens are present.
def _self_test_comment_stripping():
    import tempfile
    sample = (
        "package x;\n"
        "class T {\n"
        "  static final Set<String> RESERVED = Set.of(\n"
        '    "real-one",        // do NOT reserve "fake-line", it is an example\n'
        '    /* also avoid "fake-block" here */ "real-two"\n'
        "  );\n"
        "}\n"
    )
    with tempfile.NamedTemporaryFile(
            "w", suffix=".java", delete=False, encoding="utf-8") as tf:
        tf.write(sample)
        tmp_path = tf.name
    try:
        parsed = parse_java_reserved(tmp_path)
    finally:
        os.unlink(tmp_path)
    assert parsed == {"real-one", "real-two"}, (
        f"comment-stripping regression FAILED: expected only the real tokens, "
        f"got {sorted(parsed) if parsed else parsed}")


_self_test_comment_stripping()

print()
print("== ReservedNames.java code-copy assertion ==")
print(f"sibling search root : {sibling_root}")
# CASE: parse_java_reserved() lower-cases every literal (the app-repo copies store
# their labels lower-case and match case-insensitively — isReserved() lower-cases
# the candidate first). The canonical YAML keeps the real on-disk case for the one
# mixed-case label, `remoteEntry.json` (the actual module-federation manifest
# filename). So this code-copy assertion must compare case-INSENSITIVELY, else
# `remoteEntry.json` would false-flag as drift for every copy no matter how it is
# spelled (parse always folds it to `remoteentry.json`). Stages 2-4 above keep case
# on purpose (they match literal route path segments like `/remoteEntry.json`, where
# case is significant) — only THIS stage folds it.
reserved_set_lower = {r.lower() for r in reserved_set}
# Copies the assertion could NOT run against. Tracked PER COPY, not as a single
# "did anything get checked" flag: with the old `any_checked` boolean, 2 present +
# 1 absent still reported a clean PASS, i.e. the ONE copy that drifted could be
# the very one that was silently skipped.
missing_copies = []
for label, repo, rel in CODE_COPIES:
    jpath = os.path.join(sibling_root, repo, rel)
    if not os.path.isfile(jpath):
        missing_copies.append((label, repo, jpath))
        print(f"  [MISSING] {label:<13} NOT CHECKED — no such file: {jpath}")
        continue
    parsed = parse_java_reserved(jpath)
    if parsed is None:
        failed = True
        print(f"  [FAIL] {label:<16} could NOT parse RESERVED[_LABELS] Set.of(...) "
              f"in {jpath}", file=sys.stderr)
        continue
    only_canon = sorted(reserved_set_lower - parsed)
    only_copy = sorted(parsed - reserved_set_lower)
    if only_canon or only_copy:
        failed = True
        print(f"  [FAIL] {label:<16} DRIFTED from canonical:", file=sys.stderr)
        if only_canon:
            print(f"           in canonical but MISSING from {repo}: {only_canon}", file=sys.stderr)
        if only_copy:
            print(f"           in {repo} but NOT canonical: {only_copy}", file=sys.stderr)
    else:
        print(f"  [OK]   {label:<16} ({len(parsed)} labels == canonical)")

incomplete = bool(missing_copies)
if incomplete:
    print()
    print(f"INCOMPLETE: the code-copy assertion could NOT run for "
          f"{len(missing_copies)} of {len(CODE_COPIES)} ReservedNames.java "
          f"copies:", file=sys.stderr)
    for label, repo, jpath in missing_copies:
        print(f"  - {label} ({repo}) -> {jpath}", file=sys.stderr)
    print(file=sys.stderr)
    print("This stage is what mechanically proves the app-repo copies match the", file=sys.stderr)
    print("canonical set; an unrun assertion is NOT a pass. Fix by either:", file=sys.stderr)
    print(f"  * checking the repos out under the sibling root ({sibling_root}), or", file=sys.stderr)
    print("  * RESERVED_SIBLING_ROOT=/path/to/tree scripts/validate-reserved-prefixes.sh, or", file=sys.stderr)
    print("  * RESERVED_ALLOW_MISSING_COPIES=1 to accept an INCOMPLETE run on purpose", file=sys.stderr)
    print("    (never in CI — .gitlab-ci.yml's lint:reserved-prefixes clones them).", file=sys.stderr)
else:
    print(f"  all {len(CODE_COPIES)} declared copies were present and checked.")

# ---- final verdict ----------------------------------------------------------
# Three distinct verdicts, three distinct exit codes — see the EXIT CODES block at
# the top of this file. A run that skipped the code-copy assertion must never be
# indistinguishable from one that ran it.
print()
if failed:
    print("RESULT: FAIL — see the violations above.", file=sys.stderr)
    sys.exit(1)
if incomplete:
    if allow_missing_copies:
        print("RESULT: PASS (INCOMPLETE — code-copy assertion SKIPPED for "
              f"{len(missing_copies)}/{len(CODE_COPIES)} copies; exit 0 forced by "
              "RESERVED_ALLOW_MISSING_COPIES=1). The other stages are consistent; "
              "the copies were NOT verified.")
        sys.exit(0)
    print("RESULT: INCOMPLETE — no drift found in the stages that ran, but the "
          f"code-copy assertion did NOT run ({len(missing_copies)}/"
          f"{len(CODE_COPIES)} copies absent). NOT a pass.", file=sys.stderr)
    sys.exit(3)
print("RESULT: PASS — canonical reserved set is consistent across all stages.")
sys.exit(0)
PY
