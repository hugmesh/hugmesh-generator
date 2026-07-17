#!/usr/bin/env bash
# sign-and-digest.sh — sign the unsigned Snapdragon Auditor release APK
# (produced by build.Dockerfile) with the OFFLINE release keystore (produced
# by gen-auditor-signing-key.sh), then print the shipped APK's signer-cert
# SHA-256 digest as a sanity check against the value already configured on
# the AttestationServer + phone-wizard side (see COUPLING.md).
#
# The keystore path is ALWAYS an argument — it is never embedded in this
# script, never defaulted to a path inside this repo, and never logged. Run
# this on the same offline machine (or a machine with the pki USB / Vault
# keystore mounted) that holds the release key — never copy the keystore
# onto a build server or into a container image.
set -euo pipefail

usage() {
  cat <<EOF
Usage: $0 --unsigned APK --keystore JKS --alias NAME --out APK [--ks-pass-env VAR]

  Signs an unsigned Auditor release APK with the offline release keystore and
  prints the resulting signer-cert SHA-256 digest (uppercase hex, no colons —
  the format AttestationProtocol.java's comparison and phone-wizard's
  --apk-signer-sha256 both expect).

Options:
  --unsigned APK      Path to app-release-unsigned.apk (from build.Dockerfile's
                       export stage).
  --keystore JKS       Path to the release keystore (from
                       gen-auditor-signing-key.sh). NEVER a path inside a
                       container build context — mount/reference it from
                       wherever the pki USB / Vault checkout actually is.
  --alias NAME         Key alias inside the keystore. Default: snapdragon-auditor
  --out APK            Where to write the signed app-release.apk.
  --ks-pass-env VAR    Name of an environment variable already holding the
                       keystore/key password. If omitted, you will be
                       prompted (password is never accepted as a CLI arg, to
                       keep it off argv/process listings).
  -h, --help           Show this help.

Requires: apksigner, openssl (for the -r digest fallback path, unused by
default since apksigner already emits the right format).
EOF
  exit "${1:-0}"
}

UNSIGNED=""
KEYSTORE=""
ALIAS="snapdragon-auditor"
OUT_APK=""
PASS_ENV=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --unsigned)    UNSIGNED="$2"; shift 2 ;;
    --keystore)    KEYSTORE="$2"; shift 2 ;;
    --alias)       ALIAS="$2"; shift 2 ;;
    --out)         OUT_APK="$2"; shift 2 ;;
    --ks-pass-env) PASS_ENV="$2"; shift 2 ;;
    -h|--help)     usage 0 ;;
    *)             echo "ERROR: unknown argument: $1" >&2; usage 1 ;;
  esac
done

[ -n "${UNSIGNED}" ] || { echo "ERROR: --unsigned is required" >&2; usage 1; }
[ -n "${KEYSTORE}" ] || { echo "ERROR: --keystore is required" >&2; usage 1; }
[ -n "${OUT_APK}" ]  || { echo "ERROR: --out is required" >&2; usage 1; }
[ -f "${UNSIGNED}" ] || { echo "ERROR: unsigned APK not found: ${UNSIGNED}" >&2; exit 1; }
[ -f "${KEYSTORE}" ] || { echo "ERROR: keystore not found: ${KEYSTORE}" >&2; exit 1; }

command -v apksigner >/dev/null 2>&1 \
  || { echo "ERROR: apksigner not found (Android SDK build-tools; e.g. dev-util/android-sdk-build-tools)" >&2; exit 1; }

if [ -n "${PASS_ENV}" ]; then
  [ -n "${!PASS_ENV:-}" ] || { echo "ERROR: env var ${PASS_ENV} is empty/unset" >&2; exit 1; }
  KS_PASS_ARG="pass:${!PASS_ENV}"
else
  echo -n "Enter the keystore/key password for alias '${ALIAS}' (input hidden): " >&2
  read -rs KS_PASS_RAW
  echo >&2
  [ -n "${KS_PASS_RAW}" ] || { echo "ERROR: empty password refused" >&2; exit 1; }
  KS_PASS_ARG="pass:${KS_PASS_RAW}"
fi

echo "==> Signing $(basename "${UNSIGNED}") -> ${OUT_APK}" >&2
apksigner sign \
  --ks "${KEYSTORE}" \
  --ks-key-alias "${ALIAS}" \
  --ks-pass "${KS_PASS_ARG}" \
  --key-pass "${KS_PASS_ARG}" \
  --out "${OUT_APK}" \
  "${UNSIGNED}"
unset KS_PASS_RAW KS_PASS_ARG

echo "==> Verifying signature" >&2
apksigner verify "${OUT_APK}"

echo "==> Signer-cert SHA-256 digest (method b, per patches.md §2.2 / spec —" >&2
echo "    apksigner prints lowercase hex with no colons; uppercased below" >&2
echo "    since AttestationProtocol.java's comparison is case-sensitive" >&2
echo "    uppercase). Cross-check this against the value" >&2
echo "    gen-auditor-signing-key.sh printed (method a) — they MUST be" >&2
echo "    identical, or the wrong keystore/alias was used for this build:" >&2
echo >&2

DIGEST="$(
  apksigner verify --print-certs "${OUT_APK}" \
    | grep 'Signer #1 certificate SHA-256 digest' \
    | awk '{print $NF}' | tr 'a-z' 'A-Z'
)"

echo "AUDITOR_SIGNER_DIGEST=${DIGEST}"
echo >&2
echo "==> This is the AttestationServer <-> Auditor-fork coupling value —" >&2
echo "    see COUPLING.md. It must match:" >&2
echo "      - AttestationServer's AUDITOR_SIGNER_DIGEST build ARG" >&2
echo "        (specs/cluster/manifests/attestation-server/Dockerfile)" >&2
echo "      - phone-wizard's --apk-signer-sha256 pin" >&2
echo "    A mismatch there means the server will REJECT every attestation" >&2
echo "    from this build, silently (no partial-credit path)." >&2
