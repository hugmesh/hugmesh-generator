#!/usr/bin/env bash
# test-domain-golive-flag.sh — pins the "Go live when ready" image flag
# (hugmesh-generator#1201):
#
#     --domain-go-live <domain>=<provider>        (repeatable)
#
# on the two builders that bake the go-live set (rpi5, x86). Every check EXECUTES the
# builder with --print-plan (the real argument loop and validation, no build step, no
# root, no network). Pinned:
#   A. no flag -> no PLAN_DOMAIN_GO_LIVE line (an image without the flag is unchanged);
#   B. valid flags are threaded, in order, as PLAN_DOMAIN_GO_LIVE=<d>:<p>,...;
#   C. every malformed value is REFUSED with a --domain-go-live message and exit 1:
#      unknown provider, tor-onion, no '=', single-label name, uppercase, shell
#      syntax in the name, the same domain twice, a missing value;
#   D. a client/desktop role refuses the flag;
#   E. --help documents it; the bake call, the agent, its init script and cron are
#      installed by the builder, and the agent is linked into the default runlevel.
# And once: the lib's provider list equals the go-live registry minus tor-onion and
# the Studio's GO_LIVE_AT_READY_PROVIDERS; the lib's bake writes the file and removes
# a stale one; provision.sh installs KEYS/go-live/<domain>.token 0600.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_domain-golive-lib.sh"
REG="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh"
P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

SCR="$(mktemp -d "${TMPDIR:-/tmp}/domain-golive-flag.XXXXXX")" || { echo "  FAIL no scratch dir"; exit 1; }
trap 'rm -rf "${SCR}"' EXIT
WD="${SCR}/work"; mkdir -p "${SCR}/cwd"

norm() { sed -e 's/\x1b\[[0-9;]*m//g'; }
run() {
    local b="$1"; shift
    OUT="$(cd "${SCR}/cwd" && timeout 120 bash "${b}" -w "${WD}" "$@" 2>&1)"
    RC=$?
    printf '%s\n' "${OUT}" | norm > "${SCR}/out.txt"
}
strip_comments() { sed -e 's/^[[:space:]]*#.*$//' -e 's/[[:space:]]#.*$//' "$1"; }

echo "== --domain-go-live on the go-live builders (#1201) =="
declare -A NODE_ARGS=( [rpi5]="--role backend" [x86-host]="--role backend" )
declare -A CLIENT_ARGS=( [rpi5]="--role desktop" [x86-host]="--role laptop" )

for n in rpi5 x86-host; do
    b="${REPO}/build-${n}-stage4.sh"
    [ -f "${b}" ] || { bad "${n}: builder missing"; continue; }
    # shellcheck disable=SC2206
    X=( ${NODE_ARGS[$n]} ); C=( ${CLIENT_ARGS[$n]} )

    run "${b}" "${X[@]}" --print-plan
    if [ "${RC}" -ne 0 ]; then
        bad "${n}: no-flag --print-plan failed (rc=${RC}): $(tail -1 "${SCR}/out.txt")"; continue
    fi
    grep -q '^PLAN_DOMAIN_GO_LIVE=' "${SCR}/out.txt" && bad "${n}: A no flag still prints PLAN_DOMAIN_GO_LIVE" \
        || ok "${n}: A no flag -> no PLAN_DOMAIN_GO_LIVE line"

    run "${b}" "${X[@]}" --domain-go-live a.test=byo-domain --domain-go-live shop.b.test=cloudflare-tunnel --print-plan
    if [ "${RC}" -eq 0 ] && grep -qx 'PLAN_DOMAIN_GO_LIVE=a.test:byo-domain,shop.b.test:cloudflare-tunnel' "${SCR}/out.txt"; then
        ok "${n}: B two domains threaded in order"
    else
        bad "${n}: B not threaded (rc=${RC}): $(grep -m1 'PLAN_DOMAIN_GO_LIVE\|ERROR' "${SCR}/out.txt" || tail -1 "${SCR}/out.txt")"
    fi

    refuse() {  # <label> <fragment> <args...>
        local label="$1" frag="$2"; shift 2
        run "${b}" "${X[@]}" "$@" --print-plan
        if [ "${RC}" -eq 1 ] && grep -q -- "--domain-go-live.*${frag}" "${SCR}/out.txt"; then
            ok "${n}: C refuses ${label}"
        else
            bad "${n}: C did NOT refuse ${label} (rc=${RC}): $(grep -m1 'ERROR\|PLAN_DOMAIN_GO_LIVE' "${SCR}/out.txt" || tail -1 "${SCR}/out.txt")"
        fi
    }
    refuse "an unknown provider"       "provider must be" --domain-go-live a.test=bogus
    refuse "tor-onion"                 "needs no public flip" --domain-go-live a.test=tor-onion
    refuse "a value with no '='"       "no '='"            --domain-go-live a.test
    refuse "a single-label name"       "not a public DNS"  --domain-go-live localhost=byo-domain
    refuse "an uppercase name"         "not a public DNS"  --domain-go-live A.TEST=byo-domain
    refuse "shell syntax in the name"  "not a public DNS"  --domain-go-live 'a.test;x=byo-domain'
    refuse "the same domain twice"     "twice"             --domain-go-live a.test=byo-domain --domain-go-live a.test=duckdns
    refuse "a missing value"           "needs a value"     --domain-go-live ""

    run "${b}" "${C[@]}" --domain-go-live a.test=byo-domain --print-plan
    if [ "${RC}" -eq 1 ] && grep -q -- '--domain-go-live is for mesh node images' "${SCR}/out.txt"; then
        ok "${n}: D client role (${C[*]}) refuses the flag"
    else
        bad "${n}: D client role accepted the flag (rc=${RC}): $(tail -1 "${SCR}/out.txt")"
    fi

    run "${b}" --help
    grep -q -- '--domain-go-live' "${SCR}/out.txt" && ok "${n}: E --help documents --domain-go-live" \
        || bad "${n}: E --help does not document --domain-go-live"
    code="$(strip_comments "${b}")"
    for needle in 'domain_golive_bake "${SYSROOT}/etc/hugmesh"' \
                  'usr/sbin/hugmesh-go-live-at-ready' 'etc/init.d/hugmesh-go-live-at-ready' \
                  'etc/cron.d/hugmesh-go-live-at-ready'; do
        grep -qF -- "${needle}" <<< "${code}" && ok "${n}: E installs ${needle##*/}" \
            || bad "${n}: E missing ${needle}"
    done
    grep -qE 'hugmesh-go-live-reconcile hugmesh-go-live-at-ready' <<< "${code}" \
        && ok "${n}: E hugmesh-go-live-at-ready is linked beside hugmesh-go-live-reconcile" \
        || bad "${n}: E hugmesh-go-live-at-ready is not in the runlevel list"
done

echo "== the vocabulary, the bake, the token install =="
lib_list="$(bash -c ". '${LIB}'; printf '%s\n' \${DOMAIN_GOLIVE_PROVIDERS}" | sort | paste -sd' ' -)"
reg_list="$(bash -c ". '${REG}' >/dev/null 2>&1; printf '%s\n' \"\${GO_LIVE_PROVIDER_IDS[@]}\"" | grep -vx 'tor-onion' | sort | paste -sd' ' -)"
[ -n "${lib_list}" ] && [ "${lib_list}" = "${reg_list}" ] && ok "lib providers = registry minus tor-onion (${lib_list})" \
    || bad "lib providers (${lib_list}) != registry minus tor-onion (${reg_list})"
py_list="$(cd "${REPO}/studio" && python3 -c 'from hugmesh_studio.core.config import GO_LIVE_AT_READY_PROVIDERS as p; print(" ".join(sorted(p)))' 2>/dev/null)"
[ "${py_list}" = "${lib_list}" ] && ok "Studio GO_LIVE_AT_READY_PROVIDERS = lib providers" \
    || bad "Studio GO_LIVE_AT_READY_PROVIDERS (${py_list:-unreadable}) != lib (${lib_list})"

D="${SCR}/etc"; mkdir -p "${D}"
bash -c "err(){ echo \"\$*\" >&2; }; . '${LIB}'; domain_golive_add a.test=duckdns; domain_golive_add b.test=byo-domain; domain_golive_bake '${D}'"
if [ "$(grep -v '^#' "${D}/domain-go-live" 2>/dev/null | paste -sd, -)" = "a.test=duckdns,b.test=byo-domain" ]; then
    ok "bake writes one <domain>=<provider> line per domain"
else
    bad "bake wrote: $(cat "${D}/domain-go-live" 2>/dev/null)"
fi
bash -c "err(){ :; }; . '${LIB}'; domain_golive_bake '${D}'"
[ ! -e "${D}/domain-go-live" ] && ok "bake with no flag removes a stale file" || bad "stale domain-go-live survived"

PV="${REPO}/specs/etc/keys-provision/provision.sh"
fn="$(sed -n '/^provision_go_live_tokens()/,/^}/p' "${PV}")"
if [ -n "${fn}" ] && grep -q 'provision_go_live_tokens' <<< "$(strip_comments "${PV}" | sed -n '/^main()/,$p')"; then
    K="${SCR}/keys"; T="${SCR}/root"; mkdir -p "${K}/go-live" "${T}"
    printf 'tok-a\n' > "${K}/go-live/a.test.token"; printf 'x\n' > "${K}/go-live/BAD NAME.token"
    out="$(BASE="${K}" bash -c "log(){ echo \"\$*\"; }; warn(){ echo \"W \$*\"; }; chown(){ :; }
        $(printf '%s\n' "${fn}" | sed "s|dest=/etc/hugmesh/go-live-tokens|dest=${T}/go-live-tokens|"); provision_go_live_tokens" 2>&1)"
    m="$(stat -c '%a' "${T}/go-live-tokens/a.test.token" 2>/dev/null)"
    [ "${m}" = 600 ] && [ "$(stat -c '%a' "${T}/go-live-tokens")" = 700 ] && ok "provision installs <domain>.token 0600 in a 0700 dir" \
        || bad "token mode ${m:-missing}: ${out}"
    [ ! -e "${T}/go-live-tokens/BAD NAME.token" ] && grep -q 'ignoring' <<< "${out}" && ok "provision ignores a badly named token" \
        || bad "badly named token installed"
    grep -q 'tok-a' <<< "${out}" && bad "provision logged the token value" || ok "provision never logs the token value"
else
    bad "provision_go_live_tokens missing or not called from main()"
fi

echo "domain-golive-flag: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ] || exit 1
