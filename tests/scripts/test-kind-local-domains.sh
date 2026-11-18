#!/usr/bin/env bash
# =============================================================================
# test-kind-local-domains.sh — scripts/kind-local-domains.sh (the kind lane's per-domain
# look door) refuses what it cannot do, applies exactly what the looks folder says,
# fails when the door does not answer, and deletes only what it labelled.
#
# WHY. The Docker lane serves each domain's own look and the list of the mesh's domains;
# the kind lane did neither (one look for the mesh, no other host). The script gives it
# both. Its honesty is the point: a probe that "passes" when the door answers nothing, or
# a `down` that deletes by name instead of by label, would be a lane that lies. This suite
# runs the REAL script and the REAL look_serving against stub kubectl and curl (nothing
# touches a cluster or the network) and pins:
#   1. an unknown kube context       -> rc 2, names `make kind-up`, kubectl never applies
#   2. a missing namespace           -> rc 2, names `make kind-up`
#   3. `up`                          -> seeds the samples, applies ONE List holding the six
#                                       objects, waits for the rollout, probes each host
#                                       with --resolve to 127.0.0.1, rc 0
#   4. a door that answers 404       -> rc 1 and the failing host named (never "ok")
#   5. KIND_SAMPLE_DOMAINS=0 and nothing recorded -> rc 1, kubectl never applies
#   6. `down`                        -> ONE delete, selected by the label, no object names
#   7. an unknown verb               -> usage, rc 2
# Needs bash + python3 (no PyYAML, no Qt).
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL="$(cd "${HERE}/../.." && pwd)"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/kind-local-domains-test.XXXXXX")" || exit 2
trap 'rm -rf "${WORK}"' EXIT
export PYTHONDONTWRITEBYTECODE=1

# A copy of the tree the script needs, so seeding writes into WORK and not the checkout.
mkdir -p "${WORK}/repo/scripts" "${WORK}/bin"
cp "${REAL}/scripts/kind-local-domains.sh" "${WORK}/repo/scripts/"
ln -s "${REAL}/studio" "${WORK}/repo/studio"
SCRIPT="${WORK}/repo/scripts/kind-local-domains.sh"

# stub kubectl: records argv (one call per line) and the file given to `apply -f`.
cat > "${WORK}/bin/kubectl" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "${STUB_LOG}"
case "$*" in
  *"config get-contexts"*) echo "${STUB_CONTEXTS:-kind-hugmesh-local}"; exit 0 ;;
  *" get ns "*) [ "${STUB_NS:-present}" = "present" ] && exit 0 || exit 1 ;;
  *" apply -f "*) a="$*"; f="${a##* -f }"; f="${f%% *}"; cp "$f" "${STUB_APPLIED}"; exit 0 ;;
esac
exit 0
EOF
# stub curl: prints the HTTP code STUB_CODE and records the --resolve it was given.
cat > "${WORK}/bin/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "${STUB_LOG}"
printf '%s' "${STUB_CODE:-200}"
EOF
chmod +x "${WORK}/bin/kubectl" "${WORK}/bin/curl"
export PATH="${WORK}/bin:${PATH}"
export STUB_LOG="${WORK}/calls.log" STUB_APPLIED="${WORK}/applied.json"

P=0; F=0
ok()  { P=$((P+1)); echo "  PASS $*"; }
bad() { F=$((F+1)); echo "  FAIL $*"; }
reset() { : > "${STUB_LOG}"; rm -f "${STUB_APPLIED}"; rm -rf "${WORK}/repo/tests"; }
run() { bash "${SCRIPT}" "$@" >"${WORK}/out.txt" 2>&1; echo $?; }
applied() { grep -c ' apply -f ' "${STUB_LOG}"; }

echo "== 1. unknown kube context"
reset; rc="$(STUB_CONTEXTS=other run up)"
[ "${rc}" = 2 ] && ok "rc 2" || bad "rc ${rc}, want 2"
grep -q 'make kind-up' "${WORK}/out.txt" && ok "names make kind-up" || bad "no hint"
[ "$(applied)" = 0 ] && ok "nothing applied" || bad "applied"

echo "== 2. namespace missing"
reset; rc="$(STUB_NS=absent run up)"
[ "${rc}" = 2 ] && ok "rc 2" || bad "rc ${rc}, want 2"
grep -q 'make kind-up' "${WORK}/out.txt" && ok "names make kind-up" || bad "no hint"
[ "$(applied)" = 0 ] && ok "nothing applied" || bad "applied"

echo "== 3. up applies the samples' six objects and probes each host"
reset; rc="$(run up)"
[ "${rc}" = 0 ] && ok "rc 0" || { bad "rc ${rc}"; sed 's/^/      /' "${WORK}/out.txt"; }
[ "$(applied)" = 1 ] && ok "exactly one apply" || bad "applies: $(applied)"
if [ -s "${STUB_APPLIED}" ]; then
  python3 - "${STUB_APPLIED}" <<'PY' && ok "one List of ConfigMap x2, Deployment, Service, Ingress x2, all labelled" || bad "wrong objects"
import json, sys
d = json.load(open(sys.argv[1]))
kinds = sorted(o["kind"] for o in d["items"])
assert d["kind"] == "List" and kinds == ["ConfigMap", "ConfigMap", "Deployment", "Ingress", "Ingress", "Service"], kinds
assert all(o["metadata"]["labels"]["hugmesh.net/local-domains"] == "true" for o in d["items"])
PY
else
  bad "kubectl never received a file"
fi
grep -q 'rollout status deploy/hugmesh-look-door' "${STUB_LOG}" && ok "waited for the rollout" || bad "no rollout wait"
for h in acme.localhost example.localhost; do
  grep -q "curl.*--resolve ${h}:8443:127.0.0.1 https://${h}:8443/hug-domains.json" "${STUB_LOG}" \
    && ok "probed ${h} over https through 127.0.0.1:8443" || bad "did not probe ${h} over https"
  grep -q "curl.*--resolve ${h}:8080:127.0.0.1 http://${h}:8080/hug-domains.json" "${STUB_LOG}" \
    && ok "probed ${h} over http through 127.0.0.1:8080" || bad "did not probe ${h} over http"
  grep -q "ok    https://${h}:8443/login/" "${WORK}/out.txt" && ok "printed the https sign-in URL for ${h}" || bad "no https URL for ${h}"
done
[ -d "${WORK}/repo/tests/stack/.looks/by-host/acme.localhost" ] && ok "samples seeded into the tree it runs in" || bad "no samples"

echo "== 4. a door that answers 404 fails and names the host"
reset; rc="$(STUB_CODE=404 PROBE_SECONDS=0 run up)"
[ "${rc}" = 1 ] && ok "rc 1" || bad "rc ${rc}, want 1"
grep -q "FAIL .*acme.localhost.*'404'" "${WORK}/out.txt" && ok "names acme.localhost and the code" || bad "host not named"
grep -q "FAIL .*acme.localhost: https" "${WORK}/out.txt" && grep -q "FAIL .*acme.localhost: http " "${WORK}/out.txt" \
  && ok "names both the https and the http leg" || bad "a leg was not reported"
grep -q 'ok    http' "${WORK}/out.txt" && bad "reported ok for a 404" || ok "no false ok"

echo "== 5. samples off and nothing recorded -> nothing to serve"
reset; rc="$(KIND_SAMPLE_DOMAINS=0 run up)"
[ "${rc}" = 1 ] && ok "rc 1" || bad "rc ${rc}, want 1"
[ "$(applied)" = 0 ] && ok "nothing applied" || bad "applied"

echo "== 6. down deletes by label only"
reset; rc="$(run down)"
[ "${rc}" = 0 ] && ok "rc 0" || bad "rc ${rc}"
n="$(grep -c ' delete ' "${STUB_LOG}")"
[ "${n}" = 1 ] && ok "one delete call" || bad "delete calls: ${n}"
d="$(grep ' delete ' "${STUB_LOG}")"
case "${d}" in *"-l hugmesh.net/local-domains=true"*) ok "selected by the label" ;; *) bad "no label selector: ${d}" ;; esac
case "${d}" in *hugmesh-look-door*|*hugmesh-fe-gateway*) bad "named an object: ${d}" ;; *) ok "names no object" ;; esac

echo "== 7. unknown verb"
reset; rc="$(run bogus)"
[ "${rc}" = 2 ] && ok "rc 2" || bad "rc ${rc}, want 2"
grep -q 'usage:' "${WORK}/out.txt" && ok "prints usage" || bad "no usage"

echo
echo "${P} passed, ${F} failed"
[ "${F}" -eq 0 ] || exit 1
exit 0
