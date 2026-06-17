#!/usr/bin/env bash
# test-self-report.sh — unit tests for the node-side ONE-SHOT LIVENESS self-report
# (snapdragon-device-enrollment-report) of the machine_key_fp AUTO-CAPTURE flow.
#
# WHAT IT DOES (runs ANYWHERE with bash — no live BFF, no curl, no node): it SOURCES
# the real script (its main() is guarded behind a BASH_SOURCE check so sourcing does
# NOT run the POST flow), then exercises the pure helpers that build the request:
#   * json_escape — the fp/hostname/mesh are OPAQUE tokens spliced into a JSON body;
#     a backslash / double-quote / tab must be escaped so the body stays valid JSON
#     and the fingerprint is carried BYTE-FOR-BYTE (never mangled — an fp mismatch
#     fails closed everywhere downstream).
#   * read_env — the bare KEY=VALUE node.env reader (shared transport contract with
#     the Layer-B sync agent) reads MACHINE_KEY_FP exactly, not a normalised form.
# Plus a static contract check: the script targets the mTLS /bff/internal/** path
# (NO JWT) and the provision hook invokes it best-effort.

set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT="${REPO}/specs/usr/sbin/snapdragon-device-enrollment-report"
PROVISION="${REPO}/specs/etc/keys-provision/provision.sh"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }

[ -r "${SCRIPT}" ] || { echo "self-report script missing (${SCRIPT})"; exit 2; }

# Source the real script (main is guarded out when sourced).
# shellcheck source=/dev/null
. "${SCRIPT}"

echo "-- json_escape: opaque tokens are carried byte-for-byte (valid JSON) --"
# A plain fingerprint passes through unchanged (byte-for-byte — the load-bearing rule).
got="$(json_escape 'nodekey:abc+/DEF123==')"
[ "${got}" = 'nodekey:abc+/DEF123==' ] \
    && ok "plain fingerprint unchanged" \
    || bad "plain fingerprint mangled -> '${got}'"

# A double-quote is escaped (so it cannot break out of the JSON string).
got="$(json_escape 'ho"st')"
[ "${got}" = 'ho\"st' ] \
    && ok "double-quote escaped" \
    || bad "double-quote not escaped -> '${got}'"

# A backslash is escaped.
got="$(json_escape 'a\b')"
[ "${got}" = 'a\\b' ] \
    && ok "backslash escaped" \
    || bad "backslash not escaped -> '${got}'"

echo "-- the composed body is valid JSON with the exact fingerprint --"
fp='nodekey:OPAQUE+TOKEN/xyz=='
host='node-1'
mesh='east-01'
tn='ts-1'
body="$(printf '{"machineKeyFp":"%s","hostname":"%s","meshId":"%s","tailnetId":"%s"}' \
    "$(json_escape "${fp}")" "$(json_escape "${host}")" "$(json_escape "${mesh}")" "$(json_escape "${tn}")")"
if command -v jq >/dev/null 2>&1; then
    parsed_fp="$(printf '%s' "${body}" | jq -r '.machineKeyFp' 2>/dev/null)"
    [ "${parsed_fp}" = "${fp}" ] \
        && ok "body parses + machineKeyFp is byte-identical to the baked fp" \
        || bad "fp drift through the body: got '${parsed_fp}' != '${fp}'"
    printf '%s' "${body}" | jq -e '.hostname=="node-1" and .meshId=="east-01"' >/dev/null 2>&1 \
        && ok "body carries the reconciliation hints" \
        || bad "body missing/incorrect hints"
else
    echo "  (jq absent — skipping body-parse asserts)"
fi

echo "-- read_env reads a bare KEY=VALUE exactly (shared node.env contract) --"
TMPENV="$(mktemp)"; trap 'rm -f "${TMPENV}"' EXIT
cat > "${TMPENV}" <<EOF
MACHINE_KEY_FP=nodekey:EXACT+VALUE/==
MESH_ID=east-01
BFF_EXPORT_URL=https://admin-bff.snapdragon-backend.svc:8443
EOF
NODE_ENV="${TMPENV}"
got="$(read_env MACHINE_KEY_FP)"
[ "${got}" = 'nodekey:EXACT+VALUE/==' ] \
    && ok "read_env returns the fingerprint byte-for-byte" \
    || bad "read_env mangled the fp -> '${got}'"
got="$(read_env MESH_ID)"
[ "${got}" = 'east-01' ] && ok "read_env reads MESH_ID" || bad "read_env MESH_ID -> '${got}'"

echo "-- contract: mTLS /bff/internal path (NO JWT) + best-effort provision hook --"
grep -q '/bff/internal/device-enrollment/self-report' "${SCRIPT}" \
    && ok "targets the mTLS /bff/internal/** self-report path (no JWT)" \
    || bad "self-report path not /bff/internal/**"
# Presents an mTLS client cert (Layer-B transport), never a bearer token. We only flag
# an ACTUAL bearer/token in a curl/header line — the prose "NO JWT" in comments is fine.
grep -q -- '--cert' "${SCRIPT}" \
    && ! grep -Eqi 'authorization:[[:space:]]*bearer|-H[^#]*bearer|bff_token=|--header[^#]*bearer' "${SCRIPT}" \
    && ok "presents an mTLS client cert, never a JWT/bearer token" \
    || bad "self-report uses a JWT/bearer (should be mTLS only)"
grep -q 'snapdragon-device-enrollment-report' "${PROVISION}" \
    && ok "provision.sh invokes the one-shot self-report" \
    || bad "provision.sh does NOT invoke the self-report"
# The hook must be best-effort (|| true) so a failed report never blocks boot.
grep -q 'snapdragon-device-enrollment-report 2>/dev/null || true' "${PROVISION}" \
    && ok "provision hook is best-effort (|| true, never blocks boot)" \
    || bad "provision hook is NOT best-effort"

echo ""
echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
