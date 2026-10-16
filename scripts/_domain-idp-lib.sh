#!/usr/bin/env bash
# _domain-idp-lib.sh — SOURCED helper: the per-domain identity-provider choice
# (issue #47, Domain.idp) for the image CLI. ONE implementation, sourced by every
# stage4 builder (build-*-stage4.sh), so the ten parsers cannot drift apart.
#
#   --domain-idp <domain>=own|superdomain      (repeatable)
#
# The Studio already models this choice as Domain.idp (core/config.py,
# DOMAIN_IDP_CHOICES = superdomain|own, default superdomain) and writes it into the
# mesh manifest's domains[] with the default OMITTED, so a manifest with no `own`
# domain keeps its pre-#47 bytes. A stage4 builder does not write that manifest (the
# Studio session does), so the image-side record is a baked file with the same field
# name, the same two values and the same omit-the-default rule:
#
#   /etc/hugmesh/domain-idp      one `<domain>=own` line per own-Casdoor domain
#
# The file exists ONLY when at least one domain is `own`. `superdomain` is accepted
# (it is the explicit spelling of the default) and records nothing, so an image built
# with no flag, or with only `=superdomain` flags, is byte-identical to one built
# before this flag existed. Nothing on the image reads the file yet: the build-time
# writer of the casdoor-domains ApplicationSet elements is still a follow-up
# (docs/DOMAIN-IDP.md, "Lane 1").
#
# CONTRACT FOR CALLERS (all of it lives in the builder):
#   * define err() — this file calls it and then `exit 1`, like the builders' own
#     _validate_* helpers do;
#   * call domain_idp_add "${2:-}" from the argument loop;
#   * after the loop, once CLUSTER_DOMAIN and (where the builder has it) DOMAINS are
#     final, call domain_idp_check "${CLUSTER_DOMAIN}" "${DOMAINS:-}";
#   * print domain_idp_plan_line inside the --print-plan block;
#   * call domain_idp_bake "${SYSROOT}/etc/hugmesh" where the sysroot's /etc/hugmesh
#     is being written.
#
# Nothing here forks a subshell that could swallow an `exit`, and nothing uses
# `local a=$1 b=$a` (bash 5.3 localises every name before assigning it).

# The closed vocabulary. tests/scripts/test-domain-idp-flag.sh pins this against
# DOMAIN_IDP_CHOICES in studio/hugmesh_studio/core/config.py.
DOMAIN_IDP_SUPERDOMAIN="superdomain"
DOMAIN_IDP_OWN="own"

# Newline-separated "<domain>=<idp>" records, in the order given. A string rather
# than an array: an empty array is "unbound" under `set -u` on older bash.
DOMAIN_IDP_SPECS=""

# domain_idp_add VALUE — parse and record one --domain-idp argument.
domain_idp_add() {
    local spec name idp
    spec="${1:-}"
    if [ -z "${spec}" ]; then
        err "--domain-idp needs a value: <domain>=own|superdomain"; exit 1
    fi
    case "${spec}" in
        *=*) ;;
        *) err "--domain-idp '${spec}' has no '=': expected <domain>=own|superdomain"; exit 1 ;;
    esac
    name="${spec%%=*}"
    idp="${spec#*=}"
    # Lowercase RFC-1123 dotted name — the same shape every builder demands of
    # --domains elements, because the name is later written into root-read files.
    if ! [[ "${name}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$ ]]; then
        err "--domain-idp domain '${name}' is not a valid DNS name (allowed: lowercase RFC-1123 dotted name)"; exit 1
    fi
    case "${idp}" in
        "${DOMAIN_IDP_SUPERDOMAIN}"|"${DOMAIN_IDP_OWN}") ;;
        *) err "--domain-idp '${spec}': idp must be ${DOMAIN_IDP_OWN} or ${DOMAIN_IDP_SUPERDOMAIN}, got '${idp}'"; exit 1 ;;
    esac
    case $'\n'"${DOMAIN_IDP_SPECS}" in
        *$'\n'"${name}="*)
            err "--domain-idp names '${name}' twice (give each domain one choice)"; exit 1 ;;
    esac
    DOMAIN_IDP_SPECS="${DOMAIN_IDP_SPECS}${DOMAIN_IDP_SPECS:+$'\n'}${name}=${idp}"
}

# domain_idp_check CLUSTER_DOMAIN DOMAINS — cross-checks, run once both are final.
#   * the mesh's OWN domain (CLUSTER_DOMAIN) always uses the superdomain Casdoor, as
#     in the Studio (local_mesh_bootstrap rejects it, local_mesh_domains forces it);
#   * when the builder was given a --domains list (x86 client images), every
#     --domain-idp name must be one of its elements. Builders with no such list
#     (the nine ARM/Jetson builders, and any x86 NODE role) have nothing to check
#     the name against and accept any valid DNS name.
domain_idp_check() {
    local own listed rec name idp d found
    own="${1:-}"
    listed="${2:-}"
    [ -n "${DOMAIN_IDP_SPECS}" ] || return 0
    while IFS= read -r rec; do
        [ -n "${rec}" ] || continue
        name="${rec%%=*}"
        idp="${rec#*=}"
        if [ "${idp}" = "${DOMAIN_IDP_OWN}" ] && [ -n "${own}" ] && [ "${name}" = "${own}" ]; then
            err "--domain-idp ${name}=own: '${name}' is this mesh's own domain (--cluster-domain) and always uses the superdomain Casdoor"; exit 1
        fi
        if [ -n "${listed}" ]; then
            found=false
            for d in ${listed//,/ }; do
                if [ "${d}" = "${name}" ]; then found=true; fi
            done
            if ! ${found}; then
                err "--domain-idp names '${name}', which is not in --domains (${listed})"; exit 1
            fi
        fi
    done <<< "${DOMAIN_IDP_SPECS}"
}

# domain_idp_own_names — the own-Casdoor domains, one per line, in the order given.
domain_idp_own_names() {
    local rec
    [ -n "${DOMAIN_IDP_SPECS}" ] || return 0
    while IFS= read -r rec; do
        if [ "${rec#*=}" = "${DOMAIN_IDP_OWN}" ]; then printf '%s\n' "${rec%%=*}"; fi
    done <<< "${DOMAIN_IDP_SPECS}"
}

# domain_idp_plan_line — the --print-plan line. Prints NOTHING when no domain is
# `own`, so every plan without the flag keeps its bytes.
domain_idp_plan_line() {
    local names
    names="$(domain_idp_own_names | paste -sd, -)"
    if [ -n "${names}" ]; then printf 'PLAN_DOMAIN_IDP=%s\n' "${names}"; fi
    return 0
}

# domain_idp_bake DIR — write DIR/domain-idp (only the own domains), or make sure no
# such file is there. DIR is the sysroot's /etc/hugmesh, which exists by now.
domain_idp_bake() {
    local dir names
    dir="${1:?domain_idp_bake needs the sysroot /etc/hugmesh directory}"
    names="$(domain_idp_own_names)"
    if [ -z "${names}" ]; then
        rm -f "${dir}/domain-idp"
        return 0
    fi
    mkdir -p "${dir}"
    printf '%s\n' "${names}" | sed "s/\$/=${DOMAIN_IDP_OWN}/" > "${dir}/domain-idp"
    chmod 0644 "${dir}/domain-idp"
    if declare -F info >/dev/null 2>&1; then
        info "Baked per-domain IdP choice -> /etc/hugmesh/domain-idp ($(printf '%s' "${names}" | paste -sd, -) = ${DOMAIN_IDP_OWN})"
    fi
    return 0
}
