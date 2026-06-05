#!/usr/bin/env bash
# gen-keystores.sh — generate the per-API machine-user JKS keystores + the
# shared truststore for the Snapdragon cluster, from a single cluster CA.
#
# Each Java API/UI machine user (the Spring Cloud Gateways + Spring services)
# gets its own JKS keystore (private key + CA-signed cert) used as its mTLS
# identity when talking to other namespaces. A single truststore (built from the
# cluster CA chain) is what every Java JRE/JDK trusts — it is installed into the
# container's JRE at runtime (built from the certs on the USB KEYS stick).
#
# Output (under OUTDIR):
#   certs/cluster-ca.crt           the cluster CA (trust anchor; goes on the KEYS stick)
#   certs/cluster-ca.key           CA private key (KEEP OFFLINE; pki stick only)
#   keystores/<svc>.keystore.jks   per-service identity keystore (key + cert chain)
#   keystores/truststore.jks       trust store (cluster CA) — JKS
#   keystores/truststore.p12       trust store — PKCS12 (for non-keytool consumers)
#   keystores/passwords.json       store passwords (offline/USB fallback)
#
# Two cert paths exist:
#   • OFFLINE / USB (this script): the cluster CA (cluster-ca.crt is the trust
#     anchor that goes on every KEYS stick) + per-service fallback keystores.
#     keys-provision installs the truststore into each node's JRE from the USB.
#   • IN-CLUSTER (preferred): Vault PKI imports THIS cluster CA (provisioned to
#     the vault ns as the "cluster-ca" Secret from the pki USB) and issues a
#     short-lived cert per app; External Secrets Operator syncs each into a
#     <app>-mtls TLS Secret and the workload assembles its JKS/PKCS12 keystore
#     at startup. See specs/cluster/manifests/vault-pki + .../external-secrets.
# Because the in-cluster certs chain to this same cluster CA, the offline
# truststore validates them. The CA private key never leaves the pki USB / Vault.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(cd "${HERE}/.." && pwd)"
[ -f "${REPO}/brand.conf" ] && . "${REPO}/brand.conf" || true
DOMAIN="${CLUSTER_DOMAIN:-snapdragon.systems}"
BRAND="${BRAND:-snapdragon}"

OUT="${1:-${REPO}/keys-out}"
KS="${OUT}/keystores"
CA="${OUT}/certs"
KEYALG="RSA"; KEYBITS=2048; DAYS=825

# Java API machine-users that get an mTLS identity keystore: "name:namespace".
# (Casdoor=Go, Synapse=Python, Mastodon=Ruby are not Java; they consume the same
#  CA via PEM and are issued certs by gen-cluster-secrets if needed.)
SERVICES=(
  "${BRAND}-pki-gateway:${BRAND}-pki"
  "${BRAND}-be-gateway:${BRAND}-backend"
  "${BRAND}-fe-gateway:${BRAND}-frontend"
  "${BRAND}-auth:${BRAND}-pki"
  "${BRAND}-api:${BRAND}-backend"
  "admin-bff:${BRAND}-backend"
)

for t in openssl keytool; do command -v "$t" >/dev/null || { echo "ERROR: need $t" >&2; exit 1; }; done
mkdir -p "${KS}" "${CA}"
randpass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# ── Cluster CA (reuse if present, else create) ─────────────────────
if [ ! -f "${CA}/cluster-ca.crt" ] || [ ! -f "${CA}/cluster-ca.key" ]; then
  echo "==> Generating cluster CA"
  openssl req -x509 -newkey "${KEYALG}:${KEYBITS}" -nodes -days 3650 \
    -keyout "${CA}/cluster-ca.key" -out "${CA}/cluster-ca.crt" \
    -subj "/O=${BRAND} cluster/CN=${BRAND} Cluster CA" 2>/dev/null
else
  echo "==> Reusing existing cluster CA at ${CA}/cluster-ca.crt"
fi

# ── Truststore (cluster CA) — JKS + PKCS12 ─────────────────────────
TS_PASS="$(randpass)"
rm -f "${KS}/truststore.jks" "${KS}/truststore.p12"
keytool -importcert -noprompt -alias "${BRAND}-cluster-ca" \
  -file "${CA}/cluster-ca.crt" -keystore "${KS}/truststore.jks" \
  -storetype JKS -storepass "${TS_PASS}" 2>/dev/null
openssl pkcs12 -export -nokeys -in "${CA}/cluster-ca.crt" \
  -out "${KS}/truststore.p12" -passout "pass:${TS_PASS}" -name "${BRAND}-cluster-ca"
echo "==> Truststore built (JKS + PKCS12)"

# ── Per-service identity keystores ─────────────────────────────────
PW_JSON="{\"truststore\":\"${TS_PASS}\",\"services\":{"
first=1
for entry in "${SERVICES[@]}"; do
  svc="${entry%%:*}"; ns="${entry##*:}"
  cn="${svc}.${ns}.svc.cluster.local"
  pass="$(randpass)"
  tmp="$(mktemp -d)"
  echo "  - ${svc} (CN=${cn})"
  openssl genpkey -algorithm "${KEYALG}" -pkeyopt "rsa_keygen_bits:${KEYBITS}" -out "${tmp}/key.pem" 2>/dev/null
  openssl req -new -key "${tmp}/key.pem" -out "${tmp}/csr.pem" -subj "/O=${BRAND}/CN=${cn}" 2>/dev/null
  cat > "${tmp}/ext" <<EXT
subjectAltName = DNS:${cn},DNS:${svc}.${ns},DNS:${svc}.${DOMAIN}
extendedKeyUsage = serverAuth,clientAuth
keyUsage = digitalSignature,keyEncipherment
EXT
  openssl x509 -req -in "${tmp}/csr.pem" -CA "${CA}/cluster-ca.crt" -CAkey "${CA}/cluster-ca.key" \
    -CAcreateserial -days "${DAYS}" -extfile "${tmp}/ext" -out "${tmp}/cert.pem" 2>/dev/null
  cat "${tmp}/cert.pem" "${CA}/cluster-ca.crt" > "${tmp}/chain.pem"
  # key + chain -> PKCS12 -> JKS (mTLS identity; trusts the CA too)
  openssl pkcs12 -export -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" -certfile "${CA}/cluster-ca.crt" \
    -name "${svc}" -out "${tmp}/${svc}.p12" -passout "pass:${pass}"
  keytool -importkeystore -noprompt \
    -srckeystore "${tmp}/${svc}.p12" -srcstoretype PKCS12 -srcstorepass "${pass}" \
    -destkeystore "${KS}/${svc}.keystore.jks" -deststoretype JKS -deststorepass "${pass}" 2>/dev/null
  rm -rf "${tmp}"
  [ "${first}" = 1 ] || PW_JSON+=","
  PW_JSON+="\"${svc}\":\"${pass}\""; first=0
done
PW_JSON+="}}"
printf '%s\n' "${PW_JSON}" | (command -v jq >/dev/null && jq . || cat) > "${KS}/passwords.json"
chmod 0600 "${KS}/passwords.json" "${CA}/cluster-ca.key" 2>/dev/null || true

echo "==> Done. Keystores in ${KS}:"
ls -1 "${KS}"
