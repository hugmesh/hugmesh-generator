#!/usr/bin/env bash
# gen-certs.sh — generate the TLS CA + server certificate and the runtime
# "values" the integration stack serves the front page with. Rootless; uses
# openssl only. These stand in for the certs/values a KEYS stick would carry.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OUT="${1:-${HERE}/certs}"
DOMAIN="${SNAP_DOMAIN:-hugmesh.net}"
mkdir -p "${OUT}"

echo "==> Generating CA + server cert for *.${DOMAIN} (+localhost) in ${OUT}"

# Root CA (the cluster CA the KEYS stick would distribute).
openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
    -keyout "${OUT}/ca.key" -out "${OUT}/ca.crt" \
    -subj "/O=HugMesh Systems/CN=HugMesh Cluster CA" 2>/dev/null

# Server key + CSR.
openssl req -newkey rsa:2048 -nodes \
    -keyout "${OUT}/server.key" -out "${OUT}/server.csr" \
    -subj "/O=HugMesh Systems/CN=${DOMAIN}" 2>/dev/null

cat > "${OUT}/san.ext" <<EOF
subjectAltName = DNS:${DOMAIN},DNS:*.${DOMAIN},DNS:id.${DOMAIN},DNS:matrix.${DOMAIN},DNS:mastodon.${DOMAIN},DNS:localhost,IP:127.0.0.1
extendedKeyUsage = serverAuth
EOF

openssl x509 -req -in "${OUT}/server.csr" \
    -CA "${OUT}/ca.crt" -CAkey "${OUT}/ca.key" -CAcreateserial \
    -days 825 -extfile "${OUT}/san.ext" \
    -out "${OUT}/server.crt" 2>/dev/null

cat "${OUT}/server.crt" "${OUT}/ca.crt" > "${OUT}/fullchain.crt"

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

echo "==> Done:"
ls -1 "${OUT}"
echo "--- server cert SANs ---"
openssl x509 -in "${OUT}/server.crt" -noout -ext subjectAltName 2>/dev/null | sed 's/^/    /'
