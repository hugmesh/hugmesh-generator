#!/usr/bin/env bash
# gen-certs.sh — generate the TLS CA + server certificate and the runtime
# "values" the integration stack serves the front page with. Rootless; uses
# openssl only. These stand in for the certs/values a KEYS stick would carry.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${HERE}/certs}"
DOMAIN="${SNAP_DOMAIN:-hugmesh.net}"
mkdir -p "${OUT}"

# LEAF_ONLY=1 re-issues ONLY the server certificate under the CA already in ${OUT}: the
# CA (what a browser or device was told to trust) and values.json (its session secret)
# stay as they are. `make stack-certs` uses it to add *.localhost to a leaf minted before
# the sample domains existed (acme.localhost, example.localhost).
#
# SNAP_EXTRA_SANS (comma separated; default the two sample domains) adds those host names
# to the leaf. Listed one by one on purpose: OpenSSL refuses a wildcard over a single label
# (`*.localhost` is read like `*.com`), so a domain served at <slug>.localhost needs its own
# SAN. The CA only vouches for ${DOMAIN}, localhost and loopback, so a name outside
# those is refused here rather than minted into a leaf no client would accept.
LEAF_ONLY="${LEAF_ONLY:-}"
if [ "${LEAF_ONLY}" = 1 ] && { [ ! -f "${OUT}/ca.key" ] || [ ! -f "${OUT}/ca.crt" ]; }; then
    echo "gen-certs: LEAF_ONLY=1 needs ${OUT}/ca.key and ca.crt (mint a fresh set instead)" >&2
    exit 1
fi

EXTRA_SANS=""
for n in $(printf '%s' "${SNAP_EXTRA_SANS-acme.localhost,example.localhost}" | tr ',' ' '); do
    case "${n}" in
        *[!a-z0-9.-]*|.*|*..*|*.) echo "gen-certs: SNAP_EXTRA_SANS entry '${n}' is not a plain host name" >&2; exit 1 ;;
        *.localhost|*."${DOMAIN}") EXTRA_SANS="${EXTRA_SANS},DNS:${n}" ;;
        *) echo "gen-certs: SNAP_EXTRA_SANS entry '${n}' is outside what the CA vouches for (*.localhost, *.${DOMAIN})" >&2; exit 1 ;;
    esac
done

if [ "${LEAF_ONLY}" = 1 ]; then
    echo "==> Re-issuing the server cert for *.${DOMAIN} (+localhost) under the existing CA in ${OUT}"
else
    echo "==> Generating CA + server cert for *.${DOMAIN} (+localhost) in ${OUT}"
fi

# Root CA (the cluster CA the KEYS stick would distribute). NAME-CONSTRAINED:
# it can only ever vouch for ${DOMAIN} (and its subdomains), localhost and the
# loopback addresses. A CA without nameConstraints that someone imports into a
# browser or a device trust store can sign a certificate for ANY site, so a leaked
# or shared ca.key would let its holder intercept anything that trusts it. With
# the constraints, a certificate for any other name fails to verify even when the
# CA is trusted. Never trust this CA outside a throwaway test profile anyway.
if [ "${LEAF_ONLY}" != 1 ]; then
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "${OUT}/ca.key" -out "${OUT}/ca.crt" \
    -subj "/O=HugMesh Test/CN=HugMesh Test CA" \
    -addext "basicConstraints=critical,CA:TRUE,pathlen:0" \
    -addext "keyUsage=critical,keyCertSign,cRLSign" \
    -addext "nameConstraints=critical,permitted;DNS:${DOMAIN},permitted;DNS:localhost,permitted;IP:127.0.0.0/255.0.0.0,permitted;IP:0:0:0:0:0:0:0:1/FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF:FFFF" \
    2>/dev/null
fi

# Server key + CSR.
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUT}/server.key" -out "${OUT}/server.csr" \
    -subj "/O=HugMesh Test/CN=${DOMAIN}" 2>/dev/null

cat > "${OUT}/san.ext" <<EOF
subjectAltName = DNS:${DOMAIN},DNS:*.${DOMAIN},DNS:id.${DOMAIN},DNS:matrix.${DOMAIN},DNS:mastodon.${DOMAIN},DNS:localhost${EXTRA_SANS},IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

openssl x509 -req -in "${OUT}/server.csr" \
    -CA "${OUT}/ca.crt" -CAkey "${OUT}/ca.key" -CAcreateserial \
    -days 825 -extfile "${OUT}/san.ext" \
    -out "${OUT}/server.crt" 2>/dev/null

cat "${OUT}/server.crt" "${OUT}/ca.crt" > "${OUT}/fullchain.crt"

if [ "${LEAF_ONLY}" != 1 ]; then
# Runtime "values" the UI is served with (Casdoor issuer, service URLs, and a
# generated session secret) — same shape provisioning would inject.
cat > "${OUT}/values.json" <<EOF
{
  "clusterDomain": "${DOMAIN}",
  "casdoorIssuer": "https://id.${DOMAIN}",
  "matrixUrl": "https://matrix.${DOMAIN}",
  "mastodonUrl": "https://mastodon.${DOMAIN}",
  "uptraceUrl": "https://uptrace.${DOMAIN}",
  "sessionSecret": "$(openssl rand -hex 24)",
  "generatedAt": "$(date -u +%FT%TZ)"
}
EOF
fi

echo "==> Done:"
ls -1 "${OUT}"
echo "--- server cert SANs ---"
openssl x509 -in "${OUT}/server.crt" -noout -ext subjectAltName 2>/dev/null | sed 's/^/    /'
