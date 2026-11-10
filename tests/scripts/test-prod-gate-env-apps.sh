#!/usr/bin/env bash
# test-prod-gate-env-apps.sh — an ENV=prod image never ships the ENV=test e2e
# harness, on EVERY builder that bakes the cluster GitOps tree.
#
# The defect this pins: the prune of apps/99-test-runner.yaml,
# apps/00-app-of-apps-waved.yaml and manifests/test-runner/, the :dev tag pin and
# the static prod-hygiene self-check existed only in build-x86-host-stage4.sh. The
# Pi builder's gate_env_apps (also run by the Orange Pi node builders through
# scripts/_node-role-lib.sh) pruned only 09-lan-dns.yaml for ENV=prod, so ENV=prod
# Pi images shipped the tier:test test-runner Application, which bootstrap.sh then
# applies like every other baked app.
#
# Runs the REAL functions (extracted from the builders / loaded through the node
# role loader) over a scratch copy of specs/cluster. No root, no network.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT
P=0
N=0
ok()  { printf '  PASS %s\n' "$*"; P=$((P + 1)); }
bad() { printf '  FAIL %s\n' "$*"; N=$((N + 1)); }

extract_fn() { # $1 builder, $2 function
    sed -n "/^$2() {/,/^}/p" "$1"
}

new_sysroot() {
    local s
    s="$(mktemp -d "${WORK}/sys.XXXXXX")"
    mkdir -p "${s}/var/lib/hugmesh"
    cp -r "${REPO}/specs/cluster" "${s}/var/lib/hugmesh/cluster"
    printf '%s\n' "${s}"
}

# run_gate <builder> <sysroot> <ENV> [hygiene-script-dir] -> rc of gate_env_apps
run_gate() {
    local b="$1"
    local s="$2"
    local env="$3"
    local sd="${4:-${REPO}}"
    ( info() { :; }; warn() { :; }; err() { printf 'ERR %s\n' "$*" >&2; }
      SYSROOT="${s}"; ENV="${env}"; RELEASE_STATE=public; CLUSTER_DOMAIN=hugmesh.net
      SCRIPT_DIR="${sd}"; RELEASE_TAG=19700101
      # shellcheck source=scripts/_prod-gate-lib.sh
      source "${REPO}/scripts/_prod-gate-lib.sh"
      eval "$(extract_fn "${REPO}/${b}" rewrite_prod_image_tags)"
      eval "$(extract_fn "${REPO}/${b}" gate_env_apps)"
      gate_env_apps ) >"${WORK}/gate.log" 2>&1
}

# judge_prod <sysroot> <label>: the baked tree carries no test harness.
judge_prod() {
    local t="$1/var/lib/hugmesh/cluster"
    local label="$2"
    local left=""
    # Not vacuous: a bake that never produced the tree must not pass as "pruned".
    if ! ls "${t}"/apps/*.yaml >/dev/null 2>&1; then
        bad "${label}: no baked apps/*.yaml at all (the bake did not run)"
        return
    fi
    [ -e "${t}/apps/99-test-runner.yaml" ] && left="${left} apps/99-test-runner.yaml"
    [ -e "${t}/apps/00-app-of-apps-waved.yaml" ] && left="${left} apps/00-app-of-apps-waved.yaml"
    [ -d "${t}/manifests/test-runner" ] && left="${left} manifests/test-runner/"
    if [ -z "${left}" ]; then ok "${label}: the test-runner wave is pruned"
    else bad "${label}: the ENV=prod tree still ships${left}"; fi
    # Every Application bootstrap.sh would apply: none may be tier:test.
    if grep -lE 'hugmesh\.net/tier:[[:space:]]*test' "${t}"/apps/*.yaml >/dev/null 2>&1; then
        bad "${label}: an apps/*.yaml labelled hugmesh.net/tier: test survives (bootstrap.sh applies every one)"
    else ok "${label}: no tier:test Application in apps/"; fi
    if bash "${REPO}/scripts/validate-prod-hygiene.sh" --static "${t}" >/dev/null 2>&1; then
        ok "${label}: the static prod-hygiene check passes on the baked tree"
    else bad "${label}: the static prod-hygiene check FAILS on the baked tree"; fi
}

echo "== ENV=prod, each builder that defines gate_env_apps =="
for b in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
    s="$(new_sysroot)"
    if run_gate "${b}" "${s}" prod; then ok "${b}: gate_env_apps returns 0 for ENV=prod"
    else bad "${b}: gate_env_apps failed for ENV=prod: $(tail -3 "${WORK}/gate.log" | tr '\n' ' ')"; fi
    judge_prod "${s}" "${b}"
done

echo "== ENV=test keeps the harness (no regression) =="
for b in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
    s="$(new_sysroot)"
    run_gate "${b}" "${s}" test || true
    if [ -e "${s}/var/lib/hugmesh/cluster/apps/99-test-runner.yaml" ] \
       && [ -d "${s}/var/lib/hugmesh/cluster/manifests/test-runner" ]; then
        ok "${b}: ENV=test keeps apps/99-test-runner.yaml and manifests/test-runner"
    else bad "${b}: ENV=test lost the test-runner wave"; fi
done

echo "== fail closed =="
for b in build-rpi5-stage4.sh build-x86-host-stage4.sh; do
    # A tier:test Application that is not the known harness must stop the build.
    s="$(new_sysroot)"
    sed 's/^  name: .*/  name: planted-test-app/' \
        "${REPO}/specs/cluster/apps/99-test-runner.yaml" \
        > "${s}/var/lib/hugmesh/cluster/apps/98-planted.yaml"
    if run_gate "${b}" "${s}" prod; then bad "${b}: a planted tier:test Application did not fail the ENV=prod gate"
    else ok "${b}: a planted tier:test Application fails the ENV=prod gate"; fi
    # The self-check cannot be skipped by a missing script.
    s="$(new_sysroot)"
    mkdir -p "${WORK}/empty-scriptdir"
    if run_gate "${b}" "${s}" prod "${WORK}/empty-scriptdir"; then
        bad "${b}: ENV=prod passed with the prod-hygiene script missing (the check was skipped)"
    else ok "${b}: ENV=prod refuses when the prod-hygiene script is missing"; fi
done

echo "== the release tag must be a pinned tag =="
for tag in main dev latest 'x;rm -rf /' ''; do
    s="$(new_sysroot)"
    if ( source "${REPO}/scripts/_prod-gate-lib.sh"
         prod_gate_cluster_tree "${s}/var/lib/hugmesh/cluster" "${tag}" "${REPO}/scripts/validate-prod-hygiene.sh" ) >/dev/null 2>&1; then
        bad "release tag '${tag}' was accepted"
    else ok "release tag '${tag}' is refused"; fi
done

echo "== Orange Pi node path (node_role_bake_cluster_tree, ENV=prod) =="
s="$(new_sysroot)"
rm -rf "${s}/var/lib/hugmesh"
if out="$(SCRIPT_DIR="${REPO}" SYSROOT="${s}" bash -c '
        set -euo pipefail
        SHARED_SPECS="${SCRIPT_DIR}/specs"
        ENV=prod RELEASE_STATE=public BRAND=hugmesh BRAND_TITLE="HugMesh Systems" ORG=hugmesh CLUSTER_DOMAIN=hugmesh.net
        ROLE=frontend ROLE_CLIENT=false NODE_ROLE=true
        banner() { :; }; info() { :; }; warn() { :; }; err() { echo "ERR $1" >&2; }
        . "${SCRIPT_DIR}/scripts/_optional-services-lib.sh"
        # Loaded the way the Orange Pi builders load it (the per-builder check
        # below asserts they do); optional here so this leg judges the PRUNE.
        if [ -f "${SCRIPT_DIR}/scripts/_prod-gate-lib.sh" ]; then . "${SCRIPT_DIR}/scripts/_prod-gate-lib.sh"; fi
        . "${SCRIPT_DIR}/scripts/_node-role-lib.sh"
        node_role_load_pi_settings
        node_role_load_pi_functions
        OPTIONAL_SERVICES="${OPTIONAL_SERVICES//,/ }"
        node_role_bake_cluster_tree "${SYSROOT}" "${SHARED_SPECS}"
    ' 2>&1)"; then
    ok "node_role_bake_cluster_tree runs for ENV=prod"
else bad "node_role_bake_cluster_tree failed for ENV=prod: $(printf '%s' "${out}" | tail -3 | tr '\n' ' ')"; fi
judge_prod "${s}" "Orange Pi node bake"

echo "== every builder that runs gate_env_apps loads the shared prod gate =="
# gate_env_apps calls prod_gate_cluster_tree, so a builder that runs it (directly,
# or through the node role loader) without sourcing the lib dies with
# 'command not found' on the first ENV=prod build.
for b in "${REPO}"/build-*-stage4.sh; do
    uses=0
    grep -qE '^gate_env_apps\(\) \{' "${b}" && uses=1
    # (no `grep -q` after a pipe: under pipefail its early exit SIGPIPEs the
    # first grep on a large file and a FOUND match reads as a miss)
    grep -vE '^[[:space:]]*#' "${b}" | grep -E '_node-role-lib\.sh' >/dev/null && uses=1
    [ "${uses}" = 1 ] || continue
    if grep -vE '^[[:space:]]*#' "${b}" | grep -E '^[[:space:]]*(source|\.)[[:space:]]+"\$\{SCRIPT_DIR\}/scripts/_prod-gate-lib\.sh"' >/dev/null; then
        ok "$(basename "${b}") sources scripts/_prod-gate-lib.sh"
    else bad "$(basename "${b}") runs gate_env_apps but never sources scripts/_prod-gate-lib.sh"; fi
done

echo "== test-prod-gate-env-apps: ${P} passed, ${N} failed =="
[ "${N}" -eq 0 ]
