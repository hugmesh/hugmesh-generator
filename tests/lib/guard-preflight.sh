# shellcheck shell=bash
# guard-preflight.sh — a guard that cannot run must go RED, never green.
#
# THE DEFECT THIS EXISTS TO KILL
# ------------------------------
# The repo's habitual preflight was
#
#     for t in openssl keytool python3; do
#       command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }
#     done
#
# On a workstation that is honest ("I can't run this"). In CI it is a lie: the
# job's image decides which tools exist, so the line silently converts "this
# runner has no JDK" into "these keystores are correct". Exactly that shipped in
# this lane: orphan-guards-verify ran on `alpine:3`, which carries no JDK, so
# tests/keystores/test-keystores{,-external-ca,-multidomain}.sh printed
# "SKIP: need keytool" and exited 0 for every pipeline — three guards wired in
# and checking nothing — while tests/scripts/test-headscale-oidc-secret-staging.sh
# went hard RED from the same missing keytool. A guard that skips, and a job that
# is red for an environmental reason: both halves of the disease at once.
#
# THE POSTURE (the same one tests/scripts/test-eso-seed-contract.sh uses)
# ----------------------------------------------------------------------
#   * missing tooling is a FAILURE, exit 1, naming what is missing;
#   * a human at a terminal may opt out DELIBERATELY with
#         GUARD_TOOLING_ALLOW_SKIP=1
#     and gets a loud, distinguishable SKIP line;
#   * CI never sets that variable, and that is not a promise — it is checked.
#     tests/scripts/test-guard-integrity.sh fails if the name appears anywhere in
#     .gitlab-ci.yml, and fails if any suite a CI batch job runs still carries the
#     old `SKIP … exit 0` shape.
#
# Sourced as:  . "$(dirname "${BASH_SOURCE[0]}")/../lib/guard-preflight.sh"

# guard_skip_allowed — true only for the explicit, deliberate local opt-out.
guard_skip_allowed() { [ "${GUARD_TOOLING_ALLOW_SKIP:-0}" = "1" ]; }

guard__opt_out_note() {
    echo "      (DELIBERATE local opt-out. CI never sets this variable, and"
    echo "       tests/scripts/test-guard-integrity.sh fails if .gitlab-ci.yml"
    echo "       ever mentions it — so the CI path cannot reach this branch.)"
}

# guard_require_tools <tool>... — every tool must be on PATH, or the suite dies.
guard_require_tools() {
    local missing="" t
    for t in "$@"; do
        command -v "${t}" >/dev/null 2>&1 || missing="${missing} ${t}"
    done
    [ -z "${missing}" ] && return 0
    if guard_skip_allowed; then
        echo "SKIP: missing${missing} and GUARD_TOOLING_ALLOW_SKIP=1 was set"
        guard__opt_out_note
        exit 0
    fi
    echo "  FAIL missing required tool(s):${missing}"
    echo "       This guard cannot run without them, and exiting 0 would report a"
    echo "       property as verified that was never looked at. Install them, or"
    echo "       set GUARD_TOOLING_ALLOW_SKIP=1 to opt out deliberately (never in"
    echo "       CI: a CI runner missing a tool is a broken job image, not a pass)."
    exit 1
}

# guard_require_capability <description> — for probes that need more than a
# binary on PATH (an algorithm the local openssl was built without, say). Used as
#     openssl genpkey -algorithm ed25519 -out "$f" || \
#         guard_require_capability "openssl cannot mint ed25519 keys"
guard_require_capability() {
    local what="$1"
    if guard_skip_allowed; then
        echo "SKIP: ${what} and GUARD_TOOLING_ALLOW_SKIP=1 was set"
        guard__opt_out_note
        exit 0
    fi
    echo "  FAIL ${what}"
    echo "       The guard needs it; without it nothing below is checked, so this"
    echo "       is a failure and not a pass. Set GUARD_TOOLING_ALLOW_SKIP=1 to"
    echo "       opt out deliberately (never in CI)."
    exit 1
}
