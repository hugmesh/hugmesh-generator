#!/usr/bin/env bash
# test-fe-bff-route-lane-parity.sh — the COMPOSE fe route table and the CLUSTER fe
# route table must send the same /bff path to the same BFF.
#
# WHY THIS EXISTS
# ---------------
# hugmesh-generator#366: five /bff paths were routed to DIFFERENT services by the
# two fe route tables. The cluster table (specs/cluster/apps/20-gateway-fe.yaml)
# sent them to user-bff via `/bff/register/**`, `/bff/me/**` and
# `/bff/provision/**`; the compose table
# (tests/stack/gateway-routes/fe/application-routes.yml) had no entry for any of
# them, so all five fell through to its `/bff/**` admin-bff catch-all. The compose
# e2e lane therefore could not observe the cluster's 404s — the split was the bug,
# and it survived for months precisely because no test read BOTH tables.
#
# Operator decision 40 (hugmesh-generator#347, answers comment of 2026-09-17)
# chose FULL alignment onto user-bff, over the cheaper option of carving the two
# `/bff/register/*` paths back to admin-bff on the cluster. Two of the five —
# POST /bff/register/google and POST /bff/register/discord — initially had NO
# user-bff handler and 404'd on BOTH lanes, an ACCEPTED regression pending a
# fix. UPDATED 2026-09-18: that fix landed
# (hugmesh/hugmesh-user-bff-api#20, commit dc34c8b, LegacyPathParityController)
# — this guard's own FIVE table went stale claiming otherwise for a day
# (flagged on hugmesh-generator#347 2026-09-18T07:21Z) because `has_handler`
# was only ever printed, never asserted; it is asserted now (see the FIVE
# table below). This guard is what stops a well-meaning "fix" from quietly
# restoring the split.
#
# WHAT IS ASSERTED
# ----------------
#   1. ALIGNMENT — each of the five resolves to user-bff on BOTH tables.
#   2. PARITY — every probe path below resolves to the SAME service on both
#      tables (an outcome assertion: it survives renames and reordering, and
#      fails if anything is inserted above that would swallow the traffic).
#   3. NO WIDENING — the compose table must NOT carry the cluster's
#      `/bff/me/**`, `/bff/register/**` or `/bff/provision/**` subtrees. admin-bff
#      owns POST+GET /bff/me/appeal (AccountAppealUserController) and
#      POST /bff/register/complete (AuthController) under those same prefixes; a
#      subtree on compose would move THOSE to user-bff as well, which is a sixth
#      and seventh 404 nobody decided on.
#   4. NON-REGRESSION — /bff/me/appeal and /bff/register/complete still reach
#      admin-bff on the compose lane.
#
# KNOWN DIVERGENCE, reported and NOT asserted: the cluster's `/bff/me/**` already
# swallows /bff/me/appeal, so that path 404s on a cluster today. It is recorded on
# hugmesh-generator#366; the fix belongs in specs/cluster/apps/20-gateway-fe.yaml,
# which this lane does not own. This guard PRINTS it every run rather than pinning
# it, so fixing it there does not turn this file red.
#
# NEGATIVE CONTROLS: six mutations of the parsed tables must each trip the checks.
# A guard whose controls are never exercised can rot into a vacuous pass; these
# run in-process on copies, so the files on disk are never modified.
#
# Offline: reads two files. No cluster, no docker, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import copy
import re
import sys

root = sys.argv[1]

try:
    import yaml
except Exception as e:                                        # pragma: no cover
    print(f"FATAL: PyYAML is required ({e}).", file=sys.stderr)
    sys.exit(2)

COMPOSE_FE = f"{root}/tests/stack/gateway-routes/fe/application-routes.yml"
CLUSTER_FE = f"{root}/specs/cluster/apps/20-gateway-fe.yaml"

passed = 0
failed = 0


def ok(msg):
    global passed
    passed += 1
    print(f"  PASS {msg}")


def bad(msg):
    global failed
    failed += 1
    print(f"  FAIL {msg}")


# ---------------------------------------------------------------- matching ---
def ant_to_re(pattern):
    """Spring's path matching: ** crosses /, * does not.

    TRAILING `/**` MATCHES ZERO SEGMENTS. Both AntPathMatcher and the
    PathPattern parser webflux actually uses treat `/bff/me/**` as matching the
    bare `/bff/me` as well as `/bff/me/x`. Rendering it as `^/bff/me/.*$` — the
    naive translation — would make a bare-prefix probe (`/bff/me`,
    `/bff/register`, `/bff/provision`) report a CROSS-LANE DISAGREEMENT that the
    real gateways do not have: the cluster's subtree route would be skipped and
    the probe would fall through to `/bff/**`. No probe in FIVE or HOLDBACK is a
    bare prefix today, so this is a correctness fix for the NEXT probe someone
    adds, not a change to any current verdict. The MATCHER_CASES block below
    pins the semantics so it cannot silently regress.
    """
    out, i = [], 0
    while i < len(pattern):
        if pattern.startswith("/**", i) and i + 3 == len(pattern):
            out.append("(?:/.*)?")
            i += 3
        elif pattern.startswith("**", i):
            out.append(".*")
            i += 2
        elif pattern[i] == "*":
            out.append("[^/]*")
            i += 1
        else:
            out.append(re.escape(pattern[i]))
            i += 1
    return re.compile("^" + "".join(out) + "$")


def first_match(routes, path):
    """SCG semantics: first route in DECLARED ORDER whose Path predicate holds.

    A route carrying a Host or Header predicate is SKIPPED rather than modelled:
    this simulator has no request to evaluate them against. That is safe only
    while no /bff route in either table gates on one, which is exactly what
    check 0 below asserts — and check 0 is scoped to /bff paths, because those
    are the only paths this guard reasons about. A Host-scoped /bff route added
    to one lane only would therefore be caught by check 0 (loudly), not silently
    mis-simulated here."""
    for r in routes:
        if r["host"] or r["header"]:
            continue
        if not r["paths"]:
            continue
        if any(ant_to_re(p.strip()).search(path) for p in r["paths"] if p.strip()):
            return r
    return None


def service_of(uri):
    """`http://hugmesh-user-bff-api:8080` and
    `https://hugmesh-user-bff-api.hugmesh-backend.svc.cluster.local:8080` are the
    SAME service expressed in the two lanes' DNS. Reduce both to the workload
    name so the comparison is about WHO SERVES IT, not about spelling."""
    host = re.sub(r"^[a-z]+://", "", str(uri)).split("/")[0]
    host = host.rsplit(":", 1)[0] if re.search(r":\d+$", host) else host
    return host.split(".")[0]


# ------------------------------------------------------------------ loaders ---
def load_compose_routes(path):
    doc = yaml.safe_load(open(path))
    raw = doc["spring"]["cloud"]["gateway"]["server"]["webflux"]["routes"]
    routes = []
    for r in raw:
        entry = {"id": r["id"], "uri": r["uri"], "paths": [], "host": None,
                 "header": None}
        for p in r.get("predicates", []):
            if p.startswith("Path="):
                entry["paths"] = p[len("Path="):].split(",")
            elif p.startswith("Host="):
                entry["host"] = p[len("Host="):]
            elif p.startswith("Header="):
                entry["header"] = p[len("Header="):]
        routes.append(entry)
    return routes


def load_cluster_routes(path):
    doc = yaml.safe_load(open(path))
    values = yaml.safe_load(doc["spec"]["source"]["helm"]["values"])
    routes = []
    for r in values["routes"]:
        routes.append({
            "id": r["id"],
            "uri": r["uri"],
            "paths": str(r["path"]).split(",") if r.get("path") else [],
            "host": r.get("host"),
            "header": r.get("header"),
        })
    return routes


# -------------------------------------------------------------- the probes ---
USER_BFF = "hugmesh-user-bff-api"
ADMIN_BFF = "hugmesh-admin-bff-api"

# The five paths of #366. `owner` is the service BOTH tables must resolve them to
# after decision 40. `handler` records whether that service actually has one.
# UPDATED 2026-09-18: all five now do — user-bff-api#20 (commit dc34c8b) added
# the last two, closing the "accepted 404" gap this table used to carry for
# them (stale claim flagged on hugmesh-generator#347 2026-09-18T07:21Z: this
# table still said has_handler=False and printed a 404-ACCEPTED line for both
# after #20 had already landed). `has_handler` is now ASSERTED below, not only
# printed: any entry with has_handler=False fails the run, because decision
# 40's five-path alignment no longer expects any 404s among them — a False
# value here is either a stale claim (fix this table) or a real regression (a
# handler was removed), and either way it must not go green silently.
FIVE = [
    ("/bff/me/namespaces",      USER_BFF, True,
     "admin-ui bff.service.ts myNamespaces()"),
    ("/bff/provision/matrix",   USER_BFF, True,
     "login-ui provisionServiceTokens(), every sign-in"),
    ("/bff/provision/mastodon", USER_BFF, True,
     "login-ui provisionServiceTokens(), every sign-in"),
    ("/bff/register/google",    USER_BFF, True,
     "LegacyPathParityController (hugmesh-user-bff-api#20, commit dc34c8b)"),
    ("/bff/register/discord",   USER_BFF, True,
     "LegacyPathParityController (hugmesh-user-bff-api#20, commit dc34c8b)"),
]

# Paths that must NOT move, and are the reason compose keeps EXACT entries rather
# than mirroring the cluster's subtrees. `compose_owner` is asserted; the cluster
# column is REPORTED (see the KNOWN DIVERGENCE note in the header).
HOLDBACK = [
    ("/bff/me/appeal", ADMIN_BFF,
     "admin-bff AccountAppealUserController — POST+GET, a curtailed principal's "
     "own ban appeal"),
    ("/bff/register/complete", ADMIN_BFF,
     "admin-bff AuthController#registerComplete — stage 2 of two-stage signup"),
]

# Compose must never carry these. They are the cluster's spelling.
FORBIDDEN_ON_COMPOSE = ["/bff/me/**", "/bff/register/**", "/bff/provision/**"]

# The two matching rules every verdict above rests on. Pinned here because a
# wrong matcher does not fail loudly — it silently answers the WRONG service and
# every assertion below inherits the error. Case 1 is the zero-segment rule the
# naive Ant translation gets wrong (see ant_to_re).
MATCHER_CASES = [
    ("/bff/me/**",   "/bff/me",                True),
    ("/bff/me/**",   "/bff/me/namespaces",     True),
    ("/bff/me/**",   "/bff/me/appeal/attach",  True),
    ("/bff/me/**",   "/bff/mex",               False),
    ("/bff/me/**",   "/bff/meow/x",            False),
    ("/bff/**",      "/bff/register/google",   True),
    ("/bff/register", "/bff/register/google",  False),
    ("/bff/*",       "/bff/register/google",   False),
    ("/bff/*",       "/bff/register",          True),
]


def check(compose, cluster, report=False):
    """Every assertion, over PARSED tables. Returns a list of failure strings so
    the negative controls can assert that a mutation produces at least one."""
    fails = []

    def note(msg):
        fails.append(msg)

    # 0. The matcher ignores Host/Header predicates; prove no /bff route has one.
    for name, routes in (("compose", compose), ("cluster", cluster)):
        for r in routes:
            if (r["host"] or r["header"]) and any(
                    p.strip().startswith("/bff") for p in r["paths"]):
                note(f"[{name}] route '{r['id']}' gates a /bff path on a "
                     f"Host/Header predicate — this matcher cannot model that")

    # 1 + 2. Alignment and parity for the five.
    for path, owner, has_handler, caller in FIVE:
        c = first_match(compose, path)
        k = first_match(cluster, path)
        if c is None:
            note(f"[compose] {path} matched NO route at all")
            continue
        if k is None:
            note(f"[cluster] {path} matched NO route at all")
            continue
        cs, ks = service_of(c["uri"]), service_of(k["uri"])
        if cs != ks:
            note(f"THE LANES DISAGREE on {path}: compose -> {cs} "
                 f"(route '{c['id']}'), cluster -> {ks} (route '{k['id']}'). "
                 f"decision 40 requires both to be {owner}.")
            continue
        if cs != owner:
            note(f"{path} resolves to {cs} on BOTH lanes; decision 40 requires "
                 f"{owner}. re-open decision 40 on hugmesh-generator#347 before "
                 f"widening it here.")
            continue
        # has_handler is ASSERTED, not merely printed (hugmesh-generator#347,
        # 2026-09-18T07:21Z — this table went stale claiming has_handler=False
        # for two paths whose user-bff handler had already landed, and nothing
        # here turned red over it). Decision 40's alignment no longer expects
        # ANY 404 among the five: every entry must claim has_handler=True, or
        # this table is either behind reality (fix the claim) or reporting a
        # real regression (a handler was removed) — either way it is a FAIL,
        # never a print-only FYI.
        if not has_handler:
            note(f"{path}: has_handler=False in the FIVE table (caller: "
                 f"{caller}) — decision 40's five-path alignment landed real "
                 f"user-bff handlers for all five (hugmesh-user-bff-api#15, "
                 f"#20); a False entry here is stale unless a handler has "
                 f"genuinely been removed. Verify against user-bff's source "
                 f"before either fixing this table or filing the regression.")
            continue
        if report:
            ok(f"{path} -> {owner} on BOTH lanes (serves it — {caller})")

    # 3. No widening on compose.
    compose_paths = [p.strip() for r in compose for p in r["paths"]]
    for pat in FORBIDDEN_ON_COMPOSE:
        if pat in compose_paths:
            note(f"[compose] carries the cluster subtree '{pat}'. The compose "
                 f"table keeps EXACT entries: a subtree here also moves "
                 f"/bff/me/appeal and /bff/register/complete off admin-bff, "
                 f"which decision 40 did not cover.")
        elif report:
            ok(f"[compose] does not carry the cluster subtree '{pat}'")

    # 4. Non-regression on compose for the paths a subtree would have eaten.
    for path, owner, why in HOLDBACK:
        c = first_match(compose, path)
        cs = service_of(c["uri"]) if c else None
        if cs != owner:
            note(f"[compose] {path} now resolves to {cs} (route "
                 f"'{c['id'] if c else 'NONE'}'); it must stay on {owner} — "
                 f"{why}")
        elif report:
            ok(f"[compose] {path} still -> {owner} ({why})")

    return fails


# ------------------------------------------------------------------- run it ---
compose = load_compose_routes(COMPOSE_FE)
cluster = load_cluster_routes(CLUSTER_FE)
print(f"parsed {len(compose)} compose routes, {len(cluster)} cluster routes")

print("\n== path-matcher semantics ==")
for pat, probe, want in MATCHER_CASES:
    got = bool(ant_to_re(pat).search(probe))
    if got == want:
        ok(f"'{pat}' {'matches' if want else 'does not match'} '{probe}'")
    else:
        bad(f"matcher: '{pat}' vs '{probe}' -> {got}, expected {want}. Every "
            f"lane verdict in this file is computed with this matcher, so a "
            f"wrong answer here is a wrong answer everywhere.")

if not compose or not cluster:
    print("FATAL: parsed ZERO routes out of a table — the shape changed.",
          file=sys.stderr)
    sys.exit(2)

print("\n== lane parity (the real tables) ==")
for msg in check(compose, cluster, report=True):
    bad(msg)

# The KNOWN DIVERGENCE, reported not asserted.
print("\n== reported, NOT asserted (hugmesh-generator#366, specs/cluster) ==")
for path, owner, why in HOLDBACK:
    k = first_match(cluster, path)
    ks = service_of(k["uri"]) if k else None
    if ks != owner:
        print(f"  NOTE [cluster] {path} -> {ks} (route "
              f"'{k['id'] if k else 'NONE'}') but is served by {owner} — that "
              f"path 404s on a cluster today. Fix belongs in "
              f"specs/cluster/apps/20-gateway-fe.yaml; this lane owns only the "
              f"compose table.")
    else:
        print(f"  NOTE [cluster] {path} -> {ks} (agrees with compose)")

# BARE PREFIXES — reported, not asserted. Only visible at all because ant_to_re
# gives trailing `/**` its real zero-segment semantics (see its docstring): the
# cluster's `/bff/provision/**` claims the bare `/bff/provision`, while compose,
# which carries exact paths, lets it fall to `/bff/**`. HARMLESS TODAY, measured:
# no BFF maps a bare prefix — user-bff origin/main c3d24c4 maps /bff/me,
# /bff/register (SsoAuthController) and /me/namespaces + /provision/{matrix,
# mastodon} (LegacyPathParityController), admin-bff origin/main maps
# /provision/matrix + /provision/mastodon (AuthController) — so a bare
# /bff/provision 404s whichever service answers it. Printed so that a future
# handler at a bare prefix is a decision somebody makes on purpose rather than a
# route-table accident.
for bare in ("/bff/me", "/bff/register", "/bff/provision"):
    c = first_match(compose, bare)
    k = first_match(cluster, bare)
    cs = service_of(c["uri"]) if c else None
    ks = service_of(k["uri"]) if k else None
    verdict = "agree" if cs == ks else "DIVERGE (no handler either side today)"
    print(f"  NOTE bare {bare}: compose -> {cs}, cluster -> {ks} — {verdict}")

# ------------------------------------------------------- negative controls ---
# Each mutation must produce at least one failure. A control that SURVIVES means
# this guard cannot see the defect it claims to catch.
print("\n== negative controls (mutations of the parsed tables) ==")


def drop_path(routes, pat):
    out = copy.deepcopy(routes)
    for r in out:
        r["paths"] = [p for p in r["paths"] if p.strip() != pat]
    return out


def repoint(routes, route_id, uri):
    out = copy.deepcopy(routes)
    for r in out:
        if r["id"] == route_id:
            r["uri"] = uri
    return out


def widen(routes, route_id, pat):
    out = copy.deepcopy(routes)
    for r in out:
        if r["id"] == route_id:
            r["paths"].append(pat)
    return out


def move_below_catchall(routes, route_id, catchall_id):
    out = copy.deepcopy(routes)
    moved = [r for r in out if r["id"] == route_id]
    rest = [r for r in out if r["id"] != route_id]
    idx = next(i for i, r in enumerate(rest) if r["id"] == catchall_id)
    return rest[:idx + 1] + moved + rest[idx + 1:]


CONTROLS = [
    ("compose drops /bff/me/namespaces (a partial revert)",
     lambda: (drop_path(compose, "/bff/me/namespaces"), cluster)),
    ("compose drops all five (the full revert to the #366 split)",
     lambda: (
         [dict(r, paths=[p for p in r["paths"]
                         if p.strip() not in [f[0] for f in FIVE]])
          for r in copy.deepcopy(compose)],
         cluster)),
    ("compose user-bff route is moved BELOW the /bff/** admin catch-all",
     lambda: (move_below_catchall(compose, "hugmesh-user-bff-api",
                                  "hugmesh-admin-bff-api"), cluster)),
    ("compose 'un-does' decision 40 by re-pointing user-bff back at admin-bff",
     lambda: (repoint(compose, "hugmesh-user-bff-api",
                      "http://hugmesh-admin-bff-api:8080"), cluster)),
    ("compose mirrors the cluster subtree /bff/me/** instead of exact paths",
     lambda: (widen(compose, "hugmesh-user-bff-api", "/bff/me/**"), cluster)),
    ("cluster re-points /bff/register/** back at admin-bff (the split, from "
     "the other side)",
     lambda: (compose, repoint(cluster, "hugmesh-user-bff-api-register",
                               "https://hugmesh-admin-bff-api.hugmesh-backend"
                               ".svc.cluster.local:8080"))),
]

caught = survived = 0
for label, mutate in CONTROLS:
    mc, mk = mutate()
    fails = check(mc, mk)
    if fails:
        caught += 1
        print(f"  CAUGHT  {label}")
        print(f"          -> {fails[0]}")
    else:
        survived += 1
        bad(f"CONTROL SURVIVED: {label} — this guard is blind to it")

print(f"\ncontrols: {caught} caught / {survived} survived")
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
