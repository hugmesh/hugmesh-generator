#!/usr/bin/env bash
# test-download-verify.sh — unit test for scripts/_download-lib.sh, the shared
# supply-chain download-verification helper used by the image builders.
#
# Proves, WITHOUT any network access, the core security property: verification
# ABORTS (non-zero) on a tampered checksum and PASSES (zero) on a correct one.
# Covers the raw sha256/sha512 helpers and the publisher-manifest helper
# (tailscale SHA256SUMS / headscale checksums.txt format), including the
# fail-closed behaviour when a basename is absent from the manifest.
#
# Run: bash tests/scripts/test-download-verify.sh
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/scripts/_download-lib.sh"
[ -f "${LIB}" ] || { echo "  FAIL helper missing: ${LIB}"; exit 1; }

# shellcheck source=/dev/null
DLV_QUIET=1 source "${LIB}"

P=0; F=0
ok()  { echo "  PASS $*"; P=$((P+1)); }
bad() { echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== _download-lib.sh verification unit test =="

# ── Fixtures ──────────────────────────────────────────────────────────────────
ART="${WORK}/tailscale_1.76.10_arm64.tgz"
printf 'pretend-tailscale-tarball-bytes\n' > "${ART}"
GOOD256="$(sha256sum "${ART}" | awk '{print $1}')"
GOOD512="$(sha512sum "${ART}" | awk '{print $1}')"
BAD256="$(printf '%064d' 0)"   # 64 zero hex chars — definitely not the real hash

# ── 1. sha256: correct hash PASSES ──────────────────────────────────────────
if dlv_verify_sha256 "${ART}" "${GOOD256}" >/dev/null 2>&1; then
  ok "dlv_verify_sha256 returns 0 on a correct checksum"
else
  bad "dlv_verify_sha256 should PASS on a correct checksum"
fi

# ── 2. sha256: tampered hash ABORTS (non-zero) ──────────────────────────────
if dlv_verify_sha256 "${ART}" "${BAD256}" >/dev/null 2>&1; then
  bad "dlv_verify_sha256 should ABORT (non-zero) on a mismatched checksum"
else
  ok "dlv_verify_sha256 returns non-zero on a tampered checksum"
fi

# ── 3. sha256: tampered FILE (same expected hash) ABORTS ────────────────────
TAMPERED="${WORK}/tampered.tgz"
printf 'pretend-tailscale-tarball-bytes-MUTATED\n' > "${TAMPERED}"
if dlv_verify_sha256 "${TAMPERED}" "${GOOD256}" >/dev/null 2>&1; then
  bad "dlv_verify_sha256 should ABORT when the file bytes were tampered"
else
  ok "dlv_verify_sha256 catches a tampered file (bytes changed, hash unchanged)"
fi

# ── 4. sha512: correct hash PASSES ──────────────────────────────────────────
if dlv_verify_sha512 "${ART}" "${GOOD512}" >/dev/null 2>&1; then
  ok "dlv_verify_sha512 returns 0 on a correct checksum"
else
  bad "dlv_verify_sha512 should PASS on a correct checksum"
fi

# ── 5. empty expected hash FAILS CLOSED ─────────────────────────────────────
if dlv_verify_sha256 "${ART}" "" >/dev/null 2>&1; then
  bad "dlv_verify_sha256 should FAIL CLOSED on an empty expected hash"
else
  ok "dlv_verify_sha256 fails closed on an empty expected hash"
fi

# ── 6. publisher manifest (SHA256SUMS): matching line PASSES ────────────────
SUMS="${WORK}/SHA256SUMS"
{
  printf '%s  tailscale_1.76.10_amd64.tgz\n' "${BAD256}"
  printf '%s  %s\n' "${GOOD256}" "$(basename "${ART}")"   # our arm64 line
  printf '%s *some_other_artifact.bin\n' "${BAD256}"
} > "${SUMS}"
if dlv_verify_from_sumsfile "${ART}" "$(basename "${ART}")" "${SUMS}" sha256 >/dev/null 2>&1; then
  ok "dlv_verify_from_sumsfile PASSES when the basename line matches"
else
  bad "dlv_verify_from_sumsfile should PASS on a matching manifest line"
fi

# ── 7. publisher manifest: tampered line for our basename ABORTS ────────────
SUMS_BAD="${WORK}/SHA256SUMS.bad"
printf '%s  %s\n' "${BAD256}" "$(basename "${ART}")" > "${SUMS_BAD}"
if dlv_verify_from_sumsfile "${ART}" "$(basename "${ART}")" "${SUMS_BAD}" sha256 >/dev/null 2>&1; then
  bad "dlv_verify_from_sumsfile should ABORT when the manifest hash is wrong"
else
  ok "dlv_verify_from_sumsfile ABORTS when the manifest hash for our basename is wrong"
fi

# ── 8. publisher manifest: basename ABSENT fails closed ─────────────────────
if dlv_verify_from_sumsfile "${ART}" "not-in-the-manifest.tgz" "${SUMS}" sha256 >/dev/null 2>&1; then
  bad "dlv_verify_from_sumsfile should FAIL CLOSED when the basename is absent"
else
  ok "dlv_verify_from_sumsfile fails closed when the basename is absent from the manifest"
fi

# ── 9. substring safety: a basename that is a SUFFIX of another must not match ─
# Manifest only lists 'xtailscale_1.76.10_arm64.tgz'; verifying the real
# basename must NOT accidentally match the longer line.
SUMS_SUB="${WORK}/SHA256SUMS.sub"
printf '%s  x%s\n' "${GOOD256}" "$(basename "${ART}")" > "${SUMS_SUB}"
if dlv_verify_from_sumsfile "${ART}" "$(basename "${ART}")" "${SUMS_SUB}" sha256 >/dev/null 2>&1; then
  bad "dlv_verify_from_sumsfile must not match a basename that is only a suffix of a manifest entry"
else
  ok "dlv_verify_from_sumsfile rejects a suffix-only basename match (anchored compare)"
fi

# ── 10. stage3 DIGESTS parser: SHA512 line for our basename is preferred ─────
# Reproduce the awk extraction dlv_verify_stage3 uses against a Gentoo-format
# DIGESTS body (algo markers + "<hex>  <name>" lines) WITHOUT needing GPG/network.
STAGE3="${WORK}/stage3-arm64-openrc-20260601T000000Z.tar.xz"
printf 'pretend-stage3-bytes\n' > "${STAGE3}"
S3_512="$(sha512sum "${STAGE3}" | awk '{print $1}')"
S3_256="$(sha256sum "${STAGE3}" | awk '{print $1}')"
DIGESTS="${WORK}/${STAGE3##*/}.DIGESTS"
{
  printf '# BLAKE2B HASH\n'
  printf 'deadbeef  %s\n' "$(basename "${STAGE3}")"
  printf '# SHA512 HASH\n'
  printf '%s  %s\n' "${S3_512}" "$(basename "${STAGE3}")"
  printf '# SHA256 HASH\n'
  printf '%s  %s\n' "${S3_256}" "$(basename "${STAGE3}")"
} > "${DIGESTS}"

extract_512="$(awk -v f="$(basename "${STAGE3}")" '
  /^#[[:space:]]*SHA512/ { algo="sha512"; next }
  /^#[[:space:]]*SHA256/ { algo="sha256"; next }
  /^#/ { algo=""; next }
  { for (i=1;i<=NF;i++) if ($i==f && algo=="sha512") { print $1; exit } }
' "${DIGESTS}")"
if [ "${extract_512}" = "${S3_512}" ]; then
  ok "stage3 DIGESTS awk extracts the SHA512 line for the matching basename"
else
  bad "stage3 DIGESTS awk should extract the SHA512 hash (got '${extract_512}')"
fi

# Verify the extracted hash actually validates the tarball, and a mutated
# tarball is rejected against the same DIGESTS hash.
if dlv_verify_sha512 "${STAGE3}" "${extract_512}" >/dev/null 2>&1; then
  ok "stage3 tarball verifies against the DIGESTS SHA512"
else
  bad "stage3 tarball should verify against the DIGESTS SHA512"
fi
printf 'pretend-stage3-bytes-TAMPERED\n' > "${STAGE3}.bad"
if dlv_verify_sha512 "${STAGE3}.bad" "${extract_512}" >/dev/null 2>&1; then
  bad "a tampered stage3 must FAIL against the DIGESTS SHA512"
else
  ok "a tampered stage3 ABORTS against the DIGESTS SHA512"
fi

# ── 11. builder wiring: EVERY stage4 builder sources the lib + verifies ──────
# Regression guard for the x86 port: each builder must source _download-lib.sh,
# verify the stage3 seed (dlv_verify_stage3), verify headscale against the
# release checksums.txt (dlv_verify_from_sumsfile) and tailscale against its
# .sha256 sidecar (dlv_verify_sha256_sidecar). A builder silently dropping any
# of these re-opens the unverified-download supply-chain hole.
for b in build-rpi5-stage4.sh build-frite-stage4.sh build-jetson-stage4.sh build-x86-host-stage4.sh; do
  BF="${REPO}/${b}"
  [ -f "${BF}" ] || { bad "${b}: builder missing"; continue; }
  grep -qE 'source .*(_download-lib\.sh)' "${BF}" \
    && ok "${b}: sources scripts/_download-lib.sh" || bad "${b}: does not source _download-lib.sh"
  grep -q 'dlv_verify_stage3' "${BF}" \
    && ok "${b}: verifies the stage3 seed (dlv_verify_stage3)" || bad "${b}: stage3 seed not verified"
  grep -q 'dlv_verify_from_sumsfile' "${BF}" \
    && ok "${b}: verifies headscale against checksums.txt" || bad "${b}: headscale not checksum-verified"
  grep -q 'dlv_verify_sha256_sidecar' "${BF}" \
    && ok "${b}: verifies tailscale against its .sha256 sidecar" || bad "${b}: tailscale not checksum-verified"
done

echo "== done: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
