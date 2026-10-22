#!/usr/bin/env bash
# test-gateway-vanity-domains.sh — the fe-gateway's vanity-subdomain route, per brand
# domain (hugmesh-generator#582), offline.
#
# WHAT WAS TRUE BEFORE. apps/20-gateway-fe.yaml carried the vanity route as the literal
# `host: "*.hugmesh.net"` and the Ingress admitted the literal `*.hugmesh.net`. A mesh
# with a second brand domain had no way to give `<username>.<that domain>` the same
# treatment: the request fell through to the front page route, or never passed the
# Ingress at all.
#
# WHAT IT PINS, AND HOW (nothing is built, booted or deployed; no cluster, no root):
#   A. the chart as the repo ships it — `helm template` of
#      specs/cluster/charts/hugmesh-gateway with the values of the REAL
#      apps/20-gateway-fe.yaml: the vanity route's predicate is exactly the cluster
#      domain's own wildcard, and the Ingress hosts are exactly the committed ones. An
#      empty `vanityDomains` and an absent one render the same bytes.
#   B. with `vanityDomains[i]` set the way ArgoCD passes helm parameters: the vanity
#      route matches `*.<domain>` for each entry (one comma-separated Host predicate,
#      the cluster domain's wildcard first), the Ingress admits `*.<domain>` with the
#      primary host's exact http block (the PoW shield backend included), NO other route
#      gains a host, and the route still sits before the catch-all `frontend-host`.
#   C. the other gateway instances (be, pki, superadmin) — no route of theirs is marked
#      `vanity`, so the same parameters change no Host predicate of theirs.
#   D. controls, staged in a COPY of the chart (the repo tree is never touched): with
#      the route half removed, or the Ingress half removed, or the route's `vanity`
#      mark removed, the checks of B go red. Each control proves its edit landed.
#   E. the edge-AI host: every Host the be-gateway's edge-ai* routes match on is an
#      exact host of the be-gateway Ingress, so ai.<domain> is not handed to the
#      fe-gateway wildcard (whose vanity route would swallow /v1/**); with a control.
#
# WHAT IT CANNOT PROVE: that anything WRITES `vanityDomains` (nothing does yet — no
# builder reads the mesh manifest's domains[]), or that a live ingress-nginx and
# gateway serve `<username>.<brand domain>`. Both are open and said so in the chart's
# values.yaml.
#
#   bash tests/scripts/test-gateway-vanity-domains.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHART="${REPO}/specs/cluster/charts/hugmesh-gateway"
APPS="${REPO}/specs/cluster/apps"
FE_APP="${APPS}/20-gateway-fe.yaml"
for f in "${FE_APP}" "${CHART}/templates/configmap.yaml" "${CHART}/templates/service.yaml" "${CHART}/values.yaml"; do
    [ -e "${f}" ] || { echo "FAIL missing ${f}"; exit 1; }
done
for b in helm python3; do
    command -v "${b}" >/dev/null 2>&1 || { echo "FAIL ${b} is required (an absent tool is a FAIL here, never a skip)"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL python3 yaml (PyYAML) is required"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/gateway-vanity.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

# values_of APP_FILE OUT — the helm values block of an Application, as ArgoCD reads it.
values_of() {
    python3 - "$1" > "$2" <<'PY'
import sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Application"]
sys.stdout.write(docs[0]["spec"]["source"]["helm"]["values"])
PY
}

# render CHART RELEASE VALUES [--set ...] -> the full rendered manifest on stdout.
render() {
    local chart="$1" release="$2" values="$3"; shift 3
    helm template "${release}" "${chart}" -f "${values}" "$@" 2>"${WORK}/render.err"
}

# facts RENDERED -> one JSON object: every route's Host predicate (by id, in order),
# the Ingress hosts in order, and each Ingress rule's http block.
facts() {
    python3 - "$1" <<'PY'
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d]
cm = [d for d in docs if d.get("kind") == "ConfigMap" and d["metadata"]["name"].endswith("-routes")]
ing = [d for d in docs if d.get("kind") == "Ingress"]
routes = yaml.safe_load(cm[0]["data"]["application-routes.yml"])
routes = routes["spring"]["cloud"]["gateway"]["server"]["webflux"]["routes"]
hosts, order = {}, []
for r in routes:
    order.append(r["id"])
    preds = [p for p in r.get("predicates") or [] if str(p).startswith("Host=")]
    if preds:
        hosts[r["id"]] = preds
rules = ing[0]["spec"]["rules"] if ing else []
print(json.dumps({"route_hosts": hosts, "route_order": order,
                  "ingress_hosts": [x.get("host") for x in rules],
                  "ingress_http": {x.get("host"): x.get("http") for x in rules},
                  "ingresses": len(ing), "routes_cm": len(cm)}))
PY
}
jget() { python3 -c 'import json,sys; v=json.loads(sys.argv[1]);
for k in sys.argv[2:]: v=v[k]
print(json.dumps(v, sort_keys=True))' "$@"; }

values_of "${FE_APP}" "${WORK}/fe.yaml" || { echo "FAIL cannot read ${FE_APP}"; exit 1; }
D1="brandb.example"; D2="shop.hugmesh.net"
SETS=(--set "vanityDomains[0]=${D1}" --set "vanityDomains[1]=${D2}")

# ═════════════════════ A. the chart as the repo ships it ═════════════════════
echo "== A. no vanity domain: the committed route and hosts, and nothing else =="
render "${CHART}" hugmesh-fe-gateway "${WORK}/fe.yaml" > "${WORK}/a.yaml" \
    || { bad "A helm template failed: $(head -c 300 "${WORK}/render.err")"; echo; echo "== RESULT: ${P} passed, ${F} failed =="; exit 1; }
A="$(facts "${WORK}/a.yaml")"
[ "$(jget "${A}" route_hosts vanity-subdomain)" = '["Host=*.hugmesh.net"]' ] \
    && ok "A the vanity route matches the cluster domain's own wildcard, exactly" \
    || bad "A vanity predicate: $(jget "${A}" route_hosts)"
[ "$(jget "${A}" route_hosts)" = '{"vanity-subdomain": ["Host=*.hugmesh.net"]}' ] \
    && ok "A it is the only route with a Host predicate" \
    || bad "A routes with a Host predicate: $(jget "${A}" route_hosts)"
[ "$(jget "${A}" ingress_hosts)" = '["hugmesh.net", "*.hugmesh.net"]' ] \
    && ok "A the Ingress admits exactly the committed hosts" \
    || bad "A Ingress hosts: $(jget "${A}" ingress_hosts)"
render "${CHART}" hugmesh-fe-gateway "${WORK}/fe.yaml" --set-json 'vanityDomains=[]' > "${WORK}/a-empty.yaml"
cmp -s "${WORK}/a.yaml" "${WORK}/a-empty.yaml" \
    && ok "A an explicitly empty vanityDomains renders the same bytes as an absent one" \
    || bad "A an empty vanityDomains changed the render"

# ═════════════════════ B. one entry per brand domain ═════════════════════
echo "== B. vanityDomains: the route and the Ingress, both halves =="
render "${CHART}" hugmesh-fe-gateway "${WORK}/fe.yaml" "${SETS[@]}" > "${WORK}/b.yaml" \
    || bad "B helm template failed: $(head -c 300 "${WORK}/render.err")"
B="$(facts "${WORK}/b.yaml")"
WANT_PRED="[\"Host=*.hugmesh.net,*.${D1},*.${D2}\"]"
check_b() {   # check_b FACTS LABEL -> 0 when every B invariant holds (prints nothing)
    local f="$1"
    [ "$(jget "${f}" route_hosts)" = "{\"vanity-subdomain\": ${WANT_PRED}}" ] || return 1
    [ "$(jget "${f}" ingress_hosts)" = "[\"hugmesh.net\", \"*.hugmesh.net\", \"*.${D1}\", \"*.${D2}\"]" ] || return 1
    [ "$(jget "${f}" ingress_http "*.${D1}")" = "$(jget "${f}" ingress_http hugmesh.net)" ] || return 1
    [ "$(jget "${f}" ingress_http "*.${D2}")" = "$(jget "${f}" ingress_http hugmesh.net)" ] || return 1
    return 0
}
[ "$(jget "${B}" route_hosts vanity-subdomain)" = "${WANT_PRED}" ] \
    && ok "B the vanity route matches *.<domain> for each entry, the cluster domain's wildcard first" \
    || bad "B vanity predicate: $(jget "${B}" route_hosts)"
[ "$(jget "${B}" route_hosts)" = "{\"vanity-subdomain\": ${WANT_PRED}}" ] \
    && ok "B no other route gained a Host predicate" \
    || bad "B routes with a Host predicate: $(jget "${B}" route_hosts)"
[ "$(jget "${B}" ingress_hosts)" = "[\"hugmesh.net\", \"*.hugmesh.net\", \"*.${D1}\", \"*.${D2}\"]" ] \
    && ok "B the Ingress admits *.<domain> for each entry, after the committed hosts" \
    || bad "B Ingress hosts: $(jget "${B}" ingress_hosts)"
[ "$(jget "${B}" ingress_http "*.${D1}")" = "$(jget "${B}" ingress_http hugmesh.net)" ] \
    && [ "$(jget "${B}" ingress_http "*.${D2}")" = "$(jget "${B}" ingress_http hugmesh.net)" ] \
    && ok "B each vanity rule carries the primary host's exact http block (path / Prefix, the same backend)" \
    || bad "B a vanity rule's http block differs from the primary host's"
python3 - "${B}" <<'PY' && ok "B the vanity route still sits before the catch-all frontend-host" || bad "B route order: vanity-subdomain is not before frontend-host"
import json, sys
o = json.loads(sys.argv[1])["route_order"]
sys.exit(0 if o.index("vanity-subdomain") < o.index("frontend-host") == len(o) - 1 else 1)
PY
[ "$(jget "${B}" ingresses)" = 1 ] && ok "B still one Ingress (the rules are added to it, not to a second one)" || bad "B Ingress count: $(jget "${B}" ingresses)"
# the PoW shield: when the generator points the Ingress at Anubis, the vanity hosts go through it too
render "${CHART}" hugmesh-fe-gateway "${WORK}/fe.yaml" "${SETS[@]}" \
    --set ingress.backendServiceName=anubis --set ingress.backendServicePort=8923 > "${WORK}/b-anubis.yaml"
BA="$(facts "${WORK}/b-anubis.yaml")"
[ "$(jget "${BA}" ingress_http "*.${D1}")" = "$(jget "${BA}" ingress_http hugmesh.net)" ] \
    && printf '%s' "$(jget "${BA}" ingress_http "*.${D1}")" | grep -aF '"name": "anubis"' >/dev/null \
    && ok "B with the PoW shield as the Ingress backend, a vanity host goes through it too" \
    || bad "B PoW shield: vanity rule backend $(jget "${BA}" ingress_http "*.${D1}")"
# the only lines of the render that differ from A are the predicate, its checksum and the new rules
python3 - "${WORK}/a.yaml" "${WORK}/b.yaml" "${D1}" "${D2}" <<'PY' && ok "B nothing else in the render changed (the predicate line, the routes checksum, the two new rules)" || bad "B the render changed somewhere else too"
import difflib, sys
a = open(sys.argv[1]).read().splitlines(); b = open(sys.argv[2]).read().splitlines()
removed = [l[1:] for l in difflib.ndiff(a, b) if l.startswith("- ")]
added = [l[1:] for l in difflib.ndiff(a, b) if l.startswith("+ ")]
ok_removed = all("Host=*.hugmesh.net" in l or "checksum/routes" in l for l in removed)
rule = {"http:", "paths:", "- path: /", "pathType: Prefix", "backend:", "service:",
        "name: hugmesh-fe-gateway", "port:", "number: 8080",
        '- host: "*.%s"' % sys.argv[3], '- host: "*.%s"' % sys.argv[4]}
ok_added = all(l.strip() in rule or "Host=*.hugmesh.net,*." in l or "checksum/routes" in l for l in added)
sys.exit(0 if ok_removed and ok_added and len(removed) == 2 else 1)
PY

# ═════════════════════ C. the other gateway instances ═════════════════════
echo "== C. the other gateways have no vanity route =="
for app in 20-gateway-be.yaml 20-gateway-pki.yaml 22-gateway-superadmin.yaml; do
    [ -f "${APPS}/${app}" ] || { bad "C ${app} is missing"; continue; }
    values_of "${APPS}/${app}" "${WORK}/${app}.values" 2>/dev/null || { bad "C cannot read ${app}"; continue; }
    grep -aE '^[[:space:]]*vanity:[[:space:]]*true' "${WORK}/${app}.values" >/dev/null \
        && { bad "C ${app} marks a route vanity — only the fe-gateway serves vanity subdomains"; continue; }
    render "${CHART}" gw "${WORK}/${app}.values" > "${WORK}/c0.yaml" 2>/dev/null
    render "${CHART}" gw "${WORK}/${app}.values" "${SETS[@]}" > "${WORK}/c1.yaml" 2>/dev/null
    c0="$(jget "$(facts "${WORK}/c0.yaml")" route_hosts)"; c1="$(jget "$(facts "${WORK}/c1.yaml")" route_hosts)"
    [ -n "${c0}" ] && [ "${c0}" = "${c1}" ] \
        && ok "C ${app}: the same parameters change no route's Host predicate" \
        || bad "C ${app}: route hosts ${c0} -> ${c1}"
done

# ═════════════════════ D. controls ═════════════════════
echo "== D. controls: each half removed in a staged copy turns B red =="
# control ID FILE-RELATIVE-TO-STAGE OLD NEW  (OLD must occur exactly once, or the control proves nothing)
control() {
    local id="$1" rel="$2" old="$3" new="$4" stage="${WORK}/stage-$1"
    rm -rf "${stage}"; mkdir -p "${stage}"
    cp -r "${CHART}" "${stage}/chart"; cp "${FE_APP}" "${stage}/app.yaml"
    if ! python3 - "${stage}/${rel}" "${old}" "${new}" <<'PY'
import sys
p, old, new = sys.argv[1:4]
s = open(p).read()
if s.count(old) != 1:
    sys.exit("anchor occurs %d times" % s.count(old))
open(p, "w").write(s.replace(old, new))
PY
    then bad "D ${id}: the control's edit did not land — it proves nothing"; return; fi
    values_of "${stage}/app.yaml" "${stage}/fe.yaml"
    render "${stage}/chart" hugmesh-fe-gateway "${stage}/fe.yaml" "${SETS[@]}" > "${stage}/out.yaml" 2>/dev/null
    if check_b "$(facts "${stage}/out.yaml" 2>/dev/null)"; then
        bad "D ${id}: the checks of B still pass without it — they would not notice the regression"
    else
        ok "D ${id}: the checks of B go red"
    fi
}
control route-half chart/templates/configmap.yaml \
    '{{ if .vanity }}{{ range $.Values.vanityDomains }},*.{{ . }}{{ end }}{{ end }}' ''
control ingress-half chart/templates/service.yaml \
    '{{- range .Values.vanityDomains }}' '{{- range list }}'
control route-unmarked app.yaml \
    '            vanity: true
' ''
# positive control: an unedited staged copy passes, so the three above are what bite
stage="${WORK}/stage-clean"; mkdir -p "${stage}"; cp -r "${CHART}" "${stage}/chart"; cp "${FE_APP}" "${stage}/app.yaml"
values_of "${stage}/app.yaml" "${stage}/fe.yaml"
render "${stage}/chart" hugmesh-fe-gateway "${stage}/fe.yaml" "${SETS[@]}" > "${stage}/out.yaml" 2>/dev/null
check_b "$(facts "${stage}/out.yaml")" \
    && ok "D positive control: an unedited staged copy passes" \
    || bad "D positive control: an unedited staged copy FAILED — staging is wrong, the controls above mean nothing"

# ═════════════════════ E. the edge-AI host is not a vanity host ═════════════════════
# ingress-nginx serves a Host that has an exact rule from that rule and everything else
# under *.<domain> from the fe-gateway, whose host-only vanity-subdomain route rewrites
# EVERY path to the profile lookup. So each Host the be-gateway's edge-ai* routes match
# on must be an exact host of the be-gateway Ingress, or https://ai.<domain>/v1/models
# lands on the vanity route and never reaches the model server.
echo "== E. ai.<domain> is admitted by the be-gateway Ingress, exactly =="
BE_APP="${APPS}/20-gateway-be.yaml"
# check_e APP_FILE -> 0 when every edge-ai* route Host is an exact be Ingress host
check_e() {
    values_of "$1" "${WORK}/e.values" || return 1
    render "${CHART}" hugmesh-be-gateway "${WORK}/e.values" > "${WORK}/e.yaml" || return 1
    python3 - "$(facts "${WORK}/e.yaml")" <<'PY'
import json, sys
f = json.loads(sys.argv[1])
want = sorted({h for rid, preds in f["route_hosts"].items() if rid.startswith("edge-ai")
               for p in preds for h in p[len("Host="):].split(",")})
if not want:
    sys.exit("no edge-ai route carries a Host predicate")
missing = [h for h in want if h not in f["ingress_hosts"]]
print("edge-ai hosts %s; be Ingress hosts %s" % (want, f["ingress_hosts"]))
sys.exit(1 if missing else 0)
PY
}
e_out="$(check_e "${BE_APP}" 2>&1)" \
    && ok "E every edge-ai route Host is an exact be-gateway Ingress host (${e_out})" \
    || bad "E an edge-ai route Host is missing from the be-gateway Ingress: ${e_out}"
# control: the same app with the ai. extraHost removed must go red
mkdir -p "${WORK}/stage-e"
grep -avE '^[[:space:]]*-[[:space:]]+"?ai\.' "${BE_APP}" > "${WORK}/stage-e/app.yaml"
if cmp -s "${BE_APP}" "${WORK}/stage-e/app.yaml"; then
    bad "E control: removing the ai. extraHost changed nothing — it proves nothing"
elif check_e "${WORK}/stage-e/app.yaml" >/dev/null 2>&1; then
    bad "E control: without the ai. extraHost the check still passes"
else
    ok "E control: without the ai. extraHost the check goes red"
fi

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
