#!/usr/bin/env bash
# test-games-screens-wiring.sh — the five committed surfaces that wire the games
# member + games admin SCREENS (2026-10-28 cross-repo contract) must agree, and
# the access guards among them must be load-bearing.
#
# THE CONTRACT, in one place (every other lane assumes these names verbatim):
#   * ONE native-federation remote `games` (hugmesh-games/games-ui) served on
#     :8080 behind the fe route `games-ui` (Path=/games/**, StripPrefix=1), and
#     the games BFF behind the fe route `games-bff` (Path=/games/api/**,
#     StripPrefix=1), games-bff BEFORE games-ui, both after the deep-link route
#     (whose Path list carries /games/**) and before frontend-host.
#   * route-access, fe gateway: /games/api/admin/** ROLE_GAMES_ADMIN;
#     /games/api/** and /games/** each ROLE_GAMES + ROLE_ADMIN and NOT ROLE_MOD (a
#     platform mod without ROLE_GAMES is not a games user, matching gamesGuard); the
#     pre-existing /games/admin/** ROLE_GAMES_ADMIN row untouched; no be /games or
#     /games/api/admin rows (the portal host is not on the be-gateway).
#   * optional-services.yaml games: routeAccessRows carries the three fe
#     patterns, gatewayRouteIds carries games-ui + games-bff, extraManifestPaths
#     carries manifests/games-ui — so a games-DESELECTED build prunes all of it,
#     and scripts/_optional-services-lib.sh's games case actually does.
#   * compose (tests/stack/compose.games.yaml, profile games): hugmesh-games-ui,
#     hugmesh-games-bff (env exactly as the contract), games-bff-db,
#     games-cassandra-init.
#   * kind twins (specs/cluster/apps/20-gateway-fe.yaml + manifests/games-ui):
#     same two routes against the cluster Services, same deep-link entry, a
#     Service hugmesh-games-ui on :8080 with /remoteEntry.json probes.
#
# WHAT IS ASSERTED: each surface individually, then PARITY — the fe /games row
# set in 20-schema.sql == the fe /games patterns optional-services.yaml owns,
# the compose route pair == the kind route pair (ids, paths, strip, order),
# and the prune case names every row/route/dir the catalogue says it owns.
#
# NEGATIVE CONTROLS (in-process, on parsed COPIES — the files on disk are never
# modified): each of the mutations below must trip at least one check, and
# each is PROVEN to have changed the copy before it is run:
#   drop one of the five SQL rows; flip a row to allow=false; drop /games/**
#   from the compose deep-link list; drop it from the kind deep-link list;
#   swap games-ui above games-bff (compose); move games-ui below frontend-host;
#   change games-ui's StripPrefix; drop games-ui from gatewayRouteIds; drop a
#   fe pattern from routeAccessRows; drop manifests/games-ui from
#   extraManifestPaths; drop the kind games-bff route; point the kind Service
#   at :80; drop hugmesh-games-ui from compose; change the BFF's
#   CASDOOR_ORGANIZATION; drop a fe row from the prune case.
#
# Offline: python3 + PyYAML. No cluster, no docker, no network.
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 1; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required — refusing to skip" >&2; exit 1; }

python3 - "$ROOT" <<'PY'
import copy
import re
import sys

import yaml

root = sys.argv[1]
COMPOSE_FE = f"{root}/tests/stack/gateway-routes/fe/application-routes.yml"
CLUSTER_FE = f"{root}/specs/cluster/apps/20-gateway-fe.yaml"
SQL        = f"{root}/specs/cluster/manifests/route-access/initdb/20-schema.sql"
OPT        = f"{root}/specs/cluster/optional-services.yaml"
COMPOSE_G  = f"{root}/tests/stack/compose.games.yaml"
KIND_DEP   = f"{root}/specs/cluster/manifests/games-ui/deployment.yaml"
KIND_SVC   = f"{root}/specs/cluster/manifests/games-ui/service.yaml"
KIND_KUST  = f"{root}/specs/cluster/manifests/games-ui/kustomization.yaml"
PRUNE_LIB  = f"{root}/scripts/_optional-services-lib.sh"

FE = "hugmesh-fe-gateway"
WANT_ROWS = {
    ("/games/api/admin/**", "ROLE_GAMES_ADMIN"),
    ("/games/api/**", "ROLE_GAMES"), ("/games/api/**", "ROLE_ADMIN"),
    ("/games/**", "ROLE_GAMES"), ("/games/**", "ROLE_ADMIN"),
}
WANT_FE_PATTERNS = {"/games/api/admin/**", "/games/api/**", "/games/**"}
BFF_ENV = {
    "DB_HOST": "games-bff-db", "DB_PORT": "5432", "DB_NAME": "threewizards",
    "DB_USER": "threewizards", "DB_PASS": "threewizards",
    "CASDOOR_ENDPOINT": "http://casdoor:8000", "CASDOOR_ORGANIZATION": "hugmesh",
    "CASDOOR_CLIENT_ID": "dev-games-client", "CASDOOR_CLIENT_SECRET": "dev-games-secret",
    "CASSANDRA_CONTACT_POINTS": "cassandra:9042", "CASSANDRA_KEYSPACE": "threewizards",
    "CASSANDRA_LOCAL_DC": "datacenter1", "SPRING_PROFILES_ACTIVE": "prod",
    "APP_UPLOADS_GAMES_DIR": "/var/hugmesh/games",
}

passed = failed = 0
def ok(m):
    global passed; passed += 1; print(f"  PASS {m}")
def bad(m):
    global failed; failed += 1; print(f"  FAIL {m}")

# ── loaders (each returns a plain dict the checks and the mutations share) ──
def load_compose_fe():
    doc = yaml.safe_load(open(COMPOSE_FE))
    out = []
    for r in doc["spring"]["cloud"]["gateway"]["server"]["webflux"]["routes"]:
        paths, strip, header = [], None, None
        for p in r.get("predicates", []):
            if p.startswith("Path="):
                paths = [s.strip() for s in p[5:].split(",") if s.strip()]
            elif p.startswith("Header="):
                header = p[7:]
        for f in r.get("filters", []) or []:
            if str(f).startswith("StripPrefix="):
                strip = int(str(f).split("=", 1)[1])
        out.append({"id": r["id"], "uri": r.get("uri", ""), "paths": paths, "strip": strip, "header": header})
    return out

def load_cluster_fe():
    doc = yaml.safe_load(open(CLUSTER_FE))
    values = yaml.safe_load(doc["spec"]["source"]["helm"]["values"])
    out = []
    for r in values["routes"]:
        paths = [s.strip() for s in str(r["path"]).split(",") if s.strip()] if r.get("path") else []
        strip = None
        for f in r.get("filters", []) or []:
            if str(f).startswith("StripPrefix="):
                strip = int(str(f).split("=", 1)[1])
        out.append({"id": r["id"], "uri": r.get("uri", ""), "paths": paths, "strip": strip, "header": r.get("header")})
    return out

ROW_RE = re.compile(r"\(\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*'([^']+)'\s*,\s*(true|false)\s*\)")
def load_sql():
    return [{"gw": m[1], "pat": m[2], "role": m[3], "allow": m[4] == "true"}
            for m in ROW_RE.finditer(open(SQL).read())]

def load_opt():
    doc = yaml.safe_load(open(OPT))
    # the catalogue is a list of slugs somewhere under the top-level doc; find games
    def walk(o):
        if isinstance(o, dict):
            if o.get("slug") == "games":
                return o
            for v in o.values():
                r = walk(v)
                if r: return r
        elif isinstance(o, list):
            for v in o:
                r = walk(v)
                if r: return r
        return None
    g = walk(doc)
    if not g:
        raise SystemExit(f"FATAL: no slug: games in {OPT}")
    return g

def load_compose_games():
    return yaml.safe_load(open(COMPOSE_G))

def load_kind():
    deps = [d for d in yaml.safe_load_all(open(KIND_DEP)) if d]
    svcs = [d for d in yaml.safe_load_all(open(KIND_SVC)) if d]
    kust = yaml.safe_load(open(KIND_KUST))
    return {"deployment": next(d for d in deps if d.get("kind") == "Deployment"),
            "service": next(d for d in svcs if d.get("kind") == "Service"),
            "kustomization": kust}

def load_prune():
    text = open(PRUNE_LIB).read()
    m = re.search(r"^\s*games\)\n(.*?)^\s*;;", text, re.S | re.M)
    if not m:
        raise SystemExit(f"FATAL: no `games)` case in {PRUNE_LIB}")
    return m.group(1)

# ── checks (each returns its failure count so controls can assert a trip) ───
def check_routes(name, routes):
    n = 0
    ids = [r["id"] for r in routes]
    def find(i): return next((r for r in routes if r["id"] == i), None)
    dl, bff, ui, host = find("remote-deeplink-to-host-shell"), find("games-bff"), find("games-ui"), find("frontend-host")
    for label, r in (("games-bff", bff), ("games-ui", ui), ("deep-link", dl), ("frontend-host", host)):
        if r is None:
            bad(f"[{name}] route {label} missing"); n += 1
    if n: return n
    if "/games/**" in dl["paths"]: ok(f"[{name}] deep-link route carries /games/**")
    else: bad(f"[{name}] deep-link route lacks /games/** — a refresh on /games lands in the bare remote"); n += 1
    if bff["paths"] == ["/games/api/**"] and bff["strip"] == 1: ok(f"[{name}] games-bff = /games/api/** StripPrefix=1")
    else: bad(f"[{name}] games-bff is {bff['paths']} strip={bff['strip']} (want /games/api/** strip 1)"); n += 1
    if ui["paths"] == ["/games/**"] and ui["strip"] == 1: ok(f"[{name}] games-ui = /games/** StripPrefix=1")
    else: bad(f"[{name}] games-ui is {ui['paths']} strip={ui['strip']} (want /games/** strip 1)"); n += 1
    order = [ids.index("remote-deeplink-to-host-shell"), ids.index("games-bff"), ids.index("games-ui"), ids.index("frontend-host")]
    if order == sorted(order): ok(f"[{name}] order deep-link < games-bff < games-ui < frontend-host")
    else: bad(f"[{name}] route order wrong: deep-link@{order[0]} games-bff@{order[1]} games-ui@{order[2]} frontend-host@{order[3]}"); n += 1
    if ":8080" in ui["uri"] and "hugmesh-games-ui" in ui["uri"]: ok(f"[{name}] games-ui -> hugmesh-games-ui:8080")
    else: bad(f"[{name}] games-ui uri {ui['uri']} (want hugmesh-games-ui on :8080)"); n += 1
    if ":8080" in bff["uri"] and "hugmesh-games" in bff["uri"]: ok(f"[{name}] games-bff -> the games BFF on :8080")
    else: bad(f"[{name}] games-bff uri {bff['uri']}"); n += 1
    return n

def check_sql(rows):
    n = 0
    fe = {(r["pat"], r["role"]): r["allow"] for r in rows if r["gw"] == FE}
    for pat, role in sorted(WANT_ROWS):
        if (pat, role) not in fe: bad(f"[sql] missing fe row ('{pat}','{role}')"); n += 1
        elif fe[(pat, role)] is not True: bad(f"[sql] fe row ('{pat}','{role}') is not an ALLOW row"); n += 1
        else: ok(f"[sql] fe row ('{pat}','{role}') allow")
    if fe.get(("/games/admin/**", "ROLE_GAMES_ADMIN")) is True: ok("[sql] pre-existing /games/admin/** ROLE_GAMES_ADMIN row intact")
    else: bad("[sql] the /games/admin/** ROLE_GAMES_ADMIN row is gone"); n += 1
    extra = {k for k in fe if k[0] in WANT_FE_PATTERNS} - WANT_ROWS
    if not extra: ok("[sql] no extra role at the three new fe patterns (ROLE_USER etc. would widen the floor)")
    else: bad(f"[sql] unexpected fe rows {sorted(extra)}"); n += 1
    be = {(r["pat"], r["role"]) for r in rows if r["gw"] == "hugmesh-be-gateway" and r["pat"].startswith("/games/")}
    for gone in (("/games/api/admin/**", "ROLE_GAMES_ADMIN"), ("/games/**", "ROLE_GAMES"), ("/games/**", "ROLE_ADMIN"), ("/games/**", "ROLE_MOD")):
        if gone in be: bad(f"[sql] be row {gone} is back; the be-gateway does not serve the games portal"); n += 1
        else: ok(f"[sql] be row {gone} retired")
    return n

def check_opt(g):
    n = 0
    rows = {(r["gateway"], r["urlPattern"]) for r in g.get("routeAccessRows", [])}
    for pat in sorted(WANT_FE_PATTERNS):
        if (FE, pat) in rows: ok(f"[opt] games.routeAccessRows owns fe {pat}")
        else: bad(f"[opt] games.routeAccessRows lacks fe {pat} — a games-deselected build would keep the grant"); n += 1
    for rid in ("games-ui", "games-bff"):
        if rid in g.get("gatewayRouteIds", []): ok(f"[opt] games.gatewayRouteIds owns {rid}")
        else: bad(f"[opt] games.gatewayRouteIds lacks {rid} — a games-deselected build keeps a route into the void"); n += 1
    if "manifests/games-ui" in g.get("extraManifestPaths", []): ok("[opt] games.extraManifestPaths owns manifests/games-ui")
    else: bad("[opt] games.extraManifestPaths lacks manifests/games-ui"); n += 1
    return n

def check_compose(doc):
    n = 0
    s = doc.get("services", {})
    for name in ("hugmesh-games-ui", "hugmesh-games-bff", "games-bff-db", "games-cassandra-init", "hugmesh-wasm-fragment"):
        if name in s and "games" in (s[name].get("profiles") or []): ok(f"[compose] {name} behind profile games")
        else: bad(f"[compose] service {name} missing or not behind profile games"); n += 1
    if n: return n
    ui, bff = s["hugmesh-games-ui"], s["hugmesh-games-bff"]
    if ui.get("image") == "hugmesh-games/games-ui:dev" and str((ui.get("build") or {}).get("context", "")).endswith("/games-ui"):
        ok("[compose] hugmesh-games-ui = image hugmesh-games/games-ui:dev from ${GAMES_SRC}/games-ui")
    else: bad(f"[compose] hugmesh-games-ui image/context wrong: {ui.get('image')} {ui.get('build')}"); n += 1
    if "HUG_THEME_CSS" in (ui.get("environment") or {}): ok("[compose] hugmesh-games-ui consumes HUG_THEME_CSS like user-ui")
    else: bad("[compose] hugmesh-games-ui has no HUG_THEME_CSS"); n += 1
    if "remoteEntry.json" in " ".join(map(str, (ui.get("healthcheck") or {}).get("test", []))): ok("[compose] hugmesh-games-ui healthcheck probes /remoteEntry.json")
    else: bad("[compose] hugmesh-games-ui healthcheck does not probe /remoteEntry.json"); n += 1
    env = {k: str(v) for k, v in (bff.get("environment") or {}).items()}
    for k, v in sorted(BFF_ENV.items()):
        if env.get(k) == v: ok(f"[compose] games-bff env {k}={v}")
        else: bad(f"[compose] games-bff env {k}={env.get(k)!r} (contract: {v})"); n += 1
    if bff.get("image") == "hugmesh-games/bff:dev" and str((bff.get("build") or {}).get("context", "")).endswith("/backend"):
        ok("[compose] hugmesh-games-bff = image hugmesh-games/bff:dev from ${GAMES_SRC}/backend")
    else: bad(f"[compose] hugmesh-games-bff image/context wrong"); n += 1
    deps = bff.get("depends_on") or {}
    for d, cond in (("games-bff-db", "service_healthy"), ("games-cassandra-init", "service_completed_successfully"), ("casdoor", "service_started")):
        if isinstance(deps, dict) and (deps.get(d) or {}).get("condition") == cond: ok(f"[compose] games-bff depends_on {d}: {cond}")
        else: bad(f"[compose] games-bff depends_on {d} != {cond}"); n += 1
    ci = s["games-cassandra-init"]
    if ci.get("image") == "cassandra:5" and ci.get("restart") == "no" and any(str(v).endswith("docker/cassandra-init.cql:/init.cql:ro") for v in ci.get("volumes") or []):
        ok("[compose] games-cassandra-init runs the games repo's own cassandra-init.cql once")
    else: bad("[compose] games-cassandra-init shape wrong"); n += 1
    db = s["games-bff-db"]
    if db.get("image") == "postgres:16-alpine" and (db.get("environment") or {}).get("POSTGRES_DB") == "threewizards": ok("[compose] games-bff-db = postgres:16-alpine threewizards")
    else: bad("[compose] games-bff-db shape wrong"); n += 1
    return n

def check_kind(k):
    n = 0
    dep, svc, kust = k["deployment"], k["service"], k["kustomization"]
    c = dep["spec"]["template"]["spec"]["containers"][0]
    ports = [p.get("containerPort") for p in c.get("ports", [])]
    if ports == [8080]: ok("[kind] games-ui container listens on 8080 (nginx-unprivileged)")
    else: bad(f"[kind] games-ui containerPort {ports} (want [8080])"); n += 1
    for probe in ("readinessProbe", "livenessProbe"):
        if (c.get(probe) or {}).get("httpGet", {}).get("path") == "/remoteEntry.json": ok(f"[kind] {probe} fetches /remoteEntry.json")
        else: bad(f"[kind] {probe} does not fetch /remoteEntry.json"); n += 1
    sp = svc["spec"]["ports"][0]
    if svc["metadata"]["name"] == "hugmesh-games-ui" and svc["metadata"].get("namespace") == "hugmesh-frontend" and sp.get("port") == 8080:
        ok("[kind] Service hugmesh-games-ui.hugmesh-frontend:8080 (what the games-ui route targets)")
    else: bad(f"[kind] Service {svc['metadata']} port {sp}"); n += 1
    if dep["spec"]["selector"]["matchLabels"] == svc["spec"]["selector"]: ok("[kind] Service selector matches the Deployment labels")
    else: bad("[kind] Service selector != Deployment selector"); n += 1
    res = kust.get("resources", [])
    if "deployment.yaml" in res and "service.yaml" in res: ok("[kind] kustomization lists deployment.yaml + service.yaml")
    else: bad(f"[kind] kustomization resources {res}"); n += 1
    img = (kust.get("images") or [{}])[0]
    if img.get("name") == c.get("image", "").split(":")[0] and str(img.get("newTag", "")) and str(img.get("newTag")).lower() != "latest":
        ok(f"[kind] image placeholder {img.get('name')} rewritten to {img.get('newName')}:{img.get('newTag')}")
    else: bad(f"[kind] images transform {img} does not match container image {c.get('image')}"); n += 1
    return n

def check_prune(text):
    n = 0
    for pat in sorted(WANT_FE_PATTERNS | {"/games/admin/**"}):
        if f"'{pat}'" in text: ok(f"[prune] games case drops fe row {pat}")
        else: bad(f"[prune] games case never drops fe row {pat} — a games-deselected build keeps the grant"); n += 1
    if re.search(r"_opt_drop_route\s+\"\$\{apps\}/20-gateway-fe\.yaml\"\s+games-bff\s+games-ui", text): ok("[prune] games case drops fe routes games-bff + games-ui")
    else: bad("[prune] games case does not drop the fe routes games-bff + games-ui"); n += 1
    if "manifests/games-ui" in text: ok("[prune] games case removes manifests/games-ui")
    else: bad("[prune] games case keeps manifests/games-ui"); n += 1
    return n

def check_parity(sql_rows, g, compose_routes, cluster_routes):
    n = 0
    sql_fe = {r["pat"] for r in sql_rows if r["gw"] == FE and r["pat"].startswith("/games/")}
    opt_fe = {r["urlPattern"] for r in g.get("routeAccessRows", []) if r["gateway"] == FE and r["urlPattern"].startswith("/games/")}
    if sql_fe == opt_fe: ok(f"[parity] fe /games patterns: seed == optional-services ({sorted(sql_fe)})")
    else: bad(f"[parity] seed fe /games patterns {sorted(sql_fe)} != optional-services {sorted(opt_fe)}"); n += 1
    def pair(routes):
        return [(r["id"], tuple(r["paths"]), r["strip"]) for r in routes if r["id"] in ("games-bff", "games-ui")]
    if pair(compose_routes) == pair(cluster_routes) and len(pair(compose_routes)) == 2: ok("[parity] compose and kind carry the same games-bff/games-ui pair in the same order")
    else: bad(f"[parity] compose {pair(compose_routes)} != kind {pair(cluster_routes)}"); n += 1
    for rid in ("games-bff", "games-ui"):
        if rid in g.get("gatewayRouteIds", []) and any(r["id"] == rid for r in cluster_routes): ok(f"[parity] gatewayRouteIds {rid} names a real kind route")
        else: bad(f"[parity] gatewayRouteIds/{rid} and the kind table disagree"); n += 1
    return n

print("== games member + admin screens: the five surfaces agree ==")
compose_routes = load_compose_fe(); cluster_routes = load_cluster_fe()
sql_rows = load_sql(); opt_games = load_opt(); compose_games = load_compose_games()
kind = load_kind(); prune = load_prune()
check_routes("compose", compose_routes)
check_routes("kind", cluster_routes)
check_sql(sql_rows)
check_opt(opt_games)
check_compose(compose_games)
check_kind(kind)
check_prune(prune)
check_parity(sql_rows, opt_games, compose_routes, cluster_routes)

# ── negative controls ────────────────────────────────────────────────────────
print()
print("== negative controls (the guard must FAIL when the wiring regresses) ==")
import contextlib, io

def control(label, original, mutate, checker):
    """Mutate a deep copy, PROVE it changed, run the checker silently, require a trip."""
    global passed, failed
    m = copy.deepcopy(original)
    mutate(m)
    if m == original:
        bad(f"negative control: {label} -> the mutation did not change the copy (control is vacuous)"); return
    p0, f0 = passed, failed
    with contextlib.redirect_stdout(io.StringIO()):
        n = checker(m)
    passed, failed = p0, f0
    if n: ok(f"negative control: {label} -> caught ({n} finding(s))")
    else: bad(f"negative control: {label} -> NOT caught (guard is vacuous)")

def drop_row(pat, role):
    def f(rows): rows[:] = [r for r in rows if not (r["gw"] == FE and r["pat"] == pat and r["role"] == role)]
    return f
def flip_row(pat, role):
    def f(rows):
        for r in rows:
            if r["gw"] == FE and r["pat"] == pat and r["role"] == role: r["allow"] = False
    return f
def drop_dl(rs):
    r = next(x for x in rs if x["id"] == "remote-deeplink-to-host-shell"); r["paths"] = [p for p in r["paths"] if p != "/games/**"]
def swap_ui_above_bff(rs):
    i, j = [x["id"] for x in rs].index("games-bff"), [x["id"] for x in rs].index("games-ui"); rs[i], rs[j] = rs[j], rs[i]
def ui_after_host(rs):
    r = next(x for x in rs if x["id"] == "games-ui"); rs.remove(r); rs.append(r)
def ui_strip2(rs):
    next(x for x in rs if x["id"] == "games-ui")["strip"] = 2
def drop_route(rid):
    def f(rs): rs[:] = [x for x in rs if x["id"] != rid]
    return f

control("sql: ('/games/**','ROLE_GAMES') row dropped", sql_rows, drop_row("/games/**", "ROLE_GAMES"), check_sql)
control("sql: ('/games/api/admin/**','ROLE_GAMES_ADMIN') row dropped", sql_rows, drop_row("/games/api/admin/**", "ROLE_GAMES_ADMIN"), check_sql)
control("sql: ('/games/api/**','ROLE_ADMIN') flipped to allow=false", sql_rows, flip_row("/games/api/**", "ROLE_ADMIN"), check_sql)
control("sql: a ROLE_MOD row added at /games/api/** (a platform mod is not a games user)", sql_rows, lambda rows: rows.append({"gw": FE, "pat": "/games/api/**", "role": "ROLE_MOD", "allow": True}), check_sql)
control("sql: a ROLE_USER row added at /games/** (floor widened)", sql_rows, lambda rows: rows.append({"gw": FE, "pat": "/games/**", "role": "ROLE_USER", "allow": True}), check_sql)
control("compose: /games/** dropped from the deep-link list", compose_routes, drop_dl, lambda rs: check_routes("neg", rs))
control("kind: /games/** dropped from the deep-link list", cluster_routes, drop_dl, lambda rs: check_routes("neg", rs))
control("compose: games-ui swapped above games-bff", compose_routes, swap_ui_above_bff, lambda rs: check_routes("neg", rs))
control("compose: games-ui moved below frontend-host", compose_routes, ui_after_host, lambda rs: check_routes("neg", rs))
control("compose: games-ui StripPrefix changed to 2", compose_routes, ui_strip2, lambda rs: check_routes("neg", rs))
control("kind: games-bff route dropped", cluster_routes, drop_route("games-bff"), lambda rs: check_routes("neg", rs))
control("opt: games-ui dropped from gatewayRouteIds", opt_games, lambda g: g["gatewayRouteIds"].remove("games-ui"), check_opt)
control("opt: fe /games/api/** dropped from routeAccessRows", opt_games, lambda g: g["routeAccessRows"].remove({"gateway": FE, "urlPattern": "/games/api/**"}), check_opt)
control("opt: manifests/games-ui dropped from extraManifestPaths", opt_games, lambda g: g["extraManifestPaths"].remove("manifests/games-ui"), check_opt)
control("compose: hugmesh-games-ui service removed", compose_games, lambda d: d["services"].pop("hugmesh-games-ui"), check_compose)
control("compose: games-bff CASDOOR_ORGANIZATION changed to threewizards", compose_games, lambda d: d["services"]["hugmesh-games-bff"]["environment"].__setitem__("CASDOOR_ORGANIZATION", "threewizards"), check_compose)
control("compose: games-bff no longer waits for games-cassandra-init", compose_games, lambda d: d["services"]["hugmesh-games-bff"]["depends_on"].pop("games-cassandra-init"), check_compose)
control("kind: Service port changed to 80", kind, lambda k: k["service"]["spec"]["ports"][0].__setitem__("port", 80), check_kind)
control("kind: readiness probe no longer fetches /remoteEntry.json", kind, lambda k: k["deployment"]["spec"]["template"]["spec"]["containers"][0]["readinessProbe"]["httpGet"].__setitem__("path", "/"), check_kind)
# the prune case is a string, so its control is a plain replace:
mutated = prune.replace("'/games/api/**'", "")
if mutated == prune: bad("negative control: prune mutation did not change the copy")
else:
    p0, f0 = passed, failed
    with contextlib.redirect_stdout(io.StringIO()):
        n = check_prune(mutated)
    passed, failed = p0, f0
    if n: ok(f"negative control: prune: fe row /games/api/** no longer dropped -> caught ({n} finding(s))")
    else: bad("negative control: prune: fe row /games/api/** no longer dropped -> NOT caught")
control("parity: optional-services drops a fe pattern the seed keeps", opt_games, lambda g: g["routeAccessRows"].remove({"gateway": FE, "urlPattern": "/games/**"}), lambda g: check_parity(sql_rows, g, compose_routes, cluster_routes))
control("parity: kind games-ui StripPrefix differs from compose", cluster_routes, ui_strip2, lambda rs: check_parity(sql_rows, opt_games, compose_routes, rs))

print()
print(f"== games screens wiring: {passed} passed, {failed} failed ==")
sys.exit(1 if failed else 0)
PY
