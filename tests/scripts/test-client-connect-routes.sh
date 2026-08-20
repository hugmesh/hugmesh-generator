#!/usr/bin/env bash
# test-client-connect-routes.sh — an external Matrix/Mastodon CLIENT must be able
# to complete its handshake against the FRONT DOOR, and the paths that carry it
# must never be answered by the Angular shell.
#
# THE BUG THIS EXISTS TO KILL
# ---------------------------
# The fe-gateway ends its route table with
#
#     - id: frontend-host
#       predicates: [ Path=/** ]        # the Angular host shell
#
# and the shell's nginx serves `try_files $uri $uri/ /index.html`. So ANY path
# with no route of its own does not 404 — it returns **HTTP 200 with
# `text/html`**, the SPA's own index.html. Measured on the live stack before the
# fix that accompanies this test:
#
#     GET https://localhost:8488/_matrix/client/versions   -> 200 text/html
#     GET https://localhost:8488/.well-known/matrix/client -> 200 text/html
#
# That is the single most dangerous shape a routing gap can take, because the
# usual health check — "did it 200?" — passes. Element would have been handed a
# homeserver URL that answers every CS-API call with a web page.
#
# Both client-connect banners already defend against it on the READ side: they
# require a 2xx AND a JSON content-type AND a protocol-identity field
# (`versions[]` for Matrix, `domain`/`uri` for Mastodon) before they will show a
# user a URL — see hugmesh-matrix-ui + hugmesh-mastodon-ui
# client-connect.service.ts. They were correctly reporting "unavailable"; what was
# missing was the ROUTE. This test is the WRITE-side counterpart, so the routing
# can never silently regress back to the SPA while the banners stay honest and
# users simply lose the feature again.
#
# WHAT IS ASSERTED (the invariant, not a literal route list)
# ---------------------------------------------------------
# For each route table (compose fe + cluster fe spec), Spring Cloud Gateway's
# real matching semantics are SIMULATED — first-match-wins over the ordered list,
# Ant-style `*`/`**`, plus the Host and Accept-header predicates — and for every
# path a real client handshake actually performs we assert:
#
#   1. some route matches it BEFORE the /** catch-all, and
#   2. the winning route's uri is a HOMESERVER (tuwunel/mastodon/akkoma),
#      never the shell host.
#
# Asserting the OUTCOME of the match rather than "a route with id X exists" is
# the point: it stays true if the routes are renamed, merged or reordered, and it
# fails if anything is inserted ABOVE them that would swallow the traffic.
#
# It also asserts the ACCESS posture, because opening the CS-API at the front door
# is an access decision: the fe rows for each exposed pattern must be
# role-for-role IDENTICAL to the be-gateway rows for the same pattern (the front
# door is a SECOND ingress to the same homeservers and must not be more
# permissive than the first), and no exposed pattern may be seeded PUBLIC — PUBLIC
# would waive the role check for authenticated callers, which is exactly the
# platform-ban enforcement we keep.
#
# Offline: reads files only. No cluster, no docker, no network.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

python3 - "$ROOT" <<'PY'
import re
import sys

root = sys.argv[1]

try:
    import yaml
except Exception as e:
    print(f"FATAL: PyYAML is required ({e}).", file=sys.stderr)
    sys.exit(2)

COMPOSE_FE = f"{root}/tests/stack/gateway-routes/fe/application-routes.yml"
CLUSTER_FE = f"{root}/specs/cluster/apps/20-gateway-fe.yaml"
SCHEMA     = f"{root}/specs/cluster/manifests/route-access/initdb/20-schema.sql"

passed = failed = 0


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
    """Spring's Ant path matching: ** crosses /, * does not."""
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


def path_matches(patterns, path):
    return any(ant_to_re(p.strip()).search(path) for p in patterns if p.strip())


def host_matches(pattern, host):
    return ant_to_re(pattern.strip().replace(".", "\x00")
                     ).search(host.replace(".", "\x00")) is not None


def load_compose_routes(path):
    """Compose table: predicates are raw SCG strings (Path=..., Header=...)."""
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
    """Cluster spec: the chart's values shape (id/uri/path/host/header)."""
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


def first_match(routes, path, host, accept):
    """SCG semantics: first route in DECLARED ORDER whose predicates all hold."""
    for r in routes:
        if r["host"] and not host_matches(r["host"], host):
            continue
        if r["paths"] and not path_matches(r["paths"], path):
            continue
        if r["header"]:
            name, _, value_re = r["header"].partition(",")
            if name.strip().lower() != "accept":
                continue
            if not re.search(value_re.strip(), accept):
                continue
        return r
    return None


# The paths a REAL client handshake performs, and who must answer them.
#   Matrix: version negotiation, then login, then autodiscovery.
#   Mastodon: instance doc, dynamic app registration, then the OAuth token.
HANDSHAKE = [
    ("/_matrix/client/versions",       "matrix",   "CS-API version negotiation"),
    ("/_matrix/client/v3/login",       "matrix",   "CS-API login"),
    ("/.well-known/matrix/client",     "matrix",   "client autodiscovery"),
    ("/.well-known/matrix/server",     "matrix",   "server autodiscovery"),
    ("/api/v1/instance",               "mastodon", "instance document (the banner's probe)"),
    ("/api/v2/instance",               "mastodon", "instance document v2"),
    ("/api/v1/apps",                   "mastodon", "dynamic app registration"),
    ("/oauth/token",                   "mastodon", "OAuth token exchange"),
]

HOMESERVER_HINT = {
    "matrix":   ("tuwunel",),
    "mastodon": ("mastodon-web", "akkoma"),
}
# The Angular shell — the thing that was silently answering these paths.
# BOTH spellings on purpose. The shell's workload/DNS name was renamed
# `*-systems-web` -> `hugmesh-host-shell`, and the compose lane moved first: for a
# while this tuple named ONLY the retired spelling, so the substring arm of the
# check below silently matched nothing on the compose table and the gate leaned
# entirely on its `paths == ["/**"]` arm. Keeping the historical spelling means a
# resurrected old name is still caught; keeping the current one means the
# substring arm actually fires again. Add, never replace, on the next rename.
SHELL_HINT = ("host-shell", "systems-web")


def check_table(name, routes):
    """The core invariant, run against one route table."""
    local_fail = 0
    for path, platform, why in HANDSHAKE:
        # A client sends Accept: application/json, and dials the apex host.
        r = first_match(routes, path, "hugmesh.net", "application/json")
        if r is None:
            bad(f"[{name}] {path} ({why}) matched NO route at all")
            local_fail += 1
            continue
        if any(h in r["uri"] for h in SHELL_HINT) or r["paths"] == ["/**"]:
            bad(f"[{name}] {path} ({why}) is answered by the SPA shell "
                f"(route '{r['id']}' -> {r['uri']}) — the 200-text/html trap")
            local_fail += 1
            continue
        if not any(h in r["uri"] for h in HOMESERVER_HINT[platform]):
            bad(f"[{name}] {path} ({why}) resolves to '{r['id']}' -> {r['uri']}, "
                f"which is not a {platform} homeserver")
            local_fail += 1
            continue
        ok(f"[{name}] {path} -> route '{r['id']}' ({r['uri']}) — {why}")
    return local_fail


print("== client handshake reaches a homeserver, not the SPA ==")
compose_routes = load_compose_routes(COMPOSE_FE)
cluster_routes = load_cluster_routes(CLUSTER_FE)
check_table("compose", compose_routes)
check_table("cluster", cluster_routes)

# The deep-link route must keep owning HTML NAVIGATIONS to the shell prefixes —
# proof the new routes did not disturb the ordering contract above them.
print()
print("== the shell deep-link route is undisturbed ==")
for table, routes in (("compose", compose_routes), ("cluster", cluster_routes)):
    r = first_match(routes, "/social/matrix/room/1", "hugmesh.net", "text/html")
    if r and r["id"] == "remote-deeplink-to-host-shell":
        ok(f"[{table}] an HTML navigation to /social/matrix/** still wins to the host shell")
    else:
        bad(f"[{table}] deep-link navigation now resolves to "
            f"'{r['id'] if r else None}' — the first-route contract regressed")
    # …while a JSON/XHR fetch for the same prefix still reaches the remote.
    r = first_match(routes, "/social/matrix/remoteEntry.json", "hugmesh.net", "application/json")
    if r and r["id"] == "matrix-ui":
        ok(f"[{table}] a non-navigation fetch under /social/matrix/** still reaches the remote")
    else:
        bad(f"[{table}] remote asset fetch resolves to '{r['id'] if r else None}'")

# ------------------------------------------------------------ access rows ---
print()
print("== route-access posture for the newly exposed patterns ==")
sql = open(SCHEMA).read()
ROW = re.compile(
    r"\(\s*'(?P<gw>[^']+)'\s*,\s*'(?P<pat>[^']+)'\s*,\s*'(?P<role>[^']+)'\s*,\s*(?P<allow>true|false)\s*\)")
rows = {}
for m in ROW.finditer(sql):
    rows.setdefault((m.group("gw"), m.group("pat")), set()).add(
        (m.group("role"), m.group("allow")))

# Every pattern the fe route table now proxies to a homeserver.
EXPOSED = ["/_matrix/**", "/.well-known/matrix/**",
           "/api/v1/**", "/api/v2/**", "/oauth/**"]

for pat in EXPOSED:
    fe = rows.get(("hugmesh-fe-gateway", pat), set())
    be = rows.get(("hugmesh-be-gateway", pat), set())
    if not fe:
        bad(f"{pat} is routed on the fe front door but has NO gateway_route_access row "
            f"— the surface would be governed only by the coarse floor")
        continue
    if any(role == "PUBLIC" for role, _ in fe):
        bad(f"{pat} is seeded PUBLIC on the fe gateway — PUBLIC waives the role check "
            f"for authenticated callers, disabling platform-ban enforcement")
        continue
    if fe != be:
        bad(f"{pat} fe rows {sorted(fe)} != be rows {sorted(be)} — the front door is a "
            f"second ingress to the same homeserver and must not differ")
        continue
    ok(f"{pat} fe rows match be rows exactly ({len(fe)} roles, none PUBLIC)")

# The external-client ISSUANCE sub-paths must exist on fe too, else a native
# client can never mint a token through the front door.
ISSUANCE = ["/_matrix/client/v3/login", "/_matrix/client/r0/login",
            "/_matrix/client/v3/register", "/_matrix/client/r0/register",
            "/api/v1/apps"]
for pat in ISSUANCE:
    if rows.get(("hugmesh-fe-gateway", pat)):
        ok(f"{pat} carries an external-client issuance row on the fe gateway")
    else:
        bad(f"{pat} has no fe external-client issuance row")

# ------------------------------------------------------- negative controls ---
print()
print("== negative controls (the test must FAIL when the bug returns) ==")


def expect_caught(label, mutate):
    """Re-run the invariant against a DELIBERATELY BROKEN table and require it to
    trip. The probe run's own output is suppressed — its FAIL lines are the
    expected detections, not real failures — so only the verdict is reported."""
    import contextlib
    import io
    routes = load_compose_routes(COMPOSE_FE)
    mutate(routes)
    global passed, failed
    p0, f0 = passed, failed
    with contextlib.redirect_stdout(io.StringIO()):
        n = check_table("neg", routes)
    passed, failed = p0, f0
    if n:
        ok(f"negative control: {label} -> caught ({n} handshake path(s) broken)")
    else:
        bad(f"negative control: {label} -> NOT caught (test is vacuous)")


def drop(ids):
    return lambda rs: rs.__setitem__(
        slice(None), [r for r in rs if r["id"] not in ids])


def move_after_catchall(rid):
    def f(rs):
        r = next(x for x in rs if x["id"] == rid)
        rs.remove(r)
        rs.append(r)          # now BELOW the /** catch-all
    return f


def repoint_to_shell(rid):
    def f(rs):
        next(x for x in rs if x["id"] == rid)["uri"] = "http://hugmesh-host-shell:8080"
    return f


expect_caught("the /_matrix route is deleted (the original gap)",
              drop({"matrix-cs-api"}))
expect_caught("the /_matrix route is moved BELOW the /** catch-all",
              move_after_catchall("matrix-cs-api"))
expect_caught("the /_matrix route is repointed at the Angular shell",
              repoint_to_shell("matrix-cs-api"))
expect_caught("the Mastodon client-API route is deleted",
              drop({"mastodon-client-api"}))
expect_caught("the Mastodon OAuth route is deleted (client can register but never get a token)",
              drop({"mastodon-oauth"}))
expect_caught("the .well-known autodiscovery route is deleted",
              drop({"matrix-wellknown"}))

print()
print(f"== client-connect routes: {passed} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
PY
