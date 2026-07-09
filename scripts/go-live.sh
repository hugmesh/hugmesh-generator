#!/usr/bin/env bash
# go-live.sh — the superadmin go-live wizard ENGINE (v1).
#
# WHAT IT IS
#   The single flag-driven driver that takes a brand from internal-only to
#   publicly live. Every front-end (make go-live / scripts/go-live-menu.sh /
#   Studio / admin UI) dispatches THIS script's flags — the flags are the
#   engine, exactly as the build scripts are for `make`.
#
# WHAT IT IS NOT (v1 non-goals, deliberate)
#   * It NEVER reimplements release posture. The mechanism already exists:
#     /etc/snapdragon/release-state (baked, internal|public) OR the
#     /etc/snapdragon/go-live marker flip the posture, and
#     specs/usr/sbin/snapdragon-firewall-reconcile (boot oneshot + 60s cron,
#     fail-closed) + specs/cluster/bootstrap/bootstrap.sh converge on it.
#     This script is ONLY the effector that writes the marker after the edge
#     prerequisites pass. Rollback = delete the marker (--rollback).
#   * NO registrar API drivers beyond the thin ones the catalog names (the
#     DuckDNS/Cloudflare DDNS updaters + the OPTIONAL Cloudflare CNAME
#     creator) — everything else is deep-link + autofill + downloadable files.
#   * NO router mutation — instructions only.
#   * NO unattended auto-go-live: --flip requires an interactive typed
#     confirmation on a real TTY. There is deliberately no bypass flag; the
#     human confirm IS the security boundary.
#
# PROVIDERS
#   Declared in scripts/golive-providers.conf (one [section] per provider);
#   this script carries no per-provider page URLs or notes of its own.
#
# SECRET HYGIENE
#   Tokens are read from --token-file/--cf-api-token-file (or a masked TTY
#   prompt), written ONLY to the gitignored keys-layout destinations the
#   catalog names (token_dest, relative to --keys-dir), mode 0600. They are
#   never echoed, never placed in argv of child processes, never logged.
#
# USAGE
#   go-live.sh --list
#   go-live.sh --provider cloudflare-tunnel --info | --links [--open]
#   go-live.sh --provider ddns --domain example.org --ddns-subdomain home \
#              --token-file /path/token --emit
#   go-live.sh --provider registrar-manual --domain example.org \
#              --record-ip 203.0.113.7 --emit
#   go-live.sh --domain example.org --verify
#   go-live.sh --domain example.org --flip [--persist]      (root, on-device)
#   go-live.sh --rollback [--persist]                       (root, on-device)
#   go-live.sh --status
#
# Interactive prompts + many benignly-non-zero probes => no `set -e`; we keep
# -u/pipefail and handle every error explicitly (same rationale as
# scripts/build-menu.sh and specs/usr/sbin/snapdragon-domain-reconcile).
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
CATALOG="${GOLIVE_CATALOG:-${SCRIPT_DIR}/golive-providers.conf}"

# The EXISTING posture files (owned by snapdragon-firewall-reconcile /
# the image bake — this script only reads them, plus writes the marker).
RELEASE_STATE_FILE="${GOLIVE_RELEASE_STATE_FILE:-/etc/snapdragon/release-state}"
GO_LIVE_MARKER="${GOLIVE_MARKER:-/etc/snapdragon/go-live}"
CLUSTER_DOMAIN_FILE="${GOLIVE_CLUSTER_DOMAIN_FILE:-/etc/snapdragon/cluster-domain}"

# ── Colours (only when stderr is a TTY, matching scripts/build-menu.sh) ────────
if [ -t 2 ]; then
    C_RED=$'\033[31m'; C_GRN=$'\033[32m'; C_YEL=$'\033[33m'; C_CYN=$'\033[36m'
    C_BLD=$'\033[1m';  C_RST=$'\033[0m'
else
    C_RED=''; C_GRN=''; C_YEL=''; C_CYN=''; C_BLD=''; C_RST=''
fi
say()  { printf '%s[go-live]%s %s\n' "${C_GRN}" "${C_RST}" "$*" >&2; }
warn() { printf '%s[go-live] WARN:%s %s\n' "${C_YEL}" "${C_RST}" "$*" >&2; }
die()  { printf '%s[go-live] ERROR:%s %s\n' "${C_RED}" "${C_RST}" "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }

# ── Options ─────────────────────────────────────────────────────────────────────
PROVIDER=""
DOMAIN=""
[ -r "${CLUSTER_DOMAIN_FILE}" ] && DOMAIN="$(tr -d '[:space:]' < "${CLUSTER_DOMAIN_FILE}" 2>/dev/null)"
TOKEN_FILE=""            # secret token source (never a --token VALUE flag: argv leaks)
CF_API_TOKEN_FILE=""     # optional Cloudflare API token (thin --create-dns driver)
TUNNEL_ID=""             # Cloudflare tunnel UUID (CNAME target autofill)
DDNS_SERVICE="duckdns"   # duckdns | cloudflare
DDNS_SUBDOMAIN=""        # DDNS hostname label
RECORD_IP=""             # public A/AAAA record value
OUT_DIR="${GOLIVE_OUT:-${REPO_DIR}/out/go-live}"
KEYS_DIR="${GOLIVE_KEYS_DIR:-${REPO_DIR}/keys-template}"
DO_LIST=0; DO_INFO=0; DO_LINKS=0; DO_OPEN=0; DO_EMIT=0; DO_VERIFY=0
DO_CREATE_DNS=0; DO_FLIP=0; DO_ROLLBACK=0; DO_STATUS=0; DO_PERSIST=0
FORCE=0; DRY_RUN=0

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "${BASH_SOURCE[0]}"; }

while [ "$#" -gt 0 ]; do
    case "$1" in
        --provider)          PROVIDER="${2:?--provider needs a value}"; shift 2 ;;
        --domain)            DOMAIN="${2:?--domain needs a value}"; shift 2 ;;
        --token-file)        TOKEN_FILE="${2:?--token-file needs a path}"; shift 2 ;;
        --cf-api-token-file) CF_API_TOKEN_FILE="${2:?--cf-api-token-file needs a path}"; shift 2 ;;
        --tunnel-id)         TUNNEL_ID="${2:?--tunnel-id needs a value}"; shift 2 ;;
        --ddns-service)      DDNS_SERVICE="${2:?--ddns-service needs duckdns|cloudflare}"; shift 2 ;;
        --ddns-subdomain)    DDNS_SUBDOMAIN="${2:?--ddns-subdomain needs a value}"; shift 2 ;;
        --record-ip)         RECORD_IP="${2:?--record-ip needs a value}"; shift 2 ;;
        --out)               OUT_DIR="${2:?--out needs a dir}"; shift 2 ;;
        --keys-dir)          KEYS_DIR="${2:?--keys-dir needs a dir}"; shift 2 ;;
        --list|--list-providers) DO_LIST=1; shift ;;
        --info)              DO_INFO=1; shift ;;
        --links)             DO_LINKS=1; shift ;;
        --open)              DO_OPEN=1; shift ;;
        --emit)              DO_EMIT=1; shift ;;
        --create-dns)        DO_CREATE_DNS=1; shift ;;
        --verify)            DO_VERIFY=1; shift ;;
        --flip)              DO_FLIP=1; shift ;;
        --rollback)          DO_ROLLBACK=1; shift ;;
        --status)            DO_STATUS=1; shift ;;
        --persist)           DO_PERSIST=1; shift ;;
        --force)             FORCE=1; shift ;;
        --dry-run)           DRY_RUN=1; shift ;;
        -h|--help)           usage; exit 0 ;;
        *) die "unknown flag: $1 (see --help)" ;;
    esac
done

[ -r "${CATALOG}" ] || die "provider catalog not found: ${CATALOG}"

# ── Input validation (security-relevant) ────────────────────────────────────────
# --ddns-subdomain is interpolated into the EMITTED ddns-update.sh through an
# expanding heredoc, and that script is installed as a root cron job — so it
# MUST be a strict single DNS label (no dots, no shell metacharacters) before
# anything else runs. --record-ip lands verbatim in records.csv/zone.db, so it
# gets the same shape check (a newline/comma would forge extra DNS rows).
if [ -n "${DDNS_SUBDOMAIN}" ]; then
    [[ "${DDNS_SUBDOMAIN}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] \
        || die "--ddns-subdomain must be a single lowercase DNS label ([a-z0-9-], 1-63 chars, no dots)"
fi
if [ -n "${RECORD_IP}" ]; then
    case "${RECORD_IP}" in
        *:*) [[ "${RECORD_IP}" =~ ^[0-9A-Fa-f:]{2,45}(\.[0-9]{1,3}(\.[0-9]{1,3}){2})?$ ]] \
                 || die "--record-ip is not a valid IPv6 literal" ;;
        *)   [[ "${RECORD_IP}" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] \
                 || die "--record-ip is not a valid IPv4 address" ;;
    esac
fi

# ── Catalog access (scripts/golive-providers.conf) ──────────────────────────────
# cat_get SECTION KEY    -> first value (empty if unset)
# cat_get_all SECTION KEY-> every value, one per line (link/note rows repeat)
# cat_sections           -> every [provider-id]
cat_get() {
    awk -v s="$1" -v k="$2" '
        /^\[/ { in_s = ($0 == "[" s "]"); next }
        in_s && $1 == k && $2 == "=" { line = $0; sub(/^[^=]*= ?/, "", line); print line; exit }
    ' "${CATALOG}"
}
cat_get_all() {
    awk -v s="$1" -v k="$2" '
        /^\[/ { in_s = ($0 == "[" s "]"); next }
        in_s && $1 == k && $2 == "=" { line = $0; sub(/^[^=]*= ?/, "", line); print line }
    ' "${CATALOG}"
}
cat_sections() { awk -F'[][]' '/^\[/ { print $2 }' "${CATALOG}"; }

require_provider() {
    [ -n "${PROVIDER}" ] || die "this action needs --provider (try --list)"
    cat_sections | grep -qx "${PROVIDER}" \
        || die "unknown provider '${PROVIDER}' — available: $(cat_sections | tr '\n' ' ')"
}
require_domain() {
    [ -n "${DOMAIN}" ] || die "this action needs --domain (no ${CLUSTER_DOMAIN_FILE} bake found to autofill from)"
    [[ "${DOMAIN}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)+$ ]] \
        || die "'${DOMAIN}' is not a valid DNS name"
}

# ── Hostname autofill — the SAME reserved set the cloudflared config maps
# (specs/cluster/manifests/cloudflared/configmap.yaml: apex + api./matrix./
# mastodon. + the *.<domain> vanity wildcard). ─────────────────────────────────
golive_hosts() {  # one FQDN per line, apex first, wildcard last
    printf '%s\n' "${DOMAIN}" "api.${DOMAIN}" "matrix.${DOMAIN}" "mastodon.${DOMAIN}" "*.${DOMAIN}"
}

# ── Secret handling ──────────────────────────────────────────────────────────────
# read_token PROMPT -> sets REPLY_TOKEN. File first (--token-file), masked TTY
# prompt second, hard refusal third. The value is never echoed or logged.
REPLY_TOKEN=""
read_token() {
    local prompt="$1"
    if [ -n "${TOKEN_FILE}" ]; then
        [ -r "${TOKEN_FILE}" ] || die "--token-file not readable: ${TOKEN_FILE}"
        REPLY_TOKEN="$(tr -d '\n' < "${TOKEN_FILE}")"
    elif [ -t 0 ]; then
        printf '%s (input hidden): ' "${prompt}" >&2
        IFS= read -r -s REPLY_TOKEN </dev/tty || REPLY_TOKEN=""
        printf '\n' >&2
    fi
    [ -n "${REPLY_TOKEN}" ] || die "no token provided (use --token-file, or run on a TTY for a masked prompt)"
}

# store_token REL_DEST — write REPLY_TOKEN to ${KEYS_DIR}/REL_DEST (0600).
# These destinations are the gitignored keys-layout paths the catalog names.
store_token() {
    local rel="$1" dest="${KEYS_DIR}/$1"
    [ "${DRY_RUN}" = 1 ] && { say "[dry-run] would write token -> ${dest} (0600)"; return 0; }
    ( umask 077 && mkdir -p "$(dirname "${dest}")" ) || die "cannot create $(dirname "${dest}")"
    ( umask 077 && printf '%s\n' "${REPLY_TOKEN}" > "${dest}" ) || die "cannot write ${dest}"
    chmod 600 "${dest}" 2>/dev/null || true
    say "token written -> ${dest} (0600; gitignored — never commit it)"
}

# curl with a Bearer token WITHOUT the token in argv: the Authorization header
# is passed via a 0600 temp file (`curl -H @file`).
CF_HDR_FILE=""
cf_auth_header() {
    [ -n "${CF_HDR_FILE}" ] && [ -f "${CF_HDR_FILE}" ] && return 0
    [ -n "${CF_API_TOKEN_FILE}" ] || die "--create-dns / --ddns-service cloudflare needs --cf-api-token-file"
    [ -r "${CF_API_TOKEN_FILE}" ]  || die "--cf-api-token-file not readable: ${CF_API_TOKEN_FILE}"
    CF_HDR_FILE="$(umask 077 && mktemp)" || die "mktemp failed"
    printf 'Authorization: Bearer %s\n' "$(tr -d '\n' < "${CF_API_TOKEN_FILE}")" > "${CF_HDR_FILE}"
}
cleanup() { [ -n "${CF_HDR_FILE}" ] && rm -f "${CF_HDR_FILE}" 2>/dev/null; return 0; }
trap cleanup EXIT

# ── Actions ──────────────────────────────────────────────────────────────────────
action_list() {
    printf '%sGo-live providers%s (%s):\n' "${C_BLD}" "${C_RST}" "${CATALOG}"
    local p
    while IFS= read -r p; do
        printf '  %s%-18s%s %s\n' "${C_CYN}" "${p}" "${C_RST}" "$(cat_get "${p}" title)"
    done < <(cat_sections)
}

action_info() {
    require_provider
    printf '%s[%s]%s %s\n' "${C_BLD}" "${PROVIDER}" "${C_RST}" "$(cat_get "${PROVIDER}" title)"
    printf '  model:    %s\n' "$(cat_get "${PROVIDER}" model)"
    printf '  summary:  %s\n' "$(cat_get "${PROVIDER}" summary)"
    printf '  inputs:   %s\n' "$(cat_get "${PROVIDER}" inputs)"
    printf '  optional: %s\n' "$(cat_get "${PROVIDER}" optional)"
    local td; td="$(cat_get "${PROVIDER}" token_dest)"
    [ -n "${td}" ] && printf '  token ->  %s/%s (gitignored)\n' "${KEYS_DIR}" "${td}"
    printf '  emits:    %s\n' "$(cat_get "${PROVIDER}" emits)"
    printf '  verify:   %s\n' "$(cat_get "${PROVIDER}" verify)"
    local n
    while IFS= read -r n; do [ -n "${n}" ] && printf '  note:     %s\n' "${n}"; done \
        < <(cat_get_all "${PROVIDER}" note)
}

action_links() {
    require_provider
    local row url label
    printf '%sDeep links — %s%s\n' "${C_BLD}" "${PROVIDER}" "${C_RST}"
    while IFS= read -r row; do
        [ -n "${row}" ] || continue
        url="${row%% *}"; label="${row#* }"
        printf '  %s%s%s\n      %s\n' "${C_CYN}" "${label}" "${C_RST}" "${url}"
        if [ "${DO_OPEN}" = 1 ]; then
            if have xdg-open; then xdg-open "${url}" >/dev/null 2>&1 & disown
            else warn "xdg-open not available — open the URL by hand"; fi
        fi
    done < <(cat_get_all "${PROVIDER}" link)
}

# record_target -> echoes "TYPE VALUE" for the record set (CNAME to the tunnel
# when a tunnel id is in play, A to --record-ip otherwise, placeholder last).
record_target() {
    if [ -n "${TUNNEL_ID}" ]; then printf 'CNAME %s.cfargotunnel.com' "${TUNNEL_ID}"
    elif [ "${PROVIDER}" = cloudflare-tunnel ]; then printf 'CNAME <TUNNEL-ID>.cfargotunnel.com'
    elif [ -n "${RECORD_IP}" ]; then
        case "${RECORD_IP}" in *:*) printf 'AAAA %s' "${RECORD_IP}" ;; *) printf 'A %s' "${RECORD_IP}" ;; esac
    else printf 'A <PUBLIC-IP>'
    fi
}

emit_records_csv() {
    local out="${OUT_DIR}/records.csv" tgt type val fqdn
    tgt="$(record_target)"; type="${tgt%% *}"; val="${tgt#* }"
    {
        echo "# ${DOMAIN} go-live record set — paste into your DNS provider (see --links)."
        echo "type,name,content,ttl,proxied"
        while IFS= read -r fqdn; do
            printf '%s,%s,%s,300,%s\n' "${type}" "${fqdn}" "${val}" \
                "$([ "${type}" = CNAME ] && echo true || echo false)"
        done < <(golive_hosts)
    } > "${out}" || die "cannot write ${out}"
    say "record set -> ${out}"
}

emit_zone_file() {
    local out="${OUT_DIR}/zone.db" tgt type val fqdn
    tgt="$(record_target)"; type="${tgt%% *}"; val="${tgt#* }"
    [ "${type}" = CNAME ] && val="${val}."
    {
        echo "; ${DOMAIN} go-live zone fragment (BIND syntax) — importable at most registrars."
        echo "\$TTL 300"
        while IFS= read -r fqdn; do
            printf '%-28s IN %-6s %s\n' "${fqdn}." "${type}" "${val}"
        done < <(golive_hosts)
    } > "${out}" || die "cannot write ${out}"
    say "zone fragment -> ${out}"
}

emit_ddns_config() {
    local upd="${OUT_DIR}/ddns-update.sh" cron="${OUT_DIR}/ddns.cron"
    local tokdest="${KEYS_DIR}/$(cat_get "${PROVIDER}" token_dest)"
    local fqdn
    case "${DDNS_SERVICE}" in
        duckdns)    fqdn="${DDNS_SUBDOMAIN}.duckdns.org" ;;
        cloudflare) fqdn="${DDNS_SUBDOMAIN}.${DOMAIN}" ;;
        *) die "--ddns-service must be duckdns or cloudflare" ;;
    esac
    cat > "${upd}" <<UPDATER || die "cannot write ${upd}"
#!/usr/bin/env bash
# ddns-update.sh — emitted by go-live.sh --provider ddns (service: ${DDNS_SERVICE}).
# Re-points ${fqdn} at this host's current public IP. The token is read from the
# keys-layout file at RUNTIME (never baked into this script, argv, or cron mail).
set -uo pipefail
SERVICE="${DDNS_SERVICE}"
SUBDOMAIN="${DDNS_SUBDOMAIN}"
DOMAIN="${DOMAIN}"
TOKEN_FILE="\${DDNS_TOKEN_FILE:-${tokdest}}"
[ -r "\${TOKEN_FILE}" ] || { echo "ddns-update: token file not readable: \${TOKEN_FILE}" >&2; exit 1; }
TOK="\$(tr -d '\n' < "\${TOKEN_FILE}")"
case "\${SERVICE}" in
    duckdns)
        # Empty ip= => DuckDNS uses the request's source address. -K - keeps the
        # token OUT of argv (visible /proc cmdline).
        printf 'url = "https://www.duckdns.org/update?domains=%s&token=%s&ip="\n' "\${SUBDOMAIN}" "\${TOK}" \
            | curl -sS -m 20 -K - ;;
    cloudflare)
        command -v jq >/dev/null 2>&1 || { echo "ddns-update: jq required for cloudflare" >&2; exit 1; }
        HDR="\$(umask 077 && mktemp)"; trap 'rm -f "\${HDR}"' EXIT
        printf 'Authorization: Bearer %s\n' "\${TOK}" > "\${HDR}"
        IP="\$(curl -sS -m 20 https://api.ipify.org)" || exit 1
        ZID="\$(curl -sS -m 20 -H @"\${HDR}" "https://api.cloudflare.com/client/v4/zones?name=\${DOMAIN}" | jq -r '.result[0].id // empty')"
        [ -n "\${ZID}" ] || { echo "ddns-update: no Cloudflare zone for \${DOMAIN}" >&2; exit 1; }
        FQDN="\${SUBDOMAIN}.\${DOMAIN}"
        RID="\$(curl -sS -m 20 -H @"\${HDR}" "https://api.cloudflare.com/client/v4/zones/\${ZID}/dns_records?type=A&name=\${FQDN}" | jq -r '.result[0].id // empty')"
        BODY="\$(jq -nc --arg n "\${FQDN}" --arg ip "\${IP}" '{type:"A",name:\$n,content:\$ip,ttl:300,proxied:false}')"
        if [ -n "\${RID}" ]; then
            curl -sS -m 20 -X PUT  -H @"\${HDR}" -H 'Content-Type: application/json' -d "\${BODY}" \
                "https://api.cloudflare.com/client/v4/zones/\${ZID}/dns_records/\${RID}" >/dev/null
        else
            curl -sS -m 20 -X POST -H @"\${HDR}" -H 'Content-Type: application/json' -d "\${BODY}" \
                "https://api.cloudflare.com/client/v4/zones/\${ZID}/dns_records" >/dev/null
        fi ;;
esac
UPDATER
    chmod 755 "${upd}" 2>/dev/null || true
    cat > "${cron}" <<CRON || die "cannot write ${cron}"
# ${fqdn} DDNS refresh — install as /etc/cron.d/snapdragon-ddns (with
# ddns-update.sh at /usr/local/sbin/snapdragon-ddns-update). 5-minute floor,
# mirroring the snapdragon-*-reconcile cron convention.
*/5 * * * * root /usr/local/sbin/snapdragon-ddns-update >/dev/null 2>&1
CRON
    say "DDNS updater -> ${upd}"
    say "cron snippet -> ${cron}"
}

emit_checklist() {
    local out="${OUT_DIR}/checklist.txt" row n fqdn
    {
        echo "GO-LIVE CHECKLIST — ${DOMAIN} via ${PROVIDER}"
        echo "generated: $(date -u '+%Y-%m-%dT%H:%M:%SZ') (go-live.sh v1)"
        echo
        echo "$(cat_get "${PROVIDER}" summary)"
        echo
        echo "Hostnames (autofilled from the baked cluster domain set):"
        while IFS= read -r fqdn; do echo "  - ${fqdn}"; done < <(golive_hosts)
        echo
        echo "Provider pages (exact deep links):"
        while IFS= read -r row; do
            [ -n "${row}" ] && printf '  - %s\n      %s\n' "${row#* }" "${row%% *}"
        done < <(cat_get_all "${PROVIDER}" link)
        echo
        echo "Notes:"
        while IFS= read -r n; do [ -n "${n}" ] && echo "  * ${n}"; done \
            < <(cat_get_all "${PROVIDER}" note)
        echo
        echo "Then, ON THE DEVICE:"
        echo "  1. go-live.sh --domain ${DOMAIN} --verify      # probe DNS/HTTP before flipping"
        echo "  2. go-live.sh --domain ${DOMAIN} --flip        # writes ${GO_LIVE_MARKER} (typed confirm)"
        echo "     snapdragon-firewall-reconcile converges the posture within 60s — no reboot."
        echo "  3. Rollback any time: go-live.sh --rollback    # deletes the marker"
    } > "${out}" || die "cannot write ${out}"
    say "checklist -> ${out}"
}

action_emit() {
    require_provider; require_domain
    local emits inputs td
    emits="$(cat_get "${PROVIDER}" emits)"
    inputs="$(cat_get "${PROVIDER}" inputs)"
    td="$(cat_get "${PROVIDER}" token_dest)"
    case " ${inputs} " in *' subdomain '*)
        [ -n "${DDNS_SUBDOMAIN}" ] || die "provider '${PROVIDER}' needs --ddns-subdomain" ;;
    esac
    case " ${inputs} " in *' record-ip '*)
        [ -n "${RECORD_IP}" ] || [ -n "${TUNNEL_ID}" ] \
            || die "provider '${PROVIDER}' needs --record-ip (or --tunnel-id for a CNAME set)" ;;
    esac
    if [ "${DRY_RUN}" = 1 ]; then
        say "[dry-run] would emit '${emits}' for ${PROVIDER} into ${OUT_DIR}"
        [ -n "${td}" ] && say "[dry-run] would store the token -> ${KEYS_DIR}/${td}"
        return 0
    fi
    mkdir -p "${OUT_DIR}" || die "cannot create ${OUT_DIR}"
    # Secret first (fail before writing partial artifacts if the token is missing).
    if [ -n "${td}" ]; then
        case " ${inputs} " in *' token '*)
            read_token "${PROVIDER} token"
            store_token "${td}" ;;
        esac
    fi
    local a
    for a in ${emits}; do
        case "${a}" in
            checklist)   emit_checklist ;;
            records-csv) emit_records_csv ;;
            zone-file)   emit_zone_file ;;
            ddns-config) emit_ddns_config ;;
            *) warn "unknown artifact '${a}' in catalog — skipped" ;;
        esac
    done
    [ "${DO_CREATE_DNS}" = 1 ] && action_create_dns
    say "emit done — artifacts in ${OUT_DIR}"
}

# The ONE optional thin API driver v1 allows beyond DDNS: create the tunnel
# CNAMEs via the Cloudflare API (token from --cf-api-token-file, never argv).
action_create_dns() {
    require_domain
    [ -n "${TUNNEL_ID}" ] || die "--create-dns needs --tunnel-id (the CNAME target is <tunnel-id>.cfargotunnel.com)"
    have curl || die "--create-dns needs curl"
    have jq   || die "--create-dns needs jq"
    [ "${DRY_RUN}" = 1 ] && { say "[dry-run] would create CNAMEs -> ${TUNNEL_ID}.cfargotunnel.com for: $(golive_hosts | tr '\n' ' ')"; return 0; }
    cf_auth_header
    local zid fqdn rid body target="${TUNNEL_ID}.cfargotunnel.com"
    zid="$(curl -sS -m 20 -H @"${CF_HDR_FILE}" \
        "https://api.cloudflare.com/client/v4/zones?name=${DOMAIN}" | jq -r '.result[0].id // empty')"
    [ -n "${zid}" ] || die "no Cloudflare zone found for ${DOMAIN} (is the domain on this account?)"
    while IFS= read -r fqdn; do
        rid="$(curl -sS -m 20 -H @"${CF_HDR_FILE}" \
            "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records?type=CNAME&name=${fqdn}" \
            | jq -r '.result[0].id // empty')"
        body="$(jq -nc --arg n "${fqdn}" --arg t "${target}" \
            '{type:"CNAME",name:$n,content:$t,ttl:1,proxied:true}')"
        if [ -n "${rid}" ]; then
            curl -sS -m 20 -X PUT  -H @"${CF_HDR_FILE}" -H 'Content-Type: application/json' \
                -d "${body}" "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records/${rid}" \
                >/dev/null 2>&1 && say "updated CNAME ${fqdn} -> ${target}" \
                || warn "failed to update CNAME ${fqdn}"
        else
            curl -sS -m 20 -X POST -H @"${CF_HDR_FILE}" -H 'Content-Type: application/json' \
                -d "${body}" "https://api.cloudflare.com/client/v4/zones/${zid}/dns_records" \
                >/dev/null 2>&1 && say "created CNAME ${fqdn} -> ${target}" \
                || warn "failed to create CNAME ${fqdn}"
        fi
    done < <(golive_hosts | grep -v '^\*')   # the wildcard is dashboard-only on some plans
    warn "wildcard *.${DOMAIN} not auto-created — add it in the dashboard if your plan supports proxied wildcards"
}

# ── Verify — probe BEFORE flipping (design step 5). Non-destructive. ────────────
VERIFY_FAILS=0
probe_dns() {
    local fqdn ok
    for fqdn in "${DOMAIN}" "api.${DOMAIN}"; do
        ok=""
        if have getent; then getent hosts "${fqdn}" >/dev/null 2>&1 && ok=1
        elif have host;  then host -W 5 "${fqdn}" >/dev/null 2>&1 && ok=1
        fi
        if [ -n "${ok}" ]; then say "dns: ${fqdn} resolves"
        else warn "dns: ${fqdn} does NOT resolve yet"; VERIFY_FAILS=$((VERIFY_FAILS+1)); fi
    done
}
probe_http() {
    have curl || { warn "http: curl absent — skipping"; return 0; }
    local code
    code="$(curl -skI -m 10 -o /dev/null -w '%{http_code}' "https://${DOMAIN}/" 2>/dev/null)"
    if [ -n "${code}" ] && [ "${code}" != 000 ]; then say "http: https://${DOMAIN}/ answered (HTTP ${code})"
    else warn "http: https://${DOMAIN}/ not reachable yet"; VERIFY_FAILS=$((VERIFY_FAILS+1)); fi
}
probe_tunnel() {
    if have kubectl && kubectl -n devops get deploy cloudflared >/dev/null 2>&1; then
        local ready
        ready="$(kubectl -n devops get deploy cloudflared -o jsonpath='{.status.readyReplicas}' 2>/dev/null)"
        if [ "${ready:-0}" -ge 1 ] 2>/dev/null; then say "tunnel: cloudflared deployment ready (${ready} replica)"
        else warn "tunnel: cloudflared deployment present but NOT ready (token missing / creds not provisioned?)"; VERIFY_FAILS=$((VERIFY_FAILS+1)); fi
    else
        warn "tunnel: kubectl/cloudflared not visible from here — verify on the cluster node"
    fi
}
probe_ddns() {
    [ -n "${DDNS_SUBDOMAIN}" ] || { warn "ddns: --ddns-subdomain unset — skipping the live update probe"; return 0; }
    local upd="${OUT_DIR}/ddns-update.sh"
    if [ -x "${upd}" ]; then
        if "${upd}" >/dev/null 2>&1; then say "ddns: live update via ${upd} succeeded"
        else warn "ddns: live update via ${upd} FAILED"; VERIFY_FAILS=$((VERIFY_FAILS+1)); fi
    else
        warn "ddns: no emitted updater at ${upd} — run --emit first"; VERIFY_FAILS=$((VERIFY_FAILS+1))
    fi
}
probe_funnel() {
    if have tailscale; then
        if tailscale funnel status >/dev/null 2>&1; then say "funnel: tailscale funnel status OK"
        else warn "funnel: 'tailscale funnel status' failed (Funnel not enabled for this node/tailnet?)"; VERIFY_FAILS=$((VERIFY_FAILS+1)); fi
    else
        warn "funnel: tailscale CLI not present — verify on the node itself"
    fi
}
action_verify() {
    require_domain
    local probes="dns http" p
    [ -n "${PROVIDER}" ] && probes="$(cat_get "${PROVIDER}" verify)"
    say "verify (${probes}) for ${DOMAIN}"
    for p in ${probes}; do
        case "${p}" in
            dns) probe_dns ;; http) probe_http ;; tunnel) probe_tunnel ;;
            ddns) probe_ddns ;; funnel) probe_funnel ;;
            *) warn "unknown probe '${p}' in catalog — skipped" ;;
        esac
    done
    if [ "${VERIFY_FAILS}" -gt 0 ]; then
        warn "verify finished with ${VERIFY_FAILS} failing probe(s)"
        return 1
    fi
    say "verify passed"
    return 0
}

# ── Flip / rollback — the ONLY posture writes this script performs. The
# enforcement itself lives in snapdragon-firewall-reconcile (60s cron) +
# bootstrap.sh; we only write the marker they already watch. ───────────────────
require_device_root() {
    [ "${DRY_RUN}" = 1 ] && return 0
    [ "$(id -u)" = 0 ] || die "writing under /etc/snapdragon needs root (re-run with sudo)"
    [ -d "$(dirname "${GO_LIVE_MARKER}")" ] \
        || die "$(dirname "${GO_LIVE_MARKER}") does not exist — this does not look like a provisioned Snapdragon host"
}
action_flip() {
    require_domain
    require_device_root
    if [ -e "${GO_LIVE_MARKER}" ]; then
        say "already live: ${GO_LIVE_MARKER} present — nothing to do (use --rollback to go internal)"
        return 0
    fi
    if [ "${FORCE}" = 1 ]; then
        warn "--force: skipping the pre-flip verify gate"
    else
        action_verify || die "verify failed — fix the edge first, or re-run with --force (the typed confirm still applies)"
    fi
    # ── HUMAN CONFIRM — the security boundary. No bypass flag exists, by design
    # (unattended auto-go-live is a v1 non-goal). ──────────────────────────────
    [ "${DRY_RUN}" = 1 ] && { say "[dry-run] would prompt for the typed confirm, then write ${GO_LIVE_MARKER}"; return 0; }
    [ -t 0 ] || die "refusing to flip without an interactive terminal — unattended go-live is deliberately unsupported"
    printf '%sABOUT TO GO PUBLIC%s: %s will accept public 80/443 within 60s of the flip.\n' \
        "${C_BLD}${C_RED}" "${C_RST}" "${DOMAIN}" >&2
    printf 'Type the domain (%s) to confirm: ' "${DOMAIN}" >&2
    local ans; IFS= read -r ans </dev/tty || ans=""
    [ "${ans}" = "${DOMAIN}" ] || die "confirmation mismatch — NOT flipping"
    {
        echo "# go-live marker — presence flips the release posture to PUBLIC"
        echo "# (read by snapdragon-firewall-reconcile + bootstrap.sh; content informational)."
        echo "# Rollback: delete this file (go-live.sh --rollback); reconcile reverts within 60s."
        echo "domain=${DOMAIN}"
        echo "provider=${PROVIDER:-unspecified}"
        echo "flipped_at=$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
    } > "${GO_LIVE_MARKER}" || die "cannot write ${GO_LIVE_MARKER}"
    say "marker written: ${GO_LIVE_MARKER} — snapdragon-firewall-reconcile converges within 60s (no reboot)"
    if [ "${DO_PERSIST}" = 1 ]; then
        printf 'public\n' > "${RELEASE_STATE_FILE}" \
            && say "persisted: ${RELEASE_STATE_FILE}=public (survives marker deletion — rollback needs --rollback --persist)" \
            || warn "could not write ${RELEASE_STATE_FILE} — posture still flips via the marker"
    fi
}
action_rollback() {
    require_device_root
    [ "${DRY_RUN}" = 1 ] && { say "[dry-run] would delete ${GO_LIVE_MARKER}$([ "${DO_PERSIST}" = 1 ] && echo " and set release-state=internal")"; return 0; }
    if [ -e "${GO_LIVE_MARKER}" ]; then
        rm -f "${GO_LIVE_MARKER}" || die "cannot delete ${GO_LIVE_MARKER}"
        say "marker deleted — snapdragon-firewall-reconcile reverts to INTERNAL within 60s"
    else
        say "no marker at ${GO_LIVE_MARKER} — nothing to roll back"
    fi
    if [ "${DO_PERSIST}" = 1 ]; then
        printf 'internal\n' > "${RELEASE_STATE_FILE}" \
            && say "persisted: ${RELEASE_STATE_FILE}=internal" \
            || warn "could not write ${RELEASE_STATE_FILE}"
    elif [ -r "${RELEASE_STATE_FILE}" ] && [ "$(cat "${RELEASE_STATE_FILE}" 2>/dev/null)" = public ]; then
        warn "${RELEASE_STATE_FILE} is still 'public' — the device stays PUBLIC despite the deleted marker (use --rollback --persist)"
    fi
}
action_status() {
    # READ-ONLY report. The authoritative posture decision is
    # snapdragon-firewall-reconcile's — this mirrors its two inputs for display.
    local rs="internal (default — no file)" marker="absent"
    [ -r "${RELEASE_STATE_FILE}" ] && rs="$(cat "${RELEASE_STATE_FILE}" 2>/dev/null)"
    [ -e "${GO_LIVE_MARKER}" ] && marker="present"
    printf '%sGo-live status%s\n' "${C_BLD}" "${C_RST}"
    printf '  release-state: %s  (%s)\n' "${rs}" "${RELEASE_STATE_FILE}"
    printf '  go-live marker: %s  (%s)\n' "${marker}" "${GO_LIVE_MARKER}"
    [ -n "${DOMAIN}" ] && printf '  domain: %s\n' "${DOMAIN}"
    if [ "${rs}" = public ] || [ "${marker}" = present ]; then
        printf '  posture: %sPUBLIC%s (as enforced by snapdragon-firewall-reconcile)\n' "${C_RED}" "${C_RST}"
    else
        printf '  posture: %sINTERNAL%s (tailnet-only 80/443; the safe default)\n' "${C_GRN}" "${C_RST}"
    fi
}

# ── Dispatch (multiple actions compose in a sane order) ─────────────────────────
RAN=0
[ "${DO_LIST}" = 1 ]    && { action_list; RAN=1; }
[ "${DO_INFO}" = 1 ]    && { action_info; RAN=1; }
[ "${DO_LINKS}" = 1 ]   && { action_links; RAN=1; }
[ "${DO_EMIT}" = 1 ]    && { action_emit; RAN=1; }
if [ "${DO_CREATE_DNS}" = 1 ] && [ "${DO_EMIT}" = 0 ]; then action_create_dns; RAN=1; fi
if [ "${DO_VERIFY}" = 1 ] && [ "${DO_FLIP}" = 0 ]; then
    action_verify; VERIFY_RC=$?; RAN=1
else
    VERIFY_RC=0
fi
[ "${DO_FLIP}" = 1 ]     && { action_flip; RAN=1; }
[ "${DO_ROLLBACK}" = 1 ] && { action_rollback; RAN=1; }
[ "${DO_STATUS}" = 1 ]   && { action_status; RAN=1; }
[ "${RAN}" = 0 ] && { action_status; printf '\n' >&2; usage >&2; }
exit "${VERIFY_RC}"
