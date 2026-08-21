#!/usr/bin/env bash
# test-nullmailer-cross-postinst.sh — EXECUTED-DECISION test for the first-boot
# nullmailer ownership re-fix (issue #60 item 7) in the SHARED first-boot
# finaliser, specs/etc/local.d/01-firstboot.start.tmpl.
#
# WHY THIS EXISTS
# mail-mta/nullmailer-2.2-r2's pkg_postinst chowns BY NAME with `|| die`. Under
# the cross builders' ROOT=<sysroot> merges (--root-deps=rdeps + --with-bdeps=n)
# the ebuild's own BDEPEND="acct-user/nullmail" never merges to /, so the chown
# runs on the x86 build host against the HOST passwd and dies. Portage treats a
# postinst die as non-critical, so the image still BUILDS — it just ships a mail
# spool the nullmail daemon cannot write to. The template repairs that at first
# boot. Nothing else in the tree tests that repair, and it is exactly the shape
# that rots silently: a template block nobody executes, plus per-builder copy
# plumbing that a functional test of ONE builder cannot see.
#
# GROUND TRUTH (measured, not assumed) — out/sessions/20260815-154029-05f5d2,
# wl-be.rpi5/sysroot, the run PR #73 was written against:
#     /etc/passwd                              nullmail:x:88:88   (present!)
#     /var/log/nullmailer                      root:root  770
#     /var/spool/nullmailer/{tmp,queue,failed} root:root  755
#     /var/spool/nullmailer/trigger            root:root  660 (fifo EXISTS)
#     /etc/nullmailer/remotes                  root:nullmail 0640 (already ok)
# Case B below replays exactly that state.
#
# HERMETIC: no network, no root, no build, no container. The block is extracted
# from the real template and executed with chown/chmod/mkfifo/getent shims on
# PATH that RECORD their arguments, and with the block's absolute paths rebound
# to a temp root (a non-root test cannot create /var/spool/nullmailer). The
# CONTROL FLOW and the REPORTING DECISION executed are the real ones.
#
# What is asserted, in order:
#   A. coverage parity  every operation nullmailer's pkg_postinst performs is
#                       reproduced by the block (5 chown targets, 4 chmod 770,
#                       trigger 660, remotes root:nullmail + 0640, fifo 0660)
#   B. repair           replaying the REAL damaged sysroot state issues exactly
#                       those calls and reports success
#   C. honesty/failure  a failing chown yields a WARNING on stderr and NO
#                       success line (the pre-fix code printed success anyway)
#   D. honesty/absent   a missing acct-user is REPORTED, not silently skipped
#   E. honesty/missing  a missing spool dir is named on stderr
#   F. no-op            no nullmailer installed => completely silent, rc 0
#   G. copy plumbing    ALL ten stage4 builders render the SHARED template and
#                       chmod +x it, and enable OpenRC `local` in every role
#                       branch — the file is useless in an image that does not
#                       run it, and a per-arch/per-role gap is invisible in the
#                       template itself (the #60-item-1 trap shape).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TMPL="${REPO}/specs/etc/local.d/01-firstboot.start.tmpl"
[ -f "${TMPL}" ] || { echo "  FAIL template missing: ${TMPL}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P + 1)); }
bad() { echo "  FAIL $*"; F=$((F + 1)); }

WORK="$(mktemp -d)"
trap 'rm -rf "${WORK}"' EXIT

# ── extract the block from the REAL template ─────────────────────────────────
# Bounded by two stable anchors in the template so the fragment can never run
# on past the block (an over-capturing extractor makes every later assertion
# meaningless). Both anchors are asserted present before the cut.
BLOCK="${WORK}/block.sh"
grep -q '^# ── nullmailer ownership re-fix' "${TMPL}" \
    || { echo "  FAIL template has no nullmailer re-fix block"; exit 1; }
grep -q '^if \[ -b /dev/nvme0n1 \]; then' "${TMPL}" \
    || { echo "  FAIL template lost the NVMe anchor that bounds the block"; exit 1; }
awk '/^# ── nullmailer ownership re-fix/{f=1}
     /^if \[ -b \/dev\/nvme0n1 \]; then/{f=0}
     f{print}' "${TMPL}" > "${BLOCK}.raw"
[ -s "${BLOCK}.raw" ] || { echo "  FAIL extracted block is empty"; exit 1; }
bash -n "${BLOCK}.raw" || { echo "  FAIL extracted block is not valid bash"; exit 1; }

echo "=== A. coverage parity with mail-mta/nullmailer pkg_postinst ==="
# The ebuild's pkg_postinst tail, verbatim in effect:
#   mkfifo --mode=0660 trigger (when absent)
#   chown nullmail:nullmail  /var/log/nullmailer + spool/{tmp,queue,failed,trigger}
#   chmod 770                /var/log/nullmailer + spool/{tmp,queue,failed}
#   chmod 660                spool/trigger
#   chmod 0640               /etc/nullmailer/remotes
#   chown root:nullmail      /etc/nullmailer/remotes
need_re=(
  'mkfifo --mode=0660 /var/spool/nullmailer/trigger'
  '/var/log/nullmailer'
  '/var/spool/nullmailer/tmp'
  '/var/spool/nullmailer/queue'
  '/var/spool/nullmailer/failed'
  '/var/spool/nullmailer/trigger'
  'chmod 660 /var/spool/nullmailer/trigger'
  'chown root:nullmail /etc/nullmailer/remotes'
  'chmod 0640 /etc/nullmailer/remotes'
  'chmod 770'
)
for r in "${need_re[@]}"; do
    if grep -qF -- "${r}" "${BLOCK}.raw"; then ok "block covers: ${r}"
    else bad "block does NOT cover the postinst operation: ${r}"; fi
done
# The pre-fix shape: suppressing every error and announcing success anyway.
if grep -qE 'chown[^|]*2>/dev/null \|\| true' "${BLOCK}.raw"; then
    bad "block still swallows chown errors with '2>/dev/null || true'"
else
    ok "block no longer swallows chown/chmod errors"
fi

# ── shim harness ─────────────────────────────────────────────────────────────
# Rebind the block's absolute paths into a temp root and record every call.
mk_case() {
    local root="$1"
    sed -e "s#/var/spool/nullmailer#${root}/var/spool/nullmailer#g" \
        -e "s#/var/log/nullmailer#${root}/var/log/nullmailer#g" \
        -e "s#/etc/nullmailer#${root}/etc/nullmailer#g" \
        "${BLOCK}.raw" > "${root}/run.sh"
}
mk_shims() { # <root> <getent_rc> <chown_rc>
    local root="$1" grc="$2" crc="$3" bin="$1/bin"
    mkdir -p "${bin}"
    cat > "${bin}/getent" <<SH
#!/usr/bin/env bash
echo "getent \$*" >> "${root}/calls"
exit ${grc}
SH
    cat > "${bin}/chown" <<SH
#!/usr/bin/env bash
echo "chown \$*" >> "${root}/calls"
exit ${crc}
SH
    cat > "${bin}/chmod" <<SH
#!/usr/bin/env bash
echo "chmod \$*" >> "${root}/calls"
exit 0
SH
    cat > "${bin}/mkfifo" <<SH
#!/usr/bin/env bash
echo "mkfifo \$*" >> "${root}/calls"
exit 0
SH
    chmod +x "${bin}"/*
}
run_case() { # <root>  -> stdout in $root/out, stderr in $root/err, rc in $root/rc
    local root="$1"
    ( PATH="${root}/bin:${PATH}"; bash "${root}/run.sh" ) \
        > "${root}/out" 2> "${root}/err"; echo $? > "${root}/rc"
}

echo
echo "=== B. replay of the REAL 08-15 damaged cross sysroot ==="
B="${WORK}/b"; mkdir -p "${B}"
mkdir -p "${B}/var/log/nullmailer" "${B}/var/spool/nullmailer"/{tmp,queue,failed} "${B}/etc/nullmailer"
mkfifo "${B}/var/spool/nullmailer/trigger"          # the fifo DID get created
: > "${B}/etc/nullmailer/remotes"
mk_shims "${B}" 0 0; mk_case "${B}"; run_case "${B}"
calls="$(cat "${B}/calls" 2>/dev/null || true)"
# Asserted as (operation, path) COVERAGE, not as an exact argv: whether the
# block chowns five paths in one call or in five is a refactor detail, but
# missing any one of them is the defect.
assert_call() { # <op-prefix> <path> <label>
    if grep -q "^$1 " <<<"${calls}" && grep -qF -- "$2" <<<"$(grep "^$1 " <<<"${calls}")"; then
        ok "issued: $1 ... $3"
    else
        bad "did NOT issue: $1 ... $3"
    fi
}
for d in var/log/nullmailer var/spool/nullmailer/tmp \
         var/spool/nullmailer/queue var/spool/nullmailer/failed; do
    assert_call "chown nullmail:nullmail" "${B}/${d}" "/${d}"
    assert_call "chmod 770"               "${B}/${d}" "/${d}"
done
assert_call "chown nullmail:nullmail" "${B}/var/spool/nullmailer/trigger" "/var/spool/nullmailer/trigger"
assert_call "chmod 660"               "${B}/var/spool/nullmailer/trigger" "/var/spool/nullmailer/trigger"
assert_call "chown root:nullmail"     "${B}/etc/nullmailer/remotes"       "/etc/nullmailer/remotes"
assert_call "chmod 0640"              "${B}/etc/nullmailer/remotes"       "/etc/nullmailer/remotes"
grep -q 'mkfifo' <<<"${calls}" && bad "re-created an EXISTING trigger fifo (not idempotent)" \
                               || ok "existing trigger fifo left alone (idempotent)"
grep -q 're-applied postinst ownership' "${B}/out" && ok "reported success on a clean repair" \
                                                   || bad "no success line on a clean repair"
[ -s "${B}/err" ] && bad "wrote to stderr on a clean repair: $(cat "${B}/err")" \
                  || ok "clean repair is quiet on stderr"

echo
echo "=== C. a FAILING chown must warn, not claim success ==="
C="${WORK}/c"; mkdir -p "${C}"
mkdir -p "${C}/var/log/nullmailer" "${C}/var/spool/nullmailer"/{tmp,queue,failed} "${C}/etc/nullmailer"
mkfifo "${C}/var/spool/nullmailer/trigger"; : > "${C}/etc/nullmailer/remotes"
mk_shims "${C}" 0 1; mk_case "${C}"; run_case "${C}"      # chown exits 1
grep -q 're-applied postinst ownership' "${C}/out" \
    && bad "claimed success while every chown FAILED (the pre-fix defect)" \
    || ok "did not claim success while chown failed"
grep -qi 'WARNING' "${C}/err" && ok "warned on stderr when the re-fix failed" \
                              || bad "failed re-fix produced no warning"
grep -q 'emerge --config mail-mta/nullmailer' "${C}/err" \
    && ok "warning names the operator recovery step" || bad "warning gives no recovery step"

echo
echo "=== D. absent acct-user must be REPORTED, not silently skipped ==="
D="${WORK}/d"; mkdir -p "${D}"
mkdir -p "${D}/var/spool/nullmailer"
mk_shims "${D}" 2 0; mk_case "${D}"; run_case "${D}"      # getent exits 2 (no user)
grep -qi 'WARNING' "${D}/err" && ok "absent 'nullmail' user is reported on stderr" \
                              || bad "absent 'nullmail' user vanished silently (premise unverified)"
grep -q 'chown' "${D}/calls" 2>/dev/null && bad "chowned despite the user being absent" \
                                         || ok "no chown attempted without the user"

echo
echo "=== E. a MISSING spool dir is named ==="
E="${WORK}/e"; mkdir -p "${E}"
mkdir -p "${E}/var/spool/nullmailer"/{tmp,queue} "${E}/var/log/nullmailer"   # 'failed' absent
mkfifo "${E}/var/spool/nullmailer/trigger"
mk_shims "${E}" 0 0; mk_case "${E}"; run_case "${E}"
grep -q 'MISSING' "${E}/err" && ok "missing spool dir named on stderr" || bad "missing spool dir not reported"
grep -q 're-applied postinst ownership' "${E}/out" \
    && bad "claimed success with a spool dir missing" || ok "no success line with a spool dir missing"

echo
echo "=== F. nullmailer not installed => silent no-op ==="
G="${WORK}/f"; mkdir -p "${G}"                          # no /var/spool/nullmailer at all
mk_shims "${G}" 0 0; mk_case "${G}"; run_case "${G}"
[ -s "${G}/out" ] && bad "printed to stdout with nullmailer absent: $(cat "${G}/out")" \
                  || ok "silent on stdout with nullmailer absent"
[ -s "${G}/err" ] && bad "printed to stderr with nullmailer absent: $(cat "${G}/err")" \
                  || ok "silent on stderr with nullmailer absent"
[ "$(cat "${G}/rc")" = "0" ] && ok "rc 0 with nullmailer absent" || bad "non-zero rc with nullmailer absent"

echo
echo "=== G. copy plumbing: every builder renders the template AND runs local ==="
# A functional test of ONE builder cannot see a builder that was missed, and the
# repair is inert in any image whose default runlevel lacks OpenRC `local`.
builders=("${REPO}"/build-*-stage4.sh)
[ "${#builders[@]}" -eq 10 ] && ok "found 10 stage4 builders" \
                             || bad "expected 10 stage4 builders, found ${#builders[@]}"
for b in "${builders[@]}"; do
    n="$(basename "${b}")"
    grep -q 'render_template "${SHARED_SPECS}/etc/local.d/01-firstboot.start.tmpl"' "${b}" \
        && ok "${n} renders the SHARED first-boot template" \
        || bad "${n} does NOT render specs/etc/local.d/01-firstboot.start.tmpl"
    grep -q 'chmod +x "${SYSROOT}/etc/local.d/01-firstboot.start"' "${b}" \
        && ok "${n} makes it executable" || bad "${n} never chmod +x's the rendered finaliser"
    # Every runlevel service-list assignment in the builder must include `local`;
    # a role branch that omits it ships an image that never runs the finaliser.
    mapfile -t lists < <(grep -oE '^[[:space:]]*(DEFAULT_)?SVCS=\([^)]*\)' "${b}")
    if [ "${#lists[@]}" -eq 0 ]; then
        bad "${n} has no runlevel service list to check"
    else
        miss=0
        for l in "${lists[@]}"; do grep -qE '(\(| )local( |\))' <<<"${l}" || miss=1; done
        [ "${miss}" -eq 0 ] && ok "${n}: OpenRC 'local' in every role's runlevel list" \
                            || bad "${n}: a role's runlevel list omits 'local' — finaliser never runs"
    fi
done

echo
echo "RESULT: ${P} passed, ${F} failed"
[ "${F}" -eq 0 ]
