#!/usr/bin/env bash
# test-deeplink-remote-coverage.sh — every in-shell `*-ui` remote route's own
# path must also be in the SPA deep-link fallback's Path list, on BOTH fe route
# tables, /login must never be, and the ordering that sends everything ELSE
# (remoteEntry.json, chunks, XHR — anything without Accept: text/html) to the
# remote itself must stay undisturbed.
#
# THE BUG THIS EXISTS TO KILL
# ---------------------------
# hugmesh-generator#381. `remote-deeplink-to-host-shell` (the first route in
# both fe-gateway tables) sends HTML NAVIGATIONS for a fixed list of prefixes to
# the Angular host shell, so a refresh/bookmark/shared link resolves the deep
# link instead of falling into a federated remote's own standalone
# index.html (no shell chrome, no menu, no session UI — the exact failure the
# operator originally reported for the social remotes on 2026-08-14). Every
# remote below that route in EITHER table that is mounted inside the shell
# (i.e. every `<slug>-ui` route other than login-ui, which is the deliberately
# EXCLUDED standalone door) must have its own path in that list too, or a
# refresh on its prefix falls through this route and lands on the remote's own
# nginx SPA fallback instead. /admin, /mod and /user were exactly that gap: the
# routes existed (unlike an earlier version of this comment's false claim), so
# they were NOT immune, and a live probe of /user/profile was measured serving
# user-ui's own index.html rather than the shell. This guard is the mechanical
# form of "the next remote added cannot regress this" — it does not hardcode
# the prefix list, it DERIVES it from each table's own `*-ui` route entries, so
# a future remote (e.g. a hypothetical superadmin-ui) trips it automatically
# the moment its own route lands without a matching deep-link entry.
#
# WHAT IS ASSERTED (per table, independently — compose and the cluster twin
# specs/cluster/apps/20-gateway-fe.yaml can each carry a DIFFERENT set of `*-ui`
# routes today: wiki-ui/owncast-ui/tube-ui exist only on compose, a pre-existing
# gap tracked elsewhere and NOT this guard's concern)
#   [coverage]   every route in the table whose id ends in `-ui`, other than
#                `login-ui`, has EVERY one of its own Path predicate's
#                patterns present, byte-for-byte, in the deep-link route's own
#                Path list.
#   [login-excl] no pattern belonging to login-ui's own path (`/login/**`) ever
#                appears in the deep-link route's Path list — the standalone
#                login-ui must keep answering a direct GET itself.
#   [order]      a REAL Spring Cloud Gateway first-match-wins simulation, over
#                the WHOLE table, for each covered prefix: an HTML navigation
#                still resolves to the deep-link route (proves the deep-link
#                route still PRECEDES the remote's own route, not merely that
#                the path string is listed somewhere), and a request that does
#                not carry a matching `Accept: text/html` — including one with
#                NO Accept header at all — still resolves to the remote's own
#                route, exactly as before this change.
#   [self-present] the derivation is not vacuous: the coverage set actually
#                contains more than one id per table (else a parsing bug that
#                silently found zero `*-ui` routes would report clean).
#
# NEGATIVE CONTROLS: six mutations of the parsed tables must each trip the
# checks, including a synthesised BRAND NEW remote (proving the derivation
# really does generalise to "the next remote added" rather than only knowing
# about admin/mod/user by name) and moving the deep-link route itself AFTER
# the remotes it is meant to precede (proving [order] catches a positional
# regression, not just a missing string). All run in-process on copies; the
# files on disk are never modified by this script.
#
# Offline: reads two files. No cluster, no docker, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

python3 - "$ROOT" <<'PY'
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

DEEPLINK_ID = "remote-deeplink-to-host-shell"
EXCLUDED_UI_IDS = {"login-ui"}   # the standalone door — must stay OFF the list

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
    """Spring's Ant path matching: ** crosses /, * does not, and a TRAILING
    `/**` also matches zero segments (AntPathMatcher/PathPattern both do) —
    not exercised by the concrete probes below (each has a segment past the
    prefix) but kept correct rather than the naive translation, matching the
    lesson recorded in test-fe-bff-route-lane-parity.sh's MATCHER_CASES."""
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


def first_match(routes, path, accept):
    """SCG semantics: first route in DECLARED ORDER whose predicates all hold.
    `accept` is the request's Accept header value, or None to model a request
    that carries no Accept header at all (fails a Header predicate exactly like
    a non-matching value does — SCG's HeaderRoutePredicateFactory requires the
    header to be PRESENT). A route with no Path predicate (host-only, like
    vanity-subdomain) can never win here — this simulator only ever asks about
    apex-host requests, and a Host=*.<domain> route does not match the apex."""
    for r in routes:
        if not r["paths"]:
            continue
        if not any(ant_to_re(p).search(path) for p in r["paths"]):
            continue
        if r.get("header"):
            name, _, value_re = r["header"].partition(",")
            if name.strip().lower() != "accept":
                continue
            if accept is None or not re.search(value_re.strip(), accept):
                continue
        return r
    return None


# ------------------------------------------------------------------ loaders ---
def load_compose_routes(path):
    doc = yaml.safe_load(open(path))
    raw = doc["spring"]["cloud"]["gateway"]["server"]["webflux"]["routes"]
    routes = []
    for r in raw:
        paths, header = [], None
        for p in r.get("predicates", []):
            if p.startswith("Path="):
                paths = [s.strip() for s in p[len("Path="):].split(",") if s.strip()]
            elif p.startswith("Header="):
                header = p[len("Header="):]
        routes.append({"id": r["id"], "paths": paths, "header": header})
    return routes


def load_cluster_routes(path):
    doc = yaml.safe_load(open(path))
    values = yaml.safe_load(doc["spec"]["source"]["helm"]["values"])
    routes = []
    for r in values["routes"]:
        paths = [s.strip() for s in str(r["path"]).split(",") if s.strip()] if r.get("path") else []
        routes.append({"id": r["id"], "paths": paths, "header": r.get("header")})
    return routes


# -------------------------------------------------------------- the checks ---
def in_shell_ui_routes(routes):
    """Every route mounted in the shell whose OWN path the deep-link route must
    also carry — derived from the table itself, never hardcoded."""
    return [r for r in routes
            if r["id"] != DEEPLINK_ID and r["id"].endswith("-ui")
            and r["id"] not in EXCLUDED_UI_IDS]


def check_coverage(name, routes):
    """[coverage] + [login-excl] + [self-present]. Returns the failure count so
    negative controls can assert a mutation trips at least one."""
    local_fail = 0

    deeplink = next((r for r in routes if r["id"] == DEEPLINK_ID), None)
    if deeplink is None:
        bad(f"[{name}] no '{DEEPLINK_ID}' route at all")
        return 1
    deeplink_paths = set(deeplink["paths"])

    ui_routes = in_shell_ui_routes(routes)
    if len(ui_routes) < 2:
        bad(f"[{name}] only {len(ui_routes)} in-shell '*-ui' route(s) found — "
            f"the derivation looks broken (this table should have several)")
        local_fail += 1

    for r in ui_routes:
        missing = [p for p in r["paths"] if p not in deeplink_paths]
        if missing:
            bad(f"[{name}] '{r['id']}' path(s) {missing} missing from "
                f"'{DEEPLINK_ID}' — a refresh on that prefix falls into the "
                f"bare remote instead of the shell")
            local_fail += 1
        else:
            ok(f"[{name}] '{r['id']}' -> {r['paths']} covered by the deep-link route")

    login_route = next((r for r in routes if r["id"] == "login-ui"), None)
    login_paths = set(login_route["paths"]) if login_route else {"/login/**"}
    leaked = login_paths & deeplink_paths
    if leaked:
        bad(f"[{name}] login-ui path(s) {sorted(leaked)} ARE on the deep-link "
            f"route's Path list — login-ui is the designed standalone door and "
            f"must keep answering a direct GET itself")
        local_fail += 1
    else:
        ok(f"[{name}] login-ui's own path is NOT on the deep-link route "
           f"(the standalone door is undisturbed)")

    return local_fail


def concrete(pattern):
    """A real request path a covered glob would actually receive."""
    return pattern[:-3] + "/probe" if pattern.endswith("/**") else pattern


def check_order(name, routes):
    """[order]. A real first-match-wins simulation over the WHOLE table, so it
    catches a POSITIONAL regression (the deep-link route moved, or something
    inserted above it) that a pure set-membership check like check_coverage
    cannot — and independently proves non-navigation traffic still reaches the
    remote unchanged."""
    local_fail = 0
    for r in in_shell_ui_routes(routes):
        for p in r["paths"]:
            path = concrete(p)
            nav = first_match(routes, path, "text/html, application/xhtml+xml")
            if nav is not None and nav["id"] == DEEPLINK_ID:
                ok(f"[{name}] HTML navigation to {path} still resolves to the "
                   f"shell ('{DEEPLINK_ID}')")
            else:
                bad(f"[{name}] HTML navigation to {path} resolves to "
                    f"'{nav['id'] if nav else None}', not '{DEEPLINK_ID}' — "
                    f"either {p} is missing from its Path list or the route "
                    f"order regressed")
                local_fail += 1

            asset = first_match(routes, path, None)
            if asset is not None and asset["id"] == r["id"]:
                ok(f"[{name}] a non-navigation request (no matching Accept) "
                   f"under {path} still reaches the remote ('{r['id']}'), "
                   f"unchanged")
            else:
                bad(f"[{name}] a non-navigation request under {path} resolves "
                    f"to '{asset['id'] if asset else None}', not the remote "
                    f"'{r['id']}' — route order regressed")
                local_fail += 1
    return local_fail


print("== every in-shell *-ui remote's path is on the deep-link route ==")
compose_routes = load_compose_routes(COMPOSE_FE)
cluster_routes = load_cluster_routes(CLUSTER_FE)
check_coverage("compose", compose_routes)
check_coverage("cluster", cluster_routes)

print()
print("== route order: non-navigation requests still reach the remote unchanged ==")
check_order("compose", compose_routes)
check_order("cluster", cluster_routes)

# ------------------------------------------------------- negative controls ---
print()
print("== negative controls (the test must FAIL when the bug returns) ==")


def expect_caught(label, table_loader, table_path, mutate, checker=check_coverage):
    """Re-run one invariant against a DELIBERATELY BROKEN copy of one table and
    require it to trip. The probe run's own PASS/FAIL lines are suppressed —
    they are the expected detections, not real findings here — only the
    verdict is reported. The loader is called fresh each time so mutating one
    control can never leak into another."""
    import contextlib
    import io
    routes = table_loader(table_path)
    mutate(routes)
    global passed, failed
    p0, f0 = passed, failed
    with contextlib.redirect_stdout(io.StringIO()):
        n = checker("neg", routes)
    passed, failed = p0, f0
    if n:
        ok(f"negative control: {label} -> caught ({n} finding(s))")
    else:
        bad(f"negative control: {label} -> NOT caught (test is vacuous)")


def drop_path(route_id, path):
    def f(rs):
        r = next(x for x in rs if x["id"] == route_id)
        r["paths"] = [p for p in r["paths"] if p != path]
    return f


def add_path(route_id, path):
    def f(rs):
        r = next(x for x in rs if x["id"] == route_id)
        r["paths"] = list(r["paths"]) + [path]
    return f


def add_new_ui_remote(slug, path):
    """Synthesise a brand-new in-shell remote, exactly as a future PR would add
    one — its OWN route exists, but nobody has added its prefix to the
    deep-link list yet. Proves the guard catches the NEXT remote, not just the
    three named in #381."""
    def f(rs):
        rs.append({"id": f"{slug}-ui", "paths": [path], "header": None})
    return f


def move_to_end(route_id):
    """The deep-link route stops PRECEDING the remotes it exists to shadow —
    e.g. something new got inserted above it, or it was reordered by hand.
    check_coverage cannot see this (the path string is still 'in the list');
    only the order simulation can."""
    def f(rs):
        r = next(x for x in rs if x["id"] == route_id)
        rs.remove(r)
        rs.append(r)
    return f


# "remove /user from one lane's list -> red"
expect_caught("compose: /user/** dropped from the deep-link Path list",
              load_compose_routes, COMPOSE_FE, drop_path(DEEPLINK_ID, "/user/**"))
# same shape, other lane — proves the check is not compose-only
expect_caught("cluster: /admin/** dropped from the deep-link Path list",
              load_cluster_routes, CLUSTER_FE, drop_path(DEEPLINK_ID, "/admin/**"))
# "add /login -> red"
expect_caught("compose: /login/** added to the deep-link Path list",
              load_compose_routes, COMPOSE_FE, add_path(DEEPLINK_ID, "/login/**"))
expect_caught("cluster: /login/** added to the deep-link Path list",
              load_cluster_routes, CLUSTER_FE, add_path(DEEPLINK_ID, "/login/**"))
# the generality claim: a brand-new remote nobody has wired yet
expect_caught("compose: a new 'settings-ui' route lands with no deep-link entry",
              load_compose_routes, COMPOSE_FE, add_new_ui_remote("settings", "/settings/**"))
# the ORDER claim: the path string can still be present while the route itself
# no longer precedes the remotes it is meant to shadow
expect_caught("compose: the deep-link route is moved after every remote it shadows",
              load_compose_routes, COMPOSE_FE, move_to_end(DEEPLINK_ID),
              checker=check_order)

print()
print(f"== deep-link remote coverage: {passed} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
PY
