#!/usr/bin/env bash
# _domain-golive-lib.sh — SOURCED helper: "Go live when ready" (hugmesh-generator#1201)
# for the image CLI. ONE implementation, sourced by the stage4 builders that bake the
# go-live set (build-rpi5-stage4.sh, build-x86-host-stage4.sh), so the parsers cannot
# drift apart. The same shape as scripts/_domain-idp-lib.sh.
#
#   --domain-go-live <domain>=<provider>      (repeatable)
#
# Records that <domain> goes public on its own once the node has booted and the mesh's
# containers are healthy, through <provider> (a hugmesh-go-live provider id). The
# image-side record is:
#
#   /etc/hugmesh/domain-go-live      one `<domain>=<provider>` line per domain
#
# read by /usr/sbin/hugmesh-go-live-at-ready. The file exists ONLY when the flag was
# given, so an image built without it is byte-identical to one built before it existed.
#
# OPERATOR DECISION (2026-11-25, #1201): choosing this at build time IS consent for the
# unattended go-live of that domain.
#
# A provider SECRET (API key / tunnel token) is NEVER a builder argument and never
# reaches an image: the Studio writes it onto the edge role's KEYS stick as
# go-live/<domain>.token (provision_go_live_tokens installs it at first boot).
#
# CONTRACT FOR CALLERS (all of it lives in the builder):
#   * define err() — this file calls it and then `exit 1`;
#   * call domain_golive_add "${2:-}" from the argument loop;
#   * after the loop, once ROLE_CLIENT is known, call
#     domain_golive_check "${ROLE}" "${ROLE_CLIENT}";
#   * print domain_golive_plan_line inside the --print-plan block;
#   * call domain_golive_bake "${SYSROOT}/etc/hugmesh" where /etc/hugmesh is written.
#
# Nothing here forks a subshell that could swallow an `exit`, and nothing uses
# `local a=$1 b=$a` (bash 5.3 localises every name before assigning it).

# The closed vocabulary: the go-live provider registry's ids
# (specs/usr/lib/hugmesh/go-live-providers.sh GO_LIVE_PROVIDER_IDS) WITHOUT tor-onion,
# which the driver refuses to commit (an onion needs no public flip).
# tests/scripts/test-domain-golive-flag.sh pins this list against the registry and
# against GO_LIVE_AT_READY_PROVIDERS in studio/hugmesh_studio/core/config.py.
DOMAIN_GOLIVE_PROVIDERS="cloudflare-tunnel byo-domain duckdns tailscale-funnel router-portforward"

# Newline-separated "<domain>=<provider>" records, in the order given.
DOMAIN_GOLIVE_SPECS=""

# domain_golive_add VALUE — parse and record one --domain-go-live argument.
domain_golive_add() {
    local spec name prov p known
    spec="${1:-}"
    if [ -z "${spec}" ]; then
        err "--domain-go-live needs a value: <domain>=<provider>"; exit 1
    fi
    case "${spec}" in
        *=*) ;;
        *) err "--domain-go-live '${spec}' has no '=': expected <domain>=<provider>"; exit 1 ;;
    esac
    name="${spec%%=*}"
    prov="${spec#*=}"
    # A PUBLIC name: lowercase RFC-1123, at least two labels (it is written into a
    # root-read file and handed to the driver's --domain).
    if ! [[ "${name}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]]; then
        err "--domain-go-live domain '${name}' is not a public DNS name (lowercase RFC-1123, at least two labels)"; exit 1
    fi
    if [ "${prov}" = "tor-onion" ]; then
        err "--domain-go-live ${name}=tor-onion: a Tor address needs no public flip; use the domain's Tor front door instead"; exit 1
    fi
    known=false
    for p in ${DOMAIN_GOLIVE_PROVIDERS}; do
        if [ "${p}" = "${prov}" ]; then known=true; fi
    done
    if ! ${known}; then
        err "--domain-go-live '${spec}': provider must be one of: ${DOMAIN_GOLIVE_PROVIDERS}"; exit 1
    fi
    case $'\n'"${DOMAIN_GOLIVE_SPECS}" in
        *$'\n'"${name}="*)
            err "--domain-go-live names '${name}' twice (give each domain one provider)"; exit 1 ;;
    esac
    DOMAIN_GOLIVE_SPECS="${DOMAIN_GOLIVE_SPECS}${DOMAIN_GOLIVE_SPECS:+$'\n'}${name}=${prov}"
}

# domain_golive_check ROLE ROLE_CLIENT — a client/desktop image (the builder's own
# ROLE_CLIENT=true) has no cluster to take public. Any node role is accepted: the agent
# acts only on the node labelled hugmesh.net/backend=true and records `not-edge`
# everywhere else, so baking the same file into every node of a fleet is harmless.
domain_golive_check() {
    local role is_client
    role="${1:-}"
    is_client="${2:-false}"
    [ -n "${DOMAIN_GOLIVE_SPECS}" ] || return 0
    if [ "${is_client}" = "true" ]; then
        err "--domain-go-live is for mesh node images; role '${role}' is a client image with no cluster to take public"; exit 1
    fi
    return 0
}

# domain_golive_plan_line — PLAN_DOMAIN_GO_LIVE=<domain>:<provider>,... or nothing.
domain_golive_plan_line() {
    if [ -n "${DOMAIN_GOLIVE_SPECS}" ]; then
        printf 'PLAN_DOMAIN_GO_LIVE=%s\n' "$(printf '%s\n' "${DOMAIN_GOLIVE_SPECS}" | sed 's/=/:/' | paste -sd, -)"
    fi
    return 0
}

# domain_golive_bake DIR — write DIR/domain-go-live, or make sure there is none.
domain_golive_bake() {
    local dir
    dir="${1:?domain_golive_bake needs the sysroot /etc/hugmesh directory}"
    if [ -z "${DOMAIN_GOLIVE_SPECS}" ]; then
        rm -f "${dir}/domain-go-live"
        return 0
    fi
    mkdir -p "${dir}"
    {
        echo "# Go live when ready (hugmesh-generator#1201), baked by the builder from"
        echo "# --domain-go-live. One <domain>=<provider> per line; read by"
        echo "# /usr/sbin/hugmesh-go-live-at-ready. Status: hugmesh-go-live-at-ready --status"
        printf '%s\n' "${DOMAIN_GOLIVE_SPECS}"
    } > "${dir}/domain-go-live"
    chmod 0644 "${dir}/domain-go-live"
    if declare -F info >/dev/null 2>&1; then
        info "Baked go-live-when-ready -> /etc/hugmesh/domain-go-live ($(printf '%s\n' "${DOMAIN_GOLIVE_SPECS}" | paste -sd, -))"
    fi
    return 0
}
