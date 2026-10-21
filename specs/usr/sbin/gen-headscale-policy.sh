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
#   6. on a CONTENT CHANGE (hash differs) run `headscale policy set -f` and force
#      the server-assigned tags via hugmesh-headscale-forcetags. Under policy
#      mode:file (what the fleet ships) `policy set` is REFUSED by headscale
#      ("update is disabled for modes other than 'database'") and the policy is
#      read at STARTUP only, so on that refusal the script RESTARTS headscale
#      (same fix as provision.sh, commit e1743555) and waits for it to answer
#      before forcing tags. A policy is "applied" only once a marker says so
#      (${CACHE_DIR}/applied-policy-hash), so a failed apply is retried on the
#      next tick instead of being forgotten because the file is already on disk.
#   7. a policy headscale does not load (it never answers after the restart, even
#      after a second restart) is not rolled back to the previous file as it was:
#      that file still grants every edge the export has since REVOKED, and the cursor
#      has already advanced so the same generation is never fetched again. The
#      fallback is the previous policy narrowed to the ssh edges the rejected policy
#      still carries, computed without temp files. When even that cannot be computed
#      the previous policy is NOT restored: the refused one stays and headscale stays
#      down (fail closed). A restart command that fails outright cannot change what is
#      running, so that case only alarms and retries. The rejected policy is kept as
#      pending and retried a bounded number of ticks, and an ALARM
#      (${CACHE_DIR}/apply-failed + a daemon.crit log line) is raised. Loading the
#      FALLBACK on a later tick does not clear it; loading the pending policy, or a
#      newer generation that replaces it, does.
#   8. a policy that cannot be written into /etc/headscale (disk full, read-only)
#      raises the same alarm, is kept pending, and does NOT advance the export
#      cursor, so the same generation is installed again on the next tick.
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
# Hash of the policy the RUNNING headscale is known to have loaded. Written only
# after `policy set` or a restart succeeded; apply is skipped only when this
# matches, never merely because the rendered file is already on disk.
APPLIED_MARK="${CACHE_DIR}/applied-policy-hash"
# After a restart, wait up to HS_READY_TRIES x HS_READY_SLEEP seconds for the
# headscale socket to answer before forcing tags (or declaring the policy bad).
HS_READY_TRIES="${HS_READY_TRIES:-20}"
HS_READY_SLEEP="${HS_READY_SLEEP:-1}"
# A start that is merely late must not be mistaken for a rejected policy: restart up
# to this many times, waiting a full ready window after each, before concluding
# headscale will not load the file.
HS_APPLY_ATTEMPTS="${HS_APPLY_ATTEMPTS:-2}"
# A policy headscale would not load is retried on this many LATER ticks (each retry
# restarts headscale), then left alone so a genuinely bad policy cannot flap the
# control plane every minute. The alarm stays raised either way.
HS_PENDING_RETRIES="${HS_PENDING_RETRIES:-3}"
# Raised while the policy the export asks for is NOT what headscale serves (apply
# failed, restart failed, or the policy was rejected and a fallback is running).
# Body is key=value lines; removed only when the wanted policy is loaded.
ALARM_MARK="${CACHE_DIR}/apply-failed"
# The rendered policy headscale refused to load, and how many retry ticks it has had.
PENDING_POLICY="${CACHE_DIR}/pending-policy.hujson"
PENDING_TRIES="${CACHE_DIR}/pending-tries"

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

# ── (4) Atomic cache swap, and last-good bump (Layer-A's own cursor) ──────────
commit_cache() {
    local newjson="$1"
    local tmp="${EXPORT_JSON}.tmp.$$"
    cp -f "${newjson}" "${tmp}" 2>/dev/null || { warn "cache stage failed"; return 1; }
    chmod 0600 "${tmp}" 2>/dev/null || true
    have sync && sync 2>/dev/null || true
    mv -f "${tmp}" "${EXPORT_JSON}" 2>/dev/null || { warn "cache rename failed"; rm -f "${tmp}"; return 1; }
    return 0
}

# Advance Layer-A's cursor. Called only after the policy rendered from generation
# <newgen> is installed in /etc/headscale.
bump_cursor() {
    local newgen="$1"
    local lgt="${LAST_GOOD}.tmp.$$"
    printf '%s\n' "${newgen}" > "${lgt}" 2>/dev/null && mv -f "${lgt}" "${LAST_GOOD}" 2>/dev/null || { rm -f "${lgt}"; warn "last-good bump failed"; }
    chmod 0600 "${LAST_GOOD}" 2>/dev/null || true
    return 0
}

# ── (6) Apply on content change + force server-assigned tags ──────────────────
policy_hash() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

# Block until the headscale socket answers (it does not right after a restart).
headscale_ready() {
    local i
    for ((i = 0; i < HS_READY_TRIES; i++)); do
        headscale nodes list >/dev/null 2>&1 && return 0
        sleep "${HS_READY_SLEEP}"
    done
    return 1
}

# Restart headscale so a policy.mode:file policy is re-read. rc-service is the
# OpenRC entry point provision.sh uses for the same job.
restart_headscale() {
    have rc-service && rc-service headscale restart >/dev/null 2>&1
}

# Restart headscale and wait for it to answer. Returns 0 once it does, 2 when the
# restart command itself fails (nothing was reloaded), 1 when it was restarted but
# never answered. A slow start gets HS_APPLY_ATTEMPTS full windows before it counts
# as 1, so a policy is not declared rejected because headscale was merely late.
restart_and_wait() {
    local i
    for ((i = 1; i <= HS_APPLY_ATTEMPTS; i++)); do
        restart_headscale || return 2
        headscale_ready && return 0
        warn "headscale did not answer within ${HS_READY_TRIES}x${HS_READY_SLEEP}s of restart attempt ${i}/${HS_APPLY_ATTEMPTS}"
    done
    return 1
}

# ALARM: a failed or late apply must be loud and stay loud. The previous behaviour
# was one warn line and silence, while the running headscale kept granting edges the
# export had already revoked.
raise_alarm() {
    local since
    since="$(sed -n 's/^since=//p' "${ALARM_MARK}" 2>/dev/null | head -1)"
    [ -n "${since}" ] || since="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    local wanted="${POLICY_OUT}"
    [ -f "${PENDING_POLICY}" ] && wanted="${PENDING_POLICY}"
    printf 'since=%s\nwanted_policy=%s\nreason=%s\n' "${since}" "$(policy_hash "${wanted}" | cut -c1-12)" "$*" \
        > "${ALARM_MARK}" 2>/dev/null || true
    log "ALARM: Layer-A policy NOT applied as exported: $*"
    have logger && logger -p daemon.crit -t "${LOG_TAG}" -- "ALARM: Layer-A policy not applied as exported: $*" 2>/dev/null || true
}

# The wanted policy is loaded: drop the alarm and any pending rejected policy.
clear_alarm() {
    [ -e "${ALARM_MARK}" ] && log "Layer-A policy now applied as exported — alarm cleared"
    rm -f "${ALARM_MARK}" "${PENDING_POLICY}" "${PENDING_TRIES}" 2>/dev/null || true
}

# Keep a rejected policy for retry. A different policy starts a fresh retry count; the
# same one being retried keeps its count so the cap holds.
save_pending() {
    if [ ! -f "${PENDING_POLICY}" ] || [ "$(policy_hash "${PENDING_POLICY}")" != "$(policy_hash "$1")" ]; then
        cp -f "$1" "${PENDING_POLICY}" 2>/dev/null || true
        printf '0\n' > "${PENDING_TRIES}" 2>/dev/null || true
    fi
}

# revocation_safe_fallback <prev> <rejected> <out>: the policy to run while the
# rejected one cannot be loaded. It is <prev> with every ssh edge the rejected policy
# no longer carries REMOVED, so a revocation survives a failed apply (the old rollback
# restored <prev> verbatim and with it every revoked edge). Edges that are in both are
# kept, and so is the always-on tag:superadmin break-glass edge. When nothing was
# revoked <prev> is copied byte for byte. A rejected policy that does not parse keeps
# NO edge but break-glass. Uses no temp file (jq reads both policies through pipes),
# so a full or missing TMPDIR cannot turn the narrowing off. Returns 1, writing
# NOTHING, when <prev> itself cannot be narrowed: the caller must then not run <prev>.
revocation_safe_fallback() {
    local prev="$1" rejected="$2" out="$3" before after
    rm -f "${out}" 2>/dev/null
    have jq || return 1
    before="$(sed -e 's#//.*$##' "${prev}" 2>/dev/null \
        | jq '(.ssh // []) | if type == "array" then length else error("ssh is not a list") end' 2>/dev/null)" || before=""
    case "${before}" in ''|*[!0-9]*) return 1 ;; esac
    sed -e 's#//.*$##' "${rejected}" 2>/dev/null | jq -e 'type == "object"' >/dev/null 2>&1 \
        || warn "the refused policy does not parse — the fallback keeps only the tag:superadmin ssh edge"
    if ! sed -e 's#//.*$##' "${prev}" 2>/dev/null | jq \
            --slurpfile k <(sed -e 's#//.*$##' "${rejected}" 2>/dev/null \
                | jq -c '(.ssh // []) | if type == "array" then . else [] end' 2>/dev/null) '
            ($k[0] // []) as $keep
            | if has("ssh") then
                .ssh |= map(. as $e | select($e.src == ["tag:superadmin"] or any($keep[]; . == $e)))
              else . end' > "${out}" 2>/dev/null; then
        rm -f "${out}" 2>/dev/null; return 1
    fi
    after="$(jq '(.ssh // []) | length' "${out}" 2>/dev/null)" || after=""
    case "${after}" in ''|*[!0-9]*) rm -f "${out}" 2>/dev/null; return 1 ;; esac
    if [ "${after}" = "${before}" ]; then
        cp -f "${prev}" "${out}" 2>/dev/null || { rm -f "${out}" 2>/dev/null; return 1; }   # nothing revoked: previous policy, untouched
    else
        log "fallback policy drops $((before - after)) ssh edge(s) the rejected policy had revoked"
    fi
    return 0
}

# The policy the export asks for is loaded only when the file headscale now serves IS
# that policy. While a refused policy is pending, the file loaded may be the fallback
# built from it, and loading the fallback must not clear the alarm.
wanted_is_loaded() {
    [ ! -f "${PENDING_POLICY}" ] || [ "$(policy_hash "${PENDING_POLICY}")" = "$(policy_hash "${POLICY_OUT}")" ]
}

# Make the RUNNING headscale serve POLICY_OUT. Returns 0 once it serves the policy the
# export asks for (marker written, alarm cleared), 1 otherwise (the alarm is raised).
#   $1 = fresh (POLICY_OUT was just installed from the export) or retry (a later tick
#        re-activating what is on disk, which may be a fallback)
#   $2 = the file POLICY_OUT replaced, if any (may be empty): when headscale will not
#        load POLICY_OUT it is the base of the fallback policy.
activate_policy() {
    local mode="$1" prev="${2:-}" hash set_err set_rc=0 rc=0
    hash="$(policy_hash "${POLICY_OUT}")"
    if have headscale; then
        # stderr is CAPTURED: it was discarded here, which is why a mode:file refusal
        # looked like success. Under mode:file this fails every time, by design.
        set_err="$(headscale policy set -f "${POLICY_OUT}" 2>&1)" || set_rc=$?
    else
        set_err="headscale binary not found"; set_rc=127
    fi
    if [ "${set_rc}" -eq 0 ]; then
        log "APPLIED Layer-A policy (hash ${hash:0:12}) via headscale policy set -f"
    else
        warn "headscale policy set failed for ${POLICY_OUT}: ${set_err:-<no output>}"
        # policy.mode=file reads the file at STARTUP only (specs/etc/headscale/
        # config.yaml), so the running server still serves the old policy. Restart.
        restart_and_wait || rc=$?
        if [ "${rc}" -eq 2 ]; then
            warn "headscale restart FAILED — the running server still serves the policy it read at startup (Layer-A revocations are NOT propagating); will retry next tick"
            raise_alarm "headscale restart failed; the running policy predates ${hash:0:12} and any revocation in it is NOT in force"
            return 1
        elif [ "${rc}" -eq 0 ]; then
            log "headscale restarted to load ${POLICY_OUT} (hash ${hash:0:12}; policy.mode=file reloads at startup)"
        elif [ -n "${prev}" ] && [ -f "${prev}" ]; then
            # Restarted, still silent after every attempt: headscale rejected the new
            # policy at startup. Keep the control plane up, but NOT on the previous
            # file as it was: it still grants whatever the export has since revoked.
            warn "headscale did not answer after loading hash ${hash:0:12} — falling back to the previous policy minus every ssh edge the new one revokes"
            # On a retry tick POLICY_OUT may already be the fallback: it must never
            # replace the policy the export asked for as the pending one.
            if [ "${mode}" = fresh ] || [ ! -f "${PENDING_POLICY}" ]; then
                save_pending "${POLICY_OUT}"
            fi
            if ! revocation_safe_fallback "${prev}" "${POLICY_OUT}" "${POLICY_OUT}.fallback" \
                || ! mv -f "${POLICY_OUT}.fallback" "${POLICY_OUT}" 2>/dev/null; then
                rm -f "${POLICY_OUT}.fallback" 2>/dev/null
                # FAIL CLOSED: the previous policy is NOT restored, because it may still
                # carry edges the refused policy revokes. The refused policy stays on
                # disk and headscale stays down until a policy loads.
                raise_alarm "headscale would not load ${hash:0:12} and no revocation-safe fallback could be built from the previous policy; the previous policy was NOT restored and headscale is DOWN"
                return 1
            fi
            if restart_and_wait; then
                printf '%s\n' "$(policy_hash "${POLICY_OUT}")" > "${APPLIED_MARK}" 2>/dev/null || true
                raise_alarm "headscale would not load ${hash:0:12}; running the previous policy minus revoked edges, retrying it for ${HS_PENDING_RETRIES} more tick(s)"
            else
                warn "fallback restart FAILED — headscale is DOWN; will retry next tick"
                raise_alarm "headscale would not load ${hash:0:12} and the fallback policy did not start either: headscale is DOWN"
            fi
            return 1
        else
            warn "headscale did not answer after restart — will retry next tick"
            raise_alarm "headscale did not answer after loading ${hash:0:12}; no previous policy to fall back to"
            return 1
        fi
    fi
    printf '%s\n' "${hash}" > "${APPLIED_MARK}" 2>/dev/null || warn "could not write ${APPLIED_MARK}"
    local loaded_wanted=0
    if wanted_is_loaded; then
        clear_alarm
    else
        # A retry tick brought up the FALLBACK (it had not started on the earlier
        # tick). That is not the exported policy: keep it pending and keep the alarm.
        loaded_wanted=1
        raise_alarm "headscale is running the fallback ${hash:0:12}, not the exported policy $(policy_hash "${PENDING_POLICY}" | cut -c1-12), which it refused; retrying it"
    fi

    # Force the server-assigned tags so freshly-approved nodes get
    # tag:dev_<fp>/tag:dom_<domain>/tag:mesh_<id> that the ssh edges name as dst.
    if [ -x "${FORCETAGS}" ]; then
        "${FORCETAGS}" 2>/dev/null || warn "hugmesh-headscale-forcetags reported an error (some nodes may lack forced tags until next run)"
    else
        warn "hugmesh-headscale-forcetags missing — server-forced dst tags NOT applied; generated ssh edges will not match until it runs"
    fi
    return "${loaded_wanted}"
}

# apply_policy <rendered>: install <rendered> as POLICY_OUT and activate it. Returns 0
# once it is installed (activation is tracked by the applied marker, the pending policy
# and the alarm), 1 when it could NOT be installed: main then does not advance the
# export cursor, so the same generation is fetched and installed again next tick.
apply_policy() {
    local rendered="$1"
    local cur_hash new_hash applied=""
    new_hash="$(policy_hash "${rendered}")"
    [ -f "${POLICY_OUT}" ] && cur_hash="$(policy_hash "${POLICY_OUT}")" || cur_hash=""
    [ -f "${APPLIED_MARK}" ] && applied="$(head -1 "${APPLIED_MARK}" 2>/dev/null)"
    if [ -n "${new_hash}" ] && [ "${new_hash}" = "${cur_hash}" ] && [ "${new_hash}" = "${applied}" ]; then
        log "rendered policy unchanged and already applied (hash ${new_hash:0:12}) — no re-apply"
        clear_alarm   # the export now asks for exactly what is running: nothing is pending any more
        return 0
    fi
    # A newer policy than the pending one is now the one the export asks for: the old
    # pending policy must never be re-installed over it.
    if [ -f "${PENDING_POLICY}" ] && [ "$(policy_hash "${PENDING_POLICY}")" != "${new_hash}" ]; then
        rm -f "${PENDING_POLICY}" "${PENDING_TRIES}" 2>/dev/null
    fi
    # Keep the file being replaced so a policy headscale rejects at startup can be rolled back.
    local prev=""
    if [ -f "${POLICY_OUT}" ] && [ "${new_hash}" != "${cur_hash}" ]; then
        prev="${POLICY_OUT}.prev"
        cp -f "${POLICY_OUT}" "${prev}" 2>/dev/null || prev=""
    elif [ -f "${POLICY_OUT}.prev" ]; then
        prev="${POLICY_OUT}.prev"   # re-activating what is already on disk: same fallback base as the first try
    fi
    # Install the new policy atomically. A failure here (disk full, read-only or
    # unwritable /etc/headscale) leaves the previous policy running, so it is alarmed
    # and kept pending like a refused policy, and the caller holds the cursor.
    local tmp="${POLICY_OUT}.tmp.$$"
    if ! cp -f "${rendered}" "${tmp}" 2>/dev/null; then
        rm -f "${tmp}" 2>/dev/null
        warn "policy stage failed — the previous policy keeps running"
        save_pending "${rendered}"
        raise_alarm "could not stage ${new_hash:0:12} into $(dirname "${POLICY_OUT}"); the running policy predates it and any revocation in it is NOT in force"
        return 1
    fi
    chown headscale:headscale "${tmp}" 2>/dev/null || true
    chmod 0644 "${tmp}" 2>/dev/null || true
    if ! mv -f "${tmp}" "${POLICY_OUT}" 2>/dev/null; then
        rm -f "${tmp}" 2>/dev/null
        warn "policy install failed — the previous policy keeps running"
        save_pending "${rendered}"
        raise_alarm "could not install ${new_hash:0:12} as ${POLICY_OUT}; the running policy predates it and any revocation in it is NOT in force"
        return 1
    fi

    activate_policy fresh "${prev}" || true
    return 0
}

# install_generation <export> <rendered> <generation>: cache the export (force-tags
# reads it), apply the rendered policy, and bump Layer-A's cursor only once that policy
# is installed. A policy that could not be written to /etc/headscale leaves the cursor
# where it was, so the same generation is fetched and installed again next tick even
# when no state file (alarm, pending policy) could be written either.
install_generation() {
    commit_cache "$1" || true
    if apply_policy "$2"; then
        bump_cursor "$3"
        return 0
    fi
    warn "policy for generation $3 not installed — export cursor NOT advanced, it is fetched again next tick"
    return 1
}

# A policy that is on disk but not marked applied (a restart that failed on an
# earlier tick). The fetch path below cannot retry it: the export cursor already
# advanced, so the same generation is refused as a rollback. Retry it directly.
retry_pending() {
    local applied="" tries=0
    [ -f "${APPLIED_MARK}" ] && applied="$(head -1 "${APPLIED_MARK}" 2>/dev/null)"
    [ -f "${PENDING_TRIES}" ] && tries="$(head -1 "${PENDING_TRIES}" 2>/dev/null)"
    case "${tries}" in ''|*[!0-9]*) tries=0 ;; esac
    if [ -f "${POLICY_OUT}" ] && [ "$(policy_hash "${POLICY_OUT}")" != "${applied}" ]; then
        # The refused policy itself is on disk (no fallback could be built): every
        # retry restarts headscale on it, so it shares the pending retry cap.
        if wanted_is_loaded && [ -f "${PENDING_POLICY}" ]; then
            if [ "${tries}" -ge "${HS_PENDING_RETRIES}" ]; then
                warn "the policy headscale refused was retried ${tries} time(s); not retrying it again until a new export generation replaces it — the ALARM stays raised"
                return 0
            fi
            printf '%s\n' "$((tries + 1))" > "${PENDING_TRIES}" 2>/dev/null || true
        fi
        log "policy on disk is not marked applied — retrying activation"
        local base=""
        [ -f "${POLICY_OUT}.prev" ] && base="${POLICY_OUT}.prev"
        activate_policy retry "${base}" || true
        return 0
    fi
    # What is on disk IS what runs, but the export asked for another policy: headscale
    # refused it, or it could not be installed. Offer it again (the cause may have been
    # transient); the alarm stays raised until it loads.
    [ -f "${PENDING_POLICY}" ] || return 0
    if [ "${tries}" -ge "${HS_PENDING_RETRIES}" ]; then
        warn "the policy headscale refused was retried ${tries} time(s); not retrying it again until a new export generation replaces it — the ALARM stays raised"
        return 0
    fi
    log "retrying the pending policy (retry $((tries + 1))/${HS_PENDING_RETRIES})"
    # apply_policy only reads its argument, so the pending file is passed as it is (no
    # temp copy that a full TMPDIR could silently skip). A retry that cannot even be
    # installed restarted nothing and does not count against the cap.
    if apply_policy "${PENDING_POLICY}" && [ -f "${PENDING_POLICY}" ]; then
        printf '%s\n' "$((tries + 1))" > "${PENDING_TRIES}" 2>/dev/null || true
    fi
    return 0
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
    _init || exit 0   # fail-closed: any unmet precondition keeps the current policy
    retry_pending
    local fetched; fetched="$(mktemp 2>/dev/null)" || { raise_alarm "mktemp failed: no export can be fetched, so no revocation is propagating"; exit 0; }
    local rendered; rendered="$(mktemp 2>/dev/null)" || { rm -f "${fetched}"; raise_alarm "mktemp failed: no export can be fetched, so no revocation is propagating"; exit 0; }
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

    install_generation "${fetched}" "${rendered}" "${gen}" || true
    exit 0
}

# Run main ONLY when executed directly. When sourced (the off-node render unit
# test sources this file to drive render_policy/dev_tag_for_fp without a live BFF
# or headscale), main does NOT run.
if [ "${BASH_SOURCE[0]}" = "${0}" ]; then
    main "$@"
fi
