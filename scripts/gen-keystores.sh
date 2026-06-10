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
# Also honor a committed brand profile (brands/<BRAND>.conf) so a value set via
# `make ... BRAND=acme` / the profile (incl. optional CA_CERT/CA_KEY) is picked
# up. brand.conf (above) still wins over the profile for the same vars unless
# the profile re-sets them; env/CLI (parsed below) win over both.
if [ -n "${BRAND:-}" ] && [ -f "${REPO}/brands/${BRAND}.conf" ]; then
  # shellcheck disable=SC1090
  . "${REPO}/brands/${BRAND}.conf"
fi
DOMAIN="${CLUSTER_DOMAIN:-snapdragon.systems}"
BRAND="${BRAND:-snapdragon}"

# ── External CA inputs (optional) ──────────────────────────────────
# Provide an EXISTING CA to use as the issuer for every generated leaf cert,
# instead of minting a fresh self-signed root. Accepted via (lowest→highest
# precedence): brand.conf / brands/<BRAND>.conf  <  env  <  CLI flags below.
#   CA_CERT       path to the CA certificate (PEM)
#   CA_KEY        path to the CA private key (PEM; may be encrypted)
#   CA_KEY_PASS   passphrase for CA_KEY (only if the key is encrypted)
# When CA_CERT+CA_KEY are absent, the original self-signed-root behavior is kept.
CA_CERT="${CA_CERT:-}"
CA_KEY="${CA_KEY:-}"
CA_KEY_PASS="${CA_KEY_PASS:-}"

# ── Arg parsing: positional OUTDIR (back-compat) + optional CA flags ─
OUT=""
usage_keystores() {
  cat <<EOF
Usage: $0 [OUTDIR] [--ca-cert FILE] [--ca-key FILE] [--ca-key-pass VAL]

  Generates the cluster CA (or uses a provided one), the per-service mTLS
  keystores, and the shared truststore under OUTDIR (default: ${REPO}/keys-out).

Options:
  --ca-cert FILE       Use an EXISTING CA certificate (PEM) as the issuer.
  --ca-key FILE        Private key for --ca-cert (PEM; may be encrypted).
  --ca-key-pass VAL    Passphrase for --ca-key (if encrypted). Prefer the
                       CA_KEY_PASS env var over this flag (avoids the process list).
  -h, --help           Show this help.

  CA_CERT / CA_KEY / CA_KEY_PASS may also be set via env or brand.conf /
  brands/<BRAND>.conf. When no CA is provided, a self-signed root is generated.
EOF
  exit "${1:-0}"
}
while [[ $# -gt 0 ]]; do
  case "$1" in
    --ca-cert)      CA_CERT="$2"; shift 2 ;;
    --ca-key)       CA_KEY="$2"; shift 2 ;;
    --ca-key-pass)  CA_KEY_PASS="$2"; shift 2 ;;
    -h|--help)      usage_keystores 0 ;;
    --)             shift; break ;;
    -*)             echo "ERROR: unknown option: $1" >&2; usage_keystores 1 ;;
    *)              if [ -z "${OUT}" ]; then OUT="$1"; else echo "ERROR: unexpected arg: $1" >&2; usage_keystores 1; fi; shift ;;
  esac
done
OUT="${OUT:-${REPO}/keys-out}"
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
  "${BRAND}-api:${BRAND}-backend"
  "${BRAND}-admin-bff-api:${BRAND}-backend"
  "${BRAND}-mod-bff-api:${BRAND}-backend"
  "${BRAND}-user-bff-api:${BRAND}-backend"
)

for t in openssl keytool; do command -v "$t" >/dev/null || { echo "ERROR: need $t" >&2; exit 1; }; done
mkdir -p "${KS}" "${CA}"
randpass() { openssl rand -base64 24 | tr -d '/+=' | cut -c1-24; }

# ── Validate a provided external CA (never prints the key) ──────────
# Confirms both files are readable, the cert parses, the key loads (honoring
# CA_KEY_PASS), and — algorithm-agnostically (RSA/EC) — that the key's public
# half matches the certificate's. All openssl stderr is suppressed so no key
# material can leak; only pass/fail diagnostics are printed.
validate_external_ca() {
  local cert="$1" key="$2"
  [ -r "${cert}" ] || { echo "ERROR: CA cert not readable: ${cert}" >&2; exit 1; }
  [ -r "${key}" ]  || { echo "ERROR: CA key not readable: ${key}" >&2; exit 1; }
  openssl x509 -in "${cert}" -noout 2>/dev/null \
    || { echo "ERROR: CA cert is not a valid PEM X.509 certificate: ${cert}" >&2; exit 1; }
  if ! openssl x509 -in "${cert}" -noout -checkend 0 >/dev/null 2>&1; then
    echo "WARNING: provided CA certificate is expired (${cert}); proceeding anyway." >&2
  fi
  # basicConstraints CA:TRUE is expected for a CA, but some private CAs omit it.
  if ! openssl x509 -in "${cert}" -noout -ext basicConstraints 2>/dev/null | grep -qi 'CA:TRUE'; then
    echo "WARNING: provided CA cert lacks basicConstraints CA:TRUE; using it anyway." >&2
  fi
  # Load the key (CA_KEY_PASS via env:, never on the command line / argv).
  if ! openssl pkey -in "${key}" ${CA_KEY_PASS:+-passin env:CA_KEY_PASS} -noout >/dev/null 2>&1; then
    echo "ERROR: cannot load CA private key (wrong/missing CA_KEY_PASS, or unreadable key): ${key}" >&2
    exit 1
  fi
  # Key-matches-cert: compare public keys (works for RSA and EC). Compare hashes
  # so no key/cert material is ever emitted.
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "${cert}" -noout -pubkey 2>/dev/null | openssl sha256 2>/dev/null)"
  key_pub="$(openssl pkey -in "${key}" ${CA_KEY_PASS:+-passin env:CA_KEY_PASS} -pubout 2>/dev/null | openssl sha256 2>/dev/null)"
  if [ -z "${cert_pub}" ] || [ "${cert_pub}" != "${key_pub}" ]; then
    echo "ERROR: CA private key does not match the CA certificate (public-key mismatch)." >&2
    exit 1
  fi
}

# ── Cluster CA: provided external CA  >  reuse on disk  >  self-signed ──
# Signing inputs the per-service loop uses; defaulted to the on-disk pair and
# overridden below when an external CA key is kept off the output directory.
CA_CRT_FILE="${CA}/cluster-ca.crt"
CA_KEY_FILE="${CA}/cluster-ca.key"
CA_PASSIN=()   # extra `-passin env:CA_KEY_PASS` args for openssl when key is encrypted

if [ -n "${CA_CERT}" ] || [ -n "${CA_KEY}" ]; then
  # External CA requested — require BOTH halves.
  [ -n "${CA_CERT}" ] && [ -n "${CA_KEY}" ] \
    || { echo "ERROR: provide BOTH CA_CERT and CA_KEY (got only one)." >&2; exit 1; }
  export CA_KEY_PASS   # so `-passin env:CA_KEY_PASS` can read it (never on argv)
  validate_external_ca "${CA_CERT}" "${CA_KEY}"
  echo "==> Using PROVIDED external CA as issuer (no CA generated)"
  # Publish the provided CA cert as the trust anchor (copy; never modify input).
  cat "${CA_CERT}" > "${CA}/cluster-ca.crt"
  CA_CRT_FILE="${CA}/cluster-ca.crt"
  if [ -n "${CA_KEY_PASS}" ]; then
    # Encrypted key: sign in place from the ORIGINAL path with -passin env:, so
    # the private key is never written (decrypted) into the output directory.
    CA_KEY_FILE="${CA_KEY}"
    CA_PASSIN=(-passin env:CA_KEY_PASS)
  else
    # Unencrypted key: the signing openssl calls need a key path; keep using the
    # original path directly (still not copied into OUT).
    CA_KEY_FILE="${CA_KEY}"
  fi
elif [ ! -f "${CA}/cluster-ca.crt" ] || [ ! -f "${CA}/cluster-ca.key" ]; then
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
  -file "${CA_CRT_FILE}" -keystore "${KS}/truststore.jks" \
  -storetype JKS -storepass "${TS_PASS}" 2>/dev/null
openssl pkcs12 -export -nokeys -in "${CA_CRT_FILE}" \
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
  openssl x509 -req -in "${tmp}/csr.pem" -CA "${CA_CRT_FILE}" -CAkey "${CA_KEY_FILE}" "${CA_PASSIN[@]}" \
    -CAcreateserial -days "${DAYS}" -extfile "${tmp}/ext" -out "${tmp}/cert.pem" 2>/dev/null
  cat "${tmp}/cert.pem" "${CA_CRT_FILE}" > "${tmp}/chain.pem"
  # key + chain -> PKCS12 -> JKS (mTLS identity; trusts the CA too)
  openssl pkcs12 -export -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" -certfile "${CA_CRT_FILE}" \
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
# Lock down the password file and the CA key. With an external CA the private
# key is NEVER copied into ${CA}, so only chmod cluster-ca.key when we own it.
chmod 0600 "${KS}/passwords.json" 2>/dev/null || true
[ -f "${CA}/cluster-ca.key" ] && chmod 0600 "${CA}/cluster-ca.key" 2>/dev/null || true

echo "==> Done. Keystores in ${KS}:"
ls -1 "${KS}"
