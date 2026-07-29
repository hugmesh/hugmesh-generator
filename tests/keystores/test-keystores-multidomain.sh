#!/usr/bin/env bash
# test-keystores-multidomain.sh — proves the multi-tenancy per-domain CA loop
# (PR4) in scripts/gen-keystores.sh:
#
#   1) N=1 BYTE-/FUNCTIONALLY-IDENTICAL: with the default single domain (no
#      brands/domains.conf rows), the refactored generator produces the SAME
#      output structure as the FROZEN pre-refactor generator
#      (golden/gen-keystores.pre-mt.sh) — same cert/keystore file set, same CA
#      subject, same truststore alias, same per-service CN/SAN/issuer/chain, same
#      passwords.json shape — i.e. the loop with N=1 is a no-op transformation.
#      (Key/cert/password BYTES differ run-to-run by design — they are randomly
#      generated — so we assert STRUCTURAL identity, the meaning of "byte-identical
#      output" for a generator whose every run is random.) We also assert the WIDE
#      architecture-tier truststore then holds EXACTLY the one root == the narrow
#      truststore.
#
#   2) N=2: two domains -> two INDEPENDENT-ROOT CAs (distinct issuers), two NARROW
#      truststores (each its OWN root ONLY -> cross-domain trust DENIED at the TLS
#      anchor, defense in depth), and ONE WIDE truststore holding BOTH roots
#      (architecture tier).
#
#   3) IMPORT-CA per domain: a row that supplies CA_CERT/CA_KEY uses THAT cert as
#      the issuer (not a freshly generated root).
#
# Rootless; needs openssl + keytool + python3.
set -uo pipefail

REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
GEN="${REPO}/scripts/gen-keystores.sh"
GOLD="${REPO}/tests/keystores/golden/gen-keystores.pre-mt.sh"
BRAND="${BRAND:-hugmesh}"
SERVICES=("${BRAND}-pki-gateway" "${BRAND}-be-gateway" "${BRAND}-fe-gateway"
          "${BRAND}-api" "${BRAND}-admin-bff-api" "${BRAND}-mod-bff-api" "${BRAND}-user-bff-api")

for t in openssl keytool python3; do command -v "$t" >/dev/null || { echo "SKIP: need $t"; exit 0; }; done

W="$(mktemp -d)"; trap 'rm -rf "${W}"' EXIT
P=0; F=0
ok(){ echo "  PASS $*"; P=$((P+1)); }
bad(){ echo "  FAIL $*"; F=$((F+1)); }
pw(){ python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(d["services"][sys.argv[2]] if len(sys.argv)>2 else d["truststore"])' "$1" "${@:2}"; }
ts_alias_count(){ keytool -list -keystore "$1" -storepass "$2" 2>/dev/null | grep -c trustedCertEntry; }
ca_fp(){ openssl x509 -in "$1" -noout -fingerprint -sha256 2>/dev/null | cut -d= -f2; }
# Set of relative file paths under a dir (sorted), EXCLUDING the new architecture/
# wide-truststore subdir, so we compare apples to apples with the golden.
file_set(){ ( cd "$1" && find . -type f ! -path './keystores/architecture/*' | LC_ALL=C sort ); }

echo "== gen-keystores MULTI-DOMAIN / per-domain-CA test =="

# ─────────────────────────────────────────────────────────────────────
# 1) N=1 BYTE-/FUNCTIONALLY-IDENTICAL vs the frozen pre-refactor golden
# ─────────────────────────────────────────────────────────────────────
echo "-- N=1: refactored output structurally identical to the pre-refactor golden --"
[ -x "${GOLD}" ] || chmod +x "${GOLD}" 2>/dev/null || true
GOUT="${W}/gold"; NOUT="${W}/new"
# Run with an EMPTY domains.conf path so the default single-domain path is taken
# in BOTH (the golden has no such concept; the new script falls back to N=1).
DOMAINS_CONF="${W}/none.conf" bash "${GOLD}" "${GOUT}" >/dev/null 2>&1 || bad "golden generator failed"
DOMAINS_CONF="${W}/none.conf" bash "${GEN}"  "${NOUT}" >/dev/null 2>&1 || bad "refactored generator failed"

# (a) identical output file SET (minus the additive architecture/ subdir)
if diff <(file_set "${GOUT}") <(file_set "${NOUT}") >/dev/null; then
  ok "N=1 output file set identical to pre-refactor golden"
else
  bad "N=1 file set differs from golden:"; diff <(file_set "${GOUT}") <(file_set "${NOUT}") | sed 's/^/      /'
fi

# (b) identical CA subject (issuer identity is the load-bearing trust property)
gsub="$(openssl x509 -in "${GOUT}/certs/cluster-ca.crt" -noout -subject 2>/dev/null)"
nsub="$(openssl x509 -in "${NOUT}/certs/cluster-ca.crt" -noout -subject 2>/dev/null)"
[ -n "${nsub}" ] && [ "${gsub}" = "${nsub}" ] && ok "N=1 CA subject identical (${nsub#subject=})" || bad "N=1 CA subject differs: '${gsub}' vs '${nsub}'"

# (c) identical truststore alias + same single trustedCertEntry count
galias="$(keytool -list -keystore "${GOUT}/keystores/truststore.jks" -storepass "$(pw "${GOUT}/keystores/passwords.json")" 2>/dev/null | grep -i 'cluster-ca' | head -1 | cut -d, -f1)"
nalias="$(keytool -list -keystore "${NOUT}/keystores/truststore.jks" -storepass "$(pw "${NOUT}/keystores/passwords.json")" 2>/dev/null | grep -i 'cluster-ca' | head -1 | cut -d, -f1)"
[ -n "${nalias}" ] && [ "${galias}" = "${nalias}" ] && ok "N=1 truststore alias identical (${nalias})" || bad "N=1 truststore alias differs: '${galias}' vs '${nalias}'"
[ "$(ts_alias_count "${NOUT}/keystores/truststore.jks" "$(pw "${NOUT}/keystores/passwords.json")")" = "1" ] \
  && ok "N=1 narrow truststore holds exactly one CA" || bad "N=1 narrow truststore != 1 CA"

# (d) per-service: identical CN, SAN, issuer, chain-length for every service
gpwj="${GOUT}/keystores/passwords.json"; npwj="${NOUT}/keystores/passwords.json"
svc_match=1
for svc in "${SERVICES[@]}"; do
  gp="$(keytool -exportcert -keystore "${GOUT}/keystores/${svc}.keystore.jks" -storepass "$(pw "${gpwj}" "${svc}")" -alias "${svc}" -rfc 2>/dev/null)"
  np="$(keytool -exportcert -keystore "${NOUT}/keystores/${svc}.keystore.jks" -storepass "$(pw "${npwj}" "${svc}")" -alias "${svc}" -rfc 2>/dev/null)"
  gsubj="$(echo "${gp}" | openssl x509 -noout -subject 2>/dev/null)"; nsubj="$(echo "${np}" | openssl x509 -noout -subject 2>/dev/null)"
  giss="$(echo "${gp}"  | openssl x509 -noout -issuer  2>/dev/null)"; niss="$(echo "${np}"  | openssl x509 -noout -issuer  2>/dev/null)"
  gsan="$(echo "${gp}"  | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' ')"
  nsan="$(echo "${np}"  | openssl x509 -noout -ext subjectAltName 2>/dev/null | tr -d ' ')"
  [ -n "${nsubj}" ] && [ "${gsubj}" = "${nsubj}" ] && [ "${giss}" = "${niss}" ] && [ "${gsan}" = "${nsan}" ] || { svc_match=0; bad "${svc}: subject/issuer/SAN differs from golden"; echo "      subj '${gsubj}' vs '${nsubj}'"; echo "      san  '${gsan}' vs '${nsan}'"; }
done
[ "${svc_match}" = 1 ] && ok "N=1 every service cert (CN/SAN/issuer) identical to golden"

# (e) identical passwords.json shape (truststore + same service keys)
gkeys="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("truststore="+("y" if "truststore" in d else "n"),*sorted(d["services"]))' "${gpwj}")"
nkeys="$(python3 -c 'import json,sys;d=json.load(open(sys.argv[1]));print("truststore="+("y" if "truststore" in d else "n"),*sorted(d["services"]))' "${npwj}")"
[ "${gkeys}" = "${nkeys}" ] && ok "N=1 passwords.json shape identical" || bad "N=1 passwords.json shape differs: '${gkeys}' vs '${nkeys}'"

# (f) WIDE architecture-tier truststore exists and (N=1) holds exactly the one root
ARCH="${NOUT}/keystores/architecture"
if [ -f "${ARCH}/truststore.jks" ] && [ -f "${ARCH}/passwords.json" ]; then
  ats_pass="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["truststore"])' "${ARCH}/passwords.json")"
  [ "$(ts_alias_count "${ARCH}/truststore.jks" "${ats_pass}")" = "1" ] && ok "N=1 WIDE truststore holds exactly the one root (== narrow)" || bad "N=1 WIDE truststore anchor count != 1"
  # its single anchor must be the SAME cert as the narrow root
  keytool -exportcert -keystore "${ARCH}/truststore.jks" -storepass "${ats_pass}" -alias "${BRAND}-cluster-ca" -rfc 2>/dev/null > "${W}/arch-anchor.pem"
  [ "$(ca_fp "${W}/arch-anchor.pem")" = "$(ca_fp "${NOUT}/certs/cluster-ca.crt")" ] && ok "N=1 WIDE anchor == the domain's narrow root" || bad "N=1 WIDE anchor != narrow root"
else
  bad "N=1 WIDE architecture truststore missing"
fi

# ─────────────────────────────────────────────────────────────────────
# 2) N=2: two independent roots, two narrow truststores, one wide 2-anchor store
# ─────────────────────────────────────────────────────────────────────
echo "-- N=2: two independent-root domains + narrow stores + one wide 2-anchor store --"
M2="${W}/dom2.conf"; printf '%s\n' '# two domains' 'acme.test   acme' 'beta.test   beta' > "${M2}"
M2OUT="${W}/m2"
DOMAINS_CONF="${M2}" bash "${GEN}" "${M2OUT}" >/dev/null 2>&1 || bad "N=2 generator failed"

for b in acme beta; do
  [ -f "${M2OUT}/certs/${b}/cluster-ca.crt" ] && ok "${b}: independent CA generated under certs/${b}/" || bad "${b}: CA missing"
  [ -f "${M2OUT}/keystores/${b}/truststore.jks" ] && ok "${b}: narrow truststore present" || bad "${b}: truststore missing"
done

# distinct roots (different fingerprints) + correct per-brand CN
afp="$(ca_fp "${M2OUT}/certs/acme/cluster-ca.crt")"; bfp="$(ca_fp "${M2OUT}/certs/beta/cluster-ca.crt")"
[ -n "${afp}" ] && [ -n "${bfp}" ] && [ "${afp}" != "${bfp}" ] && ok "the two domain roots are INDEPENDENT (distinct certs)" || bad "domain roots not distinct"
openssl x509 -in "${M2OUT}/certs/acme/cluster-ca.crt" -noout -subject 2>/dev/null | grep -q 'CN *= *acme Cluster CA' && ok "acme root CN = 'acme Cluster CA'" || bad "acme root CN wrong"
openssl x509 -in "${M2OUT}/certs/beta/cluster-ca.crt" -noout -subject 2>/dev/null | grep -q 'CN *= *beta Cluster CA' && ok "beta root CN = 'beta Cluster CA'" || bad "beta root CN wrong"

# each NARROW truststore holds EXACTLY its OWN root (cross-domain DENY at the anchor)
ap="$(pw "${M2OUT}/keystores/acme/passwords.json")"; bp="$(pw "${M2OUT}/keystores/beta/passwords.json")"
[ "$(ts_alias_count "${M2OUT}/keystores/acme/truststore.jks" "${ap}")" = "1" ] && ok "acme narrow truststore = 1 anchor (own root only)" || bad "acme narrow truststore anchor count != 1"
[ "$(ts_alias_count "${M2OUT}/keystores/beta/truststore.jks" "${bp}")" = "1" ] && ok "beta narrow truststore = 1 anchor (own root only)" || bad "beta narrow truststore anchor count != 1"
# acme's narrow store must NOT contain beta's root (isolation)
keytool -exportcert -keystore "${M2OUT}/keystores/acme/truststore.jks" -storepass "${ap}" -alias acme-cluster-ca -rfc 2>/dev/null > "${W}/acme-anchor.pem"
[ "$(ca_fp "${W}/acme-anchor.pem")" = "${afp}" ] && ok "acme narrow anchor = acme root (NOT beta) -> cross-domain DENY" || bad "acme narrow anchor wrong"

# acme's leaf must verify against acme's root and NOT beta's root
keytool -exportcert -keystore "${M2OUT}/keystores/acme/acme-be-gateway.keystore.jks" -storepass "$(pw "${M2OUT}/keystores/acme/passwords.json" acme-be-gateway)" -alias acme-be-gateway -rfc 2>/dev/null > "${W}/acme-leaf.pem"
openssl verify -CAfile "${M2OUT}/certs/acme/cluster-ca.crt" "${W}/acme-leaf.pem" >/dev/null 2>&1 && ok "acme leaf verifies against acme root" || bad "acme leaf does NOT verify against acme root"
openssl verify -CAfile "${M2OUT}/certs/beta/cluster-ca.crt" "${W}/acme-leaf.pem" >/dev/null 2>&1 && bad "acme leaf WRONGLY verifies against beta root (isolation broken)" || ok "acme leaf does NOT verify against beta root (isolation holds)"

# the ONE WIDE store holds BOTH roots (architecture tier is cross-domain)
WARCH="${M2OUT}/keystores/architecture"
warch_pass="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["truststore"])' "${WARCH}/passwords.json")"
[ "$(ts_alias_count "${WARCH}/truststore.jks" "${warch_pass}")" = "2" ] && ok "WIDE architecture truststore holds BOTH roots (2 anchors)" || bad "WIDE truststore anchor count != 2"
keytool -exportcert -keystore "${WARCH}/truststore.jks" -storepass "${warch_pass}" -alias acme-cluster-ca -rfc 2>/dev/null > "${W}/w-acme.pem"
keytool -exportcert -keystore "${WARCH}/truststore.jks" -storepass "${warch_pass}" -alias beta-cluster-ca -rfc 2>/dev/null > "${W}/w-beta.pem"
[ "$(ca_fp "${W}/w-acme.pem")" = "${afp}" ] && [ "$(ca_fp "${W}/w-beta.pem")" = "${bfp}" ] && ok "WIDE store anchors == the two domain roots" || bad "WIDE store anchors != the two roots"

# ─────────────────────────────────────────────────────────────────────
# 3) IMPORT-CA per domain (in a 2-domain build): one domain IMPORTS a provided
#    cert as its issuer; the OTHER GENERATES an independent root. Proves the
#    per-domain --ca-cert/--ca-key seam works alongside per-domain generate, and
#    uses the per-brand subdir layout.
# ─────────────────────────────────────────────────────────────────────
echo "-- import-CA per domain: provided cert is the issuer (not generated) --"
EXTDIR="${W}/extca"; mkdir -p "${EXTDIR}"
EXT_CN="Imported Domain Root CA"
openssl req -x509 -newkey rsa:2048 -nodes -days 30 \
  -keyout "${EXTDIR}/imp.key" -out "${EXTDIR}/imp.crt" \
  -subj "/O=ImpTest/CN=${EXT_CN}" -addext "basicConstraints=critical,CA:TRUE" >/dev/null 2>&1
IMP_FP="$(ca_fp "${EXTDIR}/imp.crt")"
# Row 1 imports the external CA; row 2 (gen.test) generates its own root.
M3="${W}/dom3.conf"
{ printf '%s %s %s %s\n' 'imp.test' 'imp' "${EXTDIR}/imp.crt" "${EXTDIR}/imp.key"
  printf '%s %s\n' 'gen.test' 'gen'; } > "${M3}"
M3OUT="${W}/m3"
DOMAINS_CONF="${M3}" bash "${GEN}" "${M3OUT}" >/dev/null 2>&1 || bad "import-CA generator failed"

# published trust anchor == the provided cert (not a fresh root); key NOT leaked
[ -f "${M3OUT}/certs/imp/cluster-ca.crt" ] && [ "$(ca_fp "${M3OUT}/certs/imp/cluster-ca.crt")" = "${IMP_FP}" ] && ok "imp domain published CA == PROVIDED cert (not generated)" || bad "imp domain CA != provided cert"
[ ! -f "${M3OUT}/certs/imp/cluster-ca.key" ] && ok "imported CA private key NOT written into output dir" || bad "imported CA key leaked into output dir"
# the OTHER (generated) domain got a DISTINCT, freshly-generated root (not the import)
[ -f "${M3OUT}/certs/gen/cluster-ca.key" ] && [ "$(ca_fp "${M3OUT}/certs/gen/cluster-ca.crt")" != "${IMP_FP}" ] && ok "gen domain GENERATED its own independent root (!= imported)" || bad "gen domain did not generate a distinct root"
# leaf issued by the imported CA + verifies against it
keytool -exportcert -keystore "${M3OUT}/keystores/imp/imp-be-gateway.keystore.jks" -storepass "$(pw "${M3OUT}/keystores/imp/passwords.json" imp-be-gateway)" -alias imp-be-gateway -rfc 2>/dev/null > "${W}/imp-leaf.pem"
openssl x509 -in "${W}/imp-leaf.pem" -noout -issuer 2>/dev/null | grep -q "${EXT_CN}" && ok "imp leaf issued by the IMPORTED CA" || bad "imp leaf issuer != imported CA"
openssl verify -CAfile "${EXTDIR}/imp.crt" "${W}/imp-leaf.pem" >/dev/null 2>&1 && ok "imp leaf verifies against the imported CA" || bad "imp leaf does NOT verify against imported CA"
# WIDE store anchors the imported root (alongside the generated one)
W3="${M3OUT}/keystores/architecture"; w3p="$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1]))["truststore"])' "${W3}/passwords.json")"
[ "$(ts_alias_count "${W3}/truststore.jks" "${w3p}")" = "2" ] && ok "WIDE store holds both the imported + generated roots (2 anchors)" || bad "WIDE store anchor count != 2"
keytool -exportcert -keystore "${W3}/truststore.jks" -storepass "${w3p}" -alias imp-cluster-ca -rfc 2>/dev/null > "${W}/w3.pem"
[ "$(ca_fp "${W}/w3.pem")" = "${IMP_FP}" ] && ok "WIDE store anchor (imp) == the imported root" || bad "WIDE store anchor (imp) != imported root"

# ─────────────────────────────────────────────────────────────────────
# 4) SINGLE-ROW import via domains.conf stays on the BYTE-IDENTICAL canonical
#    layout (no per-brand subdir) and still honors the import — same seam, N=1.
# ─────────────────────────────────────────────────────────────────────
echo "-- single-row import: canonical layout + imported issuer (N=1 byte-identical path) --"
M4="${W}/dom4.conf"; printf '%s %s %s %s\n' 'imp.test' "${BRAND}" "${EXTDIR}/imp.crt" "${EXTDIR}/imp.key" > "${M4}"
M4OUT="${W}/m4"
DOMAINS_CONF="${M4}" bash "${GEN}" "${M4OUT}" >/dev/null 2>&1 || bad "single-row import generator failed"
# canonical (no subdir) cert == the imported one
[ -f "${M4OUT}/certs/cluster-ca.crt" ] && [ ! -d "${M4OUT}/certs/${BRAND}" ] && [ "$(ca_fp "${M4OUT}/certs/cluster-ca.crt")" = "${IMP_FP}" ] \
  && ok "single-row import -> canonical certs/cluster-ca.crt == imported (no subdir)" || bad "single-row import layout/issuer wrong"

echo "== RESULT: ${P} passed, ${F} failed =="
[ "${F}" -eq 0 ]
