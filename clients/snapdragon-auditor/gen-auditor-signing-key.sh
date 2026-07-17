#!/usr/bin/env bash
# gen-auditor-signing-key.sh — generate the Snapdragon Auditor RELEASE signing
# key (one-time, OFFLINE), mirroring scripts/gen-keystores.sh's key-custody
# posture: this key is generated on a machine that will never leave the org's
# control and its output NEVER gets committed. The key is the long-term trust
# root for every Snapdragon Auditor install — losing it breaks update
# continuity for every device that already trusts it.
#
# Storage: keep the generated .jks (and its password) on the pki USB / Vault,
# the SAME custody chain scripts/gen-keystores.sh uses for the cluster CA key
# (cluster-ca.key). Do NOT leave a copy under this repo's working tree beyond
# a throwaway/local test — the default OUTDIR below lives under the
# already-gitignored /keys-out/ tree for exactly this reason (defense in
# depth; the root .gitignore also has explicit *.jks / keystore.properties
# patterns in case OUTDIR is ever pointed elsewhere inside the repo).
#
# Output (under OUTDIR):
#   <alias>-release.jks   the release keystore (PKCS12-format JKS; EC secp256r1)
#
# This script does NOT build or sign an APK — see sign-and-digest.sh for that,
# and build.Dockerfile for the (unsigned, keystore-free) APK build.
#
# The digest printed at the end is the AttestationServer <-> Auditor-fork
# COUPLING value — see COUPLING.md. It must be set as BOTH:
#   - the AttestationServer Dockerfile's AUDITOR_SIGNER_DIGEST build ARG
#     (specs/cluster/manifests/attestation-server/Dockerfile)
#   - phone-wizard's --apk-signer-sha256 pin (scripts/phone-wizard.sh)
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/../.." && pwd)"

ALIAS="snapdragon-auditor"
VALIDITY_DAYS=10000
OUT="${REPO}/keys-out/auditor-signing"

usage() {
  cat <<EOF
Usage: $0 [OUTDIR] [--alias NAME] [--validity DAYS]

  Generates the Snapdragon Auditor release signing key (EC secp256r1,
  SHA256withECDSA, PKCS12-format JKS) into OUTDIR/<alias>-release.jks, offline.
  Prints the SHA-256-of-DER-signing-cert digest — the value that couples this
  key to the self-hosted AttestationServer's AUDITOR_SIGNER_DIGEST config and
  phone-wizard's --apk-signer-sha256 pin (see COUPLING.md).

  Refuses to overwrite an existing keystore at the target path.

Options:
  OUTDIR            Output directory. Default: ${OUT}
                     (under the repo's already-gitignored keys-out/ tree —
                     move the result to the pki USB / Vault; do not keep it
                     in a repo checkout long-term.)
  --alias NAME       Key alias. Default: ${ALIAS}
  --validity DAYS    Certificate validity in days. Default: ${VALIDITY_DAYS}
  -h, --help          Show this help.

Requires: keytool, openssl.
EOF
  exit "${1:-0}"
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias)    ALIAS="$2"; shift 2 ;;
    --validity) VALIDITY_DAYS="$2"; shift 2 ;;
    -h|--help)  usage 0 ;;
    --)         shift; break ;;
    -*)         echo "ERROR: unknown option: $1" >&2; usage 1 ;;
    *)          OUT="$1"; shift ;;
  esac
done

for t in keytool openssl; do
  command -v "${t}" >/dev/null 2>&1 || { echo "ERROR: need ${t}" >&2; exit 1; }
done

mkdir -p "${OUT}"
KEYSTORE="${OUT}/${ALIAS}-release.jks"

if [ -f "${KEYSTORE}" ]; then
  echo "ERROR: refusing to overwrite existing keystore: ${KEYSTORE}" >&2
  echo "       (this is the long-term Auditor release-signing trust root —" >&2
  echo "       generating a new one breaks update continuity for every" >&2
  echo "       device that already trusts the old one. Move/rename the" >&2
  echo "       existing file first if you really mean to replace it.)" >&2
  exit 1
fi

echo "==> This is a LONG-TERM signing key. Move ${KEYSTORE} (and its store" >&2
echo "    password) to the pki USB / Vault immediately after this script" >&2
echo "    exits — do not leave it sitting in a repo checkout." >&2
echo >&2

echo -n "Enter a store/key password for the new keystore (input hidden): " >&2
read -rs STOREPASS
echo >&2
if [ -z "${STOREPASS}" ]; then
  echo "ERROR: empty password refused" >&2
  exit 1
fi
echo -n "Confirm password: " >&2
read -rs STOREPASS_CONFIRM
echo >&2
if [ "${STOREPASS}" != "${STOREPASS_CONFIRM}" ]; then
  echo "ERROR: passwords did not match" >&2
  exit 1
fi

echo "==> Generating EC secp256r1 release key (alias: ${ALIAS}, validity: ${VALIDITY_DAYS}d)" >&2
keytool -genkeypair -v \
  -keystore "${KEYSTORE}" \
  -alias "${ALIAS}" \
  -keyalg EC -groupname secp256r1 \
  -sigalg SHA256withECDSA \
  -validity "${VALIDITY_DAYS}" \
  -storetype PKCS12 \
  -storepass:env STOREPASS \
  -dname "CN=Snapdragon Auditor, O=Snapdragon, OU=Auditor Release Signing" \
  -noprompt >&2

chmod 600 "${KEYSTORE}"
unset STOREPASS_CONFIRM

echo "==> Keystore written: ${KEYSTORE}" >&2
echo >&2
echo "==> Computing signing-cert SHA-256 digest (method a: from the keystore" >&2
echo "    directly, per patches.md §2.2/spec — keytool -exportcert emits DER" >&2
echo "    by default; do NOT add -rfc). This is the value that seeds BOTH:" >&2
echo "      - AttestationServer's AUDITOR_SIGNER_DIGEST build ARG" >&2
echo "        (specs/cluster/manifests/attestation-server/Dockerfile)" >&2
echo "      - phone-wizard's --apk-signer-sha256 pin" >&2
echo >&2

DIGEST="$(
  keytool -exportcert -alias "${ALIAS}" -keystore "${KEYSTORE}" -storepass:env STOREPASS \
    | openssl dgst -sha256 -r \
    | awk '{print toupper($1)}'
)"
unset STOREPASS

echo "AUDITOR_SIGNER_DIGEST=${DIGEST}"
echo >&2
echo "==> Cross-check (method b, apksigner --print-certs) is NOT run here —" >&2
echo "    it needs a built+signed APK, which does not exist yet at key-gen" >&2
echo "    time. After you build+sign a release (sign-and-digest.sh), that" >&2
echo "    script re-derives the SAME digest from the shipped APK via" >&2
echo "    'apksigner verify --print-certs' as a sanity check that the right" >&2
echo "    keystore/alias was used. The two values MUST match; a mismatch" >&2
echo "    means the wrong keystore/alias was used for that build." >&2
