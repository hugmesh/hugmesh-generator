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
#                judged as ARGOCD WILL DEPLOY IT: apps/50-games.yaml must render exactly
#                specs/cluster/manifests/games with no spec.source.kustomize (images,
#                patches, namePrefix: argocd-repo-server applies those before the build)
#                and no other path; then every container and initContainer of every
#                workload in `kubectl kustomize` of that directory is read: the backend
#                image runs in exactly one container (Deployment hugmesh-games/games),
#                the two-realm environment is handed to that container only, no second
#                workload carries app=hugmesh-games (the Services' selector), nothing
#                pulls from ghcr.io, and that one image is exactly what the images: entry
#                composes (no patch replaces it), its tag a sha-<12>, a release, or the
#                placeholder that resolves to nothing (and then no digest may ride along:
#                a runtime pulls by digest and ignores the tag), never a floating name.
#                For a sha-/release tag the public registry is asked for the RENDERED
#                tag's manifest: a pinned digest must equal it, and the image's revision
#                label must be a hugmesh-games commit descending from #52's merge
#                (3ae21def; a release branch counts).
#                Pod templates are found by SHAPE for every kind (spec.template.spec,
#                spec.jobTemplate.spec.template.spec, a PodTemplate's template.spec, a
#                Pod's spec); a kind outside Deployment/StatefulSet/DaemonSet/Job/
#                CronJob that carries containers FAILS, and so does a container list
#                anywhere else in a document. casdoor-games, the other workload in the
#                games namespace, is held to the same image rules.
#   ways in      every document of every file under apps/ (recursed, as the roots
#                sync it) and app-of-apps.yaml: no Application or ApplicationSet other
#                than 50-games.yaml's single hugmesh-games may reach the games path or
#                the games namespace (casdoor-games may enter the namespace from its
#                own path; the optional-services scaffold may keep its games element
#                while it is unselected and its template carries no override); list
#                elements are substituted into the template, glob paths are matched;
#                no .argocd-source*.yaml anywhere under specs/ (argocd-repo-server's
#                parameter overrides; `kubectl kustomize` ignores them); no kustomization
#                outside manifests/games pulls that directory in.
#
# THREAT MODEL of the merge-order pin (the backend image must be a build at or after
# hugmesh-games#52, 3ae21def, whenever the two-realm environment is set): the guard
# protects against a CARELESS or UNINFORMED repo editor, or an automated bump, that
# would deploy an older backend with the two-realm env through any mechanism ArgoCD
# honours from THIS repository: kustomize images/patches/components, an Application's
# spec.source.kustomize, .argocd-source*.yaml override files, a second Application or
# ApplicationSet at the games path or in the games namespace, and any workload kind
# carrying a pod template. BOUNDS, not defended: a malicious committer (who can edit
# this suite too); admission-time mutation (Kyverno mutate rules, webhooks), which a
# render-time check cannot see; registry tag re-pointing beyond the digest check (a
# pinned digest is verified, a tag alone is only as good as the registry); and the
# admin-bff reconciler flipping the optional-services games element at runtime (its
# template carries no override, so a flip renders the same pinned tree).
#   scheduling   every nodeSelector in the games tier (games, games-portal,
#                casdoor-games) names a label the host KEYS profile sets AND the
#                backend-gpu role's ROLE_LABELS and keys hint carry; a pair nobody sets
#                is a pod that stays Pending forever.
#   stores (2)   the keyspace Job is a Sync-phase hook in a wave between the stores and
#                the BFF: a PostSync hook in the same Application as the pod that needs
#                the keyspace never runs.
#   casdoor      no Casdoor app.conf relies on in-app `${ENV||default}` interpolation
#                (casbin/casdoor does not expand it inside a value; the as-shipped
#                casdoor-games conf could never connect): every __TOKEN__ in the template
#                is rendered by a render-app-conf initContainer the pod mounts, and that
#                initContainer's script is RUN here (sh, the manifest's args, hostile
#                values carrying | & / \ ' " $ # ; ? @ and spaces): no byte printed, no
#                token left, every value read back byte for byte (the DB user and
#                password through the postgres:// URL the way lib/pq decodes it).
#                tests/casdoor/test-casdoor-render-boot.sh boots the real image on it.
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
# bash + python3 + PyYAML + kubectl (for `kubectl kustomize`; no cluster, no docker) +
# curl + awk (the Casdoor render). Offline, except the pinned-build proof: ghcr.io
# (anonymous manifest reads) and a commit-graph-only clone of the public hugmesh-games
# repo. Both are REQUIRED in CI and reported as NOT VERIFIED offline; a placeholder tag
# needs no call. In .github/workflows/shell-suites.yml this suite is in the tool-heavy
# job, the one with curl and a checksum-verified kubectl (the debian/python image has
# neither, and this suite exits 2 there rather than skipping).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

command -v python3 >/dev/null 2>&1 || { echo "FATAL: python3 required (refusing to skip)" >&2; exit 2; }
command -v curl >/dev/null 2>&1 || { echo "FATAL: curl required for the registry reads (refusing to skip)" >&2; exit 2; }
python3 -c 'import yaml' 2>/dev/null || { echo "FATAL: PyYAML required (refusing to skip)" >&2; exit 2; }
command -v kubectl >/dev/null 2>&1 || { echo "FATAL: kubectl required for kubectl kustomize (refusing to skip)" >&2; exit 2; }
command -v awk >/dev/null 2>&1 || { echo "FATAL: awk required to run the Casdoor render (refusing to skip)" >&2; exit 2; }
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

# One layer up: ArgoCD renders the APPLICATION, not this directory. argocd-repo-server
# applies spec.source.kustomize (images -> `kustomize edit set image`, patches,
# namePrefix, ...) before the build, and a path pointing at a parent overlay re-pins
# whatever it likes, so the only Application this check can vouch for is one that
# renders exactly this directory with nothing on top. And it must be the ONLY way in:
# every Application and ApplicationSet the roots can reach (apps/ is synced with
# directory.recurse, every document of every file) is read, a second one at this path
# or into this namespace is refused, and so is any `.argocd-source*.yaml` (the parameter
# override file argocd-repo-server merges into spec.source before the build;
# `kubectl kustomize` never reads it) and any kustomization elsewhere that pulls this
# directory in.
import fnmatch, posixpath
GAMES_PATH = "specs/cluster/manifests/games"
GAMES_NS = "hugmesh-games"
THIS_REPO = "https://github.com/hugmesh/hugmesh-generator.git"
def npath(p):
    p = posixpath.normpath(str(p).strip().strip("/")) if str(p).strip() else ""
    return "" if p == "." else p
def strict_source(src, want_path, where):
    check(src.get("repoURL") == THIS_REPO and src.get("targetRevision") == "main",
          f"[app] {where}: the source is this repository's main (repoURL={src.get('repoURL')!r}, targetRevision={src.get('targetRevision')!r})")
    check(npath(src.get("path", "")) == want_path, f"[app] {where}: spec.source.path is {want_path}, the directory rendered below (got {src.get('path')!r}; a parent overlay re-pins the image behind this check)")
    extra = sorted(set(src) - {"repoURL", "targetRevision", "path"})
    check(not extra, f"[app] {where}: spec.source carries nothing but repoURL/targetRevision/path (got {extra}): a kustomize images/patches/namePrefix override is applied by argocd-repo-server before the build and never reaches the render below")
# Every Application allowed to touch the games path or namespace, and what it renders.
# casdoor-games shares the namespace; its render is held to the same image rules below.
ALLOWED_APPS = {("50-games.yaml", "hugmesh-games"): GAMES_PATH,
                ("06-casdoor-games.yaml", "casdoor-games"): "specs/cluster/manifests/casdoor-games"}
# The optional-services scaffolding carries a `games` element; it may stay only while it
# creates nothing (installed != "true") and its template carries no override.
ALLOWED_APPSETS = {("13a-optional-services.yaml", "optional-services")}
def app_files():
    yield os.path.join(C, "app-of-apps.yaml")
    for dp, dn, fn in os.walk(os.path.join(C, "apps")):
        dn.sort()
        for f in sorted(fn):
            yield os.path.join(dp, f)
def all_strings(o):
    if isinstance(o, dict):
        for k, v in o.items():
            yield from all_strings(k); yield from all_strings(v)
    elif isinstance(o, list):
        for v in o:
            yield from all_strings(v)
    elif isinstance(o, str):
        yield o
def touches_games(s):
    s = str(s).strip()
    if s == GAMES_NS:
        return True
    p = npath(s)
    return p == GAMES_PATH or (any(ch in p for ch in "*?[") and fnmatch.fnmatchcase(GAMES_PATH, p))
TPL = re.compile(r"\{\{-?\s*\.?([A-Za-z0-9_.]+)\s*-?\}\}")
def fill(s, params):
    return TPL.sub(lambda m: str(params.get(m.group(1), m.group(0))), str(s))
def list_elements(gens, inherited_selector=None):
    """(element, selected?) for every list generator, nested matrix/merge included."""
    for g in gens or []:
        sel = (g.get("selector") or {})
        for kind in ("matrix", "merge"):
            if kind in g:
                yield from list_elements((g[kind] or {}).get("generators"), sel or inherited_selector)
        if "list" in g:
            s = sel or inherited_selector or {}
            ml = s.get("matchLabels") or {}
            for e in (g["list"] or {}).get("elements") or []:
                # a matchExpressions selector is not evaluated: such an element counts as selected
                chosen = all(str(e.get(k)) == str(v) for k, v in ml.items()) if not s.get("matchExpressions") else True
                yield e, chosen
games_apps, apps_seen = [], 0
for p in app_files():
    rel = os.path.relpath(p, os.path.join(C, "apps")) if os.path.dirname(p) != C else os.path.relpath(p, C)
    try:
        fdocs = docs(p) if p.endswith((".yaml", ".yml", ".json")) else []
    except Exception as e:
        bad(f"[app] {rel} does not parse ({e}): an Application this check cannot read is one it cannot vouch for")
        continue
    for i, d in enumerate(fdocs):
        if not isinstance(d, dict) or d.get("kind") not in ("Application", "ApplicationSet"):
            continue
        apps_seen += 1
        name = (d.get("metadata") or {}).get("name")
        spec = d.get("spec") or {}
        where = f"{rel} doc {i + 1} {d['kind']} {name}"
        if d["kind"] == "Application":
            srcs = ([spec["source"]] if spec.get("source") else []) + list(spec.get("sources") or [])
            dest_ns = (spec.get("destination") or {}).get("namespace")
            hit = dest_ns == GAMES_NS or any(npath(s.get("path", "")) == GAMES_PATH for s in srcs if isinstance(s, dict))
            if not hit:
                continue
            games_apps.append((rel, name))
            want = ALLOWED_APPS.get((rel, name))
            if want is None:
                bad(f"[app] {where} reaches the games path or the {GAMES_NS} namespace; only apps/50-games.yaml's hugmesh-games (and casdoor-games into the namespace) may: a second Application renders the BFF with whatever override it carries")
                continue
            check("sources" not in spec, f"[app] {where}: one spec.source, no multi-source list")
            strict_source(spec.get("source") or {}, want, where)
            check(dest_ns == GAMES_NS, f"[app] {where}: deploys into {GAMES_NS} (got {dest_ns!r})")
        else:
            tspec = ((spec.get("template") or {}).get("spec")) or {}
            tsrcs = ([tspec["source"]] if tspec.get("source") else []) + list(tspec.get("sources") or [])
            rendered_hits = []
            for e, chosen in list_elements(spec.get("generators")):
                paths = [npath(fill(s.get("path", ""), e)) for s in tsrcs if isinstance(s, dict)]
                ns = fill((tspec.get("destination") or {}).get("namespace", ""), e)
                if GAMES_PATH in paths or ns == GAMES_NS:
                    rendered_hits.append((e, chosen))
            literal = [s for s in all_strings({k: v for k, v in spec.items()}) if touches_games(s)]
            if not rendered_hits and not literal:
                continue
            games_apps.append((rel, name))
            if (rel, name) not in ALLOWED_APPSETS:
                bad(f"[app] {where} reaches the games path or the {GAMES_NS} namespace (elements {[e for e, _ in rendered_hits]}, literals {literal}); only apps/50-games.yaml's hugmesh-games may: a generated Application renders the BFF with whatever its template carries")
                continue
            check(not [e for e, chosen in rendered_hits if chosen],
                  f"[app] {where}: the games element stays unselected (installed != \"true\"): a generated optional-games is a second owner of the BFF (selected: {[e for e, c in rendered_hits if c]})")
            check("templatePatch" not in spec and "sources" not in tspec, f"[app] {where}: no templatePatch and no multi-source template")
            tsrc = tspec.get("source") or {}
            extra = sorted(set(tsrc) - {"repoURL", "targetRevision", "path"})
            check(tsrc.get("repoURL") == THIS_REPO and tsrc.get("targetRevision") == "main" and not extra,
                  f"[app] {where}: the template source is this repository's main with nothing but repoURL/targetRevision/path (extra {extra}): a reconciler flip of `installed` then renders the same pinned tree")
check(apps_seen > 50, f"[app] read every Application and ApplicationSet under apps/ ({apps_seen}; a walk that reads nothing proves nothing)")
check(games_apps.count(("50-games.yaml", "hugmesh-games")) == 1,
      f"[app] exactly one Application named hugmesh-games in apps/50-games.yaml reaches the games path (found {games_apps})")
app = next((d for d in docs(f"{C}/apps/50-games.yaml") if d.get("kind") == "Application"), None)
if app is None:
    bad("[app] apps/50-games.yaml carries no Application")
argo_src = []
for dp, dn, fn in os.walk(os.path.join(root, "specs")):
    argo_src += [os.path.relpath(os.path.join(dp, f), root) for f in fn if f.startswith(".argocd-source")]
check(not argo_src, f"[app] no .argocd-source*.yaml anywhere under specs/ (found {argo_src}): argocd-repo-server merges it into spec.source (images, patches) before the build")
GAMES_DIR = os.path.realpath(os.path.join(root, GAMES_PATH))
pulls = []
for dp, dn, fn in os.walk(C):
    for f in fn:
        if f not in ("kustomization.yaml", "kustomization.yml", "Kustomization"):
            continue
        kp = os.path.join(dp, f)
        if os.path.realpath(dp) == GAMES_DIR:
            continue
        try:
            k = yaml.safe_load(open(kp)) or {}
        except Exception as e:
            bad(f"[app] {os.path.relpath(kp, root)} does not parse ({e})"); continue
        for key in ("resources", "components", "bases"):
            for r in k.get(key) or []:
                if not isinstance(r, str) or "://" in r:
                    continue
                t = os.path.realpath(os.path.join(dp, r))
                if t == GAMES_DIR or t.startswith(GAMES_DIR + os.sep):
                    pulls.append(f"{os.path.relpath(kp, root)} -> {r}")
check(not pulls, f"[app] no kustomization outside manifests/games pulls that directory in (found {pulls}): an overlay re-pins the image behind this check")

# The whole render, every pod template, every container: the backend image must run
# in exactly ONE place, the two-realm environment must be handed to that place only,
# nothing else may stand behind the Services' selector, and nothing may pull from
# ghcr.io (a second copy of the backend with the two-realm env is the same hole as an
# unpinned first one). Pod templates are found by SHAPE, not by kind: the four known
# places (spec.template.spec, spec.jobTemplate.spec.template.spec, a PodTemplate's
# template.spec, a Pod's spec) are read for every kind, a kind outside the workload
# controllers this check judges FAILS, and so does a `containers` list anywhere else
# in a document (a CRD's own pod template is one this check cannot vouch for).
BACKEND_NAME = re.compile(r"hugmesh[-.]games[-/]backend|hugmesh\.games-backend")
TWO_REALM_ENV = {"APP_TENANCY_ISSUERS", "APP_TENANCY_JWKS_URIS", "APP_SECURITY_GAMES_REALM_ISSUERS"}
KNOWN_WORKLOADS = {"Deployment", "StatefulSet", "DaemonSet", "Job", "CronJob"}
def render(path):
    return [d for d in yaml.safe_load_all(subprocess.run(["kubectl", "kustomize", path], check=True, capture_output=True, text=True, env={**os.environ, "KUBECONFIG": "/dev/null"}).stdout) if d]
def pod_specs(d):
    """[(pod spec, pod labels)] at the four places a pod template lives, for ANY kind."""
    spec = d.get("spec") if isinstance(d.get("spec"), dict) else {}
    out = []
    for holder in (spec.get("template"),
                   (((spec.get("jobTemplate") or {}).get("spec") or {}).get("template")),
                   d.get("template") if isinstance(d.get("template"), dict) else None):
        if isinstance(holder, dict) and isinstance(holder.get("spec"), dict) and any(k in holder["spec"] for k in ("containers", "initContainers", "ephemeralContainers")):
            out.append((holder["spec"], ((holder.get("metadata") or {}).get("labels") or {})))
    if any(k in spec for k in ("containers", "initContainers", "ephemeralContainers")):
        out.append((spec, ((d.get("metadata") or {}).get("labels") or {})))
    return out
def stray_containers(o, reached, path="", found=None):
    """every dict carrying a container list that pod_specs() did not reach"""
    found = [] if found is None else found
    if isinstance(o, dict):
        if any(isinstance(o.get(k), list) for k in ("containers", "initContainers", "ephemeralContainers")) and not any(o is r for r in reached):
            found.append(path or "/")
        for k, v in o.items():
            stray_containers(v, reached, f"{path}/{k}", found)
    elif isinstance(o, list):
        for i, v in enumerate(o):
            stray_containers(v, reached, f"{path}/{i}", found)
    return found
def selector_labels(d):
    sel = ((d.get("spec") or {}).get("selector")) if isinstance(d.get("spec"), dict) else None
    if not isinstance(sel, dict):
        return {}
    return sel.get("matchLabels") if isinstance(sel.get("matchLabels"), dict) else {k: v for k, v in sel.items() if isinstance(v, str)}
def all_containers(ps):
    for where in ("initContainers", "containers", "ephemeralContainers"):
        for c in ps.get(where) or []:
            yield where, c
def judge_workloads(tdocs, tier):
    """unknown kinds and stray pod templates FAIL; yields (workload, pod spec, labels)"""
    for d in tdocs:
        found = pod_specs(d)
        wl = f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
        stray = stray_containers(d, [ps for ps, _ in found])
        check(not stray, f"[image] {tier}: {wl} carries a container list outside every pod template this check reads ({stray}): a workload kind this analyser does not judge")
        if found and d.get("kind") not in KNOWN_WORKLOADS:
            bad(f"[image] {tier}: {wl} carries containers but is a workload kind this analyser does not judge (judged: {sorted(KNOWN_WORKLOADS)}); its pods run whatever it says")
        for ps, labels in found:
            yield d, wl, ps, labels
rendered, backend_at, two_realm_at, selected, ghcr, rps, walked = "", [], [], [], [], {}, []
try:
    rendered_docs = render(f"{M}/games")
    for d, wl, ps, tl in judge_workloads(rendered_docs, "manifests/games"):
        if selector_labels(d).get("app") == "hugmesh-games" or tl.get("app") == "hugmesh-games":
            selected.append(wl)
        for where, c in all_containers(ps):
            img = str(c.get("image", ""))
            if BACKEND_NAME.search(img):
                backend_at.append((wl, where, c.get("name"), img))
            envs = c.get("env") or []
            if {e.get("name") for e in envs} & TWO_REALM_ENV or any((((e.get("valueFrom") or {}).get("secretKeyRef") or {}).get("name") == "casdoor-games-app") for e in envs):
                two_realm_at.append((wl, where, c.get("name"), img))
            if img.startswith("ghcr.io/"):
                ghcr.append((wl, where, c.get("name"), img))
            walked.append(f"{wl}/{where}/{c.get('name')}={img}")
            if wl == "Deployment/hugmesh-games" and where == "containers" and c.get("name") == "games":
                rendered = img
                rps = ps
    if not rendered:
        bad("[image] the render has no Deployment hugmesh-games with a container named games")
except Exception as e:  # a render that fails is a FAIL, never a skip
    bad(f"[image] kubectl kustomize of manifests/games did not yield the BFF image: {e}")
# casdoor-games shares the namespace (ALLOWED_APPS above): nothing in its render may run
# the backend, carry the two-realm environment, stand behind app=hugmesh-games or pull
# from ghcr.io either.
try:
    cg = []
    for d, wl, ps, tl in judge_workloads(render(f"{M}/casdoor-games"), "manifests/casdoor-games"):
        if selector_labels(d).get("app") == "hugmesh-games" or tl.get("app") == "hugmesh-games":
            cg.append(("selector", wl))
        for where, c in all_containers(ps):
            img = str(c.get("image", ""))
            envs = {e.get("name") for e in (c.get("env") or [])}
            if BACKEND_NAME.search(img) or img.startswith("ghcr.io/") or envs & TWO_REALM_ENV:
                cg.append((wl, where, c.get("name"), img))
    check(not cg, f"[image] the casdoor-games render (same namespace) runs no backend image, no ghcr.io image, no two-realm env, nothing under app=hugmesh-games (found {cg})")
except Exception as e:
    bad(f"[image] kubectl kustomize of manifests/casdoor-games failed: {e}")
rname, tag, digest = split_ref(rendered)
check(backend_at == [("Deployment/hugmesh-games", "containers", "games", rendered)] if rendered else False,
      f"[image] the backend image runs in exactly one container of the whole render, Deployment hugmesh-games/games (found {backend_at})")
check(two_realm_at == [("Deployment/hugmesh-games", "containers", "games", rendered)] if rendered else False,
      f"[image] the two-realm environment (APP_TENANCY_*, the casdoor-games-app client) is handed to that one container and no other (found {two_realm_at})")
check(selected == ["Deployment/hugmesh-games"], f"[image] exactly one workload carries app=hugmesh-games, the selector of the hugmesh-games and portal `api` Services (found {selected})")
check(bool(rps) and len(rps.get("containers") or []) == 1 and not rps.get("initContainers") and not rps.get("ephemeralContainers"),
      "[image] the BFF pod is one container: no second container, no initContainer, no ephemeral container")
check(not ghcr, f"[image] nothing in the render pulls from ghcr.io; first-party images come through Harbor (found {ghcr})")
if walked:
    ok(f"[image] every image walked ({len(walked)}; first-party = registry.hugmesh.net/..., the rest third-party, judged by test-cluster-manifest-integrity.sh): " + "; ".join(walked))
check(rendered and rendered == composed, f"[image] the RENDERED backend image {rendered!r} is exactly what the images: entry composes ({composed!r}); nothing patches the container image behind the pin")
check(rname == PFX + "hugmesh-games/backend", f"[image] the rendered backend name is {rname!r}, the published backend under the Harbor host")
check(tag == PLACEHOLDER or SHA_TAG.match(tag) is not None or RELEASE_TAG.match(tag) is not None,
      f"[image] rendered backend tag {tag!r}: the fail-closed placeholder, a sha-<12> or a release, never a floating name (main moves under the cluster and a pre-#52 build accepts a mesh-iss token signed by the games key)")
if tag == PLACEHOLDER:
    check(not digest, f"[image] no digest rides with the placeholder (rendered {rendered!r}: a runtime pulls by digest and ignores the tag, so the placeholder would resolve to a real, unverified image)")
else:
    check(not digest or DIGEST.match(digest) is not None, f"[image] the pinned digest {digest!r} is sha256:<64 hex>")

# ── every nodeSelector in the games tier is a label some role actually sets ──────
# A pair nobody sets is a pod Pending forever, and nothing on a cluster says why. The
# labels come from the KEYS stick (.hugmesh.node_labels, applied by provision.sh); the
# shipped example for the x86 host is keys-template/examples/provision.host.json, and
# the builder's banner + keys hint for backend-gpu (the role that runs the BFF) are
# the only words an operator building that node ever sees. kubelet's own labels
# (kubernetes.io/arch, os, hostname) need no stick.
import json
hostp = json.load(open(f"{root}/keys-template/examples/provision.host.json"))["hugmesh"]["node_labels"]
builder = text(f"{root}/build-x86-host-stage4.sh")
m = re.search(r'^    backend-gpu\)\n(?:.*\n)*?\s*ROLE_LABELS="([^"]+)"', builder, re.M)
gpu_labels = dict(x.split("=", 1) for x in (m.group(1).split(",") if m else []))
m = re.search(r'backend-gpu\)\s+echo "      # worker; .*?node_labels \{([^}]*)\}', builder)
hint = {k.strip(): v.strip().replace('\\"', '"').strip('"') for k, v in (x.split(":", 1) for x in (m.group(1).split(",") if m else []) if ":" in x)}
KUBELET_OWN = {"kubernetes.io/arch", "kubernetes.io/os", "kubernetes.io/hostname"}
seen_pairs = set()
for tier in ("games", "casdoor-games"):  # games renders games-portal too
    try:
        tdocs = render(f"{M}/{tier}")
    except Exception as e:
        bad(f"[sched] kubectl kustomize of manifests/{tier} failed: {e}")
        continue
    for d in tdocs:
        for ps, _labels in pod_specs(d):
            wl = f"{d.get('kind')}/{(d.get('metadata') or {}).get('name')}"
            for k, v in (ps.get("nodeSelector") or {}).items():
                if k in KUBELET_OWN:
                    continue
                seen_pairs.add((k, str(v)))
                check(str(hostp.get(k)) == str(v) and gpu_labels.get(k) == str(v) and hint.get(k) == str(v),
                      f"[sched] {wl} nodeSelector {k}={v}: the host KEYS profile sets {hostp.get(k)!r}, backend-gpu ROLE_LABELS carry {gpu_labels.get(k)!r}, its keys hint says {hint.get(k)!r}")
check({("hugmesh.net/games", "true"), ("hugmesh.net/compute", "gpu")} <= seen_pairs, f"[sched] the tier pins both hugmesh.net/games=true and hugmesh.net/compute=gpu (seen {sorted(seen_pairs)})")

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
    named = set(re.findall(r"__[A-Z_]+__", args))
    check(tokens and tokens == named, f"[casdoor:{cdir}] the initContainer names every template token and no other (template {sorted(tokens)}, script {sorted(named)})")
    ienv = {e["name"] for e in init.get("env") or []}
    check({x.strip("_") for x in tokens} <= ienv, f"[casdoor:{cdir}] the initContainer is handed every token's value (env {sorted(ienv)})")
    # Run the script. The manifest's own `sh -c <args>`, its two mount paths pointed at a
    # scratch dir, every token's env set to a value sed could never have carried.
    import tempfile, urllib.parse
    if init.get("command") == ["sh", "-c"] and len(init.get("args") or []) == 1 and tpl:
        with tempfile.TemporaryDirectory() as td:
            os.makedirs(f"{td}/template"); os.makedirs(f"{td}/rendered")
            open(f"{td}/template/app.conf.template", "w").write(tpl)
            script = init["args"][0].replace("/template/app.conf.template", f"{td}/template/app.conf.template").replace("/rendered/app.conf", f"{td}/rendered/app.conf")
            values = {x.strip("_"): f"v|&/\\'\"$%#;?@ {x.strip('_').lower()} \\1" for x in tokens}
            r = subprocess.run(["sh", "-c", script], env={**os.environ, **values}, capture_output=True, text=True)
            out = open(f"{td}/rendered/app.conf", errors="replace").read() if os.path.exists(f"{td}/rendered/app.conf") else ""
            check(r.returncode == 0, f"[casdoor:{cdir}] the render script exits 0 under sh (rc {r.returncode}: {(r.stderr or r.stdout)[:120]!r})")
            check(not r.stdout and not r.stderr, f"[casdoor:{cdir}] the render prints nothing ({len(r.stdout) + len(r.stderr)} bytes; a value could be among them)")
            left = sorted(set(re.findall(r"__[A-Z_]+__", out)))
            check(out and not left, f"[casdoor:{cdir}] every template token is rendered by the initContainer (left in the output: {left})")
            dsn = next((l for l in out.splitlines() if l.strip().startswith("dataSourceName")), "")
            got = {}
            try:
                u = urllib.parse.urlsplit(dsn.split("=", 1)[1].strip().strip('"'))
                user, _, pw = u.netloc.rpartition("@")[0].partition(":")
                got = {"CASDOOR_DB_USER": urllib.parse.unquote(user, errors="strict"), "CASDOOR_DB_PASSWORD": urllib.parse.unquote(pw, errors="strict")}
                check(u.scheme == "postgres" and "?" not in u.netloc, f"[casdoor:{cdir}] dataSourceName is a postgres:// URL with the credentials in its userinfo ({dsn.strip()[:40]!r}...)")
            except Exception as e:
                bad(f"[casdoor:{cdir}] dataSourceName does not parse as a URL: {e}")
            for name, want in sorted(values.items()):
                if name in ("CASDOOR_DB_USER", "CASDOOR_DB_PASSWORD"):
                    check(got.get(name) == want, f"[casdoor:{cdir}] {name} reads back byte for byte through the URL the way lib/pq decodes it (| & / \\ ' \" $ % # ; ? @ space)")
                else:
                    check(f'"{want}"' in out or f"= {want}" in out, f"[casdoor:{cdir}] {name} is rendered literally (| & / \\ ' \" $ % # ; ? @ space)")
    else:
        bad(f"[casdoor:{cdir}] the initContainer is not `sh -c <one script>` (command {init.get('command')!r}), so its render cannot be run here")
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
# be a hugmesh-games commit that descends from #52's merge commit, 3ae21def (a release
# is cut from release/X.Y, so every branch is fetched, commit objects only:
# --filter=tree:0, no trees, no blobs, under a megabyte). Required
# in CI (no network there is a failure, not a skip); offline it is reported, loudly, as
# not verified.
echo "== the pinned backend build =="
PR52_MERGE=3ae21def10e8a09c4a8bb86b4fcbccacdba6549d
GRAPH="${WORK}/hugmesh-games.git"
have_graph(){
  [ -d "${GRAPH}" ] && return 0
  git clone -q --bare --filter=tree:0 --no-tags https://github.com/hugmesh/hugmesh-games.git "${GRAPH}" >/dev/null 2>&1
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
# --retry 2: a resolver or connect timeout is transient (seen once in a container run:
# "Resolving timed out after 10001 milliseconds"); a 404 or a bad digest is not retried.
def get(url, headers, want_headers=False):
    with tempfile.TemporaryDirectory() as d:
        hf, bf = os.path.join(d, "h"), os.path.join(d, "b")
        cmd = ["curl", "-sS", "-L", "--connect-timeout", "10", "--max-time", "60", "--retry", "2", "--retry-delay", "3", "-D", hf, "-o", bf, "-w", "%{http_code}"]
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
    print(f"{tag}: revision {rev[:12]} is not a commit on any hugmesh-games branch"); sys.exit(1)
if subprocess.run(["git", "-C", graph, "merge-base", "--is-ancestor", floor, rev], capture_output=True).returncode != 0:
    print(f"{tag}: revision {rev[:12]} does not descend from #52's merge {floor[:12]} (a pre-#52 build)"); sys.exit(1)
print(f"{tag}: manifest {dtag[:19]}..., revision {rev[:12]} is at or after #52's merge {floor[:12]}" + (" and the pinned digest equals the tag's" if digest else " (no digest pinned)")); sys.exit(0)
PY
}
# The tag and digest come from the RENDERED Deployment, never from the kustomization
# text: what `kubectl kustomize manifests/games` puts on container `games` is what the
# cluster pulls (the Application check above is what makes that equality hold).
read -r TAG DIGEST < <(python3 - "${REPO}/specs/cluster/manifests/games" <<'PY'
import os, subprocess, sys, yaml
try:
    out = subprocess.run(["kubectl", "kustomize", sys.argv[1]], check=True, capture_output=True, text=True, env={**os.environ, "KUBECONFIG": "/dev/null"}).stdout
    dep = next(d for d in yaml.safe_load_all(out) if d and d["kind"] == "Deployment" and d["metadata"]["name"] == "hugmesh-games")
    img = next(c for c in dep["spec"]["template"]["spec"]["containers"] if c["name"] == "games")["image"]
    rest, _, digest = img.partition("@")
    tag = rest.rpartition(":")[2] if ":" in rest.rsplit("/", 1)[-1] else ""
    print(tag or "-", digest)
except Exception as e:
    print("RENDER-FAILED", "")
PY
)
[ "${TAG}" != "RENDER-FAILED" ] || bad "the rendered backend image could not be read (kubectl kustomize failed)"
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
  mkdir -p "${T}/keys-template/examples"
  cp "${REPO}/keys-template/examples/provision.host.json" "${T}/keys-template/examples/"
  cp "${REPO}/build-x86-host-stage4.sh" "${T}/"
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
A = "specs/cluster/apps/"
# a second Application at the games path, overriding the image (the refuter's n7)
SHADOW = ("apiVersion: argoproj.io/v1alpha1\nkind: Application\nmetadata:\n  name: hugmesh-games-main\n  namespace: devops\n"
          "spec:\n  project: default\n  source:\n    repoURL: https://github.com/hugmesh/hugmesh-generator.git\n    targetRevision: main\n"
          "    path: specs/cluster/manifests/games\n    kustomize:\n      namePrefix: shadow-\n      images:\n"
          "        - registry.hugmesh.net/hugmesh/hugmesh-games/backend=ghcr.io/hugmesh/hugmesh-games/backend:main\n"
          "  destination:\n    server: https://kubernetes.default.svc\n    namespace: hugmesh-games\n")
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
expect_red "n1: the Application overrides the image with kustomize.images (ghcr :main)" "spec.source carries nothing but" 'rep("specs/cluster/apps/50-games.yaml", "    path: specs/cluster/manifests/games\n", "    path: specs/cluster/manifests/games\n    kustomize:\n      images:\n        - registry.hugmesh.net/hugmesh/hugmesh-games/backend=ghcr.io/hugmesh/hugmesh-games/backend:main\n")'
expect_red "n1b: the Application overrides the image to the first-party host, pre-#52 build" "spec.source carries nothing but" 'rep("specs/cluster/apps/50-games.yaml", "    path: specs/cluster/manifests/games\n", "    path: specs/cluster/manifests/games\n    kustomize:\n      images:\n        - registry.hugmesh.net/hugmesh/hugmesh-games/backend=registry.hugmesh.net/hugmesh/hugmesh-games/backend:sha-f111cfe3382d\n")'
expect_red "n2: the Application carries a JSON6902 image patch" "spec.source carries nothing but" 'rep("specs/cluster/apps/50-games.yaml", "    path: specs/cluster/manifests/games\n", "    path: specs/cluster/manifests/games\n    kustomize:\n      patches:\n        - target: { kind: Deployment, name: hugmesh-games }\n          patch: |-\n            - op: replace\n              path: /spec/template/spec/containers/0/image\n              value: ghcr.io/hugmesh/hugmesh-games/backend:main\n")'
expect_red "n3: the Application points at a parent overlay that re-pins the image" "spec.source.path is specs/cluster/manifests/games" 'rep("specs/cluster/apps/50-games.yaml", "    path: specs/cluster/manifests/games\n", "    path: specs/cluster/overlays/games-main\n")
os.makedirs(os.path.join(root, "specs/cluster/overlays/games-main"), exist_ok=True)
open(os.path.join(root, "specs/cluster/overlays/games-main/kustomization.yaml"), "w").write("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nresources:\n  - ../../manifests/games\nimages:\n  - name: registry.hugmesh.net/hugmesh/hugmesh-games/backend\n    newName: ghcr.io/hugmesh/hugmesh-games/backend\n    newTag: main\n    digest: \"\"\n")'
expect_red "n3b: the Application names another repository" "the source is this repository" 'rep("specs/cluster/apps/50-games.yaml", "    repoURL: https://github.com/hugmesh/hugmesh-generator.git\n", "    repoURL: https://github.com/hugmesh/hugmesh-generator-fork.git\n")'
expect_red "n4: a second container in the BFF pod runs ghcr :main" "the backend image runs in exactly one container" 'rep(M+"games/kustomization.yaml", "patches:\n", "patches:\n  - target: { kind: Deployment, name: hugmesh-games }\n    patch: |\n      - op: add\n        path: /spec/template/spec/containers/-\n        value:\n          name: games-main\n          image: ghcr.io/hugmesh/hugmesh-games/backend:main\n          ports: [{ name: http2, containerPort: 8081 }]\n")'
expect_red "n4b: a second container with the two-realm env under a foreign name" "the two-realm environment" 'rep(M+"games/kustomization.yaml", "patches:\n", "patches:\n  - target: { kind: Deployment, name: hugmesh-games }\n    patch: |\n      - op: add\n        path: /spec/template/spec/containers/-\n        value:\n          name: sidecar\n          image: docker.io/library/alpine:3.20\n          env: [{ name: APP_TENANCY_JWKS_URIS, value: \"x\" }]\n")'
expect_red "n5: a second Deployment under the Services selector app=hugmesh-games" "exactly one workload carries app=hugmesh-games" 'rep(M+"games/kustomization.yaml", "  - deployment.yaml\n", "  - deployment.yaml\n  - deployment-main.yaml\n")
open(os.path.join(root, M, "games/deployment-main.yaml"), "w").write("apiVersion: apps/v1\nkind: Deployment\nmetadata:\n  name: hugmesh-games-main\n  namespace: hugmesh-games\n  labels: { app: hugmesh-games }\nspec:\n  replicas: 1\n  selector: { matchLabels: { app: hugmesh-games } }\n  template:\n    metadata: { labels: { app: hugmesh-games } }\n    spec:\n      containers:\n        - name: games\n          image: docker.io/library/alpine:3.20\n          ports: [{ name: http, containerPort: 8080 }]\n")'
expect_red "n6: an initContainer in the BFF pod runs ghcr :main" "the BFF pod is one container" 'rep(M+"games/kustomization.yaml", "patches:\n", "patches:\n  - target: { kind: Deployment, name: hugmesh-games }\n    patch: |\n      - op: add\n        path: /spec/template/spec/initContainers\n        value:\n          - name: warm\n            image: ghcr.io/hugmesh/hugmesh-games/backend:main\n")'
# Round 4 (refuter's n7, n7b, n9, n10) and their siblings: every way in that ArgoCD
# honours from this repository, one layer above the render.
expect_red "n7: a second Application (apps/50b-games-main.yaml) at the games path with images ghcr :main" "50b-games-main.yaml doc 1 Application hugmesh-games-main reaches the games path" 'open(os.path.join(root, A, "50b-games-main.yaml"), "w").write(SHADOW)'
expect_red "n7b: the same Application appended as a second document of 50-games.yaml" "50-games.yaml doc 2 Application hugmesh-games-main reaches the games path" 'open(os.path.join(root, A, "50-games.yaml"), "a").write("---\n" + SHADOW)'
expect_red "n7c: a second hugmesh-games Application (same name) in a nested apps/ directory" "games/50-games.yaml doc 1 Application hugmesh-games reaches the games path" 'os.makedirs(os.path.join(root, A, "games"), exist_ok=True)
open(os.path.join(root, A, "games/50-games.yaml"), "w").write(SHADOW.replace("name: hugmesh-games-main", "name: hugmesh-games"))'
expect_red "n7c2: a second hugmesh-games Application (same name) appended to 50-games.yaml" "exactly one Application named hugmesh-games" 'open(os.path.join(root, A, "50-games.yaml"), "a").write("---\n" + SHADOW.replace("name: hugmesh-games-main", "name: hugmesh-games"))'
expect_red "n7d: a second Application into the games namespace from another path" "50c-games-x.yaml doc 1 Application hugmesh-games-main reaches the games path or the hugmesh-games namespace" 'open(os.path.join(root, A, "50c-games-x.yaml"), "w").write(SHADOW.replace("path: specs/cluster/manifests/games\n", "path: specs/cluster/manifests/games-x\n"))'
expect_red "n7e: an ApplicationSet whose list element renders the games path" "50d-games-set.yaml doc 1 ApplicationSet games-set reaches the games path" 'open(os.path.join(root, A, "50d-games-set.yaml"), "w").write("apiVersion: argoproj.io/v1alpha1\nkind: ApplicationSet\nmetadata: { name: games-set, namespace: devops }\nspec:\n  goTemplate: true\n  generators:\n    - list: { elements: [ { slug: games, ns: hugmesh-games } ] }\n  template:\n    metadata: { name: \"x-{{ .slug }}\" }\n    spec:\n      project: default\n      source: { repoURL: \"https://github.com/hugmesh/hugmesh-generator.git\", targetRevision: main, path: \"specs/cluster/manifests/{{ .slug }}\" }\n      destination: { server: \"https://kubernetes.default.svc\", namespace: \"{{ .ns }}\" }\n")'
expect_red "n7f: an ApplicationSet with a git directory generator whose glob takes in manifests/games" "50e-dirs.yaml doc 1 ApplicationSet dirs reaches the games path" 'open(os.path.join(root, A, "50e-dirs.yaml"), "w").write("apiVersion: argoproj.io/v1alpha1\nkind: ApplicationSet\nmetadata: { name: dirs, namespace: devops }\nspec:\n  generators:\n    - git: { repoURL: \"https://github.com/hugmesh/hugmesh-generator.git\", revision: main, directories: [ { path: \"specs/cluster/manifests/*\" } ] }\n  template:\n    metadata: { name: \"d-{{path.basename}}\" }\n    spec:\n      project: default\n      source: { repoURL: \"https://github.com/hugmesh/hugmesh-generator.git\", targetRevision: main, path: \"{{path}}\" }\n      destination: { server: \"https://kubernetes.default.svc\", namespace: \"{{path.basename}}\" }\n")'
expect_red "n7g: the optional-services games element flipped to installed" "the games element stays unselected" 'rep(A+"13a-optional-services.yaml", "{ slug: games,   path: specs/cluster/manifests/games,         namespace: hugmesh-games,    installed: \"false\" }", "{ slug: games,   path: specs/cluster/manifests/games,         namespace: hugmesh-games,    installed: \"true\" }")'
expect_red "n7h: the optional-services template gains a kustomize override" "the template source is this repository" 'rep(A+"13a-optional-services.yaml", "        path: \"{{ .path }}\"\n", "        path: \"{{ .path }}\"\n        kustomize: { namePrefix: shadow- }\n")'
expect_red "n8: an overlay elsewhere pulls manifests/games in" "no kustomization outside manifests/games pulls" 'os.makedirs(os.path.join(root, "specs/cluster/manifests/games-shadow"), exist_ok=True)
open(os.path.join(root, "specs/cluster/manifests/games-shadow/kustomization.yaml"), "w").write("apiVersion: kustomize.config.k8s.io/v1beta1\nkind: Kustomization\nnamespace: hugmesh-shadow\nresources:\n  - ../games\nimages:\n  - name: registry.hugmesh.net/hugmesh/hugmesh-games/backend\n    newName: ghcr.io/hugmesh/hugmesh-games/backend\n    newTag: main\n")'
expect_red "n9: .argocd-source-hugmesh-games.yaml in manifests/games overrides the image" "no .argocd-source*.yaml anywhere under specs/" 'open(os.path.join(root, M, "games/.argocd-source-hugmesh-games.yaml"), "w").write("kustomize:\n  images:\n    - registry.hugmesh.net/hugmesh/hugmesh-games/backend=ghcr.io/hugmesh/hugmesh-games/backend:main\n")'
expect_red "n9b: a bare .argocd-source.yaml in manifests/games" "no .argocd-source*.yaml anywhere under specs/" 'open(os.path.join(root, M, "games/.argocd-source.yaml"), "w").write("kustomize:\n  namePrefix: shadow-\n")'
expect_red "n10: a ReplicationController under app=hugmesh-games runs ghcr :main with the two-realm env" "a workload kind this analyser does not judge" 'rep(M+"games/kustomization.yaml", "  - deployment.yaml\n", "  - deployment.yaml\n  - rc.yaml\n")
open(os.path.join(root, M, "games/rc.yaml"), "w").write("apiVersion: v1\nkind: ReplicationController\nmetadata:\n  name: hugmesh-games-rc\n  namespace: hugmesh-games\nspec:\n  replicas: 1\n  selector: { app: hugmesh-games }\n  template:\n    metadata: { labels: { app: hugmesh-games } }\n    spec:\n      containers:\n        - name: games\n          image: ghcr.io/hugmesh/hugmesh-games/backend:main\n          env: [{ name: APP_TENANCY_ISSUERS, value: \"x\" }]\n")'
expect_red "n10b: the same ReplicationController is also caught by the selector rule" "exactly one workload carries app=hugmesh-games" 'rep(M+"games/kustomization.yaml", "  - deployment.yaml\n", "  - deployment.yaml\n  - rc.yaml\n")
open(os.path.join(root, M, "games/rc.yaml"), "w").write("apiVersion: v1\nkind: ReplicationController\nmetadata:\n  name: hugmesh-games-rc\n  namespace: hugmesh-games\nspec:\n  replicas: 1\n  selector: { app: hugmesh-games }\n  template:\n    metadata: { labels: { app: hugmesh-games } }\n    spec:\n      containers:\n        - name: games\n          image: docker.io/library/alpine:3.20\n")'
expect_red "n11: a custom resource carrying its own container list (no pod template shape)" "outside every pod template this check reads" 'rep(M+"games/kustomization.yaml", "  - deployment.yaml\n", "  - deployment.yaml\n  - runner.yaml\n")
open(os.path.join(root, M, "games/runner.yaml"), "w").write("apiVersion: example.net/v1\nkind: GamesRunner\nmetadata:\n  name: shadow\n  namespace: hugmesh-games\nspec:\n  runner:\n    containers:\n      - name: games\n        image: docker.io/library/alpine:3.20\n")'
expect_red "n12: the casdoor-games render (same namespace) gains a backend container" "the casdoor-games render (same namespace) runs no backend image" 'rep(M+"casdoor-games/kustomization.yaml", "resources:\n", "resources:\n  - shadow.yaml\n")
open(os.path.join(root, M, "casdoor-games/shadow.yaml"), "w").write("apiVersion: apps/v1\nkind: Deployment\nmetadata: { name: shadow, namespace: hugmesh-games }\nspec:\n  selector: { matchLabels: { app: shadow } }\n  template:\n    metadata: { labels: { app: shadow } }\n    spec:\n      containers:\n        - { name: games, image: ghcr.io/hugmesh/hugmesh-games/backend:main }\n")'
expect_red "a nodeSelector label no role sets" "the host KEYS profile sets" 'rep(M+"games/bff-db.yaml", "nodeSelector: { hugmesh.net/games: \"true\" }", "nodeSelector: { hugmesh.net/games-tier: \"true\" }")'
expect_red "the backend-gpu keys hint loses the games label" "its keys hint says" 'rep("build-x86-host-stage4.sh", ", hugmesh.net/games: \x5c\x22true\x5c\x22 }\x22 ;;", " }\x22 ;;")'
expect_red "the games render handed a raw (unencoded) DB password" "reads back byte for byte through the URL" 'rep(M+"casdoor-games/deployment.yaml", "enc(ENVIRON[\"CASDOOR_DB_PASSWORD\"])", "ENVIRON[\"CASDOOR_DB_PASSWORD\"]")'
expect_red "the games render back on sed" "the render script exits 0" 'rep(M+"casdoor-games/deployment.yaml", "              LC_ALL=C awk \x27\n", "              sed -e \"s|__CASDOOR_DB_USER__|${CASDOOR_DB_USER}|g\" -e \"s|__CASDOOR_DB_PASSWORD__|${CASDOOR_DB_PASSWORD}|g\" /template/app.conf.template > /rendered/app.conf; exit $?\n              LC_ALL=C awk \x27\n")'
expect_red "the keyspace Job back to PostSync" "Sync-phase hook" 'rep(M+"games/cassandra-init.yaml", "argocd.argoproj.io/hook: Sync\n", "argocd.argoproj.io/hook: PostSync\n")'
expect_red "the BFF loses its wave" "waves order" 'rep(M+"games/deployment.yaml", "    argocd.argoproj.io/sync-wave: \"2\"\n", "")'
expect_red "casdoor-games dataSourceName back on in-app interpolation" "dataSourceName carries no" 'rep(M+"casdoor-games/app-conf-configmap.yaml", "postgres://__CASDOOR_DB_USER__:__CASDOOR_DB_PASSWORD__@casdoor-games-pg", "postgres://${CASDOOR_DB_USER||threewizards}:${CASDOOR_DB_PASSWORD||}@casdoor-games-pg")'
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
