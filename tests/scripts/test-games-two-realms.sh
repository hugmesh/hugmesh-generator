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
#   images       the kustomize image names are the published set; the backend image is
#                judged RENDERED (kubectl kustomize), not by the newTag text: the string
#                must be exactly what the images: entry composes (no patch replaces it),
#                the tag is a sha-<12>, a release, or the placeholder that resolves to
#                nothing (and then no digest may ride along: a runtime pulls by digest
#                and ignores the tag), never a floating name. For a sha-/release tag the
#                public registry is asked for the tag's manifest: a pinned digest must
#                equal it, and the image's revision label must be a hugmesh-games main
#                commit at or after #52's merge (3ae21def).
#   stores (2)   the keyspace Job is a Sync-phase hook in a wave between the stores and
#                the BFF: a PostSync hook in the same Application as the pod that needs
#                the keyspace never runs.
#   casdoor      no Casdoor app.conf relies on in-app `${ENV||default}` interpolation
#                (casbin/casdoor does not expand it inside a value; the as-shipped
#                casdoor-games conf could never connect): every __TOKEN__ in the template
#                is rendered by a render-app-conf initContainer the pod mounts.
#   sync         hugmesh-actions' GM mirror into the games realm is OFF: GM_SYNC_ENABLED
#                is not true, no games-side client in the pod, first tick 100 years out,
#                no backend -> games egress, no `mesh-*` role seeded, every seeded
#                description fits Casdoor's varchar(100).
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
# bash + python3 + PyYAML + kubectl (for `kubectl kustomize`; no cluster, no docker).
# Offline, except the pinned-build proof: ghcr.io (anonymous manifest reads) and a
# commit-graph-only clone of the public hugmesh-games repo. Both are REQUIRED in CI and
# reported as NOT VERIFIED offline; a placeholder tag needs no call.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FATAL: curl required for the registry reads (refusing to skip)" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required (refusing to skip)" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "FATAL: kubectl required for kubectl kustomize (refusing to skip)" >&2; exit 2; }
export KUBECONFIG=/dev/null

WORK="$(mktemp -d "${TMPDIR:-/tmp}/games-two-realms.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT
ANALYSER="${WORK}/analyser.py"

cat > "${ANALYSER}" <<'PY'
import os, re, subprocess, sys
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
def reaches(ns, peer):
    return any(peer in [p.get("namespaceSelector", {}).get("matchLabels", {}).get("kubernetes.io/metadata.name") for p in r.get("to", [])]
               for r in rules(ns))
check(allows("hugmesh-frontend", "hugmesh-games", 8080), "[egress] fe-gateway -> games BFF :8080")
check(not reaches("hugmesh-backend", "hugmesh-games"), "[egress] backend has no path to hugmesh-games (the sync is off; a mesh user's /games goes through the fe-gateway)")
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

# ── the backend image, as RENDERED: pinned to a build at or after hugmesh-games#52 ──
# The rule is enforced on `kubectl kustomize` output, not on the newTag text: a digest
# next to the placeholder renders `backend:needs-...@sha256:...`, which a runtime pulls
# by digest with the tag ignored, and a JSON6902/strategic patch on the container image
# renders whatever it likes while the images: entry still reads as pinned.
PLACEHOLDER = "needs-hugmesh-games-pr52"
SHA_TAG = re.compile(r"^sha-[0-9a-f]{12}$")
RELEASE_TAG = re.compile(r"^\d+\.\d+\.\d+(-[0-9A-Za-z.]+)?$")
DIGEST = re.compile(r"^sha256:[0-9a-f]{64}$")
def split_ref(ref):
    rest, _, digest = ref.partition("@")
    name, tag = rest, ""
    if ":" in rest.rsplit("/", 1)[-1]:
        name, _, tag = rest.rpartition(":")
    return name, tag, digest
bi = next((i for i in pk.get("images", []) if i.get("name") == "hugmesh/hugmesh.games-backend"), {})
composed = f"{bi.get('newName', '')}:{bi.get('newTag', '')}" + (f"@{bi['digest']}" if bi.get("digest") else "")
try:
    rendered_docs = [d for d in yaml.safe_load_all(subprocess.run(["kubectl", "kustomize", f"{M}/games"], check=True, capture_output=True, text=True, env={**os.environ, "KUBECONFIG": "/dev/null"}).stdout) if d]
    rdep = next(d for d in rendered_docs if d["kind"] == "Deployment" and d["metadata"]["name"] == "hugmesh-games")
    rendered = next(c for c in rdep["spec"]["template"]["spec"]["containers"] if c["name"] == "games")["image"]
except Exception as e:  # a render that fails is a FAIL, never a skip
    rendered = ""
    bad(f"[image] kubectl kustomize of manifests/games did not yield the BFF image: {e}")
rname, tag, digest = split_ref(rendered)
check(rendered and rendered == composed, f"[image] the RENDERED backend image {rendered!r} is exactly what the images: entry composes ({composed!r}); nothing patches the container image behind the pin")
check(rname == PFX + "hugmesh-games/backend", f"[image] the rendered backend name is {rname!r}, the published backend under the Harbor host")
check(tag == PLACEHOLDER or SHA_TAG.match(tag) is not None or RELEASE_TAG.match(tag) is not None,
      f"[image] rendered backend tag {tag!r}: the fail-closed placeholder, a sha-<12> or a release, never a floating name (main moves under the cluster and a pre-#52 build accepts a mesh-iss token signed by the games key)")
if tag == PLACEHOLDER:
    check(not digest, f"[image] no digest rides with the placeholder (rendered {rendered!r}: a runtime pulls by digest and ignores the tag, so the placeholder would resolve to a real, unverified image)")
else:
    check(not digest or DIGEST.match(digest) is not None, f"[image] the pinned digest {digest!r} is sha256:<64 hex>")

# ── the keyspace Job runs BEFORE the BFF, inside the same Application ─────────
# PostSync fires only once every resource is Healthy; the BFF names the keyspace with
# schema-action NONE and cannot start without it, so a PostSync keyspace Job and the
# pod that needs it wait for each other forever (the pin above makes that real).
def wave(d):
    return int(((d.get("metadata") or {}).get("annotations") or {}).get("argocd.argoproj.io/sync-wave", "0"))
kj = next((d for d in docs(f"{M}/games/cassandra-init.yaml") if d["kind"] == "Job"), None)
if kj is None:
    bad("[keyspace] no Job in games/cassandra-init.yaml")
else:
    ann = kj["metadata"].get("annotations") or {}
    check(ann.get("argocd.argoproj.io/hook") == "Sync", f"[keyspace] the Job is a Sync-phase hook (hook={ann.get('argocd.argoproj.io/hook')!r}); PostSync in the BFF's own Application never runs")
    check(ann.get("argocd.argoproj.io/hook-delete-policy") == "BeforeHookCreation", "[keyspace] the hook is recreated on every sync (the CQL is IF NOT EXISTS)")
    cass = next(d for d in docs(f"{M}/games/cassandra.yaml") if d["kind"] == "Deployment")
    check(wave(cass) < wave(kj) < wave(dep), f"[keyspace] waves order cassandra ({wave(cass)}) < keyspace Job ({wave(kj)}) < BFF ({wave(dep)})")

# ── no Casdoor app.conf relies on in-app `${ENV||default}` interpolation ──────
# casbin/casdoor expands beego's syntax only when the WHOLE value is one expression;
# `user=${CASDOOR_DB_USER||x} ...` is used literally and the pod exits 2. The systems
# Casdoor was fixed in #263 with a sed render in an initContainer; every Casdoor here
# must carry that shape, with every __TOKEN__ in the template actually rendered.
for cdir, cm_name in (("casdoor", "casdoor-app-conf"), ("casdoor-games", "casdoor-games-app-conf"), ("casdoor-domain", "casdoor-domain-app-conf")):
    cm = next((d for d in docs(f"{M}/{cdir}/app-conf-configmap.yaml") if d["kind"] == "ConfigMap"), {})
    data = cm.get("data") or {}
    tpl = data.get("app.conf.template")
    conf_lines = [l for l in (tpl or data.get("app.conf") or "").splitlines() if not l.lstrip().startswith("#")]
    dsn = next((l for l in conf_lines if l.strip().startswith("dataSourceName")), "")
    check("${" not in dsn, f"[casdoor:{cdir}] dataSourceName carries no `${{` (in-app interpolation never happens inside a value: {dsn.strip()[:60]!r})")
    check(not [l for l in conf_lines if "${" in l], f"[casdoor:{cdir}] no app.conf key relies on in-app `${{ENV||default}}` interpolation")
    check(tpl is not None and "app.conf" not in data, f"[casdoor:{cdir}] the ConfigMap ships app.conf.template (rendered by an initContainer), not a final app.conf")
    cdep = next((d for d in docs(f"{M}/{cdir}/deployment.yaml") if d["kind"] == "Deployment"), None)
    pod = ((cdep or {}).get("spec") or {}).get("template", {}).get("spec", {})
    init = next((c for c in pod.get("initContainers") or [] if c.get("name") == "render-app-conf"), None)
    if init is None:
        bad(f"[casdoor:{cdir}] no render-app-conf initContainer: the template is mounted unrendered and Casdoor exits 2")
        continue
    args = "\n".join(str(a) for a in (init.get("args") or []) + (init.get("command") or []))
    tokens = set(re.findall(r"__[A-Z_]+__", tpl or ""))
    rendered_tokens = set(re.findall(r"s\|(__[A-Z_]+__)\|", args))
    check(tokens and tokens == rendered_tokens, f"[casdoor:{cdir}] every template token is rendered by the initContainer (template {sorted(tokens)}, sed {sorted(rendered_tokens)})")
    ienv = {e["name"] for e in init.get("env") or []}
    check({x.strip("_") for x in tokens} <= ienv, f"[casdoor:{cdir}] the initContainer is handed every token's value (env {sorted(ienv)})")
    imounts = {m["name"]: m["mountPath"] for m in init.get("volumeMounts") or []}
    check(imounts.get("app-conf-template") == "/template" and imounts.get("rendered-conf") == "/rendered" and "/template/app.conf.template" in args and "/rendered/app.conf" in args,
          f"[casdoor:{cdir}] the initContainer reads /template/app.conf.template and writes /rendered/app.conf")
    main = next(c for c in pod["containers"] if c["name"] == "casdoor")
    mm = next((m for m in main.get("volumeMounts") or [] if m.get("mountPath") == "/conf/app.conf"), {})
    check(mm.get("name") == "rendered-conf" and mm.get("subPath") == "app.conf", f"[casdoor:{cdir}] Casdoor mounts the RENDERED app.conf at /conf/app.conf (mount {mm})")
    vols = {v["name"]: v for v in pod.get("volumes") or []}
    check((vols.get("app-conf-template") or {}).get("configMap", {}).get("name") == cm_name and "emptyDir" in (vols.get("rendered-conf") or {}),
          f"[casdoor:{cdir}] app-conf-template is the {cm_name} ConfigMap and rendered-conf is an emptyDir")

# ── the GM sync is off ───────────────────────────────────────────────────────
ad = next(d for d in docs(f"{M}/hugmesh-apis/deployment.yaml") if d["kind"] == "Deployment")
ac = next(c for c in ad["spec"]["template"]["spec"]["containers"] if c["name"] == "api")
aenv = {e["name"]: e for e in ac["env"]}
check(not [k for k in aenv if k.startswith("CASDOOR_GAMES_")], "[sync] hugmesh-api is handed no games-realm client (CASDOOR_GAMES_*)")
check("casdoor-sync-games" not in uncommented(f"{M}/hugmesh-apis/deployment.yaml"), "[sync] no container reads the casdoor-sync-games Secret")
enabled = str((aenv.get("GM_SYNC_ENABLED") or {}).get("value") or "false")
check(enabled.lower() != "true", f"[sync] GM_SYNC_ENABLED is not true (hugmesh-actions#21's flag, default false; value {enabled!r})")
delay = str((aenv.get("GM_SYNC_INITIAL_DELAY_MS") or {}).get("value") or "")
check(delay.isdigit() and int(delay) >= 10 * 365 * 24 * 3600 * 1000, f"[sync] the first tick is at least ten years out (GM_SYNC_INITIAL_DELAY_MS={delay or 'unset'}; an image from before #21 has no enable flag)")
grole = (aenv.get("GM_SYNC_GAMES_ROLE") or {}).get("value")
check(grole is None or str(grole).startswith("mesh-"), f"[sync] no games role the realm owns is named as the mirror target (GM_SYNC_GAMES_ROLE={grole!r})")
for k in ("CASDOOR_PLATFORM_URL", "CASDOOR_PLATFORM_CLIENT_SECRET"):
    check(k in aenv, f"[sync] the systems side ({k}) stays: it also backs the actions resource server")

# ── the games realm's catalog: its own roles, each inside Casdoor's columns ──
import json
init = json.loads(docs(f"{M}/casdoor-games/init-data-configmap.yaml")[0]["data"]["init_data.json"])
seeded = init.get("roles", []) + init.get("permissions", [])
check(seeded and all(len(str(o.get("description", ""))) <= 100 and len(str(o.get("displayName", ""))) <= 100 for o in seeded),
      "[issuer] every seeded role/permission description and displayName fits Casdoor's varchar(100) (a 247-char one made Casdoor exit 2)")
check(not [r for r in init.get("roles", []) if str(r.get("name", "")).startswith("mesh-")],
      "[issuer] no mesh-* role is seeded: games-realm admin comes only from the realm's own `admin`")

# ── comments that used to describe a system that does not exist ──────────────
for rel, phrase in (("tests/stack/compose.games.yaml", "two-realm portal"),
                    ("tests/stack/compose.games.yaml", "hasRole ADMIN"),
                    ("specs/cluster/manifests/games-ui/deployment.yaml", "two-realm portal"),
                    ("specs/cluster/manifests/games-ui/deployment.yaml", "DEFERRED"),
                    ("specs/cluster/apps/20-gateway-fe.yaml", "DEFERRED, stated honestly: on the CLUSTER the games BFF"),
                    ("specs/cluster/manifests/games/deployment.yaml", "iss-strict JwtIssuerValidator"),
                    ("specs/cluster/manifests/hugmesh-apis/deployment.yaml", "The single automatic mirror"),
                    ("specs/cluster/manifests/casdoor-games/kustomization.yaml", "mirror is the scheduled hugmesh-actions"),
                    ("specs/cluster/manifests/networkpolicy/tier-egress.yaml", "hugmesh-actions sync handle"),
                    ("specs/cluster/manifests/casdoor/games-admin-sync-job.yaml", "-> admin (games)"),
                    ("specs/cluster/manifests/casdoor-games/deployment.yaml", "into this realm's \"admin\" role"),
                    ("specs/cluster/manifests/hugmesh-apis/deployment.yaml", "the image has no enable flag"),
                    ("tests/stack/compose.local.yaml", "the image has no enable flag"),
                    ("specs/cluster/manifests/games/kustomization.yaml", "preferably, add its"),
                    ("specs/cluster/manifests/games/cassandra-init.yaml", "ArgoCD PostSync hook, the idiom"),
                    ("specs/cluster/manifests/casdoor-games/app-conf-configmap.yaml", "working scaffold"),
                    ("specs/cluster/manifests/casdoor-domain/app-conf-configmap.yaml", "MUST be validated")):
    check(phrase not in text(os.path.join(root, rel)), f"[docs] {rel} no longer says {phrase!r}")

print(f"== analyser: {F} failure(s) ==")
sys.exit(1 if F else 0)
PY

P=0; N=0
ok(){ P=$((P+1)); echo "  PASS $*"; }
bad(){ N=$((N+1)); echo "  FAIL $*"; }

echo "== static wiring =="
python3 "${ANALYSER}" "${REPO}" && ok "the analyser is green on this tree" || bad "the analyser is red on this tree"

# ── the pinned backend build is at or after hugmesh-games#52 ─────────────────
# Judged on the RENDERED image. A sha-<12>/release tag is looked up on the public
# registry (anonymous pull token): a pinned digest must equal the tag's manifest digest
# (what a runtime pulls; the tag is ignored next to a digest), and the amd64 image's
# org.opencontainers.image.revision label (the Release workflow writes the commit) must
# be a commit on hugmesh-games main at or after #52's merge commit, 3ae21def. The commit
# graph comes from a commit-only clone (--filter=tree:0, no trees, no blobs). Required
# in CI (no network there is a failure, not a skip); offline it is reported, loudly, as
# not verified.
echo "== the pinned backend build =="
PR52_MERGE=3ae21def10e8a09c4a8bb86b4fcbccacdba6549d
GRAPH="${WORK}/hugmesh-games.git"
have_graph(){
  [ -d "${GRAPH}" ] && return 0
  git clone -q --bare --filter=tree:0 --single-branch --branch main --no-tags https://github.com/hugmesh/hugmesh-games.git "${GRAPH}" >/dev/null 2>&1
}
verify_pin(){ # $1 tag, $2 digest ("" = none) -> 0 ok, 1 refused, 2 unreachable; prints why
  python3 - "$1" "$2" "${PR52_MERGE}" "${GRAPH}" <<'PY'
import json, os, re, subprocess, sys, tempfile
tag, digest, floor, graph = sys.argv[1:5]
REPO = "hugmesh/hugmesh-games/backend"
ACCEPT = ", ".join(["application/vnd.oci.image.index.v1+json", "application/vnd.oci.image.manifest.v1+json",
                    "application/vnd.docker.distribution.manifest.list.v2+json", "application/vnd.docker.distribution.manifest.v2+json"])
class NotFound(Exception): pass
# curl, not urllib: a blob GET redirects to a host with four AAAA records, and urllib
# walks each dead IPv6 address to its full timeout (80 s per blob measured on a host
# without IPv6 reach) where curl's happy-eyeballs connect takes a second. curl also drops
# the Authorization header on the cross-host redirect, which the signed blob URL wants.
def get(url, headers, want_headers=False):
    with tempfile.TemporaryDirectory() as d:
        hf, bf = os.path.join(d, "h"), os.path.join(d, "b")
        cmd = ["curl", "-sS", "-L", "--connect-timeout", "10", "--max-time", "60", "-D", hf, "-o", bf, "-w", "%{http_code}"]
        for k, v in headers.items():
            cmd += ["-H", f"{k}: {v}"]
        r = subprocess.run(cmd + [url], capture_output=True, text=True)
        if r.returncode != 0:
            raise RuntimeError(f"curl rc={r.returncode}: {r.stderr.strip()[:160]}")
        code = int((r.stdout.strip() or "0")[-3:])
        if code == 404:
            raise NotFound(url)
        if code >= 400:
            raise RuntimeError(f"HTTP {code} from {url}")
        hdrs = {}
        for line in open(hf, errors="replace"):
            k, sep, v = line.partition(":")
            if sep and k.strip().lower() not in hdrs:
                hdrs[k.strip().lower()] = v.strip()
        body = open(bf, "rb").read()
        return (body, hdrs) if want_headers else body
try:
    tok = json.loads(get(f"https://ghcr.io/token?scope=repository:{REPO}:pull", {}))["token"]
    auth = {"Authorization": f"Bearer {tok}", "Accept": ACCEPT}
    try:
        body, hdrs = get(f"https://ghcr.io/v2/{REPO}/manifests/{tag}", auth, True)
    except NotFound:
        print(f"{tag}: no manifest for this tag on ghcr.io/{REPO} (pin only a tag the Release workflow pushed)"); sys.exit(1)
    dtag = hdrs.get("docker-content-digest", "")
    if not re.match(r"^sha256:[0-9a-f]{64}$", dtag):
        print(f"{tag}: registry returned no Docker-Content-Digest"); sys.exit(2)
    if digest and digest != dtag:
        print(f"{tag}: the pinned digest {digest[:19]}... is NOT this tag's manifest digest {dtag[:19]}...; the cluster would pull the digest, not the tag"); sys.exit(1)
    pulled = digest or dtag
    man = json.loads(get(f"https://ghcr.io/v2/{REPO}/manifests/{pulled}", auth))
    if "manifests" in man:  # an index: the cluster schedules the BFF on amd64
        sub = next((m["digest"] for m in man["manifests"] if (m.get("platform") or {}).get("architecture") == "amd64" and (m.get("platform") or {}).get("os") == "linux"), None)
        if not sub:
            print(f"{tag}: the index {pulled[:19]}... carries no linux/amd64 manifest"); sys.exit(1)
        man = json.loads(get(f"https://ghcr.io/v2/{REPO}/manifests/{sub}", auth))
    cfg = json.loads(get(f"https://ghcr.io/v2/{REPO}/blobs/{man['config']['digest']}", auth))
    rev = ((cfg.get("config") or {}).get("Labels") or {}).get("org.opencontainers.image.revision", "")
except Exception as e:
    print(f"unreachable: ghcr.io/{REPO}:{tag}: {e}"); sys.exit(2)
if not re.match(r"^[0-9a-f]{40}$", rev):
    print(f"{tag}: image {pulled[:19]}... carries no org.opencontainers.image.revision label (not a Release-workflow build)"); sys.exit(1)
if subprocess.run(["git", "-C", graph, "cat-file", "-e", f"{rev}^{{commit}}"], capture_output=True).returncode != 0:
    print(f"{tag}: revision {rev[:12]} is not a commit on hugmesh-games main"); sys.exit(1)
if subprocess.run(["git", "-C", graph, "merge-base", "--is-ancestor", floor, rev], capture_output=True).returncode != 0:
    print(f"{tag}: revision {rev[:12]} is BEFORE #52's merge {floor[:12]} on main (a pre-#52 build)"); sys.exit(1)
print(f"{tag}: manifest {dtag[:19]}..., revision {rev[:12]} is at or after #52's merge {floor[:12]}" + (" and the pinned digest equals the tag's" if digest else " (no digest pinned)")); sys.exit(0)
PY
}
read -r TAG DIGEST < <(python3 - "${REPO}/specs/cluster/manifests/games/kustomization.yaml" <<'PY'
import sys, yaml
k = yaml.safe_load(open(sys.argv[1]))
i = next((i for i in k.get("images", []) if i.get("name") == "hugmesh/hugmesh.games-backend"), {})
print(i.get("newTag") or "-", i.get("digest") or "")
PY
)
case "${TAG}" in
  needs-hugmesh-games-pr52)
    ok "backend tag is the placeholder: it names no image, so no pre-#52 build can start with the two-realm environment (replace it with the sha- tag AND digest of a main build at or after 3ae21def)";;
  sha-????????????|[0-9]*) ;;
  *) bad "backend tag '${TAG}' is a floating name";;
esac
if ! have_graph; then
  if [ -n "${CI:-}" ]; then bad "cannot fetch the hugmesh-games commit graph; CI must reach github.com"; else echo "  NOT VERIFIED (offline): no commit graph, the registry checks are skipped"; fi
else
  if [ "${TAG}" != needs-hugmesh-games-pr52 ] && [ "${TAG}" != "-" ]; then
    why="$(verify_pin "${TAG}" "${DIGEST}")"; rc=$?
    case "${rc}" in
      0) ok "backend pin ${TAG}: ${why}";;
      1) bad "backend pin ${TAG} REFUSED: ${why}";;
      *) if [ -n "${CI:-}" ]; then bad "cannot prove what build ${TAG} is (${why}); CI must reach the public registry"; else echo "  NOT VERIFIED (offline): ${why}"; fi;;
    esac
  fi
  # The verifier itself, against known tags. A verifier that cannot tell these apart
  # proves nothing: the last pre-#52 main build; the refuter's m2 (a tag the Release
  # workflow never pushed, with a pre-#52 digest); a post-#52 tag with a pre-#52 digest;
  # a pre-#52 tag with its OWN correct digest (ancestry, not digest equality, must
  # refuse it); and #52's merge build with its digest.
  PRE52_DIGEST=sha256:fcc3e1ae30a4c504a7a8cdd2948107286f21eaaf1cbab4696b1e251c06808272
  while IFS='|' read -r ctag cdigest want label; do
    why="$(verify_pin "${ctag}" "${cdigest}")"; rc=$?
    if [ "${rc}" -eq 2 ]; then
      if [ -n "${CI:-}" ]; then bad "verifier control: ${why}"; else echo "  NOT VERIFIED (offline): verifier control ${ctag}"; fi
    elif [ "${rc}" -eq "${want}" ]; then ok "verifier control: ${label} -- ${why}"; else bad "verifier control: ${label} -- got rc=${rc}: ${why}"; fi
  done <<CASES
sha-f111cfe3382d||1|the 0.2.0-beta.3 build (pre-#52, no digest) is refused by ancestry
sha-b557b3944d8e|${PRE52_DIGEST}|1|m2: a tag the Release workflow never pushed is refused
sha-3ae21def10e8|${PRE52_DIGEST}|1|a post-#52 tag with the pre-#52 digest is refused (the digest is what gets pulled)
sha-73a5bc2c6d09|sha256:cd6c05b0a1d6f216373493d9460e5e44ca0dd6afc9ddf489ccefb6087b9a8e43|1|a pre-#52 tag with its own correct digest is refused by ancestry alone
sha-3ae21def10e8|sha256:f2142f61a782c1801de91d986182cb7eddd4b8d1a9ce1c6359ca0dd7dea3bcc9|0|#52's merge build with its manifest digest is accepted
CASES
fi

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
  cp "${REPO}/tests/stack/compose.games.yaml" "${REPO}/tests/stack/compose.local.yaml" "${T}/tests/stack/"
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
expect_red "the backend tracks :main again" "never a floating name" 'rep(M+"games/kustomization.yaml", "newTag: sha-3ae21def10e8", "newTag: main")'
expect_red "the backend pinned to a branch tag" "never a floating name" 'rep(M+"games/kustomization.yaml", "newTag: sha-3ae21def10e8", "newTag: fix-games-two-realms")'
expect_red "m1: the placeholder with a digest riding along" "no digest rides with the placeholder" 'rep(M+"games/kustomization.yaml", "newTag: sha-3ae21def10e8", "newTag: needs-hugmesh-games-pr52")'
expect_red "m3: a JSON6902 patch replaces the container image with ghcr :main" "nothing patches the container image" 'rep(M+"games/kustomization.yaml", "patches:\n", "patches:\n  - target: { kind: Deployment, name: hugmesh-games }\n    patch: |\n      - op: replace\n        path: /spec/template/spec/containers/0/image\n        value: ghcr.io/hugmesh/hugmesh-games/backend:main\n")'
expect_red "a strategic-merge patch sets an allowed-looking image behind the pin" "nothing patches the container image" 'rep(M+"games/kustomization.yaml", "patches:\n", "patches:\n  - patch: |\n      apiVersion: apps/v1\n      kind: Deployment\n      metadata: { name: hugmesh-games }\n      spec: { template: { spec: { containers: [ { name: games, image: registry.hugmesh.net/hugmesh/hugmesh-games/backend:sha-3ae21def10e8 } ] } } }\n")'
expect_red "the keyspace Job back to PostSync" "Sync-phase hook" 'rep(M+"games/cassandra-init.yaml", "argocd.argoproj.io/hook: Sync\n", "argocd.argoproj.io/hook: PostSync\n")'
expect_red "the BFF loses its wave" "waves order" 'rep(M+"games/deployment.yaml", "    argocd.argoproj.io/sync-wave: \"2\"\n", "")'
expect_red "casdoor-games dataSourceName back on in-app interpolation" "dataSourceName carries no" 'rep(M+"casdoor-games/app-conf-configmap.yaml", "user=__CASDOOR_DB_USER__ password=__CASDOOR_DB_PASSWORD__", "user=${CASDOOR_DB_USER||threewizards} password=${CASDOOR_DB_PASSWORD||}")'
expect_red "casdoor-domain origin back on in-app interpolation" "no app.conf key relies on" 'rep(M+"casdoor-domain/app-conf-configmap.yaml", "origin = \"__CASDOOR_ORIGIN__\"", "origin = \"${CASDOOR_ORIGIN||https://id.hugmesh.net}\"")'
expect_red "casdoor-games render initContainer removed" "no render-app-conf initContainer" 'rep(M+"casdoor-games/deployment.yaml", "        - name: render-app-conf\n", "        - name: render-something-else\n")'
expect_red "a template token the initContainer never renders" "every template token is rendered" 'rep(M+"casdoor-domain/app-conf-configmap.yaml", "dbName = casdoor", "dbName = __CASDOOR_DB_NAME__")'
expect_red "casdoor-games mounts the unrendered template" "mounts the RENDERED app.conf" 'rep(M+"casdoor-games/deployment.yaml", "- { name: rendered-conf, mountPath: /conf/app.conf, subPath: app.conf, readOnly: true }", "- { name: app-conf-template, mountPath: /conf/app.conf, subPath: app.conf.template, readOnly: true }")'
expect_red "the GM sync switched on" "GM_SYNC_ENABLED is not true" 'rep(M+"hugmesh-apis/deployment.yaml", "{ name: GM_SYNC_ENABLED, value: \"false\" }", "{ name: GM_SYNC_ENABLED, value: \"true\" }")'
expect_red "the sync-job header describes the mirror again" "no longer says" 'rep(M+"casdoor/games-admin-sync-job.yaml", "#   (2) fe-gateway:", "#   (2) actions:   ROLE_GAMES_ADMIN (systems) -> admin (games)\n#   (2b) fe-gateway:")'
expect_red "the games-side client handed back to hugmesh-api" "no games-realm client" 'rep(M+"hugmesh-apis/deployment.yaml", "            - { name: GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\" }\n", "            - { name: CASDOOR_GAMES_URL, value: \"http://casdoor-games.hugmesh-games.svc.cluster.local:8000\" }\n            - { name: GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\" }\n")'
expect_red "the sync Secret mounted again" "casdoor-sync-games" 'rep(M+"hugmesh-apis/deployment.yaml", "            - { name: GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\" }\n", "            - { name: GAMES_SECRET, valueFrom: { secretKeyRef: { name: casdoor-sync-games, key: clientSecret } } }\n            - { name: GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\" }\n")'
expect_red "the initial delay dropped" "ten years out" 'rep(M+"hugmesh-apis/deployment.yaml", "            - { name: GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\" }\n", "")'
expect_red "the initial delay back to a minute" "ten years out" 'rep(M+"hugmesh-apis/deployment.yaml", "GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\"", "GM_SYNC_INITIAL_DELAY_MS, value: \"60000\"")'
expect_red "the realm admin role named as the mirror target" "no games role the realm owns" 'rep(M+"hugmesh-apis/deployment.yaml", "            - { name: GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\" }\n", "            - { name: GM_SYNC_GAMES_ROLE, value: \"admin\" }\n            - { name: GM_SYNC_INITIAL_DELAY_MS, value: \"3153600000000\" }\n")'
expect_red "the backend egress to hugmesh-games returns" "no path to hugmesh-games" 'rep(M+"networkpolicy/tier-egress.yaml", "    # No path to hugmesh-games.", "    - to:\n        - namespaceSelector: { matchLabels: { kubernetes.io/metadata.name: hugmesh-games } }\n      ports:\n        - { protocol: TCP, port: 8000 }\n    # No path to hugmesh-games.")'
expect_red "a 101-char description seeded" "varchar(100)" 'rep(M+"casdoor-games/init-data-configmap.yaml", "\"description\": \"Standard player; can access the portal and play unlocked levels.\"", "\"description\": \"" + "x" * 101 + "\"")'
expect_red "a mesh-games-admin role seeded" "no mesh-* role" 'rep(M+"casdoor-games/init-data-configmap.yaml", "{ \"owner\": \"threewizards\", \"name\": \"player\",", "{ \"owner\": \"threewizards\", \"name\": \"mesh-games-admin\", \"displayName\": \"Mesh games admin\", \"description\": \"synced\", \"users\": [], \"roles\": [], \"domains\": [], \"isEnabled\": true },\n        { \"owner\": \"threewizards\", \"name\": \"player\",")'
expect_red "the mirror comment returns" "no longer says" 'rep(M+"hugmesh-apis/deployment.yaml", "Two-Casdoor sync (GameMasterAdminSyncAction): OFF", "The single automatic mirror: ROLE_GAMES_ADMIN(systems) -> admin(games)")'

echo
echo "== test-games-two-realms: ${P} passed, ${N} failed =="
[ "${N}" -eq 0 ] || exit 1
