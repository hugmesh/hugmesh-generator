#!/usr/bin/env bash
# test-vpn-reconcile-verify.sh — unit test for /usr/lib/snapdragon/vpn-verify.sh
# (the egress-VPN signed-export consumer, PR5).
#
# Proves, WITHOUT a node / a live BFF (ephemeral Ed25519 key + a hand-built signed
# envelope whose canonical bytes match VpnExportService.canonicalBytes):
#   * vpn_canonical_bytes reconstructs the v1-vpn body EXACTLY (header + sorted
#     entries) — asserted against a reference string;
#   * vpn_verify_export ACCEPTS a correctly-signed envelope against the BAKED pub;
#   * it REJECTS a tampered body (signature no longer covers the bytes);
#   * it REJECTS an unsigned envelope (signed=false / signature=null) — fail-closed;
#   * it REJECTS a FOREIGN key (signed by a different key than the baked pub);
#   * the strict-monotonic guard ACCEPTS gen>last-good and REJECTS gen<=last-good
#     (rollback).
#
# This mirrors tests/device-registry/test-registry-allow-deny.sh's approach (build
# the canonical bytes the JVM would, sign with openssl Ed25519, verify the bash
# consumer round-trips). End-to-end equality with a LIVE BFF payload is a
# needs-node check (documented in the PR body).
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
LIB="${REPO}/specs/usr/lib/snapdragon/vpn-verify.sh"
[ -r "${LIB}" ] || { echo "  FAIL verify lib missing: ${LIB}"; exit 1; }
for t in openssl jq base64; do command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done

# shellcheck source=/dev/null
. "${LIB}" || { echo "  FAIL could not source ${LIB}"; exit 1; }

P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
WORK="$(mktemp -d)"; trap 'rm -rf "${WORK}"' EXIT

echo "== vpn-verify.sh consumer unit test =="

# ── Ephemeral signing key + the baked public half ─────────────────────────────
PRIV="${WORK}/priv.pem"; PUB_PEM="${WORK}/pub.pem"; PUB_B64="${WORK}/registry-pub.ed25519"
openssl genpkey -algorithm ed25519 -out "${PRIV}" 2>/dev/null || { echo "SKIP: no ed25519"; exit 0; }
openssl pkey -in "${PRIV}" -pubout -out "${PUB_PEM}" 2>/dev/null
# The baked pub is base64 of the X.509 SPKI DER (== RegistrySigner.publicKeyBase64()).
openssl pkey -pubin -in "${PUB_PEM}" -outform DER 2>/dev/null | base64 -w0 > "${PUB_B64}"

# A second (foreign) key, for the foreign-key rejection case.
FPRIV="${WORK}/foreign.pem"
openssl genpkey -algorithm ed25519 -out "${FPRIV}" 2>/dev/null

# ── Build the canonical bytes the JVM (VpnExportService.canonicalBytes) emits ──
# v1-vpn\n node=..\n generation=..\n then one cfg= line per entry (sorted by name).
NODE="mkey:abc"; GEN=7
canon() {
  printf 'v1-vpn\n'
  printf 'node=%s\n' "${NODE}"
  printf 'generation=%s\n' "${GEN}"
  printf 'cfg=%s\tkind=%s\tsecret=%s\tendpoint=%s\tservices=%s\n' \
         "proton-us" "wireguard" "ref-1" "1.2.3.4:51820" "coturn"
}
CANON="${WORK}/canon.bin"; canon > "${CANON}"

# Sign the canonical bytes (detached Ed25519, raw input — matches the JVM).
SIG_B64="$(openssl pkeyutl -sign -inkey "${PRIV}" -rawin -in "${CANON}" 2>/dev/null | base64 -w0)"
FSIG_B64="$(openssl pkeyutl -sign -inkey "${FPRIV}" -rawin -in "${CANON}" 2>/dev/null | base64 -w0)"

# Build the signed envelope JSON the agent fetches (SignedVpnExport shape).
envelope() {  # $1=signature-b64 (or "null" literal) ; $2=signed-bool ; $3=secretRef
  local sig="$1" signed="$2" sref="${3:-ref-1}"
  local sigfield
  if [ "${sig}" = "null" ]; then sigfield='null'; else sigfield="\"${sig}\""; fi
  cat <<JSON
{
  "body": {
    "node": "${NODE}",
    "generation": ${GEN},
    "entries": [
      { "configName": "proton-us", "kind": "wireguard", "secretRef": "${sref}",
        "endpoint": "1.2.3.4:51820", "serviceSlugs": ["coturn"] }
    ]
  },
  "contentHash": "x",
  "signature": ${sigfield},
  "publicKey": "advertised-ignored",
  "signed": ${signed}
}
JSON
}

# ── Case 1: canonical reconstruction matches the reference byte-for-byte ────────
GOOD="${WORK}/good.json"; envelope "${SIG_B64}" "true" > "${GOOD}"
RECON="${WORK}/recon.bin"; vpn_canonical_bytes "${GOOD}" > "${RECON}" 2>/dev/null
if cmp -s "${CANON}" "${RECON}"; then ok "vpn_canonical_bytes matches the JVM reference bytes"; else
  bad "canonical reconstruction DIVERGED from the reference"; echo "    want:"; xxd "${CANON}" | head -3; echo "    got:"; xxd "${RECON}" | head -3
fi

# ── Case 2: ACCEPT a correctly-signed envelope (no gen guard) ──────────────────
if vpn_verify_export "${GOOD}" "${PUB_B64}"; then ok "ACCEPT a correctly-signed export"; else bad "rejected a valid export"; fi

# ── Case 3: REJECT a tampered body (secretRef changed; sig no longer covers it) ─
TAMPER="${WORK}/tamper.json"; envelope "${SIG_B64}" "true" "ref-EVIL" > "${TAMPER}"
if vpn_verify_export "${TAMPER}" "${PUB_B64}"; then bad "ACCEPTED a tampered body (LEAK)"; else ok "REJECT a tampered body"; fi

# ── Case 4: REJECT an unsigned envelope (fail-closed) ──────────────────────────
UNSIGNED="${WORK}/unsigned.json"; envelope "null" "false" > "${UNSIGNED}"
if vpn_verify_export "${UNSIGNED}" "${PUB_B64}"; then bad "ACCEPTED an unsigned export"; else ok "REJECT an unsigned export (fail-closed)"; fi

# ── Case 5: REJECT a foreign-key signature ─────────────────────────────────────
FOREIGN="${WORK}/foreign.json"; envelope "${FSIG_B64}" "true" > "${FOREIGN}"
if vpn_verify_export "${FOREIGN}" "${PUB_B64}"; then bad "ACCEPTED a foreign-key signature"; else ok "REJECT a foreign-key signature"; fi

# ── Case 6: strict-monotonic guard ─────────────────────────────────────────────
LG="${WORK}/last-good"; printf '5' > "${LG}"
if vpn_verify_export "${GOOD}" "${PUB_B64}" "${LG}"; then ok "ACCEPT gen=7 > last-good=5 (forward step)"; else bad "rejected a valid forward generation"; fi
printf '7' > "${LG}"
if vpn_verify_export "${GOOD}" "${PUB_B64}" "${LG}"; then bad "ACCEPTED gen=7 == last-good=7 (replay)"; else ok "REJECT gen==last-good (replay)"; fi
printf '9' > "${LG}"
if vpn_verify_export "${GOOD}" "${PUB_B64}" "${LG}"; then bad "ACCEPTED gen=7 < last-good=9 (rollback)"; else ok "REJECT gen<last-good (rollback)"; fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
