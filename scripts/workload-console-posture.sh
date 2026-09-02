#!/usr/bin/env bash
# workload-console-posture.sh — print which of the Workload Console's FOUR gates are
# open, and therefore whether "stats + running versions" can render for anybody at all.
#
# WHY THIS EXISTS. The operator asked how to view stats on the running services and
# which versions are running, and could not find it. The console that answers both
# questions is real, rich, and shipped DARK behind four INDEPENDENT gates
# (docs/OPTIONAL-SERVICES.md §7.2 counts three OFFs; the third is really two, because
# the DB master flag and the per-admin TTL'd grant are separate rows in separate tables
# flipped by separate endpoints). Opening one of the four changes NOTHING an operator
# can see, so "I enabled it and it still shows nothing" is the expected experience and
# not a bug. This tool exists so the answer to "why do I see nothing?" is a measurement
# instead of a guess, and so it names EVERY gate still shut rather than the first one.
#
# WHAT IT MEASURES, AND WHAT IT CANNOT.
#   Gates 1 and 2 are BUILD-TIME and leave physical evidence: gate_optional_services
#   PRUNES the overlay, the kustomization line, the RBAC Application and the two
#   route-access rows when the workloadConsole slug is deselected (the default). So the
#   honest measurement is the EFFECT on a rendered cluster tree — the files that are
#   there — never the builder's intent and never a grep for the slug name. Pass the
#   rendered tree with --tree.
#   Gates 3 and 4 live in POSTGRES (workload_console_config / workload_console_grant in
#   the admin-bff schema). Nothing in this repo, and nothing kubectl can reach, can read
#   them. They are therefore UNKNOWN unless the caller measures them and says so with
#   --db-admin-enabled / --active-grants. UNKNOWN IS NEVER TREATED AS OPEN: the verdict
#   is DARK and the reason printed is "not measured", because an unmeasured gate is an
#   unproven one and the friendlier default would report a console nobody can see.
#
# WHY THIS PARSES YAML AND DOES NOT SCAN LINES (a review finding, and it was REAL).
# The first version of this tool scanned the overlay's text with regexes and was wrong
# in three ways that all report a LIT console the operator cannot see — and closing those
# three surfaced a fourth of the same family:
#   * THE MOUNT WAS NEVER MEASURED. The contract token path
#     /var/run/secrets/workload-console-read/token is a FILE; the volumeMount's
#     mountPath is its PARENT DIRECTORY. The only line in the overlay carrying the full
#     path is the env var that names it, so `path in text` tested the ENV and called it
#     the mount. Deleting both volumeMounts, or the whole `volumes:` block, left the
#     tool saying LIT on a console that 503s.
#   * DUPLICATE env ENTRIES WERE INVISIBLE. A line scanner returned the FIRST match;
#     the kubelet takes the LAST. Appending WORKLOAD_CONSOLE_ENABLED=false further down
#     the same env list turns the console off and the tool still said LIT.
#   * A PATCH THAT TARGETS NOTHING LOOKED FINE. One character wrong in the overlay's
#     metadata.name and it matches no resource. Measured with kubectl kustomize: the
#     build FAILS outright ("no resource matches strategic merge patch ... no matches
#     for Id"), so ArgoCD cannot sync the admin-bff at all — and the scanner, which only
#     ever read env-looking lines, reported all four gates open.
#   * A PATCH ON THE WRONG CONTAINER RENDERED CLEAN. Found while closing the three
#     above, and the nastiest of the family because NOTHING goes red: patch the right
#     Deployment but a container `name` it does not have and `kustomize build` succeeds,
#     ArgoCD syncs, the admin-bff is healthy. A strategic merge on `containers` is keyed
#     on `name`, so an unmatched name is not an override — measured with kubectl
#     kustomize, it ADDS A SECOND CONTAINER holding every WORKLOAD_CONSOLE_* var while
#     the real app container renders with none of them. Every text-level fact (env
#     present, mounts present, volumes present) is true of that render.
# All four are now structural checks on a real YAML load, each with its own reason
# line. PyYAML is therefore a HARD dependency (as it already is for §9 of the
# accompanying guard); an absent one is an ERROR, never a fallback to guessing.
#
# STILL NOT MEASURED, and these are real: env delivered via `envFrom` (a ConfigMap or
# Secret reference) instead of an inline `env:` entry is invisible to this tool, as is
# any drift between a cluster and the tree it was built from (there is no live mode —
# a manual `kubectl set env` cannot be seen from here).
#
# Usage:
#   scripts/workload-console-posture.sh [--tree=DIR] [--db-admin-enabled=true|false]
#                                       [--active-grants=N] [--require-lit]
#
#   --tree=DIR              a RENDERED cluster tree (the directory holding apps/ and
#                           manifests/). Default: this repo's specs/cluster, which is the
#                           LIT SOURCE — a real device tree is the post-gate one, and the
#                           report says so out loud when the default is used.
#   --db-admin-enabled=     workload_console_config.admin_enabled for the domain in
#                           question, as MEASURED (see the SQL in the report footer).
#   --active-grants=N       count of workload_console_grant rows with state='active' and
#                           expires_at > now() for the admin you care about.
#   --require-lit           exit 3 when the verdict is DARK (for scripting). Without it
#                           the exit code says only whether the posture was DETERMINABLE.
#
# Exit codes: 0 posture determined and printed · 1 could not determine (unreadable tree,
#             or no python3/PyYAML) · 2 usage error · 3 DARK and --require-lit was given.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"

TREE=""
TREE_IS_DEFAULT=1
DB_ADMIN_ENABLED="unknown"
ACTIVE_GRANTS="unknown"
REQUIRE_LIT=""

die() { echo "workload-console-posture.sh: $*" >&2; exit 2; }

for arg in "$@"; do
  case "${arg}" in
    --tree=*)              TREE="${arg#*=}"; TREE_IS_DEFAULT=0 ;;
    --db-admin-enabled=*)  DB_ADMIN_ENABLED="${arg#*=}" ;;
    --active-grants=*)     ACTIVE_GRANTS="${arg#*=}" ;;
    --require-lit)         REQUIRE_LIT=1 ;;
    # The WHOLE header block, found by where the comments STOP. A hardcoded line
    # range silently truncates the help the next time the header grows — which it just
    # did, twice — and a truncated help is a help that omits the caveats.
    -h|--help)             awk 'NR>1 && $0 !~ /^#/ { exit } { print }' "${BASH_SOURCE[0]}"; exit 0 ;;
    *)                     die "unknown argument '${arg}'" ;;
  esac
done

[ -n "${TREE}" ] || TREE="${REPO}/specs/cluster"

case "${DB_ADMIN_ENABLED}" in
  true|false|unknown) ;;
  *) die "--db-admin-enabled must be true, false or unknown (got '${DB_ADMIN_ENABLED}')" ;;
esac
case "${ACTIVE_GRANTS}" in
  unknown) ;;
  ''|*[!0-9]*) die "--active-grants must be a non-negative integer or unknown (got '${ACTIVE_GRANTS}')" ;;
esac

# A tool that cannot read its source must say so, not assume a posture.
[ -d "${TREE}" ] || { echo "workload-console-posture.sh: cannot read cluster tree '${TREE}'" >&2; exit 1; }

command -v python3 >/dev/null 2>&1 \
  || { echo "workload-console-posture.sh: python3 is required to parse the overlay (refusing to guess)" >&2; exit 1; }
python3 -c 'import yaml' >/dev/null 2>&1 \
  || { echo "workload-console-posture.sh: PyYAML is required — the mount, the duplicate-env and the patch-target checks are STRUCTURAL and a line scanner gets all three wrong (see the header). Install python3-yaml; refusing to guess." >&2; exit 1; }

OUT="$(TREE="${TREE}" TREE_IS_DEFAULT="${TREE_IS_DEFAULT}" \
       DB_ADMIN_ENABLED="${DB_ADMIN_ENABLED}" ACTIVE_GRANTS="${ACTIVE_GRANTS}" \
       python3 - <<'PY'
import os, re, sys
import yaml

tree = os.environ["TREE"]
default_tree = os.environ["TREE_IS_DEFAULT"] == "1"
db_flag = os.environ["DB_ADMIN_ENABLED"]
grants = os.environ["ACTIVE_GRANTS"]

BFFDIR  = os.path.join(tree, "manifests", "admin-bff-api")
OVERLAY = os.path.join(BFFDIR, "workload-console-patch.yaml")
KUST    = os.path.join(BFFDIR, "kustomization.yaml")
RBACAPP = os.path.join(tree, "apps", "14-workload-console-rbac.yaml")
TOKENS  = os.path.join(tree, "manifests", "workload-console-rbac", "token-secrets.yaml")
ROUTES  = os.path.join(tree, "manifests", "route-access", "initdb", "20-schema.sql")

# The cross-repo mount contract (WorkloadConsoleClientConfig). Each is a FILE; the
# volumeMount that delivers it names its PARENT DIRECTORY, which is exactly why a
# substring test for these strings can only ever find the env vars that name them.
READ_TOKEN   = "/var/run/secrets/workload-console-read/token"
MUTATE_TOKEN = "/var/run/secrets/workload-console-mutate/token"
TOKEN_FILE_ENV = {"read":   "WORKLOAD_CONSOLE_K8S_READ_TOKEN_FILE",
                  "mutate": "WORKLOAD_CONSOLE_K8S_MUTATE_TOKEN_FILE"}


def read(p):
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as fh:
            return fh.read()
    except OSError:
        return None


def load_docs(p):
    """(status, [documents]). status is 'absent', 'ok', or an 'unparseable: …' string.
    A file that is present but broken must NEVER read as a shut gate for the wrong
    reason, so the three states are kept distinct."""
    txt = read(p)
    if txt is None:
        return "absent", []
    try:
        return "ok", [d for d in yaml.safe_load_all(txt) if d is not None]
    except yaml.YAMLError as exc:
        return "unparseable: %s" % str(exc).replace("\n", " ")[:160], []


def first_doc(p):
    st, docs = load_docs(p)
    return st, (docs[0] if docs else None)


def dig(d, *keys):
    for k in keys:
        if not isinstance(d, dict):
            return None
        d = d.get(k)
    return d


def as_list(v):
    return v if isinstance(v, list) else []


def scalar(v):
    """A YAML scalar as the string the kubelet would see. `value: "true"` loads as the
    str 'true'; the (invalid, but writable) `value: true` loads as the bool True and is
    normalised here so the reported reason is about the GATE and not about quoting."""
    if v is None:
        return None
    if isinstance(v, bool):
        return "true" if v else "false"
    return str(v)


def containers_of(doc):
    return [c for c in as_list(dig(doc, "spec", "template", "spec", "containers"))
            if isinstance(c, dict)]


def env_pairs(container):
    out = []
    for e in as_list(container.get("env")):
        if isinstance(e, dict) and "name" in e:
            out.append((str(e["name"]), scalar(e.get("value"))))
    return out


def env_effective(pairs, name):
    """(value, occurrences). KUBELET SEMANTICS: when a name appears more than once in
    one container's env list the LAST entry wins. The previous line scanner returned the
    FIRST, so a later `WORKLOAD_CONSOLE_ENABLED=false` appended to the same list turned
    the console off invisibly. The occurrence count is returned so a duplicate can be
    reported as its own reason rather than silently resolved."""
    hits = [v for n, v in pairs if n == name]
    if not hits:
        return None, 0
    return hits[-1], len(hits)


def mount_covering(container, token_path):
    """The volumeMount that actually delivers token_path — the entry whose mountPath is
    that file's directory (or the file itself, via subPath). Longest match wins, the way
    the kubelet resolves nested mounts."""
    best = None
    best_len = -1
    for m in as_list(container.get("volumeMounts")):
        if not isinstance(m, dict):
            continue
        mp = str(m.get("mountPath") or "").rstrip("/")
        if not mp:
            continue
        if token_path == mp or token_path.startswith(mp + "/"):
            if len(mp) > best_len:
                best, best_len = m, len(mp)
    return best


def volume_named(doc, name):
    for v in as_list(dig(doc, "spec", "template", "spec", "volumes")):
        if isinstance(v, dict) and v.get("name") == name:
            return v
    return None


def strip_sql_comments(sql):
    r"""Every SQL comment removed, and NOTHING inside a quoted string touched.

    This is a character scanner and not a regex on purpose, twice over:

    * `re.sub(r"/\*.*?\*/", "", sql)` IS A BUG ON THIS FILE. The route patterns
      themselves contain `/**` — '/bff/admin/workloads/**' — so that regex opens a
      block comment INSIDE a quoted pattern and swallows every real row up to the
      next `*/` anywhere in the file.
    * Skipping `/* */` altogether was the hole this replaced. Measured: with the two
      real rows pruned and a block-commented copy appended, the previous parser
      counted both as seeded and the whole tool printed LIT on a tree that seeds
      NOTHING. The `--` and `/* */` legs fail separately and are planted separately
      by the guard (M4b, M4c).

    This strip is the ONLY defence, deliberately. An earlier version also anchored the
    tuple match to `^\(`, which happened to reject a `--` line for free — and that
    redundancy is worse than it looks twice over: it made a mutation that deleted the
    comment stripping survive the guard, and it reported a row written
    `VALUES ('a', …), ('b', …);` on one line as MISSING, a false DARK on a tree that
    really does seed it. The tuple scan is now unanchored and finds every tuple on the
    line, so nothing but this function keeps prose out.

    gate_optional_services removes the INSERT TUPLES and leaves prose behind —
    20-schema.sql discusses both console patterns four times — so a check that reads
    comments is green on a tree whose rows are gone. That is comment-token inversion,
    and it is the bug class this repo keeps being bitten by.

    `--` runs to end of line; `/* */` NESTS, the way PostgreSQL nests them; a single
    quoted string ends on a lone `'` and continues through the doubled `''` escape.
    Newlines are preserved so the caller still sees one tuple per line."""
    out = []
    i, n = 0, len(sql)
    depth = 0      # block-comment nesting depth
    quoted = False
    while i < n:
        c = sql[i]
        nxt = sql[i + 1] if i + 1 < n else ""
        if depth:
            if c == "/" and nxt == "*":
                depth += 1; i += 2; continue
            if c == "*" and nxt == "/":
                depth -= 1; i += 2; continue
            if c == "\n":
                out.append("\n")
            i += 1; continue
        if quoted:
            out.append(c)
            if c == "'":
                if nxt == "'":
                    out.append(nxt); i += 2; continue
                quoted = False
            i += 1; continue
        if c == "'":
            quoted = True; out.append(c); i += 1; continue
        if c == "-" and nxt == "-":
            while i < n and sql[i] != "\n":
                i += 1
            continue
        if c == "/" and nxt == "*":
            depth = 1; i += 2; continue
        out.append(c); i += 1
    return "".join(out)


def route_rows(sql):
    """The route-access patterns actually SEEDED, from the INSERT tuples only —
    every comment form stripped first (see strip_sql_comments)."""
    pats = set()
    for l in strip_sql_comments(sql).split("\n"):
        # EVERY tuple on the line, not the first and not only a line-leading one. The
        # rows ship one-per-line today, but `VALUES ('a', 'b', …), ('c', 'd', …);` is
        # the same INSERT and a line-anchored parser would report those rows MISSING —
        # a false DARK on a tree that really does seed them. Comment stripping, not the
        # match position, is what keeps prose out.
        for m in re.finditer(r"\(\s*'([^']*)'\s*,\s*'([^']*)'", l):
            pats.add((m.group(1), m.group(2)))
    return pats


# ── read the tree once ────────────────────────────────────────────────────────
ov_status, overlay = first_doc(OVERLAY)
ku_status, kust    = first_doc(KUST)
tok_status, tokens = load_docs(TOKENS)
sql = read(ROUTES)

ov_container = None
ov_env = []
if ov_status == "ok" and overlay is not None:
    cs = containers_of(overlay)
    if cs:
        ov_container = cs[0]
        ov_env = env_pairs(ov_container)

# The Secrets the RBAC side really mints, read from the manifest rather than assumed —
# rebrand_sysroot rewrites names in a built device tree, so nothing may be hardcoded.
minted_secrets = set()
for d in tokens:
    if isinstance(d, dict) and d.get("kind") == "Secret":
        n = dig(d, "metadata", "name")
        if n:
            minted_secrets.add(str(n))


def kust_deployment():
    """The Deployment this kustomization builds, found through its OWN `resources:`
    list. Never the hardcoded name: build-x86-host-stage4.sh's rebrand_sysroot rewrites
    hugmesh- to the tenant brand throughout a built device tree, so a literal would make
    this check fire on every rebranded image."""
    if ku_status != "ok" or not isinstance(kust, dict):
        return None
    for rel in as_list(kust.get("resources")):
        if not isinstance(rel, str):
            continue
        st, docs = load_docs(os.path.join(BFFDIR, rel))
        if st != "ok":
            continue
        for d in docs:
            if isinstance(d, dict) and d.get("kind") == "Deployment":
                return d
    return None


# ── the patch must actually TARGET that Deployment ────────────────────────────
# A strategic-merge patch is matched to its resource by apiVersion/kind/name/namespace,
# and a patch that matches nothing is not a no-op: measured with `kubectl kustomize`,
# the build FAILS ("no resource matches strategic merge patch … no matches for Id"), so
# ArgoCD cannot sync the admin-bff at all. Both build-time gates are then shut, and the
# old line scanner — which only ever looked at env-shaped lines — saw none of it.
target_why = []
if ov_status == "ok" and overlay is not None:
    dep = kust_deployment()
    if dep is None:
        target_why.append("the admin-bff kustomization builds no Deployment this overlay could patch, so the overlay is dead weight")
    else:
        want = (dig(dep, "metadata", "name"), dig(dep, "metadata", "namespace"), dep.get("kind"), dep.get("apiVersion"))
        got  = (dig(overlay, "metadata", "name"), dig(overlay, "metadata", "namespace"), overlay.get("kind"), overlay.get("apiVersion"))
        for label, g, w in (("kind", got[2], want[2]), ("apiVersion", got[3], want[3]),
                            ("metadata.name", got[0], want[0]), ("metadata.namespace", got[1], want[1])):
            if g != w:
                target_why.append("the overlay's %s is %r but the Deployment the kustomization builds is %r — the strategic-merge patch matches NO resource, so `kustomize build` fails and not one WORKLOAD_CONSOLE_* env is ever rendered" % (label, g, w))
        dep_names = [c.get("name") for c in containers_of(dep)]
        if ov_container is None:
            target_why.append("the overlay declares no container under spec.template.spec.containers, so it carries no env to merge")
        elif ov_container.get("name") not in dep_names:
            target_why.append("the overlay patches container %r but the Deployment's containers are %r — a strategic merge keyed on `name` would ADD a second container instead of setting the env on the app one" % (ov_container.get("name"), dep_names))

# A duplicate is a gate-level fact (last one wins), reported once per variable.
def dup_reason(name, count):
    return ("%s is declared %d times in the same container env list; the kubelet takes "
            "the LAST, so whatever an earlier entry says is dead text" % (name, count))


# ── GATE 1: the generator gate ────────────────────────────────────────────────
g1_why = list(target_why)
if ov_status == "absent":
    g1_why.append("the deployment overlay manifests/admin-bff-api/workload-console-patch.yaml is absent (pruned: slug deselected)")
elif ov_status != "ok":
    g1_why.append("manifests/admin-bff-api/workload-console-patch.yaml %s" % ov_status)
elif ov_container is None:
    g1_why.append("the overlay declares no container, so WORKLOAD_CONSOLE_ENABLED is never set")
else:
    v, n = env_effective(ov_env, "WORKLOAD_CONSOLE_ENABLED")
    if n > 1:
        g1_why.append(dup_reason("WORKLOAD_CONSOLE_ENABLED", n))
    if v != "true":
        g1_why.append("the overlay does not set WORKLOAD_CONSOLE_ENABLED=true (effective value %r)" % v)

if ku_status == "absent":
    g1_why.append("manifests/admin-bff-api/kustomization.yaml is absent")
elif ku_status != "ok":
    g1_why.append("manifests/admin-bff-api/kustomization.yaml %s" % ku_status)
else:
    applied = set()
    for p in as_list(kust.get("patches")):
        if isinstance(p, dict) and isinstance(p.get("path"), str):
            applied.add(os.path.normpath(p["path"]))
    if os.path.basename(OVERLAY) not in applied:
        g1_why.append("the admin-bff kustomization no longer applies the overlay (its `- path:` line was pruned), so the env is never rendered")

if sql is None:
    g1_why.append("manifests/route-access/initdb/20-schema.sql is unreadable")
else:
    have = route_rows(sql)
    for pat in ("/bff/admin/workloads/**", "/bff/superadmin/workloads/**"):
        if not any(p == pat for _, p in have):
            # NOT "so the gateway 404s it": an unmatched url_pattern is NO_RULE
            # and GatewayRouteAccessFilter FORWARDS (docs/ROUTE-ACCESS.md,
            # "'No matching row' is NOT a denial"). An unseeded row UNGOVERNS the
            # prefix; what refuses it is the BFF's own WorkloadAuthorizationFilter
            # under WORKLOAD_CONSOLE_ENABLED=false. Reported here because the rows
            # are part of what the slug owns, so their absence is evidence the slug
            # is deselected — not because their absence is itself a wall.
            g1_why.append("route-access row for %s is not seeded, so the prefix is "
                          "UNGOVERNED at the gateway (NO_RULE forwards); the refusal "
                          "is the BFF's WorkloadAuthorizationFilter on a disabled "
                          "prefix" % pat)

gate1 = "OPEN" if not g1_why else "SHUT"

# ── GATE 2: the k8s seam ──────────────────────────────────────────────────────
# Three SEPARATE facts per half, because they fail separately and an operator has to be
# told which one to fix: the env var that NAMES the token file, the volumeMount that
# DELIVERS it, and the pod `volumes:` entry (plus its Secret) the mount refers to.
g2_why = list(target_why)
if ov_status == "absent":
    g2_why.append("no overlay, so WORKLOAD_CONSOLE_K8S_ENABLED is unset and the fail-closed NoopWorkloadClient 503s every call")
elif ov_status != "ok":
    g2_why.append("manifests/admin-bff-api/workload-console-patch.yaml %s, so the k8s seam cannot be measured" % ov_status)
elif ov_container is None:
    g2_why.append("the overlay declares no container, so neither the k8s seam env nor the token mounts exist")
else:
    v, n = env_effective(ov_env, "WORKLOAD_CONSOLE_K8S_ENABLED")
    if n > 1:
        g2_why.append(dup_reason("WORKLOAD_CONSOLE_K8S_ENABLED", n))
    if v != "true":
        g2_why.append("the overlay does not set WORKLOAD_CONSOLE_K8S_ENABLED=true (effective value %r) — NoopWorkloadClient 503s every call" % v)

    for label, path in (("read", READ_TOKEN), ("mutate", MUTATE_TOKEN)):
        envname = TOKEN_FILE_ENV[label]
        ev, en = env_effective(ov_env, envname)
        if en > 1:
            g2_why.append(dup_reason(envname, en))
        if ev != path:
            g2_why.append("%s does not name the contract path %s (effective value %r), so the %s client looks for its token somewhere the admin-bff does not publish" % (envname, path, ev, label))

        m = mount_covering(ov_container, path)
        if m is None:
            mounted = [str(x.get("mountPath")) for x in as_list(ov_container.get("volumeMounts")) if isinstance(x, dict)]
            g2_why.append("NO volumeMount delivers %s — the container mounts %s — so the %s token file never exists and that half degrades to the 503 posture" % (path, mounted or "nothing", label))
            continue
        vol = volume_named(overlay, m.get("name"))
        if vol is None:
            g2_why.append("the %s token mount refers to volume %r but the pod spec declares no such volume, so the mount cannot be satisfied" % (label, m.get("name")))
            continue
        sname = dig(vol, "secret", "secretName")
        if not sname:
            g2_why.append("volume %r backing the %s token mount is not a secret volume (no secret.secretName), so it delivers no ServiceAccount token" % (m.get("name"), label))
        elif tok_status == "ok" and minted_secrets and str(sname) not in minted_secrets:
            g2_why.append("volume %r mounts Secret %r, which manifests/workload-console-rbac/token-secrets.yaml does not mint (it mints %s) — the volume is optional:true, so it mounts EMPTY and the %s half 503s silently" % (m.get("name"), str(sname), sorted(minted_secrets), label))

if read(RBACAPP) is None:
    g2_why.append("apps/14-workload-console-rbac.yaml is absent, so the two ServiceAccounts and their token Secrets are never created")
if tok_status == "absent":
    g2_why.append("manifests/workload-console-rbac/token-secrets.yaml is absent, so no token is ever minted (the volumes are optional:true and mount empty)")
elif tok_status != "ok":
    g2_why.append("manifests/workload-console-rbac/token-secrets.yaml %s" % tok_status)

gate2 = "OPEN" if not g2_why else "SHUT"

# ── GATE 3: the DB master flag (RUNTIME ONLY) ────────────────────────────────
if db_flag == "unknown":
    gate3, g3_why = "UNKNOWN", ["not measured — workload_console_config.admin_enabled lives in the admin-bff Postgres and defaults FALSE; pass --db-admin-enabled= after measuring it"]
elif db_flag == "true":
    gate3, g3_why = "OPEN", []
else:
    gate3, g3_why = "SHUT", ["workload_console_config.admin_enabled is false for this domain (the shipped default) — every workloads request is refused before any k8s call"]

# ── GATE 4: the per-admin TTL'd grant (RUNTIME ONLY) ─────────────────────────
if grants == "unknown":
    gate4, g4_why = "UNKNOWN", ["not measured — workload_console_grant leases live in the admin-bff Postgres and none exists by default; pass --active-grants= after measuring it"]
elif int(grants) > 0:
    gate4, g4_why = "OPEN", []
else:
    gate4, g4_why = "SHUT", ["no active, unexpired workload_console_grant row — the ~24h lease expiry sweep returns every admin to dark automatically"]

gates = [
    ("1", "generator-gate",  gate1, g1_why, "build-time (workloadConsole slug)"),
    ("2", "k8s-seam",        gate2, g2_why, "build-time (same slug)"),
    ("3", "db-master-flag",  gate3, g3_why, "runtime (SUPERADMIN + step-up)"),
    ("4", "admin-grant",     gate4, g4_why, "runtime (SUPERADMIN, TTL'd lease)"),
]

print("== workload console posture ==")
print("   cluster tree : %s%s" % (tree, "  (DEFAULT: this repo's LIT SOURCE, not a built device tree)" if default_tree else ""))
for num, name, state, why, owner in gates:
    print("   GATE %s  %-16s %-8s  %s" % (num, name, state, owner))
    for w in why:
        print("            - %s" % w)

not_open = [(num, name, why) for num, name, state, why, _ in gates if state != "OPEN"]
verdict = "LIT" if not not_open else "DARK"
print("WORKLOAD_CONSOLE_POSTURE=%s" % verdict)
if verdict == "DARK":
    # Name EVERY gate that is not open. Reporting only the first would tell an
    # operator who just opened one gate that they are one step away when they are
    # three, which is the failure mode this whole report exists to remove.
    print("DARK BECAUSE %d of 4 gates are not open: %s"
          % (len(not_open), "; ".join("gate-%s %s" % (n, nm) for n, nm, _ in not_open)))
    print("   stats and running-version data render for NOBODY until all four are open.")
else:
    print("   all four gates are open: /bff/admin/workloads/** should render for a granted admin.")
print("")
print("MEASURE GATES 3 AND 4 (admin-bff Postgres, read-only):")
print("   SELECT domain, admin_enabled, dangerous_tier_enabled FROM workload_console_config;")
print("   SELECT count(*) FROM workload_console_grant")
print("    WHERE state='active' AND expires_at > now() AND grantee='<admin>';")
sys.exit(0 if verdict == "LIT" else 10)
PY
)"
rc=$?
printf '%s\n' "${OUT}"
case "${rc}" in
  0)  [ -n "${REQUIRE_LIT}" ] && exit 0; exit 0 ;;
  10) [ -n "${REQUIRE_LIT}" ] && exit 3; exit 0 ;;
  *)  exit 1 ;;
esac
