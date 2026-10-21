#!/usr/bin/env bash
# test-domain-idp-flag.sh — pins the image-CLI per-domain identity-provider flag
# (hugmesh-generator#509, a child of #47):
#
#     --domain-idp <domain>=own|superdomain        (repeatable)
#
# on EVERY stage4 builder. The builders are found by GLOB (build-*-stage4.sh), so a
# builder that was missed turns this red and so does an eleventh builder added
# without the flag. Nothing here greps for a function name and calls that a pass:
# every builder is EXECUTED with `--print-plan`, which runs the real argument loop
# and the real validation block and stops before any build step (no root, no
# network, no cross toolchain).
#
# What is pinned, per builder:
#   A. a valid flag is accepted and shows up in the plan as PLAN_DOMAIN_IDP=<own>,
#      own domains only, in the order given;
#   B. the explicit default (=superdomain) is accepted and changes NOTHING: the
#      plan is byte-identical to the one built with no flag at all;
#   C. a plan with no flag has no PLAN_DOMAIN_IDP line (omit-the-default);
#   D. each malformed value is REFUSED with a --domain-idp message and exit 1:
#      unknown idp, no '=', empty name, uppercase/invalid name, repeated domain,
#      missing value, and the mesh's own --cluster-domain set to own;
#   E. --help documents the flag;
#   F. the bake call is present in the builder (static, comments stripped — the
#      bake itself needs a real sysroot, so the lib's bake is executed in section 2
#      and the call site is the part checked by reading).
# And, once: the lib's vocabulary equals the Studio's DOMAIN_IDP_CHOICES, the lib's
# bake writes only own domains (and removes a stale file when there are none), x86
# checks the name against --domains, and --unaffiliated refuses the flag.
#
# DOMAIN_IDP_BASE_TREE=<dir>  an extract of the tree BEFORE this change (for example
#   `git archive origin/main | tar -x -C <dir>`): the no-flag plan of every builder
#   is then compared byte for byte with that tree's. Unset, that leg is a counted
#   SKIP and the in-tree omit-the-default checks (B, C) still run.
#
# Offline, no root, no docker. Exit 0 = all pass, 1 = a check failed.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_domain-idp-lib.sh"
P=0; F=0; S=0
ok()   { echo "  PASS $*"; P=$((P+1)); }
bad()  { echo "  FAIL $*"; F=$((F+1)); }
skip() { echo "  SKIP $*"; S=$((S+1)); }

SCR="$(mktemp -d "${TMPDIR:-/tmp}/domain-idp-flag.XXXXXX")" || { echo "  FAIL no scratch dir"; exit 1; }
trap 'rm -rf "${SCR}"' EXIT
WD="${SCR}/work"
mkdir -p "${SCR}/cwd"

echo "== --domain-idp on every stage4 builder (#509) =="

BUILDERS=()
for _b in "${REPO}"/build-*-stage4.sh; do
    [ -f "${_b}" ] && BUILDERS+=("${_b}")
done
unset _b
# The glob must not be able to pass vacuously: ten builders exist today.
if [ "${#BUILDERS[@]}" -ge 10 ]; then
    ok "found ${#BUILDERS[@]} stage4 builders by glob (>= 10)"
else
    bad "found only ${#BUILDERS[@]} stage4 builders by glob (ten exist) — wrong REPO or a builder was renamed"
fi
[ -f "${LIB}" ] && ok "scripts/_domain-idp-lib.sh exists" || bad "scripts/_domain-idp-lib.sh is missing"

# run <builder> <args...> -> OUT (stdout+stderr, colour stripped, the per-second
# "Build stamp: <UTC time>" banner masked), RC
norm() { sed -e 's/\x1b\[[0-9;]*m//g' -e 's/Build stamp: [0-9]\{8\}T[0-9]\{6\}Z/Build stamp: <ts>/'; }
run() {
    local b="$1"; shift
    OUT="$(cd "${SCR}/cwd" && timeout 120 bash "${b}" -w "${WD}" "$@" 2>&1)"
    RC=$?
    OUT="$(printf '%s\n' "${OUT}" | norm)"
    # grep reads this FILE, never a pipe: `printf | grep -q` can die of SIGPIPE under
    # pipefail and report a found match as a miss.
    printf '%s\n' "${OUT}" > "${SCR}/out.txt"
}
# Extra args that make x86 a CLIENT image, where --domains is meaningful; every
# other builder takes no extra args.
extra_for() { case "$(basename "$1")" in build-x86-host-stage4.sh) echo "--role laptop" ;; *) echo "" ;; esac; }

# ── 1. per builder ────────────────────────────────────────────────────────────
for b in "${BUILDERS[@]}"; do
    n="$(basename "${b}" -stage4.sh)"; n="${n#build-}"
    # shellcheck disable=SC2046
    X=( $(extra_for "${b}") )

    run "${b}" "${X[@]}" --print-plan
    base_rc=${RC}; base_out="${OUT}"
    if [ "${base_rc}" -ne 0 ]; then
        bad "${n}: the no-flag --print-plan baseline failed (rc=${base_rc}); the rest of this builder's checks are meaningless: $(printf '%s\n' "${base_out}" | tail -1)"
        continue
    fi

    # C. omit-the-default
    if printf '%s\n' "${base_out}" > "${SCR}/base.txt"; grep -q '^PLAN_DOMAIN_IDP=' "${SCR}/base.txt"; then
        bad "${n}: a plan built with no --domain-idp carries a PLAN_DOMAIN_IDP line"
    else
        ok "${n}: no flag -> no PLAN_DOMAIN_IDP line"
    fi

    # A. own domains, in order, own only
    run "${b}" "${X[@]}" --domain-idp a.test=own --domain-idp b.test=superdomain --domain-idp c.test=own --print-plan
    if [ "${RC}" -eq 0 ] && grep -qx 'PLAN_DOMAIN_IDP=a.test,c.test' "${SCR}/out.txt"; then
        ok "${n}: a.test=own b.test=superdomain c.test=own -> PLAN_DOMAIN_IDP=a.test,c.test"
    else
        bad "${n}: valid --domain-idp flags not threaded (rc=${RC}): $(grep -m1 'PLAN_DOMAIN_IDP\|ERROR\|Unknown' "${SCR}/out.txt" || tail -1 "${SCR}/out.txt")"
    fi

    # B. the explicit default changes nothing
    run "${b}" "${X[@]}" --domain-idp a.test=superdomain --domain-idp b.test=superdomain --print-plan
    if [ "${RC}" -eq 0 ] && [ "${OUT}" = "${base_out}" ]; then
        ok "${n}: =superdomain only -> plan byte-identical to the no-flag plan"
    else
        bad "${n}: =superdomain only changed the plan (rc=${RC})"
    fi

    # D. refusals
    refuse() {  # <label> <expected-fragment> <args...>
        local label="$1" frag="$2"; shift 2
        run "${b}" "${X[@]}" "$@" --print-plan
        if [ "${RC}" -eq 1 ] && grep -q -- "--domain-idp.*${frag}" "${SCR}/out.txt"; then
            ok "${n}: refuses ${label}"
        else
            bad "${n}: did NOT refuse ${label} (rc=${RC}): $(grep -m1 'ERROR\|PLAN_DOMAIN_IDP' "${SCR}/out.txt" || tail -1 "${SCR}/out.txt")"
        fi
    }
    refuse "an unknown idp value"            "idp must be"     --domain-idp a.test=bogus
    refuse "a value with no '='"             "no '='"          --domain-idp a.test
    refuse "an empty domain name"            "not a valid DNS" --domain-idp =own
    refuse "an uppercase domain name"        "not a valid DNS" --domain-idp A.TEST=own
    refuse "a name carrying shell/sed syntax" "not a valid DNS" '--domain-idp' 'a.test|x=own'
    refuse "the same domain twice"           "twice"           --domain-idp a.test=own --domain-idp a.test=superdomain
    refuse "a missing value"                 "needs a value"   --domain-idp ""
    refuse "the mesh's own domain as own"    "own domain"      --cluster-domain mesh.test --domain-idp mesh.test=own

    # E. --help documents the flag
    run "${b}" --help
    if grep -q -- '--domain-idp' "${SCR}/out.txt"; then
        ok "${n}: --help documents --domain-idp"
    else
        bad "${n}: --help does not mention --domain-idp"
    fi

    # F. the bake call (static; comments stripped so prose cannot satisfy it)
    # The comment-stripped builder goes to a FILE and grep reads the file: a
    # `printf | grep -q` over a 200 KB script dies of SIGPIPE under pipefail and
    # reports a found match as a miss.
    sed 's/^[[:space:]]*#.*$//' "${b}" > "${SCR}/code.sh"
    if grep -qF 'domain_idp_bake "${SYSROOT}/etc/hugmesh"' "${SCR}/code.sh" \
       && grep -qF 'source "${SCRIPT_DIR}/scripts/_domain-idp-lib.sh"' "${SCR}/code.sh" \
       && grep -qF 'domain_idp_check ' "${SCR}/code.sh" \
       && grep -qF 'domain_idp_plan_line' "${SCR}/code.sh"; then
        ok "${n}: sources the lib and calls check, plan line and bake"
    else
        bad "${n}: missing the lib source or one of domain_idp_check / domain_idp_plan_line / domain_idp_bake"
    fi

    # no-flag bytes vs the tree before this change
    if [ -n "${DOMAIN_IDP_BASE_TREE:-}" ]; then
        if [ -f "${DOMAIN_IDP_BASE_TREE}/$(basename "${b}")" ]; then
            OUT0="$(cd "${SCR}/cwd" && timeout 120 bash "${DOMAIN_IDP_BASE_TREE}/$(basename "${b}")" -w "${WD}" "${X[@]}" --print-plan 2>&1 | norm)"
            if [ "${OUT0}" = "${base_out}" ]; then
                ok "${n}: no-flag plan is byte-identical to the base tree's"
            else
                bad "${n}: no-flag plan DIFFERS from the base tree's: $(diff <(printf '%s\n' "${OUT0}") <(printf '%s\n' "${base_out}") | head -6 | tr '\n' '|')"
            fi
        else
            bad "${n}: DOMAIN_IDP_BASE_TREE has no $(basename "${b}")"
        fi
    fi
done
[ -n "${DOMAIN_IDP_BASE_TREE:-}" ] || skip "no DOMAIN_IDP_BASE_TREE: the no-flag-bytes-vs-base leg did not run (the in-tree omit-the-default checks above did)"

# ── 2. the lib itself ─────────────────────────────────────────────────────────
echo "-- lib: vocabulary, bake"
# Same two values as the Studio's DOMAIN_IDP_CHOICES.
CFG="${REPO}/studio/hugmesh_studio/core/config.py"
studio_sd="$(sed -n 's/^DOMAIN_IDP_SUPERDOMAIN = "\(.*\)"$/\1/p' "${CFG}")"
studio_own="$(sed -n 's/^DOMAIN_IDP_OWN = "\(.*\)"$/\1/p' "${CFG}")"
lib_sd="$(bash -c 'err(){ :; }; . "$1"; printf %s "${DOMAIN_IDP_SUPERDOMAIN}"' _ "${LIB}")"
lib_own="$(bash -c 'err(){ :; }; . "$1"; printf %s "${DOMAIN_IDP_OWN}"' _ "${LIB}")"
if [ -n "${studio_sd}" ] && [ -n "${studio_own}" ] && [ "${lib_sd}" = "${studio_sd}" ] && [ "${lib_own}" = "${studio_own}" ]; then
    ok "lib vocabulary (${lib_own}|${lib_sd}) equals the Studio's DOMAIN_IDP_CHOICES"
else
    bad "lib vocabulary (${lib_own}|${lib_sd}) != Studio (${studio_own}|${studio_sd})"
fi

bake_case() {  # <label> <expected-file-content|-> <flags...>; sources the lib in a subshell
    local label="$1" want="$2"; shift 2
    local d="${SCR}/bake.$RANDOM"
    mkdir -p "${d}"
    # a stale file from an earlier build must not survive a build with no own domain
    printf 'stale.test=own\n' > "${d}/domain-idp"
    ( err() { echo "ERR $1" >&2; }; info() { :; }
      # shellcheck disable=SC1090
      . "${LIB}"
      for s in "$@"; do domain_idp_add "${s}"; done
      domain_idp_bake "${d}" ) || { bad "bake ${label}: the lib exited non-zero"; return; }
    if [ "${want}" = "-" ]; then
        if [ ! -e "${d}/domain-idp" ]; then ok "bake ${label}: no file (and the stale one is gone)"
        else bad "bake ${label}: wrote ${d}/domain-idp: $(cat "${d}/domain-idp")"; fi
    else
        if [ -f "${d}/domain-idp" ] && [ "$(cat "${d}/domain-idp")" = "${want}" ]; then ok "bake ${label}: exactly the own domains"
        else bad "bake ${label}: wrong content: $(cat "${d}/domain-idp" 2>&1 | tr '\n' '|')"; fi
    fi
}
bake_case "no flag"                      "-"
bake_case "only =superdomain"            "-"  a.test=superdomain b.test=superdomain
bake_case "one own"                      "a.test=own"  a.test=own
bake_case "own + superdomain + own"      "$(printf 'a.test=own\nc.test=own')"  a.test=own b.test=superdomain c.test=own

# ── 3. x86: the name must be one of --domains; --unaffiliated refuses the flag ─
echo "-- x86: --domains cross-check, --unaffiliated"
X86="${REPO}/build-x86-host-stage4.sh"
if [ -f "${X86}" ]; then
    run "${X86}" --role laptop --domains a.test,b.test --domain-idp b.test=own --print-plan
    if [ "${RC}" -eq 0 ] && grep -qx 'PLAN_DOMAIN_IDP=b.test' "${SCR}/out.txt"; then ok "x86: a --domain-idp name that is in --domains is accepted"
    else bad "x86: rejected a name that IS in --domains (rc=${RC})"; fi
    run "${X86}" --role laptop --domains a.test,b.test --domain-idp c.test=own --print-plan
    if [ "${RC}" -eq 1 ] && grep -q 'not in --domains' "${SCR}/out.txt"; then ok "x86: a name that is NOT in --domains is refused"
    else bad "x86: accepted a name that is not in --domains (rc=${RC})"; fi
    run "${X86}" --role laptop --unaffiliated --domain-idp c.test=own --print-plan
    if [ "${RC}" -eq 1 ] && grep -q -- '--unaffiliated conflicts with --domain-idp' "${SCR}/out.txt"; then ok "x86: --unaffiliated refuses --domain-idp"
    else bad "x86: --unaffiliated did not refuse --domain-idp (rc=${RC})"; fi
else
    bad "build-x86-host-stage4.sh is missing"
fi

echo
echo "== ${P} passed, ${F} failed, ${S} skipped =="
[ "${F}" -eq 0 ]
