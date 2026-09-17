#!/usr/bin/env bash
# test-superadmin-bff-reachability.sh — a browser must have a WORKING path to the
# /bff/superadmin/** surfaces the shipped admin-ui already calls, and only
# ROLE_SUPERADMIN may take it.
#
# THE BUG THIS EXISTS TO KILL (observed 2026-08-26)
# -------------------------------------------------
# There was NO browser path to ANY /bff/superadmin/** endpoint. The two halves of
# the routing contract had drifted in OPPOSITE directions, and each half read as
# correct when inspected on its own:
#
#   * hugmesh-fe-gateway ROUTED the family and did not GOVERN it.
#     apps/20-gateway-fe.yaml ends with `path: /bff/**` -> hugmesh-admin-bff-api
#     (the compose lane, tests/stack/gateway-routes/fe/application-routes.yml,
#     ends the same way), so /bff/superadmin/anything IS forwarded to admin-bff —
#     the correct upstream, since every superadmin surface is an admin-bff
#     controller. But 20-schema.sql carried no fe-gateway /bff/superadmin row, and
#     a routed path with zero matching allow rows is DEFAULT-DENY.
#
#   * hugmesh-be-gateway GOVERNED the family and did not ROUTE it.
#     20-schema.sql carried '/bff/superadmin/**' -> ROLE_SUPERADMIN (plus
#     /bff/superadmin/games-services/**, /bff/superadmin/workloads/**,
#     /bff/image-builds/**) on the be-gateway, while apps/20-gateway-be.yaml
#     contains no `path: /bff…` predicate AT ALL. Those rows govern traffic that
#     never arrives.
#
# Net effect: the already-shipped admin-ui superadmin pages — backing-services,
# fleet-entitlements, phone-devices, the desktop dials and the superadmin half of
# the workload console — were dead ends, and the be-gateway rows made the surface
# LOOK granted to anyone auditing the table alone. A grep for "is there a
# ROLE_SUPERADMIN row for /bff/superadmin/**" answers YES and is useless: the
# question that matters is which GATEWAY carries it and whether that gateway
# routes the path.
#
# WHAT IS ASSERTED (outcomes, not the presence of a literal line)
# ---------------------------------------------------------------
# Both halves are simulated from the real files and the two are JOINED:
#
#   1. ROUTED   — Spring Cloud Gateway first-match-wins over the ordered route
#                 table: each probe path matches a route, that route is not the
#                 SPA `/**` catch-all, and its uri is the admin-bff.
#   2. GOVERNED — the route-access decision model (longest matching url_pattern
#                 wins; deny-wins at that length; anything unmatched is
#                 default-deny) admits ROLE_SUPERADMIN.
#   3. DECIDING PATTERN — the row that decides is '/bff/superadmin/**' (or a
#                 longer fe row), never a broader one, never "no rule". This is
#                 the "not swallowed by an earlier broader row" check.
#   4. NO DOWN-CASCADE — ROLE_ADMIN / ROLE_FLEET_ADMIN / ROLE_USER / anonymous are
#                 DENIED every probe. ROLE_SUPERADMIN is a separate tier, not a
#                 role admin inherits.
#   5. ORPHAN LEDGER — every '/bff…' row on a gateway that routes no '/bff' path
#                 must be named in DOCUMENTED_ORPHANS with a reason, and every
#                 ledger entry must still BE an orphan. The be-gateway set is
#                 deliberately RETAINED (it grants nothing without a route, and
#                 optional-services.yaml keys on those exact tuples) — the ledger
#                 is what stops a NEW un-routed row from quietly reading as a
#                 grant, which is how this defect was born.
#   6. CROSS-MODEL (§12) — the specificity model used above is a transcription of
#                 the repo oracle, tests/e2e/specs/rbac-route-access.ts
#                 patternMatch(). node IMPORTS that function out of the .ts and it
#                 is asked to score every (pattern, path) pair the seed generates;
#                 both models must pick the same winning row. A source pin runs
#                 even where node cannot.
#   7. SLUG LIFETIME (§13) — a superadmin surface owned by an OPTIONAL slug must
#                 not stay reachable at the fe door after that slug is deselected.
#                 Measured by EXECUTING both real builders' gate_optional_services
#                 case bodies against a sandbox copy of the seed; every survivor
#                 must be in DESELECT_SURVIVORS naming the wall that is left.
#
# WHAT THIS DELIBERATELY DOES *NOT* ASSERT
# ----------------------------------------
# '/bff/superadmin/games-services/**' is asserted DENIED at the fe front door, not
# reachable. An earlier cut of this file listed it in PROBES and asserted it
# reachable unconditionally, which made a test out of an exposure nobody asked for:
# the app-store control plane rides the OPTIONAL `games` slug, so the floor would
# have outlived its slug. 20-schema.sql now carries an unconditional DENY at the
# longer pattern and §5b + §13 pin it.
#
# WHAT THIS CANNOT PROVE — read before quoting a green run
# ---------------------------------------------------------
# NO GATEWAY IS EXECUTED HERE. `default-deny` is the documented contract of
# GatewayRouteAccessFilter (20-schema.sql header + the hugmesh-gateway repo), and
# this suite encodes that contract; it does not observe it. A green run proves the
# DATA now says "ROLE_SUPERADMIN may reach /bff/superadmin/** at the front door
# and nobody else may", and that the fe route table forwards those paths to
# admin-bff. It does NOT prove a live gateway loads the row, that admin-bff
# answers, or that the browser session carries the role. The live half is
# tests/e2e/specs/14-rbac-gateway-live.spec.ts (LIVE_GATEWAY=1), which needs a
# stack this suite deliberately does not require.
#
# Offline: reads files, runs sed/awk-only builder case bodies against a temp copy of
# the seed, and (when node exists) imports one pure function from a .ts. No cluster,
# no docker, no network, no root, no image build.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "  FAIL python3 not available"; exit 1; }
python3 -c 'import yaml' 2>/dev/null || {
  echo "  FAIL PyYAML not available (pip install pyyaml) — this suite parses the"
  echo "       gateway route tables and MUST NOT read as a pass without them"
  exit 1
}

# ── §13 input: run the REAL builders' optional-service gate, offline ─────────
# Nothing about the prune is restated here. The slug list, `_opt_selected`, every
# `_opt_*` helper and each `<slug>)` case body are EXTRACTED FROM THE BUILDER and
# executed against a sandbox copy of 20-schema.sql — the same technique
# tests/workload-console/test-workload-console.sh uses, and the reason it exists:
# a grep that the builder still MENTIONS a path stays green through any change to
# the prune itself. Only the schema is seeded (the cases also rm apps/manifests
# that are absent here; those calls are no-ops and their stderr is discarded).
#
# Offline and rootless: sed/awk on a temp copy. No image is built, nothing is
# installed, no network. If a builder or slug cannot be gated the python half
# reports it as a FAIL, never as an absence.
GATEDIR="$(mktemp -d "${TMPDIR:-/tmp}/superadmin-gate.XXXXXX")"
trap 'rm -rf "${GATEDIR}"' EXIT

# ⚠ 2026-09-16, landing this branch on a main that had moved 540 commits: every
# extractor below used to awk the BUILDER FILE for `^gate_optional_services() {`.
# That was true on 2026-08-26 and is false now — main moved the whole gate into
# the shared scripts/_optional-services-lib.sh that both builders `source`, so
# awk-ing the builder found NOTHING and §13 reported, verbatim,
#   "the gate sandbox is EMPTY — no builder's gate_optional_services was executed"
#   "no slug's gate removed a single route-access row"
#   "DESELECT_SURVIVORS names case(s) that no longer survive"
# i.e. three FAILs with one cause. Main had already met and solved this in
# tests/stack/test-optional-services-exclude.sh, so this now uses that same
# resolver, tests/lib/opt-gate-source.sh, which reproduces BASH'S OWN order
# (sourced libs first, builder last, last definition wins). A builder that
# re-grows a LOCAL copy is therefore still what gets executed here.
# shellcheck source=tests/lib/opt-gate-source.sh
. "${ROOT}/tests/lib/opt-gate-source.sh"

_g_extract_fn() {   # $1=builder $2=fn — as THAT builder resolves it
  opt_gate_extract_fn "$1" "$2"; printf '\n'
}
_g_extract_all_opt_fns() {  # every _opt_* helper, as that builder resolves it
  local _f
  # Names are discovered from the whole resolution chain, then each is extracted
  # through the resolver, so a builder-local override wins over the lib copy.
  for _f in $(opt_gate_sources "$1" | xargs -r grep -hoE '^[[:space:]]*(function[[:space:]]+)?_opt_[a-z_]+[[:space:]]*\(\)' \
                | grep -oE '_opt_[a-z_]+' | sort -u); do
    opt_gate_extract_fn "$1" "${_f}"; printf '\n'
  done
}
_g_extract_case() { # $1=builder $2=case label — body between `<label>)` and `;;`
  opt_gate_extract_fn "$1" gate_optional_services | awk -v lbl="$2" '
    $0 ~ ("^[[:space:]]*" lbl "\\)[[:space:]]*$") { p=1; next }
    p && $0 ~ /^[[:space:]]*;;[[:space:]]*$/ { exit }
    p { print }'
}
# The slug list the REAL gate loops over, read out of gate_optional_services()
# itself rather than restated — a slug added there is gated here automatically.
_g_slugs() {        # $1=builder
  opt_gate_extract_fn "$1" gate_optional_services \
    | sed -n 's/^[[:space:]]*for slug in \(.*\); do$/\1/p' | head -n 1
}

for _g_b in "${ROOT}/build-rpi5-stage4.sh" "${ROOT}/build-x86-host-stage4.sh"; do
  [ -f "${_g_b}" ] || continue
  _g_bn="$(basename "${_g_b}")"
  _g_list="$(_g_slugs "${_g_b}")"
  [ -n "${_g_list}" ] || continue
  printf '%s\n' "${_g_list}" > "${GATEDIR}/${_g_bn}.slugs"
  for _g_slug in ${_g_list}; do
    _g_out="${GATEDIR}/${_g_bn}/${_g_slug}"
    mkdir -p "${_g_out}/manifests/route-access/initdb" "${_g_out}/apps"
    cp "${ROOT}/specs/cluster/manifests/route-access/initdb/20-schema.sql" \
       "${_g_out}/manifests/route-access/initdb/20-schema.sql"
    (
      set +e +u +o pipefail          # the case bodies touch files absent from the sandbox
      OPTIONAL_SERVICES=""           # deselect EVERYTHING, then gate this one slug
      tree="${_g_out}"; apps="${_g_out}/apps"
      info() { :; }; warn() { :; }; die() { :; }
      eval "$(_g_extract_fn "${_g_b}" _opt_selected)"
      eval "$(_g_extract_all_opt_fns "${_g_b}")"
      _g_body="$(_g_extract_case "${_g_b}" "${_g_slug}")"
      [ -n "${_g_body}" ] || exit 0
      eval "${_g_body}"
    ) >/dev/null 2>&1
  done
done

python3 - "$ROOT" "$GATEDIR" <<'PY'
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

import yaml

root = sys.argv[1]
GATEDIR = sys.argv[2] if len(sys.argv) > 2 else ""
TS_ORACLE = f"{root}/tests/e2e/specs/rbac-route-access.ts"

SCHEMA     = f"{root}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
CLUSTER_FE = f"{root}/specs/cluster/apps/20-gateway-fe.yaml"
CLUSTER_BE = f"{root}/specs/cluster/apps/20-gateway-be.yaml"
CLUSTER_SA = f"{root}/specs/cluster/apps/22-gateway-superadmin.yaml"
COMPOSE_FE = f"{root}/tests/stack/gateway-routes/fe/application-routes.yml"
# The shipped admin-ui remote, as vendored into the compose lane's static dist.
# OPTIONAL input: used to cross-check the hard-coded probe list against what the
# UI actually calls. Absent => a LOUD skip, never a silent pass.
ADMIN_UI_DIST = f"{root}/tests/stack/.uidist/_remotes/admin"

FE = "hugmesh-fe-gateway"
BE = "hugmesh-be-gateway"
SA = "hugmesh-superadmin-gateway"

passed = failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  PASS {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"  FAIL {msg}")


def skip(msg):
    # LOUD skip: a named reason on stdout. Never used for anything this suite
    # can decide on its own — only for the optional admin-ui bundle cross-check.
    print(f"  SKIP {msg}")


# ─────────────────────────────────────────────────────────────── SQL parsing ──
# COMMENTS ARE STRIPPED BEFORE ANY ROW IS MATCHED, and that is not tidiness.
# 20-schema.sql documents its rows in long `--` prose that QUOTES row tuples
# verbatim — the note above the fe superadmin row literally spells out
# ('hugmesh-fe-gateway','/bff/superadmin/workloads/**','ROLE_SUPERADMIN',false)
# as the deny row an operator could add. A parser that reads raw text would load
# that suggestion AS A ROW and conclude the workload tier is denied. Four checks
# in this repo have been inverted by prose naming the token they grep for; this is
# the fifth candidate, pre-empted.
#
# The stripper is a character scanner, not a regex: `--` inside a single-quoted
# literal is data, not a comment. (No current row contains one, but a url_pattern
# legitimately could.)
def strip_sql_comments(text):
    out = []
    i, n = 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "'":
                if i + 1 < n and text[i + 1] == "'":   # '' escape
                    out.append(text[i + 1])
                    i += 2
                    continue
                in_str = False
            i += 1
            continue
        if c == "'":
            in_str = True
            out.append(c)
            i += 1
            continue
        if c == "-" and i + 1 < n and text[i + 1] == "-":
            j = text.find("\n", i)
            i = n if j < 0 else j                      # keep the newline
            continue
        out.append(c)
        i += 1
    return "".join(out)


ROW_RE = re.compile(
    r"\(\s*'(?P<gw>[^']+)'\s*,\s*'(?P<pat>[^']+)'\s*,\s*'(?P<role>[^']+)'\s*,"
    r"\s*(?P<allow>true|false)\s*\)")

raw_sql = open(SCHEMA, encoding="utf-8").read()
sql = strip_sql_comments(raw_sql)

# Sanity floor: the stripper must not have eaten the seed, and must have removed
# something. Both directions, because a no-op stripper and a too-greedy one fail
# in opposite, equally silent ways.
ROWS = [(m.group("gw"), m.group("pat"), m.group("role"), m.group("allow") == "true")
        for m in ROW_RE.finditer(sql)]
RAW_ROWS = [(m.group("gw"), m.group("pat"), m.group("role"), m.group("allow") == "true")
            for m in ROW_RE.finditer(raw_sql)]

print("== the seed parses, and comments are stripped before it does ==")
if len(ROWS) < 100:
    bad(f"only {len(ROWS)} route-access rows parsed out of the seed — the parser or "
        f"the file shape changed; every verdict below would be vacuous")
    print()
    print(f"== RESULT: {passed} passed, {failed} failed ==")
    sys.exit(1)
ok(f"parsed {len(ROWS)} route-access rows from the comment-stripped seed")

if len(sql) >= len(raw_sql):
    bad("strip_sql_comments() removed NOTHING from a file that is ~60% `--` prose "
        "— it is a no-op and the anti-prose guarantee is fiction")
else:
    ok(f"comment stripper removed {len(raw_sql) - len(sql)} bytes of `--` prose "
       f"before any row was matched")

# The specific inversion this suite is exposed to: the fe superadmin note quotes
# a DENY tuple as an operator suggestion. Prove the stripper drops it.
prose_deny = (FE, "/bff/superadmin/workloads/**", "ROLE_SUPERADMIN", False)
if prose_deny in RAW_ROWS and prose_deny not in ROWS:
    ok("the DENY tuple quoted inside a `--` comment is visible in the raw text and "
       "ABSENT from the parsed rows — prose cannot forge a row")
elif prose_deny in ROWS:
    bad(f"a row tuple that exists only inside a comment was parsed as real: "
        f"{prose_deny}")
else:
    # The comment was reworded; the stripper is still proven by the byte count
    # above, but say so rather than claiming a check that did not run.
    skip("the comment-embedded DENY tuple is no longer present in 20-schema.sql — "
         "the prose-forgery control could not be exercised (byte-count control "
         "above still applies)")

BY_GW_PAT = {}
for gw, pat, role, allow in ROWS:
    BY_GW_PAT.setdefault((gw, pat), []).append((role, allow))


# ────────────────────────────────────────────────── the route-access decision ──
def ant_to_re(pattern):
    """Spring's Ant path matching: `**` crosses `/`, `*` does not."""
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def pattern_matches(pattern, path):
    if pattern.endswith("/**"):
        prefix = pattern[:-3]
        # `/admin/**` must match `/admin` and `/admin/x` but NOT `/administrator`.
        return path == prefix or path.startswith(prefix + "/")
    return ant_to_re(pattern).match(path) is not None


def specificity(pattern):
    """The gateway's own ranking key: the RAW LENGTH of url_pattern.

    ⚠ CORRECTED 2026-09-16, landing `integrate/superadmin` (#351). This function
    used to score `prefix.length * 2` for a glob and `pattern.length * 2 + 1` for an
    exact literal, transcribed from a `patternMatch()` that `tests/e2e/specs/
    rbac-route-access.ts` exported on 2026-08-26. Main has since replaced that whole
    hand-maintained oracle with a GENERATED seed plus `antMatch()`, and ranks by raw
    `urlPattern.length` — and THAT is the model the real gateway implements:

        hugmesh-gateway  src/main/java/net/hugmesh/gateway/cache/
                         GatewayRouteAccessService.java:182
            int len = r.urlPattern().length();

    (read at hugmesh-gateway main @ 13f1651). The two models are NOT equivalent.
    They agree glob-vs-glob, and they INVERT exact-vs-glob, which is live in this
    seed today:

        '/api/federation/vanity'      len 22   old score 45
        '/api/federation/vanity/**'   len 25   old score 44

    The gateway picks the GLOB (25 > 22); the old model picked the EXACT row. Both
    rows are PUBLIC so no shipped decision flipped, which is exactly why the branch
    could carry a wrong oracle for three weeks without a red test. §12 below now
    pins this against the TS oracle rather than against the retired one, and
    `old_specificity` is kept as the negative control that the two really differ.

    Kept deliberately NOT delegated to the TS: this suite must still reach a verdict
    on a box with no node (§12 degrades to a source-text pin there), and a Python
    model is what §5/§13's mutation battery mutates."""
    return len(pattern)


def decide(rows_by_gw_pat, gateway, path, roles):
    """(decision, deciding_pattern, roles_at_that_pattern).

    Model, transcribed from 20-schema.sql's header ("the most specific matching
    url_pattern wins") and test-mfa-required-rules.sh defect (b) ("decide() picks
    the LONGEST matching url_pattern and evaluates ONLY the rows at that length"):

      * pick the single most-specific matching url_pattern for THIS gateway;
      * nothing matched            -> DENY (default-deny);
      * any allow=false row there  -> DENY (deny-wins at the longest match);
      * a PUBLIC row there         -> ALLOW without a role;
      * otherwise ALLOW iff the caller holds one of that pattern's roles.
    """
    best, best_pat = -1, None
    for (gw, pat) in rows_by_gw_pat:
        if gw != gateway or not pattern_matches(pat, path):
            continue
        s = specificity(pat)
        if s > best:
            best, best_pat = s, pat
    if best_pat is None:
        return ("DENY", None, [])
    at = rows_by_gw_pat[(gateway, best_pat)]
    if any(not allow for _, allow in at):
        return ("DENY", best_pat, [r for r, _ in at])
    if any(r == "PUBLIC" for r, _ in at):
        return ("ALLOW", best_pat, [r for r, _ in at])
    granted = any(r in roles for r, _ in at)
    return ("ALLOW" if granted else "DENY", best_pat, [r for r, _ in at])


# ─────────────────────────────────────────────────────────── route  tables ──
def load_cluster_routes(path):
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    values = yaml.safe_load(doc["spec"]["source"]["helm"]["values"])
    out = []
    for r in values.get("routes", []) or []:
        out.append({"id": r["id"], "uri": r["uri"],
                    "paths": str(r["path"]).split(",") if r.get("path") else [],
                    "host": r.get("host")})
    return out


def load_compose_routes(path):
    doc = yaml.safe_load(open(path, encoding="utf-8"))
    raw = doc["spring"]["cloud"]["gateway"]["server"]["webflux"]["routes"]
    out = []
    for r in raw:
        entry = {"id": r["id"], "uri": r["uri"], "paths": [], "host": None}
        for p in r.get("predicates", []):
            if p.startswith("Path="):
                entry["paths"] = p[len("Path="):].split(",")
            elif p.startswith("Host="):
                entry["host"] = p[len("Host="):]
        out.append(entry)
    return out


def host_matches(pattern, host):
    return ant_to_re(pattern.strip().replace(".", "\x00")
                     ).match(host.replace(".", "\x00")) is not None


def first_match(routes, path, host):
    """SCG semantics: first route in DECLARED ORDER whose predicates all hold.
    Route tables ARE order-sensitive (unlike the route-access rows above) — this
    is where a broader entry declared earlier really does swallow a narrower one."""
    for r in routes:
        if r["host"] and not host_matches(r["host"], host):
            continue
        if r["paths"] and not any(ant_to_re(p.strip()).match(path)
                                  for p in r["paths"] if p.strip()):
            continue
        return r
    return None


CLUSTER_FE_ROUTES = load_cluster_routes(CLUSTER_FE)
CLUSTER_BE_ROUTES = load_cluster_routes(CLUSTER_BE)
CLUSTER_SA_ROUTES = load_cluster_routes(CLUSTER_SA)
COMPOSE_FE_ROUTES = load_compose_routes(COMPOSE_FE)

ROUTE_TABLES = {
    "cluster-fe": (FE, CLUSTER_FE_ROUTES),
    "compose-fe": (FE, COMPOSE_FE_ROUTES),
    "cluster-be": (BE, CLUSTER_BE_ROUTES),
    "cluster-superadmin": (SA, CLUSTER_SA_ROUTES),
}

# Probe paths: the /bff/superadmin/** endpoints the SHIPPED admin-ui calls. Taken
# from tests/stack/.uidist/_remotes/admin (the vendored remote), and cross-checked
# against that bundle below so the list cannot rot as pages are added.
PROBES = [
    ("/bff/superadmin/backing-services",            "backing-services page"),
    ("/bff/superadmin/backing-services/postgres",   "backing-services detail"),
    ("/bff/superadmin/fleet-entitlements",          "fleet-entitlements page"),
    ("/bff/superadmin/phone-devices",               "phone-devices page"),
    ("/bff/superadmin/phone-devices/abc/owner",     "phone-device owner assignment"),
    ("/bff/superadmin/desktop/dials",               "desktop dials page"),
    ("/bff/superadmin/cloud-backups/total",         "cloud-backups tile"),
    ("/bff/superadmin/workloads/pods",              "workload console (superadmin half)"),
    ("/bff/superadmin/workloads/exec-tty/pod-1",    "workload console dangerous tier"),
]

# Superadmin-prefixed paths that must be DENIED at the fe front door even for
# ROLE_SUPERADMIN. 2026-08-26: '/bff/superadmin/games-services/**' used to sit in
# PROBES above and was asserted reachable UNCONDITIONALLY — which quietly made a
# test out of an exposure nobody asked for. The games app-store control plane
# rides the OPTIONAL `games` slug, its endpoints live in the ALWAYS-PRESENT
# admin-bff, and gate_optional_services can only REMOVE rows — so the
# '/bff/superadmin/**' floor would have outlived its slug on a games-deselected
# build and admitted a superadmin to app-store curation at the PUBLIC door, where
# before the floor existed there was no fe row for that family at all. No shipped
# admin-ui path calls it (§11 extracts the bundle's paths and lists none), so
# 20-schema.sql now carries an unconditional DENY at the longer pattern, and this
# is the assertion that it works.
DENY_PROBES = [
    ("/bff/superadmin/games-services",              "games app-store control plane (root)"),
    ("/bff/superadmin/games-services/catalog",      "games app-store catalog curation"),
    ("/bff/superadmin/games-services/offers/dom-1", "games app-store per-domain offers"),
]
SHELL_HINT = ("host-shell", "systems-web")

# ── §1 ROUTED ────────────────────────────────────────────────────────────────
print()
print("== §1 the fe route tables forward /bff/superadmin/** to the admin-bff ==")
for label in ("cluster-fe", "compose-fe"):
    _, routes = ROUTE_TABLES[label]
    for path, why in PROBES:
        r = first_match(routes, path, "hugmesh.net")
        if r is None:
            bad(f"[{label}] {path} ({why}) matches NO route — nothing forwards it")
        elif any(h in r["uri"] for h in SHELL_HINT) or r["paths"] == ["/**"]:
            bad(f"[{label}] {path} ({why}) is answered by the SPA shell "
                f"(route '{r['id']}' -> {r['uri']}) — 200 text/html where JSON is due")
        elif "admin-bff" not in r["uri"]:
            bad(f"[{label}] {path} ({why}) resolves to '{r['id']}' -> {r['uri']}, "
                f"which is not the admin-bff")
        else:
            ok(f"[{label}] {path} -> '{r['id']}' ({why})")

# ── §2/§3/§4 GOVERNED, by the right row, not swallowed ───────────────────────
print()
print("== §2 ROLE_SUPERADMIN is ADMITTED at the fe front door ==")
for path, why in PROBES:
    d, pat, at = decide(BY_GW_PAT, FE, path, {"ROLE_SUPERADMIN"})
    if d != "ALLOW":
        bad(f"{path} ({why}) is {d} for ROLE_SUPERADMIN on {FE} — deciding row "
            f"{pat!r} carries {sorted(at)}; the page is a DEAD END")
    else:
        ok(f"{path} -> ALLOW for ROLE_SUPERADMIN via {pat!r}")

print()
print("== §3 the DECIDING row is the superadmin floor, not a broader one ==")
for path, why in PROBES:
    _, pat, _ = decide(BY_GW_PAT, FE, path, {"ROLE_SUPERADMIN"})
    if pat is None:
        bad(f"{path} matches NO fe row at all — governed by nothing, default-deny")
    elif not pat.startswith("/bff/superadmin"):
        bad(f"{path} is decided by {pat!r} — a row OUTSIDE the superadmin family "
            f"is swallowing the superadmin surface")
    else:
        ok(f"{path} decided by {pat!r}")

print()
print("== §4 precedence: the deciding row out-ranks every other fe row that matches ==")
for path, why in PROBES:
    _, win, _ = decide(BY_GW_PAT, FE, path, {"ROLE_SUPERADMIN"})
    if win is None:
        bad(f"{path}: no matching fe row, so precedence cannot be checked")
        continue
    others = sorted({p for (g, p) in BY_GW_PAT
                     if g == FE and p != win and pattern_matches(p, path)},
                    key=specificity, reverse=True)
    runner = others[0] if others else None
    if runner is not None and specificity(runner) >= specificity(win):
        bad(f"{path}: {runner!r} ties or beats the deciding row {win!r} "
            f"({specificity(runner)} >= {specificity(win)}) — the winner is ambiguous")
        continue
    # A THIRD, cruder reading of the same contract: raw pattern length. This is NOT
    # the repo oracle and is not claimed to be — §12 is where patternMatch() is
    # actually executed and compared. What this adds is a cheap independent signal:
    # where the scored model and "the longer string wins" disagree, the outcome is
    # model-dependent and must not read as a pass. (Corrected 2026-08-26: the first
    # cut of this suite described this branch as the oracle cross-check, which it
    # never was — it never reads the TS file.)
    if runner is not None and len(runner) > len(win):
        bad(f"{path}: specificity() picks {win!r} but raw pattern length picks "
            f"{runner!r} — two readings of 'most specific wins' disagree, so the "
            f"outcome is not decidable here. (Since 2026-09-16 specificity() IS raw "
            f"length, so this can only fire if someone changes it back; see §12.)")
        continue
    ok(f"{path}: {win!r} wins; runner-up {runner!r}" if runner
       else f"{path}: {win!r} is the ONLY matching fe row")

# ── §5 NO DOWN-CASCADE ───────────────────────────────────────────────────────
print()
print("== §5 no down-cascade: only ROLE_SUPERADMIN gets in ==")
DENIED_TIERS = {
    "ROLE_ADMIN":        frozenset({"ROLE_ADMIN"}),
    "ROLE_FLEET_ADMIN":  frozenset({"ROLE_FLEET_ADMIN"}),
    "ROLE_MOD":          frozenset({"ROLE_MOD"}),
    "ROLE_USER":         frozenset({"ROLE_USER"}),
    "anonymous":         frozenset(),
}
for tier, roles in DENIED_TIERS.items():
    leaked = []
    for path, _ in PROBES:
        d, pat, at = decide(BY_GW_PAT, FE, path, roles)
        if d != "DENY":
            leaked.append(f"{path} (via {pat!r} {sorted(at)})")
    if leaked:
        bad(f"{tier} reaches superadmin surface(s) at the front door: "
            + "; ".join(leaked))
    else:
        ok(f"{tier} is DENIED every /bff/superadmin probe on {FE}")

# The §13 deselect-survivor ledger, DEFINED HERE because §5b consults it too
# (it was below §13 until 2026-09-16, which made §5b a NameError the moment it
# started asking which posture is in force). §13 is still what enforces
# staleness and the "names the wall" minimum.
DESELECT_SURVIVORS = {
    ("workloadConsole", "/bff/superadmin/workloads/**"):
        "DELIBERATE, disclosed in 20-schema.sql beside the floor and in "
        "docs/OPTIONAL-SERVICES.md §7.2. The shipped admin-ui calls six "
        "/bff/superadmin/workloads/* paths from the PUBLIC /admin/workloads mount, "
        "so denying it at the fe door darks a shipped page — an operator posture "
        "decision, not a defect. Walls left on a deselected build: the admin-bff "
        "WorkloadAuthorizationFilter denies a disabled prefix (a direct in-cluster "
        "call 404s too), the k8s seam is the fail-closed NoopWorkloadClient, the DB "
        "master flags default false, and the row is ROLE_SUPERADMIN + mfa_required.",
    ("workloadConsole", "/bff/admin/workloads/**"):
        "PRE-EXISTING and unrelated to the superadmin floor: the fe "
        "'/bff/admin/**' -> ROLE_ADMIN floor has matched this prefix since long "
        "before 2026-08-26, so the ADMIN read-only half of the console has always "
        "survived deselection at the front door. Same BFF-side walls as the row "
        "above. Recorded here because docs/OPTIONAL-SERVICES.md used to claim the "
        "gateway 404s the whole prefix, and it never did.",
    ("games", "/bff/superadmin/games-services/**"):
        "OPERATOR POSTURE, recorded 2026-09-16 (#351) rather than asserted away. "
        "`integrate/superadmin` seeded an explicit fe DENY row at this pattern so "
        "the app-store control plane would be tailnet-only. The row is left out "
        "because operator decision 8 (#244 ACCEPT) is SPECIFIC to it — answered "
        "\"without the games-services deny row\" — even though it is the EARLIER "
        "answer (2026-09-10) and decision 20 (\"land the whole branch\", "
        "2026-09-16) is the LATER, GENERAL one. Recency and specificity point "
        "opposite ways here, so this is a merge-time reading parked for the "
        "operator as decision 28, not a ruling. Walls left on a games-deselected "
        "build: the "
        "admin-bff's own hasRole(\"SUPERADMIN\") on every games-services handler; "
        "the gateway filter short-circuits ROLE_ADMIN/ROLE_SUPERADMIN BEFORE "
        "decide() runs, so the row could not have changed what a privileged "
        "principal reaches either way; a NON-privileged caller is already "
        "governed-but-ungranted DENY under the /bff/superadmin/** floor; and the "
        "games workloads themselves are pruned, so the curation endpoints have "
        "nothing to curate. The cost of the row, measured on this merge, is that as "
        "the LONGEST matching pattern with allow=false it is skipped by the "
        "`WHERE allow = true` flip and strips the MFA step-up floor from this "
        "subtree (test-mfa-required-rules.sh: 124 passed/1 failed with the row, "
        "125 passed/0 failed without — re-measured on the land pass; an earlier "
        "note here said 125/1). "
        "Reinstating it is an operator call parked on #351, not a merge call.",
}

# ── §5b the optional-slug surfaces the floor must not carry UNEXAMINED ───────
print()
print("== §5b the games app-store control plane: walled, or ledgered with its walls ==")
DENY_ROW_KEY = (FE, "/bff/superadmin/games-services/**")
_deny_seeded = DENY_ROW_KEY in BY_GW_PAT
# TWO LEGAL SHAPES, and the ledger decides which one is in force. Either the
# explicit fe DENY row walls this family at the public door (what
# `integrate/superadmin` proposed), or the family is a RECORDED deselect survivor
# governed by the /bff/superadmin/** floor with the remaining walls named (what
# operator decision 8 chose — see DESELECT_SURVIVORS below). What is NOT legal is
# neither: an open optional-slug control plane at the public door with nobody
# having written down why.
if _deny_seeded:
    for path, why in DENY_PROBES:
        d, pat, at = decide(BY_GW_PAT, FE, path, {"ROLE_SUPERADMIN"})
        if d != "DENY":
            bad(f"{path} ({why}) is {d} for ROLE_SUPERADMIN on {FE} via {pat!r} "
                f"{sorted(at)} — the deny row is seeded but is NOT the winning "
                f"pattern for this path")
        elif pat != "/bff/superadmin/games-services/**":
            bad(f"{path} ({why}) is DENIED, but by {pat!r} rather than the explicit "
                f"deny row — the wall is incidental and would vanish with that row")
        else:
            ok(f"{path} -> DENY via the explicit deny row {pat!r} ({why})")
    _no_deny = [r for r in ROWS if r[:2] != (FE, "/bff/superadmin/games-services/**")]
    _m = {}
    for _gw, _pat, _role, _allow in _no_deny:
        _m.setdefault((_gw, _pat), []).append((_role, _allow))
    _would = [p for p, _ in DENY_PROBES if decide(_m, FE, p, {"ROLE_SUPERADMIN"})[0] == "ALLOW"]
    if len(_would) == len(DENY_PROBES):
        ok(f"and the deny is load-bearing: remove that one row and all "
           f"{len(_would)} probe(s) go back to ALLOW via the floor")
    else:
        bad(f"removing the deny row leaves only {len(_would)}/{len(DENY_PROBES)} "
            f"probe(s) ALLOWed — §5b is partly vacuous")
elif ("games", "/bff/superadmin/games-services/**") in DESELECT_SURVIVORS:
    # The ledgered posture. Assert the SHAPE it claims, so the entry cannot be a
    # blanket amnesty: the family must be reachable for ROLE_SUPERADMIN ONLY, and
    # only via the floor — anything else means the entry describes a world that
    # stopped existing.
    _bad = []
    for path, why in DENY_PROBES:
        d, pat, at = decide(BY_GW_PAT, FE, path, {"ROLE_SUPERADMIN"})
        if d != "ALLOW" or pat != "/bff/superadmin/**":
            _bad.append(f"{path}: {d} via {pat!r}")
    _leak = [f"{path} as {tier}"
             for path, _ in DENY_PROBES
             for tier in ("ROLE_ADMIN", "ROLE_USER")
             if decide(BY_GW_PAT, FE, path, {tier})[0] != "DENY"]
    if _bad:
        bad("the ledgered games posture does not hold: " + "; ".join(_bad[:4])
            + " — DESELECT_SURVIVORS says this family is governed by the "
              "/bff/superadmin/** floor, so if it is not, the entry is stale")
    elif _leak:
        bad("the games app-store control plane admits a NON-superadmin tier at the "
            "public door: " + "; ".join(_leak[:4]) + " — the ledger entry's stated "
            "wall (governed-but-ungranted for everyone else) is not holding")
    else:
        ok(f"games app-store control plane: all {len(DENY_PROBES)} probe(s) are "
           f"ALLOW for ROLE_SUPERADMIN via the '/bff/superadmin/**' floor and DENY "
           f"for every other tier — the DESELECT_SURVIVORS posture recorded for "
           f"decision 8, not an unexamined hole")
else:
    bad("the games app-store control plane is neither walled by an explicit fe DENY "
        "row NOR recorded in DESELECT_SURVIVORS — an optional slug's control plane "
        "is open at the PUBLIC door with no written posture. Add the row, or add "
        "the ledger entry naming the walls that are left.")

# ── §6 the row itself, exactly once ──────────────────────────────────────────
print()
print("== §6 the canonical seed carries the fe superadmin floor exactly once ==")
NEW_ROW = (FE, "/bff/superadmin/**", "ROLE_SUPERADMIN", True)
n = ROWS.count(NEW_ROW)
if n == 1:
    ok(f"{NEW_ROW} present exactly once")
elif n == 0:
    bad(f"{NEW_ROW} is MISSING from the canonical seed")
else:
    bad(f"{NEW_ROW} appears {n} times — uq_route_access_row would collapse the "
        f"duplicates on ON CONFLICT DO NOTHING, but the seed is lying about intent")

# ── §7 the three doors agree ─────────────────────────────────────────────────
print()
print("== §7 every gateway that names /bff/superadmin/** gates it ROLE_SUPERADMIN ==")
for gw in (FE, BE, SA):
    at = BY_GW_PAT.get((gw, "/bff/superadmin/**"), [])
    if at == [("ROLE_SUPERADMIN", True)]:
        ok(f"{gw} /bff/superadmin/** -> ROLE_SUPERADMIN (allow)")
    else:
        bad(f"{gw} /bff/superadmin/** carries {sorted(at)} — the three doors to the "
            f"same admin-bff surface must not differ")

# ── §8 no (gateway, pattern) mixes allow and deny ────────────────────────────
print()
print("== §8 no url_pattern carries both an allow and a deny row ==")
mixed = sorted(k for k, v in BY_GW_PAT.items()
               if any(a for _, a in v) and any(not a for _, a in v))
if mixed:
    bad("allow/deny mixed on the same (gateway, url_pattern): "
        + ", ".join(f"{g} {p}" for g, p in mixed)
        + " — deny-wins vs role-match is then model-dependent and this suite's "
          "decide() cannot be trusted for those paths")
else:
    ok(f"all {len(BY_GW_PAT)} (gateway, url_pattern) keys are uniformly allow or "
       f"uniformly deny — deny-wins is unambiguous")

# ── §9 the ORPHAN LEDGER ─────────────────────────────────────────────────────
# A '/bff…' row on a gateway whose route table has no '/bff' predicate governs
# traffic that never arrives. Harmless (it cannot admit anything) but ACTIVELY
# MISLEADING: this is precisely what made the superadmin surface look granted for
# as long as it did. Retained with a reason, and pinned here so a NEW one fails.
DOCUMENTED_ORPHANS = {
    (BE, "/bff/image-builds/arch/**"):
        "image-builder console seam; be-gateway routes no /bff path. Retained: "
        "grants nothing without a route, and it is the written posture for the "
        "day a /bff route is added to the api/tailnet door.",
    (BE, "/bff/image-builds/**"):
        "the mesh-workload half of the same image-builder seam (ROLE_IMAGE_BUILDER "
        "capability tier). Retained for the same reason as the arch row above.",
    (BE, "/bff/superadmin/**"):
        "the row this suite's defect report is about. Retained: deleting it would "
        "erase the be-gateway posture without changing any decision.",
    (BE, "/bff/superadmin/games-services/**"):
        "listed verbatim in optional-services.yaml games.routeAccessRows — "
        "gate_optional_services removes it by (gateway, urlPattern) on deselect, "
        "so deleting it here would leave that entry pointing at nothing.",
    (BE, "/bff/games-services/instances/**"):
        "listed verbatim in optional-services.yaml games.routeAccessRows; "
        "gate_optional_services removes it by (gateway, urlPattern) on deselect.",
    (BE, "/bff/games-services/catalog/**"):
        "listed verbatim in optional-services.yaml games.routeAccessRows; "
        "gate_optional_services removes it by (gateway, urlPattern) on deselect.",
    (BE, "/bff/superadmin/workloads/**"):
        "listed verbatim in optional-services.yaml workloadConsole.routeAccessRows.",
    (BE, "/bff/admin/workloads/**"):
        "listed verbatim in optional-services.yaml workloadConsole.routeAccessRows "
        "(the ADMIN read-only half of the same console).",
}

print()
print("== §9 every un-routed /bff row is a DOCUMENTED orphan, and the ledger is honest ==")


def routes_any_bff(routes):
    return any(p.strip().startswith("/bff")
               for r in routes for p in r["paths"] if p.strip())


actual_orphans = set()
for (gw, pat) in BY_GW_PAT:
    if not pat.startswith("/bff"):
        continue
    tables = [t for t, (g, _) in ROUTE_TABLES.items() if g == gw]
    if not tables:
        continue                      # gateway has no route table in this repo
    if any(routes_any_bff(ROUTE_TABLES[t][1]) and
           first_match(ROUTE_TABLES[t][1], pat.replace("/**", "/probe"),
                       "hugmesh.net") is not None
           for t in tables):
        # Reachable on at least one of this gateway's tables — not an orphan.
        # (The `/**`->`/probe` rewrite turns the row's pattern into a concrete
        # path the route matcher can be asked about.)
        continue
    actual_orphans.add((gw, pat))

undocumented = sorted(actual_orphans - set(DOCUMENTED_ORPHANS))
if undocumented:
    bad("un-routed /bff route-access row(s) with no ledger entry — a row that "
        "governs traffic which never arrives reads as a grant to anyone auditing "
        "the table: " + ", ".join(f"{g} {p}" for g, p in undocumented))
else:
    ok(f"all {len(actual_orphans)} un-routed /bff rows are in DOCUMENTED_ORPHANS")

stale = sorted(set(DOCUMENTED_ORPHANS) - actual_orphans)
if stale:
    bad("DOCUMENTED_ORPHANS names row(s) that are no longer orphaned (or no longer "
        "exist) — drop them, or the ledger rots into a blanket amnesty: "
        + ", ".join(f"{g} {p}" for g, p in stale))
else:
    ok("no stale ledger entry — every documented orphan is still an orphan")

thin = sorted(k for k, v in DOCUMENTED_ORPHANS.items() if len(v.strip()) < 40)
if thin:
    bad("ledger entr(ies) with no real reason: "
        + ", ".join(f"{g} {p}" for g, p in thin))
else:
    ok("every ledger entry records WHY the orphan is retained")

fe_orphans = sorted(p for (g, p) in actual_orphans if g == FE)
if fe_orphans:
    bad(f"the fe-gateway — the door a browser actually uses — has un-routed /bff "
        f"rows: {fe_orphans}")
else:
    ok("the fe-gateway has ZERO un-routed /bff rows (every row it carries is reachable)")

# ── §10 MFA lockstep ─────────────────────────────────────────────────────────
print()
print("== §10 the new row is inside the mfa_required flip prefix ==")
flip = re.search(r"UPDATE\s+gateway_route_access[\s\S]*?mfa_required\s*=\s*true[\s\S]*?;",
                 sql)
if flip is None:
    bad("no `UPDATE gateway_route_access SET mfa_required = true` statement found — "
        "test-mfa-required-rules.sh owns this, but the new row's coverage cannot be "
        "confirmed without it")
elif "/bff/superadmin/%" in flip.group(0):
    ok("the flip UPDATE keys on the '/bff/superadmin/%' PREFIX, so the new row is "
       "flipped without a companion edit (test-mfa-required-rules.sh check (b) is "
       "the deep version of this)")
else:
    bad("the mfa_required flip no longer keys on '/bff/superadmin/%' — the new row "
       "would be left mfa_required=false as the deciding rule")

# ── §11 admin-ui cross-check (optional input, LOUD skip) ─────────────────────
print()
print("== §11 every /bff/superadmin path the shipped admin-ui calls is reachable ==")
if not os.path.isdir(ADMIN_UI_DIST):
    skip(f"{os.path.relpath(ADMIN_UI_DIST, root)} is absent — the admin-ui bundle "
         f"cross-check did NOT run. §1-§5 above still ran against the hard-coded "
         f"PROBES list; what is unverified is whether the UI has since added a "
         f"superadmin path that list does not name.")
else:
    called = set()
    for fn in sorted(os.listdir(ADMIN_UI_DIST)):
        if not fn.endswith(".js"):
            continue
        txt = open(os.path.join(ADMIN_UI_DIST, fn), encoding="utf-8",
                   errors="replace").read()
        for m in re.finditer(r"/bff/superadmin/[A-Za-z0-9._-]+(?:/[A-Za-z0-9._-]+)*",
                             txt):
            called.add(m.group(0))
    if not called:
        bad(f"the admin-ui bundle is present but names ZERO /bff/superadmin paths — "
            f"the extractor's shape assumption broke, so this check is vacuous")
    else:
        unreachable = []
        for p in sorted(called):
            d, pat, _ = decide(BY_GW_PAT, FE, p, {"ROLE_SUPERADMIN"})
            r = first_match(CLUSTER_FE_ROUTES, p, "hugmesh.net")
            if d != "ALLOW" or r is None or "admin-bff" not in r["uri"]:
                unreachable.append(f"{p} (access={d} via {pat!r}, "
                                   f"route={r['id'] if r else None})")
        if unreachable:
            bad(f"admin-ui calls path(s) a superadmin cannot reach: "
                + "; ".join(unreachable))
        else:
            ok(f"all {len(called)} distinct /bff/superadmin paths in the shipped "
               f"admin-ui bundle route to admin-bff and admit ROLE_SUPERADMIN")

# ── §12 CROSS-MODEL: this suite's specificity() vs the repo oracle, EXECUTED ──
# The finding this section exists to close: specificity() above claimed to be "the
# repo's oracle (rbac-route-access.ts patternMatch)" and was not. Nothing compared
# them, so the claim was decoration. Two things run here:
#
#   (a) a SOURCE PIN that always runs — the three scoring expressions are read out
#       of the TS file itself, so editing the oracle's formula fails this suite
#       even where node cannot run;
#   (b) an EXECUTED comparison — node imports patternMatch from the .ts directly
#       (Node >= 22.6 strips types) and is asked for {matched, specificity} for
#       every (pattern, path) pair generated from the WHOLE seed. Every mismatch
#       must be in MODEL_DIVERGENCES with a reason.
#
# Node is deliberately NOT a hard requirement: the GitLab lane runs python:3-slim.
# Absent node is a LOUD skip that names what did not run, and (a) still runs.
print()
print("== §12 cross-model: specificity() is the repo oracle, checked against it ==")

# Patterns whose two models KNOWINGLY differ, recorded rather than silently
# tolerated. Same ledger idiom as DOCUMENTED_ORPHANS: an undocumented divergence
# fails, and a documented one that stops diverging fails too.
MODEL_DIVERGENCES = {
    # EMPTIED 2026-09-16 (#351). The two entries here — '/*.js' and '/*.css' —
    # recorded that the RETIRED patternMatch() implemented only two shapes and so
    # compared a single-segment glob literally, never matching '/app.js'. Main's
    # antMatch() implements that shape (rbac-route-access.ts: the
    # `pattern.includes('*')` branch builds a `[^/]*` regex), so the divergence is
    # GONE, not merely unledgered — and the stale-ledger assertion below would fail
    # if these were left in, which is how it was noticed. The mechanism stays: an
    # undocumented divergence fails, and a documented one that stops diverging fails
    # too, so this dict must stay empty only while the models really agree.
}

ts_src = ""
if not os.path.isfile(TS_ORACLE):
    bad(f"{os.path.relpath(TS_ORACLE, root)} is MISSING — specificity() above is a "
        f"transcription of a file that is not there")
else:
    ts_src = open(TS_ORACLE, encoding="utf-8").read()
    m = re.search(r"export function antMatch\([\s\S]*?\n\}", ts_src)
    d = re.search(r"export function decideAgainst\([\s\S]*?\n\}", ts_src)
    if m is None:
        bad("antMatch() is not EXPORTED from rbac-route-access.ts — §12(b) cannot "
            "import it. (Before 2026-09-16 this pinned patternMatch(); main retired "
            "that with the generated-seed oracle. If the export moved again, point "
            "this at the new name rather than deleting the section.)")
    elif d is None:
        bad("decideAgainst() is not EXPORTED from rbac-route-access.ts — the "
            "RANKING rule lives in it and §12 pins the ranking, not just matching")
    else:
        body = m.group(0)
        rank = d.group(0)
        required = {
            "antMatch's root-glob branch":     "pattern === '/**'",
            "antMatch's trailing-glob branch": "pattern.endsWith('/**')",
            "antMatch's segment-glob branch":  "[^/]*",
            "the RAW-LENGTH ranking key":      "r.urlPattern.length > bestLen",
            "ranking by that same length":     "r.urlPattern.length !== bestLen",
        }
        hay = {k: (body if k.startswith("antMatch") else rank)
               for k in required}
        missing = [k for k, v in required.items() if v not in hay[k]]
        if missing:
            bad("the repo oracle's matching or RANKING changed — specificity() above "
                "is a transcription of it and must be re-synced. Missing: "
                + ", ".join(missing))
        else:
            ok("source pin: the oracle still matches on antMatch()'s three shapes "
               "and ranks by RAW urlPattern.length — which is what "
               "GatewayRouteAccessService.java:182 does, and what specificity() "
               "above now returns")

# ---- (b) execute it -----------------------------------------------------------
ALL_PATTERNS = sorted({p for (_g, p) in BY_GW_PAT})


def _paths_for(pattern):
    if pattern.endswith("/**"):
        pre = pattern[:-3]
        return [pre, pre + "/x", pre + "/x/y"]
    if "*" in pattern:
        return [pattern, pattern.replace("*", "x")]
    return [pattern, pattern + "/x"]


PATH_UNIVERSE = sorted({q for p in ALL_PATTERNS for q in _paths_for(p)}
                       | {p for p, _ in PROBES} | {p for p, _ in DENY_PROBES})
PAIRS = [(pat, path) for pat in ALL_PATTERNS for path in PATH_UNIVERSE]


def run_ts_oracle(pairs):
    """[(matched, rank_key)] from the REAL oracle, or None + a reason.

    `rank_key` is `pattern.length`, which is literally what decideAgainst() ranks
    by (`r.urlPattern.length > bestLen`) and what the gateway ranks by
    (GatewayRouteAccessService.java:182). Taken from the TS side rather than
    recomputed here so the two halves of §12 stay independent."""
    if shutil.which("node") is None:
        return None, "node is not on PATH"
    tmp = tempfile.mkdtemp(prefix="superadmin-ts.")
    try:
        helper = os.path.join(tmp, "probe.mjs")
        payload = os.path.join(tmp, "pairs.json")
        with open(helper, "w", encoding="utf-8") as fh:
            fh.write(
                "import { readFileSync } from 'node:fs';\n"
                "const mod = await import(process.argv[2]);\n"
                "if (typeof mod.antMatch !== 'function') {\n"
                "  console.error('antMatch is not exported'); process.exit(3);\n"
                "}\n"
                "const pairs = JSON.parse(readFileSync(process.argv[3], 'utf8'));\n"
                "process.stdout.write(JSON.stringify(pairs.map(([p, q]) => {\n"
                "  return [mod.antMatch(p, q) === true, p.length];\n"
                "})));\n")
        with open(payload, "w", encoding="utf-8") as fh:
            json.dump(pairs, fh)
        # STAGE THE MODULE GRAPH. Since main replaced the hand-written mirror with a
        # GENERATED seed, the oracle starts with
        #     import { ROUTE_ACCESS_SEED } from './rbac-route-access.seed';
        # — an EXTENSIONLESS relative specifier, which TypeScript resolves and Node's
        # ESM loader does not ("Cannot find module …/rbac-route-access.seed", measured
        # on Node v26.8.1). Before 2026-09-16 the oracle was self-contained and this
        # never arose, so §12(b) silently downgraded to "node could not import the .ts
        # oracle" — a SKIP, i.e. the executed half quietly stopped running. Copy the
        # oracle and every sibling .ts it imports into the sandbox and add the
        # extension there; the repo tree is not touched.
        staged = os.path.join(tmp, os.path.basename(TS_ORACLE))
        src_dir = os.path.dirname(TS_ORACLE)
        src = open(TS_ORACLE, encoding="utf-8").read()
        for spec in sorted(set(re.findall(r"from\s+'(\./[A-Za-z0-9_.-]+)'", src))):
            sib = os.path.join(src_dir, os.path.basename(spec) + ".ts")
            if os.path.isfile(sib):
                shutil.copyfile(sib, os.path.join(tmp, os.path.basename(sib)))
                src = src.replace(f"from '{spec}'", f"from '{spec}.ts'")
        with open(staged, "w", encoding="utf-8") as fh:
            fh.write(src)
        last = ""
        for argv in (["node", helper, staged, payload],
                     ["node", "--experimental-strip-types", helper, staged, payload]):
            try:
                r = subprocess.run(argv, capture_output=True, text=True, timeout=120)
            except Exception as exc:                       # noqa: BLE001
                last = f"{argv[1]}: {exc}"
                continue
            if r.returncode == 0 and r.stdout.strip():
                try:
                    return json.loads(r.stdout), None
                except ValueError as exc:
                    last = f"unparseable stdout: {exc}"
                    continue
            last = (r.stderr or r.stdout or "").strip().splitlines()[-1:] or ["rc=%d" % r.returncode]
            last = last[0]
        return None, f"node could not import the .ts oracle ({last})"
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def old_specificity(pattern):
    """The RETIRED patternMatch() scoring, kept ONLY as a negative control.

    ⚠ REPOINTED 2026-09-16 (#351). This used to hold the suite's FIRST wrong model
    (literal-prefix length * 2, +1 for an exact pattern). That model happens to rank
    exact-vs-glob the SAME WAY the gateway does, so once specificity() was corrected
    to raw length the control could no longer tell the two apart and said so:
        "the old and new specificity formulas rank EVERY case identically on this
         seed — then §12's whole premise is unfalsifiable here"
    A control that cannot fail is not a control. The model this suite actually moved
    away from is the one the retired `patternMatch()` implemented, which INVERTS
    exact-vs-glob, so that is what is pinned here:
        glob  -> (len(pattern) - 3) * 2      '/'   -> 1      exact -> len * 2 + 1
    On '/api/federation/vanity' (fe, PUBLIC) it scores the exact row 45 and the glob
    row 44 and picks the EXACT one; the gateway scores 22 and 25 and picks the GLOB."""
    if pattern.endswith("/**"):
        return (len(pattern) - 3) * 2
    if pattern == "/":
        return 1
    return len(pattern) * 2 + 1


ts_scores, why = run_ts_oracle(PAIRS)
if ts_scores is None:
    skip(f"the EXECUTED half of §12 did not run: {why}. The source pin above still "
         f"ran. What is unverified is that patternMatch and specificity() agree on "
         f"the {len(PAIRS)} (pattern, path) pairs of the live seed.")
else:
    got = dict(zip(PAIRS, [(bool(a), b) for a, b in ts_scores]))
    match_diffs, score_diffs = [], []
    for (pat, path) in PAIRS:
        ts_m, ts_s = got[(pat, path)]
        py_m = pattern_matches(pat, path)
        if py_m != ts_m:
            match_diffs.append((pat, path, py_m, ts_m))
        elif py_m and specificity(pat) != ts_s:
            score_diffs.append((pat, path, specificity(pat), ts_s))
    undoc = sorted({p for p, _q, _a, _b in match_diffs} - set(MODEL_DIVERGENCES))
    if undoc:
        bad("pattern(s) where this suite and the repo oracle DISAGREE ON MATCHING "
            "with no ledger entry: " + ", ".join(repr(p) for p in undoc))
    else:
        ok(f"matching agrees on all {len(PAIRS)} (pattern, path) pairs except the "
           f"{len(MODEL_DIVERGENCES)} ledgered pattern(s)")
    if score_diffs:
        head = "; ".join(f"{p!r} vs {q!r}: py={a} ts={b}"
                         for p, q, a, b in score_diffs[:4])
        bad(f"{len(score_diffs)} (pattern, path) pair(s) rank DIFFERENTLY from the "
            f"repo oracle — specificity() is not the gateway's key: {head}")
    else:
        ok(f"specificity() equals the oracle's ranking key (raw urlPattern.length) "
           f"on every matching pair ({len(PAIRS)} pairs). Both are now the same "
           f"expression BY DESIGN — that is the 2026-09-16 correction — so the "
           f"protection against the TS side moving is the source pin above, and "
           f"against the gateway moving is GatewayRouteAccessService.java:182")
    stale_div = sorted(set(MODEL_DIVERGENCES) - {p for p, _q, _a, _b in match_diffs})
    if stale_div:
        bad("MODEL_DIVERGENCES names pattern(s) that no longer diverge — drop them "
            "or the ledger rots into a blanket amnesty: "
            + ", ".join(repr(p) for p in stale_div))
    else:
        ok("every ledgered divergence still occurs (the ledger is not stale)")

    # Whole-decision agreement, ledgered patterns removed from BOTH models.
    ignored = set(MODEL_DIVERGENCES)
    rank_diffs = []
    for gw in sorted({g for (g, _p) in BY_GW_PAT}):
        pats = [p for (g, p) in BY_GW_PAT if g == gw and p not in ignored]
        for path in PATH_UNIVERSE:
            py_hits = [p for p in pats if pattern_matches(p, path)]
            ts_hits = [p for p in pats if got[(p, path)][0]]
            py_win = ({p for p in py_hits if specificity(p) == max(specificity(q) for q in py_hits)}
                      if py_hits else set())
            ts_win = ({p for p in ts_hits if got[(p, path)][1] == max(got[(q, path)][1] for q in ts_hits)}
                      if ts_hits else set())
            if py_win != ts_win:
                rank_diffs.append((gw, path, sorted(py_win), sorted(ts_win)))
    if rank_diffs:
        head = "; ".join(f"{g} {q!r}: py={a} ts={b}" for g, q, a, b in rank_diffs[:4])
        bad(f"{len(rank_diffs)} (gateway, path) case(s) where the two models pick a "
            f"DIFFERENT winning row — 'most specific wins' has two contradictory "
            f"transcriptions in this repo: {head}")
    else:
        ok(f"both models pick the SAME winning row for every one of the "
           f"{len(PATH_UNIVERSE)} paths on every gateway")

    # NEGATIVE CONTROL for exactly this finding: put the OLD formula back and the
    # ranking check must go red on the /api/federation/vanity pair.
    old_rank_diffs = []
    for gw in sorted({g for (g, _p) in BY_GW_PAT}):
        pats = [p for (g, p) in BY_GW_PAT if g == gw and p not in ignored]
        for path in PATH_UNIVERSE:
            py_hits = [p for p in pats if pattern_matches(p, path)]
            ts_hits = [p for p in pats if got[(p, path)][0]]
            py_win = ({p for p in py_hits if old_specificity(p) == max(old_specificity(q) for q in py_hits)}
                      if py_hits else set())
            ts_win = ({p for p in ts_hits if got[(p, path)][1] == max(got[(q, path)][1] for q in ts_hits)}
                      if ts_hits else set())
            if py_win != ts_win:
                old_rank_diffs.append((gw, path))
    if old_rank_diffs:
        ok(f"negative control: restoring the OLD patternMatch-derived formula makes the "
           f"cross-model check RED on {len(old_rank_diffs)} case(s), e.g. "
           f"{old_rank_diffs[0][0]} {old_rank_diffs[0][1]!r} — the divergence was "
           f"real and this check sees it")
    else:
        bad("negative control: the OLD (wrong) specificity formula ALSO agrees with "
            "the oracle on this data — §12 cannot tell the two models apart and is "
            "vacuous")

# A node-free version of the same negative control, so the fix is demonstrated even
# where §12(b) skipped: the two Python formulas must actually rank something
# differently, or "the model was corrected" is an empty claim.
_shift = [(p, q) for p in ALL_PATTERNS for q in _paths_for(p)]
_flips = []
for gw in sorted({g for (g, _p) in BY_GW_PAT}):
    pats = [p for (g, p) in BY_GW_PAT if g == gw and p not in MODEL_DIVERGENCES]
    for path in PATH_UNIVERSE:
        hits = [p for p in pats if pattern_matches(p, path)]
        if not hits:
            continue
        a = {p for p in hits if specificity(p) == max(specificity(q) for q in hits)}
        b = {p for p in hits if old_specificity(p) == max(old_specificity(q) for q in hits)}
        if a != b:
            _flips.append((gw, path, sorted(a), sorted(b)))
if _flips:
    ok(f"the correction is not cosmetic: the old and new formulas pick a different "
       f"winning row in {len(_flips)} case(s), e.g. {_flips[0][0]} {_flips[0][1]!r} "
       f"-> new {_flips[0][2]} vs old {_flips[0][3]}")
else:
    bad("the old and new specificity formulas rank EVERY case identically on this "
        "seed — then §12's whole premise is unfalsifiable here and must be re-argued")


# ── §13 an optional slug's superadmin surface must not outlive its slug ───────
# THE DEFECT: the '/bff/superadmin/**' floor is deliberately absent from every
# *.routeAccessRows list in optional-services.yaml (it also carries five pages that
# are not optional-gated). gate_optional_services can only REMOVE rows, never add
# one — so a superadmin-prefixed surface owned by an OPTIONAL slug stays matched at
# the PUBLIC fe door after that slug is deselected, on a gateway that forwards it to
# the always-present admin-bff. That is not hypothetical: it is what the games
# app-store control plane did until the deny row in §5b, and what the workload
# console still does BY DECISION.
#
# This is measured by EXECUTION, not by reading the builder: the bash preamble ran
# each real builder's `<slug>)` case body — extracted from the builder, with the
# builder's own `_opt_*` helpers and its own slug list — against a sandbox copy of
# 20-schema.sql. Here the PRUNED seed is re-parsed and asked the only question that
# matters: can somebody still get in at the front door?
print()
print("== §13 no optional slug leaves a superadmin surface open at the fe door ==")


ALL_ROLES = {"ROLE_SUPERADMIN", "ROLE_ADMIN", "ROLE_FLEET_ADMIN", "ROLE_MOD",
             "ROLE_USER", "ROLE_IMAGE_BUILDER", "ROLE_GAMES_SERVICES",
             "ROLE_GAMES_SERVICES_ADMIN", "ROLE_GAMES_SERVICES_RUNNER"}


def _rows_of(path):
    txt = strip_sql_comments(open(path, encoding="utf-8").read())
    return [(m.group("gw"), m.group("pat"), m.group("role"), m.group("allow") == "true")
            for m in ROW_RE.finditer(txt)]


if not GATEDIR or not os.path.isdir(GATEDIR):
    bad("the gate sandbox was not created — §13 cannot run, and an un-run check is "
        "not a pass")
else:
    gated = sorted(d for d in os.listdir(GATEDIR) if os.path.isdir(f"{GATEDIR}/{d}"))
    if not gated:
        bad("the gate sandbox is EMPTY — no builder's gate_optional_services was "
            "executed, so §13 would report 'no survivors' vacuously")
    survivors, checked = {}, 0
    for bn in gated:
        for slug in sorted(os.listdir(f"{GATEDIR}/{bn}")):
            f = f"{GATEDIR}/{bn}/{slug}/manifests/route-access/initdb/20-schema.sql"
            if not os.path.isfile(f):
                bad(f"[{bn}] slug {slug!r}: the gate produced no pruned schema — the "
                    f"case body could not be executed, so its posture is UNKNOWN")
                continue
            pruned = _rows_of(f)
            if len(pruned) < 50:
                bad(f"[{bn}] slug {slug!r}: the pruned seed has only {len(pruned)} "
                    f"rows — the gate mangled the file, verdicts would be junk")
                continue
            gone = sorted({(g, p) for (g, p, _r, _a) in ROWS}
                          - {(g, p) for (g, p, _r, _a) in pruned})
            if not gone:
                continue
            checked += 1
            m = {}
            for g, p, r, a in pruned:
                m.setdefault((g, p), []).append((r, a))
            for (_g, p) in gone:
                if not p.startswith("/bff"):
                    continue
                probe = p[:-3] + "/probe" if p.endswith("/**") else p
                d, win, at = decide(m, FE, probe, ALL_ROLES)
                if d == "ALLOW":
                    survivors.setdefault((slug, p), set()).add(
                        f"{bn}: {probe} -> ALLOW via {win!r} {sorted(at)}")
    if checked == 0:
        bad("no slug's gate removed a single route-access row — the extraction is "
            "broken and §13 is vacuous")
    else:
        ok(f"executed {checked} builder×slug gate(s) that prune route-access rows")
    undoc = sorted(k for k in survivors if k not in DESELECT_SURVIVORS)
    if undoc:
        for slug, p in undoc:
            bad(f"slug {slug!r} drops {p!r} but the fe front door STILL admits it — "
                + "; ".join(sorted(survivors[(slug, p)]))
                + ". A broader surviving row is carrying an optional service's "
                  "control plane onto the PUBLIC door. Add a DENY row at the longer "
                  "pattern (gate_optional_services cannot add one for you), or "
                  "record it in DESELECT_SURVIVORS with the wall that is left.")
    else:
        ok(f"every deselect-survivor is in DESELECT_SURVIVORS ({len(survivors)} of "
           f"them) — no undocumented optional surface is open at the front door")
    stale_s = sorted(set(DESELECT_SURVIVORS) - set(survivors))
    if stale_s:
        bad("DESELECT_SURVIVORS names case(s) that no longer survive (or no longer "
            "exist) — drop them, or the ledger becomes a blanket amnesty: "
            + ", ".join(f"{a} {b}" for a, b in stale_s))
    else:
        ok("no stale §13 ledger entry — every recorded survivor still survives")
    thin_s = sorted(k for k, v in DESELECT_SURVIVORS.items() if len(v.strip()) < 80)
    if thin_s:
        bad("§13 ledger entr(ies) that do not name the remaining wall: "
            + ", ".join(f"{a} {b}" for a, b in thin_s))
    else:
        ok("every §13 ledger entry names the wall that is actually left")
    _games = ("games", "/bff/superadmin/games-services/**")
    if _games in survivors and _games not in DESELECT_SURVIVORS:
        bad("the games app-store control plane is OPEN at the fe door on a "
            "games-deselected build and is NOT in the ledger — the §5b deny row is "
            "not doing its job and nobody has written down why")
    elif _games in survivors:
        ok("games-deselected: /bff/superadmin/games-services/** survives at the fe "
           "door via the floor, as DESELECT_SURVIVORS records for operator decision "
           "8 — the walls named there are what hold it (checked in §5b)")
    else:
        ok("games-deselected: /bff/superadmin/games-services/** is NOT reachable at "
           "the fe door (an explicit deny row holds through the gate)")


# ─────────────────────────────────────────────── NEGATIVE CONTROLS (mutations) ─
# Break the DATA, then require the check above to go red. Anything that survives
# is reported as a SURVIVOR here rather than quietly dropped.
print()
print("== negative controls: break it and require the checks to notice ==")


def rows_to_map(rows):
    m = {}
    for gw, pat, role, allow in rows:
        m.setdefault((gw, pat), []).append((role, allow))
    return m


def superadmin_verdict(rows):
    """Re-run §2+§3 (ALLOW via a superadmin-family row) over a mutated row set."""
    m = rows_to_map(rows)
    broken = 0
    for path, _ in PROBES:
        d, pat, _ = decide(m, FE, path, {"ROLE_SUPERADMIN"})
        if d != "ALLOW" or pat is None or not pat.startswith("/bff/superadmin"):
            broken += 1
    return broken


def downcascade_verdict(rows):
    """Re-run §5 (every non-superadmin tier is denied) over a mutated row set."""
    m = rows_to_map(rows)
    leaks = 0
    for roles in DENIED_TIERS.values():
        for path, _ in PROBES:
            if decide(m, FE, path, roles)[0] != "DENY":
                leaks += 1
    return leaks


def expect_caught(label, mutate, verdict=superadmin_verdict, base_rows=None):
    rows = list(base_rows if base_rows is not None else ROWS)
    before = verdict(rows)
    mutate(rows)
    after = verdict(rows)
    if after > before:
        ok(f"negative control: {label} -> CAUGHT ({after} probe(s) now failing, "
           f"was {before})")
    else:
        bad(f"negative control: {label} -> SURVIVED (still {after} failing, was "
            f"{before}) — the check is vacuous for this defect")


def expect_unchanged(label, mutate, verdict=superadmin_verdict, note=""):
    """An EQUIVALENT-MUTANT control, stated on purpose. Used where a mutation
    cannot change the outcome because the model genuinely does not depend on the
    thing mutated — printing it is how the claim stays honest."""
    rows = list(ROWS)
    before = verdict(rows)
    mutate(rows)
    after = verdict(rows)
    if after == before:
        ok(f"equivalent mutant: {label} -> outcome UNCHANGED. {note}")
    else:
        bad(f"{label} CHANGED the outcome ({before} -> {after}) — the model was "
            f"assumed not to depend on this, and it does. {note}")


def drop_row(target):
    def f(rows):
        rows[:] = [r for r in rows if r != target]
    return f


def replace_row(target, new):
    def f(rows):
        rows[:] = [new if r == target else r for r in rows]
    return f


def prepend_row(new):
    def f(rows):
        rows.insert(0, new)
    return f


def move_row_to_end(target):
    """Move `target` to the end of the VALUES list, WITHOUT raising when it is
    absent. The old form was `rows.remove(t), rows.append(t)`, and list.remove
    raises ValueError on a missing row — which is exactly the state every §14
    mutation of the fe '/bff/superadmin/**' row produces. The suite then died
    mid-run with a traceback that BURIED the eight correct FAIL lines above it and
    never printed a tally. Presence is asserted at the call site instead, so a
    missing row is reported as a vacuous control rather than a crash."""
    def f(rows):
        rows[:] = [r for r in rows if r != target] + [target]
    return f


expect_caught("the fe /bff/superadmin/** row is DELETED (the original defect)",
              drop_row(NEW_ROW))
expect_caught("the fe row's allow is flipped to FALSE",
              replace_row(NEW_ROW, (FE, "/bff/superadmin/**", "ROLE_SUPERADMIN", False)))
expect_caught("the fe row's pattern loses its /** (exact path only)",
              replace_row(NEW_ROW, (FE, "/bff/superadmin", "ROLE_SUPERADMIN", True)))
expect_caught("the fe row is re-gated to ROLE_ADMIN (down-cascade leak)",
              replace_row(NEW_ROW, (FE, "/bff/superadmin/**", "ROLE_ADMIN", True)),
              verdict=downcascade_verdict)
expect_caught("a BROADER fe floor is added as PUBLIC and the superadmin row is "
              "deleted with it (the surface goes anonymous)",
              lambda rows: (drop_row(NEW_ROW)(rows),
                            prepend_row((FE, "/bff/**", "PUBLIC", True))(rows)),
              verdict=downcascade_verdict)

# ── controls for the three defects the 2026-08-26 review found ───────────────
DENY_ROW = (FE, "/bff/superadmin/games-services/**", "ROLE_SUPERADMIN", False)
# ⚠ THESE THREE CONTROLS MUTATE A ROW THAT IS NOT SEEDED. They break the fe
# games-services DENY row and require §5b to notice — which it cannot when the row
# does not exist: dropping an absent row changes nothing, so all three reported
# "SURVIVED … the check is vacuous for this defect" on the 2026-09-16 merge. That is
# the controls being honest, not a defect in them, so they are GATED on the row's
# presence and announce what is unverified rather than being deleted. They come back
# the moment operator decision 8 is revisited and the row is seeded (#351).
if DENY_ROW in ROWS:


    def deny_verdict(rows):
        """Re-run §5b: every DENY_PROBES path must be DENIED for ROLE_SUPERADMIN."""
        m = rows_to_map(rows)
        leaks = 0
        for path, _ in DENY_PROBES:
            if decide(m, FE, path, {"ROLE_SUPERADMIN"})[0] != "DENY":
                leaks += 1
        return leaks


    expect_caught("the games-services DENY row is deleted (finding #2: the floor "
                  "outlives the games slug and app-store curation reaches the PUBLIC "
                  "door on a games-deselected build)",
                  drop_row(DENY_ROW), verdict=deny_verdict)
    expect_caught("the games-services deny is flipped to an ALLOW",
                  replace_row(DENY_ROW, (FE, "/bff/superadmin/games-services/**",
                                         "ROLE_SUPERADMIN", True)),
                  verdict=deny_verdict)
    # Writing the deny at the SAME pattern as the floor is caught by §2, NOT by §5b —
    # and saying which check catches it is the point of a control. deny-wins is
    # evaluated at the winning LENGTH, so an allow+deny pair on one (gateway, pattern)
    # blanks the whole superadmin console instead of just the games family. §8 flags the
    # mixed key as well; deny_verdict cannot see it because the probes stay DENIED.
    expect_caught("the deny is written at the SAME pattern as the floor (deny-wins then "
                  "blanks the WHOLE superadmin console, not just games-services)",
                  replace_row(DENY_ROW, (FE, "/bff/superadmin/**", "ROLE_SUPERADMIN", False)),
                  verdict=superadmin_verdict)
else:
    skip("the three games-services DENY-row controls did not run: that row is not "
         "seeded (operator decision 8, #244 ACCEPT, \"without the games-services "
         "deny row\"). What is unverified is that §5b would notice the row being "
         "deleted, flipped to ALLOW, or written at the floor's own pattern. §5b's "
         "ledgered branch — the posture that IS in force — is exercised instead, "
         "and its own leak check runs every time.")

_mixed_rows = [r for r in ROWS if r != DENY_ROW] + [
    (FE, "/bff/superadmin/**", "ROLE_SUPERADMIN", False)]
_mixed_map = {}
for _gw, _pat, _role, _allow in _mixed_rows:
    _mixed_map.setdefault((_gw, _pat), []).append((_role, _allow))
if any(any(a for _, a in v) and any(not a for _, a in v) for v in _mixed_map.values()):
    ok("negative control: that same mutation also trips §8 (one (gateway, pattern) "
       "carrying both an allow and a deny row)")
else:
    bad("negative control: an allow+deny pair on one (gateway, pattern) does NOT "
        "trip §8 — that check is vacuous")

# §13's ledger must not be able to absorb a NEW open surface (finding #1/#2 class).
_fake_surv = ("brand-new-slug", "/bff/superadmin/brand-new-surface/**")
if sorted({_fake_surv} - set(DESELECT_SURVIVORS)) == [_fake_surv]:
    ok("negative control: a NEW optional slug whose superadmin surface stays open "
       "at the fe door is reported as undocumented (the §13 ledger cannot silently "
       "absorb one)")
else:
    bad("negative control: a NEW open optional surface would NOT be reported — the "
        "§13 ledger is vacuous")

# The unit's ordering mutation, answered honestly. Route TABLES are ordered and a
# broader earlier entry really does swallow a narrower one (§1 and the nc below
# prove that). Route-access ROWS are NOT: the loader reads them into a set and
# decide() ranks by pattern specificity, so file position carries no meaning. Both
# controls below are therefore EQUIVALENT MUTANTS by construction, and saying so
# is the finding — not a gap.
if NEW_ROW in ROWS:
    expect_unchanged("the fe /bff/superadmin/** row is moved to the END of the INSERT",
                     move_row_to_end(NEW_ROW),
                     note="Row order is not the precedence mechanism: decide() ranks "
                          "by url_pattern specificity, so the row is correct anywhere "
                          "in the VALUES list.")
else:
    # Reached only when something upstream has already broken the floor row — in
    # which case §2 has ALREADY failed loudly and this control has nothing to move.
    # Say so and keep going; do not crash and bury the findings above.
    bad("the row-ordering control could not run: the fe '/bff/superadmin/**' "
        "ROLE_SUPERADMIN allow row is not in the seed, so there is nothing to move "
        "and the equivalent-mutant claim is unproven. The failures printed above "
        "are the real finding.")
expect_unchanged("a BROADER fe '/bff/**' ROLE_USER row is inserted BEFORE it",
                 prepend_row((FE, "/bff/**", "ROLE_USER", True)),
                 note="specificity('/bff/superadmin/**')="
                      f"{specificity('/bff/superadmin/**')} beats "
                      f"specificity('/bff/**')={specificity('/bff/**')}, "
                      "so an earlier broader row cannot swallow it.")

# …and prove the deciding-pattern machinery is not a rubber stamp: a LONGER row
# DOES take the decision away, in the direction an operator would actually use.
print()
rows = list(ROWS)
rows.insert(0, (FE, "/bff/superadmin/workloads/**", "ROLE_SUPERADMIN", False))
m = rows_to_map(rows)
wl = [p for p, _ in PROBES if p.startswith("/bff/superadmin/workloads/")]
other = [p for p, _ in PROBES if not p.startswith("/bff/superadmin/workloads/")]
wl_denied = all(decide(m, FE, p, {"ROLE_SUPERADMIN"})[0] == "DENY" for p in wl)
other_ok = all(decide(m, FE, p, {"ROLE_SUPERADMIN"})[0] == "ALLOW" for p in other)
if wl and wl_denied and other_ok:
    ok("longest-pattern control: adding the DENY row at "
       "'/bff/superadmin/workloads/**' takes the decision away for the "
       f"{len(wl)} workload probe(s) and leaves the other {len(other)} ALLOWed — "
       "the deciding-pattern model is real, and the tailnet-only posture for the "
       "dangerous tier is one row away for an operator who wants it back")
else:
    bad(f"longest-pattern control failed: workloads denied={wl_denied} "
        f"(n={len(wl)}), others still allowed={other_ok} — decide() is not "
        f"honouring the longer pattern")

# Route-table mutation: order DOES matter here.
print()
compose_ok = first_match(COMPOSE_FE_ROUTES, PROBES[0][0], "hugmesh.net")
mutated = [r for r in COMPOSE_FE_ROUTES if r["id"] != "hugmesh-admin-bff-api"]
after = first_match(mutated, PROBES[0][0], "hugmesh.net")
if compose_ok and "admin-bff" in compose_ok["uri"] and (
        after is None or "admin-bff" not in after["uri"]):
    ok(f"negative control: deleting the compose '/bff/**' route -> CAUGHT "
       f"({PROBES[0][0]} now resolves to {after['id'] if after else None})")
else:
    bad("negative control: deleting the '/bff/**' route did NOT change where "
        "/bff/superadmin/** resolves — §1 is vacuous")

# Ledger mutation: a NEW un-routed row must not pass unnoticed.
print()
fake = (BE, "/bff/brand-new-surface/**")
probe_orphans = set(actual_orphans) | {fake}
if sorted(probe_orphans - set(DOCUMENTED_ORPHANS)) == [fake]:
    ok("negative control: a NEW un-routed /bff row on the be-gateway is reported "
       "as undocumented (the ledger cannot silently absorb one)")
else:
    bad("negative control: a NEW un-routed /bff row would NOT be reported — the "
        "orphan ledger is vacuous")

print()
print(f"== RESULT: {passed} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
PY
