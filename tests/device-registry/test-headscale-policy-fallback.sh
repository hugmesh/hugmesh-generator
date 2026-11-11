#!/usr/bin/env bash
# test-headscale-policy-fallback.sh — keys-provision's headscale policy step fails
# CLOSED in every branch: headscale never starts on a policy that gives a security tag
# an owner, on one that could not be read, or on none at all.
#
# WHY. provision_headscale checks the policy it is about to load
# (headscale_policy_owned_security_tags). A KEYS-stick override (or a stale baked file)
# that gives tag:superadmin / tag:mesh_* / tag:dev_* / tag:dom_* an owner lets any
# pre-auth key holder claim that tag. When the clean baked bootstrap policy could not be
# used instead, three fallback branches used to fail OPEN, each with only a warning:
#   1. an override that could not be narrowed was "loaded UNSAFE";
#   2. an unreadable override was kept (headscale parses hujson that jq cannot, e.g. a
#      trailing comma, so its owners were loaded unchecked);
#   3. with no policy file at all, headscale was started anyway.
# The check itself also read the policy differently from headscale: a "TagOwners"
# member, or the first of two "tagOwners" members, was invisible to it, while headscale
# 0.23.0 (Go JSON: case-insensitive member names, repeated objects merged) granted the
# tags they own. Now every such outcome stages a static deny-all policy and marks
# first-boot health UNPROTECTED, and when even that cannot be written headscale is not
# started.
#
# HOW (offline: bash + jq + perl + awk). The REAL provision_headscale and its helpers
# are cut out of specs/etc/keys-provision/provision.sh, every absolute path they touch
# is rewritten into a per-scenario sandbox (and the run is refused if one is left
# over), and the commands around them (headscale, rc-service, rc-update, chown, logger)
# are stubs. The rc-service stub snapshots /etc/headscale/policy.hujson whenever
# headscale would (re)start, i.e. whenever headscale (policy.mode file) reads it. Each
# snapshot is judged by THIS file's own reader, not the production one: it strips
# hujson the way headscale tolerates it (comments, trailing commas), folds member
# names, unions repeated members, and calls anything it cannot parse UNSAFE.
#
# Scenarios cover every branch (clean override, bootstrap swap, narrowing, narrowing
# that cannot be written, unreadable with and without a bootstrap, no policy, the
# case-variant and repeated-member spellings, a bad baked bootstrap, a deny-all that
# cannot be written, a stale mark). Negative controls re-run scenarios with the
# production check or the deny-all writer disabled and require this file to see it.
# The live half (pinned headscale really starts on the deny-all text, and really
# grants the spellings the old check missed) is test-headscale-policy-fallback-live.sh.
#
# HS_FALLBACK_PROVISION=<file> points the suite at another copy of provision.sh (the
# mutation battery, or origin/main to watch it fail).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PROVISION="${HS_FALLBACK_PROVISION:-${REPO}/specs/etc/keys-provision/provision.sh}"
BOOTSTRAP_SRC="${REPO}/specs/etc/headscale/policy.bootstrap.hujson"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
cannot() { echo "CANNOT RUN: $* — this guard checked NOTHING"; exit 2; }

for t in jq perl awk sed cmp; do command -v "$t" >/dev/null 2>&1 || cannot "$t is required"; done
[ -f "${PROVISION}" ] || cannot "${PROVISION} not found"
[ -f "${BOOTSTRAP_SRC}" ] || cannot "${BOOTSTRAP_SRC} not found"

WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT
SEC_RE='^tag:(superadmin$|mesh_|dev_|dom_)'

# ── this file's own reader (independent of the production check) ─────────────
# hujson -> JSON as headscale tolerates it: // and /* */ comments, trailing commas.
to_json() { perl -0pe 's{/\*.*?\*/}{}gs; s{//[^\n]*}{}g; s{,(\s*[\]\}])}{$1}g' "$1" 2>/dev/null; }
# owners_seen <file>: prints "<tag>" for every security tag with an owner under ANY
# member whose name folds to "tagowners", across repeats; rc 1 when it does not parse.
owners_seen() {
    local j
    j="$(to_json "$1")" || return 1
    printf '%s' "${j}" | jq -e 'type == "object"' >/dev/null 2>&1 || return 1
    printf '%s' "${j}" | jq -nr --stream --arg re "${SEC_RE}" '
        [inputs | select(length == 2)
         | select((.[0] | length) > 1 and (.[0][0] | type) == "string")
         # Go folds U+017F to "s" and U+212A (Kelvin) to "k" when it matches names.
         | select((.[0][0] | ascii_downcase | gsub("\u017f"; "s") | gsub("\u212a"; "k")) == "tagowners")
         | select((.[0][1] | tostring) | test($re))
         | select((.[0] | length) > 2 or (.[1] != [] and .[1] != null))
         | .[0][1]] | unique[]' 2>/dev/null
}
# unsafe_reason <file>: empty when the file is safe for headscale to start on.
unsafe_reason() {
    local o
    [ -f "$1" ] || { echo "no policy file (headscale would start on none)"; return; }
    if ! o="$(owners_seen "$1")"; then echo "does not parse here (headscale may read it, owners unchecked)"; return; fi
    [ -z "${o}" ] || echo "security tag(s) with an owner: $(printf '%s' "${o}" | tr '\n' ' ')"
}

# ── extract the real functions ───────────────────────────────────────────────
extract() { awk -v fn="$1" '$0 ~ "^" fn "\\(\\) \\{" {p=1} p {print} p && /^}/ {exit}' "${PROVISION}"; }
SRC="${WORK}/extracted.sh"; : > "${SRC}"
for fn in headscale_policy_owned_security_tags headscale_deny_all_policy headscale_stage_deny_all_policy \
          headscale_policy_unprotected provision_headscale; do
    body="$(extract "${fn}")"
    if [ -n "${body}" ]; then printf '%s\n\n' "${body}" >> "${SRC}"
    else bad "${fn}() not found in $(basename "${PROVISION}")"; fi
done
grep -q '^provision_headscale() {' "${SRC}" || cannot "provision_headscale() could not be extracted"
# Rewrite every absolute path into the sandbox ${HSB}, then refuse to run if any
# command line still names one (comments and the policy text are not commands).
sed -i -E 's#(^|[^A-Za-z0-9_}])/(etc/headscale|var/lib/headscale|run/headscale|var/log/headscale|run/hugmesh)#\1${HSB}/\2#g' "${SRC}"
leftover="$(sed 's#/dev/null##g' "${SRC}" | grep -nE '(^|[^A-Za-z0-9_}.])/(etc|var|run|usr|opt|root|home|boot|srv|dev|sys|proc)/' \
    | grep -vE '^[0-9]+:[[:space:]]*(#|//)')"
[ -z "${leftover}" ] || cannot "provision_headscale names a path this suite does not sandbox — refusing to run it:
${leftover}"
ok "extracted provision_headscale + helpers; every path they touch is sandboxed"

# ── fixtures ─────────────────────────────────────────────────────────────────
FX="${WORK}/fx"; mkdir -p "${FX}"
cat > "${FX}/clean.hujson" <<'EOF'
{
  // a clean KEYS override (FIXTURE-CLEAN)
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": [] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ]
}
EOF
cat > "${FX}/owned.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"], "tag:dev_abc": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.96.0.0/12:443"] } ]
}
EOF
# headscale reads hujson (trailing commas allowed); jq cannot. Owned on purpose.
cat > "${FX}/unreadable.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"], },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] }, ],
}
EOF
cat > "${FX}/case.hujson" <<'EOF'
{
  "TagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ]
}
EOF
cat > "${FX}/dup.hujson" <<'EOF'
{
  "tagOwners": { "tag:hugmesh": ["hugmesh"], "tag:superadmin": ["hugmesh"] },
  "acls": [ { "action": "accept", "src": ["tag:hugmesh"], "dst": ["10.244.0.0/16:*"] } ],
  "tagOwners": { "tag:hugmesh": ["hugmesh"] }
}
EOF
printf '{\n  "tagOwner\xc5\xbf": { "tag:superadmin": ["hugmesh"] },\n  "acls": []\n}\n' > "${FX}/nonascii.hujson"
sed 's/"tag:superadmin": \[\]/"tag:superadmin": ["hugmesh"]/' "${BOOTSTRAP_SRC}" > "${FX}/bootstrap-owned.hujson"
cmp -s "${BOOTSTRAP_SRC}" "${FX}/bootstrap-owned.hujson" && cannot "could not plant an owner in the bootstrap fixture (shape changed?)"
printf '{"headscale":{"enabled":true}}\n' > "${FX}/provision.json"

# Fixture sanity: the reader above must call every bad fixture unsafe and the clean
# ones safe, or every scenario verdict below means nothing.
for f in owned unreadable case dup nonascii bootstrap-owned; do
    [ -n "$(unsafe_reason "${FX}/${f}.hujson")" ] && ok "reader: fixture ${f} is unsafe" \
        || bad "reader: fixture ${f} reads as safe — the scenario verdicts would be vacuous"
done
for f in "${FX}/clean.hujson" "${BOOTSTRAP_SRC}"; do
    [ -z "$(unsafe_reason "${f}")" ] && ok "reader: $(basename "${f}") is safe" \
        || bad "reader: $(basename "${f}") reads as unsafe ($(unsafe_reason "${f}"))"
done

# ── scenario runner ──────────────────────────────────────────────────────────
# run_scenario <name> <override fixture|-> <bootstrap fixture|-> [baked policy.hujson|-]
# Env: FAIL_MV_RE (mv fails when its source matches), PRE_MARK=1 (a stale mark exists),
#      EXTRA_SRC (shell text evaluated after the functions: negative controls).
run_scenario() {
    local name="$1" ovr="$2" boot="$3" baked="${4:--}"
    local sb="${WORK}/sb-${name}"
    rm -rf "${sb}"; mkdir -p "${sb}/keys/headscale" "${sb}/etc/headscale"
    [ "${ovr}" = "-" ] || cp "${ovr}" "${sb}/keys/headscale/policy.hujson"
    [ "${boot}" = "-" ] || cp "${boot}" "${sb}/etc/headscale/policy.bootstrap.hujson"
    [ "${baked}" = "-" ] || cp "${baked}" "${sb}/etc/headscale/policy.hujson"
    if [ "${PRE_MARK:-0}" = 1 ]; then
        mkdir -p "${sb}/run/hugmesh/firewall-health"; echo stale > "${sb}/run/hugmesh/firewall-health/headscale_policy.unprotected"
    fi
    (
        HSB="${sb}"; MANIFEST="${FX}/provision.json"
        # shellcheck disable=SC2034  # read by the extracted provision_headscale
        BASE="${sb}/keys"
        n=0
        log()  { echo "[kp] $*" >> "${HSB}/log"; }
        warn() { log "WARNING: $*"; }
        have() { command -v "$1" >/dev/null 2>&1; }
        jqm()  { jq -r "$1" "${MANIFEST}" 2>/dev/null; }
        getent() { return 0; }; groupadd() { :; }; useradd() { :; }; chown() { :; }; sleep() { :; }
        logger() { echo "$*" >> "${HSB}/syslog"; }
        resolve_endpoint() { :; }; resolve_magic_dns_domain() { :; }; resolve_ssh_user() { echo superadmin; }
        approve_mesh_routes_now() { :; }; provision_headscale_derp() { :; }
        mv() { # fault injection: fail when the SOURCE (next-to-last argument) matches
            local mv_src="${*: -2:1}"
            if [ -n "${FAIL_MV_RE:-}" ] && [[ "${mv_src}" =~ ${FAIL_MV_RE} ]]; then return 1; fi
            command mv "$@"
        }
        snap() { # what headscale (policy.mode file) reads at (re)start
            n=$((n + 1))
            if [ -f "${HSB}/etc/headscale/policy.hujson" ]; then cp "${HSB}/etc/headscale/policy.hujson" "${HSB}/loaded.${n}"
            else : > "${HSB}/loaded.${n}.missing"; fi
            echo "$1 ${n}" >> "${HSB}/starts"
        }
        rc-service() {
            echo "rc-service $*" >> "${HSB}/rc"
            case "$1 $2" in "headscale start"|"headscale restart") snap "$2" ;; esac
            # fault: the policy file is removed underneath the run after headscale started
            [ "${VANISH_AFTER_START:-0}" = 1 ] && [ "$1 $2" = "headscale start" ] && rm -f "${HSB}/etc/headscale/policy.hujson"
            return 0
        }
        rc-update() { echo "rc-update $*" >> "${HSB}/rc"; }
        headscale() {
            case "$1 ${2:-}" in
                "policy set") return 1 ;;   # policy.mode file refuses; provision restarts instead
                *) return 0 ;;
            esac
        }
        # shellcheck source=/dev/null
        . "${SRC}"
        [ -n "${EXTRA_SRC:-}" ] && eval "${EXTRA_SRC}"
        provision_headscale; echo "$?" > "${HSB}/rc.exit"
    ) >/dev/null 2>&1
    SB="${sb}"
}
mark()      { echo "${SB}/run/hugmesh/firewall-health/headscale_policy.unprotected"; }
started()   { [ -s "${SB}/starts" ]; }
first_load() { echo "${SB}/loaded.1"; }
# every policy headscale would have read in this scenario is safe
all_loads_safe() {
    local f r out=""
    for f in "${SB}"/loaded.*; do
        [ -e "${f}" ] || continue
        case "${f}" in *.missing) out="${out} $(basename "${f}"): no policy file;"; continue ;; esac
        r="$(unsafe_reason "${f}")"; [ -z "${r}" ] || out="${out} $(basename "${f}"): ${r};"
    done
    printf '%s' "${out}"
}
DENYALL="${WORK}/denyall.expected"
( eval "$(extract headscale_deny_all_policy)" && headscale_deny_all_policy ) > "${DENYALL}" 2>/dev/null || : > "${DENYALL}"
is_denyall() { [ -s "${DENYALL}" ] && cmp -s "$1" "${DENYALL}"; }

expect_safe_start() { # <label>
    started || { bad "$1: headscale was never started"; return; }
    local u; u="$(all_loads_safe)"
    [ -z "${u}" ] && ok "$1: every policy headscale would read is safe" || bad "$1: headscale would read an UNSAFE policy:${u}"
}
expect_denyall() { # <label> <reason substring> — deny-all in force, health marked by THAT branch
    expect_safe_start "$1"
    grep -q "^reason=.*$2" "$(mark)" 2>/dev/null && ok "$1: the mark names the branch that failed closed ('$2')" \
        || bad "$1: the mark does not say '$2' (got: $(sed -n 's/^reason=//p' "$(mark)" 2>/dev/null | cut -c1-120))"
    is_denyall "$(first_load)" && ok "$1: the deny-all policy is what headscale starts on" \
        || bad "$1: headscale does not start on the deny-all policy"
    grep -q '^state=deny-all$' "$(mark)" 2>/dev/null && ok "$1: first-boot health marked UNPROTECTED (state=deny-all)" \
        || bad "$1: no UNPROTECTED health mark with state=deny-all"
    grep -q 'ERROR: headscale policy step FAILED CLOSED' "${SB}/log" 2>/dev/null && grep -q 'failed closed' "${SB}/syslog" 2>/dev/null \
        && ok "$1: an ERROR line and a syslog line say it failed closed" || bad "$1: no ERROR/syslog line for the fail-closed fallback"
}
expect_narrowed() { # <label> <source fixture>
    expect_safe_start "$1"
    if ! is_denyall "$(first_load)" && jq -e --slurpfile o <(to_json "$2") '.acls == $o[0].acls' "$(first_load)" >/dev/null 2>&1; then
        ok "$1: narrowed — the policy's own rules are kept, not replaced by deny-all"
    else bad "$1: not the narrowed policy (deny-all or something else is loaded)"; fi
    expect_no_mark "$1"
}
expect_no_mark() { [ ! -e "$(mark)" ] && ok "$1: no health mark (a working policy is in force)" || bad "$1: a health mark was left although a working policy is in force"; }

# ── 0. the deny-all policy itself ────────────────────────────────────────────
echo "== deny-all policy text =="
if [ -s "${DENYALL}" ]; then
    j="$(to_json "${DENYALL}")"
    [ -z "$(unsafe_reason "${DENYALL}")" ] && ok "deny-all: no tag has an owner" || bad "deny-all: $(unsafe_reason "${DENYALL}")"
    printf '%s' "${j}" | jq -e '(.acls == []) and ((.ssh // []) == []) and ((.autoApprovers // {}) == {}) and ((.hosts // {}) == {})' >/dev/null 2>&1 \
        && ok "deny-all: no ACL, no SSH rule, no auto-approver, no host" || bad "deny-all: grants something (acls/ssh/autoApprovers/hosts not empty)"
    printf '%s' "${j}" | jq -e '[.tagOwners[]] | all(. == [])' >/dev/null 2>&1 && printf '%s' "${j}" | jq -e '.tagOwners | has("tag:superadmin")' >/dev/null 2>&1 \
        && ok "deny-all: tag:superadmin listed with an empty owner list, every listed tag ownerless" || bad "deny-all: a listed tag has an owner, or tag:superadmin is not declared"
    printf '%s' "${j}" | jq -e '[.groups[]?] | all(. == [])' >/dev/null 2>&1 \
        && ok "deny-all: its groups have no members" || bad "deny-all: a group has members"
    # headscale 0.23 refuses a policy with no groups, hosts, acls and ssh ("empty policy").
    printf '%s' "${j}" | jq -e '((.groups // {}) | length) + ((.hosts // {}) | length) + ((.acls // []) | length) + ((.ssh // []) | length) > 0' >/dev/null 2>&1 \
        && ok "deny-all: not an 'empty policy' to headscale 0.23 (it would refuse to start)" || bad "deny-all: headscale 0.23 would reject it as an empty policy and not start"
    grep -q '^}' "${DENYALL}" && bad "deny-all: a line starts with '}' — the awk '/^fn\\(\\)/,/^}/' extraction would cut the function short" \
        || ok "deny-all: no line starts with '}' (function extraction stays whole)"
else
    bad "headscale_deny_all_policy produced nothing"
fi

# ── 1. the production check reads the policy the way headscale does ──────────
echo "== headscale_policy_owned_security_tags =="
(
    eval "$(extract headscale_policy_owned_security_tags)"
    # <file> -> its owned security tags, sorted, space-separated; UNREADABLE on rc 1.
    g() { local o; o="$(headscale_policy_owned_security_tags "$1")" || { echo UNREADABLE; return; }; printf '%s\n' "${o}" | sed '/^$/d' | sort | paste -sd' ' -; }
    [ "$(g "${FX}/case.hujson")" = "tag:superadmin" ] && echo "PASS-sub flags owners under a case-variant TagOwners member" || echo "FAIL-sub missed owners under TagOwners (got '$(g "${FX}/case.hujson")')"
    [ "$(g "${FX}/dup.hujson")" = "tag:superadmin" ] && echo "PASS-sub flags owners in the first of two tagOwners members" || echo "FAIL-sub missed owners in a repeated tagOwners member (got '$(g "${FX}/dup.hujson")')"
    [ "$(g "${FX}/nonascii.hujson")" = UNREADABLE ] && echo "PASS-sub a non-ASCII member name makes the policy unreadable" || echo "FAIL-sub a non-ASCII member name was read (got '$(g "${FX}/nonascii.hujson")')"
    printf '' > "${WORK}/empty.json"
    [ "$(g "${WORK}/empty.json")" = UNREADABLE ] && echo "PASS-sub an empty file is unreadable, not clean" || echo "FAIL-sub an empty file reads as clean"
    printf '%s' '{"tagOwners":["hugmesh"]}' > "${WORK}/arr.json"
    [ "$(g "${WORK}/arr.json")" = UNREADABLE ] && echo "PASS-sub a tagOwners that is not an object is unreadable" || echo "FAIL-sub a non-object tagOwners was read (got '$(g "${WORK}/arr.json")')"
    [ "$(g "${FX}/owned.hujson")" = "tag:dev_abc tag:superadmin" ] && echo "PASS-sub flags every owned security tag" || echo "FAIL-sub owned fixture read as '$(g "${FX}/owned.hujson")'"
    [ -z "$(g "${BOOTSTRAP_SRC}")" ] && echo "PASS-sub the shipped bootstrap policy reads clean" || echo "FAIL-sub the shipped bootstrap reads '$(g "${BOOTSTRAP_SRC}")'"
) > "${WORK}/guard.out" 2>&1
while IFS= read -r l; do
    case "${l}" in PASS-sub\ *) ok "guard: ${l#PASS-sub }" ;; FAIL-sub\ *) bad "guard: ${l#FAIL-sub }" ;; esac
done < "${WORK}/guard.out"
grep -q -- '-sub' "${WORK}/guard.out" || bad "guard: the unit checks did not run ($(head -c 200 "${WORK}/guard.out"))"

# ── 2. every branch of provision_headscale ───────────────────────────────────
echo "== provision_headscale branches =="
B="${FX}/bootstrap.hujson"; cp "${BOOTSTRAP_SRC}" "${B}"

run_scenario clean "${FX}/clean.hujson" "${B}"
expect_safe_start "clean override"
cmp -s "$(first_load)" "${FX}/clean.hujson" && ok "clean override: loaded as written" || bad "clean override: not loaded as written"
expect_no_mark "clean override"

PRE_MARK=1 run_scenario stale "${FX}/clean.hujson" "${B}"
expect_no_mark "clean override after a failed earlier run (stale mark)"

run_scenario owned-boot "${FX}/owned.hujson" "${B}"
expect_safe_start "owned override + clean bootstrap"
cmp -s "$(first_load)" "${B}" && ok "owned override + clean bootstrap: the bootstrap is staged instead" || bad "owned override + clean bootstrap: the bootstrap was not staged"
expect_no_mark "owned override + clean bootstrap"

run_scenario owned-narrow "${FX}/owned.hujson" -
expect_safe_start "owned override, no bootstrap (narrowed)"
if jq -e --slurpfile o <(to_json "${FX}/owned.hujson") '.acls == $o[0].acls and .tagOwners["tag:hugmesh"] == ["hugmesh"]' "$(first_load)" >/dev/null 2>&1; then
    ok "owned override, no bootstrap: narrowed — the override's rules and membership owner kept"
else bad "owned override, no bootstrap: not the narrowed override"; fi
expect_no_mark "owned override, no bootstrap (narrowed)"

FAIL_MV_RE='\.narrowed\.' run_scenario narrow-fails "${FX}/owned.hujson" -
expect_denyall "owned override that cannot be narrowed (was: loaded UNSAFE)" "could not be narrowed"

run_scenario unreadable "${FX}/unreadable.hujson" -
expect_denyall "unreadable override, no bootstrap (was: kept and loaded)" "could not be read"

run_scenario unreadable-boot "${FX}/unreadable.hujson" "${B}"
expect_safe_start "unreadable override + clean bootstrap"
cmp -s "$(first_load)" "${B}" && ok "unreadable override + clean bootstrap: the bootstrap is staged instead" || bad "unreadable override + clean bootstrap: the bootstrap was not staged"

run_scenario none - -
expect_denyall "no policy at all (was: headscale started on none)" "no headscale policy"

run_scenario case "${FX}/case.hujson" -
expect_narrowed "case-variant TagOwners override, no bootstrap" "${FX}/case.hujson"

run_scenario case-boot "${FX}/case.hujson" "${B}"
expect_safe_start "case-variant TagOwners override + clean bootstrap"
cmp -s "$(first_load)" "${B}" && ok "case-variant override + clean bootstrap: the bootstrap is staged instead" || bad "case-variant override + clean bootstrap: the override was loaded"

run_scenario dup "${FX}/dup.hujson" -
expect_narrowed "repeated tagOwners override, no bootstrap" "${FX}/dup.hujson"

run_scenario nonascii "${FX}/nonascii.hujson" -
expect_denyall "non-ASCII member name, no bootstrap" "could not be read"

run_scenario bad-bootstrap - "${FX}/bootstrap-owned.hujson"
expect_narrowed "no override, baked bootstrap gives tag:superadmin an owner" "${FX}/bootstrap-owned.hujson"

FAIL_MV_RE='\.(narrowed|deny-all)\.' run_scenario cannot-write "${FX}/owned.hujson" -
if started; then bad "deny-all cannot be written: headscale was STARTED (on $(all_loads_safe || true))"
else ok "deny-all cannot be written: headscale is not started"; fi
grep -q 'rc-update del headscale default' "${SB}/rc" 2>/dev/null && grep -q 'rc-service headscale stop' "${SB}/rc" 2>/dev/null \
    && ok "deny-all cannot be written: headscale is stopped and taken out of the runlevel" || bad "deny-all cannot be written: headscale left in the runlevel or not stopped"
[ ! -e "${SB}/etc/headscale/policy.hujson" ] && ok "deny-all cannot be written: the unsafe policy file is removed" || bad "deny-all cannot be written: the unsafe policy file is still in place"
grep -q '^state=not-started$' "$(mark)" 2>/dev/null && ok "deny-all cannot be written: health marked UNPROTECTED (state=not-started)" || bad "deny-all cannot be written: no UNPROTECTED mark with state=not-started"
[ "$(cat "${SB}/rc.exit" 2>/dev/null)" = 1 ] && ok "deny-all cannot be written: provision_headscale returns 1" || bad "deny-all cannot be written: provision_headscale returned $(cat "${SB}/rc.exit" 2>/dev/null)"

# The FINAL GATE re-reads the file headscale will start on. A first check that misreads
# (here: says "clean" once, then reads truly) must still not let an owned policy start.
EXTRA_SRC='eval "real_$(declare -f headscale_policy_owned_security_tags)"
    headscale_policy_owned_security_tags() { if [ ! -e "${HSB}/.misread" ]; then : > "${HSB}/.misread"; return 0; fi; real_headscale_policy_owned_security_tags "$@"; }' \
    run_scenario final-gate "${FX}/owned.hujson" -
expect_denyall "first check misreads an owned override as clean (final gate)" "not clean on the final check"

# A narrowing that does not narrow (simulated: jq passes the narrowing program's input
# through) must be caught by the narrowed file's own re-check, not left to the gate.
EXTRA_SRC='jq() { case "$*" in *with_entries*tagowners*) cat ;; *) command jq "$@" ;; esac; }' \
    run_scenario narrow-noop "${FX}/owned.hujson" -
expect_denyall "narrowing that leaves an owner in place" "could not be narrowed"

# A deny-all write that comes out short (disk full) must not be put in place.
EXTRA_SRC='headscale_deny_all_policy() { printf "{\n  \"groups\": {\n"; }' \
    run_scenario short-write - -
if started; then bad "short deny-all write: headscale was STARTED on it"
else ok "short deny-all write: not put in place, headscale is not started"; fi
grep -q '^state=not-started$' "$(mark)" 2>/dev/null && ok "short deny-all write: health marked UNPROTECTED (state=not-started)" \
    || bad "short deny-all write: no not-started mark"

VANISH_AFTER_START=1 run_scenario vanish "${FX}/clean.hujson" -
grep -q 'rc-service headscale stop' "${SB}/rc" 2>/dev/null && grep -q '^state=not-started$' "$(mark)" 2>/dev/null \
    && ok "policy file removed underneath after start: headscale is stopped and health marked" \
    || bad "policy file removed underneath after start: headscale left running on no checked policy"

# ── 3. NEGATIVE CONTROLS: the verdicts above can see a fail-open ─────────────
echo "== negative controls =="
EXTRA_SRC='headscale_policy_owned_security_tags() { return 0; }' run_scenario nc-noguard "${FX}/owned.hujson" -
[ -n "$(all_loads_safe)" ] && ok "control: with the production check disabled, an owned override is seen loading" \
    || bad "control: the production check was disabled and nothing was seen — the scenario verdicts are vacuous"
EXTRA_SRC='headscale_stage_deny_all_policy() { return 0; }' run_scenario nc-nodenyall - -
[ -n "$(all_loads_safe)" ] && ok "control: with the deny-all writer disabled, a start on no policy is seen" \
    || bad "control: the deny-all writer was disabled and nothing was seen"
EXTRA_SRC='headscale_stage_deny_all_policy() { return 0; }' FAIL_MV_RE='\.narrowed\.' run_scenario nc-unsafe "${FX}/owned.hujson" -
[ -n "$(all_loads_safe)" ] && ok "control: an owned policy left in place by a no-op deny-all writer is seen loading" \
    || bad "control: an owned policy left in place was not seen"

echo
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
