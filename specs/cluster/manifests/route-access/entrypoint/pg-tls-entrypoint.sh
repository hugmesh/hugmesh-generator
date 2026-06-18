#!/bin/sh
# route-access-db Postgres entrypoint wrapper — GATED in-cluster TLS (ships dark).
#
# Mirrors the egress-proxy entrypoint idiom (manifests/egress-proxy): an env-var
# gate defaulting OFF selects the config, so enabling is config-only and the
# default wire path is byte-identical to ssl-off.
#
# GATE: PG_TLS_ENABLED (default "false").
#   - OFF (default): exec the SAME static server args as before — NO `-c ssl=on`.
#     The Vault-PKI server cert is mounted at /etc/postgres-tls but UNUSED. The
#     wire path is byte-identical to the pre-TLS deployment.
#   - ON: append `-c ssl=on -c ssl_cert_file=… -c ssl_key_file=…` so Postgres
#     offers TLS. (Server `ssl=on` still ACCEPTS non-TLS `host` connections, so
#     flipping the server gate alone does NOT break consumers that have not yet
#     added `sslmode=require`; tighten consumers + pg_hba to `hostssl` as a
#     follow-up once every consumer negotiates TLS.)
#
# This wrapper calls the stock postgres image entrypoint (docker-entrypoint.sh),
# so initdb runs unchanged.
set -eu

# Static server hardening args (identical to the pre-gate `args:` list).
set -- postgres \
  -c password_encryption=scram-sha-256 \
  -c max_connections=50 \
  -c log_connections=on \
  -c log_disconnections=on \
  -c log_min_duration_statement=2000

if [ "${PG_TLS_ENABLED:-false}" = "true" ]; then
  echo "route-access-db: PG_TLS_ENABLED=true -> Postgres ssl=on (serving TLS from /etc/postgres-tls)"
  set -- "$@" \
    -c ssl=on \
    -c ssl_cert_file=/etc/postgres-tls/tls.crt \
    -c ssl_key_file=/etc/postgres-tls/tls.key
else
  echo "route-access-db: PG_TLS_ENABLED=false -> ssl off (default; cert mounted but unused)"
fi

exec docker-entrypoint.sh "$@"
