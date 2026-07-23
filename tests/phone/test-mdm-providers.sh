#!/usr/bin/env bash
# test-mdm-providers.sh — offline unit test for the MDM PROVIDER REGISTRY
# (specs/usr/lib/hugmesh/mdm-providers.sh), the sourceable data+emit library
# the phone wizard drives. Mirrors tests/go-live/test-go-live-driver.sh's
# conventions for the go-live provider registry (P/F counters, mktemp+trap,
# source-the-lib-and-assert-its-contract).
#
# Runs ANYWHERE with just bash — NO root, NO network, NO device, NO adb. It
# sources the registry and asserts:
#   (a) the registry shape: MDM_PROVIDER_IDS + the parallel assoc arrays cover
#       exactly the same id set, no orphan/missing rows.
#   (b) the DEFAULT provider is the SOVEREIGN one (headwind), and it is first.
#   (c) accessors: known/label/mechanism/status/sovereignty for both providers.
#   (d) mechanisms are the two expected kinds (dpc-adb sovereign, os-enrollment
#       cloud) — the split the driver branches on instead of hard-coding ids.
#   (e) emit: mdmp_emit renders a runbook per provider; unknown id -> rc 2;
#       the azure runbook carries the Graph remoteLock + unlock-asymmetry +
#       sovereignty-forfeiture narration and the supplied intune device id;
#       and NO tenant/client-secret material is ever emitted by the registry
#       (secret custody is server-side only).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/specs/usr/lib/hugmesh/mdm-providers.sh"
[ -r "${LIB}" ] || { echo "  FAIL registry lib missing: ${LIB}"; exit 1; }
command -v bash >/dev/null || { echo "SKIP: need bash"; exit 0; }

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}" 2>/dev/null' EXIT

echo "== MDM provider registry: offline unit test =="

# shellcheck source=specs/usr/lib/hugmesh/mdm-providers.sh
source "${LIB}"

# ── (a) registry shape: ids vs the parallel arrays ──────────────────────────
[ "${#MDM_PROVIDER_IDS[@]}" -ge 2 ] && ok "(a) MDM_PROVIDER_IDS has >=2 providers (${MDM_PROVIDER_IDS[*]})" \
    || bad "(a) MDM_PROVIDER_IDS too small: ${MDM_PROVIDER_IDS[*]:-none}"
SHAPE_OK=1
for id in "${MDM_PROVIDER_IDS[@]}"; do
    for arr in MDM_PROVIDER_LABEL MDM_PROVIDER_MECH MDM_PROVIDER_STATUS MDM_PROVIDER_SOVEREIGNTY MDM_PROVIDER_EMITS; do
        declare -n ref="${arr}"
        [ -n "${ref[$id]:-}" ] || { bad "(a) ${arr} missing a row for '${id}'"; SHAPE_OK=0; }
        unset -n ref
    done
    declare -F "mdmp_emit_${id}" >/dev/null || { bad "(a) no mdmp_emit_${id} function for '${id}'"; SHAPE_OK=0; }
done
[ "${SHAPE_OK}" -eq 1 ] && ok "(a) every id has a full row (label/mech/status/sovereignty/emits) + an mdmp_emit_<id>"
# no orphan array keys beyond the id list
for id in "${!MDM_PROVIDER_LABEL[@]}"; do
    printf '%s\n' "${MDM_PROVIDER_IDS[@]}" | grep -qx "${id}" \
        || bad "(a) MDM_PROVIDER_LABEL has an orphan key '${id}' not in MDM_PROVIDER_IDS"
done

# ── (b) DEFAULT = the sovereign provider, first in the list ─────────────────
[ "$(mdmp_default)" = "headwind" ] && ok "(b) mdmp_default is headwind (the sovereign default)" \
    || bad "(b) mdmp_default='$(mdmp_default)', want headwind"
[ "${MDM_PROVIDER_IDS[0]}" = "headwind" ] && ok "(b) headwind is FIRST (prioritised sovereign row)" \
    || bad "(b) first id is '${MDM_PROVIDER_IDS[0]}', want headwind"
mdmp_is_sovereign "$(mdmp_default)" && ok "(b) the default provider is sovereign" \
    || bad "(b) the default provider is not sovereign"

# ── (c) accessors ───────────────────────────────────────────────────────────
mdmp_known headwind && mdmp_known azure-intune && ok "(c) mdmp_known true for both providers" \
    || bad "(c) mdmp_known failed for a known provider"
! mdmp_known not-a-provider && ok "(c) mdmp_known false for an unknown provider" \
    || bad "(c) mdmp_known true for an unknown provider"
[ -n "$(mdmp_label headwind)" ] && [ -n "$(mdmp_label azure-intune)" ] \
    && ok "(c) mdmp_label non-empty for both" || bad "(c) mdmp_label empty"
mdmp_is_full headwind && mdmp_is_full azure-intune && ok "(c) both providers are status=full" \
    || bad "(c) a provider is not full"

# ── (d) mechanisms: the split the driver branches on ────────────────────────
[ "$(mdmp_mechanism headwind)" = "dpc-adb" ] && ok "(d) headwind mechanism = dpc-adb" \
    || bad "(d) headwind mechanism = '$(mdmp_mechanism headwind)', want dpc-adb"
[ "$(mdmp_mechanism azure-intune)" = "os-enrollment" ] && ok "(d) azure-intune mechanism = os-enrollment" \
    || bad "(d) azure-intune mechanism = '$(mdmp_mechanism azure-intune)', want os-enrollment"
[ "$(mdmp_sovereignty headwind)" = "sovereign" ] && [ "$(mdmp_sovereignty azure-intune)" = "cloud" ] \
    && ok "(d) sovereignty: headwind=sovereign, azure-intune=cloud" \
    || bad "(d) sovereignty wrong (headwind=$(mdmp_sovereignty headwind), azure=$(mdmp_sovereignty azure-intune))"

# ── (e) emit: per-provider runbook + dispatch + secret hygiene ──────────────
mdmp_emit not-a-provider "${WORK}"; RC=$?
[ "${RC}" -eq 2 ] && ok "(e) mdmp_emit unknown id -> rc 2" || bad "(e) mdmp_emit unknown id rc=${RC}, want 2"

HW_OUT="${WORK}/hw"; mkdir -p "${HW_OUT}"
MDMP_HEADWIND_URL="https://headwind.test.invalid" mdmp_emit headwind "${HW_OUT}"; RC=$?
[ "${RC}" -eq 0 ] && [ -s "${HW_OUT}/runbook.txt" ] && grep -q 'dpm set-device-owner' "${HW_OUT}/runbook.txt" \
    && grep -qi 'sovereign' "${HW_OUT}/runbook.txt" \
    && ok "(e) headwind emit: runbook with the adb device-owner + sovereign narration" \
    || bad "(e) headwind emit wrong (rc=${RC})"

AZ_OUT="${WORK}/az"; mkdir -p "${AZ_OUT}"
INTUNE_ID="12345678-90ab-cdef-1234-567890abcdef"
MDMP_INTUNE_DEVICE_ID="${INTUNE_ID}" mdmp_emit azure-intune "${AZ_OUT}"; RC=$?
RB="${AZ_OUT}/runbook.txt"
[ "${RC}" -eq 0 ] && [ -s "${RB}" ] && ok "(e) azure-intune emit exits 0 with a runbook" \
    || { bad "(e) azure-intune emit rc=${RC}"; }
grep -q 'remoteLock' "${RB}" && ok "(e) azure runbook documents the Graph remoteLock mechanism" \
    || bad "(e) azure runbook missing remoteLock"
grep -qi 'UNLOCK ASYMMETRY' "${RB}" && grep -qi 'does NOT push a credential' "${RB}" \
    && ok "(e) azure runbook documents the unlock asymmetry" || bad "(e) azure runbook missing the unlock asymmetry"
grep -qi 'FORFEITS the sovereign' "${RB}" && ok "(e) azure runbook carries the sovereignty-forfeiture caveat" \
    || bad "(e) azure runbook missing the sovereignty caveat"
grep -qi 'NOT over adb' "${RB}" && ok "(e) azure runbook states enrollment is OS-level, not adb dpm" \
    || bad "(e) azure runbook does not distinguish os-enrollment from adb"
grep -qF "${INTUNE_ID}" "${RB}" && ok "(e) azure runbook echoes the supplied intune device id" \
    || bad "(e) azure runbook missing the supplied intune device id"

# SECRET HYGIENE: the registry must NEVER emit tenant/client-secret material —
# custody is server-side (admin-bff) only. Emit with hostile-looking env creds
# present and prove none of them reach the runbook.
FAKE_TENANT="TENANTSECRET-should-never-appear"
FAKE_SECRET="CLIENTSECRET-should-never-appear"
LEAK_OUT="${WORK}/leak"; mkdir -p "${LEAK_OUT}"
TENANT_ID="${FAKE_TENANT}" CLIENT_SECRET="${FAKE_SECRET}" AZURE_CLIENT_SECRET="${FAKE_SECRET}" \
    MDMP_INTUNE_DEVICE_ID="${INTUNE_ID}" mdmp_emit azure-intune "${LEAK_OUT}" >/dev/null 2>&1
if grep -qF "${FAKE_TENANT}" "${LEAK_OUT}/runbook.txt" || grep -qF "${FAKE_SECRET}" "${LEAK_OUT}/runbook.txt"; then
    bad "(e) SECRET HYGIENE: azure credential material leaked into the registry runbook"
else
    ok "(e) SECRET HYGIENE: no tenant/client-secret material in the emitted runbook (custody is server-side only)"
fi

echo
echo "== mdm-providers registry test: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ] || exit 1
exit 0
