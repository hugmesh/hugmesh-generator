#!/usr/bin/env bash
# tor-domains-live-check.sh — the LIVE proof of per-domain Tor onions on the compose
# stack (hugmesh-generator#582, operator decision 68 = A on #347).
#
# It needs a RUNNING stack that has at least one Tor domain:
#     make stack-up TOR=1 BRAND_B=1 && make stack-seed
#     bash tests/stack/tor-domains-live-check.sh
# It never starts, stops or changes the stack: it reads files, reads the gateway's map
# and environment, and sends HTTP requests (one sign-in per persona).
#
# WHAT IT GRADES. "A Tor domain = its own HiddenService stanza fronting the SAME
# gateway, distinguished by the onion Host": so a Tor domain's onion must answer every
# request exactly as that domain's HTTPS door does, and nothing else may be served.
#   R  the readouts   tests/stack/tor-onion/hostname and <slug>.hostname exist, are v3
#                     onion names, and are all different.
#   M  the host map   as the fe-gateway reads it: the mesh's onion first, as `default`,
#                     then one `<onion>=<tenant>` per Tor domain; and the gateway's
#                     APP_TENANCY_HOSTS_FILE names that file.
#   T  through Tor    https://<onion>/login answers 200 for the mesh's onion and for
#                     each domain's, through the stack's SOCKS5 client.
#   U  unregistered   an onion Host the map does not name is REFUSED: 403 with
#                     X-Route-Denied on a public path. (Before #582 it was served as
#                     the default brand — hugmesh-gateway#38's live baseline.)
#   P  the default persona  signs in on the mesh's onion; its session is good there
#                     (/bff/me 200), good on a Tor domain whose tenant is `default`,
#                     and REFUSED (403 X-Route-Denied) on a Tor domain with its own
#                     tenant — the brand wall, as on that domain's HTTPS door.
#   B  a domain's own persona  (a tenant other than `default`) signs in on that
#                     domain's onion and /bff/me answers 200. The SAME sign-in is tried
#                     on the domain's HTTPS door as a control: if that fails too, the
#                     row is BLOCKED (the brand's own door refuses it — not an onion
#                     finding), not FAIL.
#
# ARGUMENTS  one per Tor domain: <slug>=<tenant>[=<https host>[=<persona>]]
#            default: brandb=brandb=brandb.localtest.me=e2e-tenant2-user
#
# ENV
#   E2E_PASSWORD / E2E_CREDENTIALS_FILE   the personas' password. This script is a
#       CONSUMER of the e2e password contract: it reads, it never generates. Missing ->
#       rows P and B are reported UNCHECKED and the run fails.
#   LIVE_DEFAULT_PERSONA   e2e-user
#   TOR_SOCKS_HOST_PORT    9050    PUBLIC_HTTPS_PORT   8488
#   LIVE_READOUT_DIR       tests/stack/tor-onion
#   LIVE_MAP_CMD / LIVE_GWENV_CMD   how to read the gateway's map / its env value
#       (default: `docker compose ... exec -T hugmesh-fe-gateway ...`). The offline pin
#       (studio/tests/test_domain_services_tor.py) points these and `curl` at stubs.
#
# EXIT  0 every row passed · 1 a row failed or could not be checked · 2 usage/tooling.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
READOUTS="${LIVE_READOUT_DIR:-${REPO}/tests/stack/tor-onion}"
SOCKS="127.0.0.1:${TOR_SOCKS_HOST_PORT:-9050}"
FRONT_PORT="${PUBLIC_HTTPS_PORT:-8488}"
DEFAULT_PERSONA="${LIVE_DEFAULT_PERSONA:-e2e-user}"
MAP_PATH="/tenancy/onion-hosts.map"
COMPOSE=(docker compose -f "${REPO}/tests/stack/compose.local.yaml"
         -f "${REPO}/tests/stack/compose.tor-domains.yaml" --profile tor)
LIVE_MAP_CMD="${LIVE_MAP_CMD:-}"
LIVE_GWENV_CMD="${LIVE_GWENV_CMD:-}"

for b in curl; do
    command -v "${b}" >/dev/null 2>&1 || { echo "FAIL ${b} is required"; exit 2; }
done

[ "$#" -gt 0 ] || set -- "brandb=brandb=brandb.localtest.me=e2e-tenant2-user"
DOMAINS=()
for arg in "$@"; do
    IFS='=' read -r slug tenant host persona <<<"${arg}"
    case "${slug}" in ''|[!a-z0-9]*|*[!a-z0-9-]*) echo "usage: bad slug in '${arg}' (want <slug>=<tenant>[=<https host>[=<persona>]])"; exit 2 ;; esac
    case "${tenant:-}" in ''|[!a-z0-9]*|*[!a-z0-9-]*) echo "usage: bad tenant in '${arg}'"; exit 2 ;; esac
    DOMAINS+=("${slug} ${tenant} ${host:--} ${persona:--}")
done

P=0; F=0; B=0
ok()      { echo "  PASS $*"; P=$((P+1)); }
bad()     { echo "  FAIL $*"; F=$((F+1)); }
blocked() { echo "  BLOCKED $*"; B=$((B+1)); }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/tor-domains-live.XXXXXX")"
trap 'rm -rf "${WORK}"' EXIT

valid_onion() {
    local name="$1" base="${1%.onion}"
    [ "${name}" != "${base}" ] || return 1
    case "${base}" in ''|*[!a-z2-7]*) return 1 ;; esac
    [ "${#base}" -eq 56 ]
}
readout() { tr -d '[:space:]' < "$1" 2>/dev/null || true; }

# code_of OUT-HEADERS-FILE curl-args... -> the status code (000 when curl failed)
code_of() {
    local hdr="$1"; shift
    curl -sk --max-time 60 -o /dev/null -D "${hdr}" -w '%{http_code}' "$@" 2>/dev/null || echo 000
}
denied() { grep -ai '^x-route-denied:' "$1" >/dev/null 2>&1; }
via_tor() { code_of "$1" --socks5-hostname "${SOCKS}" "${@:2}"; }

# ═══════════════════════════ R. the readouts ═══════════════════════════
echo "== R. the readouts =="
PRIMARY="$(readout "${READOUTS}/hostname")"
if valid_onion "${PRIMARY}"; then ok "R the mesh's onion is read out: ${PRIMARY}"
else bad "R ${READOUTS}/hostname holds no v3 onion name ('${PRIMARY}') — is the stack up with TOR=1?"; fi
SEEN=" ${PRIMARY} "
ONIONS=()
for row in "${DOMAINS[@]}"; do
    read -r slug tenant host persona <<<"${row}"
    name="$(readout "${READOUTS}/${slug}.hostname")"
    ONIONS+=("${name}")
    if ! valid_onion "${name}"; then
        bad "R ${slug}: ${READOUTS}/${slug}.hostname holds no v3 onion name ('${name}') — was the stack brought up with this Tor domain?"
    else
        case "${SEEN}" in
            *" ${name} "*) bad "R ${slug}: its onion ${name} is not its own — another door already has it" ;;
            *) ok "R ${slug}: its own onion is read out: ${name}" ;;
        esac
    fi
    SEEN="${SEEN}${name} "
done

# ═══════════════════════════ M. the host map ═══════════════════════════
echo "== M. the gateway's host map =="
if [ -n "${LIVE_MAP_CMD}" ]; then MAP="$(bash -c "${LIVE_MAP_CMD}" 2>/dev/null || true)"
else MAP="$("${COMPOSE[@]}" exec -T hugmesh-fe-gateway cat "${MAP_PATH}" 2>/dev/null || true)"; fi
if [ -n "${LIVE_GWENV_CMD}" ]; then GWENV="$(bash -c "${LIVE_GWENV_CMD}" 2>/dev/null || true)"
else GWENV="$("${COMPOSE[@]}" exec -T hugmesh-fe-gateway printenv APP_TENANCY_HOSTS_FILE 2>/dev/null || true)"; fi
MAP_LINES="$(printf '%s\n' "${MAP}" | sed 's/#.*//' | tr -d ' \t\r' | grep -a . || true)"
[ "$(printf '%s' "${GWENV}" | tr -d '[:space:]')" = "${MAP_PATH}" ] \
    && ok "M the fe-gateway reads ${MAP_PATH} (APP_TENANCY_HOSTS_FILE)" \
    || bad "M the fe-gateway's APP_TENANCY_HOSTS_FILE is '${GWENV}', not ${MAP_PATH} — without it every onion is served as the default brand"
[ "$(printf '%s\n' "${MAP_LINES}" | head -n 1)" = "${PRIMARY}=default" ] && [ -n "${PRIMARY}" ] \
    && ok "M the mesh's onion is registered first, as default" \
    || bad "M the map's first entry is '$(printf '%s\n' "${MAP_LINES}" | head -n 1)', not ${PRIMARY}=default — the mesh's own door would be refused"
i=0
for row in "${DOMAINS[@]}"; do
    read -r slug tenant host persona <<<"${row}"
    name="${ONIONS[$i]}"; i=$((i+1))
    printf '%s\n' "${MAP_LINES}" | grep -axF -- "${name}=${tenant}" >/dev/null && [ -n "${name}" ] \
        && ok "M ${slug}: its onion is registered as ${tenant}" \
        || bad "M ${slug}: the map has no line ${name}=${tenant}"
done
n_want=$(( ${#DOMAINS[@]} + 1 ))
[ "$(printf '%s\n' "${MAP_LINES}" | grep -ac .)" -eq "${n_want}" ] \
    && ok "M the map names exactly these ${n_want} onions" \
    || bad "M the map has $(printf '%s\n' "${MAP_LINES}" | grep -ac .) entries, not ${n_want}"

# ═══════════════════════════ T. through Tor ═══════════════════════════
echo "== T. each onion's login page, through Tor (${SOCKS}) =="
c="$(via_tor "${WORK}/h" "https://${PRIMARY}/login")"
[ "${c}" = 200 ] && ok "T the mesh's onion serves /login (200)" || bad "T the mesh's onion /login -> ${c}"
i=0
for row in "${DOMAINS[@]}"; do
    read -r slug tenant host persona <<<"${row}"
    name="${ONIONS[$i]}"; i=$((i+1))
    c="$(via_tor "${WORK}/h" "https://${name}/login")"
    [ "${c}" = 200 ] && ok "T ${slug}: its onion serves /login (200)" || bad "T ${slug}: its onion /login -> ${c}"
done

# ═══════════════════════════ U. an unregistered onion ═══════════════════════════
echo "== U. an onion the map does not name =="
STRANGER="$(printf 'x%.0s' $(seq 56) | tr x q).onion"
c="$(code_of "${WORK}/u" -H "Host: ${STRANGER}" "https://localhost:${FRONT_PORT}/")"
if [ "${c}" = 403 ] && denied "${WORK}/u"; then ok "U an unregistered onion Host is refused (403 X-Route-Denied)"
else bad "U an unregistered onion Host on a public path -> ${c}$(denied "${WORK}/u" && echo ' X-Route-Denied' || echo ' (no X-Route-Denied)') — want 403 X-Route-Denied; 200 is the pre-#582 behaviour"; fi

# ═══════════════════════════ P / B. the personas ═══════════════════════════
PW="${E2E_PASSWORD:-}"
if [ -z "${PW}" ]; then
    CRED="${E2E_CREDENTIALS_FILE:-${REPO}/.e2e-credentials}"
    [ -r "${CRED}" ] && PW="$(sed -n 's/^E2E_PASSWORD=//p' "${CRED}" | head -n 1)"
fi
# login JAR USER curl-args... -> the status of POST /bff/login (the cookie lands in JAR)
login() {
    local jar="$1" user="$2"; shift 2
    local body
    body="$(printf '{"username":"%s","password":"%s"}' "${user}" "${PW}")"
    curl -sk --max-time 90 -o /dev/null -w '%{http_code}' -c "${jar}" -X POST \
        -H 'content-type: application/json' -d "${body}" "$@" 2>/dev/null || echo 000
}
echo "== P. the default persona (${DEFAULT_PERSONA}) =="
if [ -z "${PW}" ]; then
    bad "P/B UNCHECKED: no E2E_PASSWORD in the environment or in .e2e-credentials (this script reads the password, it never generates one) — run make stack-seed first"
else
    JAR="${WORK}/default.jar"
    c="$(login "${JAR}" "${DEFAULT_PERSONA}" --socks5-hostname "${SOCKS}" "https://${PRIMARY}/bff/login")"
    if [ "${c}" != 200 ]; then
        bad "P ${DEFAULT_PERSONA} could not sign in on the mesh's onion (POST /bff/login -> ${c})"
    else
        ok "P ${DEFAULT_PERSONA} signs in on the mesh's onion"
        c="$(via_tor "${WORK}/h" -b "${JAR}" "https://${PRIMARY}/bff/me")"
        [ "${c}" = 200 ] && ok "P its session is good on the mesh's onion (/bff/me 200)" || bad "P /bff/me on the mesh's onion -> ${c}"
        # The cookie belongs to the mesh's onion host, so it is sent EXPLICITLY to the others.
        COOKIE="$(awk '$6 != "" && $0 !~ /^# / {sub(/^#HttpOnly_/, ""); printf "%s%s=%s", (n++ ? "; " : ""), $6, $7}' "${JAR}")"
        i=0
        for row in "${DOMAINS[@]}"; do
            read -r slug tenant host persona <<<"${row}"
            name="${ONIONS[$i]}"; i=$((i+1))
            c="$(via_tor "${WORK}/p" -H "Cookie: ${COOKIE}" "https://${name}/bff/me")"
            if [ "${tenant}" = default ]; then
                [ "${c}" = 200 ] && ok "P ${slug} (tenant default): the default persona's session is good on its onion" \
                    || bad "P ${slug} (tenant default): /bff/me on its onion -> ${c}, want 200"
            elif [ "${c}" = 403 ] && denied "${WORK}/p"; then
                ok "P ${slug} (tenant ${tenant}): the default persona is REFUSED on its onion (403 X-Route-Denied) — the brand wall"
            else
                bad "P ${slug} (tenant ${tenant}): the default persona on its onion -> ${c}, want 403 X-Route-Denied; 200 means this onion is served as the default brand"
            fi
        done
    fi

    echo "== B. each Tor domain's own persona =="
    i=0
    for row in "${DOMAINS[@]}"; do
        read -r slug tenant host persona <<<"${row}"
        name="${ONIONS[$i]}"; i=$((i+1))
        [ "${tenant}" != default ] || { ok "B ${slug}: tenant default — its personas are the mesh's (row P)"; continue; }
        if [ "${persona}" = - ]; then bad "B ${slug}: UNCHECKED — no persona given for tenant ${tenant} (<slug>=<tenant>=<https host>=<persona>)"; continue; fi
        JAR="${WORK}/${slug}.jar"
        c="$(login "${JAR}" "${persona}" --socks5-hostname "${SOCKS}" "https://${name}/bff/login")"
        if [ "${c}" = 200 ]; then
            m="$(via_tor "${WORK}/h" -b "${JAR}" "https://${name}/bff/me")"
            [ "${m}" = 200 ] && ok "B ${slug}: ${persona} signs in on its onion and /bff/me answers 200" \
                || bad "B ${slug}: ${persona} signed in on its onion but /bff/me -> ${m}"
            continue
        fi
        # the control: the SAME sign-in on the domain's HTTPS door
        if [ "${host}" = - ]; then bad "B ${slug}: ${persona} on its onion -> ${c} (no HTTPS host given to compare with)"; continue; fi
        h="$(login "${WORK}/ctl.jar" "${persona}" -H "Host: ${host}" "https://localhost:${FRONT_PORT}/bff/login")"
        if [ "${h}" = 200 ]; then bad "B ${slug}: ${persona} signs in on ${host} (200) but NOT on its onion (${c}) — the onion is not that domain's door"
        else blocked "B ${slug}: ${persona} cannot sign in on its onion (${c}) NOR on its HTTPS door ${host} (${h}) — the brand's own sign-in is broken on this stack; not an onion finding"; fi
    done
fi

echo
echo "== RESULT: ${P} passed, ${F} failed, ${B} blocked =="
[ "${F}" -eq 0 ] && [ "${B}" -eq 0 ]
