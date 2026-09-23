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
#   5. DECISION 60 (hugmesh-generator#347, operator 2026-09-18; generator half
#      hugmesh-generator#569) — APP_BFF_EXCHANGE_CACHE_TTL_MS is pinned to the
#      string "0" for admin-bff-api AND mod-bff-api on BOTH lanes: the compose
#      service blocks in tests/stack/compose.local.yaml and the cluster
#      Deployments under specs/cluster/manifests/{admin,mod}-bff-api/. Checked
#      by VALUE, not presence, and on the cluster side against what kustomize
#      RENDERS, not deployment.yaml alone (an offline scan of every patch the
#      kustomization applies, plus the rendered Deployment when kustomize or
#      kubectl is on PATH). This is the BFF mirror of the gateway's own
#      pin, which lives in tests/stack/test-gateway-auth-flag-parity.sh; the
#      DECISION 60 section below says why the BFF pin is asserted here and
#      not there.
#
# KNOWN DIVERGENCE, reported and NOT asserted: the cluster's `/bff/me/**` already
# swallows /bff/me/appeal, so that path 404s on a cluster today. It is recorded on
# hugmesh-generator#366; the fix belongs in specs/cluster/apps/20-gateway-fe.yaml,
# which this lane does not own. This guard PRINTS it every run rather than pinning
# it, so fixing it there does not turn this file red.
#
# NEGATIVE CONTROLS: every mutation in CONTROLS (route tables), TTL_CONTROLS
# (decision 60, by value) and KUSTOMIZE_CONTROLS (decision 60, as rendered)
# must trip its check, and each list must still contain every label in its
# REQUIRED_* set — a shrunk or emptied list is a FAIL, not a quieter pass. The
# decision-60 controls also carry the VERDICT they expect (NOT FOUND, ABSENT,
# not "0", ...): a control that trips the wrong branch is reported as caught
# with the wrong verdict and fails, so a diagnosis cannot rot back while the
# tally stays green. Controls run in-process on copies, or on a staged copy of
# a manifests directory under a temporary dir for the kustomize layers; the
# tree is never modified.
#
# Offline: reads the two fe route tables, tests/stack/compose.local.yaml and the
# two BFF Deployments with their kustomizations. No cluster, no docker, no
# network. kustomize/kubectl is OPTIONAL: with one on PATH the rendered
# Deployment is asserted too; without one the run prints NOTE ... NOT RUN and
# the patch scan stands alone. It never prints a PASS it did not earn.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import copy
import os
import re
import shutil
import subprocess
import sys
import tempfile

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

# The labels a control list must still contain, spelled out rather than
# derived from the list: deleting a tuple must not also delete it from the
# requirement. A count ("at least N") is blind to a control being deleted and
# another added, and an ok()-only check is blind to everything; this is the
# fail-closed shape of tests/stack/test-gateway-auth-flag-parity.sh's
# vacuity lines.
REQUIRED_ROUTE_CONTROLS = frozenset([
    "compose drops /bff/me/namespaces (a partial revert)",
    "compose drops all five (the full revert to the #366 split)",
    "compose user-bff route is moved BELOW the /bff/** admin catch-all",
    "compose 'un-does' decision 40 by re-pointing user-bff back at admin-bff",
    "compose mirrors the cluster subtree /bff/me/** instead of exact paths",
    "cluster re-points /bff/register/** back at admin-bff (the split, from "
    "the other side)",
])


def assert_controls_complete(name, controls, required, caught, survived, not_run=0):
    """One PASS when every required label is present and every control that ran
    was caught; otherwise a FAIL naming what is missing. Called after each
    control loop so an emptied or shrunk list can never pass quietly. not_run
    is for controls whose tool is absent on this host; they are named in the
    PASS line so nobody reads it as full coverage."""
    present = {c[0] for c in controls}
    missing = sorted(required - present)
    if missing:
        bad(f"{name}: REQUIRED control(s) missing from the list: {missing} — a "
            f"control that is gone cannot be exercised, and the guard is now "
            f"blind to what it caught")
    elif survived or caught + not_run != len(controls):
        bad(f"{name}: {caught} caught / {survived} survived / {not_run} not run of "
            f"{len(controls)} — every control that runs must be caught")
    else:
        ok(f"{name}: all {caught} controls that ran were caught, every required "
           f"label present" + (f" ({not_run} NOT RUN on this host — see the NOTE above)"
                               if not_run else ""))


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

assert_controls_complete("route-table controls", CONTROLS, REQUIRED_ROUTE_CONTROLS,
                         caught, survived)
print(f"\ncontrols: {caught} caught / {survived} survived")

# ---------------------------------------------------------------------------
# DECISION 60 — a second, orthogonal assertion kept in this same offline file.
# Decision 60 (hugmesh-generator#347, operator 2026-09-18; generator half
# hugmesh-generator#569) pins APP_BFF_EXCHANGE_CACHE_TTL_MS = "0" for
# admin-bff-api and mod-bff-api on BOTH lanes: the same posture #398/PR#406
# pinned for the gateway's own mirror of the cache
# (HUGMESH_GATEWAY_BFF_EXCHANGE_CACHE_TTL_MS), which
# tests/stack/test-gateway-auth-flag-parity.sh guards.
#
# WHY HERE AND NOT IN THAT SIBLING. The sibling resolves every value through the
# gateway image's application.yml, so it needs the org-private hugmesh-gateway
# checkout and FAILS as INCOMPLETE without one; that keeps it out of the GitHub
# pre-merge gate (it is in the ungated lane there, and GitLab-only otherwise).
# Its cluster mode also reads ArgoCD Application helm `extraEnv`, not the raw
# Deployments the BFFs are deployed from. This file needs nothing but the tree
# and is pre-merge gated on both hosts, and it already owns the four files the
# pin lives in, so the BFF pin is asserted here. The two guards name each other.
#
# CHECKED BY VALUE, NOT PRESENCE. A fixture with both lanes drifted to the SAME
# non-zero number is perfect parity and a reopened suspension-bypass window;
# the sibling records the same measurement for the gateway's key.
print("\n== decision 60: APP_BFF_EXCHANGE_CACHE_TTL_MS pinned to \"0\" on both lanes ==")

COMPOSE_STACK = f"{root}/tests/stack/compose.local.yaml"
CLUSTER_ADMIN_BFF = f"{root}/specs/cluster/manifests/admin-bff-api/deployment.yaml"
CLUSTER_MOD_BFF = f"{root}/specs/cluster/manifests/mod-bff-api/deployment.yaml"
TTL_KEY = "APP_BFF_EXCHANGE_CACHE_TTL_MS"


def compose_env(doc, service):
    """The service's environment mapping, or None when no service of that name
    is in the file. None is a distinct verdict: a renamed service must be
    reported as NOT FOUND, not as a missing pin on a service that exists."""
    svc = (doc.get("services") or {}).get(service)
    if svc is None:
        return None
    return dict(svc.get("environment") or {})


def cluster_env(doc, container_name):
    """The container's env as {name: value}, or None when the Deployment has no
    container of that name (same rule as compose_env: a rename is its own
    verdict, never a traceback and never ABSENT)."""
    spec = (((doc.get("spec") or {}).get("template") or {}).get("spec") or {})
    ctr = next((c for c in (spec.get("containers") or [])
                if isinstance(c, dict) and c.get("name") == container_name), None)
    if ctr is None:
        return None
    return {e["name"]: e.get("value") for e in (ctr.get("env") or [])}


def is_kubernetes_lane(label):
    """Every lane that is not a compose service is a Kubernetes container. The
    distinction matters for the TYPE of the value: EnvVar.value must be a
    string, so an unquoted `value: 0` is rejected by the API server and the
    ArgoCD sync fails, while compose coerces a bare 0 to "0" and runs."""
    return not label.startswith("compose ")


def check_ttl_pin(lanes):
    """{label: env_dict_or_None} -> list of failure strings, one per lane that
    is not pinned. Four verdicts, reported differently so a reader knows what
    to fix: the service/container was NOT FOUND (None), the key is ABSENT, the
    key is present with NO LITERAL VALUE (an empty `value:` or a `valueFrom:`
    reference), the value is NOT A STRING on a Kubernetes lane, or the value
    is PRESENT-BUT-WRONG."""
    fails = []
    for label, env in lanes.items():
        if env is None:
            fails.append(f"[{label}] service/container NOT FOUND under the name this "
                         f"guard looks for — renamed or removed. The pin cannot be "
                         f"judged until LIVE_LANES names it again; this is not a "
                         f"verdict on {TTL_KEY} itself")
            continue
        val = env.get(TTL_KEY)
        if TTL_KEY in env and val is None:
            fails.append(f"[{label}] {TTL_KEY} is present but carries NO LITERAL VALUE "
                         f"(an empty `value:` or a `valueFrom:` reference) — decision 60 "
                         f"pins the literal string \"0\"; an empty value hands Spring "
                         f"\"\" and a reference hands it whatever resolves at runtime, "
                         f"neither of which is a pinned zero window")
            continue
        if is_kubernetes_lane(label) and TTL_KEY in env and not isinstance(val, str):
            fails.append(f"[{label}] {TTL_KEY} is {val!r} ({type(val).__name__}), not the "
                         f"string \"0\" — Kubernetes EnvVar.value must be a string, so "
                         f"the API server rejects this Deployment and the ArgoCD sync "
                         f"fails; write value: \"0\" (quoted)")
            continue
        if val is None:
            fails.append(f"[{label}] {TTL_KEY} is ABSENT — decision 60 (2026-09-18) "
                         f"pins it to \"0\" explicitly; dropping the line hands the "
                         f"suspension-bypass window to whichever image tag is "
                         f"deployed (0 on both BFF mains since 2026-09-18 — "
                         f"admin-bff-api PR #74, mod-bff-api PR #20 — and 5000 = "
                         f"5 s on any older tag)")
        elif str(val) != "0":
            fails.append(f"[{label}] {TTL_KEY}={val!r}, not \"0\" — decision 60 "
                         f"(2026-09-18) pinned this to a zero suspension-bypass "
                         f"window on both lanes; re-open the decision on #347 "
                         f"before widening it here")
    return fails


compose_full = yaml.safe_load(open(COMPOSE_STACK))
admin_cluster_full = yaml.safe_load(open(CLUSTER_ADMIN_BFF))
mod_cluster_full = yaml.safe_load(open(CLUSTER_MOD_BFF))

# The four lanes under the pin, keyed by the label every verdict prints. Adding
# a lane is one row here plus a control below.
LIVE_LANES = {
    "compose admin-bff-api": compose_env(compose_full, "hugmesh-admin-bff-api"),
    "compose mod-bff-api":   compose_env(compose_full, "hugmesh-mod-bff-api"),
    "cluster admin-bff-api": cluster_env(admin_cluster_full, "hugmesh-admin-bff-api"),
    "cluster mod-bff-api":   cluster_env(mod_cluster_full, "hugmesh-mod-bff-api"),
}

ttl_fails = check_ttl_pin(LIVE_LANES)
if ttl_fails:
    for msg in ttl_fails:
        bad(msg)
else:
    ok(f"{TTL_KEY} pinned to \"0\" on all {len(LIVE_LANES)} lanes "
       f"({', '.join(LIVE_LANES)})")


def with_lanes(changes):
    """The live lanes with the named ones replaced — a COPY; the live dicts and
    the files on disk are never touched."""
    unknown = set(changes) - set(LIVE_LANES)
    assert not unknown, f"control names a lane that does not exist: {unknown}"
    return {**LIVE_LANES, **changes}


# Both pass a NOT FOUND lane (None) through unchanged: the live check has
# already failed that lane, and a control over it must not turn into a
# traceback that hides the tally.
def without_key(env):
    return None if env is None else {k: v for k, v in env.items() if k != TTL_KEY}


def with_value(env, value):
    return None if env is None else {**env, TTL_KEY: value}


# Negative controls: (label, expected verdict substring, mutation). Each
# mutation must produce at least one failure AND that failure must carry the
# expected verdict — "some failure" would let the NOT FOUND branch rot back
# into ABSENT (finding 4's misdiagnosis) while every control still read CAUGHT.
TTL_CONTROLS = [
    ("compose admin-bff-api drops the pin", "is ABSENT",
     lambda: with_lanes({"compose admin-bff-api": without_key(LIVE_LANES["compose admin-bff-api"])})),
    ("compose mod-bff-api set to 5000 (the pre-2026-09-18 image default)", "not \"0\"",
     lambda: with_lanes({"compose mod-bff-api": with_value(LIVE_LANES["compose mod-bff-api"], "5000")})),
    ("cluster admin-bff-api drops the pin", "is ABSENT",
     lambda: with_lanes({"cluster admin-bff-api": without_key(LIVE_LANES["cluster admin-bff-api"])})),
    ("cluster mod-bff-api set to 5000 (the pre-2026-09-18 image default)", "not \"0\"",
     lambda: with_lanes({"cluster mod-bff-api": with_value(LIVE_LANES["cluster mod-bff-api"], "5000")})),
    ("BOTH lanes drift to the SAME non-zero value (parity alone would miss this)", "not \"0\"",
     lambda: with_lanes({"compose admin-bff-api": with_value(LIVE_LANES["compose admin-bff-api"], "5000"),
                         "cluster admin-bff-api": with_value(LIVE_LANES["cluster admin-bff-api"], "5000")})),
    # An unquoted 0 on a Kubernetes lane parses as int 0 and str(0) == "0"; the
    # API server rejects it, so the guard must too.
    ("cluster admin-bff-api tidies value: \"0\" to an unquoted int 0 (API rejects it)", "not the string",
     lambda: with_lanes({"cluster admin-bff-api": with_value(LIVE_LANES["cluster admin-bff-api"], 0)})),
    # A valueFrom reference (or an empty value:) parses as None with the key present.
    ("cluster mod-bff-api pin becomes a valueFrom reference (no literal value)", "NO LITERAL VALUE",
     lambda: with_lanes({"cluster mod-bff-api": with_value(LIVE_LANES["cluster mod-bff-api"], None)})),
    # A rename is reported as NOT FOUND, never as ABSENT and never as a traceback.
    ("compose service renamed (compose_env finds nothing)", "NOT FOUND",
     lambda: with_lanes({"compose mod-bff-api": compose_env(compose_full, "no such service (control)")})),
    ("cluster container renamed (cluster_env finds nothing)", "NOT FOUND",
     lambda: with_lanes({"cluster mod-bff-api": cluster_env(mod_cluster_full, "no such container (control)")})),
]

# Spelled out rather than derived from TTL_CONTROLS: deleting a tuple from the
# list must not also delete it from the requirement.
REQUIRED_TTL_CONTROLS = frozenset([
    "compose admin-bff-api drops the pin",
    "compose mod-bff-api set to 5000 (the pre-2026-09-18 image default)",
    "cluster admin-bff-api drops the pin",
    "cluster mod-bff-api set to 5000 (the pre-2026-09-18 image default)",
    "BOTH lanes drift to the SAME non-zero value (parity alone would miss this)",
    "cluster admin-bff-api tidies value: \"0\" to an unquoted int 0 (API rejects it)",
    "cluster mod-bff-api pin becomes a valueFrom reference (no literal value)",
    "compose service renamed (compose_env finds nothing)",
    "cluster container renamed (cluster_env finds nothing)",
])

def judge_control(label, expect, mfails):
    """True when the control was caught WITH the expected verdict. A control
    that produced no failure, or a failure of the wrong kind, is reported as a
    FAIL either way; the second case is what keeps a diagnosis honest."""
    if not mfails:
        bad(f"CONTROL SURVIVED: {label} — this guard is blind to it")
        return False
    if not any(expect in m for m in mfails):
        bad(f"CONTROL CAUGHT WITH THE WRONG VERDICT: {label} — expected {expect!r} in "
            f"the failure, got: {mfails[0]}")
        return False
    print(f"  CAUGHT  {label}")
    print(f"          -> {mfails[0]}")
    return True


ttl_caught = ttl_survived = 0
for label, expect, mutate in TTL_CONTROLS:
    if judge_control(label, expect, check_ttl_pin(mutate())):
        ttl_caught += 1
    else:
        ttl_survived += 1

# Vacuity, fail-closed: the live lanes produced zero failures (asserted via
# ttl_fails above), every REQUIRED label is still in the list and every control
# was caught. An emptied or shrunk TTL_CONTROLS is a FAIL, not a missing PASS.
assert_controls_complete("decision 60 controls", TTL_CONTROLS, REQUIRED_TTL_CONTROLS,
                         ttl_caught, ttl_survived)

print(f"\ndecision 60 controls: {ttl_caught} caught / {ttl_survived} survived")

# ---------------------------------------------------------------------------
# THE CLUSTER LANE IS WHAT KUSTOMIZE RENDERS. ArgoCD builds each manifests/
# directory through its kustomization.yaml and applies the RESULT; the pin
# read from deployment.yaml above is only the input. Both kustomizations
# already carry patches (a JSON6902 op each, and admin-bff's strategic-merge
# workload-console-patch.yaml, which edits containers[].env), so a patch that
# sets APP_BFF_EXCHANGE_CACHE_TTL_MS to another value — or drops the env list,
# or the whole container — would deploy that while deployment.yaml still says
# "0" and the check above stays green.
#
# Two layers, because the CI jobs that run this suite (python:3-slim) have no
# kubectl, so layer (a) is the only layer that gates a merge:
#   (a) ALWAYS: an offline scan of every patch a kustomization can apply.
#       FAIL if any patch text names the key; if any JSON6902 op's `path` or
#       `from` is ON THE CHAIN /spec/template/spec/containers/<n>/env — the
#       env itself or anything under it (an index-based op rewrites the value
#       without naming it) and every ANCESTOR of it (a `replace` of a whole
#       container, of the containers list or of the pod spec, and a `move` of
#       env elsewhere, all drop the pin without naming it); if a
#       strategic-merge patch carries a `$patch` / `$retainKeys` /
#       `$setElementOrder` / `$deleteFromPrimitiveList` directive, or sets any
#       node on that chain to null (`env: null` and `containers: null` both
#       render WITHOUT the pin — measured with kubectl kustomize v5.8.1; an
#       empty `env: []` is a no-op); if a patch file the kustomization names
#       is missing; or if the kustomization uses a field this scan cannot see
#       through (replacements, components, transformers, generators — none is
#       used today; using one is a decision, made by extending this scan).
#   (b) WHEN kustomize OR kubectl IS ON PATH: the directory is rendered and
#       the rendered Deployment's container env is put through check_ttl_pin
#       like any other lane; a lane that produces no rendered verdict is a
#       FAIL, never a missing PASS. Without a binary the run prints a NOTE and
#       (a) stands alone; it never prints a PASS it did not earn.
print("\n== decision 60: the cluster lane as kustomize RENDERS it ==")

KUSTOMIZE_LANES = {
    # label -> (kustomization dir, Deployment name, container name)
    "cluster admin-bff-api": (os.path.dirname(CLUSTER_ADMIN_BFF), "hugmesh-admin-bff-api",
                              "hugmesh-admin-bff-api"),
    "cluster mod-bff-api": (os.path.dirname(CLUSTER_MOD_BFF), "hugmesh-mod-bff-api",
                            "hugmesh-mod-bff-api"),
}
OPAQUE_KUSTOMIZE_FIELDS = ("replacements", "components", "transformers", "generators")
# The chain from the Deployment root down to a container's env; None marks the
# list index. An op on ANY node of this chain, or under its last node, can
# drop or rewrite the pin without naming it.
ENV_CHAIN = ("spec", "template", "spec", "containers", None, "env")
SMP_DIRECTIVE = re.compile(r"\$(patch|retainKeys|setElementOrder|deleteFromPrimitiveList)\b")


def kustomize_patch_texts(kdir):
    """(kustomization dict, [(where, text)], [(where, missing file)]) for every
    patch the kustomization can apply: inline `patches[].patch`,
    `patches[].path` files, and the legacy patchesStrategicMerge /
    patchesJson6902 forms. A named file that does not exist is returned in the
    third list so the scan can FAIL on it instead of tracing back."""
    kdoc = yaml.safe_load(open(os.path.join(kdir, "kustomization.yaml"))) or {}
    out, missing = [], []

    def add_file(where, rel):
        full = os.path.join(kdir, rel)
        if os.path.isfile(full):
            out.append((where, open(full).read()))
        else:
            missing.append((where, rel))

    for i, p in enumerate(kdoc.get("patches") or []):
        if isinstance(p, dict):
            if p.get("patch") is not None:
                out.append((f"patches[{i}].patch (inline)", str(p["patch"])))
            if p.get("path"):
                add_file(f"patches[{i}].path={p['path']}", p["path"])
        elif isinstance(p, str):
            add_file(f"patches[{i}]={p}", p)
    for i, p in enumerate(kdoc.get("patchesStrategicMerge") or []):
        if isinstance(p, str) and (os.path.isfile(os.path.join(kdir, p))
                                   or re.fullmatch(r"[\w./-]+\.ya?ml", p)):
            add_file(f"patchesStrategicMerge[{i}]={p}", p)
        else:
            out.append((f"patchesStrategicMerge[{i}] (inline)", str(p)))
    for i, p in enumerate(kdoc.get("patchesJson6902") or []):
        if isinstance(p, dict):
            if p.get("path"):
                add_file(f"patchesJson6902[{i}].path={p['path']}", p["path"])
            if p.get("patch") is not None:
                out.append((f"patchesJson6902[{i}].patch (inline)", str(p["patch"])))
    return kdoc, out, missing


def on_env_chain(pointer):
    """True when a JSON pointer is a container's env, anything under it, or
    any ANCESTOR of it: "" (the document root), /spec, /spec/template,
    /spec/template/spec, /spec/template/spec/containers,
    /spec/template/spec/containers/N, .../N/env, .../N/env/22/value. Compared
    segment by segment — a plain string-prefix test would flag the live
    /spec/template/spec/imagePullSecrets op, which shares three segments and
    cannot touch env. A container index must be digits: `containers/-` (append
    a sidecar) is not on the chain."""
    if not isinstance(pointer, str):
        return False
    if pointer == "":
        return True
    if not pointer.startswith("/"):
        return False
    segs = pointer[1:].split("/")
    for seg, want in zip(segs, ENV_CHAIN):
        if want is None:
            if not seg.isdigit():
                return False
        elif seg != want:
            return False
    return True


def json6902_chain_ops(text):
    """'<op> path=<p>' / '<op> from=<p>' for every op in a text that parses as
    a JSON6902 op list whose path or from is on the env chain; [] for
    strategic-merge patches and anything else."""
    try:
        ops = yaml.safe_load(text)
    except yaml.YAMLError:
        return []
    if not isinstance(ops, list):
        return []
    hits = []
    for op in ops:
        if not isinstance(op, dict):
            continue
        for field in ("path", "from"):
            if field in op and on_env_chain(op.get(field)):
                hits.append(f"{op.get('op')} {field}={op.get(field)}")
    return hits


def strategic_merge_hazards(text):
    """Hazards in a text read as a strategic-merge patch: a `$...` directive
    anywhere (a `$patch: replace|delete` swaps or drops the element it sits
    in), or a null on the spec.template.spec.containers[].env chain (null in
    a strategic merge DELETES the node). [] for a JSON6902 op list."""
    hazards = [f"directive ${d}" for d in sorted(set(SMP_DIRECTIVE.findall(text)))]
    try:
        doc = yaml.safe_load(text)
    except yaml.YAMLError:
        return hazards
    if not isinstance(doc, dict):
        return hazards
    node, walked = doc, []
    for key in ("spec", "template", "spec", "containers"):
        if not isinstance(node, dict) or key not in node:
            return hazards
        walked.append(key)
        node = node[key]
        if node is None:
            hazards.append(f"{'.'.join(walked)}: null (deletes it)")
            return hazards
    if isinstance(node, list):
        for c in node:
            if isinstance(c, dict) and "env" in c and c["env"] is None:
                hazards.append(f"containers[name={c.get('name')}].env: null (deletes it)")
    return hazards


def check_kustomize_patches(label, kdir):
    """Failure strings for layer (a): the offline scan of kustomization.yaml."""
    kdoc, texts, missing = kustomize_patch_texts(kdir)
    kfile = os.path.join(kdir, "kustomization.yaml")
    fails = []
    for where, rel in missing:
        fails.append(f"[{label}] {kfile} {where} names a patch file that does not exist "
                     f"({rel}) — kustomize itself refuses this tree, and this scan cannot "
                     f"read what is not there")
    for where, text in texts:
        if TTL_KEY in text:
            fails.append(f"[{label}] {kfile} {where} names {TTL_KEY} — a patch is what "
                         f"ArgoCD applies on top of deployment.yaml, so the rendered "
                         f"value can differ from the file the check above reads. The "
                         f"pin lives in deployment.yaml only; remove the patch, or "
                         f"re-open decision 60 on #347")
        for hit in json6902_chain_ops(text):
            fails.append(f"[{label}] {kfile} {where} has a JSON6902 op on the "
                         f"containers[].env chain ({hit}) — an op under env rewrites "
                         f"{TTL_KEY} by index without naming it, and a replace/move of "
                         f"env, of a container, of the containers list or of the pod "
                         f"spec drops the pin without naming it; env is owned by "
                         f"deployment.yaml, edit it there")
        for hz in strategic_merge_hazards(text):
            fails.append(f"[{label}] {kfile} {where} strategic-merge {hz} — a directive "
                         f"or a null on the spec.template.spec.containers[].env chain "
                         f"replaces or deletes the list that carries {TTL_KEY} without "
                         f"naming it (env: null and containers: null both render WITHOUT "
                         f"the pin); env is owned by deployment.yaml, edit it there")
    for field in OPAQUE_KUSTOMIZE_FIELDS:
        if kdoc.get(field):
            fails.append(f"[{label}] {kfile} uses `{field}`, which can rewrite the "
                         f"rendered Deployment without naming {TTL_KEY} in any text this "
                         f"scan reads; extend the scan before using it")
    return fails


def kustomize_cmd():
    if shutil.which("kustomize"):
        return ["kustomize", "build"]
    if shutil.which("kubectl"):
        return ["kubectl", "kustomize"]
    return None


def rendered_container_env(cmd, kdir, deploy_name, container_name):
    """Layer (b): the container env of the Deployment kustomize renders, or None
    when no Deployment/container of those names is rendered. Raises on a
    render error so it lands as a FAIL, never as a quiet None."""
    res = subprocess.run(cmd + [kdir], capture_output=True, text=True)
    if res.returncode != 0:
        raise RuntimeError(f"{' '.join(cmd)} {kdir}: rc={res.returncode}: "
                           f"{res.stderr.strip()[:300]}")
    for doc in yaml.safe_load_all(res.stdout):
        if (isinstance(doc, dict) and doc.get("kind") == "Deployment"
                and (doc.get("metadata") or {}).get("name") == deploy_name):
            return cluster_env(doc, container_name)
    return None


KCMD = kustomize_cmd()

# Layer (a) on the live tree.
for label, (kdir, _deploy, _ctr) in KUSTOMIZE_LANES.items():
    scan_fails = check_kustomize_patches(label, kdir)
    for msg in scan_fails:
        bad(msg)
    if not scan_fails:
        ok(f"[{label}] no kustomize patch names {TTL_KEY}, touches the containers[].env "
           f"chain, carries a strategic-merge directive or null, or names a missing "
           f"file, and no opaque field is used ({kdir}/kustomization.yaml)")

# Layer (b) on the live tree.
if KCMD is None:
    print(f"  NOTE render assertion NOT RUN: neither kustomize nor kubectl is on PATH "
          f"(the python:3-slim CI jobs that run this suite have neither). The patch "
          f"scan above is the assertion that stands on this host; a host with either "
          f"binary also asserts the rendered Deployment.")
else:
    rendered, render_errors = {}, set()
    for label, (kdir, deploy, ctr) in KUSTOMIZE_LANES.items():
        try:
            rendered[f"rendered {label}"] = rendered_container_env(KCMD, kdir, deploy, ctr)
        except Exception as e:                                    # noqa: BLE001
            render_errors.add(label)
            bad(f"[{label}] kustomize render failed: {type(e).__name__}: {e}")
    # Every lane must reach a verdict: a lane that neither rendered nor
    # errored is a render assertion that silently went away, not a PASS.
    unrendered = [label for label in KUSTOMIZE_LANES
                  if label not in render_errors and f"rendered {label}" not in rendered]
    for label in unrendered:
        bad(f"[{label}] kustomize render produced NO verdict although {' '.join(KCMD)} "
            f"is on PATH — the render assertion did not run for this lane")
    render_fails = check_ttl_pin(rendered)
    for msg in render_fails:
        bad(msg)
    if rendered and not render_fails and not render_errors and not unrendered:
        ok(f"{TTL_KEY} is the string \"0\" in the kustomize-RENDERED Deployment for "
           f"{', '.join(rendered)} (via {' '.join(KCMD)})")


# Negative controls for both layers, staged as COPIES of a manifests directory
# under a temporary dir (TMPDIR honoured); the tree is never modified.
def staged_dir(label, mutation):
    """A copy of the lane's kustomization directory with one mutation applied
    to its kustomization.yaml: kind "strategic" writes the text to a file and
    appends {"path": file} to `patches:`; "json6902" appends {"patch": text,
    "target": {...}}; "missing" appends a path to a file that does not exist;
    "field" sets a top-level kustomization key. Returns (tmp_root, copy_dir);
    the caller removes tmp_root."""
    kdir, deploy, _ctr = KUSTOMIZE_LANES[label]
    tmp = tempfile.mkdtemp(prefix="ttl-pin-kustomize-")
    dst = os.path.join(tmp, os.path.basename(kdir))
    shutil.copytree(kdir, dst)
    kpath = os.path.join(dst, "kustomization.yaml")
    kdoc = yaml.safe_load(open(kpath))
    kind = mutation["kind"]
    if kind == "strategic":
        with open(os.path.join(dst, "ttl-control-patch.yaml"), "w") as f:
            f.write(mutation["text"])
        kdoc.setdefault("patches", []).append({"path": "ttl-control-patch.yaml"})
    elif kind == "json6902":
        kdoc.setdefault("patches", []).append(
            {"patch": mutation["text"],
             "target": {"kind": "Deployment", "name": deploy}})
    elif kind == "missing":
        kdoc.setdefault("patches", []).append({"path": mutation["path"]})
    elif kind == "field":
        kdoc[mutation["field"]] = mutation["value"]
    else:                                                          # pragma: no cover
        raise ValueError(f"unknown staged mutation kind {kind!r}")
    with open(kpath, "w") as f:
        yaml.safe_dump(kdoc, f)
    return tmp, dst


def live_container(label):
    """(container index, deep copy of the container dict) from the lane's
    deployment.yaml, for controls that re-list a container without the pin."""
    _kdir, _deploy, ctr = KUSTOMIZE_LANES[label]
    doc = yaml.safe_load(open(KUSTOMIZE_LANES[label][0] + "/deployment.yaml"))
    spec = doc["spec"]["template"]["spec"]
    ci = next(i for i, c in enumerate(spec["containers"]) if c["name"] == ctr)
    return ci, copy.deepcopy(spec["containers"][ci])


def container_minus_pin(label):
    ci, c = live_container(label)
    c["env"] = [e for e in c["env"] if e["name"] != TTL_KEY]
    return ci, c


def strategic_patch_5000(label):
    _kdir, deploy, ctr = KUSTOMIZE_LANES[label]
    return {"kind": "strategic", "text": (
        "apiVersion: apps/v1\nkind: Deployment\n"
        f"metadata: {{name: {deploy}, namespace: hugmesh-backend}}\n"
        "spec:\n  template:\n    spec:\n      containers:\n"
        f"        - name: {ctr}\n          env:\n"
        f"            - {{name: {TTL_KEY}, value: \"5000\"}}\n")}


def json6902_by_index_5000(label):
    """Rewrites the pin's value by its INDEX in env — the text never contains
    the key name, which is exactly what a plain grep would miss."""
    ci, c = live_container(label)
    ei = next(i for i, e in enumerate(c["env"]) if e["name"] == TTL_KEY)
    return {"kind": "json6902", "text": (
        f"- op: replace\n  path: /spec/template/spec/containers/{ci}/env/{ei}/value\n"
        f"  value: \"5000\"\n")}


def json6902_replace_container(label):
    """Replaces the WHOLE container with a copy that lacks the pin: no key
    name, no op under env — only an ancestor path."""
    ci, c = container_minus_pin(label)
    return {"kind": "json6902", "text": yaml.safe_dump(
        [{"op": "replace", "path": f"/spec/template/spec/containers/{ci}", "value": c}])}


def json6902_replace_containers_list(label):
    ci, c = container_minus_pin(label)
    return {"kind": "json6902", "text": yaml.safe_dump(
        [{"op": "replace", "path": "/spec/template/spec/containers", "value": [c]}])}


def json6902_move_env_to_args(label):
    """A `move` whose `path` is nowhere near env — only its `from` is."""
    ci, _c = live_container(label)
    return {"kind": "json6902", "text": (
        f"- op: move\n  from: /spec/template/spec/containers/{ci}/env\n"
        f"  path: /spec/template/spec/containers/{ci}/args\n")}


def strategic_patch_directive_replace(label):
    """A `$patch: replace` element at the head of the container's env list,
    re-listing every entry but the pin: the key is never named, no null, no
    JSON6902 op. Renders WITHOUT the pin (measured, kubectl kustomize v5.8.1);
    the same directive on the container element itself is merged, not
    replaced, by kustomize, so the env-level form is the one staged here."""
    _kdir, deploy, _ctr = KUSTOMIZE_LANES[label]
    _ci, c = container_minus_pin(label)
    body = {"apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {"name": deploy, "namespace": "hugmesh-backend"},
            "spec": {"template": {"spec": {"containers": [
                {"name": c["name"], "env": [{"$patch": "replace"}] + c["env"]}]}}}}
    return {"kind": "strategic", "text": yaml.safe_dump(body)}


def strategic_patch_null(label, node):
    """`env: null` under the container, or `containers: null` under the pod
    spec — both delete the list in a strategic merge (measured)."""
    _kdir, deploy, ctr = KUSTOMIZE_LANES[label]
    if node == "env":
        pod_spec = {"containers": [{"name": ctr, "env": None}]}
    else:
        pod_spec = {"containers": None}
    body = {"apiVersion": "apps/v1", "kind": "Deployment",
            "metadata": {"name": deploy, "namespace": "hugmesh-backend"},
            "spec": {"template": {"spec": pod_spec}}}
    return {"kind": "strategic", "text": yaml.safe_dump(body)}


def scan_control(label, mutation):
    tmp, dst = staged_dir(label, mutation)
    try:
        return check_kustomize_patches(label, dst)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def render_control(label, mutation):
    _kdir, deploy, ctr = KUSTOMIZE_LANES[label]
    tmp, dst = staged_dir(label, mutation)
    try:
        env = rendered_container_env(KCMD, dst, deploy, ctr)
        return check_ttl_pin({f"rendered {label}": env})
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


ADMIN, MOD = "cluster admin-bff-api", "cluster mod-bff-api"
# (label, needs_render, expected verdict substring, fn) — fn returns the
# failure strings the mutation must produce, and one of them must carry the
# expected verdict. Scan controls run on every host; render controls need a
# binary and are reported as NOT RUN without one. The scan controls are the
# ones that gate a merge, so every bypass class the scan claims to close has
# one here: name, index-op, ancestor-op (container, list, move), directive,
# null (env, containers), missing file, opaque field.
KUSTOMIZE_CONTROLS = [
    ("scan: a strategic-merge patch sets the admin-bff pin to 5000", False,
     f"names {TTL_KEY}",
     lambda: scan_control(ADMIN, strategic_patch_5000(ADMIN))),
    ("scan: an inline JSON6902 op rewrites the mod-bff pin by index, never naming the key", False,
     "JSON6902 op on the containers[].env chain",
     lambda: scan_control(MOD, json6902_by_index_5000(MOD))),
    ("scan: a JSON6902 replace of the WHOLE mod-bff container drops the pin (ancestor path)", False,
     "JSON6902 op on the containers[].env chain",
     lambda: scan_control(MOD, json6902_replace_container(MOD))),
    ("scan: a JSON6902 replace of the admin-bff containers LIST drops the pin (ancestor path)", False,
     "JSON6902 op on the containers[].env chain",
     lambda: scan_control(ADMIN, json6902_replace_containers_list(ADMIN))),
    ("scan: a JSON6902 move of mod-bff env to args (only `from` is on the chain)", False,
     "JSON6902 op on the containers[].env chain",
     lambda: scan_control(MOD, json6902_move_env_to_args(MOD))),
    ("scan: a strategic-merge `$patch: replace` re-lists the mod-bff env without the pin", False,
     "strategic-merge directive $patch",
     lambda: scan_control(MOD, strategic_patch_directive_replace(MOD))),
    ("scan: a strategic-merge `env: null` deletes the admin-bff env list", False,
     "env: null",
     lambda: scan_control(ADMIN, strategic_patch_null(ADMIN, "env"))),
    ("scan: a strategic-merge `containers: null` deletes the mod-bff containers list", False,
     "containers: null",
     lambda: scan_control(MOD, strategic_patch_null(MOD, "containers"))),
    ("scan: the admin-bff kustomization names a patch file that does not exist", False,
     "does not exist",
     lambda: scan_control(ADMIN, {"kind": "missing", "path": "no-such-patch.yaml"})),
    ("scan: the mod-bff kustomization uses `replacements` (an opaque field)", False,
     "uses `replacements`",
     lambda: scan_control(MOD, {"kind": "field", "field": "replacements", "value": [
         {"source": {"kind": "Service", "name": "hugmesh-mod-bff-api", "fieldPath": "metadata.name"},
          "targets": [{"select": {"kind": "Deployment"},
                       "fieldPaths": ["spec.template.spec.containers.0.env.0.value"]}]}]})),
    ("render: the rendered admin-bff Deployment carries 5000 from a strategic-merge patch", True,
     "not \"0\"",
     lambda: render_control(ADMIN, strategic_patch_5000(ADMIN))),
    ("render: the rendered mod-bff Deployment carries 5000 from an index-only JSON6902 op", True,
     "not \"0\"",
     lambda: render_control(MOD, json6902_by_index_5000(MOD))),
    ("render: the rendered mod-bff container lacks the pin after a whole-container replace", True,
     "is ABSENT",
     lambda: render_control(MOD, json6902_replace_container(MOD))),
    ("render: the rendered mod-bff env lacks the pin after an env-level `$patch: replace`", True,
     "is ABSENT",
     lambda: render_control(MOD, strategic_patch_directive_replace(MOD))),
    ("render: the rendered admin-bff container lacks env after `env: null`", True,
     "is ABSENT",
     lambda: render_control(ADMIN, strategic_patch_null(ADMIN, "env"))),
    ("render: the rendered mod-bff Deployment has no container after `containers: null`", True,
     "NOT FOUND",
     lambda: render_control(MOD, strategic_patch_null(MOD, "containers"))),
]
REQUIRED_KUSTOMIZE_CONTROLS = frozenset([
    "scan: a strategic-merge patch sets the admin-bff pin to 5000",
    "scan: an inline JSON6902 op rewrites the mod-bff pin by index, never naming the key",
    "scan: a JSON6902 replace of the WHOLE mod-bff container drops the pin (ancestor path)",
    "scan: a JSON6902 replace of the admin-bff containers LIST drops the pin (ancestor path)",
    "scan: a JSON6902 move of mod-bff env to args (only `from` is on the chain)",
    "scan: a strategic-merge `$patch: replace` re-lists the mod-bff env without the pin",
    "scan: a strategic-merge `env: null` deletes the admin-bff env list",
    "scan: a strategic-merge `containers: null` deletes the mod-bff containers list",
    "scan: the admin-bff kustomization names a patch file that does not exist",
    "scan: the mod-bff kustomization uses `replacements` (an opaque field)",
    "render: the rendered admin-bff Deployment carries 5000 from a strategic-merge patch",
    "render: the rendered mod-bff Deployment carries 5000 from an index-only JSON6902 op",
    "render: the rendered mod-bff container lacks the pin after a whole-container replace",
    "render: the rendered mod-bff env lacks the pin after an env-level `$patch: replace`",
    "render: the rendered admin-bff container lacks env after `env: null`",
    "render: the rendered mod-bff Deployment has no container after `containers: null`",
])

k_caught = k_survived = k_not_run = 0
for label, needs_render, expect, mutate in KUSTOMIZE_CONTROLS:
    if needs_render and KCMD is None:
        k_not_run += 1
        print(f"  NOT RUN {label} (no kustomize/kubectl on this host)")
        continue
    try:
        kfails = mutate()
    except Exception as e:                                        # noqa: BLE001
        # A control that cannot even be BUILT (e.g. the live container was
        # renamed, so the constructor finds nothing) is its own diagnosis.
        k_survived += 1
        bad(f"CONTROL ERROR: {label} — the mutation raised {type(e).__name__}: {e!s} "
            f"(the control could not be built, so it proved nothing)")
        continue
    if judge_control(label, expect, kfails):
        k_caught += 1
    else:
        k_survived += 1

assert_controls_complete("kustomize controls", KUSTOMIZE_CONTROLS, REQUIRED_KUSTOMIZE_CONTROLS,
                         k_caught, k_survived, not_run=k_not_run)
print(f"\nkustomize controls: {k_caught} caught / {k_survived} survived / {k_not_run} not run")
print(f"{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
