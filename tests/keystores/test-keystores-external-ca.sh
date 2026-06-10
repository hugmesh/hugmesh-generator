#!/usr/bin/env bash
# test-keystores-external-ca.sh — integration test for the EXTERNAL-CA mode of
# scripts/gen-keystores.sh. Verifies that when an existing CA (CA_CERT + CA_KEY)
# is provided, every generated leaf is signed by THAT CA (chains to it, issuer =
# its CN), the truststore bundles it, the provided CA is never overwritten, the
# CA private key is never written into the output dir or printed, and that the
# negative paths (cert/key mismatch, only one of the pair) fail cleanly.
#
# Rootless; needs openssl + keytool + python3. (kubeadm seeding is exercised by
# gen-provision-keys.sh, not here.)
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${REPO}/scripts/gen-keystores.sh"
BRAND="${BRAND:-snapdragon}"
# Mirror scripts/gen-keystores.sh SERVICES (the Java machine-users that get an
# mTLS identity keystore).
EXPECT=("${BRAND}-pki-gateway" "${BRAND}-be-gateway" "${BRAND}-fe-gateway"
        "${BRAND}-api" "${BRAND}-admin-bff-api" "${BRAND}-mod-bff-api" "${BRAND}-user-bff-api")

for t in openssl keytool python3; do command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
pw(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["services"][sys.argv[2]] if len(sys.argv)>2 else d["truststore"])' "$1" "${@:2}"; }

echo "== gen-keystores EXTERNAL-CA integration test =="

# ── Throwaway external root CA with a DISTINCT CN ──────────────────
CADIR="${W}/ext-ca"; mkdir -p "${CADIR}"
CA_CN="External Test Root CA"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "${CADIR}/root.key" -out "${CADIR}/root.crt" \
  -subj "/O=ExtTest/CN=${CA_CN}" \
  -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1
CRT_SHA_BEFORE="$(sha256sum "${CADIR}/root.crt" | cut -d' ' -f1)"
KEY_SHA_BEFORE="$(sha256sum "${CADIR}/root.key" | cut -d' ' -f1)"

# ── 1) Generate with the external CA via flags ─────────────────────
OUT="${W}/out"
LOG="$(bash "${GEN}" "${OUT}" --ca-cert "${CADIR}/root.crt" --ca-key "${CADIR}/root.key" 2>&1)"
[ $? -eq 0 ] && ok "generator exits 0 with external CA" || { bad "generator failed: ${LOG}"; }

echo "${LOG}" | grep -q "Using PROVIDED external CA" && ok "announced external-CA issuer path" || bad "did not announce external CA"

# Provided CA published as the trust anchor, source untouched, key not leaked.
if cmp -s "${CADIR}/root.crt" "${OUT}/certs/cluster-ca.crt"; then ok "published cluster-ca.crt == provided CA"; else bad "cluster-ca.crt != provided CA"; fi
[ ! -f "${OUT}/certs/cluster-ca.key" ] && ok "CA private key NOT written into output dir" || bad "CA key leaked into output dir"
[ "$(sha256sum "${CADIR}/root.crt" | cut -d' ' -f1)" = "${CRT_SHA_BEFORE}" ] && ok "source CA cert untouched" || bad "source CA cert modified"
[ "$(sha256sum "${CADIR}/root.key" | cut -d' ' -f1)" = "${KEY_SHA_BEFORE}" ] && ok "source CA key untouched" || bad "source CA key modified"
echo "${LOG}" | grep -qc 'BEGIN .*PRIVATE KEY' && [ "$(echo "${LOG}" | grep -c 'BEGIN .*PRIVATE KEY')" -eq 0 ] 2>/dev/null
[ "$(echo "${LOG}" | grep -c 'BEGIN .*PRIVATE KEY')" -eq 0 ] && ok "no PEM key material in output" || bad "key material in output"

# ── Every leaf chains to + is issued by the PROVIDED CA ────────────
PWJSON="${OUT}/keystores/passwords.json"
for svc in "${EXPECT[@]}"; do
  ks="${OUT}/keystores/${svc}.keystore.jks"
  [ -f "${ks}" ] || { bad "${svc}: keystore missing"; continue; }
  keytool -exportcert -keystore "${ks}" -storepass "$(pw "${PWJSON}" "${svc}")" -alias "${svc}" -rfc 2>/dev/null > "${W}/leaf.pem"
  if openssl verify -CAfile "${CADIR}/root.crt" "${W}/leaf.pem" >/dev/null 2>&1; then ok "${svc}: verifies against PROVIDED CA"; else bad "${svc}: does NOT verify against provided CA"; fi
  openssl x509 -in "${W}/leaf.pem" -noout -issuer 2>/dev/null | grep -q "${CA_CN}" && ok "${svc}: issuer = provided CA CN" || bad "${svc}: wrong issuer"
done

# ── Truststore bundles the provided CA ─────────────────────────────
keytool -exportcert -keystore "${OUT}/keystores/truststore.jks" -storepass "$(pw "${PWJSON}")" \
  -alias "${BRAND}-cluster-ca" -rfc 2>/dev/null > "${W}/ts.pem"
tsfp="$(openssl x509 -in "${W}/ts.pem" -noout -fingerprint -sha256 2>/dev/null)"
cafp="$(openssl x509 -in "${CADIR}/root.crt" -noout -fingerprint -sha256 2>/dev/null)"
[ -n "${tsfp}" ] && [ "${tsfp}" = "${cafp}" ] && ok "truststore.jks contains the PROVIDED CA" || bad "truststore CA != provided CA"

# ── 2) Negative: cert/key MISMATCH -> non-zero + clear message ──────
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "${CADIR}/wrong.key" 2>/dev/null
MLOG="$(bash "${GEN}" "${W}/out-mismatch" --ca-cert "${CADIR}/root.crt" --ca-key "${CADIR}/wrong.key" 2>&1)"; mrc=$?
[ "${mrc}" -ne 0 ] && ok "mismatch exits non-zero (rc=${mrc})" || bad "mismatch did not fail"
echo "${MLOG}" | grep -q "does not match" && ok "mismatch prints a clear error" || bad "mismatch error unclear"
[ "$(echo "${MLOG}" | grep -c 'BEGIN .*PRIVATE KEY')" -eq 0 ] && ok "no key material on mismatch" || bad "key material on mismatch"

# ── 3) Negative: only one of the pair -> 'provide BOTH' ────────────
OLOG="$(bash "${GEN}" "${W}/out-one" --ca-cert "${CADIR}/root.crt" 2>&1)"; orc=$?
[ "${orc}" -ne 0 ] && echo "${OLOG}" | grep -q "provide BOTH" && ok "single-half input -> 'provide BOTH' error" || bad "single-half input not rejected"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
