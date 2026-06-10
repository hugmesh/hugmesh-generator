#!/usr/bin/env bash
# test-keystores.sh — integration test for scripts/gen-keystores.sh.
# Verifies the generator produces a cluster CA, a valid per-API JKS keystore
# for every Java machine-user (PrivateKeyEntry, CA-signed, chain → cluster CA),
# and a truststore containing the cluster CA. Rootless; needs openssl + keytool.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
BRAND="${BRAND:-snapdragon}"
# Mirror scripts/gen-keystores.sh SERVICES (the Java machine-users that get an
# mTLS identity keystore).
EXPECT=("${BRAND}-pki-gateway" "${BRAND}-be-gateway" "${BRAND}-fe-gateway"
        "${BRAND}-api" "${BRAND}-admin-bff-api" "${BRAND}-mod-bff-api" "${BRAND}-user-bff-api")

for t in openssl keytool python3; do command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done

OUT="$(mktemp -d)"; trap 'rm -rf "${OUT}"' EXIT
P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
pw(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["services"][sys.argv[2]] if len(sys.argv)>2 else d["truststore"])' "${OUT}/keystores/passwords.json" "$@"; }

echo "== gen-keystores integration test =="
bash "${REPO}/scripts/gen-keystores.sh" "${OUT}" >/dev/null 2>&1 || { echo "  FAIL generator exited non-zero"; exit 1; }

[ -f "${OUT}/certs/cluster-ca.crt" ] && ok "cluster CA generated" || bad "cluster CA missing"
[ -f "${OUT}/keystores/passwords.json" ] && python3 -c "import json;json.load(open('${OUT}/keystores/passwords.json'))" 2>/dev/null \
  && ok "passwords.json is valid JSON" || bad "passwords.json invalid/missing"

TS_PASS="$(pw)"
keytool -list -keystore "${OUT}/keystores/truststore.jks" -storepass "${TS_PASS}" 2>/dev/null \
  | grep -q trustedCertEntry && ok "truststore.jks contains the cluster CA" || bad "truststore missing CA"
[ -f "${OUT}/keystores/truststore.p12" ] && ok "truststore.p12 (PKCS12) present" || bad "truststore.p12 missing"

for svc in "${EXPECT[@]}"; do
  ks="${OUT}/keystores/${svc}.keystore.jks"
  if [ ! -f "${ks}" ]; then bad "${svc}: keystore missing"; continue; fi
  out="$(keytool -list -v -keystore "${ks}" -storepass "$(pw "${svc}")" 2>/dev/null)"
  echo "${out}" | grep -q 'PrivateKeyEntry'                 && ok "${svc}: has private-key identity" || bad "${svc}: no PrivateKeyEntry"
  echo "${out}" | grep -q 'Certificate chain length: 2'      && ok "${svc}: cert chain → CA (len 2)"  || bad "${svc}: chain not anchored to CA"
  echo "${out}" | grep -q "Issuer: CN=${BRAND} Cluster CA"   && ok "${svc}: issued by cluster CA"     || bad "${svc}: wrong issuer"
done

# Cryptographically verify one service cert against the CA.
svc="${BRAND}-be-gateway"
keytool -exportcert -keystore "${OUT}/keystores/${svc}.keystore.jks" -storepass "$(pw "${svc}")" \
  -alias "${svc}" -rfc 2>/dev/null > "${OUT}/svc.pem"
if openssl verify -CAfile "${OUT}/certs/cluster-ca.crt" "${OUT}/svc.pem" >/dev/null 2>&1; then
  ok "${svc} cert verifies against the cluster CA (openssl)"
else bad "${svc} cert does NOT verify against the CA"; fi

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
