#!/usr/bin/env bash
# =============================================================================
# test-games-two-realms.sh — both ways into games must stay wired in the cluster.
#
# THE DESIGN (operator, 2026-10-30): TWO realms. A games player signs in with a
# games-realm (threewizards) account and need not be a mesh user; a mesh user with
# ROLE_GAMES / ROLE_GAMES_ADMIN reaches games through the mesh shell.
#
# WHAT THIS PINS, offline over specs/cluster and the builders:
#   mesh path    the BFF trusts both issuers (one domain, per-issuer JWKS, games-realm
#                issuer list); fe route-access has no ROLE_MOD superset on /games; the
#                games-ui remote has an Application; netpols admit the key fetch.
#   games path   the portal has a Deployment + Ingress; the be-gateway no longer has
#                the host or its rows; casdoor-games is published; ingress-nginx
#                reaches exactly those two pods; cloudflared rules sit above the
#                wildcard.
#   stores       the BFF names its Postgres + Cassandra; the ESO secret, the Vault write
#                and the registry agree; both stores are off the broad from-set.
#   egress       tier-egress carries the paths both realms need, before anyone carves
#                it into the manual overlay.
#   images       the kustomize image names are the published set.
#   builders     parameterize_games_domain(), run for real over a scratch tree from
#                BOTH builders; the RELEASE_STATE=internal Ingress class rewrite; the
#                games-deselected prune.
#
# NOT PINNED: whether the BFF image reads these variables, which is hugmesh-games'
# own test suite, and whether any of it works on a live cluster.
#
# Negative controls: each mutation goes on a scratch copy, the copy must really differ,
# and the analyser must go RED naming the planted defect.
#
# Offline: bash + python3 + PyYAML. No cluster, no docker, no network.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required (refusing to skip)" >&2; exit 2; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/games-two-realms.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
ANALYSER="${WORK}/analyser.py"

cat > "${ANALYSER}" <<'PY'
import os, re, sys
import yaml

root = sys.argv[1]
C = os.path.join(root, "specs/cluster")
M = os.path.join(C, "manifests")
F = 0
def ok(m): print("  PASS " + m)
def bad(m):
    global F
    F += 1
    print("  FAIL " + m)
def docs(p): return [d for d in yaml.safe_load_all(open(p)) if d]
def text(p): return open(p, errors="replace").read()
def uncommented(p): return "\n".join(l for l in text(p).splitlines() if not l.lstrip().startswith("#"))
def check(cond, m):
    (ok if cond else bad)(m)

G_ISS, S_ISS = "https://id.hugmesh.games", "https://id.hugmesh.net"

# ── BFF env ──────────────────────────────────────────────────────────────────
dep = next(d for d in docs(f"{M}/games/deployment.yaml") if d["kind"] == "Deployment")
c = dep["spec"]["template"]["spec"]["containers"][0]
env = {e["name"]: e for e in c["env"]}
val = lambda n: (env.get(n) or {}).get("value")
check(val("APP_TENANCY_ISSUERS") == f"{G_ISS}=default,{S_ISS}=default", "[bff] both issuers map to ONE domain")
check(val("APP_TENANCY_JWKS_URIS") == f"{G_ISS}=http://casdoor-games.hugmesh-games.svc.cluster.local:8000/.well-known/jwks,{S_ISS}=http://casdoor.hugmesh-pki.svc.cluster.local:8000/.well-known/jwks",
      "[bff] each issuer has its own in-cluster JWKS")
check(val("APP_SECURITY_GAMES_REALM_ISSUERS") == G_ISS, "[bff] only the games issuer's `admin` makes a games admin")
check("APP_TENANCY_DOMAIN" not in env, "[bff] APP_TENANCY_DOMAIN unset: the domain comes from the validated iss")
check(val("DB_HOST") == "games-bff-db" and val("DB_NAME") == "threewizards", "[bff] names its own Postgres")
for k in ("DB_USER", "DB_PASS"):
    ref = ((env.get(k) or {}).get("valueFrom") or {}).get("secretKeyRef") or {}
    check(ref.get("name") == "games-bff-db", f"[bff] {k} comes from the games-bff-db Secret")
check(val("CASSANDRA_CONTACT_POINTS") == "games-cassandra:9042", "[bff] names its own Cassandra")
check(val("CASSANDRA_LOCAL_DC") == "datacenter1", "[bff] local DC is what the image's SimpleSnitch advertises")
check(val("APP_SECURITY_REQUIRE_MANAGED_SECRETS") == "true", "[bff] refuses a blank secret at boot")

# ── route-access ─────────────────────────────────────────────────────────────
sql = text(f"{M}/route-access/initdb/20-schema.sql")
rows = set(re.findall(r"^\s*\('(hugmesh-[a-z]+-gateway)',\s*'([^']+)',\s*'([^']+)',\s*true\)", sql, re.M))
FE, BE = "hugmesh-fe-gateway", "hugmesh-be-gateway"
for pat in ("/games/api/**", "/games/**"):
    check((FE, pat, "ROLE_GAMES") in rows and (FE, pat, "ROLE_ADMIN") in rows, f"[routes] fe {pat} admits ROLE_GAMES + ROLE_ADMIN")
    check((FE, pat, "ROLE_MOD") not in rows, f"[routes] fe {pat} does NOT admit a bare ROLE_MOD")
check((FE, "/games/api/admin/**", "ROLE_GAMES_ADMIN") in rows, "[routes] fe admin API keeps ROLE_GAMES_ADMIN")
check(not [r for r in rows if r[0] == BE and r[1] in ("/games/**", "/games/api/admin/**")], "[routes] be-gateway carries no games portal rows")
check("'hugmesh-fe-gateway'" in sql and re.search(r"DELETE FROM gateway_route_access\s+WHERE gateway = 'hugmesh-be-gateway'\s+AND url_pattern IN \('/games/api/admin/'", sql) is not None,
      "[routes] a re-apply retires the be rows on an existing database")
check(re.search(r"AND url_pattern IN \('/games/api/' \|\| '\*\*', '/games/' \|\| '\*\*'\)\s+AND role = 'ROLE_MOD'", sql) is not None,
      "[routes] a re-apply retires the fe ROLE_MOD rows on an existing database")
seed = text(f"{root}/tests/e2e/specs/rbac-route-access.seed.ts")
check("urlPattern: '/games/api/**', role: 'ROLE_MOD'" not in seed and "urlPattern: '/games/**', role: 'ROLE_MOD'" not in seed, "[routes] the e2e oracle's seed mirrors the SQL")

# ── be-gateway off the portal host ───────────────────────────────────────────
be = uncommented(f"{C}/apps/20-gateway-be.yaml")
check(not re.search(r"^\s*- id: games\s*$", be, re.M), "[be] no `games` host route")
check("games.hugmesh.net" not in be, "[be] no games.<domain> extraHost")
opt = yaml.safe_load(text(f"{C}/optional-services.yaml"))
items = opt.get("services") if isinstance(opt, dict) and "services" in opt else None
if items is None:
    def find(o):
        if isinstance(o, list):
            for x in o:
                if isinstance(x, dict) and x.get("slug") == "games":
                    return x
                r = find(x)
                if r: return r
        elif isinstance(o, dict):
            for x in o.values():
                r = find(x)
                if r: return r
    g = find(opt)
else:
    g = next(x for x in items if x.get("slug") == "games")
check("games" not in g["gatewayRouteIds"], "[opt] gatewayRouteIds no longer names `games`")
check(not [r for r in g["routeAccessRows"] if r["gateway"] == BE and r["urlPattern"] in ("/games/**", "/games/api/admin/**")], "[opt] routeAccessRows no longer names the be rows")
check("manifests/games-portal" in g["extraManifestPaths"], "[opt] extraManifestPaths owns manifests/games-portal")
check("apps/50a-games-ui.yaml" in g["apps"], "[opt] apps owns 50a-games-ui.yaml")
check("games-bff-db" in g["esoKeys"], "[opt] esoKeys owns games-bff-db")

# ── the mesh remote has an Application ───────────────────────────────────────
try:
    ui = docs(f"{C}/apps/50a-games-ui.yaml")[0]
    check(ui["spec"]["source"]["path"] == "specs/cluster/manifests/games-ui" and ui["spec"]["destination"]["namespace"] == "hugmesh-frontend",
          "[ui] an Application deploys manifests/games-ui into hugmesh-frontend")
except OSError:
    bad("[ui] apps/50a-games-ui.yaml is missing, so the fe-gateway games-ui route has nothing behind it")

# ── the portal ───────────────────────────────────────────────────────────────
pk = yaml.safe_load(text(f"{M}/games/kustomization.yaml"))
check("../games-portal" in pk["resources"], "[portal] reached from the games kustomization")
for r in ("bff-db.yaml", "cassandra.yaml", "cassandra-init.yaml"):
    check(r in pk["resources"], f"[stores] {r} listed in the games kustomization")
UPSTREAMS = {"api", "login", "registration", "producer-registration", "banned", "admin", "mod", "publisher",
             "api-docs", "games-three-wizards", "games-dodecahedron", "games-rpg-maker", "games-vn-maker",
             "rpg-builder", "vn-builder", "wasm-fragment"}
svcs = {d["metadata"]["name"]: d for d in docs(f"{M}/games-portal/service.yaml")}
check(UPSTREAMS <= set(svcs), "[portal] every upstream the image's nginx.conf resolves at startup has a Service")
check(svcs["api"]["spec"]["selector"] == {"app": "hugmesh-games"}, "[portal] Service `api` is the games BFF")
sib = os.environ.get("GAMES_SRC") or os.path.join(root, "..", "hugmesh-games")
ngx = os.path.join(sib, "frontend", "nginx.conf")
if os.path.isfile(ngx):
    used = set(re.findall(r"proxy_pass http://([a-z-]+):8080", text(ngx)))
    check(used <= set(svcs), f"[portal] against the sibling checkout: nginx.conf upstreams {sorted(used - set(svcs)) or 'all'} covered")
else:
    print("  INFO [portal] no hugmesh-games checkout: the upstream list is checked against the list pinned here, not the image's nginx.conf")
pc = next(d for d in docs(f"{M}/games-portal/deployment.yaml") if d["kind"] == "Deployment")["spec"]["template"]["spec"]["containers"][0]
check(set(pc["securityContext"]["capabilities"]["add"]) == {"CHOWN", "SETUID", "SETGID"} and pc["securityContext"]["allowPrivilegeEscalation"] is False,
      "[portal] the measured capability set, no privilege escalation")
def ingress(p):
    d = next(x for x in docs(p) if x["kind"] == "Ingress")
    r = d["spec"]["rules"][0]
    return d["spec"]["ingressClassName"], r["host"], r["http"]["paths"][0]["backend"]["service"]["name"]
check(ingress(f"{M}/games-portal/ingress.yaml") == ("nginx", "games.hugmesh.net", "hugmesh-games-portal"), "[portal] Ingress at games.<domain> straight to the portal")
check(ingress(f"{M}/casdoor-games/ingress.yaml") == ("nginx", "id.hugmesh.games", "casdoor-games"), "[issuer] Ingress at the issuer host straight to casdoor-games")
check("ingress.yaml" in text(f"{M}/casdoor-games/kustomization.yaml"), "[issuer] Ingress listed in the casdoor-games kustomization")
check(f'origin = "{G_ISS}"' in text(f"{M}/casdoor-games/app-conf-configmap.yaml"), "[issuer] Casdoor origin is the literal the builders rewrite")

# ── cloudflared ──────────────────────────────────────────────────────────────
cf = yaml.safe_load(docs(f"{M}/cloudflared/configmap.yaml")[0]["data"]["config.yaml"])["ingress"]
hosts = [r.get("hostname") for r in cf]
wild = hosts.index("*.hugmesh.net")
for h in ("games.hugmesh.net", "id.hugmesh.games"):
    check(h in hosts and hosts.index(h) < wild, f"[tunnel] {h} sits above the *.<domain> wildcard")

# ── ingress netpols ──────────────────────────────────────────────────────────
ti = {(d["metadata"]["namespace"], d["metadata"]["name"]): d for d in docs(f"{M}/networkpolicy/tier-ingress.yaml")}
door = ti.get(("hugmesh-games", "games-ingress-doors"))
if door is None:
    bad("[netpol] no policy admits ingress-nginx to the portal and the issuer; the Ingresses would time out")
else:
    vals = door["spec"]["podSelector"]["matchExpressions"][0]["values"]
    check(set(vals) == {"casdoor-games", "hugmesh-games-portal"}, "[netpol] ingress-nginx reaches exactly the portal and the issuer")
    peers = door["spec"]["ingress"][0]["from"]
    check([p["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"] for p in peers] == ["ingress-nginx"], "[netpol] only the ingress-nginx namespace is the peer")
tier = next(d for k, d in ti.items() if k[0] == "hugmesh-games" and k[1] != "games-ingress-doors")
notin = tier["spec"]["podSelector"]["matchExpressions"][0]["values"]
check({"casdoor-games-pg", "games-bff-db", "games-cassandra"} <= set(notin), "[netpol] the games stores are off the broad from-set")
di = {d["metadata"]["name"]: d for d in docs(f"{M}/networkpolicy/db-ingress.yaml")}
for name, want in (("db-ingress-games-bff-db", {"hugmesh-games"}), ("db-ingress-games-cassandra", {"hugmesh-games", "games-cassandra-init"})):
    d = di.get(name)
    got = {p["podSelector"]["matchLabels"]["app"] for p in d["spec"]["ingress"][0]["from"]} if d else None
    check(got == want, f"[netpol] {name} admits exactly {sorted(want)}")
jw = {d["metadata"]["name"]: d for d in docs(f"{M}/networkpolicy/casdoor-jwks-ingress.yaml")}
check("games-bff-to-casdoor-jwks" in jw, "[netpol] games BFF -> casdoor.hugmesh-pki:8000 is admitted")

# ── tier-egress, latent until carved ─────────────────────────────────────────
te = docs(f"{M}/networkpolicy/tier-egress.yaml")
def rules(ns, name="tier-egress"):
    d = next((x for x in te if x["metadata"]["namespace"] == ns and x["metadata"]["name"] == name), None)
    return (d or {}).get("spec", {}).get("egress", [])
def allows(ns, peer, port):
    for r in rules(ns):
        names = [p.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name") for p in r.get("to", [])]
        if peer in names:
            ports = r.get("ports")
            if ports is None or any(x.get("port") == port for x in ports):
                return True
    return False
check(allows("hugmesh-frontend", "hugmesh-games", 8080), "[egress] fe-gateway -> games BFF :8080")
check(allows("hugmesh-backend", "hugmesh-games", 8000) and allows("hugmesh-backend", "hugmesh-games", 8080), "[egress] backend -> casdoor-games :8000 + games :8080")
check(allows("hugmesh-games", "hugmesh-pki", 8000), "[egress] games -> systems Casdoor :8000 (key fetch)")
pub = next((x for x in te if x["metadata"]["namespace"] == "hugmesh-games" and x["metadata"]["name"] == "casdoor-games-public-egress"), None)
if pub is None:
    bad("[egress] casdoor-games has no public path, so GitHub OAuth dies at the carve")
else:
    check(pub["spec"]["podSelector"] == {"matchLabels": {"app": "casdoor-games"}}, "[egress] the public path is casdoor-games only")
    rule = pub["spec"]["egress"][0]
    check([p["port"] for p in rule["ports"]] == [443], "[egress] the public path is :443 only")
    check({"10.244.0.0/16", "10.96.0.0/12", "100.64.0.0/10"} <= set(rule["to"][0]["ipBlock"]["except"]), "[egress] the public path excludes the cluster CIDRs")
check("- tier-egress.yaml" not in uncommented(f"{M}/networkpolicy/kustomization.yaml"), "[egress] tier-egress stays out of the auto-sync app")

# ── secrets ──────────────────────────────────────────────────────────────────
es = next((d for d in docs(f"{M}/external-secrets/secretstore.yaml") if d["metadata"].get("name") == "games-bff-db"), None)
if es is None:
    bad("[eso] no ExternalSecret games-bff-db")
else:
    ref = es["spec"]["data"][0]["remoteRef"]
    check(es["metadata"]["namespace"] == "hugmesh-games" and ref == {"key": "hugmesh/games-bff", "property": "db_password_plain"}, "[eso] games-bff-db reads hugmesh/games-bff db_password_plain")
gs = text(f"{root}/scripts/gen-cluster-secrets.sh")
check('/games-bff" \\\n            db_password_plain="${GAMES_BFF_DB_PASSWORD}"' in gs, "[eso] the online write mints that key")
check('"games-bff-db": {' in gs and 'GAMES_BFF_DB_PASSWORD="${GAMES_BFF_DB_PASSWORD}" \\' in gs, "[eso] the offline bundle carries it too")

# ── images ───────────────────────────────────────────────────────────────────
tsv = next(l for l in text(f"{root}/scripts/release/repos.tsv").splitlines() if l.startswith("9|hugmesh-games|"))
published = set(tsv.split("|")[6].split())
imgs = {}
for k in ("games", "games-ui", "games-portal"):
    for i in yaml.safe_load(text(f"{M}/{k}/kustomization.yaml")).get("images", []):
        imgs[i["name"]] = i["newName"]
PFX = "registry.hugmesh.net/hugmesh/"
for name, want in (("hugmesh/hugmesh.games-backend", "hugmesh-games/backend"), ("hugmesh/games-portal", "hugmesh-games/frontend")):
    new = imgs.get(name, "")
    check(new == PFX + want and want in published, f"[images] {name} -> {new} is in the published set")
check(imgs.get("hugmesh/games-ui") == PFX + "hugmesh-games/games-ui", "[images] games-ui is named under the repo's image path (publishing it is a hugmesh-games change)")

# ── comments that used to describe a system that does not exist ──────────────
for rel, phrase in (("tests/stack/compose.games.yaml", "two-realm portal"),
                    ("tests/stack/compose.games.yaml", "hasRole ADMIN"),
                    ("specs/cluster/manifests/games-ui/deployment.yaml", "two-realm portal"),
                    ("specs/cluster/manifests/games-ui/deployment.yaml", "DEFERRED"),
                    ("specs/cluster/apps/20-gateway-fe.yaml", "DEFERRED, stated honestly: on the CLUSTER the games BFF"),
                    ("specs/cluster/manifests/games/deployment.yaml", "iss-strict JwtIssuerValidator")):
    check(phrase not in text(os.path.join(root, rel)), f"[docs] {rel} no longer says {phrase!r}")

print(f"== analyser: {F} failure(s) ==")
sys.exit(1 if F else 0)
PY

P=0; N=0
ok(){ P=$((P+1)); echo "  PASS $*"; }
bad(){ N=$((N+1)); echo "  FAIL $*"; }

echo "== static wiring =="
python3 "${ANALYSER}" "${REPO}" && ok "the analyser is green on this tree" || bad "the analyser is red on this tree"

# ── the builders, for real ───────────────────────────────────────────────────
echo "== parameterize_games_domain(), run from each builder =="
extract_fn(){ # $1 builder, $2 function
  sed -n "/^$2() {/,/^}/p" "$1"
}
run_param(){ # $1 builder, $2 GAMES_DOMAIN, $3 CLUSTER_DOMAIN -> echoes sysroot
  local builder="$1"
  local gd="$2"
  local cd="$3"
  local s
  s="$(mktemp -d "${WORK}/sys.XXXXXX")"
  mkdir -p "${s}/var/lib/hugmesh"
  cp -r "${REPO}/specs/cluster" "${s}/var/lib/hugmesh/cluster"
  ( info(){ :; }
    SYSROOT="${s}"; GAMES_DOMAIN="${gd}"; CLUSTER_DOMAIN="${cd}"
    eval "$(extract_fn "${REPO}/build-x86-host-stage4.sh" _sed_rep_escape)"
    eval "$(extract_fn "${REPO}/${builder}" parameterize_games_domain)"
    parameterize_games_domain ) >/dev/null 2>&1 || { echo "RUN-FAILED"; return 1; }
  echo "${s}"
}
judge_param(){ # $1 sysroot, $2 want issuer host, $3 want portal host, $4 label
  python3 - "$1" "$2" "$3" "$4" <<'PY'
import re, sys, yaml
s, gid, portal, label = sys.argv[1:5]
t = f"{s}/var/lib/hugmesh/cluster/manifests"
fails = []
def need(cond, m):
    if not cond: fails.append(m)
dep = next(d for d in yaml.safe_load_all(open(f"{t}/games/deployment.yaml")) if d and d["kind"] == "Deployment")
env = {e["name"]: e.get("value") for e in dep["spec"]["template"]["spec"]["containers"][0]["env"]}
iss = f"https://{gid}"
need(env["CASDOOR_ISSUER_URI"] == iss, f"CASDOOR_ISSUER_URI={env['CASDOOR_ISSUER_URI']}")
need(env["APP_SECURITY_GAMES_REALM_ISSUERS"] == iss, "games-realm issuer list")
need(env["APP_TENANCY_ISSUERS"].startswith(f"{iss}=default,"), f"APP_TENANCY_ISSUERS={env['APP_TENANCY_ISSUERS']}")
need(env["APP_TENANCY_JWKS_URIS"].startswith(f"{iss}=http://casdoor-games."), "JWKS map key")
need(f'origin = "{iss}"' in open(f"{t}/casdoor-games/app-conf-configmap.yaml").read(), "Casdoor origin")
ing = next(d for d in yaml.safe_load_all(open(f"{t}/casdoor-games/ingress.yaml")) if d)
need(ing["spec"]["rules"][0]["host"] == gid, f"issuer Ingress host {ing['spec']['rules'][0]['host']}")
ing = next(d for d in yaml.safe_load_all(open(f"{t}/games-portal/ingress.yaml")) if d)
need(ing["spec"]["rules"][0]["host"] == portal, f"portal Ingress host {ing['spec']['rules'][0]['host']}")
cf = yaml.safe_load(next(d for d in yaml.safe_load_all(open(f"{t}/cloudflared/configmap.yaml")) if d)["data"]["config.yaml"])["ingress"]
hosts = [r.get("hostname") for r in cf]
need(gid in hosts and portal in hosts, f"tunnel hosts {hosts}")
kust = open(f"{t}/games/kustomization.yaml").read()
need("hugmesh/hugmesh.games-backend" in kust, "the canonical image placeholder must survive the rewrite")
if fails:
    print(f"  FAIL {label}: " + "; ".join(fails)); sys.exit(1)
print(f"  PASS {label}: issuer {gid}, portal {portal}, in lockstep")
PY
}
for b in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
  while IFS='|' read -r gd cd gid portal; do
    s="$(run_param "${b}" "${gd}" "${cd}")"
    if [ "${s}" = "RUN-FAILED" ] || [ ! -d "${s}" ]; then bad "${b} ${gd}: the function did not run"; continue; fi
    if judge_param "${s}" "${gid}" "${portal}" "${b} GAMES_DOMAIN=${gd}"; then P=$((P+1)); else N=$((N+1)); fi
    rm -rf "${s}"
  done <<'CASES'
games.hugmesh.net|hugmesh.net|games-id.hugmesh.net|games.hugmesh.net
games.acme.example|acme.example|games-id.acme.example|games.acme.example
acme.games|acme.example|id.acme.games|acme.games
hugmesh.games|hugmesh.net|id.hugmesh.games|hugmesh.games
CASES
done

echo "== RELEASE_STATE=internal, from each builder =="
for b in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
  s="$(mktemp -d "${WORK}/int.XXXXXX")"
  mkdir -p "${s}/var/lib/hugmesh"
  cp -r "${REPO}/specs/cluster" "${s}/var/lib/hugmesh/cluster"
  ( info(){ :; }; warn(){ :; }
    SYSROOT="${s}"; ENV=prod; RELEASE_STATE=internal; CLUSTER_DOMAIN=hugmesh.net
    eval "$(extract_fn "${REPO}/${b}" gate_env_apps)"
    gate_env_apps ) >/dev/null 2>&1
  t="${s}/var/lib/hugmesh/cluster/manifests"
  if grep -q '^  ingressClassName: nginx-internal$' "${t}/games-portal/ingress.yaml" \
     && grep -q '^  ingressClassName: nginx-internal$' "${t}/casdoor-games/ingress.yaml"; then
    ok "${b}: both games Ingresses move to nginx-internal"
  else bad "${b}: a games Ingress keeps the public class on an internal mesh (no controller answers it)"; fi
  # Pick out the doors policy only: an untouched rule elsewhere must not satisfy this.
  if python3 - "${t}/networkpolicy/tier-ingress.yaml" <<'PY'
import sys, yaml
d = next(x for x in yaml.safe_load_all(open(sys.argv[1])) if x and x["metadata"]["name"] == "games-ingress-doors")
n = d["spec"]["ingress"][0]["from"][0]["namespaceSelector"]["matchLabels"]["kubernetes.io/metadata.name"]
sys.exit(0 if n == "ingress-nginx-internal" else 1)
PY
  then ok "${b}: the doors policy admits ingress-nginx-internal"
  else bad "${b}: the doors policy still names the public controller on an internal mesh"; fi
  rm -rf "${s}"
done

echo "== a games-deselected build =="
s="$(mktemp -d "${WORK}/prune.XXXXXX")"
mkdir -p "${s}/var/lib/hugmesh"
cp -r "${REPO}/specs/cluster" "${s}/var/lib/hugmesh/cluster"
( info(){ :; }; warn(){ :; }
  # shellcheck source=/dev/null
  . "${REPO}/scripts/_optional-services-lib.sh"
  SYSROOT="${s}"; OPTIONAL_SERVICES=""; EXCLUDE_SERVICES=""; ENABLE_GAMES=0
  USER_LEVEL_SERVICES="akkoma tuwunel phpbb games owncast tube character-studio character-forge"
  gate_optional_services ) >"${WORK}/prune.log" 2>&1
T="${s}/var/lib/hugmesh/cluster"
for p in manifests/games-portal manifests/casdoor-games manifests/games manifests/games-ui apps/50a-games-ui.yaml; do
  [ ! -e "${T}/${p}" ] && ok "pruned: ${p}" || bad "${p} survives a games-deselected build"
done
if [ -f "${T}/manifests/cloudflared/configmap.yaml" ]; then
  if grep -Eq 'hostname: (games\.hugmesh\.net|id\.hugmesh\.games)$' "${T}/manifests/cloudflared/configmap.yaml"; then
    bad "the tunnel keeps a games hostname on a games-deselected build"
  else ok "the tunnel carries no games hostname"; fi
  python3 - "${T}/manifests/cloudflared/configmap.yaml" <<'PY' && ok "the tunnel config still parses, wildcard intact" || bad "the prune corrupted the tunnel config"
import sys, yaml
d = next(x for x in yaml.safe_load_all(open(sys.argv[1])) if x)
hosts = [r.get("hostname") for r in yaml.safe_load(d["data"]["config.yaml"])["ingress"]]
sys.exit(0 if "*.hugmesh.net" in hosts and hosts[-1] is None else 1)
PY
else
  bad "the prune run lost the tunnel config: $(tail -3 "${WORK}/prune.log" | tr '\n' ' ')"
fi
rm -rf "${s}"

# ── negative controls ────────────────────────────────────────────────────────
echo "== negative controls =="
expect_red(){ # $1 label, $2 string the failure must name, $3 python mutation (p = root)
  local label="$1"
  local want="$2"
  local mut="$3"
  local T="${WORK}/mut"
  rm -rf "${T}"; mkdir -p "${T}/specs" "${T}/tests/e2e/specs" "${T}/tests/stack" "${T}/scripts/release"
  cp -r "${REPO}/specs/cluster" "${T}/specs/cluster"
  cp "${REPO}/tests/e2e/specs/rbac-route-access.seed.ts" "${T}/tests/e2e/specs/"
  cp "${REPO}/tests/stack/compose.games.yaml" "${T}/tests/stack/"
  cp "${REPO}/scripts/gen-cluster-secrets.sh" "${T}/scripts/"
  cp "${REPO}/scripts/release/repos.tsv" "${T}/scripts/release/"
  local before after out
  before="$(cd "${T}" && find . -type f -exec cat {} + | sha256sum)"
  python3 - "${T}" <<PYM || { bad "${label}: the mutation script failed"; return; }
import os, sys
root = sys.argv[1]
def rep(rel, old, new):
    p = os.path.join(root, rel); t = open(p).read()
    assert old in t, "anchor missing: " + old
    open(p, "w").write(t.replace(old, new))
M = "specs/cluster/manifests/"
${mut}
PYM
  after="$(cd "${T}" && find . -type f -exec cat {} + | sha256sum)"
  if [ "${before}" = "${after}" ]; then bad "${label}: the mutation changed nothing (the control is vacuous)"; return; fi
  out="$(python3 "${ANALYSER}" "${T}" 2>&1)"
  if [ $? -eq 0 ]; then bad "${label}: the analyser stayed GREEN"; return; fi
  if ! printf '%s\n' "${out}" | grep -aF -- "${want}" | grep -a 'FAIL' >/dev/null; then
    bad "${label}: RED, but not for the planted reason (wanted ${want}); got: $(printf '%s\n' "${out}" | grep -a FAIL | head -2 | tr '\n' ' ')"; return
  fi
  ok "negative control: ${label}"
}
expect_red "the be-gateway host route returns" "no \`games\` host route" 'rep("specs/cluster/apps/20-gateway-be.yaml", "          - id: games-servers-console\n", "          - id: games\n            host: games.hugmesh.net\n            uri: http://x:8080\n          - id: games-servers-console\n")'
expect_red "ROLE_MOD back on the fe member API" "does NOT admit a bare ROLE_MOD" 'rep(M+"route-access/initdb/20-schema.sql", "  (\x27hugmesh-fe-gateway\x27,  \x27/games/api/**\x27,         \x27ROLE_ADMIN\x27,     true),", "  (\x27hugmesh-fe-gateway\x27,  \x27/games/api/**\x27,         \x27ROLE_MOD\x27,     true),\n  (\x27hugmesh-fe-gateway\x27,  \x27/games/api/**\x27,         \x27ROLE_ADMIN\x27,     true),")'
expect_red "the realms stamped with two domains" "both issuers map to ONE domain" 'rep(M+"games/deployment.yaml", "https://id.hugmesh.net=default", "https://id.hugmesh.net=mesh")'
expect_red "mesh admin treated as a games admin" "only the games issuer" 'rep(M+"games/deployment.yaml", "APP_SECURITY_GAMES_REALM_ISSUERS, value: \"https://id.hugmesh.games\"", "APP_SECURITY_GAMES_REALM_ISSUERS, value: \"https://id.hugmesh.games,https://id.hugmesh.net\"")'
expect_red "the BFF loses its Postgres" "names its own Postgres" 'rep(M+"games/deployment.yaml", "name: DB_HOST, value: games-bff-db", "name: DB_HOST, value: localhost")'
expect_red "the portal Ingress points at the BFF" "straight to the portal" 'rep(M+"games-portal/ingress.yaml", "name: hugmesh-games-portal\n                port", "name: hugmesh-games\n                port")'
expect_red "one portal upstream Service removed" "has a Service" 'rep(M+"games-portal/service.yaml", "  name: mod\n", "  name: moderator\n")'
expect_red "the tunnel rule falls below the wildcard" "sits above the *.<domain> wildcard" 'rep(M+"cloudflared/configmap.yaml", "      - hostname: id.hugmesh.games\n        service: https://ingress-nginx-controller.ingress-nginx.svc.cluster.local:443\n        originRequest: { noTLSVerify: true }\n", "")'
expect_red "ingress-nginx admitted to the BFF" "exactly the portal and the issuer" 'rep(M+"networkpolicy/tier-ingress.yaml", "values: [casdoor-games, hugmesh-games-portal]", "values: [casdoor-games, hugmesh-games-portal, hugmesh-games]")'
expect_red "games-bff-db back on the broad from-set" "off the broad from-set" 'rep(M+"networkpolicy/tier-ingress.yaml", "values: [casdoor-games-pg, games-bff-db, games-cassandra]", "values: [casdoor-games-pg]")'
expect_red "the frontend egress loses the games BFF" "fe-gateway -> games BFF" 'rep(M+"networkpolicy/tier-egress.yaml", "    # 2a. fe-gateway -> the games BFF (the games-bff route, a mesh user\x27s /games/api/**).\n    - to:\n        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: hugmesh-games } }\n      ports:\n        - { protocol: TCP, port: 8080 }\n", "")'
expect_red "the public egress widened to all ports" "the public path is :443 only" 'rep(M+"networkpolicy/tier-egress.yaml", "              - 100.64.0.0/10   # tailnet/CGNAT (control plane — direct)\n      ports:\n        - { protocol: TCP, port: 443 }\n", "              - 100.64.0.0/10   # tailnet/CGNAT (control plane — direct)\n      ports:\n        - { protocol: TCP, port: 443 }\n        - { protocol: TCP, port: 80 }\n")'
expect_red "the ESO key renamed" "games-bff-db reads" 'rep(M+"external-secrets/secretstore.yaml", "key: hugmesh/games-bff", "key: hugmesh/games-bff-renamed")'
expect_red "the dotted image name returns" "is in the published set" 'rep(M+"games/kustomization.yaml", "hugmesh/hugmesh-games/backend", "hugmesh/hugmesh.games/backend")'
expect_red "the stale comment returns" "no longer says" 'rep("tests/stack/compose.games.yaml", "the standalone games-realm portal", "the standalone two-realm portal")'

echo
echo "== test-games-two-realms: ${P} passed, ${N} failed =="
[ "${N}" -eq 0 ] || exit 1
