#!/usr/bin/env bash
# _prod-gate-lib.sh — the ONE implementation of the ENV=prod clean-up of a baked
# cluster GitOps tree, sourced by every stage4 builder that bakes that tree
# (build-x86-host-stage4.sh, build-rpi5-stage4.sh, and the Orange Pi node builders,
# which run the Pi builder's gate_env_apps through scripts/_node-role-lib.sh).
#
# WHY THIS FILE EXISTS. Until this change the prune of the ENV=test e2e harness and
# the static prod-hygiene self-check lived only in build-x86-host-stage4.sh
# (rewrite_prod_image_tags). The Pi builder's gate_env_apps pruned only the LAN
# wildcard-DNS app for ENV=prod, so an ENV=prod Pi or Orange Pi image shipped
# apps/99-test-runner.yaml (labelled hugmesh.net/tier: test, automated prune +
# selfHeal), apps/00-app-of-apps-waved.yaml and manifests/test-runner/, and nothing
# failed the build. bootstrap.sh applies every baked apps/*.yaml, so the test
# harness Application was created on a production cluster; the only thing in its
# way was the Kyverno tier:test rule, which is itself applied in the same loop.
#
# NO `set -e` here: the caller owns its shell options. One `local` per assignment
# (bash 5.3 localises a whole `local a=$1 b=$a` list before assigning).

# prod_gate_validate_release_tag <tag>
#   rc=0 when <tag> is a pinned image tag ENV=prod may pin first-party :dev images
#   to: non-empty, only letters, digits, '.', '_' and '-', and not one of the
#   floating names dev / main / latest. rc=1 (with a message) otherwise.
#   Every builder calls it right after argument parsing when ENV=prod, so a bad
#   --release-tag fails in seconds, not after the emerge phase; prod_gate_cluster_tree
#   calls it again at gate time (fail closed if a caller skipped the early check).
#   ACCEPTED-SET NOTE: before this lib, build-x86-host-stage4.sh accepted ANY
#   --release-tag unchecked (it was pasted into a sed replacement). It now refuses
#   '+', '/', spaces and every other character outside [A-Za-z0-9._-] for ENV=prod.
#   None of those is valid in an OCI image tag, so no working prod build is lost.
#   ENV=test builds never use the tag and are not checked.
prod_gate_validate_release_tag() {
    local tag="${1-}"
    case "${tag}" in
        ''|*[!A-Za-z0-9._-]*|dev|main|latest)
            _prod_gate_err "release tag '${tag}' is not a pinned tag (letters, digits, . _ - only; not dev/main/latest)"
            return 1 ;;
    esac
    return 0
}

# prod_gate_cluster_tree <cluster-tree> <release-tag> <hygiene-script>
#   For an ENV=prod image, over the BAKED tree only (never the repo):
#   1. pin first-party floating `:dev` image tags to <release-tag>;
#   2. prune the ENV=test e2e harness wave (apps/99-test-runner.yaml,
#      apps/00-app-of-apps-waved.yaml, manifests/test-runner/);
#   3. run <hygiene-script> --static over the tree.
#   Returns 0 when the tree is clean, 1 when the self-check fails or cannot run
#   (FAIL CLOSED: a prod image whose hygiene was never checked is not clean).
#   A missing tree is a no-op (0), the same as gate_env_apps.
#   Uses info/err when the caller defines them, plain stderr otherwise.
prod_gate_cluster_tree() {
    local tree="${1:?prod_gate_cluster_tree: cluster tree required}"
    local tag="${2:?prod_gate_cluster_tree: release tag required}"
    local hygiene="${3:?prod_gate_cluster_tree: hygiene script required}"
    [ -d "${tree}" ] || return 0
    prod_gate_validate_release_tag "${tag}" || return 1

    local n=0
    local f
    while IFS= read -r -d '' f; do
        # Any first-party image (its repo path contains 'hugmesh') tagged :dev ->
        # :<tag>. The repo-path class EXCLUDES ':' so the match stops before the
        # tag (first-party image paths carry no registry port).
        if grep -qE 'image:[[:space:]]*[^[:space:]:]*hugmesh[^[:space:]:]*:dev([[:space:]]|$)' "${f}" 2>/dev/null; then
            sed -i -E "s#(image:[[:space:]]*[^[:space:]:]*hugmesh[^[:space:]:]*):dev([[:space:]]|\$)#\\1:${tag}\\2#g" "${f}" || return 1
            n=$((n + 1))
        fi
    done < <(find "${tree}" -type f \( -name '*.yaml' -o -name '*.yml' \) -print0 2>/dev/null)
    _prod_gate_info "ENV=prod: pinned first-party :dev image tags -> :${tag} in ${n} file(s)"

    rm -f "${tree}/apps/99-test-runner.yaml" "${tree}/apps/00-app-of-apps-waved.yaml" || return 1
    rm -rf "${tree}/manifests/test-runner" || return 1
    _prod_gate_info "ENV=prod: pruned the test-runner wave (apps/99-test-runner.yaml, apps/00-app-of-apps-waved.yaml, manifests/test-runner) from the baked tree"

    if [ ! -f "${hygiene}" ]; then
        _prod_gate_err "ENV=prod: prod-hygiene gate script not found at ${hygiene}; refusing to build a prod image whose tree was never checked"
        return 1
    fi
    if bash "${hygiene}" --static "${tree}"; then
        _prod_gate_info "ENV=prod: prod-hygiene static gate PASSED on the baked tree"
        return 0
    fi
    _prod_gate_err "ENV=prod: prod-hygiene static gate FAILED on the baked tree (a dev-only server, test harness or floating :dev tag survived); refusing to build a prod image"
    return 1
}

_prod_gate_info() {
    if declare -F info >/dev/null; then info "$*"; else printf '%s\n' "$*" >&2; fi
}

_prod_gate_err() {
    if declare -F err >/dev/null; then err "$*"; else printf 'ERROR: %s\n' "$*" >&2; fi
}
