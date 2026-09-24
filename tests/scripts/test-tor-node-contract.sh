#!/usr/bin/env bash
# test-tor-node-contract.sh — the NODE Tor contract, end to end, offline
# (hugmesh-generator#583; decision 70 = B and 68 = A on #347).
#
# WHAT IT PINS, AND HOW (nothing is built, booted or started; no root, no network):
#
#   A. specs/usr/sbin/hugmesh-tor-reconcile — the REAL agent, run against a sandbox
#      root (HUGMESH_TOR_ROOT) with rc-service / tor / id / chown / sleep stubbed on a
#      HERMETIC PATH (a curated tool dir, so the host's own OpenRC can never answer).
#      Decision 70 = B links the distro `tor` service TOO, so the agent must converge a
#      tor that OpenRC may already have started: reload (never restart, never a second
#      start) on a torrc change, nothing when unchanged, start only when stopped,
#      restart only when OpenRC says crashed; verify the candidate torrc BEFORE it
#      replaces the live one; refuse a malformed upstream; render one extra
#      HiddenService stanza per /etc/hugmesh/tor/domains slug and withdraw the export
#      (never the key) of a slug that is removed.
#   B. both stage4 builders — `--print-plan` across node and client roles
#      (PLAN_TOR_ONION), then the REAL gate code executed: rpi5's
#      resolve_stage4_packages() and both builders' runlevel blocks and x86's PKGS
#      line, extracted from the builder and run in a sandbox. Their package/service
#      lists must EQUAL specs/cluster/optional-services.yaml's tor nodePackages /
#      nodeServices (this suite is those fields' consumer), and the agent's default
#      upstream must equal torHiddenServiceUpstream. Static pins keep every tor gate
#      routed through the ONE predicate (_tor_node_selected), so no bare
#      `_opt_selected tor` gate can come back.
#   C. specs/usr/lib/hugmesh/go-live-providers.sh — the tor-onion card states what a
#      node publishes (HTTPS on :443, cluster-domain certificate), never :80/http, and
#      lists per-domain onions.
#   D. tests/qemu/assertions.sh — assert_tor_node_contract() extracted and driven
#      against FIXTURE root trees (the role_topology_test.sh pattern), live half
#      included via ${_R}/proc and a stubbed rc-service. Every leg matches the
#      VERDICT and the message together.
#
# WHAT IT CANNOT PROVE: a booted node. No QEMU guest or Pi has run a tor-selected
# image with this contract; that is awaiting a live run.
#
#   bash tests/scripts/test-tor-node-contract.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
AGENT="${REPO}/specs/usr/sbin/hugmesh-tor-reconcile"
X86="${REPO}/build-x86-host-stage4.sh"
RPI5="${REPO}/build-rpi5-stage4.sh"
REG="${REPO}/specs/cluster/optional-services.yaml"
GOLIVE="${REPO}/specs/usr/lib/hugmesh/go-live-providers.sh"
ASSERTIONS="${REPO}/tests/qemu/assertions.sh"
for f in "${AGENT}" "${X86}" "${RPI5}" "${REG}" "${GOLIVE}" "${ASSERTIONS}"; do
    [ -f "${f}" ] || { echo "FAIL missing ${f}"; exit 1; }
done

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
# has TEXT NEEDLE / hasnt TEXT NEEDLE — fixed-string, drained (no `| grep -q`).
has()   { printf '%s\n' "$1" | grep -F -- "$2" >/dev/null; }
hasnt() { ! has "$1" "$2"; }

HUP_PID=""
# NEVER `kill 0` — that signals the whole process group, this suite included.
WORK="$(mktemp -d)"; trap '[ -n "${HUP_PID}" ] && kill "${HUP_PID}" 2>/dev/null; rm -rf "${WORK}"' EXIT

# ── the registry's tor entry (the contract's declared side) ───────────────────
REG_OUT="$(python3 - "${REG}" <<'PY'
import sys, yaml
d = yaml.safe_load(open(sys.argv[1]))
t = [s for s in d["spec"]["services"] if s["slug"] == "tor"][0]
print(" ".join(t["nodePackages"]))
print(" ".join(t["nodeServices"]))
print(t["torHiddenServiceUpstream"])
PY
)" || { echo "FAIL cannot read the tor entry of ${REG}"; exit 1; }
REG_PKGS="$(sed -n 1p <<<"${REG_OUT}")"
REG_SVCS="$(sed -n 2p <<<"${REG_OUT}")"
REG_UP="$(sed -n 3p <<<"${REG_OUT}")"
WANT_ON="on packages=${REG_PKGS} services=${REG_SVCS}"
echo "== registry: nodePackages='${REG_PKGS}' nodeServices='${REG_SVCS}' upstream='${REG_UP}' =="
[ "${REG_SVCS}" = "tor hugmesh-tor-reconcile" ] \
    && ok "registry: nodeServices is [tor, hugmesh-tor-reconcile] (decision 70 = B: the distro tor service is linked too)" \
    || bad "registry: nodeServices is '${REG_SVCS}', want 'tor hugmesh-tor-reconcile' (decision 70 = B)"

# ═════════════════════════════ A. the reconcile agent ═════════════════════════
echo "== A. hugmesh-tor-reconcile convergence (stubbed OpenRC, hermetic PATH) =="
TOOLS="${WORK}/tools"; mkdir -p "${TOOLS}"
for t in basename cat chmod cmp cp date dirname install mkdir mktemp mv rm sort tr; do
    p="$(command -v "${t}")" || { echo "FAIL host lacks ${t}"; exit 1; }
    ln -s "${p}" "${TOOLS}/${t}"
done
STUB="${WORK}/stub"; mkdir -p "${STUB}"
# rc-service: logs its argv; `status` exits with the code in $STATE_DIR/status,
# `reload` with the one in $STATE_DIR/reload (default 0), everything else 0.
cat > "${STUB}/rc-service" <<'EOF'
#!/bin/bash
echo "$*" >> "${STATE_DIR}/rc.log"
case "$2" in
    status) exit "$(cat "${STATE_DIR}/status" 2>/dev/null || echo 3)" ;;
    reload) exit "$(cat "${STATE_DIR}/reload" 2>/dev/null || echo 0)" ;;
esac
exit 0
EOF
cat > "${STUB}/tor" <<'EOF'
#!/bin/bash
echo "$*" >> "${STATE_DIR}/tor.log"
exit "$(cat "${STATE_DIR}/verify" 2>/dev/null || echo 0)"
EOF
cat > "${STUB}/id" <<'EOF'
#!/bin/bash
[ -f "${STATE_DIR}/no-tor-user" ] && exit 1
exit 0
EOF
printf '#!/bin/bash\nexit 0\n' > "${STUB}/chown"
printf '#!/bin/bash\necho sleep >> "${STATE_DIR}/sleep.log"\nexit 0\n' > "${STUB}/sleep"
chmod +x "${STUB}"/*
NORC="${WORK}/norc"; mkdir -p "${NORC}"   # the same stubs minus rc-service
for t in tor id chown sleep; do ln -s "${STUB}/${t}" "${NORC}/${t}"; done

ONION_A="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa.onion"
ONION_G="gggggggggggggggggggggggggggggggggggggggggggggggggggggggg.onion"
ONION_S="ssssssssssssssssssssssssssssssssssssssssssssssssssssssss.onion"

# fresh_root NAME — a sandbox node root with the primary keypair already minted
# (so the agent never waits) and an empty state dir for the stubs.
fresh_root() {
    R="${WORK}/node-$1"; STATE_DIR="${WORK}/state-$1"
    mkdir -p "${R}/var/lib/tor/hugmesh-onion" "${R}/var/log" "${STATE_DIR}"
    echo "${ONION_A}" > "${R}/var/lib/tor/hugmesh-onion/hostname"
    export STATE_DIR
}
# run_agent [PATHDIR] — the real agent under a hermetic PATH; records its exit code.
run_agent() {
    local pd
    pd="${1:-${STUB}}"
    HUGMESH_TOR_ROOT="${R}" HUGMESH_TOR_WAIT_TRIES=2 STATE_DIR="${STATE_DIR}" \
        PATH="${pd}:${TOOLS}" /bin/bash "${AGENT}" >/dev/null 2>&1
    AGENT_RC=$?
}
rc_log()  { cat "${STATE_DIR}/rc.log" 2>/dev/null; }
torrc()   { cat "${R}/etc/tor/torrc" 2>/dev/null; }
agent_log() { cat "${R}/var/log/hugmesh-tor-reconcile.log" 2>/dev/null; }

# A1 — stopped tor, no torrc yet (first boot): write + start, never restart/reload.
fresh_root a1; echo 3 > "${STATE_DIR}/status"; run_agent
[ "${AGENT_RC}" -eq 0 ] && ok "A1 agent exits 0" || bad "A1 agent exited ${AGENT_RC}"
has "$(torrc)" "HiddenServicePort 443 ${REG_UP}" \
    && ok "A1 torrc publishes HiddenServicePort 443 -> the registry's upstream (${REG_UP})" \
    || { bad "A1 torrc lacks 'HiddenServicePort 443 ${REG_UP}'"; torrc | sed 's/^/      | /'; }
has "$(torrc)" "HiddenServiceDir /var/lib/tor/hugmesh-onion" \
    && ok "A1 torrc paths are the NODE's (the test root never leaks into the torrc)" \
    || bad "A1 torrc HiddenServiceDir is not the node path"
hasnt "$(torrc)" "${R}" && ok "A1 no sandbox prefix inside the torrc" || bad "A1 the sandbox prefix leaked into the torrc"
has "$(rc_log)" "tor start" && ok "A1 stopped tor -> rc-service tor start" || bad "A1 stopped tor was not started (rc.log: $(rc_log | tr '\n' ';'))"
hasnt "$(rc_log)" "restart" && hasnt "$(rc_log)" "reload" \
    && ok "A1 no restart/reload of a stopped tor" || bad "A1 unexpected restart/reload: $(rc_log | tr '\n' ';')"
has "$(cat "${STATE_DIR}/tor.log" 2>/dev/null)" "--verify-config -f ${R}/etc/tor/torrc.hugmesh." \
    && ok "A1 the CANDIDATE file is verified (tor --verify-config -f <candidate>), not the live torrc" \
    || bad "A1 verify did not target the candidate: $(cat "${STATE_DIR}/tor.log" 2>/dev/null)"
[ "$(cat "${R}/var/lib/hugmesh/tor/hostname" 2>/dev/null)" = "${ONION_A}" ] \
    && ok "A1 primary hostname exported to /var/lib/hugmesh/tor/hostname" || bad "A1 primary hostname not exported"
[ ! -e "${STATE_DIR}/sleep.log" ] && ok "A1 no hostname wait when the key is already minted" || bad "A1 slept although the hostname existed"
ls "${R}/etc/tor/" | grep -F 'torrc.hugmesh.' >/dev/null && bad "A1 a candidate torrc was left behind" || ok "A1 no candidate file left behind"

# A2 — the same node again, tor running, nothing changed: a pure no-op.
: > "${STATE_DIR}/rc.log"; echo 0 > "${STATE_DIR}/status"
cp "${R}/etc/tor/torrc" "${WORK}/a2.before"; run_agent
[ "$(rc_log)" = "tor status" ] \
    && ok "A2 running + unchanged torrc -> only 'rc-service tor status' (no start/restart/reload)" \
    || bad "A2 running + unchanged torrc made calls: $(rc_log | tr '\n' ';')"
cmp -s "${WORK}/a2.before" "${R}/etc/tor/torrc" && ok "A2 torrc byte-identical on a re-run" || bad "A2 torrc changed on an idempotent re-run"

# A3 — running tor, upstream override changes the torrc: reload exactly once.
: > "${STATE_DIR}/rc.log"; mkdir -p "${R}/etc/hugmesh/tor"
printf '# staged by the operator\n\n  10.0.0.7:443  \n' > "${R}/etc/hugmesh/tor/upstream"
run_agent
has "$(torrc)" "HiddenServicePort 443 10.0.0.7:443" && ok "A3 upstream override honoured (first non-comment line, whitespace stripped)" \
    || bad "A3 upstream override not in torrc"
[ "$(rc_log | grep -c -F 'tor reload')" -eq 1 ] && ok "A3 running + changed torrc -> exactly one 'rc-service tor reload'" \
    || bad "A3 want one reload: $(rc_log | tr '\n' ';')"
hasnt "$(rc_log)" "restart" && hasnt "$(rc_log)" "tor start" \
    && ok "A3 a running tor is never restarted or started again" || bad "A3 restart/start on a running tor: $(rc_log | tr '\n' ';')"

# A4 — reload refused by OpenRC: fall back to SIGHUP on the pidfile's pid.
fresh_root a4; echo 0 > "${STATE_DIR}/status"; echo 1 > "${STATE_DIR}/reload"
HUP_MARK="${WORK}/a4.hup"
bash -c 'trap "echo got > '"${HUP_MARK}"'; exit 0" HUP; while :; do sleep 0.1; done' &
HUP_PID=$!
mkdir -p "${R}/run/tor"; echo "${HUP_PID}" > "${R}/run/tor/tor.pid"
run_agent
for _i in 1 2 3 4 5 6 7 8 9 10; do [ -e "${HUP_MARK}" ] && break; /bin/sleep 0.1; done
[ -e "${HUP_MARK}" ] && ok "A4 reload refused -> kill -HUP <pidfile pid> reached the daemon" || bad "A4 no SIGHUP fallback"
kill "${HUP_PID}" 2>/dev/null; HUP_PID=""

# A5 — OpenRC says crashed (status 32): restart, nothing else.
fresh_root a5; echo 32 > "${STATE_DIR}/status"; run_agent
has "$(rc_log)" "tor restart" && hasnt "$(rc_log)" "tor start" \
    && ok "A5 crashed tor -> rc-service tor restart (and no plain start)" || bad "A5 crashed: $(rc_log | tr '\n' ';')"

# A6 — candidate fails verification: the live torrc is left untouched, no service call.
fresh_root a6; mkdir -p "${R}/etc/tor"; echo "OLD-WORKING-TORRC" > "${R}/etc/tor/torrc"
echo 0 > "${STATE_DIR}/status"; echo 1 > "${STATE_DIR}/verify"; run_agent
[ "$(torrc)" = "OLD-WORKING-TORRC" ] && ok "A6 a candidate that fails --verify-config never replaces the live torrc" \
    || bad "A6 live torrc was overwritten by an unverified candidate"
hasnt "$(rc_log)" "reload" && hasnt "$(rc_log)" "start" && ok "A6 no reload/start after a failed verify" \
    || bad "A6 service touched after a failed verify: $(rc_log | tr '\n' ';')"
[ "${AGENT_RC}" -eq 0 ] && ok "A6 still exits 0 (fail-soft)" || bad "A6 exit ${AGENT_RC}"

# A7 — malformed upstream lines are refused (written verbatim into the torrc otherwise).
for bogus in '1.2.3.4' 'host:443;HiddenServiceDir' 'host/x:443' 'a:99999999' ':443' 'host:443#x'; do
    fresh_root a7; mkdir -p "${R}/etc/hugmesh/tor"; printf '%s\n' "${bogus}" > "${R}/etc/hugmesh/tor/upstream"
    run_agent
    if has "$(torrc)" "HiddenServicePort 443 ${REG_UP}" && [ "$(torrc | grep -c '^HiddenServicePort')" -eq 1 ]; then
        ok "A7 malformed upstream '${bogus}' refused, default kept"
    else
        bad "A7 malformed upstream '${bogus}' reached the torrc"; torrc | grep '^HiddenService' | sed 's/^/      | /'
    fi
done
fresh_root a7b; mkdir -p "${R}/etc/hugmesh/tor"; echo '[fd00::7]:8443' > "${R}/etc/hugmesh/tor/upstream"; run_agent
has "$(torrc)" "HiddenServicePort 443 [fd00::7]:8443" && ok "A7 a bracketed IPv6 host:port is accepted" || bad "A7 IPv6 upstream refused"

# A8 — per-domain onions (decision 68 = A).
fresh_root a8; echo 0 > "${STATE_DIR}/status"; mkdir -p "${R}/etc/hugmesh/tor"
printf 'games\n# comment\nBad_Slug\n\nshop\ngames\n-x\n' > "${R}/etc/hugmesh/tor/domains"
mkdir -p "${R}/var/lib/tor/hugmesh-onion.d/games" "${R}/var/lib/tor/hugmesh-onion.d/shop"
echo "${ONION_G}" > "${R}/var/lib/tor/hugmesh-onion.d/games/hostname"
echo "${ONION_S}" > "${R}/var/lib/tor/hugmesh-onion.d/shop/hostname"
run_agent
[ "$(torrc | grep -c '^HiddenServiceDir ')" -eq 3 ] && ok "A8 primary + 2 valid, de-duplicated domain stanzas (invalid slugs dropped)" \
    || { bad "A8 want 3 HiddenServiceDir lines"; torrc | grep '^HiddenService' | sed 's/^/      | /'; }
has "$(torrc)" "HiddenServiceDir /var/lib/tor/hugmesh-onion.d/games" && has "$(torrc)" "HiddenServiceDir /var/lib/tor/hugmesh-onion.d/shop" \
    && ok "A8 each domain has its own HiddenServiceDir" || bad "A8 domain HiddenServiceDir missing"
[ "$(torrc | grep -c "^HiddenServicePort 443 ${REG_UP}\$")" -eq 3 ] && ok "A8 every onion fronts the SAME upstream" || bad "A8 domain stanza upstream differs"
hasnt "$(torrc)" "Bad_Slug" && hasnt "$(torrc)" "onion.d/-x" && ok "A8 invalid slugs never reach the torrc" || bad "A8 invalid slug in torrc"
[ "$(cat "${R}/var/lib/hugmesh/tor/games.hostname" 2>/dev/null)" = "${ONION_G}" ] && [ "$(cat "${R}/var/lib/hugmesh/tor/shop.hostname" 2>/dev/null)" = "${ONION_S}" ] \
    && ok "A8 each domain onion exported to <slug>.hostname" || bad "A8 domain hostname exports missing"
[ "$(cat "${R}/var/lib/hugmesh/tor/hostname" 2>/dev/null)" = "${ONION_A}" ] && ok "A8 primary export unchanged by the domain list" || bad "A8 primary export disturbed"
has "$(rc_log)" "tor reload" && ok "A8 adding domain stanzas to a running tor reloads it" || bad "A8 no reload after the domain change"
printf 'games\n' > "${R}/etc/hugmesh/tor/domains"; : > "${STATE_DIR}/rc.log"; run_agent
[ ! -e "${R}/var/lib/hugmesh/tor/shop.hostname" ] && ok "A8 removed domain's export withdrawn" || bad "A8 stale shop.hostname still exported"
[ -s "${R}/var/lib/tor/hugmesh-onion.d/shop/hostname" ] && ok "A8 removed domain's KEY material kept (custody: re-adding restores the same onion)" \
    || bad "A8 the removed domain's key directory was deleted"
[ -e "${R}/var/lib/hugmesh/tor/games.hostname" ] && [ -e "${R}/var/lib/hugmesh/tor/hostname" ] \
    && ok "A8 remaining exports intact" || bad "A8 a kept export was withdrawn"

# A9 — no tor user (net-vpn/tor absent): inert, no torrc, no service call.
fresh_root a9; touch "${STATE_DIR}/no-tor-user"; run_agent
[ ! -e "${R}/etc/tor/torrc" ] && [ -z "$(rc_log)" ] && [ "${AGENT_RC}" -eq 0 ] \
    && ok "A9 no tor user -> inert (no torrc, no rc-service call, exit 0)" || bad "A9 agent acted without a tor user"

# A10 — no OpenRC at all: never exec a daemon; HUP a live pidfile tor on change.
fresh_root a10; run_agent "${NORC}"
has "$(agent_log)" "no OpenRC to start it" && [ ! -e "${STATE_DIR}/rc.log" ] \
    && ok "A10 no OpenRC + no running tor -> left stopped (the agent never starts a daemon itself)" \
    || bad "A10 unexpected: $(agent_log | tail -2 | tr '\n' ';')"
n_other="$(grep -c -v -F -- '--verify-config' "${STATE_DIR}/tor.log" 2>/dev/null)"
[ -s "${STATE_DIR}/tor.log" ] && [ "${n_other:-0}" -eq 0 ] \
    && ok "A10 tor was only ever invoked for --verify-config (never exec'd as a daemon)" || bad "A10 tor invoked outside --verify-config: $(cat "${STATE_DIR}/tor.log" 2>/dev/null)"

# ═════════════════════════════ B. the builders ════════════════════════════════
echo "== B. builders: PLAN_TOR_ONION across roles, then the real gate code =="
plan() {  # BUILDER ARGS... -> prints the plan (stderr folded in; ANSI kept)
    local b
    b="$1"; shift
    ( cd "${REPO}" && "./${b}" "$@" --env test -w "${WORK}/wd" --print-plan ) 2>&1
}
plan_val() { printf '%s\n' "$1" | sed -n "s/^PLAN_$2=//p"; }
leg() {  # LABEL WANT BUILDER ARGS...
    local label want out got
    label="$1"; want="$2"; shift 2
    out="$(plan "$@")"
    got="$(plan_val "${out}" TOR_ONION)"
    if [ "${got}" = "${want}" ]; then ok "B ${label}: PLAN_TOR_ONION=${got}"
    else bad "B ${label}: PLAN_TOR_ONION='${got}', want '${want}'"; printf '%s\n' "${out}" | tail -5 | sed 's/^/      | /'; fi
    LEG_OUT="${out}"
}
leg "x86 backend --optional-services tor"   "${WANT_ON}" build-x86-host-stage4.sh --role backend --optional-services tor
leg "x86 pki --with-tor"                    "${WANT_ON}" build-x86-host-stage4.sh --role pki --with-tor
leg "x86 frontend (tor not selected)"       "off"        build-x86-host-stage4.sh --role frontend
leg "x86 backend --with-tor --exclude-services tor" "off" build-x86-host-stage4.sh --role backend --with-tor --exclude-services tor
for role in desktop laptop standalone-unaffiliated; do
    for sel in "--with-tor" "--optional-services tor"; do
        # shellcheck disable=SC2086
        leg "x86 CLIENT ${role} ${sel}" "off" build-x86-host-stage4.sh --role "${role}" ${sel}
        has "${LEG_OUT}" "tor selected on CLIENT role '${role}' — dropped" \
            && ok "B x86 CLIENT ${role} ${sel}: the drop is WARNED (the check runs after the role is known)" \
            || bad "B x86 CLIENT ${role} ${sel}: no drop warning — the client check is dead again"
    done
done
leg "rpi5 frontend --optional-services tor" "${WANT_ON}" build-rpi5-stage4.sh --role frontend --optional-services tor
leg "rpi5 pki (tor not selected)"           "off"        build-rpi5-stage4.sh --role pki
leg "rpi5 CLIENT desktop --optional-services tor" "off"  build-rpi5-stage4.sh --role desktop --optional-services tor
has "${LEG_OUT}" "tor selected on CLIENT role 'desktop' — dropped" && ok "B rpi5 CLIENT desktop: the drop is warned" || bad "B rpi5 CLIENT desktop: no drop warning"

# ── the builders' own tor definitions, loaded as bash would read them ──
tor_defs() {  # BUILDER -> the three definition lines (arrays + predicate), column 0
    grep -E '^(TOR_NODE_PACKAGES=|TOR_NODE_SERVICES=|_tor_node_selected\(\) \{)' "$1"
}
# shellcheck source=/dev/null
source "${REPO}/scripts/_optional-services-lib.sh"
info() { :; }; warn() { :; }; _rsp_info() { :; }
for B in "${X86}" "${RPI5}"; do
    bn="$(basename "${B}")"
    defs="$(tor_defs "${B}")"
    [ "$(printf '%s\n' "${defs}" | grep -c .)" -eq 3 ] && ok "B ${bn}: exactly one TOR_NODE_PACKAGES / TOR_NODE_SERVICES / _tor_node_selected definition" \
        || { bad "B ${bn}: tor definitions not found exactly once"; printf '%s\n' "${defs}" | sed 's/^/      | /'; }
    eval "${defs}"
    [ "${TOR_NODE_PACKAGES[*]}" = "${REG_PKGS}" ] && ok "B ${bn}: TOR_NODE_PACKAGES == registry nodePackages" || bad "B ${bn}: TOR_NODE_PACKAGES '${TOR_NODE_PACKAGES[*]}' != registry '${REG_PKGS}'"
    [ "${TOR_NODE_SERVICES[*]}" = "${REG_SVCS}" ] && ok "B ${bn}: TOR_NODE_SERVICES == registry nodeServices" || bad "B ${bn}: TOR_NODE_SERVICES '${TOR_NODE_SERVICES[*]}' != registry '${REG_SVCS}'"

    # the runlevel block, executed for real against a sandbox sysroot
    blk="$(sed -n '/^if _tor_node_selected; then$/,/^fi$/p' "${B}")"
    [ -n "${blk}" ] || bad "B ${bn}: runlevel block 'if _tor_node_selected; then … fi' not found"
    for case_ in "false tor" "true tor" "false akkoma"; do
        ROLE_CLIENT="${case_% *}"; OPTIONAL_SERVICES="${case_#* }"
        SYSROOT="${WORK}/sys-${bn}-${ROLE_CLIENT}-${OPTIONAL_SERVICES}"
        mkdir -p "${SYSROOT}/etc/hugmesh/registry"; : > "${SYSROOT}/etc/hugmesh/registry/cron-tor-reconcile"
        SVCS=(); DEFAULT_SVCS=()
        eval "${blk}"
        got="${SVCS[*]}${DEFAULT_SVCS[*]}"
        if [ "${ROLE_CLIENT}" = false ] && [ "${OPTIONAL_SERVICES}" = tor ]; then
            [ "${got}" = "${REG_SVCS}" ] && [ -f "${SYSROOT}/etc/cron.d/hugmesh-tor-reconcile" ] \
                && ok "B ${bn}: node + tor -> runlevel gets '${got}' + the 24h cron" || bad "B ${bn}: node + tor -> runlevel '${got}', cron $( [ -f "${SYSROOT}/etc/cron.d/hugmesh-tor-reconcile" ] && echo yes || echo no)"
        else
            [ -z "${got}" ] && [ ! -e "${SYSROOT}/etc/cron.d/hugmesh-tor-reconcile" ] \
                && ok "B ${bn}: ROLE_CLIENT=${ROLE_CLIENT} OPTIONAL_SERVICES=${OPTIONAL_SERVICES} -> nothing linked" || bad "B ${bn}: ROLE_CLIENT=${ROLE_CLIENT} OPTIONAL_SERVICES=${OPTIONAL_SERVICES} linked '${got}'"
        fi
    done

    # static: every tor gate goes through the ONE predicate (comment lines ignored)
    code="$(grep -v -E '^[[:space:]]*#' "${B}")"
    n_bare="$(printf '%s\n' "${code}" | grep -c -F '_opt_selected tor')"
    [ "${n_bare}" -eq 2 ] && ok "B ${bn}: bare '_opt_selected tor' only in the predicate + the CLIENT drop (no gate bypasses _tor_node_selected)" \
        || { bad "B ${bn}: '_opt_selected tor' appears ${n_bare}x in code (want 2)"; printf '%s\n' "${code}" | grep -n -F '_opt_selected tor' | sed 's/^/      | /'; }
    n_pkg="$(printf '%s\n' "${code}" | grep -E '(PKGS|STAGE4_PACKAGES)\+?=' | grep -c -F 'net-vpn/tor')"
    [ "${n_pkg}" -eq 0 ] && ok "B ${bn}: no package assignment names net-vpn/tor literally (only via TOR_NODE_PACKAGES)" \
        || { bad "B ${bn}: ${n_pkg} package assignment(s) add net-vpn/tor outside TOR_NODE_PACKAGES (bypasses the gate)"; printf '%s\n' "${code}" | grep -E '(PKGS|STAGE4_PACKAGES)\+?=' | grep -n -F 'net-vpn/tor' | sed 's/^/      | /'; }
    n_rl="$(printf '%s\n' "${code}" | grep -E 'SVCS\+=\(' | grep -c -E '(^|[^_])tor([^-_a-z]|$)|hugmesh-tor-reconcile')"
    [ "${n_rl}" -eq 0 ] && ok "B ${bn}: no SVCS+= names tor literally (only via TOR_NODE_SERVICES)" \
        || bad "B ${bn}: ${n_rl} SVCS+= line(s) name tor literally"
done
# the CLIENT drop must run AFTER the role case (the x86 check used to run before it and never fired)
x86_role_ln="$(grep -n -E '^    laptop\|chromebook\)' "${X86}" | head -1 | cut -d: -f1)"
x86_drop_ln="$(grep -n -F 'if ${ROLE_CLIENT} && _opt_selected tor; then' "${X86}" | head -1 | cut -d: -f1)"
[ -n "${x86_role_ln}" ] && [ -n "${x86_drop_ln}" ] && [ "${x86_drop_ln}" -gt "${x86_role_ln}" ] \
    && ok "B x86: the CLIENT drop (line ${x86_drop_ln}) runs after the role case (line ${x86_role_ln})" \
    || bad "B x86: CLIENT drop at '${x86_drop_ln}' is not after the role case at '${x86_role_ln}'"

# x86 PKGS gate: the real line, executed.
eval "$(tor_defs "${X86}")"
pk_line="$(grep -E '^_tor_node_selected && PKGS=' "${X86}")"
[ "$(printf '%s\n' "${pk_line}" | grep -c .)" -eq 1 ] && ok "B x86: exactly one PKGS gate line, guarded by _tor_node_selected" || bad "B x86: PKGS gate line not found exactly once"
for case_ in "false tor:${REG_PKGS}" "true tor:" "false akkoma:"; do
    sel="${case_%%:*}"; want="${case_#*:}"
    ROLE_CLIENT="${sel% *}"; OPTIONAL_SERVICES="${sel#* }"; PKGS=""
    eval "${pk_line}" || true
    got="$(printf '%s' "${PKGS}" | tr -s ' ' | sed 's/^ //')"
    [ "${got}" = "${want}" ] && ok "B x86 PKGS: ROLE_CLIENT=${ROLE_CLIENT} OPTIONAL_SERVICES=${OPTIONAL_SERVICES} -> '${got}'" \
        || bad "B x86 PKGS: ROLE_CLIENT=${ROLE_CLIENT} OPTIONAL_SERVICES=${OPTIONAL_SERVICES} -> '${got}', want '${want}'"
done

# rpi5 package resolver: the real function, executed.
eval "$(tor_defs "${RPI5}")"
eval "$(awk '/^resolve_stage4_packages\(\) \{/{p=1} p{print} p&&/^\}/{exit}' "${RPI5}")"
if declare -F resolve_stage4_packages >/dev/null; then
    SPECS_DIR="${REPO}/specs-rpi5"; BOARD=rpi5; ENCRYPT_ROOT=false
    EXTRA_PACKAGES=""; PACKAGES_ADD=""; PACKAGES_DROP=""
    for case_ in "false tor:yes" "true tor:no" "false akkoma:no"; do
        sel="${case_%%:*}"; want="${case_#*:}"
        ROLE_CLIENT="${sel% *}"; OPTIONAL_SERVICES="${sel#* }"
        set_="$(resolve_stage4_packages quiet 2>/dev/null)"
        if printf '%s\n' "${set_}" | grep -x -F "${REG_PKGS}" >/dev/null; then got=yes; else got=no; fi
        [ "${got}" = "${want}" ] && ok "B rpi5 resolve_stage4_packages: ROLE_CLIENT=${ROLE_CLIENT} OPTIONAL_SERVICES=${OPTIONAL_SERVICES} -> ${REG_PKGS} ${got}" \
            || bad "B rpi5 resolve_stage4_packages: ROLE_CLIENT=${ROLE_CLIENT} OPTIONAL_SERVICES=${OPTIONAL_SERVICES} -> ${REG_PKGS} ${got}, want ${want}"
    done
else
    bad "B rpi5: resolve_stage4_packages() could not be extracted"
fi

# the agent's default upstream IS the registry's
agent_up="$(sed -n 's/^UPSTREAM="\([^"]*\)"$/\1/p' "${AGENT}")"
[ "${agent_up}" = "${REG_UP}" ] && ok "B agent default UPSTREAM (${agent_up}) == registry torHiddenServiceUpstream" \
    || bad "B agent default UPSTREAM '${agent_up}' != registry '${REG_UP}'"

# ═════════════════════════════ C. the Go-Live card ═════════════════════════════
echo "== C. go-live tor-onion card states what a node publishes =="
GL="${WORK}/gl"; mkdir -p "${GL}/exp" "${GL}/out1" "${GL}/out2"
echo "${ONION_A}" > "${GL}/exp/hostname"; echo "${ONION_G}" > "${GL}/exp/games.hostname"
GL_ONION_EXPORT_DIR="${GL}/exp" bash -c 'source "$1"; glp_emit tor-onion "$2"' _ "${GOLIVE}" "${GL}/out1" >/dev/null 2>&1 \
    || bad "C glp_emit tor-onion failed"
ins="$(cat "${GL}/out1/instructions.txt" 2>/dev/null)"
has "${ins}" "Tor Browser -> https://${ONION_A}/" && ok "C card opens https://<onion>/" || bad "C card does not open https://<onion>/"
hasnt "${ins}" "http://${ONION_A}" && ok "C card never offers http://<onion> (the node serves :443 only)" || bad "C card still offers http://<onion>"
has "${ins}" "the onion :443 (HTTPS)" && hasnt "${ins}" "onion :80" && ok "C card maps the onion :443, not :80" || bad "C card port claim wrong"
has "${ins}" "127.0.0.1:443 by default" && ok "C card names the real default upstream" || bad "C card default upstream wrong"
has "${ins}" "CERTIFICATE:" && has "${ins}" "no .onion name is on it" && ok "C card carries the certificate note" || bad "C card lacks the certificate note"
has "${ins}" "curl -skI https://${ONION_A}/" && ok "C VERIFY line uses https + -k" || bad "C VERIFY line wrong"
[ "$(cat "${GL}/out1/onion.txt" 2>/dev/null)" = "${ONION_A}" ] && ok "C onion.txt is the primary address alone (Studio's golive test reads it whole)" || bad "C onion.txt changed shape"
[ "$(cat "${GL}/out1/domain-onions.txt" 2>/dev/null)" = "games ${ONION_G}" ] && ok "C domain-onions.txt lists each Tor domain's onion" || bad "C domain-onions.txt wrong"
has "${ins}" "https://${ONION_G}/" && ok "C card lists the domain onion" || bad "C card omits the domain onion"
rm -f "${GL}/exp/games.hostname"
GL_ONION_EXPORT_DIR="${GL}/exp" bash -c 'source "$1"; glp_emit tor-onion "$2"' _ "${GOLIVE}" "${GL}/out2" >/dev/null 2>&1
[ ! -e "${GL}/out2/domain-onions.txt" ] && ok "C no domain-onions.txt when the node serves only the primary onion" || bad "C empty domain-onions.txt emitted"

# ═════════════════════ D. tests/qemu/assertions.sh tor block ═════════════════════
echo "== D. assert_tor_node_contract against fixture roots =="
EXT="${WORK}/tor-assert.sh"
{
    echo 'PASS=0; FAIL=0'
    echo 'ok()   { echo "  PASS  $*"; }'
    echo 'bad()  { echo "  FAIL  $*"; }'
    echo 'skip() { echo "  SKIP  $*"; }'
    sed -n '/^_rl_has() {/,/^}/p' "${ASSERTIONS}"
    sed -n '/^assert_tor_node_contract() {/,/^}/p' "${ASSERTIONS}"
} > "${EXT}"
grep -F 'assert_tor_node_contract() {' "${EXT}" >/dev/null || bad "D assert_tor_node_contract() not extractable from assertions.sh"
grep -E '^assert_tor_node_contract "" live$' "${ASSERTIONS}" >/dev/null \
    && ok "D assertions.sh CALLS assert_tor_node_contract \"\" live on the guest" || bad "D assertions.sh never calls the tor block live"
DSTUB="${WORK}/dstub"; mkdir -p "${DSTUB}"
printf '#!/bin/bash\nexit "$(cat "${TOR_STATUS_FILE}" 2>/dev/null || echo 0)"\n' > "${DSTUB}/rc-service"; chmod +x "${DSTUB}/rc-service"
has_v() { printf '%s\n' "$1" | grep -F -- "$2" | grep -F -- "$3" >/dev/null; }   # OUT VERDICT MSG
fx() {  # NAME ROLE ARTEFACTS... -> fixture root in FX
    local a
    FX="${WORK}/fx-$1"; rm -rf "${FX}"; mkdir -p "${FX}/etc/hugmesh" "${FX}/etc/runlevels/default" "${FX}/etc/init.d"
    echo "$2" > "${FX}/etc/hugmesh/role"; shift 2
    for a in "$@"; do
        case "${a}" in
            package)   mkdir -p "${FX}/usr/bin"; : > "${FX}/usr/bin/tor" ;;
            initd)     : > "${FX}/etc/init.d/tor" ;;
            agent)     mkdir -p "${FX}/usr/sbin"; printf '#!/bin/sh\n' > "${FX}/usr/sbin/hugmesh-tor-reconcile"; chmod +x "${FX}/usr/sbin/hugmesh-tor-reconcile" ;;
            tor-linked) ln -s /etc/init.d/tor "${FX}/etc/runlevels/default/tor" ;;
            reconcile-linked) ln -s /etc/init.d/hugmesh-tor-reconcile "${FX}/etc/runlevels/default/hugmesh-tor-reconcile" ;;
            cron)      mkdir -p "${FX}/etc/cron.d"; : > "${FX}/etc/cron.d/hugmesh-tor-reconcile" ;;
            proc1)     mkdir -p "${FX}/proc/101"; echo tor > "${FX}/proc/101/comm" ;;
            proc2)     mkdir -p "${FX}/proc/102"; echo tor > "${FX}/proc/102/comm" ;;
            procother) mkdir -p "${FX}/proc/103"; echo sshd > "${FX}/proc/103/comm" ;;
            torrc)     mkdir -p "${FX}/etc/tor"; printf 'User tor\nHiddenServicePort 443 127.0.0.1:443\n' > "${FX}/etc/tor/torrc" ;;
            hostname)  mkdir -p "${FX}/var/lib/hugmesh/tor"; echo "${ONION_A}" > "${FX}/var/lib/hugmesh/tor/hostname" ;;
        esac
    done
}
run_fx() {  # [live] [status-rc]
    echo "${2:-0}" > "${WORK}/tor-status"
    TOR_STATUS_FILE="${WORK}/tor-status" PATH="${DSTUB}:${PATH}" bash -c '
        set -u; source "$1/scripts/_roles-lib.sh"; source "$2"; assert_tor_node_contract "$3" "$4"' _ "${REPO}" "${EXT}" "${FX}" "${1:-}" 2>&1
}
FULL=(package initd agent tor-linked reconcile-linked cron)
LIVE_OK=("${FULL[@]}" proc1 procother torrc hostname)

fx none backend; o="$(run_fx)"
has_v "${o}" PASS "tor not selected" && hasnt "${o}" FAIL && ok "D cluster node, no tor artefacts -> PASS 'not selected'" || { bad "D none"; echo "${o}" | sed 's/^/      | /'; }
fx full pki "${FULL[@]}"; o="$(run_fx)"
hasnt "${o}" FAIL && has_v "${o}" SKIP "not a live guest" && ok "D cluster node, full contract (static) -> no FAIL, runtime SKIPped" || { bad "D full static"; echo "${o}" | sed 's/^/      | /'; }
for miss in package tor-linked reconcile-linked cron; do
    arts=(); for a in "${FULL[@]}"; do [ "${a}" = "${miss}" ] || arts+=("${a}"); done
    fx "miss-${miss}" frontend "${arts[@]}"; o="$(run_fx)"
    has_v "${o}" FAIL "${miss} is MISSING" && ok "D half-applied selection without ${miss} -> FAIL names it" || { bad "D missing ${miss} not caught"; echo "${o}" | sed 's/^/      | /'; }
done
fx no-initd backend package agent tor-linked reconcile-linked cron; o="$(run_fx)"
has_v "${o}" FAIL "cannot start" && ok "D linked tor with no /etc/init.d/tor -> FAIL" || { bad "D missing init.d/tor not caught"; echo "${o}" | sed 's/^/      | /'; }
fx cli-bad desktop tor-linked reconcile-linked; o="$(run_fx)"
has_v "${o}" FAIL "scheduled on a CLIENT image" && ok "D client image with tor linked -> FAIL" || { bad "D client tor not caught"; echo "${o}" | sed 's/^/      | /'; }
fx cli-cron laptop cron; o="$(run_fx)"
has_v "${o}" FAIL "scheduled on a CLIENT image" && ok "D client image with the tor cron -> FAIL" || { bad "D client cron not caught"; echo "${o}" | sed 's/^/      | /'; }
fx cli-ok desktop; o="$(run_fx)"
has_v "${o}" PASS "no tor node service scheduled" && hasnt "${o}" FAIL && ok "D clean client image -> PASS" || { bad "D clean client"; echo "${o}" | sed 's/^/      | /'; }
fx live-ok backend "${LIVE_OK[@]}"; o="$(run_fx live 0)"
hasnt "${o}" FAIL && has_v "${o}" PASS "exactly one tor daemon" && has_v "${o}" PASS "v3 onion hostname is exported" \
    && ok "D live: started, one daemon, torrc 443, v3 hostname -> no FAIL" || { bad "D live ok"; echo "${o}" | sed 's/^/      | /'; }
fx live-two backend "${LIVE_OK[@]}" proc2; o="$(run_fx live 0)"
has_v "${o}" FAIL "2 tor daemons are running" && ok "D live: two tor processes -> FAIL (two owners, two daemons)" || { bad "D two daemons not caught"; echo "${o}" | sed 's/^/      | /'; }
arts=(); for a in "${LIVE_OK[@]}"; do [ "${a}" = proc1 ] || arts+=("${a}"); done
fx live-zero backend "${arts[@]}"; o="$(run_fx live 0)"
has_v "${o}" FAIL "no tor daemon is running" && ok "D live: no tor process -> FAIL" || { bad "D zero daemons not caught"; echo "${o}" | sed 's/^/      | /'; }
fx live-stopped backend "${LIVE_OK[@]}"; o="$(run_fx live 3)"
has_v "${o}" FAIL "NOT started" && ok "D live: rc-service status non-zero -> FAIL" || { bad "D stopped service not caught"; echo "${o}" | sed 's/^/      | /'; }
fx live-torrc backend "${LIVE_OK[@]}"; printf 'HiddenServicePort 80 127.0.0.1:80\n' > "${FX}/etc/tor/torrc"; o="$(run_fx live 0)"
has_v "${o}" FAIL "no managed 'HiddenServicePort 443" && ok "D live: torrc without the 443 stanza -> FAIL" || { bad "D torrc not caught"; echo "${o}" | sed 's/^/      | /'; }
fx live-host backend "${LIVE_OK[@]}"; echo "not-an-onion" > "${FX}/var/lib/hugmesh/tor/hostname"; o="$(run_fx live 0)"
has_v "${o}" FAIL "holds no v3 onion" && ok "D live: garbage exported hostname -> FAIL" || { bad "D hostname not caught"; echo "${o}" | sed 's/^/      | /'; }

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
