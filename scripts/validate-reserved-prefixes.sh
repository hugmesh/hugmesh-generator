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
#   5) CODE-COPY assertion — when the sibling app repos are checked out next to
#      this one (or REReservedNames paths are given), parse each ReservedNames.java
#      RESERVED[_LABELS] set and assert it EQUALS the canonical set. SKIPPED (not
#      failed) for any copy not present, so this repo's own CI stays green while a
#      developer with the siblings checked out gets the mechanical drift check that
#      replaces hand-counting. PLANNED reserves (forum/phpbb) are expected in the
#      canonical set without a deployed route — they are NEVER flagged by stage 3/4.
#
# Wired into .gitlab-ci.yml (lint stage). Uses python3 + PyYAML (present in CI)
# for robust YAML parsing; degrades to a clear error if python3/PyYAML is absent.
#
# Exit 0 = consistent; non-zero = drift / mismatch (prints the offending labels).
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
# assertion). Default: sibling checkouts next to this repo (…/GitHub/<repo>). Any
# absent copy is SKIPPED, not failed — so this repo's own CI (which does not check
# out the app repos) stays green; a developer with the siblings present gets the
# mechanical drift check. Override the search root with RESERVED_SIBLING_ROOT.
SIBLING_ROOT="${RESERVED_SIBLING_ROOT:-$(cd "${REPO_ROOT}/.." && pwd)}"

for f in "$CANONICAL" "$CONFIGMAP" "$SCHEMA_SQL"; do
  [[ -f "$f" ]] || { echo "FATAL: missing required file: $f" >&2; exit 2; }
done

if ! command -v python3 >/dev/null 2>&1; then
  echo "FATAL: python3 is required to parse the gateway YAML." >&2
  exit 2
fi

# Hand off to python for the actual set-logic (YAML + SQL parsing). The script
# prints a human report and exits non-zero on any violation.
python3 - "$CANONICAL" "$CONFIGMAP" "$SCHEMA_SQL" "$GATEWAY_GLOB" "$MANIFESTS_DIR" "$SIBLING_ROOT" <<'PY'
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
) = sys.argv[1:7]

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
    # the host-shell web Service KEPT its pre-rebrand name (the rebrand renamed the
    # hugmesh-* family pattern below but not this Service) — reached only via the
    # frontend-host /** catch-all, never a public first-label of its own.
    "snapdragon-systems-web",
    # character-forge Services keep the repo's DESIGN-locked snapdragon-* names
    # (the repo was CREATED as snapdragon-character-forge-bff-api; docs/XR-CHAT.md).
    # Both are reached only via the reserved `/character-forge/**` +
    # `/bff/character-forge/**` route prefixes (stage 3/5-enforced), never a public
    # first-label of their own.
    "snapdragon-character-forge-bff-api", "snapdragon-character-forge-ui",
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

# ---- 7) CODE-COPY assertion: each ReservedNames.java set == canonical -------
# Mechanically asserts the app-repo ReservedNames copies match the canonical set
# (replaces hand-counting). There are THREE physical copies today: federation-api
# and actions each keep their own literal duplicate, and hugmesh-auth-core holds
# the shared copy that user-bff-api + admin-bff-api both consume as a Maven
# dependency (`import systems.hugmesh.authcore.reserved.ReservedNames`) — so
# checking auth-core covers both BFFs, which no longer carry their own file. (The
# old userbff/profile + adminbff/reserved paths were removed when the copy was
# consolidated into auth-core; listing them here only produced silent SKIPs and
# left the real shared copy unchecked.) SKIP-IF-ABSENT: a copy not checked out next
# to this repo is reported as SKIP, not failed, so this repo's own CI stays green —
# the app repos run their own ReservedNamesTest. Override the search root with
# RESERVED_SIBLING_ROOT. Handles both field names in use (RESERVED_LABELS in
# federation-api; RESERVED in hugmesh-actions/hugmesh-auth-core).
CODE_COPIES = [
    ("federation-api", "hugmesh-federation-api",
     "src/main/java/systems/hugmesh/federation/controller/ReservedNames.java"),
    ("actions", "hugmesh-actions",
     "src/main/java/systems/hugmesh/actions/registration/ReservedNames.java"),
    ("auth-core", "hugmesh-auth-core",
     "src/main/java/systems/hugmesh/authcore/reserved/ReservedNames.java"),
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
any_checked = False
for label, repo, rel in CODE_COPIES:
    jpath = os.path.join(sibling_root, repo, rel)
    if not os.path.isfile(jpath):
        print(f"  [SKIP] {label:<16} (not checked out: {repo})")
        continue
    parsed = parse_java_reserved(jpath)
    if parsed is None:
        failed = True
        print(f"  [FAIL] {label:<16} could NOT parse RESERVED[_LABELS] Set.of(...) "
              f"in {jpath}", file=sys.stderr)
        continue
    any_checked = True
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

if not any_checked:
    print("  note: no app-repo copies were present — code-copy assertion skipped.")
    print("        (run with the app repos checked out, or set RESERVED_SIBLING_ROOT,")
    print("         to mechanically verify the four ReservedNames.java sets.)")

# ---- final verdict ----------------------------------------------------------
print()
if failed:
    print("RESULT: FAIL — see the violations above.", file=sys.stderr)
    sys.exit(1)
print("RESULT: PASS — canonical reserved set is consistent across all stages.")
sys.exit(0)
PY
