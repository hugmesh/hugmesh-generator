#!/usr/bin/env bash
# kind-local-domains.sh — give the kind lane the per-domain look and the list of other
# domains the Docker lane already has (operator ask 2026-11-18: "no easy way to sign in to
# different domains" on the local lanes).
#
# WHAT IT DOES. The Docker lane's front door (tests/stack/tls-front/default.conf) answers
# a stylesheet by Host from tests/stack/.looks/by-host/<Host>/ and serves the list of the
# mesh's domains as /hug-domains.json. The kind lane's front door is ingress-nginx in
# front of the fe-gateway and had neither: one look for the whole mesh and no host but
# hugmesh.net. This script turns the SAME .looks/ folder into cluster objects
# (studio core/look_serving.py `kind-bundle`):
#
#   * a small nginx "look door" Deployment + Service in ns hugmesh-frontend that does
#     what the Docker door does, with the fe-gateway as its upstream;
#   * a ConfigMap holding the look files and domains.json;
#   * an Ingress sending every path of each domain host to the look door, and one
#     sending only /hug-domains.json of the mesh's own hosts (hugmesh.net, *.hugmesh.net)
#     there, so the sign-in page on the mesh's own name lists the others too.
#
# With no domain recorded it seeds the two samples (acme.localhost, example.localhost:
# `.localhost` names resolve to this machine in every browser, no /etc/hosts edit, no
# root), exactly as `make stack-up` does; a Studio-recorded .looks/ is used as it is.
#
#   bash scripts/kind-local-domains.sh up       apply (idempotent); fails unless the door answers
#   bash scripts/kind-local-domains.sh down     delete exactly the objects it labelled
#   bash scripts/kind-local-domains.sh status   read-only: what is there, does it answer
#
# Environment: KIND_CONTEXT (default kind-hugmesh-local), KIND_HTTP_PORT / KIND_HTTPS_PORT
# (default 8080 / 8443, the host ports kind-local.yaml maps to ingress-nginx's :80 / :443),
# KIND_SAMPLE_DOMAINS=0 (do not seed
# samples; use only what is recorded). It never creates or deletes the cluster, never runs
# sudo, and touches only objects carrying the label hugmesh.net/local-domains=true.
#
# Guarded offline by studio/tests/test_look_kind_bundle.py (the objects) and
# tests/scripts/test-kind-local-domains.sh (this script's refusals).
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
CTX="${KIND_CONTEXT:-kind-hugmesh-local}"
NS="${KIND_DOMAINS_NAMESPACE:-hugmesh-frontend}"
PORT="${KIND_HTTP_PORT:-8080}"
SPORT="${KIND_HTTPS_PORT:-8443}"
LABEL="hugmesh.net/local-domains=true"
LOOKS="${REPO}/tests/stack/.looks"
PY="${PYTHON:-python3}"
BUNDLE=""

log()  { echo "==> $*"; }
fail() { echo "FAIL: $1" >&2; exit "${2:-1}"; }
K()    { kubectl --context "${CTX}" "$@"; }
look() { (cd "${REPO}/studio" && "${PY}" -m hugmesh_studio.core.look_serving "$@" --generator-dir "${REPO}"); }

preflight() {
  command -v kubectl >/dev/null 2>&1 || fail "kubectl is not installed" 2
  command -v "${PY}" >/dev/null 2>&1 || fail "${PY} is not installed" 2
  command -v curl >/dev/null 2>&1    || fail "curl is not installed" 2
  kubectl config get-contexts -o name 2>/dev/null | grep -x "${CTX}" >/dev/null \
    || fail "no kube context '${CTX}': run \`make kind-up\` first (or set KIND_CONTEXT)" 2
  K get ns "${NS}" >/dev/null 2>&1 \
    || fail "namespace ${NS} does not exist on ${CTX}: the mesh is not up yet; run \`make kind-up\`" 2
}

# The domain names the door serves, one per line, read from the SERVED file so what is
# probed is what is served. Empty when there is no domains.json.
domain_names() {
  [ -f "${LOOKS}/domains.json" ] || return 0
  "${PY}" -c 'import json,sys
for r in json.load(open(sys.argv[1])).get("domains", []):
    n = str(r.get("name", "")).strip()
    if n: print(n)' "${LOOKS}/domains.json"
}

# Does the door answer for every domain, on BOTH host ports? Through the REAL ingress, with
# the Host header a browser would send (the https leg skips certificate checks: the
# cluster's ingress presents its own self-signed certificate). ingress-nginx reloads a few
# seconds after an Ingress changes, so a miss is retried (PROBE_SECONDS, default 60) before
# it counts. Prints one line per URL; non-zero when any never answered. The https URL is
# the one to SIGN IN on: the session cookie is Secure, so a sign-in over plain http is
# accepted but a non-browser client never sends the cookie back.
probe_one() { # <scheme> <host> <port> -> 0 when /hug-domains.json answers 200
  local scheme="$1" host="$2" port="$3" code="" waited=0
  while :; do
    code="$(curl -sk -m 15 -o /dev/null -w '%{http_code}' \
            --resolve "${host}:${port}:127.0.0.1" "${scheme}://${host}:${port}/hug-domains.json")"
    [ "${code}" = "200" ] && { echo "    ok    ${scheme}://${host}:${port}/login/"; return 0; }
    [ "${waited}" -ge "${PROBE_SECONDS:-60}" ] && break
    sleep 3; waited=$((waited + 3))
  done
  echo "    FAIL  ${host}: ${scheme} /hug-domains.json answered '${code}' via 127.0.0.1:${port} after ${waited}s" >&2
  return 1
}
probe() {
  local bad=0 host
  for host in $(domain_names); do
    probe_one https "${host}" "${SPORT}" || bad=1
    probe_one http  "${host}" "${PORT}"  || bad=1
  done
  return ${bad}
}

cmd_up() {
  preflight
  if [ "${KIND_SAMPLE_DOMAINS:-1}" = "0" ]; then
    look seed-samples --off >/dev/null 2>&1 || true
  else
    log "Seeding the sample domains when none are recorded"
    look seed-samples >/dev/null || fail "could not seed the sample domains"
  fi
  BUNDLE="$(mktemp "${TMPDIR:-/tmp}/kind-local-domains.XXXXXX")" || fail "no temp file"
  trap 'rm -f "${BUNDLE}"' EXIT
  log "Building the look-door objects from ${LOOKS#"${REPO}/"}"
  look kind-bundle > "${BUNDLE}" || fail "nothing to serve (see the message above)"
  log "Applying to ${CTX} (ns ${NS})"
  K apply -f "${BUNDLE}" || fail "kubectl apply failed"
  # One Ingress carries every domain host and one ConfigMap every file, so applying
  # REPLACES them: a domain that is gone is gone from both, nothing to prune.
  K -n "${NS}" rollout status deploy/hugmesh-look-door --timeout=180s \
    || fail "the look door did not become ready (kubectl -n ${NS} describe deploy/hugmesh-look-door)"
  log "Probing the door through ingress-nginx on 127.0.0.1:${SPORT} (https) and :${PORT} (http)"
  probe || fail "the door does not answer for every domain (are ingress-nginx's :443 / :80 mapped to ${SPORT} / ${PORT}?)"
  echo "    Sign in on the https URLs (accept the cluster's self-signed certificate); the mesh's"
  echo "    own name lists the others as \"another domain\"."
}

cmd_down() {
  preflight
  log "Deleting the objects labelled ${LABEL} in ns ${NS}"
  K -n "${NS}" delete ingress,service,deployment,configmap -l "${LABEL}" --ignore-not-found \
    || fail "kubectl delete failed"
}

cmd_status() {
  preflight
  K -n "${NS}" get deploy,svc,ingress,configmap -l "${LABEL}" || fail "kubectl get failed"
  [ -n "$(domain_names)" ] || { echo "    no domains.json in ${LOOKS#"${REPO}/"}: nothing is being served"; return 1; }
  probe
}

case "${1:-}" in
  up)     cmd_up ;;
  down)   cmd_down ;;
  status) cmd_status ;;
  *)      echo "usage: $0 up|down|status" >&2; exit 2 ;;
esac
