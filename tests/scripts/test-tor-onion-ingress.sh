#!/usr/bin/env bash
# test-tor-onion-ingress.sh — a hardware node's minted .onion is admitted at the
# ingress edge (hugmesh-generator#614), offline.
#
# THE DEFECT IT PINS. A tor-selected node publishes HiddenServicePort 443 -> its ingress
# edge, but the fe-gateway Ingress admitted only the cluster domain, so a Tor client got
# ingress-nginx's default-server 404 and never reached the gateway. Now the node agent
# specs/usr/sbin/hugmesh-tor-ingress-admit writes the node's exported onions as helm
# parameters `ingress.onionHosts[i]` on the fe-gateway Application, and the gateway chart
# renders one Ingress rule per onion.
#
# WHAT IT PINS, AND HOW (nothing is built, booted or deployed; no cluster, no root):
#   A. the chart — `helm template` of specs/cluster/charts/hugmesh-gateway with the
#      values of the REAL apps/20-gateway-fe.yaml: no onion rule by default; with
#      onionHosts, one rule per onion on the SAME Ingress (so the same class), with the
#      SAME backend as the cluster host (Anubis included), and never a TLS entry for it;
#      the internal release state's `nginx-internal` class carries over.
#   B. the agent's `plan` (pure) against sandbox roots (HUGMESH_TOR_ROOT): hostname file
#      present -> the onion is a parameter, absent -> none; per-domain exports; refused
#      non-v3 names; withdrawal of what THIS node admitted before; other nodes' entries
#      and every non-onion parameter (kind's extraHosts[N] included) kept untouched.
#   C. the RENDER proof: plan output fed to `helm template` exactly as ArgoCD passes
#      helm parameters -> the Ingress admits the onion when the hostname file exists and
#      admits no .onion host at all when it does not.
#   D. the agent's `apply` against a STUB kubectl that serves an Application JSON and
#      applies merge patches to it: no admin kubeconfig -> no kubectl call at all;
#      first run -> one patch carrying the resourceVersion + a refresh annotation;
#      steady state -> a read and no patch; withdrawal; get/patch failures fail soft and
#      record nothing; the rebranded Application name is read from the baked tree; an
#      Application without spec.source.helm is refused.
#   E. the wiring — the cron runs the agent every 5 minutes; both stage4 builders' own
#      tor `cp` lines, EXECUTED in a sandbox sysroot, bake it executable next to the
#      reconcile.
#
# WHAT IT CANNOT PROVE: a booted tor node whose ArgoCD re-renders the Ingress and whose
# ingress-nginx then routes https://<onion>/ to the login page. That needs a QEMU tor
# node (operator sudo) and is awaiting a live run.
#
#   bash tests/scripts/test-tor-onion-ingress.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${REPO}/specs/usr/sbin/hugmesh-tor-ingress-admit"
CHART="${REPO}/specs/cluster/charts/hugmesh-gateway"
FE_APP="${REPO}/specs/cluster/apps/20-gateway-fe.yaml"
CRON="${REPO}/specs/etc/cron.d/hugmesh-tor-reconcile"
X86="${REPO}/build-x86-host-stage4.sh"
RPI5="${REPO}/build-rpi5-stage4.sh"
for f in "${AGENT}" "${FE_APP}" "${CRON}" "${X86}" "${RPI5}" "${CHART}/templates/service.yaml"; do
    [ -e "${f}" ] || { echo "FAIL missing ${f}"; exit 1; }
done
for b in helm jq python3; do
    command -v "${b}" >/dev/null 2>&1 || { echo "FAIL ${b} is required (an absent tool is a FAIL here, never a skip)"; exit 1; }
done
python3 -c 'import yaml' 2>/dev/null || { echo "FAIL python3 yaml (PyYAML) is required"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
has()   { printf '%s\n' "$1" | grep -aF -- "$2" >/dev/null; }
hasnt() { ! has "$1" "$2"; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tor-onion-ingress.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

ONION_A="$(printf 'a%.0s' $(seq 56)).onion"
ONION_B="$(printf 'b%.0s' $(seq 56)).onion"
ONION_G="$(printf 'g%.0s' $(seq 55))2.onion"
ONION_X="$(printf 'x%.0s' $(seq 56)).onion"   # admitted by ANOTHER node
ONION_OLD="$(printf 'o%.0s' $(seq 56)).onion" # admitted by THIS node earlier

# The fe-gateway Application as the repo ships it, as JSON (what `kubectl get -o json`
# returns), with a resourceVersion.
python3 - "${FE_APP}" > "${WORK}/app.json" <<'PY' || { echo "FAIL cannot read ${FE_APP}"; exit 1; }
import json, sys, yaml
docs = [d for d in yaml.safe_load_all(open(sys.argv[1])) if d and d.get("kind") == "Application"]
app = docs[0]
app.setdefault("metadata", {})["resourceVersion"] = "4242"
print(json.dumps(app))
PY
jq -r '.spec.source.helm.values' "${WORK}/app.json" > "${WORK}/values.yaml"

# render VALUES_FILE PARAMS_JSON -> the Ingress document, as ArgoCD renders the chart
# (`helm template` with each helm parameter as a --set).
render() {
    local _sets=() _n _v
    while IFS=$'\t' read -r _n _v; do
        [ -n "${_n}" ] && _sets+=(--set "${_n}=${_v}")
    done < <(jq -r '.[] | [.name, .value] | @tsv' <<<"$2")
    helm template hugmesh-fe-gateway "${CHART}" -f "$1" "${_sets[@]+"${_sets[@]}"}" 2>"${WORK}/render.err" \
        | python3 -c '
import json, sys, yaml
ing = [d for d in yaml.safe_load_all(sys.stdin) if d and d.get("kind") == "Ingress"]
print(json.dumps(ing[0] if len(ing) == 1 else {"_count": len(ing)}))'
}
hosts_of()   { jq -r '[.spec.rules[]?.host] | join(" ")' <<<"$1"; }
backend_of() { jq -r --arg h "$2" '.spec.rules[] | select(.host == $h) | .http.paths[0].backend.service | "\(.name):\(.port.number)"' <<<"$1"; }

# ═════════════════════════════ A. the chart ═════════════════════════════
echo "== A. the gateway chart renders onionHosts as Ingress rules =="
ING0="$(render "${WORK}/values.yaml" '[]')"
[ "$(jq -r '.kind // empty' <<<"${ING0}")" = Ingress ] && ok "A the fe Application values render exactly one Ingress" || bad "A no single Ingress rendered: ${ING0} $(head -c 300 "${WORK}/render.err")"
h0="$(hosts_of "${ING0}")"
hasnt "${h0}" ".onion" && ok "A default render admits no .onion host (${h0})" || bad "A default render already admits an onion: ${h0}"
PRIMARY="$(jq -r '.spec.rules[0].host' <<<"${ING0}")"

ING1="$(render "${WORK}/values.yaml" "$(jq -cn --arg a "${ONION_A}" --arg b "${ONION_B}" '[{name:"ingress.onionHosts[0]",value:$a},{name:"ingress.onionHosts[1]",value:$b}]')")"
h1="$(hosts_of "${ING1}")"
has " ${h1} " " ${ONION_A} " && has " ${h1} " " ${ONION_B} " && ok "A onionHosts[0..1] -> both onions are Ingress hosts" || bad "A onionHosts not rendered: ${h1}"
[ "$(jq '.spec.rules | length' <<<"${ING1}")" -eq "$(( $(jq '.spec.rules | length' <<<"${ING0}") + 2 ))" ] \
    && ok "A exactly two rules added, nothing else changed in the rule list" || bad "A rule count wrong: $(jq '.spec.rules|length' <<<"${ING1}")"
[ "$(backend_of "${ING1}" "${ONION_A}")" = "$(backend_of "${ING1}" "${PRIMARY}")" ] \
    && ok "A the onion rule has the SAME backend as the cluster host ($(backend_of "${ING1}" "${PRIMARY}"))" || bad "A onion backend '$(backend_of "${ING1}" "${ONION_A}")' != primary '$(backend_of "${ING1}" "${PRIMARY}")'"
[ "$(jq -r '[.spec.tls[]?.hosts[]?] | map(select(endswith(".onion"))) | length' <<<"${ING1}")" -eq 0 ] \
    && ok "A no TLS entry names an onion (no onion SAN exists; the edge default certificate answers)" || bad "A a TLS entry names an onion"
# The internal release state (the builders' sed: className nginx -> nginx-internal) and the
# Anubis PoW shield (backendServiceName: anubis) must carry over to the onion rule.
sed -E 's/^([[:space:]]*className: )nginx$/\1nginx-internal/' "${WORK}/values.yaml" > "${WORK}/values-internal.yaml"
cmp -s "${WORK}/values.yaml" "${WORK}/values-internal.yaml" && bad "A internal-state fixture: the className sed changed nothing (fixture broken)"
ING2="$(render "${WORK}/values-internal.yaml" "$(jq -cn --arg a "${ONION_A}" '[{name:"ingress.onionHosts[0]",value:$a}]')")"
[ "$(jq -r '.spec.ingressClassName' <<<"${ING2}")" = nginx-internal ] && has " $(hosts_of "${ING2}") " " ${ONION_A} " \
    && ok "A RELEASE_STATE=internal: the onion rule rides the nginx-internal Ingress (the pki edge serves it)" || bad "A internal class: $(jq -c '{c:.spec.ingressClassName,h:[.spec.rules[].host]}' <<<"${ING2}")"
ING3="$(render "${WORK}/values.yaml" "$(jq -cn --arg a "${ONION_A}" '[{name:"ingress.onionHosts[0]",value:$a},{name:"ingress.backendServiceName",value:"anubis"},{name:"ingress.backendServicePort",value:"8923"}]')")"
[ "$(backend_of "${ING3}" "${ONION_A}")" = "anubis:8923" ] && ok "A Anubis up: the onion goes through the PoW gate like the clearnet host" || bad "A Anubis: onion backend '$(backend_of "${ING3}" "${ONION_A}")'"

# ═════════════════════════════ B. the agent's plan (pure) ═════════════════════════════
echo "== B. hugmesh-tor-ingress-admit plan =="
mkroot() {  # NAME -> a sandbox root with the export + state dirs
    local _r="${WORK}/root-$1"
    rm -rf "${_r}"; mkdir -p "${_r}/var/lib/hugmesh/tor" "${_r}/var/lib/hugmesh/tor-ingress" "${_r}/var/log"
    printf '%s' "${_r}"
}
plan() {  # ROOT [APP_JSON_FILE] -> params JSON in $p, the agent's rc in PLAN_RC (no subshell)
    HUGMESH_TOR_ROOT="$1" bash "${AGENT}" plan < "${2:-${WORK}/app.json}" > "${WORK}/plan.out" 2>"${WORK}/plan.err"
    PLAN_RC=$?
    p="$(cat "${WORK}/plan.out")"
}
onions_in() { jq -r '[.[] | select(.name | test("^ingress\\.onionHosts\\[[0-9]+\\]$")) | .value] | join(" ")' <<<"$1"; }
BASE_PARAMS="$(jq -c '.spec.source.helm.parameters // []' "${WORK}/app.json")"

R1="$(mkroot none)"
plan "${R1}"
[ "${PLAN_RC}" -eq 0 ] && [ -z "$(onions_in "${p}")" ] && ok "B no hostname file -> no onion parameter" || bad "B no hostname: rc=${PLAN_RC} onions='$(onions_in "${p}")' $(head -c 200 "${WORK}/plan.err")"
[ "$(jq -cS . <<<"${p}")" = "$(jq -cS . <<<"${BASE_PARAMS}")" ] && ok "B no hostname file -> the parameter list is unchanged" || bad "B no hostname: params changed: ${p}"

R2="$(mkroot primary)"; printf '%s\n' "${ONION_A}" > "${R2}/var/lib/hugmesh/tor/hostname"
plan "${R2}"
[ "$(onions_in "${p}")" = "${ONION_A}" ] && has "${p}" '"name":"ingress.onionHosts[0]"' && ok "B primary hostname -> ingress.onionHosts[0]=<onion>" || bad "B primary: ${p}"

R3="$(mkroot domains)"; printf '%s\n' "${ONION_A}" > "${R3}/var/lib/hugmesh/tor/hostname"
printf '%s\n' "${ONION_G}" > "${R3}/var/lib/hugmesh/tor/games.hostname"
printf '  %s  \n' "${ONION_B}" > "${R3}/var/lib/hugmesh/tor/brandb.hostname"
plan "${R3}"
[ "$(onions_in "${p}")" = "${ONION_A} ${ONION_B} ${ONION_G}" ] && ok "B primary + two per-domain exports -> three hosts, primary first then slug order (whitespace trimmed)" || bad "B domains: '$(onions_in "${p}")'"

R4="$(mkroot invalid)"
printf '%s\n' "$(printf 'a%.0s' $(seq 55)).onion" > "${R4}/var/lib/hugmesh/tor/hostname"           # 55 chars
printf '%s\n' "$(printf 'A%.0s' $(seq 56)).onion" > "${R4}/var/lib/hugmesh/tor/upper.hostname"      # uppercase
printf '%s\n' "${ONION_A}.evil.example" > "${R4}/var/lib/hugmesh/tor/suffix.hostname"               # not an onion
printf '%s"}]\n' "${ONION_B}" > "${R4}/var/lib/hugmesh/tor/inject.hostname"                         # JSON injection
printf '%s\n' "$(printf '1%.0s' $(seq 56)).onion" > "${R4}/var/lib/hugmesh/tor/digit.hostname"      # base32 has no 1
plan "${R4}"
[ "${PLAN_RC}" -eq 0 ] && [ -z "$(onions_in "${p}")" ] && ok "B a 55-char, uppercase, suffixed, injected or non-base32 name is refused" || bad "B invalid names admitted: '$(onions_in "${p}")'"

R5="$(mkroot dup)"; printf '%s\n' "${ONION_A}" > "${R5}/var/lib/hugmesh/tor/hostname"; printf '%s\n' "${ONION_A}" > "${R5}/var/lib/hugmesh/tor/same.hostname"
plan "${R5}"
[ "$(onions_in "${p}")" = "${ONION_A}" ] && ok "B the same onion exported twice -> one host" || bad "B dup: '$(onions_in "${p}")'"

# live Application already carrying: a kind-style extraHosts parameter, another node's
# onion, and an onion THIS node admitted earlier (recorded) but no longer exports.
jq --arg x "${ONION_X}" --arg o "${ONION_OLD}" \
   '.spec.source.helm.parameters = [{name:"ingress.extraHosts[1]",value:"kind.example"},{name:"ingress.onionHosts[0]",value:$x},{name:"ingress.onionHosts[1]",value:$o},{name:"image.tag",value:"1.2.3"}]' \
   "${WORK}/app.json" > "${WORK}/app-live.json"
R6="$(mkroot withdraw)"; printf '%s\n' "${ONION_A}" > "${R6}/var/lib/hugmesh/tor/hostname"; printf '%s\n' "${ONION_OLD}" > "${R6}/var/lib/hugmesh/tor-ingress/admitted"
plan "${R6}" "${WORK}/app-live.json"
[ "$(onions_in "${p}")" = "${ONION_X} ${ONION_A}" ] && ok "B withdraws this node's stale onion, keeps another node's, appends its own (reindexed from 0)" || bad "B withdraw: '$(onions_in "${p}")' ${p}"
has "${p}" '{"name":"ingress.extraHosts[1]","value":"kind.example"}' && has "${p}" '{"name":"image.tag","value":"1.2.3"}' \
    && ok "B every non-onion parameter (kind's extraHosts[N], image.tag) is kept verbatim" || bad "B non-onion params lost: ${p}"
[ "$(jq -r '[.[] | select(.name|startswith("ingress.onionHosts[")) | .name] | join(" ")' <<<"${p}")" = "ingress.onionHosts[0] ingress.onionHosts[1]" ] \
    && ok "B onion indices are contiguous from 0 (no helm list gap)" || bad "B indices: ${p}"
R7="$(mkroot other)"
plan "${R7}" "${WORK}/app-live.json"
[ "$(onions_in "${p}")" = "${ONION_X} ${ONION_OLD}" ] && ok "B a node with no export and no record touches no other node's entry" || bad "B other: '$(onions_in "${p}")'"

# ═════════════════════════════ C. the render proof ═════════════════════════════
echo "== C. render: hostname file present -> admitted; absent -> no .onion host =="
plan "${R2}"; ING="$(render "${WORK}/values.yaml" "${p}")"
has " $(hosts_of "${ING}") " " ${ONION_A} " && [ "$(backend_of "${ING}" "${ONION_A}")" = "$(backend_of "${ING}" "${PRIMARY}")" ] \
    && ok "C hostname file present: the rendered Ingress admits ${ONION_A:0:12}….onion -> $(backend_of "${ING}" "${ONION_A}")" || bad "C present: hosts '$(hosts_of "${ING}")'"
plan "${R1}"; ING="$(render "${WORK}/values.yaml" "${p}")"
hasnt "$(hosts_of "${ING}")" ".onion" && ok "C hostname file absent: the rendered Ingress admits no .onion host" || bad "C absent: hosts '$(hosts_of "${ING}")'"
plan "${R3}"; ING="$(render "${WORK}/values.yaml" "${p}")"
n="$(jq '[.spec.rules[].host | select(endswith(".onion"))] | length' <<<"${ING}")"
[ "${n}" -eq 3 ] && ok "C primary + two domain onions: three onion rules rendered" || bad "C domains rendered ${n} onion rules"

# ═════════════════════════════ D. apply against a stub kubectl ═════════════════════════════
echo "== D. hugmesh-tor-ingress-admit apply (stub kubectl) =="
STUB="${WORK}/stub"; mkdir -p "${STUB}"
cat > "${STUB}/kubectl" <<'SH'
#!/usr/bin/env bash
# Stub: logs argv, serves ${KT_APP} for `get application`, applies a merge patch to it
# (honouring a resourceVersion precondition like the API server does).
echo "$*" >> "${KT_LOG}"
args=("$@"); verb=""; name=""; body=""
for ((i=0; i<${#args[@]}; i++)); do
    case "${args[i]}" in
        get|patch|annotate) [ -z "${verb}" ] && { verb="${args[i]}"; name="${args[i+2]:-}"; } ;;
        -p) body="${args[i+1]}" ;;
    esac
done
[ -n "${KT_FAIL:-}" ] && [ "${KT_FAIL}" = "${verb}" ] && { echo "stub: ${verb} fails" >&2; exit 1; }
case "${verb}" in
    get)   [ "${name}" = "${KT_WANT_NAME}" ] || { echo "not found: ${name}" >&2; exit 1; }; cat "${KT_APP}" ;;
    patch)
        rv="$(jq -r '.metadata.resourceVersion // empty' <<<"${body}")"
        cur="$(jq -r '.metadata.resourceVersion' "${KT_APP}")"
        [ -z "${rv}" ] || [ "${rv}" = "${cur}" ] || { echo "Conflict" >&2; exit 1; }
        jq --argjson b "${body}" '.spec.source.helm.parameters = $b.spec.source.helm.parameters | .metadata.resourceVersion = ((.metadata.resourceVersion|tonumber) + 1 | tostring)' "${KT_APP}" > "${KT_APP}.new" && mv "${KT_APP}.new" "${KT_APP}"
        printf '%s\n' "${body}" >> "${KT_LOG}.bodies" ;;
    annotate) : ;;
    *) exit 1 ;;
esac
SH
chmod +x "${STUB}/kubectl"
apply() {  # ROOT -> runs apply; APPLY_RC, and the stub log in KLOG
    : > "${WORK}/kt.log"; : > "${WORK}/kt.log.bodies"
    HUGMESH_TOR_ROOT="$1" HUGMESH_TOR_KUBECTL="${STUB}/kubectl" KT_LOG="${WORK}/kt.log" KT_APP="${WORK}/live.json" \
        KT_WANT_NAME="${KT_WANT_NAME:-hugmesh-gateway-fe}" KT_FAIL="${KT_FAIL:-}" bash "${AGENT}" apply > "${WORK}/apply.out" 2>&1
    APPLY_RC=$?
    KLOG="$(cat "${WORK}/kt.log")"
}
n_verb() { printf '%s\n' "${KLOG}" | grep -ac -- " $1 application " || true; }
live_onions() { onions_in "$(jq -c '.spec.source.helm.parameters // []' "${WORK}/live.json")"; }
baked() {  # ROOT [NAME] -> bake the (optionally rebranded) fe Application + an admin kubeconfig
    mkdir -p "$1/var/lib/hugmesh/cluster/apps" "$1/etc/kubernetes"
    sed "s/^  name: hugmesh-gateway-fe$/  name: ${2:-hugmesh-gateway-fe}/" "${FE_APP}" > "$1/var/lib/hugmesh/cluster/apps/20-gateway-fe.yaml"
    : > "$1/etc/kubernetes/admin.conf"
}

# the live Application carries one unrelated helm parameter, so ordering and keep-verbatim
# are both observable
jq '.spec.source.helm.parameters = [{name:"image.tag",value:"1.2.3"}]' "${WORK}/app.json" > "${WORK}/live.json"
D1="$(mkroot noconf)"; printf '%s\n' "${ONION_A}" > "${D1}/var/lib/hugmesh/tor/hostname"
apply "${D1}"
[ "${APPLY_RC}" -eq 0 ] && [ -z "${KLOG}" ] && ok "D1 no /etc/kubernetes/admin.conf (a worker) -> exit 0 and NO kubectl call" || bad "D1 rc=${APPLY_RC} kubectl: ${KLOG}"
has "$(cat "${D1}/var/log/hugmesh-tor-ingress-admit.log" 2>/dev/null)" "not a control-plane node" && ok "D1 the log says why nothing was admitted" || bad "D1 silent: $(cat "${D1}/var/log/hugmesh-tor-ingress-admit.log" 2>/dev/null)"

D2="$(mkroot cp)"; baked "${D2}"; printf '%s\n' "${ONION_A}" > "${D2}/var/lib/hugmesh/tor/hostname"
apply "${D2}"
[ "${APPLY_RC}" -eq 0 ] && [ "$(n_verb patch)" -eq 1 ] && ok "D2 control-plane node + hostname -> exactly one patch" || bad "D2 rc=${APPLY_RC} patches=$(n_verb patch): ${KLOG}"
[ "$(live_onions)" = "${ONION_A}" ] && ok "D2 the live Application now carries ingress.onionHosts[0]=<onion>" || bad "D2 live onions '$(live_onions)'"
jq -e '.spec.source.helm.parameters | any(.name == "image.tag" and .value == "1.2.3")' "${WORK}/live.json" >/dev/null \
    && ok "D2 the unrelated helm parameter survives the patch" || bad "D2 the patch dropped image.tag: $(jq -c '.spec.source.helm.parameters' "${WORK}/live.json")"
has "$(cat "${WORK}/kt.log.bodies")" '"resourceVersion":"4242"' && ok "D2 the patch carries the read resourceVersion (a concurrent writer conflicts instead of losing an entry)" || bad "D2 no resourceVersion precondition: $(cat "${WORK}/kt.log.bodies")"
has "${KLOG}" "--kubeconfig ${D2}/etc/kubernetes/admin.conf" && has "${KLOG}" "-n devops" && ok "D2 kubectl runs with the node admin kubeconfig in the Application namespace" || bad "D2 kubectl argv: ${KLOG}"
has "${KLOG}" "argocd.argoproj.io/refresh=hard" && ok "D2 ArgoCD is asked to refresh" || bad "D2 no refresh annotation"
[ "$(cat "${D2}/var/lib/hugmesh/tor-ingress/admitted" 2>/dev/null)" = "${ONION_A}" ] && ok "D2 the admitted record names the onion" || bad "D2 admitted record: '$(cat "${D2}/var/lib/hugmesh/tor-ingress/admitted" 2>/dev/null)'"
ING="$(render "${WORK}/values.yaml" "$(jq -c '.spec.source.helm.parameters' "${WORK}/live.json")")"
has " $(hosts_of "${ING}") " " ${ONION_A} " && ok "D2 the PATCHED Application renders an Ingress that admits the onion" || bad "D2 patched render hosts '$(hosts_of "${ING}")'"

apply "${D2}"
[ "${APPLY_RC}" -eq 0 ] && [ "$(n_verb get)" -eq 1 ] && [ "$(n_verb patch)" -eq 0 ] && ok "D3 steady state -> one read, NO patch" || bad "D3 steady: ${KLOG}"
# order-only difference must not patch either (two writers ordering differently would
# otherwise patch forever)
jq '.spec.source.helm.parameters |= ([.[] | select(.name|startswith("ingress.onionHosts"))] + [.[] | select(.name|startswith("ingress.onionHosts")|not)])' "${WORK}/live.json" > "${WORK}/live.tmp" && mv "${WORK}/live.tmp" "${WORK}/live.json"
[ "$(jq -r '.spec.source.helm.parameters[0].name' "${WORK}/live.json")" = "ingress.onionHosts[0]" ] || bad "D3 reorder fixture did not reorder (fixture broken)"
apply "${D2}"
[ "$(n_verb patch)" -eq 0 ] && ok "D3 a reordered but equal parameter set -> NO patch" || bad "D3 reorder patched: ${KLOG}"

rm -f "${D2}/var/lib/hugmesh/tor/hostname"
apply "${D2}"
[ "$(n_verb patch)" -eq 1 ] && [ -z "$(live_onions)" ] && ok "D4 hostname withdrawn -> one patch removes this node's onion" || bad "D4 withdraw: patches=$(n_verb patch) live='$(live_onions)'"
[ ! -s "${D2}/var/lib/hugmesh/tor-ingress/admitted" ] && ok "D4 the admitted record is emptied" || bad "D4 record kept: $(cat "${D2}/var/lib/hugmesh/tor-ingress/admitted")"
apply "${D2}"
[ -z "${KLOG}" ] && ok "D4 nothing exported and nothing admitted -> no kubectl call at all" || bad "D4 idle run called kubectl: ${KLOG}"

printf '%s\n' "${ONION_A}" > "${D2}/var/lib/hugmesh/tor/hostname"
KT_FAIL=get apply "${D2}"
[ "${APPLY_RC}" -eq 0 ] && [ "$(n_verb patch)" -eq 0 ] && [ ! -s "${D2}/var/lib/hugmesh/tor-ingress/admitted" ] && ok "D5 Application unreadable (API not up) -> exit 0, no patch, nothing recorded" || bad "D5 rc=${APPLY_RC} ${KLOG}"
KT_FAIL=patch apply "${D2}"
[ "${APPLY_RC}" -eq 0 ] && [ ! -s "${D2}/var/lib/hugmesh/tor-ingress/admitted" ] && [ -z "$(live_onions)" ] && ok "D6 patch refused (conflict/RBAC) -> exit 0, nothing recorded, retried next run" || bad "D6 rc=${APPLY_RC} record='$(cat "${D2}/var/lib/hugmesh/tor-ingress/admitted" 2>/dev/null)'"
apply "${D2}"
[ "$(live_onions)" = "${ONION_A}" ] && ok "D6 the next run admits it" || bad "D6 retry: '$(live_onions)'"

cp "${WORK}/app.json" "${WORK}/live.json"
D7="$(mkroot brand)"; baked "${D7}" acme-gateway-fe; printf '%s\n' "${ONION_A}" > "${D7}/var/lib/hugmesh/tor/hostname"
KT_WANT_NAME=acme-gateway-fe apply "${D7}"
[ "$(n_verb patch)" -eq 1 ] && has "${KLOG}" "patch application acme-gateway-fe" && ok "D7 a rebranded image patches <brand>-gateway-fe, read from the baked Application" || bad "D7 brand: ${KLOG}"

jq 'del(.spec.source.helm)' "${WORK}/app.json" > "${WORK}/live.json"
D8="$(mkroot nohelm)"; baked "${D8}"; printf '%s\n' "${ONION_A}" > "${D8}/var/lib/hugmesh/tor/hostname"
apply "${D8}"
[ "${APPLY_RC}" -eq 0 ] && [ "$(n_verb patch)" -eq 0 ] && ok "D8 an Application without spec.source.helm is refused, not rewritten" || bad "D8 ${KLOG}"

# a run that DID patch, with another node's entry present, keeps it
jq --arg x "${ONION_X}" '.spec.source.helm.parameters = [{name:"ingress.onionHosts[0]",value:$x}]' "${WORK}/app.json" > "${WORK}/live.json"
D9="$(mkroot twonodes)"; baked "${D9}"; printf '%s\n' "${ONION_A}" > "${D9}/var/lib/hugmesh/tor/hostname"
apply "${D9}"
[ "$(live_onions)" = "${ONION_X} ${ONION_A}" ] && ok "D9 a second tor control-plane node appends; the first node's onion survives" || bad "D9 '$(live_onions)'"

# ═════════════════════════════ E. wiring ═════════════════════════════
echo "== E. cron + builder bake =="
cron_code="$(grep -av -E '^[[:space:]]*(#|$)' "${CRON}")"
cline="$(printf '%s\n' "${cron_code}" | grep -aE '[[:space:]]root[[:space:]]+/usr/sbin/hugmesh-tor-ingress-admit([[:space:]]|$)' || true)"
[ "$(printf '%s' "${cline}" | grep -ac .)" -eq 1 ] && ok "E cron.d: exactly one entry runs the admit agent as root" || bad "E cron.d: admit entries: '${cline}'"
case "$(awk '{print $1" "$2" "$3" "$4" "$5}' <<<"${cline}")" in
    '*/5 * * * *'|'*/2 * * * *'|'* * * * *') ok "E cron.d: the admit agent runs at least every 5 minutes (API/ArgoCD come up long after the @reboot export)" ;;
    *) bad "E cron.d: admit cadence '$(awk '{print $1" "$2" "$3" "$4" "$5}' <<<"${cline}")' is slower than every 5 minutes" ;;
esac
for B in "${X86}" "${RPI5}"; do
    bn="$(basename "${B}")"
    cps="$(grep -av -E '^[[:space:]]*#' "${B}" | grep -aE '^[[:space:]]*cp "\$\{SHARED_SPECS\}/(usr/sbin|etc/init.d|etc/cron.d)/hugmesh-tor-')"
    SB="${WORK}/bake-${bn}"; rm -rf "${SB}"; mkdir -p "${SB}/usr/sbin" "${SB}/etc/init.d" "${SB}/etc/hugmesh/registry"
    ( SHARED_SPECS="${REPO}/specs"; SYSROOT="${SB}"; eval "${cps}" ) >/dev/null 2>&1
    if [ -x "${SB}/usr/sbin/hugmesh-tor-ingress-admit" ] && [ -x "${SB}/usr/sbin/hugmesh-tor-reconcile" ] \
       && cmp -s "${SB}/usr/sbin/hugmesh-tor-ingress-admit" "${AGENT}"; then
        ok "E ${bn}: its own tor bake lines, executed, put an executable admit agent next to the reconcile"
    else
        bad "E ${bn}: executed tor bake lines did not bake an executable /usr/sbin/hugmesh-tor-ingress-admit"; printf '%s\n' "${cps}" | sed 's/^/      | /'
    fi
done

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
