#!/usr/bin/env bash
# gen-keystores.sh — generate the per-API machine-user JKS keystores + the
# shared truststore for the HugMesh cluster, from a single cluster CA.
#
# Each Java API/UI machine user (the Spring Cloud Gateways + Spring services)
# gets its own JKS keystore (private key + CA-signed cert) used as its mTLS
# identity when talking to other namespaces. A single truststore (built from the
# cluster CA chain) is what every Java JRE/JDK trusts — it is installed into the
# container's JRE at runtime (built from the certs on the USB KEYS stick).
#
# Output (under OUTDIR) — DEFAULT single-domain layout (unchanged):
#   certs/cluster-ca.crt           the cluster CA (trust anchor; goes on the KEYS stick)
#   certs/cluster-ca.key           CA private key (KEEP OFFLINE; pki stick only)
#   keystores/<svc>.keystore.jks   per-service identity keystore (key + cert chain)
#   keystores/truststore.jks       NARROW trust store (this domain's CA) — JKS
#   keystores/truststore.p12       NARROW trust store — PKCS12 (non-keytool consumers)
#   keystores/passwords.json       store passwords (offline/USB fallback)
#   keystores/architecture/        WIDE multi-anchor trust store (every domain root)
#                                  for the ARCHITECTURE TIER (Vault/federation/superadmin);
#                                  with one domain it holds exactly that one root.
#
# MULTI-DOMAIN (brands/domains.conf with >1 active row) ADDS, per extra brand:
#   certs/<brand>/cluster-ca.{crt,key}   that domain's independent (or imported) CA
#   keystores/<brand>/<svc>.keystore.jks per-service identity keystores
#   keystores/<brand>/truststore.{jks,p12} that domain's NARROW own-root trust store
#   keystores/<brand>/passwords.json     store passwords
# (the single default domain keeps the flat top-level layout above — byte-identical).
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
# FAIL-CLOSED (defense before use): BRAND is a PATH COMPONENT of the brands/<BRAND>.conf
# profile dot-sourced just below — a value like ../../evil (from env or the brand.conf
# sourced above) would source arbitrary shell. validate_brand_domain() runs later, AFTER
# this source, so gate BRAND as a DNS-label slug HERE, before it can select the file.
if [ -n "${BRAND:-}" ] && [[ ! "${BRAND}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]]; then
  echo "ERROR: invalid BRAND '${BRAND}' (must be a DNS label [a-z0-9-]; no '/', '..', whitespace) — refusing to source brands/${BRAND}.conf" >&2
  exit 1
fi
if [ -n "${BRAND:-}" ] && [ -f "${REPO}/brands/${BRAND}.conf" ]; then
  # shellcheck disable=SC1090
  . "${REPO}/brands/${BRAND}.conf"
fi
DOMAIN="${CLUSTER_DOMAIN:-hugmesh.net}"
BRAND="${BRAND:-hugmesh}"

# ── Multi-tenancy: per-domain CA loop (PR4) ─────────────────────────
# By DEFAULT this script provisions ONE domain (the single ${BRAND}/${DOMAIN}
# above) — and that single-domain run is BYTE-/functionally-IDENTICAL to the
# pre-multi-tenancy behavior: the loop below runs with N=1 as a pure no-op
# transformation (same paths, same CA subject, same aliases, same service certs,
# and a WIDE truststore that then holds exactly the one root == the narrow one).
#
# A build opts into MULTIPLE domains/brands baked in from the start by listing
# them in brands/domains.conf (or a file named via DOMAINS_CONF). Each non-blank,
# non-`#` line is one domain row, whitespace-separated:
#
#     DOMAIN [BRAND] [CA_CERT] [CA_KEY]
#
#   DOMAIN   (required) the brand's CLUSTER_DOMAIN.
#   BRAND    (optional) slug used in names; defaults to DOMAIN's first label.
#   CA_CERT  (optional) path to an EXISTING CA cert (PEM) to IMPORT as that
#            domain's issuer instead of GENERATING an independent root.
#   CA_KEY   (optional, REQUIRED with CA_CERT) the imported CA's private key
#            (PEM). SECRET — keep it OFF git (an absolute path on the key-USB /
#            a secret dir; NEVER commit it).
#
# Per-domain CA model (multi-tenancy fork, DEFAULT = independent root): each
# domain GENERATES its own independent-root CA, OR IMPORTS a provided one (reuses
# the same --ca-cert/--ca-key seam, now per-domain). Each domain gets a NARROW
# truststore (its own root ONLY) under keystores/ (single domain) or
# keystores/<brand>/ (multi-domain). ONE WIDE multi-anchor truststore (every
# domain's root) is built for the ARCHITECTURE TIER ONLY (Vault / federation /
# superadmin), which must validate cross-domain mTLS; per-brand gateway instances
# keep the narrow own-domain truststore. With N=1 the wide truststore holds
# exactly the one root, so nothing changes for a default build.
DOMAINS_CONF="${DOMAINS_CONF:-${REPO}/brands/domains.conf}"

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

# ── Crypto agility knobs (override via env / brand.conf) ────────────
# Centralised so the brand/operator can tune the whole keystore chain in one
# place. Defaults are the strongest the openssl+keytool+JVM toolchain handles
# interoperably TODAY (see docs/CRYPTO-AUDIT.md):
#   KEY_TYPE  rsa | ec        — asymmetric key family for the CA + every leaf.
#   KEY_BITS  RSA modulus bits (rsa) — 4096 (was 2048; raised, never lowered).
#   EC_CURVE  named curve (ec) — P-384 (ecdsa-with-SHA384 class).
#   SIG_HASH  X.509 signature digest — sha384 (sha384WithRSAEncryption /
#             ecdsa-with-SHA384; validated by every JVM + openssl). SHA-3 in the
#             cert SIGNATURE is NOT yet portable to the SunRsaSign JCA provider,
#             so it stays a documented migration path, not the default.
#   FP_HASH   internal key/cert FINGERPRINT digest (no interop constraint) —
#             sha3-512 (post-quantum-grade high-bit hash) where openssl supports
#             it, else sha512.
# Back-compat: a value still set via the old KEYALG/KEYBITS names is honoured.
KEY_TYPE="${KEY_TYPE:-${KEYALG:-rsa}}"
KEY_TYPE="$(printf '%s' "${KEY_TYPE}" | tr '[:upper:]' '[:lower:]')"
KEY_BITS="${KEY_BITS:-${KEYBITS:-4096}}"
EC_CURVE="${EC_CURVE:-P-384}"
SIG_HASH="${SIG_HASH:-sha384}"
DAYS="${DAYS:-825}"
# Pick the strongest fingerprint digest openssl actually provides on this host.
if [ -z "${FP_HASH:-}" ]; then
  if echo x | openssl dgst -sha3-512 >/dev/null 2>&1; then FP_HASH="sha3-512"; else FP_HASH="sha512"; fi
fi
# Human-readable size suffix for the log line ("-4096" / " P-384").
case "${KEY_TYPE}" in ec) KEY_TYPE_DESC=" ${EC_CURVE}" ;; *) KEY_TYPE_DESC="-${KEY_BITS}" ;; esac

# Generate a private key of the configured family into $1. Used for both the
# self-signed CA key and every per-service leaf key, so the whole chain shares
# one algorithm decision (crypto-agility).
gen_private_key() {
  local out="$1"
  case "${KEY_TYPE}" in
    ec)  openssl genpkey -algorithm EC  -pkeyopt "ec_paramgen_curve:${EC_CURVE}" -out "${out}" 2>/dev/null ;;
    rsa) openssl genpkey -algorithm RSA -pkeyopt "rsa_keygen_bits:${KEY_BITS}"   -out "${out}" 2>/dev/null ;;
    *)   echo "ERROR: unsupported KEY_TYPE='${KEY_TYPE}' (use rsa|ec)" >&2; exit 1 ;;
  esac
}

# Java API machine-users that get an mTLS identity keystore: "name:namespace".
# (Casdoor=Go, tuwunel=Rust, Mastodon=Ruby are not Java; they consume the same
#  CA via PEM and are issued certs by gen-cluster-secrets if needed.)
# Parameterised by brand so each domain in the loop gets its own brand's service
# set; with the single default brand this yields exactly the historical list.
services_for_brand() {
  local b="$1"
  printf '%s\n' \
    "${b}-pki-gateway:${b}-pki" \
    "${b}-be-gateway:${b}-backend" \
    "${b}-fe-gateway:${b}-frontend" \
    "${b}-api:${b}-backend" \
    "${b}-admin-bff-api:${b}-backend" \
    "${b}-mod-bff-api:${b}-backend" \
    "${b}-user-bff-api:${b}-backend"
}

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
  if ! openssl x509 -in "${cert}" -noout -ext basicConstraints 2>/dev/null | grep -i 'CA:TRUE' >/dev/null; then
    echo "WARNING: provided CA cert lacks basicConstraints CA:TRUE; using it anyway." >&2
  fi
  # Load the key (CA_KEY_PASS via env:, never on the command line / argv).
  if ! openssl pkey -in "${key}" ${CA_KEY_PASS:+-passin env:CA_KEY_PASS} -noout >/dev/null 2>&1; then
    echo "ERROR: cannot load CA private key (wrong/missing CA_KEY_PASS, or unreadable key): ${key}" >&2
    exit 1
  fi
  # Key-matches-cert: compare public keys (works for RSA and EC). Compare hashes
  # (strongest digest available — FP_HASH, sha3-512 where supported) so no
  # key/cert material is ever emitted.
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "${cert}" -noout -pubkey 2>/dev/null | openssl dgst "-${FP_HASH}" 2>/dev/null)"
  key_pub="$(openssl pkey -in "${key}" ${CA_KEY_PASS:+-passin env:CA_KEY_PASS} -pubout 2>/dev/null | openssl dgst "-${FP_HASH}" 2>/dev/null)"
  if [ -z "${cert_pub}" ] || [ "${cert_pub}" != "${key_pub}" ]; then
    echo "ERROR: CA private key does not match the CA certificate (public-key mismatch)." >&2
    exit 1
  fi
}

# ── provision_domain: one domain's CA + narrow truststore + keystores ─
# Provisions exactly ONE domain into the given cert/keystore dirs. The body is
# the verbatim pre-multi-tenancy single-domain logic, lifted into a function and
# parameterised by the per-domain brand/domain/CA-input + target dirs:
#   $1 d_brand     brand slug for this domain
#   $2 d_domain    CLUSTER_DOMAIN for this domain (SAN suffix)
#   $3 d_ca_cert   external CA cert to IMPORT (empty => GENERATE independent root)
#   $4 d_ca_key    external CA key (required iff d_ca_cert non-empty)
#   $5 d_ca_pass   passphrase for d_ca_key (empty if unencrypted) — read via env
#   $6 d_ca_dir    cert output dir   (cluster-ca.{crt,key} live here)
#   $7 d_ks_dir    keystore output dir (truststore + per-svc keystores + passwords.json)
# Side effect: prints this domain's published CA cert path to FD 3 (the loop
# collects them into the WIDE multi-anchor truststore for the architecture tier).
provision_domain() {
  local d_brand="$1" d_domain="$2" d_ca_cert="$3" d_ca_key="$4" d_ca_pass="$5" d_ca_dir="$6" d_ks_dir="$7"
  # Defense-in-depth: re-validate at the sink. d_brand/d_domain name the ${d_ca_dir}/
  # ${d_ks_dir} paths (mkdir/rm below), keytool aliases and openssl -subj fields. Every
  # current caller validates before building DOMAIN_ROWS, but re-gate here so a future
  # caller cannot reach these root sinks with an unsafe brand/domain (fail-closed).
  validate_brand_domain "${d_brand}" "${d_domain}"
  # REALPATH CONTAINMENT (Phase 6 — parity with generate-brand-repos.sh L197-206).
  # d_ca_dir/d_ks_dir are ${CA}/${d_brand} and ${KS}/${d_brand}; ${OUT} is the root-owned
  # node-local staging base (NEVER export-derived). d_brand is the sole export-derived path
  # component and is DNS-label-validated three times, but anchor the destructive mkdir/rm
  # sinks under ${OUT} as a realpath backstop so even a future regression cannot escape.
  local _out_abs _cad_abs _ksd_abs
  _out_abs="$(mkdir -p "${OUT}" 2>/dev/null; realpath -m -- "${OUT}")"
  _cad_abs="$(realpath -m -- "${d_ca_dir}")"
  _ksd_abs="$(realpath -m -- "${d_ks_dir}")"
  case "${_cad_abs}/" in "${_out_abs}"/*) : ;; *) echo "ERROR: refusing CA dir outside OUT: '${d_ca_dir}' -> '${_cad_abs}'" >&2; exit 1 ;; esac
  case "${_ksd_abs}/" in "${_out_abs}"/*) : ;; *) echo "ERROR: refusing keystore dir outside OUT: '${d_ks_dir}' -> '${_ksd_abs}'" >&2; exit 1 ;; esac
  mkdir -p "${d_ca_dir}" "${d_ks_dir}"

  # Cluster CA: provided external CA  >  reuse on disk  >  self-signed.
  # Signing inputs the per-service loop uses; defaulted to the on-disk pair and
  # overridden below when an external CA key is kept off the output directory.
  local CA_CRT_FILE="${d_ca_dir}/cluster-ca.crt"
  local CA_KEY_FILE="${d_ca_dir}/cluster-ca.key"
  local CA_PASSIN=()   # extra `-passin env:CA_KEY_PASS` args for openssl when key is encrypted

  if [ -n "${d_ca_cert}" ] || [ -n "${d_ca_key}" ]; then
    # External CA requested for this domain — require BOTH halves.
    [ -n "${d_ca_cert}" ] && [ -n "${d_ca_key}" ] \
      || { echo "ERROR: provide BOTH CA_CERT and CA_KEY (got only one)." >&2; exit 1; }
    CA_KEY_PASS="${d_ca_pass}"
    export CA_KEY_PASS   # so `-passin env:CA_KEY_PASS` can read it (never on argv)
    validate_external_ca "${d_ca_cert}" "${d_ca_key}"
    echo "==> Using PROVIDED external CA as issuer (no CA generated)"
    # Publish the provided CA cert as the trust anchor (copy; never modify input).
    cat "${d_ca_cert}" > "${d_ca_dir}/cluster-ca.crt"
    CA_CRT_FILE="${d_ca_dir}/cluster-ca.crt"
    if [ -n "${d_ca_pass}" ]; then
      # Encrypted key: sign in place from the ORIGINAL path with -passin env:, so
      # the private key is never written (decrypted) into the output directory.
      CA_KEY_FILE="${d_ca_key}"
      CA_PASSIN=(-passin env:CA_KEY_PASS)
    else
      # Unencrypted key: the signing openssl calls need a key path; keep using the
      # original path directly (still not copied into OUT).
      CA_KEY_FILE="${d_ca_key}"
    fi
  elif [ ! -f "${d_ca_dir}/cluster-ca.crt" ] || [ ! -f "${d_ca_dir}/cluster-ca.key" ]; then
    echo "==> Generating cluster CA (${KEY_TYPE^^}${KEY_TYPE_DESC:-}, ${SIG_HASH} signature)"
    # Key first (uniform RSA/EC path), then self-sign with the chosen digest.
    gen_private_key "${d_ca_dir}/cluster-ca.key"
    openssl req -x509 -key "${d_ca_dir}/cluster-ca.key" -nodes -days 3650 "-${SIG_HASH}" \
      -out "${d_ca_dir}/cluster-ca.crt" \
      -subj "/O=${d_brand} cluster/CN=${d_brand} Cluster CA" 2>/dev/null
  else
    echo "==> Reusing existing cluster CA at ${d_ca_dir}/cluster-ca.crt"
  fi

  # ── NARROW truststore (this domain's CA ONLY) — JKS + PKCS12 ───────
  # Per-brand gateway/BFF/UI instances anchor on their OWN domain's root only;
  # cross-domain trust is denied by namespace + this narrow anchor (defense in
  # depth). The architecture tier gets the WIDE store assembled after the loop.
  local TS_PASS; TS_PASS="$(randpass)"
  rm -f "${d_ks_dir}/truststore.jks" "${d_ks_dir}/truststore.p12"
  keytool -importcert -noprompt -alias "${d_brand}-cluster-ca" \
    -file "${CA_CRT_FILE}" -keystore "${d_ks_dir}/truststore.jks" \
    -storetype JKS -storepass "${TS_PASS}" 2>/dev/null
  openssl pkcs12 -export -nokeys -in "${CA_CRT_FILE}" \
    -out "${d_ks_dir}/truststore.p12" -passout "pass:${TS_PASS}" -name "${d_brand}-cluster-ca"
  echo "==> Truststore built (JKS + PKCS12)"

  # ── Per-service identity keystores ───────────────────────────────
  local PW_JSON="{\"truststore\":\"${TS_PASS}\",\"services\":{"
  local first=1 entry svc ns cn pass tmp _KU
  while IFS= read -r entry; do
    svc="${entry%%:*}"; ns="${entry##*:}"
    cn="${svc}.${ns}.svc.cluster.local"
    pass="$(randpass)"
    tmp="$(mktemp -d)"
    echo "  - ${svc} (CN=${cn})"
    gen_private_key "${tmp}/key.pem"
    openssl req -new -key "${tmp}/key.pem" -out "${tmp}/csr.pem" -subj "/O=${d_brand}/CN=${cn}" 2>/dev/null
    # keyEncipherment only applies to RSA key-transport suites; EC leaves use ECDHE
    # (keyAgreement) so emit the family-appropriate keyUsage.
    case "${KEY_TYPE}" in ec) _KU="digitalSignature,keyAgreement" ;; *) _KU="digitalSignature,keyEncipherment" ;; esac
    cat > "${tmp}/ext" <<EXT
subjectAltName = DNS:${cn},DNS:${svc}.${ns},DNS:${svc}.${d_domain}
extendedKeyUsage = serverAuth,clientAuth
keyUsage = ${_KU}
EXT
    openssl x509 -req -in "${tmp}/csr.pem" -CA "${CA_CRT_FILE}" -CAkey "${CA_KEY_FILE}" "${CA_PASSIN[@]}" \
      -CAcreateserial -days "${DAYS}" "-${SIG_HASH}" -extfile "${tmp}/ext" -out "${tmp}/cert.pem" 2>/dev/null
    cat "${tmp}/cert.pem" "${CA_CRT_FILE}" > "${tmp}/chain.pem"
    # key + chain -> PKCS12 -> JKS (mTLS identity; trusts the CA too)
    openssl pkcs12 -export -inkey "${tmp}/key.pem" -in "${tmp}/cert.pem" -certfile "${CA_CRT_FILE}" \
      -name "${svc}" -out "${tmp}/${svc}.p12" -passout "pass:${pass}"
    keytool -importkeystore -noprompt \
      -srckeystore "${tmp}/${svc}.p12" -srcstoretype PKCS12 -srcstorepass "${pass}" \
      -destkeystore "${d_ks_dir}/${svc}.keystore.jks" -deststoretype JKS -deststorepass "${pass}" 2>/dev/null
    rm -rf "${tmp}"
    [ "${first}" = 1 ] || PW_JSON+=","
    PW_JSON+="\"${svc}\":\"${pass}\""; first=0
  done < <(services_for_brand "${d_brand}")
  PW_JSON+="}}"
  printf '%s\n' "${PW_JSON}" | (command -v jq >/dev/null && jq . || cat) > "${d_ks_dir}/passwords.json"
  # Lock down the password file and the CA key. With an external CA the private
  # key is NEVER copied into ${d_ca_dir}, so only chmod cluster-ca.key when we own it.
  chmod 0600 "${d_ks_dir}/passwords.json" 2>/dev/null || true
  [ -f "${d_ca_dir}/cluster-ca.key" ] && chmod 0600 "${d_ca_dir}/cluster-ca.key" 2>/dev/null || true

  # Hand this domain's published CA cert (the trust anchor) back to the loop so
  # it can be added to the WIDE multi-anchor architecture-tier truststore.
  printf '%s\t%s\n' "${d_brand}" "${CA_CRT_FILE}" >&3
}

# ── Build the domain list (DEFAULT = exactly one row = current single domain) ──
# Each row is "brand<TAB>domain<TAB>ca_cert<TAB>ca_key". With no brands/domains.conf
# (or an empty one) the list is exactly the historical single {BRAND, DOMAIN,
# CA_CERT, CA_KEY}, so the loop below is a no-op transformation (N=1).
# ── Slug / DNS-name validation (#4) ────────────────────────────────────────────
# domains.conf rows ultimately originate from the SIGNED #118 cross-domain export
# (authenticity-verified, NOT content-validated) when this script is driven by
# hugmesh-domain-reconcile. The brand slug (_b) and domain (_d) are later built
# straight into ROOT filesystem paths in the multi-domain branch:
#   _ca_dir="${CA}/${_b}"; _ks_dir="${KS}/${_b}"  -> mkdir -p / rm -f (as root)
# so a value containing '/' or '..' would escape the output tree. Validate each
# parsed row up front and FAIL CLOSED on a bad slug/domain; legit slugs
# (e.g. hugmesh) and domains (e.g. hugmesh.net) still pass.
_KS_DNS_LABEL='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$'
_KS_DNS_NAME='^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?(\.[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?)*$'
validate_brand_domain() {
  local b="$1" d="$2"
  [[ "${b}" =~ ${_KS_DNS_LABEL} ]] \
    || { echo "ERROR: invalid brand slug '${b}' (must be a DNS label; no '/', '..', whitespace)" >&2; exit 1; }
  [[ "${d}" =~ ${_KS_DNS_NAME} ]] \
    || { echo "ERROR: invalid domain '${d}' (must be a DNS name; no '/', '..', whitespace)" >&2; exit 1; }
}

DOMAIN_ROWS=()
if [ -f "${DOMAINS_CONF}" ] && grep -qE '^[[:space:]]*[^#[:space:]]' "${DOMAINS_CONF}"; then
  echo "==> Multi-domain build from ${DOMAINS_CONF}"
  while IFS= read -r _line || [ -n "${_line}" ]; do
    # Strip comments (full-line and trailing) + surrounding whitespace; skip blanks.
    _line="${_line%%#*}"
    # shellcheck disable=SC2086
    set -- ${_line}
    [ "$#" -ge 1 ] || continue
    _d="$1"; _b="${2:-}"; _cc="${3:-}"; _ck="${4:-}"
    # Default brand = the domain's first DNS label (e.g. acme.test -> acme).
    [ -n "${_b}" ] || _b="${_d%%.*}"
    # Fail closed on a slug/domain that could escape the output tree (#4).
    validate_brand_domain "${_b}" "${_d}"
    DOMAIN_ROWS+=("${_b}"$'\t'"${_d}"$'\t'"${_cc}"$'\t'"${_ck}")
  done < "${DOMAINS_CONF}"
fi
# Fallback / default: the single current domain. This is the BYTE-IDENTICAL path.
if [ "${#DOMAIN_ROWS[@]}" -eq 0 ]; then
  validate_brand_domain "${BRAND}" "${DOMAIN}"
  DOMAIN_ROWS+=("${BRAND}"$'\t'"${DOMAIN}"$'\t'"${CA_CERT}"$'\t'"${CA_KEY}")
fi
N_DOMAINS="${#DOMAIN_ROWS[@]}"

# ── Loop: provision each domain; collect each root for the WIDE store ──
# WIDE_ANCHORS accumulates "brand<TAB>ca-cert-path" lines for the architecture
# tier. For N=1 the single domain writes directly into ${CA}/${KS} (no nesting),
# so every output path/alias/subject equals the pre-refactor script's — the
# single-domain output is byte-/functionally-identical (see tests/keystores).
WIDE_ANCHORS=""
WIDE_FILE="$(mktemp)"
for _row in "${DOMAIN_ROWS[@]}"; do
  IFS=$'\t' read -r _b _d _cc _ck <<<"${_row}"
  # CA_KEY_PASS: per-domain rows don't carry a passphrase (imported CA keys on a
  # multi-domain build are expected unencrypted, or the single-domain CA_KEY_PASS
  # env applies to the single row). Single-domain keeps the historical env value.
  if [ "${N_DOMAINS}" -eq 1 ]; then
    # SINGLE DOMAIN (default): write into the canonical ${CA}/${KS} (no per-brand
    # subdir) so the layout is identical to the historical single-domain output.
    _ca_dir="${CA}"; _ks_dir="${KS}"; _pass="${CA_KEY_PASS}"
  else
    echo "==> [domain ${_b} / ${_d}]"
    _ca_dir="${CA}/${_b}"; _ks_dir="${KS}/${_b}"; _pass=""
  fi
  provision_domain "${_b}" "${_d}" "${_cc}" "${_ck}" "${_pass}" "${_ca_dir}" "${_ks_dir}" 3>>"${WIDE_FILE}"
done
WIDE_ANCHORS="$(cat "${WIDE_FILE}")"; rm -f "${WIDE_FILE}"

# ── WIDE multi-anchor truststore (ARCHITECTURE TIER ONLY) ──────────
# Vault / federation-api / the superadmin module are cross-domain: they must
# validate mTLS from EVERY domain, so they trust EVERY domain's root. Per-brand
# gateway/BFF/UI instances do NOT use this store (they use their narrow own-domain
# truststore from provision_domain). This extends the historical one-anchor import
# path to import N anchors — and for N=1 it contains exactly the one root, making
# it functionally identical to that single domain's narrow truststore.
build_wide_truststore() {
  local out_dir="${KS}/architecture"
  mkdir -p "${out_dir}"
  local ts_pass; ts_pass="$(randpass)"
  rm -f "${out_dir}/truststore.jks" "${out_dir}/truststore.p12"
  local concat; concat="$(mktemp)"
  local b crt
  while IFS=$'\t' read -r b crt; do
    [ -n "${crt}" ] && [ -f "${crt}" ] || continue
    # Import each domain root under its own alias (so N anchors coexist).
    keytool -importcert -noprompt -alias "${b}-cluster-ca" \
      -file "${crt}" -keystore "${out_dir}/truststore.jks" \
      -storetype JKS -storepass "${ts_pass}" 2>/dev/null
    cat "${crt}" >> "${concat}"
  done <<<"${WIDE_ANCHORS}"
  # PKCS12 wide truststore (Java reads it natively) — all roots, no keys.
  openssl pkcs12 -export -nokeys -in "${concat}" \
    -out "${out_dir}/truststore.p12" -passout "pass:${ts_pass}" -name architecture-truststore 2>/dev/null
  rm -f "${concat}"
  printf '{"truststore":"%s","tier":"architecture","anchors":%s}\n' "${ts_pass}" "${N_DOMAINS}" \
    > "${out_dir}/passwords.json"
  chmod 0600 "${out_dir}/passwords.json" 2>/dev/null || true
  echo "==> WIDE architecture-tier truststore built (${N_DOMAINS} anchor(s)) in ${out_dir}"
}
build_wide_truststore

echo "==> Done. Keystores in ${KS}:"
ls -1 "${KS}"
