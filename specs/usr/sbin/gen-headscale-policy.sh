#!/bin/bash
# gen-headscale-policy.sh — Layer-A device-license-registry headscale policy
# renderer. Runs ONLY on the headscale CONTROL (pki) node — the one node that
# holds the headscale socket + binary + DB. It is the SECOND enforcement layer
# off the SAME signed export Layer-B (per-node sshd) consumes, so the tailnet
# control plane also obeys the auth predicate.
#
# FLOW (every step FAIL-CLOSED — on ANY fetch/verify/rollback failure KEEP the
# last-APPLIED policy.hujson; NEVER wipe to allow-all; if the node has NEVER had
# a verified export, keep the baked BOOTSTRAP policy):
#   1. source /usr/lib/hugmesh/registry-verify.sh (REUSE Layer-B's
#      verify_export / canonical_bytes / verify_sig — NO duplication, so a
#      canonicalisation drift can never split Layer-A from Layer-B).
#   2. read /etc/hugmesh/registry/node.env (BFF_EXPORT_URL / BFF_CLIENT_CERT /
#      BFF_CLIENT_KEY / BFF_CA / MESH_ID — the SAME file + transport Layer-B
#      uses) and the BAKED /etc/hugmesh/registry/registry-pub.ed25519.
#   3. fetch GET <BFF>/bff/admin/device-licenses/export?mesh=<MESH_ID> over the
#      SAME in-cluster mTLS SUPERADMIN identity.
#   4. verify_export against its OWN last-good cursor
#      (/var/lib/hugmesh/headscale-policy/last-good-generation — independent
#      of Layer-B's cursor so the two layers reconcile at different cadences).
#   5. render /etc/headscale/policy.hujson from policy.hujson.tmpl by walking
#      .body.operators[] with jq into the ssh[] edges + the dynamic dst tagOwners.
#   6. on a CONTENT CHANGE (hash differs) run `headscale policy set -f` (REQUIRED
#      because headscale runs policy mode:file — DB is not the source in file
#      mode) and force the server-assigned tags via hugmesh-headscale-forcetags.
#
# THE FOUR FIXES (vs main's forgeable policy):
#   [FIX-SERVERTAG]   dst tags (tag:dev_<fp>, tag:dom_<domain>, tag:mesh_<id>,
#                     tag:superadmin) are SERVER-FORCED at approval, listed
#                     control-owned in tagOwners; a node cannot self-advertise
#                     them, so the SSH destination is non-forgeable.
#   [FIX-DROPMESHRULE] the rendered acls[] DROPS the any-to-any
#                     tag:hugmesh->tag:hugmesh:* rule and KEEPS only the
#                     10.244/10.96 CIDR data-plane rule (k8s, not SSH).
#   [FIX-DENY22]      headscale ssh is default-deny; the generated ssh[] block
#                     emits EXACTLY the predicate-permitted edges, so :22 is
#                     default-deny.
#   [FIX-OIDC-USERS]  DEFERRED. Until per-tenant Casdoor->headscale OIDC users
#                     land, the SSH SOURCE side is the advisory tag:hugmesh
#                     (the reusable preauth key still gates JOIN). The
#                     load-bearing per-operator SOURCE authenticity + per-key %f
#                     pinning stay in Layer-B. Layer-A is ADVISORY on the source
#                     side, REAL on the destination side (server-forced dst tags
#                     + dropped any-to-any rule). See the PR body.
#
# VALIDATION STATUS: every shell path here is `bash -n`-clean and the render is
# smoke-tested off-node against a synthetic export (the PR body carries the
# rendered sample + a `jq`-parse proof). What CANNOT be checked here: that a
# LIVE headscale ACCEPTS the rendered hujson, that forged tag:dev_/tag:dom_
# advertisements are actually REJECTED by the server, and that :22 is truly
# default-deny on a booted control node — those need a live headscale + a
# running admin-bff /export (see the PR body VERIFIED-vs-NEEDS-HEADSCALE matrix).

set -uo pipefail

NODE_ENV="/etc/hugmesh/registry/node.env"
PUB_KEY="/etc/hugmesh/registry/registry-pub.ed25519"
VERIFY_LIB="/usr/lib/hugmesh/registry-verify.sh"

# Layer-A keeps its OWN cache + monotonic cursor, separate from Layer-B's
# /var/lib/hugmesh/device-registry, so the two layers can be reconciled at
# different cadences (both read the same export generation; a node where only
# one layer advanced is a transient, self-healing divergence).
CACHE_DIR="/var/lib/hugmesh/headscale-policy"
EXPORT_JSON="${CACHE_DIR}/export.json"
LAST_GOOD="${CACHE_DIR}/last-good-generation"

POLICY_OUT="/etc/headscale/policy.hujson"
POLICY_TMPL="/etc/headscale/policy.hujson.tmpl"
FORCETAGS="/usr/sbin/hugmesh-headscale-forcetags"

# Baked per-node privileged SSH local account (the Tailscale-SSH `users` value —
# the LOCAL unix account a session opens AS, NOT the Casdoor operator). Source of
# truth = node.env TS_SSH_USER (staged by provision_headscale_policy_sync from
# resolve_ssh_user); falls back to "admin" so a partially-provisioned control
# node still renders a usable policy rather than an empty users list.
LOG_TAG="hugmesh-policy-sync"

log()  { echo "[${LOG_TAG} $(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; command -v logger >/dev/null 2>&1 && logger -t "${LOG_TAG}" -- "$*" 2>/dev/null || true; }
warn() { log "WARNING: $*"; }
have() { command -v "$1" >/dev/null 2>&1; }

# Read a bare KEY=VALUE from node.env WITHOUT sourcing it (no code execution).
read_env() {
    local k="$1" line
    line="$(grep -E "^${k}=" "${NODE_ENV}" 2>/dev/null | head -1)" || return 1
    [ -n "${line}" ] || return 1
    printf '%s' "${line#*=}" | tr -d '"'"'"' '
}

# A headscale-safe membership tag for THIS mesh: tag:mesh_<sanitised MESH_ID>.
# headscale tag names allow [a-z0-9-]; lowercase + replace anything else with '-'.
sanitise_tag() {
    printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -e 's/-\{2,\}/-/g' -e 's/^-//' -e 's/-$//'
}

# ── Pre-flight (fail-closed = keep whatever policy is already applied) ─────────
# Wrapped in a function + run only when EXECUTED (not sourced) so the render path
# can be unit-tested off-node (a test sources this file then drives render_policy
# directly). On any unmet precondition this returns non-zero and the executed
# entrypoint exits 0 fail-closed (keeps the current policy).
_init() {
    [ -r "${VERIFY_LIB}" ] || { warn "verify lib missing (${VERIFY_LIB}) — keeping current policy"; return 1; }
    [ -r "${NODE_ENV}" ]   || { warn "node.env missing (${NODE_ENV}) — not wired for Layer-A? keeping current policy"; return 1; }
    [ -r "${PUB_KEY}" ]    || { warn "baked public key missing (${PUB_KEY}) — keeping current policy"; return 1; }
    [ -r "${POLICY_TMPL}" ] || { warn "render template missing (${POLICY_TMPL}) — keeping current policy"; return 1; }
    # shellcheck source=/dev/null
    . "${VERIFY_LIB}" 2>/dev/null || { warn "failed to source verify lib — keeping current policy"; return 1; }
    have jq      || { warn "jq absent — keeping current policy"; return 1; }
    have openssl || { warn "openssl absent — keeping current policy"; return 1; }

    mkdir -p "${CACHE_DIR}" 2>/dev/null || true
    chmod 0700 "${CACHE_DIR}" 2>/dev/null || true   # control-node-only; root reads it

    MESH_ID="$(read_env MESH_ID)"            || { warn "node.env missing MESH_ID — keeping current policy"; return 1; }
    [ -n "${MESH_ID}" ]                      || { warn "empty MESH_ID — keeping current policy"; return 1; }
    BFF_URL="$(read_env BFF_EXPORT_URL)"     || BFF_URL=""
    MTLS_CERT="$(read_env BFF_CLIENT_CERT)"  || MTLS_CERT=""
    MTLS_KEY="$(read_env BFF_CLIENT_KEY)"    || MTLS_KEY=""
    MTLS_CA="$(read_env BFF_CA)"             || MTLS_CA="/etc/hugmesh/pki/ca-chain.crt"
    TS_SSH_USER="$(read_env TS_SSH_USER)"    || TS_SSH_USER=""
    [ -n "${TS_SSH_USER}" ] || TS_SSH_USER="admin"
    MESH_TAG="tag:mesh_$(sanitise_tag "${MESH_ID}")"
    return 0
}

# ── (3) Fetch the signed export over the SAME mTLS identity Layer-B uses ───────
# A missing URL / client cert is the BOOTSTRAP / not-yet-wired state: keep the
# applied policy and exit 0 (NO mesh outage — the baked bootstrap policy already
# lets the privileged operator in during provisioning).
fetch_export() {
    local out="$1"
    [ -n "${BFF_URL}" ] || { warn "BFF_EXPORT_URL unset — bootstrap/offline, keeping current policy"; return 1; }
    have curl || { warn "curl absent — cannot fetch, keeping current policy"; return 1; }
    local url="${BFF_URL%/}/bff/admin/device-licenses/export?mesh=${MESH_ID}"
    local args=(-sS -m 15 --fail -o "${out}")
    [ -f "${MTLS_CA}" ]   && args+=(--cacert "${MTLS_CA}")
    if [ -n "${MTLS_CERT}" ] && [ -n "${MTLS_KEY}" ] && [ -f "${MTLS_CERT}" ] && [ -f "${MTLS_KEY}" ]; then
        args+=(--cert "${MTLS_CERT}" --key "${MTLS_KEY}")
    else
        warn "mTLS client cert/key not present — the /export call will be rejected (SUPERADMIN|mTLS); keeping current policy"
        return 1
    fi
    if curl "${args[@]}" "${url}" 2>/dev/null; then
        [ -s "${out}" ] && return 0
        warn "empty export body from ${url} — keeping current policy"; return 1
    fi
    warn "fetch failed (${url}) — keeping current policy"; return 1
}

# ── (5) Render policy.hujson from the verified export ──────────────────────────
# Build the dynamic tagOwners suffix + the ssh[] edge block with jq, then splice
# them into the template at the @@ markers. We emit the SUPERADMIN mesh rule
# ALWAYS (independent of the export body) so superadmin reach to core nodes the
# export deliberately omits is preserved (the SUPERADMIN RULE in the design).
#
# Determinism: jq sorts the operator-derived dst tags + edges; the export is
# already server-sorted (op, fp, via). Output is pretty 2-space JSON so a content
# hash is stable across runs.
render_policy() {
    local export_json="$1" out="$2"

    # Dynamic dst tagOwners: one "tag:dev_<shorthash>" per distinct machineKeyFp
    # and one "tag:dom_<domain>" per distinct domain. We DERIVE the domain from
    # the `via`/hostname is NOT reliable (the export carries no domain field), so
    # tag:dom_* is minted from the operator's license domain ONLY when present;
    # since the export AuthorizedOperator carries no domain, we mint tag:dom_*
    # from a best-effort: NONE here (kept for the force-tag step which knows the
    # node's registry domain). The renderer therefore emits per-NODE tag:dev_*
    # owners (the load-bearing dst); tag:dom_* owners are added by the force-tag
    # companion from the registry, not from the export body. So the dynamic
    # tagOwners suffix here lists ONLY the tag:dev_<fp> family.
    #
    # tag:dev_<fp> uses a short, headscale-safe hash of the FULL machineKeyFp so
    # the ACL string is bounded + charset-clean while staying 1:1 with the fp.
    # The SAME hash is computed by hugmesh-headscale-forcetags so the forced
    # tag matches the rendered dst EXACTLY.
    #
    # Compute dev-tag shorthashes in shell (sha256 first 12 hex of the fp) and
    # build BOTH the tagOwners suffix and the per-edge ssh accepts. Doing the
    # hash in shell keeps a single source of truth for the fp->tag mapping shared
    # with hugmesh-headscale-forcetags (which sources dev_tag_for_fp below).
    local fps fp short
    fps="$(jq -r '[ .body.operators[]?.machineKeyFp // empty ] | unique | .[]' "${export_json}" 2>/dev/null)"

    # tagOwners dynamic suffix (leading comma + newline so it slots after the
    # static tag:superadmin entry in the template).
    local to_suffix=""
    local seen_tags=""
    while IFS= read -r fp; do
        [ -n "${fp}" ] || continue
        short="$(dev_tag_for_fp "${fp}")"
        # de-dup tagOwners entries (multiple operators -> same node)
        case " ${seen_tags} " in
            *" ${short} "*) : ;;
            *)
                to_suffix="${to_suffix},
    \"tag:${short}\": [\"hugmesh\"]"
                seen_tags="${seen_tags} ${short}"
                ;;
        esac
    done <<< "${fps}"

    # ssh edges: one accept per node (uniq by machineKeyFp). src is the ADVISORY
    # tag:hugmesh (OPERATOR-IDENTITY open issue: no per-operator tailnet
    # identity until OIDC users land). dst is the SERVER-FORCED tag:dev_<short>.
    # users is the node-local privileged ssh account.
    #
    # The ALWAYS-emitted SUPERADMIN mesh rule is FIRST (independent of the export
    # body) so superadmin reach to core nodes the export omits is preserved even
    # when the export is empty. Each edge is JSON-encoded with `jq -cn` so
    # quoting/escaping is correct; the shell joins them into the splice body
    # (one element per line, indented to slot under the template's ssh[ marker).
    local ssh_splice=""
    local sup_edge
    sup_edge="$(jq -cn --arg sshuser "${TS_SSH_USER}" --arg meshtag "${MESH_TAG}" \
        '{action:"accept",src:["tag:superadmin"],dst:[$meshtag],users:[$sshuser]}' 2>/dev/null)"
    [ -n "${sup_edge}" ] || { warn "failed to render SUPERADMIN edge — keeping current policy"; return 1; }
    ssh_splice="$(printf '\n    %s' "${sup_edge}")"

    while IFS= read -r fp; do
        [ -n "${fp}" ] || continue
        short="$(dev_tag_for_fp "${fp}")"
        [ -n "${short}" ] || { warn "could not derive dev tag for an fp — skipping that edge (fail-closed: node unreachable, not over-broad)"; continue; }
        local edge
        edge="$(jq -cn --arg sshuser "${TS_SSH_USER}" --arg devtag "tag:${short}" \
            '{action:"accept",src:["tag:hugmesh"],dst:[$devtag],users:[$sshuser]}' 2>/dev/null)"
        [ -n "${edge}" ] || continue
        ssh_splice="${ssh_splice},$(printf '\n    %s' "${edge}")"
    done <<< "${fps}"

    # Splice into the template via awk (literal, marker-anchored — no regex on the
    # payload). We write to a tmp then the caller hashes/compares/installs.
    SNAP_TO_SUFFIX="${to_suffix}" SNAP_SSH_SPLICE="${ssh_splice}" \
    awk '
        {
            line=$0
            gsub(/@@HUGMESH_TAGOWNERS_DYNAMIC@@/, ENVIRON["SNAP_TO_SUFFIX"], line)
            gsub(/@@HUGMESH_SSH_EDGES@@/, ENVIRON["SNAP_SSH_SPLICE"], line)
            print line
        }
    ' "${POLICY_TMPL}" > "${out}" 2>/dev/null || return 1

    # Sanity: NO leftover @@ markers (a leftover would mean a failed splice).
    if grep -q '@@' "${out}" 2>/dev/null; then
        warn "rendered policy still contains @@ markers — refusing to apply (keeping current policy)"
        return 1
    fi
    return 0
}

# dev_tag_for_fp <machineKeyFp> -> "dev_<12hex>" (NO leading tag:). The canonical
# fp->tag mapping. hugmesh-headscale-forcetags carries a BYTE-IDENTICAL copy of
# this function (sourcing this file would execute main()) so the SERVER-FORCED tag
# equals the rendered ssh dst EXACTLY. If you change the hash here, change it there
# too (a drift makes the forced tag != the edge dst => the node is unreachable,
# fail-closed, never over-broad).
dev_tag_for_fp() {
    local fp="$1" h
    [ -n "${fp}" ] || { echo ""; return 1; }
    h="$(printf '%s' "${fp}" | openssl dgst -sha256 2>/dev/null | awk '{print $NF}' | cut -c1-12)"
    [ -n "${h}" ] || { echo ""; return 1; }
    echo "dev_${h}"
}

# ── (4) Atomic cache swap + last-good bump (Layer-A's own cursor) ─────────────
commit_cache() {
    local newjson="$1" newgen="$2"
    local tmp="${EXPORT_JSON}.tmp.$$"
    cp -f "${newjson}" "${tmp}" 2>/dev/null || { warn "cache stage failed"; return 1; }
    chmod 0600 "${tmp}" 2>/dev/null || true
    have sync && sync 2>/dev/null || true
    mv -f "${tmp}" "${EXPORT_JSON}" 2>/dev/null || { warn "cache rename failed"; rm -f "${tmp}"; return 1; }
    local lgt="${LAST_GOOD}.tmp.$$"
    printf '%s\n' "${newgen}" > "${lgt}" 2>/dev/null && mv -f "${lgt}" "${LAST_GOOD}" 2>/dev/null || { rm -f "${lgt}"; warn "last-good bump failed"; }
    chmod 0600 "${LAST_GOOD}" 2>/dev/null || true
    return 0
}

# ── (6) Apply on content change + force server-assigned tags ──────────────────
apply_policy() {
    local rendered="$1"
    local cur_hash new_hash
    new_hash="$(sha256sum "${rendered}" 2>/dev/null | awk '{print $1}')"
    [ -f "${POLICY_OUT}" ] && cur_hash="$(sha256sum "${POLICY_OUT}" 2>/dev/null | awk '{print $1}')" || cur_hash=""
    if [ -n "${new_hash}" ] && [ "${new_hash}" = "${cur_hash}" ]; then
        log "rendered policy unchanged (hash ${new_hash:0:12}) — no re-apply"
        return 0
    fi
    # Install the new policy atomically.
    local tmp="${POLICY_OUT}.tmp.$$"
    cp -f "${rendered}" "${tmp}" 2>/dev/null || { warn "policy stage failed — keeping current"; return 1; }
    chown headscale:headscale "${tmp}" 2>/dev/null || true
    chmod 0644 "${tmp}" 2>/dev/null || true
    mv -f "${tmp}" "${POLICY_OUT}" 2>/dev/null || { warn "policy install failed — keeping current"; rm -f "${tmp}"; return 1; }

    # REQUIRED re-apply: headscale policy mode:file is NOT hot-reloaded.
    if have headscale && headscale policy set -f "${POLICY_OUT}" 2>/dev/null; then
        log "APPLIED Layer-A policy (hash ${new_hash:0:12}) via headscale policy set -f"
    else
        warn "headscale policy set failed (check hujson / mode:file / socket) — file written, server may run stale until next apply"
    fi

    # Force the server-assigned tags so freshly-approved nodes get
    # tag:dev_<fp>/tag:dom_<domain>/tag:mesh_<id> that the ssh edges name as dst.
    if [ -x "${FORCETAGS}" ]; then
        "${FORCETAGS}" 2>/dev/null || warn "hugmesh-headscale-forcetags reported an error (some nodes may lack forced tags until next run)"
    else
        warn "hugmesh-headscale-forcetags missing — server-forced dst tags NOT applied; generated ssh edges will not match until it runs"
    fi
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    _init || exit 0   # fail-closed: any unmet precondition keeps the current policy
    local fetched; fetched="$(mktemp 2>/dev/null)" || { warn "mktemp failed — keeping current policy"; exit 0; }
    local rendered; rendered="$(mktemp 2>/dev/null)" || { rm -f "${fetched}"; warn "mktemp failed — keeping current policy"; exit 0; }
    trap 'rm -f "${fetched}" "${rendered}" 2>/dev/null || true' EXIT

    if ! fetch_export "${fetched}"; then
        exit 0   # bootstrap/offline/transport failure: keep applied policy
    fi

    # Verify signature over canonical bytes against the BAKED key AND enforce
    # STRICT monotonicity against Layer-A's OWN last-good cursor (REUSED Layer-B
    # gate — same canonicalisation, no split).
    if ! verify_export "${fetched}" "${PUB_KEY}" "${LAST_GOOD}"; then
        warn "fetched export FAILED verification or rollback guard (unsigned/tampered/foreign/gen<=last-good) — keeping current policy"
        exit 0
    fi
    local mesh; mesh="$(rv_mesh "${fetched}")"
    if [ "${mesh}" != "${MESH_ID}" ]; then
        warn "fetched export meshId=${mesh} != baked ${MESH_ID} — refusing, keeping current policy"
        exit 0
    fi
    local gen; gen="$(rv_gen "${fetched}")"

    if ! render_policy "${fetched}" "${rendered}"; then
        warn "policy render failed — keeping current policy (fail-closed)"
        exit 0
    fi
    # Final shape guard: the rendered file MUST parse as JSON once comments are
    # stripped (defence-in-depth before we hand it to headscale).
    if have jq; then
        if ! sed -e 's#//.*$##' "${rendered}" 2>/dev/null | jq -e . >/dev/null 2>&1; then
            warn "rendered policy did not parse as JSON (after comment strip) — keeping current policy"
            exit 0
        fi
    fi

    # Accept: bump Layer-A's cursor, then apply on content change.
    commit_cache "${fetched}" "${gen}" || true
    apply_policy "${rendered}"
    exit 0
}

# Run main ONLY when executed directly. When sourced (the off-node render unit
# test sources this file to drive render_policy/dev_tag_for_fp without a live BFF
# or headscale), main does NOT run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
